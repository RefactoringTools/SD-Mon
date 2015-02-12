%%%-------------------------------------------------------------------
%%% @author md504 <>
%%% @copyright (C) 2014, md504
%%% @doc
%%%
%%% @end
%%% Created :  6 Oct 2014 by md504 <>
%%%-------------------------------------------------------------------
-module(run_env).

-compile([export_all]).

%% API
-export([start/0, generate/0]).

-export([generate_groupcnf/2, generate_tracecnf/2]).  % called by sdmon_master

%% Dummy API
-export([start_dummy/0, start_dummy/1, ping/1, stop/1, status/1]).

-define(CONFIGFILE, "test/config/test.config").              % run_env input

-define(TRACE_config, "config/trace.config").  % run_env output
-define(GROUP_config, "config/group.config").  % run_env output

-define(LOGFILE, "sd_mon_log").

-define(timout, 5000).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the environment
%%
%% @spec 
%% @end
%%--------------------------------------------------------------------
start() ->
    {Hosts, VMNames, UID} = generate(),
    start_hosts(Hosts, VMNames, UID). 

generate() ->
    {ok, Configs} = file:consult(?CONFIGFILE),
    {ok, Hosts} = get_hosts(Configs),
    {ok, SGroups} = get_sgroups(Configs),
    {ok, GGroups} = get_global_groups(Configs),
    {ok, Traces} = get_traces(Configs),
    {ok, VMsNum} = get_vmsnum(Configs),
    {ok, UID} = get_uid(Configs),
    store_uid(UID),
    timer:start(), timer:sleep(100),
    generate_groupcnf(SGroups, GGroups),
    upload_group_config(UID, Hosts),
    NewHosts = add_localhost(Hosts),
    {VMNames, TracedFreeNoAutoVMs} = 
	vms_to_start(NewHosts, VMsNum, SGroups, GGroups, Traces),
    clear_dir(),
    generate_tracecnf(Traces, TracedFreeNoAutoVMs),
    {NewHosts, VMNames, UID}. 
    

	 
%%%===================================================================
%%% Internal Functions
%%%===================================================================

vms_to_start(Hosts, VMsNum, SGroups, GGroups, Traces) ->
    HostVMs = vm_names(Hosts, VMsNum),
    SGVMs = ck_VMNames(nodup(lists:flatten([VMs || {_, _, VMs} <- SGroups]))),
    GGVMs = ck_VMNames(nodup(lists:flatten([VMs || {_, _, VMs} <- GGroups]))),
    TRVMs = [VM || {node, VM, _} <- Traces],                 % checked on get
    AutoFreeNoTraceVMs = (HostVMs -- SGVMs -- GGVMs) -- TRVMs,
%%  io:format("HostVMs=~p~nSGVMs=~p~n,GGVMs=~p~n,TRVMs=~p~nFREEVMs=~p~n",
%% 	  [HostVMs,SGVMs,GGVMs,TRVMs,AutoFreeNoTraceVMs]),
    {lists:umerge([lists:sort(HostVMs), lists:sort(SGVMs), 
		  lists:sort(GGVMs), lists:sort(TRVMs)]), AutoFreeNoTraceVMs}.

vm_names(Hosts, VMsNum) ->
    [list_to_atom("node"++integer_to_list(N)++"@"++ atom_to_list(H))
     || H <- Hosts, N <- lists:seq(1, VMsNum)].

clear_dir() ->
    case filelib:is_file(?TRACE_config++".init") of
	true ->
	    file:delete(?TRACE_config++".init"),
	    file:delete(?GROUP_config++".init");
	_ ->
	    first_run
    end.    

generate_groupcnf(SGroups, GGroups) ->
    Kernelgroups= [{kernel, [{s_groups, ck_group_nodes(SGroups)}, 
			     {global_groups, ck_group_nodes(GGroups)}]}],
    {ok, File} =  file:open(?GROUP_config, write),
    io:format(File, "~p.", [Kernelgroups]),
    file:close(File).
		  
generate_tracecnf(Traces, FreeVMs) ->
    {ok, File} =  file:open(?TRACE_config, write),
    io:format(File, "~p.", [{traces, Traces ++ 
				 [{node, VM, notrace} || VM <- FreeVMs]
			    }]),
    file:close(File).

start_hosts([], _VMsNum, _UID) ->
    ok;
start_hosts([Host | Hosts], VMs, UID) ->
    io:format("~n-------------- HOST: ~p - -------------~n", [Host]),
    HostVMs = host_vms(Host, VMs),
    case inet:gethostbyaddr(atom_to_list(Host)) of
	{ok, _} ->
	    start_host_vms(Host, HostVMs, UID),
	    start_hosts(Hosts, VMs--HostVMs, UID);
	_  ->
	    io:format("HOST ~p is unreachable: VMs cannot be started.~n",[Host]),
	    start_hosts(Hosts, VMs--HostVMs, UID)
    end.    
    
host_vms(Host, VMs) ->
    [VM || VM<-VMs, lists:suffix(atom_to_list(Host), atom_to_list(VM))].
    
start_host_vms(_Host, [], _UID) ->  
    ok;
start_host_vms(Host, [VM | HostVMs], UID) ->  
    case get_localhost() of
	Host ->
	    SSH = "", 
	    CONFIG = ?GROUP_config;
	_ ->
	    SSH = "ssh -q -l " ++ UID ++ " " ++ atom_to_list(Host) ++ " ",
	    CONFIG = "/tmp/group.config"
    end,
    kill_VM(SSH, VM),
    CMD = SSH ++ "erl -detached -name " ++ atom_to_list(VM)  
              ++ " -setcookie " ++ atom_to_list(erlang:get_cookie())
	      ++ " -config " ++ CONFIG 
	      ++ " -run s_group"
	      ++ " -run run_env start_dummy " 
%             ++ term_to_list(Args)
	      ++ " -s init stop",
%	      ++ " >>" ++ ?LOGFILE,  % da costruire in Results
    os:cmd(CMD),
%    io:format("CMD is: ~p~n",[CMD]),
    io:format("Started VM  ~p with UNIX PID = ~p~n", [VM, unix_VM_PID(SSH, VM)]),
    start_host_vms(Host, HostVMs, UID).

start_cmd(Host, VM) ->
    {ok, [UID]} = file:consult(".uid"),
    case get_localhost() of
	Host ->
	    SSH = "", 
	    CONFIG = ?GROUP_config;
	_ ->
	    SSH = "ssh -q -l " ++ UID ++ " " ++ atom_to_list(Host) ++ " ",
	    CONFIG = "/tmp/group.config"
    end, 
    SSH ++ "erl -detached -name " ++ atom_to_list(VM)  
              ++ " -setcookie " ++ atom_to_list(erlang:get_cookie())
	      ++ " -config " ++ CONFIG 
	      ++ " -run s_group"
	      ++ " -run run_env start_dummy " 
	      ++ " -s init stop".

%%--------------------------------------------------------------------
%% @doc
%% Starts the test node so that it can be pinged
%%
%% @spec start_dummy(Args) -> _
%% @spec Args = List of strings, as passed by erl -run flag, if any
%% @end
%%--------------------------------------------------------------------
start_dummy() -> start_dummy([]).
start_dummy(Traces) ->
    register(node(), self()),
    loop([list_to_term(Trace) || Trace <- Traces]).

ping(Node) ->
    {Node,Node} ! {self(), ping},
    receive
	pong -> pong
    after ?timout ->
        timout
    end.

status(Node) ->
    {Node,Node} ! {self(), status},
    receive
	{status, Status} -> Status
    after ?timout ->
        timout
    end.

stop(Node) ->
    {Node,Node} ! stop.
	       

loop(Trace) ->
    receive
        {From, ping} ->
	    From ! pong,
	    loop(Trace);
        {From, status} ->
	    From ! {status, Trace},
	    loop(Trace);
	stop ->
	    stop	
    end.




%%%===================================================================
%%% Utility Functions
%%%===================================================================

get_hosts(Configs) ->
    LocalHost =
	case lists:keyfind(localhost, 1, Configs) of
	    {localhost, []} -> 	get_localhost();
	    {localhost, [LocalH]} -> LocalH 
	end,
    put(localhost, LocalHost),
    store_localhost(LocalHost),
    {ok, element(2, lists:keyfind(hosts, 1, Configs))}.

get_sgroups(Configs) ->
   {ok, ck_group_nodes(element(2, lists:keyfind(s_groups, 1, Configs)))}.

get_global_groups(Configs) ->
   {ok, element(2, lists:keyfind(global_groups, 1, Configs))}.
    
get_traces(Configs) ->
   {ok, ck_traces(element(2, lists:keyfind(traces, 1, Configs)))}.

get_vmsnum(Configs) ->
   {ok, element(2, lists:keyfind(vms_num, 1, Configs))}.

get_uid(Configs) ->
   {ok, element(2, lists:keyfind(uid, 1, Configs))}.

store_uid(UID) ->
    {ok, Dev} = file:open(".uid",write),
    io:format(Dev,"~p.",[UID]),
    file:close(Dev).

store_localhost(Localhost) ->
    {ok, Dev} = file:open(".localhost",write),
    io:format(Dev,"~p.",[Localhost]),
    file:close(Dev).


kill_local_VM(VM) ->
    kill_VM("", VM).

kill_VM(SSH, VM) ->
    case unix_VM_PID(SSH, VM) of
	"" ->
	    nothing_to_kill;
	PID ->
	    io:format("Killing OLD ~p with Unix PID = ~p~n",[VM,PID]),
	    os:cmd(SSH ++ "kill -9 " ++ PID)
    end.

unix_VM_PID(SSH, String) ->
    os:cmd(SSH ++ "ps axu|grep " ++ atom_to_list(String) ++ 
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

get_localhost() ->
    case get(localhost) of
	undefined ->
	    list_to_atom(os:cmd("hostname -i")--"\n");
	LocalHost ->
	    LocalHost
    end.

add_local_ip(NodeName) ->
    NodeStr = atom_to_list(NodeName),
    case lists:member($@, NodeStr) of 
	true ->
	    NodeName;
	_ ->
	    list_to_atom(NodeStr++"@"++atom_to_list(get_localhost()))
    end.

ck_VMNames(VMs) ->
    lists:map(fun add_local_ip/1, VMs).

ck_group_nodes(Groups) ->
    [{G,T,ck_VMNames(Nodes)} || {G,T,Nodes} <-Groups].

ck_traces(Traces) ->
    ck_traces(Traces, []).
ck_traces([], NewTraces) ->
    NewTraces;
ck_traces([{node, Node, Trace} | T], Acc) ->
    ck_traces(T, Acc ++ [{node, add_local_ip(Node), Trace}]);
ck_traces([GroupTuple | T], Acc) ->
    ck_traces(T, Acc ++ [GroupTuple]).
    



upload_group_config(_, []) ->
    io:format("~n",[]);
upload_group_config(UID, [Host|T]) ->
    CMD = "scp "++?GROUP_config++" "++UID++"@"++atom_to_list(Host)++":/tmp",
%    io:format("CMD IS: ~p~n",[CMD]),
    io:format("~nUploading configuration to host ~p",[Host]),
    os:cmd(CMD),
    upload_group_config(UID, T).


add_localhost(Hosts) ->
    LOCALHOST = get_localhost(),
    case lists:member(LOCALHOST, Hosts) of
	true ->
	    Hosts;
	_ ->
	    [LOCALHOST|Hosts]
    end.
