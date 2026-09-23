#!/bin/bash
# Trust the root CA (traefik/generate_certificates) inside Kavita at container start.
#
# Why this exists: the LinuxServer base image installs ca-certificates but never
# runs `update-ca-certificates` at boot. A cert bind-mounted into
# /usr/local/share/ca-certificates therefore stays invisible: both .NET and curl
# verify against the generated bundle at /etc/ssl/certs/ca-certificates.crt.
#
# Kavita is .NET and fetches the OIDC discovery document from
# https://authentik.$TLD/application/o/kavita/.well-known/openid-configuration
# over TLS. Without this it fails with:
#   AuthenticationException: The remote certificate is invalid because of
#   errors in the certificate chain: PartialChain
#
# compose.yml mounts this script as
# /custom-cont-init.d/10-update-ca-certificates.sh:ro, which the image's
# init-custom-files step executes (before svc-kavita starts) because it is
# executable.
set -euo pipefail

CA_SRC=/usr/local/share/ca-certificates/root-ca.crt

if [[ -f "$CA_SRC" ]]; then
    echo "[kavita-ca] merging $(basename "$CA_SRC") into the system trust store"
    update-ca-certificates
else
    echo "[kavita-ca] $CA_SRC not mounted; skipping (TLS to *.$TLD will fail)"
fi
