%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_user_privacy.erl
%%% Purpose : Central, per-user WhatsApp-style privacy store.
%%%
%%% One table, many fields. Each feature (last_seen, avatar,
%%% phone_number, availability, group_direct_invite, …) just calls
%%% {@link is_visible/4} when deciding whether to reveal its data
%%% to a requester.
%%%
%%% Privacy values: `everyone' | `contacts' | `nobody'.
%%% `contacts' means the requester has roster subscription `from'
%%% or `both' on the target (target has approved them).
%%%
%%% Protocol (namespace `wingtrill:privacy'):
%%%
%%%   --- Read all privacy fields ---
%%%   <iq type="get" id="p1">
%%%     <query xmlns="wingtrill:privacy"/>
%%%   </iq>
%%%
%%%   <iq type="result" id="p1">
%%%     <query xmlns="wingtrill:privacy">
%%%       <field name="last_seen"           value="contacts"/>
%%%       <field name="availability"        value="everyone"/>
%%%       <field name="group_direct_invite" value="contacts"/>
%%%       <field name="avatar"              value="everyone"/>
%%%       <field name="phone_number"        value="contacts"/>
%%%     </query>
%%%   </iq>
%%%
%%%   --- Set one or more fields ---
%%%   <iq type="set" id="p2">
%%%     <query xmlns="wingtrill:privacy">
%%%       <field name="last_seen" value="contacts"/>
%%%       <field name="avatar"    value="nobody"/>
%%%     </query>
%%%   </iq>
%%% @end
%%%----------------------------------------------------------------------
-module(mod_user_privacy).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").
-include("mod_roster.hrl").

%% jlib.hrl already defines NS_PRIVACY for XEP-0016.
-define(NS_USER_PRIVACY, <<"wingtrill:privacy">>).

%% Known privacy fields — add to this list to expose a new one.
-define(FIELDS, [<<"last_seen">>,
                 <<"availability">>,
                 <<"group_direct_invite">>,
                 <<"avatar">>,
                 <<"phone_number">>]).

-define(VALUES, [<<"everyone">>, <<"contacts">>, <<"nobody">>]).
-define(DEFAULT_VALUE, <<"everyone">>).

%% gen_mod
-export([start/2, stop/1, hooks/1, supported_features/0, config_spec/0]).

%% Public API for other custom modules
-export([get_privacy/3,
         set_privacy/4,
         is_visible/4,
         is_contact/3,
         known_fields/0]).

%% Hook handler
-export([user_send_iq/3]).

-ignore_xref([user_send_iq/3]).

%%%----------------------------------------------------------------------
%%% gen_mod
%%%----------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(HostType, Opts) ->
    mod_user_privacy_backend:init(HostType, Opts).

-spec stop(mongooseim:host_type()) -> any().
stop(_HostType) ->
    ok.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_iq, HostType, fun ?MODULE:user_send_iq/3, #{}, 50}].

-spec supported_features() -> [atom()].
supported_features() -> [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"backend">> => #option{type = atom,
                                          validate = {module, mod_user_privacy}}
                },
       defaults = #{<<"backend">> => rdbms}
      }.

%%%----------------------------------------------------------------------
%%% Public API — used by mod_last_seen and friends
%%%----------------------------------------------------------------------

-spec known_fields() -> [binary()].
known_fields() -> ?FIELDS.

%% Look up one field; missing rows default to `everyone'.
-spec get_privacy(mongooseim:host_type(), jid:jid() | {jid:lserver(), jid:luser()},
                  binary()) -> binary().
get_privacy(HostType, #jid{luser = LUser, lserver = LServer}, Field) ->
    get_privacy(HostType, {LServer, LUser}, Field);
get_privacy(HostType, {LServer, LUser}, Field) ->
    case mod_user_privacy_backend:get_privacy(HostType, LServer, LUser, Field) of
        {ok, Value} -> Value;
        not_found -> ?DEFAULT_VALUE
    end.

-spec set_privacy(mongooseim:host_type(), jid:jid(), binary(), binary()) ->
    ok | {error, term()}.
set_privacy(HostType, #jid{luser = LUser, lserver = LServer}, Field, Value) ->
    case is_known_field(Field) andalso is_valid_value(Value) of
        true ->
            mod_user_privacy_backend:set_privacy(HostType, LServer, LUser, Field, Value);
        false ->
            {error, bad_request}
    end.

%% Can `RequesterJid' see `Field' on `TargetJid'?
%% Self always sees self. Otherwise honour the target's privacy choice.
-spec is_visible(mongooseim:host_type(), jid:jid(), jid:jid(), binary()) -> boolean().
is_visible(HostType, RequesterJid, TargetJid, Field) ->
    case same_bare(RequesterJid, TargetJid) of
        true ->
            true;
        false ->
            case get_privacy(HostType, TargetJid, Field) of
                <<"everyone">> -> true;
                <<"nobody">> -> false;
                <<"contacts">> -> is_contact(HostType, TargetJid, RequesterJid)
            end
    end.

%% Is `RequesterJid' a contact of `TargetJid'? That is, does `TargetJid'
%% have a roster entry for them with subscription `from' or `both'.
-spec is_contact(mongooseim:host_type(), jid:jid(), jid:jid()) -> boolean().
is_contact(HostType, TargetJid, RequesterJid) ->
    RequesterLJID = jid:to_lower(jid:to_bare(RequesterJid)),
    case mod_roster:get_roster_entry(HostType, TargetJid, RequesterLJID, short) of
        #roster{subscription = both} -> true;
        #roster{subscription = from} -> true;
        _ -> false
    end.

%%%----------------------------------------------------------------------
%%% IQ handling via user_send_iq hook
%%%----------------------------------------------------------------------

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, _Params, #{host_type := HostType}) ->
    case mongoose_iq:info(Acc) of
        {#iq{xmlns = ?NS_USER_PRIVACY} = IQ, Acc1} ->
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid = mongoose_acc:to_jid(Acc1),
            Reply = handle_iq(HostType, FromJid, IQ),
            ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(Reply)),
            {stop, Acc1};
        _ ->
            {ok, Acc}
    end.

-spec handle_iq(mongooseim:host_type(), jid:jid(), jlib:iq()) -> jlib:iq().
handle_iq(HostType, FromJid, #iq{type = get, sub_el = SubEl} = IQ) ->
    Fields = requested_fields(SubEl),
    Results = [{F, get_privacy(HostType, FromJid, F)} || F <- Fields],
    IQ#iq{type = result, sub_el = [privacy_query_el(Results)]};
handle_iq(HostType, FromJid, #iq{type = set, sub_el = SubEl} = IQ) ->
    case parse_field_updates(SubEl) of
        {ok, Updates} ->
            apply_updates(HostType, FromJid, Updates),
            IQ#iq{type = result, sub_el = []};
        {error, Reason} ->
            error_reply(IQ, Reason)
    end;
handle_iq(_HostType, _FromJid, IQ) ->
    error_reply(IQ, bad_request).

%%%----------------------------------------------------------------------
%%% Parsing / rendering helpers
%%%----------------------------------------------------------------------

%% Empty `<query/>' returns all known fields; otherwise only the named
%% `<field name="..."/>' children that belong to the whitelist.
-spec requested_fields(exml:element()) -> [binary()].
requested_fields(#xmlel{children = Children}) ->
    Named = [exml_query:attr(El, <<"name">>)
             || El = #xmlel{name = <<"field">>} <- Children],
    Filtered = [N || N <- Named, is_known_field(N)],
    case Filtered of
        [] -> ?FIELDS;
        _ -> lists:usort(Filtered)
    end.

-spec parse_field_updates(exml:element()) ->
    {ok, [{binary(), binary()}]} | {error, bad_request}.
parse_field_updates(#xmlel{children = Children}) ->
    Fields = [El || El = #xmlel{name = <<"field">>} <- Children],
    case Fields of
        [] ->
            {error, bad_request};
        _ ->
            parse_updates(Fields, [])
    end.

parse_updates([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_updates([El | Rest], Acc) ->
    Name = exml_query:attr(El, <<"name">>),
    Value = exml_query:attr(El, <<"value">>),
    case is_known_field(Name) andalso is_valid_value(Value) of
        true -> parse_updates(Rest, [{Name, Value} | Acc]);
        false -> {error, bad_request}
    end.

-spec apply_updates(mongooseim:host_type(), jid:jid(), [{binary(), binary()}]) -> ok.
apply_updates(HostType, #jid{luser = LUser, lserver = LServer}, Updates) ->
    lists:foreach(
        fun({Field, Value}) ->
            case mod_user_privacy_backend:set_privacy(HostType, LServer, LUser,
                                                      Field, Value) of
                ok -> ok;
                {error, Reason} ->
                    ?LOG_WARNING(#{what => user_privacy_set_failed,
                                   reason => Reason, field => Field,
                                   value => Value, user => LUser, server => LServer})
            end
        end, Updates).

-spec privacy_query_el([{binary(), binary()}]) -> exml:element().
privacy_query_el(Results) ->
    #xmlel{name = <<"query">>,
           attrs = #{<<"xmlns">> => ?NS_USER_PRIVACY},
           children = [field_el(F, V) || {F, V} <- Results]}.

field_el(Field, Value) ->
    #xmlel{name = <<"field">>,
           attrs = #{<<"name">> => Field, <<"value">> => Value},
           children = []}.

%%%----------------------------------------------------------------------
%%% Validation helpers
%%%----------------------------------------------------------------------

is_known_field(undefined) -> false;
is_known_field(Field) -> lists:member(Field, ?FIELDS).

is_valid_value(undefined) -> false;
is_valid_value(Value) -> lists:member(Value, ?VALUES).

same_bare(#jid{luser = U1, lserver = S1}, #jid{luser = U2, lserver = S2}) ->
    U1 =:= U2 andalso S1 =:= S2.

-spec error_reply(jlib:iq(), atom()) -> jlib:iq().
error_reply(#iq{sub_el = SubEl} = IQ, bad_request) ->
    IQ#iq{type = error, sub_el = [SubEl, mongoose_xmpp_errors:bad_request()]}.