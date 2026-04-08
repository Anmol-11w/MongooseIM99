## Module Description

Real-time voice customer agent module that implements a full voice pipeline using Groq APIs: **STT (Whisper) -> LLM (LLaMA) -> TTS (Orpheus)**. Clients send audio as base64 in a custom `<audio>` element; the bot responds with text plus an audio download URL via XEP-0066 Out-of-Band Data.

Also supports text-only input (standard `<body>` element), in which case the STT step is skipped and the text goes directly through LLM -> TTS.

### How It Works

1. **Message interception** -- The module hooks into `user_send_message` (priority 49) and checks if the recipient matches the configured `bot_username`.
2. **Audio extraction** -- If the message contains an `<audio xmlns="urn:xmpp:voice:0">` element, the base64 audio is decoded. Otherwise, the `<body>` text is used directly.
3. **STT** -- Audio is sent to Groq's Whisper API as multipart/form-data for transcription.
4. **LLM** -- The transcribed text (or input text) is sent to Groq's chat completions API for a response.
5. **TTS** -- The LLM response is sent to Groq's Orpheus TTS API to generate spoken audio.
6. **Reply** -- The audio is saved to disk, and the bot replies with the text in `<body>` and the audio URL in an XEP-0066 `<x xmlns="jabber:x:oob">` element.

Audio files are served via the `mod_ai_bot_voice_http` cowboy handler.

### Architecture

```
XMPP Client (WebRTC audio capture)
  --> user_send_message hook
      --> mod_ai_bot_voice:user_send_message/3
          --> extract_audio (base64 decode)
          --> call_stt: Groq Whisper API (multipart/form-data)
          --> call_llm: Groq Chat Completions API (JSON)
          --> call_tts: Groq Orpheus TTS API (JSON -> WAV bytes)
          --> save audio to disk
      <-- ejabberd_router:route/3 (reply with text + audio URL)

HTTP Client (browser/app)
  --> GET /voice-audio/<token>.wav
      --> mod_ai_bot_voice_http (cowboy handler)
      <-- audio/wav binary
```

### Source Files

| File | Purpose |
| ---- | ------- |
| `src/custom/ai_bot/mod_ai_bot_voice.erl` | Main module: voice pipeline, STT/LLM/TTS API calls |
| `src/custom/ai_bot/mod_ai_bot_voice_http.erl` | Cowboy handler for serving audio files via HTTP |

## Options

### `modules.mod_ai_bot_voice.pool_tag`
* **Syntax:** string
* **Default:** no default, this option is mandatory
* **Example:** `pool_tag = "ai_bot"`

HTTP pool tag for the Groq API. Can be shared with `mod_ai_bot` if both use Groq.

### `modules.mod_ai_bot_voice.api_key`
* **Syntax:** string
* **Default:** no default, this option is mandatory
* **Example:** `api_key = "gsk_your-groq-key"`

Groq API key. Must have access to the Whisper, LLaMA, and Orpheus models.

### `modules.mod_ai_bot_voice.bot_username`
* **Syntax:** string
* **Default:** `"voiceagent"`
* **Example:** `bot_username = "support"`

The local part of the voice bot's JID. Must be different from `mod_ai_bot.bot_username` if both modules are enabled.

### `modules.mod_ai_bot_voice.audio_dir`
* **Syntax:** string (filesystem path)
* **Default:** `"/tmp/voice_audio"`
* **Example:** `audio_dir = "/var/lib/mongooseim/voice_audio"`

Directory where TTS audio files are saved. Created automatically on module start. Must match the `audio_dir` configured in `mod_ai_bot_voice_http`.

### `modules.mod_ai_bot_voice.audio_base_url`
* **Syntax:** string (URL)
* **Default:** `"http://localhost:5280/voice-audio"`
* **Example:** `audio_base_url = "https://chat.example.com/voice-audio"`

Base URL for audio file downloads. Must point to the `mod_ai_bot_voice_http` handler endpoint. In production, use your public hostname.

### `modules.mod_ai_bot_voice.stt_model`
* **Syntax:** string
* **Default:** `"whisper-large-v3-turbo"`
* **Example:** `stt_model = "whisper-large-v3"`

Groq Whisper model for speech-to-text. Available models:

| Model | Speed | Accuracy |
| ----- | ----- | -------- |
| `whisper-large-v3-turbo` | Fastest | Good |
| `whisper-large-v3` | Slower | Best |
| `distil-whisper-large-v3-en` | Fast | English only |

### `modules.mod_ai_bot_voice.llm_model`
* **Syntax:** string
* **Default:** `"llama-3.3-70b-versatile"`
* **Example:** `llm_model = "llama-3.1-8b-instant"`

Groq LLM model for generating the agent response.

### `modules.mod_ai_bot_voice.tts_model`
* **Syntax:** string
* **Default:** `"canopylabs/orpheus-v1-english"`
* **Example:** `tts_model = "canopylabs/orpheus-arabic-saudi"`

Groq TTS model. You must accept the model terms at the Groq console before use.

### `modules.mod_ai_bot_voice.tts_voice`
* **Syntax:** string
* **Default:** `"diana"`
* **Example:** `tts_voice = "austin"`

Voice for TTS output. Available Orpheus English voices:

| Voice | Description |
| ----- | ----------- |
| `autumn` | Female |
| `diana` | Female |
| `hannah` | Female |
| `austin` | Male |
| `daniel` | Male |
| `troy` | Male |

### `modules.mod_ai_bot_voice.max_tokens`
* **Syntax:** positive integer
* **Default:** `4096`
* **Example:** `max_tokens = 2048`

Maximum tokens in the LLM response. Keep low for voice (shorter responses = faster TTS).

### `modules.mod_ai_bot_voice.response_format`
* **Syntax:** string
* **Default:** `"wav"`
* **Example:** `response_format = "wav"`

Audio output format. Orpheus currently only supports `wav`.

### `modules.mod_ai_bot_voice.system_prompt`
* **Syntax:** string
* **Default:** Built-in customer service agent prompt
* **Example:** `system_prompt = "You are a friendly hotel receptionist."`

System prompt for the LLM. The default prompt instructs the agent to keep responses brief and conversational (2-3 sentences) since they will be spoken aloud.

## HTTP Handler Setup

The `mod_ai_bot_voice_http` handler serves audio files. Add it to an HTTP listener:

```toml
[[listen.http]]
  port = 5280

  [[listen.http.handlers.mod_ai_bot_voice_http]]
    host = "_"
    path = "/voice-audio"
    audio_dir = "/tmp/voice_audio"
```

### Handler Options

| Option | Type | Default | Description |
| ------ | ---- | ------- | ----------- |
| `audio_dir` | string | `"/tmp/voice_audio"` | Directory to serve files from (must match module config) |

## Setup

### 1. Configure the Groq HTTP pool

```toml
[outgoing_pools.http.ai_bot]
  scope = "global"
  workers = 5

  [outgoing_pools.http.ai_bot.connection]
    host = "https://api.groq.com"
    path_prefix = "/openai/v1"
    request_timeout = 30000
```

### 2. Accept Orpheus TTS model terms

Visit the Groq console and accept the terms for the Orpheus TTS model:
`https://console.groq.com/playground?model=canopylabs%2Forpheus-v1-english`

### 3. Register the bot user

```bash
mongooseimctl register voiceagent yourdomain.com somesecurepassword
```

### 4. Enable the module and HTTP handler

```toml
[[listen.http.handlers.mod_ai_bot_voice_http]]
  host = "_"
  path = "/voice-audio"
  audio_dir = "/tmp/voice_audio"

[modules.mod_ai_bot_voice]
  pool_tag = "ai_bot"
  api_key = "gsk_your-groq-key"
  audio_base_url = "http://yourdomain.com:5280/voice-audio"
```

## Example Configuration

```toml
[outgoing_pools.http.ai_bot]
  scope = "global"
  workers = 10

  [outgoing_pools.http.ai_bot.connection]
    host = "https://api.groq.com"
    path_prefix = "/openai/v1"
    request_timeout = 30000

[modules.mod_ai_bot_voice]
  pool_tag = "ai_bot"
  api_key = "gsk_your-groq-key"
  bot_username = "support"
  audio_dir = "/var/lib/mongooseim/voice_audio"
  audio_base_url = "https://chat.example.com/voice-audio"
  stt_model = "whisper-large-v3-turbo"
  llm_model = "llama-3.3-70b-versatile"
  tts_model = "canopylabs/orpheus-v1-english"
  tts_voice = "diana"
  max_tokens = 2048
  response_format = "wav"
  system_prompt = "You are a friendly customer support agent for Acme Corp. Keep responses brief and conversational."
```

## XMPP Protocol

### Sending audio to the bot

```xml
<message type="chat" to="voiceagent@yourdomain.com" id="v001">
  <audio xmlns="urn:xmpp:voice:0" format="wav">UklGRi4AAABXQVZFZm10IBAAAA...</audio>
</message>
```

The `format` attribute tells the STT API the audio encoding. Supported: `wav`, `mp3`, `ogg`, `webm`, `flac`, `m4a`.

### Sending text to the bot (skips STT)

```xml
<message type="chat" to="voiceagent@yourdomain.com" id="v002">
  <body>What are your business hours?</body>
</message>
```

### Bot reply (text + audio URL)

```xml
<message type="chat" from="voiceagent@yourdomain.com" to="alice@yourdomain.com" id="1775...">
  <body>Our business hours are Monday through Friday, 9 AM to 5 PM Eastern Time.</body>
  <x xmlns="jabber:x:oob">
    <url>http://yourdomain.com:5280/voice-audio/1775-677145-106537.wav</url>
  </x>
</message>
```

The client should:
1. Display the `<body>` text as a chat bubble
2. Fetch the audio from the `<url>` and play it (or offer a play button)

### Error reply

```xml
<message type="chat" from="voiceagent@yourdomain.com" to="alice@yourdomain.com" id="1775...">
  <body>Sorry, I couldn't understand the audio. Please try again or send a text message.</body>
</message>
```

Stage-specific error messages:

| Stage | Error message |
| ----- | ------------- |
| STT | "Sorry, I couldn't understand the audio. Please try again or send a text message." |
| LLM | "Sorry, I'm unable to process your request right now. Please try again later." |
| TTS | "Sorry, I couldn't generate an audio response. Please try again later." |

## Logging

| Log level | `what` field | Meaning |
| --------- | ------------ | ------- |
| `info` | `ai_bot_voice_stt_done` | STT transcription completed |
| `info` | `ai_bot_voice_llm_done` | LLM response generated |
| `warning` | `ai_bot_voice_stt_http_error` | Groq STT API returned non-200 |
| `warning` | `ai_bot_voice_llm_http_error` | Groq LLM API returned non-200 |
| `warning` | `ai_bot_voice_tts_http_error` | Groq TTS API returned non-200 |
| `error` | `ai_bot_voice_error` | Pipeline failed at a specific stage |

## Hooks

| Hook | Priority | Purpose |
| ---- | -------- | ------- |
| `user_send_message` | 49 | Intercept messages to the voice bot (runs before `mod_ai_bot` at 50) |

## Limitations

- **No conversation history** -- Each voice interaction is independent. The agent does not remember prior exchanges.
- **Synchronous processing** -- The full STT -> LLM -> TTS pipeline runs synchronously. Typical latency is 2-5 seconds with Groq.
- **WAV only** -- Orpheus TTS currently only supports WAV output, which produces larger files than compressed formats.
- **No audio cleanup** -- Audio files in `audio_dir` are not automatically deleted. Set up a cron job to remove old files: `find /tmp/voice_audio -mtime +1 -delete`
- **No streaming** -- Audio is generated in full before sending. Real-time streaming would require WebSocket/Jingle integration.
- **Single-turn only** -- No multi-turn conversation support yet.

## Future Enhancements

- **Conversation history** -- Store per-user conversation state for multi-turn voice interactions.
- **Jingle/WebRTC** -- Real-time bidirectional audio streaming via XMPP Jingle (XEP-0166) for true P2P voice.
- **Audio cleanup** -- Automatic TTL-based cleanup of old audio files.
- **Streaming TTS** -- Stream audio chunks as they are generated for lower perceived latency.
- **VAD (Voice Activity Detection)** -- Detect speech boundaries for more natural turn-taking.
- **Language detection** -- Auto-detect input language and switch LLM/TTS accordingly.