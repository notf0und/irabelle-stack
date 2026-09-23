"""Shared state and input queue for the in-app manual-solve prompt.

The Shelfmark bypass helper runs as a *separate process* from the gunicorn web
worker that serves the UI, so the two halves of the manual-solve prompt talk
through files:

  state.json   the helper writes what the browser should show (active, deadline,
               viewport), and the web route hands it to the page.
  frame.jpg    the helper's latest JPEG of the bypass browser's viewport.
  input.jsonl  the web route appends the user's clicks/keys, and the helper's
               hold loop drains and forwards them to Chrome over CDP.

Everything here is stdlib-only and import-safe in both processes: the web
worker imports this module too, so it must never pull in the bypasser or CDP.

Every write is best-effort and never raises. This is a prompt bolted onto
someone else's search path: if the scratch directory is missing or not writable
by the current user (the worker runs as ``shelfmark``, the helper inherits it),
the right outcome is a prompt that fails to appear - not a 500 in the middle of
a download, and certainly not a hold that throws out of ``_bypass``.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

# The downloader's entrypoint already uses /tmp/shelfmark as its runtime tmp
# dir, so both processes agree on a writable, same-container location.
DIR = Path(os.environ.get("MANUAL_SOLVE_DIR", "/tmp/shelfmark/manual-solve"))

STATE_FILE = DIR / "state.json"
FRAME_FILE = DIR / "frame.jpg"
INPUT_FILE = DIR / "input.jsonl"

INACTIVE: dict = {"active": False}


def ensure_dir() -> bool:
    """Create the scratch directory, reporting whether it is usable."""
    try:
        DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    return True


def _atomic_write(path: Path, data: bytes) -> bool:
    """Write via a temp file + rename so a reader never sees a torn file."""
    if not ensure_dir():
        return False
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_bytes(data)
        os.replace(tmp, path)
    except OSError:
        return False
    return True


def read_state() -> dict:
    """Return the current state, or an inactive one if it is missing/corrupt."""
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return dict(INACTIVE)
    return data if isinstance(data, dict) else dict(INACTIVE)


def write_state(state: dict) -> bool:
    state = dict(state)
    state["updated"] = time.time()
    return _atomic_write(STATE_FILE, json.dumps(state).encode("utf-8"))


def write_frame(jpeg: bytes) -> bool:
    """Publish the newest viewport capture for the web route to serve."""
    return _atomic_write(FRAME_FILE, jpeg)


def clear_state() -> None:
    """Mark the prompt inactive and drop the frame so nothing goes stale.

    Called on startup as well as on every exit path, so a helper that was killed
    mid-hold cannot leave a phantom prompt on screen. The input queue is emptied
    too: a click that arrived just as the window closed must not be replayed
    against whatever page the next hold is looking at.
    """
    write_state(dict(INACTIVE))
    for path in (FRAME_FILE, INPUT_FILE):
        try:
            path.unlink()
        except OSError:
            pass


def append_input(events: list[dict]) -> int:
    """Queue input events for the hold loop; returns how many were written."""
    if not events:
        return 0
    if not ensure_dir():
        return 0
    try:
        with INPUT_FILE.open("a", encoding="utf-8") as handle:
            for event in events:
                handle.write(json.dumps(event, separators=(",", ":")) + "\n")
    except OSError:
        return 0
    return len(events)


def drain_input() -> list[dict]:
    """Take all queued input events, leaving the queue empty."""
    try:
        raw = INPUT_FILE.read_text(encoding="utf-8")
    except OSError:
        return []

    if not raw.strip():
        return []

    # Truncate first: if parsing throws below, we would rather drop a malformed
    # event than replay stale clicks against a page that has moved on.
    try:
        INPUT_FILE.write_text("", encoding="utf-8")
    except OSError:
        return []

    events: list[dict] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            events.append(parsed)
    return events
