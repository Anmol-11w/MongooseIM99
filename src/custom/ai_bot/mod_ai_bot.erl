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
-export([user_send_message/3]).

%%--------------------------------------------------------------------
%% gen_mod callbacks
%%--------------------------------------------------------------------

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
start(_HostType, _Opts) ->
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
            <<"system_prompt">> => #option{type = binary}
        },
        defaults = #{
            <<"provider">> => claude,
            <<"bot_username">> => <<"devbot">>,
            <<"model">> => <<"claude-sonnet-4-20250514">>,
            <<"max_tokens">> => 4096,
            <<"system_prompt">> => default_system_prompt()
        },
        required = [<<"pool_tag">>, <<"api_key">>]
    }.

-spec hooks(mongooseim:host_type()) -> gen_hook:hook_list().
hooks(HostType) ->
    [{user_send_message, HostType, fun ?MODULE:user_send_message/3, #{}, 50}].

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

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

-spec handle_bot_message(mongoose_acc:t(), mongooseim:host_type(), exml:element()) ->
    mongoose_c2s_hooks:result().
handle_bot_message(Acc, HostType, Packet) ->
    case exml_query:subelement(Packet, <<"body">>) of
        #xmlel{} = BodyElem ->
            Body = exml_query:cdata(BodyElem),
            process_bot_query(Acc, HostType, Body);
        undefined ->
            {ok, Acc}
    end.

-spec process_bot_query(mongoose_acc:t(), mongooseim:host_type(), binary()) ->
    mongoose_c2s_hooks:result().
process_bot_query(Acc, _HostType, <<>>) ->
    {ok, Acc};
process_bot_query(Acc, HostType, UserMessage) ->
    {From, To, _Packet} = mongoose_acc:packet(Acc),
    case call_ai_api(HostType, UserMessage) of
        {ok, ResponseText} ->
            send_reply(From, To, ResponseText),
            {stop, Acc};
        {error, Reason} ->
            ?LOG_ERROR(#{what => ai_bot_api_error,
                         reason => Reason,
                         host_type => HostType}),
            ErrorMsg = <<"Sorry, I'm unable to process your request right now. Please try again later.">>,
            send_reply(From, To, ErrorMsg),
            {stop, Acc}
    end.

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

-spec send_reply(jid:jid(), jid:jid(), binary()) -> ok.
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
                   children = [#xmlcdata{content = ResponseText}]}
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
