%%%-------------------------------------------------------------------
%%% @author jaspreetchhabra
%%% @copyright (C) 2026, Wingtrill
%%% @doc AI chatbot module for MongooseIM.
%%%
%%% Intercepts messages sent to a configured bot JID and forwards them
%%% to a configurable AI provider (Claude, OpenAI/ChatGPT, Gemini, or Groq)
%%% via a managed HTTP pool. Replies are routed back to the sender as
%%% regular chat messages.
%%%
%%% Configuration (mongooseim.toml):
%%%
%%%   [outgoing_pools.http.ai_bot]
%%%     scope = "global"
%%%     workers = 5
%%%     [outgoing_pools.http.ai_bot.connection]
%%%       host = "https://api.anthropic.com"   # or openai/gemini
%%%       path_prefix = "/v1"
%%%       request_timeout = 30000
%%%
%%%   [modules.mod_ai_bot]
%%%     provider = "claude"           # "claude" | "openai" | "gemini"
%%%     pool_tag = "ai_bot"
%%%     bot_username = "devbot"
%%%     api_key = "sk-ant-..."
%%%     model = "claude-sonnet-4-20250514"
%%%     max_tokens = 4096
%%% @end
%%%==============================================================================
-module(mod_ai_bot).

-behaviour(gen_mod).

-include("jlib.hrl").
-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, supported_features/0, config_spec/0, hooks/1]).

%% Hook handlers
-export([user_send_message/3, user_available/3]).

%%--------------------------------------------------------------------
%% gen_mod callbacks
%%--------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
start(_HostType, _Opts) ->
    case ets:info(ai_bot_rate_limit) of
        undefined ->
            ets:new(ai_bot_rate_limit, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ok
    end,
    ok.

-spec stop(mongooseim:host_type()) -> ok.
stop(_HostType) ->
    ok.

-spec supported_features() -> [atom()].
supported_features() ->
    [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
        items = #{
            <<"provider">> => #option{type = atom,
                                      validate = {enum, [claude, openai, gemini, groq]}},
            <<"pool_tag">> => #option{type = atom, validate = pool_name},
            <<"bot_username">> => #option{type = binary},
            <<"api_key">> => #option{type = binary},
            <<"model">> => #option{type = binary},
            <<"max_tokens">> => #option{type = integer, validate = positive},
            <<"system_prompt">> => #option{type = binary},
            <<"welcome_message">> => #option{type = binary}
        },
        defaults = #{
            <<"provider">> => claude,
            <<"bot_username">> => <<"devbot">>,
            <<"model">> => <<"claude-sonnet-4-20250514">>,
            <<"max_tokens">> => 4096,
            <<"system_prompt">> => default_system_prompt(),
            <<"welcome_message">> => <<"Hey! I'm your AI assistant. Ask me anything!">>
        },
        required = [<<"pool_tag">>, <<"api_key">>]
    }.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_message, HostType, fun ?MODULE:user_send_message/3, #{}, 50},
     {user_available, HostType, fun ?MODULE:user_available/3, #{}, 90}].

%%--------------------------------------------------------------------
%% Hook handlers
%%--------------------------------------------------------------------

-spec user_send_message(mongoose_acc:t(),
                        mongoose_c2s_hooks:params(),
                        gen_hook:extra()) ->
    mongoose_c2s_hooks:result().
user_send_message(Acc, _Params, #{host_type := HostType}) ->
    {_From, To, Packet} = mongoose_acc:packet(Acc),
    BotUsername = gen_mod:get_module_opt(HostType, ?MODULE, bot_username),
    case jid:to_lus(To) of
        {BotUsername, _Server} ->
            handle_bot_message(Acc, HostType, Packet);
        _ ->
            {ok, Acc}
    end.

%% Send a welcome message from the bot when user comes online
-spec user_available(mongoose_acc:t(), map(), gen_hook:extra()) ->
    {ok, mongoose_acc:t()}.
user_available(Acc, #{jid := UserJid}, #{host_type := HostType}) ->
    BotUsername = gen_mod:get_module_opt(HostType, ?MODULE, bot_username),
    WelcomeMsg = gen_mod:get_module_opt(HostType, ?MODULE, welcome_message),
    Server = UserJid#jid.lserver,
    BotJid = jid:make_noprep(BotUsername, Server, <<>>),
    send_reply(UserJid, BotJid, WelcomeMsg),
    {ok, Acc}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

-spec handle_bot_message(mongoose_acc:t(), mongooseim:host_type(), exml:element()) ->
    mongoose_c2s_hooks:result().
handle_bot_message(Acc, HostType, Packet) ->
    case exml_query:subelement(Packet, <<"body">>) of
        #xmlel{} = BodyElem ->
            Body = exml_query:cdata(BodyElem),
            {From, _To, _P} = mongoose_acc:packet(Acc),
            case check_rate_limit(From) of
                ok ->
                    process_bot_query(Acc, HostType, Body);
                rate_limited ->
                    send_reply(From, element(2, mongoose_acc:packet(Acc)),
                               <<"Please wait a moment before sending another message.">>),
                    {stop, Acc}
            end;
        undefined ->
            {ok, Acc}
    end.

-spec process_bot_query(mongoose_acc:t(), mongooseim:host_type(), binary()) ->
    mongoose_c2s_hooks:result().
process_bot_query(Acc, _HostType, <<>>) ->
    {ok, Acc};
process_bot_query(Acc, HostType, UserMessage) ->
    {From, To, _Packet} = mongoose_acc:packet(Acc),
    %% Spawn the API call in a separate process to avoid crashing the c2s process
    spawn(fun() ->
        try
            case call_ai_api(HostType, UserMessage) of
                {ok, ResponseText} ->
                    send_reply(From, To, ResponseText);
                {error, Reason} ->
                    ?LOG_ERROR(#{what => ai_bot_api_error,
                                 reason => Reason,
                                 host_type => HostType}),
                    ErrorMsg = <<"Sorry, I'm unable to process your request right now. Please try again later.">>,
                    send_reply(From, To, ErrorMsg)
            end
        catch
            Class:Error:Stack ->
                ?LOG_ERROR(#{what => ai_bot_crash,
                             class => Class,
                             reason => Error,
                             stacktrace => Stack,
                             host_type => HostType}),
                CrashMsg = <<"Sorry, something went wrong. Please try again.">>,
                send_reply(From, To, CrashMsg)
        end
    end),
    {stop, Acc}.

-spec call_ai_api(mongooseim:host_type(), binary()) ->
    {ok, binary()} | {error, any()}.
call_ai_api(HostType, UserMessage) ->
    Provider = gen_mod:get_module_opt(HostType, ?MODULE, provider),
    ApiKey = gen_mod:get_module_opt(HostType, ?MODULE, api_key),
    Model = gen_mod:get_module_opt(HostType, ?MODULE, model),
    MaxTokens = gen_mod:get_module_opt(HostType, ?MODULE, max_tokens),
    SystemPrompt = gen_mod:get_module_opt(HostType, ?MODULE, system_prompt),
    PoolTag = gen_mod:get_module_opt(HostType, ?MODULE, pool_tag),
    {Path, Headers, Payload} = build_request(Provider, ApiKey, Model, MaxTokens,
                                              SystemPrompt, UserMessage),
    case mongoose_http_client:post(global, PoolTag, Path, Headers, Payload) of
        {ok, {<<"200">>, RespBody}} ->
            parse_response(Provider, RespBody);
        {ok, {Code, RespBody}} ->
            ?LOG_WARNING(#{what => ai_bot_api_http_error,
                           provider => Provider,
                           response_code => Code,
                           response_body => RespBody,
                           host_type => HostType}),
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Provider-specific request builders
%%--------------------------------------------------------------------

-spec build_request(atom(), binary(), binary(), integer(), binary(), binary()) ->
    {binary(), [{binary(), binary()}], binary()}.
build_request(claude, ApiKey, Model, MaxTokens, SystemPrompt, UserMessage) ->
    Path = <<"/messages">>,
    Headers = [
        {<<"x-api-key">>, ApiKey},
        {<<"anthropic-version">>, <<"2023-06-01">>},
        {<<"content-type">>, <<"application/json">>}
    ],
    Payload = jiffy:encode(#{
        <<"model">> => Model,
        <<"max_tokens">> => MaxTokens,
        <<"system">> => SystemPrompt,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => UserMessage}
        ]
    }),
    {Path, Headers, Payload};

build_request(openai, ApiKey, Model, MaxTokens, SystemPrompt, UserMessage) ->
    Path = <<"/chat/completions">>,
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, <<"application/json">>}
    ],
    Payload = jiffy:encode(#{
        <<"model">> => Model,
        <<"max_tokens">> => MaxTokens,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => SystemPrompt},
            #{<<"role">> => <<"user">>, <<"content">> => UserMessage}
        ]
    }),
    {Path, Headers, Payload};

build_request(groq, ApiKey, Model, MaxTokens, SystemPrompt, UserMessage) ->
    Path = <<"/chat/completions">>,
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, <<"application/json">>}
    ],
    Payload = jiffy:encode(#{
        <<"model">> => Model,
        <<"max_tokens">> => MaxTokens,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => SystemPrompt},
            #{<<"role">> => <<"user">>, <<"content">> => UserMessage}
        ]
    }),
    {Path, Headers, Payload};

build_request(gemini, ApiKey, Model, _MaxTokens, SystemPrompt, UserMessage) ->
    Path = <<"/models/", Model/binary, ":generateContent?key=", ApiKey/binary>>,
    Headers = [
        {<<"content-type">>, <<"application/json">>}
    ],
    Payload = jiffy:encode(#{
        <<"system_instruction">> => #{
            <<"parts">> => [#{<<"text">> => SystemPrompt}]
        },
        <<"contents">> => [
            #{<<"parts">> => [#{<<"text">> => UserMessage}]}
        ]
    }),
    {Path, Headers, Payload}.

%%--------------------------------------------------------------------
%% Provider-specific response parsers
%%--------------------------------------------------------------------

-spec parse_response(atom(), binary()) -> {ok, binary()} | {error, any()}.
parse_response(Provider, RespBody) ->
    try
        parse_response_body(Provider, jiffy:decode(RespBody, [return_maps]))
    catch
        _:Reason ->
            ?LOG_ERROR(#{what => ai_bot_parse_error,
                         provider => Provider,
                         reason => Reason,
                         response_body => RespBody}),
            {error, {parse_error, Reason}}
    end.

-spec parse_response_body(atom(), map()) -> {ok, binary()}.
parse_response_body(claude, #{<<"content">> := Content}) ->
    Texts = [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Content],
    {ok, iolist_to_binary(lists:join(<<"\n">>, Texts))};

parse_response_body(openai, #{<<"choices">> := [#{<<"message">> := #{<<"content">> := Text}} | _]}) ->
    {ok, Text};

parse_response_body(groq, Response) ->
    parse_response_body(openai, Response);

parse_response_body(gemini, #{<<"candidates">> := [#{<<"content">> := #{<<"parts">> := Parts}} | _]}) ->
    Texts = [T || #{<<"text">> := T} <- Parts],
    {ok, iolist_to_binary(lists:join(<<"\n">>, Texts))}.

-define(RATE_LIMIT_MS, 3000).

-spec check_rate_limit(jid:jid()) -> ok | rate_limited.
check_rate_limit(From) ->
    Key = jid:to_bare_binary(From),
    Now = erlang:system_time(millisecond),
    case ets:lookup(ai_bot_rate_limit, Key) of
        [{_, LastTime}] when Now - LastTime < ?RATE_LIMIT_MS ->
            rate_limited;
        _ ->
            ets:insert(ai_bot_rate_limit, {Key, Now}),
            ok
    end.

-spec send_reply(jid:jid(), jid:jid(), binary()) -> mongoose_acc:t().
send_reply(OrigFrom, BotJid, ResponseText) ->
    ReplyEl = #xmlel{
        name = <<"message">>,
        attrs = #{
            <<"type">> => <<"chat">>,
            <<"from">> => jid:to_binary(BotJid),
            <<"to">> => jid:to_binary(OrigFrom),
            <<"id">> => mongoose_bin:gen_from_timestamp()
        },
        children = [
            #xmlel{name = <<"body">>,
                   children = [#xmlcdata{content = ResponseText}]},
            %% XEP-0334: no-store hint — prevents MAM from archiving bot messages
            #xmlel{name = <<"no-store">>,
                   attrs = #{<<"xmlns">> => <<"urn:xmpp:hints">>}},
            #xmlel{name = <<"no-permanent-store">>,
                   attrs = #{<<"xmlns">> => <<"urn:xmpp:hints">>}}
        ]
    },
    ejabberd_router:route(BotJid, OrigFrom,
                          mongoose_acc:new(#{from_jid => BotJid,
                                            to_jid => OrigFrom,
                                            location => ?LOCATION,
                                            lserver => BotJid#jid.lserver,
                                            element => ReplyEl})).

%%--------------------------------------------------------------------
%% Default system prompt
%%--------------------------------------------------------------------

-spec default_system_prompt() -> binary().
default_system_prompt() ->
    <<"You are a senior app development assistant. Help users with:\n"
      "- Generating Swift/Kotlin/Erlang code\n"
      "- Designing mobile and backend architectures\n"
      "- Debugging issues and reviewing code\n"
      "- Creating boilerplate and project scaffolding\n"
      "- CI/CD and deployment guidance\n"
      "Keep responses concise and code-focused. "
      "Use markdown formatting for code blocks.">>.
