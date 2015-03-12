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

insert(in, From, To) ->                   % to be called from master node only
    insert(in, From, To, node()).
insert(in, From, To, MasterNode) ->
    {sdmon_db, MasterNode} ! {in, From, To}.

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
    Tab = ets:new(in_tab, [ordered_set,named_table,public]),
    Groups = get_groups(),
    {ok,Tref} = timer:apply_interval(Refresh, ?MODULE, to_file, 
				     [Tab, "/tmp/in_tab.txt"]),
    loop(Tab, Groups, Tref).

loop(Tab, Groups, Tref) ->
    receive
	{in, From, To} ->
	    increment(Tab, From, To),
	    loop(Tab, Groups, Tref);
	stop ->
	    timer:cancel(Tref),
	    flush(Tab),
	    stop
    end.

flush(Tab) ->
    receive
	{in, From, To} ->
	    increment(Tab, From, To),
	    to_file(Tab, "/tmp/in_tab.txt"),
	    flush(Tab)
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

to_file(Tab, File) ->
    L = ets:tab2list(Tab),
    {ok, Dev} = file:open(File, [write]),
    io:format(Dev, "~p",[L]),
    file:close(Dev).    
    
    
