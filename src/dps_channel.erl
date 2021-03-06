-module(dps_channel).
-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").
% -ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
% -endif.

-export([start_link/1]).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-export([publish/2,
         messages/2,
         unsubscribe/1,
         subscribe/1,
         subscribe/2,
         multi_fetch/2,
         multi_fetch/3,
         find/1,

         channels_table/0,


         prepend_sorted/2,
         messages_newer/2,

         dumper/1,
         messages_limit/0,
         replicate_messages/3,
         replicate/5,
         msgs_from_peers/2]).


-record(state, {
    subscribers = []    :: list(),
    messages = []       :: list(),
    last_ts = 0         :: non_neg_integer(),
    limit               :: non_neg_integer(),
    tag                 :: term(),
    replicator          :: pid()
}).

%%
%% External API
%%

-spec messages_limit() -> non_neg_integer().
messages_limit() ->
    40.

-spec channels_table() -> Table::term().
channels_table() -> dps_channels_table.


-spec publish(Tag :: dps:tag(), Msg :: dps:message()) -> TS :: dps:timestamp().
publish(Tag, Msg) ->
    TS = dps_util:ts(),
    Pid = find(Tag),
    {_,Len} = process_info(Pid,message_queue_len),
    if 
        Len > 1000 -> throw(dps_busy);
        Len > 100 -> timer:sleep(20*Len);
    true -> ok end,
    % FIXME: this is a debug output to notify busy channels
    % case process_info(find(Tag), messages) of
    %     {messages, Messages} when length(Messages) > 20 ->
    %         ?debugFmt("Warning! Channel ~s is overloaded. Delay publish: ~p", [Tag, Messages]),
    %         timer:sleep(500);
    %     _ -> ok
    % end,
    try gen_server:call(find(Tag), {publish, Msg, TS}, 3000)
    catch
      exit:{timeout,_} = Error ->
        {_,Len1} = process_info(Pid,message_queue_len),
        % ?debugFmt("Error timeout in publish ~B to ~s with ~B messages ~p~n:~n~p~n", [TS, Tag, Len, Messages, process_info(find(Tag))]),
        erlang:raise(exit, {publish,Tag,Len,Len1,Error}, erlang:get_stacktrace())
    end,
    TS.


replicate_messages(Pid, LastTS, Msgs) ->
    gen_server:call(Pid, {replication_messages, LastTS, Msgs}).


-spec messages(Tag :: dps:tag(), Timestamp :: dps:timestamp()) -> 
    {ok, TS :: dps:timestamp(), [Message :: term()]}.
messages(Tag, TS) when is_number(TS) ->
    {ok, LastTS, Messages} = gen_server:call(find(Tag), {messages, TS}),
    {ok, LastTS, Messages}.


-spec subscribe(Tag :: dps:tag()) -> Msgs :: non_neg_integer().
subscribe(Tag) ->
    subscribe(Tag, 0).

-spec subscribe(Tag :: dps:tag(), TS :: dps:timestamp()) ->
                                                    Msgs :: non_neg_integer().
subscribe(Tag, TS) ->
    gen_server:call(find(Tag), {subscribe, self(), TS}).


-spec unsubscribe(Tag :: term()) -> ok.
unsubscribe(Tag) ->
    gen_server:call(find(Tag), {unsubscribe, self()}).


-spec find(Tag :: term()) -> Pid :: pid().
find(Pid) when is_pid(Pid) ->
    Pid;
find(Tag) ->
    case dps_channels_manager:find(Tag) of
        {Tag, Pid, _} -> Pid;
        undefined -> erlang:throw({no_channel,Tag})
    end.


-spec multi_fetch([Tag :: dps:tag()], TS :: dps:timestamp()) ->
    {ok, LastTS :: dps:timestamp(), [Message :: term()]}.
multi_fetch(Tags, TS) ->
    multi_fetch(Tags, TS, 60000).


-spec multi_fetch([Tag :: dps:tag()], TS :: dps:timestamp(),
        Timeout :: non_neg_integer()) ->
            {ok, LastTS :: dps:timestamp(), [Message :: term()]}.
multi_fetch(Tags, TS, Timeout) ->
    [subscribe(Tag, TS) || Tag <- Tags],
    % FIXME: this is a temporary debug sleep to make replies less CPU intensive
    % timer:sleep(500),
    receive
        {dps_msg, _Tag, LastTS, Messages} ->
            [unsubscribe(Tag) || Tag <- Tags],
            receive_multi_fetch_results(LastTS, Messages)
    after
        Timeout ->
            [unsubscribe(Tag) || Tag <- Tags],
            receive_multi_fetch_results(TS, [])
    end.


-spec msgs_from_peers(Tag :: dps:tag(), CallbackPid :: pid()) -> ok.
msgs_from_peers(Tag, CallbackPid) ->
    Pid = dps_channels_manager:find(Tag),
    Pid ! {give_me_messages, CallbackPid},
    ok.

-spec start_link(Tag :: dps:tag()) -> Result :: {ok, pid()} | {error, term()}.
start_link(Tag) ->
    gen_server:start_link(?MODULE, Tag, []).

%%
%% gen_server callbacks
%%

-spec init(Tag :: dps:tag()) -> {ok, #state{}}.
init(Tag) ->
    self() ! replicate_from_peers,
    put(publish_count,0),
    put(publish_time,0),
    put(subscribe_count,0),
    put(subscribe_time,0),
    put(unsubscribe_count,0),
    put(unsubscribe_time,0),
    put(tag,Tag),
    % FIXME: this is enabling debug output for channel
    % Self = self(),
    % spawn(fun() -> dumper(Self) end),
    {ok, #state{tag = Tag, limit = ?MODULE:messages_limit()}}.

dumper(Pid) ->
    {dictionary,Dict} = process_info(Pid,dictionary),
    Tag = proplists:get_value(tag,Dict),
    SubCount = proplists:get_value(subscribe_count,Dict),
    SubTime = proplists:get_value(subscribe_time,Dict),

    UnsubCount = proplists:get_value(unsubscribe_count,Dict),
    UnsubTime = proplists:get_value(unsubscribe_time,Dict),
    PubCount = proplists:get_value(publish_count,Dict),
    PubTime = proplists:get_value(publish_time,Dict),
    if PubCount > 0 ->
    io:format("Chan ~s: publish ~B/~B, subscribe ~B/~B, unsubscribe: ~B/~B~n", [Tag, 
        PubCount,PubTime,SubCount,SubTime, UnsubCount,UnsubTime]);
    true -> ok end,
    timer:sleep(1000),
    dumper(Pid).


handle_call({publish, Msg, TS}, _From, State = #state{messages = Msgs, limit = Limit,
                            replicator = Replicator, subscribers = Subscribers, tag = Tag}) ->
    T1 = erlang:now(),
    % gen_server:reply(From, ok),
    Messages1 = prepend_sorted({TS,Msg}, Msgs),
    Messages = if
        length(Messages1) >= Limit*2 -> lists:sublist(Messages1, Limit);
        true -> Messages1
    end,
    [{LastTS, _}|_] = Messages,
    distribute_message({dps_msg, Tag, LastTS, [Msg]}, Subscribers),

    ?MODULE:replicate(Replicator, LastTS, TS, Msg, Limit),
    T2 = erlang:now(),
    put(publish_count,get(publish_count)+1),
    put(publish_time,get(publish_time)+timer:now_diff(T2,T1)),
    {reply, ok, State#state{messages = Messages, last_ts = LastTS}};

handle_call({subscribe, Pid, TS}, _From, State = #state{messages = Messages, tag = Tag,
                                                subscribers = Subscribers, last_ts = LastTS}) ->
    T1 = erlang:now(),
    Ref = erlang:monitor(process, Pid),
    Msgs = messages_newer(Messages, TS),
    case Msgs of
        [] -> ok;
        _ -> Pid ! {dps_msg, Tag, LastTS, Msgs}
    end,
    NewState = State#state{subscribers = [{Pid,Ref} | Subscribers]},
    T2 = erlang:now(),
    put(subscribe_count,get(subscribe_count)+1),
    put(subscribe_time,get(subscribe_time)+timer:now_diff(T2,T1)),
    {reply, length(Msgs), NewState};

handle_call({unsubscribe, Pid}, _From, State = #state{subscribers = Subscribers}) ->
    T1 = erlang:now(),
    {Delete, Remain} = lists:partition(fun({P,_Ref}) -> P == Pid end, Subscribers),
    [erlang:demonitor(Ref) || {_Pid,Ref} <- Delete],
    NewState = State#state{subscribers = Remain},
    T2 = erlang:now(),
    put(unsubscribe_count,get(unsubscribe_count)+1),
    put(unsubscribe_time,get(unsubscribe_time)+timer:now_diff(T2,T1)),
    {reply, ok, NewState};

handle_call({messages, TS}, _From, State = #state{last_ts = LastTS, messages = AllMessages}) ->
    Messages = messages_newer(AllMessages, TS),
    {reply, {ok, LastTS, Messages}, State};

handle_call({replication_messages, LastTS1, Msgs}, _From, State = #state{}) ->
    {reply, ok, replication_messages(LastTS1, Msgs, State)};

handle_call(_Msg, _From, State) ->
    {reply, {error, {unknown_call, _Msg}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

distribute_message(Message, Subscribers) ->
    [Sub ! Message || {Sub, _Ref} <- Subscribers].


replicate(Replicator, LastTS, TS, Msg, Limit) ->
    case erlang:process_info(Replicator, message_queue_len) of
        {message_queue_len, QueueLen} when QueueLen > Limit ->
            % gen_server:call(Replicator, {message, LastTS, {TS, Msg}});
            % for now we just skip messages, if replicator is too slow
            ok;
        undefined ->
            ok;
        _ ->
            Replicator ! {message, LastTS, {TS, Msg}}
    end.


handle_info(replicate_from_peers, State = #state{tag = Tag}) ->
    {ok, Replicator} = dps_sup:channel_replicator(Tag),
    rpc:multicall(nodes(), ?MODULE, msgs_from_peers, [Tag, self()]),
    {noreply, State#state{replicator = Replicator}};


handle_info({give_me_messages, Pid}, State = #state{last_ts = LastTS, messages = Messages}) ->
    Pid ! {replication_messages, LastTS, Messages},
    {noreply, State};

handle_info({replication_messages, LastTS1, Msgs}, State = #state{}) ->
    {noreply, replication_messages(LastTS1, Msgs, State)};

handle_info({'DOWN', Ref, _, Pid, _}, State = #state{subscribers=Subscribers}) ->
    {noreply, State#state{subscribers = Subscribers -- [{Pid,Ref}]}};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%%
%% Internal functions
%%


replication_messages(_, [], State) ->
    State;

replication_messages(LastTS1, Msgs, State = #state{messages = Messages, tag = Tag,
                                                subscribers = Subscribers, last_ts = LastTS2}) ->
    LastTS = lists:max([LastTS1, LastTS2]),
    Messages1 = lists:foldl(fun(M, List) ->
        prepend_sorted(M,List)
    end, Messages, Msgs),

    SendMessage = {dps_msg, Tag, LastTS, [M || {_TS, M} <- Msgs]},
    [Sub ! SendMessage || {Sub, _Ref} <- Subscribers],
    State#state{last_ts = LastTS, messages = Messages1 }.
        


-spec receive_multi_fetch_results(LastTS :: non_neg_integer(),
        Messages :: list()) ->
            {ok, LastTS :: non_neg_integer(), Messages :: list()}.
receive_multi_fetch_results(LastTS, Messages) ->
    receive
        {dps_msg, _Tag, LastTS1, Messages1} ->
            receive_multi_fetch_results(LastTS1, Messages ++ Messages1)
    after
        0 ->
            {ok, LastTS, Messages}
    end.

%% WARNING!
%% This is a very thin place. We use erlang:now() together with
%% messages contents as a unique identifier across nodes
%%
prepend_sorted({TS,Msg}, [{TS,Msg}|_] = Messages) ->
    Messages;

prepend_sorted({TS1,Msg1}, [{TS2,_Msg2}|_] = Messages) when TS1 >= TS2 ->
    [{TS1,Msg1}|Messages];

prepend_sorted({TS,Msg}, []) ->
    [{TS,Msg}];

prepend_sorted({TS1,Msg1}, [{TS2,Msg2}|Messages]) when TS1 < TS2 ->
    [{TS2,Msg2}|prepend_sorted({TS1,Msg1}, Messages)].


messages_newer(Messages, TS) ->
    messages_newer(Messages, TS, []).

messages_newer([{TS1,Msg1}|Messages], TS, Acc) when TS1 > TS ->
    messages_newer(Messages, TS, [Msg1|Acc]);

messages_newer(_Messages, _TS, Acc) ->
    Acc.

