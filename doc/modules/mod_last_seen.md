## Module Description

WhatsApp-style "last seen" for MongooseIM. Clients query any JID and receive a single response that combines:

* live online status from the session manager, and
* the offline timestamp recorded by upstream `mod_last` (XEP-0012),

gated by the target user's privacy preference (see `mod_user_privacy`, field `last_seen`).

### How It Works

1. A client sends a `get` IQ with namespace `wingtrill:last:seen` to another user (or to the server for a self-query).
2. `mod_last_seen` calls `mod_user_privacy:is_visible/4` with field `last_seen` to decide whether the target has permitted the requester to see.
3. If visible:
    * If the target has at least one active session (`ejabberd_sm:get_user_resources/2` returns non-empty), the response is `status="online"` with `seconds="0"`.
    * Otherwise, the response is `status="offline"` with `seconds="N"` where `N` is the age of `mod_last`'s stored timestamp.
4. If not visible, the response is `status="hidden"` with no `seconds`.

### Architecture

```
client (IQ get, ns=wingtrill:last:seen)
  --> user_send_iq hook
      --> mod_last_seen:user_send_iq/3
          --> mod_user_privacy:is_visible/4        (privacy gate)
          --> ejabberd_sm:get_user_resources/2     (is target online?)
          --> mod_last:get_last_info/3             (offline timestamp, XEP-0012)
```

This module is read-only. The **write** path for the timestamp is upstream `mod_last` — it hooks `sm_remove_connection_hook` and upserts into the `last` table on disconnect. Without `mod_last` enabled, `get_last_info/3` always returns `not_found` and responses will be `status="offline"` with no `seconds`.

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/last_seen/mod_last_seen.erl` | IQ handler, presence + timestamp resolution |
| `src/mod_last.erl` | (upstream) XEP-0012 Last Activity — stores the timestamp |
| `src/custom/privacy/mod_user_privacy.erl` | Privacy gate (field `last_seen`) |

## Dependencies

Both must be enabled on the same host:

* `mod_last` — provides the disconnect-time timestamp storage.
* `mod_user_privacy` — provides the `last_seen` privacy check.

## Database

No new tables. Reuses the `last` table (owned by `mod_last`) and the `user_privacy` table (owned by `mod_user_privacy`).

## Options

This module takes no configuration options of its own.

## Example Configuration

```toml
[modules.mod_last]
  backend = "rdbms"

[modules.mod_user_privacy]
  backend = "rdbms"

[modules.mod_last_seen]
```

## XMPP Protocol

### Namespace

`wingtrill:last:seen`

### Query

```xml
<iq type="get" to="bob@example.com" id="ls1">
  <query xmlns="wingtrill:last:seen"/>
</iq>
```

A query with no `to` (or `to` = bare server) is treated as a self-query.

### Response — Online

```xml
<iq type="result" from="bob@example.com" id="ls1">
  <query xmlns="wingtrill:last:seen" status="online" seconds="0"/>
</iq>
```

### Response — Offline (timestamp available)

```xml
<iq type="result" from="bob@example.com" id="ls1">
  <query xmlns="wingtrill:last:seen" status="offline" seconds="1234"/>
</iq>
```

`seconds` is the elapsed time since the target last disconnected.

### Response — Offline (no timestamp recorded)

```xml
<iq type="result" from="bob@example.com" id="ls1">
  <query xmlns="wingtrill:last:seen" status="offline"/>
</iq>
```

Returned if `mod_last` has never stored a timestamp for this user (e.g. they've never logged in, or `mod_last` is disabled).

### Response — Hidden (privacy)

```xml
<iq type="result" from="bob@example.com" id="ls1">
  <query xmlns="wingtrill:last:seen" status="hidden"/>
</iq>
```

Returned when the target's `last_seen` privacy setting denies the requester. The response is indistinguishable between `nobody` and `contacts` (when the requester is not a contact) — clients cannot infer which rule blocked them.

### Status Values

| Status | Meaning |
| ------ | ------- |
| `online` | Target has at least one active session |
| `offline` | Target is disconnected; `seconds` present if `mod_last` has a record |
| `hidden` | Blocked by `mod_user_privacy` (field `last_seen`) |

### Self-Query Exemption

A user querying their own last-seen bypasses the privacy check. Useful for clients that want to display their own "last seen" consistently in settings UIs.

### Error Responses

| Condition | Error |
| --------- | ----- |
| `type="set"` / `type="result"` / `type="error"` | `<not-allowed/>` |

## Privacy Controls

Users control who can see their last-seen via `mod_user_privacy`:

```xml
<iq type="set" id="p1">
  <query xmlns="wingtrill:privacy">
    <field name="last_seen" value="contacts"/>
  </query>
</iq>
```

See `mod_user_privacy` documentation for the full protocol.
