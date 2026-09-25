#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dsh/uninstall.sh — undo what dsh/install.sh did on this host.
#
#   ./dsh/uninstall.sh           remove the service, route, certificate and the
#                                dsh-mobile plugin; keep ~/.dsh (sessions and
#                                credentials) and dsh/.env
#   ./dsh/uninstall.sh --purge   also delete ~/.dsh and dsh/.env
#   ./dsh/uninstall.sh --yes     no confirmation prompt (for scripts)
#
# It never touches the repo's own files: dsh/install.sh, the templates and the
# README stay, so `git pull` keeps working and ./dsh/install.sh puts it back.
#
# Uninstalling also removes DSH_INSTALL from host.env, so the next ./setup.sh
# asks again rather than assuming.
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
Usage: ./dsh/uninstall.sh [options]

  --purge   also delete ~/.dsh (sessions, credentials, settings, profiles)
            and dsh/.env. Without it both are kept, so a later
            ./dsh/install.sh starts from what you had.
  --yes     do not ask for confirmation
  -h, --help  this text
EOF
  exit "${1:-0}"
}

PURGE=no
ASSUME_YES=no
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=yes ;;
    --yes|-y) ASSUME_YES=yes ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# --- settings ---------------------------------------------------------------
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
TLD=$(setting TLD "$ROOT_TLD")
PUBLIC_HOST=$(setting PUBLIC_HOST "dsh.$TLD")
DSH_PROFILE=$(setting DSH_PROFILE "web")
DSH_HOME=$(setting DSH_HOME "${DSH_HOME:-$HOME/.dsh}")
PROFILE_DIR="$DSH_HOME/profiles/$DSH_PROFILE"
UNIT="$HOME/.config/systemd/user/dsh-web.service"
ROUTE="$REPO_DIR/traefik/config/certificates/dsh.yml"
CERT_DIR="$REPO_DIR/traefik/config/certificates"

say "dsh — DeepSeek Harness at $PUBLIC_HOST"

if [ "$ASSUME_YES" != yes ]; then
  if [ ! -t 0 ]; then
    die "refusing to uninstall without a terminal — re-run with --yes to confirm"
  fi
  if [ "$PURGE" = yes ]; then
    printf '    Remove the dsh service AND delete %s (sessions, credentials,\n' "$DSH_HOME"
    read -r -p "    settings, profiles)? This cannot be undone. [y/N] " answer || true
  else
    read -r -p "    Remove the dsh service, route and plugin from this host? [y/N] " answer || true
  fi
  case "${answer:-}" in
    [yY]|[yY][eE][sS]) ;;
    *) note "left everything as it is"; exit 0 ;;
  esac
fi

# --- the systemd user service -----------------------------------------------
say "Host service"
if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null; then
  systemctl --user stop dsh-web.service 2>/dev/null && note "stopped dsh-web.service" || true
  systemctl --user disable dsh-web.service 2>/dev/null && note "disabled dsh-web.service" || true
  if [ -f "$UNIT" ]; then
    rm -f "$UNIT"
    note "removed $UNIT"
  else
    note "no unit at $UNIT"
  fi
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed dsh-web.service 2>/dev/null || true
else
  warn "systemd --user is not reachable here — remove the unit by hand if it exists:"
  warn "    rm -f $UNIT"
  [ -f "$UNIT" ] && rm -f "$UNIT" && note "removed $UNIT anyway"
fi

# --- the Traefik route and certificate --------------------------------------
say "Traefik"
if [ -f "$ROUTE" ]; then
  rm -f "$ROUTE"
  note "removed traefik/config/certificates/dsh.yml"
else
  note "no route file at traefik/config/certificates/dsh.yml"
fi
removed_cert=no
for suffix in crt key; do
  if [ -f "$CERT_DIR/$PUBLIC_HOST.$suffix" ]; then
    rm -f "$CERT_DIR/$PUBLIC_HOST.$suffix"
    removed_cert=yes
  fi
done
if [ "$removed_cert" = yes ]; then
  note "removed the $PUBLIC_HOST certificate"
  # tls.yml is generated from the *.crt files that exist, so this drops the
  # entry instead of leaving Traefik pointing at a deleted key.
  if [ -x "$REPO_DIR/traefik/generate_certificates/3-sync-tls-file.sh" ]; then
    "$REPO_DIR/traefik/generate_certificates/3-sync-tls-file.sh" >/dev/null 2>&1 || true
    note "re-synced traefik/config/certificates/tls.yml"
  fi
else
  note "no $PUBLIC_HOST certificate to remove"
fi

# --- the dsh-mobile plugin and its checkout ---------------------------------
say "Plugin"
if [ -d "$DSH_DIR/.dsh-mobile" ]; then
  rm -rf "$DSH_DIR/.dsh-mobile"
  note "removed the dsh-mobile checkout (dsh/.dsh-mobile)"
fi
if [ -f "$PROFILE_DIR/package.json" ]; then
  # Drop the dependency and the bundle entry, keeping the rest of the profile
  # (and any other plugin) exactly as it was.
  node -e '
    const fs = require("node:fs")
    const p = process.argv[1]
    const m = JSON.parse(fs.readFileSync(p, "utf8"))
    let changed = false
    if (m.dependencies && Object.hasOwn(m.dependencies, "dsh-mobile")) {
      delete m.dependencies["dsh-mobile"]; changed = true
    }
    const bundles = m.dsh?.profile?.bundles
    if (Array.isArray(bundles)) {
      const kept = bundles.filter((name) => name !== "dsh-mobile")
      if (kept.length !== bundles.length) { m.dsh.profile.bundles = kept; changed = true }
    }
    if (changed) fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n")
  ' "$PROFILE_DIR/package.json" 2>/dev/null \
    && note "removed dsh-mobile from $PROFILE_DIR/package.json" \
    || warn "could not edit $PROFILE_DIR/package.json"
  rm -rf "$PROFILE_DIR/plugins/dsh-mobile" "$PROFILE_DIR/node_modules/dsh-mobile"
  note "removed the vendored dsh-mobile plugin"
else
  note "no profile at $PROFILE_DIR"
fi

# --- remember that this user does not want it -------------------------------
if [ -f host.env ] && grep -q '^[[:space:]]*DSH_INSTALL[[:space:]]*=' host.env; then
  sed -i '/^[[:space:]]*DSH_INSTALL[[:space:]]*=/d' host.env
  note "removed DSH_INSTALL from host.env — ./setup.sh will ask again"
fi

# --- --purge: the harness's own state ---------------------------------------
if [ "$PURGE" = yes ]; then
  say "Purge"
  if [ -n "$DSH_HOME" ] && [ "$DSH_HOME" != "/" ] && [ -d "$DSH_HOME" ]; then
    rm -rf "$DSH_HOME"
    note "deleted $DSH_HOME (sessions, credentials, profiles)"
  else
    note "no $DSH_HOME to delete"
  fi
  if [ -f "$DSH_ENV" ]; then
    rm -f "$DSH_ENV"
    note "deleted dsh/.env"
  fi
fi

say "Done"
note "the repo's own files (dsh/, the README, the blueprint) are untouched."
note "put it back any time with: ./setup.sh --dsh   (or ./dsh/install.sh)"
