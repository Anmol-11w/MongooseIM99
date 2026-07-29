## Module Description

WhatsApp-style broadcast lists for MongooseIM. The owner sends one message to a virtual JID and the server fans it out as N individual 1:1 messages — each recipient sees a normal private chat from the owner. Recipients reply directly to the owner; there is no shared room and recipients cannot see each other.

### How It Works

1. The owner manages lists via `wingtrill:broadcast` IQ stanzas: create / list / read / update / delete.
2. Each list has a virtual JID of the form `broadcast.<list_id>@<host>`.
3. When the owner sends a `<message/>` to that JID, `mod_broadcast` intercepts it on the `user_send_message` hook, looks up the members, and routes a copy to each — `from` = owner bare JID, `to` = member bare JID. The original stanza is dropped.
4. Senders who don't own the list receive `<forbidden/>`. Unknown list IDs receive `<item-not-found/>`.

### Architecture

```
client (IQ set, ns=wingtrill:broadcast, <create/>)
  --> user_send_iq hook
      --> mod_broadcast:user_send_iq/3
          --> mod_broadcast_backend:create_list/4
              --> mod_broadcast_rdbms        (broadcast_lists, broadcast_list_members)

client (<message to="broadcast.42@host"/>)
  --> user_send_message hook
      --> mod_broadcast:user_send_message/3
          --> mod_broadcast_backend:get_list_owner/2     (ownership check)
          --> mod_broadcast_backend:get_members/3        (load members)
          --> ejabberd_router:route/3                    (one route per member)
          --> {stop, Acc}                                (drop original)
```

The fan-out copies are *fresh* messages from the owner. Recipients have no way to tell the message came via a broadcast list — by design (matches WhatsApp's behavior on the recipient side). Each copy gets its `id` attribute stripped so that any client-side dedupe by stanza id doesn't collapse them.

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/broadcast/mod_broadcast.erl` | IQ handler, message fan-out, ownership checks |
| `src/custom/broadcast/mod_broadcast_backend.erl` | Backend proxy (`mongoose_backend`) |
| `src/custom/broadcast/mod_broadcast_rdbms.erl` | Postgres implementation, prepared queries |

## Dependencies

* `outgoing_pools.rdbms.default` — required for the `rdbms` backend.

No XMPP-module dependencies. The owner check is by bare JID equality; there is no roster integration, so a list can contain any JID the owner adds.

## Database

Two new tables in `priv/pg.sql`:

```sql
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
```

`member_jid` stores the bare JID as a binary; on insert, JIDs are lowercased and stripped of resource. Deleting a list cascades to its members.

## Options

| Name | Type | Default | Description |
| ---- | ---- | ------- | ----------- |
| `backend` | atom | `rdbms` | Storage backend. Only `rdbms` is implemented. |

## Example Configuration

```toml
[modules.mod_broadcast]
  backend = "rdbms"
```

## XMPP Protocol

### Namespace

`wingtrill:broadcast`

### Virtual JID Format

```
broadcast.<list_id>@<host>
```

`<list_id>` is the integer primary key returned by `<create/>`. The owner uses this JID as the `to` of any `<message/>` they want fanned out.

### List All My Lists

```xml
<iq type="get" id="b1">
  <query xmlns="wingtrill:broadcast"/>
</iq>
```

```xml
<iq type="result" id="b1">
  <query xmlns="wingtrill:broadcast">
    <list id="42" name="Friends" jid="broadcast.42@example.com"/>
    <list id="43" name="Family"  jid="broadcast.43@example.com"/>
  </query>
</iq>
```

The summary form omits members. Use `<list/>` (below) to fetch members for a single list.

### Get One List

```xml
<iq type="get" id="b2">
  <list xmlns="wingtrill:broadcast" id="42"/>
</iq>
```

```xml
<iq type="result" id="b2">
  <list xmlns="wingtrill:broadcast" id="42" name="Friends" jid="broadcast.42@example.com">
    <member jid="alice@example.com"/>
    <member jid="bob@example.com"/>
  </list>
</iq>
```

### Create a List

```xml
<iq type="set" id="b3">
  <create xmlns="wingtrill:broadcast" name="Friends">
    <member jid="alice@example.com"/>
    <member jid="bob@example.com"/>
  </create>
</iq>
```

```xml
<iq type="result" id="b3">
  <list xmlns="wingtrill:broadcast" id="42" name="Friends" jid="broadcast.42@example.com">
    <member jid="alice@example.com"/>
    <member jid="bob@example.com"/>
  </list>
</iq>
```

The `<member/>` children are optional — a list may be created empty and have members added later via `<update/>`.

### Update a List

```xml
<iq type="set" id="b4">
  <update xmlns="wingtrill:broadcast" id="42" name="Close Friends">
    <member jid="alice@example.com"/>
    <member jid="charlie@example.com"/>
  </update>
</iq>
```

* `name` (attribute, optional) — rename the list. Omit to leave unchanged.
* `<member/>` children — **replace** the entire member list. To preserve existing members, the client must include them. Omit the `<member/>` children entirely to leave the membership unchanged.

Result: empty `<iq type="result"/>`.

### Delete a List

```xml
<iq type="set" id="b5">
  <delete xmlns="wingtrill:broadcast" id="42"/>
</iq>
```

Result: empty `<iq type="result"/>`. Cascades to `broadcast_list_members`.

### Sending a Broadcast Message

```xml
<message type="chat" to="broadcast.42@example.com" id="m1">
  <body>Hi everyone!</body>
</message>
```

Each member receives:

```xml
<message type="chat" from="owner@example.com" to="alice@example.com">
  <body>Hi everyone!</body>
</message>
```

Notes:
* The original stanza is dropped — there is no echo back to the owner. Clients should optimistically render the outgoing message locally and rely on MAM for cross-device sync.
* Any payload (body, attachments, OOB, MAM-relevant elements) is preserved on each copy.
* Each copy lacks the original `id` so client-side dedupe doesn't collapse them.

### Error Responses

| Condition | Error |
| --------- | ----- |
| Sender is not the list owner | `<forbidden/>` |
| List ID does not exist | `<item-not-found/>` |
| Malformed IQ (missing/non-integer `id`, missing `name` on create, etc.) | `<bad-request/>` |
| DB failure during create | `<internal-server-error/>` |

## Security Notes

* **Ownership is enforced server-side** on every mutation and on every fan-out. A user who has somehow learned another user's `list_id` cannot read, modify, or send through it.
* **No recipient consent** — adding a JID to a broadcast list does not require subscription or approval. Recipients receive messages exactly as if the owner had typed them in a normal 1:1 chat. If you want to gate this by roster, add a `mod_user_privacy` field (e.g. `broadcast_invite`) and call `is_visible/4` in `fan_out/4` before routing each copy.
* **No member visibility on the recipient side** — recipients cannot enumerate other recipients of the same broadcast. The fan-out copies do not carry any `xmlns="wingtrill:broadcast"` marker.

## Limits

The module enforces no hard cap on member count. Each broadcast send issues N synchronous `ejabberd_router:route/3` calls inside the `user_send_message` hook, so very large lists will block the c2s process for the duration of the fan-out. If you need to support 1000+ member lists, consider moving the fan-out to an async worker.