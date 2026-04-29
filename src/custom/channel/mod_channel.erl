%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_channel.erl
%%% Purpose : Telegram-style one-way channels with persistent history.
%%%
%%% A channel is a one-to-many publication: admins post messages to a
%%% virtual channel JID, and subscribers receive them. Unlike
%%% mod_broadcast (eager fan-out, no persistence), each channel
%%% message is stored to a per-channel append-only log first, then
%%% fanned out to currently-online subscribers. Offline subscribers
%%% catch up via the history IQ on next connect — this avoids the
%%% offline-message write amplification that breaks broadcast at
%%% Telegram-channel scale.
%%%
%%% Virtual JID convention: `channel.<channel_id>@<host>'.
%%%
%%% Roles:
%%%   owner  - the creator; can promote/demote/delete
%%%   admin  - can post and manage subscribers
%%%   subscriber - read-only consumer
%%%
%%% IQ Protocol (namespace `wingtrill:channel'):
%%%
%%%   --- List channels I'm in (subscribed or admin) ---
%%%   <iq type="get" id="c1">
%%%     <query xmlns="wingtrill:channel"/>
%%%   </iq>
%%%
%%%   --- Get one channel ---
%%%   <iq type="get" id="c2">
%%%     <get xmlns="wingtrill:channel" id="42"/>
%%%   </iq>
%%%
%%%   --- Create ---
%%%   <iq type="set" id="c3">
%%%     <create xmlns="wingtrill:channel"
%%%             handle="news" name="News"
%%%             description="..." type="public"/>
%%%   </iq>
%%%
%%%   --- Update name/description ---
%%%   <iq type="set" id="c4">
%%%     <update xmlns="wingtrill:channel" id="42" name="..." description="..."/>
%%%   </iq>
%%%
%%%   --- Delete (owner only) ---
%%%   <iq type="set" id="c5">
%%%     <delete xmlns="wingtrill:channel" id="42"/>
%%%   </iq>
%%%
%%%   --- Subscribe to a public channel ---
%%%   <iq type="set" id="c6">
%%%     <join xmlns="wingtrill:channel" handle="news"/>
%%%   </iq>
%%%
%%%   --- Unsubscribe ---
%%%   <iq type="set" id="c7">
%%%     <leave xmlns="wingtrill:channel" id="42"/>
%%%   </iq>
%%%
%%%   --- Admin posts a message ---
%%%   <iq type="set" id="c8">
%%%     <post xmlns="wingtrill:channel" id="42">
%%%       <body>Hello world</body>
%%%     </post>
%%%   </iq>
%%%
%%%   --- Fetch history (paginated; `before' is exclusive msg id) ---
%%%   <iq type="get" id="c9">
%%%     <history xmlns="wingtrill:channel" id="42" before="1000" limit="50"/>
%%%   </iq>
%%%
%%%   --- List subscribers (admin only) ---
%%%   <iq type="get" id="c10">
%%%     <members xmlns="wingtrill:channel" id="42" offset="0" limit="100"/>
%%%   </iq>
%%%
%%%   --- Promote / demote (owner only) ---
%%%   <iq type="set" id="c11">
%%%     <promote xmlns="wingtrill:channel" id="42" jid="alice@host"/>
%%%   </iq>
%%%   <iq type="set" id="c12">
%%%     <demote xmlns="wingtrill:channel" id="42" jid="alice@host"/>
%%%   </iq>
%%%
%%%   --- Admin adds member (private channels) / removes member ---
%%%   <iq type="set" id="c13">
%%%     <add xmlns="wingtrill:channel" id="42" jid="bob@host"/>
%%%   </iq>
%%%   <iq type="set" id="c14">
%%%     <remove xmlns="wingtrill:channel" id="42" jid="bob@host"/>
%%%   </iq>
%%%
%%%   --- Search public channels ---
%%%   <iq type="get" id="c15">
%%%     <search xmlns="wingtrill:channel" query="news" limit="20"/>
%%%   </iq>
%%%
%%% Posting also works by sending a `<message/>' to
%%% `channel.<id>@<host>' from an admin; non-admins get a forbidden
%%% error and the stanza is dropped.
%%% @end
%%%----------------------------------------------------------------------
-module(mod_channel).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

-define(NS_CHANNEL, <<"wingtrill:channel">>).
-define(CHANNEL_PREFIX, <<"channel.">>).
-define(MAX_HISTORY_LIMIT, 200).
-define(DEFAULT_HISTORY_LIMIT, 50).
-define(MAX_MEMBERS_LIMIT, 500).
-define(DEFAULT_MEMBERS_LIMIT, 100).

-export([start/2, stop/1, hooks/1, supported_features/0, config_spec/0]).
-export([user_send_iq/3, user_send_message/3]).

-ignore_xref([user_send_iq/3, user_send_message/3]).

%%%----------------------------------------------------------------------
%%% gen_mod
%%%----------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(HostType, Opts) ->
    mod_channel_backend:init(HostType, Opts).

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
                                          validate = {module, mod_channel}}},
       defaults = #{<<"backend">> => rdbms}
      }.

%%%----------------------------------------------------------------------
%%% IQ handling
%%%----------------------------------------------------------------------

-spec user_send_iq(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_iq(Acc, _Params, #{host_type := HostType}) ->
    case mongoose_iq:info(Acc) of
        {#iq{xmlns = ?NS_CHANNEL} = IQ, Acc1} ->
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
        <<"query">>   -> handle_list_mine(HostType, FromJid, IQ);
        <<"get">>     -> handle_get_one(HostType, FromJid, IQ);
        <<"history">> -> handle_history(HostType, FromJid, IQ);
        <<"members">> -> handle_members(HostType, FromJid, IQ);
        <<"search">>  -> handle_search(HostType, FromJid, IQ);
        _ -> error_reply(IQ, bad_request)
    end;
handle_iq(HostType, FromJid, #iq{type = set, sub_el = SubEl} = IQ) ->
    case SubEl#xmlel.name of
        <<"create">>  -> handle_create(HostType, FromJid, IQ);
        <<"update">>  -> handle_update(HostType, FromJid, IQ);
        <<"delete">>  -> handle_delete(HostType, FromJid, IQ);
        <<"join">>    -> handle_join(HostType, FromJid, IQ);
        <<"leave">>   -> handle_leave(HostType, FromJid, IQ);
        <<"post">>    -> handle_post_iq(HostType, FromJid, IQ);
        <<"promote">> -> handle_role_change(HostType, FromJid, IQ, promote);
        <<"demote">>  -> handle_role_change(HostType, FromJid, IQ, demote);
        <<"add">>     -> handle_admin_add(HostType, FromJid, IQ);
        <<"remove">>  -> handle_admin_remove(HostType, FromJid, IQ);
        _ -> error_reply(IQ, bad_request)
    end;
handle_iq(_HostType, _FromJid, IQ) ->
    error_reply(IQ, bad_request).

%% --- list my channels (admin + subscribed) ---
handle_list_mine(HostType, #jid{lserver = LServer} = FromJid, IQ) ->
    BareBin = bare_jid_bin(FromJid),
    AdminOf = mod_channel_backend:list_admin_channels(HostType, LServer, BareBin),
    Subscribed = mod_channel_backend:list_subscribed_channels(HostType, LServer, BareBin),
    Items = [channel_summary_el(LServer, Ch, <<"admin">>) || Ch <- AdminOf]
         ++ [channel_summary_el(LServer, Ch, <<"subscriber">>)
             || Ch <- Subscribed,
                not is_in_admin_list(maps:get(id, Ch), AdminOf)],
    IQ#iq{type = result,
          sub_el = [#xmlel{name = <<"query">>,
                           attrs = #{<<"xmlns">> => ?NS_CHANNEL},
                           children = Items}]}.

%% --- get one channel ---
handle_get_one(HostType, #jid{lserver = LServer} = FromJid,
               #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case load_channel_for_member(HostType, LServer, FromJid, ChId) of
                {ok, Ch, _Role} ->
                    IQ#iq{type = result,
                          sub_el = [channel_full_el(LServer, Ch)]};
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- create ---
handle_create(HostType, #jid{lserver = LServer} = FromJid,
              #iq{sub_el = SubEl} = IQ) ->
    Owner = bare_jid_bin(FromJid),
    Handle = normalize_handle(exml_query:attr(SubEl, <<"handle">>)),
    Name = exml_query:attr(SubEl, <<"name">>),
    Desc = default(exml_query:attr(SubEl, <<"description">>), <<>>),
    Type = parse_type(exml_query:attr(SubEl, <<"type">>)),
    case validate_create(Handle, Name, Type) of
        ok ->
            case mod_channel_backend:create_channel(HostType, LServer, Owner,
                                                    Handle, Name, Desc, Type) of
                {ok, ChId} ->
                    {ok, Ch} = mod_channel_backend:get_channel(HostType, ChId),
                    IQ#iq{type = result,
                          sub_el = [channel_full_el(LServer, Ch)]};
                {error, handle_taken} ->
                    error_reply(IQ, conflict);
                {error, _} ->
                    error_reply(IQ, internal_server_error)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- update ---
handle_update(HostType, #jid{lserver = LServer} = FromJid,
              #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case ensure_admin(HostType, LServer, FromJid, ChId) of
                {ok, _Role} ->
                    Updates = parse_update_attrs(SubEl),
                    case Updates of
                        [] ->
                            IQ#iq{type = result, sub_el = []};
                        _ ->
                            mod_channel_backend:update_channel(HostType, ChId, Updates),
                            IQ#iq{type = result, sub_el = []}
                    end;
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- delete (owner only) ---
handle_delete(HostType, #jid{lserver = LServer} = FromJid,
              #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case ensure_owner(HostType, LServer, FromJid, ChId) of
                ok ->
                    mod_channel_backend:delete_channel(HostType, ChId),
                    IQ#iq{type = result, sub_el = []};
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- join (subscribe) ---
handle_join(HostType, #jid{lserver = LServer} = FromJid,
            #iq{sub_el = SubEl} = IQ) ->
    Subscriber = bare_jid_bin(FromJid),
    case resolve_channel(HostType, LServer, SubEl) of
        {ok, #{id := ChId, channel_type := Type} = Ch} ->
            case Type of
                <<"public">> ->
                    case mod_channel_backend:subscribe(HostType, ChId, Subscriber) of
                        ok ->
                            IQ#iq{type = result,
                                  sub_el = [channel_full_el(LServer, Ch)]};
                        {error, already_subscribed} ->
                            IQ#iq{type = result,
                                  sub_el = [channel_full_el(LServer, Ch)]};
                        {error, _} ->
                            error_reply(IQ, internal_server_error)
                    end;
                _ ->
                    error_reply(IQ, forbidden)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- leave ---
handle_leave(HostType, #jid{lserver = LServer} = FromJid,
             #iq{sub_el = SubEl} = IQ) ->
    Subscriber = bare_jid_bin(FromJid),
    case parse_id(SubEl) of
        {ok, ChId} ->
            case mod_channel_backend:get_channel(HostType, ChId) of
                {ok, #{server := LServer}} ->
                    mod_channel_backend:unsubscribe(HostType, ChId, Subscriber),
                    IQ#iq{type = result, sub_el = []};
                _ ->
                    error_reply(IQ, item_not_found)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- post via IQ ---
handle_post_iq(HostType, #jid{lserver = LServer} = FromJid,
               #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case ensure_admin(HostType, LServer, FromJid, ChId) of
                {ok, _Role} ->
                    Body = body_text(SubEl),
                    case is_valid_body(Body) of
                        true ->
                            {ok, MsgId} = post_and_fanout(HostType, FromJid, ChId, Body),
                            IQ#iq{type = result,
                                  sub_el = [#xmlel{
                                      name = <<"posted">>,
                                      attrs = #{<<"xmlns">> => ?NS_CHANNEL,
                                                <<"id">> => integer_to_binary(ChId),
                                                <<"msg_id">> => integer_to_binary(MsgId)},
                                      children = []}]};
                        false ->
                            error_reply(IQ, bad_request)
                    end;
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- history ---
handle_history(HostType, #jid{lserver = LServer} = FromJid,
               #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case load_channel_for_member(HostType, LServer, FromJid, ChId) of
                {ok, _Ch, _Role} ->
                    Before = parse_int_attr(SubEl, <<"before">>, 0),
                    Limit = bound(parse_int_attr(SubEl, <<"limit">>,
                                                 ?DEFAULT_HISTORY_LIMIT),
                                  1, ?MAX_HISTORY_LIMIT),
                    Msgs = mod_channel_backend:fetch_history(HostType, ChId, Before, Limit),
                    Items = [history_msg_el(M) || M <- Msgs],
                    IQ#iq{type = result,
                          sub_el = [#xmlel{name = <<"history">>,
                                           attrs = #{<<"xmlns">> => ?NS_CHANNEL,
                                                     <<"id">> => integer_to_binary(ChId)},
                                           children = Items}]};
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- members (admin only) ---
handle_members(HostType, #jid{lserver = LServer} = FromJid,
               #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case ensure_admin(HostType, LServer, FromJid, ChId) of
                {ok, _Role} ->
                    Offset = max(0, parse_int_attr(SubEl, <<"offset">>, 0)),
                    Limit = bound(parse_int_attr(SubEl, <<"limit">>,
                                                 ?DEFAULT_MEMBERS_LIMIT),
                                  1, ?MAX_MEMBERS_LIMIT),
                    Subs = mod_channel_backend:list_subscribers(HostType, ChId, Offset, Limit),
                    Total = mod_channel_backend:count_subscribers(HostType, ChId),
                    Admins = mod_channel_backend:list_admins(HostType, ChId),
                    AdminEls = [#xmlel{name = <<"admin">>,
                                       attrs = #{<<"jid">> => J,
                                                 <<"role">> => R},
                                       children = []}
                                || {J, R} <- Admins],
                    SubEls = [#xmlel{name = <<"subscriber">>,
                                     attrs = #{<<"jid">> => J},
                                     children = []}
                              || J <- Subs],
                    IQ#iq{type = result,
                          sub_el = [#xmlel{name = <<"members">>,
                                           attrs = #{<<"xmlns">> => ?NS_CHANNEL,
                                                     <<"id">> => integer_to_binary(ChId),
                                                     <<"total">> => integer_to_binary(Total)},
                                           children = AdminEls ++ SubEls}]};
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- search public channels ---
handle_search(HostType, #jid{lserver = LServer}, #iq{sub_el = SubEl} = IQ) ->
    Q = default(exml_query:attr(SubEl, <<"query">>), <<>>),
    Limit = bound(parse_int_attr(SubEl, <<"limit">>, 20), 1, 50),
    Results = mod_channel_backend:search_channels(HostType, LServer, Q, Limit),
    Items = [channel_summary_el(LServer, Ch, <<"none">>) || Ch <- Results],
    IQ#iq{type = result,
          sub_el = [#xmlel{name = <<"search">>,
                           attrs = #{<<"xmlns">> => ?NS_CHANNEL},
                           children = Items}]}.

%% --- promote / demote (owner only) ---
handle_role_change(HostType, #jid{lserver = LServer} = FromJid,
                   #iq{sub_el = SubEl} = IQ, Action) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case ensure_owner(HostType, LServer, FromJid, ChId) of
                ok ->
                    TargetJid = exml_query:attr(SubEl, <<"jid">>),
                    case bare_jid_normalize(TargetJid) of
                        {ok, Bin} ->
                            case Action of
                                promote ->
                                    Now = erlang:system_time(second),
                                    mod_channel_backend:add_admin(HostType, ChId,
                                                                  Bin, <<"admin">>, Now);
                                demote ->
                                    mod_channel_backend:remove_admin(HostType, ChId, Bin)
                            end,
                            IQ#iq{type = result, sub_el = []};
                        error ->
                            error_reply(IQ, bad_request)
                    end;
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- admin adds member ---
handle_admin_add(HostType, #jid{lserver = LServer} = FromJid,
                 #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case ensure_admin(HostType, LServer, FromJid, ChId) of
                {ok, _Role} ->
                    TargetJid = exml_query:attr(SubEl, <<"jid">>),
                    case bare_jid_normalize(TargetJid) of
                        {ok, Bin} ->
                            mod_channel_backend:subscribe(HostType, ChId, Bin),
                            IQ#iq{type = result, sub_el = []};
                        error ->
                            error_reply(IQ, bad_request)
                    end;
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%% --- admin removes member ---
handle_admin_remove(HostType, #jid{lserver = LServer} = FromJid,
                    #iq{sub_el = SubEl} = IQ) ->
    case parse_id(SubEl) of
        {ok, ChId} ->
            case ensure_admin(HostType, LServer, FromJid, ChId) of
                {ok, _Role} ->
                    TargetJid = exml_query:attr(SubEl, <<"jid">>),
                    case bare_jid_normalize(TargetJid) of
                        {ok, Bin} ->
                            mod_channel_backend:unsubscribe(HostType, ChId, Bin),
                            IQ#iq{type = result, sub_el = []};
                        error ->
                            error_reply(IQ, bad_request)
                    end;
                {error, Reason} ->
                    error_reply(IQ, Reason)
            end;
        {error, Reason} ->
            error_reply(IQ, Reason)
    end.

%%%----------------------------------------------------------------------
%%% Message handling: posting via <message/> to channel JID
%%%----------------------------------------------------------------------

-spec user_send_message(mongoose_acc:t(), mongoose_c2s_hooks:params(), gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_message(Acc, _Params, #{host_type := HostType}) ->
    {From, To, Packet} = mongoose_acc:packet(Acc),
    case parse_channel_jid(To) of
        {ok, ChId} ->
            handle_channel_message(HostType, From, ChId, Packet, Acc);
        not_channel ->
            {ok, Acc}
    end.

handle_channel_message(HostType, From, ChId, Packet, Acc) ->
    case mod_channel_backend:get_channel(HostType, ChId) of
        {ok, #{}} ->
            case mod_channel_backend:is_admin(HostType, ChId, bare_jid_bin(From)) of
                true ->
                    Body = exml_query:path(Packet,
                                           [{element, <<"body">>}, cdata]),
                    case is_valid_body(Body) of
                        true ->
                            post_and_fanout(HostType, From, ChId, Body),
                            {stop, Acc};
                        false ->
                            bounce(From, mongoose_acc:to_jid(Acc), Packet, Acc, bad_request),
                            {stop, Acc}
                    end;
                false ->
                    bounce(From, mongoose_acc:to_jid(Acc), Packet, Acc, forbidden),
                    {stop, Acc}
            end;
        not_found ->
            bounce(From, mongoose_acc:to_jid(Acc), Packet, Acc, item_not_found),
            {stop, Acc}
    end.

%%%----------------------------------------------------------------------
%%% Posting + fan-out
%%%
%%% Persist first, then push to currently-online subscribers in
%%% chunks. Offline subscribers catch up via the history IQ on next
%%% connect — they are intentionally not delivered offline messages
%%% because at channel scale (potentially millions of subscribers per
%%% channel) the offline-store write amplification is unacceptable.
%%%----------------------------------------------------------------------

-define(FANOUT_CHUNK, 500).

-spec post_and_fanout(mongooseim:host_type(), jid:jid(), integer(), binary()) ->
    {ok, integer()}.
post_and_fanout(HostType, FromJid, ChId, Body) ->
    SenderBin = bare_jid_bin(FromJid),
    {ok, MsgId} = mod_channel_backend:store_message(HostType, ChId, SenderBin, Body),
    spawn(fun() -> fanout_to_subscribers(HostType, ChId, MsgId, SenderBin, Body) end),
    {ok, MsgId}.

fanout_to_subscribers(HostType, ChId, MsgId, SenderBin, Body) ->
    case mod_channel_backend:get_channel(HostType, ChId) of
        {ok, #{server := LServer}} ->
            FromJid = jid:from_binary(channel_jid(LServer, ChId)),
            fanout_loop(HostType, ChId, MsgId, SenderBin, Body, FromJid, 0);
        _ ->
            ok
    end.

fanout_loop(HostType, ChId, MsgId, SenderBin, Body, FromJid, Offset) ->
    case mod_channel_backend:list_subscribers(HostType, ChId, Offset, ?FANOUT_CHUNK) of
        [] -> ok;
        Subs ->
            lists:foreach(
              fun(SubBin) ->
                  case jid:from_binary(SubBin) of
                      error -> ok;
                      ToJid ->
                          Stanza = channel_message_stanza(ChId, MsgId, SenderBin, Body),
                          ejabberd_router:route(FromJid, ToJid, Stanza)
                  end
              end, Subs),
            case length(Subs) < ?FANOUT_CHUNK of
                true -> ok;
                false ->
                    fanout_loop(HostType, ChId, MsgId, SenderBin, Body,
                                FromJid, Offset + ?FANOUT_CHUNK)
            end
    end.

channel_message_stanza(ChId, MsgId, SenderBin, Body) ->
    #xmlel{name = <<"message">>,
           attrs = #{<<"type">> => <<"chat">>},
           children = [#xmlel{name = <<"body">>,
                              attrs = #{},
                              children = [#xmlcdata{content = Body}]},
                       #xmlel{name = <<"channel">>,
                              attrs = #{<<"xmlns">> => ?NS_CHANNEL,
                                        <<"id">> => integer_to_binary(ChId),
                                        <<"msg_id">> => integer_to_binary(MsgId),
                                        <<"sender">> => SenderBin},
                              children = []}]}.

%%%----------------------------------------------------------------------
%%% Authorization helpers
%%%----------------------------------------------------------------------

ensure_owner(HostType, LServer, FromJid, ChId) ->
    Bin = bare_jid_bin(FromJid),
    case mod_channel_backend:get_channel(HostType, ChId) of
        {ok, #{server := LServer, owner := Bin}} -> ok;
        {ok, #{}} -> {error, forbidden};
        not_found -> {error, item_not_found}
    end.

ensure_admin(HostType, LServer, FromJid, ChId) ->
    Bin = bare_jid_bin(FromJid),
    case mod_channel_backend:get_channel(HostType, ChId) of
        {ok, #{server := LServer, owner := Bin}} ->
            {ok, <<"owner">>};
        {ok, #{server := LServer}} ->
            case mod_channel_backend:is_admin(HostType, ChId, Bin) of
                true -> {ok, <<"admin">>};
                false -> {error, forbidden}
            end;
        {ok, #{}} ->
            {error, forbidden};
        not_found ->
            {error, item_not_found}
    end.

%% Returns the channel (and the requester's role) iff the requester is
%% owner, admin, or a current subscriber.
load_channel_for_member(HostType, LServer, FromJid, ChId) ->
    Bin = bare_jid_bin(FromJid),
    case mod_channel_backend:get_channel(HostType, ChId) of
        {ok, #{server := LServer, owner := Bin} = Ch} ->
            {ok, Ch, <<"owner">>};
        {ok, #{server := LServer} = Ch} ->
            case mod_channel_backend:is_admin(HostType, ChId, Bin) of
                true -> {ok, Ch, <<"admin">>};
                false ->
                    case mod_channel_backend:is_subscriber(HostType, ChId, Bin) of
                        true  -> {ok, Ch, <<"subscriber">>};
                        false ->
                            case maps:get(channel_type, Ch, <<"public">>) of
                                <<"public">> -> {ok, Ch, <<"none">>};
                                _ -> {error, forbidden}
                            end
                    end
            end;
        {ok, #{}} ->
            {error, forbidden};
        not_found ->
            {error, item_not_found}
    end.

%%%----------------------------------------------------------------------
%%% Parsing / validation
%%%----------------------------------------------------------------------

-spec parse_channel_jid(jid:jid()) -> {ok, integer()} | not_channel.
parse_channel_jid(#jid{luser = LUser}) ->
    PrefixLen = byte_size(?CHANNEL_PREFIX),
    case LUser of
        <<Prefix:PrefixLen/binary, IdBin/binary>>
          when Prefix =:= ?CHANNEL_PREFIX, byte_size(IdBin) > 0 ->
            try {ok, binary_to_integer(IdBin)}
            catch _:_ -> not_channel
            end;
        _ ->
            not_channel
    end.

parse_id(El) ->
    case exml_query:attr(El, <<"id">>) of
        undefined -> {error, bad_request};
        IdBin ->
            try {ok, binary_to_integer(IdBin)}
            catch _:_ -> {error, bad_request}
            end
    end.

parse_int_attr(El, Attr, Default) ->
    case exml_query:attr(El, Attr) of
        undefined -> Default;
        Bin ->
            try binary_to_integer(Bin)
            catch _:_ -> Default
            end
    end.

parse_type(<<"private">>) -> <<"private">>;
parse_type(_) -> <<"public">>.

parse_update_attrs(El) ->
    Pairs = [{name, exml_query:attr(El, <<"name">>)},
             {description, exml_query:attr(El, <<"description">>)},
             {channel_type, parse_type_optional(exml_query:attr(El, <<"type">>))}],
    [{K, V} || {K, V} <- Pairs, V =/= undefined].

parse_type_optional(undefined) -> undefined;
parse_type_optional(<<"private">>) -> <<"private">>;
parse_type_optional(<<"public">>)  -> <<"public">>;
parse_type_optional(_) -> undefined.

resolve_channel(HostType, LServer, El) ->
    case exml_query:attr(El, <<"id">>) of
        undefined ->
            case exml_query:attr(El, <<"handle">>) of
                undefined -> {error, bad_request};
                Handle ->
                    Norm = normalize_handle(Handle),
                    case mod_channel_backend:get_channel_by_handle(HostType, LServer, Norm) of
                        {ok, Ch} -> {ok, Ch};
                        not_found -> {error, item_not_found}
                    end
            end;
        IdBin ->
            try
                ChId = binary_to_integer(IdBin),
                case mod_channel_backend:get_channel(HostType, ChId) of
                    {ok, #{server := LServer} = Ch} -> {ok, Ch};
                    _ -> {error, item_not_found}
                end
            catch _:_ -> {error, bad_request}
            end
    end.

normalize_handle(undefined) -> undefined;
normalize_handle(Bin) when is_binary(Bin) ->
    string:lowercase(Bin).

validate_create(Handle, Name, _Type) ->
    case is_valid_handle(Handle) of
        false -> {error, bad_request};
        true ->
            case is_valid_name(Name) of
                true -> ok;
                false -> {error, bad_request}
            end
    end.

is_valid_handle(undefined) -> false;
is_valid_handle(<<>>) -> false;
is_valid_handle(H) when is_binary(H), byte_size(H) >= 3, byte_size(H) =< 64 ->
    handle_chars_ok(H);
is_valid_handle(_) -> false.

handle_chars_ok(<<>>) -> true;
handle_chars_ok(<<C, Rest/binary>>) when (C >= $a andalso C =< $z)
                                  orelse (C >= $0 andalso C =< $9)
                                  orelse C =:= $_ orelse C =:= $- ->
    handle_chars_ok(Rest);
handle_chars_ok(_) -> false.

is_valid_name(undefined) -> false;
is_valid_name(<<>>) -> false;
is_valid_name(N) when is_binary(N), byte_size(N) =< 250 -> true;
is_valid_name(_) -> false.

is_valid_body(undefined) -> false;
is_valid_body(<<>>) -> false;
is_valid_body(B) when is_binary(B), byte_size(B) =< 16384 -> true;
is_valid_body(_) -> false.

bare_jid_bin(Jid) ->
    jid:to_binary(jid:to_bare(jid:to_lower(Jid))).

bare_jid_normalize(undefined) -> error;
bare_jid_normalize(Bin) when is_binary(Bin) ->
    case jid:from_binary(Bin) of
        error -> error;
        Jid -> {ok, jid:to_binary(jid:to_bare(jid:to_lower(Jid)))}
    end.

body_text(SubEl) ->
    exml_query:path(SubEl, [{element, <<"body">>}, cdata]).

default(undefined, D) -> D;
default(V, _) -> V.

bound(N, Lo, _Hi) when N < Lo -> Lo;
bound(N, _Lo, Hi) when N > Hi -> Hi;
bound(N, _, _) -> N.

is_in_admin_list(ChId, List) ->
    lists:any(fun(#{id := X}) -> X =:= ChId end, List).

%%%----------------------------------------------------------------------
%%% XML rendering
%%%----------------------------------------------------------------------

channel_summary_el(LServer, Ch, RoleBin) ->
    #xmlel{name = <<"channel">>,
           attrs = base_attrs(LServer, Ch, RoleBin),
           children = []}.

channel_full_el(LServer, Ch) ->
    Attrs = base_attrs(LServer, Ch, <<>>),
    Attrs1 = maps:remove(<<"role">>, Attrs),
    Attrs2 = Attrs1#{<<"xmlns">> => ?NS_CHANNEL,
                     <<"description">> => maps:get(description, Ch, <<>>),
                     <<"created_at">> =>
                         integer_to_binary(maps:get(created_at, Ch, 0))},
    #xmlel{name = <<"channel">>, attrs = Attrs2, children = []}.

base_attrs(LServer, Ch, RoleBin) ->
    Base = #{<<"id">> => integer_to_binary(maps:get(id, Ch)),
             <<"handle">> => maps:get(handle, Ch),
             <<"name">> => maps:get(name, Ch),
             <<"type">> => maps:get(channel_type, Ch, <<"public">>),
             <<"jid">> => channel_jid(LServer, maps:get(id, Ch))},
    case RoleBin of
        <<>> -> Base;
        _ -> Base#{<<"role">> => RoleBin}
    end.

history_msg_el(#{id := MsgId, sender := Sender, body := Body, sent_at := Sent}) ->
    #xmlel{name = <<"msg">>,
           attrs = #{<<"id">> => integer_to_binary(MsgId),
                     <<"sender">> => Sender,
                     <<"sent_at">> => integer_to_binary(Sent)},
           children = [#xmlel{name = <<"body">>, attrs = #{},
                              children = [#xmlcdata{content = Body}]}]}.

channel_jid(LServer, Id) ->
    <<?CHANNEL_PREFIX/binary, (integer_to_binary(Id))/binary, "@", LServer/binary>>.

%%%----------------------------------------------------------------------
%%% Error replies / bouncing
%%%----------------------------------------------------------------------

bounce(From, To, Packet, Acc, Reason) ->
    Err = make_error(Reason),
    ErrPacket = jlib:make_error_reply(Packet, Err),
    ejabberd_router:route(To, From, Acc, ErrPacket).

make_error(forbidden)             -> mongoose_xmpp_errors:forbidden();
make_error(item_not_found)        -> mongoose_xmpp_errors:item_not_found();
make_error(conflict)              -> mongoose_xmpp_errors:conflict();
make_error(bad_request)           -> mongoose_xmpp_errors:bad_request();
make_error(internal_server_error) -> mongoose_xmpp_errors:internal_server_error().

error_reply(#iq{sub_el = SubEl} = IQ, Reason) ->
    IQ#iq{type = error, sub_el = [SubEl, make_error(safe_reason(Reason))]}.

safe_reason(R) when R =:= forbidden;
                    R =:= item_not_found;
                    R =:= conflict;
                    R =:= bad_request;
                    R =:= internal_server_error -> R;
safe_reason(_) -> bad_request.