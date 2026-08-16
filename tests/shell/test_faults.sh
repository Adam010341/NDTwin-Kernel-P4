#!/usr/bin/env bash
#
# Tests for faults.sh -- the L5 fault-injection harness.
#
# [Co-developed with claude code -- Adam]
#
# These drive the real round logic out of faults.sh with every world-touching function
# replaced (the same source-then-override seam as tests/shell/test_up_ovs_wedge_guard.sh).
# Nothing is injected, no tc runs, no signal is sent, no interpreter is started: this file
# was written while a live round owned the machine, and a single real `tc` here would have
# corrupted somebody else's experiment.
#
# The load-bearing case is netem_attach_point. `tc qdisc add dev X root netem` silently
# REPLACES TCLink's htb -- shaping gone, `del root` restores the kernel default rather than
# htb, and the NOPASSWD grants cannot put it back. So "on an htb interface, never attach at
# root" is the one property that, if it regresses, damages the testbed rather than the test.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAULTS="$HERE/../../tools/test_workflow/faults.sh"

PASS=0
FAIL=0

check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# faults.sh returns early when sourced, so this defines its functions without running one.
# shellcheck source=/dev/null
source "$FAULTS"

# ---------------------------------------------------------------------------------------
echo "the catalogue is data: faults.txt parses into ids, specs and reasons"

check "the shipped catalogue lists exactly the three agreed types" "L-2 L-3 N-4" \
      "$(catalogue_ids | tr '\n' ' ' | sed 's/ $//')"
check "commented-out TODO entries are not live types" no \
      "$(catalogue_ids | grep -q 'L-4' && echo yes || echo no)"
check "the spec field comes back whole" "link_loss direction=one loss=100% expect=moving" \
      "$(catalogue_field L-2 2)"
check "the reason field names the incident" yes \
      "$(catalogue_field L-2 3 | grep -q '291 s' && echo yes || echo no)"
check "an unknown id yields nothing" "" "$(catalogue_field L-99 2)"

echo "spec parsing"
check "the action is the first word" "link_loss" "$(spec_action "$(catalogue_field L-2 2)")"
check "a key is read out" "100%" "$(spec_value "$(catalogue_field L-2 2)" loss)"
check "a missing key falls back to the default" "any" \
      "$(spec_value "link_loss loss=5%" expect any)"
check "N-4 declares its restore signal" "CONT" "$(spec_value "$(catalogue_field N-4 2)" restore)"
check "L-3's expectation is 'moving' -- the gray-failure blind spot, stated" "moving" \
      "$(spec_value "$(catalogue_field L-3 2)" expect)"

# ---------------------------------------------------------------------------------------
echo
echo "netem attach point: never at root on a shaped (htb) interface"

HTB_TREE='qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 1 direct_packets_stat 0
qdisc pfifo_fast 0: dev s1-eth1 parent 5:1 bands 3'
PLAIN_TREE='qdisc pfifo_fast 0: dev s9-eth1 root refcnt 2 bands 3'
ALREADY_NETEM='qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 1
qdisc netem 10: dev s1-eth1 parent 5:1 limit 1000 loss 100%'

show_qdisc() { echo "$FAKE_TREE"; }

FAKE_TREE="$HTB_TREE"
check "htb root -> netem hangs under the default class" "parent 5:1" "$(netem_attach_point s1-eth1)"
check "htb root -> the answer is NEVER 'root'" no \
      "$([[ "$(netem_attach_point s1-eth1)" == "root" ]] && echo yes || echo no)"

FAKE_TREE="$PLAIN_TREE"
check "unshaped interface -> root is correct (the P4 testbed case)" "root" \
      "$(netem_attach_point s9-eth1)"

FAKE_TREE="$ALREADY_NETEM"
check "netem already present -> unsafe, refuse" "unsafe" "$(netem_attach_point s1-eth1)"

FAKE_TREE=""
check "unreadable tree -> unsafe, refuse" "unsafe" "$(netem_attach_point s1-eth1)"

FAKE_TREE='qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10'
check "htb with no default class -> unsafe rather than a guess" "unsafe" \
      "$(netem_attach_point s1-eth1)"

FAKE_TREE='qdisc htb 7: dev s2-eth3 root refcnt 2 default 20'
check "the handle and default class are read, not hardcoded" "parent 7:20" \
      "$(netem_attach_point s2-eth3)"

echo "netem delete point: remove exactly what was added"
FAKE_TREE="$ALREADY_NETEM"
check "a netem under a class is deleted by parent" "parent 5:1" "$(netem_delete_point s1-eth1)"
FAKE_TREE='qdisc netem 10: dev s9-eth1 root refcnt 2 limit 1000'
check "a netem at root is deleted at root" "root" "$(netem_delete_point s9-eth1)"
FAKE_TREE="$HTB_TREE"
check "no netem to delete -> unsafe, do not touch root" "unsafe" "$(netem_delete_point s1-eth1)"

# ---------------------------------------------------------------------------------------
echo
echo "a round: qdisc snapshot, baseline, inject, revert, recheck, diff"

# run_round is invoked through command substitution, and it calls these stubs through
# command substitution again, so shell variables cannot carry state between them -- the
# increments simply vanish. Everything the round mutates therefore lives in files.
TC_LOG="$TMP/tc.log"
SIG_LOG="$TMP/sig.log"
VERDICT_QUEUE="$TMP/verdicts"
NETEM_STATE="$TMP/netem"

reset_round() {
    : > "$TC_LOG"
    : > "$SIG_LOG"
    rm -rf "$NETEM_STATE"; mkdir -p "$NETEM_STATE"
    printf 'moving\nstill\nmoving\n' > "$VERDICT_QUEUE"
    QDISC_DIFF_RC=0
    QDISC_SAVE_RC=0
    TC_RC=0
    OPT_IFACE="s1-eth1"
    OPT_PEER_IFACE="s5-eth1"
    OPT_PID="12345"
    PAIR_SRC="10.0.0.1"
    PAIR_DST="10.0.0.2"
}

queue_verdicts() { printf '%s\n' "$@" > "$VERDICT_QUEUE"; }

# A qdisc tree per device, so adding netem to one interface does not make the other look
# contaminated -- which is what direction=both needs, and what a single static stub cannot
# express. Every device here is a shaped (htb) TCLink interface, the damaging case.
show_qdisc() {
    local dev="$1"
    echo "qdisc htb 5: dev $dev root refcnt 2 r2q 10 default 1 direct_packets_stat 0"
    if [[ -f "$NETEM_STATE/$dev" ]]; then
        echo "qdisc netem 10: dev $dev parent 5:1 limit 1000 loss 100%"
    else
        echo "qdisc pfifo_fast 0: dev $dev parent 5:1 bands 3"
    fi
}

run_tc() {
    echo "$*" >> "$TC_LOG"
    [[ $TC_RC -ne 0 ]] && return $TC_RC
    # Model what tc would actually do, so the revert has something real to find.
    local dev=""
    local prev=""
    local word
    for word in "$@"; do
        [[ "$prev" == "dev" ]] && dev="$word"
        prev="$word"
    done
    case "$1 $2" in
        "qdisc add") [[ -n "$dev" ]] && : > "$NETEM_STATE/$dev" ;;
        "qdisc del") [[ -n "$dev" ]] && rm -f "$NETEM_STATE/$dev" ;;
    esac
    return 0
}
run_signal() { echo "$1 $2" >> "$SIG_LOG"; return 0; }
settle()     { :; }
qdisc_save() { return $QDISC_SAVE_RC; }
qdisc_diff() { return $QDISC_DIFF_RC; }
check_pair() {
    local verdict
    verdict="$(head -1 "$VERDICT_QUEUE")"
    tail -n +2 "$VERDICT_QUEUE" > "$VERDICT_QUEUE.next"
    mv "$VERDICT_QUEUE.next" "$VERDICT_QUEUE"
    echo "${verdict:-moving}"
}

reset_round
queue_verdicts moving moving moving   # L-2 expects 'moving' during: P4 reroutes around it
out="$(run_round L-2 2>&1)"; rc=$?
check "a well-behaved round passes" 0 "$rc"
check "it says PASS" yes "$(grep -q "PASS L-2" <<<"$out" && echo yes || echo no)"
check "netem went under the class, not at root" yes \
      "$(grep -q "qdisc add dev s1-eth1 parent 5:1 netem loss 100%" "$TC_LOG" && echo yes || echo no)"
check "nothing was added at root" no \
      "$(grep -qE "qdisc add dev \S+ root" "$TC_LOG" && echo yes || echo no)"
check "direction=one touched exactly one interface" 1 \
      "$(grep -c "qdisc add" "$TC_LOG")"

echo "a tc that will not run says how to run it as uid 0"
reset_round
TC_RC=1
out="$(run_round L-2 2>&1)"; rc=$?
check "the round fails rather than pretending" 1 "$rc"
# Measured from `sudo -n -l` on 2026-08-13: the NOPASSWD grant for tc is only
#   tc qdisc add dev s*-eth* root netem *  /  del dev s*-eth* root  /  show dev s*-eth*
# so the SAFE `parent H:D` form this script computes is NOT permitted, while the form that
# destroys TCLink's htb is. Failing is correct; failing without saying why wastes a round.
check "and names the mnexec escape" yes "$(grep -q "mnexec" <<<"$out" && echo yes || echo no)"
check "and says the grant only covers the destructive form" yes \
      "$(grep -q "only the 'root netem' form" <<<"$out" && echo yes || echo no)"

echo "the qdisc diff is the veto"
reset_round
QDISC_DIFF_RC=1
out="$(run_round L-2 2>&1)"; rc=$?
check "a dirty qdisc tree fails the round even though the checks were fine" 1 "$rc"
check "and says the round is void" yes "$(grep -q "ROUND VOID" <<<"$out" && echo yes || echo no)"

reset_round
QDISC_SAVE_RC=1
out="$(run_round L-2 2>&1)"; rc=$?
check "no snapshot means nothing is injected at all" 1 "$rc"
check "and tc was never called" 0 "$(wc -l < "$TC_LOG")"

echo "a broken baseline is not a valid experiment"
reset_round
queue_verdicts still still still
out="$(run_round L-2 2>&1)"; rc=$?
check "a round on an already-dead network fails" 1 "$rc"
check "and injects nothing" 0 "$(wc -l < "$TC_LOG")"
check "and says why" yes "$(grep -q "already broken" <<<"$out" && echo yes || echo no)"
# Named verdict, not just a nonzero exit: without the precondition the round runs to the
# end and fails later for a different reason, which looks identical from the exit code.
check "and names the baseline verdict it refused" yes \
      "$(grep -q "baseline is 'still'" <<<"$out" && echo yes || echo no)"

echo "revert always runs"
reset_round
queue_verdicts moving still moving   # 'during' contradicts the catalogue's expect=moving
out="$(run_round L-2 2>&1)"; rc=$?
check "an unexpected mid-round verdict fails the round" 1 "$rc"
check "but the netem was still removed" yes \
      "$(grep -q "qdisc del dev s1-eth1 parent 5:1 netem" "$TC_LOG" && echo yes || echo no)"

echo "the network must come back"
reset_round
queue_verdicts moving still still
out="$(run_round L-2 2>&1)"; rc=$?
check "a network that stays dead after the revert fails the round" 1 "$rc"
check "and says the damage was left behind" yes \
      "$(grep -q "did not come back" <<<"$out" && echo yes || echo no)"

echo "direction=both needs both ends"
reset_round
OPT_PEER_IFACE=""
out="$(run_round L-3 2>&1)"; rc=$?
check "refuses without --peer-iface" 1 "$rc"
check "and says which option is missing" yes \
      "$(grep -q -- "--peer-iface" <<<"$out" && echo yes || echo no)"

reset_round
queue_verdicts moving moving moving   # L-3 expects moving: the gray-failure blind spot
out="$(run_round L-3 2>&1)"; rc=$?
check "direction=both touches both interfaces" 2 "$(grep -c "qdisc add" "$TC_LOG")"
check "and the second one is the peer" yes \
      "$(grep -q "dev s5-eth1" "$TC_LOG" && echo yes || echo no)"

echo "proc_signal targets a PID and restores it"
reset_round
# N-4's live answer (2026-08-16 first real round): the beacon watchdog reroutes around a
# frozen switch, so the catalogue now expects moving DURING the fault, and so must the
# stubbed round.
queue_verdicts moving moving moving
out="$(run_round N-4 2>&1)"; rc=$?
check "the round passes" 0 "$rc"
check "SIGSTOP went to the PID from --pid" yes \
      "$(grep -q "^STOP 12345$" "$SIG_LOG" && echo yes || echo no)"
check "SIGCONT put it back" yes "$(grep -q "^CONT 12345$" "$SIG_LOG" && echo yes || echo no)"
check "no tc was involved" 0 "$(wc -l < "$TC_LOG")"

reset_round
OPT_PID=""
out="$(run_round N-4 2>&1)"; rc=$?
check "refuses without --pid rather than signalling something else" 1 "$rc"
check "and nothing was signalled" 0 "$(wc -l < "$SIG_LOG")"

echo "unknown ids and unknown mechanisms are usage errors, not silent no-ops"
reset_round
out="$(run_round L-99 2>&1)"; rc=$?
check "an id not in the catalogue is exit 2" 2 "$rc"

CATALOGUE_BACKUP="$FAULTS_CATALOGUE"
FAULTS_CATALOGUE="$TMP/bogus.txt"
echo "X-1 | teleport target=moon expect=still | not a mechanism" > "$FAULTS_CATALOGUE"
reset_round
out="$(run_round X-1 2>&1)"; rc=$?
check "an unimplemented mechanism is exit 2" 2 "$rc"
check "and says a new mechanism needs code" yes \
      "$(grep -q "needs code" <<<"$out" && echo yes || echo no)"
FAULTS_CATALOGUE="$CATALOGUE_BACKUP"

echo "verdict matching"
check "'any' accepts anything" 0 "$(verdict_ok any disputed; echo $?)"
check "an exact match passes" 0 "$(verdict_ok still still; echo $?)"
check "a mismatch fails" 1 "$(verdict_ok still moving; echo $?)"

echo "option parsing"
PAIR_SRC=""; PAIR_DST=""
check "--pair splits into two addresses" "10.0.0.1/10.0.0.2" \
      "$(parse_opts --pair 10.0.0.1,10.0.0.2 >/dev/null 2>&1; echo "$PAIR_SRC/$PAIR_DST")"
check "a --pair without a comma is a usage error" 2 \
      "$(parse_opts --pair 10.0.0.1 >/dev/null 2>&1; echo $?)"
check "a missing --pair is a usage error" 2 \
      "$(PAIR_SRC=""; PAIR_DST=""; parse_opts --iface s1-eth1 >/dev/null 2>&1; echo $?)"
check "an unknown option is a usage error" 2 \
      "$(parse_opts --nope x >/dev/null 2>&1; echo $?)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
