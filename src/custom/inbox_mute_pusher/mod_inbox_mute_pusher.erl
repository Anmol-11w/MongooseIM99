%%%-------------------------------------------------------------------
%%% @author Wingtrill
%%% @copyright (C) 2026, Wingtrill
%%% @doc File    : mod_inbox_mute_pusher.erl
%%% Purpose : Suppress RabbitMQ (and any other `mod_event_pusher'
%%% backend's) push-notification events for muted Inbox
%%% (`erlang-solutions.com:xmpp:inbox:0') conversations, and attach the
%%% recipient's *total* unread count (across every conversation) as a
%%% `badge' field on every event that isn't suppressed.
%%%
%%% Neither `mod_event_pusher_rabbit' nor `mod_inbox' know about each
%%% other, so a muted 1:1 conversation would otherwise still trigger a
%%% push, and no event carries a badge count today. Rather than editing
%%% either core module, this hooks the shared `push_event' hook (fired
%%% once per event by `mod_event_pusher:push_event/2', ahead of every
%%% backend — rabbit, http, push, sns) at a lower priority than any
%%% backend (see `hooks/1'):
%%%
%%% <ul>
%%%   <li>If muted, returns `{stop, HookAcc}' — `gen_hook:run_hook/4'
%%%       stops calling any further, lower-priority-number handlers once
%%%       one returns `stop' (`gen_hook.erl:127,229-230'), so the event
%%%       never reaches `mod_event_pusher_rabbit' (or any other backend)
%%%       at all. The (more expensive) total-unread lookup is skipped
%%%       entirely in this case — no point computing a badge for an
%%%       event that never gets published.</li>
%%%   <li>Otherwise, stashes the recipient's total unread count onto
%%%       `HookAcc.metadata' under the key `badge', and — if the sender
%%%       has a phone number on file (`phone_contacts', populated by
%%%       `mod_contact_sync' from the JWT `phone_number' claim at login)
%%%       — the sender's phone number under `from_phone', so
%%%       `wingtrill-notifier' can show a phone number instead of a raw
%%%       JID as the notification title. `mod_event_pusher_rabbit'
%%%       already merges `metadata' into every published event's JSON
%%%       (`mod_event_pusher_rabbit.erl:129'), so both fields show up
%%%       automatically with no changes needed there either. `from_phone'
%%%       is simply omitted when the sender has no phone on file (e.g.
%%%       never authenticated via JWT) — the notifier falls back to the
%%%       JID in that case.</li>
%%% </ul>
%%%
%%% Badge caveat: this hook runs *before* `mod_inbox''s own
%%% `filter_local_packet' handler (priority 90 vs. the translator that
%%% triggers `push_event' at priority 80), which is what actually
%%% increments `unread_count' for the current message. So the total read
%%% here is *pre-this-message* — `badge' is reported as `total + 1`, a
%%% best-effort approximation (same approach many chat apps take
%%% server-side), not an authoritative count. The client's own next
%%% inbox fetch is the real reconciliation point.
%%%
%%% Caching: this hook runs on every 1:1 chat message, so both DB reads
%%% it needs are cached with a short, millisecond-granular TTL — a
%%% hand-rolled ETS table for each (NOT `mongoose_user_cache': its
%%% `time_to_live' option is in *minutes*, not seconds — a plain integer
%%% is passed straight to `timer:minutes/1' by `segmented_cache' — and its
%%% default segment/rotation model is meant for much longer-lived data
%%% than a live unread count; that mismatch caused a real bug in an
%%% earlier version of this module, where the badge stayed stuck far
%%% longer than intended):
%%% <ul>
%%%   <li>The per-conversation mute check (keyed by the `{recipient,
%%%       sender}' pair), TTL `mute_cache_ttl_ms'.</li>
%%%   <li>The aggregate total-unread count (keyed only by the recipient),
%%%       TTL `unread_cache_ttl_ms'. Every use also optimistically bumps
%%%       the cached value by 1 (see `unread_total/2'), but — critically —
%%%       preserves the *original* fetch timestamp rather than resetting
%%%       it on every bump. Resetting it would let a busy conversation
%%%       keep the cache perpetually "fresh" and never actually re-check
%%%       the database; preserving it guarantees a hard resync every
%%%       `unread_cache_ttl_ms' regardless of traffic.</li>
%%% </ul>
%%% Session (c2s) state was considered and ruled out for this: this hook
%%% runs in whatever process routed the message (typically the
%%% *sender's* c2s process, per `mongoose_local_delivery.erl'), not the
%%% recipient's, and an offline recipient has no c2s process at all.
%%%
%%% Scope: 1:1 chat only (stanza type=`chat', delivered-to-recipient
%%% direction, i.e. the `chat_msg_recv' / `chat_msg_exchange' case).
%%% Groupchat is intentionally out of scope: resolving the correct
%%% Inbox "remote" JID for a MUC message needs affiliation lookups
%%% (see `mod_inbox:muclight_enabled/1' and friends) that aren't safe
%%% to replicate here without risking a mismatched inbox row.
%%%
%%% Expects `mod_inbox' and `mod_event_pusher' to be enabled.
%%% @end
%%%-------------------------------------------------------------------
-module(mod_inbox_mute_pusher).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-include("mongoose_config_spec.hrl").
-include("mod_event_pusher_events.hrl").
-include("mongoose_logger.hrl").

-export([start/2, stop/1, hooks/1, supported_features/0, config_spec/0]).
-export([push_event/3]).

-ignore_xref([push_event/3]).

-define(MUTE_CACHE, inbox_mute_pusher_mute_cache).
-define(UNREAD_CACHE, inbox_mute_pusher_unread_cache).
-define(PHONE_CACHE, inbox_mute_pusher_phone_cache).
-define(UNREAD_TOTAL_QUERY, inbox_mute_pusher_unread_total).
-define(SENDER_PHONE_QUERY, inbox_mute_pusher_sender_phone).
-define(DEFAULT_MUTE_CACHE_TTL_MS, 2000).
-define(DEFAULT_UNREAD_CACHE_TTL_MS, 2000).
%% Phone numbers change far less often than unread counts/mute state, so a
%% much longer TTL is appropriate here.
-define(DEFAULT_PHONE_CACHE_TTL_MS, 60000).
%% Sentinel cached when a sender has no phone on file, so a repeated miss
%% doesn't re-query the DB every time within the TTL window.
-define(NO_PHONE, no_phone).

%%%----------------------------------------------------------------------
%%% gen_mod
%%%----------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(_HostType, _Opts) ->
    ensure_cache(?MUTE_CACHE),
    ensure_cache(?UNREAD_CACHE),
    ensure_cache(?PHONE_CACHE),
    mongoose_rdbms:prepare(?UNREAD_TOTAL_QUERY, inbox, [lserver, luser, box],
        <<"SELECT SUM(unread_count) FROM inbox WHERE lserver = ? AND luser = ? AND box = ?">>),
    mongoose_rdbms:prepare(?SENDER_PHONE_QUERY, phone_contacts, [server, username],
        <<"SELECT phone FROM phone_contacts WHERE server = ? AND username = ?">>),
    ok.

-spec stop(mongooseim:host_type()) -> any().
stop(_HostType) -> ok.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    %% Lower than every mod_event_pusher backend's push_event priority
    %% (rabbit is 50) so a `stop' here pre-empts all of them.
    [{push_event, HostType, fun ?MODULE:push_event/3, #{}, 10}].

-spec supported_features() -> [atom()].
supported_features() -> [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
        items = #{<<"mute_cache_ttl_ms">> => #option{type = integer, validate = positive},
                  <<"unread_cache_ttl_ms">> => #option{type = integer, validate = positive},
                  <<"phone_cache_ttl_ms">> => #option{type = integer, validate = positive}},
        defaults = #{<<"mute_cache_ttl_ms">> => ?DEFAULT_MUTE_CACHE_TTL_MS,
                     <<"unread_cache_ttl_ms">> => ?DEFAULT_UNREAD_CACHE_TTL_MS,
                     <<"phone_cache_ttl_ms">> => ?DEFAULT_PHONE_CACHE_TTL_MS}
    }.

%%%----------------------------------------------------------------------
%%% Hook handler
%%%----------------------------------------------------------------------

-spec push_event(HookAcc, Params, Extra) -> {ok | stop, HookAcc} when
      HookAcc :: mod_event_pusher:push_event_acc(),
      Params :: mod_event_pusher:push_event_params(),
      Extra :: gen_hook:extra().
push_event(HookAcc, #{event := Event}, #{host_type := HostType}) ->
    case mute_status(Event, HostType) of
        muted ->
            io:format("inbox_mute_pusher_check muted=true~n"),
            {stop, HookAcc};
        {not_muted, To, From} ->
            Total = unread_total(HostType, To),
            Phone = sender_phone(HostType, From),
            io:format("inbox_mute_pusher_check muted=false unread_total=~p badge=~p from_phone=~p~n",
                      [Total, Total + 1, Phone]),
            {ok, with_badge(with_phone(HookAcc, Phone), Total)};
        not_applicable ->
            {ok, HookAcc}
    end.

%% @private
-spec mute_status(mod_event_pusher:event(), mongooseim:host_type()) ->
    muted | {not_muted, jid:jid(), jid:jid()} | not_applicable.
mute_status(#chat_event{type = chat, direction = out, from = From, to = To}, HostType) ->
    case is_muted(HostType, To, From) of
        true -> muted;
        false -> {not_muted, To, From}
    end;
mute_status(_, _) ->
    not_applicable.

%% @private
%% Read-through ETS cache (TTL `mute_cache_ttl_ms', default 2s) in front of
%% `mod_inbox_backend:get_entry_properties/2' for the mute check alone.
-spec is_muted(mongooseim:host_type(), jid:jid(), jid:jid()) -> boolean().
is_muted(HostType, To, From) ->
    Key = mod_inbox_utils:build_inbox_entry_key(To, From),
    CacheKey = {jid:to_lus(To), jid:to_lus(From)},
    TtlMs = ttl_ms(HostType, mute_cache_ttl_ms, ?DEFAULT_MUTE_CACHE_TTL_MS),
    case cache_lookup(?MUTE_CACHE, CacheKey, TtlMs) of
        {ok, MutedUntil, _FetchedAtMs} ->
            MutedUntil > erlang:system_time(microsecond);
        miss ->
            MutedUntil = fetch_muted_until(HostType, Key),
            cache_put(?MUTE_CACHE, CacheKey, MutedUntil),
            MutedUntil > erlang:system_time(microsecond)
    end.

%% @private
-spec fetch_muted_until(mongooseim:host_type(), mod_inbox:entry_key()) -> integer().
fetch_muted_until(HostType, Key) ->
    case mod_inbox_backend:get_entry_properties(HostType, Key) of
        #{muted_until := MutedUntil} = Props when MutedUntil > 0 ->
            case MutedUntil > erlang:system_time(microsecond) of
                true -> MutedUntil;
                false ->
                    clear_expired_mute(HostType, Key, Props),
                    0
            end;
        _ ->
            0
    end.

%% @private
%% Read-through ETS cache (TTL `unread_cache_ttl_ms', default 2s) in front
%% of the total-unread SUM query, keyed only by the recipient.
%% `mod_inbox`'s own increment (a separate code path this module doesn't
%% observe) never invalidates this cache, so on every use the cached
%% value is also optimistically bumped to `Total + 1' — the message this
%% event represents — so a burst of messages within one TTL window
%% increments the badge locally (`total+1, total+2, total+3, ...') instead
%% of repeating the same stale value. Crucially, the bump preserves the
%% *original* fetch timestamp (does not reset the TTL clock), so this
%% still hard-resyncs with the database every `unread_cache_ttl_ms'
%% regardless of how much traffic keeps the entry "hot".
-spec unread_total(mongooseim:host_type(), jid:jid()) -> non_neg_integer().
unread_total(HostType, To) ->
    CacheKey = jid:to_lus(To),
    TtlMs = ttl_ms(HostType, unread_cache_ttl_ms, ?DEFAULT_UNREAD_CACHE_TTL_MS),
    case cache_lookup(?UNREAD_CACHE, CacheKey, TtlMs) of
        {ok, Total, FetchedAtMs} ->
            ets:insert(?UNREAD_CACHE, {CacheKey, Total + 1, FetchedAtMs}),
            Total;
        miss ->
            Total = fetch_unread_total(HostType, To),
            cache_put(?UNREAD_CACHE, CacheKey, Total + 1),
            Total
    end.

%% @private
-spec fetch_unread_total(mongooseim:host_type(), jid:jid()) -> non_neg_integer().
fetch_unread_total(HostType, To) ->
    {LUser, LServer} = jid:to_lus(To),
    Result = mongoose_rdbms:execute_successfully(
        HostType, ?UNREAD_TOTAL_QUERY, [LServer, LUser, <<"inbox">>]),
    case Result of
        {selected, [{null}]} -> 0;
        {selected, [{Sum}]} when is_integer(Sum) -> Sum;
        {selected, [{Sum}]} when is_binary(Sum) -> binary_to_integer(Sum);
        {selected, []} -> 0
    end.

%% @private
-spec with_badge(mod_event_pusher:push_event_acc(), non_neg_integer()) ->
    mod_event_pusher:push_event_acc().
with_badge(HookAcc = #{metadata := Metadata}, Total) ->
    HookAcc#{metadata := Metadata#{badge => Total + 1}}.

%% @private
%% Only attaches `from_phone' when one is on file — omitted entirely
%% otherwise, so `wingtrill-notifier' can fall back to the JID with a
%% simple `maps:get(<<"from_phone">>, Json, undefined)'.
-spec with_phone(mod_event_pusher:push_event_acc(), binary() | undefined) ->
    mod_event_pusher:push_event_acc().
with_phone(HookAcc, undefined) ->
    HookAcc;
with_phone(HookAcc = #{metadata := Metadata}, Phone) ->
    HookAcc#{metadata := Metadata#{from_phone => Phone}}.

%% @private
%% Read-through ETS cache (TTL `phone_cache_ttl_ms', default 60s — phone
%% numbers change far less often than unread counts) in front of
%% `phone_contacts', populated by `mod_contact_sync' from the JWT
%% `phone_number' claim at login. Returns `undefined' if the sender has
%% none on file (e.g. never authenticated via JWT).
-spec sender_phone(mongooseim:host_type(), jid:jid()) -> binary() | undefined.
sender_phone(HostType, From) ->
    CacheKey = jid:to_lus(From),
    TtlMs = ttl_ms(HostType, phone_cache_ttl_ms, ?DEFAULT_PHONE_CACHE_TTL_MS),
    case cache_lookup(?PHONE_CACHE, CacheKey, TtlMs) of
        {ok, ?NO_PHONE, _} ->
            undefined;
        {ok, Phone, _} ->
            Phone;
        miss ->
            case fetch_sender_phone(HostType, From) of
                undefined ->
                    cache_put(?PHONE_CACHE, CacheKey, ?NO_PHONE),
                    undefined;
                Phone ->
                    cache_put(?PHONE_CACHE, CacheKey, Phone),
                    Phone
            end
    end.

%% @private
-spec fetch_sender_phone(mongooseim:host_type(), jid:jid()) -> binary() | undefined.
fetch_sender_phone(HostType, From) ->
    {LUser, LServer} = jid:to_lus(From),
    Result = mongoose_rdbms:execute_successfully(
        HostType, ?SENDER_PHONE_QUERY, [LServer, LUser]),
    case Result of
        {selected, [{Phone}]} -> Phone;
        {selected, []} -> undefined
    end.

%% @doc Passive expiry (comparing `muted_until' against "now") never writes
%% anything back on its own, so a lapsed mute would otherwise sit in the
%% `inbox' row forever as stale data. Since we already fetched the row to
%% check it, opportunistically reset it to `0' here too.
-spec clear_expired_mute(mongooseim:host_type(), mod_inbox:entry_key(),
                         mod_inbox:entry_properties()) -> ok.
clear_expired_mute(HostType, Key, Props) ->
    case mod_inbox_backend:set_entry_properties(HostType, Key, Props#{muted_until => 0}) of
        {error, Reason} ->
            io:format("inbox_mute_pusher_clear_failed key=~p reason=~p~n", [Key, Reason]);
        _ ->
            ok
    end.

%%%----------------------------------------------------------------------
%%% Generic hand-rolled ETS TTL cache, shared by both caches above
%%%----------------------------------------------------------------------

%% @private
-spec ensure_cache(atom()) -> ok.
ensure_cache(Table) ->
    case ets:whereis(Table) of
        undefined -> ets:new(Table, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,
    ok.

%% @private
%% Returns the cached value AND its original fetch time, so callers that
%% need to bump the value (see `unread_total/2') can preserve it instead
%% of resetting the TTL clock on every write.
-spec cache_lookup(atom(), term(), integer()) -> {ok, term(), integer()} | miss.
cache_lookup(Table, Key, TtlMs) ->
    case ets:lookup(Table, Key) of
        [{Key, Value, FetchedAtMs}] ->
            case erlang:monotonic_time(millisecond) - FetchedAtMs < TtlMs of
                true -> {ok, Value, FetchedAtMs};
                false -> miss
            end;
        [] ->
            miss
    end.

%% @private
%% Stores a freshly-fetched value with a fresh timestamp (use only on a
%% cache miss — see `unread_total/2' for the bump-without-resetting path).
-spec cache_put(atom(), term(), term()) -> true.
cache_put(Table, Key, Value) ->
    ets:insert(Table, {Key, Value, erlang:monotonic_time(millisecond)}).

%% @private
-spec ttl_ms(mongooseim:host_type(), atom(), integer()) -> integer().
ttl_ms(HostType, OptKey, Default) ->
    gen_mod:get_module_opt(HostType, ?MODULE, OptKey, Default).
