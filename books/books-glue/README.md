# books-glue

Small glue service that keeps the book pipeline in sync after Calibre-Web-Automated
(CWA) finishes processing a downloaded book.

## The problem it solves

The download pipeline is:

```
Shelfmark downloader  -->  CWA ingest dir  -->  CWA processes (convert/fix/import)
        -->  Calibre library  -->  CWA web UI  +  Kavita
```

1. **Downloader links break** — Shelfmark records the book at its ingest path
   (`/cwa-book-ingest/...`), but CWA *moves* the finished file into the Calibre
   library, so clicking the completed download returns "File not found".
2. **Kavita is slow** — Kavita's folder watcher + daily 4am scan are delayed by
   minutes/hours, so new books don't appear until you manually scan.

(Originally the Calibre desktop GUI was also restarted to pick up new books,
but that's no longer needed: the CWA web UI at `calibre-web-automated.$TLD`
reads the library live and shows new books immediately. The restart remains
available as an opt-in via `CALIBRE_AUTO_RESTART=true`.)

## How it works

`books-glue` polls the Calibre library folder every 20 s and:

1. For every downloader history row whose ingest file has been moved away — and
   for any row already relocated whose link no longer matches its title — it
   matches the book against the library and updates
   `download_history.download_path` to the new location (`/calibre-library/...`),
   which the downloader now serves from its read-only library mount.

   Matching is scored on **title tokens**, tokenised Unicode-aware so non-Latin
   titles work. Author only breaks ties, and the row's own recorded format ranks
   *above* author: library author names are transliterated inconsistently
   ("Виктор Олегович Пелевин" vs "Victor Pelevin"), and an author-first ordering
   once linked a Pelevin title to the wrong book (KGBT+ instead of the intended
   one). A row whose existing library path no longer matches its title is
   re-matched, so a bad link self-corrects instead of silently serving the wrong
   download.
2. ~60 s after the last new file appears (so CWA has finished writing the whole
   book folder), it calls Kavita's `POST /api/Library/scan-all` API so the book
   appears in Kavita within seconds (cooldown: at most once per 5 minutes).
3. Optional: if `CALIBRE_AUTO_RESTART=true`, it restarts the `calibre` container
   through the Docker socket so the desktop GUI reloads the library.
4. Once a day, it refreshes the shadow-library mirror lists in Shelfmark from
   [open-slum.org](https://open-slum.org/) (a mirror that has died otherwise
   costs a failed request per search). It reads the page, keeps the domains SLUM
   reports as up or protected, and pushes them through Shelfmark's own settings
   API so they apply live. This is self-throttled via
   `/state/mirror-refresh.json`, so it is a cheap no-op on every other poll. See
   `../scripts/shelfmark/refresh_mirrors.py` and its README for the details,
   fail-safes and the `MIRROR_REFRESH_*` knobs.

On first start it only records a snapshot of the existing library (no actions),
so old books don't trigger a scan/restart storm.

## Configuration

Every action can be toggled from `.env` — no compose edits needed.
`GLUE_ENABLED=false` makes the glue idle (equivalent to commenting the service
out, but re-enableable with a single env change).

| Variable | Default | Meaning |
|---|---|---|
| `GLUE_ENABLED` | `true` | master switch; `false` = glue does nothing |
| `GLUE_FIX_DOWNLOADER` | `true` | fix downloader links after CWA moves the file |
| `GLUE_SCAN_KAVITA` | `true` | trigger Kavita scan-all on new books |
| `CALIBRE_AUTO_RESTART` | `false` | also restart the Calibre GUI on new books (requires the Docker socket mounted, see `compose.yml`) |
| `MIRROR_REFRESH_ENABLED` | `true` | daily SLUM mirror refresh (interval/sources/verification are `MIRROR_REFRESH_*` in `../scripts/shelfmark/README.md`) |
| `POLL_INTERVAL` | `20` | seconds between polls |
| `ACTION_DEBOUNCE` | `60` | seconds to wait after the last new file before acting |
| `ACTION_COOLDOWN` | `300` | minimum seconds between Kavita scans / Calibre restarts |
| `KAVITA_API_KEY` | – | Kavita user API key (Settings → your user → API Key); used with the `x-api-key` header |
| `MATCH_THRESHOLD` | `0.6` | minimum token-overlap score to consider a library file a match |

Example — keep the glue running but stop the Kavita scans:

```dotenv
GLUE_SCAN_KAVITA=false
```

The remaining variables (`LIBRARY_DIR`, `INGEST_DIR`, `DOWNLOADER_DB`,
`DOWNLOADER_LIBRARY_PREFIX`, `DOWNLOADER_INGEST_PREFIX`, `KAVITA_URL`,
`STATE_FILE`) match the mounts in `compose.yml` and normally don't need changing.

## Notes / caveats

- `glue.py` is bind-mounted as a **single file**, so editing it on the host does
  not reach a running container (the mount keeps the old inode). Recreate it
  after an edit: `docker compose up -d --force-recreate books-glue`. The same
  applies to the shims in `../scripts/shelfmark/`.
- The CWA web UI (`calibre-web-automated.$TLD`) refreshes itself and is the
  recommended way to browse the library — it needs no glue and no restarts.
- If you enable `CALIBRE_AUTO_RESTART`, restarting the Calibre container
  briefly disconnects the `calibre.$TLD` GUI tab (~30–60 s) whenever a new book
  lands, and editing in the GUI at that moment can be interrupted.
- The time between "download finished" and "book appears" is still dominated by
  CWA processing (conversion to EPUB for non-EPUB downloads). The glue acts as
  soon as the finished book lands in the library.
- `KAVITA_API_KEY` lives in `.env`; regenerate/update it there if it ever
  changes in Kavita.
- The downloader needs the library mounted at `/calibre-library` (read-only) to
  serve relocated files — already added to `compose.yml`.
