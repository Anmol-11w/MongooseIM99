%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_last_seen.erl
%%% Purpose : WhatsApp-style last-seen query.
%%%
%%% Wraps the standard XEP-0012 timestamps (mod_last) and the live
%%% presence registry (ejabberd_sm) behind a privacy check against
%%% the shared {@link mod_user_privacy} store (field `last_seen').
%%%
%%% Expects `mod_last' and `mod_user_privacy' to be enabled.
%%%
%%% Protocol (namespace `wingtrill:last:seen'):
%%%
%%%   <iq type="get" to="bob@host" id="ls1">
%%%     <query xmlns="wingtrill:last:seen"/>
%%%   </iq>
%%%
%%%   <iq type="result" from="bob@host" id="ls1">
%%%     <query xmlns="wingtrill:last:seen"
%%%            status="online|offline|hidden"
%%%            seconds="1234"/>
%%%   </iq>
%%% @end
%%%----------------------------------------------------------------------
-module(mod_last_seen).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

-define(NS_LAST_SEEN, <<"wingtrill:last:seen">>).
-define(FIELD_LAST_SEEN, <<"last_seen">>).

-export([start/2, stop/1, hooks/1, supported_features/0, config_spec/0]).
-export([user_send_iq/3]).

-ignore_xref([user_send_iq/3]).

%%%----------------------------------------------------------------------
%%% gen_mod
%%%----------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(_HostType, _Opts) -> ok.

-spec stop(mongooseim:host_type()) -> any().
stop(_HostType) -> ok.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_iq, HostType, fun ?MODULE:user_send_iq/3, #{}, 50}].

-spec supported_features() -> [atom()].
supported_features() -> [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{items = #{}}.

%%%----------------------------------------------------------------------
%%% IQ handling via user_send_iq hook
%%%----------------------------------------------------------------------

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, _Params, #{host_type := HostType}) ->
    case mongoose_iq:info(Acc) of
        {#iq{xmlns = ?NS_LAST_SEEN, type = get} = IQ, Acc1} ->
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid = mongoose_acc:to_jid(Acc1),
            TargetJid = resolve_target(FromJid, ToJid),
            Reply = build_reply(HostType, FromJid, TargetJid, IQ),
            ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(Reply)),
            {stop, Acc1};
        {#iq{xmlns = ?NS_LAST_SEEN} = IQ, Acc1} ->
            %% Only `get' is supported; reject set/result/error.
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid = mongoose_acc:to_jid(Acc1),
            ErrorIQ = IQ#iq{type = error,
                            sub_el = [IQ#iq.sub_el,
                                      mongoose_xmpp_errors:not_allowed()]},
            ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(ErrorIQ)),
            {stop, Acc1};
        _ ->
            {ok, Acc}
    end.

%%%----------------------------------------------------------------------
%%% Reply building
%%%----------------------------------------------------------------------

%% IQs addressed to a bare server (no `luser') are treated as self-query.
-spec resolve_target(jid:jid(), jid:jid()) -> jid:jid().
resolve_target(FromJid, ToJid) ->
    case (jid:to_bare(ToJid))#jid.luser of
        <<>> -> jid:to_bare(FromJid);
        _ -> jid:to_bare(ToJid)
    end.

-spec build_reply(mongooseim:host_type(), jid:jid(), jid:jid(), jlib:iq()) -> jlib:iq().
build_reply(HostType, RequesterJid, TargetJid, IQ) ->
    case mod_user_privacy:is_visible(HostType, RequesterJid, TargetJid,
                                     ?FIELD_LAST_SEEN) of
        true ->
            {Status, Seconds} = resolve_presence(HostType, TargetJid),
            IQ#iq{type = result, sub_el = [query_el(Status, Seconds)]};
        false ->
            IQ#iq{type = result, sub_el = [query_el(<<"hidden">>, undefined)]}
    end.

-spec resolve_presence(mongooseim:host_type(), jid:jid()) ->
    {Status :: binary(), Seconds :: non_neg_integer() | undefined}.
resolve_presence(HostType, #jid{luser = LU, lserver = LS}) ->
    case ejabberd_sm:get_user_resources(jid:make_bare(LU, LS)) of
        [_ | _] ->
            {<<"online">>, 0};
        [] ->
            Now = erlang:system_time(second),
            case mod_last:get_last_info(HostType, LU, LS) of
                {ok, Ts, _Status} when is_integer(Ts) ->
                    {<<"offline">>, max(0, Now - Ts)};
                _ ->
                    {<<"offline">>, undefined}
            end
    end.

-spec query_el(binary(), non_neg_integer() | undefined) -> exml:element().
query_el(Status, undefined) ->
    #xmlel{name = <<"query">>,
           attrs = #{<<"xmlns">> => ?NS_LAST_SEEN, <<"status">> => Status},
           children = []};
query_el(Status, Seconds) ->
    #xmlel{name = <<"query">>,
           attrs = #{<<"xmlns">> => ?NS_LAST_SEEN,
                     <<"status">> => Status,
                     <<"seconds">> => integer_to_binary(Seconds)},
           children = []}.