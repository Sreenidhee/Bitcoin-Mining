%% COP5615 Project 1 - bitcoin mining with SHA-256.
%%
%% Command line entry point. If the argument is an integer, this node
%% becomes the server (boss + local workers) and mines for hashes with
%% that many leading zeroes. If it's a hostname/IP instead, this node
%% becomes a worker that connects to a server already running there.
%%
%%   project1 <k>            server mode
%%   project1 <host-or-ip>   worker mode
%%
%% A few optional extra args after the main one (all have defaults) -
%% mostly there for the work-unit / worker-count benchmarking in the
%% README:
%%
%%   project1 <k> [Limit] [WorkUnitSize] [NumWorkers]
%%   project1 <host-or-ip> [NumWorkers]
%%
%% stdout only ever gets bitcoin lines ("<input><TAB><sha256>"), every
%% status/error message goes to stderr so `... > coins.txt` stays clean.
-module(project1).

-include("bitcoin.hrl").

-export([main/0, main/1, self_test/0]).

%% erl -run project1 main with no args at all calls main/0
main() ->
    usage("no argument given").

main(RawArgs) ->
    logs_to_stderr(),
    case [to_list(A) || A <- RawArgs] of
        [First | Rest] ->
            case parse_mode(First) of
                {difficulty, K} -> start_server(K, Rest);
                {server, Host}  -> start_worker(Host, Rest);
                {error, Reason} -> usage(Reason)
            end;
        [] ->
            usage("no argument given")
    end.

%% redirect erlang's own crash reports / distribution warnings to
%% stderr, otherwise a node dying mid-run can print junk to stdout
%% right in the middle of our bitcoin output
logs_to_stderr() ->
    try
        {ok, Cfg0} = logger:get_handler_config(default),
        Module     = maps:get(module, Cfg0),
        HandlerCfg = maps:get(config, Cfg0, #{}),
        %% logger_std_h won't change its output device in place, so just
        %% swap in a new handler with the same config pointed at stderr
        Cfg = (maps:without([id, module], Cfg0))#{
                config => HandlerCfg#{type => standard_error}},
        _  = logger:remove_handler(default),
        ok = logger:add_handler(default, Module, Cfg)
    catch
        _:_ -> ok
    end.

%% integer -> difficulty (server mode). anything else -> assume it's a
%% server address (hostname, IP, or full node name like bitcoin_server@1.2.3.4)
parse_mode(Arg) ->
    case is_integer_string(Arg) of
        true ->
            case list_to_integer(Arg) of
                K when K < 0 ->
                    {error, "difficulty must be >= 0"};
                K when K > 64 ->
                    {error, "difficulty must be =< 64 (a SHA-256 digest "
                            "only has 64 hexadecimal digits)"};
                K ->
                    {difficulty, K}
            end;
        false ->
            case is_valid_host(Arg) of
                true  -> {server, Arg};
                false -> {error, "\"" ++ Arg ++ "\" is neither an integer "
                                 "difficulty nor a valid hostname/IP address"}
            end
    end.

start_server(K, Opts) ->
    Limit   = opt(Opts, 1, infinity),
    Unit    = opt(Opts, 2, ?DEFAULT_WORK_UNIT),
    Workers = opt(Opts, 3, erlang:system_info(schedulers_online)),
    case {valid_limit(Limit), is_pos(Unit), is_pos(Workers)} of
        {true, true, true} ->
            ensure_distributed(?SERVER_NODE_BASE, {8,8,8,8}),
            Boss = bitcoin_boss:start(K, Limit, Unit),
            bitcoin_worker:start_local(Boss, Workers),
            banner(K, Limit, Unit, Workers),
            ok;
        _ ->
            usage("optional arguments must be positive integers")
    end.

banner(K, Limit, Unit, Workers) ->
    E = standard_error,
    io:format(E, "[server] node ................: ~p~n", [node()]),
    io:format(E, "[server] cookie ..............: ~p~n", [erlang:get_cookie()]),
    io:format(E, "[server] difficulty (k) ......: ~p leading zero hex digits~n", [K]),
    io:format(E, "[server] candidate format ....: ~s<n>~n", [?PREFIX]),
    io:format(E, "[server] work unit size ......: ~p candidates~n", [Unit]),
    io:format(E, "[server] local worker actors .: ~p (schedulers_online = ~p)~n",
              [Workers, erlang:system_info(schedulers_online)]),
    io:format(E, "[server] search space ........: ~s~n", [limit_text(Limit)]),
    io:format(E, "[server] remote workers join with:~n", []),
    io:format(E, "         erl -noshell -name worker@<THAT-MACHINE-IP> "
                 "-setcookie ~s -pa . -run project1 main ~s~n",
              [erlang:get_cookie(), node()]),
    io:format(E, "[server] mining; stdout lines are \"<input><TAB><sha256>\"~n", []).

limit_text(infinity) -> "unlimited (Ctrl-C to stop; `kill <os pid>' "
                        "stops it and prints a summary)";
limit_text(N)        -> integer_to_list(N) ++ " candidates, then a summary is printed".

start_worker(Arg, Opts) ->
    Workers = opt(Opts, 1, erlang:system_info(schedulers_online)),
    case is_pos(Workers) of
        false ->
            usage("worker count must be a positive integer");
        true ->
            {ServerNode, Host} = server_node(Arg),
            case inet:gethostbyname(Host) of
                {error, Why} ->
                    fail("cannot resolve \"" ++ Host ++ "\" (~p). Give the "
                         "server's IP address or a resolvable hostname.", [Why]);
                {ok, _} ->
                    ensure_distributed(?WORKER_NODE_BASE ++ "_" ++ os:getpid(), Host),
                    join(ServerNode, Workers)
            end
    end.

%% accepts either a plain address ("10.0.0.5" - node name gets derived)
%% or the full node name ("bitcoin_server@10.0.0.5") from the server banner
server_node(Arg) ->
    case string:tokens(Arg, "@") of
        [_Name, Host] -> {list_to_atom(Arg), Host};
        [Host]        -> {list_to_atom(?SERVER_NODE_BASE ++ "@" ++ Host), Host};
        _             -> fail("~s is not a valid node name or address", [Arg])
    end.

%% the spec says a worker "will not display anything" - taken literally
%% here: no routine status chatter at all, not even to stderr. The only
%% output a worker ever produces is a fatal error (can't resolve the
%% host, can't connect, no boss there) that stops it before it starts,
%% which is a startup failure rather than a "result" - a worker that
%% failed silently with zero explanation would just be bad usability.
join(ServerNode, Workers) ->
    case net_kernel:connect_node(ServerNode) of
        true ->
            case rpc:call(ServerNode, erlang, whereis, [?BOSS_NAME]) of
                Pid when is_pid(Pid) ->
                    bitcoin_worker:start_remote(ServerNode, Workers);
                _ ->
                    fail("connected to ~p but no boss is registered there. "
                         "Start the server first with: erl -noshell -name ~p "
                         "-setcookie ~p -pa . -run project1 main <k>",
                         [ServerNode, ServerNode, erlang:get_cookie()])
            end;
        false ->
            fail("could not connect to ~p.~n"
                 "  * is the server running (erl ... -run project1 main <k>)?~n"
                 "  * do both nodes use the same cookie (~p here)?~n"
                 "  * is epmd reachable on TCP 4369 and the distribution port open?~n"
                 "  * are both nodes started with -name (long names), not -sname?",
                 [ServerNode, erlang:get_cookie()])
    end.

%% normally the node's already alive because -name was passed on the
%% command line. if not, we start distribution ourselves, picking the
%% local IP that actually routes towards Target (so a remote node has
%% something to send replies back to).
ensure_distributed(Base, Target) ->
    case node() of
        'nonode@nohost' ->
            Name = list_to_atom(Base ++ "@" ++ local_host(Target)),
            %% erl only starts epmd by itself when -name/-sname is on
            %% the command line, so make sure it's up before we try this
            os:cmd("epmd -daemon"),
            case net_kernel:start([Name, longnames]) of
                {ok, _} ->
                    set_cookie_if_needed(),
                    io:format(standard_error,
                              "[info] Erlang distribution started automatically as ~p~n",
                              [node()]);
                {error, Reason} ->
                    fail("could not start Erlang distribution: ~p.~n"
                         "  Start the VM with -name <name>@<ip> instead.", [Reason])
            end;
        _Alive ->
            set_cookie_if_needed()
    end.

%% respect an explicit -setcookie if given, otherwise fall back to our
%% own default so the README commands work without extra setup
set_cookie_if_needed() ->
    case init:get_argument(setcookie) of
        {ok, _} -> ok;
        error   -> erlang:set_cookie(node(), ?COOKIE)
    end.

local_host(Target) ->
    case route_address(Target) of
        {ok, IP} -> inet:ntoa(IP);
        error    -> net_adm:localhost()
    end.

%% "connecting" a UDP socket doesn't send anything, it just makes the OS
%% pick an outgoing interface, and we read that address back
route_address(Target) ->
    case gen_udp:open(0) of
        {ok, Sock} ->
            Result =
                case gen_udp:connect(Sock, Target, 9) of
                    ok ->
                        case inet:sockname(Sock) of
                            {ok, {{0,0,0,0}, _}} -> error;
                            {ok, {IP, _Port}}    -> {ok, IP};
                            _                    -> error
                        end;
                    _ ->
                        error
                end,
            gen_udp:close(Sock),
            Result;
        _ ->
            error
    end.

%% run with: erl -noshell -pa . -eval "project1:self_test()" -s init stop
self_test() ->
    Input    = "COP5615 is a boring class",
    Expected = "fb4431b6a2df71b6cbad961e08fa06ee6fff47e3bc14e977f4b2ea57caee48a4",
    Actual   = bitcoin_worker:sha256_hex(Input),
    io:format("input           : ~s~n",  [Input]),
    io:format("expected sha256 : ~s~n",  [Expected]),
    io:format("computed sha256 : ~s~n",  [Actual]),
    io:format("digest length   : ~p hexadecimal characters~n", [length(Actual)]),
    Ok1 = (Actual =:= Expected) andalso (length(Actual) =:= 64),
    io:format("reference vector: ~s~n", [pass(Ok1)]),

    %% this candidate is known to have 6 leading zeroes, so it exercises
    %% the leading-zero check right around the boundary
    Sample  = bitcoin_worker:candidate(18169626),
    Digest  = crypto:hash(sha256, Sample),
    Zeroes  = bitcoin_worker:leading_zeroes(Digest),
    io:format("sample candidate: ~s -> ~s (~p leading zeroes)~n",
              [Sample, bitcoin_worker:to_hex(Digest), Zeroes]),
    Ok2 = lists:all(fun(K) ->
                        bitcoin_worker:has_leading_zeroes(Digest, K) =:= (K =< Zeroes)
                    end, lists:seq(0, 64)),
    io:format("leading-zero test at k = 0..64: ~s~n", [pass(Ok2)]),
    io:format("SELF TEST: ~s~n", [pass(Ok1 andalso Ok2)]),
    ok.

pass(true)  -> "PASS";
pass(false) -> "FAIL".

to_list(A) when is_atom(A)   -> atom_to_list(A);
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L)                   -> L.

%% Nth optional arg, or Default if it wasn't given
opt(Opts, N, _Default) when length(Opts) >= N ->
    Arg = lists:nth(N, Opts),
    case is_integer_string(Arg) of
        true  -> list_to_integer(Arg);
        false -> invalid
    end;
opt(_Opts, _N, Default) ->
    Default.

is_pos(N) when is_integer(N), N > 0 -> true;
is_pos(_)                           -> false.

valid_limit(infinity) -> true;
valid_limit(N)        -> is_pos(N).

is_integer_string([$- | Rest]) -> is_digits(Rest);
is_integer_string(S)           -> is_digits(S).

is_digits([])    -> false;
is_digits(S)     -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, S).

%% loose check for a valid-looking hostname/IP - not trying to be a
%% full RFC validator, just rejecting obviously wrong stuff
is_valid_host([])   -> false;
is_valid_host(Host) ->
    Allowed = fun(C) ->
                  (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                  (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $- orelse
                  C =:= $: orelse C =:= $@ orelse C =:= $_
              end,
    lists:all(Allowed, Host)
        andalso hd(Host) =/= $. andalso hd(Host) =/= $-
        andalso lists:last(Host) =/= $. andalso lists:last(Host) =/= $-.

usage(Reason) ->
    E = standard_error,
    io:format(E, "error: ~s~n~n", [Reason]),
    io:format(E, "usage:~n", []),
    io:format(E, "  server  : erl -noshell -pa . -name bitcoin_server@<IP> "
                 "-setcookie bitcoin -run project1 main <k> [Limit] [WorkUnit] [Workers]~n", []),
    io:format(E, "  worker  : erl -noshell -pa . -name worker@<IP> "
                 "-setcookie bitcoin -run project1 main <server-ip-or-node> [Workers]~n", []),
    io:format(E, "~n  <k>     number of leading zero hex digits (0..64)~n", []),
    io:format(E, "  Limit   optional: stop after this many candidates and print a summary~n", []),
    io:format(E, "  WorkUnit optional: candidates per work request (default ~p)~n",
              [?DEFAULT_WORK_UNIT]),
    io:format(E, "  Workers optional: number of mining actors (default schedulers_online)~n", []),
    halt(1).

fail(Fmt, Args) ->
    io:format(standard_error, "error: " ++ Fmt ++ "~n", Args),
    halt(1).
