# irabelle-stack

A small self-hosted stack — [Traefik](https://traefik.io) as the HTTPS
front door, [dockhand](https://github.com/fnsys/dockhand) as the Docker
dashboard and [authentik](https://goauthentik.io) as the one login for both
and for Pi-hole — that publishes services under an internal domain
(`traefik.smart`, `dockhand.smart`, ...) with locally-signed certificates.

On top of that foundation it ships a media stack (`arr`, `books` and `plex`, all
sharing one `downloads/` tree), a private search engine (`searxng`), workflow
automation with a sandboxed code runner (`n8n`), and a voice server for Home
Assistant (`pocket-tts2`). Each is an independent stack — deploy the ones you
want and ignore the rest.

```
.
├── .env.example                     # template for the per-client .env files
├── host.env.example                 # host VLAN settings for host-vlan.sh
├── setup.sh                         # bootstrap: .env copies + root CA + pick stacks
├── host-vlan.sh                     # host Docker VLAN + macvlan network (needs root)
├── update.sh                        # pull + register new stacks (cron-friendly)
├── stacks.sh                        # start / stop / status every stack at once
├── NETWORK.md                       # VLAN / macvlan / bridge layout and why
├── traefik/
│   ├── compose.yml                  # reads ${TLD} from .env
│   ├── config/
│   │   ├── traefik.yml.example      # static config; setup.sh copies it into place
│   │   ├── traefik.yml              # your copy, edit away — not in git
│   │   ├── certificates/            # written by our scripts, as you — not in git
│   │   └── logs/                    # the certificate watcher's log — not in git
│   └── generate_certificates/
│       ├── 1-generate-root-certificates.sh
│       ├── 2-site-certificate.sh
│       ├── 3-sync-tls-file.sh
│       └── cert-watcher.sh
├── dockhand/
│   ├── compose.yml                  # reads ${TLD} from .env
│   └── config/dockhand/             # runtime state, not in git
├── authentik/
│   ├── compose.yml                  # server + worker + postgres; the forward-auth middleware
│   ├── .env.example                 # your login, generated secrets
│   └── config/
│       ├── authentik/blueprints/irabelle.yaml  # user, Dockhand OIDC, Pi-hole proxy
│       ├── authentik/data/          # media — not in git
│       └── postgresql/              # the database — not in git
├── adblock/
│   ├── compose.yml                  # Pi-hole + Unbound, on the Docker VLAN
│   ├── .env.example                 # TLD, TZ, static IPs
│   └── config/                          # one directory per service
│       ├── pihole/                      #   → /etc/pihole
│       │   ├── dnsmasq.d/99-irabelle.conf   # the *.$TLD wildcard
│       │   └── (database, blocklists — runtime state, not in git)
│       └── unbound/
│           ├── unbound.conf.example     # recursive resolver; setup.sh copies it
│           └── unbound.conf             # your copy — not in git
├── integrations.py                  # wires the media apps together (run by setup.sh)
├── fast-disk.sh                     # keeps every config/ on an SSD, same paths (sudo)
├── ADDING-A-STACK.md                # step by step, for a new stack
├── arr/
│   ├── compose.yml                  # Sonarr, Radarr, Prowlarr, Bazarr, Lingarr,
│   │                                # Cleanuparr, Byparr, Transmission
│   └── .env.example                 # generated API keys and DB passwords
├── books/
│   ├── compose.yml                  # Calibre, CWA, Shelfmark, Kavita, books-glue
│   ├── .env.example                 # TLD, TZ, PUID/PGID, KAVITA_API_KEY, toggles
│   ├── books-glue/                  # our own sync script — tracked source
│   │   ├── glue.py
│   │   └── README.md
│   └── scripts/
│       ├── shelfmark/               # manual-solve prompt, AA search cache,
│       │                            # mirror refresh (see its README)
│       └── kavita/                  # start hook: trust our root CA
├── plex/
│   └── compose.yml                  # Plex, on the host network; plex.$TLD via Traefik
├── searxng/
│   ├── compose.yml                  # SearXNG + Valkey
│   ├── .env.example                 # TLD, TZ, SEARXNG_SECRET
│   └── config/searxng/config/
│       └── settings.yml.example     # per-install; setup.sh copies it into place
├── n8n/
│   ├── compose.yml                  # n8n + its sandboxed code-execution cluster
│   └── .env.example                 # TLD, TZ, PUID/PGID, sandbox secrets
├── pocket-tts2/
│   ├── compose.yml                  # voice server for Home Assistant (host net)
│   ├── Dockerfile                   # built here, not pulled
│   ├── .env.example                 # TLD, TZ, PUID/PGID, optional HF_TOKEN
│   └── config/                      # mounted at /data, next to the caches
│       ├── start_services.sh        # entrypoint: Wyoming + OpenAI API
│       ├── wyoming_server.py
│       └── openai_api.py
├── smarthome/
│   ├── compose.yml                  # Home Assistant, MariaDB, Mosquitto, Zigbee2MQTT,
│   │                                # ESPHome, VoiceBM
│   ├── .env.example                 # generated passwords, HOST_IP, Zigbee dongle
│   ├── mosquitto.conf               # MQTT broker config (login from .env)
│   ├── scripts/homeassistant-entrypoint.sh   # trust our CA, wait for the DB
│   └── build/voicebm/               # built here, not pulled
├── iptv/
│   ├── compose.yml                  # Threadfin, streamlink, Cloudflare WARP
│   ├── build/streamlink/            # built here, with its custom plugin
│   └── config/streamlink/streams.yaml.example   # per-install; setup.sh copies it
├── monitoring/compose.yml           # Glances
├── mail/                            # Mailpit (SMTP catcher, optional relay)
├── ai/compose.yml                   # Ollama; models in ai/models/, not config/
├── dsh/                             # DeepSeek Harness — a HOST service, not a
│   ├── install.sh                   #   stack (no compose.yml): install.sh runs
│   ├── dsh-web-bridge.mjs           #   it as a systemd user service, renders the
│   ├── dsh-web.service.example      #   dsh.$TLD route behind authentik, and
│   ├── traefik/dsh.yml              #   installs dsh-mobile into its profile
│   ├── icons/                       #   PWA icons the bridge injects
│   └── .env.example                 #   harness settings; dsh/.env is gitignored
└── downloads/                       # media tree shared by arr, books and plex,
    ├── movies/                      #   at /data/downloads in every container
    ├── tv/                          #   → libraries — data, not in git
    ├── books/
    ├── torrents/{tv,movies}/        #   → finished torrents, hardlinked into tv/movies
    ├── complete/books/              #   → CWA ingest folder
    └── incomplete/                  #   → in-progress downloads
```

In a stack with more than one service, each service keeps its config and state
in `{stack}/config/{service}/` — `adblock` has `config/pihole/` (which *is* its
`/etc/pihole`) and `config/unbound/`. A single-service stack keeps its config
directly under `{stack}/config/`.

Every immediate subdirectory that contains a `compose.yml` is a **stack**.
`setup.sh` discovers them, so adding a stack means adding a directory — no
script changes. A stack may also ship its own `.env.example` (see
[Configuration](#configuration)). `dsh/` is the one deliberate exception: it is
a host service with no `compose.yml` — see [DeepSeek Harness](#deepseek-harness).

`adblock` is the LAN's DNS: Pi-hole at 192.168.40.5 on the Docker VLAN, with a
local recursive Unbound on a private bridge behind it. It needs the host VLAN
from `host-vlan.sh` first — see [NETWORK.md](NETWORK.md).

Beyond `traefik`, `dockhand` and `adblock`, the checkout ships six application
stacks, each deployed the same way — pick it in Dockhand:

| Stack | What it is | Published as |
| --- | --- | --- |
| `arr` | Sonarr, Radarr, Prowlarr, Bazarr, Lingarr, Cleanuparr, Byparr, Transmission | `sonarr.$TLD` … `transmission.$TLD` |
| `books` | Calibre, Calibre-Web-Automated, Shelfmark, Kavita, and our `books-glue` sync service | `calibre.$TLD`, `calibre-web-automated.$TLD`, `shelfmark.$TLD`, `kavita.$TLD` |
| `plex` | Plex | `plex.$TLD` |
| `searxng` | SearXNG and its Valkey | `searxng.$TLD` |
| `n8n` | n8n and its sandboxed code-execution cluster | `n8n.$TLD` |
| `pocket-tts2` | Pocket TTS 2.1.0 for the Home Assistant voice pipeline | host ports 10215/10216 — see below |
| `smarthome` | Home Assistant and its MariaDB, Mosquitto, Zigbee2MQTT, ESPHome, VoiceBM | `homeassistant.$TLD`, `zigbee2mqtt.$TLD`, `esphome.$TLD`, `voicebm.$TLD` — see [Smart home](#smart-home) |
| `iptv` | Threadfin (IPTV tuner for Plex), streamlink, Cloudflare WARP | `threadfin.$TLD`; streams on ports 46200-46250 |
| `monitoring` | Glances | `glances.$TLD` |
| `mail` | Mailpit | `mailpit.$TLD`; SMTP on port 1025 |
| `ai` | Ollama | `ollama.$TLD` (behind authentik); `127.0.0.1:11434` on the host |

`dsh` is the one exception to that table: the DeepSeek Harness refuses to bind
anything but loopback, so it runs as a host systemd *user* service with a small
bridge in front of it, and has no `compose.yml` to deploy from Dockhand.
Installing it is opt-in — `setup.sh` asks once and remembers the answer in
`host.env` (`DSH_INSTALL`, `--dsh` / `--no-dsh`) — and it is provisioned
through `dsh/install.sh`; see [DeepSeek Harness](#deepseek-harness).

`arr`, `books` and `plex` all reach into the shared `downloads/` tree at the repo
root, mounted whole at the same path — `/data/downloads` — in every container.
One path everywhere means no remote path mappings between the apps, and one
mount on one filesystem is what lets a finished torrent be *hardlinked* into
the library instead of copied, which is the difference between an instant
import and a full disk copy. `setup.sh` creates the empty skeleton there; the
whole tree is gitignored.

Every web UI in them logs in through authentik, and `setup.sh` wires them to
each other — see [Media apps](#media-apps-wired-together-and-behind-authentik).

Two stacks are worth a note on networking, because media and voice protocols sit
awkwardly around an HTTP reverse proxy — one keeps the normal model, one cannot:

* **`plex` uses `network_mode: host`**, so LAN clients (TVs, phones, the desktop
  app) see it as local, find it on their own and stream straight from 32400.
  Traefik still routes `plex.$TLD` to it (through `host.docker.internal`), and
  the containers that talk to it — Sonarr, Radarr, Bazarr — map the name `plex`
  to the host, so `http://plex:32400` works from there too. No authentik in
  front: the Plex apps sign in with your Plex account.
* **`pocket-tts2` uses `network_mode: host`**, because Home Assistant finds it by
  mDNS broadcast and dials it on a raw Wyoming port. There is no hostname for
  Traefik to route, so host networking is what makes it work at all.

## Bootstrapping a host with no DNS yet

This LAN's only resolver is the Pi-hole this stack runs, so a brand new host
can't resolve *anything* before that Pi-hole exists — including the
`git clone` and `docker pull` this repo itself needs. Paste this whole block
into an SSH session on the new host and it gets out of that on its own:

```sh
# 1. a reusable escape hatch, kept in $HOME on purpose so re-cloning the
#    stack never takes it with it. setup.sh reverts this automatically once
#    adblock (Pi-hole) is confirmed running — see the end of its own output.
cat > ~/manual-dns.sh <<'MANUAL_DNS_SCRIPT'
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# manual-dns.sh — point this machine's resolver at a public DNS server for a
# while, then hand it back. Nothing is written to any configuration file.
#
#   ./manual-dns.sh on               # switch to 8.8.8.8
#   ./manual-dns.sh on 1.1.1.1       # ...or to something else
#   ./manual-dns.sh off              # back to the network-provided resolver
#   ./manual-dns.sh status           # what is in use right now
#
# `on` and `off` need root and re-exec themselves through sudo. `status` does
# not, and is the safe one to run any time.
#
# Why this exists: the router advertises its Pi-hole as the LAN resolver
# (DHCP option 6) and has no other upstream (`noresolv=1`), so while Pi-hole is
# down this machine cannot resolve anything — including the `git clone` and
# `docker pull` needed to bring Pi-hole back. This is the way out of that
# chicken-and-egg.
#
# The override is runtime-only: systemd-resolved forgets it at the next DHCP
# lease renewal or reboot. `off` restores the network-provided value, which
# will be Pi-hole again.
#
# It lives in the home directory on purpose — outside the checkout, so deleting
# and re-cloning the stack does not take it with it.
# ---------------------------------------------------------------------------
set -euo pipefail

SERVERS=(8.8.8.8)

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: ./manual-dns.sh [on [SERVER...] | off | status]

  on      replace every link's resolver with the given servers (default 8.8.8.8)
  off     hand the links back to what the network provides (DHCP)
  status  show the resolver(s) in use and whether public names resolve

Runtime only: no change to netplan, NetworkManager or resolved.conf, so a
reboot or a lease renewal undoes it on its own.
EOF
}

command -v resolvectl >/dev/null 2>&1 || die "resolvectl not found — this needs systemd-resolved"
resolvectl status >/dev/null 2>&1 || die "systemd-resolved is not answering"

# The links worth touching: every interface that actually carries an IPv4
# address. Container and bridge interfaces are excluded — they have their own
# resolver plumbing and nothing there needs a public DNS server.
links() {
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '{ print $2 }' \
    | grep -vE '^(lo|docker[0-9]*|br-|veth|virbr|bond|tun|tap)' \
    | sort -u
}

show_link() {                     # $1 = link
  local dns
  dns=$(resolvectl dns "$1" 2>/dev/null | sed 's/^Link [0-9]* ([^)]*): *//')
  printf '    %-16s %s\n' "$1" "${dns:-(none)}"
}

status() {
  local link
  say "Resolver in use"
  while read -r link; do
    [ -n "$link" ] && show_link "$link"
  done < <(links)
  printf '\n    public names:  '
  if timeout 6 resolvectl query github.com >/dev/null 2>&1; then
    printf 'resolve\n'
  else
    printf 'DO NOT RESOLVE\n'
  fi
  printf '    default route: %s\n' "$(ip -4 route show default 2>/dev/null | head -1)"
}

set_dns() {
  local link
  say "Pointing every link at ${SERVERS[*]}"
  while read -r link; do
    [ -n "$link" ] || continue
    printf '    %-16s ' "$link"
    if resolvectl dns "$link" "${SERVERS[@]}" >/dev/null 2>&1; then
      printf 'ok\n'
    else
      printf 'FAILED\n'
    fi
  done < <(links)
  resolvectl flush-caches >/dev/null 2>&1 || true
  status
}

revert_dns() {
  local link
  say "Reverting to the network-provided resolver"
  while read -r link; do
    [ -n "$link" ] || continue
    printf '    %-16s ' "$link"
    if resolvectl revert "$link" >/dev/null 2>&1; then
      printf 'reverted\n'
    else
      printf 'FAILED\n'
    fi
  done < <(links)
  resolvectl flush-caches >/dev/null 2>&1 || true
  note "that is the LAN config again — Pi-hole, which fails while it is down"
  status
}

case "${1:-status}" in
  on)
    shift
    if [ $# -gt 0 ]; then SERVERS=("$@"); fi
    if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" on "${SERVERS[@]}"; fi
    set_dns
    ;;
  off)
    if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" off; fi
    revert_dns
    ;;
  status)          status ;;
  -h|--help|help)  usage ;;
  *)               usage >&2; exit 1 ;;
esac
MANUAL_DNS_SCRIPT
chmod +x ~/manual-dns.sh

# 2. point this host at a public resolver so the clone/pull below can resolve names
~/manual-dns.sh on

# 3. clone and bootstrap
git clone git@github.com:notf0und/irabelle-stack.git irabelle-stack
cd irabelle-stack
./setup.sh
```

`setup.sh` hands `~/manual-dns.sh` back to the router's DNS on its own, once
`adblock` (Pi-hole) is confirmed actually running — see its final "Manual DNS
override" section. Nothing to do here afterward.

Already have working DNS? Skip straight to [Quickstart](#quickstart) below.

## Quickstart

```sh
git clone <this repo> irabelle-stack
cd irabelle-stack
./setup.sh
```

`setup.sh` bootstraps the host and then gets out of the way. It does only the
work Dockhand cannot do for itself:

1. create the `.env` files the stacks read — from `.env.example` at the root,
   and copied into every stack (a stack shipping its own `.env.example` uses
   that instead, so it can carry extra variables);
2. create the shared `app-bridge` network Dockhand attaches to;
3. generate the root CA behind the `*.$TLD` certificates; then, if this
   checkout is on a slow (spinning or USB) disk, offer to keep every stack's
   `config/` — its settings and databases — on an SSD instead (see
   [Configs and databases on a fast disk](#configs-and-databases-on-a-fast-disk));
4. start the **base stacks** — traefik, adblock, authentik and Dockhand —
   so `https://<service>.<TLD>`, the login and Dockhand work right after
   this script finishes. adblock needs `app-macvlan`, so it only starts once
   `host-vlan.sh` has created it. Every other stack (arr, books, plex, …) is
   not started: it is adopted into Dockhand (step 6) and you deploy it from
   there;
5. start **Dockhand** (the last base stack, on its own because it needs a
   health check and a baseline first);
6. give Dockhand the things that are not in git — a local environment named
   **Irabelle** (timezone from `.env`'s `TZ`, scheduled updates applied
   automatically, automatic image pruning, version-tag checks and selfh.st
   icons all on), and this checkout as an external stack path — so a fresh
   clone is usable without clicking through onboarding. This baseline is
   applied once, only when Dockhand's own database is empty (a fresh
   install); it never overwrites a setting you change afterward in
   Dockhand's UI, the same way an existing `.env` is left alone;
7. set up **single sign-on** — it asks once for a username and your email
   (your login for authentik, Dockhand, Pi-hole and the media apps) and
   generates the password, then makes that the Dockhand login too and
   switches Dockhand's authentication on. See
   [Single sign-on](#single-sign-on-authentik). Then it wires together any
   media apps that are already running (`integrations.py`, see
   [Media apps](#media-apps-wired-together-and-behind-authentik)) — on a
   first run none are yet;
8. trust the root CA on this host itself (`sudo`; skip with `--no-trust-ca`)
   — every *client* device (phone, laptop, ...) still needs its own one-time
   step regardless, printed at the end alongside the CA's path;
9. if `~/manual-dns.sh` exists and shows a manual override active (this
   repo's own bootstrapping-before-Pi-hole-exists escape hatch, not
   something every install has), hand this host's DNS back to whatever the
   router now provides — safe to skip if adblock isn't actually running yet.
   This happens right after the stacks start, before Dockhand, once Pi-hole
   answers; if public names then fail to resolve, the override is put back
   and it tells you;
10. print your login and the URLs to open last, as clickable hyperlinks —
    `https://dockhand.<TLD>` first, `ip:port` fallbacks after — so it works
    over SSH: clicking a hyperlink opens it in the browser on *your* machine,
    which is the only way this can work at all over a plain SSH session,
    since nothing running on the server can reach into a remote desktop on
    its own. It only tries to launch a browser itself when the host has a
    display to draw on.

Every stack other than the base ones — including any added later — is
deployed by hand, from Dockhand's UI, where it is already waiting.

Because Dockhand's own `dockhand.<TLD>` name needs Traefik, its port is
published directly (`DOCKHAND_PORT`, default 3000) — that URL is the
chicken-and-egg escape hatch. It bypasses Traefik's TLS, which is why the
single sign-on step switches Dockhand's authentication on; `setup.sh` warns
if it is still off.

It also installs two cron jobs — `update.sh`, which every 12 hours pulls this
checkout and makes newly added stacks *available* in Dockhand, and the
certificate watcher at boot (the issued certificates live in the checkout and
are not in git either). Neither one deploys anything, and neither leaves a log
file behind:

```sh
./setup.sh               # installs them by default
./setup.sh --no-cron     # skip them
```

`setup.sh` never issues service certificates and never overwrites an existing
`.env`, root CA or certificate. It is safe to re-run. The directories it creates
are the ones a container or the watcher would otherwise invent as root: every
bind-mount source in the checkout, the shared `downloads/` skeleton, the TTS
model and voice caches, and `traefik/config/logs` with
`traefik/config/certificates`. That last pair is the cautionary tale — a
root-owned `logs/` is what made the certificate watcher look broken: it could not
write its own log, and the failing write aborted it under `set -e`. To deploy by
hand instead, it is just compose:

```sh
docker compose -f traefik/compose.yml up -d
```

### Configs and databases on a fast disk

This checkout usually lives on the big disk the media needs, and that disk is
often a USB or spinning one. Left there, every database here waits on it:
Home Assistant's history, Plex, the *arrs, Pi-hole all slow down together, and
a finished download that is being written to the same disk makes it worse.
Moving just their state to an SSD fixes that — measured on station, the USB
disk went from constantly busy to idle, and Home Assistant history loads
almost instantly.

`setup.sh` does it for you. On its first run, when it sees the checkout on a
slow disk, it lists the SSDs it could use and asks; the answer is kept in
`host.env` (`FAST_DATA_DIR`). From then on every run keeps it up to date —
including for stacks added later:

```sh
./setup.sh                          # asks, once
./setup.sh --fast-disk /home/irabelle-stack-data   # or say where up front
./setup.sh --no-fast-disk           # keep them here, and stop asking
./fast-disk.sh status               # where each <stack>/config is now
```

What `fast-disk.sh` does, per stack: copy `<stack>/config` to
`FAST_DATA_DIR/<stack>/config` (first while everything runs, then again during
one short stop), bind-mount that copy back over `<stack>/config`, and add the
mount to `/etc/fstab`. **Every path stays the same** — in compose files, in
Dockhand, in your shell. Docker is made to wait for those mounts at boot, so
nothing ever starts against the old copy underneath them. Only `config/`
moves: `downloads/` stays on the big disk, where large sequential reads and
writes are what it does well.

**Before you delete or re-clone the checkout, release the fast disk first:**

```sh
sudo ./fast-disk.sh release
```

That copies everything back into the checkout and removes the mounts and fstab
lines. Skip it and `rm -rf` reaches through the mounts into the SSD copy.

### Starting and stopping everything

`stacks.sh` acts on every stack in the checkout at once — any directory here
with a `compose.yml`, the same rule `setup.sh` uses:

```sh
./stacks.sh              # stop everything (the default action)
./stacks.sh start        # bring it all back
./stacks.sh restart      # restart in place
./stacks.sh status       # one line per stack: running/total
./stacks.sh down         # remove the containers (volumes are kept)
```

`stop` keeps the containers, so `start` restores them exactly as they were: no
compose file is read and no `.env` is needed. Containers are matched by
compose's project label *and* the checkout they were created from, so it never
touches another checkout's containers, or the host's own Docker workloads.

To pick up a changed `compose.yml` or `.env`, use `down` then `start`, or force
a recreate:

```sh
docker compose -f <stack>/compose.yml up -d --force-recreate
```

That distinction matters more than it looks: a **bind-mounted config file** —
`traefik/config/traefik.yml`, say — is invisible to `docker compose up -d`. It
sees no change in the service definition, leaves the container running, and the
old configuration stays in effect. Restart or force-recreate the container.

### Keeping the checkout yours

Containers run as root, so the files they create in a bind mount are owned by
root. Reading them is fine, but a root-owned **directory** inside the checkout
cannot be emptied without `sudo` — `rm -rf` fails on it — which is the annoyance
this layout exists to avoid.

Nothing is hidden in a volume: everything a stack writes stays in the checkout,
where you can read and edit it. Three things make that work:

* `setup.sh` creates the directories a container would otherwise create for
  itself — `dockhand/config/dockhand`, `traefik/config/logs`, plus every bind
  mount source — **as you**, so no directory here is ever root-owned.
* Where an image lets it, the container simply runs as you (`PUID`/`PGID`):
  every `authentik` container does, postgres included, so its database under
  `authentik/config/postgresql` is yours outright.
* It then puts a **default ACL** on the directories containers write into —
  `downloads/`, `adblock/config/pihole`, `dockhand/config/dockhand`,
  `traefik/config/logs`, and the `config/` root of every application stack
  (`arr`, `books`, `plex`, `searxng`, `n8n`, `pocket-tts2`). New files inherit
  it, new subdirectories inherit it
  recursively, and the upshot is that root-written files stay yours to edit and
  root-written directories stay yours to delete. It needs the `acl` package
  (`sudo apt install acl`); `setup.sh` warns with that line if `setfacl` is
  missing.

The root CA and the issued certificates live in the checkout too, but our own
scripts write them as you. A re-clone therefore issues a **new** CA — devices
that trusted the old one must import the new one — while Pi-hole's and
Dockhand's state, being ordinary directories here, simply goes with the
checkout.

If a root-owned path does turn up, `setup.sh` reports it and prints the fix:

```sh
find /path/to/irabelle-stack -user root              # look
sudo chown -R $(id -un) /path/to/irabelle-stack      # then rm -rf works
```

### Deploying through Dockhand (or any git-based tool)

These stacks work from a git-based deploy, with one difference: `.env` is
gitignored, so a fresh checkout does not have one and there is nothing for
Compose to interpolate. The values come from the tool instead — in Dockhand,
the stack's **Environment variables** panel:

| Variable | Value |
| --- | --- |
| `TLD` | `smart` |
| `PIHOLE_IP` | `192.168.40.5` |
| `APP_BRIDGE_SUBNET` | `docker network inspect app-bridge` → its subnet (the only one let into the Pi-hole UI) |

The `authentik` stack needs everything in `authentik/.env.example` the same
way — the secrets are the `change-me` lines there.

`env_file` is declared optional in the application stacks — `adblock`, `arr`,
`books`, `plex`, `searxng`, `n8n` and `pocket-tts2` — for exactly this reason, so
a missing `.env` is not an error and the panel can carry the values. The same
variables in the stack's `.env` (via `setup.sh`) work identically for the CLI
path — both at once is fine, the file wins.

The stacks that ship their own `.env.example` are the ones carrying variables the
repo root does not know about, so their panels need these:

| Stack | Panel variables |
| --- | --- |
| `arr` | `TLD`, `TZ`, `PUID`, `PGID`, `SONARR_API_KEY`, `RADARR_API_KEY`, `PROWLARR_API_KEY`, `LINGARR_DB_PASSWORD`, `LINGARR_DB_ROOT_PASSWORD` |
| `plex` | `TLD`, `TZ`, `PUID`, `PGID` — inherited from the repo root; `PLEX_CLAIM` for the one start that claims it |
| `books` | `TLD`, `TZ`, `PUID`, `PGID`, `KAVITA_API_KEY`, `SHELFMARK_USERNAME`, `SHELFMARK_PASSWORD`, and the optional `GLUE_*` / `CALIBRE_AUTO_RESTART` toggles |
| `searxng` | `TLD`, `TZ`, `SEARXNG_SECRET` |
| `n8n` | `TLD`, `TZ`, `PUID`, `PGID`, `SANDBOX_API_KEYS`, `SANDBOX_API_RUNNER_REGISTRATION_TOKEN`, `SANDBOX_API_RUNNER_API_KEY` |
| `pocket-tts2` | `TLD`, `TZ`, `PUID`, `PGID`, and optionally `HF_TOKEN` |
| `smarthome` | `TLD`, `TZ`, `PUID`, `PGID`, `HOST_IP`, `HA_DB_PASSWORD`, `HA_DB_ROOT_PASSWORD`, `MQTT_PASSWORD`, and for Zigbee `ZIGBEE_DEVICE` + `COMPOSE_PROFILES=zigbee` |
| `mail` | `TLD`, `TZ`, `PUID`, `PGID`, and optionally the `MP_*` relay/webhook settings |
| `iptv`, `monitoring`, `ai` | `TLD`, `TZ`, `PUID`, `PGID` — inherited from the repo root |

`dsh` is not in this table: it is a host service rather than a Dockhand stack,
and its settings live in `dsh/.env` — see
[DeepSeek Harness](#deepseek-harness).

For the two that carry generated secrets — `searxng` (`SEARXNG_SECRET`) and `n8n`
(the three sandbox values) — `setup.sh` fills them in from the literal
`change-me` placeholder in the `.env.example`. When deploying from git instead,
put any random string in the panel: compose refuses to start without them, which
is deliberate, since an empty secret is worse than a missing one.

`KAVITA_API_KEY` is the one value that cannot be generated: Kavita issues it.
`setup.sh` creates your Kavita account and fills it in; on a git-based deploy,
leave it empty until the stack has run once, then paste the key in.

One caveat if you use Dockhand: before **1.0.40**, Deploy/Sync passed those
variables to Compose but Start/Stop/Down did not, so a stack with any `${VAR}`
would deploy and then fail on every later action
([#1313](https://github.com/Finsys/dockhand/issues/1313)). Upgrade, or operate
the stack through Deploy/Sync only.

#### Two ways to register a stack, and why they differ

| | **From git** | **Import / `update.sh`** |
| --- | --- | --- |
| Files | cloned into Dockhand's own storage | stay in this checkout |
| `.env` | not in the clone (gitignored) → values must come from the env panel | the ones `setup.sh` writes, used as-is |
| Secrets | Dockhand's environment panel | the gitignored `.env`, as usual |
| Auto-sync, webhooks | yes, per stack | no — redeploy after your own `git pull` |
| Adding a stack | one Dockhand stack per subdirectory, by hand | one command (below) |

Because imported stacks keep their files here, they fit this repo's design
better: `setup.sh` creates the `.env` files, and Dockhand reads them in place.

#### Making a new stack available automatically

Dockhand has no directory watcher, so a stack added here does not register
itself. `update.sh` closes that gap using the same API as Dockhand's Import
button — it scans this checkout, subtracts what Dockhand already tracks, and
adopts the rest:

```sh
./update.sh --dry-run      # list what would be adopted; no pull, no writes
./update.sh                # pull, then adopt anything new
./update.sh --no-pull      # adopt what is on disk now, without pulling
./update.sh --deploy       # adopt, then deploy (opt-in)
```

It is meant for cron, and `setup.sh` installs it:

```cron
0 */12 * * * /home/carlos/irabelle-stack/update.sh
```

Registering a stack is inert — no containers are created, nothing is started,
stopped or restarted. New stacks simply appear in Dockhand waiting for you to
deploy them, which is why there is no `--deploy` in the cron line: this script
keeps stacks *available*, you decide when they *run*.

Two deliberate behaviours: it takes a lock so one run cannot overlap the next,
and if `git pull --ff-only` fails it exits **before** registering anything — a
half-updated checkout, or one with local edits, is not something to hand to
Dockhand. It locates Dockhand by inspecting the container; set `DOCKHAND_URL` to
point it elsewhere. Once Dockhand authentication is on it authenticates with
the API token `setup.sh` saved to `dockhand/.api-token`; `DOCKHAND_TOKEN`
overrides it.

## Single sign-on (authentik)

One login — asked for once by `setup.sh`, password generated — covers
authentik, Dockhand and Pi-hole, and logging in to one logs you in to the
others. `setup.sh` prints it at the end; it is also in `authentik/.env`
(`ADMIN_USERNAME`, `ADMIN_PASSWORD`). Change the password in authentik
(`https://authentik.<TLD>`, top right → Settings), not in that file: the
user is created once, the first time authentik starts, and the file is not
read for it again.

How each service is wired:

* **authentik** itself is configured by
  `authentik/config/authentik/blueprints/irabelle.yaml`, which the worker
  applies on every start — the user (in `authentik Admins`), an OIDC client
  for Dockhand, and proxy providers for Pi-hole and the DeepSeek Harness. Both
  applications are bound to `authentik Admins`, so a user added later for
  something else gets into neither. Edit the blueprint, not the UI, for
  anything it defines.
* **Dockhand** speaks OIDC itself. `setup.sh` creates a local Dockhand user
  with the same name and password, registers authentik as its OIDC provider
  (the default button on the login page) and switches authentication on.
  Dockhand matches the authentik login to that user by name. The local
  password is the way in while authentik is down (on `http://<host>:3000`
  too), but it is a copy: it does not follow a later change in authentik.
  Dockhand checks the login server-side at `https://authentik.<TLD>`, which
  it reaches through a Traefik alias on `app-bridge` and trusts through
  `NODE_EXTRA_CA_CERTS` (both in the compose files, no DNS needed).
* **Pi-hole** has no OIDC, so it gets **forward auth** instead: its HTTPS
  router carries Traefik's `authentik@docker` middleware, which asks
  authentik about every request first. Pi-hole's own password is switched
  off — authentik's login is the only one — and its web server only accepts
  connections from `app-bridge` (`FTLCONF_webserver_acl`), so Pi-hole's LAN
  address (192.168.40.5) cannot be used to get around it. DNS on that
  address is unaffected. If authentik is down, `pihole.<TLD>` answers 404
  rather than letting anyone in.

**The rule: every web UI is behind authentik.** Either the app logs in through
it over OIDC (Dockhand, Kavita, Shelfmark, Cleanuparr), or Traefik's
`authentik@docker` middleware stands in front of it (everything else with a UI:
the *arrs, Transmission, Calibre and Calibre-Web, Zigbee2MQTT, ESPHome, VoiceBM,
Threadfin, Glances, Mailpit, Ollama, SearXNG, n8n, Pi-hole, the DeepSeek Harness
at `dsh.$TLD`, and Traefik's own dashboard). The exceptions, and why:

| Not behind authentik | Why | Protected by |
| --- | --- | --- |
| Home Assistant | its companion apps and devices cannot do a web login | its own login |
| Plex | the Plex apps sign in with your Plex account | Plex's login |
| `/api` on Sonarr, Radarr, Prowlarr, Bazarr | called by phone apps and Home Assistant | the API key |
| n8n `/webhook*`, `/form*`, `/mcp*` | called by other systems | their own secret path or credentials |
| Calibre-Web `/opds`, `/kobo` | e-readers | Calibre-Web's password |
| the bare `traefik` name | `cert-watcher.sh` reads the router list there | only this host and Docker's networks (172.16/12) get in |

A few services listen on the host network, where Traefik is not in the way:
Glances and VoiceBM's dashboard are bound to the Docker bridge address only, so
the LAN cannot reach them around authentik; VoiceBM's audio and speech ports
stay on the LAN for Home Assistant and your speakers.

To put another service behind the login the same way, add
`authentik@docker` to its router's middlewares, then add a `forward_single`
proxy provider and application for it to the blueprint — and the provider
to the embedded outpost's list there.

authentik also always has its own built-in `akadmin` account. You do not use
it, but it is given a generated password (`AUTHENTIK_BOOTSTRAP_PASSWORD`),
because an `akadmin` without one leaves authentik's first-run setup page open
to anyone on the LAN.

## DeepSeek Harness

`dsh/` puts the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
at `https://dsh.$TLD` behind the authentik login, with the
[dsh-mobile](https://github.com/notf0und/dsh-mobile) plugin installed so a phone
gets a proper shell.

It is the one thing here that is **not a container**. `dsh web` refuses to bind
anything but `127.0.0.1` — the GUI is remote code execution — so
`dsh/dsh-web-bridge.mjs` runs as a systemd *user* service on the host, listens
on the Docker gateway, and forwards to the harness on loopback; Traefik dials
the bridge through `host.docker.internal`, exactly as the `plex` and `glances`
stacks reach their host-network containers. The upside is that the agent runs as
you, on this host, with your real checkouts and tools.

`dsh/install.sh` owns the whole install and is idempotent. Installing it is
**opt-in**: `setup.sh` asks on its first run and remembers the answer in
`host.env` as `DSH_INSTALL` (`yes`/`no`), because a host user service and a
Node.js dependency are a real choice — `--dsh` / `--no-dsh` answer without
being asked.

```sh
./setup.sh                 # asks once, unless host.env already answers
./setup.sh --dsh           # install it, no question
./dsh/install.sh           # install/refresh directly, after editing dsh/.env
./dsh/install.sh --status  # node / profile / plugin / service / route
```

It creates `dsh/.env` (TLD from the root `.env`), bootstraps the DSH profile,
clones and installs `dsh-mobile`, renders and starts the systemd user service,
enables lingering so it survives logging out of SSH, and renders
`traefik/config/certificates/dsh.yml` — the route in Traefik's file provider.
The authentik half is the `dsh-provider` forward-auth provider in the blueprint
above. `update.sh` only ever **refreshes an install that already exists**
(`--no-restart`), so nothing installs dsh behind your back.

Two things worth knowing:

* **It tracks the latest release on every start.** `DSH_REFRESH_ON_START=1`
  makes the bridge resolve and download `DSH_UPDATE_TAG` before each cold start,
  so every instance is the newest release — the effect of
  `npx @deepseek-ai/dsh@latest web`, without the `npx` process that outlives a
  stop and keeps holding the port. A release that never becomes ready is rolled
  back automatically.
* **The harness needs Node.js** (20+, 22+ recommended) on this host. Without it
  `install.sh` explains what to install and `setup.sh` carries on; nothing else
  depends on it.

The harness stops itself after `IDLE_MINUTES` (20 by default) with no browser
connection, no session activity and no running tool, and starts again on the
next request — so it costs nothing while unused. Logs and control are
`journalctl --user -u dsh-web` and `systemctl --user status dsh-web`. Full
detail, including the PWA/phone notes and a troubleshooting table, is in
[dsh/README.md](dsh/README.md).

## Smart home

The `smarthome` stack is Home Assistant with what it usually needs next to it.
Deploy it from Dockhand, then run `./integrations.py` (the update cron job does
it too, within 12 hours):

* **Home Assistant keeps its own login** — no authentik in front, because its
  companion apps and devices cannot do that login. `integrations.py` creates the
  owner account with your authentik username and password (so there is no
  first-run wizard), tells it to trust Traefik's forwarded headers (without that
  `homeassistant.<TLD>` answers 400), points its history at the stack's MariaDB,
  and connects its MQTT integration to Mosquitto.
* **MQTT has a real login**, generated into `smarthome/.env` (`MQTT_USER`,
  `MQTT_PASSWORD`) and applied at every start. Give your devices the same, and
  this host's address on port 1883.
* **Zigbee2MQTT starts only with a coordinator plugged in.** `setup.sh` looks
  in `/dev/serial/by-id/` for a Zigbee dongle and, when it finds one, writes
  `ZIGBEE_DEVICE` and `COMPOSE_PROFILES=zigbee` into `smarthome/.env`. Plug one
  in later and re-run `./setup.sh`, or set both by hand.
* **ESPHome is on `app-bridge`, not the host network**, so its dashboard (no
  login of its own) is only reachable through authentik. Device status comes
  from ping rather than mDNS; flashing over the air works as usual. Its build
  cache (several GB) is in `smarthome/cache/`, so it stays off the fast disk.
* **VoiceBM** (speaker recognition and speech-to-text for HA's voice pipeline)
  is built from `smarthome/build/voicebm` on the first deploy and downloads its
  models on the first start (about 500 MB with the defaults, set in
  `smarthome/.env`). HA reaches its Wyoming proxy at `127.0.0.1:10301`.
* **Host network:** Home Assistant and VoiceBM share the host's network stack,
  so what they listen on is on the LAN. Home Assistant (8123) has its login.
  VoiceBM's dashboard is patched at build time to listen on the Docker bridge
  only, so `voicebm.<TLD>` (behind authentik) is the one way to it; its audio
  server (9090) and Wyoming/transcription ports (10301/10302) stay on the LAN
  for HA, cameras and speakers, and have no login — keep them off an untrusted
  network.

## Media apps: wired together and behind authentik

The same authentik login covers every web UI in `arr`, `books` and `plex`,
and the apps get connected to each other the way the reference server
(station) has them, so a fresh install is ready to search and download
without clicking through a dozen settings pages.

These stacks are not started by `setup.sh`: it adopts them into Dockhand,
and you deploy the ones you want from there. The wiring is `integrations.py`,
which only touches apps that are running and only adds what is missing —
anything you change in an app's UI afterwards is left alone. It runs at the
end of `setup.sh` and on every `update.sh` run (the 12-hour cron job), so a
stack you deploy gets wired on its own. To have it done straight away, run it
right after deploying:

```sh
./integrations.py
```

Run by hand like that it is also what claims Plex (below).

| App | Login | What `integrations.py` sets up |
| --- | --- | --- |
| Sonarr, Radarr | authentik forward auth (app login set to External) | root folder, Transmission as download client (into `downloads/torrents/…`), a Plex connection once Plex is claimed |
| Prowlarr | forward auth (External) | Sonarr and Radarr as apps (full sync, so they get every indexer), Byparr as the Cloudflare proxy, Transmission, and station's working public trackers — 1337x, EZTV and Torrent Downloads through Byparr |
| Bazarr | forward auth | Sonarr and Radarr, an English language profile as the default, the providers that need no account (embedded subtitles, Subf2m, BSPlayer) |
| Lingarr | forward auth | first-run screen, Sonarr and Radarr. No languages: pick source and target in its UI to start translating |
| Cleanuparr | authentik over OIDC | your account, Sonarr, Radarr, Transmission, the queue cleaner and the malware blocker |
| Transmission, Byparr | forward auth | download and in-progress directories |
| Plex | its own (your Plex account) | the Movies and TV Shows libraries, once claimed |
| Kavita | authentik over OIDC | your admin account, the Books library (CWA's Calibre library), and the API key books-glue uses |
| Shelfmark | authentik over OIDC | your admin account, Prowlarr (switched on) and Transmission for torrents, the path between Transmission and CWA's ingest folder, Byparr for Cloudflare, the Library button to CWA, and the login books-glue's mirror refresh uses |
| Calibre-Web-Automated | forward auth, then authentik's username header | its default `admin` renamed to your login and given your password |
| Calibre | forward auth | — |

A few things worth knowing:

* **API access skips authentik.** `/api` on Sonarr, Radarr, Prowlarr and
  Bazarr has its own router without the middleware, so phone apps and Home
  Assistant keep working with the app's API key alone. The apps talk to each
  other over `app-bridge` by container name and never touch authentik.
* **Every app with a login of its own keeps a local account** with your name
  and the password from `authentik/.env` — the way in if authentik is down.
  Like Dockhand's, it is a copy and does not follow a later change in
  authentik.
* **Plex has to be claimed once.** Once the plex stack is deployed, run
  `./integrations.py` in a terminal: it asks for a code from
  <https://plex.tv/claim> (valid four minutes — get it right before), restarts
  Plex with it, and then creates the libraries and connects Sonarr and Radarr
  on that same run. Enter skips; the cron runs never ask.
* **E-readers.** CWA's `/opds` and `/kobo` paths skip authentik (an e-reader
  cannot do that login) and use CWA's own password — your authentik one, as
  set by `integrations.py`. Kavita's OPDS URL carries its own key. Calibre's
  8181/8081 are also published directly, for BookFusion; those bypass
  authentik too.
* **Trust.** Kavita, Shelfmark and Cleanuparr check the authentik login
  server-side over `https://authentik.<TLD>`, so they trust the root CA:
  Kavita through a start hook (`books/scripts/kavita`), the others through
  `ca-bundle.crt`, which `setup.sh` rebuilds next to the CA on every run from
  this host's roots plus ours.

## Configuration

Each stack reads its own `.env` from its own directory. The repo root has the
master copy: `setup.sh` uses it as the template, so a new stack starts with the
values you already configured, and every stack can then diverge (a future stack
may need variables the others do not).

A stack can also ship its own `.env.example` next to its `compose.yml`. When it
does, that file is the template for that stack's `.env` — it wins over the root
one, so a stack with extra variables (or different defaults) is described by its
own directory and the shared root template stays generic. If a stack has no
`.env.example`, it inherits the root values as before.

`TLD` is shared by every stack, and the root `.env` is its only source of
truth — a stack's own `.env.example` (adblock, dockhand) declares it as
`TLD=@TLD@`, expanded from the root `.env` when `setup.sh` creates that
stack's `.env`, rather than repeating a literal value. If a stack's `.env`
ever drifts from the root one (e.g. hand-edited), `setup.sh` overwrites it to
match on the next run instead of silently deploying services under two
different domains — you never need to touch a stack's `.env` for `TLD`
directly. To re-copy the whole template into one stack:

```sh
cp .env traefik/.env     # a stack with its own .env.example takes that instead
```

### Renaming the internal domain

This is also how an existing install moves off an earlier default (`local`, then
`internal`). Edit `TLD` in the root `.env` only, then re-run `setup.sh`:

```sh
$EDITOR .env       # TLD=smart
./setup.sh         # syncs every stack's .env and the adblock dnsmasq wildcard,
                    # then pick the stacks again to restart them with it
```

The compose labels interpolate `${TLD}` and `cert-watcher.sh` reads `TLD` from
the stack's `.env`, both already synced by the step above. `setup.sh` also
rewrites the TLD portion of `adblock/config/pihole/dnsmasq.d/99-irabelle.conf`'s
`address=`/`local=` lines in place, leaving the LAN address next to it
untouched — that file can't read `${TLD}` itself, since Compose only
interpolates variables inside `compose.yml`, not arbitrary mounted files.
Nothing else needs editing. Old certificates are left on disk on purpose; to
retire the previous names:

```sh
rm traefik/config/certificates/<old-host>.crt traefik/config/certificates/<old-host>.key
traefik/generate_certificates/3-sync-tls-file.sh
```

### Why `.smart`

Chromium and Firefox both decide whether typed text navigates or searches by
checking the TLD against two lists: a handful of RFC-reserved names hardcoded
into the browser (`test`, `example`, `internal`, `local`, plus `invalid` and
`localhost` on Firefox), and the **Public Suffix List / current ICANN root
zone** — i.e. every TLD that is actually delegated today, the same way
`.com` or `.org` are recognized. Outside both lists, a typed host like
`foo.lan` or `foo.ira` gets no "visit" candidate generated at all on Android
Chrome (confirmed directly via `chrome://omnibox`'s debug export during setup)
— it's pure search, every time, on every device, with no workaround short of
always typing a scheme or trailing slash.

`smart` is not on the reserved list, but it *is* a delegated TLD: BMW's `.mini`
and Dell's `.dell` work the same way for the same reason. This can be checked
directly against IANA's published root zone list
(`https://data.iana.org/TLD/tlds-alpha-by-domain.txt`) for any candidate
before relying on it.

**The trade-off, confirmed by live lookup, not assumed:** `.smart` is the
real production TLD of Smart Communications, a Philippine telecom — it is not
dormant. `dig shop.smart` resolves to a live server today, and
`account.smart` / `my.smart` delegate to Smart Communications' own real
nameservers. Locally this is a non-issue: `adblock/config/pihole/dnsmasq.d/99-irabelle.conf`'s
`address=`/`local=` wildcard answers every query under `.smart` before it
leaves the LAN, for any device using this network's resolver. The exposure is
narrower and specific: a device that bypasses that resolver — off this
network, on mobile data, or with secure DNS/DoH pointed at a public
resolver — resolves `.smart` names for real, so a service name that happens
to match something Smart Communications actually runs (`shop`, `account`,
`my`, and likely other customer-portal-shaped words) would reach their real
server instead of failing safely. Service names here (`traefik`, `dockhand`,
`pihole`) don't collide with anything found by live lookup at setup time, but
a new service name should be checked the same way before adding it.

There is no dormant, collision-free option this short: `home.arpa`
([RFC 8375](https://www.rfc-editor.org/rfc/rfc8375)) is the only alternative
with a real collision-proof guarantee (PSL-listed, works with zero
configuration everywhere, including Firefox for Android and Safari), at the
cost of being much longer to type. `.test` is the only *hardcoded* option
short enough to compete, at the cost of reading like a test fixture in logs
and certificates.

See [Name resolution](#name-resolution) for the DNS side.

## Name resolution

Services are published as `<service>.$TLD`, and every one of those names points
at the host running Traefik — Traefik then routes by SNI/`Host()`. One wildcard
is therefore all the DNS you need, and any stack added later is reachable
without touching DNS again.

Point your local resolver at this host. With **Pi-hole** (dnsmasq), add:

```
address=/smart/192.168.1.2
local=/smart/
```

`192.168.1.2` is this host's LAN address. `address=` answers A queries with that
address; `local=` makes dnsmasq authoritative for the zone, so other query types
— notably AAAA, which browsers send first — get a definitive local answer
(NODATA, or NXDOMAIN for names that do not exist) instead of being forwarded
upstream and leaking internal names to a public resolver.

Where the lines go depends on the Pi-hole version:

* **v6** — *Settings → All settings → Miscellaneous → `misc.dnsmasq_lines`*,
  adding the two lines as separate entries. The All settings page only appears
  in Expert mode. The same thing from the shell:

  ```sh
  sudo pihole-FTL --config misc.dnsmasq_lines \
    '["address=/smart/192.168.1.2","local=/smart/"]'
  ```

  The `/etc/dnsmasq.d/` directory is *not* read unless `misc.etc_dnsmasq_d` is
  set to `true` — and don't enable both at once, as the two sets of lines can
  conflict.
* **v5** — a file in `/etc/dnsmasq.d/`, e.g. `/etc/dnsmasq.d/05-smart.conf`.

The **Local DNS Records** page can't do this: it only adds exact A/AAAA records,
so a wildcard there means one entry per service. Saving `misc.dnsmasq_lines`
restarts FTL for you; on v5 run `pihole restartdns`. Then check it:

```sh
dig +short dockhand.smart @192.168.1.2   # → 192.168.1.2
dig AAAA    dockhand.smart @192.168.1.2  # → NODATA (NOERROR, empty) — not forwarded
```

Any dnsmasq behaves the same way, so a router running OpenWrt/DNSMasq can serve
the zone with the same two lines:

```sh
uci add_list dhcp.@dnsmasq[0].address='/smart/192.168.1.2'
uci add_list dhcp.@dnsmasq[0].local='/smart/'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

Failing that, per-client `/etc/hosts` entries work for individual names. Note
that clients which ignore your resolver — hardcoded DNS, Android Private DNS, or
a browser with secure DNS/DoH enabled — will not resolve `*.smart`.

## Host networking

Containers that need a real address on the router's Docker VLAN — Pi-hole,
Unbound — ride a macvlan network on a VLAN interface the host creates. That is
the one part of this setup that needs root, so it lives in its own script:

```sh
cp host.env.example host.env      # optional; every default works without it
sudo ./host-vlan.sh --dry-run     # read the netplan it would write
sudo ./host-vlan.sh --try         # apply, auto-rollback unless you confirm
```

It writes `/etc/netplan/60-docker-vlan.yaml` — the same filename `station` uses
— and creates the macvlan network on top of the VLAN interface
(`Docker.Online`, id 40, 192.168.40.0/24). `sudo ./host-vlan.sh --down` removes
both again.

`./setup.sh` deliberately does not do this. It stays unprivileged, and it now
refuses to start a stack whose compose file wants a macvlan network that does
not exist yet, instead of quietly creating a plain bridge in its place.

**[NETWORK.md](NETWORK.md)** has the address plan, the Pi-hole + Unbound compose
files, the per-service bridge network pattern for isolating containers from each
other, and the router-side steps.

## Certificates

`setup.sh` only creates the root CA
(`1-generate-root-certificates.sh`), once per client; the CA and especially
`root-ca.key` stay out of git.

Service certificates are issued by **`cert-watcher.sh`**, which watches Docker
events, discovers every host Traefik is routing (via the Traefik API, falling
back to container labels) and issues a certificate for any new `*.$TLD`
service through `2-site-certificate.sh`. `3-sync-tls-file.sh` then rewrites
`tls.yml` from the certificates on disk — `tls.yml` is derived, never
hand-edited or appended to.

Run the watcher at boot:

```sh
crontab -e
# @reboot /home/carlos/irabelle-stack/traefik/generate_certificates/cert-watcher.sh
```

Worth knowing on a brand-new checkout: `traefik/config/certificates/` and
`traefik/config/logs/` are not committed (nothing in them belongs in git), and
neither is a bind-mount source, so Docker does not create them. `setup.sh` does,
as you, and the watcher fills them in. Traefik's file provider watches
`config/certificates`, but it builds the certificate list at startup, so restart
it once after the first certificates appear:

```sh
docker compose -f traefik/compose.yml restart
```

### Trusting the CA on a client

```sh
# Debian/Ubuntu
sudo cp traefik/generate_certificates/root-certificates/root-ca.crt \
        /usr/local/share/ca-certificates/irabelle-root.crt
sudo update-ca-certificates

# Fedora/RHEL: /etc/pki/ca-trust/source/anchors + update-ca-trust
# macOS:       security add-trusted-cert -d -r trustRoot \
#                -k /Library/Keychains/System.keychain root-ca.crt
```

Firefox keeps its own store: set `security.enterprise_roots.enabled=true` in
`about:config`, or import the CA under Settings → Privacy & Security →
Certificates.

Service names are resolved as described in [Name resolution](#name-resolution).

## Adding a stack or a service

**[ADDING-A-STACK.md](ADDING-A-STACK.md)** is the step-by-step: the
`compose.yml` template, `.env.example`, where state goes, the authentik login
(OIDC or forward auth), wiring it to the other apps in `integrations.py`, and
deploying it. In short: a directory with a `compose.yml` is a stack, and every
script here picks it up on its own; state goes in its `config/`, it joins
`app-bridge`, it is published as `<name>.<TLD>` behind authentik, and it is
deployed from Dockhand.

## Repository hygiene

Clients run Docker in this checkout, and Docker writes state next to the
Compose files. Everything a client generates is gitignored, so nobody's
`git status` is ever dirty and no private key, token or database can be
committed by accident:

| Ignored | Why |
| --- | --- |
| `.env`, `.env.*` | per-client config; may grow secrets (`.env.example` is committed) |
| `host.env` | host networking for `host-vlan.sh` (`host.env.example` is committed) |
| `**/config/traefik.yml` | per-install static config (`traefik.yml.example` is committed) |
| `**/config/unbound/unbound.conf` | per-install resolver config (`unbound.conf.example` is committed) |
| `**/config/pihole/*` | Pi-hole's database, blocklists and settings (`…/pihole/dnsmasq.d/` stays tracked) |
| `**/config/certificates/*` | leaf certificates, **private keys**, generated `tls.yml` |
| `**/generate_certificates/root-certificates/` | the private root CA |
| `**/config/logs/*` | Traefik's access log keeps request headers (cookies, auth) |
| `**/config/dockhand/*` | `.encryption_key`, sqlite DB, icon cache |
| `**/config/postgresql/*`, `**/config/authentik/data/` | authentik's database (every user and session) and media |
| `dockhand/.api-token` | the Dockhand API token `setup.sh` and `update.sh` use |
| `downloads/` | the media tree `arr`, `books` and `plex` share — data, and potentially huge |
| `**/config/{bazarr,prowlarr,radarr,sonarr,transmission}/*` | each *arr app's database, logs and settings |
| `**/config/{cleanuparr,lingarr,lingarr-db}/*` | Cleanuparr's and Lingarr's settings, Lingarr's MariaDB |
| `**/config/{calibre,calibre-web-automated,shelfmark,kavita,books-glue}/*` | the book pipeline's library metadata, download history and glue state (`books-glue/glue.py` stays tracked) |
| `**/config/plex/*` | Plex's database, metadata and per-client preferences |
| `**/config/searxng/{cache,data}/*` | the search cache and Valkey's dump |
| `**/config/searxng/config/settings.yml` | per-install SearXNG config (`settings.yml.example` is committed) |
| `**/config/{n8n,sandbox-tls}/*` | the workflow/credential database and the sandbox cluster's regenerated mTLS material |
| `pocket-tts2/config/{models,voices}/*` | the TTS model and voice caches |
| `**/config/{homeassistant,homeassistant-db,mosquitto,zigbee2mqtt,esphome,voicebm}/*`, `smarthome/cache/` | Home Assistant's config and history database, MQTT data, Zigbee network, ESPHome devices, VoiceBM's models and recordings; ESPHome's build cache |
| `**/config/{threadfin,warp}/*`, `**/config/streamlink/streams.yaml` | IPTV playlists and buffer, the WARP registration, your stream list (`streams.yaml.example` is committed) |
| `**/config/{mailpit,ollama}/*`, `ai/models/` | the mail store, Ollama's keys and its models |
| `dsh/.dsh-mobile/` | the dsh-mobile checkout `dsh/install.sh` clones to build the plugin into the DSH profile (`dsh/.env` is covered by the `.env` rule) |

The patterns use `**/` so any stack added later is covered without touching
`.gitignore`. Nothing generated is committed and no `.gitkeep` placeholders are
needed: the runtime directories are created by the scripts and containers that
write into them.

The rule behind the list: **tracked files are the ones a `git pull` must be able
to update; anything an install or its owner edits lives outside git** and is
created by `setup.sh` from a committed `.example`. Editing one of those can
never block a pull. A tracked file is expected to stay pristine on a running
install, and if one is modified the pull stops with *"Your local changes to the
following files would be overwritten"* — which is the signal that the file
belongs in this list instead.
