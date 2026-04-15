%%%-------------------------------------------------------------------
%%% @doc Jingle relay module for peer-to-peer WebRTC calls.
%%%
%%% Intercepts Jingle IQ stanzas (urn:xmpp:jingle:1) sent to bare JIDs
%%% and forwards them to the recipient's connected resource(s).
%%%
%%% Without this module, MongooseIM returns service-unavailable for
%%% Jingle IQs addressed to bare JIDs since no module handles the
%%% namespace.
%%%
%%% For calls to the AI bot, mod_ai_bot_call handles those at priority 10.
%%% This module runs at priority 50 so it only catches user-to-user calls.
%%% @end
%%%-------------------------------------------------------------------
-module(mod_jingle).

-behaviour(gen_mod).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, supported_features/0, config_spec/0, hooks/1]).

%% Hook handlers
-export([user_send_iq/3]).

-define(NS_JINGLE, <<"urn:xmpp:jingle:1">>).

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
        items = #{},
        defaults = #{}
    }.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_iq, HostType, fun ?MODULE:user_send_iq/3, #{}, 50}].

%%--------------------------------------------------------------------
%% Hook handler: relay Jingle IQs to the recipient's full JID
%%--------------------------------------------------------------------

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, _Params, _Extra) ->
    {From, To, Packet} = mongoose_acc:packet(Acc),
    case exml_query:subelement_with_ns(Packet, ?NS_JINGLE) of
        undefined ->
            {ok, Acc};
        _JingleEl ->
            case To#jid.lresource of
                <<>> ->
                    %% Bare JID — find online resources and forward
                    relay_to_resources(Acc, From, To, Packet);
                _ ->
                    %% Full JID — let normal routing handle it
                    {ok, Acc}
            end
    end.

%%--------------------------------------------------------------------
%% Internal: forward the Jingle IQ to the recipient's online resources
%%--------------------------------------------------------------------

-spec relay_to_resources(mongoose_acc:t(), jid:jid(), jid:jid(), exml:element()) ->
    mongoose_c2s_hooks:result().
relay_to_resources(Acc, From, To, Packet) ->
    Resources = ejabberd_sm:get_user_resources(To),
    case Resources of
        [] ->
            %% User is offline — let normal error handling reply
            {ok, Acc};
        [Resource | _] ->
            %% Forward to the first available resource.
            %% Do NOT send a fake ack — the callee's real response
            %% will route back to the caller directly.
            FullTo = jid:replace_resource(To, Resource),
            NewPacket = set_attr(<<"to">>, jid:to_binary(FullTo), Packet),
            route(From, FullTo, NewPacket),
            {stop, Acc}
    end.

-spec route(jid:jid(), jid:jid(), exml:element()) -> mongoose_acc:t().
route(From, To, El) ->
    ejabberd_router:route(From, To,
                          mongoose_acc:new(#{from_jid => From,
                                            to_jid => To,
                                            location => ?LOCATION,
                                            lserver => From#jid.lserver,
                                            element => El})).


-spec set_attr(binary(), binary(), exml:element()) -> exml:element().
set_attr(Key, Value, #xmlel{attrs = Attrs} = El) when is_map(Attrs) ->
    El#xmlel{attrs = Attrs#{Key => Value}};
set_attr(Key, Value, #xmlel{attrs = Attrs} = El) ->
    NewAttrs = lists:keystore(Key, 1, Attrs, {Key, Value}),
    El#xmlel{attrs = NewAttrs}.