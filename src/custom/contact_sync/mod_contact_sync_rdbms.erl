%% RDBMS backend for mod_contact_sync.
%% Optimized with last7 digit matching for faster lookup.

-module(mod_contact_sync_rdbms).

-behaviour(mod_contact_sync_backend).

-include("mongoose.hrl").

-export([init/2,
         store_phone/4,
         lookup_phones/3,
         get_user_phone/3,
         remove_user/3]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, _Opts) ->
    prepare_queries(HostType),
    ok.

-spec store_phone(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    ok | {error, term()}.
store_phone(HostType, LServer, LUser, Phone) ->
    Last7 = last7(Phone),
    InsertParams = [Phone, Last7, LServer, LUser],
    UpdateParams = [LUser],
    case rdbms_queries:execute_upsert(HostType, phone_contacts_upsert,
                                       InsertParams, UpdateParams) of
        {updated, _} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{what => phone_contact_store_failed,
                           reason => Reason, phone => Phone,
                           user => LUser, server => LServer}),
            {error, Reason}
    end.

-spec lookup_phones(mongooseim:host_type(), jid:lserver(), [binary()]) ->
    [{Phone :: binary(), Username :: binary()}].
lookup_phones(_HostType, _LServer, []) ->
    [];
lookup_phones(HostType, LServer, Phones) ->
    Last7List = lists:usort([last7(P) || P <- Phones]),
    QuotedList =
        lists:map(
            fun(V) -> << "'", V/binary, "'" >> end,
            Last7List
        ),
    Last7ListBin = iolist_to_binary(
        lists:join(<<",">>, QuotedList)
    ),
    Query = <<"SELECT phone, username FROM phone_contacts WHERE server ='", LServer/binary, "' AND last7 IN (", Last7ListBin/binary, ")">>,
    case mongoose_rdbms:sql_query(HostType, Query) of
        {selected, Rows} ->
            Rows;
        _ ->
            []
    end.

-spec get_user_phone(mongooseim:host_type(), jid:lserver(), jid:luser()) -> binary().
get_user_phone(HostType, LServer, LUser) ->
    case mongoose_rdbms:execute_successfully(HostType, phone_contacts_get_by_user,
                                              [LServer, LUser]) of
        {selected, []} -> <<>>;
        {selected, [{Phone}]} -> Phone
    end.

-spec remove_user(mongooseim:host_type(), jid:luser(), jid:lserver()) ->
    ok | {error, term()}.
remove_user(HostType, LUser, LServer) ->
    case mongoose_rdbms:execute_successfully(HostType, phone_contacts_delete_user,
                                              [LServer, LUser]) of
        {updated, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%%%----------------------------------------------------------------------
%%% Internal helpers
%%%----------------------------------------------------------------------

%% Extract last 7 digits from phone (normalized)
-spec last7(binary()) -> binary().
last7(Phone) ->
    Digits = re:replace(Phone, "[^0-9]", "", [global, {return, binary}]),
    Size = byte_size(Digits),
    case Size >= 7 of
        true -> binary:part(Digits, Size - 7, 7);
        false -> Digits
    end.

%%%----------------------------------------------------------------------
%%% Internal: prepared queries
%%%----------------------------------------------------------------------

-spec prepare_queries(mongooseim:host_type()) -> ok.
prepare_queries(HostType) ->
    rdbms_queries:prepare_upsert(HostType, phone_contacts_upsert, phone_contacts,
        [<<"phone">>, <<"last7">>, <<"server">>, <<"username">>],
        [<<"username">>],
        [<<"phone">>, <<"server">>]),

    mongoose_rdbms:prepare(phone_contacts_get_by_user, phone_contacts,
        [server, username],
        <<"SELECT phone FROM phone_contacts WHERE server = ? AND username = ?">>),

    mongoose_rdbms:prepare(phone_contacts_delete_user, phone_contacts,
        [server, username],
        <<"DELETE FROM phone_contacts WHERE server = ? AND username = ?">>),

    ok.

