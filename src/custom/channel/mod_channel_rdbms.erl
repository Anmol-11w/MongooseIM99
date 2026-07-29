%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc
%%% RDBMS backend for mod_channel.
%%%
%%% Tables:
%%%   channels             - one row per channel
%%%   channel_admins       - owner + extra admins (cascade delete)
%%%   channel_subscribers  - subscriber roster (cascade delete)
%%%   channel_messages     - append-only message log (cascade delete)
%%% @end
%%%----------------------------------------------------------------------
-module(mod_channel_rdbms).

-behaviour(mod_channel_backend).

-include("mongoose.hrl").

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

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, _Opts) ->
    prepare_queries(HostType),
    ok.

-spec create_channel(mongooseim:host_type(), jid:lserver(), binary(),
                     binary(), binary(), binary(), binary()) ->
    {ok, integer()} | {error, term()}.
create_channel(HostType, Server, Owner, Handle, Name, Desc, Type) ->
    Now = erlang:system_time(second),
    F = fun() ->
            case insert_channel(HostType, Server, Owner, Handle, Name, Desc, Type, Now) of
                {ok, ChId} ->
                    mongoose_rdbms:execute_successfully(
                      HostType, channel_admin_insert,
                      [ChId, Owner, <<"owner">>, Now]),
                    {ok, ChId};
                {error, _} = E ->
                    E
            end
        end,
    case mongoose_rdbms:sql_transaction(HostType, F) of
        {atomic, {ok, ChId}}      -> {ok, ChId};
        {atomic, {error, R}}      -> {error, R};
        {aborted, _}              -> {error, handle_taken};
        Other                     -> {error, Other}
    end.

insert_channel(HostType, Server, Owner, Handle, Name, Desc, Type, Now) ->
    case mongoose_rdbms:execute(HostType, channel_insert,
                                [Server, Owner, Handle, Name, Desc, Type, Now]) of
        {updated, _, [{Id}]} -> {ok, to_integer(Id)};
        {selected, [{Id}]}   -> {ok, to_integer(Id)};
        Other                -> {error, Other}
    end.

-spec get_channel(mongooseim:host_type(), integer()) ->
    {ok, map()} | not_found.
get_channel(HostType, ChId) ->
    case mongoose_rdbms:execute_successfully(HostType, channel_select_one,
                                             [ChId]) of
        {selected, []} -> not_found;
        {selected, [Row]} -> {ok, channel_row_to_map(Row)}
    end.

-spec get_channel_by_handle(mongooseim:host_type(), jid:lserver(), binary()) ->
    {ok, map()} | not_found.
get_channel_by_handle(HostType, Server, Handle) ->
    case mongoose_rdbms:execute_successfully(HostType, channel_select_handle,
                                             [Server, Handle]) of
        {selected, []} -> not_found;
        {selected, [Row]} -> {ok, channel_row_to_map_by_handle(Row, Server, Handle)}
    end.

-spec update_channel(mongooseim:host_type(), integer(),
                     [{atom(), binary()}]) -> ok.
update_channel(_HostType, _ChId, []) ->
    ok;
update_channel(HostType, ChId, Updates) ->
    lists:foreach(fun({Field, Value}) -> apply_update(HostType, ChId, Field, Value) end,
                  Updates),
    ok.

apply_update(HostType, ChId, name, V) ->
    mongoose_rdbms:execute_successfully(HostType, channel_update_name, [V, ChId]);
apply_update(HostType, ChId, description, V) ->
    mongoose_rdbms:execute_successfully(HostType, channel_update_desc, [V, ChId]);
apply_update(HostType, ChId, channel_type, V) ->
    mongoose_rdbms:execute_successfully(HostType, channel_update_type, [V, ChId]).

-spec delete_channel(mongooseim:host_type(), integer()) -> ok.
delete_channel(HostType, ChId) ->
    mongoose_rdbms:execute_successfully(HostType, channel_delete, [ChId]),
    ok.

-spec add_admin(mongooseim:host_type(), integer(), binary(), binary(), integer()) ->
    ok | {error, term()}.
add_admin(HostType, ChId, Jid, Role, AddedAt) ->
    case mongoose_rdbms:execute(HostType, channel_admin_insert,
                                [ChId, Jid, Role, AddedAt]) of
        {updated, _} -> ok;
        Other -> {error, Other}
    end.

-spec remove_admin(mongooseim:host_type(), integer(), binary()) -> ok.
remove_admin(HostType, ChId, Jid) ->
    mongoose_rdbms:execute_successfully(HostType, channel_admin_delete, [ChId, Jid]),
    ok.

-spec list_admins(mongooseim:host_type(), integer()) -> [{binary(), binary()}].
list_admins(HostType, ChId) ->
    {selected, Rows} = mongoose_rdbms:execute_successfully(
                         HostType, channel_admins_select, [ChId]),
    [{Jid, Role} || {Jid, Role} <- Rows].

-spec is_admin(mongooseim:host_type(), integer(), binary()) -> boolean().
is_admin(HostType, ChId, Jid) ->
    case mongoose_rdbms:execute_successfully(HostType, channel_admin_check,
                                             [ChId, Jid]) of
        {selected, []} -> false;
        {selected, _} -> true
    end.

-spec subscribe(mongooseim:host_type(), integer(), binary()) ->
    ok | {error, already_subscribed}.
subscribe(HostType, ChId, Jid) ->
    Now = erlang:system_time(second),
    case mongoose_rdbms:execute(HostType, channel_subscriber_insert,
                                [ChId, Jid, Now]) of
        {updated, _} -> ok;
        _ -> {error, already_subscribed}
    end.

-spec unsubscribe(mongooseim:host_type(), integer(), binary()) -> ok.
unsubscribe(HostType, ChId, Jid) ->
    mongoose_rdbms:execute_successfully(HostType, channel_subscriber_delete,
                                        [ChId, Jid]),
    ok.

-spec is_subscriber(mongooseim:host_type(), integer(), binary()) -> boolean().
is_subscriber(HostType, ChId, Jid) ->
    case mongoose_rdbms:execute_successfully(HostType, channel_subscriber_check,
                                             [ChId, Jid]) of
        {selected, []} -> false;
        {selected, _} -> true
    end.

-spec list_subscribers(mongooseim:host_type(), integer(),
                       non_neg_integer(), pos_integer()) -> [binary()].
list_subscribers(HostType, ChId, Offset, Limit) ->
    {selected, Rows} = mongoose_rdbms:execute_successfully(
                         HostType, channel_subscribers_select,
                         [ChId, Limit, Offset]),
    [Jid || {Jid} <- Rows].

-spec count_subscribers(mongooseim:host_type(), integer()) -> non_neg_integer().
count_subscribers(HostType, ChId) ->
    case mongoose_rdbms:execute_successfully(HostType, channel_subscribers_count,
                                             [ChId]) of
        {selected, [{N}]} -> to_integer(N);
        {selected, []} -> 0
    end.

-spec list_subscribed_channels(mongooseim:host_type(), jid:lserver(), binary()) ->
    [map()].
list_subscribed_channels(HostType, Server, Jid) ->
    {selected, Rows} = mongoose_rdbms:execute_successfully(
                         HostType, channel_subscribed_select, [Server, Jid]),
    [channel_row_to_map(R) || R <- Rows].

-spec list_admin_channels(mongooseim:host_type(), jid:lserver(), binary()) ->
    [map()].
list_admin_channels(HostType, Server, Jid) ->
    {selected, Rows} = mongoose_rdbms:execute_successfully(
                         HostType, channel_admin_channels_select, [Server, Jid]),
    [channel_row_to_map(R) || R <- Rows].

-spec store_message(mongooseim:host_type(), integer(), binary(), binary()) ->
    {ok, integer()}.
store_message(HostType, ChId, Sender, Body) ->
    Now = erlang:system_time(second),
    case mongoose_rdbms:execute(HostType, channel_message_insert,
                                [ChId, Sender, Body, Now]) of
        {updated, _, [{Id}]} -> {ok, to_integer(Id)};
        {selected, [{Id}]}   -> {ok, to_integer(Id)}
    end.

-spec fetch_history(mongooseim:host_type(), integer(),
                    non_neg_integer(), pos_integer()) -> [map()].
fetch_history(HostType, ChId, Before, Limit) ->
    BeforeArg = case Before of
                    0 -> 9223372036854775807;
                    N -> N
                end,
    {selected, Rows} = mongoose_rdbms:execute_successfully(
                         HostType, channel_messages_select,
                         [ChId, BeforeArg, Limit]),
    [#{id => to_integer(Id),
       sender => Sender,
       body => Body,
       sent_at => to_integer(Sent)}
     || {Id, Sender, Body, Sent} <- Rows].

-spec search_channels(mongooseim:host_type(), jid:lserver(),
                      binary(), pos_integer()) -> [map()].
search_channels(HostType, Server, Query, Limit) ->
    Pattern = <<"%", Query/binary, "%">>,
    {selected, Rows} = mongoose_rdbms:execute_successfully(
                         HostType, channel_search,
                         [Server, Pattern, Pattern, Limit]),
    [channel_row_to_map(R) || R <- Rows].

%%%----------------------------------------------------------------------
%%% Row helpers
%%%----------------------------------------------------------------------

channel_row_to_map({Id, Server, Owner, Handle, Name, Desc, Type, CreatedAt}) ->
    #{id => to_integer(Id),
      server => Server,
      owner => Owner,
      handle => Handle,
      name => Name,
      description => Desc,
      channel_type => Type,
      created_at => to_integer(CreatedAt)}.

%% select_handle returns the same shape as select_one — kept separate
%% for clarity in case it diverges later.
channel_row_to_map_by_handle(Row, _Server, _Handle) ->
    channel_row_to_map(Row).

to_integer(N) when is_integer(N) -> N;
to_integer(B) when is_binary(B) -> binary_to_integer(B).

%%%----------------------------------------------------------------------
%%% Prepared queries
%%%----------------------------------------------------------------------

-spec prepare_queries(mongooseim:host_type()) -> ok.
prepare_queries(_HostType) ->
    %% channels
    mongoose_rdbms:prepare(channel_insert, channels,
                           [server, owner, handle, name, description,
                            channel_type, created_at],
                           <<"INSERT INTO channels "
                             "(server, owner, handle, name, description, "
                             " channel_type, created_at) "
                             "VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id">>),
    mongoose_rdbms:prepare(channel_select_one, channels,
                           [id],
                           <<"SELECT id, server, owner, handle, name, "
                             "description, channel_type, created_at "
                             "FROM channels WHERE id = ?">>),
    mongoose_rdbms:prepare(channel_select_handle, channels,
                           [server, handle],
                           <<"SELECT id, server, owner, handle, name, "
                             "description, channel_type, created_at "
                             "FROM channels WHERE server = ? AND handle = ?">>),
    mongoose_rdbms:prepare(channel_update_name, channels,
                           [name, id],
                           <<"UPDATE channels SET name = ? WHERE id = ?">>),
    mongoose_rdbms:prepare(channel_update_desc, channels,
                           [description, id],
                           <<"UPDATE channels SET description = ? WHERE id = ?">>),
    mongoose_rdbms:prepare(channel_update_type, channels,
                           [channel_type, id],
                           <<"UPDATE channels SET channel_type = ? WHERE id = ?">>),
    mongoose_rdbms:prepare(channel_delete, channels,
                           [id],
                           <<"DELETE FROM channels WHERE id = ?">>),
    mongoose_rdbms:prepare(channel_search, channels,
                           [server, handle, name, limit],
                           <<"SELECT id, server, owner, handle, name, "
                             "description, channel_type, created_at "
                             "FROM channels "
                             "WHERE server = ? AND channel_type = 'public' "
                             "  AND (handle LIKE ? OR name LIKE ?) "
                             "ORDER BY created_at DESC LIMIT ?">>),

    %% admins
    mongoose_rdbms:prepare(channel_admin_insert, channel_admins,
                           [channel_id, admin_jid, role, added_at],
                           <<"INSERT INTO channel_admins "
                             "(channel_id, admin_jid, role, added_at) "
                             "VALUES (?, ?, ?, ?)">>),
    mongoose_rdbms:prepare(channel_admin_delete, channel_admins,
                           [channel_id, admin_jid],
                           <<"DELETE FROM channel_admins "
                             "WHERE channel_id = ? AND admin_jid = ? "
                             "  AND role <> 'owner'">>),
    mongoose_rdbms:prepare(channel_admins_select, channel_admins,
                           [channel_id],
                           <<"SELECT admin_jid, role FROM channel_admins "
                             "WHERE channel_id = ? ORDER BY added_at">>),
    mongoose_rdbms:prepare(channel_admin_check, channel_admins,
                           [channel_id, admin_jid],
                           <<"SELECT 1 FROM channel_admins "
                             "WHERE channel_id = ? AND admin_jid = ?">>),
    mongoose_rdbms:prepare(channel_admin_channels_select, channels,
                           [server, admin_jid],
                           <<"SELECT c.id, c.server, c.owner, c.handle, c.name, "
                             "c.description, c.channel_type, c.created_at "
                             "FROM channels c "
                             "JOIN channel_admins a ON a.channel_id = c.id "
                             "WHERE c.server = ? AND a.admin_jid = ? "
                             "ORDER BY c.created_at DESC">>),

    %% subscribers
    mongoose_rdbms:prepare(channel_subscriber_insert, channel_subscribers,
                           [channel_id, subscriber_jid, joined_at],
                           <<"INSERT INTO channel_subscribers "
                             "(channel_id, subscriber_jid, joined_at) "
                             "VALUES (?, ?, ?)">>),
    mongoose_rdbms:prepare(channel_subscriber_delete, channel_subscribers,
                           [channel_id, subscriber_jid],
                           <<"DELETE FROM channel_subscribers "
                             "WHERE channel_id = ? AND subscriber_jid = ?">>),
    mongoose_rdbms:prepare(channel_subscriber_check, channel_subscribers,
                           [channel_id, subscriber_jid],
                           <<"SELECT 1 FROM channel_subscribers "
                             "WHERE channel_id = ? AND subscriber_jid = ?">>),
    mongoose_rdbms:prepare(channel_subscribers_select, channel_subscribers,
                           [channel_id, limit, offset],
                           <<"SELECT subscriber_jid FROM channel_subscribers "
                             "WHERE channel_id = ? "
                             "ORDER BY joined_at LIMIT ? OFFSET ?">>),
    mongoose_rdbms:prepare(channel_subscribers_count, channel_subscribers,
                           [channel_id],
                           <<"SELECT COUNT(*) FROM channel_subscribers "
                             "WHERE channel_id = ?">>),
    mongoose_rdbms:prepare(channel_subscribed_select, channels,
                           [server, subscriber_jid],
                           <<"SELECT c.id, c.server, c.owner, c.handle, c.name, "
                             "c.description, c.channel_type, c.created_at "
                             "FROM channels c "
                             "JOIN channel_subscribers s ON s.channel_id = c.id "
                             "WHERE c.server = ? AND s.subscriber_jid = ? "
                             "ORDER BY s.joined_at DESC">>),

    %% messages
    mongoose_rdbms:prepare(channel_message_insert, channel_messages,
                           [channel_id, sender_jid, body, sent_at],
                           <<"INSERT INTO channel_messages "
                             "(channel_id, sender_jid, body, sent_at) "
                             "VALUES (?, ?, ?, ?) RETURNING id">>),
    mongoose_rdbms:prepare(channel_messages_select, channel_messages,
                           [channel_id, before_id, limit],
                           <<"SELECT id, sender_jid, body, sent_at "
                             "FROM channel_messages "
                             "WHERE channel_id = ? AND id < ? "
                             "ORDER BY id DESC LIMIT ?">>),
    ok.