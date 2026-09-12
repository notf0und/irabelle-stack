# irabelle-stack

A small self-hosted stack — [Traefik](https://traefik.io) as the HTTPS
front door and [dockhand](https://github.com/fnsys/dockhand) as the Docker
dashboard — that publishes services under an internal domain
(`traefik.test`, `dockhand.test`, ...) with locally-signed certificates.

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
│   │   ├── traefik.yml              # static config (providers, entrypoints)
│   │   ├── certificates/            # generated at runtime, not in git
│   │   └── logs/                    # generated at runtime, not in git
│   └── generate_certificates/
│       ├── 1-generate-root-certificates.sh
│       ├── 2-site-certificate.sh
│       ├── 3-sync-tls-file.sh
│       └── cert-watcher.sh
├── dockhand/
│   ├── compose.yml                  # reads ${TLD} from .env
│   └── config/dockhand/             # runtime state, not in git
└── adblock/
    ├── compose.yml                  # Pi-hole + Unbound, on the Docker VLAN
    ├── .env.example                 # TLD, TZ, PIHOLE_PASSWORD, static IPs
    └── config/
        ├── dnsmasq.d/99-irabelle.conf   # the *.$TLD wildcard
        └── etc-pihole/                  # runtime state, not in git
```

Every immediate subdirectory that contains a `compose.yml` is a **stack**.
`setup.sh` discovers them, so adding a stack means adding a directory — no
script changes. A stack may also ship its own `.env.example` (see
[Configuration](#configuration)).

`adblock` is the LAN's DNS: Pi-hole at 192.168.40.5 on the Docker VLAN, with a
local recursive Unbound on a private bridge behind it. It needs the host VLAN
from `host-vlan.sh` first — see [NETWORK.md](NETWORK.md).

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
4. start **Dockhand** and print the URL to open — as a clickable hyperlink, so
   it works over SSH; it only tries to launch a browser itself when the host
   has a display to draw on;
5. give Dockhand the two things that are not in git — the local environment it
   needs, and this checkout as an external stack path — so a fresh clone is
   usable without clicking through onboarding.

It does **not** start any other stack. From there you deploy what you want in
Dockhand — `traefik` first, since every other service is published through it,
so the `https://<service>.<TLD>` names only work once it is running.

Because Dockhand's own `dockhand.<TLD>` name needs Traefik, its port is
published directly (`DOCKHAND_PORT`, default 3000) — that URL is the
chicken-and-egg escape hatch. It bypasses Traefik's TLS, so **turn on
authentication**; `setup.sh` warns if it is still off.

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

### Deploying through Dockhand (or any git-based tool)

These stacks work from a git-based deploy, with one difference: `.env` is
gitignored, so a fresh checkout does not have one and there is nothing for
Compose to interpolate. The values come from the tool instead — in Dockhand,
the stack's **Environment variables** panel:

| Variable | Value |
| --- | --- |
| `TLD` | `test` |
| `PIHOLE_PASSWORD` | the Pi-hole admin password |
| `PIHOLE_IP` | `192.168.40.5` |

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
point it elsewhere, and `DOCKHAND_TOKEN` to a bearer token once Dockhand
authentication is enabled.

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

`TLD` is shared by every stack. If a stack's `.env` disagrees with the root
one, `setup.sh` says so instead of silently deploying services under two
different domains. To re-copy the template into one stack:

```sh
cp .env traefik/.env     # a stack with its own .env.example takes that instead
```

### Renaming the internal domain

This is also how an existing install moves off an earlier default (`local`, then
`internal`). Edit `TLD` in each stack's `.env` (and in the root `.env` so new
stacks inherit it):

```sh
$EDITOR .env traefik/.env dockhand/.env     # TLD=test
./setup.sh                                  # re-runs, then pick the stacks again
```

The compose labels interpolate `${TLD}` and `cert-watcher.sh` reads `TLD` from
the stack's `.env`, so nothing else needs editing. Old certificates are left on
disk on purpose; to retire the previous names:

```sh
rm traefik/config/certificates/<old-host>.crt traefik/config/certificates/<old-host>.key
traefik/generate_certificates/3-sync-tls-file.sh
```

### Why `.test`

`test` is the shortest namespace that needs no client-side configuration:

* It is reserved by [RFC 2606](https://www.rfc-editor.org/rfc/rfc2606) and
  [RFC 6761](https://www.rfc-editor.org/rfc/rfc6761), so it can never be
  delegated and collide with a real domain.
* Browsers have recognized it as a URL for years — Chromium hardcodes `test` in
  its omnibox fixup and Firefox ships
  `browser.fixup.domainsuffixwhitelist.test=true` — so `traefik.test` typed
  without a scheme navigates instead of going to a search engine.

The cost is the name itself: a `.test` domain reads as a test fixture in logs
and certificates. `.internal` is the same mechanism with a more deliberate ring,
but its browser whitelist entries are newer (2024+), so old, un-updated browsers
may still search for it. `home.arpa`
([RFC 8375](https://www.rfc-editor.org/rfc/rfc8375)) is longer but sits in the
Public Suffix List, so it also works on clients that hardcode nothing — Firefox
for Android, Safari and other PSL-aware tools.

Avoid `.local` (reserved for multicast DNS,
[RFC 6762](https://www.rfc-editor.org/rfc/rfc6762): phones, macOS and Windows
hand `*.local` to mDNS and ignore the unicast DNS answer) and `.lan` or made-up
names like `.ira`, which are neither special-use nor in either browser's fixup
list, so typing `service.lan` with no scheme searches for it instead of
navigating.

See [Name resolution](#name-resolution) for the DNS side.

## Name resolution

Services are published as `<service>.$TLD`, and every one of those names points
at the host running Traefik — Traefik then routes by SNI/`Host()`. One wildcard
is therefore all the DNS you need, and any stack added later is reachable
without touching DNS again.

Point your local resolver at this host. With **Pi-hole** (dnsmasq), add:

```
address=/test/192.168.1.2
local=/test/
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
    '["address=/test/192.168.1.2","local=/test/"]'
  ```

  The `/etc/dnsmasq.d/` directory is *not* read unless `misc.etc_dnsmasq_d` is
  set to `true` — and don't enable both at once, as the two sets of lines can
  conflict.
* **v5** — a file in `/etc/dnsmasq.d/`, e.g. `/etc/dnsmasq.d/05-test.conf`.

The **Local DNS Records** page can't do this: it only adds exact A/AAAA records,
so a wildcard there means one entry per service. Saving `misc.dnsmasq_lines`
restarts FTL for you; on v5 run `pihole restartdns`. Then check it:

```sh
dig +short dockhand.test @192.168.1.2   # → 192.168.1.2
dig AAAA    dockhand.test @192.168.1.2  # → NODATA (NOERROR, empty) — not forwarded
```

Any dnsmasq behaves the same way, so a router running OpenWrt/DNSMasq can serve
the zone with the same two lines:

```sh
uci add_list dhcp.@dnsmasq[0].address='/test/192.168.1.2'
uci add_list dhcp.@dnsmasq[0].local='/test/'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

Failing that, per-client `/etc/hosts` entries work for individual names. Note
that clients which ignore your resolver — hardcoded DNS, Android Private DNS, or
a browser with secure DNS/DoH enabled — will not resolve `*.test`.

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
they are not bind-mount targets, so Docker will not create them. The watcher
creates both when it runs. If Traefik was started before they existed it will
have logged and ignored the missing directory — restart it once after the first
certificates appear:

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
| `**/config/certificates/*` | leaf certificates, **private keys**, generated `tls.yml` |
| `**/generate_certificates/root-certificates/` | the private root CA |
| `**/config/logs/*` | access log keeps request headers (cookies, auth) |
| `**/config/dockhand/*` | `.encryption_key`, sqlite DB, icon cache |

The patterns use `**/` so any stack added later is covered without touching
`.gitignore`. Nothing generated is committed and no `.gitkeep` placeholders are
needed: the runtime directories are created by the scripts and containers that
write into them.
