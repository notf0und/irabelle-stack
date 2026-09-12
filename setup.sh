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

command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. the .env files -------------------------------------------------------
# A stack's .env.example is a template: @REPO_DIR@ expands to this checkout's
# absolute path, which is what the dockhand stack needs for matching paths.
write_env_from() { sed "s|@REPO_DIR@|$REPO_DIR|g" "$1" >"$2"; }

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
  if [ -n "$ROOT_TLD" ] && [ "$stack_tld" != "$ROOT_TLD" ]; then
    warn "$s/.env has TLD=$stack_tld but .env has TLD=$ROOT_TLD"
    warn "service names will not match — edit one, or delete $s/.env to re-copy"
  fi
done
note "stacks found: ${STACKS[*]}"

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
      ENV_NAME=${DOCKHAND_ENV_NAME:-local}
      if api POST /api/environments \
           "{\"name\":\"$ENV_NAME\",\"connectionType\":\"socket\",\"socketPath\":\"/var/run/docker.sock\"}" \
           >/dev/null 2>&1; then
        note "created the '$ENV_NAME' environment (local Docker socket)"
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
fi

# --- hand over ---------------------------------------------------------------
AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
  "http://127.0.0.1:$DOCKHAND_PORT/api/environments" 2>/dev/null || true)

say "Dockhand is up — open one of these"
# `ip -o` gives: "2: enp1s0    inet 192.168.1.2/24 brd ..." — dev is field 2,
# the address is field 4.
ip -4 -o addr show scope global 2>/dev/null | while read -r _ dev _ cidr _; do
  case "$dev" in lo|docker*|br-*|veth*) continue ;; esac
  printf '    http://%s:%s\n' "${cidr%%/*}" "$DOCKHAND_PORT"
done

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
