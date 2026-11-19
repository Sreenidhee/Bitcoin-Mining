#!/bin/bash
# Test runner for project1. Run this from inside the project1 folder
# (next to the .erl files). Checks every requirement in the assignment
# one at a time and prints PASS/FAIL for each.
#
#   cd project1
#   ./run_checks.sh
#
# Needs: erl/erlc on PATH, python3 on PATH.

set -u
cd "$(dirname "$0")"
PROJ=.
TMP=$(mktemp -d)
PASS=0
FAIL=0

ok()   { echo "  PASS - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "== $1 =="; }

# ---------------------------------------------------------------
hdr "0. compile"
if erlc -o "$PROJ" "$PROJ"/*.erl 2>"$TMP/compile.log"; then
    if [ -s "$TMP/compile.log" ]; then
        bad "compiled with warnings, check $TMP/compile.log"
    else
        ok "erlc *.erl - clean, no warnings"
    fi
else
    bad "compile failed, see $TMP/compile.log"
    cat "$TMP/compile.log"
    exit 1
fi

# ---------------------------------------------------------------
hdr "1. SHA-256 reference value"
erl -noshell -pa "$PROJ" -eval "project1:self_test()" -s init stop > "$TMP/selftest.log" 2>&1
if grep -q "SELF TEST: PASS" "$TMP/selftest.log"; then
    ok "reference hash for 'COP5615 is a boring class' matches, 64 hex chars"
else
    bad "self test failed, see $TMP/selftest.log"
    cat "$TMP/selftest.log"
fi

# ---------------------------------------------------------------
hdr "2. k=0 (every candidate should qualify)"
erl -noshell -pa "$PROJ" -run project1 main 0 5 1 1 > "$TMP/k0.out" 2>/dev/null
LINES=$(wc -l < "$TMP/k0.out" | tr -d ' ')
if [ "$LINES" = "5" ]; then
    ok "5 candidates in, 5 bitcoins out (k=0 matches everything)"
else
    bad "expected 5 lines, got $LINES"
fi
python3 check_coins.py "$TMP/k0.out" 0 > "$TMP/k0.check" 2>&1
grep -q "RESULT: PASS" "$TMP/k0.check" && ok "k=0 output independently verified" || { bad "k=0 verification failed"; cat "$TMP/k0.check"; }

# ---------------------------------------------------------------
hdr "3. k=1 (should find coins almost instantly)"
erl -noshell -pa "$PROJ" -run project1 main 1 200000 1000 4 > "$TMP/k1.out" 2>/dev/null
python3 check_coins.py "$TMP/k1.out" 1 > "$TMP/k1.check" 2>&1
grep -q "RESULT: PASS" "$TMP/k1.check" && ok "$(grep 'checked' "$TMP/k1.check")" || { bad "k=1 verification failed"; cat "$TMP/k1.check"; }

# ---------------------------------------------------------------
hdr "4. k=4, the required experiment"
erl -noshell -pa "$PROJ" -run project1 main 4 20000000 > "$TMP/k4.out" 2> "$TMP/k4.err"
python3 check_coins.py "$TMP/k4.out" 4 > "$TMP/k4.check" 2>&1
grep -q "RESULT: PASS" "$TMP/k4.check" && ok "$(grep 'checked' "$TMP/k4.check")" || { bad "k=4 verification failed"; cat "$TMP/k4.check"; }
NONTAB=$(grep -vc $'\t' "$TMP/k4.out")
[ "$NONTAB" = "0" ] && ok "stdout has zero non-coin lines" || bad "stdout has $NONTAB stray lines"
echo "  -- summary from this run --"
sed -n '/mining finished/,/====/p' "$TMP/k4.err" | sed 's/^/  /'

# ---------------------------------------------------------------
hdr "5. non-overlap / no-gap (compares Erlang output to an independent Python brute force)"
erl -noshell -pa "$PROJ" -run project1 main 3 1000000 7777 5 > "$TMP/cov.out" 2>/dev/null
python3 - "$TMP/cov.out" <<'PY'
import hashlib, sys
path = sys.argv[1]
expected = {f"modugus;{n}" for n in range(1000000)
            if hashlib.sha256(f"modugus;{n}".encode()).hexdigest().startswith("000")}
got = [l.rstrip("\n").split("\t")[0] for l in open(path) if "\t" in l]
dup = len(got) - len(set(got))
missing = len(expected - set(got))
spurious = len(set(got) - expected)
print(f"expected {len(expected)} coins, got {len(got)} lines / {len(set(got))} unique")
print(f"duplicates={dup} missing={missing} spurious={spurious}")
ok = dup == 0 and missing == 0 and spurious == 0
print("MATCH" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
PY
if [ $? -eq 0 ]; then ok "no overlaps, no gaps vs independent brute force"; else bad "range coverage mismatch"; fi

# ---------------------------------------------------------------
hdr "6. distributed: server + remote worker, worker prints nothing"
epmd -daemon 2>/dev/null
# search space sized so the server is still mining when the worker joins
erl -noshell -name bitcoin_server@127.0.0.1 -setcookie bitcoin -pa "$PROJ" \
    -run project1 main 5 200000000 100000 4 > "$TMP/srv.out" 2> "$TMP/srv.err" &
SRV=$!
sleep 2
erl -noshell -name worker1@127.0.0.1 -setcookie bitcoin -pa "$PROJ" \
    -run project1 main bitcoin_server@127.0.0.1 2 > "$TMP/wrk.out" 2> "$TMP/wrk.err"
wait "$SRV" 2>/dev/null
WLINES=$(wc -l < "$TMP/wrk.out" | tr -d ' ')
[ "$WLINES" = "0" ] && ok "remote worker printed 0 lines to stdout" || bad "remote worker printed $WLINES lines (should be 0)"
grep -q "remote worker joined" "$TMP/srv.err" && ok "server logged the remote worker joining" || bad "no join message found"
python3 check_coins.py "$TMP/srv.out" 5 > "$TMP/dist.check" 2>&1
grep -q "RESULT: PASS" "$TMP/dist.check" && ok "$(grep 'checked' "$TMP/dist.check")" || { bad "distributed run verification failed"; cat "$TMP/dist.check"; }

# ---------------------------------------------------------------
hdr "7. CPU/REAL time ratio (multicore check)"
ERRF=$(mktemp)
/usr/bin/time -p erl -noshell -pa "$PROJ" -run project1 main 4 10000000 >/dev/null 2>"$ERRF"
REAL=$(grep -m1 '^real' "$ERRF" | awk '{print $2}')
USER=$(grep -m1 '^user' "$ERRF" | awk '{print $2}')
echo "  real=${REAL}s user=${USER}s"
python3 -c "
real=float('$REAL'); user=float('$USER')
ratio = user/real if real else 0
print(f'  CPU/REAL ratio = {ratio:.2f}')
exit(0 if ratio > 1.5 else 1)
"
[ $? -eq 0 ] && ok "ratio > 1.5, shows real multicore parallelism" || bad "ratio too close to 1.0, no parallelism detected"
rm -f "$ERRF"

# ---------------------------------------------------------------
hdr "results"
echo "  $PASS passed, $FAIL failed"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
