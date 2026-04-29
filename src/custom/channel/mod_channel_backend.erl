%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc
%%% Proxy interface module between mod_channel and the storage
%%% backend (mod_channel_rdbms, etc.).
%%% @end
%%%----------------------------------------------------------------------
-module(mod_channel_backend).

-export([init/2,
         create_channel/7,
         get_channel/2,
         get_channel_by_handle/3,
         update_channel/3,
         delete_channel/2,
         add_admin/5,
         remove_admin/3,
         list_admins/2,
         is_admin/3,
         subscribe/3,
         unsubscribe/3,
         is_subscriber/3,
         list_subscribers/4,
         count_subscribers/2,
         list_subscribed_channels/3,
         list_admin_channels/3,
         store_message/4,
         fetch_history/4,
         search_channels/4]).

-define(MAIN_MODULE, mod_channel).

-type channel_id() :: integer().
-type channel_map() :: #{id := channel_id(),
                         server := jid:lserver(),
                         owner := binary(),
                         handle := binary(),
                         name := binary(),
                         description := binary(),
                         channel_type := binary(),
                         created_at := integer()}.
-type message_map() :: #{id := integer(),
                         sender := binary(),
                         body := binary(),
                         sent_at := integer()}.

-callback init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.

-callback create_channel(mongooseim:host_type(), jid:lserver(), binary(),
                         binary(), binary(), binary(), binary()) ->
    {ok, channel_id()} | {error, handle_taken | term()}.

-callback get_channel(mongooseim:host_type(), channel_id()) ->
    {ok, channel_map()} | not_found.

-callback get_channel_by_handle(mongooseim:host_type(), jid:lserver(), binary()) ->
    {ok, channel_map()} | not_found.

-callback update_channel(mongooseim:host_type(), channel_id(),
                         [{atom(), binary()}]) ->
    ok | {error, term()}.

-callback delete_channel(mongooseim:host_type(), channel_id()) ->
    ok | {error, term()}.

-callback add_admin(mongooseim:host_type(), channel_id(), binary(),
                    binary(), integer()) ->
    ok | {error, term()}.

-callback remove_admin(mongooseim:host_type(), channel_id(), binary()) ->
    ok | {error, term()}.

-callback list_admins(mongooseim:host_type(), channel_id()) ->
    [{binary(), binary()}].

-callback is_admin(mongooseim:host_type(), channel_id(), binary()) ->
    boolean().

-callback subscribe(mongooseim:host_type(), channel_id(), binary()) ->
    ok | {error, already_subscribed | term()}.

-callback unsubscribe(mongooseim:host_type(), channel_id(), binary()) ->
    ok | {error, term()}.

-callback is_subscriber(mongooseim:host_type(), channel_id(), binary()) ->
    boolean().

-callback list_subscribers(mongooseim:host_type(), channel_id(),
                           non_neg_integer(), pos_integer()) ->
    [binary()].

-callback count_subscribers(mongooseim:host_type(), channel_id()) ->
    non_neg_integer().

-callback list_subscribed_channels(mongooseim:host_type(), jid:lserver(), binary()) ->
    [channel_map()].

-callback list_admin_channels(mongooseim:host_type(), jid:lserver(), binary()) ->
    [channel_map()].

-callback store_message(mongooseim:host_type(), channel_id(), binary(), binary()) ->
    {ok, integer()}.

-callback fetch_history(mongooseim:host_type(), channel_id(),
                        non_neg_integer(), pos_integer()) ->
    [message_map()].

-callback search_channels(mongooseim:host_type(), jid:lserver(),
                          binary(), pos_integer()) ->
    [channel_map()].

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, Opts) ->
    TrackedFuns = [create_channel, get_channel, get_channel_by_handle,
                   update_channel, delete_channel,
                   add_admin, remove_admin, list_admins, is_admin,
                   subscribe, unsubscribe, is_subscriber,
                   list_subscribers, count_subscribers,
                   list_subscribed_channels, list_admin_channels,
                   store_message, fetch_history, search_channels],
    mongoose_backend:init(HostType, ?MAIN_MODULE, TrackedFuns, Opts),
    Args = [HostType, Opts],
    mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec create_channel(mongooseim:host_type(), jid:lserver(), binary(),
                     binary(), binary(), binary(), binary()) ->
    {ok, channel_id()} | {error, term()}.
create_channel(HostType, Server, Owner, Handle, Name, Desc, Type) ->
    Args = [HostType, Server, Owner, Handle, Name, Desc, Type],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec get_channel(mongooseim:host_type(), channel_id()) ->
    {ok, channel_map()} | not_found.
get_channel(HostType, ChId) ->
    Args = [HostType, ChId],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec get_channel_by_handle(mongooseim:host_type(), jid:lserver(), binary()) ->
    {ok, channel_map()} | not_found.
get_channel_by_handle(HostType, Server, Handle) ->
    Args = [HostType, Server, Handle],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec update_channel(mongooseim:host_type(), channel_id(),
                     [{atom(), binary()}]) -> ok | {error, term()}.
update_channel(HostType, ChId, Updates) ->
    Args = [HostType, ChId, Updates],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec delete_channel(mongooseim:host_type(), channel_id()) -> ok | {error, term()}.
delete_channel(HostType, ChId) ->
    Args = [HostType, ChId],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec add_admin(mongooseim:host_type(), channel_id(), binary(),
                binary(), integer()) -> ok | {error, term()}.
add_admin(HostType, ChId, Jid, Role, AddedAt) ->
    Args = [HostType, ChId, Jid, Role, AddedAt],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec remove_admin(mongooseim:host_type(), channel_id(), binary()) ->
    ok | {error, term()}.
remove_admin(HostType, ChId, Jid) ->
    Args = [HostType, ChId, Jid],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec list_admins(mongooseim:host_type(), channel_id()) -> [{binary(), binary()}].
list_admins(HostType, ChId) ->
    Args = [HostType, ChId],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec is_admin(mongooseim:host_type(), channel_id(), binary()) -> boolean().
is_admin(HostType, ChId, Jid) ->
    Args = [HostType, ChId, Jid],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec subscribe(mongooseim:host_type(), channel_id(), binary()) ->
    ok | {error, already_subscribed | term()}.
subscribe(HostType, ChId, Jid) ->
    Args = [HostType, ChId, Jid],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec unsubscribe(mongooseim:host_type(), channel_id(), binary()) ->
    ok | {error, term()}.
unsubscribe(HostType, ChId, Jid) ->
    Args = [HostType, ChId, Jid],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec is_subscriber(mongooseim:host_type(), channel_id(), binary()) -> boolean().
is_subscriber(HostType, ChId, Jid) ->
    Args = [HostType, ChId, Jid],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec list_subscribers(mongooseim:host_type(), channel_id(),
                       non_neg_integer(), pos_integer()) -> [binary()].
list_subscribers(HostType, ChId, Offset, Limit) ->
    Args = [HostType, ChId, Offset, Limit],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec count_subscribers(mongooseim:host_type(), channel_id()) -> non_neg_integer().
count_subscribers(HostType, ChId) ->
    Args = [HostType, ChId],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec list_subscribed_channels(mongooseim:host_type(), jid:lserver(), binary()) ->
    [channel_map()].
list_subscribed_channels(HostType, Server, Jid) ->
    Args = [HostType, Server, Jid],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec list_admin_channels(mongooseim:host_type(), jid:lserver(), binary()) ->
    [channel_map()].
list_admin_channels(HostType, Server, Jid) ->
    Args = [HostType, Server, Jid],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec store_message(mongooseim:host_type(), channel_id(), binary(), binary()) ->
    {ok, integer()}.
store_message(HostType, ChId, Sender, Body) ->
    Args = [HostType, ChId, Sender, Body],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec fetch_history(mongooseim:host_type(), channel_id(),
                    non_neg_integer(), pos_integer()) -> [message_map()].
fetch_history(HostType, ChId, Before, Limit) ->
    Args = [HostType, ChId, Before, Limit],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).

-spec search_channels(mongooseim:host_type(), jid:lserver(),
                      binary(), pos_integer()) -> [channel_map()].
search_channels(HostType, Server, Query, Limit) ->
    Args = [HostType, Server, Query, Limit],
    mongoose_backend:call_tracked(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args).