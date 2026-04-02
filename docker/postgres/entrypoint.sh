#!/bin/bash
set -e

# Copy SSL certs and fix permissions before postgres starts.
# Must run as root (user: root in docker-compose.yml).
mkdir -p /var/ssl/postgres
cp /tmp/ssl/cert.pem /var/ssl/postgres/cert.pem
cp /tmp/ssl/key.pem  /var/ssl/postgres/key.pem
chown 999:999 /var/ssl/postgres/cert.pem /var/ssl/postgres/key.pem
chmod 644 /var/ssl/postgres/cert.pem
chmod 600 /var/ssl/postgres/key.pem

exec "$@"