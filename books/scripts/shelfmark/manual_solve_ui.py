"""In-app manual-solve prompt for Shelfmark.

Replaces the ``shelfmark-vnc`` sidecar's browser-facing half. The bypass helper
publishes the live viewport (see ``manual_solve_bridge``); this module patches
the Flask app so the UI can show it as a native dialog:

  GET  /api/manual-solve        is a solve pending, and until when
  GET  /manual-solve/frame.jpg  the newest viewport capture
  POST /manual-solve/input      forward a click / drag / text entry
  GET  /manual-solve.js         the dialog itself

``_serve_index_html`` is wrapped to load that script, so it appears on every SPA
load including client-side navigations. Everything is same-origin, which is what
lets it work under the app's strict CSP (``script-src 'self'``,
``connect-src 'self'``) with no policy changes: the dialog is styled from the
app's own CSS custom properties and reuses its ``.modal-overlay`` class, so it
reads as a native piece of Shelfmark in both light and dark themes.

The module is imported by ``sitecustomize.py`` in every interpreter in the
container; only the gunicorn worker ever imports ``shelfmark.main``, so the
meta-path finder below simply never fires in the bypass helper.
"""

from __future__ import annotations

import logging
import sys
import time
from importlib.abc import Loader, MetaPathFinder

import manual_solve_state as state

logger = logging.getLogger(__name__)

_TARGET = "shelfmark.main"
_SCRIPT_TAG = '<script src="/manual-solve.js" defer></script>'
# If the helper died mid-hold, its state file still says "active". The deadline
# it wrote is what hands control back: past it (plus a little slack) we report
# inactive, so a phantom prompt cannot outlive the process that opened it.
_STALE_GRACE_SECONDS = 5.0


class _PatchLoader(Loader):
    """Delegates to the real loader, then installs the routes.

    ``shelfmark.main`` is imported by gunicorn as ``shelfmark.main:app``; the
    module body must finish before ``app`` and ``_serve_index_html`` exist, so
    the patch runs after ``exec_module`` returns.
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
            _install(module)
        except Exception:  # noqa: BLE001 - a UI patch must never break the app
            import traceback

            traceback.print_exc()


class _PatchFinder(MetaPathFinder):
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


def _install(main) -> None:  # noqa: ANN001
    if getattr(main, "_manual_solve_ui_installed", False):
        return
    main._manual_solve_ui_installed = True

    from flask import Response, jsonify, request

    app = getattr(main, "app", None)
    if app is None:
        logger.warning("manual-solve: no Flask app on shelfmark.main")
        return

    login_required = getattr(main, "login_required", None)

    def guard(view):  # noqa: ANN001, ANN202
        return login_required(view) if callable(login_required) else view

    @guard
    def manual_solve_state_route():  # noqa: ANN202
        data = state.read_state()
        if data.get("active"):
            expires = data.get("expires") or 0
            if expires and expires < time.time() - _STALE_GRACE_SECONDS:
                data = dict(state.INACTIVE)
        return jsonify(data)

    @guard
    def manual_solve_frame_route():  # noqa: ANN202
        try:
            jpeg = state.FRAME_FILE.read_bytes()
        except OSError:
            return Response(status=404)
        if not jpeg:
            return Response(status=404)
        response = Response(jpeg, mimetype="image/jpeg")
        response.headers["Cache-Control"] = "no-store, max-age=0"
        response.headers["Pragma"] = "no-cache"
        return response

    @guard
    def manual_solve_input_route():  # noqa: ANN202
        payload = request.get_json(silent=True) or {}
        events = payload.get("events")
        if not isinstance(events, list):
            return jsonify({"ok": False, "error": "events must be a list"}), 400
        # Bound the batch: a hostile caller cannot queue unbounded work for the
        # hold loop, and every field is re-validated there before reaching CDP.
        clean = [event for event in events[:64] if isinstance(event, dict)]
        if not clean:
            return jsonify({"ok": True, "queued": 0})
        queued = state.append_input(clean)
        if queued != len(clean):
            # Almost always a permissions problem on the scratch dir. Report it
            # instead of raising, so a broken prompt never 500s a request.
            return jsonify({"ok": False, "error": "input queue not writable"}), 503
        return jsonify({"ok": True, "queued": queued})

    def manual_solve_script_route():  # noqa: ANN202
        return Response(_CLIENT_JS, mimetype="application/javascript")

    app.add_url_rule("/api/manual-solve", "manual_solve_state", manual_solve_state_route)
    app.add_url_rule("/manual-solve/frame.jpg", "manual_solve_frame", manual_solve_frame_route)
    app.add_url_rule(
        "/manual-solve/input",
        "manual_solve_input",
        manual_solve_input_route,
        methods=["POST"],
    )
    app.add_url_rule("/manual-solve.js", "manual_solve_script", manual_solve_script_route)

    _wrap_index(main)
    logger.info("manual-solve: in-app prompt installed")


def _wrap_index(main) -> None:  # noqa: ANN001
    """Load the dialog script from the served index.html.

    ``index()`` and the SPA catch-all both look ``_serve_index_html`` up as a
    module global at call time, so rebinding the name is enough.
    """
    original = getattr(main, "_serve_index_html", None)
    if original is None or getattr(original, "_manual_solve_wrapped", False):
        return

    def patched():  # noqa: ANN202
        response = original()
        try:
            html = response.get_data(as_text=True)
            if _SCRIPT_TAG not in html:
                if "</body>" in html:
                    html = html.replace("</body>", _SCRIPT_TAG + "</body>", 1)
                else:
                    html = html + _SCRIPT_TAG
                response.set_data(html)
        except (AttributeError, RuntimeError, UnicodeDecodeError):
            logger.debug("manual-solve: could not inject index.html", exc_info=True)
        return response

    patched._manual_solve_wrapped = True  # noqa: SLF001
    main._serve_index_html = patched


install = lambda: sys.meta_path.insert(0, _PatchFinder())  # noqa: E731


_CLIENT_JS = r"""
(function () {
  "use strict";
  if (window.__shelfmarkManualSolveLoaded) { return; }
  window.__shelfmarkManualSolveLoaded = true;

  var API = "/api/manual-solve";
  var FRAME = "/manual-solve/frame.jpg";
  var INPUT = "/manual-solve/input";
  var POLL_MS = 1500;
  var FRAME_MS = 400;
  var DRAG_THROTTLE_MS = 60;

  var overlay = null;
  var pill = null;
  var img = null;
  var countEl = null;
  var noteEl = null;
  var textEl = null;
  var frameTimer = null;
  var expiresAt = 0;
  var lastSince = 0;
  var hidden = false;
  var dragging = false;
  var lastMoveAt = 0;

  function addStyles() {
    if (document.getElementById("smsolve-css")) { return; }
    var el = document.createElement("style");
    el.id = "smsolve-css";
    el.textContent = [
      ".smsolve-overlay{z-index:9999}",
      ".smsolve-card{background:var(--card-background);color:var(--text-color);",
      "border:1px solid var(--border-color);border-radius:14px;",
      "box-shadow:0 24px 60px rgba(0,0,0,.45);display:flex;flex-direction:column;",
      "width:min(1080px,96vw);max-height:92vh;overflow:hidden;font-family:inherit}",
      ".smsolve-head{display:flex;align-items:center;gap:.6rem;",
      "padding:.85rem 1.1rem;border-bottom:1px solid var(--border-color);",
      "background:var(--bg-soft)}",
      ".smsolve-title{margin:0;font-size:1rem;font-weight:600;",
      "color:var(--heading-color);flex:1}",
      ".smsolve-dot{width:.6rem;height:.6rem;border-radius:50%;flex:0 0 auto;",
      "background:var(--primary-color);box-shadow:0 0 0 3px var(--hover-action);",
      "animation:smsolve-pulse 1.6s ease-in-out infinite}",
      "@keyframes smsolve-pulse{0%,100%{opacity:1}50%{opacity:.3}}",
      ".smsolve-count{font-size:.78rem;opacity:.7;font-variant-numeric:tabular-nums}",
      ".smsolve-body{padding:1rem 1.1rem;overflow:auto;display:flex;",
      "flex-direction:column;gap:.75rem}",
      ".smsolve-lead{margin:0;font-size:.875rem;line-height:1.45;opacity:.85}",
      ".smsolve-shot{background:#111;border:1px solid var(--border-color);",
      "border-radius:10px;overflow:hidden;display:flex;justify-content:center;",
      "align-items:center;min-height:200px}",
      ".smsolve-shot img{max-width:100%;max-height:58vh;display:block;",
      "cursor:crosshair;user-select:none;-webkit-user-drag:none}",
      ".smsolve-note{margin:0;font-size:.78rem;opacity:.65;min-height:1em}",
      ".smsolve-row{display:flex;gap:.5rem;align-items:center}",
      ".smsolve-input{flex:1;background:var(--input-background);color:var(--text-color);",
      "border:1px solid var(--border-color);border-radius:8px;padding:.5rem .7rem;",
      "font:inherit;font-size:.82rem}",
      ".smsolve-btn{font:inherit;font-size:.8rem;font-weight:600;border-radius:8px;",
      "padding:.5rem .85rem;cursor:pointer;border:1px solid transparent;",
      "background:var(--primary-color);color:#fff}",
      ".smsolve-btn.ghost{background:transparent;color:var(--text-color);",
      "border-color:var(--border-color)}",
      ".smsolve-btn:hover{filter:brightness(1.06)}",
      ".smsolve-pill{position:fixed;right:1.25rem;bottom:1.25rem;z-index:9999;",
      "display:flex;align-items:center;gap:.5rem;font:inherit;font-size:.82rem;",
      "font-weight:600;padding:.6rem .9rem;border-radius:999px;cursor:pointer;",
      "border:1px solid var(--border-color);background:var(--card-background);",
      "color:var(--text-color);box-shadow:0 10px 30px rgba(0,0,0,.35)}",
      ".smsolve-pill span{width:.5rem;height:.5rem;border-radius:50%;",
      "background:var(--primary-color)}"
    ].join("");
    document.head.appendChild(el);
  }

  function send(events) {
    if (!events || !events.length) { return; }
    try {
      fetch(INPUT, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ events: events })
      }).catch(function () {});
    } catch (err) { /* never let telemetry break the page */ }
  }

  function point(ev) {
    if (!img) { return null; }
    var rect = img.getBoundingClientRect();
    if (!rect.width || !rect.height) { return null; }
    return {
      nx: Math.min(Math.max((ev.clientX - rect.left) / rect.width, 0), 1),
      ny: Math.min(Math.max((ev.clientY - rect.top) / rect.height, 0), 1)
    };
  }

  function refreshFrame() {
    if (!img) { return; }
    if (!img.complete) { return; }
    var url = FRAME + "?t=" + Date.now();
    if (img.getAttribute("src") === url) { return; }
    img.setAttribute("src", url);
    if (img.naturalWidth > 0 && noteEl) { noteEl.textContent = ""; }
    else if (noteEl) { noteEl.textContent = "Waiting for the browser to appear..."; }
    if (countEl && expiresAt) {
      var left = Math.max(0, Math.ceil(expiresAt - Date.now() / 1000));
      countEl.textContent = left + "s left";
    }
  }

  function showPill() {
    if (pill) { return; }
    addStyles();
    pill = document.createElement("button");
    pill.type = "button";
    pill.className = "smsolve-pill";
    pill.innerHTML = "<span></span>Verification needed - reopen";
    pill.addEventListener("click", function () { setHidden(false); });
    document.body.appendChild(pill);
  }

  function setHidden(value) {
    hidden = value;
    if (overlay) { overlay.style.display = value ? "none" : ""; }
    if (value) { showPill(); }
    else if (pill) { pill.remove(); pill = null; }
  }

  function build() {
    if (overlay) { return; }
    addStyles();
    overlay = document.createElement("div");
    overlay.className = "modal-overlay active smsolve-overlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", "Verification required");
    overlay.innerHTML = [
      "<div class=\"smsolve-card\">",
      "<div class=\"smsolve-head\">",
      "<span class=\"smsolve-dot\"></span>",
      "<h2 class=\"smsolve-title\">Verification required</h2>",
      "<span class=\"smsolve-count\"></span>",
      "<button type=\"button\" class=\"smsolve-btn ghost smsolve-hide\">Hide</button>",
      "</div>",
      "<div class=\"smsolve-body\">",
      "<p class=\"smsolve-lead\">Anna's Archive wants a human check before this download",
      " can continue. Solve it in the window below - the search resumes on its own.</p>",
      "<div class=\"smsolve-shot\"><img alt=\"Verification challenge\" /></div>",
      "<p class=\"smsolve-note\">Waiting for the browser to appear...</p>",
      "<div class=\"smsolve-row\">",
      "<input class=\"smsolve-input\" type=\"text\" autocomplete=\"off\"",
      " placeholder=\"If the challenge asks for text: click its field above, then type here\" />",
      "<button type=\"button\" class=\"smsolve-btn smsolve-textbtn\">Send</button>",
      "</div>",
      "</div>",
      "</div>"
    ].join("");
    document.body.appendChild(overlay);

    img = overlay.querySelector("img");
    countEl = overlay.querySelector(".smsolve-count");
    noteEl = overlay.querySelector(".smsolve-note");
    textEl = overlay.querySelector(".smsolve-input");

    overlay.querySelector(".smsolve-hide").addEventListener("click", function () {
      setHidden(true);
    });

    var submitText = function () {
      if (!textEl) { return; }
      var value = textEl.value;
      if (!value) { return; }
      send([{ type: "text", text: value }]);
      textEl.value = "";
    };
    overlay.querySelector(".smsolve-textbtn").addEventListener("click", submitText);
    textEl.addEventListener("keydown", function (ev) {
      if (ev.key === "Enter") { ev.preventDefault(); submitText(); }
    });

    img.addEventListener("mousedown", function (ev) {
      ev.preventDefault();
      var p = point(ev);
      if (!p) { return; }
      dragging = true;
      send([{ type: "down", nx: p.nx, ny: p.ny }]);
    });
    img.addEventListener("mousemove", function (ev) {
      if (!dragging) { return; }
      var now = Date.now();
      if (now - lastMoveAt < DRAG_THROTTLE_MS) { return; }
      lastMoveAt = now;
      var p = point(ev);
      if (!p) { return; }
      send([{ type: "move", nx: p.nx, ny: p.ny }]);
    });
    var endDrag = function (ev) {
      if (!dragging) { return; }
      dragging = false;
      var p = point(ev);
      if (!p) { return; }
      send([{ type: "up", nx: p.nx, ny: p.ny }]);
    };
    img.addEventListener("mouseup", endDrag);
    img.addEventListener("mouseleave", endDrag);
    img.addEventListener("contextmenu", function (ev) { ev.preventDefault(); });

    refreshFrame();
    frameTimer = setInterval(refreshFrame, FRAME_MS);
  }

  function teardown() {
    if (frameTimer) { clearInterval(frameTimer); frameTimer = null; }
    if (overlay) { overlay.remove(); overlay = null; }
    if (pill) { pill.remove(); pill = null; }
    img = null;
    countEl = null;
    noteEl = null;
    textEl = null;
    dragging = false;
    hidden = false;
    expiresAt = 0;
  }

  function poll() {
    fetch(API, { credentials: "same-origin", cache: "no-store" })
      .then(function (response) { return response.ok ? response.json() : null; })
      .then(function (data) {
        if (!data || !data.active) { teardown(); return; }
        var since = data.since || 0;
        if (since !== lastSince) { lastSince = since; hidden = false; }
        expiresAt = data.expires || 0;
        build();
        if (overlay) { overlay.style.display = hidden ? "none" : ""; }
        if (hidden) { showPill(); }
      })
      .catch(function () { /* keep the last known state on a blip */ });
  }

  poll();
  setInterval(poll, POLL_MS);
})();
"""
