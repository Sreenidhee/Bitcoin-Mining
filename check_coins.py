#!/usr/bin/env python3
"""
Independent checker for project1 output. Does NOT use Erlang at all -
recomputes SHA-256 with Python's own hashlib, so it can't share a bug
with the program it's checking.

Usage:
    erl -noshell -pa project1 -run project1 main 4 20000000 > coins.txt
    python3 check_coins.py coins.txt 4
"""
import sys
import hashlib

def main():
    if len(sys.argv) != 3:
        print("usage: check_coins.py <output-file> <k>")
        sys.exit(1)

    path, k = sys.argv[1], int(sys.argv[2])
    prefix = "modugus"
    total = 0
    bad = 0

    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            if "\t" not in line:
                print(f"line {lineno}: NO TAB CHARACTER -> {line!r}")
                bad += 1
                continue

            input_str, claimed_hash = line.split("\t")

            if not input_str.startswith(prefix):
                print(f"line {lineno}: input doesn't start with '{prefix}' -> {input_str!r}")
                bad += 1
                continue

            real_hash = hashlib.sha256(input_str.encode()).hexdigest()

            if len(claimed_hash) != 64:
                print(f"line {lineno}: hash isn't 64 hex chars -> {claimed_hash!r}")
                bad += 1
                continue

            if claimed_hash != real_hash:
                print(f"line {lineno}: hash mismatch")
                print(f"    claimed : {claimed_hash}")
                print(f"    actual  : {real_hash}")
                bad += 1
                continue

            if not claimed_hash.startswith("0" * k):
                print(f"line {lineno}: doesn't have {k} leading zeroes -> {claimed_hash}")
                bad += 1
                continue

            total += 1

    print()
    print(f"checked {total + bad} lines, {total} valid, {bad} bad")
    if bad == 0 and total > 0:
        print("RESULT: PASS - every line is a real, correctly-prefixed, "
              f"correctly-hashed bitcoin with >= {k} leading zeroes")
        sys.exit(0)
    else:
        print("RESULT: FAIL")
        sys.exit(1)

if __name__ == "__main__":
    main()
