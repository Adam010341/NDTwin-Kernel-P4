#!/usr/bin/env bash
# live07.sh -- live 07 (L1-L6, roles + unbound control) on trunk b2eeb71d, the first run since
# TICKET-P4-heartbeat segment W: the heartbeat now feeds switch_state's links and detects L4's cut.
# The script claims and releases the lab itself. Workers paused (no offline test runs) throughout.
# [Co-developed with claude code -- Adam]
set -u
G=/home/adam/Desktop/NDTwin-Kernel; L=$G/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/live07
D=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
cd "$G" || exit 9
export NDT_OWNER=orch-0927
unset L1_POLL_S SELFTEST_HB_RUN SELFTEST_HB_PKGS SELFTEST_PROBE_SUDO
say() { echo "== $(date '+%F %T %z') $*"; }
[[ "$(git rev-parse HEAD)" == b2eeb71df30fe9cdd0086f281062517ba3e86815 ]] || { say "REFUSE: HEAD is $(git rev-parse --short HEAD), not b2eeb71d"; exit 2; }
say "trunk $(git rev-parse HEAD); 07 sha256 $(sha256sum $D/07_roles_basic.sh | cut -c1-16); _common $(sha256sum $D/_common.sh | cut -c1-16); helper $(sha256sum /usr/local/sbin/ndtwin-lab | cut -c1-16); disk $(df -h / | awk 'NR==2{print $4}')"
git diff -- p4_proxy/mininet/host_count_override > "$L/knob-before.diff"; cat p4_proxy/mininet/host_count_override > "$L/knob-before.txt" 2>&1
tools/test_workflow/ndt status > "$L/status-before.txt" 2>&1
say "start 07"
bash "$D/07_roles_basic.sh" > "$L/07.log" 2>&1; rc=$?
say "end 07 rc=$rc  last: $(tail -1 "$L/07.log")"
tools/test_workflow/ndt status > "$L/status-after.txt" 2>&1; sed -n 2,4p "$L/status-after.txt"
git diff -- p4_proxy/mininet/host_count_override > "$L/knob-after.diff"; cat p4_proxy/mininet/host_count_override > "$L/knob-after.txt" 2>&1
cmp -s "$L/knob-before.txt" "$L/knob-after.txt" && say "knob unchanged ($(cat "$L/knob-after.txt"))" || say "🔴 knob CHANGED"
say "run dir: $(ls -d "$G/$D"/runs/*_07_roles_basic | tail -1)"
say "DONE rc=$rc"
