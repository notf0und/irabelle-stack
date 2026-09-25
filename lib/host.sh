#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lib/host.sh — helpers shared by the host-side shell scripts.
#
# Sourced, never executed: ./setup.sh sources it, and so does every
# <stack>/setup.sh hook (so a hook also works when run on its own). It is
# deliberately tiny — anything that is specific to one stack belongs in that
# stack's own setup.sh.
# ---------------------------------------------------------------------------

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Read one KEY=value line out of a .env-style file, stripping quotes, a
# trailing comment and whitespace. Returns nothing when the file or key is
# missing, so callers can use `${var:-default}`.
env_var() {
  [ -f "$1" ] || return 0
  local v
  v=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1)
  v=${v%%#*}
  printf '%s' "$v" | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

# Same idea, specialised to TLD.
env_tld() {
  [ -f "$1" ] || return 0
  local v
  v=$(sed -n 's/^[[:space:]]*TLD[[:space:]]*=[[:space:]]*//p' "$1" | tail -n 1)
  v=${v%%#*}
  printf '%s' "$v" | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

# Host-level settings, kept in host.env (gitignored): the choices setup.sh asks
# about and remembers — FAST_DATA_DIR, DSH_INSTALL. Relative to the checkout,
# so callers work from the repo root.
host_env_get() { env_var host.env "$1"; }
host_env_set() {
  [ -f host.env ] || printf '# Host-level settings — see host.env.example.\n' >host.env
  if grep -q "^[[:space:]]*$1[[:space:]]*=" host.env; then
    sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1=$2|" host.env
  else
    printf '%s=%s\n' "$1" "$2" >>host.env
  fi
}
