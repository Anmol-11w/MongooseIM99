## Module Description

Central, per-user privacy store for WhatsApp-style visibility controls. One table, many fields. Other custom features (`mod_last_seen`, avatar, phone number, group invites, …) consult this module to decide whether to reveal their data to a requester.

### How It Works

1. Each known privacy field (`last_seen`, `availability`, `group_direct_invite`, `avatar`, `phone_number`) can be set by the user to one of: `everyone`, `contacts`, `nobody`.
2. Feature modules call `mod_user_privacy:is_visible(HostType, RequesterJid, TargetJid, Field)` and only reveal data when it returns `true`.
3. `contacts` is resolved against the target's roster — the requester must have subscription `from` or `both` (i.e. target has approved them).

### Architecture

```
mod_last_seen / mod_avatar / ... (feature modules)
  --> mod_user_privacy:is_visible/4
      --> mod_user_privacy_backend              (behaviour / proxy)
          --> mod_user_privacy_rdbms            (RDBMS implementation)
  --> mod_roster:get_roster_entry/4             (for the `contacts` check)
```

The privacy store is independent of the features that consume it. If `mod_user_privacy` is not loaded, feature modules that depend on it will fail at runtime — enable it first.

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/privacy/mod_user_privacy.erl` | Main module: IQ handler, visibility API, contacts check |
| `src/custom/privacy/mod_user_privacy_backend.erl` | Behaviour definition and proxy delegation |
| `src/custom/privacy/mod_user_privacy_rdbms.erl` | RDBMS backend (PostgreSQL / MySQL) |

## Database

The module requires a `user_privacy` table. Run this migration on your database before enabling the module.

### PostgreSQL

```sql
CREATE TABLE user_privacy (
    server VARCHAR(250) NOT NULL,
    username VARCHAR(250) NOT NULL,
    field VARCHAR(50) NOT NULL,
    value VARCHAR(20) NOT NULL DEFAULT 'everyone',
    PRIMARY KEY (server, username, field)
);
```

### MySQL

```sql
CREATE TABLE user_privacy (
    server VARCHAR(250) NOT NULL,
    username VARCHAR(250) NOT NULL,
    field VARCHAR(50) NOT NULL,
    value VARCHAR(20) NOT NULL DEFAULT 'everyone',
    PRIMARY KEY (server, username, field)
) CHARACTER SET utf8mb4 ROW_FORMAT=DYNAMIC;
```

## Options

### `modules.mod_user_privacy.backend`
* **Syntax:** string, one of `"rdbms"`
* **Default:** `"rdbms"`

Storage backend.

## Example Configuration

```toml
[modules.mod_user_privacy]
  backend = "rdbms"
```

## XMPP Protocol

### Namespace

`wingtrill:privacy`

### Known Fields

| Field | Controls |
| ----- | -------- |
| `last_seen` | Who can query your last-seen timestamp (see `mod_last_seen`) |
| `availability` | Who can see your online/offline presence |
| `group_direct_invite` | Who can add you to a group chat without invitation |
| `avatar` | Who can fetch your avatar / profile picture |
| `phone_number` | Who can look you up by phone number (see `mod_contact_sync`) |

Values: `everyone`, `contacts`, `nobody`. Default for every field is `everyone`.

`contacts` means: the requester has roster subscription `from` or `both` on the target — in other words, the target has approved them as a contact.

### Read All Fields

```xml
<iq type="get" id="p1">
  <query xmlns="wingtrill:privacy"/>
</iq>
```

Response — all known fields, with defaults applied for any unset rows:

```xml
<iq type="result" id="p1">
  <query xmlns="wingtrill:privacy">
    <field name="last_seen"           value="contacts"/>
    <field name="availability"        value="everyone"/>
    <field name="group_direct_invite" value="contacts"/>
    <field name="avatar"              value="everyone"/>
    <field name="phone_number"        value="contacts"/>
  </query>
</iq>
```

### Read Specific Fields

```xml
<iq type="get" id="p2">
  <query xmlns="wingtrill:privacy">
    <field name="last_seen"/>
    <field name="avatar"/>
  </query>
</iq>
```

Response contains only the named fields. Unknown field names are silently dropped; an empty result falls back to returning all fields.

### Set One or More Fields

```xml
<iq type="set" id="p3">
  <query xmlns="wingtrill:privacy">
    <field name="last_seen" value="contacts"/>
    <field name="avatar"    value="nobody"/>
  </query>
</iq>
```

Response:

```xml
<iq type="result" id="p3"/>
```

Unknown field names or unknown values cause the whole set to be rejected with `<bad-request/>` (atomic update — no partial writes).

### Error Responses

| Condition | Error |
| --------- | ----- |
| `type="set"` with no `<field/>` children | `<bad-request/>` |
| `<field/>` with unknown `name` or `value` | `<bad-request/>` |
| `type="result"` or `type="error"` | `<bad-request/>` |

## Extending

To add a new privacy field:

1. Append the field name (a binary) to the `?FIELDS` macro in `mod_user_privacy.erl`.
2. In the feature module, call `mod_user_privacy:is_visible(HostType, Requester, Target, <<"new_field">>)` before revealing the data.

No schema change is needed — the `user_privacy` table is generic across fields.

## Erlang API

Intended for use by other custom modules (not user-facing).

| Function | Returns | Purpose |
| -------- | ------- | ------- |
| `get_privacy(HostType, Jid, Field)` | `binary()` | Raw value, default applied |
| `set_privacy(HostType, Jid, Field, Value)` | `ok | {error, bad_request}` | Validated upsert |
| `is_visible(HostType, Requester, Target, Field)` | `boolean()` | Full check: self-bypass + privacy + roster |
| `is_contact(HostType, Target, Requester)` | `boolean()` | Roster-only check (subscription `from` or `both`) |
| `known_fields/0` | `[binary()]` | Whitelist snapshot |
