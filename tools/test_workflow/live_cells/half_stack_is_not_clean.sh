#!/usr/bin/env bash
#
# CELL half_stack_is_not_clean -- H2. A HALF stack was invisible to both restore instruments.
#
# [Co-developed with claude code -- Adam]
#
# Source: ROLE-2, live 2026-09-11, two shapes and three moments, every one of them
# `VERDICT: CLEAN`:
#   cycle 07 01:21:14  10 bmv2 + 14 mininet + a live p4_proxy, no kernel
#                      -> `orphans_rc=5`, `VERDICT: CLEAN -- the process half only; the network
#                         half was NOT checked (kernel down)`   (logs/ROLE-2/cycle-07-probe-afterup.log)
#   cycle 13 01:27:08  the mirror image: 0 bmv2, 0 mininet, no topo session, and a kernel on
#                      :8000 serving a 14-node graph of a network that is not there
#                      (logs/ROLE-2/cycle-13-orphan-halfstack.log)
# `ndt apps orphans` answers about APP processes and about the NETWORK. It did not answer about
# the STACK, and neither did the helper that reads it, so a machine with a fabric and no recorder
# closed the round as clean.
# Fix: 6d081d13 (`stack:` line + HALF verdict), merged in 954ab467. Re-measured by ROLE-6 at
# 02:51:47 and again in its restore: `stack: kernel=down dataplane=mininet bmv2=0 mininet=15
# proxy=down verdict=HALF` -> `VERDICT: NOT CLEAN -- the stack is HALF up`, and the reverse
# control (both halves up) still CLEAN.  (logs/ROLE-6/30-h2-live-halfstack.log, 31-h2-control.log)
#
# 🔴 TWO DIRECTIONS in one cell, because "call a half stack dirty" has a wrong answer that looks
# like a fix: a verdict that reddens a HEALTHY lab would be read for a week and then ignored. So
# the whole-up control is taken first, from the same fabric, and must still be CLEAN.
#
# 🔴 How the half is made: the kernel is stopped by the pid in .test_run/pids/kernel.pid, with
# SIGTERM, by number. Never `pkill -f` (CLAUDE.md), and never a sweep -- the point is to remove
# exactly the process this cell started and nothing else on the machine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

_orphans_into() {   # <rawdir> <prefix>
    local d="$1" p="$2" orc
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 180 bash "$NDT_ROOT/tools/test_workflow/ndt" apps orphans \
        > "$d/$p.orphans.txt" 2>&1
    orc=$?
    printf '%s\n' "$orc" > "$d/$p.orphans.rc"
    bash "$NDT_ROOT/tools/test_workflow/orphans_verdict.sh" "$d/$p.orphans.txt" "$orc" \
        > "$d/$p.verdict.txt" 2>&1
    printf '%s\n' "$?" > "$d/$p.verdict.rc"
}

cell_observe() {
    local d="$1" kpid i
    cell_write_ids "$d"
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 420 bash "$NDT_ROOT/tools/test_workflow/ndt" up ovs 4 > "$d/up.log" 2>&1
    printf '%s\n' "$?" > "$d/up.rc"
    # The control, on the whole stack, BEFORE anything is broken.
    _orphans_into "$d" whole
    kpid="$(cat "$NDT_ROOT/.test_run/pids/kernel.pid" 2>/dev/null | tr -dc '0-9')"
    printf '%s\n' "${kpid:-none}" > "$d/kernel.pid"
    if [[ -z "$kpid" ]] || [[ ! -d "/proc/$kpid" ]]; then
        cell_skip "$d" "no live kernel pid in .test_run/pids/kernel.pid -- the bring-up did not finish, so no half stack could be made"
        return 0
    fi
    kill -TERM "$kpid" 2>> "$d/kill.log"
    printf 'kill -TERM %s rc=%s\n' "$kpid" "$?" >> "$d/kill.log"
    for i in $(seq 1 60); do
        [[ -d "/proc/$kpid" ]] || break
        sleep 0.5
    done
    printf 'proc_after=%s\n' "$([[ -d "/proc/$kpid" ]] && echo present || echo gone)" >> "$d/kill.log"
    # The half stack: the OVS fabric is still up, the recorder is gone.
    _orphans_into "$d" half
}

cell_judge() {
    local d="$1"
    a_have  h2_whole_verdict_present                "$d/whole.verdict.txt"
    a_have  h2_half_verdict_present                 "$d/half.verdict.txt"
    # 🔴 THE CONTROL, and it comes first on purpose: a whole stack is CLEAN.
    a_has   h2_whole_stack_is_clean       'VERDICT: CLEAN'            "$d/whole.verdict.txt"
    a_has   h2_whole_stack_reads_whole_up 'verdict=whole-up'          "$d/whole.orphans.txt"
    # 🔴 THE KEY ASSERTION: with the kernel gone and the fabric standing, the verdict is NOT the
    # token every restore gate in this repo greps for.
    a_hasnt h2_half_stack_is_not_clean    'VERDICT: CLEAN'            "$d/half.verdict.txt"
    a_has   h2_half_stack_says_not_clean  'VERDICT: NOT CLEAN'        "$d/half.verdict.txt"
    a_has   h2_half_stack_names_the_half  'the stack is HALF up'      "$d/half.verdict.txt"
    a_eq    h2_half_verdict_rc_is_1  "1"  "$(cat "$d/half.verdict.rc" 2>/dev/null)"
    # And the report it read says which half, in `ndt`'s own words.
    a_has   h2_report_names_the_half      'verdict=HALF'              "$d/half.orphans.txt"
}

cell_main half_stack_is_not_clean ndt ovs4 "$@"
