%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc Real-time voice customer agent module for MongooseIM.
%%%
%%% Implements a voice pipeline using Google Gemini APIs:
%%%   Audio In → Gemini Multimodal (STT+LLM) → Gemini TTS → Audio Out
%%%   Text In  → Gemini LLM → Gemini TTS → Audio Out
%%%
%%% The audio input path sends audio directly to Gemini's multimodal
%%% generateContent endpoint, which understands audio natively — no
%%% separate STT step needed. TTS uses Gemini's audio output modality.
%%%
%%% Clients send audio data as base64 in a custom <audio> element.
%%% The module processes it through the pipeline and responds with
%%% text (<body>) plus an audio URL (XEP-0066 Out-of-Band Data).
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
%%% Text-only fallback: if a <body> is sent instead of <audio>,
%%% the audio understanding step is skipped and text goes to LLM → TTS.
%%%
%%% Configuration (mongooseim.toml):
%%%
%%%   [modules.mod_ai_bot_voice]
%%%     pool_tag = "ai_bot"
%%%     api_key = "AIza..."
%%%     bot_username = "voiceagent"
%%%     audio_dir = "/tmp/voice_audio"
%%%     audio_base_url = "http://localhost:5280/voice-audio"
%%%     llm_model = "gemini-2.0-flash"
%%%     tts_model = "gemini-2.5-flash"
%%%     tts_voice = "Kore"
%%%     max_tokens = 4096
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
            <<"provider">> => #option{type = binary},
            <<"pool_tag">> => #option{type = atom, validate = pool_name},
            <<"bot_username">> => #option{type = binary},
            <<"api_key">> => #option{type = binary},
            <<"audio_dir">> => #option{type = binary},
            <<"audio_base_url">> => #option{type = binary},
            <<"llm_model">> => #option{type = binary},
            <<"tts_model">> => #option{type = binary},
            <<"tts_voice">> => #option{type = binary},
            <<"max_tokens">> => #option{type = integer, validate = positive},
            <<"system_prompt">> => #option{type = binary}
        },
        defaults = #{
            <<"provider">> => <<"openai">>,
            <<"bot_username">> => <<"voiceagent">>,
            <<"audio_dir">> => <<"/tmp/voice_audio">>,
            <<"audio_base_url">> => <<"http://localhost:5280/voice-audio">>,
            <<"llm_model">> => <<"gemini-2.0-flash">>,
            <<"tts_model">> => <<"gemini-2.5-flash">>,
            <<"tts_voice">> => <<"Kore">>,
            <<"max_tokens">> => 4096,
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
            case exml_query:subelement(Packet, <<"body">>) of
                #xmlel{} = BodyElem ->
                    Body = exml_query:cdata(BodyElem),
                    process_voice_pipeline(Acc, HostType, {text, Body});
                undefined ->
                    {ok, Acc}
            end
    end.

%%--------------------------------------------------------------------
%% Voice pipeline: Gemini Multimodal → Gemini TTS
%%--------------------------------------------------------------------

-spec process_voice_pipeline(mongoose_acc:t(), mongooseim:host_type(),
                             {audio, binary(), binary()} | {text, binary()}) ->
    mongoose_c2s_hooks:result().
process_voice_pipeline(Acc, _HostType, {text, <<>>}) ->
    {ok, Acc};
process_voice_pipeline(Acc, HostType, Input) ->
    {From, To, _Packet} = mongoose_acc:packet(Acc),
    spawn(fun() ->
        try
            case run_pipeline(HostType, Input) of
                {ok, ResponseText, AudioBytes} ->
                    send_voice_reply(From, To, HostType, ResponseText, AudioBytes);
                {error, Stage, Reason} ->
                    ?LOG_ERROR(#{what => ai_bot_voice_error,
                                 stage => Stage,
                                 reason => Reason,
                                 host_type => HostType}),
                    ErrorMsg = stage_error_message(Stage),
                    send_text_reply(From, To, ErrorMsg)
            end
        catch
            Class:Error:Stack ->
                ?LOG_ERROR(#{what => ai_bot_voice_crash,
                             class => Class,
                             reason => Error,
                             stacktrace => Stack,
                             host_type => HostType}),
                send_text_reply(From, To,
                    <<"Sorry, something went wrong. Please try again.">>)
        end
    end),
    {stop, Acc}.

-spec run_pipeline(mongooseim:host_type(),
                   {audio, binary(), binary()} | {text, binary()}) ->
    {ok, binary(), binary()} | {error, atom(), any()}.
run_pipeline(HostType, Input) ->
    %% Step 1: Understand input (audio or text) → get text response
    case call_gemini_llm(HostType, Input) of
        {ok, ResponseText} ->
            ?LOG_INFO(#{what => ai_bot_voice_llm_done,
                        response_length => byte_size(ResponseText)}),
            %% Step 2: Convert response text → audio
            case call_gemini_tts(HostType, ResponseText) of
                {ok, AudioBytes} ->
                    {ok, ResponseText, AudioBytes};
                {error, Reason} ->
                    {error, tts, Reason}
            end;
        {error, Reason} ->
            {error, llm, Reason}
    end.

%%--------------------------------------------------------------------
%% Gemini LLM: Multimodal generateContent (handles both audio + text)
%%--------------------------------------------------------------------

-spec call_gemini_llm(mongooseim:host_type(),
                      {audio, binary(), binary()} | {text, binary()}) ->
    {ok, binary()} | {error, any()}.
call_gemini_llm(HostType, Input) ->
    ApiKey = gen_mod:get_module_opt(HostType, ?MODULE, api_key),
    LlmModel = gen_mod:get_module_opt(HostType, ?MODULE, llm_model),
    MaxTokens = gen_mod:get_module_opt(HostType, ?MODULE, max_tokens),
    SystemPrompt = gen_mod:get_module_opt(HostType, ?MODULE, system_prompt),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    Path = <<"/models/", LlmModel/binary, ":generateContent?key=", ApiKey/binary>>,
    Headers = [{<<"content-type">>, <<"application/json">>}],
    Parts = build_input_parts(Input),
    Payload = jiffy:encode(#{
        <<"system_instruction">> => #{
            <<"parts">> => [#{<<"text">> => SystemPrompt}]
        },
        <<"contents">> => [#{<<"parts">> => Parts}],
        <<"generationConfig">> => #{
            <<"maxOutputTokens">> => MaxTokens
        }
    }),
    case mongoose_http_client:post(global, PoolTag, Path, Headers, Payload) of
        {ok, {<<"200">>, RespBody}} ->
            parse_gemini_text_response(RespBody);
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_voice_llm_http_error,
                           response_code => Code,
                           response_body => RespBody}),
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec build_input_parts({audio, binary(), binary()} | {text, binary()}) -> [map()].
build_input_parts({audio, AudioData, Format}) ->
    MimeType = audio_mime_type(Format),
    [#{<<"inline_data">> => #{
        <<"mime_type">> => MimeType,
        <<"data">> => base64:encode(AudioData)
    }},
     #{<<"text">> => <<"Please respond to the user's audio message.">>}];
build_input_parts({text, UserText}) ->
    [#{<<"text">> => UserText}].

-spec parse_gemini_text_response(binary()) -> {ok, binary()} | {error, any()}.
parse_gemini_text_response(RespBody) ->
    try
        #{<<"candidates">> := [#{<<"content">> := #{<<"parts">> := Parts}} | _]} =
            jiffy:decode(RespBody, [return_maps]),
        Texts = [T || #{<<"text">> := T} <- Parts],
        {ok, iolist_to_binary(lists:join(<<"\n">>, Texts))}
    catch
        _:Reason ->
            {error, {parse_error, Reason}}
    end.

%%--------------------------------------------------------------------
%% Gemini TTS: generateContent with audio output modality
%%--------------------------------------------------------------------

-spec call_gemini_tts(mongooseim:host_type(), binary()) ->
    {ok, binary()} | {error, any()}.
call_gemini_tts(HostType, Text) ->
    ApiKey = gen_mod:get_module_opt(HostType, ?MODULE, api_key),
    TtsModel = gen_mod:get_module_opt(HostType, ?MODULE, tts_model),
    TtsVoice = gen_mod:get_module_opt(HostType, ?MODULE, tts_voice),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    Path = <<"/models/", TtsModel/binary, ":generateContent?key=", ApiKey/binary>>,
    Headers = [{<<"content-type">>, <<"application/json">>}],
    Payload = jiffy:encode(#{
        <<"contents">> => [#{
            <<"parts">> => [#{<<"text">> => <<"Say aloud: ", Text/binary>>}]
        }],
        <<"generationConfig">> => #{
            <<"response_modalities">> => [<<"AUDIO">>],
            <<"speech_config">> => #{
                <<"voice_config">> => #{
                    <<"prebuilt_voice_config">> => #{
                        <<"voice_name">> => TtsVoice
                    }
                }
            }
        }
    }),
    case mongoose_http_client:post(global, PoolTag, Path, Headers, Payload) of
        {ok, {<<"200">>, RespBody}} ->
            parse_gemini_audio_response(RespBody);
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_voice_tts_http_error,
                           response_code => Code,
                           response_body => RespBody}),
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec parse_gemini_audio_response(binary()) -> {ok, binary()} | {error, any()}.
parse_gemini_audio_response(RespBody) ->
    try
        #{<<"candidates">> := [#{<<"content">> := #{<<"parts">> := Parts}} | _]} =
            jiffy:decode(RespBody, [return_maps]),
        case find_audio_part(Parts) of
            {ok, B64Audio} ->
                {ok, base64:decode(B64Audio)};
            not_found ->
                {error, no_audio_in_response}
        end
    catch
        _:Reason ->
            {error, {parse_error, Reason}}
    end.

-spec find_audio_part([map()]) -> {ok, binary()} | not_found.
find_audio_part([]) ->
    not_found;
find_audio_part([#{<<"inline_data">> := #{<<"data">> := Data}} | _]) ->
    {ok, Data};
find_audio_part([_ | Rest]) ->
    find_audio_part(Rest).

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
    AudioDir = gen_mod:get_module_opt(HostType, ?MODULE, audio_dir),
    AudioBaseUrl = gen_mod:get_module_opt(HostType, ?MODULE, audio_base_url),
    Token = mongoose_bin:gen_from_timestamp(),
    Filename = <<Token/binary, ".wav">>,
    FilePath = filename:join(AudioDir, Filename),
    ok = file:write_file(FilePath, AudioBytes),
    AudioUrl = <<AudioBaseUrl/binary, "/", Filename/binary>>,
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
%% Helpers
%%--------------------------------------------------------------------

-spec audio_mime_type(binary()) -> binary().
audio_mime_type(<<"wav">>) -> <<"audio/wav">>;
audio_mime_type(<<"mp3">>) -> <<"audio/mpeg">>;
audio_mime_type(<<"ogg">>) -> <<"audio/ogg">>;
audio_mime_type(<<"webm">>) -> <<"audio/webm">>;
audio_mime_type(<<"flac">>) -> <<"audio/flac">>;
audio_mime_type(<<"m4a">>) -> <<"audio/mp4">>;
audio_mime_type(_) -> <<"application/octet-stream">>.

%%--------------------------------------------------------------------
%% Error messages per pipeline stage
%%--------------------------------------------------------------------

-spec stage_error_message(atom()) -> binary().
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