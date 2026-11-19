# COP5615 Project 1 - Bitcoin Mining in Erlang

## Group 6

| | Member 1 | Member 2 |
|---|---|---|
| Name | Sreenidhee Vidya Modugu | Manvitha Gangasani |
| UF ID | 7634 8994 | 3747 1957 |

Every candidate string is prefixed with Sreenidhee's GatorLink ID: `modugus;<n>`
(the assignment only requires one team member's ID for this).

## What it does

Searches for strings `modugus;0`, `modugus;1`, `modugus;2`, ... whose SHA-256
hash starts with `k` zero hex digits, where `k` is given on the command line.
A **boss** process hands out ranges of the search space to **worker**
processes (one per CPU core). Workers hash their range and report any hits
back to the boss, which verifies and prints them. Workers can also run on a
different machine and connect to the boss over the network.

## Files

- `bitcoin.hrl` - shared constants
- `project1.erl` - command line entry point, starts server or worker mode
- `bitcoin_boss.erl` - boss process (hands out work, prints results)
- `bitcoin_worker.erl` - worker process (does the hashing)
- `check_coins.py` - independently checks a run's output against Python's hashlib
- `run_checks.sh` - runs all the checks below and prints PASS/FAIL

## Compile

```sh
erlc *.erl
```

## Run all test cases

```sh
./run_checks.sh
```

Compiles the code and runs 12 checks - SHA-256 correctness, k=0, k=1, the
required k=4 test, a non-overlap proof (compares output against an
independent Python brute force), a distributed run with a remote worker,
and the CPU/real time ratio - printing PASS/FAIL for each. Takes under a
minute.

## Run

Local mining (starts a boss + one worker per CPU core):
```sh
erl -noshell -pa . -run project1 main 4
```
`4` is the difficulty. Stop with Ctrl-C (then `a`) or `kill <pid>` from
another terminal - it prints a summary before exiting.

Server (accepts remote workers, also mines on its own):
```sh
erl -noshell -name bitcoin_server@<SERVER-IP> -setcookie bitcoin -pa . -run project1 main 4
```

Worker (connects to a server on another machine):
```sh
erl -noshell -name worker1@<WORKER-IP> -setcookie bitcoin -pa . -run project1 main <SERVER-IP>
```
A worker prints nothing itself - all results are shown by the server.

Both machines need `-name` (not `-sname`), the same `-setcookie` value, and
need to be able to reach each other over the network (epmd on port 4369).

Optional extra arguments: `project1 main <k> [Limit] [WorkUnitSize] [Workers]`.

## SHA-256 check

```sh
erl -noshell -pa . -eval "project1:self_test()" -s init stop
```
```
input           : COP5615 is a boring class
computed sha256 : fb4431b6a2df71b6cbad961e08fa06ee6fff47e3bc14e977f4b2ea57caee48a4
SELF TEST: PASS
```
Matches the value given in the assignment.

## Work unit size

The work unit is how many candidates a worker gets per request (set in
`bitcoin.hrl`, default `100000`). Tested different sizes at k=4 over 20
million candidates (4 workers, same 324 coins found every time):

| work unit | time (s) | CPU/real ratio |
|---:|---:|---:|
| 10 | 3.18 | 2.70 |
| 100 | 2.15 | 2.97 |
| 1,000 | 1.76 | 3.94 |
| 10,000 | 1.70 | 3.99 |
| **100,000** | **1.65** | **3.99** |
| 1,000,000 | 1.74 | 3.98 |

Below a few thousand, workers spend too much time asking the boss for more
work instead of hashing. Above 10,000 it flattens out. Picked 100,000
because it's on the flat part of the curve and still small enough that a
remote worker isn't stuck waiting a long time for one unit over the network.

## Result for k = 4

```sh
erl -noshell -pa . -run project1 main 4
```

Sample output (input, TAB, hash):
```
modugus;110972	00008cb177fbbdd3242488d6d61014d71bfd5d2b92141fd1a7f35e02509ca958
modugus;20385	0000c3b8b998f1d2cb74a6892c649a4e77f6b26c3f43959b906ed4250fc86162
modugus;521440	00005ffc1cd2a1eb8f45a5c74aa6e8f2eae34af25eec093ce1543203b31793db
modugus;120519	0000628e1a178562681b243894752dc00dd2fede3bf5b9fd67b2963e95d9e361
```

All output was independently checked with `check_coins.py` against Python's
own SHA-256 - every hash matches, every hash has 4 leading zeroes, and every
input starts with `modugus`.

## Running time (k = 4, 20,000,000 candidates, 8 workers)

| | |
|---|---|
| real time | 3.31 s |
| CPU time | 23.91 s |
| CPU / real ratio | 7.33 |

A ratio near 1.0 would mean no real parallelism (one core doing all the
work). 7.33 out of a possible 8 means the program is using almost the whole
machine at once.

## Coin with the most leading zeroes

```
input:  modugus;544826459
sha256: 0000000a6797bd2d44e0a1127c445018f2f973b3a9afb4c84a63571cdbf909b4
leading zeroes: 7
```
Found running k=7 over 4 billion candidates.

## Machines tested

Ran across 2 separate physical machines: a MacBook Air (server) and a
Windows laptop (worker), connected over Wi-Fi. Server started first with
its own local workers, then the Windows machine joined mid-run:

```
worker actors seen per node : [{'bitcoin_server@192.168.1.244',8},
                               {'worker1@192.168.1.71',8}]
machines (Erlang nodes)     : 2
```

1,473 bitcoins found together (k=5, 69 seconds), all independently checked
against Python's hashlib - every hash correct, every input correctly
prefixed, nothing printed on the worker's side.

## Other cases checked

k=0, k=1, negative k, k>64, bad hostname, wrong cookie, worker started
before server, worker crashing mid-range (its range gets reassigned, no
duplicate coins printed), a worker joining after the server already started
mining.
