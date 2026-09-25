#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — bootstrap this host, then hand over to Dockhand.
#
#   ./setup.sh              prepare, start Dockhand, print its URL, and install
#                           the two cron jobs
#   ./setup.sh --no-cron    do not install the cron jobs
#   ./setup.sh --no-trust-ca    skip installing the root CA into this host's
#                               own trust store (done by default; sudo —
#                               every client device still needs its own
#                               one-time step regardless)
#   ./setup.sh --fast-disk DIR  keep configs and databases on DIR (an SSD),
#                               at the same paths (see fast-disk.sh)
#   ./setup.sh --no-mount-guard skip telling Docker to wait for this
#                               checkout's filesystem at boot, if it is on a
#                               separate mount (done by default when it is;
#                               sudo; a no-op on this boot either way)
#
# Any stack added later is still deployed from Dockhand's UI — setup.sh only
# auto-starts what it can start safely (see step 4 below). What it does first
# is only the work Dockhand cannot do for itself:
#
#   1. the .env files the stacks read (gitignored, so never in the repo)
#   2. the shared app-bridge network Dockhand attaches to
#   3. the root CA behind the *.$TLD certificates
#   3b. if this checkout is on a slow (spinning or USB) disk: every stack's
#      config/ onto an SSD you pick, bind-mounted back in place (fast-disk.sh)
#   4. the base stacks — traefik, adblock (once host-vlan.sh has run),
#      authentik and Dockhand — so https://<service>.$TLD, the login and
#      Dockhand already work once this script finishes. Everything else (arr,
#      books, plex, ...) is only adopted into Dockhand, and deployed from there
#   5. each stack's own <stack>/setup.sh hook, sourced in turn: Dockhand's
#      start + baseline + single sign-on, the media apps wired together
#      (integrations.py), and the opt-in DeepSeek Harness at dsh.$TLD. The
#      container-specific work lives in the stack's directory, so removing a
#      directory removes its hook — and the question that goes with it. The
#      shared helpers are in lib/host.sh
#   6. trust the root CA on this host (see --no-trust-ca above)
#   7. tell Docker to wait for this checkout's filesystem at boot, if it is a
#      separate mount (see --no-mount-guard above)
#   8. hand this host's DNS back to the router if ~/manual-dns.sh shows a
#      manual override active and adblock is actually running (not every
#      install has this script — it's this bootstrapping problem's own
#      escape hatch). This one runs right after step 4, before Dockhand, so
#      the hooks already use the host's real resolver.
#
# The URLs to open are printed last, not step 5 — see the end of this file.
#
# Deploying by hand is still just compose, if you would rather:
#   docker compose -f traefik/compose.yml up -d
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO_DIR"

DOCKHAND_PORT=${DOCKHAND_PORT:-3000}
CRON_MODE=yes
TRUST_CA=yes
MOUNT_GUARD=yes
FAST_DISK_OPT=
DSH_OPT=

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

  --no-cron       do not install the cron jobs
  --cron          (default) install them
  --no-trust-ca     do not install the root CA into this host's own trust
                    store
  --trust-ca        (default) install it (needs sudo). This only affects
                    the host itself — every *client* device (phone,
                    laptop, ...) still needs the one-time manual step
                    printed at the end, regardless of this flag.
  --no-mount-guard  do not add the systemd drop-in that makes Docker wait
                    for this checkout's filesystem at boot
  --mount-guard     (default) add it, if this checkout is on a separate
                    mount (needs sudo; a no-op if it's on the root
                    filesystem, or if Docker is already configured to
                    wait for it)
  --fast-disk DIR   keep every stack's config/ (settings, databases) in DIR,
                    on a faster disk, bind-mounted back at the same paths
                    (needs sudo; asked for on the first run when this checkout
                    is on a slow disk — see fast-disk.sh)
  --no-fast-disk    keep them in the checkout, and stop asking
  --dsh             install the DeepSeek Harness at dsh.$TLD without asking.
                    It is a host systemd user service, not a container, and
                    needs Node.js on this host — see dsh/README.md
  --no-dsh          do not install it, and stop asking
  -h, --help        this text

Environment:
  DOCKHAND_PORT           host port for Dockhand (default 3000)
  UPDATE_CRON_SCHEDULE    cron schedule for update.sh (default 0 */12 * * *)
  ADMIN_USERNAME          the authentik/Dockhand/Pi-hole login to create,
                          instead of asking (only used the first time, while
                          authentik/.env has none yet)
  ADMIN_EMAIL             its email, instead of asking (same rule; required
                          when there is no terminal to ask on)
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cron) CRON_MODE=yes ;;
    --no-cron) CRON_MODE=no ;;
    --trust-ca) TRUST_CA=yes ;;
    --no-trust-ca) TRUST_CA=no ;;
    --mount-guard) MOUNT_GUARD=yes ;;
    --no-mount-guard) MOUNT_GUARD=no ;;
    --fast-disk) shift; FAST_DISK_OPT=${1:?--fast-disk needs a directory} ;;
    --no-fast-disk) FAST_DISK_OPT=none ;;
    --dsh) DSH_OPT=yes ;;
    --no-dsh) DSH_OPT=no ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

# Shared helpers: say/note/warn/die, env_var/env_tld, and the host.env
# get/set used by the choices this script asks about and remembers. The same
# file is sourced by every <stack>/setup.sh hook, so a hook also works on its
# own.
. "$REPO_DIR/lib/host.sh"

# --- stack setup hooks -------------------------------------------------------
# A stack may ship <stack>/setup.sh for the setup work that is specific to it.
# It is *sourced*, once the base stacks and Dockhand are up, so it shares this
# script's helpers, its $TMP and its variables. A hook whose order matters is
# named explicitly below; every other one runs in directory order after them.
#
# Removing a stack's directory removes its hook with it, so nothing here asks
# about, installs or configures a stack that is not in the checkout. A hook is
# for what a stack *needs done on this host* — the docker-level details stay in
# its compose.yml.
STACK_HOOKS_RUN=""
run_stack_hook() {
  local stack=$1 hook="$REPO_DIR/$1/setup.sh"
  case " $STACK_HOOKS_RUN " in *" $stack "*) return 0 ;; esac
  STACK_HOOKS_RUN="$STACK_HOOKS_RUN $stack"
  [ -f "$hook" ] || return 0
  # shellcheck disable=SC1090 -- the path is the whole point
  . "$hook" || warn "$stack/setup.sh failed — see its output"
  return 0
}

# A URL that is clickable in terminals supporting OSC 8 hyperlinks — which is
# most of them, over SSH included. Falls back to plain text, and is skipped
# entirely when stdout is not a terminal so redirecting setup.sh to a file does
# not fill it with escape codes.
print_url() {
  if [ -t 1 ]; then
    printf '    \033]8;;%s\033\\%s\033]8;;\033\\\n' "$1" "$1"
  else
    printf '    %s\n' "$1"
  fi
}

# A headless server has no browser, and SSH cannot reach back into yours to
# start one, so this only fires when there is a display to draw on: a local
# desktop session, or `ssh -X` with a browser installed on the server.
open_first_url() {
  local url=${1:-}
  [ -n "$url" ] || return 0

  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 &
    note "asked xdg-open to open $url"
    return 0
  fi

  if [ -n "${SSH_CONNECTION:-}" ]; then
    note "over SSH there is no browser to launch here — the link above is"
    note "clickable in most terminals, or open it from any device on the LAN"
  fi
  return 0
}

command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. the .env files -------------------------------------------------------
# A stack's .env.example is a template: @REPO_DIR@ expands to this checkout's
# absolute path (what the dockhand stack needs for matching paths), and
# @TLD@ expands to the root .env's TLD — so a stack's own .env.example only
# needs to declare TLD once, in the root .env.example, not repeat it.
# ROOT_TLD is unset on the very first call (creating the root .env itself,
# whose own .env.example has no @TLD@ to expand), hence the ":-".
# @HOST_IP@ is this host's LAN address: the first global IPv4 address that is
# not Docker's (its bridges, or the Docker VLAN host-vlan.sh creates — whose
# address is where the default route goes, so "the default route's source" would
# pick the wrong one on such a host).
HOST_VLAN_IF=$( { sed -n 's/^[[:space:]]*DOCKER_VLAN_NAME[[:space:]]*=[[:space:]]*//p' host.env 2>/dev/null || true; } | tail -n1)
HOST_IP=$(ip -4 -o addr show scope global 2>/dev/null \
  | awk -v vlan="${HOST_VLAN_IF:-Docker.Online}" '$2 !~ /^(docker|br-|veth)/ && $2 != vlan {split($4, a, "/"); print a[1]; exit}')
expand_env() { sed -e "s|@REPO_DIR@|$REPO_DIR|g" -e "s|@TLD@|${ROOT_TLD:-}|g" -e "s|@HOST_IP@|${HOST_IP:-}|g"; }
write_env_from() { expand_env <"$1" >"$2"; }

# In a .env.example, the literal value `change-me` means "generate one on first
# setup". That way a fresh clone never runs with a published default password,
# and re-cloning (which throws these files away) does not quietly restore it.
generate_placeholders() {
  local file=$1 key new
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    new=$(openssl rand -hex 16 2>/dev/null \
          || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    sed -i "s|^$key=change-me$|$key=$new|" "$file"
    note "generated $key in $file"
  done < <(sed -n 's/^\([A-Za-z0-9_]*\)=change-me$/\1/p' "$file" 2>/dev/null || true)
}

STACKS=()
for d in */; do
  d=${d%/}
  [ -f "$d/compose.yml" ] && STACKS+=("$d")
done
[ "${#STACKS[@]}" -gt 0 ] || die "no stacks found (no subdirectory contains a compose.yml)"

say "Configuration"
if [ -f .env ]; then
  note ".env exists — left untouched"
elif [ -f .env.example ]; then
  write_env_from .env.example .env
  note "created .env from .env.example"
  generate_placeholders .env
else
  die "no .env and no .env.example at the repo root"
fi

ROOT_TLD=$(env_tld .env)
for s in "${STACKS[@]}"; do
  if [ ! -f "$s/.env" ]; then
    if [ -f "$s/.env.example" ]; then
      write_env_from "$s/.env.example" "$s/.env"
      note "$s/.env created from $s/.env.example"
      generate_placeholders "$s/.env"
    else
      cp .env "$s/.env"
      note "$s/.env created from .env"
    fi
    continue
  fi
  stack_tld=$(env_tld "$s/.env")
  if [ -n "$ROOT_TLD" ] && [ -n "$stack_tld" ] && [ "$stack_tld" != "$ROOT_TLD" ]; then
    sed -i "s|^[[:space:]]*TLD[[:space:]]*=.*|TLD=$ROOT_TLD|" "$s/.env"
    note "$s/.env: TLD was $stack_tld, synced to $ROOT_TLD (root .env is the source of truth)"
  fi
  # A key the template gained after this .env was made (a new secret, say) is
  # appended, generated if it is a `change-me` — existing values are never
  # touched. Without this an older install would fail compose's `:?` checks
  # the moment the stack's compose.yml starts using the new key.
  if [ -f "$s/.env.example" ]; then
    added=0
    while IFS= read -r line; do
      key=${line%%=*}
      grep -q "^[[:space:]]*$key[[:space:]]*=" "$s/.env" && continue
      [ "$added" = 1 ] || printf '\n# Added by ./setup.sh from .env.example:\n' >>"$s/.env"
      printf '%s\n' "$line" | expand_env >>"$s/.env"
      note "$s/.env: added $key"
      added=1
    done < <(grep -E '^[A-Za-z0-9_]+=' "$s/.env.example")
    [ "$added" = 1 ] && generate_placeholders "$s/.env"
  fi
done
note "stacks found: ${STACKS[*]}"

# The one login for authentik, Dockhand and Pi-hole. Its password is a
# `change-me` placeholder like any other, so it was generated just above; the
# name is the one thing asked for, and only while authentik/.env has none —
# the blueprint creates this user the first time authentik starts, so a name
# picked later would be a second user, not a rename.
AK_ENV=authentik/.env
if [ -f "$AK_ENV" ] && [ -z "$(env_var "$AK_ENV" ADMIN_USERNAME)" ]; then
  ak_user=${ADMIN_USERNAME:-}
  if [ -z "$ak_user" ] && [ -t 0 ]; then
    while :; do
      read -r -p "    login for authentik, Dockhand and Pi-hole [$(id -un)]: " ak_user || true
      ak_user=${ak_user:-$(id -un)}
      [[ "$ak_user" =~ ^[A-Za-z0-9._-]+$ ]] && break
      warn "letters, digits, '.', '_' and '-' only"
    done
  fi
  if [ -z "$ak_user" ]; then
    ak_user=$(id -un)
    note "no terminal to ask on — the login is $ak_user (set ADMIN_USERNAME to choose)"
  fi
  [[ "$ak_user" =~ ^[A-Za-z0-9._-]+$ ]] || die "ADMIN_USERNAME '$ak_user': letters, digits, '.', '_' and '-' only"
  sed -i "s|^ADMIN_USERNAME=.*|ADMIN_USERNAME=$ak_user|" "$AK_ENV"
  note "authentik login: $ak_user (password generated in $AK_ENV)"
fi
# Your email, asked for once, like the username: authentik keeps it on your
# user, and Kavita and Shelfmark match your authentik login to the account
# setup.sh makes for you there by it. Only while authentik/.env has none.
if [ -f "$AK_ENV" ] && [ -z "$(env_var "$AK_ENV" ADMIN_EMAIL)" ]; then
  ak_email=${ADMIN_EMAIL:-}
  # A dot in the domain: authentik refuses an address like you@smart.
  email_ok() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
  if [ -z "$ak_email" ] && [ -t 0 ]; then
    while :; do
      read -r -p "    your email (for authentik, Kavita and Shelfmark): " ak_email \
        || { ak_email=; break; }
      email_ok "$ak_email" && break
      warn "that does not look like an address (user@example.com)"
    done
  fi
  if [ -z "$ak_email" ]; then
    die "no terminal to ask for your email on — set ADMIN_EMAIL=you@example.com and re-run"
  fi
  email_ok "$ak_email" || die "ADMIN_EMAIL '$ak_email' does not look like an address (user@example.com)"
  if grep -q '^ADMIN_EMAIL=' "$AK_ENV"; then
    sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$ak_email|" "$AK_ENV"
  else
    printf 'ADMIN_EMAIL=%s\n' "$ak_email" >>"$AK_ENV"
  fi
  note "authentik email: $ak_email"
fi

# adblock's dnsmasq wildcard is a real config file, not a .env — Compose can't
# interpolate ${TLD} into it, so it's kept in sync here the same way. Only the
# TLD portion of the address=/local= lines is touched; the LAN address next to
# it is per-install and left exactly as found.
DNSMASQ_CONF="adblock/config/pihole/dnsmasq.d/99-irabelle.conf"
if [ -f "$DNSMASQ_CONF" ] && [ -n "$ROOT_TLD" ]; then
  CONF_TLD=$(sed -n 's#^address=/\.\([^/]*\)/.*#\1#p' "$DNSMASQ_CONF" | head -n1)
  if [ -n "$CONF_TLD" ] && [ "$CONF_TLD" != "$ROOT_TLD" ]; then
    sed -i \
      -e "s#^address=/\.[^/]*/#address=/.$ROOT_TLD/#" \
      -e "s#^local=/\.[^/]*/\$#local=/.$ROOT_TLD/#" \
      "$DNSMASQ_CONF"
    note "$DNSMASQ_CONF: wildcard was .$CONF_TLD, synced to .$ROOT_TLD"
  fi
fi

# Zigbee2MQTT only starts with a coordinator to talk to (it is behind the
# `zigbee` compose profile). Look for one once, by its stable by-id name, and
# switch the profile on in smarthome/.env when there is. A path you set
# yourself is left alone.
if [ -f smarthome/.env ] && [ -z "$(env_var smarthome/.env ZIGBEE_DEVICE)" ]; then
  zb=$(ls /dev/serial/by-id/ 2>/dev/null \
       | grep -iE 'zigbee|sonoff|cc26|cc13|slzb|conbee|zbdongle|ezsp|efr32|skyconnect|home_assistant_connect' \
       | head -n1 || true)
  if [ -n "$zb" ]; then
    sed -i -e "s|^ZIGBEE_DEVICE=.*|ZIGBEE_DEVICE=/dev/serial/by-id/$zb|" \
           -e "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=zigbee|" smarthome/.env
    note "smarthome/.env: Zigbee coordinator found ($zb) — Zigbee2MQTT will start"
  fi
fi

# Per-install config, kept out of git so a `git pull` can never be blocked by a
# local edit — the same deal as .env above. Each one ships as a committed
# .example and is copied into place here: Traefik's static config, which people
# tweak (log level, ping, entrypoints), Unbound's, which decides whether this box
# recurses or forwards to somebody else's resolver, and SearXNG's, which decides
# what the meta-search engine exposes (notably the JSON API n8n calls).
for f in traefik/config/traefik.yml adblock/config/unbound/unbound.conf \
         searxng/config/searxng/config/settings.yml \
         iptv/config/streamlink/streams.yaml; do
  [ -f "$f.example" ] || continue
  if [ -d "$f" ]; then
    # A file mount whose source was missing left Docker to create a *directory*
    # here. Clear it so the copy below can happen (see the bind-mount section).
    rmdir "$f" 2>/dev/null && warn "removed an empty directory at $f (left by Docker)"
  fi
  if [ -f "$f" ]; then
    note "$f exists — left untouched"
  else
    cp "$f.example" "$f"
    note "created $f from $f.example"
  fi
done

# --- 2. the shared network ---------------------------------------------------
say "Docker network"
if docker network inspect app-bridge >/dev/null 2>&1; then
  note "app-bridge already exists"
else
  docker network create app-bridge >/dev/null
  note "created app-bridge"
fi

# Pi-hole's web UI has no password — authentik in front of it is the login —
# so its web server only lets in app-bridge, where Traefik is (see
# adblock/compose.yml). app-bridge's subnet is whatever Docker handed out when
# it was created, so it is looked up here and kept in sync, the same as TLD.
APP_BRIDGE_SUBNET=$(docker network inspect app-bridge \
  --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
  | tr ' ' '\n' | grep -m1 '\.' || true)
if [ -f adblock/.env ] && [ -n "$APP_BRIDGE_SUBNET" ] \
   && [ "$(env_var adblock/.env APP_BRIDGE_SUBNET)" != "$APP_BRIDGE_SUBNET" ]; then
  if grep -q '^[[:space:]]*APP_BRIDGE_SUBNET[[:space:]]*=' adblock/.env; then
    sed -i "s|^[[:space:]]*APP_BRIDGE_SUBNET[[:space:]]*=.*|APP_BRIDGE_SUBNET=$APP_BRIDGE_SUBNET|" adblock/.env
  else
    printf '\n# Written by ./setup.sh: the only subnet allowed to reach the Pi-hole UI.\nAPP_BRIDGE_SUBNET=%s\n' \
      "$APP_BRIDGE_SUBNET" >>adblock/.env
  fi
  note "adblock/.env: APP_BRIDGE_SUBNET=$APP_BRIDGE_SUBNET (the Pi-hole UI answers only Traefik)"
fi

# A stack that needs the host VLAN cannot deploy until host-vlan.sh has run.
# Not fatal here — Dockhand starts either way — but it is the first thing to
# check when such a stack refuses to deploy.
for s in "${STACKS[@]}"; do
  if grep -q 'driver:[[:space:]]*macvlan' "$s/compose.yml" 2>/dev/null; then
    if docker network inspect app-macvlan >/dev/null 2>&1; then
      note "$s: app-macvlan is present"
    else
      warn "$s needs the host VLAN — run: sudo ./host-vlan.sh"
    fi
  fi
done

# --- 3. the root CA ----------------------------------------------------------
for s in "${STACKS[@]}"; do
  gen="$s/generate_certificates/1-generate-root-certificates.sh"
  [ -x "$gen" ] || continue
  say "Root certificate ($s)"
  if [ -f "$s/generate_certificates/root-certificates/root-ca.crt" ]; then
    note "already present — kept"
  else
    ( cd "$s/generate_certificates" && ./1-generate-root-certificates.sh )
  fi
  note "service certificates are issued by cert-watcher.sh once Traefik runs"
done

# Python apps (Shelfmark) verify TLS against their own bundle, not the system
# store, so trusting our CA there means handing them a bundle of their own:
# this host's roots plus our CA. Rebuilt every run, so it follows both.
CA_DIR=traefik/generate_certificates/root-certificates
if [ -f "$CA_DIR/root-ca.crt" ]; then
  for sys_bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    [ -f "$sys_bundle" ] || continue
    cat "$sys_bundle" "$CA_DIR/root-ca.crt" >"$CA_DIR/ca-bundle.crt.tmp" \
      && mv "$CA_DIR/ca-bundle.crt.tmp" "$CA_DIR/ca-bundle.crt"
    break
  done
  [ -f "$CA_DIR/ca-bundle.crt" ] \
    || warn "no system CA bundle found — Shelfmark's authentik login will not verify"
fi

# --- bind-mount paths --------------------------------------------------------
# Docker creates a missing bind-mount source itself — as root, mode 0755. On a
# directory mount that leaves a root-owned directory inside the checkout, and a
# checkout you cannot write to is one you cannot delete: `rm -rf` needs write
# permission on the parent, which Docker owns and you do not. So create every
# in-checkout mount source first, as you, and Docker never has to invent one.
say "Bind mounts"
PRE_CREATED=0
for s in "${STACKS[@]}"; do
  # Every profile too: a service that is off for now (Zigbee2MQTT without a
  # dongle) would otherwise get its directories invented by Docker, as root,
  # the day it is switched on.
  ( cd "$s" && docker compose --profile '*' config --format json ) >"$TMP/$s.json" 2>/dev/null || continue
  python3 - "$TMP/$s.json" "$REPO_DIR" >"$TMP/$s.dirs" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
repo = sys.argv[2]
for svc in (data.get("services") or {}).values():
    for vol in (svc.get("volumes") or []):
        if vol.get("type") != "bind":
            continue
        src = vol.get("source") or ""
        if src.startswith(repo + os.sep) and not os.path.exists(src):
            print(src)
PY
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -e "$d" ] && continue  # several services can mount the same source
    if [[ "${d##*/}" == *.* ]]; then
      # Looks like a file. Docker would create a *directory* for it, and the
      # container would then read an empty one — do not paper over that.
      warn "missing file mount: ${d#"$REPO_DIR"/} — create it, or the container gets an empty directory"
    else
      mkdir -p "$d"
      note "created ${d#"$REPO_DIR"/}"
      PRE_CREATED=$((PRE_CREATED + 1))
    fi
  done <"$TMP/$s.dirs"
done
[ "$PRE_CREATED" -gt 0 ] || note "nothing missing — Docker has no reason to create anything"

# Paths created by a container or a script rather than by compose, so the loop
# above never sees them: Docker or the container would create them itself, as
# root, and a root-owned directory inside the checkout cannot be emptied
# without sudo. Create them here, while they are still yours.
# downloads/ is the media tree arr, books and plex share (see arr/compose.yml):
# every container mounts it whole, so its layout is ours to create.
for d in dockhand/config/dockhand traefik/config/logs traefik/config/certificates \
         pocket-tts2/config/models pocket-tts2/config/voices \
         downloads/tv downloads/movies downloads/books downloads/complete/books \
         downloads/incomplete downloads/torrents/tv downloads/torrents/movies; do
  if [ ! -d "$REPO_DIR/$d" ]; then
    mkdir -p "$REPO_DIR/$d"
    note "created $d"
  elif [ ! -w "$REPO_DIR/$d" ]; then
    warn "$d is not writable by $(id -un) (left root-owned by an earlier run)"
    warn "fix once with: sudo chown -R $(id -un):$(id -gn) '$REPO_DIR/$d'"
  fi
done

# Those directories are yours, but the containers run as root, so the files they
# write inside are root-owned: readable, not editable. A *default* ACL makes
# them yours — new files get it, and new subdirectories inherit it recursively —
# without changing how any container runs and without hiding the data in a
# volume. Needs the `acl` package; the warning below says so when it is absent.
# Every stack's config/ — so a stack added later is covered with no edit here —
# plus the few runtime directories outside one, and the media tree.
ACL_DIRS=(traefik/config/logs downloads)
for s in "${STACKS[@]}"; do [ -d "$s/config" ] && ACL_DIRS+=("$s/config"); done
# The second pass below walks every *existing* file, so it is deliberately
# limited to the config directories. Running it over downloads/ would mean
# traversing a media library that can hold terabytes, only to set an ACL that new
# files inherit anyway.
ACL_RECURSIVE_DIRS=()
for d in "${ACL_DIRS[@]}"; do [ "$d" = downloads ] || ACL_RECURSIVE_DIRS+=("$d"); done
if command -v setfacl >/dev/null 2>&1; then
  for d in "${ACL_DIRS[@]}"; do
    [ -d "$REPO_DIR/$d" ] || continue
    setfacl -m "d:u:$(id -un):rwX" -m "d:m:rwX" "$REPO_DIR/$d" 2>/dev/null \
      || warn "could not set the default ACL on $d"
  done
  for d in "${ACL_RECURSIVE_DIRS[@]}"; do
    [ -d "$REPO_DIR/$d" ] || continue
    # Existing entries too, where they are already yours to change — and the
    # default ACL on every existing subdirectory, not just the top: a default
    # only reaches directories created after it (pihole/, say, is not).
    setfacl -R -m "u:$(id -un):rwX" "$REPO_DIR/$d" 2>/dev/null || true
    find "$REPO_DIR/$d" -type d -user "$(id -un)" \
      -exec setfacl -m "d:u:$(id -un):rwX" -m "d:m:rwX" {} + 2>/dev/null || true
  done
else
  warn "setfacl not found: files a container writes under downloads/ or any"
  warn "stack's config/ directory stay root-owned (readable, not editable)."
  warn "Install it once with: sudo apt install acl — then re-run this."
fi

# Anything already root-owned in here came from a container start before this
# script did that, and it will block `rm -rf` of the checkout.
if find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -user root -print -quit 2>/dev/null | grep -q .; then
  warn "root-owned paths already exist in this checkout (from an earlier run)"
  warn "clear them once with: sudo chown -R $(id -un) '$REPO_DIR'"
fi

# --- fast disk for configs and databases ---------------------------------------
# This checkout usually lives on the big disk the media needs — often a USB or
# spinning one. Every stack's config/ (its databases: Home Assistant's history,
# Plex, the *arrs, Pi-hole) is small, and on such a disk everything waits on it.
# fast-disk.sh keeps those folders on an SSD instead, bind-mounted back at the
# same paths, while downloads/ stays here. Asked for once; the answer is kept in
# host.env as FAST_DATA_DIR ("none" = do not ask again). Every run re-applies
# it, so a stack added later gets its config/ moved too. host_env_get/set come
# from lib/host.sh.
[ -n "$FAST_DISK_OPT" ] && host_env_set FAST_DATA_DIR "$FAST_DISK_OPT"
FAST_DATA_DIR=$(host_env_get FAST_DATA_DIR)

if [ -z "$FAST_DATA_DIR" ]; then
  # The disks worth offering: SSDs other than the one this checkout is on, and
  # only when this checkout is on a slow one. "slow" = spinning or USB.
  python3 - "$REPO_DIR" >"$TMP/disks" <<'PY' || true
import json, os, subprocess, sys
repo = sys.argv[1]
def disk_of(dev):
    out = subprocess.run(["lsblk", "-ndo", "PKNAME", dev], capture_output=True, text=True).stdout.strip()
    return "/dev/" + out if out else dev
def props(disk):
    out = subprocess.run(["lsblk", "-ndo", "ROTA,TRAN,MODEL", disk], capture_output=True, text=True).stdout.split(None, 2)
    return (out[0] == "1" if out else True), (out[1] if len(out) > 1 else ""), (out[2].strip() if len(out) > 2 else "")
mounts = json.loads(subprocess.run(["findmnt", "-J", "-b", "-o", "TARGET,SOURCE,FSROOT,FSTYPE,AVAIL"],
                                   capture_output=True, text=True).stdout)["filesystems"]
flat = []
def walk(fs):
    for f in fs:
        flat.append(f); walk(f.get("children", []))
walk(mounts)
# An automount (autofs) lists itself first, then the real device: take the device.
here = next((l.split("[")[0].strip() for l in reversed(subprocess.run(
    ["findmnt", "-no", "SOURCE", "--target", repo], capture_output=True, text=True).stdout.splitlines())
    if l.startswith("/dev/")), "")
here_disk = disk_of(here) if here.startswith("/dev/") else ""
rota, tran, _ = props(here_disk) if here_disk else (False, "", "")
if not (rota or tran == "usb"):
    print("FAST"); sys.exit(0)          # already on an SSD: nothing to offer
seen = set()
for f in flat:
    src = f.get("source") or ""
    if not src.startswith("/dev/") or f.get("fsroot") != "/" or f.get("fstype") not in ("ext4", "xfs", "btrfs", "f2fs"):
        continue
    if f["target"].startswith("/boot") or src in seen:
        continue
    seen.add(src)
    d = disk_of(src)
    r, t, model = props(d)
    if d == here_disk or r or t == "usb":
        continue
    base = "/srv" if f["target"] == "/" else f["target"].rstrip("/")
    print(f'{base}/irabelle-stack-data\t{int(f.get("avail") or 0) // 2**30} GB free\t{f["target"]} — {model or d}')
PY
  if [ "$(head -n1 "$TMP/disks")" = FAST ]; then
    note "this checkout is already on an SSD — configs and databases stay in it"
  elif [ ! -s "$TMP/disks" ]; then
    note "this checkout is on a slow disk, and there is no SSD to put configs on"
  elif [ -t 0 ]; then
    say "Configs and databases on a faster disk"
    note "this checkout is on a slow (spinning or USB) disk: every database here"
    note "would wait on it. Their config/ folders can live on an SSD instead, at"
    note "the same paths; the media in downloads/ stays where it is."
    i=0
    while IFS=$'\t' read -r dir free where; do
      i=$((i + 1)); printf '      %d) %s  (%s, %s)\n' "$i" "$dir" "$free" "$where"
    done <"$TMP/disks"
    read -r -p "    pick one [1-$i], or Enter to keep them here: " pick || pick=
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$i" ]; then
      FAST_DATA_DIR=$(sed -n "${pick}p" "$TMP/disks" | cut -f1)
    else
      FAST_DATA_DIR=none
      note "kept here — change your mind with: ./setup.sh --fast-disk DIR"
    fi
    host_env_set FAST_DATA_DIR "$FAST_DATA_DIR"
  else
    note "configs stay on this (slow) disk — no terminal to ask on; use --fast-disk DIR"
  fi
fi

if [ -n "$FAST_DATA_DIR" ] && [ "$FAST_DATA_DIR" != none ]; then
  say "Configs and databases on $FAST_DATA_DIR"
  if sudo "$REPO_DIR/fast-disk.sh" apply "$FAST_DATA_DIR"; then
    :
  else
    warn "could not move the configs — they stay in the checkout. Retry with:"
    warn "  sudo ./fast-disk.sh apply $FAST_DATA_DIR"
  fi
fi

# --- Docker mount guard -------------------------------------------------------
# Same root-owned-directory problem as "Bind mounts" above, triggered by a
# boot race instead of a fresh checkout: if this repo lives on a filesystem
# that isn't mounted yet when Docker starts, Docker still starts, finds the
# bind-mount sources missing, and creates them itself as root — then the real
# mount lands on top a moment later, hiding a directory Docker manages
# instead of one you do. A systemd drop-in telling Docker to wait fixes it at
# the source. Only relevant at all when this checkout is on a separate mount.
if command -v findmnt >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
  MOUNT_TARGET=$(findmnt -n -o TARGET --target "$REPO_DIR" 2>/dev/null || true)
  if [ -n "$MOUNT_TARGET" ] && [ "$MOUNT_TARGET" != "/" ]; then
    if systemctl cat docker.service 2>/dev/null | grep -qF "RequiresMountsFor=$MOUNT_TARGET"; then
      note "docker.service already waits for $MOUNT_TARGET before starting"
    elif [ "$MOUNT_GUARD" = yes ]; then
      say "Docker mount guard"
      DROPIN=/etc/systemd/system/docker.service.d/irabelle-stack-mount.conf
      if printf '[Unit]\nRequiresMountsFor=%s\n' "$MOUNT_TARGET" | sudo tee "$DROPIN" >/dev/null \
         && sudo systemctl daemon-reload; then
        note "docker.service now waits for $MOUNT_TARGET before starting ($DROPIN)"
        note "takes effect on this host's next boot — Docker is already up"
        note "and the mount is already in place, so nothing changes right now"
      else
        warn "could not add the mount guard — add it by hand:"
        warn "  printf '[Unit]\\nRequiresMountsFor=$MOUNT_TARGET\\n' |"
        warn "    sudo tee $DROPIN && sudo systemctl daemon-reload"
      fi
    else
      note "$REPO_DIR is on a separate mount ($MOUNT_TARGET) but --no-mount-guard"
      note "was passed — Docker is not guaranteed to wait for it at boot"
    fi
  fi
fi

# --- 4. the base stacks -------------------------------------------------------
# Only the stacks everything else stands on start: traefik (every
# https://<service>.$TLD name), adblock (the LAN's DNS), authentik (the login)
# and Dockhand (where you deploy the rest). That is what makes those names,
# that login and Dockhand work right after this script finishes. Every other stack — arr, books, plex and the rest — is left
# for you: setup.sh adopts it into Dockhand below (update.sh --no-pull), and
# you deploy it from there when you want it.
#
# A stack that needs app-macvlan (adblock) only starts if host-vlan.sh already
# created it, matching the check above — sudo is never something this script
# does on your behalf, so a stack that isn't ready yet is skipped, not forced.
# Dockhand is a base stack too, but not in this loop: it has its own
# dedicated start, health check and baseline configuration in step 5 below.
BASE_STACKS=(traefik adblock authentik)
say "Starting the base stacks: ${BASE_STACKS[*]} (and dockhand, below)"
for s in "${BASE_STACKS[@]}"; do
  [ -f "$s/compose.yml" ] || continue
  if grep -q 'driver:[[:space:]]*macvlan' "$s/compose.yml" 2>/dev/null \
     && ! docker network inspect app-macvlan >/dev/null 2>&1; then
    note "$s: skipped — needs the host VLAN (see warning above)"
    continue
  fi
  if ( cd "$s" && docker compose up -d ); then
    note "$s started"
  else
    warn "$s failed to start — check: docker compose -f $s/compose.yml logs"
  fi
done
for s in "${STACKS[@]}"; do
  case " dockhand ${BASE_STACKS[*]} " in *" $s "*) continue ;; esac
  note "$s: not started — deploy it from Dockhand (it is adopted there below)"
done

# --- hand the host's DNS back to the router ----------------------------------
# Bootstrapping a cold host needs *some* DNS before Pi-hole is up at all — the
# git clone and docker pull this repo itself needs. manual-dns.sh (kept in the
# home directory on purpose, outside this checkout) is this host's way around
# that chicken-and-egg. Once adblock is actually running, hand the override
# back: left in place, this host would keep ignoring the router's real
# (Pi-hole) DNS from here on instead of going back to it as the router hands
# it out over DHCP. The router's own config is not this repo's responsibility
# — only whether *this host* still has a manual override active is.
#
# Done here, right after the stacks start and before Dockhand and single
# sign-on, not at the end: everything from here on (Dockhand's own pull, its
# login through authentik.$TLD) should see the resolver the host will
# actually run with, not the temporary public one.
MANUAL_DNS="$HOME/manual-dns.sh"
if [ -x "$MANUAL_DNS" ]; then
  # Captured first, matched second — not piped straight into `grep -q`. Under
  # pipefail (set at the top of this script), `grep -q` exiting the instant it
  # finds a match can SIGPIPE a still-writing upstream command (manual-dns.sh
  # prints several more lines after the one this matches on), which then makes
  # the whole pipeline look like it failed even though the match happened.
  # Hit exactly that here during testing: this check silently never fired.
  MANUAL_DNS_STATUS=$("$MANUAL_DNS" status 2>/dev/null || true)
  DNS_OVERRIDDEN=no
  case "$MANUAL_DNS_STATUS" in *8.8.8.8*) DNS_OVERRIDDEN=yes ;; esac
  if [ "$DNS_OVERRIDDEN" = yes ] \
     && [ -n "$(docker compose -f adblock/compose.yml ps --status running -q 2>/dev/null)" ]; then
    say "Manual DNS override"
    # "running" is not "answering": give Pi-hole's own healthcheck (a DNS
    # query against itself) the chance to pass before relying on it.
    printf '    waiting for pihole to answer'
    for _ in $(seq 1 30); do
      h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' pihole 2>/dev/null || true)
      # No healthcheck at all (a future image): nothing to wait for.
      [ "$h" = healthy ] || [ -z "$h" ] && break
      printf '.'
      sleep 2
    done
    printf '\n'
    note "handing this host's resolver back to whatever the router provides"
    note "over DHCP (pihole, per the router's own config):"
    if "$MANUAL_DNS" off >/dev/null 2>&1; then
      # The rest of this script still pulls images. If the handed-back
      # resolver cannot resolve public names, put the override back rather
      # than fail halfway — and say so, because that is a router or Pi-hole
      # problem this script cannot fix.
      if timeout 10 getent hosts github.com >/dev/null 2>&1; then
        note "reverted — public names resolve through pihole"
      else
        warn "reverted, but public names do not resolve that way — the manual"
        warn "override is back on. Check the router's DHCP DNS option and Pi-hole,"
        warn "then run: $MANUAL_DNS off"
        "$MANUAL_DNS" on >/dev/null 2>&1 || true
      fi
    else
      warn "could not revert automatically — run it yourself: $MANUAL_DNS off"
    fi
  fi
fi

# --- 5-6. Dockhand and single sign-on (dockhand/setup.sh) -------------------
# Starting Dockhand, restoring a baseline a fresh database needs, and
# registering authentik as its OIDC provider are the stack's own business
# now — see dockhand/setup.sh. Sourced, so the login it reads and the API
# token it mints stay visible to the summary printed at the end.
run_stack_hook dockhand

# --- wire the media apps together --------------------------------------------
# After single sign-on on purpose: Kavita, Shelfmark and Cleanuparr log in
# through authentik, and Kavita checks authentik is really there before it
# accepts that. Only apps that are running are touched, only what is missing
# is added, and a re-run changes nothing — see integrations.py.
chmod +x "$REPO_DIR/integrations.py" 2>/dev/null || true
python3 "$REPO_DIR/integrations.py" \
  || warn "wiring the apps together failed part-way — re-run: ./integrations.py"

# --- the DeepSeek Harness (a host service, not a stack) ---------------------
# The question and the install live with the stack: see dsh/setup.sh. It is
# opt-in and remembered in host.env (DSH_INSTALL), and removing dsh/ means
# it is not even offered.
run_stack_hook dsh

# Any other stack's hook, in directory order (none today).
for _hook_dir in */; do
  _hook_dir=${_hook_dir%/}
  [ -f "$_hook_dir/setup.sh" ] || continue
  run_stack_hook "$_hook_dir"
done
unset _hook_dir

# --- scheduled jobs ----------------------------------------------------------
say "Scheduled jobs"
install_cron() {
  local schedule=${UPDATE_CRON_SCHEDULE:-"0 */12 * * *"}
  local watcher="$REPO_DIR/traefik/generate_certificates/cert-watcher.sh"
  local tmp
  tmp=$(mktemp)
  # Replace our own lines, keep everything else in the crontab untouched. The
  # pattern also catches lines left by an older layout (a cert-watcher under a
  # previous path), which would otherwise sit there failing every boot.
  crontab -l 2>/dev/null | grep -vE 'irabelle-stack|cert-watcher\.sh' >"$tmp" || true

  # No redirects on purpose: these jobs do not leave log files behind. cron
  # discards the output, so if you want the history use `journalctl` after
  # appending `2>&1 | logger -t irabelle-update` to a line.
  local update_line="$schedule $REPO_DIR/update.sh # irabelle-stack"
  printf '%s\n' "$update_line" >>"$tmp"

  # The certificates live in the checkout and are gitignored, so a fresh clone
  # has none. The watcher issues them once Traefik is up; at boot it retries
  # until it can.
  local watch_line=''
  if [ -x "$watcher" ]; then
    watch_line="@reboot $watcher # irabelle-stack"
    printf '%s\n' "$watch_line" >>"$tmp"
  fi

  crontab "$tmp"
  rm -f "$tmp"

  note "installed in $(id -un)'s crontab:"
  note "  $update_line"
  [ -n "$watch_line" ] && note "  $watch_line"
  return 0
}

if [ ! -d "$REPO_DIR/.git" ]; then
  note "not a git checkout — there is nothing to pull, so no update job"
elif [ "$CRON_MODE" = "no" ]; then
  note "skipped (--no-cron)"
else
  install_cron
  note "update.sh only registers new stacks — it never deploys them"

  # @reboot only fires at boot, so a fresh setup would otherwise leave nothing
  # watching until the next reboot and no certificates after it. Start it now.
  #
  # Always restart it, even if one is already running: it reads TLD from
  # .env once at process start, not on every loop iteration, so a TLD change
  # (most commonly a rename) leaves an old instance quietly watching for the
  # previous domain's hosts forever, issuing no certificates for the new one
  # — exactly the bug this fixes. Matching on the full watcher path, not just
  # the script's basename, so this only ever touches an instance started from
  # this checkout, never another one.
  watcher="$REPO_DIR/traefik/generate_certificates/cert-watcher.sh"
  if [ -x "$watcher" ]; then
    EXISTING_WATCHER_PIDS=$(pgrep -f "$watcher" || true)
    if [ -n "$EXISTING_WATCHER_PIDS" ]; then
      # shellcheck disable=SC2086
      kill $EXISTING_WATCHER_PIDS 2>/dev/null || true
      note "stopped the running cert-watcher.sh so it re-reads the current .env"
    fi
    if command -v setsid >/dev/null 2>&1; then
      setsid "$watcher" >/dev/null 2>&1 &
    else
      nohup "$watcher" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    note "cert-watcher.sh (re)started — certificates appear as Traefik registers services"
  fi
fi

# --- hand over ---------------------------------------------------------------
AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
  "http://127.0.0.1:$DOCKHAND_PORT/api/environments" 2>/dev/null || true)

# Gathered once, reused for the scp hint below and the URL list at the very
# end. `ip -o` gives: "2: enp1s0    inet 192.168.1.2/24 brd ..." — dev is
# field 2, the address is field 4.
HOST_IPS=()
while read -r _ dev _ cidr _; do
  case "$dev" in lo|docker*|br-*|veth*) continue ;; esac
  HOST_IPS+=("${cidr%%/*}")
done < <(ip -4 -o addr show scope global 2>/dev/null)

# --- trust the root CA --------------------------------------------------------
CA_CRT="$REPO_DIR/traefik/generate_certificates/root-certificates/root-ca.crt"
if [ -f "$CA_CRT" ]; then
  say "Root CA"
  note "$CA_CRT"
  if [ -n "${HOST_IPS[0]:-}" ]; then
    note "from your own machine, over SSH:"
    note "  scp $(id -un)@${HOST_IPS[0]}:$CA_CRT ~/Downloads/irabelle-root.crt"
  fi
  CA_TRUSTED_HERE=no
  if [ "$TRUST_CA" = yes ]; then
    if command -v update-ca-certificates >/dev/null 2>&1; then
      DEST=/usr/local/share/ca-certificates/irabelle-root.crt
      if sudo cp "$CA_CRT" "$DEST" && sudo update-ca-certificates >/dev/null; then
        note "trusted on this host: $DEST (Debian/Ubuntu, via update-ca-certificates)"
        CA_TRUSTED_HERE=yes
      else
        warn "could not install the CA on this host — use the manual steps below"
      fi
    elif command -v update-ca-trust >/dev/null 2>&1; then
      DEST=/etc/pki/ca-trust/source/anchors/irabelle-root.crt
      if sudo cp "$CA_CRT" "$DEST" && sudo update-ca-trust; then
        note "trusted on this host: $DEST (Fedora/RHEL, via update-ca-trust)"
        CA_TRUSTED_HERE=yes
      else
        warn "could not install the CA on this host — use the manual steps below"
      fi
    else
      warn "no known system trust store here (not Debian/Ubuntu or Fedora/RHEL)"
      warn "install it by hand — see the steps below"
    fi
  else
    note "skipped (--no-trust-ca) — install it by hand:"
  fi
  cat <<EOF
    # Debian/Ubuntu
    sudo cp $CA_CRT /usr/local/share/ca-certificates/irabelle-root.crt
    sudo update-ca-certificates

    # Fedora/RHEL: copy into /etc/pki/ca-trust/source/anchors, then update-ca-trust
    # macOS:       security add-trusted-cert -d -r trustRoot \\
    #                -k /Library/Keychains/System.keychain root-ca.crt
EOF
  if [ "$CA_TRUSTED_HERE" = yes ]; then
    note "this only trusts it for tools ON THIS HOST — every client device"
    note "(phone, laptop, ...) that will browse to a *.$ROOT_TLD name still"
    note "needs its own one-time step, same as above (or its own equivalent —"
    note "Android: Settings -> Security -> Encryption & credentials -> Install"
    note "a certificate; iOS/macOS: AirDrop or email the .crt, then Settings ->"
    note "General -> VPN & Device Management, then also Settings -> General ->"
    note "About -> Certificate Trust Settings to fully enable it)."
  fi
  note "Firefox keeps its own store regardless of the OS: set"
  note "security.enterprise_roots.enabled=true in about:config, or import"
  note "$CA_CRT under Settings -> Privacy & Security -> Certificates."
fi

TRAEFIK_UP=no
[ -n "$(docker compose -f traefik/compose.yml ps --status running -q 2>/dev/null)" ] && TRAEFIK_UP=yes

say "What to do now"
if [ "$TRAEFIK_UP" = yes ]; then
  cat <<EOF
  1. traefik is already running (started by this script) — the
     https://<service>.$ROOT_TLD names work as soon as a service is deployed
     and cert-watcher.sh has issued its certificate.
  2. Deploy the rest from Dockhand whenever you like — arr, books, plex and
     the others are already there, adopted and waiting. New stacks turn up
     in the list after update.sh runs.
  3. After deploying arr, books or plex, run ./integrations.py to connect
     them to each other and to authentik now (the update cron job does it
     within 12 hours otherwise) — and, for plex, to claim it with a code
     from https://plex.tv/claim.
EOF
else
  cat <<EOF
  1. Deploy **traefik** first — every other service is published through it, so
     the https://<service>.$ROOT_TLD names only work once it is up.
  2. Deploy the rest from Dockhand whenever you like — arr, books, plex and
     the others are already there, adopted and waiting. New stacks turn up
     in the list after update.sh runs.
  3. After deploying arr, books or plex, run ./integrations.py to connect
     them to each other and to authentik now (the update cron job does it
     within 12 hours otherwise) — and, for plex, to claim it with a code
     from https://plex.tv/claim.
EOF
fi

if [ "$AUTH_CODE" = 200 ]; then
  warn "authentication is OFF: anyone who can reach that URL can control Docker"
  warn "on this host. The single sign-on step above normally turns it on — see"
  warn "its warnings — or turn it on in Dockhand: Settings -> Authentication."
fi

# The one login for all three, printed next to the links it opens. The
# password is the one generated at first setup: once changed in authentik
# this line is out of date (and so is the local Dockhand copy of it).
# AK_USER/AK_PASS come from the authentik/.env that setup.sh wrote above, or
# from the dockhand hook when that stack is present — hence the ":-".
if [ -n "${AK_USER:-}" ] && [ -n "${AK_PASS:-}" ] && [ -n "$ROOT_TLD" ]; then
  say "Your login — authentik, Dockhand and Pi-hole"
  note "username: $AK_USER"
  note "password: $AK_PASS"
  note "(as generated — it is in $AK_ENV; change it in authentik, top right -> Settings)"
  print_url "https://authentik.$ROOT_TLD"
  print_url "https://pihole.$ROOT_TLD/admin/"
fi

# This is the last thing printed on purpose — the actual "click this" moment,
# so it is not something you have to scroll back up for.
say "Dockhand is up — open one of these"
IP_URLS=()
for ip in "${HOST_IPS[@]}"; do IP_URLS+=("http://$ip:$DOCKHAND_PORT"); done

# The real name goes first — clicking its OSC 8 hyperlink is what actually
# opens it in *your* browser over SSH: the terminal you're reading this in
# handles that client-side, which is the only way this can work at all, since
# nothing running on the server can reach into a remote desktop on its own.
# It needs DNS pointed at this LAN's resolver and the root CA trusted first
# (see "Root CA" above) — the ip:port fallbacks below need neither.
URLS=()
[ -n "$ROOT_TLD" ] && URLS+=("https://dockhand.$ROOT_TLD")
URLS+=("${IP_URLS[@]}")

for url in "${URLS[@]}"; do print_url "$url"; done
open_first_url "${IP_URLS[0]:-}"
