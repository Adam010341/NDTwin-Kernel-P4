#!/usr/bin/env bash
#
# CELL recovery_refuses_foreign_netem -- A1 / KNOWN-ISSUES B-16. `POST /ndt/inject_link_recovery`
# deleted the previous operator's netem off a link this kernel had never declared down, and
# answered 200 {"ok":true}.
#
# [Co-developed with claude code -- Adam]
#
# Source: ROLE-1, live on an OVS 4-host fabric 2026-09-11 00:55-00:59, 3 reproductions of 3.
# Round 3 was the isolating control: an edge that had NEVER been declared (`is_up:True`,
# `down_reason:"none"`) with a hand-attached `netem loss 100%` on s1-eth1 -- and the endpoint
# still ran `qdisc del dev s1-eth1 root` and reported
#   {"status":"link recovery injected","tc":[{"command":"qdisc del dev s1-eth1 root",
#    "detached_at":"root","interface":"s1-eth1","ok":true, ...}]}   http_code=200
# Nothing in the reply or in kernel.log questioned whose qdisc it had been
# (logs/ROLE-1/07-inject-recovery.log, 08-tc-after-recovery.log).
# Fix: 0b928fe6 (InjectedNetemLedger + read-both-ends-before-writing), merged in 6c4000eb.
#
# 🔴 The netem this cell attaches is DELIBERATELY foreign: attached by hand at the attach point
# the harness would compute (an unshaped `noqueue` root), never through the API, so the kernel's
# ledger has no entry for it. That is what "somebody else's experiment" is on this machine, and
# faults.sh / the chaos harness cannot produce it because both always revert.
#
# 🔴 It is also this cell's own mess, and the cell cleans it: `sudo tc qdisc del` by interface at
# the end, never a sweep. The final whole-machine netem count is recorded so a cell that left
# something behind says so instead of being found by the next round.
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
    # 🔴 ASSERT THE INJECTION, then read it back. An experiment that did not inject anything and
    # a kernel that refused correctly are indistinguishable from the reply alone.
    sudo -n tc qdisc add dev "$NEAR" root netem loss 100% > "$d/attach.log" 2>&1
    printf 'attach rc=%s\n' "$?" >> "$d/attach.log"
    sudo -n tc qdisc show dev "$NEAR" > "$d/tc_before.txt" 2>&1
    if ! grep -q netem "$d/tc_before.txt"; then
        cell_skip "$d" "the hand-attached netem is not on $NEAR -- nothing foreign to refuse, so the 409 would prove nothing"
        return 0
    fi
    curl -s -o "$d/recovery.body" -w '%{http_code}\n' \
        -X POST http://127.0.0.1:8000/ndt/inject_link_recovery -d "$EDGE" \
        > "$d/recovery.code" 2>> "$d/recovery.curlerr"
    sudo -n tc qdisc show dev "$NEAR" > "$d/tc_after.txt" 2>&1
    sudo -n tc qdisc show dev "$FAR"  > "$d/tc_after_far.txt" 2>&1
    # --- clean up what this cell attached, and nothing else ------------------------------------
    sudo -n tc qdisc del dev "$NEAR" root > "$d/cleanup.log" 2>&1
    printf 'del %s rc=%s\n' "$NEAR" "$?" >> "$d/cleanup.log"
    sudo -n tc qdisc show dev "$NEAR" >> "$d/cleanup.log" 2>&1
    printf 'machine netem count after cleanup: %s\n' \
        "$(sudo -n tc qdisc show 2>/dev/null | grep -c netem)" > "$d/netem_final.txt"
}

cell_judge() {
    local d="$1"
    # The premise, asserted rather than assumed.
    a_has   a1r_injection_succeeded          'netem'                      "$d/tc_before.txt"
    # 🔴 THE KEY ASSERTION: a conflict, not a success.
    a_eq    a1r_http_is_409           "409"  "$(cat "$d/recovery.code" 2>/dev/null)"
    a_has   a1r_body_names_foreign_netem     'netem_not_ours'             "$d/recovery.body"
    a_has   a1r_body_says_nothing_changed    'Nothing was changed'        "$d/recovery.body"
    # The pre-fix reply, verbatim from ROLE-1: the command it ran and the claim it made.
    a_hasnt a1r_no_qdisc_was_deleted         'qdisc del dev s1-eth1 root' "$d/recovery.body"
    a_hasnt a1r_did_not_claim_a_recovery     'link recovery injected'     "$d/recovery.body"
    # 🔴 The wire, not just the reply. This is the assertion the 200 could not have satisfied.
    a_has   a1r_foreign_netem_survived       'netem'                      "$d/tc_after.txt"
    # The far end was never touched by anyone, and must still not be.
    a_hasnt a1r_far_end_untouched            'netem'                      "$d/tc_after_far.txt"
    a_has   a1r_cell_left_no_netem  'machine netem count after cleanup: 0' "$d/netem_final.txt"
}

cell_main recovery_refuses_foreign_netem kernel ovs4 "$@"
