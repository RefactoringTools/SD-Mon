%%%-------------------------------------------------------------------
%%% @author md504 <>
%%% @copyright (C) 2014, md504
%%% @doc
%%%
%%% @end
%%% Created :  7 Oct 2014 by md504 <>
%%%-------------------------------------------------------------------
-module(sdmon).


%% API
-export([start/1, get_state/1, stop/1]).
-export([env_nodes/1, add_monitor_node/2, rem_monitor_node/2]).
-export([trace_node/3, add_and_trace/3, restart_trace/2, last_token/2]).

%% For sdmon local test, i.e. called from local sdmon shell
-export([get_state/0, stop/0]).
-export([env_nodes/0, add_monitor_node/1, rem_monitor_node/1]).
-export([start_trace/3, stop_trace/2, trace_status/2]).

%% For internal use
-export([direct_monitor/4]).

-define(timeout, 5000).                 % for local calls
-define(timeoutext, 3000).              % for remote calls

-define(LOGDIR, "/SD-Mon/logs/").

-record(vmrec, {node, state=down, worker, dmon=no}).

-record(state, {master, type, gname, trace=notrace, nodes=[], token, groups}).

% to be done. token = init (from master) or Ref (make_ref())
% or better integer from 0 (at init) to MaxInt
% associated to persistent changes (no conn status): nodes/traces
% updated at each change and sent to master at each s_group change 
% if master does not match (old +1) ask for whole conf (to be done) otherwise
% updates it, dumps on files and stores it for Agent.
% At conn_up master sends token, if not updated  agent sends whole conf

-compile([debug_info, export_all]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts SD Monitor
%%
%% @spec start(Config_File) -> _
%% @end
%%--------------------------------------------------------------------

start([MasterNodeStr]) ->
    MasterNode = list_to_atom(MasterNodeStr),
    register(node(), self()),
    process_flag(trap_exit, true),
    init_log(),
    log("SDMON Master Node =~p~n",[MasterNode]),
    {Type, GName, Trace, Nodes, Token, Groups} = get_config_from_master(MasterNode),
    log("Received configuration: ~p~n",[{Type, GName, Trace, Nodes, Token, Groups}]),
    loop(build_state({MasterNode, Type, GName, Trace, Nodes, Token, Groups})).



get_config_from_master(MasterNode) ->
    case  catch sdmon_master:init_conf(MasterNode) of
    	{ok, {Type, GName, Trace, Nodes, Token, Groups}} ->
	    {Type, GName, Trace, Nodes, Token, Groups};
	_ ->                            % {'EXIT',{{nodedown,... can occur
	    receive after 3000 -> get_config_from_master(MasterNode) end
    end.

%%--------------------------------------------------------------------
%% @doc
%% Invalid token received at nodeup: stop_tracing and rebuild State
%%
%% @spec sync(State) -> New State 
%% @end
%%--------------------------------------------------------------------
sync(State) ->
    log("Sync with Master: START...~n",[]),
    MasterNode = get_master(State),
    {Type, GName, Trace, Nodes, Token, Groups} = get_config_from_master(MasterNode),
    sdmon_trace:stop_all(),
    log("Received configuration: ~p~n",[{Type, GName, Trace, Nodes, Token, Groups}]),
    NewState = build_state({MasterNode, Type, GName, Trace, Nodes, Token, Groups}),
    log("Sync with Master: END~n",[]),
    NewState.
    

%%--------------------------------------------------------------------
%% @doc
%% Returns monitored Nodes
%%
%% @spec env_node() -> {env_nodes, Nodes} | timeout | {badrpc, Reason} 
%% @end
%%--------------------------------------------------------------------
%y

env_nodes() ->               % for local test only (called from sdmon shell)
    env_nodes(node()).       % also called by sdmon_trace

env_nodes(SDMON) ->
    case to_sdmon(SDMON, env_nodes, []) of
	{env_nodes, Nodes} -> {env_nodes, Nodes};
	Other -> Other
    end.
%%--------------------------------------------------------------------
%% @doc
%% Returns Internal States
%%
%% @spec get_state(SDMON_Node) -> #state{} | timeout | {badrpc, Reason} 
%% @end
%%--------------------------------------------------------------------
%y
get_state() ->               % for local test only (called from sdmon shell)
    get_state(node()).

get_state(SDMON) ->
    case to_sdmon(SDMON, get_state, []) of
	{state, State} -> State;
	Other -> Other
    end.



%%--------------------------------------------------------------------
%% @doc
%% called by master at nodeup to sync configuration
%%
%% @spec last_token(SDMON_Node, Token) -> ok (async) 
%% @end
%%--------------------------------------------------------------------
last_token(Token) ->      % for local test only (called from sdmon shell)
    last_token(node(), Token).

last_token(SDMON, Token) ->
    to_sdmon_async(SDMON, last_token, [Token]),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Starts monitoring a given Node
%%
%% @spec add_monitor_node(SDMON_Node, Node) -> ok | {error, Reason} 
%% @spec                                          | timeout | {badrpc, Reason} 
%% @end
%%--------------------------------------------------------------------
%y needed ?
add_monitor_node(Node) ->      % for local test only (called from sdmon shell)
    add_monitor_node(node(), Node).

add_monitor_node(SDMON, Node) ->
    case to_sdmon(SDMON, add_monitor_node, [Node]) of
	{monitor, ok} -> ok;
	Other ->  Other
    end.


%%--------------------------------------------------------------------
%% @doc
%% Stops monitoring a given Node
%%
%% @spec rem_monitor_node(SDMON_Node, Node) -> ok | {error, Reason} 
%% @spec                                          | timeout | {badrpc, Reason}
%% @spec Reason = [node_down | node_not_responding]
%% @end
%%--------------------------------------------------------------------
%y needed ?
rem_monitor_node(Node) ->      % for local test only (called from sdmon shell)
    rem_monitor_node(node(), Node).

rem_monitor_node(SDMON, Node) ->
    case to_sdmon(SDMON, rem_monitor_node, [Node]) of
	{demonitor, ok} -> ok;
	Other ->  Other
    end.

%%--------------------------------------------------------------------
%% @doc
%% Add and trace new nodes dynamically
%%
%% @spec add_and_trace(SDMON_Node, Nodes, Token) -> ok | {error, Reason} 
%% @spec                                          | timeout | {badrpc, Reason}
%% @spec Reason = [node_down | node_not_responding]
%% @end
%%--------------------------------------------------------------------
add_and_trace(Nodes, Token) ->    % for local test only (called from sdmon shell)
    add_and_trace(node(), Nodes, Token).

add_and_trace(SDMON, Nodes, Token) ->
    case to_sdmon(SDMON, add_and_trace, [Nodes, Token]) of
	ok -> ok;
	Other ->  Other
    end.

%%--------------------------------------------------------------------
%% @doc
%% Add and trace new nodes dynamically
%%
%% @spec add_and_trace(SDMON_Node, Nodes, Token) -> ok | {error, Reason} 
%% @spec                                          | timeout | {badrpc, Reason}
%% @spec Reason = [node_down | node_not_responding]
%% @end
%%--------------------------------------------------------------------
untrace_and_remove(Nodes, Token) ->    % for local test only (
    untrace_and_remove(node(), Nodes, Token).

untrace_and_remove(SDMON, Nodes, Token) ->
    case to_sdmon(SDMON,  untrace_and_remove, [Nodes, Token]) of
	ok -> ok;
	Other ->  Other
    end.

%%--------------------------------------------------------------------
%% @doc
%% Add Restart trace on nodes previously traced by another deleted agent
%%
%% @spec restart_trace(SDMON_Node, Nodes) -> ok  (async)
%% @end
%%--------------------------------------------------------------------
restart_trace(Nodes) ->    % for local test only 
   restart_trace(node(), Nodes).

restart_trace(SDMON, Nodes) ->
    to_sdmon_async(SDMON,  restart_trace, [Nodes]),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Apply a tracing function to a given Node
%%
%% @spec trace(SDMON_Node, Node, Arg) -> Result | {error, Reason}
%% @spec                                        | timeout | {badrpc, Reason}
%% @spec Arg = {Type, Action, [ActionArgs] | {exec, {Mod, Fun, Args}}]
%% @spec Type = [basic | todo]
%% @spec Action = [start | status | stop]
%% @spec Reason = [bad_trace | trace_already_started | trace_not_started 
%% @spec           unknown_node | node_down | node_not_responding]
%% @end 
%%--------------------------------------------------------------------
start_trace(Node, Trace) ->   % for local test only (called from sdmon shell)
    trace_node(node(), Node, start, Trace).
start_trace(SDMON, Node, Trace) ->
    trace_node(SDMON, Node, start, Trace).

stop_trace(Node) ->   % for local test only (called from sdmon shell)
    trace_node(node(), Node, stop, []).
stop_trace(SDMON, Node) ->
    trace_node(SDMON, Node, stop, []).

trace_status(Node) ->   % for local test only (called from sdmon shell)
    trace_node(node(), Node, status, []).
trace_status(SDMON, Node) ->
    trace_node(SDMON, Node, status, []).

trace_node(Node, Action, Arg) -> % for local test only (called from sdmon shell)
    trace_node(node(), Node, Action, Arg).
trace_node(SDMON, Node, Action, Trace) ->
    case sdmon_trace:check(Trace) of
	ok ->
	   case to_sdmon(SDMON, trace_node, [Node, Action, Trace]) of
	       {trace_node, Result} ->  Result;
	       Other ->  Other
	   end;
	Error ->
	    Error
    end.



stop() ->                   % for local test only (called from sdmon shell)
    stop(node()).

stop(SDMON) ->
    to_sdmon(SDMON, stop, []).
	 
%%%===================================================================
%%% Internal Functions
%%%===================================================================

s_group_change(SDMON, Fun, Args) ->
  SDMON ! {s_group_change, Fun, Args}.

loop(State) ->
    receive
        {From, get_state, []} ->
	    From ! {state, State},
	    loop(State);

        {From, env_nodes, []} ->
	    From ! {env_nodes, get_nodes(State)},
	    loop(State);

        {From, add_monitor_node, [Node]} ->
	    case add_monitor(Node, State) of
		{ok, NewState} -> 
		    From ! {monitor, ok},
	 	    loop(NewState);
		Error ->
		    From ! Error,
		    loop(State)
		end;

	{From, rem_monitor_node, [Node]} ->
	    case rem_monitor(Node, State) of
		{ok, NewState} -> 
		    From ! {demonitor, ok},
		    loop(NewState);
		Error ->
		    From ! Error,
		    loop(State)
		end; 

	{From, add_and_trace, [Nodes, Token]} ->
	    case add_trace(Nodes, Token, State) of
		{ok, NewState} -> 
		    From !  ok,
		    loop(NewState);
		Error ->
		    From ! Error,
		    loop(State)
		end; 

	{From, untrace_and_remove, [Nodes, Token]} ->
	    case untrace_remove(Nodes, Token, State) of
		{ok, NewState} -> 
		    From !  ok,
		    loop(NewState);
		Error ->
		    From ! Error,
		    loop(State)
		end; 

	{_From, restart_trace, [Nodes]} ->
	    case re_trace(Nodes, State) of
		{ok, NewState} -> 
		    loop(NewState);
		{Error, NewState} ->
		    log("Restart trace ERROR: ~p~n",[Error]),
		    loop(NewState)
		end; 

        {From, trace_node, [Node, Action, Arg]} ->
	    case catch trace(Node, Action, Arg, State) of
		{ok, Result, NewState} -> 
		    From ! {trace_node, Result},
		    loop(NewState);
		{Error, NewState} ->
		    From ! Error,
		    loop(NewState)
		end;

	{s_group_change, Fun, Args} ->
	    sdmon_master:s_group_change(State#state.master, Fun, Args),
	    loop(State);

	{_From, last_token, [Token]} ->
	    case get_token(State) of
		Token -> 
		    log("TOKEN OK~n",[]),
		    loop (State);
		_ ->
		    loop(sync(State))
	    end;

	{nodeup, Node} ->
	    loop(handle_node_up(Node, State));

	{nodedown, Node} ->
	    loop(handle_node_down(Node, State));

	{'EXIT', Pid, Reason} ->
	    loop(handle_worker_dead(Pid, Reason, State));

	 {_From, stop, _Arg} ->
	    terminate(State),
	    log("TERMINATED (stop called)~n",[]),
	    stop;
	
	OTHER -> 
	    log("#-SDMON-#  RECEIVED UNEXPECTED MESSAGE: ~p~n",[OTHER]),
	    loop(State)
    end.


    
add_monitor(Node, State) ->
    case get_node_rec(Node, State) of
	no_node ->
	    erlang:monitor_node(Node, true),
	    case net_kernel:connect_node(Node) of 
		true -> ConnState = up;
		_ -> ConnState = down
	    end,
	    {ok, add_node(Node, ConnState, State)};
	_VMrec -> 
	    {error, already_monitored}
    end.



rem_monitor(Node, VMs) ->
    case get_node_rec(Node, VMs) of
	no_node ->
	    {error, unknown_node};
	VMrec ->
	    case VMrec#vmrec.worker of
		undefined ->
		    erlang:monitor_node(Node, false),
		    erlang:disconnect_node(Node),
		    stop_direct_monitoring(VMrec#vmrec.dmon),
		    {ok, rem_node(Node, VMs)};
		_Pid ->
		    {error, tracing_ongoing}
	    end		
    end.

% Always return ok with final State. erros on single nodes are reported in states
add_trace(Nodes, Token, State) ->
    % fun always returns new State
    AddTrace = fun(Node, LoopState) ->
		       case add_monitor(Node, LoopState) of
			   {ok,  NewLoopState} ->
			       Trace = get_trace(NewLoopState),
			       case trace(Node, start, Trace, NewLoopState) of
				   {ok, _Res, FinalLoopState} ->
				       FinalLoopState;
				   {_Error, FinalLoopState} ->
				       FinalLoopState
			       end;
			   _ ->
			       LoopState
		       end
	       end,
    NewState = lists:foldl(AddTrace, State, Nodes),
    {ok, update_token(Token, NewState)}.

% Always return ok with final State. erros on single nodes are reported in states
untrace_remove(Nodes, Token, State) ->
    UnTraceRem = fun(Node, LoopState) ->
			 case trace(Node, stop, nil, LoopState) of
			     {ok, _Res, NewLoopState} ->
				 NewLoopState;
			     {_Error, NewLoopState} ->
				 NewLoopState
			 end,
		         case rem_monitor(Node, NewLoopState) of
			     {ok, FinalLoopState} ->
				 FinalLoopState;
			     _ ->
				 NewLoopState
			 end
		    end,
    NewState = lists:foldl(UnTraceRem, State, Nodes),
    {ok, update_token(Token, NewState)}.


re_trace(Nodes, State) ->
    ReTrace = 
	fun(Node, LoopState) ->
		case get_node_rec(Node, LoopState) of
		    no_node ->
			LoopState;
		    VMrec ->
			case net_kernel:connect_node(Node) of 
			    true ->
				Trace = get_trace(LoopState),
				{_, StateChanges} = 
				    sdmon_trace:re_trace(Node, Trace, VMrec),
				update_status(Node, StateChanges, LoopState);
			    _down ->
				update_status(Node, [{state,down}], LoopState)
			end
		end
	end,
    {ok, lists:foldl(ReTrace, State, Nodes)}.
    

trace(Node, start, Trace, State) -> 
    case get_node_rec(Node, State) of
	no_node ->
	    {{error, unknown_node}, State};
	VMrec ->
	    case net_kernel:connect_node(Node) of     % verifica stato reale
		true ->
		    case sdmon_trace:trace(Node, Trace, VMrec, get_groups(State)) of
			{ok, Result, StateChanges} ->
			    {ok, Result, update_status(Node, StateChanges,State)};
			{Error, StateChanges} ->
			    {Error, update_status(Node, StateChanges, State)}
		    end;
		_down ->
		    {{error, node_down}, 
		         update_status(Node, [{state,down}], State)}
	    end
    end;

trace(Node, status, _, State) ->
    case get_node_rec(Node, State) of
	no_node ->
	    {{error, unknown_node}, State};
	VMrec ->
	    case sdmon_trace:status(Node, get_trace(State), VMrec) of
		{ok, Result, StateChanges} ->
		    {ok, Result, update_status(Node, StateChanges, State)};
		{Error, StateChanges}->
		    {Error, update_status(Node, StateChanges, State)}
	    end
    end;
	    

trace(Node, stop, _, State) ->
    case get_node_rec(Node, State) of
	no_node ->
	    {{error, unknown_node}, State};
	VMrec ->
	    case sdmon_trace:stop(Node, get_trace(State), VMrec) of
		{ok, Result, StateChanges} ->
		    log("NODE ~p: Stopped trace~n",[Node]),
		    {ok, Result, update_status(Node, StateChanges, State)};
		{Error, StateChanges}->
		    {Error, update_status(Node, StateChanges, State)}
	    end
    end.


sd_mon_NODE() ->
    {ok,Host} = inet:gethostname(),
    list_to_atom("sdmon@"++Host).
 

terminate(_VMs) ->
    sdmon_trace:stop_all().

%%%===================================================================
%%% Internal state handling
%%%===================================================================
%y
build_state({MasterNode, Type, GName, Trace, Nodes, Token, Groups})  ->
    #state{master=MasterNode, type=Type, gname=GName, trace=Trace, groups=Groups,
	   nodes=build_nodes(Trace, Nodes, Groups, []), token=Token};
build_state(MasterNode) ->
    #state{master=MasterNode}.

%y
build_nodes( _, [], _,  Recs) ->
    Recs;
build_nodes(Trace, [Node | Nodes], Groups, Recs) ->
    log("BUILDING NODE: ~p~n",[Node]),
    case lists:keyfind(Node, #vmrec.node, Recs) of
	false ->
	    erlang:monitor_node(Node, true),
	    VMrec = case net_kernel:connect_node(Node) of 
			true -> 
			    case sdmon_trace:trace(Node, Trace, #vmrec{}, Groups) of
			      {ok, _, [{worker,PID}]} ->
				    log("Node ~p traced. Worker:~p~n",[Node,PID]),
			    	    #vmrec{node=Node, state=up, worker=PID};
			      {ok, _, [R]} ->
				    log("Node ~p traced. Result: ~p~n",[Node,R]),
			    	    #vmrec{node=Node, state=up};
			       R ->
			    	    log("Node ~p NOT traced: ~p~n",[Node,R]),
			    	     #vmrec{node=Node, state=up}
			    end;
			_ -> 
			    log("Node ~p NOT traced: node down~n",[Node]),
			    #vmrec{node=Node}
		    end,
	    build_nodes(Trace, Nodes, Groups, Recs++[VMrec]);
	_  ->                              % Double entry: discard it
	    build_nodes(Trace, Nodes, Groups, Recs)
    end.


%y
get_nodes(State) ->
    [VMrec#vmrec.node || VMrec <- State#state.nodes].
%y    
get_node_rec(Node, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	    no_node;
	VMrec ->
	    VMrec
    end.
%y
add_node(Node, ConnState, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	   State#state{nodes=State#state.nodes ++ 
			   [#vmrec{node=Node, state=ConnState}]};
	Oldrec ->
	   State#state{nodes=lists:keyreplace(Node, #vmrec.node, 
					      State#state.nodes, 
					      Oldrec#vmrec{state=ConnState})}
    end.
%y
rem_node(Node, State) ->
    State#state{nodes=lists:keydelete(Node, #vmrec.node, State#state.nodes)}.

%non serve: non affidabile, last known state
%y
get_conn_state(#vmrec{state=ConnState}) ->
    ConnState.
get_conn_state(Node, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	    no_node;
	Oldrec ->
	   Oldrec#vmrec.state
    end.	
%y
change_conn_state(Node, ConnState, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	    State;
	Oldrec ->
	    State#state{nodes=lists:keyreplace(Node, #vmrec.node, 
					       State#state.nodes, 
					       Oldrec#vmrec{state=ConnState})}
    end.	
    
get_master(State) ->
    State#state.master.
get_trace(State) ->
    State#state.trace.
get_token(State) ->
    State#state.token.
get_group_type(State) ->
    State#state.type.
get_group_name(State) ->
    State#state.gname.
get_groups(State) ->
    State#state.groups.

update_trace(Trace, State) ->
    State#state{trace=Trace}.

update_token(Token, State) ->
    State#state{token=Token}.
%y
update_status(VMrec=#vmrec{node=Node}, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	    State;
	_Oldrec ->
	    State#state{nodes=lists:keyreplace(Node, #vmrec.node, 
					       State#state.nodes, VMrec)}
    end.
%y
update_status(Node, NewStatusTuples, State) ->
    case get_node_rec(Node, State) of
	no_node ->
	    State;
	VMrec ->
	    NewVMrec = update_rec(VMrec, NewStatusTuples),
%	    log("Oldrec=~p  Newrec=~p~n",[VMrec, NewVMrec]),
	    State#state{nodes=lists:keyreplace(Node, #vmrec.node, 
					       State#state.nodes, NewVMrec)} 
    end.

update_rec(VMrec, []) ->
    VMrec;
update_rec(VMrec, [{state, Value} | StatusTuples]) ->
    update_rec(VMrec#vmrec{state = Value}, StatusTuples);
update_rec(VMrec, [{worker, Value} | StatusTuples]) ->
    update_rec(VMrec#vmrec{worker = Value}, StatusTuples);
%% update_rec(VMrec, [{trace, Value} | StatusTuples]) ->
%%      update_rec(VMrec#vmrec{trace = Value}, StatusTuples);
update_rec(VMrec, [{dmon, Value} | StatusTuples]) ->
    update_rec(VMrec#vmrec{dmon = Value}, StatusTuples).    
    
%unused
add_worker(Node, Pid, _Trace, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	    State;
	Oldrec ->
	    State#state{nodes=lists:keyreplace(Node, #vmrec.node, 
					       State#state.nodes, 
					       Oldrec#vmrec{worker=Pid})}
    end.	


rem_worker(Node, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	    State;
	Oldrec ->
	    State#state{nodes=lists:keyreplace(Node, #vmrec.node, 
					       State#state.nodes, 
					       Oldrec#vmrec{worker=undefined})}
    end.	

%y
get_worker(#vmrec{worker=Worker})->
    Worker.

get_worker(Node, State) ->
    case lists:keyfind(Node, #vmrec.node, State#state.nodes) of
	false ->
	    no_node;
	VMrec ->
	    VMrec#vmrec.worker
    end.

%%%===================================================================
%%% Handling of remote transitions
%%%===================================================================
%% Losing the connection to the node causes an EXIT signal with reason
%% 'noconnection'. The link is broken and, since the worker does not trap exits,
%% it dies. So in current implementation worker is always restarted at nodeup.
%% If we allow it trapping exits it can survive to the node disconnection, and 
%% we can avoid to restart it when connection is restablished. 
%% To do that we shoud:
%% 1. Trap exits on the worker
%% 2. handle EXIT with Reason=noconnection as nodedown (handle_node_down)
%% 3. Check if the worker is still alive at nodeup (e.g. with rpc:pinfo/2)
%% On the other hand, trapping exit on worker means it never dies even if sdmon 
%% is restarted, cause there is no way for it to understand if there is a temporary
%% connection problem or if the sdmon node has been killed. So when sdmon starts 
%% it just spawns a new worker, leaving the old one alive.
%% Unless the workers are store permanently (DETS ?) and retrieved at sdmon start.
%% TO BE CONSIDERED FOR FUTURE IMPROVEMENTS

handle_worker_dead(_Pid, noconnection, State) ->   % will be followed by nodedown
    State;
handle_worker_dead(Pid, Reason, State) ->    % best effort, fails if node down
    case lists:keyfind(Pid, #vmrec.worker, State#state.nodes) of
	false ->
	    State;
	Oldrec ->    
	    Node = Oldrec#vmrec.node, {TraceType, Args} = State#state.trace,
	    case Reason of
		normal ->
		    log("NODE ~p:  Worker ~p exited with Reason: ~p~n",
		        [Node, Pid, normal]),
		    rem_worker(Node,State);
		_ ->
		    log("NODE ~p: Crashed worker ~p with Reason: ~p~n",
		        [Node, Pid, Reason]),
		    case sdmon_trace:trace(Node, {TraceType,Args}, Oldrec, na) of
			{ok, _Result, StateChanges} ->
			    update_status(Node, StateChanges, State);
			{ERROR, _StateChanges}->
			    log("Not restarted worker because of: ~p~n",[ERROR]),
			    rem_worker(Node, State)
		    end
	    end
    end.
%y	  
handle_node_up(Node, State) ->
    case get_node_rec(Node, State) of
	no_node ->           % Notification from a not monitored node !!
	    State;             % Just discard it
	VMrec ->
	    log("NODE ~p: went UP ~n",[Node]),
	    case net_kernel:connect_node(Node) of 
		true ->     
		    erlang:monitor_node(Node, false),   % to handle Node restart
		    erlang:monitor_node(Node, true),    % avoiding  many nodedown 
		                                        % for not restarted nodes
		    PID = start_worker_if_needed(VMrec, State#state.trace),
		    update_status(VMrec#vmrec{state=up, worker=PID, dmon=no}, 
				  State);
		_ ->          % up-down transition
		    log("NODE ~p: went DOWN ~n",[Node]),
		    DMon = start_direct_monitoring(Node,VMrec#vmrec.dmon),
		    update_status(VMrec#vmrec{state=down, dmon=DMon}, State)
	    end
    end.
%y
handle_node_down(Node, State) ->
    case get_node_rec(Node, State) of
	no_node ->           % Notification from a not monitored node !!
	    State;             % Just discard it
	VMrec ->
	    log("NODE ~p: went DOWN ~n",[Node]),
	    case net_kernel:connect_node(Node) of 
		true ->      % down-up transition
		    PID = start_worker_if_needed(VMrec, State#state.trace),
		    log("NODE ~p: went UP ~n",[Node]),
		    update_status(VMrec#vmrec{state=up, worker=PID}, State);
		_ ->          %  Status confirmed to down
		    DMon = start_direct_monitoring(Node,VMrec#vmrec.dmon),
		    update_status(VMrec#vmrec{state=down, dmon=DMon}, State)
	    end
    end.
	      
start_direct_monitoring(Node, no) ->          
    log("#-SDMON-#  Start Monitoring NODE ~p ...~n", [Node]),
    spawn(sdmon, direct_monitor, [self(), Node, 1, 60]);

start_direct_monitoring(_, Dmon) ->            % Monitoring already in place
    Dmon.


stop_direct_monitoring(Dmon) when is_pid(Dmon)->
    Dmon ! {sdmon, stop};
stop_direct_monitoring(_) ->
    no_dmon.
		  
%%% Makes a log printout every Logtreshold cycles (e.g. every 60 secs)
%%% until the node is up (eg: restarted) or it is demonitored.
%y
direct_monitor(SdmonPid, Node, N, LogTreshold) ->
    case net_adm:ping(Node) of
	pong ->
	    SdmonPid ! {nodeup, Node};
	_ ->
	    receive
		{sdmon, stop} ->
		    NewN = stop
	    after 1000 ->
		    if N==LogTreshold ->
		       log("~p Keep on Monitoring NODE ~p ...~n",[self(), Node]),
		       NewN=1;
		    true ->
		       NewN = N+1
		    end
	    end,
	    direct_monitor(SdmonPid, Node, NewN, LogTreshold)
    end.
	        
    
%%%===================================================================
%%%  Workers functions
%%%===================================================================
%y
% called by handle_node_up/down 
start_worker_if_needed(#vmrec{node=Node, worker=PID}, Trace) ->
    case {PID, Trace} of 
	{undefined, notrace} ->      % trace not configured
	    PID;
	{undefined, Trace} ->        % first time nodeup: start worker
	    _NewPID = start_worker(Node, Trace);
	_ ->                         % worker already started
	    case rpc:pinfo(PID,status) of
		undefined ->             % worker not alive 
		    _NewPID = start_worker(Node, Trace);
		_ ->                     % worker alive
		   log("Worker ~p is still alive~n",[PID]),
		    PID
	    end
    end.



start_worker(_Node, notrace) ->
    undefined;
start_worker(Node, Trace) ->
    SDmonPid = self(),
    PID = spawn_link(Node, sdmon_worker, init,[SDmonPid, Trace]),
    log("NODE ~p: Started worker ~p~n",[Node,PID]),
    PID.



	    
%%%===================================================================
%%% Auxiliary Functions
%%%===================================================================
init_log() ->
    NodeName = atom_to_list(node()),
    {ok,[[HOME]]} = init:get_argument(home),
    LOGFILE = HOME ++ ?LOGDIR++NodeName++".log",
    os:cmd("mv " ++ LOGFILE ++ " " ++ LOGFILE++".old"),
    log("#-SDMON ~p-#  Started~n",[NodeName]).

log(String, Args) ->  
    NodeName = atom_to_list(node()),
    {ok,[[HOME]]} = init:get_argument(home),
    LOGFILE = HOME ++ ?LOGDIR++NodeName++".log",
    {ok, Dev} = file:open(LOGFILE, [append]),
    io:format(Dev, "~p~p: "++String,[date(),time()|Args]),
    file:close(Dev).



to_sdmon(Node, Req, Args) ->           
    if Node == node() ->                % local call
	node() ! {self(),Req, Args},
	    receive
		Reply ->  Reply
	    after ?timeout ->
		    timeout
	    end;
       true ->                          % remote call
	     rpc:call(Node, sdmon, Req, Args)
    end.

to_sdmon_async(Node, Req, Args) ->           
    if Node == node() ->                % local call
	node() ! {self(),Req, Args};
       true ->                          % remote call
	     rpc:cast(Node, sdmon, Req, Args)
    end.

%% from run_env
term_to_list(Term) ->
    lists:flatten(io_lib:write(Term)).

list_to_term(String) ->
    {ok, T, _} = erl_scan:string(String ++ "."),
    case erl_parse:parse_term(T) of
        {ok, Term} ->
            Term;
        {error, Error} ->
            Error
    end.
