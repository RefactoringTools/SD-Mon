%%%-------------------------------------------------------------------
%%% @author md504 <>
%%% @copyright (C) 2014, md504
%%% @doc
%%%
%%% @end
%%% Created :  6 Oct 2014 by md504 <>
%%%-------------------------------------------------------------------
-module(sdmon_worker).
-compile([debug_info, export_all]).

%% API
-export([init/2, stop/1, get_state/1]).

-define(timeout, 5000).
%%%===================================================================
%%% API
%%%===================================================================

   
%% init(SDmonPid, {basic, []} ) ->
%%     loop(SDmonPid, {basic, []});

%% init(SDmonPid, Trace = {exec, [{M,F,Args}]}) ->
%%     Res = apply(M,F,Args),
%%     loop(SDmonPid, Trace);

%% init_worker(SDmonPid, Trace = {exec, {FUN, Args}}) ->
%%     Res = apply(FUN, Args),
%%     loop(SDmonPid, Trace);

init(SDMONPid, Trace) ->
%    process_flag(trap_exit, true),
%    loop(SDMONPid, sdmon_trace:trace(Trace)).
    loop(SDMONPid, Trace).

stop(Worker) ->
     Worker ! {self(), stop},
    receive 
	{ok, stopped} ->
	    {ok, stopped};
	Other ->
	    {error, Other}
    after ?timeout ->
	    timeout
    end.  

get_state(Worker) ->
    Worker ! {self(), get_state},
    receive 
	{ok, State} ->
	    {ok, State};
	Other ->
	    {error, Other}
    after ?timeout ->
	    timeout
    end.


%% init_worker(SDmonPid, {basic, []} ) ->
%% %    process_flag(trap_exit, true),
%%     % do something
%%     loop(SDmonPid, {basic, []});

%% %{erlang, trace_pattern,[{s_group,'_','_'},true,[global]]}
%% init_worker(SDmonPid, Trace = {exec, [{M,F,Args}]}) ->
%%     Res = apply(M,F,Args),
%%     sdmon_trace:log(Trace, Res),
%%     loop(SDmonPid, Trace);

%% init_worker(SDmonPid, Trace = {exec, {FUN, Args}}) ->
%%     Res = apply(FUN, Args),
%%     sdmon_trace:log(Trace, Res),
%%     loop(SDmonPid, Trace);

%% init_worker(_,Trace) ->
%%     sdmon_trace:log(Trace, "UNEXPECTED TRACE").

	 
%%%===================================================================
%%% Internal Functions
%%%===================================================================


loop(SDmonPid, Trace) -> 
    receive
	{From, whatareudoing} ->                     % to be removed
	    From ! {{node(), self()}, sometracing},
	    loop(SDmonPid, Trace);
	{From, get_state} ->
	    From ! {ok, Trace},
	    loop(SDmonPid, Trace);
	{From, stop} ->
	    sdmon_trace:stop(Trace),
	    From ! {ok, stopped},
	    unlink(SDmonPid);
	OTHER ->
	    sdmon_trace:log("Worker ~p Received MSG: ~p~n",[self(),OTHER]),
	    loop(SDmonPid, Trace)
    end.
