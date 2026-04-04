## Module Description

Phone-based contact synchronization for MongooseIM. Works with JWT authentication to map phone numbers to XMPP JIDs and sync device contacts to the roster.

### How It Works

1. **Phone registration** -- When a user authenticates with a JWT containing a `phone_number` claim, the module listens for the `jwt_user_phone` hook and stores the phone-to-JID mapping in the `phone_contacts` database table.
2. **Contact sync** -- The client sends a list of phone numbers from the user's address book. The server looks up each phone number, returns matching JIDs, and (optionally) adds them to both users' rosters with mutual visibility.

### Architecture

```
ejabberd_auth_jwt
  --> mongoose_hooks:jwt_user_phone/4          (fires hook on successful JWT auth)
      --> mod_contact_sync:jwt_user_phone/3    (hook handler)
          --> mod_contact_sync_backend          (behaviour / proxy)
              --> mod_contact_sync_rdbms        (RDBMS implementation)
```

The auth module is fully decoupled -- it only fires a hook. If `mod_contact_sync` is not loaded, the hook has no handlers and nothing happens.

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/mod_contact_sync.erl` | Main module: IQ handler, hook handler, roster integration |
| `src/custom/mod_contact_sync_backend.erl` | Behaviour definition and proxy delegation |
| `src/custom/mod_contact_sync_rdbms.erl` | RDBMS backend (PostgreSQL / MySQL) |
| `src/hooks/mongoose_hooks.erl` | `jwt_user_phone` hook definition |
| `src/auth/ejabberd_auth_jwt.erl` | Fires `jwt_user_phone` hook on auth success |

## Database

The module requires a `phone_contacts` table. Run this migration on your database before enabling the module.

### PostgreSQL

```sql
CREATE TABLE phone_contacts (
    phone VARCHAR(20) NOT NULL,
    server VARCHAR(250) NOT NULL,
    username VARCHAR(250) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (phone, server)
);

CREATE INDEX i_phone_contacts_username ON phone_contacts(server, username);
```

### MySQL

```sql
CREATE TABLE phone_contacts (
    phone VARCHAR(20) NOT NULL,
    server VARCHAR(250) NOT NULL,
    username VARCHAR(250) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (phone, server)
) CHARACTER SET utf8mb4 ROW_FORMAT=DYNAMIC;

CREATE INDEX i_phone_contacts_username ON phone_contacts(server, username);
```

## Options

### `modules.mod_contact_sync.backend`
* **Syntax:** string, one of `"rdbms"`
* **Default:** `"rdbms"`

Storage backend.

### `modules.mod_contact_sync.iqdisc.type`
* **Syntax:** string, one of `"one_queue"`, `"no_queue"`, `"queues"`, `"parallel"`
* **Default:** `"no_queue"`

Strategy to handle incoming stanzas. For details, please refer to
[IQ processing policies](../configuration/Modules.md#iq-processing-policies).

### `modules.mod_contact_sync.add_to_roster`
* **Syntax:** boolean
* **Default:** `true`

When `true`, matched contacts are automatically added to both users' rosters with mutual visibility under the `"Contacts"` group. The roster nick is set to the contact's phone number. When `false`, only the matching JIDs are returned in the IQ result and the client is responsible for roster management.

## Example Configuration

```toml
[modules.mod_contact_sync]
  backend = "rdbms"
  add_to_roster = true
```

## XMPP Protocol

### Namespace

`wingtrill:contact:sync`

### Sync Request

The client sends a `set` IQ with phone numbers to look up:

```xml
<iq type="set" id="sync1">
  <query xmlns="wingtrill:contact:sync">
    <phone>+1234567890</phone>
    <phone>+0987654321</phone>
    <phone>+1112223333</phone>
  </query>
</iq>
```

### Sync Response

The server returns matched contacts (phones that belong to registered users):

```xml
<iq type="result" id="sync1">
  <query xmlns="wingtrill:contact:sync">
    <contact phone="+1234567890" jid="alice@example.com"/>
    <contact phone="+0987654321" jid="bob@example.com"/>
  </query>
</iq>
```

Phones with no matching user are silently omitted. The caller's own phone is filtered out.

### Error Responses

| Condition | Error |
| --------- | ----- |
| `type="get"` | `<not-allowed/>` |
| Empty phone list | `<bad-request/>` |

## Roster Integration

When `add_to_roster = true`, for each matched contact the module:

1. Adds the contact to the caller's roster (nick = contact's phone number, group = `"Contacts"`)
2. Adds the caller to the contact's roster (nick = caller's phone number, group = `"Contacts"`)

This creates mutual visibility so both users see each other immediately.

## Hooks

| Hook | Fired by | Handled by | Purpose |
| ---- | -------- | ---------- | ------- |
| `jwt_user_phone` | `ejabberd_auth_jwt` | `mod_contact_sync` | Store phone-to-JID mapping on JWT auth |