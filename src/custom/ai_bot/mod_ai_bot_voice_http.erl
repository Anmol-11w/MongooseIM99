%%%-------------------------------------------------------------------
%%% @doc Cowboy handler for serving voice bot audio files.
%%%
%%% Serves audio files saved by mod_ai_bot_voice from a local directory.
%%%
%%% Configuration (mongooseim.toml):
%%%
%%%   [[listen.http.handlers.mod_ai_bot_voice_http]]
%%%     host = "_"
%%%     path = "/voice-audio"
%%%     audio_dir = "/tmp/voice_audio"
%%% @end
%%%-------------------------------------------------------------------
-module(mod_ai_bot_voice_http).

-behaviour(mongoose_http_handler).

-export([config_spec/0, routes/1]).

%% Cowboy handler callbacks
-export([init/2]).

-include("mongoose_config_spec.hrl").

%%--------------------------------------------------------------------
%% mongoose_http_handler callbacks
%%--------------------------------------------------------------------

config_spec() ->
    #section{
        items = #{
            <<"audio_dir">> => #option{type = string, validate = non_empty}
        },
        defaults = #{
            <<"audio_dir">> => "/tmp/voice_audio"
        }
    }.

routes(#{path := BasePath} = Opts) ->
    [{BasePath ++ "/:token", ?MODULE, Opts}].

%%--------------------------------------------------------------------
%% Cowboy handler
%%--------------------------------------------------------------------

init(Req0, #{audio_dir := AudioDir} = State) ->
    Token = cowboy_req:binding(token, Req0),
    FilePath = filename:join(AudioDir, Token),
    case file:read_file(FilePath) of
        {ok, Data} ->
            ContentType = content_type(Token),
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => ContentType,
                  <<"cache-control">> => <<"public, max-age=3600">>},
                Data, Req0),
            {ok, Req, State};
        {error, enoent} ->
            Req = cowboy_req:reply(404,
                #{<<"content-type">> => <<"text/plain">>},
                <<"Not found">>, Req0),
            {ok, Req, State}
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

content_type(Filename) ->
    case filename:extension(Filename) of
        <<".wav">> -> <<"audio/wav">>;
        <<".mp3">> -> <<"audio/mpeg">>;
        <<".ogg">> -> <<"audio/ogg">>;
        _ -> <<"application/octet-stream">>
    end.