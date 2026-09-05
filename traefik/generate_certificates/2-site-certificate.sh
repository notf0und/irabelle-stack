#!/bin/sh
set -e

DOMAIN=$1
if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

mkdir -p tmp
mkdir -p ../config/certificates

# Generate private key and CSR
openssl req -nodes -newkey rsa:2048 \
  -keyout tmp/$DOMAIN.key \
  -out tmp/$DOMAIN.csr \
  -subj "/C=NZ/ST=Auckland/L=Earth/O=Dis/CN=$DOMAIN"

# Extensions for site cert
EXT_CONF=$(mktemp)
cat <<EOF > $EXT_CONF
subjectAltName = DNS:$DOMAIN
authorityKeyIdentifier = keyid,issuer
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

# Sign with root CA
openssl x509 -req \
  -in tmp/$DOMAIN.csr \
  -CA root-certificates/root-ca.crt \
  -CAkey root-certificates/root-ca.key \
  -CAcreateserial \
  -out tmp/$DOMAIN.crt \
  -days 825 \
  -extfile $EXT_CONF

# Move to config
mv tmp/$DOMAIN.crt ../config/certificates/
mv tmp/$DOMAIN.key ../config/certificates/

# Cleanup
rm -f $EXT_CONF tmp/$DOMAIN.csr

echo "    - certFile: /config/certificates/$DOMAIN.crt" >> ../config/certificates/tls.yml
echo "      keyFile: /config/certificates/$DOMAIN.key" >> ../config/certificates/tls.yml

echo "✅ Site certificate generated: ../config/certificates/$DOMAIN.crt"
