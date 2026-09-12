#!/bin/sh
# cert-watcher.sh — watches Docker events and auto-generates a per-host
# certificate for every service published through Traefik under this stack's
# internal domain.
#
# Runs on the host that has the Docker socket and the shared Traefik config.
# Traefik's file provider (watch: true) picks up tls.yml changes automatically.
#
# The domain suffix is NOT hardcoded: it is read from the stack .env (TLD=...),
# so renaming the internal domain needs no edit here.
#
# Install with:  crontab -e
#   @reboot /home/carlos/irabelle-stack/traefik/generate_certificates/cert-watcher.sh
#
# Usage:
#   ./cert-watcher.sh          # run forever (docker events loop)
#   ./cert-watcher.sh --once   # single reconcile, then exit
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CERT_DIR="$SCRIPT_DIR/../config/certificates"
# Overridable so an unwritable config/logs (see below) is not a dead end:
#   CERT_WATCHER_LOG=/tmp/cert-watcher.log ./cert-watcher.sh
LOG_FILE=${CERT_WATCHER_LOG:-"$SCRIPT_DIR/../config/logs/cert-watcher.log"}
API_URL="https://localhost/api/http/routers"
LOCK_FILE="/tmp/traefik-cert-watcher.lock"

# --- TLD (domain suffix) ----------------------------------------------------
# Single source of truth: <stack>/.env. Falls back to "test" if unset.
if [ -f "$STACK_DIR/.env" ]; then
  TLD=$(sed -n 's/^[[:space:]]*TLD[[:space:]]*=[[:space:]]*//p' "$STACK_DIR/.env" | tail -n 1)
  TLD=${TLD%%#*}
  TLD=$(printf '%s' "$TLD" | tr -d '"' | tr -d "'" | tr -d '[:space:]')
fi
TLD=${TLD:-test}

mkdir -p "$(dirname -- "$LOG_FILE")" "$CERT_DIR" 2>/dev/null || true

# Logging must never be fatal: this runs as the checkout owner (from cron),
# while Traefik — root, inside its container — creates config/logs for its own
# log file, so appending here can hit EACCES. Under `set -e` the failing tee
# used to abort the run *after* printing "generating certificate" and before
# issuing anything, which looks exactly like a watcher that does nothing. The
# default ACL setup.sh puts on that directory is what stops it recurring.
LOG_WARNED=0
log() {
  _msg=$(printf '[%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")
  printf '%s\n' "$_msg"
  if ! printf '%s\n' "$_msg" >>"$LOG_FILE" 2>/dev/null; then
    if [ "$LOG_WARNED" -eq 0 ]; then
      LOG_WARNED=1
      printf 'warning: cannot write %s — logging to stdout only\n' "$LOG_FILE" >&2
      printf '         fix once with: sudo chown -R %s:%s %s\n' \
        "$(id -un)" "$(id -gn)" "$(dirname -- "$LOG_FILE")" >&2
    fi
  fi
  return 0
}

# Extract <service>.<TLD> hosts from the running Traefik via its API.
# Falls back to scanning docker labels if the API is unreachable.
get_hosts() {
  hosts=$(curl -skL -H "Host: traefik" "$API_URL" 2>/dev/null \
    | python3 -c '
import json, re, sys
tld = sys.argv[1]
suffix = "." + tld
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
hosts = set()
for r in data:
    for m in re.finditer(r"Host\([\"`]([^\"`]+)[\"`]\)", r.get("rule", "")):
        h = m.group(1)
        if h.endswith(suffix) and h != suffix:
            hosts.add(h)
for h in sorted(hosts):
    print(h)
' "$TLD" 2>/dev/null) || true

  if [ -z "$hosts" ]; then
    # fallback: scan traefik labels of running containers
    hosts=$(docker inspect $(docker ps -q) 2>/dev/null \
      | python3 -c '
import json, re, sys
tld = sys.argv[1]
suffix = "." + tld
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
hosts = set()
for d in data:
    labels = d.get("Config", {}).get("Labels", {})
    for k, v in labels.items():
        if k.startswith("traefik.http.routers.") and k.endswith(".rule"):
            for m in re.finditer(r"Host\([\"`]([^\"`]+)[\"`]\)", v or ""):
                h = m.group(1)
                if h.endswith(suffix) and h != suffix:
                    hosts.add(h)
for h in sorted(hosts):
    print(h)
' "$TLD" 2>/dev/null) || true
  fi

  echo "$hosts"
}

# Generate a certificate for $1 if missing; refresh tls.yml either way.
generate_for() {
  host=$1
  cert="$CERT_DIR/$host.crt"

  if [ ! -f "$cert" ]; then
    log "New .$TLD service detected: $host — generating certificate"
    (cd "$SCRIPT_DIR" && ./2-site-certificate.sh "$host") >>"$LOG_FILE" 2>&1
  else
    (cd "$SCRIPT_DIR" && ./3-sync-tls-file.sh) >>"$LOG_FILE" 2>&1
  fi
}

reconcile() {
  new_hosts=$(get_hosts)
  [ -z "$new_hosts" ] && return 0
  for host in $new_hosts; do
    generate_for "$host"
  done
}

exec 9>"$LOCK_FILE"
# exit immediately if another instance is already running
if ! flock -n 9; then
  echo "Another instance is already running (lock held on $LOCK_FILE) — exiting"
  exit 0
fi

if [ "${1:-}" = "--once" ]; then
  reconcile
  exit 0
fi

reconcile
log "Watching Docker events for new .$TLD services..."

while true; do
  # timeout forces a periodic full reconcile even without events
  timeout 300 docker events \
    --filter event=create --filter event=start --filter event=update \
    --filter event=stop --filter event=die --filter event=destroy \
    --filter event=rename \
    --format '{{.Status}}' \
    | while read -r _ev; do
        # brief delay lets Traefik register the new container's router first
        sleep 3
        reconcile
      done || true
  log "Docker events stream ended/timeout — re-syncing"
  reconcile
  sleep 5
done
