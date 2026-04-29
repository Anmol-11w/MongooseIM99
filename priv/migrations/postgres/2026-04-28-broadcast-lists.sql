-- Adds storage for mod_broadcast (WhatsApp-style broadcast lists).
-- Apply against the running mongooseim database, e.g.:
--   psql -h localhost -p 5433 -U mongooseim -d mongooseim \
--        -f priv/migrations/postgres/2026-04-28-broadcast-lists.sql

CREATE TABLE broadcast_lists (
    id BIGSERIAL PRIMARY KEY,
    server VARCHAR(250) NOT NULL,
    owner VARCHAR(250) NOT NULL,
    name VARCHAR(250) NOT NULL,
    created_at BIGINT NOT NULL
);

CREATE INDEX i_broadcast_lists_owner ON broadcast_lists(server, owner);

CREATE TABLE broadcast_list_members (
    list_id BIGINT NOT NULL REFERENCES broadcast_lists(id) ON DELETE CASCADE,
    member_jid VARCHAR(500) NOT NULL,
    PRIMARY KEY (list_id, member_jid)
);