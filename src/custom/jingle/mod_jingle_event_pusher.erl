%%%-------------------------------------------------------------------
%%% @doc Jingle call-event pusher to RabbitMQ.
%%%
%%% A standalone gen_mod that listens for outgoing Jingle IQ stanzas
%%% (urn:xmpp:jingle:1) and publishes call lifecycle events to a
%%% dedicated RabbitMQ topic exchange.  These events are consumed by
%%% wingtrill-notifier which fans out iOS VoIP pushes and Android
%%% high-priority FCM data messages.
%%%
%%% This module deliberately does NOT use mod_event_pusher; it reuses
%%% the same RabbitMQ worker pool (`event_pusher') so no extra
%%% connection infrastructure is required.
%%%
%%% Actions published:
%%%   session-initiate -> call_invite   (notify the callee)
%%%   session-accept   -> call_accept   (notify the caller)
%%%   session-terminate -> call_terminate (notify the other party)
%%%   session-info/ringing -> call_ringing (notify the caller)
%%% @end
%%%-------------------------------------------------------------------
-module(mod_jingle_event_pusher).

-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, supported_features/0, config_spec/0, hooks/1]).

%% Hook handlers
-export([user_send_iq/3]).

-ignore_xref([user_send_iq/3]).

-define(NS_JINGLE, <<"urn:xmpp:jingle:1">>).
-define(NS_JINGLE_RTP, <<"urn:xmpp:jingle:apps:rtp:1">>).
-define(NS_JINGLE_RTP_INFO, <<"urn:xmpp:jingle:apps:rtp:info:1">>).
-define(POOL_TAG, event_pusher).

-type exchange_opts() :: #{name := binary(), type := binary(), durable := boolean()}.
-type topic_map() :: #{invite := binary(), accept := binary(), terminate := binary(),
                       ringing := binary()}.

%%%===================================================================
%%% gen_mod callbacks
%%%===================================================================

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
start(HostType, Opts) ->
    create_exchange(HostType, maps:get(exchange, Opts)),
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
       items = #{<<"exchange">> => exchange_spec(<<"call_events">>),
                 <<"topics">> => topics_spec()}
      }.

-spec topics_spec() -> mongoose_config_spec:config_section().
topics_spec() ->
    #section{
       items = #{<<"invite">> => #option{type = binary,
                                         validate = non_empty},
                 <<"accept">> => #option{type = binary,
                                         validate = non_empty},
                 <<"terminate">> => #option{type = binary,
                                            validate = non_empty},
                 <<"ringing">> => #option{type = binary,
                                          validate = non_empty}},
       defaults = #{<<"invite">> => <<"call_invite">>,
                    <<"accept">> => <<"call_accept">>,
                    <<"terminate">> => <<"call_terminate">>,
                    <<"ringing">> => <<"call_ringing">>}
      }.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    %% Priority 40: run before mod_jingle (priority 50) so we observe the
    %% outgoing IQ before it is relayed, but return {ok, Acc} so normal
    %% routing continues.
    [{user_send_iq, HostType, fun ?MODULE:user_send_iq/3, #{}, 40}].

%%%===================================================================
%%% Hook handler
%%%===================================================================

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, _Params, #{host_type := HostType}) ->
    {From, To, Packet} = mongoose_acc:packet(Acc),
    case exml_query:subelement_with_ns(Packet, ?NS_JINGLE) of
        undefined ->
            {ok, Acc};
        JingleEl ->
            handle_jingle(HostType, From, To, JingleEl),
            {ok, Acc}
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

-spec handle_jingle(mongooseim:host_type(), jid:jid(), jid:jid(), exml:element()) -> ok.
handle_jingle(HostType, From, To, JingleEl) ->
    Action = exml_query:attr(JingleEl, <<"action">>),
    Sid = exml_query:attr(JingleEl, <<"sid">>, <<>>),
    case event_topic(HostType, Action, JingleEl) of
        undefined ->
            ok;
        Topic ->
            publish(HostType, From, To, Topic, Action, Sid, JingleEl)
    end.

-spec event_topic(mongooseim:host_type(), binary() | undefined, exml:element()) ->
    binary() | undefined.
event_topic(HostType, <<"session-initiate">>, _) -> topic(HostType, invite);
event_topic(HostType, <<"session-accept">>, _) -> topic(HostType, accept);
event_topic(HostType, <<"session-terminate">>, _) -> topic(HostType, terminate);
%% "session-info" also carries active/hold/mute/checksum, etc. (XEP-0167/0353)
%% -- only the "ringing" informational element is a call-lifecycle event.
event_topic(HostType, <<"session-info">>, JingleEl) ->
    case is_ringing_info(JingleEl) of
        true -> topic(HostType, ringing);
        false -> undefined
    end;
event_topic(_, _, _) -> undefined.

-spec is_ringing_info(exml:element()) -> boolean().
is_ringing_info(JingleEl) ->
    exml_query:path(JingleEl, [{element_with_ns, <<"ringing">>, ?NS_JINGLE_RTP_INFO}]) =/= undefined.

-spec topic(mongooseim:host_type(), invite | accept | terminate | ringing) -> binary().
topic(HostType, Key) ->
    maps:get(Key, gen_mod:get_module_opt(HostType, ?MODULE, topics, default_topics())).

-spec default_topics() -> topic_map().
default_topics() ->
    #{invite => <<"call_invite">>,
      accept => <<"call_accept">>,
      terminate => <<"call_terminate">>,
      ringing => <<"call_ringing">>}.

-spec publish(mongooseim:host_type(), jid:jid(), jid:jid(), binary(),
              binary(), binary(), exml:element()) -> ok.
publish(HostType, From, To, Topic, Action, Sid, JingleEl) ->
    case exchange_opts(HostType) of
        undefined ->
            ?LOG_ERROR(#{what => jingle_event_pusher_no_exchange,
                         host_type => HostType}),
            ok;
        #{name := ExchangeName} ->
            Payload = build_payload(From, To, Action, Sid, JingleEl),
            MessageJSON = iolist_to_binary(jiffy:encode(Payload)),
            RoutingKey = routing_key(To, Topic),
            PublishMethod = mongoose_amqp:basic_publish(ExchangeName, RoutingKey),
            AMQPMessage = mongoose_amqp:message(MessageJSON),
            cast_rabbit_worker(HostType, {amqp_publish, PublishMethod, AMQPMessage}),
            ?LOG_DEBUG(#{what => jingle_event_published,
                         host_type => HostType,
                         action => Action,
                         routing_key => RoutingKey}),
            ok
    end.

-spec build_payload(jid:jid(), jid:jid(), binary(), binary(), exml:element()) -> map().
build_payload(From, To, Action, Sid, JingleEl) ->
    Base = #{from_user_id => jid:to_binary(jid:to_lower(From)),
             to_user_id => jid:to_binary(jid:to_lower(To)),
             action => Action,
             sid => Sid,
             timestamp => erlang:system_time(second)},
    case call_type(JingleEl) of
        undefined -> Base;
        CallType -> Base#{call_type => CallType}
    end.

-spec call_type(exml:element()) -> binary() | undefined.
call_type(JingleEl) ->
    case exml_query:path(JingleEl, [{element_with_ns, <<"content">>, ?NS_JINGLE},
                                    {element_with_ns, <<"description">>, ?NS_JINGLE_RTP},
                                    {attr, <<"media">>}]) of
        <<"audio">> -> <<"audio">>;
        <<"video">> -> <<"video">>;
        _ -> undefined
    end.

-spec routing_key(jid:jid(), binary()) -> binary().
routing_key(ToJid, Topic) ->
    BinJID = jid:to_binary(jid:to_lus(ToJid)),
    <<BinJID/binary, ".", Topic/binary>>.

-spec create_exchange(mongooseim:host_type(), exchange_opts()) -> ok.
create_exchange(HostType, #{name := ExName, type := Type, durable := Durable}) ->
    Method = {amqp_call, mongoose_amqp:exchange_declare(ExName, Type, Durable)},
    Expected = mongoose_amqp:exchange_declare_ok(),
    case call_rabbit_worker(HostType, Method) of
        {ok, Expected} ->
            ok;
        Result ->
            error(#{what => creating_jingle_exchange_failed,
                    host_type => HostType,
                    result => Result})
    end.

-spec exchange_opts(mongooseim:host_type()) -> exchange_opts() | undefined.
exchange_opts(HostType) ->
    gen_mod:get_module_opt(HostType, ?MODULE, exchange).

-spec call_rabbit_worker(mongooseim:host_type(), term()) -> term().
call_rabbit_worker(HostType, Msg) ->
    mongoose_wpool:call(rabbit, HostType, ?POOL_TAG, Msg).

-spec cast_rabbit_worker(mongooseim:host_type(), term()) -> ok.
cast_rabbit_worker(HostType, Msg) ->
    try
        mongoose_wpool:cast(rabbit, HostType, ?POOL_TAG, Msg)
    catch
        exit:no_workers ->
            ?LOG_NOTICE(#{what => no_jingle_event_rabbit_worker_available,
                          text => <<"Dropping Jingle event because no rabbit worker is available">>,
                          host_type => HostType,
                          dropped_request => Msg})
    end.

-spec exchange_spec(binary()) -> mongoose_config_spec:config_section().
exchange_spec(Name) ->
    #section{items = #{<<"name">> => #option{type = binary,
                                             validate = non_empty},
                       <<"type">> => #option{type = binary,
                                             validate = non_empty},
                       <<"durable">> => #option{type = boolean}},
             defaults = #{<<"name">> => Name,
                          <<"type">> => <<"topic">>,
                          <<"durable">> => false}}.
