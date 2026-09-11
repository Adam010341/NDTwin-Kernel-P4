#!/usr/bin/env bash
#
# CELL up_refuses_a_model_of_another_network -- H4. `NDT_TOPO=<128-host model> ndt up p4 4`
# built the 4-host fabric anyway and let the kernel load a model of a different network.
#
# [Co-developed with claude code -- Adam]
#
# Source: ROLE-2 cycle 07, live 2026-09-11 01:15:58-01:20:58 (logs/ROLE-2/cycle-07-up.log).
# `ndt up p4` printed `hosts 4` and `topology ...128Hosts.json` on adjacent lines and never
# compared them, wrote `hosts=4` beside `model_hosts=128` into up.target, started the topology,
# brought ten switches up, and then sat in [2/3] until the role's own 300 s timeout killed it
# (rc 124). The kernel never started. This is also the live falsification of what `ndt help`
# used to promise about forgetting an environment variable (B10, scope corrected separately).
# Fix: 76b5d434, merged in 954ab467. Re-measured by ROLE-6 at 02:48:57: rc 1 in 0 s
# (logs/ROLE-6/10-h4-redo.log).
#
# 🔴 rc alone has NO discriminating power here and the judge does not use it: the pre-fix run
# also ended non-zero -- 124, from a timeout, after building a fabric. The three things that
# tell the two apart are the refusal SENTENCE, the TIME, and that nothing was built.
#
# 🔴 The knob is read before and after and required to be unchanged. `ndt up p4 <n>` rewrites
# p4_proxy/mininet/host_count_override permanently and BEFORE the topology check (WAKEUP §7.3
# item 30), and that file is somebody else's uncommitted change on this machine. A cell that
# left it altered would be a cell that damaged the tree it was checking.
#
# Needs no fabric: the refusal happens in up_p4 before anything is started. requires=idle all
# the same, because `ndt up` is not a question to ask while a round is running.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

MODEL_128=setting/StaticNetworkTopologyP4_10Switches_128Hosts.json

cell_observe() {
    local d="$1" knob="$NDT_ROOT/p4_proxy/mininet/host_count_override" t0 t1
    cell_write_ids "$d"
    if [[ ! -r "$NDT_ROOT/$MODEL_128" ]]; then
        cell_skip "$d" "no $MODEL_128 in this tree -- the cell needs a real model of another network"
        return 0
    fi
    cp "$knob" "$d/knob.before" 2>/dev/null || printf '(absent)\n' > "$d/knob.before"
    t0=$(date +%s)
    # 🔴 timeout 120, not 420: the pre-fix behaviour here is "build a fabric and hang", and a
    # cell that waited 300 s for that would be paying the defect's own price every night.
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" NDT_TOPO="$NDT_ROOT/$MODEL_128" \
        timeout 120 bash "$NDT_ROOT/tools/test_workflow/ndt" up p4 4 > "$d/up.log" 2>&1
    printf '%s\n' "$?" > "$d/up.rc"
    t1=$(date +%s); printf '%s\n' "$((t1-t0))" > "$d/up.secs"
    cp "$knob" "$d/knob.after" 2>/dev/null || printf '(absent)\n' > "$d/knob.after"
    cp "$NDT_ROOT/.test_run/up.target" "$d/up.target" 2>/dev/null \
        || printf '(absent)\n' > "$d/up.target"
}

cell_judge() {
    local d="$1" secs
    a_have  h4_up_log_present                     "$d/up.log"
    # 🔴 THE KEY ASSERTION. The sentence, because that is what distinguishes a refusal from the
    # timeout the pre-fix run also ended in.
    a_has   h4_refusal_names_two_networks \
            'refusing to build: NDT_TOPO names a model of a different network'  "$d/up.log"
    a_has   h4_refusal_names_both_counts          '128 declared by'             "$d/up.log"
    # Nothing was started. `[1/3] bmv2 fabric` is the banner the pre-fix run printed before
    # bringing ten switches up.
    a_hasnt h4_nothing_was_built                  '[1/3] bmv2 fabric'           "$d/up.log"
    a_hasnt h4_no_target_was_recorded             'recorded this target in'     "$d/up.log"
    # 0 s against 300 s. The bound is generous: what is being separated is "before it touched
    # the machine" from "after it had built a fabric".
    secs="$(cat "$d/up.secs" 2>/dev/null)"
    if [[ "$secs" =~ ^[0-9]+$ ]] && (( secs <= 30 )); then
        _a_ok  h4_refusal_is_immediate "refused in ${secs}s"
    else
        _a_bad h4_refusal_is_immediate "took [${secs:-unknown}]s -- a refusal happens before the machine is touched"
    fi
    # 🔴 The knob this command rewrites, unchanged.
    a_eq    h4_knob_unchanged  "$(cat "$d/knob.before" 2>/dev/null)"  "$(cat "$d/knob.after" 2>/dev/null)"
}

cell_main up_refuses_a_model_of_another_network ndt idle "$@"
