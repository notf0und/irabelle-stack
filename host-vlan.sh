#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# host-vlan.sh — give this host a Docker VLAN uplink, and the macvlan network
# containers ride on.
#
#   sudo ./host-vlan.sh              create/refresh the VLAN and the network
#   sudo ./host-vlan.sh --try        same, but `netplan try` (auto-rolls back
#                                    if you do not confirm within 120s)
#   sudo ./host-vlan.sh --dry-run    print everything, change nothing
#   sudo ./host-vlan.sh --status     show what is configured right now
#   sudo ./host-vlan.sh --down       remove both again
#
# This is the *host* half of the setup. ./setup.sh stays unprivileged and only
# deals with the stacks; this script is the only thing here that needs root.
#
# It mirrors the layout already running on `station`:
#
#   station:  eno1  + Docker.VLAN    (802.1Q id 10) -> 192.168.10.2/24
#   here:     <nic> + Docker.Online  (802.1Q id 40) -> 192.168.40.2/24
#   and the matching macvlan network `app-macvlan` on that VLAN's parent.
#
# It writes exactly one netplan file — /etc/netplan/60-docker-vlan.yaml, the
# same filename station uses — and creates/reuses one docker network. Nothing
# else on the host is touched, and --down puts it back.
#
# Configuration comes from ./host.env (see host.env.example); command line
# options win over it.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO_DIR"

NETPLAN_FILE=${NETPLAN_FILE:-/etc/netplan/60-docker-vlan.yaml}
MODE=apply

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo ./host-vlan.sh [options]

  --dry-run        show the netplan file and commands, change nothing
  --try            apply with `netplan try` (rolls back unless confirmed)
  --network-only   create just the docker macvlan network (no root needed)
  --down           remove the VLAN file and the docker network
  --status         print current state (no root needed)

  --nic NAME       host NIC carrying the VLAN      (default: default-route NIC)
  --vlan-id N      802.1Q id                       (default: 40)
  --vlan-name NAME interface name                  (default: Docker.Online)
  --address CIDR   address on the VLAN             (default: 192.168.<id>.2/24)
  --gateway IP     gateway on the VLAN             (default: 192.168.<id>.1)
  --network NAME   docker macvlan network name     (default: app-macvlan)
  -h, --help       this text

Values are also read from ./host.env (host.env.example is the template).
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --try) MODE=try ;;
    --network-only) MODE=network ;;
    --down) MODE=down ;;
    --status) MODE=status ;;
    --nic) shift; HOST_NIC=${1:?--nic needs a value} ;;
    --vlan-id) shift; DOCKER_VLAN_ID=${1:?--vlan-id needs a value} ;;
    --vlan-name) shift; DOCKER_VLAN_NAME=${1:?--vlan-name needs a value} ;;
    --address) shift; DOCKER_VLAN_ADDRESS=${1:?--address needs a value} ;;
    --gateway) shift; DOCKER_VLAN_GATEWAY=${1:?--gateway needs a value} ;;
    --network) shift; DOCKER_MACVLAN_NETWORK=${1:?--network needs a value} ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

# --- configuration -----------------------------------------------------------
# Host networking lives in its own file on purpose: .env is copied into every
# stack and handed to containers via env_file, and host interface names have no
# business inside a container.
if [ -f ./host.env ]; then
  HOST_ENV=./host.env
else
  HOST_ENV=''
fi
if [ -n "$HOST_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$HOST_ENV"
  set +a
fi

DOCKER_VLAN_ID=${DOCKER_VLAN_ID:-40}
DOCKER_VLAN_NAME=${DOCKER_VLAN_NAME:-Docker.Online}
DOCKER_VLAN_ADDRESS=${DOCKER_VLAN_ADDRESS:-192.168.${DOCKER_VLAN_ID}.2/24}
DOCKER_VLAN_GATEWAY=${DOCKER_VLAN_GATEWAY:-192.168.${DOCKER_VLAN_ID}.1}
DOCKER_VLAN_SUBNET=${DOCKER_VLAN_SUBNET:-192.168.${DOCKER_VLAN_ID}.0/24}
DOCKER_MACVLAN_NETWORK=${DOCKER_MACVLAN_NETWORK:-app-macvlan}
KEEP_LAN_DEFAULT_ROUTE=${KEEP_LAN_DEFAULT_ROUTE:-0}

# Which NIC carries the VLAN.
#
# "The interface on the default route" is only a safe answer the *first* time:
# once this script has run, the VLAN's own static default route (metric 50)
# wins, so the default route points at the VLAN itself. Asking an existing VLAN
# interface for its parent is authoritative, so try that first and only fall
# back to the default route when the VLAN does not exist yet.
vlan_parent() {
  ip -o link show "$DOCKER_VLAN_NAME" 2>/dev/null \
    | sed -n 's/.*@\([^:@]*\)[:@].*/\1/p' | head -1
}
default_route_nic() {
  ip -4 route show default 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

if [ -z "${HOST_NIC:-}" ]; then
  HOST_NIC=$(vlan_parent)
  if [ -z "$HOST_NIC" ]; then
    HOST_NIC=$(default_route_nic)
    [ "$HOST_NIC" = "$DOCKER_VLAN_NAME" ] && HOST_NIC=$(vlan_parent)
  fi
else
  HOST_NIC_EXPLICIT=1
fi
[ -n "${HOST_NIC:-}" ] || die "cannot detect the host NIC — pass --nic"
[ "$HOST_NIC" != "$DOCKER_VLAN_NAME" ] \
  || die "host NIC resolved to the VLAN itself ($DOCKER_VLAN_NAME) — pass --nic explicitly"
case "$HOST_NIC" in
  wl*)
    [ -n "${HOST_NIC_EXPLICIT:-}" ] \
      || warn "auto-detected NIC '$HOST_NIC' is wireless — set HOST_NIC in host.env if that is wrong"
    ;;
esac

case "$DOCKER_VLAN_ID" in
  ''|*[!0-9]*) die "VLAN id must be a number, got '$DOCKER_VLAN_ID'" ;;
esac
{ [ "$DOCKER_VLAN_ID" -ge 1 ] && [ "$DOCKER_VLAN_ID" -le 4094 ]; } \
  || die "VLAN id must be 1-4094, got $DOCKER_VLAN_ID"
[ -d "/sys/class/net/$HOST_NIC" ] || die "NIC '$HOST_NIC' does not exist on this host"

vlan_iface_ip() { printf '%s' "${DOCKER_VLAN_ADDRESS%%/*}"; }

# --- netplan document --------------------------------------------------------
netplan_body() {
  cat <<EOF
# Written by irabelle-stack/host-vlan.sh — edit that script, not this file.
# The Docker VLAN uplink, mirroring the layout used on \`station\`.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${HOST_NIC}:
      dhcp4: true
EOF
  if [ "$KEEP_LAN_DEFAULT_ROUTE" != 1 ]; then
    cat <<EOF
      dhcp4-overrides:
        # Keep the LAN address — that is management access and the router's
        # static lease — but do not accept a default route from the LAN.
        # Container egress must land in the $DOCKER_VLAN_NAME zone, never in
        # the lan zone. Set KEEP_LAN_DEFAULT_ROUTE=1 in host.env if you would
        # rather have a fail-open fallback.
        use-routes: false
EOF
  fi
  cat <<EOF
  vlans:
    ${DOCKER_VLAN_NAME}:
      id: ${DOCKER_VLAN_ID}
      link: ${HOST_NIC}
      addresses:
        - ${DOCKER_VLAN_ADDRESS}
      routes:
        - to: default
          via: ${DOCKER_VLAN_GATEWAY}
          metric: 50
EOF
}

# --- status ------------------------------------------------------------------
do_status() {
  say "host NIC ($HOST_NIC)"
  ip -br addr show "$HOST_NIC" 2>/dev/null || note "not present"

  say "VLAN interface ($DOCKER_VLAN_NAME, id $DOCKER_VLAN_ID)"
  if ip link show "$DOCKER_VLAN_NAME" >/dev/null 2>&1; then
    ip -d link show "$DOCKER_VLAN_NAME" | sed -n '2p'
    ip -br addr show "$DOCKER_VLAN_NAME"
  else
    note "not present"
  fi

  say "default route"
  ip route show default || true

  say "macvlan network ($DOCKER_MACVLAN_NETWORK)"
  docker network inspect "$DOCKER_MACVLAN_NETWORK" \
    --format '    driver={{.Driver}} parent={{index .Options "parent"}} subnet={{range .IPAM.Config}}{{.Subnet}} gateway={{.Gateway}}{{end}}' \
    2>/dev/null || note "not present"

  say "netplan file"
  if [ -f "$NETPLAN_FILE" ]; then
    ls -l "$NETPLAN_FILE"
  else
    note "$NETPLAN_FILE not present"
  fi
}

# --- down --------------------------------------------------------------------
do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root: sudo $0 --down"

  if docker network inspect "$DOCKER_MACVLAN_NETWORK" >/dev/null 2>&1; then
    local attached
    attached=$(docker network inspect "$DOCKER_MACVLAN_NETWORK" --format '{{len .Containers}}')
    [ "$attached" = 0 ] \
      || die "$attached container(s) are still attached to $DOCKER_MACVLAN_NETWORK — stop them first"
    docker network rm "$DOCKER_MACVLAN_NETWORK" >/dev/null
    note "removed docker network $DOCKER_MACVLAN_NETWORK"
  else
    note "docker network $DOCKER_MACVLAN_NETWORK not present"
  fi

  if [ -f "$NETPLAN_FILE" ]; then
    rm -f "$NETPLAN_FILE"
    netplan generate
    netplan apply
    note "removed $NETPLAN_FILE and re-applied netplan"
  else
    note "$NETPLAN_FILE not present"
  fi

  note "the LAN keeps whatever default route your other netplan files define"
}

# --- docker network ----------------------------------------------------------
# Split out of do_apply so it can be run on its own (--network-only). It needs
# no root, and it is the step that goes missing if the privileged half is
# interrupted — which then looks like a mysterious "network not found" much
# later.
ensure_network() {
  say "docker network ($DOCKER_MACVLAN_NETWORK on $DOCKER_VLAN_NAME)"

  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found on PATH — create it by hand with:"
    note "docker network create -d macvlan --subnet $DOCKER_VLAN_SUBNET \\"
    note "    --gateway $DOCKER_VLAN_GATEWAY -o parent=$DOCKER_VLAN_NAME $DOCKER_MACVLAN_NETWORK"
    return 1
  fi
  if ! ip link show "$DOCKER_VLAN_NAME" >/dev/null 2>&1; then
    warn "$DOCKER_VLAN_NAME does not exist yet — run this script without --network-only first"
    return 1
  fi

  if docker network inspect "$DOCKER_MACVLAN_NETWORK" >/dev/null 2>&1; then
    local parent
    parent=$(docker network inspect "$DOCKER_MACVLAN_NETWORK" --format '{{index .Options "parent"}}')
    if [ "$parent" = "$DOCKER_VLAN_NAME" ]; then
      note "$DOCKER_MACVLAN_NETWORK already exists (parent $parent) — kept"
      return 0
    fi
    warn "$DOCKER_MACVLAN_NETWORK exists but has parent '$parent', expected '$DOCKER_VLAN_NAME'"
    return 1
  fi

  docker network create -d macvlan \
    --subnet "$DOCKER_VLAN_SUBNET" \
    --gateway "$DOCKER_VLAN_GATEWAY" \
    -o parent="$DOCKER_VLAN_NAME" \
    "$DOCKER_MACVLAN_NETWORK" >/dev/null
  note "created macvlan network $DOCKER_MACVLAN_NETWORK on $DOCKER_VLAN_NAME"
}

# --- apply -------------------------------------------------------------------
do_apply() {
  local body backup='' i
  body=$(netplan_body)

  if [ "$MODE" = dry ]; then
    say "would write $NETPLAN_FILE"
    printf '%s\n' "$body" | sed 's/^/    /'
    say "would run"
    note "netplan generate && netplan apply"
    note "docker network create -d macvlan --subnet $DOCKER_VLAN_SUBNET \\"
    note "    --gateway $DOCKER_VLAN_GATEWAY -o parent=$DOCKER_VLAN_NAME $DOCKER_MACVLAN_NETWORK"
    return 0
  fi

  [ "$(id -u)" = 0 ] || die "must run as root: sudo $0"
  command -v netplan >/dev/null 2>&1 \
    || die "netplan not found — this script expects a netplan/networkd host"

  local need_apply=1
  say "netplan"
  if [ -f "$NETPLAN_FILE" ] && diff -q <(printf '%s\n' "$body") "$NETPLAN_FILE" >/dev/null 2>&1; then
    note "$NETPLAN_FILE already correct"
    if ip -4 -o addr show dev "$DOCKER_VLAN_NAME" 2>/dev/null | grep -q " $(vlan_iface_ip)/"; then
      note "$DOCKER_VLAN_NAME already has $(vlan_iface_ip) — not touching the network"
      need_apply=0
    fi
  else
    if [ -f "$NETPLAN_FILE" ]; then
      backup="$NETPLAN_FILE.bak-$(date +%Y%m%d%H%M%S)"
      cp -a "$NETPLAN_FILE" "$backup"
      note "existing file backed up to $backup"
    fi
    printf '%s\n' "$body" >"$NETPLAN_FILE"
    chmod 600 "$NETPLAN_FILE"
    note "wrote $NETPLAN_FILE"
  fi

  if [ "$need_apply" = 1 ]; then
    if ! netplan generate; then
      if [ -n "$backup" ]; then
        cp -a "$backup" "$NETPLAN_FILE"
        warn "restored $backup"
      else
        rm -f "$NETPLAN_FILE"
      fi
      die "netplan generate rejected the configuration — nothing was applied"
    fi

    if [ "$MODE" = try ]; then
      note "netplan try — confirm within 120s or it rolls back"
      netplan try
    else
      note "applying (this changes the host's default route)"
      netplan apply
    fi

    for i in $(seq 1 20); do
      ip -4 -o addr show dev "$DOCKER_VLAN_NAME" 2>/dev/null \
        | grep -q " $(vlan_iface_ip)/" && break
      sleep 0.5
    done
    if ! ip -4 -o addr show dev "$DOCKER_VLAN_NAME" 2>/dev/null | grep -q " $(vlan_iface_ip)/"; then
      warn "$DOCKER_VLAN_NAME did not get $(vlan_iface_ip) — is the switch port a trunk carrying id $DOCKER_VLAN_ID?"
    fi
  fi

  ensure_network || warn "the VLAN is configured; finish the network with: ./$(basename "$0") --network-only"

  do_status

  say "next"
  note "stacks attach containers to '$DOCKER_MACVLAN_NETWORK' (external: true)"
  note "the router must have id $DOCKER_VLAN_ID defined and tagged on the port this host uses"
  note "undo with: sudo $0 --down"
}

case "$MODE" in
  status) do_status ;;
  down) do_down ;;
  network) ensure_network ;;
  *) do_apply ;;
esac
