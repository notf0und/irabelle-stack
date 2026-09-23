#!/usr/bin/env python3
"""
books-glue: keeps the book pipeline in sync.

Watches the Calibre library folder (the same folder CWA imports into) and
whenever new book files appear it:

  1. Fixes stale "File not found" links in the Shelfmark downloader
     (shelfmark) history database: the downloader stores the path
     of the file while it lived in the CWA ingest folder, but CWA moves it
     into the library after processing.  This script updates those rows to
     point at the book's new location inside the library, so clicking a
     completed download in the downloader keeps working.

  2. Triggers a Kavita library scan through its REST API, so newly imported
     books appear in Kavita almost immediately instead of waiting for the
     daily scheduled scan.

  3. Restarts the Calibre GUI container so it reloads the library from disk
     (the GUI holds the library in memory and cannot see books added by CWA
     until it is restarted).  This can be disabled with CALIBRE_AUTO_RESTART.

Everything is configurable through environment variables; see compose.yml.

Pure Python 3 stdlib - no external dependencies.
"""

from __future__ import annotations

import json
import os
import re
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration (environment variables, see compose.yml)
# ---------------------------------------------------------------------------

LIBRARY_DIR = Path(os.environ.get("LIBRARY_DIR", "/library"))            # Calibre library (read-only)
INGEST_DIR = Path(os.environ.get("INGEST_DIR", "/ingest"))               # CWA ingest folder (read-only)
DOWNLOADER_DB = Path(os.environ.get("DOWNLOADER_DB", "/downloader-config/users.db"))
# Path prefix the downloader container uses for the library (its mount of the same host folder)
DOWNLOADER_LIBRARY_PREFIX = os.environ.get("DOWNLOADER_LIBRARY_PREFIX", "/calibre-library")
# Path prefix the downloader uses for the ingest folder (its mount of the same host folder)
DOWNLOADER_INGEST_PREFIX = os.environ.get("DOWNLOADER_INGEST_PREFIX", "/cwa-book-ingest")

KAVITA_URL = os.environ.get("KAVITA_URL", "http://kavita:5000").rstrip("/")
KAVITA_API_KEY = os.environ.get("KAVITA_API_KEY", "")

CALIBRE_CONTAINER = os.environ.get("CALIBRE_CONTAINER", "calibre")
CALIBRE_AUTO_RESTART = os.environ.get("CALIBRE_AUTO_RESTART", "false").lower() in ("1", "true", "yes")
DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")

# Feature toggles (all default ON except the Calibre GUI restart). Set any of
# these to "false" in .env to disable that part of the glue without touching
# compose.yml. GLUE_ENABLED=false makes the glue do nothing at all (equivalent
# to commenting the service out, but re-enableable with a single env change).
GLUE_ENABLED = os.environ.get("GLUE_ENABLED", "true").lower() in ("1", "true", "yes")
FIX_DOWNLOADER_LINKS = os.environ.get("GLUE_FIX_DOWNLOADER", "true").lower() in ("1", "true", "yes")
SCAN_KAVITA = os.environ.get("GLUE_SCAN_KAVITA", "true").lower() in ("1", "true", "yes")
# Daily shadow-library mirror refresh (mirrors rot; see scripts/shelfmark/
# refresh_mirrors.py). That module owns its own interval/cadence env; this is
# just the switch, and like the other actions it follows GLUE_ENABLED.
MIRROR_REFRESH = os.environ.get("MIRROR_REFRESH_ENABLED", "true").lower() in ("1", "true", "yes")

POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "20"))       # seconds between polls
ACTION_DEBOUNCE = int(os.environ.get("ACTION_DEBOUNCE", "60"))   # wait after last new file before acting (CWA finishing writes)
ACTION_COOLDOWN = int(os.environ.get("ACTION_COOLDOWN", "300"))  # min seconds between Kavita scans / Calibre restarts
MATCH_THRESHOLD = float(os.environ.get("MATCH_THRESHOLD", "0.6"))

STATE_FILE = Path(os.environ.get("STATE_FILE", "/state/seen.json"))

# Mounted read-only into this container (compose.yml). Optional on purpose: if
# it is not mounted the glue still runs, it just skips the mirror refresh.
try:
    import refresh_mirrors
except ImportError:  # noqa: BLE001
    refresh_mirrors = None  # type: ignore[assignment]

# Book/audiobook file extensions the glue reacts to (anything else is ignored:
# metadata.db*, cover.jpg, metadata.opf, .DS_Store, etc.)
BOOK_EXTS = {
    ".epub", ".mobi", ".azw3", ".fb2", ".djvu", ".cbz", ".cbr", ".pdf",
    ".m4b", ".mp3", ".m4a", ".flac", ".ogg", ".wma", ".aac", ".wav", ".opus",
}
IGNORED_DIRS = {".calnotes", ".caltrash", "@eaDir", "#recycle"}

STOPWORDS = {
    "the", "a", "an", "of", "and", "for", "in", "on", "to", "with", "by",
    "at", "from", "or", "is", "are", "was", "were", "book", "books",
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"[books-glue] {ts} {msg}", flush=True)

# ---------------------------------------------------------------------------
# Library / ingest helpers
# ---------------------------------------------------------------------------


def iter_library_files(root: Path) -> list[Path]:
    """Return book files under *root*, skipping calibre internals."""
    files: list[Path] = []
    try:
        for p in root.rglob("*"):
            if not p.is_file():
                continue
            if p.suffix.lower() not in BOOK_EXTS:
                continue
            rel = p.relative_to(root)
            if any(part.startswith(".") or part in IGNORED_DIRS for part in rel.parts):
                continue
            files.append(p)
    except OSError as exc:  # pragma: no cover - transient fs issues
        log(f"WARN: error walking library: {exc}")
    return files


def normalize_tokens(text: str) -> set[str]:
    """Lowercase, drop symbols/stopwords and return a token set.

    ``\\W`` is Unicode-aware, so non-Latin scripts keep their words. The previous
    ``[^a-z0-9]`` stripped every Cyrillic character, which reduced a Russian title
    to nothing but its year - so it never matched, and with only the author tokens
    left it could match the *wrong* book instead.
    """
    text = text.lower()
    text = text.replace("\u00ae", " (r) ").replace("\u2122", " ").replace("\u00a9", " ")
    text = re.sub(r"[\W_]+", " ", text)
    tokens = {t for t in text.split() if t not in STOPWORDS}
    return tokens


def row_needle_tokens(row: dict) -> tuple[set[str], set[str]]:
    """Return (title tokens, author tokens) for matching a history row.

    Matching is scored on the *title* tokens. The downloader's author field is
    often a Cyrillic full name while the library uses a transliterated one
    ("Виктор Олегович Пелевин" vs "Victor Pelevin"), so scoring a combined set
    let an author-only overlap win and pull the wrong book.
    """
    title = normalize_tokens(str(row.get("title") or ""))
    if not title:
        # No usable title - fall back to the original ingest filename.
        title = normalize_tokens(Path(str(row.get("download_path") or "")).stem)
    author = normalize_tokens(str(row.get("author") or ""))
    return title, author


def file_haystack_tokens(path: Path, root: Path) -> set[str]:
    """Tokens from a library file: parent folder names + filename stem."""
    rel = path.relative_to(root)
    folder_parts = [p for p in rel.parts[:-1]]
    folder_parts.append(path.stem)
    return normalize_tokens(" ".join(folder_parts))


def match_library_file(
    title_tokens: set[str],
    author_tokens: set[str],
    preferred_format: str | None,
    files: list[Path],
    root: Path,
) -> Path | None:
    """Return the best library file for a row, or None.

    Ranked by title-token coverage, then the row's own recorded format, then epub,
    then author overlap. Format ranks *above* author on purpose: library author
    names are transliterated inconsistently ("Виктор Олегович Пелевин" vs "Victor
    Pelevin"), so author overlap once preferred a PDF inside another book's folder
    over the correct epub.
    """
    best: Path | None = None
    best_rank: tuple[float, bool, bool, int] = (-1.0, False, False, -1)
    if not title_tokens:
        return None
    want_suffix = f".{str(preferred_format).lower().lstrip('.')}" if preferred_format else ""
    for f in files:
        hay = file_haystack_tokens(f, root)
        if not hay:
            continue
        common = title_tokens & hay
        if not common:
            continue
        score = len(common) / len(title_tokens)
        if score < MATCH_THRESHOLD:
            continue
        suffix = f.suffix.lower()
        rank = (score, suffix == want_suffix, suffix == ".epub", len(author_tokens & hay))
        if rank > best_rank:
            best, best_rank = f, rank
    if best is not None:
        log(f"match: score={best_rank[0]:.2f} format={best.suffix.lower()} -> {best}")
    return best

# ---------------------------------------------------------------------------
# Downloader history DB
# ---------------------------------------------------------------------------


def pending_rows(db_path: Path) -> list[dict]:
    """Rows whose ingest file has been moved away (processed by CWA)."""
    if not db_path.exists():
        return []
    rows: list[dict] = []
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
        conn.execute("PRAGMA busy_timeout=10000")
        try:
            cur = conn.execute(
                "SELECT task_id, title, author, download_path, format FROM download_history "
                "WHERE final_status='complete' AND download_path IS NOT NULL AND download_path != ''"
            )
            for r in cur.fetchall():
                rows.append(
                    {
                        "task_id": r[0],
                        "title": r[1],
                        "author": r[2],
                        "download_path": r[3],
                        "format": r[4],
                    }
                )
        finally:
            conn.close()
    except sqlite3.Error as exc:
        log(f"WARN: could not read downloader db: {exc}")
    return rows


def is_pending(row: dict) -> bool:
    """True when the row still points at the ingest dir and the file is gone."""
    p = row.get("download_path") or ""
    if not p.startswith(DOWNLOADER_INGEST_PREFIX):
        return False  # already relocated or unknown layout
    rel = p[len(DOWNLOADER_INGEST_PREFIX):].lstrip("/")
    return not (INGEST_DIR / rel).exists()


def is_library_mismatch(row: dict) -> bool:
    """True when an already-relocated row no longer points at a credible file.

    Existence alone is not enough: a link matched to the *wrong* book still
    resolves. So the current path is re-scored against the row's title, which is
    how a row mis-linked by the old ASCII-only matcher gets corrected instead of
    silently serving the wrong download.
    """
    p = row.get("download_path") or ""
    if not p.startswith(DOWNLOADER_LIBRARY_PREFIX):
        return False
    rel = p[len(DOWNLOADER_LIBRARY_PREFIX):].lstrip("/")
    target = LIBRARY_DIR / rel
    if not target.is_file():
        return True
    title_tokens, _author = row_needle_tokens(row)
    if not title_tokens:
        return False
    hay = file_haystack_tokens(target, LIBRARY_DIR)
    if not hay:
        return False
    return (len(title_tokens & hay) / len(title_tokens)) < MATCH_THRESHOLD


def relocate_rows(rows: list[dict], library_files: list[Path],
                  retry_skip: dict[str, float]) -> int:
    """Update download_path of matched rows to the library location."""
    updated = 0
    now = time.time()
    conn = sqlite3.connect(str(DOWNLOADER_DB), timeout=10)
    conn.execute("PRAGMA busy_timeout=10000")
    try:
        for row in rows:
            task_id = row["task_id"]
            if not (is_pending(row) or is_library_mismatch(row)):
                continue
            # Don't spam unmatched rows: retry at most every 5 minutes.
            if retry_skip.get(task_id, 0) > now:
                continue
            needle_title, needle_author = row_needle_tokens(row)
            if not needle_title:
                continue
            target = match_library_file(
                needle_title, needle_author, row.get("format"), library_files, LIBRARY_DIR
            )
            if target is None:
                # Book may still be mid-import; retry in a few minutes.
                retry_skip[task_id] = now + 300
                log(f"no library match for '{row['title']}' ({task_id}); will retry later")
                continue
            rel = target.relative_to(LIBRARY_DIR)
            new_path = f"{DOWNLOADER_LIBRARY_PREFIX}/{rel.as_posix()}"
            if new_path == row["download_path"]:
                continue
            cur = conn.execute(
                "UPDATE download_history SET download_path=? "
                "WHERE task_id=? AND final_status='complete'",
                (new_path, task_id),
            )
            conn.commit()
            if cur.rowcount:
                updated += 1
                log(f"relocated '{row['title']}' -> {new_path}")
    finally:
        conn.close()
    return updated

# ---------------------------------------------------------------------------
# Actions: Kavita scan + Calibre restart
# ---------------------------------------------------------------------------


def trigger_kavita_scan() -> bool:
    if not KAVITA_API_KEY:
        log("WARN: KAVITA_API_KEY not set, skipping Kavita scan")
        return False
    url = f"{KAVITA_URL}/api/Library/scan-all"
    req = urllib.request.Request(url, method="POST")
    req.add_header("x-api-key", KAVITA_API_KEY)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            log(f"kavita scan-all triggered (HTTP {resp.status})")
            return True
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as exc:
        log(f"WARN: kavita scan failed: {exc}")
        return False


def restart_container(name: str) -> bool:
    """Request a docker container restart through the engine unix socket.

    The restart API is synchronous and can take a minute for slow containers
    (e.g. the Calibre GUI stack), so this is fire-and-forget: we send the
    request and do not block on the full response.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(DOCKER_SOCKET)
        sock.settimeout(5)
        req = f"POST /containers/{name}/restart HTTP/1.1\r\nHost: docker\r\n\r\n"
        sock.sendall(req.encode())
        try:
            data = sock.recv(65536)
            status_line = data.split(b"\r\n", 1)[0].decode(errors="replace")
            log(f"docker restart {name}: {status_line}")
            return " 204" in status_line or " 200" in status_line
        except socket.timeout:
            log(f"docker restart {name}: request sent (container restarting in background)")
            return True
    except OSError as exc:
        log(f"WARN: could not restart {name}: {exc}")
        return False
    finally:
        sock.close()

# ---------------------------------------------------------------------------
# State (which files have already been seen)
# ---------------------------------------------------------------------------


def load_state() -> dict:
    try:
        data = json.loads(STATE_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(state))
        tmp.replace(STATE_FILE)
    except OSError as exc:
        log(f"WARN: could not write state file: {exc}")


def new_files_since(files: list[Path], state_files: dict) -> list[Path]:
    seen = set(state_files.get("files", {}).keys())
    return [f for f in files if f.relative_to(LIBRARY_DIR).as_posix() not in seen]

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def main() -> int:
    log("starting")
    log(
        f"library={LIBRARY_DIR} ingest={INGEST_DIR} db={DOWNLOADER_DB} "
        f"kavita={KAVITA_URL}"
    )
    log(
        f"toggles: enabled={GLUE_ENABLED} fix_downloader={FIX_DOWNLOADER_LINKS} "
        f"scan_kavita={SCAN_KAVITA} calibre_restart={CALIBRE_AUTO_RESTART} "
        f"mirror_refresh={MIRROR_REFRESH and refresh_mirrors is not None}"
    )
    if not GLUE_ENABLED:
        log("glue disabled via GLUE_ENABLED=false; idle (no actions)")
        while True:
            time.sleep(3600)

    state = load_state()
    pending_since: float | None = None
    last_action_at = 0.0
    retry_skip: dict[str, float] = {}

    while True:
        try:
            # 0. Keep shadow-library mirrors fresh. Self-throttled to once a day,
            #    so this is a cheap no-op on every other poll.
            if MIRROR_REFRESH and refresh_mirrors is not None:
                refresh_mirrors.maybe_run(log=log)

            files = iter_library_files(LIBRARY_DIR)
            rel_map = {
                f.relative_to(LIBRARY_DIR).as_posix(): f.stat().st_mtime
                for f in files
            }

            # First run: snapshot the library without triggering any actions,
            # so pre-existing books don't cause a scan/restart storm.
            if "files" not in state:
                state = {"files": rel_map}
                save_state(state)
                log(f"initial snapshot recorded ({len(rel_map)} files); no actions taken")
                time.sleep(POLL_INTERVAL)
                continue

            # 1. Fix stale downloader paths (also backfills historical rows).
            if FIX_DOWNLOADER_LINKS:
                rows = pending_rows(DOWNLOADER_DB)
                if rows:
                    updated = relocate_rows(rows, files, retry_skip)
                    if updated:
                        log(f"relocated {updated} download(s) to their library location")

            # 2. Detect genuinely new books (for scan + restart actions).
            fresh = new_files_since(files, state)
            if fresh and pending_since is None:
                names = ", ".join(f.relative_to(LIBRARY_DIR).as_posix() for f in fresh[:5])
                log(f"detected {len(fresh)} new file(s): {names}"
                    + (" ..." if len(fresh) > 5 else ""))
                pending_since = time.time()  # debounce starts once, not per poll

            # 3. Act once CWA has finished writing the book folder.
            acted = False
            if pending_since is not None and time.time() >= pending_since + ACTION_DEBOUNCE:
                if time.time() - last_action_at >= ACTION_COOLDOWN:
                    if SCAN_KAVITA:
                        trigger_kavita_scan()
                    if CALIBRE_AUTO_RESTART:
                        restart_container(CALIBRE_CONTAINER)
                    elif not SCAN_KAVITA:
                        log("new files detected but all actions are disabled "
                            "(GLUE_SCAN_KAVITA=false and CALIBRE_AUTO_RESTART=false)")
                    last_action_at = time.time()
                    pending_since = None
                    acted = True
                else:
                    log("new files detected but action cooldown active; will retry")

            # 4. Persist the snapshot only when nothing fresh is still waiting,
            #    otherwise the pending files would be marked seen before we act.
            if not fresh or acted:
                state = {"files": rel_map}
                save_state(state)
        except Exception as exc:  # noqa: BLE001 - keep the loop alive
            log(f"ERROR in poll cycle: {exc!r}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
