#!/bin/sh
# 1-generate-root-certificates.sh — create this stack's private root CA.
#
# Run once per client, before any leaf certificate. The CA (and especially
# root-ca.key) stays out of git; every client has its own.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CA_DIR="$SCRIPT_DIR/root-certificates"

mkdir -p "$CA_DIR"

if [ -f "$CA_DIR/root-ca.crt" ] && [ -f "$CA_DIR/root-ca.key" ]; then
  echo "✅ Root CA already exists: $CA_DIR/root-ca.crt (delete it to start over)"
  exit 0
fi

openssl req -x509 -nodes -newkey RSA:4096 \
  -keyout "$CA_DIR/root-ca.key" \
  -out "$CA_DIR/root-ca.crt" \
  -days 825 \
  -subj '/C=NZ/ST=Auckland/L=Earth/O=Irabelle/CN=Irabelle' \
  -addext "basicConstraints = critical, CA:TRUE" \
  -addext "keyUsage = critical, keyCertSign, cRLSign" \
  -addext "subjectKeyIdentifier = hash"

echo "✅ Root CA generated: $CA_DIR/root-ca.crt"
