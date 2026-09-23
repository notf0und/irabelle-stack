# scripts/shelfmark — shims for the Shelfmark downloader

Runtime patches for the `shelfmark` (Shelfmark) container, plus one
maintenance script for it, without modifying the app image.

1. **`manual_solve_bridge.py` + `manual_solve_ui.py`** — when the automated
   DDoS-Guard bypass fails, the challenge is held open and streamed into the
   Shelfmark UI as a native dialog, where the user clicks through it.
2. **`aa_search_cache.py`** — a disk-backed cache of Anna's Archive search
   pages, so a repeated search never touches AA at all.
3. **`refresh_mirrors.py`** — a daily refresh of the shadow-library mirror lists
   from open-slum.org. Unlike the others this is *not* mounted into the
   downloader: it is run by **`books-glue`** (see `books-glue/README.md`).

The three app shims are bind-mounted into the container's `/app`, which the
image already puts on `PYTHONPATH`, so `sitecustomize.py` loads in every Python
process there.

> **Replaces the old `shelfmark-vnc` sidecar.** There is no longer a second
> container, no x11vnc, no noVNC, no X11 socket, no published port and no VNC
> password. The bypasser already drives Chrome over CDP
> (`seleniumbase.cdp_driver`), so the browser is read with
> `Page.captureScreenshot` and driven with `Input.dispatchMouseEvent` /
> `Input.insertText` on the connection that is already open.

## Why a manual prompt exists at all

Anna's Archive sits behind **DDoS-Guard**, and its "manual check" variant
(`Sorry, we could not verify your browser automatically. Complete the manual
check to continue`) is solved by no available solver — not the internal one,
not Byparr/FlareSolverr, and not [Solverr](https://github.com/unseensnick/Solverr)
(tested: it returns that page while falsely reporting "Challenge solved!"). The
normal path is automatic: a 403 switches to the internal bypasser, which runs
its own Chrome and clears the challenge by itself. The prompt is the fallback
for the case where every automated method fails.

## How the manual-solve prompt works

```
shelfmark container
├─ bypass helper (subprocess)              gunicorn web worker (Flask, patched)
│   _hold_for_manual(page)                 GET  /api/manual-solve
│   • ~4 fps screencapture ──┐             GET  /manual-solve/frame.jpg
│   • writes state.json      ├── files ──▶ POST /manual-solve/input
│   • drains input.jsonl ────┘             GET  /manual-solve.js
│   • polls _is_bypassed()                 index.html patched to load it
└─ shared scratch dir: /tmp/shelfmark/manual-solve/
```

The helper and the web worker are separate processes, so they exchange the
frame and the queued input through files rather than sockets. The hold loop is
already async and already polls `_is_bypassed` every 2 s, so each tick simply
captures a frame and drains whatever the dialog queued. No threads, no extra
ports, no additional dependencies.

`_serve_index_html` is wrapped to inject `<script src="/manual-solve.js" defer>`,
which is why the dialog appears on every SPA load. Everything is same-origin, so
it works under the app's strict CSP unchanged (`script-src 'self'`,
`connect-src 'self'`), and the dialog is built from the app's own tokens —
`--card-background`, `--border-color`, `--primary-color`, `--text-color` — and
its `.modal-overlay active` class, so it follows the light/dark theme and reads
as a native piece of Shelfmark.

Clicks are forwarded as **normalized** coordinates: the page divides the click
position by the rendered image size, and the bridge multiplies by the live CSS
viewport. That sidesteps devicePixelRatio entirely, since the capture may come
back in device pixels while CDP input is in CSS pixels.

| Variable | Default | Meaning |
|---|---|---|
| `MANUAL_SOLVE_SECONDS` | `240` | How long a failed challenge is held (bounded by the remaining search budget) |
| `MANUAL_SOLVE_ONLY` | `false` | Skip the automated methods entirely — **set true to test the manual path on demand** |
| `MANUAL_SOLVE_DIR` | `/tmp/shelfmark/manual-solve` | Scratch dir shared by the two processes |

The dialog auto-dismisses when the challenge clears; the search then continues
on that same browser session. It has a **Hide** button (which leaves a small
"Verification needed — reopen" pill) so it can never trap the page, and if the
helper dies mid-hold the state route reports it inactive once the deadline
passes, so a phantom prompt cannot outlive the process that opened it.

### Routes

| Route | Purpose |
|---|---|
| `GET /api/manual-solve` | `{active, since, expires, viewport, frame}` |
| `GET /manual-solve/frame.jpg` | Newest viewport capture (`no-store`) |
| `POST /manual-solve/input` | `{"events":[{"type":"down"\|"move"\|"up","nx","ny"} \| {"type":"text","text"}]}` |
| `GET /manual-solve.js` | The dialog; injected into `index.html` |

All but the script route go through the app's own `login_required`, so they
follow whatever auth mode Shelfmark is in (currently `AUTH_METHOD=none`).

## The search cache (`aa_search_cache.py`)

The app already has a *per-search* page cache (`_search_page_reuse`), but it is
reset when the search ends, and unlike Prowlarr / Newznab / IRC the
direct-download source has no persistent cache. So a repeat search always paid a
fresh DDoS-Guard solve.

This shim patches only `shelfmark.release_sources.direct_download._fetch_search_table`:

- **Keyed on path+query, not the full URL** — `AA_BASE_URL` rotates between
  mirrors, and keying on the host would miss the cache every time it did.
- **Only genuine answers are stored** — it reuses the app's own
  `_is_reusable_answer`, and refuses a challenge interstitial outright, so a bad
  moment can never be frozen in.
- Stored as JSON in `AA_SEARCH_CACHE_DIR`, written atomically, pruned oldest-first.

Measured: the same search served in **31.2 s** uncached and **0.2 s** cached,
with 50 identical releases and no `403` / bypass traffic on the repeat.

| Variable | Default | Meaning |
|---|---|---|
| `AA_SEARCH_CACHE` | `true` | Enable the cache |
| `AA_SEARCH_CACHE_TTL` | `21600` (6 h) | How long a cached search page stays valid |
| `AA_SEARCH_CACHE_DIR` | `/config/aa-search-cache` | Where entries live (survives restarts) |
| `AA_SEARCH_CACHE_MAX` | `100` | Entries before the oldest are pruned (~80 MB, pages are ~800 KB) |

Delete the directory to force fresh searches.

## Mirror refresh (`refresh_mirrors.py`)

Mirror domains rot. A stale entry costs a failed request per search, and a dead
*primary* mirror can look like "Anna's Archive is down" while three working
mirrors sit in the list. **`books-glue` runs this once a day**; it is
deliberately not part of the downloader, so a slow SLUM fetch can never touch a
running search.

[open-slum.org](https://open-slum.org/) (SLUM) health-checks these domains every
5 minutes and publishes **static HTML** — there is no JSON API on this instance
(every `/api/status-page/*` path 404s, so the `slum-cli` script does not work
against it), hence the parser. It requires a **browser User-Agent**: SLUM
returns 403 to `python-urllib`'s default agent.

Per source it:

1. Reads the SLUM card (`annas`, `libgen`, `zlibrary`, `other`) and keeps domains
   whose status is `up` or `protected`. **`protected` is a healthy state here** —
   it is the DDoS-Guard challenge, which the internal bypasser handles;
   `annas-archive.gl` is PROTECTED and works fine.
2. Filters to hostnames belonging to that source, which matters because SLUM's
   cards are not clean: `annas` also carries `software.annas-archive.gl` and
   Anna's Archive's download hosts (`yqrii5.org`, `wbsg8v.xyz`), and `other` is a
   grab-bag that happens to contain `welib.org`.
3. Pushes the result through Shelfmark's **own settings API**
   (`PUT /api/settings/mirrors`), which persists it and calls
   `network.init_aa(force=True)` — so it applies **live, with no restart**.

Fail-safes, because losing a working mirror is worse than keeping a stale one:

- SLUM unreachable, or parsing to nothing → nothing is changed.
- A source with no usable mirrors is **skipped, never emptied**.
- `AA_BASE_URL: auto` already fails over harmlessly, so a stale entry is cheap.

| Variable | Default | Meaning |
|---|---|---|
| `MIRROR_REFRESH_ENABLED` | `true` | Master switch (also follows `GLUE_ENABLED`) |
| `MIRROR_REFRESH_INTERVAL` | `86400` | Seconds between runs |
| `MIRROR_REFRESH_SOURCES` | `aa,libgen,zlib,welib` | Which lists to manage |
| `MIRROR_REFRESH_INCLUDE_DEGRADED` | `false` | Also use SLUM `degraded` (1 failed check in 5 min) |
| `MIRROR_REFRESH_VERIFY` | `true` | Probe a mirror before adding it (see below) |
| `MIRROR_REFRESH_MAX` | `10` | Cap per list |
| `MIRROR_REFRESH_SLUM_URL` | `https://open-slum.org/` | Source page |
| `MIRROR_REFRESH_API` | `http://shelfmark:8084/api/settings/mirrors` | Where it applies |
| `MIRROR_REFRESH_STATE` | `/state/mirror-refresh.json` | Last-run stamp (the daily throttle) |

### Testing before adding, and what removes a mirror

Two different questions, with two different answers:

- **Adding**: every candidate must answer before it goes in
  (`MIRROR_REFRESH_VERIFY`, default on). A domain that is DNS-dead, has a broken
  certificate, or refuses connections is simply not added this run.
- **Removing**: only SLUM decides. A configured mirror is **never** dropped just
  because a probe failed. Probes blip — observed live, where Z-Library domains
  failed with `Errno -3` (a temporary DNS failure) and answered minutes later —
  and deleting a working mirror is worse than keeping a quiet one. `AA_BASE_URL:
  auto` already fails over harmlessly.

A probe counts **any** HTTP answer as alive (a 403 or a DDoS-Guard challenge
means the mirror is up and doing its job); only DNS, TLS and connection failures
count as dead. Set `MIRROR_REFRESH_VERIFY=false` to skip probing and add whatever
SLUM reports.

Why this matters, concretely: `annas-archive.vg` is genuinely dead (its TLS
certificate no longer validates — `CERTIFICATE_VERIFY_FAILED`), so it fails the
probe and is not added, and SLUM had already dropped it.

### Matching the shape Shelfmark expects

Each setting is a **bare base URL** — Shelfmark appends its own path
(`/search?…` for AA, `/md5/{md5}` for Z-Library and Welib, via
`mirrors.get_zlib_url_template` / `get_welib_url_template`). So a candidate must
be scheme + host with no path, query or fragment, *and* its host must match that
source's pattern:

| Source | Host pattern |
|---|---|
| Anna's Archive | `annas-archive.<tld>` |
| LibGen | `libgen.<tld>` |
| Z-Library | `z-library.<tld>`, `1lib.<tld>`, `z-lib.<tld>`, `go-to-library.<tld>`, `library-access.<tld>` |
| Welib | `welib.org`, `*.welib.org` |

This is not cosmetic. SLUM's cards are dirty: its `annas` card carries
`software.annas-archive.gl` and AA's download hosts (`yqrii5.org`, `wbsg8v.xyz`),
and its `other` card mixes `welib.org` with `libstc.nexus`, `liber3.eth.limo`
and `library.memoryoftheworld.org`. Anything that fails is **rejected and
logged** (`rejected <url> (<reason>)`) rather than written into your config — the
Welib list would otherwise have collected three unrelated mirrors. The patterns
are anchored, so `annas-archive.gl.evil.com` and `welib.example.evil.com` are
rejected too.

**Why `yqrii5.org` and `wbsg8v.xyz` in particular are rejected:** they are Anna's
Archive **download-link hosts**, not search mirrors. Their root answers:

```
HTTP 403  Link expired or invalid. Get a new link on Anna's Archive
          (find the latest official domain on Wikipedia) to continue downloading.
```

Shelfmark never needs them configured — it discovers them dynamically from the
`get.php?md5=…&key=…` links in the search results, and calls the fast-download
API on the *configured* base URL
(`{AA_BASE_URL}/dyn/api/fast_download.json`, `direct_download.py`). Putting them
in `AA_MIRROR_URLS` would make Shelfmark request `https://yqrii5.org/search?…`,
which is precisely the 403 above.

Run it by hand:

```bash
docker exec books-glue python3 /refresh_mirrors.py --dry-run     # show the diff
docker exec books-glue python3 /refresh_mirrors.py --print-slum  # what SLUM reports now
docker exec books-glue python3 /refresh_mirrors.py               # apply now
```

The list **order follows SLUM's**, because `AA_BASE_URL: auto` tries mirrors in
order and Z-Library uses only the first entry. Since SLUM is a live uptime
monitor, expect the lists to differ day to day as mirrors flap.

## Files

| File | Process | Role |
|---|---|---|
| `sitecustomize.py` | both | Entry point: installs the `runpy` bridge, patches `_bypass`, imports the companions |
| `manual_solve_state.py` | both | Scratch paths, state JSON, input queue (stdlib only, never raises) |
| `manual_solve_bridge.py` | bypass helper | CDP capture + input forwarding during the hold |
| `manual_solve_ui.py` | web worker | Flask routes, index injection, the dialog itself |
| `aa_search_cache.py` | web worker | The AA search cache |
| `refresh_mirrors.py` | books-glue | Daily mirror refresh from open-slum.org (not mounted into `/app`) |

## Durability

| What | Lives in | Survives recreate | Survives image update |
|---|---|---|---|
| Services, volumes, env vars | `compose.yml` | yes | yes |
| Vaulted app settings (blanked AA key, 280 s search timeout) | `config/shelfmark/plugins/*.json` | yes | yes |
| Cached AA search pages | `config/shelfmark/aa-search-cache/` | yes | yes (expire by TTL) |
| The shims | bind-mounted read-only from `scripts/shelfmark/*.py` into `/app` | yes | yes, **unless the app refactors the internals they hook** |

**The shims are the only fragile part**, because they hook the app by name. If an
image update renames or refactors any of these, the matching shim silently stops
applying — the app still works, it just loses the prompt and/or the cache:

- `internal_bypasser._bypass` / `_is_bypassed` (the hold)
- `shelfmark.main._serve_index_html` (the dialog injection)
- `shelfmark.main.login_required`, `app` (the routes)
- `direct_download._fetch_search_table` (the cache)

Check after every image update:

```bash
docker logs shelfmark 2>&1 | grep shelfmark-shims
docker exec shelfmark python -c "
import runpy, shelfmark.bypass.internal_bypasser as ib, shelfmark.release_sources.direct_download as dd
print(runpy._run_module_as_main.__name__, ib._bypass.__name__, dd._fetch_search_table.__name__)"
```

Expected: a `[shelfmark-shims] sitecustomize loaded from /app/sitecustomize.py`
line, then `_run_module_as_main patched_bypass _fetch_search_table`. A
`patched_bypass` or `_fetch_search_table` that is *not* the last name means that
shim has stopped applying.

Then confirm the prompt's routes are live:

```bash
docker exec shelfmark curl -s http://127.0.0.1:8084/api/manual-solve
docker exec shelfmark curl -s http://127.0.0.1:8084/ | grep -o '/manual-solve.js'
```

## Editing the shims

They are bind-mounted as **single files**, so a running container keeps the old
inode until it is restarted. After any edit:

```bash
docker restart shelfmark
```

The scratch directory (`/tmp/shelfmark/manual-solve`) is created by the bypass
helper, which runs as the app user (`shelfmark`). If it is ever created by
`root` (e.g. by hand while debugging), the web worker cannot append to the input
queue; `/manual-solve/input` then returns `503 input queue not writable` rather
than failing a request. `rm -rf /tmp/shelfmark/manual-solve` and start a search.

## Testing the manual path on demand

Set `MANUAL_SOLVE_ONLY=true` on the `shelfmark` service and run a search:
`patched_bypass` skips the automated methods and opens the prompt immediately, so
the dialog, the frame and the input forwarding can all be exercised without
waiting for a real challenge. Set it back to `false` afterwards.

## Troubleshooting

- **No dialog when a search stalls**: check the hold actually fired —
  `docker logs shelfmark | grep "MANUAL SOLVE REQUIRED"`. If the log
  line is there but no dialog appears, the SPA is not loading
  `/manual-solve.js` (check the injection above).
- **Dialog appears but the image is black/empty**: no frame has been captured
  yet, or capture is racing a navigation. The bridge logs at debug:
  `manual-solve: frame capture failed`.
- **Clicks land in the wrong place**: the viewport is read live each tick; if
  the window is resized mid-solve, coordinates follow it. A click is mapped from
  the image's *current* rendered rect, so a layout shift between paint and click
  can offset it slightly.
- **`/manual-solve/input` returns 503**: the scratch dir is not writable by the
  app user — see "Editing the shims" above.
- **Cache never hits**: check `AA_SEARCH_CACHE` is true and that the search URL's
  path+query is identical (language filters are part of it).
- **Everything logs `installed` but nothing happens**: the `runpy` bridge is not
  active — check
  `docker exec shelfmark python -c "import runpy; print(runpy._run_module_as_main)"`.
