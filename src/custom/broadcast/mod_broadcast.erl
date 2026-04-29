%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_broadcast.erl
%%% Purpose : WhatsApp-style broadcast lists.
%%%
%%% A broadcast list is a one-way fan-out: the owner sends one
%%% message addressed to a virtual JID, and the server delivers a
%%% private 1:1 copy to each member as if it had been sent
%%% directly. Recipients reply to the owner as a normal chat.
%%%
%%% Virtual JID convention: `broadcast.<list_id>@<host>'.
%%%
%%% IQ Protocol (namespace `wingtrill:broadcast'):
%%%
%%%   --- List my broadcast lists ---
%%%   <iq type="get" id="b1">
%%%     <query xmlns="wingtrill:broadcast"/>
%%%   </iq>
%%%
%%%   <iq type="result" id="b1">
%%%     <query xmlns="wingtrill:broadcast">
%%%       <list id="42" name="Friends" jid="broadcast.42@host"/>
%%%     </query>
%%%   </iq>
%%%
%%%   --- Get one list (with members) ---
%%%   <iq type="get" id="b2">
%%%     <list xmlns="wingtrill:broadcast" id="42"/>
%%%   </iq>
%%%
%%%   --- Create a list ---
%%%   <iq type="set" id="b3">
%%%     <create xmlns="wingtrill:broadcast" name="Friends">
%%%       <member jid="alice@host"/>
%%%       <member jid="bob@host"/>
%%%     </create>
%%%   </iq>
%%%
%%%   --- Update name and/or members (members element replaces all) ---
%%%   <iq type="set" id="b4">
%%%     <update xmlns="wingtrill:broadcast" id="42" name="New Name">
%%%       <member jid="alice@host"/>
%%%     </update>
%%%   </iq>
%%%
%%%   --- Delete a list ---
%%%   <iq type="set" id="b5">
%%%     <delete xmlns="wingtrill:broadcast" id="42"/>
%%%   </iq>
%%%
%%% Fan-out: a `<message/>' addressed to `broadcast.<id>@<host>' from
%%% the list owner is replaced by N copies, one per member, each
%%% with `from' = owner bare JID and `to' = member bare JID. The
%%% original stanza is dropped.
%%% @end
%%%----------------------------------------------------------------------
-module(mod_broadcast).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

-define(NS_BROADCAST, <<"wingtrill:broadcast">>).
-define(BROADCAST_PREFIX, <<"broadcast.">>).

-export([start/2, stop/1, hooks/1, supported_features/0, config_spec/0]).
-export([user_send_iq/3, user_send_message/3]).

-ignore_xref([user_send_iq/3, user_send_message/3]).

%%%----------------------------------------------------------------------
%%% gen_mod
%%%----------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(HostType, Opts) ->
    mod_broadcast_backend:init(HostType, Opts).

-spec stop(mongooseim:host_type()) -> any().
stop(_HostType) -> ok.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_iq, HostType, fun ?MODULE:user_send_iq/3, #{}, 50},
     {user_send_message, HostType, fun ?MODULE:user_send_message/3, #{}, 10}].

-spec supported_features() -> [atom()].
supported_features() -> [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"backend">> => #option{type = atom,
                                          validate = {module, mod_broadcast}}},
       defaults = #{<<"backend">> => rdbms}
      }.

%%%----------------------------------------------------------------------
%%% IQ handling
%%%----------------------------------------------------------------------

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, _Params, #{host_type := HostType}) ->
    case mongoose_iq:info(Acc) of
        {#iq{xmlns = ?NS_BROADCAST} = IQ, Acc1} ->
            FromJid = mongoose_acc:from_jid(Acc1),
            ToJid = mongoose_acc:to_jid(Acc1),
            Reply = handle_iq(HostType, FromJid, IQ),
            ejabberd_router:route(ToJid, FromJid, Acc1, jlib:iq_to_xml(Reply)),
            {stop, Acc1};
        _ ->
            {ok, Acc}
    end.

-spec handle_iq(mongooseim:host_type(), jid:jid(), jlib:iq()) -> jlib:iq().
handle_iq(HostType, FromJid, #iq{type = get, sub_el = SubEl} = IQ) ->
    case SubEl#xmlel.name of
        <<"query">> ->
            handle_list_all(HostType, FromJid, IQ);
        <<"list">> ->
            handle_get_one(HostType, FromJid, IQ);
        _ ->
            error_reply(IQ, bad_request)
    end;
handle_iq(HostType, FromJid, #iq{type = set, sub_el = SubEl} = IQ) ->
    case SubEl#xmlel.name of
        <<"create">> -> handle_create(HostType, FromJid, IQ);
        <<"update">> -> handle_update(HostType, FromJid, IQ);
        <<"delete">> -> handle_delete(HostType, FromJid, IQ);
        _ -> error_reply(IQ, bad_request)
    end;
handle_iq(_HostType, _FromJid, IQ) ->
    error_reply(IQ, bad_request).

%% --- list all my lists ---
handle_list_all(HostType, #jid{luser = LUser, lserver = LServer}, IQ) ->
    Lists = mod_broadcast_backend:list_lists(HostType, LServer, LUser),
    Items = [list_summary_el(LServer, Id, Name) || {Id, Name} <- Lists],
    IQ#iq{type = result,
          sub_el = [#xmlel{name = <<"query">>,
                           attrs = #{<<"xmlns">> => ?NS_BROADCAST},
                           children = Items}]}.

%% --- get one list (with members) ---
handle_get_one(HostType, #jid{luser = LUser, lserver = LServer} = FromJid,
               #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ListId} ->
            case ensure_owner(HostType, FromJid, ListId) of
                ok ->
                    Name = lookup_name(HostType, LServer, LUser, ListId),
                    Members = mod_broadcast_backend:get_members(HostType, LServer, ListId),
                    IQ#iq{type = result,
                          sub_el = [list_full_el(LServer, ListId, Name, Members)]};
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- create ---
handle_create(HostType, #jid{luser = LUser, lserver = LServer},
              #iq{sub_el = SubEl} = IQ) ->
    Name = exml_query:attr(SubEl, <<"name">>),
    case is_valid_name(Name) of
        false ->
            error_reply(IQ, bad_request);
        true ->
            Members = parse_members(SubEl),
            case mod_broadcast_backend:create_list(HostType, LServer, LUser, Name) of
                {ok, ListId} ->
                    case Members of
                        [] -> ok;
                        _ -> mod_broadcast_backend:set_members(HostType, ListId, Members)
                    end,
                    IQ#iq{type = result,
                          sub_el = [list_full_el(LServer, ListId, Name, Members)]};
                {error, _} ->
                    error_reply(IQ, internal_server_error)
            end
    end.

%% --- update (rename and/or replace members) ---
handle_update(HostType, #jid{lserver = LServer} = FromJid,
              #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ListId} ->
            case ensure_owner(HostType, FromJid, ListId) of
                ok ->
                    apply_update(HostType, LServer, ListId, SubEl, IQ);
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

apply_update(HostType, LServer, ListId, SubEl, IQ) ->
    case exml_query:attr(SubEl, <<"name">>) of
        undefined -> ok;
        NewName ->
            case is_valid_name(NewName) of
                true -> mod_broadcast_backend:rename_list(HostType, LServer, ListId, NewName);
                false -> ok
            end
    end,
    case exml_query:subelement(SubEl, <<"member">>) of
        undefined ->
            ok;
        _ ->
            Members = parse_members(SubEl),
            mod_broadcast_backend:set_members(HostType, ListId, Members)
    end,
    IQ#iq{type = result, sub_el = []}.

%% --- delete ---
handle_delete(HostType, #jid{lserver = LServer} = FromJid,
              #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ListId} ->
            case ensure_owner(HostType, FromJid, ListId) of
                ok ->
                    mod_broadcast_backend:delete_list(HostType, LServer, ListId),
                    IQ#iq{type = result, sub_el = []};
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%%%----------------------------------------------------------------------
%%% Message fan-out
%%%----------------------------------------------------------------------

-spec user_send_message(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_message(Acc, _Params, #{host_type := HostType}) ->
    {From, To, Packet} = mongoose_acc:packet(Acc),
    case parse_broadcast_jid(To) of
        {ok, ListId} ->
            handle_broadcast_message(HostType, From, ListId, Packet, Acc);
        not_broadcast ->
            {ok, Acc}
    end.

handle_broadcast_message(HostType, From, ListId, Packet, Acc) ->
    case mod_broadcast_backend:get_list_owner(HostType, ListId) of
        {ok, {OwnerServer, OwnerUser}} ->
            #jid{luser = FromUser, lserver = FromServer} = jid:to_bare(From),
            case {FromUser, FromServer} =:= {OwnerUser, OwnerServer} of
                true ->
                    fan_out(HostType, jid:to_bare(From), ListId, Packet),
                    {stop, Acc};
                false ->
                    bounce(From, mongoose_acc:to_jid(Acc), Packet, Acc, forbidden),
                    {stop, Acc}
            end;
        not_found ->
            bounce(From, mongoose_acc:to_jid(Acc), Packet, Acc, item_not_found),
            {stop, Acc}
    end.

fan_out(HostType, FromBare, ListId, Packet) ->
    LServer = FromBare#jid.lserver,
    Members = mod_broadcast_backend:get_members(HostType, LServer, ListId),
    lists:foreach(
      fun(MemberJidBin) ->
          case jid:from_binary(MemberJidBin) of
              error -> ok;
              MemberJid ->
                  Stanza = strip_id(Packet),
                  ejabberd_router:route(FromBare, MemberJid, Stanza)
          end
      end, Members).

%% Each fan-out copy needs its own id so receivers don't dedupe.
strip_id(#xmlel{attrs = Attrs} = Packet) ->
    Packet#xmlel{attrs = maps:remove(<<"id">>, Attrs)}.

bounce(From, To, Packet, Acc, Reason) ->
    Err = make_error(Reason),
    ErrPacket = jlib:make_error_reply(Packet, Err),
    ejabberd_router:route(To, From, Acc, ErrPacket).

make_error(forbidden) -> mongoose_xmpp_errors:forbidden();
make_error(item_not_found) -> mongoose_xmpp_errors:item_not_found().

%%%----------------------------------------------------------------------
%%% Parsing / validation
%%%----------------------------------------------------------------------

%% A broadcast JID has user-part `broadcast.<digits>'. Returns the
%% list id or `not_broadcast' for any other JID.
-spec parse_broadcast_jid(jid:jid()) -> {ok, integer()} | not_broadcast.
parse_broadcast_jid(#jid{luser = LUser}) ->
    PrefixLen = byte_size(?BROADCAST_PREFIX),
    case LUser of
        <<Prefix:PrefixLen/binary, IdBin/binary>>
          when Prefix =:= ?BROADCAST_PREFIX, byte_size(IdBin) > 0 ->
            try {ok, binary_to_integer(IdBin)}
            catch _:_ -> not_broadcast
            end;
        _ ->
            not_broadcast
    end.

parse_id(El) ->
    case exml_query:attr(El, <<"id">>) of
        undefined -> {error, bad_request};
        IdBin ->
            try {ok, binary_to_integer(IdBin)}
            catch _:_ -> {error, bad_request}
            end
    end.

parse_members(#xmlel{children = Children}) ->
    [bare_jid_binary(exml_query:attr(El, <<"jid">>))
     || El = #xmlel{name = <<"member">>} <- Children,
        is_binary(exml_query:attr(El, <<"jid">>))].

bare_jid_binary(JidBin) ->
    case jid:from_binary(JidBin) of
        error -> JidBin;
        Jid -> jid:to_binary(jid:to_bare(jid:to_lower(Jid)))
    end.

is_valid_name(undefined) -> false;
is_valid_name(<<>>) -> false;
is_valid_name(Name) when is_binary(Name), byte_size(Name) =< 250 -> true;
is_valid_name(_) -> false.

ensure_owner(HostType, #jid{luser = LUser, lserver = LServer}, ListId) ->
    case mod_broadcast_backend:get_list_owner(HostType, ListId) of
        {ok, {LServer, LUser}} -> ok;
        {ok, _} -> {error, forbidden};
        not_found -> {error, item_not_found}
    end.

lookup_name(HostType, LServer, LUser, ListId) ->
    Lists = mod_broadcast_backend:list_lists(HostType, LServer, LUser),
    case lists:keyfind(ListId, 1, Lists) of
        {_, Name} -> Name;
        false -> <<>>
    end.

%%%----------------------------------------------------------------------
%%% XML rendering
%%%----------------------------------------------------------------------

list_summary_el(LServer, Id, Name) ->
    #xmlel{name = <<"list">>,
           attrs = #{<<"id">> => integer_to_binary(Id),
                     <<"name">> => Name,
                     <<"jid">> => broadcast_jid(LServer, Id)},
           children = []}.

list_full_el(LServer, Id, Name, Members) ->
    MemberEls = [#xmlel{name = <<"member">>,
                        attrs = #{<<"jid">> => M},
                        children = []} || M <- Members],
    #xmlel{name = <<"list">>,
           attrs = #{<<"xmlns">> => ?NS_BROADCAST,
                     <<"id">> => integer_to_binary(Id),
                     <<"name">> => Name,
                     <<"jid">> => broadcast_jid(LServer, Id)},
           children = MemberEls}.

broadcast_jid(LServer, Id) ->
    <<?BROADCAST_PREFIX/binary, (integer_to_binary(Id))/binary, "@", LServer/binary>>.

%%%----------------------------------------------------------------------
%%% Error replies
%%%----------------------------------------------------------------------

error_reply(#iq{sub_el = SubEl} = IQ, forbidden) ->
    IQ#iq{type = error, sub_el = [SubEl, mongoose_xmpp_errors:forbidden()]};
error_reply(#iq{sub_el = SubEl} = IQ, item_not_found) ->
    IQ#iq{type = error, sub_el = [SubEl, mongoose_xmpp_errors:item_not_found()]};
error_reply(#iq{sub_el = SubEl} = IQ, internal_server_error) ->
    IQ#iq{type = error, sub_el = [SubEl, mongoose_xmpp_errors:internal_server_error()]};
error_reply(#iq{sub_el = SubEl} = IQ, _) ->
    IQ#iq{type = error, sub_el = [SubEl, mongoose_xmpp_errors:bad_request()]}.