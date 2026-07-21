%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_email_sync_backend.erl
%%% Purpose : Backend proxy for mod_email_sync.
%%%
%%% Provides a thin dispatch layer between the main module and the
%%% concrete storage implementation (currently only `rdbms').
%%%
%%% Callers always go through this module; they never reference a
%%% backend module directly.  The active backend is resolved at runtime
%%% via `mongoose_backend', which also instruments calls for metrics.
%%%
%%% == Adding a new backend ==
%%%
%%% 1. Create `mod_email_sync_<name>.erl' and declare
%%%    `-behaviour(mod_email_sync_backend)'.
%%% 2. Implement all three callbacks: `init/2', `store_email/4',
%%%    `lookup_emails/3'.
%%% 3. Set `backend = "<name>"' in mongooseim.toml.
%%%
%%% @end
%%%----------------------------------------------------------------------
-module(mod_email_sync_backend).

-export([init/2, store_email/4, lookup_emails/3]).

-define(MAIN_MODULE, mod_email_sync).

%%%----------------------------------------------------------------------
%%% Behaviour callbacks (implemented by each backend)
%%%----------------------------------------------------------------------

-callback init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.

-callback store_email(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    ok | {error, term()}.

-callback lookup_emails(mongooseim:host_type(), jid:lserver(), [binary()]) ->
    [{Email :: binary(), Username :: binary()}].

%%%----------------------------------------------------------------------
%%% Proxy functions
%%%----------------------------------------------------------------------

%% @doc Initialise the configured backend.
-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, Opts) ->
    TrackedFuns = [store_email, lookup_emails],
    mongoose_backend:init(HostType, ?MAIN_MODULE, TrackedFuns, Opts),
    Args = [HostType, Opts],
    mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

%% @doc Persist `Email' for `LUser' on `LServer'.
%%
%% Delegates to the active backend and tracks the call for metrics.
-spec store_email(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    ok | {error, term()}.
store_email(HostType, LServer, LUser, Email) ->
    Args = [HostType, LServer, LUser, Email],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

%% @doc Look up users whose registered email is in `Emails'.
%%
%% Returns a list of `{Email, Username}' tuples for every hit.
%% Unmatched emails are not included in the result.
-spec lookup_emails(mongooseim:host_type(), jid:lserver(), [binary()]) ->
    [{Email :: binary(), Username :: binary()}].
lookup_emails(HostType, LServer, Emails) ->
    Args = [HostType, LServer, Emails],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).