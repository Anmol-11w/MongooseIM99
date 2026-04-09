## Module Description

AI chatbot module that intercepts XMPP messages sent to a designated bot JID and forwards them to a configurable AI provider (Claude, OpenAI/ChatGPT, or Google Gemini) for processing. Responses are routed back as standard chat messages. Uses MongooseIM's managed HTTP connection pools for efficient, fault-tolerant API communication.

### How It Works

1. **Message interception** -- The module hooks into `user_send_message` and checks if the recipient matches the configured `bot_username`.
2. **API call** -- The message body is sent to the Claude API via an HTTP pool managed by `mongoose_wpool`.
3. **Reply routing** -- The API response is wrapped in an XMPP `<message type="chat">` stanza and routed back to the sender via `ejabberd_router`.

Messages to other users pass through unmodified. If the API call fails, the bot replies with a user-friendly error message and logs the failure.

### Architecture

```
XMPP Client
  --> user_send_message hook
      --> mod_ai_bot:user_send_message/3      (checks bot JID)
          --> mongoose_http_client:post/5      (Claude API via wpool)
          <-- parse response
      <-- ejabberd_router:route/3             (reply to user)
```

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/mod_ai_bot.erl` | Main module: hook handler, API client, reply routing |

## Options

### `modules.mod_ai_bot.provider`
* **Syntax:** string, one of `"claude"`, `"openai"`, `"gemini"`
* **Default:** `"claude"`
* **Example:** `provider = "openai"`

The AI provider to use. Each provider has different API formats:

| Provider | API Host | Notes |
| -------- | -------- | ----- |
| `claude` | `https://api.anthropic.com` | Anthropic Claude API. `path_prefix = "/v1"` |
| `openai` | `https://api.openai.com` | OpenAI ChatGPT API. `path_prefix = "/v1"` |
| `gemini` | `https://generativelanguage.googleapis.com` | Google Gemini API. `path_prefix = "/v1beta"` |

### `modules.mod_ai_bot.pool_tag`
* **Syntax:** string
* **Default:** no default, this option is mandatory
* **Example:** `pool_tag = "claude_ai"`

HTTP pool tag configured in the [outgoing connections](../configuration/outgoing-connections.md#) section. This pool manages connections to the Claude API.

### `modules.mod_ai_bot.api_key`
* **Syntax:** string
* **Default:** no default, this option is mandatory
* **Example:** `api_key = "sk-ant-api03-..."`

Anthropic API key used for authentication. Passed as the `x-api-key` header on every request.

### `modules.mod_ai_bot.bot_username`
* **Syntax:** string
* **Default:** `"devbot"`
* **Example:** `bot_username = "assistant"`

The local part of the bot's JID. Messages sent to `<bot_username>@<server>` are intercepted and processed. The user must be registered on the server (see [Setup](#setup)).

### `modules.mod_ai_bot.model`
* **Syntax:** string
* **Default:** `"claude-sonnet-4-20250514"`
* **Example:** `model = "claude-opus-4-20250514"`

The Claude model ID to use for generating responses.

### `modules.mod_ai_bot.max_tokens`
* **Syntax:** positive integer
* **Default:** `4096`
* **Example:** `max_tokens = 2048`

Maximum number of tokens in the Claude API response.

### `modules.mod_ai_bot.system_prompt`
* **Syntax:** string
* **Default:** Built-in developer assistant prompt
* **Example:** `system_prompt = "You are a helpful customer support agent."`

System prompt sent with every API request. Controls the bot's persona and capabilities. The default prompt configures the bot as a senior app development assistant.

## Setup

### 1. Configure the HTTP pool

Add an outgoing HTTP pool for the Claude API:

```toml
[outgoing_pools.http.claude_ai]
  scope = "global"
  workers = 5

  [outgoing_pools.http.claude_ai.connection]
    host = "https://api.anthropic.com"
    path_prefix = "/v1"
    request_timeout = 30000
```

**Pool tuning:**

| Parameter | Recommendation |
| --------- | -------------- |
| `workers` | 5-10 for low traffic, 20-50 for high traffic |
| `request_timeout` | 30000ms minimum (LLM responses can be slow) |

### 2. Register the bot user

The bot needs a registered XMPP account on the server:

```bash
mongooseimctl register devbot yourdomain.com somesecurepassword
```

The bot user does not need to be online -- `mod_ai_bot` intercepts messages at the routing layer before delivery.

### 3. Enable the module

```toml
[modules.mod_ai_bot]
  pool_tag = "claude_ai"
  api_key = "sk-ant-api03-your-key-here"
```

## Example Configuration

### Claude (default)

```toml
[outgoing_pools.http.ai_bot]
  scope = "global"
  workers = 5
  [outgoing_pools.http.ai_bot.connection]
    host = "https://api.anthropic.com"
    path_prefix = "/v1"
    request_timeout = 30000

[modules.mod_ai_bot]
  provider = "claude"
  pool_tag = "ai_bot"
  api_key = "sk-ant-api03-your-key-here"
  model = "claude-sonnet-4-20250514"
```

### OpenAI / ChatGPT

```toml
[outgoing_pools.http.ai_bot]
  scope = "global"
  workers = 5
  [outgoing_pools.http.ai_bot.connection]
    host = "https://api.openai.com"
    path_prefix = "/v1"
    request_timeout = 30000

[modules.mod_ai_bot]
  provider = "openai"
  pool_tag = "ai_bot"
  api_key = "sk-your-openai-key-here"
  model = "gpt-4o"
```

### Google Gemini

```toml
[outgoing_pools.http.ai_bot]
  scope = "global"
  workers = 5
  [outgoing_pools.http.ai_bot.connection]
    host = "https://generativelanguage.googleapis.com"
    path_prefix = "/v1beta"
    request_timeout = 30000

[modules.mod_ai_bot]
  provider = "gemini"
  pool_tag = "ai_bot"
  api_key = "your-gemini-api-key"
  model = "gemini-2.0-flash"
```

### Full customization

```toml
[outgoing_pools.http.ai_bot]
  scope = "global"
  workers = 20
  [outgoing_pools.http.ai_bot.connection]
    host = "https://api.openai.com"
    path_prefix = "/v1"
    request_timeout = 60000

[modules.mod_ai_bot]
  provider = "openai"
  pool_tag = "ai_bot"
  api_key = "sk-your-openai-key-here"
  bot_username = "assistant"
  model = "gpt-4o"
  max_tokens = 8192
  system_prompt = "You are a DevOps expert. Help with infrastructure, CI/CD, and deployment."
```

## XMPP Protocol

### Sending a message to the bot

Standard XMPP chat message -- no custom namespace required:

```xml
<message type="chat" to="devbot@yourdomain.com" id="msg1">
  <body>Write a Swift function to validate email addresses</body>
</message>
```

### Bot reply

```xml
<message type="chat" from="devbot@yourdomain.com" to="alice@yourdomain.com" id="167234...">
  <body>Here's a Swift email validation function:

```swift
func isValidEmail(_ email: String) -> Bool {
    let pattern = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
    return email.range(of: pattern, options: .regularExpression) != nil
}
```</body>
</message>
```

### Error reply

If the API is unreachable or returns an error:

```xml
<message type="chat" from="devbot@yourdomain.com" to="alice@yourdomain.com" id="167234...">
  <body>Sorry, I'm unable to process your request right now. Please try again later.</body>
</message>
```

## Logging

The module uses MongooseIM's standard logging macros. Key log entries:

| Log level | `what` field | Meaning |
| --------- | ------------ | ------- |
| `warning` | `ai_bot_api_http_error` | Claude API returned a non-200 status code |
| `error` | `ai_bot_api_error` | HTTP request failed (timeout, pool down, etc.) |
| `error` | `ai_bot_parse_error` | Could not parse the Claude API response body |

## Hooks

| Hook | Priority | Purpose |
| ---- | -------- | ------- |
| `user_send_message` | 50 | Intercept messages addressed to the bot JID |

## Limitations

- **No conversation history** -- Each message is sent to the API independently. The bot does not remember prior messages in the conversation. This can be added with a Mnesia or RDBMS backend.
- **Synchronous processing** -- The API call blocks the message processing pipeline for the sending user. For very slow responses, consider wrapping the call in an async process.
- **No multi-turn tool use** -- The current implementation sends a single user message. Claude's tool-use capabilities are not yet wired in.

## Future Enhancements

- **Conversation history** -- Store message history per user JID in Mnesia/RDBMS and pass prior turns to the API for context-aware responses.
- **Async replies** -- Use `mongoose_wpool:cast` to avoid blocking the message pipeline; route the reply when the API responds.
- **Rate limiting** -- Track API calls per JID in ETS and reject excessive requests.
- **Tool use** -- Wire up Claude's tool-use API to let the bot perform actions (create files, query databases, trigger builds).
- **Streaming** -- Support streamed responses for faster perceived latency on long answers.