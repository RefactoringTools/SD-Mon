%% @private
-module(sdmon_web_app).
-behaviour(application).

%% API.
-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
    Dispatch = 
        cowboy_router:compile([
                               {'_', [
                                      {"/", toppage_handler, []},
                                      {"/websocket", ws_handler, []},
                                      {"/static/[...]", cowboy_static,
                                       {dir, "priv/static"}}]}]),
    {ok, _} = cowboy:start_http(http, 100, [{port, 8080}],
                                    [{env, [{dispatch, Dispatch}]}]),
    sdmon_web_sup:start_link().

stop(_State) ->
	ok.
