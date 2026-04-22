#!/bin/bash
# generate-mongooseim-certs.sh
# Usage: ./generate-mongooseim-certs.sh
# This script generates a CA, client key/cert, and places them in priv/ssl/

set -e

CERT_DIR="priv/ssl"
mkdir -p "$CERT_DIR"

# 1. Generate CA key and certificate
openssl genrsa -out "$CERT_DIR/ca-key.pem" 4096
openssl req -x509 -new -nodes -key "$CERT_DIR/ca-key.pem" -sha256 -days 3650 -out "$CERT_DIR/cacert.pem" -subj "/CN=MyMongooseIMCA"

# 2. Generate client key and CSR
openssl genrsa -out "$CERT_DIR/client-key.pem" 4096
openssl req -new -key "$CERT_DIR/client-key.pem" -out "$CERT_DIR/client.csr" -subj "/CN=mongooseim-client"

# 3. Sign the client certificate with the CA
openssl x509 -req -in "$CERT_DIR/client.csr" -CA "$CERT_DIR/cacert.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial -out "$CERT_DIR/client-cert.pem" -days 365 -sha256

# 4. Clean up
rm -f "$CERT_DIR/client.csr" "$CERT_DIR/ca-key.pem" "$CERT_DIR/ca-key.srl"

echo "Certificates generated in $CERT_DIR:"
echo "- client-cert.pem"
echo "- client-key.pem"
echo "- cacert.pem"
