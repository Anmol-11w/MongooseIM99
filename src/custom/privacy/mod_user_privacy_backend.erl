%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc
%%% Proxy interface module between mod_user_privacy and backend
%%% implementations (mod_user_privacy_rdbms, etc.).
%%% @end
%%%----------------------------------------------------------------------
-module(mod_user_privacy_backend).

-export([init/2,
         get_privacy/4,
         set_privacy/5]).

-define(MAIN_MODULE, mod_user_privacy).

-callback init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.

-callback get_privacy(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    {ok, binary()} | not_found.

-callback set_privacy(mongooseim:host_type(), jid:lserver(), jid:luser(),
                      binary(), binary()) -> ok | {error, term()}.

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, Opts) ->
    TrackedFuns = [get_privacy, set_privacy],
    mongoose_backend:init(HostType, ?MAIN_MODULE, TrackedFuns, Opts),
    Args = [HostType, Opts],
    mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec get_privacy(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    {ok, binary()} | not_found.
get_privacy(HostType, LServer, LUser, Field) ->
    Args = [HostType, LServer, LUser, Field],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec set_privacy(mongooseim:host_type(), jid:lserver(), jid:luser(),
                  binary(), binary()) -> ok | {error, term()}.
set_privacy(HostType, LServer, LUser, Field, Value) ->
    Args = [HostType, LServer, LUser, Field, Value],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).