# dsh — the DeepSeek Harness at `dsh.<TLD>`

Open `https://dsh.smart` from your LAN or your phone and the harness is just
there: no SSH, no port-forwarding, no `npx` in a terminal. Behind the authentik
login you already use for everything else (or with no login at all, if single
sign-on was opted out of — see the root README), and with the [dsh-mobile][]
plugin installed so a phone gets a proper shell.

```
phone / laptop
      │  https://dsh.smart   (Pi-hole wildcard *.$TLD → this host)
      ▼
traefik :443 ── TLS (dsh.$TLD cert, cert-watcher.sh) ── authentik forward auth
      │  http://host.docker.internal:3080   (= 172.17.0.1, the Docker gateway)
      ▼
dsh-web-bridge.mjs   (host process, ~/.config/systemd/user/dsh-web.service)
      │  starts dsh on demand, replays its launch token, fixes its cookie
      │  http://127.0.0.1:3080
      ▼
dsh web   (loopback only — it refuses to bind anything else)
```

## Why this is not a container

`dsh web` deliberately refuses `--host 0.0.0.0` — the GUI is remote code
execution — so it only ever listens on `127.0.0.1`. Traefik lives in a
container and cannot reach the host's loopback, so `dsh-web-bridge.mjs` runs on
the host, listens on the Docker gateway, and forwards. That is also what makes
the agent run *as you, on this host*, with your real checkouts and tools,
rather than in a container with a mounted workspace.

So `dsh` is the one directory here **without a `compose.yml`**: it is not a
Dockhand stack. Installing it is **opt-in** — `setup.sh` asks once and keeps the
answer in `host.env` as `DSH_INSTALL` (`--dsh` / `--no-dsh` answer without being
asked) — and `dsh/install.sh` owns everything below. `update.sh` refreshes an
install that exists, but never creates one.

## What `dsh/install.sh` does

Idempotent, safe to re-run:

1. creates `dsh/.env` from `dsh/.env.example`, taking the TLD from the root
   `.env` (and appending any key a newer template gained);
2. checks Node.js (20+; 22+ recommended) and **installs npm when it is
   missing** — first through the distro's package manager, then by fetching
   npm's own tarball — since Debian/Ubuntu ship `nodejs` and `npm` separately
   and npx comes with npm. If `pnpm` is missing it uses a temporary
   `npx pnpm` shim for the plugin install;
3. bootstraps the DSH profile (`~/.dsh/profiles/web`) and seeds the `npx`
   cache the bridge reads;
4. clones/updates [dsh-mobile][] into `dsh/.dsh-mobile` and installs it into
   the profile;
5. renders `~/.config/systemd/user/dsh-web.service` and (re)starts it;
6. enables lingering, so the service survives logging out of SSH;
7. renders `traefik/config/certificates/dsh.yml` (the route the file provider
   watches) and asks `cert-watcher.sh` for the certificate.

The authentik half — a forward-auth provider for `dsh.$TLD` — is a blueprint
entry in `authentik/config/authentik/blueprints/irabelle.yaml`, applied by the
authentik worker on start. Nothing in `dsh/` needs to touch the UI.

```sh
./setup.sh                 # asks whether to install it (once; answer in host.env)
./setup.sh --dsh           # install it without the question
./dsh/setup.sh             # just this stack's hook — asks the same question
./dsh/install.sh           # install/refresh directly, after editing dsh/.env
./dsh/install.sh --status  # what is installed, changing nothing
./dsh/uninstall.sh         # remove it (--purge also deletes ~/.dsh and dsh/.env)
```

`dsh/setup.sh` is the hook `./setup.sh` sources (see
[Adding a stack](../ADDING-A-STACK.md)); `dsh/install.sh` is safe to run on its
own and `dsh/uninstall.sh` is its inverse — it removes the unit, the route, the
certificate and the plugin, and leaves `~/.dsh` alone unless you pass
`--purge`.

### Behind a hostname, not loopback

Two DSH behaviours assume the browser is on `localhost`, and both are handled
in the bridge rather than by asking you to use an SSH tunnel:

* **Settings → Models** used to fail with *"settings are unavailable in this
  browser"*. The settings client picks its persistence with
  `ctx.remote.$host.isLoopback ? "host" : "memory"`, and `isLoopback` comes
  from the address bar, so any `https://dsh.<TLD>` origin is born unusable.
  The bridge serves that one bundle with the gate forced open (the Host-side
  settings API has no such gate, and the request still crosses authentik, the
  trusted-Host fence and dsh's signed cookie).
* **Plugins that mutate through their own routes** (dshmarket's update button,
  for one) refuse a request whose `Host` is not a loopback authority, and
  compare `Origin` against it. The bridge decides trust itself — Host must be
  the public name, Origin must match, cross-site is refused — then forwards
  with the loopback authority and without `Origin`, which is what those
  plugins check. Without the bridge-side check this would be a CSRF hole,
  because their routes carry no cookie of their own.

Both are visible in `dsh-web-bridge.mjs` (`rejectReason`, `upstreamHeaders`,
`serveSettingsBundle`). If a future dsh release changes either assumption, the
bridge logs *"did not match the loopback persistence gate — passing it through
unpatched"* and the page simply behaves as upstream intends.

## Configuration

Everything is `KEY=value` in `dsh/.env` (`dsh/.env.example` documents each
key); re-run `./dsh/install.sh` after a change.

| Variable | Default | Meaning |
|---|---|---|
| `PUBLIC_HOST` | `dsh.<TLD>` | passed to `dsh web --trusted-host`; what Traefik matches |
| `LISTEN_HOST` / `LISTEN_PORT` | `172.17.0.1` / `3080` | where Traefik connects (the Docker gateway) |
| `DSH_PROFILE` | `web` | profile under `~/.dsh/profiles` to boot |
| `IDLE_MINUTES` | `20` | idle minutes before the harness is stopped (`0` = never) |
| `DSH_UPDATE_TAG` | `latest` | dist-tag to track (`latest`, `next`, `alpha`) |
| `DSH_REFRESH_ON_START` | `1` | resolve and fetch that tag before **every** cold start |
| `UPDATE_HOURS` | `1` | background check while running (`0` disables) |
| `DSH_CWD` | `$HOME` | default working directory (unset = a fresh machine's default) |
| `DSH_MOBILE_REPO` / `_REF` | the dsh-mobile repo / `main` | where the plugin is cloned from |
| `AUTH_MIDDLEWARE` | `authentik@docker` | the route's middleware; `setup.sh` writes `no-auth@docker` here when single sign-on is opted out of |

### Always the newest release

`dsh` is never launched *through* `npx`: npx does not `exec`-replace itself, so
its real process would be a grandchild that survives the bridge's `SIGTERM` and
keeps holding the port. Instead the bridge keeps its own copy of the package and
runs that directly.

With `DSH_REFRESH_ON_START=1` (the default here) it resolves `DSH_UPDATE_TAG`
and downloads it *before* each cold start, so every instance is the newest
release — the effect of `npx @deepseek-ai/dsh@latest web`, without the process
that will not die. The wait is bounded: a slow or unreachable registry just
means the cached copy comes up. A version that never becomes ready is rolled
back to the last one that served, so a bad release cannot lock you out.

## The phone shell

[dsh-mobile][] is installed into the profile, so it survives `dsh` upgrades. It
turns the sidebar into an off-canvas drawer below the shell's 1024px
breakpoint, makes Enter a line break instead of send, and fixes the tool-call,
trajectory and save-money widgets for touch — desktop is byte-for-byte as
shipped. **A restart is needed** after a plugin change for the browser roster
to be recomposed; letting the harness idle out and reopening the URL does it.

Install it as an app from the browser (**Add to Home Screen**) for the full
standalone experience. The bridge serves raster 192/512 icons into the manifest
because dsh ships only an SVG one Chrome refuses to install from
([upstream][pwa]), and `dsh.yml` deliberately exempts `/manifest.webmanifest`,
`/favicon.svg` and `/__bridge/icon-*` from forward auth — Chrome fetches those
without cookies, so authentik would otherwise answer 302 and install would
never be offered. The device must trust the root CA for any of it to work.

## Everyday operations

> **Lingering is required** or systemd tears the user service down with your
> last login and the browser shows **502 Bad Gateway**. `install.sh` enables
> it; check with `loginctl show-user "$USER" -p Linger` (want `Linger=yes`).

```sh
systemctl --user status dsh-web       # is it up?
systemctl --user restart dsh-web      # restart the bridge (and the harness)
journalctl --user -u dsh-web -f       # live logs, harness output included
systemctl --user stop dsh-web         # stop serving dsh.$TLD
./dsh/install.sh --status             # node / profile / plugin / service / route
```

If something else already owns `127.0.0.1:3080` — almost always a `dsh web` you
started by hand — the bridge does not start a competing instance; it shows a
page saying so and resumes once that one exits.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| 502 after logging out of SSH | linger is not enabled: `sudo loginctl enable-linger <user>` |
| 502 from Traefik | the bridge is not running (`systemctl --user status dsh-web`), or `LISTEN_HOST`/port changed |
| 403 from dsh | `PUBLIC_HOST` does not match the host you are using, so dsh's Host fence rejects it |
| Login page again and again | the `dsh-provider` is missing from the embedded outpost's provider list in the blueprint |
| Certificate warning for `dsh.$TLD` | `cert-watcher.sh` has not run yet (it reconciles periodically), or the device does not trust the root CA |
| "This app cannot be installed" | the device does not trust the root CA, or the bridge is not running with its `icons/` directory |
| "Starting…" page never finishes | `journalctl --user -u dsh-web -f`; usually the port is taken or dsh fails to boot |
| Plugin not visible on a phone | the roster was composed before it was installed — let the harness idle out, or restart the service |
| Settings → Models says *"settings are unavailable in this browser"* | dsh's own settings gate — the bridge should have forced it open and logged *"serving settings bundle with host persistence forced"*; if it logged *"did not match"*, upstream changed the bundle |
| A plugin's update/save button says *"untrusted origin"* | the bridge normalizes Host/Origin for the mutating routes; if you still see it, a dashboard or client is bypassing `dsh.$TLD` |
| npm is missing on the host | `./dsh/install.sh` installs it; if that failed, see the warning it printed (needs sudo, or `curl`+`tar` for the tarball fallback) |

[dsh-mobile]: https://github.com/notf0und/dsh-mobile
[pwa]: https://github.com/deepseek-ai/deepseek-harness/discussions/3736
