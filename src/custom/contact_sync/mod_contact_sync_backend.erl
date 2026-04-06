%% Proxy interface module between mod_contact_sync and backend
%% implementations (mod_contact_sync_rdbms, etc.).
-module(mod_contact_sync_backend).

-export([init/2,
         store_phone/4,
         lookup_phones/3,
         get_user_phone/3,
         remove_user/3]).

-define(MAIN_MODULE, mod_contact_sync).

-callback init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.

-callback store_phone(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    ok | {error, term()}.

-callback lookup_phones(mongooseim:host_type(), jid:lserver(), [binary()]) ->
    [{Phone :: binary(), Username :: binary()}].

-callback get_user_phone(mongooseim:host_type(), jid:lserver(), jid:luser()) ->
    binary().

-callback remove_user(mongooseim:host_type(), jid:luser(), jid:lserver()) ->
    ok | {error, term()}.

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, Opts) ->
    TrackedFuns = [store_phone, lookup_phones],
    mongoose_backend:init(HostType, ?MAIN_MODULE, TrackedFuns, Opts),
    Args = [HostType, Opts],
    mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec store_phone(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    ok | {error, term()}.
store_phone(HostType, LServer, LUser, Phone) ->
    Args = [HostType, LServer, LUser, Phone],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec lookup_phones(mongooseim:host_type(), jid:lserver(), [binary()]) ->
    [{Phone :: binary(), Username :: binary()}].
lookup_phones(HostType, LServer, Phones) ->
    Args = [HostType, LServer, Phones],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec get_user_phone(mongooseim:host_type(), jid:lserver(), jid:luser()) ->
    binary().
get_user_phone(HostType, LServer, LUser) ->
    Args = [HostType, LServer, LUser],
    mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec remove_user(mongooseim:host_type(), jid:luser(), jid:lserver()) ->
    ok | {error, term()}.
remove_user(HostType, LUser, LServer) ->
    Args = [HostType, LUser, LServer],
    mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).