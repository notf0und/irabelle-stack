# irabelle-stack

A small self-hosted stack — [Traefik](https://traefik.io) as the HTTPS
front door, [dockhand](https://github.com/fnsys/dockhand) as the Docker
dashboard and [authentik](https://goauthentik.io) as the one login for both
and for Pi-hole — that publishes services under an internal domain
(`traefik.smart`, `dockhand.smart`, ...) with locally-signed certificates.

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
└── adblock/
    ├── compose.yml                  # Pi-hole + Unbound, on the Docker VLAN
    ├── .env.example                 # TLD, TZ, static IPs
    └── config/                          # one directory per service
        ├── pihole/                      #   → /etc/pihole
        │   ├── dnsmasq.d/99-irabelle.conf   # the *.$TLD wildcard
        │   └── (database, blocklists — runtime state, not in git)
        └── unbound/
            ├── unbound.conf.example     # recursive resolver; setup.sh copies it
            └── unbound.conf             # your copy — not in git
```

In a stack with more than one service, each service keeps its config and state
in `{stack}/config/{service}/` — `adblock` has `config/pihole/` (which *is* its
`/etc/pihole`) and `config/unbound/`. A single-service stack keeps its config
directly under `{stack}/config/`.

Every immediate subdirectory that contains a `compose.yml` is a **stack**.
`setup.sh` discovers them, so adding a stack means adding a directory — no
script changes. A stack may also ship its own `.env.example` (see
[Configuration](#configuration)).

`adblock` is the LAN's DNS: Pi-hole at 192.168.40.5 on the Docker VLAN, with a
local recursive Unbound on a private bridge behind it. It needs the host VLAN
from `host-vlan.sh` first — see [NETWORK.md](NETWORK.md).

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
3. generate the root CA behind the `*.$TLD` certificates;
4. start **traefik**, and any other stack whose networks are already in
   place — a stack needing `app-macvlan` (adblock) only starts once
   `host-vlan.sh` has already created it, otherwise it's left for you to
   deploy once that's done. This is what makes `https://<service>.<TLD>`
   work right after this script finishes rather than only after a manual
   deploy;
5. start **Dockhand**;
6. give Dockhand the things that are not in git — a local environment named
   **Irabelle** (timezone from `.env`'s `TZ`, scheduled updates applied
   automatically, automatic image pruning, version-tag checks and selfh.st
   icons all on), and this checkout as an external stack path — so a fresh
   clone is usable without clicking through onboarding. This baseline is
   applied once, only when Dockhand's own database is empty (a fresh
   install); it never overwrites a setting you change afterward in
   Dockhand's UI, the same way an existing `.env` is left alone;
7. set up **single sign-on** — it asks once for a username (your login for
   authentik, Dockhand and Pi-hole) and generates the password, then makes
   that the Dockhand login too and switches Dockhand's authentication on.
   See [Single sign-on](#single-sign-on-authentik);
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

Any stack added later than the ones above is still deployed by hand, from
Dockhand's UI.

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
`.env`, root CA or certificate. It is safe to re-run. The only directories it
creates are the two runtime ones a container and the watcher write into —
`traefik/config/logs` and `traefik/config/certificates` — because Docker would
otherwise invent `logs/` as root, and a root-owned `logs/` is what made the
certificate watcher look broken: it could not write its own log, and the
failing write aborted it under `set -e`. To deploy by hand instead, it is just
compose:

```sh
docker compose -f traefik/compose.yml up -d
```

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
* It then puts a **default ACL** on the directories containers write into
  (`adblock/config/pihole`, `dockhand/config/dockhand`,
  `traefik/config/logs`). New files inherit it, new subdirectories inherit it
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

`env_file` is declared optional in `adblock/compose.yml` for exactly this
reason, so a missing `.env` is not an error, and Pi-hole is configured entirely
from those panel values. The same variables in `adblock/.env` (via `setup.sh`)
work identically for the CLI path — both at once is fine, the file wins.

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
  for Dockhand, and a proxy provider for Pi-hole. Both applications are bound
  to `authentik Admins`, so a user added later for something else gets into
  neither. Edit the blueprint, not the UI, for anything it defines.
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

To put another service behind the login the same way, add
`authentik@docker` to its router's middlewares, then add a `forward_single`
proxy provider and application for it to the blueprint — and the provider
to the embedded outpost's list there.

authentik also always has its own built-in `akadmin` account. You do not use
it, but it is given a generated password (`AUTHENTIK_BOOTSTRAP_PASSWORD`),
because an `akadmin` without one leaves authentik's first-run setup page open
to anyone on the LAN.

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

**A new stack** is a directory with a `compose.yml` and (optionally) its own
`.env`, copied from the root one by `setup.sh`. Join the `app-bridge` network
and publish routers under `${TLD}`:

```yaml
services:
  myservice:
    image: example/myservice
    networks: [app-bridge]
    labels:
      traefik.enable: true
      traefik.http.routers.myservice.rule: Host("myservice.${TLD}")
      traefik.http.routers.myservice.entrypoints: web
      traefik.http.routers.myservice.middlewares: myservice
      traefik.http.middlewares.myservice.redirectScheme.scheme: https
      traefik.http.routers.myservice-https.rule: Host("myservice.${TLD}")
      traefik.http.routers.myservice-https.entrypoints: websecure
      traefik.http.routers.myservice-https.tls: true

networks:
  app-bridge:
    external: true
```

`cert-watcher.sh` notices the new container and issues its certificate within a
few seconds. A stack that declares `external: true` cannot create the network
itself, so `setup.sh` creates a plain bridge network before starting anything
that expects it. A **macvlan** network is different — that one needs the host
VLAN and is created by `host-vlan.sh`, so `setup.sh` stops with an instruction
rather than substituting a bridge.

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
