#!/usr/bin/env python3
"""Refresh Shelfmark's shadow-library mirror lists from open-slum.org.

SLUM (Shadow Library Uptime Monitor) health-checks the mirror domains on a
5-minute cadence and publishes the result as static HTML. This script reads
that page, works out which mirrors are currently serving, and pushes them into
Shelfmark through its own settings API - the same call the Settings UI makes,
so the change is persisted and applied live (``network.init_aa(force=True)``)
with no container restart.

Why it exists: mirror domains rot. A stale entry in ``AA_MIRROR_URLS`` costs a
failed request per search, and a *dead* primary mirror can look like "Anna's
Archive is down" when three working mirrors are sitting right there. Because
``AA_BASE_URL: auto`` tries the list in order, this also keeps the best-known
mirror first.

Design notes:
  * **SLUM is the source of truth** for what is up. ``up`` and ``protected``
    both count as working: for Anna's Archive, ``protected`` is the *normal*
    healthy state (it is the DDoS-Guard challenge, which the internal bypasser
    handles - ``annas-archive.gl`` is PROTECTED and works fine).
  * **Candidates are tested before being added** (``MIRROR_REFRESH_VERIFY``,
    default on): a URL that does not answer is simply not added this run.
    Already-configured mirrors are never dropped for a failed probe, only for
    what SLUM reports - probes fail transiently (observed: ``Errno -3`` on a
    domain that answered minutes later) and deleting a working mirror is worse
    than keeping a quiet one.
  * **Each URL is checked against the shape Shelfmark expects** for that
    setting: a bare base URL (no path/query/fragment) whose host matches the
    source's pattern. SLUM's cards are not clean - its "other" card mixes
    ``welib.org`` with non-Welib mirrors - so anything that does not belong is
    rejected and logged instead of being pushed into the config.
  * **The list order follows SLUM's**, because ``AA_BASE_URL: auto`` tries
    mirrors in order and Z-Library uses only the first entry.
  * **Never wipes a list.** If SLUM fails to parse, or every candidate fails
    verification, that source is left untouched and a warning is logged. Losing
    a working mirror is far worse than keeping a stale one, and ``auto`` mode
    already fails over harmlessly.

Usage:
    refresh_mirrors.py                 # refresh now (all enabled sources)
    refresh_mirrors.py --dry-run       # show what would change, apply nothing
    refresh_mirrors.py --sources aa    # restrict to one source
    refresh_mirrors.py --print-slum    # dump what SLUM reports, then exit
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser

# A browser UA is mandatory: open-slum.org returns 403 to python-urllib's
# default agent (verified), while this one gets 200 from the containers.
DEFAULT_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126 Safari/537.36"
)

DEFAULT_SLUM_URL = "https://open-slum.org/"
DEFAULT_API = "http://shelfmark:8084/api/settings/mirrors"
DEFAULT_CONFIG = "/downloader-config/plugins/mirrors.json"
DEFAULT_STATE = "/state/mirror-refresh.json"

# SLUM card slug -> Shelfmark setting key + the URL shape that key expects.
#
# Every one of these settings is a *bare base URL*: Shelfmark appends its own
# path - ``/search?...`` for AA, ``/md5/{md5}`` for Z-Library and Welib (see
# ``mirrors.get_zlib_url_template`` / ``get_welib_url_template``). A configured
# mirror carrying a path, query or fragment therefore builds a malformed
# request, which is why the check requires scheme + host and nothing else.
#
# The host pattern is not cosmetic, because the SLUM cards are not clean:
#   * "annas" also carries software.annas-archive.gl and Anna's Archive's
#     download hosts (yqrii5.org, wbsg8v.xyz), which are not search mirrors.
#   * "other" is a grab-bag - welib.org sits beside libstc.nexus,
#     liber3.eth.limo and library.memoryoftheworld.org, which are *not* Welib
#     mirrors and must never reach WELIB_MIRROR_URLS.
SOURCES: dict[str, dict] = {
    "aa": {
        "card": "annas",
        "key": "AA_MIRROR_URLS",
        "label": "Anna's Archive",
        "pattern": re.compile(r"^annas-archive\.[a-z0-9-]+$"),
    },
    "libgen": {
        "card": "libgen",
        "key": "LIBGEN_MIRROR_URLS",
        "label": "LibGen",
        "pattern": re.compile(r"^libgen\.[a-z0-9-]+$"),
    },
    "zlib": {
        "card": "zlibrary",
        "key": "ZLIB_MIRROR_URLS",
        "label": "Z-Library",
        # The card is Z-Library-only, but the brands differ enough that an
        # explicit set is safer than accepting whatever the card contains.
        "pattern": re.compile(
            r"^(z-library|1lib|z-lib|go-to-library|library-access)\.[a-z0-9-]+$"
        ),
    },
    "welib": {
        "card": "other",
        "key": "WELIB_MIRROR_URLS",
        "label": "Welib",
        # Anchored both ends: "welib" as a substring would also match
        # notwelib.example or welib.example.somewhere-else.com.
        "pattern": re.compile(r"^(welib\.org|[a-z0-9-]+\.welib\.org)$"),
    },
}

# "protected" is a healthy state for these sites, not a failure.
OK_STATUSES = {"up", "protected"}
# One failed check in a 5-minute window; sometimes still the best available.
DEGRADED_STATUS = "degraded"


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(float(raw))
    except ValueError:
        return default
    return value if value > 0 else default


class _SlumParser(HTMLParser):
    """Collect {card_slug: [(url, status), ...]} from the SLUM homepage.

    The markup is stable and simple:

        <div class="site-card">
          <a href="annas.html" class="site-card-title">annas</a>
          ...
          <li class="domain-item-dense">
            <a href="https://annas-archive.gl" class="domain-link">...</a>
            <div class="status-col">
              <a class="status-badge compact protected" ...>PROTECTED</a>
            </div>
          </li>

    Note the card header also uses ``status-badge`` (the site-wide rollup), so a
    status is only captured while inside a domain item.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.cards: dict[str, list[tuple[str, str]]] = {}
        self._card: str | None = None
        self._in_item = False
        self._url: str | None = None
        self._status: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            if tag == "li":
                classes = dict(attrs).get("class") or ""
                if "domain-item-dense" in classes.split():
                    self._in_item = True
                    self._url = None
                    self._status = None
            return

        attr = {k: (v or "") for k, v in attrs}
        classes = attr.get("class", "").split()

        if "site-card-title" in classes:
            href = attr.get("href", "")
            slug = href[:-5] if href.endswith(".html") else href
            self._card = slug
            self.cards.setdefault(slug, [])
            return

        if not self._in_item:
            return

        if "domain-link" in classes and self._url is None:
            self._url = attr.get("href")
        elif "status-badge" in classes and self._status is None:
            tokens = [c for c in classes if c not in ("status-badge", "compact")]
            self._status = tokens[0].lower() if tokens else None

    def handle_endtag(self, tag: str) -> None:
        if tag == "li" and self._in_item:
            if self._card and self._url and self._status:
                self.cards[self._card].append((self._url, self._status))
            self._in_item = False


def parse_slum(html: str) -> dict[str, list[tuple[str, str]]]:
    parser = _SlumParser()
    parser.feed(html)
    return parser.cards


def fetch_slum(url: str, user_agent: str, timeout: int) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def _structure_error(url: str, spec: dict) -> str | None:
    """Return why a SLUM URL is not a shape Shelfmark can use, else None."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https"):
        return "not http(s)"
    host = (parsed.hostname or "").lower()
    if not host:
        return "no host"
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        return "not a bare base URL (Shelfmark appends its own path)"
    if not spec["pattern"].match(host):
        return "host is not a mirror of this source"
    return None


def select_candidates(
    parsed: dict[str, list[tuple[str, str]]],
    spec: dict,
    include_degraded: bool,
) -> tuple[list[str], list[tuple[str, str]]]:
    """Ordered SLUM URLs that pass the status + structure checks, plus rejects."""
    allowed = set(OK_STATUSES)
    if include_degraded:
        allowed.add(DEGRADED_STATUS)

    candidates: list[str] = []
    rejected: list[tuple[str, str]] = []
    for raw_url, status in parsed.get(spec["card"], []):
        if status not in allowed:
            continue
        url = raw_url.strip()
        reason = _structure_error(url, spec)
        if reason is not None:
            rejected.append((url, reason))
            continue
        if url not in candidates:
            candidates.append(url)
    return candidates, rejected


def probe(url: str, user_agent: str, timeout: int) -> bool:
    """True if the host answers at all.

    Any HTTP response counts as alive - a 403 or a DDoS-Guard challenge means
    the mirror is up and doing its job. Only DNS, TLS and connection failures
    (a dead/rotated domain, like annas-archive.vg's broken certificate) count
    as dead.
    """
    request = urllib.request.Request(url, headers={"User-Agent": user_agent})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response.read(2048)
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:  # noqa: BLE001 - URLError covers DNS/TLS/timeout
        return False


def verify(urls: list[str], user_agent: str, timeout: int, workers: int) -> list[str]:
    if not urls:
        return []
    with ThreadPoolExecutor(max_workers=max(1, min(workers, len(urls)))) as pool:
        results = list(pool.map(lambda u: (u, probe(u, user_agent, timeout)), urls))
    return [url for url, alive in results if alive]


def load_current(config_path: str) -> dict[str, list[str]]:
    try:
        with open(config_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    out: dict[str, list[str]] = {}
    for spec in SOURCES.values():
        value = data.get(spec["key"])
        if isinstance(value, list):
            out[spec["key"]] = [str(v) for v in value]
    return out


def apply_changes(api_url: str, changes: dict[str, list[str]], timeout: int) -> dict:
    # Once Shelfmark has a login (authentik, with a local admin to fall back
    # on) the settings API answers 401 without a session, so log in first as
    # that admin - OIDC mode still takes a password login from it.
    # integrations.py puts the credentials in books/.env.
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
    username = os.environ.get("SHELFMARK_USERNAME", "")
    password = os.environ.get("SHELFMARK_PASSWORD", "")
    if username and password:
        parts = urllib.parse.urlsplit(api_url)
        login = urllib.request.Request(
            f"{parts.scheme}://{parts.netloc}/api/auth/login",
            data=json.dumps({"username": username, "password": password}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with opener.open(login, timeout=timeout) as response:
            response.read()
    body = json.dumps(changes).encode("utf-8")
    request = urllib.request.Request(
        api_url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="PUT",
    )
    with opener.open(request, timeout=timeout) as response:
        payload = response.read().decode("utf-8", "replace")
    try:
        return json.loads(payload)
    except ValueError:
        return {"raw": payload}


def _describe(old: list[str], new: list[str]) -> str:
    added = [u for u in new if u not in old]
    removed = [u for u in old if u not in new]
    parts = []
    if added:
        parts.append("+" + ",".join(added))
    if removed:
        parts.append("-" + ",".join(removed))
    if not parts:
        # Same set, different order: SLUM's listing becomes the try order.
        return "reordered"
    return " ".join(parts)


def run(
    *,
    sources: list[str] | None = None,
    dry_run: bool = False,
    log=print,
) -> int:
    """Fetch SLUM, work out the target lists and (unless dry_run) apply them."""
    slum_url = os.environ.get("MIRROR_REFRESH_SLUM_URL", DEFAULT_SLUM_URL)
    api_url = os.environ.get("MIRROR_REFRESH_API", DEFAULT_API)
    config_path = os.environ.get("MIRROR_REFRESH_CONFIG", DEFAULT_CONFIG)
    user_agent = os.environ.get("MIRROR_REFRESH_USER_AGENT", DEFAULT_UA)
    include_degraded = _env_bool("MIRROR_REFRESH_INCLUDE_DEGRADED", False)
    do_verify = _env_bool("MIRROR_REFRESH_VERIFY", True)
    max_per_source = _env_int("MIRROR_REFRESH_MAX", 10)
    fetch_timeout = _env_int("MIRROR_REFRESH_TIMEOUT", 25)
    probe_timeout = _env_int("MIRROR_REFRESH_PROBE_TIMEOUT", 20)
    workers = _env_int("MIRROR_REFRESH_WORKERS", 6)

    selected = sources or [
        s.strip() for s in os.environ.get("MIRROR_REFRESH_SOURCES", "").split(",") if s.strip()
    ] or list(SOURCES)

    unknown = [s for s in selected if s not in SOURCES]
    if unknown:
        log(f"[mirrors] unknown source(s): {', '.join(unknown)}")
        return 2

    log(f"[mirrors] fetching {slum_url}")
    try:
        html = fetch_slum(slum_url, user_agent, fetch_timeout)
    except Exception as exc:  # noqa: BLE001 - never break the caller's loop
        log(f"[mirrors] ERROR: could not read SLUM: {exc!r}; leaving mirrors untouched")
        return 1

    parsed = parse_slum(html)
    if not parsed:
        log("[mirrors] ERROR: SLUM page parsed to nothing; leaving mirrors untouched")
        return 1

    current = load_current(config_path)
    changes: dict[str, list[str]] = {}

    for name in selected:
        spec = SOURCES[name]
        candidates, rejected = select_candidates(parsed, spec, include_degraded)
        for url, reason in rejected:
            log(f"[mirrors] {spec['label']}: rejected {url} ({reason})")

        if not candidates:
            log(f"[mirrors] {spec['label']}: SLUM reports nothing usable; skipping")
            continue

        old = current.get(spec["key"], [])

        if do_verify:
            alive = set(verify(candidates, user_agent, probe_timeout, workers))
            kept: list[str] = []
            unverified: list[str] = []
            for url in candidates:
                # Test before *adding*. But never drop an already-configured
                # mirror just because a probe failed: probes fail transiently
                # (observed: Errno -3 on a domain that answered minutes later),
                # and removing a working mirror is worse than keeping a quiet
                # one. Removal stays SLUM's call.
                (kept if url in alive or url in old else unverified).append(url)
            if unverified:
                log(
                    f"[mirrors] {spec['label']}: not adding (no response): "
                    f"{', '.join(unverified)}"
                )
            if not kept:
                log(f"[mirrors] {spec['label']}: nothing verified; leaving list untouched")
                continue
            candidates = kept

        target = candidates[:max_per_source]
        if target == old:
            log(f"[mirrors] {spec['label']}: up to date ({len(target)} mirrors)")
            continue
        log(f"[mirrors] {spec['label']}: {_describe(old, target)}")
        changes[spec["key"]] = target

    if not changes:
        log("[mirrors] nothing to change")
        return 0

    if dry_run:
        log(f"[mirrors] DRY RUN - would PUT {json.dumps(changes)}")
        return 0

    try:
        result = apply_changes(api_url, changes, fetch_timeout)
    except Exception as exc:  # noqa: BLE001
        log(f"[mirrors] ERROR: could not apply via {api_url}: {exc!r}")
        return 1

    if isinstance(result, dict) and result.get("success"):
        log(f"[mirrors] applied {len(changes)} list(s): {', '.join(changes)}")
        return 0
    log(f"[mirrors] ERROR: API rejected the update: {result}")
    return 1


def _state_path() -> str:
    return os.environ.get("MIRROR_REFRESH_STATE", DEFAULT_STATE)


def maybe_run(log=print) -> int | None:
    """Run at most once per interval; used by the books-glue poll loop.

    Returns the exit code when it ran, or None when it was not due yet.
    """
    if not _env_bool("MIRROR_REFRESH_ENABLED", True):
        return None

    interval = _env_int("MIRROR_REFRESH_INTERVAL", 86400)
    path = _state_path()
    last_run = 0.0
    try:
        with open(path, encoding="utf-8") as handle:
            last_run = float(json.load(handle).get("last_run", 0))
    except (OSError, ValueError, TypeError):
        last_run = 0.0

    now = time.time()
    if last_run and now - last_run < interval:
        return None

    code = run(log=log)

    # Record the attempt even on failure, so a persistent outage does not make
    # every 20s poll retry the fetch all day.
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"last_run": now, "exit_code": code}, handle)
    except OSError as exc:
        log(f"[mirrors] WARN: could not write state file: {exc}")
    return code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="print changes, apply nothing")
    parser.add_argument("--sources", help="comma-separated subset: aa,libgen,zlib,welib")
    parser.add_argument("--if-due", action="store_true", help="respect the daily interval")
    parser.add_argument(
        "--print-slum",
        action="store_true",
        help="dump what SLUM reports for the tracked cards, then exit",
    )
    args = parser.parse_args(argv)

    log = lambda msg: print(msg, flush=True)  # noqa: E731

    if args.print_slum:
        user_agent = os.environ.get("MIRROR_REFRESH_USER_AGENT", DEFAULT_UA)
        url = os.environ.get("MIRROR_REFRESH_SLUM_URL", DEFAULT_SLUM_URL)
        html = fetch_slum(url, user_agent, _env_int("MIRROR_REFRESH_TIMEOUT", 25))
        for card, entries in sorted(parse_slum(html).items()):
            print(f"{card}:")
            for link, status in entries:
                print(f"    {status:10} {link}")
        return 0

    if args.if_due:
        code = maybe_run(log=log)
        return 0 if code is None else code

    sources = [s.strip() for s in args.sources.split(",") if s.strip()] if args.sources else None
    return run(sources=sources, dry_run=args.dry_run, log=log)


if __name__ == "__main__":
    sys.exit(main())
