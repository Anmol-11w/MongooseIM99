## Module Description

Three things, all attached to `mod_event_pusher` events for a 1:1
conversation (`erlang-solutions.com:xmpp:inbox:0`, see `mod_inbox`, and
`phone_contacts`, populated by `mod_contact_sync`):

1. Suppresses push-notification events (RabbitMQ, or any other enabled
   backend) for conversations that are muted.
2. Attaches the recipient's **total unread count across every conversation**
   as a `badge` field on every event that *isn't* suppressed, so downstream
   consumers (e.g. `wingtrill-notifier`) can set a native badge count on the
   push — matching how every other chat app's app-icon badge behaves (not
   just unread count from the one sender in this event).
3. Attaches the sender's **registered phone number** (if any) as a
   `from_phone` field, so a push can show a human-readable phone number
   instead of a raw XMPP JID/username as the notification title.

Neither `mod_event_pusher_rabbit`, `mod_inbox`, nor `mod_contact_sync` know
about each other — without this module, muting a conversation only changes
what a client sees in its inbox list (it does **not** stop a push from being
sent), and no event carries a badge count or phone number at all.

### How It Works

1. `mod_event_pusher:push_event/2` fires the shared `push_event` hook once
   per event (presence, 1:1 chat, groupchat, unacked message), *before* any
   backend (rabbit/http/push/sns) runs.
2. `mod_inbox_mute_pusher` hooks `push_event` at a lower priority than every
   backend, so it always runs first.
3. For a delivered-to-recipient 1:1 chat event
   (`#chat_event{type = chat, direction = out}`), it checks the
   `{recipient, sender}` conversation's `muted_until` (cached — see
   "Caching" below; falls back to `mod_inbox_backend:get_entry_properties/2`
   on a miss).
4. If muted, it returns `{stop, HookAcc}` **immediately** — `gen_hook`'s fold
   stops calling any further, lower-priority-number handlers once one
   returns `stop`, so the event never reaches `mod_event_pusher_rabbit` (or
   any other backend) at all. The total-unread lookup (step 5) is skipped
   entirely in this case.
5. Otherwise, it looks up the recipient's **total** unread count across
   every conversation (cached — see "Caching" below; falls back to a
   `SUM(unread_count) ... WHERE luser = ...` query this module runs itself),
   sets `HookAcc.metadata.badge = total + 1` (see the caveat below).
6. It also looks up the sender's phone number from `phone_contacts` (cached
   — see "Caching" below), and, if one is on file, sets
   `HookAcc.metadata.from_phone`. Omitted entirely if the sender has never
   authenticated via JWT (no phone recorded).
7. Returns `{ok, HookAcc}`. `mod_event_pusher_rabbit` already merges
   `metadata` into every published event's JSON
   (`mod_event_pusher_rabbit.erl:129`), so `"badge"`/`"from_phone"` show up
   in the published payload automatically — no changes needed there.
8. For everything else (presence, groupchat, the sender's own
   `chat_msg_sent` mirror), it returns `{ok, HookAcc}` unchanged — no badge,
   no phone lookup, no mute check, published exactly as before.

Muting only affects the *push*. The underlying message delivery and
`mod_inbox`'s own bookkeeping (unread count, box, etc.) are completely
unaffected — this module never touches `mod_inbox`'s own hooks, and its only
write is the opportunistic expired-mute clear described below.

**Badge caveat:** this hook runs *before* `mod_inbox`'s own
`filter_local_packet` handler (priority 90 vs. the translator that triggers
`push_event` at priority 80) — the one that actually increments
`unread_count` for the current message. So the total read here is
*pre-this-message*, hence `+ 1`. This is a best-effort approximation (the
same approach many chat apps take server-side), not an authoritative count —
the client's own next inbox fetch is the real reconciliation point.

### Caching

This hook runs on every 1:1 chat message, so both reads it needs are cached
with a short, millisecond-granular TTL rather than hitting the DB every
time — via a small hand-rolled ETS table for each, **not**
`mongoose_user_cache` (an earlier version of this module used it for the
total-unread count and hit a real bug from doing so): its `time_to_live`
option is in **minutes**, not seconds or milliseconds — a plain integer is
passed straight to `timer:minutes/1` by the underlying `segmented_cache`
library — and its segment-rotation model is built for much longer-lived
data (its own default is `2` minutes per segment × `3` segments = up to 6
minutes before an untouched entry is ever dropped). That's a poor fit for a
value that should resync with the database within a couple of seconds.

* **Mute check** (keyed by the `{recipient, sender}` pair) — table
  `inbox_mute_pusher_mute_cache`, TTL'd via the `mute_cache_ttl_ms` option
  (default `2000`ms). Also doesn't fit a single-JID-keyed cache cleanly
  regardless of TTL granularity: doing so would need a shared nested map per
  recipient with a shallow merge, which risks one sender's cached mute
  status clobbering another's under concurrent messages to the same
  recipient — a correctness risk, not just staleness. Writing the
  opportunistic expired-mute clear (below) also refreshes this cache entry
  immediately, rather than waiting out its own TTL.
* **Total-unread count** (keyed only by the recipient) — table
  `inbox_mute_pusher_unread_cache`, TTL'd via the `unread_cache_ttl_ms`
  option (default `2000`ms). `mod_inbox`'s own increment (a separate code
  path this module doesn't observe) never invalidates this cache, so on
  every use the cached value is also optimistically bumped to `total + 1`
  (the message this event represents) before returning. Without that bump,
  a burst of messages within one TTL window would all read the same stale
  total and report the identical badge instead of incrementing
  (`total+1, total+1, total+1, ...` instead of the correct
  `total+1, total+2, total+3, ...`). **Critically, the bump preserves the
  *original* fetch timestamp rather than resetting it** — an earlier
  version reset it on every write, which meant a sufficiently busy
  conversation could keep the entry perpetually "fresh" and never actually
  re-check the database at all, letting the cached value drift arbitrarily
  far from the true total. Preserving the original timestamp guarantees a
  hard resync every `unread_cache_ttl_ms`, independent of traffic volume.
* **Sender phone number** (keyed by the sender) — table
  `inbox_mute_pusher_phone_cache`, TTL'd via the `phone_cache_ttl_ms` option
  (default `60000`ms — phone numbers change far less often than unread
  counts or mute state, so a much longer TTL is fine here). A sender with no
  phone on file caches a sentinel (`no_phone`) rather than `undefined`, so a
  repeated miss doesn't re-query the database every time within the TTL
  window.

**Why not cache in the recipient's c2s session state instead?** Considered
and ruled out: this hook runs in whatever process routed the message
(typically the *sender's* c2s process — `mongoose_local_delivery.erl` fires
`filter_local_packet` well before `ejabberd_sm` ever dispatches to the
recipient's c2s pid), not the recipient's own session. Reaching a different
session's state needs a `mongoose_c2s:call/cast` round-trip to its pid, and
an **offline** recipient has no c2s process to hold or serve it from at all
— offline delivery is a separate, later hook (`offline_message`). So there's
no same-process, always-available session state to read here regardless of
design.

### Architecture

```
mod_event_pusher:push_event/2
  --> push_event hook (priority-ordered, lower runs first)
      --> mod_inbox_mute_pusher:push_event/3    (priority 10)
          --> mute cache (ETS, mute_cache_ttl_ms) --miss--> mod_inbox_backend:get_entry_properties/2
          --> muted?      {stop, HookAcc}  -- chain ends here, nothing published,
                                               total-unread lookup skipped
          --> not muted?  --> unread cache (ETS, unread_cache_ttl_ms) --miss-->
                              own SUM(unread_count) query (this module's own
                              prepared statement, not mod_inbox's)
                          --> phone cache (ETS, phone_cache_ttl_ms) --miss-->
                              own SELECT phone FROM phone_contacts query
                          --> {ok, HookAcc with metadata.badge = total + 1,
                                              metadata.from_phone = phone or omitted}
      --> mod_event_pusher_rabbit:push_event/3  (priority 50, only reached if not muted)
          --> publishes to RabbitMQ, JSON includes "badge"/"from_phone"
              --> wingtrill-notifier (notifier_amqp_consumer:dispatch/1)
                  --> title = from_phone if present, else the JID
                  --> notifier_fcm:send_one/4 sets apns.payload.aps.badge (iOS)
                      and data.badge (Android, stringified)
```

### Triggering a Mute (IQ)

Muting itself is handled entirely by `mod_inbox` (namespace
`erlang-solutions.com:xmpp:inbox:0#conversation`, see
`doc/open-extensions/inbox.md`) — this module doesn't add any IQ of its own,
it just reacts to the `muted_until` value that IQ writes. From a live c2s
session, a client mutes a conversation with no `to` attribute (implicitly
"handle this yourself"):

```xml
<iq id="mute1" type="set">
  <query xmlns="erlang-solutions.com:xmpp:inbox:0#conversation" jid="bob@localhost">
    <mute>3600</mute>
  </query>
</iq>
```

```xml
<iq id="mute1" type="result" to="alice@localhost/res1">
  <query xmlns="erlang-solutions.com:xmpp:inbox:0#conversation" jid="bob@localhost">
    <box>inbox</box>
    <archive>false</archive>
    <mute>2026-07-22T11:35:21.989031Z</mute>
    <read>true</read>
  </query>
</iq>
```

`<mute>` is seconds to mute for (`0` unmutes). The server computes the
absolute expiry from the current time, so all clients agree on one UTC
timestamp regardless of local clocks.

To unmute:

```xml
<iq id="unmute1" type="set">
  <query xmlns="erlang-solutions.com:xmpp:inbox:0#conversation" jid="bob@localhost">
    <mute>0</mute>
  </query>
</iq>
```

**Without a live client session** (e.g. admin testing via `mongooseimctl`),
`to` must be set explicitly to the muter's own bare JID — there's no session
to infer "self" from:

```bash
mongooseimctl stanza sendStanza --stanza "<iq id='mute1' type='set' from='alice@localhost' to='alice@localhost'><query xmlns='erlang-solutions.com:xmpp:inbox:0#conversation' jid='bob@localhost'><mute>3600</mute></query></iq>"
```

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/inbox_mute_pusher/mod_inbox_mute_pusher.erl` | `push_event` hook handler: mute lookup + short-circuit, total-unread lookup, sender-phone lookup, all three caches, badge/phone attachment |
| `src/inbox/mod_inbox_backend.erl` | (upstream) `get_entry_properties/2`/`set_entry_properties/3` — reused, unmodified |
| `src/event_pusher/mod_event_pusher_rabbit.erl` | (upstream) the backend this module pre-empts / feeds `metadata` to — unmodified |
| `src/rdbms/mongoose_rdbms.erl` | (upstream) `prepare/4`/`execute_successfully/3` — used directly by this module for its own `SUM(unread_count)` and `phone_contacts` queries, unmodified |
| `src/custom/contact_sync/mod_contact_sync.erl` | (upstream, custom) populates `phone_contacts` from the JWT `phone_number` claim — this module only reads it, unmodified |
| `wingtrill-notifier/src/amqp/notifier_amqp_consumer.erl` | (separate repo) reads `badge`/`from_phone` out of the published JSON, prefers `from_phone` for the notification title |
| `wingtrill-notifier/src/fcm/notifier_fcm.erl` | (separate repo) sets `apns.payload.aps.badge` / `data.badge` on the FCM send |

## Dependencies

* `mod_inbox` — must be enabled; this module reads its `inbox` table via
  `mod_inbox_backend:get_entry_properties/2`.
* `mod_event_pusher` (any backend, e.g. `rabbit`) — this module is only
  useful if at least one backend is configured; it hooks the shared
  `push_event` hook regardless of which backends are enabled.

## Database

No new tables. Reuses two existing tables:
* `inbox`'s `muted_until` for the per-conversation mute check, via the
  existing `get_entry_properties/2` backend call (unmodified core code).
* `inbox`'s `unread_count` for the total-unread badge, via a **new query
  this module prepares and runs itself** — `SELECT SUM(unread_count) FROM
  inbox WHERE lserver = ? AND luser = ? AND box = ?` — since no existing
  MongooseIM query gives a true cross-conversation total
  (`get_inbox_unread/2` is single-conversation only). Covered by the
  existing `i_inbox_us_box (lserver, luser, box)` index (`priv/pg.sql`) —
  no schema change needed.
* `phone_contacts`' `phone` column for the sender's phone number, via
  another new query this module runs itself — `SELECT phone FROM
  phone_contacts WHERE server = ? AND username = ?` — covered by the
  existing `i_phone_contacts_username (server, username)` index
  (`priv/pg.sql`).

One conditional write: `set_entry_properties/3` resets `muted_until` to `0`
when a mute is found to have already expired (see "Auto-clearing expired
mutes" below) — otherwise this module never writes.

## Scope / Limitations

* **1:1 chat only.** Only messages with stanza `type="chat"` in the
  delivered-to-recipient direction (`chat_msg_recv`) are checked.
* **Groupchat is intentionally not covered.** Resolving the correct Inbox
  "remote" JID for a MUC message requires affiliation lookups (see
  `mod_inbox:muclight_enabled/1` and related logic) that this module does
  not replicate — doing so naively risks matching the wrong inbox row.
  Groupchat push events are always published regardless of mute state, with
  no badge attached.
* Presence events and the sender's own `chat_msg_sent` mirror are never
  affected (no mute check, no badge).
* **`badge` is a `total + 1` approximation**, not authoritative — see the
  caveat under "How It Works". It can drift from the client's true unread
  count in edge cases `mod_inbox` itself handles specially (e.g.
  marker-only messages) that this module doesn't replicate, and can lag up
  to `unread_cache_ttl_ms`/`mute_cache_ttl_ms` behind the database due to
  caching.

## Auto-clearing Expired Mutes

Passive expiry (comparing `muted_until` against "now") never writes
anything back on its own — a lapsed mute would otherwise sit in the `inbox`
row as stale data indefinitely, until either a new mute overwrites it or an
explicit unmute IQ clears it. Since this module already fetches the row on
every message anyway, it opportunistically writes `muted_until = 0` back the
first time it detects the timestamp has passed, via the same
`set_entry_properties/3` API a manual unmute uses.

## Options

| Option | Type | Default | Description |
| ------ | ---- | ------- | ------------ |
| `mute_cache_ttl_ms` | integer milliseconds | `2000` | TTL for the per-conversation mute-check cache |
| `unread_cache_ttl_ms` | integer milliseconds | `2000` | TTL for the total-unread-count cache |
| `phone_cache_ttl_ms` | integer milliseconds | `60000` | TTL for the sender-phone-number cache |

## Example Configuration

```toml
[modules.mod_inbox]
  backend = "rdbms"

[modules.mod_contact_sync]
  backend = "rdbms"

[modules.mod_inbox_mute_pusher]
  mute_cache_ttl_ms = 2000
  unread_cache_ttl_ms = 2000
  phone_cache_ttl_ms = 60000

[modules.mod_event_pusher.rabbit]
  chat_msg_exchange.name = "chat_msg"
  chat_msg_exchange.sent_topic = "chat_msg_sent"
  chat_msg_exchange.recv_topic = "chat_msg_recv"
```

## Testing / Verifying

**Mute suppression:** mute a conversation via the standard Inbox `mute` IQ
(see `doc/open-extensions/inbox.md`), then send a message from the other
party. Compare a RabbitMQ queue's `publish`/`deliver`/`ack` counters
(`GET /api/queues/<vhost>/<queue>` on the management API) before and after —
they should not move while muted, and should increment again once unmuted
(`mute` set back to `0`). The Inbox `unread_count` for that conversation
should still increment in both cases, confirming only the push is
suppressed.

**Auto-clear:** mute for a short period, wait for it to lapse, then send a
message. Check the `inbox` row's `muted_until` afterwards — it should now
read `0` (reset as a side effect of the check), even though no unmute IQ was
sent.

**Badge (total across conversations):** build up unread messages from **two
different senders** to the same recipient, then check
`SELECT SUM(unread_count) FROM inbox WHERE luser = '...' AND box = 'inbox'`
via `psql` before sending a third, unmuted message. Confirm the published
RabbitMQ payload's `badge` field equals that sum `+ 1` — not just the
single-conversation count from the sender of the third message. On
`wingtrill-notifier`, confirm the resulting FCM payload carries
`apns.payload.aps.badge` (integer) and `data.badge` (string) with that same
value.

**Caching:** send several messages in quick succession from the same
sender; only the first should trigger `get_entry_properties/2`
(mute) and the `SUM(...)` query (total-unread) — the rest should be served
from cache within the configured TTL windows.

**Sender phone number:** confirm the sender has a row in `phone_contacts`
(`SELECT phone FROM phone_contacts WHERE username = '...'`), send a message,
and confirm the published RabbitMQ payload carries a matching `from_phone`.
On `wingtrill-notifier`, confirm the push's title is that phone number, not
the sender's JID. Then test a sender with **no** phone on file and confirm
`from_phone` is absent from the payload and the title falls back to the JID
as before.
