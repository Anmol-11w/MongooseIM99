%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc Real-time voice call module for MongooseIM using OpenAI Realtime API.
%%%
%%% Bridges WebRTC calls from XMPP clients to OpenAI's Realtime API
%%% using standard Jingle (XEP-0location) signaling.
%%%
%%% MongooseIM acts only as a signaling relay — the actual audio streams
%%% directly between the client and OpenAI via WebRTC.
%%%
%%% Flow:
%%%   1. Client sends Jingle session-initiate with SDP offer
%%%   2. This module requests an ephemeral key from OpenAI
%%%   3. Posts the SDP offer to OpenAI Realtime WebRTC endpoint
%%%   4. Returns Jingle session-accept with SDP answer
%%%   5. Client establishes direct WebRTC connection with OpenAI
%%%
%%% XMPP Protocol (Jingle):
%%%   Client → Server (session-initiate):
%%%     <iq type="set" to="assistant@server" id="j1">
%%%       <jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
%%%               sid="sid123" initiator="user@server/res">
%%%         <content creator="initiator" name="0" senders="both">
%%%           <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
%%%             <sdp>v=0\r\n...</sdp>
%%%           </description>
%%%           <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"/>
%%%         </content>
%%%       </jingle>
%%%     </iq>
%%%
%%%   Server → Client (session-accept):
%%%     <iq type="set" from="assistant@server" to="user@server/res" id="j2">
%%%       <jingle xmlns="urn:xmpp:jingle:1" action="session-accept"
%%%               sid="sid123" responder="assistant@server">
%%%         <content creator="initiator" name="0" senders="both">
%%%           <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
%%%             <sdp>v=0\r\n...</sdp>
%%%           </description>
%%%           <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"/>
%%%         </content>
%%%       </jingle>
%%%     </iq>
%%%
%%% Configuration (mongooseim.toml):
%%%
%%%   [modules.mod_ai_bot_call]
%%%     pool_tag = "ai_bot"
%%%     api_key = "sk-..."
%%%     bot_username = "assistant"
%%%     model = "gpt-4o-realtime-preview"
%%%     voice = "alloy"
%%%     call_prompt = "You are a helpful assistant..."
%%% @end
%%%==============================================================================
-module(mod_ai_bot_call).

-behaviour(gen_mod).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, supported_features/0, config_spec/0, hooks/1]).

%% Hook handlers
-export([user_send_iq/3]).

-define(NS_JINGLE, <<"urn:xmpp:jingle:1">>).
-define(NS_JINGLE_RTP, <<"urn:xmpp:jingle:apps:rtp:1">>).
-define(NS_JINGLE_ICE, <<"urn:xmpp:jingle:transports:ice-udp:1">>).

%%--------------------------------------------------------------------
%% gen_mod callbacks
%%--------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
start(_HostType, _Opts) ->
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
            <<"model">> => #option{type = binary},
            <<"voice">> => #option{type = binary},
            <<"call_prompt">> => #option{type = binary},
            <<"temperature">> => #option{type = float},
            <<"max_response_output_tokens">> => #option{type = integer, validate = positive},
            <<"input_audio_transcription">> => #option{type = boolean},
            <<"turn_detection_type">> => #option{type = binary},
            <<"turn_detection_threshold">> => #option{type = float},
            <<"turn_detection_prefix_padding_ms">> => #option{type = integer, validate = non_negative},
            <<"turn_detection_silence_duration_ms">> => #option{type = integer, validate = positive}
        },
        defaults = #{
            <<"bot_username">> => <<"assistant">>,
            <<"model">> => <<"gpt-4o-realtime-preview">>,
            <<"voice">> => <<"alloy">>,
            <<"call_prompt">> => default_call_prompt(),
            <<"temperature">> => 0.8,
            <<"max_response_output_tokens">> => 4096,
            <<"input_audio_transcription">> => true,
            <<"turn_detection_type">> => <<"server_vad">>,
            <<"turn_detection_threshold">> => 0.5,
            <<"turn_detection_prefix_padding_ms">> => 300,
            <<"turn_detection_silence_duration_ms">> => 500
        },
        required = [<<"pool_tag">>, <<"api_key">>]
    }.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_iq, HostType, fun ?MODULE:user_send_iq/3, #{}, 10}].

%%--------------------------------------------------------------------
%% Hook handler: intercept Jingle IQ stanzas to bot JID
%%--------------------------------------------------------------------

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, _Params, #{host_type := HostType}) ->
    {From, To, Packet} = mongoose_acc:packet(Acc),
    BotUsername = gen_mod:get_module_opt(HostType, ?MODULE, bot_username),
    case jid:to_lus(To) of
        {BotUsername, _Server} ->
            handle_jingle_iq(Acc, HostType, From, To, Packet);
        _ ->
            {ok, Acc}
    end.

%%--------------------------------------------------------------------
%% Jingle IQ dispatch
%%--------------------------------------------------------------------

-spec handle_jingle_iq(mongoose_acc:t(), mongooseim:host_type(),
                       jid:jid(), jid:jid(), exml:element()) ->
    mongoose_c2s_hooks:result().
handle_jingle_iq(Acc, HostType, From, To, Packet) ->
    case exml_query:subelement_with_ns(Packet, ?NS_JINGLE) of
        #xmlel{attrs = Attrs} = JingleEl ->
            Action = maps:get(<<"action">>, Attrs, <<>>),
            Sid = maps:get(<<"sid">>, Attrs, <<>>),
            IqId = exml_query:attr(Packet, <<"id">>, <<>>),
            case Action of
                <<"session-initiate">> ->
                    %% Acknowledge the IQ immediately
                    send_iq_result(From, To, IqId),
                    handle_session_initiate(Acc, HostType, From, To, Sid, JingleEl);
                <<"session-terminate">> ->
                    send_iq_result(From, To, IqId),
                    ?LOG_INFO(#{what => ai_bot_call_terminated,
                                sid => Sid, from => jid:to_binary(From)}),
                    {stop, Acc};
                _ ->
                    %% Ack unknown actions (transport-info, etc.)
                    send_iq_result(From, To, IqId),
                    {stop, Acc}
            end;
        undefined ->
            {ok, Acc}
    end.

%%--------------------------------------------------------------------
%% session-initiate: Client sends SDP offer, we negotiate and
%% respond with session-accept containing SDP answer
%%--------------------------------------------------------------------

-spec handle_session_initiate(mongoose_acc:t(), mongooseim:host_type(),
                              jid:jid(), jid:jid(), binary(), exml:element()) ->
    mongoose_c2s_hooks:result().
handle_session_initiate(Acc, HostType, From, To, Sid, JingleEl) ->
    case extract_sdp_from_jingle(JingleEl) of
        {ok, SdpOffer} ->
            spawn(fun() ->
                try
                    case negotiate_session(HostType, SdpOffer) of
                        {ok, SdpAnswer} ->
                            send_jingle_accept(From, To, Sid, SdpAnswer);
                        {error, Stage, Reason} ->
                            ?LOG_ERROR(#{what => ai_bot_call_error,
                                         stage => Stage,
                                         reason => Reason,
                                         host_type => HostType}),
                            send_jingle_terminate(From, To, Sid,
                                                  <<"failed-application">>,
                                                  error_message(Stage))
                    end
                catch
                    Class:Error:Stack ->
                        ?LOG_ERROR(#{what => ai_bot_call_crash,
                                     class => Class,
                                     reason => Error,
                                     stacktrace => Stack,
                                     host_type => HostType}),
                        send_jingle_terminate(From, To, Sid,
                                              <<"failed-application">>,
                                              <<"Call setup failed unexpectedly.">>)
                end
            end),
            {stop, Acc};
        {error, Reason} ->
            ?LOG_WARNING(#{what => ai_bot_call_bad_sdp, reason => Reason}),
            send_jingle_terminate(From, To, Sid,
                                  <<"failed-application">>,
                                  <<"Missing or invalid SDP offer">>),
            {stop, Acc}
    end.

%%--------------------------------------------------------------------
%% OpenAI Realtime API negotiation
%%--------------------------------------------------------------------

-spec negotiate_session(mongooseim:host_type(), binary()) ->
    {ok, binary()} | {error, atom(), any()}.
negotiate_session(HostType, SdpOffer) ->
    case create_ephemeral_key(HostType) of
        {ok, EphemeralKey} ->
            ?LOG_INFO(#{what => ai_bot_call_ephemeral_key_ok}),
            send_sdp_to_openai(HostType, EphemeralKey, SdpOffer);
        {error, Reason} ->
            {error, ephemeral_key, Reason}
    end.

-spec create_ephemeral_key(mongooseim:host_type()) ->
    {ok, binary()} | {error, any()}.
create_ephemeral_key(HostType) ->
    ApiKey = gen_mod:get_module_opt(HostType, ?MODULE, api_key),
    Model = gen_mod:get_module_opt(HostType, ?MODULE, model),
    Voice = gen_mod:get_module_opt(HostType, ?MODULE, voice),
    CallPrompt = gen_mod:get_module_opt(HostType, ?MODULE, call_prompt),
    Temperature = gen_mod:get_module_opt(HostType, ?MODULE, temperature),
    MaxTokens = gen_mod:get_module_opt(HostType, ?MODULE, max_response_output_tokens),
    InputTranscription = gen_mod:get_module_opt(HostType, ?MODULE, input_audio_transcription),
    TurnDetectionType = gen_mod:get_module_opt(HostType, ?MODULE, turn_detection_type),
    TurnDetectionThreshold = gen_mod:get_module_opt(HostType, ?MODULE, turn_detection_threshold),
    TurnDetectionPrefixPadding = gen_mod:get_module_opt(HostType, ?MODULE, turn_detection_prefix_padding_ms),
    TurnDetectionSilenceDuration = gen_mod:get_module_opt(HostType, ?MODULE, turn_detection_silence_duration_ms),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    Path = <<"/realtime/sessions">>,
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, <<"application/json">>}
    ],
    TurnDetection = #{
        <<"type">> => TurnDetectionType,
        <<"threshold">> => TurnDetectionThreshold,
        <<"prefix_padding_ms">> => TurnDetectionPrefixPadding,
        <<"silence_duration_ms">> => TurnDetectionSilenceDuration
    },
    TranscriptionConfig = case InputTranscription of
        true -> #{<<"model">> => <<"whisper-1">>};
        false -> null
    end,
    %% Tool that lets the AI end the call when asked
    EndCallTool = #{
        <<"type">> => <<"function">>,
        <<"name">> => <<"end_call">>,
        <<"description">> => <<"End the current voice call. Use this when the user says goodbye, asks to hang up, or the conversation is clearly finished.">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{}
        }
    },
    Payload = jiffy:encode(#{
        <<"model">> => Model,
        <<"voice">> => Voice,
        <<"instructions">> => CallPrompt,
        <<"temperature">> => Temperature,
        <<"max_response_output_tokens">> => MaxTokens,
        <<"turn_detection">> => TurnDetection,
        <<"input_audio_transcription">> => TranscriptionConfig,
        <<"tools">> => [EndCallTool]
    }),
    ?LOG_INFO(#{what => ai_bot_call_creating_session,
                model => Model, voice => Voice}),
    case mongoose_http_client:post(global, PoolTag, Path, Headers, Payload) of
        {ok, {<<"200">>, RespBody}} ->
            parse_ephemeral_key(RespBody);
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_call_session_http_error,
                           response_code => Code,
                           response_body => RespBody}),
            {error, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec parse_ephemeral_key(binary()) -> {ok, binary()} | {error, any()}.
parse_ephemeral_key(RespBody) ->
    try
        #{<<"client_secret">> := #{<<"value">> := Key}} =
            jiffy:decode(RespBody, [return_maps]),
        {ok, Key}
    catch
        _:Reason ->
            {error, {parse_error, Reason}}
    end.

-spec send_sdp_to_openai(mongooseim:host_type(), binary(), binary()) ->
    {ok, binary()} | {error, atom(), any()}.
send_sdp_to_openai(HostType, EphemeralKey, SdpOffer) ->
    Model = gen_mod:get_module_opt(HostType, ?MODULE, model),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    Path = <<"/realtime?model=", Model/binary>>,
    Headers = [
        {<<"authorization">>, <<"Bearer ", EphemeralKey/binary>>},
        {<<"content-type">>, <<"application/sdp">>}
    ],
    ?LOG_INFO(#{what => ai_bot_call_sending_sdp,
                sdp_length => byte_size(SdpOffer)}),
    case mongoose_http_client:post(global, PoolTag, Path, Headers, SdpOffer) of
        {ok, {<<"201">>, SdpAnswer}} ->
            ?LOG_INFO(#{what => ai_bot_call_sdp_answer_ok,
                        answer_length => byte_size(SdpAnswer)}),
            {ok, SdpAnswer};
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_call_sdp_http_error,
                           response_code => Code,
                           response_body => RespBody}),
            {error, sdp_exchange, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, sdp_exchange, Reason}
    end.

%%--------------------------------------------------------------------
%% SDP extraction from Jingle content
%%--------------------------------------------------------------------

-spec extract_sdp_from_jingle(exml:element()) -> {ok, binary()} | {error, any()}.
extract_sdp_from_jingle(JingleEl) ->
    case exml_query:subelement(JingleEl, <<"content">>) of
        #xmlel{} = ContentEl ->
            case exml_query:subelement_with_ns(ContentEl, ?NS_JINGLE_RTP) of
                #xmlel{} = DescEl ->
                    case exml_query:subelement(DescEl, <<"sdp">>) of
                        #xmlel{} = SdpEl ->
                            SdpData = exml_query:cdata(SdpEl),
                            case SdpData of
                                <<>> -> {error, empty_sdp};
                                _ -> {ok, SdpData}
                            end;
                        undefined ->
                            {error, no_sdp_element}
                    end;
                undefined ->
                    {error, no_description}
            end;
        undefined ->
            {error, no_content}
    end.

%%--------------------------------------------------------------------
%% Jingle response builders
%%--------------------------------------------------------------------

%% Simple IQ ack (type=result, empty)
-spec send_iq_result(jid:jid(), jid:jid(), binary()) -> mongoose_acc:t().
send_iq_result(OrigFrom, BotJid, IqId) ->
    ResultEl = #xmlel{
        name = <<"iq">>,
        attrs = #{
            <<"type">> => <<"result">>,
            <<"from">> => jid:to_binary(BotJid),
            <<"to">> => jid:to_binary(OrigFrom),
            <<"id">> => IqId
        },
        children = []
    },
    route(BotJid, OrigFrom, ResultEl).

%% Jingle session-accept with SDP answer
-spec send_jingle_accept(jid:jid(), jid:jid(), binary(), binary()) -> mongoose_acc:t().
send_jingle_accept(OrigFrom, BotJid, Sid, SdpAnswer) ->
    AcceptEl = #xmlel{
        name = <<"iq">>,
        attrs = #{
            <<"type">> => <<"set">>,
            <<"from">> => jid:to_binary(BotJid),
            <<"to">> => jid:to_binary(OrigFrom),
            <<"id">> => mongoose_bin:gen_from_timestamp()
        },
        children = [
            #xmlel{
                name = <<"jingle">>,
                attrs = #{
                    <<"xmlns">> => ?NS_JINGLE,
                    <<"action">> => <<"session-accept">>,
                    <<"sid">> => Sid,
                    <<"responder">> => jid:to_binary(BotJid)
                },
                children = [
                    #xmlel{
                        name = <<"content">>,
                        attrs = #{
                            <<"creator">> => <<"initiator">>,
                            <<"name">> => <<"0">>,
                            <<"senders">> => <<"both">>
                        },
                        children = [
                            #xmlel{
                                name = <<"description">>,
                                attrs = #{
                                    <<"xmlns">> => ?NS_JINGLE_RTP,
                                    <<"media">> => <<"audio">>
                                },
                                children = [
                                    #xmlel{
                                        name = <<"sdp">>,
                                        children = [#xmlcdata{content = SdpAnswer}]
                                    }
                                ]
                            },
                            #xmlel{
                                name = <<"transport">>,
                                attrs = #{<<"xmlns">> => ?NS_JINGLE_ICE}
                            }
                        ]
                    }
                ]
            }
        ]
    },
    route(BotJid, OrigFrom, AcceptEl).

%% Jingle session-terminate with reason
-spec send_jingle_terminate(jid:jid(), jid:jid(), binary(), binary(), binary()) ->
    mongoose_acc:t().
send_jingle_terminate(OrigFrom, BotJid, Sid, Reason, Text) ->
    TerminateEl = #xmlel{
        name = <<"iq">>,
        attrs = #{
            <<"type">> => <<"set">>,
            <<"from">> => jid:to_binary(BotJid),
            <<"to">> => jid:to_binary(OrigFrom),
            <<"id">> => mongoose_bin:gen_from_timestamp()
        },
        children = [
            #xmlel{
                name = <<"jingle">>,
                attrs = #{
                    <<"xmlns">> => ?NS_JINGLE,
                    <<"action">> => <<"session-terminate">>,
                    <<"sid">> => Sid
                },
                children = [
                    #xmlel{
                        name = <<"reason">>,
                        children = [
                            #xmlel{name = Reason},
                            #xmlel{
                                name = <<"text">>,
                                children = [#xmlcdata{content = Text}]
                            }
                        ]
                    }
                ]
            }
        ]
    },
    route(BotJid, OrigFrom, TerminateEl).

-spec route(jid:jid(), jid:jid(), exml:element()) -> mongoose_acc:t().
route(From, To, El) ->
    ejabberd_router:route(From, To,
                          mongoose_acc:new(#{from_jid => From,
                                            to_jid => To,
                                            location => ?LOCATION,
                                            lserver => From#jid.lserver,
                                            element => El})).

%%--------------------------------------------------------------------
%% Error messages
%%--------------------------------------------------------------------

-spec error_message(atom()) -> binary().
error_message(ephemeral_key) ->
    <<"Failed to create voice session. Please try again later.">>;
error_message(sdp_exchange) ->
    <<"Failed to establish voice connection. Please try again later.">>.

%%--------------------------------------------------------------------
%% Default call prompt
%%--------------------------------------------------------------------

-spec default_call_prompt() -> binary().
default_call_prompt() ->
    <<"You are a helpful and friendly AI voice assistant. Your responsibilities:\n"
      "- Answer questions clearly and conversationally\n"
      "- Be concise since this is a real-time voice conversation\n"
      "- Use natural spoken language, avoid technical jargon unless asked\n"
      "- Be warm, patient, and professional\n"
      "Keep responses brief (2-3 sentences) and conversational.">>.