"""Disk-backed cache for Anna's Archive search pages.

Why this exists: a repeat search builds a byte-identical AA ``/search`` URL, and every
miss there costs a full DDoS-Guard browser solve. The app already has a per-search page
cache (``_search_page_reuse``), but it is reset when the search ends, and unlike
Prowlarr / Newznab / IRC the direct-download source has no persistent cache at all.

Only ``shelfmark.release_sources.direct_download._fetch_search_table`` is patched, and
only genuine answers are stored: ``_is_reusable_answer`` is the app's own "an answer,
not a giving-up" predicate, and a challenge interstitial is refused outright so a bad
moment can never be frozen in.

The cache key is the path+query, **not** the full URL: ``AA_BASE_URL`` rotates between
mirrors, and keying on the host would miss the cache every time it did.

Environment:
  AA_SEARCH_CACHE      enable/disable (default true)
  AA_SEARCH_CACHE_TTL  seconds a cached search page stays valid (default 21600 = 6h)
  AA_SEARCH_CACHE_DIR  where to keep it (default /config/aa-search-cache)
  AA_SEARCH_CACHE_MAX  max cached pages before the oldest are pruned (default 100)
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from importlib.abc import Loader, MetaPathFinder
from urllib.parse import urlsplit

_TARGET = "shelfmark.release_sources.direct_download"
_DEFAULT_DIR = "/config/aa-search-cache"
_DEFAULT_TTL = 21600  # 6 hours
# AA search pages are large (~800 KB each), so this cap is roughly 80 MB of disk.
_DEFAULT_MAX = 100


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


class _PatchLoader(Loader):
    """Delegates to the real loader, then applies the patch."""

    def __init__(self, inner: Loader, apply) -> None:  # noqa: ANN001
        self._inner = inner
        self._apply = apply

    def __getattr__(self, name: str):  # noqa: ANN401
        if name == "_inner":
            raise AttributeError(name)
        return getattr(self._inner, name)

    def create_module(self, spec):  # noqa: ANN001, ANN201
        create = getattr(self._inner, "create_module", None)
        return None if create is None else create(spec)

    def exec_module(self, module) -> None:  # noqa: ANN001
        self._inner.exec_module(module)
        try:
            self._apply(module)
        except Exception:  # noqa: BLE001 - a patch must never break the app
            import traceback

            traceback.print_exc()


class _PatchFinder(MetaPathFinder):
    def __init__(self, target: str, apply) -> None:  # noqa: ANN001
        self._target = target
        self._apply = apply

    def find_spec(self, fullname, path=None, target=None):  # noqa: ANN001, ANN201
        if fullname != self._target:
            return None
        for finder in list(sys.meta_path):
            if finder is self:
                continue
            find_spec = getattr(finder, "find_spec", None)
            if find_spec is None:
                continue
            try:
                spec = find_spec(fullname, path, target)
            except Exception:  # noqa: BLE001
                continue
            if spec is None or spec.loader is None:
                continue
            spec.loader = _PatchLoader(spec.loader, self._apply)
            return spec
        return None


def _cache_dir() -> str:
    return os.environ.get("AA_SEARCH_CACHE_DIR", "").strip() or _DEFAULT_DIR


def _ttl() -> int:
    return _env_int("AA_SEARCH_CACHE_TTL", _DEFAULT_TTL)


def _max_entries() -> int:
    return _env_int("AA_SEARCH_CACHE_MAX", _DEFAULT_MAX)


def _cache_key(url: str) -> str:
    """Identify a search independently of which mirror served it."""
    parts = urlsplit(url)
    return f"{parts.path}?{parts.query}"


def _path_for(key: str) -> str:
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return os.path.join(_cache_dir(), digest + ".json")


def load(url: str) -> str | None:
    key = _cache_key(url)
    path = _path_for(key)
    try:
        with open(path, encoding="utf-8") as fh:
            blob = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(blob, dict) or blob.get("key") != key:
        return None
    if time.time() - float(blob.get("ts", 0)) > _ttl():
        try:
            os.unlink(path)
        except OSError:
            pass
        return None
    html = blob.get("html")
    return html if isinstance(html, str) else None


def _prune() -> None:
    directory = _cache_dir()
    try:
        names = [n for n in os.listdir(directory) if n.endswith(".json")]
    except OSError:
        return
    limit = _max_entries()
    if len(names) <= limit:
        return
    entries = []
    for name in names:
        full = os.path.join(directory, name)
        try:
            entries.append((os.path.getmtime(full), full))
        except OSError:
            continue
    entries.sort()
    for _mtime, full in entries[: max(0, len(entries) - limit)]:
        try:
            os.unlink(full)
        except OSError:
            pass


def save(url: str, html: str) -> None:
    key = _cache_key(url)
    directory = _cache_dir()
    try:
        os.makedirs(directory, exist_ok=True)
        path = _path_for(key)
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"key": key, "ts": time.time(), "html": html}, fh)
        os.replace(tmp, path)
    except OSError:
        return
    _prune()


def _apply(dd) -> None:  # noqa: ANN001
    if getattr(dd, "_aa_search_cache_applied", False):
        return
    dd._aa_search_cache_applied = True
    if not _env_bool("AA_SEARCH_CACHE", True):
        return

    from bs4 import BeautifulSoup

    original = dd._fetch_search_table
    logger = dd.logger
    ttl = _ttl()

    def _fetch_search_table(url, selector):  # noqa: ANN001, ANN202
        html = load(url)
        if html is not None:
            logger.info(
                "AA search cache hit (%d bytes, ttl=%ds, key=%s)",
                len(html),
                ttl,
                _cache_key(url)[:120],
            )
            return html, BeautifulSoup(html, "html.parser").find("table")

        result = original(url, selector)
        cached_html = result[0]
        if (
            cached_html
            and not dd._looks_like_challenge_page(cached_html)
            and dd._is_reusable_answer(result)
        ):
            save(url, cached_html)
            logger.info(
                "AA search cached (%d bytes, ttl=%ds, key=%s)",
                len(cached_html),
                ttl,
                _cache_key(url)[:120],
            )
        return result

    dd._fetch_search_table = _fetch_search_table
    logger.info("AA search cache installed (dir=%s, ttl=%ds)", _cache_dir(), ttl)


sys.meta_path.insert(0, _PatchFinder(_TARGET, _apply))
