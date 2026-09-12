#!/usr/bin/env bash
#
# CELL up_refuses_while_a_down_is_in_flight -- H3. A bring-up that overlapped a teardown REUSED
# the fabric being destroyed, and the teardown then reported the new run as residue.
#
# [Co-developed with claude code -- Adam]
#
# Source: ROLE-2 cycle 13, live 2026-09-11 (logs/ROLE-2/cycle-13-up-B.log). Thirteen seconds
# into an `ndt down`, a second `ndt up p4` printed
#   `ok  already up: 10 switches, 4 hosts, reusing`
# and [3/3] then PASSED `model matches fabric` on a fabric that was mid-SIGTERM; the next line
# was a bare `Terminated`. The background `down` finished rc 1 and named the NEW kernel and
# proxy as residue, advising `ndt down --deep` -- which would have killed them. On OVS the same
# overlap was refused, but by mn_count and for a different reason (`a Mininet is already
# running`), so the refusal existed on one plane by accident.
# Fix: 019b125d (.test_run/down.inflight marker + guard in preflight), merged in cb5ab923.
# Re-measured by ROLE-6 at 02:54:42 (OVS) and 03:09:19 (P4): rc 1 in 0 s, both planes, with the
# marker's pid quoted. (logs/ROLE-6/50-h3-ovs.log, 52-h3-p4-cleanlab.log)
#
# 🔴 The overlap this cell builds is a teardown of an EMPTY lab -- 1 s of `ndt down` on a lab
# that is already down. That is ROLE-6's second attempt, and ROLE-6 wrote down why: the guard
# lives in preflight, before anything reads the machine, so the path is the same one. What is
# therefore NOT covered, here or by ROLE-6, is overlapping the teardown of a live 10-switch
# stack. CELLS.md says so in this cell's row.
#
# 🔴 The refusal must NAME the marker. `ndt up` refusing for some other reason (ports held, a
# Mininet already running) is the accident this fix replaced, and a cell that accepted any rc 1
# would pass on it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

cell_observe() {
    local d="$1" t0 t1 downpid
    cell_write_ids "$d"
    # A teardown of an already-down lab: it takes a couple of seconds, writes the marker, and
    # removes nothing, so the overlap costs the lab nothing.
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 300 bash "$NDT_ROOT/tools/test_workflow/ndt" down > "$d/down-bg.log" 2>&1 &
    downpid=$!
    printf '%s\n' "$downpid" > "$d/down.bgpid"
    # The marker, read at the instant of the overlap. This is the assertion that the window was
    # real: without it, a refusal proves nothing because there may have been nothing to refuse.
    local i
    for i in $(seq 1 60); do
        [[ -f "$NDT_ROOT/.test_run/down.inflight" ]] && break
        sleep 0.1
    done
    # 🔴 SKIP rather than carry on. If the marker is not there the window does not exist, and
    # running `ndt up ovs 4` anyway would not be a weaker cell -- it would BUILD A FABRIC this
    # cell has no reason to build, on a lab somebody else may be about to use. "I could not
    # construct the overlap" is a different answer from "the overlap was not refused", and
    # conflating them is how a cell starts reporting green for the wrong reason.
    if [[ ! -f "$NDT_ROOT/.test_run/down.inflight" ]]; then
        wait "$downpid"; printf '%s\n' "$?" > "$d/down.rc"
        cell_skip "$d" "the background 'ndt down' left no down.inflight marker within 6 s -- no overlap window was constructed, so nothing was asked of 'ndt up'"
        return 0
    fi
    cp "$NDT_ROOT/.test_run/down.inflight" "$d/down.inflight" 2>/dev/null \
        || printf '(absent)\n' > "$d/down.inflight"
    t0=$(date +%s)
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 120 bash "$NDT_ROOT/tools/test_workflow/ndt" up ovs 4 > "$d/up.log" 2>&1
    printf '%s\n' "$?" > "$d/up.rc"
    t1=$(date +%s); printf '%s\n' "$((t1-t0))" > "$d/up.secs"
    wait "$downpid"; printf '%s\n' "$?" > "$d/down.rc"
    cp "$NDT_ROOT/.test_run/down.inflight" "$d/down.inflight.after" 2>/dev/null \
        || printf '(absent)\n' > "$d/down.inflight.after"
}

cell_judge() {
    local d="$1" secs
    a_have  h3_up_log_present                       "$d/up.log"
    # The window was real -- the marker existed while the second up ran.
    a_re    h3_marker_was_in_place       '^pid=[0-9]+$'                    "$d/down.inflight"
    # 🔴 THE KEY ASSERTION: refused, and refused FOR THIS REASON.
    a_has   h3_refusal_names_the_teardown \
            "refusing to build: an 'ndt down' from this checkout is still running" "$d/up.log"
    a_has   h3_refusal_quotes_the_marker            '.test_run/down.inflight'       "$d/up.log"
    # The pre-fix sentences, on the plane where they were printed.
    #
    # 🔴 THE `ok  ` PREFIX IS THE DISCRIMINATOR, and it cost this cell its first live run.
    # `guard_no_teardown_in_flight`'s refusal QUOTES both of these strings back at the operator as
    # its own explanation of what the overlap used to do:
    #     XX    being destroyed. Measured 09-11: [1/3] said 'already up: 10 switches, reusing',
    #     XX    [3/3] passed 'model matches fabric', and the fabric was mid-SIGTERM. The teardown
    # So `a_hasnt 'already up:'` fired on the FIXED ndt -- a red cell over a correct refusal,
    # measured live 2026-09-11 13:28:55. The old fixture was no help: there the strings really
    # were the stage banners, so the assertions looked load-bearing and the gate agreed. What
    # separates the two is the `ok  ` that only a passing stage prints; the quotes live on `XX `
    # lines. A needle that appears inside the very message whose presence is being asserted
    # elsewhere in the same judge is not a needle.
    a_hasnt h3_did_not_reuse_the_fabric             'ok  already up:'               "$d/up.log"
    a_hasnt h3_did_not_verify_a_dying_fabric        'ok  model matches fabric:'     "$d/up.log"
    # 🔴 5, and renamed with the value, since 2026-09-12 (FIX-NDT-8, Adam form 5 Q15b): a
    # REFUSED `ndt up` exits 5 and a bring-up that merely found something dirty still exits 1.
    # Until today this cell accepted 1 -- and the header above says why that was nearly worthless
    # here: the pre-fix run ALSO exited 1, from `a Mininet is already running` on the OVS arm, so
    # the id passed on old/ and on new/ alike. 5 is the first value that separates them.
    # ⚠️ The `new/` fixture beside this cell was captured on 09-11, under the old contract, and
    # therefore records rc 1. It has been retired to new-0911-pre-rc-contract/ rather than edited
    # -- it is captured evidence -- so this cell has NO new/ fixture until the first live round
    # under the 09-12 contract is captured. tests/shell/mutate_live_cells.sh reports that as
    # PENDING, which is what it is.
    a_eq    h3_up_rc_is_5                    "5"    "$(cat "$d/up.rc" 2>/dev/null)"
    secs="$(cat "$d/up.secs" 2>/dev/null)"
    if [[ "$secs" =~ ^[0-9]+$ ]] && (( secs <= 30 )); then
        _a_ok  h3_refusal_is_immediate "refused in ${secs}s"
    else
        _a_bad h3_refusal_is_immediate "took [${secs:-unknown}]s -- the guard is in preflight"
    fi
    # The marker is the teardown's own, and it cleans it up: a marker left behind would refuse
    # every bring-up from then on, which is this fix with the sign flipped.
    a_has   h3_marker_was_removed                   '(absent)'    "$d/down.inflight.after"
}

cell_main up_refuses_while_a_down_is_in_flight ndt idle "$@"
