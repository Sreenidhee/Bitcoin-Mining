%% Worker actor. This is where all the actual SHA-256 hashing happens -
%% the boss just hands out ranges and collects results.
%%
%% loop: ask boss for work -> hash every candidate in the range -> send
%% any bitcoins found -> ask for more work
%%
%% Same code runs whether the worker is local (same node as the boss) or
%% remote - Boss is just a pid in the first case and {bitcoin_boss, Node}
%% in the second. A worker only ever sends coins to the boss, it never
%% prints one itself.
-module(bitcoin_worker).

-include("bitcoin.hrl").

-export([start_local/2, start_remote/2, worker_init/1]).

%% these are also used by bitcoin_boss (to re-check results) and by
%% project1:self_test/0
-export([mine_range/4, sha256_hex/1, to_hex/1,
         leading_zeroes/1, has_leading_zeroes/2, candidate/1]).

%% lookup table for hex conversion, compile-time constant
-define(HEX_DIGITS, {$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,$a,$b,$c,$d,$e,$f}).

%% spawn N local worker processes, all reporting to Boss. using plain
%% spawn (not spawn_link) so a worker dying can't take anything else
%% down with it - the boss monitors workers separately instead.
start_local(Boss, N) when is_integer(N), N > 0 ->
    [spawn(?MODULE, worker_init, [Boss]) || _ <- lists:seq(1, N)].

%% same idea but for a remote boss, plus a small helper process that
%% shuts this node down once all its workers have stopped (boss ran out
%% of work, or the server went away)
start_remote(ServerNode, N) when is_integer(N), N > 0 ->
    Boss  = {?BOSS_NAME, ServerNode},
    Pids  = [spawn(?MODULE, worker_init, [Boss]) || _ <- lists:seq(1, N)],
    spawn(fun() -> wait_for_workers(Pids) end),
    ok.

wait_for_workers(Pids) ->
    Refs = [erlang:monitor(process, P) || P <- Pids],
    collect(Refs).

collect([]) ->
    %% routine shutdown, not an error - stays silent (see project1:join/2
    %% for why a worker only ever prints genuine fault conditions)
    init:stop();
collect(Refs) ->
    receive
        {'DOWN', Ref, process, _Pid, _Reason} ->
            collect(Refs -- [Ref])
    end.

%% monitor the boss so we don't block forever if it dies / node drops
worker_init(Boss) ->
    Ref = erlang:monitor(process, Boss),
    worker_loop(Boss, Ref).

worker_loop(Boss, Ref) ->
    Boss ! {request_work, self()},
    receive
        {work, Start, Count, K} ->
            mine_range(Start, Count, K, Boss),
            %% Asking for the next unit is also how the worker reports
            %% that the previous unit is complete.
            worker_loop(Boss, Ref);
        no_more_work ->
            erlang:demonitor(Ref, [flush]),
            ok;
        {'DOWN', Ref, process, _Object, normal} ->
            %% boss finished (bounded run ended, or was stopped on
            %% purpose with kill/SIGTERM) - not an error, stay quiet
            ok;
        {'DOWN', Ref, process, _Object, Reason} ->
            %% boss node crashed or became unreachable unexpectedly -
            %% this is a real fault, worth explaining before exiting
            io:format(standard_error, "[worker] boss unreachable (~p), stopping~n", [Reason]),
            ok
    end.

%% hashes Count candidates starting at Start, sends any bitcoin found
%% straight to the boss as soon as it's found (not batched)
mine_range(_N, 0, _K, _Boss) ->
    ok;
mine_range(N, Count, K, Boss) ->
    Digits = integer_to_list(N),
    %% An iolist is passed to crypto:hash/2 so that the prefix and the
    %% digits are not copied into a new flat string for every candidate.
    Digest = crypto:hash(sha256, [?PREFIX, Digits]),
    case has_leading_zeroes(Digest, K) of
        true ->
            Boss ! {coin, ?PREFIX ++ Digits, to_hex(Digest), leading_zeroes(Digest)};
        false ->
            ok
    end,
    mine_range(N + 1, Count - 1, K, Boss).

candidate(N) ->
    ?PREFIX ++ integer_to_list(N).

sha256_hex(Data) ->
    to_hex(crypto:hash(sha256, Data)).

%% binary digest -> lowercase hex string, 2 chars per byte
to_hex(Bin) ->
    to_hex(Bin, []).

to_hex(<<>>, Acc) ->
    lists:reverse(Acc);
to_hex(<<Hi:4, Lo:4, Rest/binary>>, Acc) ->
    to_hex(Rest, [element(Lo + 1, ?HEX_DIGITS), element(Hi + 1, ?HEX_DIGITS) | Acc]).

%% checks for K leading zero hex digits without converting to hex first.
%% one hex digit = 4 bits, so K zero digits is just "first K*4 bits are
%% 0" - can check that directly on the binary with a pattern match. this
%% is the inner loop of the whole program so it matters that it's cheap;
%% we only build the hex string for the rare candidate that wins.
%% (K=0 matches a zero-width segment, which matches everything - fine)
has_leading_zeroes(Digest, K) ->
    Bits = K * 4,
    case Digest of
        <<0:Bits, _/bitstring>> -> true;
        _                       -> false
    end.

leading_zeroes(Digest) ->
    count_zero_nibbles(Digest, 0).

count_zero_nibbles(<<0:4, Rest/bitstring>>, N) ->
    count_zero_nibbles(Rest, N + 1);
count_zero_nibbles(_, N) ->
    N.
