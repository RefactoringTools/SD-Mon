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
-export([trace/2, trace/3, check/1, status/3, stop/3, stop_all/0]).
-import(sdmon, [log/2]).

-define(timeout, 5000).                 % for local calls
-define(wrapsz,  128*1024).             % Bytes, default = 128*1024 = 128 kB
-define(wrapcnt, 16).                   % Number of binaries, default = 8

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
trace(Trace, VMrec) ->
    trace(node(), Trace, VMrec).

trace(Node, Trace={basic, _StartArgs}, VMrec) ->
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

trace(Node, {exec, FUN}, VMrec) ->
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


trace(Node, {trace, Args}, _VMrec) ->
    case ckoptions(Args) of
	[] ->
	    {{error, bad_trace}, []};
	Opts ->
	init_s_group_trace(Node),
	case catch dbg:p(all, Opts) of
	    {ok, R} -> 
		{ok, started, [R]};
	    Error ->
		log("Node: ~p Tracer ERROR: ~p~n",[Node, Error]),
		{Error, [{state,down}]}
	end
    end;

trace(_, _,_) ->
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

init_s_group_trace(Node) ->
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
			     mk_trace_parser({Node, self(), FilePort})),
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
mk_trace_parser({Node, Receiver, FilePort}) -> 
    {fun trace_parser/2, {Node, Receiver, FilePort}}.

% NOTE: executed by dbg process: one (on sdmon node) for each Node (ip port)
% inter_node (send option)
trace_parser({trace, From, send, Msg, To},{Node,Receiver,FilePort}) ->
    FromNode = get_node_name(From),
    ToNode = get_node_name(To),
    case FromNode/=node() andalso ToNode/=node() 
        andalso FromNode/=ToNode andalso 
        From/=nonode andalso To/=nonode of 
        true ->
            MsgSize = byte_size(term_to_binary(Msg)),

	    Receiver ! {in, FromNode, ToNode},

	    to_file(FilePort, {trace_inter_node, FromNode,ToNode, MsgSize}),
	    FromGroups = sdmon:get_node_groups(FromNode),
	    ToGroups = sdmon:get_node_groups(ToNode),
	    case FromGroups--ToGroups of
		FromGroups ->       % Disjoined, no common groups, inter_group msg
		    to_file(FilePort, {trace_inter_group, FromGroups, ToGroups});
		_ ->                % at least 1 common group, intra_group msg
		    goon
	    end;
        false ->
	    goon
    end,
    {Node, Receiver, FilePort};

trace_parser({trace_ts, From, send, Msg, To, _TS}, {Node, Receiver, FilePort}) ->
    FromNode = get_node_name(From),
    ToNode = get_node_name(To),
    case FromNode/=node() andalso ToNode/=node() 
        andalso FromNode/=ToNode andalso 
        From/=nonode andalso To/=nonode of 
        true ->
            MsgSize = byte_size(term_to_binary(Msg)),
	    Receiver ! {in, FromNode, ToNode},
	    to_file(FilePort, {trace_inter_node, FromNode, ToNode, MsgSize}),
	    FromGroups = sdmon:get_node_groups(FromNode),
	    ToGroups = sdmon:get_node_groups(ToNode),
	    case FromGroups--ToGroups of
		FromGroups ->      % Disjoined, no common groups, inter_group msg
		    to_file(FilePort, {trace_inter_group, FromGroups, ToGroups});
		_ ->                  % at least 1 common group, intra_group msg
		    goon
	    end;
        false ->
	    goon
    end,
    {Node, Receiver, FilePort};

% scheduler (running option)
trace_parser(Trace={trace, _Pid, in, _Rq, _MFA}, {Node, Receiver, FilePort}) ->
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort};

trace_parser(Trace={trace_ts, _Pid, in, _Rq, _MFA, _TS}, 
	     {Node, Receiver, FilePort}) ->
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort};


% s_group (call option + return_from MS)
trace_parser(Trace={trace_ts, _Pid, return_from, {s_group,Fun,_Arity}, Res, _Ts}, 
             {Node, Receiver, FilePort}) ->
    Args =  erase(Fun),
    case s_group_results(Fun, Args, Res) of
	ok ->
	    Receiver ! {s_group_change, Fun, Args};
	_ -> skip
    end,
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort};

trace_parser(Trace={trace, _Pid,  return_from, {s_group, Fun, _Arity}, Res}, 
             {Node, Receiver, FilePort}) ->
    log("TRACE_PARSER RECEIVED TRACE: ~p~n",[Trace]), 
    Args =  erase(Fun),
    case s_group_results(Fun, Args, Res) of
	ok ->
	    Receiver ! {s_group_change, Fun, Args};
	_ -> skip
    end,
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort};

trace_parser(Trace={trace_ts, _Pid, call, {s_group, Fun, Args}, _Ts}, 
             {Node, Receiver, FilePort}) ->
    put(Fun, Args),
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort};
trace_parser(Trace={trace, _Pid, call, {s_group, Fun, Args}}, 
             {Node, Receiver, FilePort}) ->
    log("TRACE_PARSER RECEIVED TRACE: ~p~n",[Trace]), 
    put(Fun, Args),
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort};

% all other traces
trace_parser(Trace, {Node, Receiver, FilePort}) ->
%    log("TRACE_PARSER RECEIVED UNKNOWN TRACE: ~p~n",[Trace]), 
    to_file(FilePort, Trace),
    {Node, Receiver, FilePort}.



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
    

% from percept2_profile.erl (profile_to_file(FileSpec,Opts)
open_trace_file(Node) ->
    case get_file_port(Node) of 
	undefined ->
	    Dir = sdmon:basedir()++"/SD-Mon/traces/"++atom_to_list(node()),
	    Prefix = Dir++"/"++atom_to_list(node())++"_traces_",
	    Postfix = "_"++atom_to_list(Node),
	    os:cmd("rm "++Prefix++"*"++Postfix),
	    os:cmd("mkdir " ++ Dir),

	    FileSpec ={Prefix, wrap, Postfix, ?wrapsz, ?wrapcnt},
            
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

% decode binary and send it in a text file. 
decode_traces(Dir=[$/|_]) ->          % absolute path from user   
    {ok, Files} =  file:list_dir(Dir),
    Agents = lists:sort([File || File <- Files, not(lists:suffix("txt", File))]),
    lists:foreach(fun(Agent) -> decode_agent(Dir++Agent) end, Agents),
    analyze(Dir),
    io:format("Statistics available in directory ~p~n",[Dir]);

decode_traces(TraceDir) ->             % traces directory, called from master
    decode_traces(sdmon:basedir()++"/SD-Mon/traces/"++TraceDir++"/").
 

decode_agent(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    case lists:member("STATISTICS.txt", Files) of
	true ->                % already decoded in terminate
	    skip;
	_ ->
	    Bins = [File || File <- Files, not(lists:suffix("txt", File))],
	    AgxNds = lists:sort(nodup([{Ag, NodeStr} || [_,Ag,_,_,NodeStr] <- 
				      [string:tokens(Bin,"_") || Bin <- Bins]])), 
	    InitialStats = {0, 0, 0, 0, 0, [], [], 0},
	    {Count, IN, INsz, IG, IGsz, NxN, GxG, _MsgSz} =
		lists:foldl(
		  fun({Ag, NodeStr}, Stats) ->
			  AgentStr = "sdmon_"++Ag,
			  case Stats of
			      InitialStats ->     % first run for the Agent
				  Agent = list_to_atom(AgentStr),
				  io:format("Decoding trace files for agent ~p~n",
					    [Agent]);
			      _ ->
				  goon
			  end,
			  io:format("~p~n",[list_to_atom(NodeStr)]),
			  FileSpec = 
			     {Dir++"/"++AgentStr++"_traces_", wrap, "_"++NodeStr,
			      ?wrapsz, ?wrapcnt},
			  TextFile = 
			      Dir++"/"++AgentStr++"_traces_"++NodeStr++".txt",
			  {ok, Dev} = file:open(TextFile, [write]),
			  dbg:trace_client(file, FileSpec, {fun file_parser/2,
						 {self(), Dev, Stats}}),
			  receive 
			      {done, NewStats} ->
				  NewStats
			  end
		  end, InitialStats, AgxNds),
	    {ok, DevSt} = file:open(Dir++"/STATISTICS.txt", [write]),
	    io:format(DevSt,"~n{total_entries, ~p}.~n",[Count]),
	    io:format(DevSt,"{inter_node, ~p, ~p}.~n",[IN, average(INsz,IN)]),
	    io:format(DevSt,"{inter_group, ~p, ~p}.~n",[IG, average(IGsz,IG)]),
	    io:format(DevSt,"{nodes, ~p}.~n",[sort_stats(NxN)]),
	    io:format(DevSt,"{groups, ~p}.~n",[sort_stats(GxG)]),
	    file:close(DevSt)
    end.

analyze(Dir) ->  
    STATFILES = lists:reverse(lists:sort(
		      filelib:fold_files(Dir, "STATISTICS.txt", true, 
			    fun(F, AccIn) -> 
				 case lists:suffix("GLOBAL_STATISTICS.txt", F) of
				     true -> AccIn;
				     _ ->  [F | AccIn]
				 end 
			    end, []))),
    AgStats = [Stats || {ok, Stats} <- [file:consult(File) || File <- STATFILES]],
    {ok,[[{_,[{s_groups, SGroups}, {global_groups, GGroup}]}]]} = 
	file:consult(sdmon:basedir()++"/SD-Mon/config/group.config"),
    Groups = [{G, Nds} || {G,_,Nds} <- SGroups++GGroup],
    SYSSTATS = aggregate(AgStats),
    SumData = get_sum_data(SYSSTATS, Groups),
    {ok, Dev} = file:open(Dir++"/GLOBAL_STATISTICS.txt", [write]),
    io:format(Dev, "{group_partition, ~p}.~n~n",[Groups]),    
    io:format(Dev, "~p.~n~n",[SYSSTATS]),
    lists:foreach(fun(El) -> io:format(Dev, "~p.~n~n",[El]) end, SumData),
    file:close(Dev).

get_sum_data(SYSSTATS, Groups) ->
    NodeGroups = node_groups(Groups, []),
    AllGNames = [[] | [GName ||{GName, _} <- Groups]], % also include freenodes
    AllNodes = [Node ||{Node, _} <- NodeGroups],
    {nodes, NxN} = lists:keyfind(nodes, 1 ,SYSSTATS),
    NodeFlows = lists:map(fun(N) -> 
				  flow(N, AllGNames, AllGNames, NxN, NodeGroups) 
			  end, AllNodes),
    Bridges = [{NG, Gs} || {NG, Gs} <- NodeGroups, length(Gs) > 1],
    BridgeFlow = lists:map(fun({N, Gs}) -> 
				   flow(N, Gs, Gs, NxN, NodeGroups)
			   end, Bridges),
    SentTab = sent_tab(NxN, NodeGroups),
    Max_IN_sender = lists:foldl(fun({F,{_,IN},_}, {MaxF,MaxIN}) ->
				       case IN > MaxIN of
					   true -> {F,IN};
					   _ -> {MaxF,MaxIN}
				       end 
				end, {nonode,0}, SentTab),
    [{node_flow, NodeFlows}, {bridge_nodes, Bridges}, {bridge_flow, BridgeFlow},
     {sent_tab, SentTab}, {max_internode_sender, Max_IN_sender}].


sent_tab(NxN, NGs) ->
    sent_tab(NxN, NGs, []).
sent_tab([], _, SentTab) ->
    SentTab;
sent_tab([{From, Tos}|NxN], NGs, Tab) ->
    INTot = lists:foldl(fun({_,S,C}, {TS, TC}) -> {TS+S,TC+C} end, {0,0}, Tos),
    FromGs = get_nodegroups(From, NGs),
    IGTos = [{To, Sz, Count} || {To, Sz, Count} <- Tos,
    				FromGs--get_nodegroups(To, NGs) == FromGs],
    IGTot = lists:foldl(fun({_,S,C}, {TS, TC}) -> {TS+S,TC+C} end, {0,0}, IGTos), 
    sent_tab(NxN, NGs, Tab ++ [{From, INTot, IGTot}]).
    

    
%% Return {Node, IN, AvIN, OUT, AvOUT} where:
%% IN = incoming messages to Node sent by nodes belonging to groups FGs
%% OUT = outogoing messages from Node sent to nodes belonging to groups TGs
%% AvIN, AvOUT = Average message size.

flow(Node, FGs, TGs, NxN, NGs) ->    
    flow(Node, FGs, TGs, NxN, NGs, 0, 0, 0, 0).
flow(Node, _FGs, _TGs, [], _NGs, IN, AvIN, OUT, AvOUT) ->
    {Node, IN, AvIN, OUT, AvOUT};
flow(Node, FGs, TGs, [{Node, Tos}|NxN], NGs, IN, AvIN, OUT, AvOUT) ->
    {NewOUT, NewAvOUT} = outgoing(TGs, Tos, NGs, OUT, AvOUT),
    flow(Node, FGs, TGs, NxN, NGs, IN, AvIN, NewOUT, NewAvOUT);
flow(Node, FGs, TGs, [{From, Tos}|NxN], NGs, IN, AvIN, OUT, AvOUT) ->
    {NewIN, NewAvIN} = incoming(Node, FGs, From, Tos, NGs, IN, AvIN),
    flow(Node, FGs, TGs, NxN, NGs, NewIN, NewAvIN, OUT, AvOUT).

outgoing(_TGs, [], _NGs, OUT, AvOUT) ->
    {OUT, AvOUT};
outgoing(TGs, [{Node, Sz, Count} |Tos], NGs, OUT, AvOUT) ->
    NodeGroups = get_nodegroups(Node, NGs),
    case TGs -- NodeGroups of
	TGs ->    % disjoined, this node is external to the receiver groups, skip
%	    io:format("DISCARDED: N=~p, S=~p C=~p, TGs=~p, NG=~p~n",
%		      [Node, Sz, Count,TGs, NodeGroups]),
	    outgoing(TGs, Tos, NGs, OUT, AvOUT);
	_  ->     % this node belongs to at least 1 allowed receiver group 
	    outgoing(TGs, Tos, NGs, OUT+Count, round((AvOUT*OUT+Sz)/(OUT+Count)))
    end.

incoming(_Node, _FGs, _From, [], _NGs, IN, AvIN) ->
    {IN, AvIN};
incoming(Node, FGs, From, [{Node, Sz, Count} |Tos], NGs, IN, AvIN) ->
    FromGroups =  get_nodegroups(From, NGs),
    case FGs -- FromGroups of
	FGs ->   % disjoined, this node is external to the sender groups, skip
	    incoming(Node, FGs, From, Tos, NGs, IN, AvIN);
	_  ->     % this node belongs to at least 1 allowed sender group 
	    incoming(Node, FGs, From, Tos, NGs, 
		     IN+Count, round(average(AvIN*IN+Sz, IN+Count)))
    end;
incoming(Node, FGs, From, [_ |Tos], NGs, IN, AvIN) ->
    incoming(Node, FGs, From, Tos, NGs, IN, AvIN).

get_nodegroups(Node, NGs) ->
    case lists:keyfind(Node, 1, NGs) of
	{Node, NGroups} -> NGroups;
	false -> [[]]                   % free node
    end.

node_groups([], NodeGroups) ->
    lists:sort(NodeGroups);
node_groups([{Group, [Node|Nodes]} | T], NG) ->
    case lists:keyfind(Node, 1, NG) of
	false ->
	    node_groups([{Group, Nodes}|T], [{Node, [Group]}|NG]);
	{Node, Groups} ->
	    case lists:member(Group, Groups) of 
		false ->
		    NewGroups = lists:keyreplace(Node, 1, NG, 
					       {Node,lists:sort([Group|Groups])}),
		    node_groups([{Group, Nodes}|T], NewGroups); 
		_ ->
		    node_groups([{Group, Nodes}|T], Groups)
	    end
    end;
node_groups([{_Group, []} | T], NG) ->
    node_groups(T, NG).
   


aggregate(AgentsStats) ->
    aggregate(AgentsStats, []).
aggregate([], SYSSTATS) ->
    SYSSTATS;
aggregate([Stats | T], SYS) ->
    aggregate(T, merge(Stats, SYS)).

merge(Stats, []) ->
    Stats;
merge(Stats, SYS) ->
    merge(Stats, SYS, []).
merge([], [], MergedSYS) ->
    MergedSYS;
merge([{total_entries,T1}|Rest1], [{total_entries,T2}|Rest2], []) ->
    merge(Rest1, Rest2, [{total_entries,T1+T2}]);
merge([{inter_node, IN1, AV1}|Rest1], [{inter_node, IN2, AV2}|Rest2], Acc) ->
    merge(Rest1, Rest2, Acc++[{inter_node, IN1+IN2, 
			       average(IN1+IN2,IN1*AV1 + IN2*AV2)}]);
merge([{inter_group, IG1, AV1}|Rest1], [{inter_group, IG2, AV2}|Rest2], Acc) ->
    merge(Rest1, Rest2, Acc++[{inter_group, IG1+IG2, 
			       average(IG1+IG2,IG1*AV1 + IG2*AV2)}]);
merge([{nodes, NS1}|Rest1], [{nodes, NS2}|Rest2], Acc) ->
    merge(Rest1, Rest2, Acc++[{nodes, merge_nodes(NS1++NS2)}]);
merge([{groups, GS1}|Rest1], [{groups, GS2}|Rest2], Acc) ->
    merge(Rest1, Rest2, Acc++[{groups, merge_nodes(GS1++GS2)}]).

% {From, Tos} == {From, [{To, Sz, Num} |...]}
merge_nodes(N) ->
    merge_nodes(N, []).
merge_nodes([], MergedNodes) ->
    MergedNodes;
merge_nodes([N|T], []) ->
    merge_nodes(T, [N]);
merge_nodes([{From, Tos} | T], Acc) ->
    case lists:keyfind(From, 1, Acc) of
	false ->
	    merge_nodes(T, Acc++[{From, Tos}]);
	{From, AccTos} ->
	    NewAccTos = merge_tonodes(Tos++AccTos),
	    merge_nodes(T, lists:keyreplace(From, 1, Acc, {From, NewAccTos}))
    end.

merge_tonodes(N) ->
    lists:keysort(1, merge_tonodes(N, [])).
merge_tonodes([], MergedNodes) ->
    MergedNodes;
merge_tonodes([N|T], []) ->
    merge_tonodes(T, [N]);
merge_tonodes([{To, Sz, Count} | T], Acc) ->
    case lists:keyfind(To, 1, Acc) of
	false ->
	    merge_tonodes(T, Acc++[{To, Sz, Count}]);
	{To, AccSz, AccCount} ->
	    merge_tonodes(T, lists:keyreplace(To, 1, Acc, 
					      {To, AccSz+Sz, AccCount+Count}))
    end.    


file_parser(end_of_trace, {Caller, Dev, Stats}) -> 
    file:close(Dev),
    Caller ! {done, Stats};

file_parser(Trace={trace_inter_node, FromNode, ToNode, MsgSz}, 
	    {Caller, Dev, {Count, IN, INsz, IG, IGsz, NxN, GxG, _}}) ->
    NewNxN = add_send_node(FromNode, ToNode, MsgSz, NxN),
    io:format(Dev, "~p.~n", [Trace]),
    {Caller, Dev, {Count+1, IN+1, INsz+MsgSz, IG, IGsz, NewNxN, GxG, MsgSz}};
file_parser(Trace={trace_inter_group, FromGrups, ToGroups}, 
	    {Caller, Dev, {Count, IN, INsz, IG, IGsz, NxN, GxG, MsgSz}}) ->
    NewGxG = add_send_group(FromGrups, ToGroups, MsgSz, GxG),
    io:format(Dev, "~p.~n", [Trace]),
    {Caller, Dev, {Count+1, IN, INsz, IG+1, IGsz+MsgSz, NxN, NewGxG, 0}};
file_parser(Trace, {Caller, Dev, {Count, IN, INsz, IG, IGsz, NxN, GxG, MsgSz}}) ->
    io:format(Dev, "~p.~n", [Trace]),
    {Caller, Dev, {Count + 1, IN, INsz, IG, IGsz, NxN, GxG, MsgSz}}.
 
average(_,0) -> 0;
average(Sz, Tot) -> Sz/Tot.

add_send_node(FromNode, ToNode, MsgSz, NxN) ->   
    case lists:keyfind(FromNode, 1, NxN) of
	{FromNode, ToNodes} ->
	    case lists:keyfind(ToNode, 1, ToNodes) of
		{ToNode, Sz, Count} ->
		    NewToNodes = lists:keyreplace(ToNode, 1, ToNodes, 
						  {ToNode,Sz+MsgSz,Count+1});
		_ ->
		    NewToNodes = [{ToNode, MsgSz, 1} | ToNodes]
	    end,
	    lists:keyreplace(FromNode, 1, NxN, {FromNode, NewToNodes});
	_ ->
	    [{FromNode, [{ToNode, MsgSz, 1}]} | NxN]
    end.

add_send_group(FromGrups, ToGroups, MsgSz, GxG) ->   
    case lists:keyfind(FromGrups, 1, GxG) of
	{FromGrups, ToGs} ->
	    case lists:keyfind(ToGroups, 1, ToGs) of
		{ToGroups, Sz, Count} ->
		    NewToGs = lists:keyreplace(ToGroups, 1, ToGs, 
					       {ToGroups, Sz+MsgSz, Count+1});
		_ ->
		    NewToGs = [{ToGroups, MsgSz, 1} | ToGs]
	    end,
	    lists:keyreplace(FromGrups, 1, GxG, {FromGrups, NewToGs});
	_ ->
	    [{FromGrups, [{ToGroups, MsgSz, 1}]} | GxG]
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

%% from sdmon_master
nodup(L) ->
    nodup(L,[]).
nodup([],L) ->
    L;
nodup([H|T], NewL) ->
    case lists:member(H, NewL) of
	true ->
	    nodup(T, NewL);
	_ ->
	    nodup(T, NewL++[H])
    end.

sort_stats(List) ->
    sort_stats(List,[]).
sort_stats([], ListofSortedList) ->
    lists:sort(ListofSortedList);
sort_stats([{From, Tos} | T], Acc) ->
    sort_stats(T, [{From, lists:sort(Tos)} | Acc]).
