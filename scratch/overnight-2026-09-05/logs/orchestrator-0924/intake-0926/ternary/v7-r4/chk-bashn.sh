#!/usr/bin/env bash
for f in tests/shell/mutate_table_entry_owner.sh; do bash -n "$f"; r=$?; echo "bash -n $f -> $r"; [ $r -eq 0 ] || exit $r; done
