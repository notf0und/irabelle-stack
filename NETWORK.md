# Network layout

Two layers, two jobs. They are not alternatives, and neither replaces the other:

| Layer | Answers | Enforced by |
| --- | --- | --- |
| Docker VLAN / firewall zone | *Can this reach the internet? Can it reach my LAN?* | the router (fw4) |
| Docker network | *Can this container reach that container?* | the host (DOCKER-ISOLATION) |

Keeping them straight matters, because the obvious mistake is expecting a VLAN to
separate two containers. It cannot: everything behind one host reaches the
router through **one switch port**, and same-subnet traffic is switched, never
routed, so fw4 never sees it. A VLAN is a single trust domain.

## Address plan

Mirrors the layout already running on `station`.

| Role | station | carlos |
| --- | --- | --- |
| Physical NIC | `eno1` | `enp1s0` |
| LAN (management) | 192.168.1.2 | 192.168.1.2 (static lease) |
| Docker VLAN interface | `Docker.VLAN`, id **10** | `Docker.Online`, id **40** |
| Host address on it | 192.168.10.2/24 | 192.168.40.2/24 |
| Router gateway | 192.168.10.1 | 192.168.40.1 |
| Macvlan network | `app-macvlan` | `app-macvlan` |
| Pi-hole | 192.168.10.5 | **192.168.40.5** |
| Unbound | 192.168.10.6 | 10.77.40.6 — private bridge, **not** on the VLAN (see §2) |

The third octet follows the VLAN id — the same convention the router uses
(`30` ↔ 192.168.30.x, `40` ↔ 192.168.40.x) — so one id moves everything.

## 1. Host uplink

```sh
cp host.env.example host.env     # optional; every default works without it
sudo ./host-vlan.sh --dry-run    # read the netplan it will write
sudo ./host-vlan.sh --try        # apply, auto-rollback unless you confirm
```

It writes one file, `/etc/netplan/60-docker-vlan.yaml` — the same filename
station uses — and creates the macvlan network:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false        # address yes, default route no
  vlans:
    Docker.Online:
      id: 40
      link: enp1s0
      addresses: [192.168.40.2/24]
      routes:
        - to: default
          via: 192.168.40.1
          metric: 50
```

```sh
docker network create -d macvlan \
  --subnet 192.168.40.0/24 --gateway 192.168.40.1 \
  -o parent=Docker.Online app-macvlan
```

**Why `use-routes: false`** — this is the load-bearing line. The host keeps its
LAN address (management, and the router's static lease), but stops accepting a
default route from the LAN. All egress then has exactly one path: the Docker
VLAN, which lands in the `dockeron` zone — internet, no LAN. Leave it fail-open
(`KEEP_LAN_DEFAULT_ROUTE=1` in `host.env`) and a misconfigured trunk silently
falls back to routing container traffic into the `lan` zone, where it can reach
everything.

Requirements and checks:

- the cable must be in a **trunk port** that tags id 40 — on the client router
  that is `lan1`, which already carries `Docker.Online` (40) and
  `Docker.Offline` (30);
- `sudo ./host-vlan.sh --status` shows the VLAN, the routes and the network;
- `sudo ./host-vlan.sh --down` removes both and re-applies netplan.

## 2. `adblock` — Pi-hole and Unbound

One stack, `adblock/`. Pi-hole is at **192.168.40.5** on the VLAN because LAN
clients query it directly; Unbound is on a **private bridge** (10.77.40.6) and is
reachable only by Pi-hole. Nothing depends on an external resolver and nothing
depends on the host's DNS stack — which is the point of macvlan over host
networking.

```yaml
services:
  unbound:
    image: mvance/unbound:latest
    networks:
      adblock:                                   # private bridge, this stack only
        ipv4_address: 10.77.40.6

  pihole:
    image: pihole/pihole:latest
    env_file: .env
    environment:
      FTLCONF_dns_upstreams: 10.77.40.6        # nothing external
      FTLCONF_dns_listeningMode: all           # gotcha 1
      FTLCONF_misc_etc_dnsmasq_d: "true"       # so the .smart wildcard is read
      FTLCONF_webserver_api_password: ""        # authentik is the login (README)
      FTLCONF_webserver_acl: "-0.0.0.0/0,-[::]/0,+127.0.0.1,+[::1],+${APP_BRIDGE_SUBNET}"
    networks:
      app-macvlan:
        ipv4_address: 192.168.40.5
      app-bridge: {}                           # gotcha 2 — required, not optional
      adblock: {}
    volumes:
      - ./config/pihole:/etc/pihole
      - ./config/pihole/dnsmasq.d/99-irabelle.conf:/etc/dnsmasq.d/99-irabelle.conf:ro

networks:
  app-macvlan: {external: true, driver: macvlan}
  app-bridge:  {external: true, driver: bridge}
  adblock:     {driver: bridge, ipam: {config: [{subnet: 10.77.40.0/24}]}}
```

`adblock/.env` carries `TLD`, `TZ`, `PIHOLE_IP` and `APP_BRIDGE_SUBNET`, and
is gitignored. The UI has no password of its own — `pihole.$TLD` is behind
authentik's forward auth — so the web ACL is what stops 192.168.40.5 from
serving it password-free to the LAN: only `app-bridge`, where Traefik is,
gets in. `setup.sh` fills in that subnet. The `.smart` wildcard lives in
`adblock/config/pihole/dnsmasq.d/99-irabelle.conf` — the same mechanism the station
build uses (`etc_dnsmasq_d = true` plus `address=/.domain/ip` files):

```
address=/.smart/192.168.1.2
local=/.smart/
```

**Both lines are needed.** Since dnsmasq 2.86 an `address=` rule only answers A
and AAAA queries — every other record type for that domain is *forwarded
upstream*. Browsers do query more than A/AAAA (HTTPS/SVCB records), so without
`local=` those lookups leave the box to chase a namespace that will never exist
publicly, and they cannot be answered at all when the uplink is down. Measured
with a 2.9x dnsmasq:

| query | with `local=` | without `local=` |
| --- | --- | --- |
| `A foo.smart` | 192.168.1.2 | 192.168.1.2 |
| `TXT foo.smart` | NOERROR, no answer (local) | forwarded upstream → timeout |

It matters more if the TLD is ever a domain you own, because forwarding leaks
internal hostnames to the resolver upstream. `--address=… --local=…` is the
combination dnsmasq's own man page recommends for exactly this.

**Why Unbound is not on the VLAN.** The `mvance/unbound` image generates its own
config with `access-control: 192.168.0.0/16 allow`, so a VLAN address would make
it a resolver that any device on the LAN could query directly — bypassing
Pi-hole's blocking entirely. Unbound only ever answers Pi-hole, so it gets a
private bridge instead. Nothing on the LAN can reach it, and there is no
`unbound.conf` to maintain. (There is no DNSSEC path to get wrong either: the
image's `auto-trust-anchor-file` is relative to its working directory and it
creates the trust anchor itself.)

**Gotcha 1 — `FTLCONF_dns_listeningMode: all` is mandatory.** The default is
`local`, which answers only queries from its own subnet. LAN clients are on
192.168.1.x asking 192.168.40.5, so with the default they get nothing.

**Gotcha 2 — the `app-bridge` attachment is required, and this is carlos-specific
in the worst way.** Measured on carlos:

| from | to | |
| --- | --- | --- |
| LAN client (via router) | macvlan container | works — unicast to a MAC the switch learned on the host's port |
| carlos (host) | macvlan container | **fails** |
| bridge container (Traefik) | macvlan container | **fails** |
| macvlan sibling | macvlan sibling | works — the kernel forwards it locally |
| carlos (host) | the same container's **bridge** address | works |

macvlan children never talk to their parent interface, and the MT6000 does not
reflect a frame back out the port it arrived on. So Pi-hole must be reachable
two ways: `192.168.40.5` for the LAN, and its bridge address for everything on
the host. Without that, `pihole.$TLD` can never load and carlos cannot query its
own resolver.

The sibling row is what makes the design work: Pi-hole → Unbound at
192.168.40.6 never leaves the host, so Unbound needs no bridge of its own.

**`FTLCONF_misc_etc_dnsmasq_d: "true"`** — Pi-hole v6 does not read
`/etc/dnsmasq.d` unless this is set, and the `.smart` wildcard lives there. If
local names stop resolving, check it under Settings → All settings →
`misc.etc_dnsmasq_d`.

## 3. Everything else: bridge networks, not macvlan

A bridge container inherits the zone of whatever interface carries the host's
default route — with `host-vlan.sh` done, that is `dockeron`. So a plain bridge
container already gets *internet, no LAN*, for free, and keeps Docker's
per-container isolation, which macvlan throws away (macvlan traffic bypasses the
host's iptables entirely).

Give each service its own network and let Traefik be the only multi-homed
container. A star, not a mesh:

```yaml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    networks:
      - ha-net        # traefik + homeassistant only
      - ha-db         # its database only
  homeassistant-db:
    image: postgres:16-alpine
    networks:
      - ha-db
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    networks:
      - media-net     # traefik + the *arr services
      - media-db

networks:
  ha-net: { name: ha-net }
  ha-db:  { name: ha-db, internal: true }     # no gateway, no egress at all
  media-net: { name: media-net }
  media-db:  { name: media-db, internal: true }
```

Traefik joins `ha-net` and `media-net` (and keeps its own). A compromised
container on `media-net` cannot address HA at all — that is the isolation you
were after, and it comes from the Docker network, not the VLAN.

Two things this does **not** cover:

- **HA reaching Sonarr/Radarr.** If it is HTTP, route it through Traefik and
  don't share a network. Guard the sensitive routes so Traefik's shared ingress
  isn't a hole:

  ```yaml
  traefik.http.routers.sonarr-https.middlewares: sonarr-callers
  traefik.http.middlewares.sonarr-callers.ipallowlist.sourcerange: 172.28.0.2/32
  ```

  Only works with a clean source IP, which means Traefik on the macvlan (or the
  LAN), not behind the host's NAT.

- **Non-HTTP integrations** (MQTT, RTSP, Syncthing, database ports). For those,
  add one small network containing exactly the two members involved — for
  example `ha-mqtt` with `homeassistant` and `mosquitto` — and nothing else.

**Do not run HA with `network_mode: host`.** It is the documented way to get
mDNS/SSDP autodiscovery, and it puts HA on the host's stack: not on any Docker
network, not placeable on a VLAN, invisible to every control above.

## 4. Router side

On the client router, after the host side is up:

1. **Trunk** — the port carlos uses must tag id 40 (and 30 if you want it). On
   the reference router `lan1` already does.
2. **Hand out Pi-hole as the resolver:**
   ```sh
   uci add_list dhcp.lan.dhcp_option='6,192.168.40.5'
   uci commit dhcp && /etc/init.d/dnsmasq restart
   ```
   `lan → dockeron` is already `X` in the firewall matrix, so clients can reach
   it on every port without a new rule.
3. **No static lease is needed** for Pi-hole or Unbound: their addresses come
   from `ipv4_address:` in compose, not DHCP. Docker assigns the macvlan MAC, so
   a MAC-pinned lease would break on recreate anyway — pin `mac_address:` in
   compose if you ever need one.
4. **Rename record** — whatever *.$TLD names you publish must live in **this**
   Pi-hole, pointing at wherever Traefik is reachable. Today that record is in
   your personal Pi-hole pointing at 192.168.1.2; that is the piece that breaks
   the day the box is delivered.
5. **Optional** — if Traefik (or anything else) sits in `Docker.Offline` (30), it
   cannot reach Pi-hole on 40, because `dockeroff → dockeron` is blocked. If you
   want offline containers to resolve names without granting them internet, add
   a single rule for `dockeroff → dockeron`, port 53:
   ```sh
   uci add firewall rule
   uci set firewall.@rule[-1].name='Allow-Docker-Offline-DNS'
   uci set firewall.@rule[-1].src='dockeroff'
   uci set firewall.@rule[-1].dest='dockeron'
   uci set firewall.@rule[-1].proto='tcpudp'
   uci set firewall.@rule[-1].dest_port='53'
   uci set firewall.@rule[-1].target='ACCEPT'
   uci commit firewall && /etc/init.d/firewall reload
   ```

## 5. Gotchas worth remembering

- **A VLAN is not a container boundary.** Two macvlan containers on the same
  VLAN reach each other on every port, regardless of Docker networks.
- **`internal: true` beats `Docker.Offline` for a single container** that must
  not reach the internet: it removes the default route outright and is
  per-container, where a VLAN cuts off a whole segment.
- **Macvlan containers can't be reached by name.** Docker's embedded DNS does
  not cover macvlan endpoints; address them by IP.
- **The host cannot reach its own macvlan containers — on carlos.** Measured:
  `carlos -> 192.168.40.x` fails, `bridge container -> 192.168.40.x` fails,
  siblings work. It works on station (`ping 192.168.10.5`, 1.0ms) because that
  home switch reflects the frame back out the port it came in on; the MT6000
  does not. Never assume it works — test it, and give any container that needs
  on-host access a bridge network too.
- **An external network needs a declared `driver:`.** `docker compose config`
  emits nothing for an external network without one, and `setup.sh` will refuse
  rather than guess — guessing "bridge" is how a macvlan network gets created
  with the wrong connectivity.
- **`--down` refuses while containers are attached.** Stop the stacks first.

