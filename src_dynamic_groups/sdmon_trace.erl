%%%-------------------------------------------------------------------
%%% @author md504 <>
%%% @copyright (C) 2014, md504
%%% @doc
%%%
%%% @end
%%% Created :  7 Oct 2014 by md504 <>
%%%-------------------------------------------------------------------
-module(sdmon_trace).


%% API
-export([trace/4, trace/5, check/1, status/3, stop/3, stop_all/0]).
-import(sdmon, [log/2]).


-define(timeout, 5000).                 % for local calls


-compile([debug_info, export_all]).

%%%===================================================================
%%% API
%%%===================================================================

check([]) -> ok;

check({basic, []}) -> ok;
check({basic, _Args}) -> {error, invalid_trace_arg};

check({exec, {M,F,A}}) when is_atom(M), is_atom(F), is_list(A) -> ok;
check({exec, {F,A}}) when is_function(F), is_list(A) -> ok;
check({exec, _Args}) -> {error, invalid_trace_arg};

check({garbage_collection, []}) -> ok;
check({garbage_collection, [ttp]}) -> ok;
check({garbage_collection, _Args}) -> {error, invalid_trace_arg};

check({system_profile, []}) -> ok;
check({system_profile, _Args}) -> {error, invalid_trace_arg};

check({s_group, []}) -> ok;
check({s_group, _Args}) -> {error, invalid_trace_arg}.
	     

% trace(Node, Trace, VMrec) -> {ok, Result, StateChanges} | {Error, StaChanges}
% StateChanges are used by the caller (sdmon) to update the Node record.
% in sdmon (caller):
% -build_nodes vuole Pid x basic  
% -handle_worker_dead vuole {ok, [{worker,PID}]} to update status | Error 
% -trace vuole {ok, Result, StaeChanges} | {Error, StateChanges}

%% dbg vsn: Vedi devo_trace che pero' usa ip
%% percept2_profile usa dbg:trace_port x creare la porta che poi usa 
%% con erlang:trace e poi fa erlang:trace_pattern + erlang:trace 
%% con opzione {tracer, Port}
trace(Trace, VMrec,  GType, GName) ->
    trace(node(), Trace, VMrec, GType, GName).

trace(Node, Trace={basic, _StartArgs}, VMrec, _, _) ->
    case sdmon:get_worker(VMrec) of
	undefined ->
	    case net_kernel:connect_node(Node) of     % verifica stato reale
		true ->
		    Pid = start_worker(Node, Trace),
		    {ok, started, [{worker, Pid}]};
		_down ->
		    {{error, node_down}, [{state,down}]}
	    end;
	_ ->
	    {{error, trace_already_started}, []}
    end;

trace(Node, {exec, FUN}, VMrec, _, _) ->
    case sdmon:get_worker(VMrec) of
	undefined ->
	    case net_kernel:connect_node(Node) of     % verifica stato reale
		true ->
		    Pid = case FUN of 
			      {Fun, Args} -> spawn(Node, Fun, Args);
			      {M,F,A} -> spawn(M,F,A)
			  end,
		    {ok, started, [{worker, Pid}]};
		_down ->
		    {{error, node_down}, [{state,down}]}
	    end;
	_ ->
	    {{error, trace_already_started}, []}
    end;


trace(Node, {trace, Args}, _VMrec, GType, GName) ->
    case ckoptions(Args) of
	[] ->
	    {{error, bad_trace}, []};
	Opts ->
	init_s_group_trace(Node, GType, GName),
	case catch dbg:p(all, Opts) of
	    {ok, R} -> 
		{ok, started, [R]};
	    Error ->
		log("Node: ~p Tracer ERROR: ~p~n",[Node, Error]),
		{Error, [{state,down}]}
	end
    end;

trace(_, _,_,_,_) ->
    {{error, bad_trace}, []}.


re_trace(_Node, {basic, _StartArgs}, _VMrec) ->
    {ok, []};
re_trace(_Node, {exec, _FUN}, _VMrec) ->
    {ok, []};
re_trace(Node, {trace, Args}, _VMrec) ->
    case ckoptions(Args) of
	[] ->
	    {{error, bad_trace}, []};
	Opts ->
	re_init_s_group_trace(Node),
	case catch dbg:p(all, Opts) of
	    {ok, _R} -> 
		{ok, []};
	    Error ->
		log("Node: ~p Tracer ERROR: ~p~n",[Node, Error]),
		{Error, [{state,down}]}
	end
    end.


status(Node, {basic, _Args}, VMrec) ->
    case sdmon:get_conn_state(VMrec) of
	up ->
	    case sdmon:get_worker(VMrec) of
		undefined ->
		    {{error, trace_not_started}, []};
		Pid ->
		    Pid ! {self(), whatareudoing},
		    receive 
			{{Node,Pid}, What} ->
			    {ok, What, []};
			Other ->
			    {{error, Other}, []}
		    after ?timeout ->
			   {{error, node_not_responding}, [{state,down}]}	  
		    end
	    end;
	down ->
	    {{error, node_down}, []}
    end;

status(_Node, _Trace, _VMrec) ->
    {ok, todo, []}.
	    


stop_all() ->
    Nodes = get_all_nodes(),   
    lists:foreach(fun(Node) ->
		      dbg:stop_trace_client(get_ip_trace_client(Node)),
		      close_trace_file(Node) 
		  end, Nodes),
    delete_all(),
    dbg:stop_clear().
    
stop(Node, {basic, _Args}, VMrec) ->
    case sdmon:get_worker(VMrec) of
	undefined ->
	    {{error, trace_not_started}, []};
	Pid ->
	    Pid ! {self(), stoptracing},
	    receive 
		{{Node,Pid}, What} ->
		    {ok, What, [{worker,undefined}]};
		Other ->
		    {{error, Other}, []}
	    after ?timeout ->
		    {{error, node_not_responding},[state,down]}
	    end
    end;

stop(Node, {exec, _Args}, VMrec) ->
    case sdmon:get_worker(VMrec) of
	undefined ->
	    {{error, trace_not_started}, []};
	Pid ->
	    Pid ! {self(), stoptracing},
	    receive 
		{{Node,Pid}, What} ->
		    {ok, What, [{worker,undefined}]};
		Other ->
		    {{error, Other}, []}
	    after ?timeout ->
		    {{error, node_not_responding}, [state,down]}
	    end
    end;

%% stop(Node, {Type, _Args}, _VMrec) ->
%%     case options(Type) of
stop(Node, {trace, Args}, _VMrec) ->
    case ckoptions(Args) of
	[] ->
	    {{error, bad_trace}, []};
	Opts ->
	    case catch rpc:call(Node, erlang, trace, [all, false, Opts]) of
		Error={error,_} ->                 
		    log("RPC STOP ERROR: ~p~n",[Error]),
		    {Error, []};
		RES ->
		    dbg:stop_trace_client(delete_ip_trace_client(Node)),
		    close_trace_file(Node),
		    log("RPC STOP RESULT: ~p~n",[RES]),
		    dbg:cn(Node),
		    {ok, stopped, []} 
	    end           
    end.



start_worker(_Node, notrace) ->
    undefined;
start_worker(Node, Trace) ->
    SDmonPid = self(),
    PID = spawn_link(Node, sdmon_worker, init,[SDmonPid, Trace]),
    log("NODE ~p: Started worker ~p~n",[Node,PID]),
    PID.


re_init_s_group_trace(_Node) ->    
    MatchSpec = [{'_',[],[{return_trace}]}],
    {ok, _} = dbg:p(all, [call]),
    {ok, _} = dbg:tp({s_group,new_s_group,'_'},MatchSpec),
    {ok, _} = dbg:tp({s_group, delete_s_group, 1},MatchSpec),
    {ok, _} = dbg:tp({s_group, add_nodes, 2},MatchSpec),
    {ok, _} = dbg:tp({s_group, remove_nodes, 2},MatchSpec).

init_s_group_trace(Node, GType, GName) ->
    {_, FilePort} = open_trace_file(Node),
    MatchSpec = [{'_',[],[{return_trace}]}],
    Host = case Node of
	       nonode@nohost ->
		   {ok, H} = inet:gethostname(),
		   H;
	       _ ->
		   [_,H] = string:tokens(atom_to_list(Node),"@"),
		   H
	   end,
    case catch dbg:tracer(Node,port,dbg:trace_port(ip,0)) of
	{ok,Node} ->
	    {ok,Port} = dbg:trace_port_control(Node,get_listen_port),
	    {ok,_T} = dbg:get_tracer(Node),
	    Pid = dbg:trace_client(ip, {Host,Port}, 
			     mk_trace_parser({Node, self(), FilePort, GType, GName})),
	    store_ip_trace_client(Node, Pid);
	Other ->
	    Other
    end,
    {ok, _} = dbg:p(all, [call]),
    {ok, _} = dbg:tp({s_group,new_s_group,'_'},MatchSpec),
    {ok, _} = dbg:tp({s_group, delete_s_group, 1},MatchSpec),
    {ok, _} = dbg:tp({s_group, add_nodes, 2},MatchSpec),
    {ok, _} = dbg:tp({s_group, remove_nodes, 2},MatchSpec).

%from devo_trace.erl
mk_trace_parser({Node, Receiver, FilePort, GType, GName}) -> 
    {fun trace_parser/2, {Node, Receiver, FilePort, GType, GName}}.

% NOTE: executed by dbg process: one (on sdmon node) for each Node (ip port)
% inter_node (send option)
trace_parser(T={trace, From, send, Msg, To},{Node,Receiver,FilePort, GType, GName}) ->
    FromNode = get_node_name(From),
    ToNode = get_node_name(To),
    case FromNode/=node() andalso ToNode/=node() 
        andalso FromNode/=ToNode andalso 
        From/=nonode andalso To/=nonode of 
        true ->
            MsgSize = byte_size(term_to_binary(Msg)),
         %   Receiver ! Trace ={trace_inter_node, FromNode,ToNode, MsgSize},
	    to_file(FilePort, T),
	    to_file(FilePort, {trace_inter_node, FromNode,ToNode, MsgSize}),

	    GroupNodes = group_nodes(Node, GType),
	    case {get_group(FromNode, GroupNodes, GName), 
		  get_group(ToNode,   GroupNodes, GName)} of
		{Group, Group} ->        % intra-group message
		    goon;
		{FromGroup, ToGroup} ->  % inter-group message
		    to_file(FilePort, {trace_inter_group, FromGroup, ToGroup})
	    end;
        false ->
	    goon
    end,
    {Node, Receiver, FilePort, GType, GName};

trace_parser(T={trace_ts, From, send, Msg, To, TS}, 
	     {Node, Receiver, FilePort, GType, GName}) ->
    FromNode = get_node_name(From),
    ToNode = get_node_name(To),
    case FromNode/=node() andalso ToNode/=node() 
        andalso FromNode/=ToNode andalso 
        From/=nonode andalso To/=nonode of 
        true ->
            MsgSize = byte_size(term_to_binary(Msg)),
           % Receiver ! Trace={trace_inter_node, FromNode,ToNode, MsgSize},
	    to_file(FilePort, T),
	    to_file(FilePort, {trace_inter_node, FromNode,ToNode, MsgSize,TS}),
	    GroupNodes = group_nodes(Node, GType),
	    case {get_group(FromNode, GroupNodes, GName), 
		  get_group(ToNode,   GroupNodes, GName)} of
		{Group, Group} ->        % intra-group message
		    goon;
		{FromGroup, ToGroup} ->  % inter-group message
		    to_file(FilePort, {trace_inter_group, FromGroup, ToGroup})
	    end;
        false ->
	    goon
    end,
    {Node, Receiver, FilePort, GType, GName};


% scheduler (running option)
%% trace_parser(Trace={trace, Pid, in, Rq, _MFA}, 
trace_parser(Trace={trace, _Pid, in, _Rq, _MFA}, 
	     {Node, Receiver, FilePort, GType, GName}) ->
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort, GType, GName};
%%     case erlang:get({run_queue, Pid}) of 
%%         Rq ->
%%             {Node, Receiver, FilePort, GType, GName};
%%         undefined ->
%%             erlang:put({run_queue, Pid}, Rq),
%%             {Node, Receiver, FilePort, GType, GName};
%%         OldRq ->
%%             erlang:put({run_queue, Pid}, Rq),
%% %            Receiver!{trace_rq, OldRq, Rq},
%% %	    to_file(FilePort, {trace_rq, OldRq, Rq}),   % ???
%%             {Node, Receiver, FilePort, GType, GName}
%%     end;

%& trace_parser(Trace={trace_ts, Pid, in, Rq, _MFA, _TS}, 
trace_parser(Trace={trace_ts, _Pid, in, _Rq, _MFA, _TS}, 
	     {Node, Receiver,FilePort, GType, GName}) ->
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort, GType, GName};
%%     case erlang:get({run_queue, Pid}) of 
%%         Rq ->
%%             {Node, Receiver, FilePort, GType, GName};
%%         undefined ->
%%             erlang:put({run_queue, Pid}, Rq),
%%             {Node, Receiver, FilePort, GType, GName};
%%         OldRq ->
%%             erlang:put({run_queue, Pid}, Rq),
%% %            Receiver!{trace_rq, OldRq, Rq},
%% %	    to_file(FilePort, {trace_rq, OldRq, Rq}),   % ???
%%             {Node, Receiver, FilePort, GType, GName}
%%     end;


% s_group (call option + return_from MS)
trace_parser(Trace={trace_ts, _Pid, return_from, {s_group,Fun,_Arity}, Res, _Ts}, 
             {Node, Receiver, FilePort, GType, GName}) ->
    Args =  erase(Fun),
    case s_group_results(Fun, Args, Res) of
	ok ->
	    Receiver ! {s_group_change, Fun, Args};
	_ -> skip
    end,
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort, GType, GName};

trace_parser(Trace={trace, _Pid,  return_from, {s_group, Fun, _Arity}, Res}, 
             {Node, Receiver, FilePort, GType, GName}) ->
    log("TRACE_PARSER RECEIVED TRACE: ~p~n",[Trace]), 
    Args =  erase(Fun),
    case s_group_results(Fun, Args, Res) of
	ok ->
	    Receiver ! {s_group_change, Fun, Args};
	_ -> skip
    end,
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort, GType, GName};

trace_parser(Trace={trace_ts, _Pid, call, {s_group, Fun, Args}, _Ts}, 
             {Node, Receiver, FilePort, GType, GName}) ->
    put(Fun, Args),
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort, GType, GName};
trace_parser(Trace={trace, _Pid, call, {s_group, Fun, Args}}, 
             {Node, Receiver, FilePort, GType, GName}) ->
    log("TRACE_PARSER RECEIVED TRACE: ~p~n",[Trace]), 
    put(Fun, Args),
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort, GType, GName};

% all other traces
trace_parser(Trace, {Node, Receiver, FilePort, GType, GName}) ->
%    log("TRACE_PARSER RECEIVED UNKNOWN TRACE: ~p~n",[Trace]), 
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort, GType, GName}.



s_group_results(_Fun, undefined, _Res) -> error;
s_group_results(new_s_group, [NewSGroup, Nodes], {ok, NewSGroup, Nodes}) -> ok;
s_group_results(delete_s_group, [_SGroup], ok) -> ok;
s_group_results(add_nodes, [SGroup, _Nodes], {ok, SGroup, _NodesR}) -> ok;
s_group_results(remove_nodes, [_SGroup,_Nodes], ok) -> ok;
s_group_results(_Fun, _Args, _Res) -> error.
    


get_node_name({_RegName, Node}) ->    
    Node;
get_node_name(Arg) when is_atom(Arg) -> 
    get_node_name(whereis(Arg));
get_node_name(Arg) -> 
    try node(Arg) 
    catch _E1:_E2 ->
            nonode
    end.

group_nodes(Node, node) ->
    [Node];
group_nodes(Node, _GType) ->
    case sdmon:env_nodes() of
	{env_nodes, Nodes} ->
	    Nodes;
	_ ->         % maybe agent is under removal ??
	    [Node]
    end.

get_group(Node, GroupNodes, GName) ->
    case lists:member(Node, GroupNodes) of 
	true -> GName;
	_ -> Node
    end.	    
    

% from percept2_profile.erl (profile_to_file(FileSpec,Opts)
open_trace_file(Node) ->
    case get_file_port(Node) of 
	undefined ->
	    {ok,[[Home]]} = init:get_argument(home),
	    Dir = Home++"/SD-Mon/traces/"++atom_to_list(node()),
	    Prefix = Dir++"/"++atom_to_list(node())++"_traces_",
	    Postfix = "_"++atom_to_list(Node),
	    os:cmd("rm "++Prefix++"*"++Postfix),
	    os:cmd("mkdir " ++ Dir),

	    FileSpec ={Prefix, wrap, Postfix},
            
	    erlang:system_flag(multi_scheduling, block),
	    Port =  (dbg:trace_port(file, FileSpec))(),   
	    to_file(Port, {profile_start, erlang:now()}), % Send start time
            to_file(Port, {schedulers,erlang:system_info(schedulers)}),
	    erlang:system_flag(multi_scheduling, unblock),
		
	    store_file_port(Node, Port),
	    {ok, Port};
	Port ->
	    log("Profiling already started at port ~p.~n", [Port]),
	    {already_started, Port}
    end.

close_trace_file(Node) ->
    Port = get_file_port(Node),
    dbg:deliver_and_flush(Port),
    delete_file_port(Node),
    to_file(Port, {profile_stop, erlang:now()}),
    erlang:port_close(Port).

% decode binary and send it in a text file. To load it with file:consult
% pids, ports, funs and refs must be converted into lists (e.g. erlang:pid_to_list(Pid))
% into trace_parser clauses, before store in binary format. For future develepment.
decode_trace_file(Agent, Node) ->
    AgentStr = atom_to_list(Agent),
    NodeStr = atom_to_list(Node),
    {ok,[[Home]]} = init:get_argument(home),
    Dir = Home++"/SD-Mon/traces/"++AgentStr++"/",
    FileSpec ={Dir++AgentStr++"_traces_", wrap, "_"++NodeStr},
    TextFile = Dir++AgentStr++"_traces_"++NodeStr++".txt",
    {ok, Dev} = file:open(TextFile, [write]),
    Pid = dbg:trace_client(file, FileSpec, {fun file_parser/2, 
					    {self(), Dev, 0, 0, 0, 0, 0, [], [], 0}}),
    receive 
	{Pid, done, Count} ->
	    %dbg:stop_trace_client(Pid),
	    {done, Count}
    end.

file_parser(end_of_trace, {Caller, Dev, Count, IN, INsz, GR, GRsz, Nodes, Groups, _}) -> 
    io:format(Dev,"~n{total_entries, ~p}.~n",[Count]),
    io:format(Dev,"{inter_node, ~p, ~p}.~n",[IN, average(INsz,IN)]),
    io:format(Dev,"{inter_group, ~p, ~p}.~n",[GR, average(GRsz,GR)]),
    file:close(Dev),
    Caller ! {self(), done, Count};
file_parser(Trace={trace_inter_node, FromNode, ToNode, MsgSz}, 
	    {Caller, Dev, Count, IN, INsz, GR, GRsz, Nodes, Groups, _}) ->
    NewNodes = add_send_node(FromNode, ToNode, MsgSz, Nodes),
    io:format(Dev, "~p.~n", [Trace]),
    {Caller, Dev, Count+1, IN+1, INsz+MsgSz, GR, GRsz, NewNodes, Groups, MsgSz};
file_parser(Trace={trace_inter_group, FromGrups, ToGroups}, 
	    {Caller, Dev, Count, IN, INsz, GR, GRsz, Nodes, Groups, MsgSz}) ->
    NewGroups = add_send_group(FromGrups, ToGroups, MsgSz, Groups),
    io:format(Dev, "~p.~n", [Trace]),
    {Caller, Dev, Count+1, IN, INsz, GR+1, GRsz+MsgSz, Nodes, NewGroups, 0};
file_parser(Trace, {Caller, Dev, Count, IN, INsz, GR, GRsz, Nodes, Groups, MsgSz}) ->
    io:format(Dev, "~p.~n", [Trace]),
    {Caller, Dev, Count + 1, IN, INsz, GR, GRsz, Nodes, Groups, MsgSz}.
 
average(_,0) -> 0;
average(Sz, Tot) -> Sz/Tot.

add_send_node(FromNode, ToNode, MsgSz, Nodes) ->   
    case lists:keyfind(FromNode, 1, Nodes) of
	{FromNode, ToNodes} ->
	    case lists:keyfind(ToNode, 1, ToNodes) of
		{ToNode, Sz, Count} ->
		    NewToNodes = lists:keyreplace(ToNode, 1, ToNodes, {ToNode,Sz+MsgSz,Count+1});
		_ ->
		    NewToNodes = [{ToNode, MsgSz, 1} | ToNodes]
	    end,
	    lists:keyreplace(FromNode, 1, Nodes, {FromNode, NewToNodes});
	_ ->
	    [{FromNode, [{ToNode, MsgSz, 1}]} | Nodes]
    end.

add_send_group(FromGrups, ToGroups, MsgSz, Groups) ->   
    case lists:keyfind(FromGrups, 1, Groups) of
	{FromGrups, ToGs} ->
	    case lists:keyfind(ToGroups, 1, ToGs) of
		{ToGroups, Sz, Count} ->
		    NewToGs = lists:keyreplace(ToGroups, 1, ToGs, {ToGroups, Sz+MsgSz, Count+1});
		_ ->
		    NewToGs = [{ToGroups, MsgSz, 1} | ToGs]
	    end,
	    lists:keyreplace(FromGrups, 1, Groups, {FromGrups, NewToGs});
	_ ->
	    [{FromGrups, [{ToGroups, MsgSz, 1}]} | Groups]
    end.


store_file_port(Node, Port) ->
    put(Node, Port).
get_file_port(Node) ->
    get(Node).
delete_file_port(Node) ->
    erase(Node).

store_ip_trace_client(Node, Pid) ->
    put({ip_trace_client, Node}, Pid).
get_ip_trace_client(Node) ->
    get({ip_trace_client, Node}).
delete_ip_trace_client(Node) ->
    erase({ip_trace_client, Node}).

get_all_nodes() ->
     get_all_nodes(get(),[]).

get_all_nodes([], Nodes) ->
    Nodes;
get_all_nodes([{ip_trace_client, Node} | Rest], Nodes) ->
    get_all_nodes(Rest, Nodes ++ [Node]);
get_all_nodes([_|Rest], Nodes) ->
    get_all_nodes(Rest, Nodes).

delete_all() ->
    erase().


to_file(FilePort, Trace) ->
    erlang:port_command(FilePort, erlang:term_to_binary(Trace)).


%% options(Options) when is_list(Options) ->
%%     [options(Opt) || Opt <- Options];

options(garbage_collection) -> [garbage_collection];
options(inter_node) -> [send];
%options(inter_node) -> [m];
options(scheduler) -> [running];
options(system_profile) -> [];   % ??
options(_) -> [].
    
ckoptions(UserOpts) ->
    ckoptions(UserOpts,[]).
ckoptions([], Options) ->
    Options;
ckoptions([UO|T], Options) ->
    case options(UO) of
	[] ->
	    ckoptions([],[]);
	Opts ->
	    ckoptions(T, Options++Opts)
    end.
