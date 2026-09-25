#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dsh/install.sh — put the DeepSeek Harness behind Traefik and authentik.
#
#   ./dsh/install.sh              install or update; safe to re-run
#   ./dsh/install.sh --status     report what is installed, change nothing
#   ./dsh/install.sh --no-restart update files but leave a running service alone
#
# ./setup.sh runs this on every run, after the base stacks; run it by hand
# after editing dsh/.env.
#
# DSH is deliberately NOT a container. `dsh web` refuses to bind anything but
# 127.0.0.1 (the GUI is remote code execution), so dsh-web-bridge.mjs runs on
# the host, listens on the Docker gateway, and forwards to dsh on loopback.
# Traefik reaches the bridge through host.docker.internal, exactly like the
# plex and glances stacks reach their host-network containers.
#
# What this script owns:
#
#   * dsh/.env                    created from dsh/.env.example, with the root
#                                 .env's TLD; new keys are appended on update
#   * the dsh profile              bootstrapped, then dsh-mobile cloned from
#                                 DSH_MOBILE_REPO into dsh/.dsh-mobile and
#                                 installed into it (the phone shell)
#   * ~/.config/systemd/user/dsh-web.service
#                                 the bridge as a systemd USER service, with
#                                 lingering enabled so it survives logout
#   * traefik/config/certificates/dsh.yml
#                                 the dsh.$TLD route, in Traefik's file
#                                 provider, rendered from dsh/traefik/dsh.yml
#
# authentik's half — the forward-auth provider for dsh.$TLD — is a blueprint
# entry in authentik/config/authentik/blueprints/irabelle.yaml, applied by the
# authentik worker on start. Nothing here touches it.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DSH_DIR="$REPO_DIR/dsh"
cd "$REPO_DIR"

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./dsh/install.sh [options]

  --status       report node, profile, plugin, service and route; change nothing
  --no-restart   write the unit and route but do not restart the service
  -h, --help     this text

Everything else comes from dsh/.env (see dsh/.env.example) and the root .env.
EOF
  exit "${1:-0}"
}

RESTART=yes
STATUS_ONLY=no
while [ $# -gt 0 ]; do
  case "$1" in
    --status) STATUS_ONLY=yes ;;
    --no-restart) RESTART=no ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- settings ---------------------------------------------------------------
# Same key reading as setup.sh, so the two agree on quoting and comments.
env_var() {
  [ -f "$1" ] || return 0
  local v
  v=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1)
  v=${v%%#*}
  printf '%s' "$v" | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

ROOT_TLD=$(env_var "$REPO_DIR/.env" TLD)
ROOT_TLD=${ROOT_TLD:-smart}

DSH_ENV="$DSH_DIR/.env"
setting() {
  local v
  v=$(env_var "$DSH_ENV" "$1")
  printf '%s' "${v:-${2:-}}"
}

# Every setting has a default, so this works whether or not dsh/.env exists yet
# — which is what keeps --status read-only.
load_settings() {
  TLD=$(setting TLD "$ROOT_TLD")
  PUBLIC_HOST=$(setting PUBLIC_HOST "dsh.$TLD")
  LISTEN_HOST=$(setting LISTEN_HOST "172.17.0.1")
  LISTEN_PORT=$(setting LISTEN_PORT "3080")
  DSH_PROFILE=$(setting DSH_PROFILE "web")
  IDLE_MINUTES=$(setting IDLE_MINUTES "20")
  DSH_UPDATE_TAG=$(setting DSH_UPDATE_TAG "latest")
  DSH_REFRESH_ON_START=$(setting DSH_REFRESH_ON_START "1")
  UPDATE_HOURS=$(setting UPDATE_HOURS "1")
  DSH_CWD=$(setting DSH_CWD "$HOME")
  DSH_HOME=$(setting DSH_HOME "${DSH_HOME:-$HOME/.dsh}")
  DSH_MOBILE_REPO=$(setting DSH_MOBILE_REPO "")
  DSH_MOBILE_REF=$(setting DSH_MOBILE_REF "main")
  DSH_MOBILE_DIR="$DSH_DIR/.dsh-mobile"
  [ -d "$DSH_CWD" ] || DSH_CWD="$HOME"
  NODE=$(command -v node || true)
  NODE_DIR=$([ -n "$NODE" ] && dirname "$NODE" || true)
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT="$UNIT_DIR/dsh-web.service"
  ROUTE="$REPO_DIR/traefik/config/certificates/dsh.yml"
}
load_settings

# --- status -----------------------------------------------------------------
if [ "$STATUS_ONLY" = yes ]; then
  if [ -n "$NODE" ]; then note "node:        $NODE ($(node -v))"; else note "node:        NOT FOUND"; fi
  if [ -f "$DSH_HOME/profiles/$DSH_PROFILE/package.json" ]; then
    note "profile:     $DSH_HOME/profiles/$DSH_PROFILE (exists)"
  else
    note "profile:     $DSH_HOME/profiles/$DSH_PROFILE (missing)"
  fi
  if [ -d "$DSH_HOME/profiles/$DSH_PROFILE/plugins/dsh-mobile" ]; then
    note "dsh-mobile:  installed"
  else
    note "dsh-mobile:  not installed"
  fi
  note "unit:        $([ -f "$UNIT" ] && echo "$UNIT" || echo 'not written')"
  if systemctl --user is-active dsh-web.service >/dev/null 2>&1; then
    note "service:     active"
  else
    note "service:     not active"
  fi
  note "route:       $([ -f "$ROUTE" ] && echo "$ROUTE" || echo 'not written')"
  exit 0
fi

say "dsh — DeepSeek Harness at dsh.$ROOT_TLD"

# dsh/.env from dsh/.env.example, then the root .env stays the TLD authority.
if [ ! -f "$DSH_DIR/.env" ]; then
  sed -e "s|@TLD@|$ROOT_TLD|g" "$DSH_DIR/.env.example" >"$DSH_DIR/.env"
  note "created dsh/.env from dsh/.env.example"
else
  stack_tld=$(env_var "$DSH_DIR/.env" TLD)
  if [ -n "$stack_tld" ] && [ "$stack_tld" != "$ROOT_TLD" ]; then
    sed -i "s|^[[:space:]]*TLD[[:space:]]*=.*|TLD=$ROOT_TLD|" "$DSH_DIR/.env"
    note "dsh/.env: TLD was $stack_tld, synced to $ROOT_TLD (root .env is the source of truth)"
  fi
  # A key the template gained after this .env was made is appended; existing
  # values are never touched. @TLD@ is expanded on the way in.
  added=0
  while IFS= read -r line; do
    key=${line%%=*}
    grep -q "^[[:space:]]*$key[[:space:]]*=" "$DSH_DIR/.env" && continue
    [ "$added" = 1 ] || printf '\n# Added by ./dsh/install.sh from dsh/.env.example:\n' >>"$DSH_DIR/.env"
    printf '%s\n' "$line" | sed -e "s|@TLD@|$ROOT_TLD|g" >>"$DSH_DIR/.env"
    note "dsh/.env: added $key"
    added=1
  done < <(grep -E '^[A-Za-z0-9_]+=' "$DSH_DIR/.env.example")
fi
load_settings

# --- node -------------------------------------------------------------------
say "Node.js"
if [ -z "$NODE" ]; then
  warn "node is not installed or not on PATH — the harness cannot run."
  warn "Install Node.js 22 or newer (your distro's nodejs, or nvm), then re-run:"
  warn "    ./dsh/install.sh"
  exit 1
fi
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
if [ "$NODE_MAJOR" -lt 20 ] 2>/dev/null; then
  warn "node $(node -v) is older than 20 — dsh may not boot."
fi
note "node $(node -v) at $NODE"
command -v npm >/dev/null 2>&1 || die "npm is required (it ships with node)"
command -v npx >/dev/null 2>&1 || die "npx is required (it ships with node)"

# dsh-mobile's installer materializes the profile with pnpm. If pnpm is absent,
# put a shim on PATH that forwards to npx rather than failing the whole install.
if ! command -v pnpm >/dev/null 2>&1 && command -v corepack >/dev/null 2>&1; then
  corepack enable pnpm >/dev/null 2>&1 || true
fi
if ! command -v pnpm >/dev/null 2>&1; then
  PKG_BIN="$TMP/bin"
  mkdir -p "$PKG_BIN"
  cat >"$PKG_BIN/pnpm" <<'EOF'
#!/bin/sh
exec npx -y pnpm@latest "$@"
EOF
  chmod +x "$PKG_BIN/pnpm"
  PATH="$PKG_BIN:$PATH"
  export PATH
  note "pnpm not installed — using a temporary npx shim for this run"
fi

# --- the dsh profile and the plugin -----------------------------------------
say "DeepSeek Harness profile ($DSH_PROFILE)"
PROFILE_DIR="$DSH_HOME/profiles/$DSH_PROFILE"
if [ ! -f "$PROFILE_DIR/package.json" ]; then
  note "bootstrapping the $DSH_PROFILE profile (first use of @deepseek-ai/dsh)"
  # --dump-default-config composes the profile and exits without starting a
  # server, which is what creates profiles/<name>/package.json from the
  # shipped template — and it seeds the npx cache the bridge reads.
  if ! npx -y "@deepseek-ai/dsh@latest" --profile "$DSH_PROFILE" --dump-default-config >/dev/null 2>&1; then
    warn "could not bootstrap the profile — dsh will create it on its first start"
  fi
fi

if [ -n "$DSH_MOBILE_REPO" ]; then
  if ! command -v git >/dev/null 2>&1; then
    warn "git is not installed — cannot fetch dsh-mobile from $DSH_MOBILE_REPO"
  else
    if [ -d "$DSH_MOBILE_DIR/.git" ]; then
      if git -C "$DSH_MOBILE_DIR" fetch --quiet origin 2>/dev/null \
         && git -C "$DSH_MOBILE_DIR" checkout --quiet "$DSH_MOBILE_REF" 2>/dev/null \
         && git -C "$DSH_MOBILE_DIR" reset --hard --quiet "origin/$DSH_MOBILE_REF" 2>/dev/null; then
        note "dsh-mobile: updated to origin/$DSH_MOBILE_REF"
      else
        warn "could not update dsh-mobile in $DSH_MOBILE_DIR — using what is there"
      fi
    else
      rm -rf "$DSH_MOBILE_DIR"
      if git clone --quiet --branch "$DSH_MOBILE_REF" "$DSH_MOBILE_REPO" "$DSH_MOBILE_DIR" 2>/dev/null; then
        note "dsh-mobile: cloned $DSH_MOBILE_REPO"
      else
        warn "could not clone $DSH_MOBILE_REPO — the phone shell will be missing"
      fi
    fi
    if [ -f "$DSH_MOBILE_DIR/install.mjs" ]; then
      if (cd "$DSH_MOBILE_DIR" && node install.mjs --profile "$DSH_PROFILE" --home "$DSH_HOME"); then
        note "dsh-mobile: installed into $PROFILE_DIR"
      else
        warn "dsh-mobile's installer failed — see its output above"
      fi
    fi
  fi
else
  warn "DSH_MOBILE_REPO is empty in dsh/.env — installing without the mobile plugin"
fi

# --- the systemd user service -----------------------------------------------
# Pure-bash substitution: the values are paths and hostnames, and this keeps
# slashes, ampersands and the like from needing sed escaping.
render() {
  local src=$1 dst=$2 line
  : >"$dst"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//@REPO_DIR@/$REPO_DIR}
    line=${line//@TLD@/$TLD}
    line=${line//@HOME@/$HOME}
    line=${line//@NODE@/$NODE}
    line=${line//@NODE_DIR@/$NODE_DIR}
    line=${line//@DSH_CWD@/$DSH_CWD}
    line=${line//@DSH_HOME@/$DSH_HOME}
    line=${line//@LISTEN_HOST@/$LISTEN_HOST}
    line=${line//@LISTEN_PORT@/$LISTEN_PORT}
    line=${line//@PUBLIC_HOST@/$PUBLIC_HOST}
    line=${line//@IDLE_MINUTES@/$IDLE_MINUTES}
    line=${line//@DSH_UPDATE_TAG@/$DSH_UPDATE_TAG}
    line=${line//@DSH_REFRESH_ON_START@/$DSH_REFRESH_ON_START}
    line=${line//@UPDATE_HOURS@/$UPDATE_HOURS}
    printf '%s\n' "$line"
  done <"$src" >"$dst"
}

say "Host service"
mkdir -p "$UNIT_DIR"
render "$DSH_DIR/dsh-web.service.example" "$TMP/dsh-web.service"
if [ -f "$UNIT" ] && cmp -s "$TMP/dsh-web.service" "$UNIT"; then
  note "dsh-web.service unchanged"
else
  install -m 0644 "$TMP/dsh-web.service" "$UNIT"
  note "wrote $UNIT"
fi

# Lingering is what keeps a user service alive once your last login ends.
if command -v loginctl >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  linger=$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null | cut -d= -f2 || true)
  if [ "$linger" != "yes" ]; then
    note "enabling lingering so the service survives logout (needs sudo)"
    sudo loginctl enable-linger "$(id -un)" 2>/dev/null \
      || warn "could not enable linger — run: sudo loginctl enable-linger $(id -un)"
  fi
fi

if ! systemctl --user daemon-reload 2>/dev/null; then
  warn "systemd --user is not reachable in this session (no user D-Bus)."
  warn "Start it from a normal login: systemctl --user enable --now dsh-web.service"
elif [ "$RESTART" = yes ]; then
  systemctl --user enable dsh-web.service >/dev/null 2>&1 || true
  if systemctl --user restart dsh-web.service 2>/dev/null; then
    note "dsh-web.service restarted"
  else
    warn "could not restart dsh-web.service — check: systemctl --user status dsh-web"
  fi
fi

# --- the Traefik route ------------------------------------------------------
say "Traefik route"
mkdir -p "$(dirname -- "$ROUTE")" 2>/dev/null || true
render "$DSH_DIR/traefik/dsh.yml" "$TMP/dsh.yml"
if [ -f "$ROUTE" ] && cmp -s "$TMP/dsh.yml" "$ROUTE"; then
  note "traefik/config/certificates/dsh.yml unchanged"
elif install -m 0644 "$TMP/dsh.yml" "$ROUTE" 2>/dev/null; then
  note "wrote traefik/config/certificates/dsh.yml (dsh.$TLD -> host.docker.internal:$LISTEN_PORT)"
else
  warn "could not write $ROUTE"
  warn "fix ownership once: sudo chown $(id -un):$(id -gn) $(dirname -- "$ROUTE")"
fi

# Issue the certificate now instead of waiting for the watcher's next pass.
# The short pause lets Traefik's file provider load the route first, so the
# watcher sees dsh.$TLD in the router list on this pass.
if docker compose -f traefik/compose.yml ps --status running -q 2>/dev/null | grep -q .; then
  sleep 2
  "$REPO_DIR/traefik/generate_certificates/cert-watcher.sh" --once >/dev/null 2>&1 \
    && note "asked cert-watcher.sh for the dsh.$TLD certificate" \
    || warn "cert-watcher.sh --once did not complete — it will retry on its own"
fi

say "dsh is at https://dsh.$TLD"
note "behind authentik, then the harness's own one-time token, which the"
note "bridge replays for you — no token ever appears in the address bar."
note ""
note "first use: open the URL, log in, and add your model credentials in the"
note "harness settings. Phone: use the browser's \"Add to Home Screen\" — the"
note "dsh-mobile plugin makes it a proper phone shell."
note ""
note "service:  systemctl --user status dsh-web"
note "logs:     journalctl --user -u dsh-web -f"
note "settings: dsh/.env, then re-run ./dsh/install.sh"
