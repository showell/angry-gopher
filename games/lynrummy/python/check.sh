#!/bin/bash
# check.sh — run every test_*.py in this directory; exit non-zero on
# any failure. Single source of truth for "did the Python side pass."
# Solver-touching work must run this before committing.
#
# Tests aren't load-bearing without enforcement. See
# memory/feedback_tests_arent_load_bearing_without_enforcement.md.

set -e
cd "$(dirname "$0")"

failed=0
ran=0
for t in test_*.py; do
    [ -f "$t" ] || continue
    ran=$((ran + 1))
    out=$(python3 "$t" 2>&1) && rc=$? || rc=$?
    last=$(printf '%s\n' "$out" | tail -1)
    if [ "$rc" -ne 0 ]; then
        echo "FAIL  $t  ($last)"
        failed=$((failed + 1))
    elif printf '%s\n' "$out" | grep -qE '\b(FAIL|FAILED)\b|[0-9]+ failed'; then
        echo "FAIL  $t  ($last)"
        failed=$((failed + 1))
    else
        echo "PASS  $t  ($last)"
    fi
done

echo
if [ "$failed" -gt 0 ]; then
    echo "$failed/$ran test files failed."
    exit 1
fi
echo "$ran/$ran test files passed."
