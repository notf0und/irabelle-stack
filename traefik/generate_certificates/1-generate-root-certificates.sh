#!/bin/sh
set -e

mkdir -p root-certificates

openssl req -x509 -nodes -newkey RSA:4096 \
  -keyout root-certificates/root-ca.key \
  -out root-certificates/root-ca.crt \
  -days 825 \
  -subj '/C=NZ/ST=Auckland/L=Earth/O=Irabelle/CN=Irabelle' \
  -addext "basicConstraints = critical, CA:TRUE" \
  -addext "keyUsage = critical, keyCertSign, cRLSign" \
  -addext "subjectKeyIdentifier = hash"

echo "✅ Root CA generated: root-certificates/root-ca.crt"
