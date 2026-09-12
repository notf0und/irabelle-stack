#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update.sh — pull this checkout and make any new stacks *available* in
# Dockhand. It never deploys: new stacks simply appear, waiting for you.
#
#   ./update.sh                pull, then register anything new
#   ./update.sh --dry-run      report what would change; no pull, no writes
#   ./update.sh --no-pull      register what is on disk now, without pulling
#   ./update.sh --path DIR     scan DIR instead of this checkout
#   ./update.sh --deploy       deploy whatever was newly adopted (opt-in)
#
# Built for cron, installed by ./setup.sh:
#
#   0 */12 * * * /home/carlos/irabelle-stack/update.sh
#
# Dockhand has no directory watcher, so a stack added to this repo does not
# register itself. What it does expose is the API behind its Import button:
#
#   POST /api/stacks/scan    find compose files under a path
#   POST /api/stacks/adopt   register the ones you choose
#
# This script scans the checkout, subtracts what Dockhand already tracks, and
# adopts the rest. Adopted stacks are *Internal*: their compose and .env files
# stay where they are, in this repo — which is why the .env files ./setup.sh
# creates keep working and no Dockhand environment panel is needed.
#
# Registration on its own is inert: nothing is started, stopped or restarted
# unless you pass --deploy.
#
# Environment:
#   DOCKHAND_URL     default: the dockhand container's address (via docker)
#   DOCKHAND_TOKEN   bearer token, needed only once Dockhand auth is enabled
#   DOCKHAND_ENV     environment name or id (default: the first one)
#   UPDATE_LOCK      lock file (default /tmp/irabelle-update.lock)
# ---------------------------------------------------------------------------
set -euo pipefail

# The checkout to scan: the directory holding this script, or the current
# directory when piped in (ssh host 'bash -s' < update.sh).
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  REPO_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
else
  REPO_DIR=$PWD
fi

DRY_RUN=0
DO_PULL=1
DO_DEPLOY=0
SCAN_PATH=$REPO_DIR

say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./update.sh [options]

  --dry-run      list what would be adopted; no pull, no writes
  --no-pull      skip git and register what is on disk now
  --path DIR     scan DIR instead of this checkout
  --deploy       deploy the stacks that were newly adopted
  -h, --help     this text

Environment: DOCKHAND_URL, DOCKHAND_TOKEN, DOCKHAND_ENV, UPDATE_LOCK
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-pull) DO_PULL=0 ;;
    --deploy) DO_DEPLOY=1 ;;
    --path) shift; SCAN_PATH=${1:?--path needs a value} ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# --- pull --------------------------------------------------------------------
# --ff-only on purpose: on a box nobody is watching, refusing is better than
# inventing a merge commit. Local edits stop it here too, which is what we
# want — an unclean checkout should not be registered. A dry run never pulls.
if [ "$DRY_RUN" = 1 ]; then
  say "Dry run — not pulling"
elif [ "$DO_PULL" = 0 ]; then
  say "Not pulling (--no-pull)"
elif [ ! -d "$REPO_DIR/.git" ]; then
  say "Not a git checkout — nothing to pull"
else
  say "Pulling"
  before=$(git -C "$REPO_DIR" rev-parse --short HEAD)
  if ! git -C "$REPO_DIR" pull --ff-only; then
    printf '\n\033[31m%s\033[0m\n' "git pull failed — Dockhand left untouched." >&2
    echo "Usually local edits in the checkout, or a diverged branch." >&2
    exit 1
  fi
  after=$(git -C "$REPO_DIR" rev-parse --short HEAD)
  if [ "$before" = "$after" ]; then
    note "already at $after"
  else
    note "$before -> $after"
  fi
fi

# --- Dockhand API ------------------------------------------------------------
if [ -z "${DOCKHAND_URL:-}" ]; then
  cid_ip=$(docker inspect dockhand \
      --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null \
      | awk '{print $1}')
  [ -n "$cid_ip" ] || die "cannot find the dockhand container — set DOCKHAND_URL"
  DOCKHAND_URL="http://$cid_ip:3000"
fi
DOCKHAND_URL=${DOCKHAND_URL%/}

api() {
  local method=$1 path=$2 body=${3:-}
  local auth=()
  [ -n "${DOCKHAND_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $DOCKHAND_TOKEN")
  # -f so an HTTP error fails here, instead of an error body being handed to the
  # JSON parsers and surfacing as something misleading like "no environments".
  if [ -n "$body" ]; then
    curl -fsS -m 120 -X "$method" "$DOCKHAND_URL$path" "${auth[@]}" \
         -H 'Content-Type: application/json' --data-binary "$body"
  else
    curl -fsS -m 120 -X "$method" "$DOCKHAND_URL$path" "${auth[@]}"
  fi
}

# A lock only matters when we are about to write, so a dry run always works —
# even while the cron job is mid-run.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ "$DRY_RUN" = 0 ]; then
  exec 9>"${UPDATE_LOCK:-/tmp/irabelle-update.lock}"
  if ! flock -n 9; then
    echo "another update is already running — exiting"
    exit 0
  fi
fi

say "Dockhand at $DOCKHAND_URL"
api GET /api/environments >"$TMP/envs.json" \
  || die "cannot reach the Dockhand API at $DOCKHAND_URL"
api GET /api/stacks/sources >"$TMP/sources.json" \
  || die "Dockhand rejected GET /api/stacks/sources"

say "Scanning $SCAN_PATH"
api POST /api/stacks/scan "{\"path\":\"$SCAN_PATH\"}" >"$TMP/scan.json"

python3 - "$TMP" "${DOCKHAND_ENV:-}" <<'PY'
import json, sys

tmp, envsel = sys.argv[1], sys.argv[2]

def load(name, default):
    try:
        with open(f"{tmp}/{name}") as fh:
            return json.load(fh)
    except Exception:
        return default

envs = load("envs.json", [])
sources = load("sources.json", {})
scan = load("scan.json", {})

if not envs:
    sys.exit("Dockhand has no environments configured.\n"
             "        Add one in Dockhand (Settings -> Environments), then re-run.")

if envsel:
    matches = [e for e in envs if str(e.get("id")) == envsel or e.get("name") == envsel]
    if not matches:
        sys.exit(f"no environment matches {envsel!r}")
    env = matches[0]
else:
    env = envs[0]

tracked = set(sources) if isinstance(sources, dict) else {
    s.get("stackName") for s in sources
}

# Dockhand reports the stacks it already tracks under `skipped`, and ones it
# has only just found under `discovered`.
discovered = scan.get("discovered", [])
skipped = scan.get("skipped", [])
new = [d for d in discovered
       if d.get("name") not in tracked and not d.get("unadoptable")]
known = list(skipped) + [d for d in discovered if d not in new]

with open(f"{tmp}/adopt.json", "w") as fh:
    json.dump({
        "environmentId": env["id"],
        "stacks": [{"name": d["name"], "composePath": d["composePath"]} for d in new],
    }, fh)
with open(f"{tmp}/names.txt", "w") as fh:
    fh.write("\n".join(d["name"] for d in new))

print(f"    environment  : {env.get('name')} (id {env['id']})")
print(f"    on disk      : {len(skipped) + len(discovered)}")
print(f"    already known: {len(known)}")
for d in known:
    print(f"       {d['name']:<20} {d.get('serviceCount', '?')} service(s)")
for d in new:
    print(f"     + {d['name']:<20} {d.get('serviceCount', '?')} service(s)")
print(f"    to adopt     : {len(new)}")
PY

if [ ! -s "$TMP/names.txt" ]; then
  say "Nothing new — Dockhand already tracks every stack here."
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  say "--dry-run: nothing was adopted."
  note "drop --dry-run to adopt them."
  exit 0
fi

say "Adopting"
api POST /api/stacks/adopt "$(cat "$TMP/adopt.json")" >"$TMP/adopt-result.json"
python3 - "$TMP" <<'PY'
import json, sys
tmp = sys.argv[1]
try:
    res = json.load(open(f"{tmp}/adopt-result.json"))
except Exception:
    print(open(f"{tmp}/adopt-result.json").read()[:500])
    raise SystemExit(0)
for name in res.get("adopted", []):
    print(f"    adopted {name}")
for f in res.get("failed", []):
    print(f"    FAILED  {f.get('name')}: {f.get('error')}")
PY

if [ "$DO_DEPLOY" = 1 ]; then
  say "Deploying"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '    %-20s ' "$name"
    if api POST "/api/stacks/$name/deploy" "{}" >"$TMP/deploy-$name.json" 2>&1; then
      echo "requested"
    else
      echo "FAILED (see $TMP/deploy-$name.json)"
    fi
  done <"$TMP/names.txt"
  note "this only fires the request — watch the result in Dockhand"
else
  say "Adopted and ready to deploy."
  note "Deploy them from Dockhand, or re-run with --deploy."
fi
