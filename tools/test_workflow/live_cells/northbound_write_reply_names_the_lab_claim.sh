#!/usr/bin/env bash
#
# CELL northbound_write_reply_names_the_lab_claim -- KNOWN-ISSUES G-32, Adam's option C
# (DECISIONS-0912-NIGHT C1-6). A write that programs the fabric answers with the claim it was
# made under, so a caller can tell "my claim" from "somebody else's" from the reply itself.
#
# [Co-developed with claude code -- Adam]
#
# Source: ROLE-4 T4, live 2026-09-11 02:01:16-02:02:45 (FIX-NDT-3-SUMMARY §7-1). A loop firing
# install_flow_entry and delete_flow_entry every two seconds got 200 through the second its own
# claim expired, and went on getting 200 after a DIFFERENT owner took the claim -- with nothing
# in the reply and nothing in the log to say the lab had changed hands underneath it. Adam ruled
# option C: the kernel REPORTS and refuses nothing.
# Fix: the `lab_claim` object attached at HttpSession::buildResponse's single exit
# (`attachLabClaimIfWrite`), shipped by FIX-CPP-SMALL-1.
#
# 🔴 WHY A LIVE CELL AT ALL -- tests/shell/mutate_lab_claim_on_writes.sh already mutates this
# seam. Because that gate drives the C++ unit seam with a claim file it writes itself, and the
# thing an operator depends on is the OTHER end of the chain: stack.sh has to export
# NDT_LAB_CLAIM_FILE into the kernel it starts (one call site, line 1039), the kernel has to
# still be reading it after `ndt up`, and the file it reads has to be the one `ndt claim` wrote.
# No unit test crosses those three. This cell reads the claim file and the reply and compares
# them, which is the only place that chain is measured end to end.
#
# 🔴 THE NEGATIVE HALF IS HALF THE CELL. `isLabClaimBearingWrite` names twelve endpoints, so
# "every POST carries it" is a wrong fix that passes every positive assertion -- the shape
# mutate_lab_claim_on_writes.sh calls M8, and the reason B-6 keeps Ryu's notification route
# separate. A POST that is not one of the twelve must come back UNMARKED, and so must a GET.
#
# What this cell does to the lab: one declared link failure on the edge ROLE-1 used, withdrawn
# through the API immediately, and the machine's netem count recorded afterwards. The 400 and
# the 404 touch nothing at all.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

NEAR=s1-eth1
FAR=s5-eth1
EDGE='{"src_dpid":1,"src_interface":1,"dst_dpid":5,"dst_interface":1}'
API=http://127.0.0.1:8000

cell_observe() {
    local d="$1"
    cell_write_ids "$d"
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 420 bash "$NDT_ROOT/tools/test_workflow/ndt" up ovs 4 > "$d/up.log" 2>&1
    printf '%s\n' "$?" > "$d/up.rc"
    # The claim as it stands on disk, copied into the raw: the judge compares the reply against
    # THIS file, and a judge that read .test_run/lab.claim itself would be reading the lab.
    if ! cp "$NDT_ROOT/.test_run/lab.claim" "$d/lab.claim" 2>/dev/null; then
        cell_skip "$d" "no $NDT_ROOT/.test_run/lab.claim -- with no claim on the machine the reply's lab_claim is state=none, and 'the reply names the holder' has no holder to name"
        return 0
    fi
    if ! sudo -n tc qdisc show dev "$NEAR" > "$d/tc_pre.txt" 2>&1; then
        cell_skip "$d" "$NEAR does not exist -- the OVS 4-host fabric is not up, so there is no declared link to write about"
        return 0
    fi
    if grep -q netem "$d/tc_pre.txt"; then
        cell_skip "$d" "$NEAR already carries a netem this cell did not attach -- writing over somebody else's fault is not this cell's business"
        return 0
    fi

    # (1) a real write that programs the fabric.
    curl -s -o "$d/failure.body" -w '%{http_code}\n' \
        -X POST "$API/ndt/inject_link_failure" -d "$EDGE" > "$d/failure.code" 2>> "$d/curl.err"
    # (2) and the write that undoes it. Both are in the twelve.
    curl -s -o "$d/recovery.body" -w '%{http_code}\n' \
        -X POST "$API/ndt/inject_link_recovery" -d "$EDGE" > "$d/recovery.code" 2>> "$d/curl.err"
    # (3) the REFUSAL path, and it costs the fabric nothing: a body that is not JSON comes back
    # 400 out of buildResponse's own catch clause, which is below every handler and above the
    # single exit the mark is attached at.
    curl -s -o "$d/badreq.body" -w '%{http_code}\n' \
        -X POST "$API/ndt/inject_link_failure" -d 'not json at all' > "$d/badreq.code" 2>> "$d/curl.err"
    # (4) a POST that is NOT one of the twelve, and (5) a GET. Neither may be marked.
    curl -s -o "$d/notawrite.body" -w '%{http_code}\n' \
        -X POST "$API/ndt/no_such_endpoint" -d '{}' > "$d/notawrite.code" 2>> "$d/curl.err"
    curl -s -o "$d/read.body" -w '%{http_code}\n' \
        "$API/ndt/get_graph_data" > "$d/read.code" 2>> "$d/curl.err"

    sudo -n tc qdisc show dev "$NEAR" > "$d/tc_after.txt" 2>&1
    sudo -n tc qdisc show dev "$FAR"  > "$d/tc_after_far.txt" 2>&1
    if sudo -n tc qdisc show dev "$NEAR" 2>/dev/null | grep -q netem; then
        printf 'CELL CLEANUP: the API recovery left netem on %s and this cell removed it\n' "$NEAR" \
            >> "$d/cleanup.log"
        sudo -n tc qdisc del dev "$NEAR" root >> "$d/cleanup.log" 2>&1
    fi
    if sudo -n tc qdisc show dev "$FAR" 2>/dev/null | grep -q netem; then
        printf 'CELL CLEANUP: the API recovery left netem on %s and this cell removed it\n' "$FAR" \
            >> "$d/cleanup.log"
        sudo -n tc qdisc del dev "$FAR" root >> "$d/cleanup.log" 2>&1
    fi
    printf 'machine netem count after cleanup: %s\n' \
        "$(sudo -n tc qdisc show 2>/dev/null | grep -c netem)" > "$d/netem_final.txt"
}

cell_judge() {
    local d="$1" owner expires
    owner="$(rawfield "$d" lab.claim owner)"
    expires="$(rawfield "$d" lab.claim expires)"
    a_have  lc_claim_file_copied                       "$d/lab.claim"
    a_have  lc_write_reply_present                     "$d/failure.body"
    a_eq    lc_up_rc_is_0                    "0"       "$(cat "$d/up.rc" 2>/dev/null)"
    # The premise: there is a holder to name, and an expiry to compare. Without it every
    # assertion below is satisfied by `{"state":"none","owner":"","expires_at":0,"note":""}`.
    if [[ -n "$owner" && "$expires" =~ ^[0-9]+$ ]]; then
        _a_ok  lc_premise_a_claim_was_held "claim file names owner [$owner] expiring at $expires"
    else
        _a_bad lc_premise_a_claim_was_held \
               "claim file owner [${owner:-<none>}] expires [${expires:-<none>}]: with no holder and no expiry the reply's lab_claim cannot be told from the empty one"
    fi
    # 🔴 THE KEY ASSERTIONS. The object is there on the 200, and its fields are the FILE's --
    # tied to the value read out of the raw claim, not to a constant, so a kernel that answers
    # with a hard-coded owner fails here.
    a_has   lc_write_reply_carries_the_claim '"lab_claim":{'                 "$d/failure.body"
    a_has   lc_claim_owner_is_the_holder     "\"owner\":\"$owner\""          "$d/failure.body"
    a_has   lc_claim_expiry_is_the_file_s    "\"expires_at\":$expires"       "$d/failure.body"
    a_has   lc_claim_state_is_active         '"state":"active"'              "$d/failure.body"
    # The second write of the pair, and the REFUSAL: the mark is at the single exit, so a 400
    # from a body the kernel could not parse carries it too. That is the reply whose reader most
    # needs it -- something just went wrong and they are working out whose fabric this is.
    a_has   lc_recovery_reply_carries_it     '"lab_claim":{'                 "$d/recovery.body"
    a_eq    lc_badreq_is_a_refusal  "400"    "$(cat "$d/badreq.code" 2>/dev/null)"
    a_has   lc_refusal_carries_it_too        '"lab_claim":{'                 "$d/badreq.body"
    # 🔴 THE NEGATIVE HALF: not every POST, and not a read.
    a_hasnt lc_a_post_outside_the_twelve_is_unmarked  '"lab_claim"'          "$d/notawrite.body"
    a_hasnt lc_a_read_is_unmarked                     '"lab_claim"'          "$d/read.body"
    # Controls: the write really reached the fabric, and this cell put the wire back.
    a_eq    lc_control_write_was_accepted   "200"      "$(cat "$d/failure.code" 2>/dev/null)"
    a_has   lc_control_cell_left_no_netem  'machine netem count after cleanup: 0' "$d/netem_final.txt"
}

cell_main northbound_write_reply_names_the_lab_claim kernel ovs4 "$@"
