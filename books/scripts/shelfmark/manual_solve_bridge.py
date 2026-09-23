"""Serve the bypass browser to the Shelfmark UI while a human solves a challenge.

This replaces the old ``shelfmark-vnc`` sidecar (x11vnc + noVNC on a shared X11
socket). The bypasser already drives Chrome over CDP via seleniumbase's
``cdp_driver``, so there is no need to screen-scrape an Xvfb display from a
second container: we ask Chrome for its viewport through the connection we
already hold, and forward the user's clicks and keystrokes straight back with
``Input.dispatch*``.

The hold loop that calls this is already async and already polling
``_is_bypassed`` once every couple of seconds, so each tick just:

  1. drains any queued input events and forwards them to Chrome,
  2. captures a JPEG of the viewport and publishes it,
  3. checks whether the challenge has cleared.

Doing it inline means no threads, no sockets, no extra packages, and nothing
new listening inside the container.
"""

from __future__ import annotations

import asyncio
import base64
import json
import time
from typing import Any, Callable

import manual_solve_state as state

# ~4 fps: responsive enough to aim a click, cheap enough not to fight the
# challenge for the browser's attention.
_TICK_SECONDS = 0.25
# Matches the cadence the old hold used for _is_bypassed().
_BYPASS_POLL_SECONDS = 2.0
_FRAME_QUALITY = 70
_LEFT_BUTTON_MASK = 1
_MAX_TEXT_CHARS = 500


def _normalized_to_viewport(
    event: dict, viewport: dict
) -> tuple[float, float] | None:
    try:
        nx = float(event["nx"])
        ny = float(event["ny"])
    except (KeyError, TypeError, ValueError):
        return None
    width = max(1, int(viewport.get("w") or 1))
    height = max(1, int(viewport.get("h") or 1))
    clamped_x = min(max(nx, 0.0), 1.0)
    clamped_y = min(max(ny, 0.0), 1.0)
    return clamped_x * width, clamped_y * height


async def _dispatch_input(
    page: Any, cdp_input: Any, event: dict, viewport: dict, logger: Any
) -> None:
    """Forward one UI event to Chrome. Never let a bad event break the hold."""
    kind = event.get("type")

    if kind == "text":
        text = str(event.get("text") or "")[:_MAX_TEXT_CHARS]
        if text:
            await page.send(cdp_input.insert_text(text))
        return

    point = _normalized_to_viewport(event, viewport)
    if point is None:
        return
    x, y = point

    if kind == "down":
        await page.send(cdp_input.dispatch_mouse_event(type_="mouseMoved", x=x, y=y))
        await page.send(
            cdp_input.dispatch_mouse_event(
                type_="mousePressed",
                x=x,
                y=y,
                button=cdp_input.MouseButton.LEFT,
                buttons=_LEFT_BUTTON_MASK,
                click_count=1,
            )
        )
    elif kind == "move":
        await page.send(
            cdp_input.dispatch_mouse_event(
                type_="mouseMoved",
                x=x,
                y=y,
                button=cdp_input.MouseButton.LEFT,
                buttons=_LEFT_BUTTON_MASK,
            )
        )
    elif kind == "up":
        await page.send(
            cdp_input.dispatch_mouse_event(
                type_="mouseReleased",
                x=x,
                y=y,
                button=cdp_input.MouseButton.LEFT,
                buttons=0,
                click_count=1,
            )
        )
    else:
        logger.debug("manual-solve: ignoring unknown input event %r", kind)


async def _viewport_size(page: Any, fallback: dict) -> dict:
    """Read the CSS viewport, so normalized click coordinates stay correct.

    Normalized (0..1) coordinates are what the browser sends, and multiplying
    them by the live viewport here sidesteps devicePixelRatio entirely: the
    screenshot may come back in device pixels, but the click never has to know.
    """
    try:
        raw = await page.evaluate(
            "JSON.stringify({w: window.innerWidth, h: window.innerHeight})"
        )
        parsed = json.loads(raw) if isinstance(raw, str) else raw
        if isinstance(parsed, dict) and parsed.get("w") and parsed.get("h"):
            return {"w": int(parsed["w"]), "h": int(parsed["h"])}
    except Exception:  # noqa: BLE001 - page may be mid-navigation
        pass
    return fallback


async def hold_with_bridge(
    *,
    page: Any,
    hold_seconds: float,
    cancel_flag: Any,
    is_bypassed: Callable[[Any], Any],
    reason: str,
    logger: Any,
) -> bool:
    """Publish the live viewport and wait for a human to solve the challenge.

    Returns True as soon as the page looks bypassed (the search then continues
    on that same browser session), False if the window expires or the caller
    cancels. Always leaves the shared state inactive.
    """
    from mycdp import input_ as cdp_input  # imported here: web worker never loads it
    from mycdp import page as cdp_page

    state.ensure_dir()
    state.clear_state()  # drop anything left by a previous hold

    deadline = time.monotonic() + hold_seconds
    started_at = time.time()
    expires_at = started_at + hold_seconds
    last_bypass_check = 0.0
    viewport = {"w": 1280, "h": 720}
    frame_ready = False

    logger.warning(
        "MANUAL SOLVE REQUIRED (%s): a prompt is open in the Shelfmark UI "
        "for up to %.0fs.",
        reason,
        hold_seconds,
    )

    try:
        while time.monotonic() < deadline:
            if cancel_flag is not None and cancel_flag.is_set():
                logger.info("Manual solve hold cancelled by the caller")
                return False

            viewport = await _viewport_size(page, viewport)

            for event in state.drain_input():
                try:
                    await _dispatch_input(page, cdp_input, event, viewport, logger)
                except Exception:  # noqa: BLE001 - one bad event must not end the hold
                    logger.debug("manual-solve: input dispatch failed", exc_info=True)

            try:
                encoded = await page.send(
                    cdp_page.capture_screenshot(
                        format_="jpeg",
                        quality=_FRAME_QUALITY,
                        optimize_for_speed=True,
                    )
                )
                if encoded:
                    state.write_frame(base64.b64decode(encoded))
                    frame_ready = True
            except Exception:  # noqa: BLE001 - capture can race a navigation
                logger.debug("manual-solve: frame capture failed", exc_info=True)

            state.write_state(
                {
                    "active": True,
                    "reason": reason,
                    "since": started_at,
                    "expires": expires_at,
                    "viewport": viewport,
                    "frame": frame_ready,
                }
            )

            now = time.monotonic()
            if now - last_bypass_check >= _BYPASS_POLL_SECONDS:
                last_bypass_check = now
                try:
                    if await is_bypassed(page):
                        logger.info("Manual solve detected - continuing")
                        return True
                except Exception:  # noqa: BLE001 - page may be mid-navigation
                    pass

            await asyncio.sleep(_TICK_SECONDS)

        logger.warning(
            "Manual solve window (%.0fs) expired without a solve", hold_seconds
        )
        return False
    finally:
        state.clear_state()
