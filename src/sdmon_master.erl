%%%-------------------------------------------------------------------
%%% @author md504 <>
%%% @copyright (C) 2014, md504
%%% @doc
%%%
%%% @end
%%% Created :  7 Nov 2014 by md504 <>
%%%-------------------------------------------------------------------
-module(sdmon_master).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3, stop/0]).

%% User Interface
-export([agents/1, stop_agent/2, stop_agents/1]).

%% Agent Interface
-export([init_conf/1, s_group_change/3]).

%% Test Interface
-export([get_state/0, get_state/1]).


-define(SERVER, ?MODULE).

-define(timeout, 5000).                 % for local calls
-define(timeoutext, 3000).              % for remote calls

-define(BASEDIR, "'$HOME'/SD-Mon").
-define(TRACE_CONFIG, "./config/trace.config").   
-define(GROUP_CONFIG, "./config/group.config").

-define(LOGDIR, "./logs/").
-define(LOGFILE, "./logs/sdmon_master.log").

-record(agent, {vm, sdmon, type, gname, nodes=[], trace=notrace, state=down,
		dmon=no, token}).

-compile([debug_info, export_all]).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% to be callled from sdmon_master node)
stop() -> 
    gen_server:call(sdmon_master,{stop}, infinity).

%%%===================================================================
%%% User/test  interfaces
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the agent on request
%%
%% @spec stop_agent(SDMON) -> stopped |
%%                            {error, Reason}
%% @end
%%--------------------------------------------------------------------

stop_agent(SDMon) -> stop_agent(node(), SDMon).  % Test function from master shell
stop_agent(Master, SDMon) ->
    gen_server:call({sdmon_master, Master}, {stop_agent, SDMon}, infinity).

stop_agents() -> stop_agents(node()).            % Test function from master shel
stop_agents(Master) -> 
    lists:foreach(fun(Agent) ->  stop_agent(Master, Agent) end, agents()).

agents() ->
    agents(node()).
agents(Master) ->
    gen_server:call({sdmon_master, Master}, {get_agents}, infinity).

%%%===================================================================
%%% SDMON agent interfaces
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the agent on request
%%
%% @spec init_conf(MasterNode) -> {ok, Config} |
%%                               {error, Reason}
%% @end
%%--------------------------------------------------------------------

init_conf(Master) -> init_conf(Master, node()).
init_conf(Master, SDMon) ->
    gen_server:call({sdmon_master, Master}, {init_conf, SDMon}, infinity).

s_group_change(Master, Fun, Args) ->
    gen_server:cast({sdmon_master, Master}, {node(), s_group_change, Fun, Args}).

%%%----------------------------
%%% Test functions
%%%----------------------------
get_state() ->
    sys:get_status(sdmon_master).
get_state(Arg) ->
    get_state(node(),Arg).
get_state(Master,_) ->
    gen_server:call({sdmon_master, Master}, get_state, infinity).
    
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    init_log(),
    Traces = get_trace_cnf(),
    Groups = get_group_cnf(),
    Agents = deploy_network(Groups, Traces),
    io:format("sdmon_master started~n", []),
    {ok, Agents}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({init_conf, SDMON}, {From, _Tag}, State) ->
  case  get_sdmon_config(SDMON, State) of
      {error, Reason} ->
	  log("Received config request from unknown agent ~p~n",[SDMON]),
	  {reply, {error, Reason}, State};
      {Type,  GName, Trace, Nodes} ->
	  link(From),
	  erlang:monitor_node(SDMON, true),
	  log("Agent ~p configured~n",[SDMON]),
	  Token = 0,
	  Groups = groups(State),
	  {reply, {ok, {Type,  GName, Trace, Nodes, Token, Groups}}, 
	         update_agent(get_agent(SDMON, State), 
			      [{sdmon,From}, {state,up}, {token,Token}], State)}
  end;

handle_call(get_state, {_From, _Tag}, State) ->
    {reply, State, State};

handle_call({get_agents}, {_From, _Tag}, State) ->
    {reply, [get_agent_val(Agent, vm) || Agent <- State], State};

handle_call({stop_agent, SDMON}, {_From, _Tag}, State) ->
  case get_agent(SDMON, State) of
      false ->
	  log("Received stop request for unknown agent ~p~n",[SDMON]),
	  {reply, {error, unknown}, State};
      Agent ->
	  case net_kernel:connect_node(SDMON) of
	      true ->
		  do_stop_agent(Agent),
		  {reply, stopped, remove_agent(SDMON, State)};
	      _ ->		  
		  {reply, {error, node_down}, State}
	  end
  end;



handle_call({stop}, {_From, _Tag}, State) ->
    terminate(stop, State),
    {noreply, State};        

handle_call(Req, From, State) ->
    log("UNEXPECTED call: ~p  From: ~p~n",[Req, From]),
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({SDMON, s_group_change, Fun, Args}, State) ->
    case get_agent(SDMON, State) of
	false ->         % Notify from deleted Agent (delete_s_group?). Kill it
	    sdmon:stop(SDMON);
	_ ->
	    goon
    end,
    NewState = handle_s_group_change(SDMON, Fun, Args, State),
    {noreply, NewState};

handle_cast(Msg, State) ->
    log("UNEXPECTED cast: ~p~n",[Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({nodeup, Node}, State) ->
    {noreply, handle_node_up(Node, State)};

handle_info({nodedown, Node}, State) ->
    {noreply, handle_node_down(Node, State)};

handle_info({'EXIT', Pid, Reason}, State) ->
    {noreply, handle_exit(Pid, Reason, State)};

handle_info(Info, State) ->
    log("UNEXPECTED Info ~p~n",[Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    log("TERMINATE CALLED~n",[]),
    TimeStamp = timestamp(),                    %MAU
    lists:foreach(fun(Agent) -> do_stop_agent(Agent, TimeStamp) end, State), %MAU
    init:stop(),
    ok.

do_stop_agent(Agent) ->                  %MAU
    do_stop_agent(Agent, timestamp()).                  %MAU
do_stop_agent(Agent, TimeStamp) ->                  %MAU
    [SDMON, Nodes] = get_agent_vals(Agent, [vm,nodes]),
    unlink(get_agent_val(Agent, sdmon)),
    erlang:monitor_node(SDMON, false),
    stop_sdmon(SDMON, Nodes, TimeStamp, sync),                   %MAU
    io:format("Agent ~p: stopped~n~n",[SDMON]),
    log("Agent ~p: stopped~n",[SDMON]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%%-------------------
%%% Start functions
%%%-------------------
get_trace_cnf() ->
    CNF = case application:get_env(sdmon, trace_cnf) of
	      undefined -> ?TRACE_CONFIG;
	      {ok, File} -> File
	  end,
    case file:consult(CNF) of
	{ok, [{traces, Traces}]} -> Traces;
	_ -> []
    end.

get_group_cnf() -> 
    case file:consult(?GROUP_CONFIG) of
	{ok,[[{kernel,[{s_groups, SGROUPS}, {global_groups, GGROUPS}]}]]} -> 
		{SGROUPS, GGROUPS};
	_ -> []
    end.


deploy_network({SGroups, GGroups}, Traces) ->
%io:format("SGroups=~p~nGGRoups=~p~nTraces=~p~n",[SGroups, GGroups, Traces]),
    GNodes = nodup(lists:flatten([Nodes || {_,_,Nodes} <- GGroups++SGroups])),
    TNodes = [Node || {node, Node, _Traces} <- Traces],
    FreeNodes = TNodes -- GNodes,
    SGHosts = [{Group, choose_host(Nodes), s_group, Nodes} || 
		  {Group, _Type, Nodes} <- SGroups],
    GGHosts = [{Group, choose_host(Nodes), global_group, Nodes} || 
		  {Group, _Type, Nodes} <- GGroups],
%io:format("FREENODES=~p~n",[FreeNodes]),
    FreeHosts = [{prefix(Node), domain(Node), node, [Node]} || Node <- FreeNodes],
    start_agents(GGHosts++SGHosts++FreeHosts, Traces).


start_agents(Hosts, Traces) ->
%    log("START AGENTS: Hosts=~p~n",[Hosts]),
    io:format("~n",[]),
    start_agents(Hosts, Traces, []).

start_agents([], _, Agents) ->
    Agents;
start_agents([Host|Hosts], Traces, Agents) ->
    start_agents(Hosts, Traces, store_agent(start_agent(Host, Traces), Agents)).



start_agent({Prefix, Domain, Type, Nodes}, Traces) ->
    SSH = domain_specific(ssh, Domain),
    EBIN = domain_specific(ebin, Domain),
    NodeStr = atom_to_list(Prefix) ++ "@" ++ atom_to_list(Domain),
    VMstr = "sdmon_" ++ NodeStr,
    VM = list_to_atom(VMstr),
    case Type of
	node ->
	    Trace = get_trace(list_to_atom(NodeStr), Traces),
	    GName = VM;
	_    ->
	    Trace = get_trace(Prefix, Traces),
	    GName = Prefix
    end,
    kill_VM(SSH, VMstr), 
    CMD = SSH ++ "erl -hidden -detached -name " ++ VMstr
	++ " -setcookie " ++ atom_to_list(erlang:get_cookie())
	++ " -run sdmon start " 
	++ atom_to_list(node())
	++ " -s init stop -pa " ++ EBIN,
%	++ " >" ++ ?LOGDIR++VMstr++".log",
    os:cmd(CMD),
%    log("CMD is: ~p~n",[CMD]),
    UNIX_PID = unix_VM_PID(SSH, VMstr),
    case UNIX_PID of
	"" -> 
	    log("Failed to start VM ~p~n",[VM]);  % Then ??? will be never started
	_ ->
	    log("Started VM  ~p with UNIX PID = ~p~n",
	                        	[VM, unix_VM_PID(SSH, VMstr)]),
	    io:format("Started Agent ~p~n", [VM]),
	    net_kernel:connect_node(VM),
	    erlang:monitor_node(VM, true)	    
    end,
    new_agent(VM, [{type,Type},{gname,GName},{nodes,Nodes},{trace,Trace}]).

restart_agent(VM) ->
    SSH = domain_specific(ssh, domain(VM)),
    EBIN = domain_specific(ebin, domain(VM)),
    VMstr = atom_to_list(VM),
    kill_VM(SSH, VMstr), 
    CMD = SSH ++ "erl -hidden -detached -name " ++ VMstr
	++ " -setcookie " ++ atom_to_list(erlang:get_cookie())
	++ " -run sdmon start " 
	++ atom_to_list(node())
	++ " -s init stop -pa " ++ EBIN,
%	++ " >" ++ ?LOGDIR++VMstr++".log",
    os:cmd(CMD),
%    log("CMD is: ~p~n",[CMD]),
    UNIX_PID = unix_VM_PID(SSH, VMstr),
    case UNIX_PID of
	"" -> 
	    log("Failed to start VM ~p~n",[VM]);  % Then ??? will be never started
	_ ->
	    log("Restarted VM  ~p with UNIX PID = ~p~n",
	                        	[VM, unix_VM_PID(SSH, VMstr)]),
	    net_kernel:connect_node(VM),
	    erlang:monitor_node(VM, true)	    
    end.

domain_specific(Item, Host) ->
    domain_specific(Item, Host, get_localhost()).

domain_specific(ssh, LOCALHOST, LOCALHOST) ->
    "";
domain_specific(ssh, Domain, _) ->
    case get_uid() of 
	"" -> 
	    "ssh -q " ++ atom_to_list(Domain) ++ " ";
	UID ->
	    "ssh -q -l " ++ UID ++" " ++ atom_to_list(Domain) ++ " "
    end;    

domain_specific(basedir, LOCALHOST, LOCALHOST) ->
    ".";
domain_specific(basedir, _Domain, _) ->
    ?BASEDIR;

domain_specific(ebin, LOCALHOST, LOCALHOST) ->
    "./ebin";
domain_specific(ebin, _Domain, _) ->
    ?BASEDIR++"/ebin";

domain_specific(quote, LOCALHOST, LOCALHOST) ->
    "";
domain_specific(quote, _Domain, _) ->
    [$'].



get_localhost() ->
    case file:consult(".localhost") of
	{ok, [Localhost]} -> Localhost;
	_ -> list_to_atom(os:cmd("hostname -i")--"\n")
    end.


get_trace(Node, Traces) ->
    case lists:keyfind(Node, 2, Traces) of
	false ->                          % free node with no trace specification
	    notrace;
	 TraceTuple->
	    element(3, TraceTuple)
    end.

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

choose_host(Nodes) ->
    Domains = [domain(Node) || Node <- Nodes],
    max_recurring(Domains).


prefix(Node) ->
    NL = atom_to_list(Node),
    HL = lists:takewhile(fun(Char) -> Char =/= $@ end, NL),
    list_to_atom(HL).

domain(Node) ->
    NL = atom_to_list(Node),
    HL = tl(lists:dropwhile(fun(Char) -> Char =/= $@ end, NL)),
    list_to_atom(HL).

max_recurring(List) ->
    max_occur(count_occurences(List,[])).

count_occurences([], Acc) ->
    Acc;
count_occurences([H|T], Acc) ->
    case lists:keyfind(H,1,Acc) of
	false ->
	    count_occurences(T,Acc++[{H,1}]);
	{H,N} ->
	    count_occurences(T,lists:keyreplace(H, 1, Acc, {H,N+1}))
    end.

max_occur(List) ->
    max_occur(List,{donotcare,0}).
max_occur([], {El,_}) ->
    El;
max_occur([{El,N}|T], {_MaxEl,MaxN}) when N > MaxN ->
    max_occur(T,{El,N});
max_occur([_|T], Acc) ->
    max_occur(T,Acc).



init_log() ->
    os:cmd("mv " ++ ?LOGFILE ++ " " ++ ?LOGFILE ++ ".old"),
    log("#-SDMON MASTER-#  Started~n",[]).

log(String, Args) ->  
    {ok, Dev} = file:open(?LOGFILE, [append]),
    io:format(Dev, "~p~p: "++String,[date(),time()|Args]),
    file:close(Dev).


%% CODE FROM SDMON
%% kill_local_VM(VM) ->
%%     kill_VM("", VM).

kill_VM(SSH, VM) ->
    case unix_VM_PID(SSH, VM) of
	"" ->
	    nothing_to_kill;
	PID ->
	    log("Killing OLD ~p with Unix PID = ~p~n",[VM,PID]),
	    os:cmd(SSH ++ "kill -9 " ++ PID)
    end.

unix_VM_PID(SSH, String) ->
    os:cmd(SSH ++ "ps axu|grep " ++ String ++ 
	          "| grep beam|head -n 1|awk '{print $2}'")  -- "\n".
    

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

% taken from test config and written by run_env.erl
get_uid() ->
    case file:consult(".uid") of
	{ok, [UID]} -> UID;
	_ -> ""
    end.

encode(Term) ->
    [X+1000||X<-term_to_list(Term)].
decode(CodedString) ->
    list_to_term([X-1000||X <-CodedString]).


%%%----------------------------
%%% Callback internal functions
%%%----------------------------

get_sdmon_config(SDMON, State) ->
    case lists:keyfind(SDMON, #agent.vm, State) of
	false ->
	    {error, unknown_agent};
	Agent ->
	    {Agent#agent.type, Agent#agent.gname, Agent#agent.trace, Agent#agent.nodes}
    end.

%% O(n), max 2n. Can be improved to n (list recursion) or logn (hash, bintree)
new_state(State, _VM, []) -> State;
new_state(State, VM, [{state, Val} | StatusTuples]) ->
    Agent = lists:keyfind(VM, #agent.vm, State),
    new_state(lists:keyreplace(VM, #agent.vm, State, Agent#agent{state=Val}),
	      VM, StatusTuples).
    

handle_s_group_change(SDMON, Fun=new_s_group, Args=[SGroup, Nodes], State) ->
    log("RECEIVED S-GROUP CHANGE: ~p, ~p~n",[Fun, Args]),
    case get_agent_from_group(SGroup, State) of
	false ->                              % actually new s_group
	    ExFreeNodesAgents = free_nodes_agents(Nodes, State), % to be stopped
	    Trace = new_grp_trace(ExFreeNodesAgents, get_agent(SDMON,State)),    
	   % start a new agent with that node to trace with same traces of SDMON
	    Traces = [{s_group, SGroup, Trace}],
	    TimeStamp = timestamp(),   %MAU
	    DeleteAgentF = 
		fun(Agent, LoopState) ->
			[SDMONPid,SDMONNode,ExNodes] = 
			    get_agent_vals(Agent, [sdmon,vm,nodes]),
			unlink(SDMONPid),
			stop_sdmon(SDMONNode, ExNodes, TimeStamp),   %MAU
			_NewState = remove_agent(Agent#agent.vm, LoopState)
		end,
	    NewState = lists:foldl(DeleteAgentF, State, ExFreeNodesAgents),
	    NewAgent = start_agent({SGroup, choose_host(Nodes), s_group, Nodes}, 
				   Traces),
	    FinalState = store_agent(NewAgent, NewState), 
	    spawn(fun() -> dump_cnf(FinalState) end),
	    FinalState;
	_Agent ->                            % error: already existing
	    State                            % todo: add new nodes if needed
	end;

handle_s_group_change(_FROM, Fun=delete_s_group, Args=[SGroup], State) ->
    log("RECEIVED S-GROUP CHANGE: ~p, ~p~n",[Fun, Args]),
    % if sgroup exist, stop it
    % for each of is nodes not owned by other agents (free nodes) 
    % start a new agent, keep existing traces
    % restart tracing for node owned by other agents
     case get_agent_from_group(SGroup, State) of
	 false ->
	     log("DELETE UNKNOWWN S_GROUP: ~p~n",[SGroup]),
	     State;
	 Agent ->
	     FreeNodes = get_new_free_nodes(Agent, State),   % to be started
	     [SDMONPid,SDMONNode,Trace,Nodes] = 
		 get_agent_vals(Agent, [sdmon,vm,trace,nodes]),
	     NotFreeNodes = Nodes -- FreeNodes,
	     unlink(SDMONPid),
	     stop_sdmon(SDMONNode, Nodes),
	     NewState =  remove_agent(Agent#agent.vm, State),  
	     FinalState =
	     lists:foldl(
	       fun(Node, LoopState) ->
		       Traces = [{node, Node, Trace}],
		       NewAgent = start_agent({prefix(Node), choose_host([Node]), 
					       node, [Node]}, Traces),
		       _NewState = store_agent(NewAgent, LoopState)
	       end, NewState, FreeNodes),    
	     spawn(fun() -> dump_cnf(FinalState) end),
	     spawn(fun() -> restart_trace(NotFreeNodes, FinalState) end),
	     FinalState
     end;

handle_s_group_change(_FROM, Fun=add_nodes, Args=[SGROUP, Nodes], State) ->
    log("RECEIVED S-GROUP CHANGE: ~p, ~p~n",[Fun, Args]),
    case get_agent_from_group(SGROUP, State) of
	false ->
	    log("ADD NODES FOR UNKNOWWN S_GROUP: ~p~n",[SGROUP]),
	    State;
	Agent ->
            % if a node was free, delete free agent 
	    ExFreeNodesAgents = free_nodes_agents(Nodes, State), % to be stopped
	    TimeStamp = timestamp(),   %MAU
	    DeleteAgentF = 
		fun(Ag, LoopState) ->
			[SDMONPid,SDMONNode,ExNodes] = 
			    get_agent_vals(Ag, [sdmon,vm,nodes]),
			unlink(SDMONPid),
			stop_sdmon(SDMONNode, ExNodes, TimeStamp),  %MAU
			_NewState = remove_agent(Ag#agent.vm, LoopState)
		end,
	    NewState = lists:foldl(DeleteAgentF, State, ExFreeNodesAgents),

	    % if node is new: add and  tell sdmon to trace
	    case get_new_nodes(Agent, Nodes) of
		[] -> FinalState = NewState;
		NewNodes ->
		    NewToken = Agent#agent.token+1,
		    sdmon:add_and_trace(Agent#agent.vm, NewNodes, NewToken),
		    FinalState =  
			update_agent(Agent, [{nodes,get_agent_val(Agent,nodes)
					      ++NewNodes}, {token, NewToken}], 
				     NewState),
		    spawn(fun() -> dump_cnf(FinalState) end)
	    end,
	    FinalState
    end;


handle_s_group_change(_SDMON, Fun=remove_nodes, Args=[SGROUP, Nodes], State) ->
    log("RECEIVED S-GROUP CHANGE: ~p, ~p~n",[Fun, Args]),
    case get_agent_from_group(SGROUP, State) of
	false ->
	    log("REM NODES FOR UNKNOWWN S_GROUP: ~p~n",[SGROUP]),
	    State;
	Agent ->
	    % tell agent to remove the nodes
	    [SDMONNode,Trace,Token] = get_agent_vals(Agent, [vm,trace,token]),
	    NewToken = Token+1,
	    sdmon:untrace_and_remove(SDMONNode, Nodes, NewToken),
	    NewState = 
		update_agent(Agent, [{nodes,get_agent_val(Agent,nodes)--Nodes},
				     {token, NewToken}], State),	    
	     % if a node is not part of another group, start a new agent 
  	     NewFreeNodes = Nodes -- handled_nodes(State),   % to be started
	     FinalState =
	     lists:foldl(
	       fun(Node, LoopState) ->
		       Traces = [{node, Node, Trace}],
		       NewAgent = start_agent({prefix(Node), choose_host([Node]), 
					       node, [Node]}, Traces),
		       _NewState = store_agent(NewAgent, LoopState)
	       end, NewState, NewFreeNodes),
	     spawn(fun() -> dump_cnf(FinalState) end),
	     FinalState
     end;


handle_s_group_change(SDMON, Fun, Args, State) ->
    log("RECEIVED FROM ~p UNKNOWN S-GROUP CHANGE: ~p, ~p~n",[SDMON, Fun, Args]),
    State.

restart_trace(Nodes, Agents) ->
    NodeAgents = find_nodes_agents (Nodes, Agents),
    lists:foreach(fun({AgentVM,Ns}) ->
			  sdmon:restart_trace(AgentVM, Ns)
		  end, NodeAgents).

find_nodes_agents(Nodes, Agents) -> 
    find_nodes_agents(Nodes,Agents,[]).
find_nodes_agents([],_,NA) ->
    NA;
find_nodes_agents([N|Ns], Agents, NA) ->
    find_nodes_agents(Ns, Agents, node_agent(N, Agents, NA)).

node_agent(_, [], NA) -> 
    NA;
node_agent(N, [Ag|Ags], NA) ->   
    case lists:member(N, Ag#agent.nodes) of
	true ->
	    VM = Ag#agent.vm,
	    case lists:keyfind(VM,1,NA) of
		{VM,VMnodes} ->
		    lists:keyreplace(VM, 1, NA, {VM,VMnodes++[N]} );
		_ ->
		    NA ++ [{VM,[N]}]
	    end;
	_ ->
	    node_agent(N, Ags, NA)
    end.
	

%%% {'EXIT', AgentPID, noconnection} can come but it does not necessarily mean
%%% that the agent is dead. So ===>> CAN'T RESTART IT !! <<====
%%% QUESTION: how to understand if the agent is died or if that is due to a 
%%% temporary network problem ???
%%% ANSWER: Restart when Reason is something else.

handle_exit(_PID, noconnection, State) ->  % handled by handle_node_down 
    State;
handle_exit(PID, Reason, State) ->    
   case get_agent_from_pid(PID, State) of
       false ->
	   log("Unknown process ~p died with reason: ~p~n",[PID, Reason]),
	   State;
       Agent ->
	   VM = Agent#agent.vm,
	   log("AGENT ~p DIED WITH REASON: ~p~n",[VM, Reason]),
	   restart_agent(VM),
	   update_agent(Agent, {sdmon,undefined}, State)
   end.


handle_node_up(VM, State) ->
    case get_agent(VM, State) of
    	false ->               % Notification from unknown agent !!
	    log("UNKNOWN AGENT: ~p went DOWN~n",[VM]),
	    erlang:monitor_node(VM, false),  % could be a deleted agent
	    sdmon:stop(VM),
    	    State;             
    	Agent ->
     	    log("AGENT ~p: went UP ~n",[VM]),
    	    case net_kernel:connect_node(VM) of 
    		true ->     
    		    erlang:monitor_node(VM, false),   % to handle Node restart
    		    erlang:monitor_node(VM, true),    % avoiding  many nodedown 
    		                                      % for not restarted nodes
		    sdmon:last_token(VM, get_agent_val(Agent, token)),
		    update_agent(Agent, [{state, up},{dmon,no}], State);
    		_ ->          % up-down transition
    		    log("AGENT ~p: went DOWN ~n",[VM]),
		    DMon = start_direct_monitoring(VM,get_agent_val(Agent,dmon)),
		    update_agent(Agent, [{state, down}, {dmon,DMon}], State)
    	    end
    end.

handle_node_down(VM, State) ->
    case get_agent(VM, State) of
    	false ->               % Notification from unknown agent !!
	    log("UNKNOWN AGENT: ~p went DOWN~n",[VM]),
    	    State;             % Just discard it
    	Agent ->
	    log("AGENT ~p: went DOWN ~n",[VM]),
	    case net_kernel:connect_node(VM) of 
		true ->      % down-up transition
		    log("AGENT ~p: went UP ~n",[VM]),
		    update_agent(Agent, {state, up}, State);
		_ ->          %  Status confirmed to down
		    DMon = start_direct_monitoring(VM,get_agent_val(Agent,dmon)),
		    update_agent(Agent, [{state, down}, {dmon,DMon}], State)
	    end
    end.

start_direct_monitoring(VM, no) ->          
    log("Start Monitoring AGENT ~p ...~n", [VM]),
    spawn(sdmon_master, direct_monitor, [self(), VM, 1, 60]);

start_direct_monitoring(_, Dmon) ->            % Monitoring already in place
    Dmon.


stop_direct_monitoring(Dmon) when is_pid(Dmon)->
    Dmon ! {dmon, stop};
stop_direct_monitoring(_) ->
    no_dmon.
		  
%%% Makes a log printout every Logtreshold cycles (e.g. every 60 secs)
%%% until the node is up (eg: restarted) or it is demonitored.

direct_monitor(MasterPid, VM, N, LogTreshold) ->
    case net_adm:ping(VM) of
	pong ->
	    MasterPid ! {nodeup, VM};
	_ ->
	    receive
		{dmon, stop} ->
		    NewN = stop
	    after 1000 ->
		    if N==LogTreshold ->
		       log("~p Keep on Monitoring NODE ~p ...~n",[self(), VM]),
		       NewN=1;
		    true ->
		       NewN = N+1
		    end
	    end,
	    direct_monitor(MasterPid, VM, NewN, LogTreshold)
    end.
	    

%%%===================================================================
%%% Internal state handling
%%%===================================================================
% record(agent, {vm, type, nodes=[], trace=notrace, state=down, dmon=no})

groups(State) ->
    [{Agent#agent.gname, Agent#agent.nodes} || 
	Agent <- State, Agent#agent.type =/= node].


new_agent(VM, Vals) ->
    set_agent_vals(#agent{vm=VM}, Vals).    

get_agent(Node, State) ->
    lists:keyfind(Node, #agent.vm, State).

store_agent(Agent, State) ->
    case get_agent(Agent#agent.vm, State) of
	false -> State ++ [Agent];
	_Old -> lists:keyreplace(Agent#agent.vm, #agent.vm, State, Agent)
    end.

remove_agent(SDMON, State) ->
    lists:keydelete(SDMON, #agent.vm, State).
    

update_agent(Agent, {Key,Val}, State) ->
    update_agent(Agent, [{Key,Val}], State);
update_agent(Agent, Vals, State) ->	    
    store_agent(set_agent_vals(Agent, Vals), State).

get_agent_from_pid(Pid, State) ->
    lists:keyfind(Pid, #agent.sdmon, State).
get_agent_from_group(Pid, State) ->
    lists:keyfind(Pid, #agent.gname, State).

get_agent_val(Agent, vm) ->        % not used (vm is key)
    Agent#agent.vm;
get_agent_val(Agent, sdmon) ->
    Agent#agent.sdmon;
get_agent_val(Agent, type) ->
    Agent#agent.type;
get_agent_val(Agent, gname) ->
    Agent#agent.gname;
get_agent_val(Agent, nodes) ->
    Agent#agent.nodes;
get_agent_val(Agent, trace) ->
    Agent#agent.trace;
get_agent_val(Agent, state) ->
    Agent#agent.state;
get_agent_val(Agent, dmon) ->
    Agent#agent.dmon;
get_agent_val(Agent, token) ->
    Agent#agent.token.

get_agent_vals(Agent, Vals) -> [get_agent_val(Agent, Val) || Val <- Vals].


set_agent_val(Agent, {vm, Val}) ->    % not used (vm is key)
    Agent#agent{vm=Val};
set_agent_val(Agent, {sdmon, Val}) ->
    Agent#agent{sdmon=Val};
set_agent_val(Agent, {type, Val}) ->
    Agent#agent{type=Val};
set_agent_val(Agent, {gname, Val}) ->
    Agent#agent{gname=Val};
set_agent_val(Agent, {nodes, Val}) ->
    Agent#agent{nodes=Val};
set_agent_val(Agent, {trace, Val}) ->
    Agent#agent{trace=Val};
set_agent_val(Agent, {state, Val}) ->
    Agent#agent{state=Val};
set_agent_val(Agent, {dmon, Val}) ->
    Agent#agent{dmon=Val};
set_agent_val(Agent, {token, Val}) ->
    Agent#agent{token=Val}.

set_agent_vals(Agent, []) -> Agent;
set_agent_vals(Agent, [Val | Vals]) ->
    set_agent_vals(set_agent_val(Agent, Val), Vals). 
    
% nodes handled by OldAgent and not handled by any other Agent
get_new_free_nodes(OldAgent, Agents) ->
    HandledNodes = lists:usort(lists:flatten([Agent#agent.nodes 
					      || Agent <- Agents--[OldAgent]])),
    [Node || Node <- OldAgent#agent.nodes, not lists:member(Node, HandledNodes)].

handled_nodes(Agents) ->
    lists:usort(lists:flatten([Node || Agent <- Agents,
				       Node <- Agent#agent.nodes])).
				       
    

new_grp_trace([], false) -> notrace;
new_grp_trace([Agent|_], _) ->
    Agent#agent.trace;
new_grp_trace([], FromAgent) ->
    FromAgent#agent.trace.

	     
% Agents handling free nodes among Nodes
free_nodes_agents(Nodes, Agents) ->
    FreeNodeAgents = [Agent || Agent <- Agents, Agent#agent.type==node],
    [Agent || Node <- Nodes, Agent <- FreeNodeAgents, [Node]==Agent#agent.nodes].

% New nodes not previously handled by Agent
get_new_nodes(Agent, Nodes) ->
    [Node || Node <- Nodes, not lists:member(Node, Agent#agent.nodes)].
    

%%%===================================================================
%%% Configuration files update
%%%===================================================================

dump_cnf(State) ->
    process_flag(trap_exit, true),
    {SGroups, GGroups} = make_groups(State),
    case lists:keyfind(no_ktype, 2, SGroups++GGroups) of
	false ->
	    log("DUMPING CNF FILES ....~n",[]),

	    save_initial_conf(),

	    run_env:generate_groupcnf(SGroups, GGroups),

	    Traces = [{get_agent_val(Agent,type), get_agent_val(Agent,gname),
		       get_agent_val(Agent,trace)} || Agent <- State],
	    run_env:generate_tracecnf(Traces,[]);

	_ ->     % at list uno kernel type missing (nodedown ?): next time...
	    skip   
    end.

make_groups(State) ->
    make_groups(State,{[],[]}).

make_groups([], {SGs, GGs}) ->
    {SGs, GGs};
make_groups([Agent|Agents], {SGs, GGs}) ->
    [Type, GName, Nodes] = get_agent_vals(Agent, [type, gname, nodes]),
    case Type of
	node ->
	    make_groups(Agents, {SGs, GGs});
	s_group ->
	    make_groups(Agents, {SGs++[{GName, kernel_type(Nodes), Nodes}], GGs});
	global_group->
	    make_groups(Agents, {SGs, GGs++[{GName, kernel_type(Nodes), Nodes}]})
    end.
	  



kernel_type(Nodes) ->
    kernel_type(Nodes, no_ktype).

kernel_type([], KType) -> 
    KType;
kernel_type([Node|Nodes], KType) -> 
    case catch rpc:call(Node, init, get_argument, [hidden]) of
	{ok,[[]]} ->
	    kernel_type([], hidden);
	{ok,[["true"]]} ->
	    kernel_type([], hidden);
	 error ->
	    kernel_type([], normal);
	_ ->                              % rpc error: try next node
	    kernel_type(Nodes, KType)
    end.
	    

save_initial_conf() ->
    case filelib:is_file(?TRACE_CONFIG++".init") of
	true ->
	    already_saved;
	_ ->
	    file:copy(?TRACE_CONFIG, ?TRACE_CONFIG++".init"),
	    file:copy(?GROUP_CONFIG, ?GROUP_CONFIG++".init")
    end.

				 
stop_sdmon(SDMON, Nodes) ->                   %MAU
    stop_sdmon(SDMON, Nodes, timestamp(), async).
stop_sdmon(SDMON, Nodes, TimeStamp) ->
    stop_sdmon(SDMON, Nodes, TimeStamp, async).
stop_sdmon(SDMON, _Nodes, TimeStamp, SYNC) ->
    sdmon:stop(SDMON),
    get_trace_files(SDMON, TimeStamp),
    Host = domain(SDMON),
    SSH = domain_specific(ssh, Host),
    BaseDir = domain_specific(basedir, Host),
    Dir = BaseDir ++ "/traces/"++atom_to_list(SDMON),
    os:cmd(SSH++"rm -rf "++Dir),
    case SYNC of
	async ->
	    spawn(fun() -> sdmon_trace:decode_traces(TimeStamp) end);
	sync ->
	    sdmon_trace:decode_traces(TimeStamp)
    end.


get_trace_files(SDMONNode, Postfix) ->       %MAU
    io:format("Getting trace files from Agent ~p ...~n",[SDMONNode]),
    NodeStr = atom_to_list(SDMONNode),
    Dir = "traces/"++NodeStr,
    DestDir = "traces/"++Postfix++"/"++NodeStr,
    file:make_dir("traces/"++Postfix), 
    case domain(node()) == domain(SDMONNode) of
	true ->
	   os:cmd("mv " ++Dir++" "++DestDir);
	_ ->
	    BaseDir = ?BASEDIR++"/",
	    case get_uid() of
		"" -> UID="";
		String -> UID = String++"@"
	    end,
	    CMD = "scp -r -C "++UID++atom_to_list(domain(SDMONNode))++
		":"++BaseDir++Dir++" "++DestDir,
%	    log("SCP CMD: ~p~n",[CMD]),
	    os:cmd(CMD)
    end.


format(Int) when Int < 10 ->
    [$0|integer_to_list(Int)];
format(Int) ->
    integer_to_list(Int).

timestamp () ->
    {{Y,M,D},{H,P,S}} = {date(),time()},
    format(Y)++format(M)++format(D)++"_"++format(H)++format(P)++format(S).
  	    
	    
