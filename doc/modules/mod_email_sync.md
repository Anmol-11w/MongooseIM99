## Module Description

Email-based contact synchronization for MongooseIM. Works with JWT authentication to map email addresses to XMPP JIDs and sync a user's known contacts to the roster.

### How It Works

1. **Email registration** -- When a user authenticates with a JWT containing an `email` claim, the module listens for the `jwt_user_email` hook and stores the normalised (lowercased) email-to-JID mapping in the `email_contacts` database table.
2. **Contact sync** -- The client sends a list of email addresses. The server looks up each address, returns matching JIDs, and (optionally) adds them to both users' rosters with mutual visibility.

### Architecture

```
ejabberd_auth_jwt / custom_ejabberd_auth_jwt
  --> mongoose_hooks:jwt_user_email/4          (fires hook on successful JWT auth)
      --> mod_email_sync:jwt_user_email/3      (hook handler)
          --> mod_email_sync_backend           (behaviour / proxy)
              --> mod_email_sync_rdbms         (RDBMS implementation)
```

The auth module is fully decoupled -- it only fires a hook. If `mod_email_sync` is not loaded the hook has no handlers and nothing happens.

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/email_sync/mod_email_sync.erl` | Main module: IQ handler, hook handlers, roster integration |
| `src/custom/email_sync/mod_email_sync_backend.erl` | Behaviour definition and proxy delegation |
| `src/custom/email_sync/mod_email_sync_rdbms.erl` | RDBMS backend (PostgreSQL / MySQL) |
| `src/hooks/mongoose_hooks.erl` | `jwt_user_email` hook definition |
| `src/custom/jwt_auth/custom_ejabberd_auth_jwt.erl` | Fires `jwt_user_email` hook on auth success |

## Database

The module requires an `email_contacts` table. Run this migration on your database before enabling the module.

### PostgreSQL

```sql
CREATE TABLE email_contacts (
    email    VARCHAR(255) NOT NULL,
    server   VARCHAR(250) NOT NULL,
    username VARCHAR(250) NOT NULL,
    created_at TIMESTAMP  NOT NULL DEFAULT now(),
    PRIMARY KEY (email, server)
);

CREATE INDEX i_email_contacts_username ON email_contacts(server, username);
```

### MySQL

```sql
CREATE TABLE email_contacts (
    email    VARCHAR(255) NOT NULL,
    server   VARCHAR(250) NOT NULL,
    username VARCHAR(250) NOT NULL,
    created_at TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (email, server)
) CHARACTER SET utf8mb4 ROW_FORMAT=DYNAMIC;

CREATE INDEX i_email_contacts_username ON email_contacts(server, username);
```

The primary key `(email, server)` enforces one XMPP account per email address per server. An upsert is used so that if a user re-authenticates with the same email but a different JID, the mapping is updated automatically.

## Options

### `modules.mod_email_sync.backend`
* **Syntax:** string, one of `"rdbms"`
* **Default:** `"rdbms"`

Storage backend.

### `modules.mod_email_sync.add_to_roster`
* **Syntax:** boolean
* **Default:** `true`

When `true`, matched contacts are automatically added to both users' rosters with mutual visibility under the `"Contacts"` group. The roster nick is set to the contact's email address. When `false`, only the matching JIDs are returned in the IQ result and the client is responsible for roster management.

## Example Configuration

```toml
[modules.mod_email_sync]
  backend       = "rdbms"
  add_to_roster = true
```

## XMPP Protocol

### Namespace

`wingtrill:email:sync`

### Sync Request

The client sends a `set` IQ with email addresses to look up:

```xml
<iq type="set" id="sync1">
  <query xmlns="wingtrill:email:sync">
    <email>alice@example.com</email>
    <email>bob@example.com</email>
    <email>carol@example.com</email>
  </query>
</iq>
```

### Sync Response

The server returns matched contacts (addresses that belong to registered users):

```xml
<iq type="result" id="sync1">
  <query xmlns="wingtrill:email:sync">
    <contact email="alice@example.com" jid="alice@xmpp.domain"/>
    <contact email="bob@example.com"   jid="bob@xmpp.domain"/>
  </query>
</iq>
```

Addresses with no matching user are silently omitted. The caller's own email is filtered out even if it appears in the request list.

### Error Responses

| Condition | Error |
| --------- | ----- |
| `type="get"` | `<not-allowed/>` |
| Empty email list | `<bad-request/>` |

## Roster Integration

When `add_to_roster = true`, for each matched contact the module applies the following subscription logic:

| Scenario | Action |
| -------- | ------ |
| Already `both` subscription | Skip -- already fully wired |
| Contact has caller in their roster (any state) | `subscribe_both` -- upgrade to mutual presence |
| Contact does not have caller in their roster | One-way: add contact to caller's roster, caller subscribes to contact |

This incremental approach means two users who each have the other's email end up with a `both` subscription after at most two sync operations:

1. **User A syncs** -- finds B's email → one-way subscription (A → B), B is added to A's roster.
2. **User B syncs** -- finds A's email → sees A already in B's roster → upgrades to `subscribe_both`.

Both users are placed in the `"Contacts"` group with the matched email address as the roster nickname.

## Hooks

| Hook | Fired by | Handled by | Purpose |
| ---- | -------- | ---------- | ------- |
| `jwt_user_email` | `custom_ejabberd_auth_jwt` | `mod_email_sync` | Store email-to-JID mapping on JWT auth |
| `user_open_session` | MongooseIM core | `mod_email_sync` | Move email from ETS cache into C2S session info |
| `user_send_iq` | MongooseIM core | `mod_email_sync` | Handle `wingtrill:email:sync` IQ stanzas |

## Relation to mod_contact_sync

`mod_email_sync` and `mod_contact_sync` are independent modules that follow the same pattern. They can both be enabled simultaneously. Phone-based and email-based matches are stored in separate tables and managed by separate hooks, so enabling one does not affect the other.

| | `mod_contact_sync` | `mod_email_sync` |
| - | ------------------ | ---------------- |
| JWT claim | `phone_number` | `email` |
| Hook | `jwt_user_phone` | `jwt_user_email` |
| Namespace | `wingtrill:contact:sync` | `wingtrill:email:sync` |
| Table | `phone_contacts` | `email_contacts` |
| Lookup strategy | Last-7-digit fuzzy match | Exact lowercase match |
| Stanza element | `<phone>` | `<email>` |
| Result attribute | `phone="..."` | `email="..."` |