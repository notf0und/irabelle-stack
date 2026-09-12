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
| Unbound | 192.168.10.6 | **192.168.40.6** |

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

## 2. Pi-hole and Unbound

Two stacks, `pihole/` and `unbound/`, both on the macvlan so they are real hosts
on the VLAN. Pi-hole needs a real address because LAN clients query it directly;
Unbound only ever answers Pi-hole.

`unbound/compose.yml`:

```yaml
services:
  unbound:
    image: mvance/unbound:latest
    container_name: unbound
    restart: unless-stopped
    networks:
      app-macvlan:
        ipv4_address: 192.168.40.6

networks:
  app-macvlan:
    external: true
```

`pihole/compose.yml`:

```yaml
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    hostname: pihole
    restart: unless-stopped
    env_file: .env
    environment:
      TZ: ${TZ}
      FTLCONF_dns_upstreams: 192.168.40.6     # the local Unbound, nothing external
      FTLCONF_dns_listeningMode: all          # see gotcha 1
      FTLCONF_webserver_api_password: ${PIHOLE_PASSWORD:?set PIHOLE_PASSWORD in .env}
    networks:
      app-macvlan:
        ipv4_address: 192.168.40.5
      app-bridge: {}                          # so Traefik can publish the UI
    volumes:
      - ./config/etc-pihole:/etc/pihole
    cap_add: [NET_ADMIN]

networks:
  app-macvlan:
    external: true
  app-bridge:
    external: true
```

`PIHOLE_PASSWORD` goes in `pihole/.env`, which is gitignored.

**Gotcha 1 — `FTLCONF_dns_listeningMode: all` is mandatory here.** The default
is `local`, which answers only queries from its own subnet. Your LAN clients are
on 192.168.1.x asking 192.168.40.5, so with the default they get nothing.

**Gotcha 2 — bridge containers can't simply be pointed at the macvlan address.**
A bridge container's packet to 192.168.40.5 leaves with a 172.x source; Pi-hole
replies via *its* default route, which is the router at 192.168.40.1, and the
router has no route back to 172.x — asymmetric, and it fails. Two ways out:

- attach Pi-hole to a bridge network too (as above) and point on-host consumers
  at Pi-hole's bridge address; or
- set the daemon-wide resolver in `/etc/docker/daemon.json`
  (`"dns": ["192.168.40.5"]`), so the query is made by the host over the VLAN,
  where the reply path is symmetric.

For containers, prefer the first: it is explicit per stack.

**Unbound's placement** is the one place I would not copy station exactly. It has
no reason to hold a VLAN address — a private bridge shared with Pi-hole would do
the same job without occupying a lease. Macvlan is what station does, so it is
what is shown here; either works, since both are on `app-macvlan` and reach each
other directly.

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
- **The host reaches its own macvlan containers fine here** (measured on
  station: `ping 192.168.10.5` from the host, 0% loss). The usual "macvlan can't
  talk to its host" warning does not apply when the parent is a VLAN interface
  the host also has an address on.
- **`--down` refuses while containers are attached.** Stop the stacks first.
