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
#   4. traefik, and any other stack whose network dependencies are already
#      met (adblock, once host-vlan.sh has run) — so https://<service>.$TLD
#      already works once this script finishes, not only after a manual
#      deploy
#   5. Dockhand, on a directly reachable port, with a baseline configuration
#      (timezone, update/prune/version-check settings) applied once
#   6. single sign-on: the authentik stack's admin login (the username is
#      asked for once, the password generated) becomes the login for Dockhand
#      too — a local Dockhand user of the same name, authentik registered as
#      its OIDC provider, authentication switched on, and an API token for
#      update.sh. Pi-hole needs nothing here: it sits behind authentik's
#      forward auth in Traefik, with no password of its own.
#   7. trust the root CA on this host (see --no-trust-ca above)
#   8. tell Docker to wait for this checkout's filesystem at boot, if it is a
#      separate mount (see --no-mount-guard above)
#   9. hand this host's DNS back to the router if ~/manual-dns.sh shows a
#      manual override active and adblock is actually running (not every
#      install has this script — it's this bootstrapping problem's own
#      escape hatch). This one runs right after step 4, before Dockhand, so
#      steps 5 and 6 already use the host's real resolver.
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
  -h, --help        this text

Environment:
  DOCKHAND_PORT           host port for Dockhand (default 3000)
  UPDATE_CRON_SCHEDULE    cron schedule for update.sh (default 0 */12 * * *)
  ADMIN_USERNAME          the authentik/Dockhand/Pi-hole login to create,
                          instead of asking (only used the first time, while
                          authentik/.env has none yet)
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
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

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
write_env_from() { sed -e "s|@REPO_DIR@|$REPO_DIR|g" -e "s|@TLD@|${ROOT_TLD:-}|g" "$1" >"$2"; }

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

env_tld() {
  [ -f "$1" ] || return 0
  local v
  v=$(sed -n 's/^[[:space:]]*TLD[[:space:]]*=[[:space:]]*//p' "$1" | tail -n 1)
  v=${v%%#*}
  printf '%s' "$v" | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

# Same idea as env_tld, generalized to any KEY=value line — used below to read
# TZ out of the root .env so Dockhand's baseline timezone has one source of
# truth too, instead of a second hardcoded default drifting from it.
env_var() {
  [ -f "$1" ] || return 0
  local v
  v=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1)
  v=${v%%#*}
  printf '%s' "$v" | tr -d '"' | tr -d "'" | tr -d '[:space:]'
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

# Per-install config, kept out of git so a `git pull` can never be blocked by a
# local edit — the same deal as .env above. Each one ships as a committed
# .example and is copied into place here: Traefik's static config, which people
# tweak (log level, ping, entrypoints), and Unbound's, which decides whether
# this box recurses or forwards to somebody else's resolver.
for f in traefik/config/traefik.yml adblock/config/unbound/unbound.conf; do
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

# --- bind-mount paths --------------------------------------------------------
# Docker creates a missing bind-mount source itself — as root, mode 0755. On a
# directory mount that leaves a root-owned directory inside the checkout, and a
# checkout you cannot write to is one you cannot delete: `rm -rf` needs write
# permission on the parent, which Docker owns and you do not. So create every
# in-checkout mount source first, as you, and Docker never has to invent one.
say "Bind mounts"
PRE_CREATED=0
for s in "${STACKS[@]}"; do
  ( cd "$s" && docker compose config --format json ) >"$TMP/$s.json" 2>/dev/null || continue
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
for d in dockhand/config/dockhand traefik/config/logs traefik/config/certificates; do
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
ACL_DIRS=(adblock/config/pihole dockhand/config/dockhand traefik/config/logs)
if command -v setfacl >/dev/null 2>&1; then
  for d in "${ACL_DIRS[@]}"; do
    [ -d "$REPO_DIR/$d" ] || continue
    setfacl -m "d:u:$(id -un):rwX" -m "d:m:rwX" "$REPO_DIR/$d" 2>/dev/null \
      || warn "could not set the default ACL on $d"
    # Existing entries too, where they are already yours to change.
    setfacl -R -m "u:$(id -un):rwX" "$REPO_DIR/$d" 2>/dev/null || true
  done
else
  warn "setfacl not found: files a container writes under adblock/config/pihole,"
  warn "dockhand/config/dockhand or traefik/config/logs stay root-owned (readable,"
  warn "not editable). Install it once with: sudo apt install acl — then re-run this."
fi

# Anything already root-owned in here came from a container start before this
# script did that, and it will block `rm -rf` of the checkout.
if find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -user root -print -quit 2>/dev/null | grep -q .; then
  warn "root-owned paths already exist in this checkout (from an earlier run)"
  warn "clear them once with: sudo chown -R $(id -un) '$REPO_DIR'"
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

# --- 4. traefik, and any other stack whose networks are ready ---------------
# Traefik has no macvlan dependency, so it always starts here — that's what
# makes https://<service>.$TLD work right after this script finishes instead
# of only after a manual deploy in Dockhand. A stack that needs app-macvlan
# (adblock) only starts if host-vlan.sh already created it, matching the
# check above — sudo is never something this script does on your behalf, so a
# stack that isn't ready yet is skipped, not forced. dockhand is excluded: it
# has its own dedicated start, health check and baseline configuration below.
say "Starting traefik and any VLAN-ready stack"
for s in "${STACKS[@]}"; do
  [ "$s" = "dockhand" ] && continue
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

# --- 5. Dockhand -------------------------------------------------------------
say "Dockhand"
# --force-recreate because a re-cloned checkout is a *new* directory: a running
# container keeps the old mount, which now points at a deleted inode, so it
# would never see the fresh files.
( cd dockhand && docker compose up -d --force-recreate )

printf '    waiting for the API'
any=0
for _ in $(seq 1 40); do
  if curl -fsS -m 3 "http://127.0.0.1:$DOCKHAND_PORT/api/health" >/dev/null 2>&1; then
    any=1
    break
  fi
  printf '.'
  sleep 1
done
printf '\n'
if [ "$any" = 1 ]; then
  note "responding on port $DOCKHAND_PORT"
else
  warn "no answer on port $DOCKHAND_PORT after 40s — check: docker logs dockhand"
fi

# --- Dockhand baseline -------------------------------------------------------
# Dockhand's own database lives in its data directory, which is not in git. A
# fresh clone therefore starts with an empty one: no environment, no configured
# paths. Restore just enough that ./update.sh works and the Import dialog can
# see this checkout — so "clone, ./setup.sh" is all a new box needs, and
# re-cloning while you iterate does not leave you with a dead UI.
#
# Once single sign-on has switched Dockhand's authentication on (below), every
# call needs a token: DH_TOKEN_FILE holds the one this script minted for itself
# and for update.sh. Gitignored, and readable by you only.
DH_TOKEN_FILE="$REPO_DIR/dockhand/.api-token"
DH_TOKEN=$(cat "$DH_TOKEN_FILE" 2>/dev/null || true)

api() {
  local method=$1 path=$2 body=${3:-}
  local auth=()
  [ -n "$DH_TOKEN" ] && auth=(-H "Authorization: Bearer $DH_TOKEN")
  if [ -n "$body" ]; then
    curl -fsS -m 20 -X "$method" "http://127.0.0.1:$DOCKHAND_PORT$path" "${auth[@]}" \
      -H 'Content-Type: application/json' --data-binary "$body"
  else
    curl -fsS -m 20 -X "$method" "http://127.0.0.1:$DOCKHAND_PORT$path" "${auth[@]}"
  fi
}

# The login from authentik/.env, which is also the local Dockhand user.
AK_USER=$(env_var "$AK_ENV" ADMIN_USERNAME)
AK_PASS=$(env_var "$AK_ENV" ADMIN_PASSWORD)

# Dockhand only hands out API tokens to a *session*, and asks a local user
# for their password again when it does — so log in as that user first. JSON
# is built by python from the environment, not by the shell: a password with
# a quote in it stays a password, and it never shows up in `ps`.
mint_dockhand_token() {
  local jar="$TMP/dockhand.cookies" token
  [ -n "$AK_USER" ] && [ -n "$AK_PASS" ] || return 1
  AK_USER=$AK_USER AK_PASS=$AK_PASS python3 -c '
import json, os, sys
u, p = os.environ["AK_USER"], os.environ["AK_PASS"]
json.dump({"username": u, "password": p}, open(sys.argv[1], "w"))
json.dump({"name": "irabelle-stack (setup.sh, update.sh)", "password": p}, open(sys.argv[2], "w"))
' "$TMP/login.json" "$TMP/token-req.json"
  curl -fsS -m 20 -c "$jar" -H 'Content-Type: application/json' \
    --data-binary @"$TMP/login.json" "http://127.0.0.1:$DOCKHAND_PORT/api/auth/login" >/dev/null 2>&1 \
    || return 1
  curl -fsS -m 20 -b "$jar" -H 'Content-Type: application/json' \
    --data-binary @"$TMP/token-req.json" "http://127.0.0.1:$DOCKHAND_PORT/api/auth/tokens" \
    >"$TMP/token.json" 2>/dev/null || return 1
  rm -f "$TMP/login.json" "$TMP/token-req.json" "$jar"
  token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token",""))' "$TMP/token.json" 2>/dev/null || true)
  [ -n "$token" ] || return 1
  ( umask 077 && printf '%s\n' "$token" >"$DH_TOKEN_FILE" )
  DH_TOKEN=$token
}

if [ "$any" = 1 ]; then
  # A re-run after authentication was switched on: without a working token
  # every call below would just fail. Get one back if the token file is gone
  # (a re-clone) or was revoked in Dockhand.
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
    ${DH_TOKEN:+-H "Authorization: Bearer $DH_TOKEN"} \
    "http://127.0.0.1:$DOCKHAND_PORT/api/environments" 2>/dev/null || true)
  if [ "$code" = 401 ]; then
    if mint_dockhand_token; then
      note "Dockhand authentication is on — new API token saved to ${DH_TOKEN_FILE#"$REPO_DIR"/}"
    else
      warn "Dockhand authentication is on, and logging in as '${AK_USER:-?}' failed."
      warn "Create an API token in Dockhand (your profile -> API tokens), save it"
      warn "to ${DH_TOKEN_FILE#"$REPO_DIR"/} and re-run — until then the Dockhand steps fail."
    fi
  fi

  say "Dockhand baseline"

  if api GET /api/environments >"$TMP/envs.json" 2>/dev/null; then
    ENV_COUNT=$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print(0)' "$TMP/envs.json")
    if [ "$ENV_COUNT" = 0 ]; then
      ENV_NAME=${DOCKHAND_ENV_NAME:-Irabelle}
      ENV_TZ=$(env_var .env TZ)
      if api POST /api/environments \
           "{\"name\":\"$ENV_NAME\",\"connectionType\":\"socket\",\"socketPath\":\"/var/run/docker.sock\"}" \
           >"$TMP/env.json" 2>/dev/null; then
        note "created the '$ENV_NAME' environment (local Docker socket)"
        ENV_ID=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["id"])
except Exception: pass' "$TMP/env.json" 2>/dev/null || true)
        if [ -n "$ENV_ID" ]; then
          # These are this install's defaults, applied once at first bootstrap
          # only — a later change made in Dockhand's own UI is never overridden
          # by re-running setup.sh, the same as an existing .env is left alone.
          if [ -n "$ENV_TZ" ]; then
            api POST "/api/environments/$ENV_ID/timezone" \
              "{\"timezone\":\"$ENV_TZ\"}" >/dev/null 2>&1 \
              && note "  timezone: $ENV_TZ" \
              || warn "  could not set the environment timezone"
          fi
          api POST "/api/environments/$ENV_ID/update-check" \
            '{"enabled":true,"cron":"0 4 * * *","autoUpdate":true,"vulnerabilityCriteria":"never"}' \
            >/dev/null 2>&1 \
            && note "  scheduled updates: on, applied automatically" \
            || warn "  could not enable scheduled updates"
          api POST "/api/environments/$ENV_ID/image-prune" \
            '{"enabled":true,"cronExpression":"0 3 * * 0","pruneMode":"dangling"}' \
            >/dev/null 2>&1 \
            && note "  automatic image pruning: on" \
            || warn "  could not enable automatic image pruning"
          api POST /api/settings/semver \
            '{"enabled":true,"maxBump":"major","matchFlavor":true,"includePrerelease":false}' \
            >/dev/null 2>&1 \
            && note "  check for newer version tags: on" \
            || warn "  could not enable version-tag checks"
          # useSelfhstIcons is not true by default on a fresh Dockhand install
          # (confirmed on an actual from-scratch run), so it needs setting
          # explicitly, not just defaultTimezone.
          GENERAL_BODY='{"useSelfhstIcons":true'
          [ -n "$ENV_TZ" ] && GENERAL_BODY="$GENERAL_BODY,\"defaultTimezone\":\"$ENV_TZ\""
          GENERAL_BODY="$GENERAL_BODY}"
          api POST /api/settings/general "$GENERAL_BODY" >/dev/null 2>&1 \
            && note "  selfh.st icons: on${ENV_TZ:+; default scheduling timezone: $ENV_TZ}" \
            || warn "  could not update general settings"
        fi
      else
        warn "could not create an environment — add one in Dockhand: Settings -> Environments"
      fi
    else
      note "$ENV_COUNT environment(s) already configured"
    fi
  else
    warn "could not read the environment list from Dockhand"
  fi

  # Make the checkout a place the Import dialog can scan without browsing.
  if api GET /api/settings/general >"$TMP/general.json" 2>/dev/null; then
    PATHS=$(python3 - "$TMP/general.json" "$REPO_DIR" <<'PY'
import json, sys
try:
    cur = json.load(open(sys.argv[1])).get("externalStackPaths") or []
except Exception:
    cur = []
if isinstance(cur, str):
    cur = [p for p in cur.splitlines() if p]
if sys.argv[2] in cur:
    raise SystemExit(0)
cur.append(sys.argv[2])
print(json.dumps(cur))
PY
) || true
    if [ -n "${PATHS:-}" ]; then
      if api POST /api/settings/general "{\"externalStackPaths\":$PATHS}" >/dev/null 2>&1; then
        note "added $REPO_DIR to Dockhand's external stack paths"
      else
        warn "could not add $REPO_DIR to the external stack paths"
      fi
    else
      note "external stack paths already include this checkout"
    fi
  fi

  # Adopt any stack found here right away — otherwise Dockhand only shows raw
  # containers it noticed via the Docker socket ("Untracked"), not the proper
  # *Internal* stacks .env-driven config expects, until update.sh's cron job
  # happens to run (up to 12h later). update.sh does the actual scan+adopt via
  # Dockhand's Import API; --no-pull because this is about registering what's
  # already on disk, not about touching git.
  if [ -x "$REPO_DIR/update.sh" ]; then
    "$REPO_DIR/update.sh" --no-pull \
      || warn "could not adopt stacks automatically — run it by hand: ./update.sh --no-pull"
  fi

  # --- 6. single sign-on -------------------------------------------------------
  # authentik's side (the admin user, the Dockhand OIDC client) is its
  # blueprint's job; this is Dockhand's side. Each piece is only added when it
  # is missing, so a re-run changes nothing, and a provider or setting you
  # edit in Dockhand's own UI afterward is left alone — the same deal as the
  # baseline above.
  if [ -f "$AK_ENV" ] && [ -n "$ROOT_TLD" ]; then
    say "Single sign-on (authentik)"
    AK_SECRET=$(env_var "$AK_ENV" DOCKHAND_OIDC_CLIENT_SECRET)
    SSO_OK=yes

    if [ -z "$AK_USER" ] || [ -z "$AK_PASS" ] || [ -z "$AK_SECRET" ]; then
      warn "$AK_ENV is missing ADMIN_USERNAME, ADMIN_PASSWORD or"
      warn "DOCKHAND_OIDC_CLIENT_SECRET — Dockhand login left as it is"
      SSO_OK=no
    fi

    # The local Dockhand user: the way in when authentik is down, and what
    # the authentik login attaches to — Dockhand matches an OIDC login to an
    # existing user by name. Dockhand only lets this be created without
    # logging in while authentication is still off.
    if [ "$SSO_OK" = yes ] && api GET /api/users >"$TMP/users.json" 2>/dev/null; then
      if python3 -c 'import json,sys
sys.exit(0 if any(u.get("username")==sys.argv[2] for u in json.load(open(sys.argv[1]))) else 1)' \
           "$TMP/users.json" "$AK_USER"; then
        note "Dockhand user '$AK_USER' exists"
      elif AK_USER=$AK_USER AK_PASS=$AK_PASS python3 -c 'import json,os,sys
json.dump({"username":os.environ["AK_USER"],"password":os.environ["AK_PASS"],"displayName":os.environ["AK_USER"]},open(sys.argv[1],"w"))' \
             "$TMP/user.json" \
           && api POST /api/users @"$TMP/user.json" >/dev/null 2>&1; then
        note "created the Dockhand user '$AK_USER' (same password as authentik)"
      else
        warn "could not create the Dockhand user '$AK_USER' — Dockhand login left as it is"
        SSO_OK=no
      fi
      rm -f "$TMP/user.json"
    elif [ "$SSO_OK" = yes ]; then
      warn "could not read Dockhand's users — Dockhand login left as it is"
      SSO_OK=no
    fi

    # authentik as an OIDC provider. The issuer is authentik's public URL on
    # purpose: the browser is sent there, and the issuer inside the tokens
    # has to match it. Dockhand reaches the same name server-side through
    # Traefik's app-bridge alias, trusting our CA (see dockhand/compose.yml).
    OIDC_ID=
    OIDC_ISSUER="https://authentik.$ROOT_TLD/application/o/dockhand/"
    OIDC_REDIRECT="https://dockhand.$ROOT_TLD/api/auth/oidc/callback"
    if [ "$SSO_OK" = yes ] && api GET /api/auth/oidc >"$TMP/oidc.json" 2>/dev/null; then
      # "id issuer redirect" of the provider this script added, if it is there.
      read -r OIDC_ID OIDC_CUR_ISSUER OIDC_CUR_REDIRECT < <(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1])):
    if p.get("clientId") == "dockhand" and "/application/o/dockhand/" in (p.get("issuerUrl") or ""):
        print(p["id"], p.get("issuerUrl") or "-", p.get("redirectUri") or "-"); break' "$TMP/oidc.json" 2>/dev/null) || true
      if [ -n "$OIDC_ID" ] && [ "$OIDC_CUR_ISSUER" = "$OIDC_ISSUER" ] && [ "$OIDC_CUR_REDIRECT" = "$OIDC_REDIRECT" ]; then
        note "authentik is already an OIDC provider in Dockhand"
      elif [ -n "$OIDC_ID" ]; then
        # The TLD was renamed since: the blueprint follows on its own, this
        # copy of the URLs in Dockhand does not.
        if api PUT "/api/auth/oidc/$OIDC_ID" \
             "{\"issuerUrl\":\"$OIDC_ISSUER\",\"redirectUri\":\"$OIDC_REDIRECT\"}" >/dev/null 2>&1; then
          note "Dockhand's authentik provider: URLs moved to .$ROOT_TLD"
        else
          warn "could not move Dockhand's authentik provider to .$ROOT_TLD — edit it in Dockhand"
        fi
      else
        AK_SECRET=$AK_SECRET OIDC_ISSUER=$OIDC_ISSUER OIDC_REDIRECT=$OIDC_REDIRECT python3 -c 'import json,os,sys
json.dump({
    "name": "authentik",
    "enabled": True,
    "issuerUrl": os.environ["OIDC_ISSUER"],
    "clientId": "dockhand",
    "clientSecret": os.environ["AK_SECRET"],
    "redirectUri": os.environ["OIDC_REDIRECT"],
    "scopes": "openid profile email",
    "usernameClaim": "preferred_username",
    "emailClaim": "email",
    "displayNameClaim": "name",
}, open(sys.argv[1], "w"))' "$TMP/oidc-new.json"
        if api POST /api/auth/oidc @"$TMP/oidc-new.json" >"$TMP/oidc-created.json" 2>/dev/null; then
          OIDC_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP/oidc-created.json" 2>/dev/null || true)
          note "added authentik as Dockhand's OIDC provider (https://authentik.$ROOT_TLD)"
        else
          warn "could not add authentik as an OIDC provider in Dockhand"
        fi
        rm -f "$TMP/oidc-new.json"
      fi
    fi

    # Authentication on, with authentik as the default button on the login
    # page. Then the token for update.sh — Dockhand only issues those once
    # authentication is on.
    if [ "$SSO_OK" = yes ] && api GET /api/auth/settings >"$TMP/auth.json" 2>/dev/null; then
      if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("authEnabled") else 1)' "$TMP/auth.json"; then
        note "Dockhand authentication is already on"
      else
        AUTH_BODY='{"authEnabled":true'
        [ -n "$OIDC_ID" ] && AUTH_BODY="$AUTH_BODY,\"defaultProvider\":\"oidc:$OIDC_ID\""
        AUTH_BODY="$AUTH_BODY}"
        if api PUT /api/auth/settings "$AUTH_BODY" >/dev/null 2>&1; then
          note "Dockhand authentication: on${OIDC_ID:+ (authentik is the default login)}"
        else
          warn "could not switch Dockhand authentication on"
          SSO_OK=no
        fi
      fi
    fi
    if [ "$SSO_OK" = yes ] && [ -z "$DH_TOKEN" ]; then
      if mint_dockhand_token; then
        note "API token for update.sh saved to ${DH_TOKEN_FILE#"$REPO_DIR"/}"
      else
        warn "could not create an API token — update.sh cannot reach Dockhand until"
        warn "one is saved to ${DH_TOKEN_FILE#"$REPO_DIR"/} (your profile -> API tokens)"
      fi
    fi

    # Dockhand can only *check* the provider once authentik is up and its
    # certificate issued — both of which take a minute on a fresh install. A
    # failure here is expected then; it is not a failed setup.
    if [ -n "$OIDC_ID" ]; then
      printf '    waiting for authentik'
      for _ in $(seq 1 36); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' authentik-server 2>/dev/null)" = healthy ] && break
        printf '.'
        sleep 5
      done
      printf '\n'
      # Issue authentik.$TLD's certificate now instead of waiting for the
      # watcher, which is only (re)started further down.
      "$REPO_DIR/traefik/generate_certificates/cert-watcher.sh" --once >/dev/null 2>&1 || true
      # Asked from inside the dockhand container, with Node's own fetch: the
      # same DNS, CA and TLS stack Dockhand's login uses. (Dockhand's own
      # "Test" button wants a browser session, not the API token.)
      if OIDC_ERR=$(docker exec dockhand node -e '
fetch(process.argv[1])
  .then(r => r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status)))
  .then(d => { if (!d.issuer) throw new Error("no issuer in the discovery document"); })
  .catch(e => { console.log((e.cause && (e.cause.code || e.cause.message)) || e.message); process.exit(1); })' \
           "https://authentik.$ROOT_TLD/application/o/dockhand/.well-known/openid-configuration" 2>&1); then
        note "Dockhand reaches authentik: sign-in with authentik works"
      else
        # The reason matters: ENOTFOUND/EAI_AGAIN is DNS, a certificate code
        # (UNABLE_TO_VERIFY_LEAF_SIGNATURE, ...) is the CA or a cert not yet
        # issued, HTTP 404 is authentik still starting or its router missing.
        note "Dockhand cannot reach authentik yet (${OIDC_ERR:-no answer}) — normal on"
        note "a first run, until authentik has started and https://authentik.$ROOT_TLD"
        note "has its certificate."
        note "Dockhand's authentication settings can re-run the check (Test) later."
        note "The local login ($AK_USER) works in the meantime."
      fi
    fi
  fi
fi

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
  2. Deploy the rest whenever you like. New stacks turn up in the list after
     update.sh runs, ready for you to deploy.
EOF
else
  cat <<EOF
  1. Deploy **traefik** first — every other service is published through it, so
     the https://<service>.$ROOT_TLD names only work once it is up.
  2. Deploy the rest whenever you like. New stacks turn up in the list after
     update.sh runs, ready for you to deploy.
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
if [ -n "$AK_USER" ] && [ -n "$AK_PASS" ] && [ -n "$ROOT_TLD" ]; then
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
