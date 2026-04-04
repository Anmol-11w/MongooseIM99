%%%----------------------------------------------------------------------
%%% File    : mod_contact_sync.erl
%%% Purpose : Phone-based contact sync via JWT phone_number claims
%%%
%%% Client sends a list of phone numbers, server returns matching JIDs
%%% and optionally adds them to the roster with mutual subscription.
%%%
%%% Protocol:
%%%   <iq type="set" id="sync1">
%%%     <query xmlns="wingtrill:contact:sync">
%%%       <phone>+918427311922</phone>
%%%       <phone>+918427411922</phone>
%%%     </query>
%%%   </iq>
%%%
%%% Response:
%%%   <iq type="result" id="sync1">
%%%     <query xmlns="wingtrill:contact:sync">
%%%       <contact phone="+1234567890" jid="user1@domain.com"/>
%%%       <contact phone="+0987654321" jid="user2@domain.com"/>
%%%     </query>
%%%   </iq>
%%%----------------------------------------------------------------------
-module(mod_contact_sync).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").
-include("mod_roster.hrl").

-define(NS_CONTACT_SYNC, <<"wingtrill:contact:sync">>).
-define(PHONE_CACHE, mod_contact_sync_phone_cache).

-export([start/2, stop/1, hooks/1, supported_features/0, config_spec/0]).
-export([user_send_iq/3]).
-export([jwt_user_phone/3]).
-export([user_open_session/3]).

-ignore_xref([user_send_iq/3, jwt_user_phone/3, user_open_session/3]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(HostType, Opts) ->
    mod_contact_sync_backend:init(HostType, Opts),
    ensure_phone_cache().

-spec stop(mongooseim:host_type()) -> any().
stop(_HostType) ->
    ok.
-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{jwt_user_phone, HostType, fun ?MODULE:jwt_user_phone/3, #{}, 50},
     {user_open_session, HostType, fun ?MODULE:user_open_session/3, #{}, 50},
     {user_send_iq, HostType, fun ?MODULE:user_send_iq/3, #{}, 50}].
-spec supported_features() -> [atom()].
supported_features() -> [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"backend">> => #option{type = atom,
                                          validate = {module, mod_contact_sync}},
                 <<"add_to_roster">> => #option{type = boolean}
                },
       defaults = #{<<"backend">> => rdbms,
                    <<"add_to_roster">> => true}
      }.

%%%----------------------------------------------------------------------
%%% Hook handler: store phone from JWT auth
%%%----------------------------------------------------------------------

-spec jwt_user_phone(Acc, Params, Extra) -> {ok, Acc} when
    Acc :: ok,
    Params :: #{lserver := jid:lserver(), luser := jid:luser(), phone := binary()},
    Extra :: gen_hook:extra().
jwt_user_phone(Acc, #{lserver := LServer, luser := LUser, phone := Phone},
               #{host_type := HostType}) ->
    case mod_contact_sync_backend:store_phone(HostType, LServer, LUser, Phone) of
        ok ->
            ?LOG_INFO(#{what => phone_contact_stored,
                        phone => Phone, user => LUser, server => LServer});
        {error, Reason} ->
            ?LOG_WARNING(#{what => phone_contact_store_failed,
                           reason => Reason, phone => Phone,
                           user => LUser, server => LServer})
    end,
    %% Cache phone for pickup by user_open_session hook
    ets:insert(?PHONE_CACHE, {{LUser, LServer}, Phone}),
    {ok, Acc}.

%%%----------------------------------------------------------------------
%%% Hook handler: store phone_number in c2s_data info map
%%%----------------------------------------------------------------------

-spec user_open_session(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_open_session(Acc, #{c2s_data := StateData}, _Extra) ->
    Jid = mongoose_c2s:get_jid(StateData),
    LUser = Jid#jid.luser,
    LServer = Jid#jid.lserver,
    case ets:lookup(?PHONE_CACHE, {LUser, LServer}) of
        [{_, Phone}] ->
            ets:delete(?PHONE_CACHE, {LUser, LServer}),
            ?LOG_INFO(#{what => phone_stored_in_session,
                        phone => Phone, user => LUser, server => LServer}),
            Info = mongoose_c2s:get_info(StateData),
            NewStateData = mongoose_c2s:set_info(StateData,
                               Info#{phone_number => Phone}),
            NewAcc = mongoose_c2s_acc:to_acc(Acc, c2s_data, NewStateData),
            {ok, NewAcc};
        [] ->
            {ok, Acc}
    end.

%%%----------------------------------------------------------------------
%%% IQ handling via user_send_iq hook
%%%----------------------------------------------------------------------

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, #{c2s_data := StateData}, #{host_type := HostType}) ->
    case mongoose_iq:info(Acc) of
        {#iq{xmlns = ?NS_CONTACT_SYNC, type = set, sub_el = SubEl} = IQ, Acc1} ->
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid = mongoose_acc:to_jid(Acc1),
            LServer = FromJid#jid.lserver,
            Phones = extract_phones(SubEl),
            case Phones of
                [] ->
                    ErrorIQ = IQ#iq{type = error,
                                   sub_el = [SubEl, mongoose_xmpp_errors:bad_request()]},
                    ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(ErrorIQ)),
                    {stop, Acc1};
                _ ->
                    Matches = mod_contact_sync_backend:lookup_phones(HostType, LServer, Phones),
                    CallerUser = FromJid#jid.luser,
                    FilteredMatches = [{P, U} || {P, U} <- Matches, U =/= CallerUser],
                    AddToRoster = gen_mod:get_module_opt(HostType, ?MODULE, add_to_roster),
                    case AddToRoster of
                        true ->
                            Info = mongoose_c2s:get_info(StateData),
                            CallerPhone = maps:get(phone_number, Info, <<>>),
                            add_matches_to_roster(HostType, jid:to_bare(FromJid), CallerPhone,
                                                  LServer, FilteredMatches);
                        false ->
                            ok
                    end,
                    ResultChildren = [match_to_xml(Phone, User, LServer)
                                      || {Phone, User} <- FilteredMatches],
                    ResultEl = #xmlel{name = <<"query">>,
                                      attrs = #{<<"xmlns">> => ?NS_CONTACT_SYNC},
                                      children = ResultChildren},
                    ResultIQ = IQ#iq{type = result, sub_el = [ResultEl]},
                    ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(ResultIQ)),
                    {stop, Acc1}
            end;
        {#iq{xmlns = ?NS_CONTACT_SYNC, type = get, sub_el = SubEl} = IQ, Acc1} ->
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid = mongoose_acc:to_jid(Acc1),
            ErrorIQ = IQ#iq{type = error,
                            sub_el = [SubEl, mongoose_xmpp_errors:not_allowed()]},
            ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(ErrorIQ)),
            {stop, Acc1};
        _ ->
            {ok, Acc}
    end.

%%%----------------------------------------------------------------------
%%% Phone extraction from stanza
%%%----------------------------------------------------------------------

-spec extract_phones(exml:element()) -> [binary()].
extract_phones(#xmlel{children = Children}) ->
    lists:filtermap(fun extract_phone/1, Children).

extract_phone(#xmlel{name = <<"phone">>, children = Children}) ->
    case exml_query:cdata(#xmlel{name = <<"phone">>, children = Children}) of
        <<>> -> false;
        Phone -> {true, Phone}
    end;
extract_phone(_) ->
    false.

%%%----------------------------------------------------------------------
%%% Roster integration
%%%
%%% Subscription logic:
%%%   User1 syncs and finds User2's phone:
%%%     - Check if User2 already has User1 in their roster
%%%       (meaning User2 previously synced and had User1's phone)
%%%     - If yes  → subscribe_both (mutual presence)
%%%     - If no   → one-way: add User2 to User1's roster only
%%%   When User2 later syncs and finds User1, the reverse check
%%%   sees User1 already has User2, so it upgrades to subscribe_both.
%%%----------------------------------------------------------------------

-spec add_matches_to_roster(mongooseim:host_type(), jid:jid(), binary(),
                            jid:lserver(), [{binary(), binary()}]) -> ok.
add_matches_to_roster(HostType, CallerJid, CallerPhone, LServer, Matches) ->
    lists:foreach(
        fun({Phone, ContactUser}) ->
            ContactJid = jid:make_bare(ContactUser, LServer),
            ContactNick = case Phone of
                              <<>> -> ContactUser;
                              _ -> Phone
                          end,
            CallerNick = case CallerPhone of
                             <<>> -> CallerJid#jid.luser;
                             _ -> CallerPhone
                         end,
            sync_roster_entry(HostType, CallerJid, CallerNick,
                              ContactJid, ContactNick)
        end, Matches).

-spec sync_roster_entry(mongooseim:host_type(), jid:jid(), binary(),
                        jid:jid(), binary()) -> ok.
sync_roster_entry(HostType, CallerJid, CallerNick, ContactJid, ContactNick) ->
    case has_both_subscription(HostType, CallerJid, ContactJid) of
        true ->
            %% Already fully subscribed, nothing to do
            ok;
        false ->
            %% Check if the contact already has the caller in their roster
            %% (any state: pending subscribe, one-way, etc.)
            case has_roster_entry(HostType, ContactJid, CallerJid) of
                false ->
                    %% Contact does NOT have caller → one-way only
                    add_one_way(CallerJid, ContactJid, ContactNick);
                true ->
                    %% Contact already has caller in roster → upgrade to mutual
                    make_mutual(CallerJid, CallerNick, ContactJid, ContactNick)
            end
    end.

%% Check if CallerJid has ContactJid in their roster (any state)
-spec has_roster_entry(mongooseim:host_type(), jid:jid(), jid:jid()) -> boolean().
has_roster_entry(HostType, CallerJid, ContactJid) ->
    ContactLJID = jid:to_lower(ContactJid),
    case mod_roster:get_roster_entry(HostType, CallerJid, ContactLJID, short) of
        #roster{} -> true;
        _ -> false
    end.

%% Check if subscription is already both
-spec has_both_subscription(mongooseim:host_type(), jid:jid(), jid:jid()) -> boolean().
has_both_subscription(HostType, CallerJid, ContactJid) ->
    ContactLJID = jid:to_lower(ContactJid),
    case mod_roster:get_roster_entry(HostType, CallerJid, ContactLJID, short) of
        #roster{subscription = both} -> true;
        _ -> false
    end.

%% One-way: add contact to caller's roster, subscribe caller → contact
-spec add_one_way(jid:jid(), jid:jid(), binary()) -> ok.
add_one_way(CallerJid, ContactJid, ContactNick) ->
    case mod_roster_api:add_contact(CallerJid, ContactJid,
                                     ContactNick, [<<"Contacts">>]) of
        {ok, _} ->
            mod_roster_api:subscription(CallerJid, ContactJid, subscribe, admin_api),
            ok;
        {Error, Msg} ->
            ?LOG_WARNING(#{what => contact_sync_add_error,
                           reason => Error, msg => iolist_to_binary(Msg),
                           caller => jid:to_binary(CallerJid),
                           contact => jid:to_binary(ContactJid)}),
            ok
    end.

%% Mutual: both users have each other's phone → subscribe_both
-spec make_mutual(jid:jid(), binary(), jid:jid(), binary()) -> ok.
make_mutual(CallerJid, CallerNick, ContactJid, ContactNick) ->
    case mod_roster_api:subscribe_both(
            {CallerJid, ContactNick, [<<"Contacts">>]},
            {ContactJid, CallerNick, [<<"Contacts">>]},
            admin_api) of
        {ok, _} ->
            ok;
        {Error, Msg} ->
            ?LOG_WARNING(#{what => contact_sync_subscribe_error,
                           reason => Error, msg => iolist_to_binary(Msg),
                           caller => jid:to_binary(CallerJid),
                           contact => jid:to_binary(ContactJid)}),
            ok
    end.

%%%----------------------------------------------------------------------
%%% XML helpers
%%%----------------------------------------------------------------------

-spec match_to_xml(binary(), binary(), jid:lserver()) -> exml:element().
match_to_xml(Phone, Username, LServer) ->
    Jid = <<Username/binary, "@", LServer/binary>>,
    #xmlel{name = <<"contact">>,
           attrs = #{<<"phone">> => Phone, <<"jid">> => Jid},
           children = []}.

%%%----------------------------------------------------------------------
%%% ETS phone cache (bridges auth → session open)
%%%----------------------------------------------------------------------

ensure_phone_cache() ->
    case ets:whereis(?PHONE_CACHE) of
        undefined ->
            ets:new(?PHONE_CACHE, [named_table, public, set]);
        _ ->
            ok
    end.