%% shared constants for project1 / bitcoin_boss / bitcoin_worker

%% gatorlink prefix - every candidate string has to start with this
-define(GATORLINK, "modugus").
-define(PREFIX,    "modugus;").

%% name the boss registers under on the server node. remote workers
%% reach it as {?BOSS_NAME, ServerNode}
-define(BOSS_NAME, bitcoin_boss).

%% only used if we have to start distribution ourselves (no -name given)
-define(SERVER_NODE_BASE, "bitcoin_server").
-define(WORKER_NODE_BASE, "bitcoin_worker").

%% default cookie, only used if -setcookie wasn't passed
-define(COOKIE, bitcoin).

%% candidates per work request - see README for how this was picked
-define(DEFAULT_WORK_UNIT, 100000).

%% print a progress line on stderr every this many candidates
-define(REPORT_EVERY, 10000000).
