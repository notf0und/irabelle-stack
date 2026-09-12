#!/bin/sh
# 3-sync-tls-file.sh — rebuild ../config/certificates/tls.yml from the
# certificates that actually exist on disk.
#
# tls.yml is generated (and gitignored), so it must never be hand-edited and
# it must always be derivable: no append-only drift, no duplicates, and a
# brand-new client that has just cloned the repo gets a valid file.
#
# Traefik's file provider runs with watch: true, so it picks up the change.
#
# Usage: ./3-sync-tls-file.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CERT_DIR="$SCRIPT_DIR/../config/certificates"
TLS_FILE="$CERT_DIR/tls.yml"

mkdir -p "$CERT_DIR"

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

{
  printf 'tls:\n'
  printf '  certificates:\n'
  for crt in "$CERT_DIR"/*.crt; do
    [ -e "$crt" ] || continue
    base=$(basename "$crt" .crt)
    [ -f "$CERT_DIR/$base.key" ] || continue
    printf '    - certFile: /config/certificates/%s.crt\n' "$base"
    printf '      keyFile: /config/certificates/%s.key\n' "$base"
  done
} >"$TMP_FILE"

if [ -f "$TLS_FILE" ] && cmp -s "$TMP_FILE" "$TLS_FILE"; then
  echo "tls.yml already up to date ($TLS_FILE)"
  exit 0
fi

mv "$TMP_FILE" "$TLS_FILE"
trap - EXIT
echo "✅ tls.yml written: $TLS_FILE"
