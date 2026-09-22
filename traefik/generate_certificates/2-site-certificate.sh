#!/bin/sh
# 2-site-certificate.sh — issue one leaf certificate for a fully-qualified
# host, signed by this stack's local root CA.
#
#   ./2-site-certificate.sh traefik.smart
#   ./2-site-certificate.sh traefik.smart --force
#
# Nothing here knows about the TLD: the caller always passes a full hostname
# (cert-watcher.sh builds them from whatever Traefik routers are running).
#
# Writes ../config/certificates/<host>.{crt,key} and then refreshes
# ../config/certificates/tls.yml via 3-sync-tls-file.sh.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CERT_DIR="$SCRIPT_DIR/../config/certificates"
CA_DIR="$SCRIPT_DIR/root-certificates"

DOMAIN=${1:-}
FORCE=${2:-}

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <domain> [--force]" >&2
  exit 1
fi

if [ ! -f "$CA_DIR/root-ca.crt" ] || [ ! -f "$CA_DIR/root-ca.key" ]; then
  echo "No root CA found in $CA_DIR — run ./1-generate-root-certificates.sh first." >&2
  exit 1
fi

mkdir -p "$CERT_DIR" "$SCRIPT_DIR/tmp"

if [ -f "$CERT_DIR/$DOMAIN.crt" ] && [ -f "$CERT_DIR/$DOMAIN.key" ] && [ "$FORCE" != "--force" ]; then
  echo "✅ Site certificate already exists: $CERT_DIR/$DOMAIN.crt (pass --force to regenerate)"
  exec "$SCRIPT_DIR/3-sync-tls-file.sh"
fi

# Generate private key and CSR
openssl req -nodes -newkey rsa:2048 \
  -keyout "$SCRIPT_DIR/tmp/$DOMAIN.key" \
  -out "$SCRIPT_DIR/tmp/$DOMAIN.csr" \
  -subj "/C=NZ/ST=Auckland/L=Earth/O=Dis/CN=$DOMAIN"

# Extensions for site cert
EXT_CONF=$(mktemp)
trap 'rm -f "$EXT_CONF"' EXIT
cat <<EOF >"$EXT_CONF"
subjectAltName = DNS:$DOMAIN
authorityKeyIdentifier = keyid,issuer
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

# Sign with root CA
openssl x509 -req \
  -in "$SCRIPT_DIR/tmp/$DOMAIN.csr" \
  -CA "$CA_DIR/root-ca.crt" \
  -CAkey "$CA_DIR/root-ca.key" \
  -CAcreateserial \
  -out "$SCRIPT_DIR/tmp/$DOMAIN.crt" \
  -days 825 \
  -extfile "$EXT_CONF"

# Move to config
mv "$SCRIPT_DIR/tmp/$DOMAIN.crt" "$CERT_DIR/"
mv "$SCRIPT_DIR/tmp/$DOMAIN.key" "$CERT_DIR/"

# Cleanup
rm -f "$EXT_CONF" "$SCRIPT_DIR/tmp/$DOMAIN.csr"
trap - EXIT

# tls.yml is derived, never appended to.
"$SCRIPT_DIR/3-sync-tls-file.sh"

echo "✅ Site certificate generated: $CERT_DIR/$DOMAIN.crt"
