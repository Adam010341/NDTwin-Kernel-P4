#!/usr/bin/env bash
#
# CELL link_failure_cuts_both_ends_or_neither -- A1 / KNOWN-ISSUES B-16, second finding.
# `POST /ndt/inject_link_failure` had one end refused and cut the other one anyway, and still
# answered 200 {"status":"link failure injected"}.
#
# [Co-developed with claude code -- Adam]
#
# Source: ROLE-1, live on an OVS 4-host fabric 2026-09-11 00:57:27, 2 reproductions of 2
# (logs/ROLE-1/06-inject-failure.log). With a foreign `netem loss 100%` already on s1-eth1 that
# end was refused -- `"ok":false`, "refusing to stack a second one" -- while
# `qdisc add dev s5-eth1 root netem loss 100%` really happened, and the status line said the
# failure had been injected:
#   {"down_reason":"declared","status":"link failure injected","tc":[
#     {"interface":"s1-eth1","ok":false,...,"refused":"netem is already attached..."},
#     {"attached_at":"root","command":"qdisc add dev s5-eth1 root netem loss 100%","ok":true,...}]}
# Unidirectional loss is its own fault type for a reason (faults.txt L-2): it kills LLDP in one
# direction only and leaves the control plane's graph permanently asymmetric.
# Fix: 0b928fe6 (cutLinkEnds plans every end before attaching any, and rolls back an attach whose
# sibling then failed), merged in 6c4000eb.
#
# 🔴 The declaration is expected to STAND -- that is the half this endpoint can carry out, the
# same as on a non-MININET deployment -- and the reply has to say which half happened. So this
# cell asserts the presence of the `wire` sentence, not the absence of a declaration: "refuse the
# whole request" is a different contract and is not what was ruled.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

NEAR=s1-eth1
FAR=s5-eth1
EDGE='{"src_dpid":1,"src_interface":1,"dst_dpid":5,"dst_interface":1}'

cell_observe() {
    local d="$1"
    cell_write_ids "$d"
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 420 bash "$NDT_ROOT/tools/test_workflow/ndt" up ovs 4 > "$d/up.log" 2>&1
    printf '%s\n' "$?" > "$d/up.rc"
    if ! sudo -n tc qdisc show dev "$NEAR" > "$d/tc_pre.txt" 2>&1; then
        cell_skip "$d" "$NEAR does not exist -- the OVS 4-host fabric is not up, so there is no link end to act on"
        return 0
    fi
    sudo -n tc qdisc add dev "$NEAR" root netem loss 100% > "$d/attach.log" 2>&1
    printf 'attach rc=%s\n' "$?" >> "$d/attach.log"
    sudo -n tc qdisc show dev "$NEAR" > "$d/tc_before.txt" 2>&1
    sudo -n tc qdisc show dev "$FAR"  > "$d/tc_before_far.txt" 2>&1
    if ! grep -q netem "$d/tc_before.txt" || grep -q netem "$d/tc_before_far.txt"; then
        cell_skip "$d" "the premise is not set up: want a foreign netem on $NEAR and none on $FAR"
        return 0
    fi
    curl -s -o "$d/failure.body" -w '%{http_code}\n' \
        -X POST http://127.0.0.1:8000/ndt/inject_link_failure -d "$EDGE" \
        > "$d/failure.code" 2>> "$d/failure.curlerr"
    sudo -n tc qdisc show dev "$NEAR" > "$d/tc_after.txt" 2>&1
    sudo -n tc qdisc show dev "$FAR"  > "$d/tc_after_far.txt" 2>&1
    # --- restore: withdraw the declaration, then take back the qdisc this cell attached --------
    # Withdrawn through the API first, so the kernel's own state goes back with it; the foreign
    # netem is still standing at that point, so this is the "declared + not ours" path and is
    # expected to leave the qdisc alone. Then the qdisc, by interface.
    curl -s -o "$d/withdraw.body" -w '%{http_code}\n' \
        -X POST http://127.0.0.1:8000/ndt/inject_link_recovery -d "$EDGE" \
        > "$d/withdraw.code" 2>> "$d/failure.curlerr"
    sudo -n tc qdisc del dev "$NEAR" root > "$d/cleanup.log" 2>&1
    printf 'del %s rc=%s\n' "$NEAR" "$?" >> "$d/cleanup.log"
    if sudo -n tc qdisc show dev "$FAR" 2>/dev/null | grep -q netem; then
        # Only reachable if the fix regressed and the far end really was cut. Recorded loudly,
        # because a cell that quietly repaired the defect's damage would hide it.
        printf 'REGRESSION CLEANUP: %s carried netem and this cell removed it\n' "$FAR" >> "$d/cleanup.log"
        sudo -n tc qdisc del dev "$FAR" root >> "$d/cleanup.log" 2>&1
    fi
    printf 'machine netem count after cleanup: %s\n' \
        "$(sudo -n tc qdisc show 2>/dev/null | grep -c netem)" > "$d/netem_final.txt"
}

cell_judge() {
    local d="$1"
    a_has   a1f_injection_succeeded           'netem'   "$d/tc_before.txt"
    a_hasnt a1f_far_end_started_clean         'netem'   "$d/tc_before_far.txt"
    # 🔴 THE KEY ASSERTION, on the wire: with one end refused, the other end is NOT cut.
    a_hasnt a1f_far_end_was_not_cut           'netem'   "$d/tc_after_far.txt"
    # ... and the status line does not claim a cut that did not happen.
    a_hasnt a1f_does_not_claim_injected       'link failure injected'                  "$d/failure.body"
    a_has   a1f_says_nothing_was_attached     'link failure declared; nothing was attached' "$d/failure.body"
    # The reply says which half happened, rather than leaving it to be inferred from an array.
    a_has   a1f_names_the_half_that_happened  'no netem was attached to either end'     "$d/failure.body"
    # The declaration stands -- asserted, because "refuse the whole request" is a different
    # contract from the one that was ruled.
    a_has   a1f_declaration_still_stands      'The declaration stands'                  "$d/failure.body"
    a_has   a1f_cell_left_no_netem  'machine netem count after cleanup: 0' "$d/netem_final.txt"
}

cell_main link_failure_cuts_both_ends_or_neither kernel ovs4 "$@"
