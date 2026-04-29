%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_email_sync_rdbms.erl
%%% Purpose : RDBMS backend for mod_email_sync.
%%%
%%% == Storage model ==
%%%
%%% Emails are stored in the `email_contacts' table:
%%%
%%% ```sql
%%% CREATE TABLE email_contacts (
%%%     email    VARCHAR(255) NOT NULL,
%%%     server   VARCHAR(250) NOT NULL,
%%%     username VARCHAR(250) NOT NULL,
%%%     created_at TIMESTAMP  NOT NULL DEFAULT now(),
%%%     PRIMARY KEY (email, server)
%%% );
%%% '''
%%%
%%% The primary key `(email, server)' enforces one XMPP account per
%%% email address per server.  Upserts handle the case where a user
%%% re-authenticates with a different JID (username changes).
%%%
%%% == Lookup strategy ==
%%%
%%% Unlike phone numbers (which use a last-7-digit prefix for fuzzy
%%% matching), email addresses are exact identifiers.  The client sends
%%% the full address and the server performs a direct `IN (...)' query.
%%% Emails are normalised to lowercase before both storage and lookup
%%% so comparisons are effectively case-insensitive.
%%%
%%% The `IN' list is built with inline string literals rather than
%%% positional parameters because the RDBMS prepared-statement API
%%% does not support variable-length parameter lists.  All values are
%%% already normalised to lowercase at this point so SQL injection via
%%% case manipulation is not a concern; the only characters that could
%%% appear in a valid email address are safe in a quoted string literal.
%%%
%%% @end
%%%----------------------------------------------------------------------

-module(mod_email_sync_rdbms).

-behaviour(mod_email_sync_backend).

-include("mongoose.hrl").

-export([init/2, store_email/4, lookup_emails/3]).

%%%----------------------------------------------------------------------
%%% Backend API
%%%----------------------------------------------------------------------

%% @doc Prepare RDBMS statements for this host type.
-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, _Opts) ->
    prepare_queries(HostType),
    ok.

%% @doc Upsert the `(Email, LServer) → LUser' mapping.
%%
%% If a row for `(Email, LServer)' already exists the `username' column
%% is updated.  This covers the edge case where a user's XMPP node
%% (username) changes while their email stays the same.
-spec store_email(mongooseim:host_type(), jid:lserver(), jid:luser(), binary()) ->
    ok | {error, term()}.
store_email(HostType, LServer, LUser, Email) ->
    InsertParams = [Email, LServer, LUser],
    UpdateParams = [LUser],
    case rdbms_queries:execute_upsert(HostType, email_contacts_upsert,
                                      InsertParams, UpdateParams) of
        {updated, _} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{what   => email_contact_store_failed,
                           reason => Reason,
                           email  => Email,
                           user   => LUser,
                           server => LServer}),
            {error, Reason}
    end.

%% @doc Return `{Email, Username}' rows for all emails that are
%% registered on `LServer'.
%%
%% An empty input list short-circuits immediately with `[]' to avoid
%% issuing a malformed SQL query.
%%
%% The input list is de-duplicated and lowercased before the query so
%% that duplicate or mixed-case addresses from the client result in a
%% single database hit.
-spec lookup_emails(mongooseim:host_type(), jid:lserver(), [binary()]) ->
    [{Email :: binary(), Username :: binary()}].
lookup_emails(_HostType, _LServer, []) ->
    [];
lookup_emails(HostType, LServer, Emails) ->
    %% Normalise and de-duplicate to keep the IN list compact.
    NormEmails  = lists:usort([jid:str_tolower(E) || E <- Emails]),
    %% Build a comma-separated list of quoted string literals.
    QuotedList  = [<<"'", E/binary, "'">> || E <- NormEmails],
    EmailListBin = iolist_to_binary(lists:join(<<",">>, QuotedList)),
    Query = <<"SELECT email, username FROM email_contacts"
              " WHERE server='", LServer/binary,
              "' AND email IN (", EmailListBin/binary, ")">>,
    case mongoose_rdbms:sql_query(HostType, Query) of
        {selected, Rows} -> Rows;
        _                -> []
    end.

%%%----------------------------------------------------------------------
%%% Internal: prepared statements
%%%----------------------------------------------------------------------

%% @doc Register the upsert statement for `email_contacts'.
%%
%% Insert columns : email, server, username
%% Update columns : username          (updated when email/server key exists)
%% Key columns    : email, server
-spec prepare_queries(mongooseim:host_type()) -> ok.
prepare_queries(HostType) ->
    rdbms_queries:prepare_upsert(
        HostType,
        email_contacts_upsert,      %% statement name
        email_contacts,             %% table
        [<<"email">>, <<"server">>, <<"username">>],   %% insert columns
        [<<"username">>],           %% update columns on conflict
        [<<"email">>,  <<"server">>]                   %% conflict key
    ),
    ok.