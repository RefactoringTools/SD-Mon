%%%-------------------------------------------------------------------
%%% @author mau <>
%%% @copyright (C) 2015, mau
%%% @doc
%%%
%%% @end
%%% Created : 16 Feb 2015 by mau <>
%%%-------------------------------------------------------------------
-module(sdmon_db).

-compile([debug_info, export_all]).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts db for run-time visualization
%%
%% @spec start() -> _
%% @end
%%--------------------------------------------------------------------

start() ->
    start(200).
start(Refresh) ->
    spawn(sdmon_db, init, [Refresh]).

insert(Type, From, To) ->                 % to be called from master node only
    insert(Type, From, To, node()).
insert(in, From, To, MasterNode) ->
    {sdmon_db, MasterNode} ! {in, From, To};
insert(ig, From, To, MasterNode) ->
    {sdmon_db, MasterNode} ! {ig, From, To}.

stop() ->                                 % to be called from master node only
    stop(node()).
stop(MasterNode) ->
    {sdmon_db, MasterNode} ! stop.


%%%===================================================================
%%% Internal functions
%%%===================================================================
init(Refresh) ->
    register(sdmon_db, self()),
    process_flag(trap_exit, true),
    _IN_Tab = ets:new(in_tab, [ordered_set,named_table,public]),
    _IG_Tab = ets:new(ig_tab, [ordered_set,named_table,public]),
    Groups = get_groups(),
    WEBNode = list_to_atom("sdmon_web@"++atom_to_list(sdmon_master:get_localhost())),
    File = "/tmp/in_tab.txt",
    {ok,Tref} = timer:apply_interval(Refresh, ?MODULE, show, [WEBNode, File]),
    loop(Groups, WEBNode, File, Tref).

loop(Groups, WEBNode, File, Tref) ->
    receive
	{in, From, To} ->
	    increment(in_tab, From, To),
	    loop(Groups, WEBNode, File, Tref);
	{ig, From, To} ->
	    increment(ig_tab, From, To),
	    loop(Groups, WEBNode, File, Tref);
	stop ->
	    timer:cancel(Tref),
	    flush(WEBNode, File),
	    stop
    end.

flush(WEBNode, File) ->
    receive
	{in, From, To} ->
	    increment(in_tab, From, To),
	    to_file(File),
	    flush(WEBNode, File);
	{ig, From, To} ->
	    increment(ig_tab, From, To),
	    to_web(WEBNode),
	    flush(WEBNode, File)
	after 0 ->
		true
	end.

increment(Tab, From, To) ->
    case ets:lookup(Tab, {From, To}) of
	[] ->
	    ets:insert(Tab, {{From, To}, 1});
	[_Object] ->
	    ets:update_counter(Tab, {From,To}, 1)
    end.

get_groups() ->
    sdmon_master:groups(sdmon_master:get_state(dc)).

show(WEBNode, File) ->
    to_file(File),
    to_web(WEBNode).


to_file(File) ->
    L = ets:tab2list(in_tab),
    {ok, Dev} = file:open(File, [write]),
    io:format(Dev, "~p",[L]),
    file:close(Dev).  

to_web(WEBNode) ->
    {ws_handler, WEBNode} ! clear,
    to_web_loop(ets:tab2list(ig_tab), WEBNode).
to_web_loop([], _) ->  done;
to_web_loop([H|T], WEBNode) ->
    {ws_handler, WEBNode} ! H,
    to_web_loop(T, WEBNode).
    
    
