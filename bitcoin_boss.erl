%% Coordinator actor. One boss per run, registered locally so remote
%% workers can reach it as {bitcoin_boss, ServerNode}.
%%
%% Owns the search space (one counter, `next') and is the only process
%% that hands ranges out. Since an Erlang process only handles one
%% message at a time, reading `next' and bumping it happens atomically
%% w.r.t. every worker - no lock needed, two workers just can't end up
%% with the same range.
%%
%% Boss doesn't hash anything itself, it just moves the counter around,
%% double-checks results before printing them, and prints them.
-module(bitcoin_boss).

-include("bitcoin.hrl").

-export([start/3, loop/1]).

%% gen_event callbacks - just used to catch SIGTERM and shut down
%% cleanly with a summary instead of just dying. see install_signal_handler/0
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2]).

-record(state, {
          k                         :: non_neg_integer(),   % required leading zeroes
          next     = 0              :: non_neg_integer(),   % next unassigned index
          limit    = infinity       :: non_neg_integer() | infinity,
          unit                      :: pos_integer(),       % work unit size
          busy     = #{}            :: #{pid() => {integer(), integer()}},
          requeue  = []             :: [{integer(), integer()}],
          monitors = #{}            :: #{pid() => reference()},
          nodes    = #{}            :: #{node() => non_neg_integer()},
          coins    = 0              :: non_neg_integer(),
          best     = none           :: none | {non_neg_integer(), string(), string()},
          assigned = 0              :: non_neg_integer(),
          reported = 0              :: non_neg_integer(),
          seen     = #{}            :: #{non_neg_integer() => true}  % candidate index, not string
         }).

%% Limit is how big the search space is (infinity = run until stopped)
start(K, Limit, Unit) ->
    Pid = spawn(fun() -> boss_init(K, Limit, Unit) end),
    true = register(?BOSS_NAME, Pid),
    install_signal_handler(),
    Pid.

boss_init(K, Limit, Unit) ->
    %% reset the runtime/wall_clock counters here so the summary at the
    %% end reports time since the boss started, not since the VM booted
    erlang:statistics(runtime),
    erlang:statistics(wall_clock),
    loop(#state{k = K, limit = Limit, unit = Unit}).

%% catches SIGTERM (plain `kill <pid>') and turns it into a clean
%% shutdown that still prints the summary, instead of just dying.
%% not doing this for SIGINT/Ctrl-C - Erlang's own break handler owns
%% that one and os:set_signal(sigint, _) just gets rejected.
install_signal_handler() ->
    try
        os:set_signal(sigterm, handle),
        _ = gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
        ok = gen_event:add_handler(erl_signal_server, ?MODULE, [])
    catch
        _:_ -> ok
    end.

init(_Args)                  -> {ok, []}.
handle_event(_Signal, State) -> request_shutdown(), {ok, State}.
handle_call(_Request, State) -> {ok, ok, State}.
handle_info(_Info,    State) -> {ok, State}.
terminate(_Reason,   _State) -> ok.

request_shutdown() ->
    case whereis(?BOSS_NAME) of
        undefined -> init:stop();
        Pid       -> Pid ! shutdown
    end.

loop(State) ->
    receive
        {request_work, Worker} ->
            loop(handle_request(Worker, State));
        {coin, Input, Hash, Zeroes} ->
            loop(handle_coin(Input, Hash, Zeroes, State));
        {'DOWN', _Ref, process, Worker, Reason} ->
            loop(handle_down(Worker, Reason, State));
        shutdown ->
            finish(State);
        Other ->
            io:format(standard_error, "[boss] ignoring unexpected message: ~p~n", [Other]),
            loop(State)
    end.

%% a request_work means "I'm done with the last range, give me another"
handle_request(Worker, State0) ->
    State1 = track_worker(Worker, State0),
    {OldRange, Busy1} = case maps:take(Worker, State1#state.busy) of
                             {R, B} -> {R, B};
                             error  -> {none, State1#state.busy}
                         end,
    %% Worker asking for more work (rather than being reported DOWN)
    %% means OldRange was mined start to finish successfully, so it can
    %% never be reissued again - anything remembered in `seen' for it
    %% can be forgotten. See forget_range/2 below for why this matters.
    State2 = forget_range(OldRange, State1#state{busy = Busy1}),
    case next_range(State2) of
        {none, State3} ->
            Worker ! no_more_work,
            maybe_finish(State3);
        {{Start, Count}, State3} ->
            Worker ! {work, Start, Count, State3#state.k},
            State4 = State3#state{busy = maps:put(Worker, {Start, Count},
                                                  State3#state.busy)},
            maybe_report(State4)
    end.

%% ranges reclaimed from a dead worker get handed out again before we
%% move the `next' pointer forward, so nothing gets silently skipped
next_range(#state{requeue = [Range | Rest]} = S) ->
    {Range, S#state{requeue = Rest}};
next_range(#state{next = Next, limit = Limit, unit = Unit} = S) ->
    Count = case Limit of
                infinity            -> Unit;
                _ when Next >= Limit -> 0;
                _                   -> min(Unit, Limit - Next)
            end,
    case Count of
        0 -> {none, S};
        _ -> {{Next, Count}, S#state{next     = Next + Count,
                                     assigned = S#state.assigned + Count}}
    end.

%% `seen' only needs to remember coins from ranges that could still be
%% reissued (still in flight, or sitting in `requeue' after a crash) -
%% once a range is fully and successfully mined, it's done forever and
%% nothing in it can be rediscovered, so its entries can be dropped.
%% Without this, `seen' would grow for as long as the program runs
%% (worst case on an unlimited low-difficulty run, millions of strings);
%% with it, `seen' stays bounded by roughly (workers x work-unit-size x
%% hit-rate), the same order of magnitude as one round of work.
forget_range(none, State) ->
    State;
forget_range({Start, Count}, #state{seen = Seen} = State) ->
    End = Start + Count,
    State#state{seen = maps:filter(
        fun(N, _) -> N < Start orelse N >= End end, Seen)}.

%% first time we see this worker - start monitoring it (so we notice if
%% it dies or disconnects) and note which node it's on
track_worker(Worker, #state{monitors = Mons, nodes = Nodes} = S) ->
    case maps:is_key(Worker, Mons) of
        true ->
            S;
        false ->
            Ref  = erlang:monitor(process, Worker),
            Node = node(Worker),
            case Node =:= node() of
                true  -> ok;
                false -> io:format(standard_error,
                                   "[boss] remote worker joined from ~p~n", [Node])
            end,
            S#state{monitors = maps:put(Worker, Ref, Mons),
                    nodes    = maps:update_with(Node, fun(C) -> C + 1 end, 1, Nodes)}
    end.

%% worker died, or its node dropped off - put its range back in the queue
handle_down(Worker, Reason, #state{busy = Busy} = S0) ->
    S1 = S0#state{monitors = maps:remove(Worker, S0#state.monitors)},
    case maps:take(Worker, Busy) of
        {Range, Busy1} ->
            io:format(standard_error,
                      "[boss] worker ~p on ~p lost (~p); its range ~p is requeued~n",
                      [Worker, node(Worker), Reason, Range]),
            maybe_finish(S1#state{busy = Busy1, requeue = [Range | S1#state.requeue]});
        error ->
            S1
    end.

%% re-hash everything here before printing it - don't just trust what a
%% worker (possibly on someone else's machine) claims it found.
%%
%% also checked against `seen': when a worker dies mid-range, its whole
%% range gets requeued and remined from the start (see handle_down/3),
%% which can rediscover a coin that already got printed before the
%% crash. `seen' makes sure a given candidate index only ever gets
%% printed once, no matter how many times it's reported - and
%% forget_range/2 keeps it from growing forever (see there for why).
handle_coin(Input, Hash, Zeroes, #state{k = K, seen = Seen} = S) ->
    case valid_coin(Input, Hash, Zeroes, K) of
        {true, N} ->
            case maps:is_key(N, Seen) of
                true ->
                    S; % already printed once, this is a requeue re-find
                false ->
                    io:format("~s\t~s~n", [Input, Hash]),
                    S#state{coins = S#state.coins + 1,
                            best  = better(S#state.best, {Zeroes, Input, Hash}),
                            seen  = maps:put(N, true, Seen)}
            end;
        false ->
            io:format(standard_error,
                      "[boss] discarded unverifiable result ~p from ~p~n",
                      [Input, node()]),
            S
    end.

%% checks the input is a genuine "modugus;<digits>" candidate (not just
%% something that happens to start with "modugus"), and that the hash
%% and leading-zero count the worker claimed are both actually correct.
%% returns {true, N} (the candidate's numeric index, for `seen') or false.
valid_coin(Input, Hash, Zeroes, K) ->
    PrefixLen = length(?PREFIX),
    case lists:prefix(?PREFIX, Input) andalso is_digit_suffix(Input, PrefixLen) of
        false ->
            false;
        true ->
            Digest = crypto:hash(sha256, Input),
            Valid = bitcoin_worker:to_hex(Digest) =:= Hash
                andalso bitcoin_worker:leading_zeroes(Digest) =:= Zeroes
                andalso Zeroes >= K,
            case Valid of
                true  -> {true, list_to_integer(lists:nthtail(PrefixLen, Input))};
                false -> false
            end
    end.

is_digit_suffix(Input, PrefixLen) ->
    Suffix = lists:nthtail(PrefixLen, Input),
    Suffix =/= "" andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Suffix).

better(none, New) ->
    New;
better({Z0, _, _} = Old, {Z1, _, _} = New) ->
    case Z1 > Z0 of true -> New; false -> Old end.

maybe_report(#state{assigned = A, reported = R} = S) when A - R >= ?REPORT_EVERY ->
    io:format(standard_error, "[boss] ~p candidates dispatched, ~p bitcoins found~n",
              [A, S#state.coins]),
    S#state{reported = A};
maybe_report(S) ->
    S.

%% only actually finish once the space is exhausted, the requeue is
%% empty, and no worker is still holding a range
maybe_finish(#state{busy = Busy, requeue = []} = S) when map_size(Busy) =:= 0 ->
    finish(S);
maybe_finish(S) ->
    S.

finish(S) ->
    {_, Cpu}  = erlang:statistics(runtime),
    {_, Wall} = erlang:statistics(wall_clock),
    Out = standard_error,
    io:format(Out, "~n===================== mining finished =====================~n", []),
    io:format(Out, "difficulty (leading zeroes) : ~p~n",   [S#state.k]),
    io:format(Out, "candidates searched         : ~p~n",   [S#state.assigned]),
    io:format(Out, "work unit size              : ~p~n",   [S#state.unit]),
    io:format(Out, "bitcoins found              : ~p~n",   [S#state.coins]),
    io:format(Out, "worker actors seen per node : ~p~n",   [maps:to_list(S#state.nodes)]),
    io:format(Out, "machines (Erlang nodes)     : ~p~n",   [maps:size(S#state.nodes)]),
    report_best(Out, S#state.best),
    io:format(Out, "REAL TIME (wall clock)      : ~.3f s~n", [Wall / 1000]),
    io:format(Out, "CPU TIME  (all schedulers)  : ~.3f s~n", [Cpu / 1000]),
    io:format(Out, "CPU TIME / REAL TIME        : ~.2f~n",   [ratio(Cpu, Wall)]),
    io:format(Out, "===========================================================~n", []),
    %% init:stop, not halt - so buffered stdout gets flushed first
    init:stop(),
    S.

report_best(Out, none) ->
    io:format(Out, "coin with most leading zeroes: none found~n", []);
report_best(Out, {Z, Input, Hash}) ->
    io:format(Out, "coin with most leading zeroes: ~s~n", [Input]),
    io:format(Out, "                        hash : ~s~n", [Hash]),
    io:format(Out, "               leading zeroes: ~p~n", [Z]).

ratio(_Cpu, 0)  -> 0.0;
ratio(Cpu, Wall) -> Cpu / Wall.
