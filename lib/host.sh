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

# Ensure every stack's config/ directory is owned by the container user
# (PUID:PGID). This is required for services that write at runtime
# (mosquitto passwd file, esphome secrets.yaml, mariadb data, …).
# Idempotent and safe to run even if the directories do not exist.
fix_stack_config_ownership() {
  local uid="${PUID:-1000}"
  local gid="${PGID:-1000}"
  for d in */config/; do
    [ -d "$d" ] || continue
    chown -R "$uid:$gid" "$d" 2>/dev/null || true
  done
}

# Recreate containers that are stuck in a restart loop, from their own compose
# project. A running stack is deliberately left alone (see stack_is_running),
# so a compose change — a fixed command, a new env var — otherwise waits for a
# manual redeploy. A container that is crash-looping is already broken, though,
# so rebuilding it from its current compose file can only help, and that is what
# lets a fix take effect on the next ./setup.sh or ./update.sh. Healthy
# containers are never touched.
recreate_restarting_containers() {
  local c svc proj dir
  for c in $(docker ps --filter status=restarting --format '{{.Names}}' 2>/dev/null); do
    svc=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)
    proj=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
    dir=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
    [ -n "$svc" ] && [ -n "$proj" ] && [ -n "$dir" ] && [ -d "$dir" ] || continue
    note "$c is in a restart loop — recreating it from $dir"
    ( cd "$dir" && docker compose -p "$proj" up -d --force-recreate "$svc" ) \
      || echo "could not recreate $c — check: docker logs $c" >&2
  done
}

# True when a stack already has a running container. setup.sh and the hooks use
# this to leave a stack that is already up exactly as it is — no `up -d` (which
# can recreate a container when the compose file changed) and no pull. Applying
# a change is a deliberate act: Dockhand, or
# `docker compose -f <stack>/compose.yml up -d` by hand.
stack_is_running() {
  [ -n "$(docker compose -f "$1/compose.yml" ps --status running -q 2>/dev/null)" ]
}
