## Module Description

Telegram-style one-way channels for MongooseIM. Admins post messages to a channel JID, and subscribers receive them. Unlike `mod_broadcast` (eager fan-out, no persistence), every channel message is appended to a per-channel log first and then pushed to currently-online subscribers. Offline subscribers catch up via a `history` IQ on next connect — this avoids the offline-store write amplification that breaks broadcast at channel scale (potentially millions of subscribers per channel).

### Roles

| Role         | Permissions                                          |
|--------------|------------------------------------------------------|
| `owner`      | All admin powers, plus delete channel and promote/demote admins |
| `admin`      | Post messages, list members, add/remove subscribers   |
| `subscriber` | Read-only: receives posts, can fetch history, can leave |

### How It Works

1. Channel state is managed via `wingtrill:channel` IQ stanzas: create / get / list / update / delete / join / leave / post / history / members / search / promote / demote / add / remove.
2. Each channel has a virtual JID of the form `channel.<channel_id>@<host>` and a unique handle (e.g. `news`) within a server.
3. Admins post either by sending a `<message/>` to the channel JID **or** by an IQ `<post/>` (preferred — returns the assigned message id).
4. The server (a) inserts the message into `channel_messages`, then (b) asynchronously fans it out to currently-online subscribers in 500-row chunks.
5. Subscribers fetch backlog with `<history id="N" before="M" limit="50"/>` (paginates backwards from `before`).

### Architecture

```
admin (IQ set, ns=wingtrill:channel, <post id="42"><body>..</body></post>)
  --> user_send_iq hook
      --> mod_channel:user_send_iq/3
          --> mod_channel_backend:store_message/4    (channel_messages)
          --> spawn fanout
              --> mod_channel_backend:list_subscribers/4   (paginated)
              --> ejabberd_router:route/3                  (one route per online sub)

subscriber (IQ get, <history id="42" before="1000" limit="50"/>)
  --> user_send_iq hook
      --> mod_channel:user_send_iq/3
          --> mod_channel_backend:fetch_history/4    (channel_messages)
```

Persisting before fan-out gives channel posts at-least-once delivery semantics from the perspective of subscribers who connect later — even if the server restarts mid-fanout, the message is durable and offline subs will see it on `<history/>`. Online delivery is best-effort (no per-subscriber retries on transient route failures).

### Public vs Private

- `type = "public"` — anyone can `<join handle="..."/>`. Listed in `<search/>`.
- `type = "private"` — `<join/>` returns `<forbidden/>`. Admins add subscribers via `<add jid="..." id="N"/>`. Not listed in search.

## Options

### `modules.mod_channel.backend`
* **Syntax:** non-empty string, one of `"rdbms"`
* **Default:** `"rdbms"`
* **Example:** `backend = "rdbms"`

## Example Configuration

```toml
[modules.mod_channel]
  backend = "rdbms"
```

## Database Schema

Four tables: `channels`, `channel_admins`, `channel_subscribers`, `channel_messages`. See `priv/migrations/postgres/2026-04-30-channels.sql` for the migration; the schema is also in `priv/pg.sql`.

## Wire Examples

Create a public channel:
```xml
<iq type="set" id="c1">
  <create xmlns="wingtrill:channel"
          handle="news" name="News" description="Daily updates" type="public"/>
</iq>
```

Subscriber joins by handle:
```xml
<iq type="set" id="c2">
  <join xmlns="wingtrill:channel" handle="news"/>
</iq>
```

Admin posts:
```xml
<iq type="set" id="c3">
  <post xmlns="wingtrill:channel" id="42">
    <body>Hello, subscribers!</body>
  </post>
</iq>
```

Subscriber fetches the last 50 messages:
```xml
<iq type="get" id="c4">
  <history xmlns="wingtrill:channel" id="42" limit="50"/>
</iq>
```

The `<history/>` reply contains `<msg id="..." sender="..." sent_at="..."><body>...</body></msg>` children, ordered newest-first. To page further back, set `before="<oldest_id_seen>"` in the next request.