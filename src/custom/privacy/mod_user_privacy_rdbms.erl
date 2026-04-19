%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc
%%% RDBMS backend for mod_user_privacy. One row per (user, field).
%%% @end
%%%----------------------------------------------------------------------
-module(mod_user_privacy_rdbms).

-behaviour(mod_user_privacy_backend).

-include("mongoose.hrl").

-export([init/2,
         get_privacy/4,
         set_privacy/5]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, _Opts) ->
    prepare_queries(HostType),
    ok.

-spec get_privacy(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    {ok, binary()} | not_found.
get_privacy(HostType, LServer, LUser, Field) ->
    case mongoose_rdbms:execute_successfully(HostType, user_privacy_select,
                                             [LServer, LUser, Field]) of
        {selected, [{Value}]} -> {ok, Value};
        {selected, []} -> not_found
    end.

-spec set_privacy(mongooseim:host_type(), jid:lserver(), jid:luser(),
                  binary(), binary()) -> ok | {error, term()}.
set_privacy(HostType, LServer, LUser, Field, Value) ->
    InsertParams = [LServer, LUser, Field, Value],
    UpdateParams = [Value],
    case rdbms_queries:execute_upsert(HostType, user_privacy_upsert,
                                      InsertParams, UpdateParams) of
        {updated, _} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%%%----------------------------------------------------------------------
%%% Prepared queries
%%%----------------------------------------------------------------------

-spec prepare_queries(mongooseim:host_type()) -> ok.
prepare_queries(HostType) ->
    mongoose_rdbms:prepare(user_privacy_select, user_privacy,
                           [server, username, field],
                           <<"SELECT value FROM user_privacy "
                             "WHERE server = ? AND username = ? AND field = ?">>),
    rdbms_queries:prepare_upsert(HostType, user_privacy_upsert, user_privacy,
                                 [<<"server">>, <<"username">>,
                                  <<"field">>, <<"value">>],
                                 [<<"value">>],
                                 [<<"server">>, <<"username">>, <<"field">>]),
    ok.