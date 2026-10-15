#!/usr/bin/env bash
for f in tests/shell/mutate_p4_health.sh tests/shell/sum_p4_health_gate_shards.sh tests/shell/test_p4_health_gate_scripts.sh; do [ -f "$f" ] || { echo "bash -n $f -> missing"; continue; }; bash -n "$f"; r=$?; echo "bash -n $f -> $r"; [ $r -eq 0 ] || exit $r; done
