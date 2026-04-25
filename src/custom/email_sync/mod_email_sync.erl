%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_email_sync.erl
%%% Purpose : Email-based contact discovery via JWT `email' claims.
%%%
%%% == Overview ==
%%%
%%% When a user authenticates with a JWT that carries an `email' claim,
%%% this module stores the normalised (lowercased) address in the
%%% `email_contacts' table via the {@link jwt_user_email/3} hook.
%%%
%%% Clients can then send a list of email addresses they know; the
%%% server returns which of those addresses belong to registered users
%%% and, when `add_to_roster' is enabled, automatically wires up roster
%%% subscriptions between the caller and every match.
%%%
%%% == XMPP Protocol ==
%%%
%%% Namespace: `wingtrill:email:sync'
%%%
%%% Request (IQ set from client):
%%% ```
%%%   <iq type="set" id="sync1">
%%%     <query xmlns="wingtrill:email:sync">
%%%       <email>alice@example.com</email>
%%%       <email>bob@example.com</email>
%%%     </query>
%%%   </iq>
%%% '''
%%%
%%% Response (IQ result from server):
%%% ```
%%%   <iq type="result" id="sync1">
%%%     <query xmlns="wingtrill:email:sync">
%%%       <contact email="alice@example.com" jid="alice@xmpp.domain"/>
%%%     </query>
%%%   </iq>
%%% '''
%%%
%%% An empty `<email>' element or a GET request returns an error IQ.
%%%
%%% == Roster subscription logic ==
%%%
%%% When `add_to_roster = true' (the default):
%%%
%%% <ol>
%%%   <li>User A syncs and the server finds User B's email:
%%%     <ul>
%%%       <li>If B already has A in their roster → `subscribe_both'
%%%           (mutual presence, both see each other online).</li>
%%%       <li>Otherwise → one-way: A is added to B's contact list and
%%%           A subscribes to B's presence. B has not yet synced A's
%%%           email so B gets no subscription yet.</li>
%%%     </ul>
%%%   </li>
%%%   <li>Later, User B syncs and finds User A's email:
%%%     The reverse check now sees A in B's roster, so the subscription
%%%     is upgraded to `subscribe_both'.</li>
%%% </ol>
%%%
%%% This mirrors the behaviour of {@link mod_contact_sync} exactly.
%%%
%%% == Configuration ==
%%%
%%% ```toml
%%% [modules.mod_email_sync]
%%%   backend     = "rdbms"   # only supported backend
%%%   add_to_roster = true    # set false to disable roster wiring
%%% '''
%%%
%%% == Dependencies ==
%%%
%%% * `mod_roster' and `mod_roster_api' must be enabled.
%%% * `ejabberd_auth_jwt' / `custom_ejabberd_auth_jwt' must fire the
%%%   `jwt_user_email' hook on successful JWT authentication.
%%% * The `email_contacts' table must exist (see priv/pg.sql).
%%%
%%% @end
%%%----------------------------------------------------------------------
-module(mod_email_sync).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").
-include("mod_roster.hrl").

%% XMPP namespace handled by this module.
-define(NS_EMAIL_SYNC, <<"wingtrill:email:sync">>).

%% ETS table that bridges the jwt_user_email hook (fired during auth)
%% and the user_open_session hook (fired when the C2S process opens).
%% The two hooks run in different process contexts, so we pass the
%% email through a short-lived public ETS table keyed by {LUser, LServer}.
-define(EMAIL_CACHE, mod_email_sync_email_cache).

-export([start/2, stop/1, hooks/1, supported_features/0, config_spec/0]).
-export([user_send_iq/3, jwt_user_email/3, user_open_session/3]).

-ignore_xref([user_send_iq/3, jwt_user_email/3, user_open_session/3]).

%%%----------------------------------------------------------------------
%%% gen_mod callbacks
%%%----------------------------------------------------------------------

%% @doc Initialise the RDBMS backend and the inter-hook ETS cache.
-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(HostType, Opts) ->
    mod_email_sync_backend:init(HostType, Opts),
    ensure_email_cache().

-spec stop(mongooseim:host_type()) -> any().
stop(_HostType) ->
    ok.

%% @doc Register the three hooks this module drives:
%% <ul>
%%   <li>`jwt_user_email'   – persist email from JWT token on login.</li>
%%   <li>`user_open_session' – move email from ETS cache into C2S state.</li>
%%   <li>`user_send_iq'      – handle the `wingtrill:email:sync' IQ.</li>
%% </ul>
-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{jwt_user_email,    HostType, fun ?MODULE:jwt_user_email/3,    #{}, 50},
     {user_open_session, HostType, fun ?MODULE:user_open_session/3, #{}, 50},
     {user_send_iq,      HostType, fun ?MODULE:user_send_iq/3,      #{}, 50}].

-spec supported_features() -> [atom()].
supported_features() -> [dynamic_domains].

%% @doc Declare the accepted TOML options for this module.
%% `backend'      – backend module atom (default: `rdbms').
%% `add_to_roster' – wire up roster subscriptions automatically (default: `true').
-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"backend">>      => #option{type = atom,
                                               validate = {module, mod_email_sync}},
                 <<"add_to_roster">> => #option{type = boolean}
                },
       defaults = #{<<"backend">>      => rdbms,
                    <<"add_to_roster">> => true}
      }.

%%%----------------------------------------------------------------------
%%% Hook: jwt_user_email
%%%
%%% Fired by custom_ejabberd_auth_jwt:on_auth_success/4 immediately
%%% after a successful JWT login when the token has a non-empty `email'
%%% claim.  We normalise the address to lowercase, persist it to the
%%% database, and stash it in the ETS cache so user_open_session can
%%% embed it in the C2S info map.
%%%----------------------------------------------------------------------

%% @doc Store the authenticated user's email address.
%%
%% Called by the `jwt_user_email' hook.  The email is normalised to
%% lowercase before storage so lookups are case-insensitive.
-spec jwt_user_email(Acc, Params, Extra) -> {ok, Acc} when
    Acc    :: ok,
    Params :: #{lserver := jid:lserver(), luser := jid:luser(), email := binary()},
    Extra  :: gen_hook:extra().
jwt_user_email(Acc,
               #{lserver := LServer, luser := LUser, email := Email},
               #{host_type := HostType}) ->
    NormEmail = normalize_email(Email),
    case mod_email_sync_backend:store_email(HostType, LServer, LUser, NormEmail) of
        ok ->
            ?LOG_INFO(#{what => email_contact_stored,
                        email => NormEmail, user => LUser, server => LServer});
        {error, Reason} ->
            ?LOG_WARNING(#{what => email_contact_store_failed,
                           reason => Reason, email => NormEmail,
                           user => LUser, server => LServer})
    end,
    %% Cache so user_open_session can embed it in C2S state.
    ets:insert(?EMAIL_CACHE, {{LUser, LServer}, NormEmail}),
    {ok, Acc}.

%%%----------------------------------------------------------------------
%%% Hook: user_open_session
%%%
%%% Fired when a C2S session is fully opened.  We move the email from
%%% the ETS cache (written by jwt_user_email above) into the C2S info
%%% map under the key `email_address'.  This makes the caller's own
%%% address available in user_send_iq without a database round-trip,
%%% which is needed to set the CallerNick on the contact's roster entry.
%%%----------------------------------------------------------------------

%% @doc Embed the caller's email into the C2S session info map.
%%
%% Reads from the ETS cache populated by {@link jwt_user_email/3} and
%% stores the email as `email_address' in the C2S state info map.
%% The cache entry is deleted after the move so it does not accumulate.
-spec user_open_session(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_open_session(Acc, #{c2s_data := StateData}, _Extra) ->
    Jid    = mongoose_c2s:get_jid(StateData),
    LUser  = Jid#jid.luser,
    LServer = Jid#jid.lserver,
    case ets:lookup(?EMAIL_CACHE, {LUser, LServer}) of
        [{_, Email}] ->
            ets:delete(?EMAIL_CACHE, {LUser, LServer}),
            ?LOG_INFO(#{what => email_stored_in_session,
                        email => Email, user => LUser, server => LServer}),
            Info        = mongoose_c2s:get_info(StateData),
            NewStateData = mongoose_c2s:set_info(StateData, Info#{email_address => Email}),
            NewAcc      = mongoose_c2s_acc:to_acc(Acc, c2s_data, NewStateData),
            {ok, NewAcc};
        [] ->
            {ok, Acc}
    end.

%%%----------------------------------------------------------------------
%%% Hook: user_send_iq
%%%
%%% Intercepts IQ stanzas whose namespace is wingtrill:email:sync.
%%% Only `set' is supported; `get' returns not-allowed.
%%%
%%% On a valid `set':
%%%   1. Extract and normalise the <email> children.
%%%   2. Look up matching users in the database.
%%%   3. Filter out the caller themselves.
%%%   4. Optionally add matches to the roster (see add_matches_to_roster).
%%%   5. Return a result IQ with <contact email="..." jid="..."/> elements.
%%%----------------------------------------------------------------------

%% @doc Handle the `wingtrill:email:sync' IQ stanza.
%%
%% Accepts a `set' IQ containing one or more `<email>' elements.
%% Returns a `result' IQ with a `<contact>' element for each email
%% address that matches a registered user on this server.
%% Returns `bad-request' for an empty list and `not-allowed' for a `get'.
-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, #{c2s_data := StateData}, #{host_type := HostType}) ->
    case mongoose_iq:info(Acc) of
        {#iq{xmlns = ?NS_EMAIL_SYNC, type = set, sub_el = SubEl} = IQ, Acc1} ->
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid   = mongoose_acc:to_jid(Acc1),
            LServer = FromJid#jid.lserver,
            Emails  = extract_emails(SubEl),
            case Emails of
                [] ->
                    %% Client sent a sync with no email elements.
                    ErrorIQ = IQ#iq{type   = error,
                                    sub_el = [SubEl, mongoose_xmpp_errors:bad_request()]},
                    ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(ErrorIQ)),
                    {stop, Acc1};
                _ ->
                    Matches        = mod_email_sync_backend:lookup_emails(HostType, LServer, Emails),
                    CallerUser     = FromJid#jid.luser,
                    %% Never return the caller as a contact of themselves.
                    FilteredMatches = [{E, U} || {E, U} <- Matches, U =/= CallerUser],
                    AddToRoster = gen_mod:get_module_opt(HostType, ?MODULE, add_to_roster),
                    case AddToRoster of
                        true ->
                            Info        = mongoose_c2s:get_info(StateData),
                            CallerEmail = maps:get(email_address, Info, <<>>),
                            add_matches_to_roster(HostType, jid:to_bare(FromJid),
                                                  CallerEmail, LServer, FilteredMatches);
                        false ->
                            ok
                    end,
                    ResultChildren = [match_to_xml(Email, User, LServer)
                                      || {Email, User} <- FilteredMatches],
                    ResultEl  = #xmlel{name     = <<"query">>,
                                       attrs    = #{<<"xmlns">> => ?NS_EMAIL_SYNC},
                                       children = ResultChildren},
                    ResultIQ  = IQ#iq{type = result, sub_el = [ResultEl]},
                    ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(ResultIQ)),
                    {stop, Acc1}
            end;
        {#iq{xmlns = ?NS_EMAIL_SYNC, type = get, sub_el = SubEl} = IQ, Acc1} ->
            %% GET is not a defined operation for this namespace.
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid   = mongoose_acc:to_jid(Acc1),
            ErrorIQ = IQ#iq{type   = error,
                            sub_el = [SubEl, mongoose_xmpp_errors:not_allowed()]},
            ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(ErrorIQ)),
            {stop, Acc1};
        _ ->
            {ok, Acc}
    end.

%%%----------------------------------------------------------------------
%%% Email extraction
%%%----------------------------------------------------------------------

%% @doc Extract and normalise all non-empty `<email>' children of SubEl.
-spec extract_emails(exml:element()) -> [binary()].
extract_emails(#xmlel{children = Children}) ->
    lists:filtermap(fun extract_email/1, Children).

%% Returns `{true, NormalisedEmail}' for a non-empty `<email>' element,
%% `false' for anything else.
extract_email(#xmlel{name = <<"email">>, children = Children}) ->
    case exml_query:cdata(#xmlel{name = <<"email">>, children = Children}) of
        <<>>  -> false;
        Email -> {true, normalize_email(Email)}
    end;
extract_email(_) ->
    false.

%%%----------------------------------------------------------------------
%%% Roster integration
%%%
%%% We implement the same incremental subscription strategy as
%%% mod_contact_sync:
%%%
%%%   Step 1 – Caller syncs, finds ContactUser:
%%%     a) Already `both' subscription → skip (already fully wired).
%%%     b) Contact has Caller in their roster (any state) → make mutual.
%%%     c) Otherwise → one-way: add Contact to Caller's roster and send
%%%        a subscribe presence from Caller to Contact.
%%%
%%%   Step 2 – ContactUser later syncs and finds Caller:
%%%     Now case (b) applies in reverse, upgrading to mutual.
%%%
%%% The result is that two users who each have the other's email end up
%%% with a `both' subscription after at most two sync operations.
%%%----------------------------------------------------------------------

%% @doc Wire up roster entries for every `{Email, ContactUser}' pair
%% returned by the database lookup.
%%
%% `CallerEmail' is the email stored in the caller's C2S session info.
%% It is used as the roster nickname shown on the contact's side so
%% that each user's contact list entry reads as an email address.
-spec add_matches_to_roster(mongooseim:host_type(), jid:jid(), binary(),
                            jid:lserver(), [{binary(), binary()}]) -> ok.
add_matches_to_roster(HostType, CallerJid, CallerEmail, LServer, Matches) ->
    lists:foreach(
        fun({Email, ContactUser}) ->
            ContactJid  = jid:make_bare(ContactUser, LServer),
            %% Use the email as the roster nickname so it is human-readable.
            ContactNick = case Email of
                              <<>> -> ContactUser;
                              _    -> Email
                          end,
            CallerNick  = case CallerEmail of
                              <<>> -> CallerJid#jid.luser;
                              _    -> CallerEmail
                          end,
            sync_roster_entry(HostType, CallerJid, CallerNick,
                              ContactJid, ContactNick)
        end, Matches).

%% @doc Apply the correct subscription action for a single caller/contact pair.
-spec sync_roster_entry(mongooseim:host_type(), jid:jid(), binary(),
                        jid:jid(), binary()) -> ok.
sync_roster_entry(HostType, CallerJid, CallerNick, ContactJid, ContactNick) ->
    case has_both_subscription(HostType, CallerJid, ContactJid) of
        true ->
            %% Already mutually subscribed; nothing to do.
            ok;
        false ->
            case has_roster_entry(HostType, ContactJid, CallerJid) of
                false ->
                    %% Contact does not know Caller yet → one-way only.
                    add_one_way(CallerJid, ContactJid, ContactNick);
                true ->
                    %% Contact already has Caller → upgrade to mutual.
                    make_mutual(CallerJid, CallerNick, ContactJid, ContactNick)
            end
    end.

%% @doc Return `true' if CallerJid has ContactJid in their roster
%% under any subscription state (none/to/from/both, including pending).
-spec has_roster_entry(mongooseim:host_type(), jid:jid(), jid:jid()) -> boolean().
has_roster_entry(HostType, CallerJid, ContactJid) ->
    ContactLJID = jid:to_lower(ContactJid),
    case mod_roster:get_roster_entry(HostType, CallerJid, ContactLJID, short) of
        #roster{} -> true;
        _         -> false
    end.

%% @doc Return `true' if the subscription between CallerJid and
%% ContactJid is already `both' (mutual presence).
-spec has_both_subscription(mongooseim:host_type(), jid:jid(), jid:jid()) -> boolean().
has_both_subscription(HostType, CallerJid, ContactJid) ->
    ContactLJID = jid:to_lower(ContactJid),
    case mod_roster:get_roster_entry(HostType, CallerJid, ContactLJID, short) of
        #roster{subscription = both} -> true;
        _                            -> false
    end.

%% @doc Add ContactJid to CallerJid's roster and send a one-way
%% subscribe presence (Caller → Contact).
-spec add_one_way(jid:jid(), jid:jid(), binary()) -> ok.
add_one_way(CallerJid, ContactJid, ContactNick) ->
    case mod_roster_api:add_contact(CallerJid, ContactJid,
                                    ContactNick, [<<"Contacts">>]) of
        {ok, _} ->
            mod_roster_api:subscription(CallerJid, ContactJid, subscribe, admin_api),
            ok;
        {Error, Msg} ->
            ?LOG_WARNING(#{what    => email_sync_add_error,
                           reason  => Error,
                           msg     => iolist_to_binary(Msg),
                           caller  => jid:to_binary(CallerJid),
                           contact => jid:to_binary(ContactJid)}),
            ok
    end.

%% @doc Create a mutual (`both') subscription between CallerJid and
%% ContactJid, placing each in the other's "Contacts" group.
-spec make_mutual(jid:jid(), binary(), jid:jid(), binary()) -> ok.
make_mutual(CallerJid, CallerNick, ContactJid, ContactNick) ->
    case mod_roster_api:subscribe_both(
             {CallerJid,  ContactNick, [<<"Contacts">>]},
             {ContactJid, CallerNick,  [<<"Contacts">>]},
             admin_api) of
        {ok, _} ->
            ok;
        {Error, Msg} ->
            ?LOG_WARNING(#{what    => email_sync_subscribe_error,
                           reason  => Error,
                           msg     => iolist_to_binary(Msg),
                           caller  => jid:to_binary(CallerJid),
                           contact => jid:to_binary(ContactJid)}),
            ok
    end.

%%%----------------------------------------------------------------------
%%% XML helpers
%%%----------------------------------------------------------------------

%% @doc Build a `<contact email="..." jid="..."/>' result element.
-spec match_to_xml(binary(), binary(), jid:lserver()) -> exml:element().
match_to_xml(Email, Username, LServer) ->
    Jid = <<Username/binary, "@", LServer/binary>>,
    #xmlel{name     = <<"contact">>,
           attrs    = #{<<"email">> => Email, <<"jid">> => Jid},
           children = []}.

%%%----------------------------------------------------------------------
%%% Helpers
%%%----------------------------------------------------------------------

%% @doc Lowercase the email address for case-insensitive storage and lookup.
-spec normalize_email(binary()) -> binary().
normalize_email(Email) ->
    jid:str_tolower(Email).

%%%----------------------------------------------------------------------
%%% ETS email cache
%%%
%%% Bridges the jwt_user_email hook (fired synchronously during SASL
%%% auth, before the C2S session exists) and the user_open_session hook
%%% (fired once the session is open).  The table is public so both the
%%% auth process and the C2S process can access it without message
%%% passing.  Entries are deleted immediately after being consumed.
%%%----------------------------------------------------------------------

%% @doc Create the ETS cache table if it does not already exist.
ensure_email_cache() ->
    case ets:whereis(?EMAIL_CACHE) of
        undefined ->
            ets:new(?EMAIL_CACHE, [named_table, public, set]);
        _ ->
            ok
    end.