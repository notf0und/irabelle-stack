#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — bootstrap this host, then hand over to Dockhand.
#
#   ./setup.sh              prepare, start Dockhand, print its URL, and install
#                           the two cron jobs
#   ./setup.sh --no-cron    do not install the cron jobs
#
# From here on, stacks are deployed from Dockhand's UI — setup.sh starts no
# stack but Dockhand itself. What it does first is only the work Dockhand
# cannot do for itself:
#
#   1. the .env files the stacks read (gitignored, so never in the repo)
#   2. the shared app-bridge network Dockhand attaches to
#   3. the root CA behind the *.$TLD certificates
#   4. Dockhand, on a directly reachable port
#
# Deploying by hand is still just compose, if you would rather:
#   docker compose -f traefik/compose.yml up -d
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO_DIR"

DOCKHAND_PORT=${DOCKHAND_PORT:-3000}
CRON_MODE=yes

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

  --no-cron     do not install the cron jobs
  --cron        (default) install them
  -h, --help    this text

Environment:
  DOCKHAND_PORT           host port for Dockhand (default 3000)
  UPDATE_CRON_SCHEDULE    cron schedule for update.sh (default 0 */12 * * *)
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cron) CRON_MODE=yes ;;
    --no-cron) CRON_MODE=no ;;
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

# --- 4. Dockhand -------------------------------------------------------------
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
api() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -fsS -m 20 -X "$method" "http://127.0.0.1:$DOCKHAND_PORT$path" \
      -H 'Content-Type: application/json' --data-binary "$body"
  else
    curl -fsS -m 20 -X "$method" "http://127.0.0.1:$DOCKHAND_PORT$path"
  fi
}

if [ "$any" = 1 ]; then
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
            '{"enabled":true,"cron":"0 4 * * *","autoUpdate":false,"vulnerabilityCriteria":"never"}' \
            >/dev/null 2>&1 \
            && note "  scheduled update checks: on" \
            || warn "  could not enable scheduled update checks"
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
          if [ -n "$ENV_TZ" ]; then
            api POST /api/settings/general \
              "{\"defaultTimezone\":\"$ENV_TZ\"}" >/dev/null 2>&1 \
              && note "  default scheduling timezone: $ENV_TZ" \
              || warn "  could not set the default scheduling timezone"
          fi
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
  # watching until the next reboot and no certificates after it. Start it now;
  # the flock in the script makes a duplicate instance harmless.
  watcher="$REPO_DIR/traefik/generate_certificates/cert-watcher.sh"
  if [ -x "$watcher" ] && ! pgrep -f 'cert-watcher\.sh' >/dev/null 2>&1; then
    if command -v setsid >/dev/null 2>&1; then
      setsid "$watcher" >/dev/null 2>&1 &
    else
      nohup "$watcher" >/dev/null 2>&1 &
    fi
    note "started cert-watcher.sh — certificates appear as Traefik registers services"
  fi
fi

# --- hand over ---------------------------------------------------------------
AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
  "http://127.0.0.1:$DOCKHAND_PORT/api/environments" 2>/dev/null || true)

say "Dockhand is up — open one of these"
# `ip -o` gives: "2: enp1s0    inet 192.168.1.2/24 brd ..." — dev is field 2,
# the address is field 4.
URLS=()
while read -r _ dev _ cidr _; do
  case "$dev" in lo|docker*|br-*|veth*) continue ;; esac
  URLS+=("http://${cidr%%/*}:$DOCKHAND_PORT")
done < <(ip -4 -o addr show scope global 2>/dev/null)

for url in "${URLS[@]}"; do print_url "$url"; done
open_first_url "${URLS[0]:-}"

if [ "$AUTH_CODE" = 200 ]; then
  warn "authentication is OFF: anyone who can reach that URL can control Docker"
  warn "on this host. Turn it on in Dockhand: Settings -> Authentication."
fi

cat <<EOF

Next, in Dockhand:
  1. Settings -> Authentication: create an admin user.
  2. Deploy **traefik** first — every other service is published through it, so
     the https://<service>.$ROOT_TLD names only work once it is up.
  3. Deploy the rest whenever you like. New stacks turn up in the list after
     update.sh runs, ready for you to deploy.
EOF
