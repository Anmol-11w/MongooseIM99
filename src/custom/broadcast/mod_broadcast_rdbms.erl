%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc
%%% RDBMS backend for mod_broadcast.
%%%
%%% Two tables:
%%%   broadcast_lists         — owner + name + created_at
%%%   broadcast_list_members  — bare JID per list (cascade delete)
%%% @end
%%%----------------------------------------------------------------------
-module(mod_broadcast_rdbms).

-behaviour(mod_broadcast_backend).

-include("mongoose.hrl").

-export([init/2,
         create_list/4,
         delete_list/3,
         rename_list/4,
         list_lists/3,
         get_members/3,
         set_members/3,
         get_list_owner/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, _Opts) ->
    prepare_queries(HostType),
    ok.

-spec create_list(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    {ok, integer()} | {error, term()}.
create_list(HostType, LServer, LUser, Name) ->
    Now = erlang:system_time(second),
    %% Postgres returns `{updated, N, Rows}' for `INSERT ... RETURNING'.
    %% mongoose_rdbms:execute_successfully/3 only handles 2-tuples and would
    %% raise on the 3-tuple shape, so we use execute/3 directly.
    case mongoose_rdbms:execute(HostType, broadcast_list_insert,
                                [LServer, LUser, Name, Now]) of
        {updated, _, [{Id}]} -> {ok, to_integer(Id)};
        {selected, [{Id}]}   -> {ok, to_integer(Id)};
        Other                -> {error, Other}
    end.

-spec delete_list(mongooseim:host_type(), jid:lserver(), integer()) ->
    ok | {error, term()}.
delete_list(HostType, LServer, ListId) ->
    case mongoose_rdbms:execute_successfully(HostType, broadcast_list_delete,
                                             [ListId, LServer]) of
        {updated, _} -> ok;
        Other -> {error, Other}
    end.

-spec rename_list(mongooseim:host_type(), jid:lserver(), integer(), binary()) ->
    ok | {error, term()}.
rename_list(HostType, LServer, ListId, Name) ->
    case mongoose_rdbms:execute_successfully(HostType, broadcast_list_rename,
                                             [Name, ListId, LServer]) of
        {updated, _} -> ok;
        Other -> {error, Other}
    end.

-spec list_lists(mongooseim:host_type(), jid:lserver(), jid:luser()) ->
    [{integer(), binary()}].
list_lists(HostType, LServer, LUser) ->
    case mongoose_rdbms:execute_successfully(HostType, broadcast_list_select_owner,
                                             [LServer, LUser]) of
        {selected, Rows} ->
            [{to_integer(Id), Name} || {Id, Name} <- Rows]
    end.

-spec get_members(mongooseim:host_type(), jid:lserver(), integer()) -> [binary()].
get_members(HostType, _LServer, ListId) ->
    case mongoose_rdbms:execute_successfully(HostType, broadcast_members_select,
                                             [ListId]) of
        {selected, Rows} ->
            [Jid || {Jid} <- Rows]
    end.

-spec set_members(mongooseim:host_type(), integer(), [binary()]) ->
    ok | {error, term()}.
set_members(HostType, ListId, Members) ->
    F = fun() ->
            mongoose_rdbms:execute_successfully(HostType, broadcast_members_clear,
                                                [ListId]),
            lists:foreach(
              fun(Jid) ->
                  mongoose_rdbms:execute_successfully(HostType,
                                                      broadcast_members_insert,
                                                      [ListId, Jid])
              end, lists:usort(Members)),
            ok
        end,
    case mongoose_rdbms:sql_transaction(HostType, F) of
        {atomic, ok} -> ok;
        Other -> {error, Other}
    end.

-spec get_list_owner(mongooseim:host_type(), integer()) ->
    {ok, {jid:lserver(), jid:luser()}} | not_found.
get_list_owner(HostType, ListId) ->
    case mongoose_rdbms:execute_successfully(HostType, broadcast_list_select_one,
                                             [ListId]) of
        {selected, [{Server, Owner}]} -> {ok, {Server, Owner}};
        {selected, []} -> not_found
    end.

%%%----------------------------------------------------------------------
%%% Prepared queries
%%%----------------------------------------------------------------------

-spec prepare_queries(mongooseim:host_type()) -> ok.
prepare_queries(_HostType) ->
    mongoose_rdbms:prepare(broadcast_list_insert, broadcast_lists,
                           [server, owner, name, created_at],
                           <<"INSERT INTO broadcast_lists "
                             "(server, owner, name, created_at) "
                             "VALUES (?, ?, ?, ?) RETURNING id">>),
    mongoose_rdbms:prepare(broadcast_list_delete, broadcast_lists,
                           [id, server],
                           <<"DELETE FROM broadcast_lists "
                             "WHERE id = ? AND server = ?">>),
    mongoose_rdbms:prepare(broadcast_list_rename, broadcast_lists,
                           [name, id, server],
                           <<"UPDATE broadcast_lists SET name = ? "
                             "WHERE id = ? AND server = ?">>),
    mongoose_rdbms:prepare(broadcast_list_select_owner, broadcast_lists,
                           [server, owner],
                           <<"SELECT id, name FROM broadcast_lists "
                             "WHERE server = ? AND owner = ? "
                             "ORDER BY created_at">>),
    mongoose_rdbms:prepare(broadcast_list_select_one, broadcast_lists,
                           [id],
                           <<"SELECT server, owner FROM broadcast_lists "
                             "WHERE id = ?">>),
    mongoose_rdbms:prepare(broadcast_members_select, broadcast_list_members,
                           [list_id],
                           <<"SELECT member_jid FROM broadcast_list_members "
                             "WHERE list_id = ? ORDER BY member_jid">>),
    mongoose_rdbms:prepare(broadcast_members_clear, broadcast_list_members,
                           [list_id],
                           <<"DELETE FROM broadcast_list_members "
                             "WHERE list_id = ?">>),
    mongoose_rdbms:prepare(broadcast_members_insert, broadcast_list_members,
                           [list_id, member_jid],
                           <<"INSERT INTO broadcast_list_members "
                             "(list_id, member_jid) VALUES (?, ?)">>),
    ok.

%% Postgres returns BIGSERIAL as binary — normalize to integer.
to_integer(N) when is_integer(N) -> N;
to_integer(B) when is_binary(B) -> binary_to_integer(B).