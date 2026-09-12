#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stacks.sh — act on every stack in this checkout at once.
#
#   ./stacks.sh              stop everything (same as `./stacks.sh stop`)
#   ./stacks.sh start        start what `stop` left behind
#   ./stacks.sh restart      restart the containers in place
#   ./stacks.sh status       one line per stack: running/total
#   ./stacks.sh down         remove the containers (volumes are kept)
#
# A stack is any directory here with a compose.yml — the same rule setup.sh
# uses — so adding a stack needs no edit here. Containers are matched by
# compose's own project label *and* the checkout they were created from, so
# this never touches another checkout's containers, or the host's own Docker
# workloads.
#
# `stop` keeps the containers, so `start` brings them back exactly as they
# were: no compose file is read and no .env is needed. Use `down` to remove
# them, or, to pick up a changed compose.yml or .env:
#
#   docker compose -f <stack>/compose.yml up -d --force-recreate
#
# (A bind-mounted config file — traefik.yml, say — is invisible to
# `docker compose up -d`: the container is not recreated, so the old
#  configuration keeps running. Restart or force-recreate it.)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO_DIR"

usage() {
  cat <<'EOF'
usage: ./stacks.sh [stop|start|restart|status|down]

  stop      stop every stack's containers (default). Containers, their data
            and the networks are kept, so `start` brings them straight back.
  start     start the containers `stop` left behind. A stack with no
            containers at all is started from its compose file instead.
  restart   restart every stack's containers in place.
  status    one line per stack: running/total containers.
  down      remove every stack's containers. Volumes are kept; the external
            app-bridge and app-macvlan networks are never removed.

To pick up a changed compose.yml or .env, use `down` then `start`, or:
  docker compose -f <stack>/compose.yml up -d --force-recreate
EOF
}

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- what counts as a stack -------------------------------------------------
STACKS=()
for d in */; do
  d=${d%/}
  [ -f "$d/compose.yml" ] && STACKS+=("$d")
done
[ ${#STACKS[@]} -gt 0 ] || die "no stacks found: no <dir>/compose.yml under $REPO_DIR"

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker ps >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is $(id -un) in the docker group?)"

# --- containers belonging to a stack in *this* checkout ---------------------
# docker's label filter is an exact match, so the project name selects the
# candidates and the working directory confirms the checkout.
stack_ids() {
  local stack=$1 cid wd
  while read -r cid; do
    [ -n "$cid" ] || continue
    wd=$(docker inspect "$cid" --format \
      '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
    case "$wd" in
      "$REPO_DIR"/*) printf '%s\n' "$cid" ;;
    esac
  done < <(docker ps -aq --filter "label=com.docker.compose.project=$stack")
}

names_for() {
  local id
  for id in "$@"; do
    docker inspect "$id" --format '{{.Name}}' 2>/dev/null | sed 's#^/##'
  done
}

running_for() {
  local id n=0
  for id in "$@"; do
    [ "$(docker inspect "$id" --format '{{.State.Running}}' 2>/dev/null)" = true ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# --- actions ----------------------------------------------------------------
do_stop() {
  local stack ids total=0 moved=0
  say "Stopping every stack"
  for stack in "${STACKS[@]}"; do
    mapfile -t ids < <(stack_ids "$stack")
    total=$((total + ${#ids[@]}))
    if [ ${#ids[@]} -eq 0 ]; then
      note "$(printf '%-10s' "$stack") no containers"
      continue
    fi
    printf '    %-10s %s\n' "$stack" "$(names_for "${ids[@]}" | tr '\n' ' ')"
    docker stop "${ids[@]}" >/dev/null
    moved=$((moved + ${#ids[@]}))
  done
  say "Stopped $moved container(s) across ${#STACKS[@]} stack(s)"
  note "bring them back with: ./stacks.sh start"
}

do_start() {
  local stack ids
  say "Starting every stack"
  for stack in "${STACKS[@]}"; do
    mapfile -t ids < <(stack_ids "$stack")
    if [ ${#ids[@]} -eq 0 ]; then
      note "$(printf '%-10s' "$stack") no containers yet — creating from compose.yml"
      ( cd "$stack" && docker compose up -d ) || die "could not start $stack from its compose file"
      continue
    fi
    printf '    %-10s %s\n' "$stack" "$(names_for "${ids[@]}" | tr '\n' ' ')"
    docker start "${ids[@]}" >/dev/null
  done
  say "Done"
  if ! pgrep -f 'cert-watcher\.sh' >/dev/null 2>&1; then
    note "cert-watcher.sh is not running — start it with ./setup.sh, or:"
    note "  $REPO_DIR/traefik/generate_certificates/cert-watcher.sh &"
  fi
}

do_restart() {
  local stack ids
  say "Restarting every stack"
  for stack in "${STACKS[@]}"; do
    mapfile -t ids < <(stack_ids "$stack")
    if [ ${#ids[@]} -eq 0 ]; then
      note "$(printf '%-10s' "$stack") no containers"
      continue
    fi
    printf '    %-10s %s\n' "$stack" "$(names_for "${ids[@]}" | tr '\n' ' ')"
    docker restart "${ids[@]}" >/dev/null
  done
  say "Done"
}

do_status() {
  local stack ids n
  say "Stack status"
  for stack in "${STACKS[@]}"; do
    mapfile -t ids < <(stack_ids "$stack")
    n=$(running_for "${ids[@]}")
    printf '    %-10s %s/%s running' "$stack" "$n" "${#ids[@]}"
    if [ "${#ids[@]}" -gt 0 ]; then
      printf '   %s' "$(names_for "${ids[@]}" | tr '\n' ' ')"
    fi
    printf '\n'
  done
}

do_down() {
  local stack ids
  say "Removing every stack's containers"
  for stack in "${STACKS[@]}"; do
    mapfile -t ids < <(stack_ids "$stack")
    if [ ${#ids[@]} -eq 0 ]; then
      note "$(printf '%-10s' "$stack") no containers"
      continue
    fi
    printf '    %-10s %s\n' "$stack" "$(names_for "${ids[@]}" | tr '\n' ' ')"
    if ! ( cd "$stack" && docker compose down ); then
      warn "$stack: compose down failed (a missing .env will do that); containers were left alone"
      warn "recreate it with ./setup.sh, or remove them by hand: docker rm -f ${ids[*]}"
    fi
  done
  say "Done — volumes and the external networks are untouched"
}

case "${1:-stop}" in
  ""|stop)     do_stop ;;
  start)       do_start ;;
  restart)     do_restart ;;
  status)      do_status ;;
  down)        do_down ;;
  -h|--help|help) usage ;;
  *)           usage >&2; exit 1 ;;
esac
