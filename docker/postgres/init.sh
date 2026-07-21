#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE ROLE mongooseim WITH PASSWORD 'mongooseim_secret' LOGIN;
    CREATE DATABASE mongooseim OWNER mongooseim;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname mongooseim \
    -f /docker-init/pg.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname mongooseim <<-EOSQL
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO mongooseim;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO mongooseim;
    GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO mongooseim;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO mongooseim;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO mongooseim;
EOSQL
