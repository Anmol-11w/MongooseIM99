%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc Real-time voice customer agent module for MongooseIM.
%%%
%%% Implements a full voice pipeline using Groq APIs:
%%%   Audio In → STT (Whisper) → LLM (LLaMA) → TTS (Orpheus) → Audio Out
%%%
%%% Clients send audio data as base64 in a custom &lt;audio&gt; element.
%%% The module processes it through the pipeline and responds with
%%% text (&lt;body&gt;) plus an audio URL (XEP-0066 Out-of-Band Data).
%%% Audio files are saved to disk and served via mod_ai_bot_voice_http.
%%%
%%% XMPP Protocol:
%%%   Client → Bot:
%%%     <message to="voiceagent@server">
%%%       <audio xmlns="urn:xmpp:voice:0" format="wav">BASE64_AUDIO</audio>
%%%     </message>
%%%
%%%   Bot → Client:
%%%     <message from="voiceagent@server">
%%%       <body>Agent response text</body>
%%%       <x xmlns="jabber:x:oob">
%%%         <url>http://server:5280/voice-audio/abc123.wav</url>
%%%       </x>
%%%     </message>
%%%
%%% Text-only fallback: if a &lt;body&gt; is sent instead of &lt;audio&gt;,
%%% the STT step is skipped and the text goes directly to LLM → TTS.
%%%
%%% Configuration (mongooseim.toml):
%%%
%%%   [modules.mod_ai_bot_voice]
%%%     pool_tag = "ai_bot"
%%%     api_key = "gsk_..."
%%%     bot_username = "voiceagent"
%%%     audio_dir = "/tmp/voice_audio"
%%%     audio_base_url = "http://localhost:5280/voice-audio"
%%%     stt_model = "whisper-large-v3-turbo"
%%%     llm_model = "llama-3.3-70b-versatile"
%%%     tts_model = "canopylabs/orpheus-v1-english"
%%%     tts_voice = "diana"
%%%     max_tokens = 4096
%%%     response_format = "wav"
%%%     system_prompt = "You are a customer service agent..."
%%% @end
%%%==============================================================================
-module(mod_ai_bot_voice).

-behaviour(gen_mod).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, supported_features/0, config_spec/0, hooks/1]).

%% Hook handlers
-export([user_send_message/3]).

-define(NS_VOICE, <<"urn:xmpp:voice:0">>).
-define(NS_OOB, <<"jabber:x:oob">>).

%%--------------------------------------------------------------------
%% gen_mod callbacks
%%--------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
start(HostType, _Opts) ->
    AudioDir = gen_mod:get_module_opt(HostType, ?MODULE, audio_dir),
    filelib:ensure_dir(<<AudioDir/binary, "/">>),
    file:make_dir(AudioDir),
    ok.

-spec stop(mongooseim:host_type()) -> ok.
stop(_HostType) ->
    ok.

-spec supported_features() -> [atom()].
supported_features() ->
    [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
        items = #{
            <<"pool_tag">> => #option{type = atom, validate = pool_name},
            <<"bot_username">> => #option{type = binary},
            <<"api_key">> => #option{type = binary},
            <<"audio_dir">> => #option{type = binary},
            <<"audio_base_url">> => #option{type = binary},
            <<"stt_model">> => #option{type = binary},
            <<"llm_model">> => #option{type = binary},
            <<"tts_model">> => #option{type = binary},
            <<"tts_voice">> => #option{type = binary},
            <<"max_tokens">> => #option{type = integer, validate = positive},
            <<"response_format">> => #option{type = binary},
            <<"system_prompt">> => #option{type = binary}
        },
        defaults = #{
            <<"bot_username">> => <<"voiceagent">>,
            <<"audio_dir">> => <<"/tmp/voice_audio">>,
            <<"audio_base_url">> => <<"http://localhost:5280/voice-audio">>,
            <<"stt_model">> => <<"whisper-large-v3-turbo">>,
            <<"llm_model">> => <<"llama-3.3-70b-versatile">>,
            <<"tts_model">> => <<"canopylabs/orpheus-v1-english">>,
            <<"tts_voice">> => <<"diana">>,
            <<"max_tokens">> => 4096,
            <<"response_format">> => <<"wav">>,
            <<"system_prompt">> => default_system_prompt()
        },
        required = [<<"pool_tag">>, <<"api_key">>]
    }.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_message, HostType, fun ?MODULE:user_send_message/3, #{}, 49}].

%%--------------------------------------------------------------------
%% Hook handlers
%%--------------------------------------------------------------------

-spec user_send_message(mongoose_acc:t(),
                        mongoose_c2s_hooks:params(),
                        gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_message(Acc, _Params, #{host_type := HostType}) ->
    {_From, To, Packet} = mongoose_acc:packet(Acc),
    BotUsername = gen_mod:get_module_opt(HostType, ?MODULE, bot_username),
    case jid:to_lus(To) of
        {BotUsername, _Server} ->
            handle_voice_message(Acc, HostType, Packet);
        _ ->
            {ok, Acc}
    end.

%%--------------------------------------------------------------------
%% Message routing
%%--------------------------------------------------------------------

-spec handle_voice_message(mongoose_acc:t(), mongooseim:host_type(), exml:element()) ->
    mongoose_c2s_hooks:result().
handle_voice_message(Acc, HostType, Packet) ->
    case extract_audio(Packet) of
        {ok, AudioData, Format} ->
            process_voice_pipeline(Acc, HostType, {audio, AudioData, Format});
        no_audio ->
            %% Fall back to text-only: skip STT, go LLM → TTS
            case exml_query:subelement(Packet, <<"body">>) of
                #xmlel{} = BodyElem ->
                    Body = exml_query:cdata(BodyElem),
                    process_voice_pipeline(Acc, HostType, {text, Body});
                undefined ->
                    {ok, Acc}
            end
    end.

%%--------------------------------------------------------------------
%% Voice pipeline: STT → LLM → TTS
%%--------------------------------------------------------------------

-spec process_voice_pipeline(mongoose_acc:t(), mongooseim:host_type(),
                             {audio, binary(), binary()} | {text, binary()}) ->
    mongoose_c2s_hooks:result().
process_voice_pipeline(Acc, _HostType, {text, <<>>}) ->
    {ok, Acc};
process_voice_pipeline(Acc, HostType, Input) ->
    {From, To, _Packet} = mongoose_acc:packet(Acc),
    case run_pipeline(HostType, Input) of
        {ok, ResponseText, AudioBytes} ->
            send_voice_reply(From, To, HostType, ResponseText, AudioBytes),
            {stop, Acc};
        {error, Stage, Reason} ->
            ?LOG_ERROR(#{what => ai_bot_voice_error,
                         stage => Stage,
                         reason => Reason,
                         host_type => HostType}),
            ErrorMsg = stage_error_message(Stage),
            send_text_reply(From, To, ErrorMsg),
            {stop, Acc}
    end.

-spec run_pipeline(mongooseim:host_type(),
                   {audio, binary(), binary()} | {text, binary()}) ->
    {ok, binary(), binary()} | {error, atom(), any()}.
run_pipeline(HostType, {audio, AudioData, Format}) ->
    case call_stt(HostType, AudioData, Format) of
        {ok, Transcription} ->
            ?LOG_INFO(#{what => ai_bot_voice_stt_done,
                        transcription => Transcription}),
            run_llm_tts(HostType, Transcription);
        {error, Reason} ->
            {error, stt, Reason}
    end;
run_pipeline(HostType, {text, UserText}) ->
    run_llm_tts(HostType, UserText).

-spec run_llm_tts(mongooseim:host_type(), binary()) ->
    {ok, binary(), binary()} | {error, atom(), any()}.
run_llm_tts(HostType, UserText) ->
    case call_llm(HostType, UserText) of
        {ok, ResponseText} ->
            ?LOG_INFO(#{what => ai_bot_voice_llm_done,
                        response_length => byte_size(ResponseText)}),
            case call_tts(HostType, ResponseText) of
                {ok, AudioBytes} ->
                    {ok, ResponseText, AudioBytes};
                {error, Reason} ->
                    {error, tts, Reason}
            end;
        {error, Reason} ->
            {error, llm, Reason}
    end.

%%--------------------------------------------------------------------
%% STT: Groq Whisper API (multipart/form-data)
%%--------------------------------------------------------------------

-spec call_stt(mongooseim:host_type(), binary(), binary()) ->
    {ok, binary()} | {error, any()}.
call_stt(HostType, AudioData, Format) ->
    ApiKey = gen_mod:get_module_opt(HostType, ?MODULE, api_key),
    SttModel = gen_mod:get_module_opt(HostType, ?MODULE, stt_model),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    {ContentType, Body} = build_multipart(AudioData, SttModel, Format),
    Path = <<"/audio/transcriptions">>,
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, ContentType}
    ],
    case mongoose_http_client:post(global, PoolTag, Path, Headers, Body) of
        {ok, {<<"200">>, RespBody}} ->
            parse_stt_response(RespBody);
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_voice_stt_http_error,
                           response_code => Code,
                           response_body => RespBody}),
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec build_multipart(binary(), binary(), binary()) ->
    {binary(), binary()}.
build_multipart(AudioData, Model, Format) ->
    Boundary = <<"----VoiceBotBoundary",
                 (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    MimeType = audio_mime_type(Format),
    Body = iolist_to_binary([
        <<"--">>, Boundary, <<"\r\n">>,
        <<"Content-Disposition: form-data; name=\"file\"; filename=\"audio.">>,
        Format, <<"\"\r\n">>,
        <<"Content-Type: ">>, MimeType, <<"\r\n\r\n">>,
        AudioData, <<"\r\n">>,
        <<"--">>, Boundary, <<"\r\n">>,
        <<"Content-Disposition: form-data; name=\"model\"\r\n\r\n">>,
        Model, <<"\r\n">>,
        <<"--">>, Boundary, <<"\r\n">>,
        <<"Content-Disposition: form-data; name=\"response_format\"\r\n\r\n">>,
        <<"json\r\n">>,
        <<"--">>, Boundary, <<"--\r\n">>
    ]),
    ContentType = <<"multipart/form-data; boundary=", Boundary/binary>>,
    {ContentType, Body}.

-spec parse_stt_response(binary()) -> {ok, binary()} | {error, any()}.
parse_stt_response(RespBody) ->
    try
        #{<<"text">> := Text} = jiffy:decode(RespBody, [return_maps]),
        {ok, Text}
    catch
        _:Reason ->
            {error, {stt_parse_error, Reason}}
    end.

-spec audio_mime_type(binary()) -> binary().
audio_mime_type(<<"wav">>) -> <<"audio/wav">>;
audio_mime_type(<<"mp3">>) -> <<"audio/mpeg">>;
audio_mime_type(<<"ogg">>) -> <<"audio/ogg">>;
audio_mime_type(<<"webm">>) -> <<"audio/webm">>;
audio_mime_type(<<"flac">>) -> <<"audio/flac">>;
audio_mime_type(<<"m4a">>) -> <<"audio/mp4">>;
audio_mime_type(_) -> <<"application/octet-stream">>.

%%--------------------------------------------------------------------
%% LLM: Groq Chat Completions API
%%--------------------------------------------------------------------

-spec call_llm(mongooseim:host_type(), binary()) ->
    {ok, binary()} | {error, any()}.
call_llm(HostType, UserMessage) ->
    ApiKey = gen_mod:get_module_opt(HostType, ?MODULE, api_key),
    LlmModel = gen_mod:get_module_opt(HostType, ?MODULE, llm_model),
    MaxTokens = gen_mod:get_module_opt(HostType, ?MODULE, max_tokens),
    SystemPrompt = gen_mod:get_module_opt(HostType, ?MODULE, system_prompt),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    Path = <<"/chat/completions">>,
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, <<"application/json">>}
    ],
    Payload = jiffy:encode(#{
        <<"model">> => LlmModel,
        <<"max_tokens">> => MaxTokens,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => SystemPrompt},
            #{<<"role">> => <<"user">>, <<"content">> => UserMessage}
        ]
    }),
    case mongoose_http_client:post(global, PoolTag, Path, Headers, Payload) of
        {ok, {<<"200">>, RespBody}} ->
            parse_llm_response(RespBody);
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_voice_llm_http_error,
                           response_code => Code,
                           response_body => RespBody}),
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec parse_llm_response(binary()) -> {ok, binary()} | {error, any()}.
parse_llm_response(RespBody) ->
    try
        #{<<"choices">> := [#{<<"message">> := #{<<"content">> := Text}} | _]} =
            jiffy:decode(RespBody, [return_maps]),
        {ok, Text}
    catch
        _:Reason ->
            {error, {llm_parse_error, Reason}}
    end.

%%--------------------------------------------------------------------
%% TTS: Groq PlayAI API
%%--------------------------------------------------------------------

-spec call_tts(mongooseim:host_type(), binary()) ->
    {ok, binary()} | {error, any()}.
call_tts(HostType, Text) ->
    ApiKey = gen_mod:get_module_opt(HostType, ?MODULE, api_key),
    TtsModel = gen_mod:get_module_opt(HostType, ?MODULE, tts_model),
    TtsVoice = gen_mod:get_module_opt(HostType, ?MODULE, tts_voice),
    ResponseFormat = gen_mod:get_module_opt(HostType, ?MODULE, response_format),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    Path = <<"/audio/speech">>,
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, <<"application/json">>}
    ],
    Payload = jiffy:encode(#{
        <<"model">> => TtsModel,
        <<"input">> => Text,
        <<"voice">> => TtsVoice,
        <<"response_format">> => ResponseFormat
    }),
    case mongoose_http_client:post(global, PoolTag, Path, Headers, Payload) of
        {ok, {<<"200">>, AudioBytes}} ->
            {ok, AudioBytes};
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_voice_tts_http_error,
                           response_code => Code,
                           response_body => RespBody}),
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Audio element extraction
%%--------------------------------------------------------------------

-spec extract_audio(exml:element()) ->
    {ok, AudioData :: binary(), Format :: binary()} | no_audio.
extract_audio(Packet) ->
    case exml_query:subelement_with_ns(Packet, ?NS_VOICE) of
        #xmlel{attrs = Attrs} = AudioElem ->
            Format = maps:get(<<"format">>, Attrs, <<"wav">>),
            RawB64 = exml_query:cdata(AudioElem),
            B64Data = binary:replace(RawB64, [<<" ">>, <<"\n">>, <<"\r">>, <<"\t">>],
                                     <<>>, [global]),
            case base64:decode(B64Data) of
                AudioData when byte_size(AudioData) > 0 ->
                    {ok, AudioData, Format};
                _ ->
                    no_audio
            end;
        undefined ->
            no_audio
    end.

%%--------------------------------------------------------------------
%% Reply builders
%%--------------------------------------------------------------------

-spec send_voice_reply(jid:jid(), jid:jid(), mongooseim:host_type(),
                       binary(), binary()) -> mongoose_acc:t().
send_voice_reply(OrigFrom, BotJid, HostType, ResponseText, AudioBytes) ->
    ResponseFormat = gen_mod:get_module_opt(HostType, ?MODULE, response_format),
    AudioDir = gen_mod:get_module_opt(HostType, ?MODULE, audio_dir),
    AudioBaseUrl = gen_mod:get_module_opt(HostType, ?MODULE, audio_base_url),
    %% Save audio to disk with unique filename
    Token = mongoose_bin:gen_from_timestamp(),
    Filename = <<Token/binary, ".", ResponseFormat/binary>>,
    FilePath = filename:join(AudioDir, Filename),
    ok = file:write_file(FilePath, AudioBytes),
    AudioUrl = <<AudioBaseUrl/binary, "/", Filename/binary>>,
    %% XEP-0066 Out-of-Band Data
    OobElem = #xmlel{
        name = <<"x">>,
        attrs = #{<<"xmlns">> => ?NS_OOB},
        children = [
            #xmlel{name = <<"url">>,
                   children = [#xmlcdata{content = AudioUrl}]}
        ]
    },
    BodyElem = #xmlel{
        name = <<"body">>,
        children = [#xmlcdata{content = ResponseText}]
    },
    ReplyEl = #xmlel{
        name = <<"message">>,
        attrs = #{
            <<"type">> => <<"chat">>,
            <<"from">> => jid:to_binary(BotJid),
            <<"to">> => jid:to_binary(OrigFrom),
            <<"id">> => mongoose_bin:gen_from_timestamp()
        },
        children = [BodyElem, OobElem]
    },
    route_reply(OrigFrom, BotJid, ReplyEl).

-spec send_text_reply(jid:jid(), jid:jid(), binary()) -> mongoose_acc:t().
send_text_reply(OrigFrom, BotJid, Text) ->
    ReplyEl = #xmlel{
        name = <<"message">>,
        attrs = #{
            <<"type">> => <<"chat">>,
            <<"from">> => jid:to_binary(BotJid),
            <<"to">> => jid:to_binary(OrigFrom),
            <<"id">> => mongoose_bin:gen_from_timestamp()
        },
        children = [
            #xmlel{name = <<"body">>,
                   children = [#xmlcdata{content = Text}]}
        ]
    },
    route_reply(OrigFrom, BotJid, ReplyEl).

-spec route_reply(jid:jid(), jid:jid(), exml:element()) -> mongoose_acc:t().
route_reply(OrigFrom, BotJid, ReplyEl) ->
    ejabberd_router:route(BotJid, OrigFrom,
                          mongoose_acc:new(#{from_jid => BotJid,
                                            to_jid => OrigFrom,
                                            location => ?LOCATION,
                                            lserver => BotJid#jid.lserver,
                                            element => ReplyEl})).

%%--------------------------------------------------------------------
%% Error messages per pipeline stage
%%--------------------------------------------------------------------

-spec stage_error_message(atom()) -> binary().
stage_error_message(stt) ->
    <<"Sorry, I couldn't understand the audio. Please try again or send a text message.">>;
stage_error_message(llm) ->
    <<"Sorry, I'm unable to process your request right now. Please try again later.">>;
stage_error_message(tts) ->
    <<"Sorry, I couldn't generate an audio response. Please try again later.">>.

%%--------------------------------------------------------------------
%% Default system prompt
%%--------------------------------------------------------------------

-spec default_system_prompt() -> binary().
default_system_prompt() ->
    <<"You are a professional customer service agent. Your responsibilities:\n"
      "- Answer customer questions clearly and concisely\n"
      "- Resolve issues with empathy and efficiency\n"
      "- Escalate complex issues when appropriate\n"
      "- Provide accurate product and service information\n"
      "Keep responses conversational and brief (2-3 sentences) since they "
      "will be spoken aloud. Avoid markdown, code blocks, or bullet points. "
      "Use natural spoken language.">>.