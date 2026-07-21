-- Adds storage for mod_channel (Telegram-style one-way channels).
-- Apply against the running mongooseim database, e.g.:
--   psql -h localhost -p 5433 -U mongooseim -d mongooseim \
--        -f priv/migrations/postgres/2026-04-30-channels.sql

CREATE TABLE channels (
    id BIGSERIAL PRIMARY KEY,
    server VARCHAR(250) NOT NULL,
    owner VARCHAR(250) NOT NULL,
    handle VARCHAR(64) NOT NULL,
    name VARCHAR(250) NOT NULL,
    description VARCHAR(2000) NOT NULL DEFAULT '',
    channel_type VARCHAR(16) NOT NULL DEFAULT 'public',
    created_at BIGINT NOT NULL,
    UNIQUE (server, handle)
);

CREATE INDEX i_channels_owner ON channels(server, owner);
CREATE INDEX i_channels_search ON channels(server, channel_type, created_at DESC);

CREATE TABLE channel_admins (
    channel_id BIGINT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    admin_jid VARCHAR(500) NOT NULL,
    role VARCHAR(16) NOT NULL DEFAULT 'admin',
    added_at BIGINT NOT NULL,
    PRIMARY KEY (channel_id, admin_jid)
);

CREATE INDEX i_channel_admins_jid ON channel_admins(admin_jid);

CREATE TABLE channel_subscribers (
    channel_id BIGINT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    subscriber_jid VARCHAR(500) NOT NULL,
    joined_at BIGINT NOT NULL,
    PRIMARY KEY (channel_id, subscriber_jid)
);

CREATE INDEX i_channel_subscribers_jid ON channel_subscribers(subscriber_jid);
CREATE INDEX i_channel_subscribers_chan_join ON channel_subscribers(channel_id, joined_at);

CREATE TABLE channel_messages (
    id BIGSERIAL PRIMARY KEY,
    channel_id BIGINT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    sender_jid VARCHAR(500) NOT NULL,
    body TEXT NOT NULL,
    sent_at BIGINT NOT NULL
);

CREATE INDEX i_channel_messages_chan ON channel_messages(channel_id, id DESC);