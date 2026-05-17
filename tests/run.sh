#!/usr/bin/env bash
# Runs every tests/test_*.sh and aggregates the result.
set -u
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do
    [ -e "$t" ] || continue
    echo "=== $t ==="
    bash "$t" || rc=1
done
exit $rc
