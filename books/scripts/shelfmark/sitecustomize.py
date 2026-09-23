"""Shelfmark shims: manual-solve prompt + Anna's Archive search cache.

Bind-mounted into the downloader's ``/app`` directory, which the image already
puts on ``PYTHONPATH``, so Python imports this in every process there (the
gunicorn worker and the bypass helper subprocess). Mounting into ``/app`` rather
than ``.../lib/python3.14/site-packages`` is deliberate: the latter would break
the moment an image update bumped Python and renamed that directory.

This file wires together three companions:

* ``manual_solve_bridge`` - streams the bypass browser to the UI over CDP and
  forwards the user's input while a human solves a challenge. It replaces the
  old ``shelfmark-vnc`` sidecar (x11vnc + noVNC in a second container); see that
  module for why no X11 or extra container is needed.
* ``manual_solve_ui`` - the Flask half: routes and the dialog the app loads.
* ``aa_search_cache`` - a disk-backed cache of Anna's Archive search pages.

Only the manual-solve hold patches the app at runtime, and it patches exactly
one function, ``_bypass``, so that a failed automated solve holds the challenge
open and polls for a human instead of reloading and racing them.
"""

from __future__ import annotations

import os
import sys
from importlib.abc import Loader, MetaPathFinder

_TARGET = "shelfmark.bypass.internal_bypasser"


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


class _PatchLoader(Loader):
    """Delegates to the real loader, then applies the patch.

    The helper subprocess is launched as ``python -m
    shelfmark.bypass.internal_bypasser``, and runpy asks the loader for
    ``get_code`` to execute the module as ``__main__``. Everything the real
    loader exposes therefore has to stay reachable, which is why this delegates
    via ``__getattr__`` instead of re-implementing the loader interface.
    """

    def __init__(self, inner: Loader) -> None:
        self._inner = inner

    def __getattr__(self, name: str):  # noqa: ANN401
        if name == "_inner":
            raise AttributeError(name)
        return getattr(self._inner, name)

    def create_module(self, spec):  # noqa: ANN001, ANN201
        create = getattr(self._inner, "create_module", None)
        return None if create is None else create(spec)

    def exec_module(self, module) -> None:
        self._inner.exec_module(module)
        try:
            _apply(module)
        except Exception:  # noqa: BLE001 - a patch must never break the app
            import traceback

            traceback.print_exc()


class _PatchFinder(MetaPathFinder):
    """Patches the bypasser module the moment it is imported."""

    def find_spec(self, fullname, path=None, target=None):  # noqa: ANN001, ANN201
        if fullname != _TARGET:
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
            spec.loader = _PatchLoader(spec.loader)
            return spec
        return None


def _apply(ib) -> None:  # noqa: ANN001
    if getattr(ib, "_manual_hold_applied", False):
        return
    ib._manual_hold_applied = True

    import manual_solve_bridge

    original_bypass = ib._bypass
    original_is_bypassed = ib._is_bypassed
    logger = ib.logger

    hold_seconds = _env_float("MANUAL_SOLVE_SECONDS", 240.0)
    manual_only = _env_bool("MANUAL_SOLVE_ONLY", False)

    async def _hold_for_manual(page, cancel_flag, reason: str) -> bool:  # noqa: ANN001
        return await manual_solve_bridge.hold_with_bridge(
            page=page,
            hold_seconds=hold_seconds,
            cancel_flag=cancel_flag,
            is_bypassed=original_is_bypassed,
            reason=reason,
            logger=logger,
        )

    async def patched_bypass(page, max_retries=None, cancel_flag=None):  # noqa: ANN001
        if manual_only:
            try:
                if await original_is_bypassed(page):
                    return True
            except Exception:  # noqa: BLE001
                pass
            return await _hold_for_manual(page, cancel_flag, "manual-only mode")

        if await original_bypass(page, max_retries=max_retries, cancel_flag=cancel_flag):
            return True
        return await _hold_for_manual(page, cancel_flag, "automated methods failed")

    ib._bypass = patched_bypass
    logger.info(
        "Manual-solve prompt installed (window=%.0fs, manual_only=%s)",
        hold_seconds,
        manual_only,
    )


def _install_runpy_bridge() -> None:
    """Route ``python -m <target>`` through a normal import.

    ``python -m`` executes the module a *second* time as ``__main__``, a separate
    module object. Patching the imported copy therefore leaves the code that
    actually runs - and its ``_bypass`` global - untouched, which is exactly why
    the first version of this shim logged "installed" and then did nothing.

    Importing instead (and calling the same entry point the ``__main__`` guard
    calls) means the patch and the running code are one and the same module.
    """
    import runpy

    original = getattr(runpy, "_run_module_as_main", None)
    if original is None:
        return

    def _run_module_as_main(mod_name, alter_argv=True):  # noqa: ANN001, ANN202
        if mod_name != _TARGET:
            return original(mod_name, alter_argv=alter_argv)
        import importlib

        module = importlib.import_module(mod_name)
        if alter_argv:
            sys.argv[0] = getattr(module, "__file__", mod_name)
        module._start_parent_watchdog()
        raise SystemExit(module._run_child_process())

    runpy._run_module_as_main = _run_module_as_main


try:
    _install_runpy_bridge()
except Exception:  # noqa: BLE001 - a patch must never break the app
    import traceback

    traceback.print_exc()

sys.meta_path.insert(0, _PatchFinder())

# Web half: registers the prompt's routes and makes the SPA load its script. In
# the bypass helper this is inert - that process never imports shelfmark.main.
try:
    import manual_solve_ui

    manual_solve_ui.install()
except Exception:  # noqa: BLE001 - a patch must never break the app
    import traceback

    traceback.print_exc()

# Companion shim: a disk-backed cache for Anna's Archive search pages. Kept in its own
# module so it stays independently reviewable, but imported here because a container can
# only have one sitecustomize.
try:
    import aa_search_cache  # noqa: F401  (installs the search cache on import)
except Exception:  # noqa: BLE001 - a patch must never break the app
    import traceback

    traceback.print_exc()

# One line per interpreter start, so `docker logs` distinguishes "the shims are not
# mounted / not on sys.path" from "mounted, but an app refactor moved the thing they
# patch". The per-patch "installed" lines further down only appear once the target
# modules are imported.
print(
    f"[shelfmark-shims] sitecustomize loaded from {__file__}",
    file=sys.stderr,
    flush=True,
)
