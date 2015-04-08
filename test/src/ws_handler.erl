-module(ws_handler).
-behaviour(cowboy_websocket_handler).

-export([init/3]).
-export([websocket_init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([websocket_terminate/3]).

-record(state, {
               count =1          :: integer(),
               cmd   = undefined :: any(),
               nodes =[]         :: [node()],
               data  = []        :: any()
              }).                        
%%The docs for the websocket behaviour can be found here: 
%% http://ninenines.eu/docs/en/cowboy/1.0/manual/cowboy_websocket_handler/

init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

%%%% Might want to change the atom to current app name
websocket_init(_TransportName, Req, _Opts) ->
    case whereis(ws_handler) of 
        undefined ->
            register(ws_handler, self());
        _ -> 
            unregister(ws_handler),
            register(ws_handler, self())
    end,
    {ok, Req, #state{}}.

%% This is called when data is recieved from the websocket.
%% Currently this just sends any data back to the client
websocket_handle({text, Msg}, Req, State) ->
    MsgStr=binary_to_list(Msg),
    FinalMsg = lists:concat(["Erlang received the message: ", MsgStr]),
    io:format("Replying with: ~p~n",[FinalMsg]),
%    {ok, Req, State};
%    {reply, {text, list_to_binary(FinalMsg)}, Req, State};
    {reply, {text, Msg}, Req, State};
websocket_handle(Data, Req, State) ->
    io:format("Msg recieved: ~p~n",[Data]),
    {ok, Req, State}.

%%Called when this process recieves an erlang message.
%%Currently this just sends those along to the client
websocket_info(Info,Req,State) -> 
    io:format("Got erlang message"),
%    MsgStr = lists:concat(["Erlang message: ", io_lib:format("~p",[Info])]),
    MsgStr =  io_lib:format("~p",[Info]),
    {reply, {text, list_to_binary(MsgStr)}, Req, State}.
    

websocket_terminate(_Reason, _Req, _State) ->
	ok.
