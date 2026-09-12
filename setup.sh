#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# irabelle-stack bootstrap
#
#   ./setup.sh                          prepare .env files and the root CA,
#                                       then pick which stacks to start
#   ./setup.sh --stacks traefik,dockhand
#   ./setup.sh --no-start               prepare only
#   ./setup.sh --list                   list the stacks found in this repo
#
# Every immediate subdirectory that contains a compose.yml is a stack.
#
# What this script does NOT do, on purpose:
#   * it never creates directories — `docker compose up` and the certificate
#     scripts create what they need;
#   * it never issues service certificates — cert-watcher.sh does that;
#   * it never overwrites an existing .env, root CA or service certificate.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO_DIR"

START=1
LIST_ONLY=0
PICKED=()

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

  --stacks a,b   start these stacks without showing the menu
  --no-start     prepare .env files and the root CA only
  --list         list the stacks found in this repo and exit
  -h, --help     this text
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stacks)
      shift
      [ $# -gt 0 ] || { echo "--stacks needs a comma-separated value" >&2; exit 2; }
      IFS=',' read -r -a _picked <<<"$1"
      PICKED+=("${_picked[@]}")
      ;;
    --no-start) START=0 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# --- discover stacks ---------------------------------------------------------
STACKS=()
for d in */; do
  d=${d%/}
  [ -f "$d/compose.yml" ] && STACKS+=("$d")
done

if [ "${#STACKS[@]}" -eq 0 ]; then
  echo "No stacks found: no subdirectory contains a compose.yml" >&2
  exit 1
fi

if [ "$LIST_ONLY" = 1 ]; then
  printf '%s\n' "${STACKS[@]}"
  exit 0
fi

# --- .env in the repo root, copied into every stack --------------------------
# Symlinks would tie every stack to one set of values, but a future stack may
# need variables of its own — so each stack gets its own copy, created only
# when it does not have one yet.
#
# A stack that ships its own .env.example is described by that template: it
# wins over the root one, so a stack can carry extra variables (or different
# defaults) without touching the shared root template. Stacks without one
# inherit the root .env.
env_tld() {
  [ -f "$1" ] || return 0
  local v
  v=$(sed -n 's/^[[:space:]]*TLD[[:space:]]*=[[:space:]]*//p' "$1" | tail -n 1)
  v=${v%%#*}
  printf '%s' "$v" | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

say "Configuration"
if [ -f .env ]; then
  note ".env exists — left untouched"
elif [ -f .env.example ]; then
  cp .env.example .env
  note "created .env from .env.example — review it"
else
  echo "no .env and no .env.example at the repo root" >&2
  exit 1
fi

ROOT_TLD=$(env_tld .env)
for s in "${STACKS[@]}"; do
  if [ ! -f "$s/.env" ]; then
    if [ -f "$s/.env.example" ]; then
      cp "$s/.env.example" "$s/.env"
      note "$s/.env created from $s/.env.example"
    else
      cp .env "$s/.env"
      note "$s/.env created from .env"
    fi
    continue
  fi
  stack_tld=$(env_tld "$s/.env")
  if [ -n "$ROOT_TLD" ] && [ "$stack_tld" != "$ROOT_TLD" ]; then
    note "WARNING: $s/.env has TLD=${stack_tld:-<unset>} but .env has TLD=$ROOT_TLD"
    note "         service names will not match — edit one, or delete $s/.env to re-copy"
  else
    note "$s/.env exists — left untouched"
  fi
done

# --- root certificate --------------------------------------------------------
for s in "${STACKS[@]}"; do
  gen="$s/generate_certificates/1-generate-root-certificates.sh"
  [ -x "$gen" ] || continue
  say "Root certificate ($s)"
  if [ -f "$s/generate_certificates/root-certificates/root-ca.crt" ]; then
    note "already present — kept"
  else
    ( cd "$s/generate_certificates" && ./1-generate-root-certificates.sh )
  fi
  note "service certificates are issued by cert-watcher.sh, not by this script"
done

if [ "$START" = 0 ]; then
  say "Prepared."
  note "start a stack with: docker compose -f <stack>/compose.yml up -d"
  exit 0
fi

# --- pick stacks -------------------------------------------------------------
select_stacks() {
  local -a items=("$@")
  local n=${#items[@]} cur=0 i key rest
  local -a sel=()
  for ((i = 0; i < n; i++)); do sel[i]=0; done

  draw() {
    local j box ptr
    for ((j = 0; j < n; j++)); do
      box='[ ]'; ptr='  '
      if [ "${sel[j]}" = 1 ]; then box='[x]'; fi
      if [ "$j" = "$cur" ]; then ptr='> '; fi
      printf '\033[K%s%s %s\n' "$ptr" "$box" "${items[j]}"
    done
  }

  {
    printf '\n\033[1mSelect the stacks to start\033[0m\n'
    printf '  space = toggle   up/down = move   a = all   n = none   enter = confirm   q = cancel\n\n'
    draw
  } >&2

  while :; do
    IFS= read -rsn1 key || break
    case "$key" in
      $'\x1b')
        rest=''
        IFS= read -rsn2 -t 0.05 rest || true
        case "$rest" in
          '[A') cur=$(((cur - 1 + n) % n)) ;;
          '[B') cur=$(((cur + 1) % n)) ;;
        esac
        ;;
      ' ') sel[cur]=$((1 - sel[cur])) ;;
      'a') for ((i = 0; i < n; i++)); do sel[i]=1; done ;;
      'n') for ((i = 0; i < n; i++)); do sel[i]=0; done ;;
      'q') printf '\033[%dA\033[K\n' "$n" >&2; PICKED=(); return 0 ;;
      '') break ;;
    esac
    printf '\033[%dA' "$n" >&2
    draw >&2
  done
  printf '\n' >&2

  PICKED=()
  for ((i = 0; i < n; i++)); do
    if [ "${sel[i]}" = 1 ]; then PICKED+=("${items[i]}"); fi
  done
  return 0
}

say "Stacks"
if [ "${#PICKED[@]}" -eq 0 ]; then
  if [ -t 0 ] && [ -t 2 ]; then
    select_stacks "${STACKS[@]}"
  else
    note "no terminal for the menu — nothing started"
    note "use: ./setup.sh --stacks $(IFS=,; echo "${STACKS[*]}")"
    exit 0
  fi
else
  for p in "${PICKED[@]}"; do
    known=0
    for s in "${STACKS[@]}"; do [ "$p" = "$s" ] && known=1; done
    if [ "$known" != 1 ]; then
      echo "Unknown stack: $p (available: ${STACKS[*]})" >&2
      exit 2
    fi
  done
fi

if [ "${#PICKED[@]}" -eq 0 ]; then
  note "nothing selected — nothing started"
  exit 0
fi

# --- start -------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

# A stack that declares a network `external: true` cannot create it; the stack
# that owns the network can. Create it first so any selection works — except a
# macvlan/ipvlan network, which needs a VLAN interface on the host and is
# created by ./host-vlan.sh (see NETWORK.md). Creating one of those as a plain
# bridge would silently give containers the wrong connectivity.
#
# Ask compose for the resolved config rather than parsing the YAML ourselves: it
# normalises name/driver/external. An external network with no declared driver
# comes back with an empty driver, which is reported as `unknown` — deliberately
# not assumed to be a bridge.
external_networks() {
  docker compose -f "$1" config 2>/dev/null | awk '
    function flush() {
      if (in_net && ext && name != "") print name "\t" (driver == "" ? "unknown" : driver)
    }
    /^networks:/ { in_net = 1; name = ""; driver = ""; ext = 0; next }
    /^[^[:space:]]/ { flush(); in_net = 0; next }
    !in_net { next }
    /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      flush(); name = $1; sub(/:$/, "", name); driver = ""; ext = 0; next
    }
    /^[[:space:]]+name:[[:space:]]*/ { name = $2; next }
    /^[[:space:]]+driver:[[:space:]]*/ { driver = $2; next }
    /^[[:space:]]+external:[[:space:]]*true/ { ext = 1; next }
    END { flush() }
  '
}

for s in "${PICKED[@]}"; do
  say "Starting $s"
  while IFS=$'\t' read -r net drv; do
    [ -n "$net" ] || continue
    docker network inspect "$net" >/dev/null 2>&1 && continue
    case "$drv" in
      macvlan|ipvlan)
        printf '\n\033[31m%s\033[0m\n' \
          "$s needs the external $drv network '$net', which does not exist yet." >&2
        printf '    Create the host VLAN and that network first:\n' >&2
        printf '        sudo ./host-vlan.sh\n' >&2
        printf '    Then re-run this script. See NETWORK.md for the address plan.\n' >&2
        exit 1
        ;;
      unknown)
        printf '\n\033[31m%s\033[0m\n' \
          "$s declares the external network '$net' without a driver." >&2
        printf '    setup.sh will not guess — add one, e.g. `driver: bridge`\n' >&2
        printf '    (or `driver: macvlan` for a VLAN-backed network).\n' >&2
        exit 1
        ;;
      *)
        docker network create "$net" >/dev/null
        note "created docker network $net"
        ;;
    esac
  done < <(external_networks "$s/compose.yml")
  docker compose -f "$s/compose.yml" up -d
done

say "Started: ${PICKED[*]}"
note "services are published as <service>.$ROOT_TLD — see README.md for DNS and CA trust"
