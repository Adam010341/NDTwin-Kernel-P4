#!/usr/bin/env bash
# bash -n of the .sh files PR "Cut A + D" changes vs main (a missing file prints "missing" and the script goes on)
for f in tests/shell/mutate_p4_exercise_tools.sh tests/shell/mutate_p4_health.sh tests/shell/mutate_p4_rule_install_time.sh tests/shell/mutate_roles_binding.sh tests/shell/mutate_table_entry.sh tests/shell/mutate_table_entry_owner.sh tests/shell/test_p4_health_gate_scripts.sh; do [ -f "$f" ] || { echo "bash -n $f -> missing"; continue; }; bash -n "$f"; r=$?; echo "bash -n $f -> $r"; [ $r -eq 0 ] || exit $r; done
