%%%----------------------------------------------------------------------
%%% @doc Wingtrill-specific JWT auth hooks.
%%%
%%% All Wingtrill-local behavior that would otherwise patch
%%% `ejabberd_auth_jwt' lives here so the upstream file stays close to
%%% rel-6.6. The upstream module delegates to this one for:
%%%
%%%   * Crash-safe JWT verification   — {@link verify/3}
%%%   * Atom-or-binary claim lookup   — {@link find_claim_user/2}
%%%   * Case-insensitive user compare — {@link normalize_login_user/1}
%%%                                     and {@link normalize_claim_user/2}
%%%   * Post-auth side effects        — {@link on_auth_success/4}
%%%     (phone contact hook)
%%% @end
%%%----------------------------------------------------------------------
-module(custom_ejabberd_auth_jwt).

-export([verify/3,
         find_claim_user/2,
         normalize_login_user/1,
         normalize_claim_user/2,
         on_auth_success/4]).

%% @doc Crash-safe wrapper around `jwerl:verify/3'. A malformed token
%% (e.g. the SASL PLAIN placeholder sent when the HttpOnly cookie is
%% missing) would otherwise take down the C2S process. Any exception
%% becomes a normal `{error, _}' so auth fails cleanly.
-spec verify(binary(), atom(), binary()) ->
          {ok, map()} | {error, term()}.
verify(Password, Alg, Key) ->
    try jwerl:verify(Password, Alg, Key)
    catch Class:Reason:_ -> {error, {Class, Reason}}
    end.

%% @doc Look up the username claim under either its atom key or its
%% binary equivalent. Some JWT libraries decode claims as binaries.
-spec find_claim_user(atom(), map()) -> {ok, binary()} | error.
find_claim_user(UserKey, TokenData) ->
    case maps:find(UserKey, TokenData) of
        {ok, _} = Found -> Found;
        error -> maps:find(atom_to_binary(UserKey, utf8), TokenData)
    end.

%% @doc Normalize the XMPP login username. XMPP nodeprep already
%% lowercases, but we re-apply defensively so the comparison in
%% {@link ejabberd_auth_jwt:check_password/4} is consistent with
%% {@link normalize_claim_user/2}.
-spec normalize_login_user(jid:luser()) -> binary().
normalize_login_user(LUser) ->
    jid:str_tolower(LUser).

%% @doc Normalize the `sub' claim for case-insensitive comparison.
%% Firebase UIDs can contain mixed case; XMPP node-preps the JID node
%% part to lowercase, so a direct compare fails. We also strip an
%% optional `@server' suffix so either `uid' or `uid@server' in the
%% claim works.
-spec normalize_claim_user(binary(), jid:lserver()) -> binary().
normalize_claim_user(ClaimUser, LServer) ->
    ClaimUserNorm = jid:str_tolower(ClaimUser),
    LServerNorm = jid:str_tolower(LServer),
    case binary:split(ClaimUserNorm, <<"@">>, [global]) of
        [Local, LServerNorm] -> Local;
        [Local, _AnyDomain] -> Local;
        _ -> ClaimUserNorm
    end.

%% @doc Post-auth side effects. Fires the `jwt_user_phone' hook when
%% the token carries a non-empty `phone_number' claim.
-spec on_auth_success(mongooseim:host_type(), jid:lserver(), jid:luser(), map()) -> ok.
on_auth_success(HostType, LServer, LUser, TokenData) ->
    maybe_store_phone(HostType, LServer, LUser, TokenData),
    maybe_store_email(HostType, LServer, LUser, TokenData).

-spec maybe_store_phone(mongooseim:host_type(), jid:lserver(), jid:luser(), map()) -> ok.
maybe_store_phone(HostType, LServer, LUser, TokenData) ->
    case TokenData of
        #{phone_number := Phone} when is_binary(Phone), Phone =/= <<>> ->
            mongoose_hooks:jwt_user_phone(HostType, LServer, LUser, Phone);
        _ ->
            ok
    end.

-spec maybe_store_email(mongooseim:host_type(), jid:lserver(), jid:luser(), map()) -> ok.
maybe_store_email(HostType, LServer, LUser, TokenData) ->
    case TokenData of
        #{email := Email} when is_binary(Email), Email =/= <<>> ->
            mongoose_hooks:jwt_user_email(HostType, LServer, LUser, Email);
        _ ->
            ok
    end.