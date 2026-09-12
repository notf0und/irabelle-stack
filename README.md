# irabelle-stack

A small self-hosted stack — [Traefik](https://traefik.io) as the HTTPS
front door and [dockhand](https://github.com/fnsys/dockhand) as the Docker
dashboard — that publishes services under an internal domain
(`traefik.test`, `dockhand.test`, ...) with locally-signed certificates.

```
.
├── .env.example                     # template for the per-client .env files
├── setup.sh                         # bootstrap: .env copies + root CA + pick stacks
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
└── dockhand/
    ├── compose.yml                  # reads ${TLD} from .env
    └── config/dockhand/             # runtime state, not in git
```

Every immediate subdirectory that contains a `compose.yml` is a **stack**.
`setup.sh` discovers them, so adding a stack means adding a directory — no
script changes. A stack may also ship its own `.env.example` (see
[Configuration](#configuration)).

## Quickstart

```sh
git clone <this repo> irabelle-stack
cd irabelle-stack
./setup.sh
```

`setup.sh` will:

1. create `.env` from `.env.example` if the repo root has none,
2. copy that `.env` into every stack that does not have its own yet — except a
   stack that ships its own `.env.example`, which is used instead,
3. generate the root CA for any stack that ships
   `generate_certificates/1-generate-root-certificates.sh`,
4. show a menu of the stacks it found and start the ones you pick.

Services come up as `<service>.test`; see
[Name resolution](#name-resolution) to make those names resolve across your LAN.

The menu is tick-box style, **everything unticked by default** — space
toggles, up/down moves, `a` selects all, `n` clears, enter confirms, `q`
cancels:

```
Select the stacks to start
  space = toggle   up/down = move   a = all   n = none   enter = confirm   q = cancel

> [ ] traefik
  [ ] dockhand
```

Non-interactive equivalents:

```sh
./setup.sh --list                     # just print the stacks found
./setup.sh --stacks traefik,dockhand  # start these, no menu
./setup.sh --no-start                 # prepare .env files and root CA only
```

`setup.sh` never creates directories, never issues service certificates and
never overwrites an existing `.env`, root CA or certificate. It is safe to
re-run.

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
one, `setup.sh` says so instead of silently starting services under two
different domains. To re-copy the template into one stack:

```sh
rm traefik/.env && ./setup.sh --no-start
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
itself, so `setup.sh` creates `app-bridge` before starting anything that
expects it.

## Repository hygiene

Clients run Docker in this checkout, and Docker writes state next to the
Compose files. Everything a client generates is gitignored, so nobody's
`git status` is ever dirty and no private key, token or database can be
committed by accident:

| Ignored | Why |
| --- | --- |
| `.env`, `.env.*` | per-client config; may grow secrets (`.env.example` is committed) |
| `**/config/certificates/*` | leaf certificates, **private keys**, generated `tls.yml` |
| `**/generate_certificates/root-certificates/` | the private root CA |
| `**/config/logs/*` | access log keeps request headers (cookies, auth) |
| `**/config/dockhand/*` | `.encryption_key`, sqlite DB, icon cache |

The patterns use `**/` so any stack added later is covered without touching
`.gitignore`. Nothing generated is committed and no `.gitkeep` placeholders are
needed: the runtime directories are created by the scripts and containers that
write into them.
