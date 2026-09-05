#!/bin/sh
# 5-cert-watcher.sh — watches Docker events and auto-generates per-host
# certificates for .ira services registered with Traefik.
#
# Runs on the host that has the Docker socket + the shared Traefik config
# (the station). Traefik's file provider (watch: true) picks up tls.yml
# changes automatically.
#
# Install with:  crontab -e  ->  @reboot .../generate_certificates/5-cert-watcher.sh
#
# Usage:
#   ./cert-watcher.sh          # run forever (docker events loop)
#   ./cert-watcher.sh --once   # single reconcile, then exit

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CERT_DIR="$SCRIPT_DIR/../config/certificates"
TLS_FILE="$CERT_DIR/tls.yml"
LOG_FILE="$SCRIPT_DIR/../config/logs/cert-watcher.log"
API_URL="https://localhost/api/http/routers"
LOCK_FILE="/tmp/traefik-cert-watcher.lock"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

# Extract .ira hosts from the running Traefik via its API.
# Falls back to scanning docker labels if the API is unreachable.
get_hosts() {
  hosts=$(curl -skL -H "Host: traefik" "$API_URL" 2>/dev/null \
    | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
hosts = set()
for r in data:
    for m in re.finditer(r"Host\([\"`]([^\"`]+)[\"`]\)", r.get("rule", "")):
        h = m.group(1)
        if h.endswith(".ira"):
            hosts.add(h)
for h in sorted(hosts):
    print(h)
' 2>/dev/null) || true

  if [ -z "$hosts" ]; then
    # fallback: scan traefik labels of running containers
    hosts=$(docker inspect $(docker ps -q) 2>/dev/null \
      | python3 -c '
import json, re, sys
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
                if h.endswith(".ira"):
                    hosts.add(h)
for h in sorted(hosts):
    print(h)
' 2>/dev/null) || true
  fi

  echo "$hosts"
}

# Generate a certificate for $1 if missing, and ensure a tls.yml entry.
generate_for() {
  host=$1
  cert="$CERT_DIR/$host.crt"

  if [ ! -f "$cert" ]; then
    log "New .ira service detected: $host — generating certificate"
    (cd "$SCRIPT_DIR" && ./2-site-certificate.sh "$host") >>"$LOG_FILE" 2>&1
  elif ! grep -q "certFile: /config/certificates/$host.crt" "$TLS_FILE"; then
    log "Certificate for $host exists but is missing from tls.yml — adding entry"
    printf '    - certFile: /config/certificates/%s.crt\n      keyFile: /config/certificates/%s.key\n' \
      "$host" "$host" >>"$TLS_FILE"
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
log "Watching Docker events for new .ira services..."

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
