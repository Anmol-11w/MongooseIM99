## Module Description

Real-time AI voice calling for MongooseIM using OpenAI Realtime API and Jingle (XEP-0location) signaling. Bridges WebRTC calls from XMPP clients to OpenAI's Realtime API -- MongooseIM handles signaling only, audio streams directly between the client and OpenAI.

### How It Works

1. **Client sends Jingle session-initiate** -- An XMPP client creates a WebRTC offer and sends it to the bot JID as a Jingle `session-initiate` IQ stanza with the SDP embedded.
2. **Module negotiates with OpenAI** -- The module creates an ephemeral session key via OpenAI's REST API, then posts the SDP offer to OpenAI's Realtime WebRTC endpoint.
3. **Module sends Jingle session-accept** -- The SDP answer from OpenAI is wrapped in a Jingle `session-accept` stanza and routed back to the client.
4. **Direct WebRTC connection** -- The client uses the SDP answer to establish a direct WebRTC audio connection with OpenAI. No audio passes through MongooseIM.

### Architecture

```
Client (React Native / Web)         MongooseIM                        OpenAI Realtime API
  |                                     |                                     |
  | Jingle session-initiate (SDP offer) |                                     |
  |------------------------------------>|                                     |
  |          IQ ack (type=result)       |                                     |
  |<------------------------------------|                                     |
  |                                     | POST /v1/realtime/sessions          |
  |                                     |------------------------------------>|
  |                                     |           ephemeral key             |
  |                                     |<------------------------------------|
  |                                     | POST /v1/realtime (SDP offer)       |
  |                                     |------------------------------------>|
  |                                     |           SDP answer                |
  |                                     |<------------------------------------|
  | Jingle session-accept (SDP answer)  |                                     |
  |<------------------------------------|                                     |
  |                                                                           |
  |============ Direct WebRTC audio (peer-to-peer) =========================>|
```

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/ai_bot/mod_ai_bot_call.erl` | Main module: Jingle handler, OpenAI API negotiation |
| `src/config/mongoose_config_spec.erl` | Module registration in `configurable_modules()` |

## Options

### `modules.mod_ai_bot_call.pool_tag`
* **Syntax:** string (atom)
* **Required:** yes

Name of the HTTP connection pool used for OpenAI API requests. Must match a pool defined in `outgoing_pools.http.<pool_tag>`.

### `modules.mod_ai_bot_call.api_key`
* **Syntax:** string
* **Required:** yes

OpenAI API key. Used to create ephemeral session keys for the Realtime API.

### `modules.mod_ai_bot_call.bot_username`
* **Syntax:** string
* **Default:** `"assistant"`

The local part of the bot JID. When a Jingle IQ is sent to `<bot_username>@<server>`, this module intercepts it.

### `modules.mod_ai_bot_call.model`
* **Syntax:** string
* **Default:** `"gpt-4o-realtime-preview"`

OpenAI Realtime model to use for voice conversations.

### `modules.mod_ai_bot_call.voice`
* **Syntax:** string
* **Default:** `"alloy"`

Voice for the AI assistant. Options include: `alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse`.

### `modules.mod_ai_bot_call.call_prompt`
* **Syntax:** string
* **Default:** *(built-in customer service prompt)*

System instructions for the AI during voice calls. This is sent as the `instructions` field in the OpenAI Realtime session configuration.

### `modules.mod_ai_bot_call.temperature`
* **Syntax:** float
* **Default:** `0.8`

Sampling temperature for AI responses. Lower values make responses more deterministic.

### `modules.mod_ai_bot_call.max_response_output_tokens`
* **Syntax:** integer
* **Default:** `4096`

Maximum number of tokens the AI can generate per response turn.

### `modules.mod_ai_bot_call.input_audio_transcription`
* **Syntax:** boolean
* **Default:** `true`

When `true`, enables Whisper-based transcription of the user's audio input. This allows the AI to have a text transcript of what was said.

### `modules.mod_ai_bot_call.turn_detection_type`
* **Syntax:** string
* **Default:** `"server_vad"`

Voice activity detection mode. `"server_vad"` means the server detects when the user stops speaking.

### `modules.mod_ai_bot_call.turn_detection_threshold`
* **Syntax:** float
* **Default:** `0.5`

VAD sensitivity threshold (0.0 to 1.0). Lower values detect speech more aggressively.

### `modules.mod_ai_bot_call.turn_detection_prefix_padding_ms`
* **Syntax:** integer
* **Default:** `300`

Milliseconds of audio to include before detected speech begins.

### `modules.mod_ai_bot_call.turn_detection_silence_duration_ms`
* **Syntax:** integer
* **Default:** `500`

Milliseconds of silence required to detect end of speech turn.

## Example Configuration

```toml
[outgoing_pools.http.ai_bot]
  scope = "global"
  workers = 5

[outgoing_pools.http.ai_bot.connection]
  host = "https://api.openai.com"
  path_prefix = "/v1"
  request_timeout = 30000
  tls.verify_mode = "none"

[modules.mod_ai_bot_call]
  pool_tag = "ai_bot"
  api_key = "sk-proj-..."
  bot_username = "assistant"
  model = "gpt-4o-realtime-preview"
  voice = "alloy"
  temperature = 0.8
  max_response_output_tokens = 4096
  call_prompt = "You are a professional customer service agent. Answer questions clearly and concisely. Keep responses brief since this is a real-time voice call."
```

## XMPP Protocol (Jingle)

### Namespaces

| Namespace | Purpose |
| --------- | ------- |
| `urn:xmpp:jingle:1` | Jingle session management |
| `urn:xmpp:jingle:apps:rtp:1` | RTP media description |
| `urn:xmpp:jingle:transports:ice-udp:1` | ICE-UDP transport |

### session-initiate (Client to Server)

The client sends a Jingle `session-initiate` with the WebRTC SDP offer:

```xml
<iq type="set" to="assistant@server" id="jingle_1">
  <jingle xmlns="urn:xmpp:jingle:1"
          action="session-initiate"
          sid="sid_1713100000_abc123"
          initiator="user@server/mobile">
    <content creator="initiator" name="0" senders="both">
      <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
        <sdp>v=0\r\no=- 123 2 IN IP4 127.0.0.1\r\n...</sdp>
      </description>
      <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"/>
    </content>
  </jingle>
</iq>
```

The server immediately acknowledges with an empty IQ result:

```xml
<iq type="result" from="assistant@server" to="user@server/mobile" id="jingle_1"/>
```

### session-accept (Server to Client)

After negotiating with OpenAI, the server sends the SDP answer:

```xml
<iq type="set" from="assistant@server" to="user@server/mobile" id="jingle_2">
  <jingle xmlns="urn:xmpp:jingle:1"
          action="session-accept"
          sid="sid_1713100000_abc123"
          responder="assistant@server">
    <content creator="initiator" name="0" senders="both">
      <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
        <sdp>v=0\r\no=- 456 2 IN IP4 ...\r\n...</sdp>
      </description>
      <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"/>
    </content>
  </jingle>
</iq>
```

### session-terminate (Either Direction)

If the OpenAI negotiation fails, the server sends a terminate:

```xml
<iq type="set" from="assistant@server" to="user@server/mobile" id="jingle_3">
  <jingle xmlns="urn:xmpp:jingle:1"
          action="session-terminate"
          sid="sid_1713100000_abc123">
    <reason>
      <failed-application/>
      <text>Failed to create voice session. Please try again later.</text>
    </reason>
  </jingle>
</iq>
```

The client can also send `session-terminate` to hang up the call.

### Terminate Reasons

| Reason | Meaning |
| ------ | ------- |
| `success` | Normal hangup |
| `decline` | Call rejected |
| `busy` | Already in a call |
| `cancel` | Caller cancelled before answer |
| `timeout` | No answer within timeout |
| `failed-application` | Server-side error |
| `gone` | User went offline |

## Hooks

| Hook | Priority | Purpose |
| ---- | -------- | ------- |
| `user_send_iq` | 10 | Intercept Jingle IQ stanzas sent to the bot JID |

## Differences from mod_ai_bot_voice (Replaced)

| Feature | mod_ai_bot_voice (old) | mod_ai_bot_call (new) |
| ------- | ---------------------- | --------------------- |
| Protocol | Custom `<audio>` elements in messages | Standard Jingle signaling |
| Audio transport | Base64 over XMPP messages | Direct WebRTC (peer-to-peer) |
| Latency | High (record → upload → process → download) | Real-time (streaming) |
| AI pipeline | STT + LLM + TTS (3 API calls) | Single Realtime API connection |
| Server load | Audio file storage + HTTP serving | Signaling only (lightweight) |
| Dependencies | mod_ai_bot_voice_http (audio file server) | None |