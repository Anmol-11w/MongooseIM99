%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc
%%% Proxy interface module between mod_broadcast and backend
%%% implementations (mod_broadcast_rdbms, etc.).
%%% @end
%%%----------------------------------------------------------------------
-module(mod_broadcast_backend).

-export([init/2,
         create_list/4,
         delete_list/3,
         rename_list/4,
         list_lists/3,
         get_members/3,
         set_members/3,
         get_list_owner/2]).

-define(MAIN_MODULE, mod_broadcast).

-type list_id() :: integer().

-callback init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.

-callback create_list(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    {ok, list_id()} | {error, term()}.

-callback delete_list(mongooseim:host_type(), jid:lserver(), list_id()) ->
    ok | {error, term()}.

-callback rename_list(mongooseim:host_type(), jid:lserver(), list_id(), binary()) ->
    ok | {error, term()}.

-callback list_lists(mongooseim:host_type(), jid:lserver(), jid:luser()) ->
    [{list_id(), binary()}].

-callback get_members(mongooseim:host_type(), jid:lserver(), list_id()) ->
    [binary()].

-callback set_members(mongooseim:host_type(), list_id(), [binary()]) ->
    ok | {error, term()}.

-callback get_list_owner(mongooseim:host_type(), list_id()) ->
    {ok, {jid:lserver(), jid:luser()}} | not_found.

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, Opts) ->
    TrackedFuns = [create_list, delete_list, rename_list,
                   list_lists, get_members, set_members, get_list_owner],
    mongoose_backend:init(HostType, ?MAIN_MODULE, TrackedFuns, Opts),
    Args = [HostType, Opts],
    mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec create_list(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    {ok, list_id()} | {error, term()}.
create_list(HostType, LServer, LUser, Name) ->
    Args = [HostType, LServer, LUser, Name],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec delete_list(mongooseim:host_type(), jid:lserver(), list_id()) ->
    ok | {error, term()}.
delete_list(HostType, LServer, ListId) ->
    Args = [HostType, LServer, ListId],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec rename_list(mongooseim:host_type(), jid:lserver(), list_id(), binary()) ->
    ok | {error, term()}.
rename_list(HostType, LServer, ListId, Name) ->
    Args = [HostType, LServer, ListId, Name],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec list_lists(mongooseim:host_type(), jid:lserver(), jid:luser()) ->
    [{list_id(), binary()}].
list_lists(HostType, LServer, LUser) ->
    Args = [HostType, LServer, LUser],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec get_members(mongooseim:host_type(), jid:lserver(), list_id()) -> [binary()].
get_members(HostType, LServer, ListId) ->
    Args = [HostType, LServer, ListId],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec set_members(mongooseim:host_type(), list_id(), [binary()]) ->
    ok | {error, term()}.
set_members(HostType, ListId, Members) ->
    Args = [HostType, ListId, Members],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec get_list_owner(mongooseim:host_type(), list_id()) ->
    {ok, {jid:lserver(), jid:luser()}} | not_found.
get_list_owner(HostType, ListId) ->
    Args = [HostType, ListId],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).