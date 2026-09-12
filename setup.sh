#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — bootstrap this host, then hand over to Dockhand.
#
#   ./setup.sh              prepare, start Dockhand, print its URL
#   ./setup.sh --cron       also install the update cron job
#   ./setup.sh --no-cron    never ask about the cron job
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
CRON_MODE=ask

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

  --cron        install the update cron job without asking
  --no-cron     never ask about the update cron job
  -h, --help    this text

Environment:
  DOCKHAND_PORT           host port for Dockhand (default 3000)
  UPDATE_CRON_SCHEDULE    cron schedule for update.sh (default */15 * * * *)
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

# --- 1. the .env files -------------------------------------------------------
# A stack's .env.example is a template: @REPO_DIR@ expands to this checkout's
# absolute path, which is what the dockhand stack needs for matching paths.
write_env_from() { sed "s|@REPO_DIR@|$REPO_DIR|g" "$1" >"$2"; }

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
else
  die "no .env and no .env.example at the repo root"
fi

ROOT_TLD=$(env_tld .env)
for s in "${STACKS[@]}"; do
  if [ ! -f "$s/.env" ]; then
    if [ -f "$s/.env.example" ]; then
      write_env_from "$s/.env.example" "$s/.env"
      note "$s/.env created from $s/.env.example"
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
( cd dockhand && docker compose up -d )

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

# --- automatic stack availability -------------------------------------------
say "Stack availability"
install_cron() {
  local schedule=${UPDATE_CRON_SCHEDULE:-"*/15 * * * *"}
  local line="$schedule $REPO_DIR/update.sh >> $HOME/irabelle-update.log 2>&1 # irabelle-stack"
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -v 'irabelle-stack' >"$tmp" || true
  printf '%s\n' "$line" >>"$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  note "installed in $(id -un)'s crontab:"
  note "  $line"
}

if [ ! -d "$REPO_DIR/.git" ]; then
  note "not a git checkout — there is nothing to pull, so no cron job"
elif [ "$CRON_MODE" = "no" ]; then
  note "skipped (--no-cron)"
else
  if [ "$CRON_MODE" = "ask" ]; then
    if [ -t 0 ]; then
      printf '    Run update.sh every 15 minutes so new stacks appear in Dockhand? [y/N] '
      read -r answer || answer=n
      case "$answer" in
        [yY]*) CRON_MODE=yes ;;
        *) CRON_MODE=no ;;
      esac
    else
      CRON_MODE=no
      note "no terminal to ask on — skipping (use --cron to install it)"
    fi
  fi
  if [ "$CRON_MODE" = "yes" ]; then
    install_cron
    note "update.sh pulls this checkout and registers new stacks; it never deploys"
  fi
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
