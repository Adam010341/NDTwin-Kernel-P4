#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_up_down_robust.sh (findings #3, #21, #49, #83).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of the four defects and must turn its named case red:
# the `ndt up ovs4` that discovered a :8000 collision only after building Ryu and a 15-process
# fabric and then left both running; the orphan sweep whose exit status was thrown away; the
# teardown verdict taken before the process table had caught up; and the installed helper that
# has been five commits behind this tree since 08-30 with nothing saying so. A mutation nobody
# catches means its case proves nothing.
#
# 🔴 THREE KINDS OF MUTANT, because "check more, clean up more" has wrong answers that look
# like fixes:
#
#   M*  the defect itself, put back. Must be CAUGHT.
#   N*  a WIDENING -- the product stops discriminating and goes green on everything: a
#       preflight that never refuses, a rollback that only prints, a `down` that always exits
#       0, a helper comparison that always says "same". Every one of these passes a
#       fires-only gate, and every one puts back exactly the property these findings are
#       about: a check with no discriminating power that looks like a check. Must be CAUGHT.
#   W*  BEHAVIOUR-PRESERVING. A rename, a rewritten conditional, a reworded message nothing
#       depends on. The suite must stay GREEN. A suite that goes red on these is asserting on
#       the text of the implementation rather than on what it does, and it would then block
#       every later edit while proving nothing -- the other way an instrument stops working.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it right now -- and the sha256 line at the bottom says so.
#
# 🔴 A mutant directory carries ports.sh, sudo_surface.sh and components.env too. ndt sources
# the first two from beside itself, so a copy without them exits 2 at source time and every
# case goes red for a reason that has nothing to do with the mutation (MERGE-LOG.md, 09-03).
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation behaved as declared, 1 one did not, 2 refused (baseline red /
#       harness), 3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_up_down_robust.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-updown-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|passed, ' <<<"$out" | sed 's/^/             /'
    fi
}

# The W* direction. Same accounting, opposite expectation: an edit that changes no behaviour
# must leave the suite GREEN, and a red here is the suite over-fitted to the implementation's
# text rather than to what it does.
report_green() {   # $1 = mutation name, $2 = mutant dir, $3 = why it changes nothing
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-58s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  RED      %-58s (behaviour is unchanged, so this is the suite reading text)\n' "$1"
        grep -E '^  FAILED|passed, ' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole directory: ndt sources ports.sh and sudo_surface.sh from beside itself, so
# they travel with it, unmutated.  The anchor must be unique, so a mutation cannot quietly land
# somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line. A gate it cannot read is a gate it is not
# checking -- finding #28.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- #3, first half: the refusal moves back to before the machine is touched ----------------

# The defect exactly: the ownership verdict is computed, printed, and not acted on. This is what
# preflight did on 09-02 -- residue named, bring-up proceeded, stack.sh refused three minutes
# and one whole fabric later.
m=$(mutant m1 "$NDT" \
    '        err "  If it is a stray nobody owns:  ndt down --deep"
        bad=1' \
    '        err "  If it is a stray nobody owns:  ndt down --deep"
        :')
report "M1: a foreign holder is named and then built over anyway" "$m" \
       "🔴 a foreign holder of :8000 refuses the bring-up"

# The verdict itself collapses: everything visible is "ours". A check that can only say ours
# cannot refuse anything, which is the state trunk was in.
m=$(mutant m2 "$NDT" \
    '    done
    echo foreign
}' \
    '    done
    echo ours
}')
report "M2: every visible listener is called ours" "$m" \
       "🔴 a foreign holder of :8000 refuses the bring-up"

# The other conflation, and the more expensive one: a socket whose owner we cannot see is read
# as a stray. bmv2 runs as root, so that refuses every live P4 fabric -- the reuse path this
# whole distinction exists to keep working. Finding #7's shape, in new code.
m=$(mutant m3 "$NDT" \
    '    [[ -z "$pids" ]] && { echo unknown; return 0; }' \
    '    [[ -z "$pids" ]] && { echo foreign; return 0; }')
report "M3: a holder we cannot see becomes a stray" "$m" \
       "🔴 a holder we cannot see is NOT refused"

# Our own running stack stops being recognised: the pidfile is read and the pid comparison is
# gone, so `ndt up` on a live stack refuses itself.
m=$(mutant m4 "$NDT" \
    '            [[ "$pid" == "$recorded" ]] && { echo ours; return 0; }' \
    '            :')
report "M4: the pid ledger no longer identifies our own listener" "$m" \
       "🔴 :8000 held by OUR OWN kernel is not a refusal"

# The plane column is ignored, so an OVS bring-up starts refusing on P4-only leftovers -- the
# ports.sh row that exists to keep the two planes' residue apart.
m=$(mutant m5 "$NDT" \
    '    done < <(ndt_port_rows "$mode")
    if (( foreign == 1 )); then' \
    '    done < <(ndt_port_rows all)
    if (( foreign == 1 )); then')
report "M5: the preflight asks about every plane's ports" "$m" \
       "a P4-only port does not block an OVS bring-up"

# --- #3, second half: the rollback ----------------------------------------------------------

# The measured case, put straight back: stack.sh's kernel step fails and `ndt up` returns,
# leaving Ryu, the topo session and the data plane behind.
m=$(mutant m6 "$NDT" \
    '        rollback_up "stack.sh could not bring the kernel up over this fabric"
        return 1
    fi' \
    '        return 1
    fi')
report "M6: a failed 'ndt up ovs4' returns without rolling back" "$m" \
       "  and rolls back"

# The rollback runs but has been told nothing was started, so it takes nothing down. Existence
# is not wiring: rollback_up can be present, correct and never given a stage.
m=$(mutant m7 "$NDT" \
    '    up_started fabric
    sudo -n "$LAB" "$ovs_verb" >/dev/null || {' \
    '    sudo -n "$LAB" "$ovs_verb" >/dev/null || {')
report "M7: up_ovs never records that it built a fabric" "$m" \
       "  stops the topo session"

# 🔴 The opposite error, and the one that costs someone else their lab: the fabric stage is
# recorded before the reuse branch, so a bring-up that REUSED a running fabric sweeps it on the
# way out.
m=$(mutant m8 "$NDT" \
    '    # -- 1. fabric --
    say "[1/3] bmv2 fabric"' \
    '    # -- 1. fabric --
    say "[1/3] bmv2 fabric"
    up_started fabric')
report "M8: a REUSED fabric is rolled back as if we built it" "$m" \
       "🔴 but does NOT sweep the fabric it reused"

# 🔴 And the other opposite error: rolling back a stack that came up and merely failed its
# verification, which destroys the one state an operator needs to be able to read.
m=$(mutant m9 "$NDT" \
    '    say "[3/3] verify"
    verify_p4 "$topo" "$want_paths"' \
    '    say "[3/3] verify"
    verify_p4 "$topo" "$want_paths" || { rollback_up "verification failed"; return 1; }')
report "M9: a stack that failed VERIFICATION is torn down too" "$m" \
       "🔴 and is NOT rolled back"

# --- #21: the sweep's exit status ------------------------------------------------------------

# Trunk's line, restored verbatim: output to /dev/null, rc dropped, fabric built on top.
m=$(mutant m10 "$NDT" \
    '            local cout crc
            cout="$(sudo -n "$LAB" cleanup 2>&1)"; crc=$?' \
    '            local cout crc
            sudo -n "$LAB" cleanup >/dev/null 2>&1; crc=0; cout=""')
report "M10: up_p4 throws the orphan sweep's rc away again" "$m" \
       "🔴 a failed orphan sweep refuses the bring-up"

# cmd_down's half of the same shape. pipefail carries the rc out of the pipeline; nothing reads
# it, so "STILL RUNNING <label> pid N" scrolls past inside a teardown that then reports clean.
m=$(mutant m11 "$NDT" \
    '        err "cleanup exited $sweep_rc -- the sweep did not finish; what survived is named above"
        down_rc=1' \
    '        :')
report "M11: 'ndt down' ignores a sweep that did not finish" "$m" \
       "🔴 'ndt down' is red when its sweep did not finish"

# --- #49: the teardown verify and the sweep it verifies --------------------------------------

# The assertion goes back to being taken at the instant of the sweep: "5 still running / not
# clean" over a machine that reads 0 a moment later.
m=$(mutant m12 "$NDT" \
    '    wait_reaped "${NDT_REAP_WAIT:-20}" || true
    cmd_clean; local clean_rc=$?' \
    '    cmd_clean; local clean_rc=$?')
report "M12: 'ndt down' asserts at the instant of the sweep" "$m" \
       "🔴 processes reaped just after the sweep are not a failure"

# 🔴 #49 with the sign flipped, which is worse: the wait is allowed to decide. When it expires
# the assertion is skipped and the teardown reports success over a live leftover.
m=$(mutant m13 "$NDT" \
    '    wait_reaped "${NDT_REAP_WAIT:-20}" || true
    cmd_clean; local clean_rc=$?
    # Both halves count.' \
    '    wait_reaped "${NDT_REAP_WAIT:-20}" || return 0
    cmd_clean; local clean_rc=$?
    # Both halves count.')
report "M13: a wait that times out is reported as clean" "$m" \
       "🔴 a process that never leaves is still RED"

# `ndt clean` is the assertion about THIS INSTANT, separately callable. Give it the wait and it
# starts answering a different question -- and a caller checking whether the machine is free
# right now is told to come back in twenty seconds.
m=$(mutant m14 "$NDT" \
    'cmd_clean() {
    local rc=0 n p' \
    'cmd_clean() {
    local rc=0 n p
    wait_reaped "${NDT_REAP_WAIT:-20}" || true')
report "M14: 'ndt clean' waits too" "$m" \
       "🔴 'ndt clean' alone does not wait"

# --- #83: the installed helper ---------------------------------------------------------------

# The comparison is made, printed, and kept out of --check: exactly the state of trunk, one
# print statement further along. A reader who runs --check is told the lab is fine.
m=$(mutant m15 "$NDT" \
    '        differs)       echo "the installed $LAB' \
    '        differs)       : "the installed $LAB')
report "M15: a mismatched helper is shown but not counted" "$m" \
       "🔴 'ndt status --check' counts it as a problem"

# "Could not compare" becomes "the same" -- the conflation this file argues against everywhere
# else, applied to its own new reading.
m=$(mutant m16 "$NDT" \
    '    if [[ -z "$repo" ]]; then echo "no-repo-copy $inst ?"; return; fi' \
    '    if [[ -z "$repo" ]]; then echo "same $inst $inst"; return; fi')
report "M16: an unanswerable helper comparison is called a match" "$m" \
       "🔴 'could not compare' is not green"

# 🔴 The other direction: preflight starts REFUSING on a helper mismatch. Whether to install is
# Adam's decision, and a bring-up that will not run until somebody types a sudo command is a
# worse failure than one that runs the old helper and says which one it ran.
m=$(mutant m17 "$NDT" \
    '    if (( labrc != 0 )); then' \
    '    if (( labrc != 0 )); then bad=1')
report "M17: a mismatched helper refuses the bring-up" "$m" \
       "🔴 preflight WARNS and does not refuse"

# --- R5: the tree `sudo ndtwin-lab` acts in ---------------------------------------------------

# The defect itself, put back: nothing compares $REPO with the lab's KERNEL_DIR, so `ndt up`
# from a worktree builds the fabric out of one tree and the kernel and proxy out of another.
# 🔴 Named on a case that DISCRIMINATES. "the bring-up is refused" stays green under this
# mutation for the wrong reason -- the fixture's fabric never reaches ten switches either way,
# so the exit code is 1 regardless. What only the comparison can produce is a refusal that
# touched nothing at all.
m=$(mutant m18 "$NDT" \
    '    guard_lab_acts_in_this_tree || bad=1' \
    '    :')
report "M18: nothing compares this checkout with the lab's tree" "$m" \
       "🔴 nothing on the machine was touched"

# The comparison is made on the strings instead of on the trees. It passes every case that has
# two genuinely different paths, and then refuses a correctly configured run whenever the two
# name the same tree by different names -- a guard against a silent wrong answer turned into a
# bring-up that cannot be made to work.
m=$(mutant m19 "$NDT" \
    '    lab="$(realpath "$lab" 2>/dev/null || printf '"'"'%s'"'"' "$lab")"' \
    '    :')
report "M19: the two trees are compared as strings, not as paths" "$m" \
       "🔴 the same tree through a symlink is not a refusal"

# 🔴 The other direction, and the one that would make this whole guard unusable: it refuses
# everything. Every "did it refuse the mismatch" case above stays green, because a check that
# cannot pass cannot pass on the wrong fixture either.
m=$(mutant m20 "$NDT" \
    '    [[ "$repo" == "$lab" ]] && return 0' \
    '    [[ "$repo" == "$lab" ]] && { :; }')
report "M20: the guard refuses even when the trees are the same" "$m" \
       "🔴 the same tree is not a refusal"

# The refusal reports this checkout's host_count_override for both trees. It still prints two
# paths and two numbers -- and the two numbers are the same one, so the reader is told the
# fabric would be built at a size it would not be built at. FINDING-01's shape inside the
# message written to prevent it.
m=$(mutant m21 "$NDT" \
    'the fabric would come from      $lab  (host_count_override $(host_count_in "$lab"))' \
    'the fabric would come from      $lab  (host_count_override $(host_count_in "$repo"))')
report "M21: both host counts are read from this tree" "$m" \
       "  the lab's tree, with ITS host count"

# `ndt:1673` restored: the one line ndtwin-lab prints to say which tree it acted in goes back
# to /dev/null. The guard above only fires when the trees DIFFER, so with this gone there is
# no output at all naming the tree a successful bring-up actually used.
m=$(mutant m22 "$NDT" \
    '        tsout="$(sudo -n "$LAB" topo-start 2>&1)"; tsrc=$?
        [[ -n "$tsout" ]] && printf '"'"'%s\n'"'"' "$tsout" | sed '"'"'s/^/      /'"'"'' \
    '        tsout="$(sudo -n "$LAB" topo-start 2>&1)"; tsrc=$?')
report "M22: topo-start's 'which tree' line is discarded again" "$m" \
       "🔴 and the helper's 'which tree' line reaches the operator"

# The refusal stops saying whose knob the two numbers are. It is a P4-only knob, and this is
# also printed on the OVS plane, where the size is the verb -- `ndt status` printed the same
# knob's neighbour on the OVS plane for weeks (D-2 / X-2) and it was read as an OVS answer.
m=$(mutant m23 "$NDT" \
    '    err "  (that knob is the P4 plane'"'"'s. On the OVS plane the size is the verb -- ovs-topo-start"' \
    '    :')
report "M23: the refusal stops saying whose knob those numbers are" "$m" \
       "🔴 and says that knob is the P4 plane's, not what OVS builds"

# --- H4: the model and the fabric are different networks (ROLE-2, 2026-09-11) -----------------

# M24 restores H4 verbatim: the NDT_TOPO escape hatch checks only that the file EXISTS. That is
# the code ROLE-2 ran `NDT_TOPO=<128-host model> ndt up p4 4` against -- fabric built, kernel
# never started, [2/3] hung past 300 s.
m=$(mutant m24 "$NDT" \
    '        local mh; mh="$(topo_model_counts "$NDT_TOPO")"; mh="${mh%% *}"' \
    '        local mh=""; echo "$NDT_TOPO"; return 0
        mh="$(topo_model_counts "$NDT_TOPO")"; mh="${mh%% *}"')
report "M24: NDT_TOPO is honoured on existence alone again (H4)" "$m" \
       "  🔴 rc 3 -- a real file, for the wrong network"

# M25: the comparison happens and the answer is thrown away -- the shape a "checked it, carried
# on" fix has. The refusal is what has to survive, not the arithmetic.
m=$(mutant m25 "$NDT" \
    '        if (( mh != want )); then
            TOPO_REFUSAL=' \
    '        if false; then
            TOPO_REFUSAL=')
# 🔴 Named case chosen after running the gate: with only THIS guard gone, record_up_target
# still refuses and `up_p4` still returns 1, so "the bring-up is refused" stays green -- two
# guards mean one can be removed without the property breaking. What only this site can produce
# is the rc-3 message, so that is what must go red.
report "M25: the host counts are compared and the verdict dropped" "$m" \
       "  naming a model of a different network"

# M26: F8's failure mode, which this fix reproduced once already. TOPO_REFUSAL is read back
# from a command substitution, so the refusal prints its fallback and names no numbers.
m=$(mutant m26 "$NDT" \
    '    both="$(topo_for_hosts "$hosts" p4; printf '"'"'\t%s\t%s'"'"' "$?" "$TOPO_REFUSAL")"
    topo="${both%%$'"'"'\t'"'"'*}"; rest="${both#*$'"'"'\t'"'"'}"
    trc="${rest%%$'"'"'\t'"'"'*}"; TOPO_REFUSAL="${rest#*$'"'"'\t'"'"'}"' \
    '    topo="$(topo_for_hosts "$hosts" p4)"; trc=$?
    both=""; rest=""')
# 🔴 Also repointed after running the gate: "the reason names both counts" reads TOPO_REFUSAL
# in the TEST's own shell, where no substitution ate it, so it cannot see this at all. The cell
# that can is the one reading up_p4's printed refusal.
report "M26: the refusal's reason dies in a subshell (F8's shape)" "$m" \
       "  🔴 and the refusal names both counts, not a fallback"

# M27: the second guard alone. record_up_target goes back to writing hosts and model_hosts side
# by side without comparing them -- the sharpest point of ROLE-2 §4.
m=$(mutant m27 "$NDT" \
    '    if [[ "$mh" =~ ^[0-9]+$ && "$hosts" =~ ^[0-9]+$ ]] && (( mh != hosts )); then' \
    '    if false; then')
report "M27: record_up_target writes both numbers and compares neither" "$m" \
       "  🔴 record_up_target refuses hosts=4 against model_hosts=128"

# M28: the other direction, and the one that would remove the documented escape hatch: any
# NDT_TOPO is refused. Every cell above stays red-worthy; the CONTROLS are what catch it.
m=$(mutant m28 "$NDT" \
    '        if (( mh != want )); then' \
    '        if true; then')
report "M28 (widening): every NDT_TOPO is refused" "$m" \
       "  🔴 a MATCHING NDT_TOPO is still honoured"

# M29: an uncountable model is refused instead of warned about. NDT_TOPO exists for models that
# do not follow the conventions, and "I could not count them" is not a mismatch.
m=$(mutant m29 "$NDT" \
    '            echo "$NDT_TOPO"; return 0
        fi
        if (( mh != want )); then' \
    '            return 1
        fi
        if (( mh != want )); then')
report "M29: an uncountable NDT_TOPO is refused rather than warned about" "$m" \
       "  an uncountable model is not refused"

# --- N*: widenings. The product goes green on everything; the suite has to notice -------------

# N1, the control: preflight never refuses. It passes every "did it go red on the broken
# fixture" question a fires-only gate asks, because a check that cannot fail cannot fail on the
# wrong fixture either.
m=$(mutant n1 "$NDT" \
    '    local labout labrc
    labout="$(lab_version_report 2>&1)"; labrc=$?' \
    '    bad=0
    local labout labrc
    labout="$(lab_version_report 2>&1)"; labrc=$?')
report "N1 (control, always green): preflight refuses nothing" "$m" \
       "🔴 a foreign holder of :8000 refuses the bring-up"

# N2: the rollback announces itself, lists what it started, and does nothing. Every message the
# suite could read at a glance is still there.
m=$(mutant n2 "$NDT" \
    '    for (( i = ${#UP_STARTED[@]} - 1; i >= 0; i-- )); do
        stage="${UP_STARTED[$i]}"
        case "$stage" in' \
    '    for (( i = ${#UP_STARTED[@]} - 1; i >= 0; i-- )); do
        stage="${UP_STARTED[$i]}"
        case "nothing" in')
report "N2 (widening, green): the rollback prints and does nothing" "$m" \
       "  stops the topo session"

# N3: `ndt down` always exits 0. The report above it is unchanged, so only an exit code tells
# the two apart -- and the exit code is what every caller reads.
# Anchor moved 2026-09-06 (W13): claim_note_down now sits between the two lines this used to
# span. The mutation is unchanged -- it still replaces cmd_down's only return with a constant 0.
# 🔴 Re-anchored 2026-09-11: H3 inserted `mark_teardown_end` between these two lines, and this
# anchor -- which spanned both -- silently stopped matching. The mutant then carried an
# UNMUTATED ndt, the suite was green, and the gate reported N3 as a survivor. That is
# tests/shell/README.md §1's case, and the reason the gate's verdict is the one we ship.
m=$(mutant n3 "$NDT" \
    '    mark_teardown_end
    return "$down_rc"' \
    '    mark_teardown_end
    return 0')
report "N3 (widening, green): 'ndt down' always exits 0" "$m" \
       "🔴 a process that never leaves is still RED"

# N4: the helper comparison always says the copies match. It still prints a line, with a sha in
# it, in the right place.
m=$(mutant n4 "$NDT" \
    '    if [[ "$inst" == "$repo" ]]; then echo "same $inst $repo"; else echo "differs $inst $repo"; fi' \
    '    echo "same $inst $repo"')
report "N4 (widening, green): the helpers always agree" "$m" \
       "a differing helper is reported"

# N5: the tree comparison always agrees. It is present, it is called from preflight, and it can
# only say "same tree" -- existence is not wiring, and a guard that cannot refuse is the state
# trunk was in with the reading already sitting there unused (lab_kernel_dir, one caller, a log
# path).
m=$(mutant n5 "$NDT" \
    'guard_lab_acts_in_this_tree() {
    local repo lab src both' \
    'guard_lab_acts_in_this_tree() {
    return 0
    local repo lab src both')
report "N5 (widening, green): the tree comparison always agrees" "$m" \
       "🔴 nothing on the machine was touched"

# --- W*: behaviour-preserving. The suite must stay GREEN --------------------------------------

# W1: the same condition in the other test syntax. Nothing observable moves.
m=$(mutant w1 "$NDT" \
    '    if (( foreign == 1 )); then' \
    '    if [[ "$foreign" == 1 ]]; then')
report_green "W1 (behaviour-preserving): an arithmetic test written as a string test" "$m" \
       "(( x == 1 )) and [[ x == 1 ]] decide the same thing on a 0/1 flag"

# W2: the early return in wait_reaped rewritten from `&&` to an if. Same condition, same answer.
m=$(mutant w2 "$NDT" \
    '    [[ "$n0" -eq 0 && "$m0" -eq 0 ]] && return 0' \
    '    if [[ "$n0" -eq 0 ]] && [[ "$m0" -eq 0 ]]; then return 0; fi')
report_green "W2 (behaviour-preserving): wait_reaped's guard rewritten" "$m" \
       "the same condition, spelled differently"

# W3: a message reworded that no assertion depends on. A suite that reads whole sentences back
# would go red here and would then block every later edit to the wording.
m=$(mutant w3 "$NDT" \
    '                err "deal with it, then retry:  ndt down --deep && ndt up p4"' \
    '                err "sort that out first, then run:  ndt down --deep && ndt up p4"')
report_green "W3 (behaviour-preserving): an advice line reworded" "$m" \
       "the advice text is not the behaviour under test"

# W4: `echo` replaced by `printf` in the verdict function. Same bytes on stdout.
m=$(mutant w4 "$NDT" \
    '    if [[ -z "$inst" ]]; then echo "not-installed ? ${repo:-?}"; return; fi' \
    '    if [[ -z "$inst" ]]; then printf "%s\n" "not-installed ? ${repo:-?}"; return; fi')
report_green "W4 (behaviour-preserving): echo written as printf" "$m" \
       "identical bytes on stdout"

# W5: the tree comparison's early return written as an if. Same condition, same answer, and the
# suite must not be reading the shape of it.
m=$(mutant w5 "$NDT" \
    '    [[ "$repo" == "$lab" ]] && return 0' \
    '    if [[ "$repo" == "$lab" ]]; then return 0; fi')
report_green "W5 (behaviour-preserving): the tree comparison written as an if" "$m" \
       "the same condition, spelled differently"

# W6: the refusal's first line reworded. Nothing asserts on it -- what the cases read is the two
# paths, the two host counts and the sentence with both ways out.
m=$(mutant w6 "$NDT" \
    '    err "refusing to build: '"'"'sudo $LAB'"'"' does not act in this checkout."' \
    '    err "refusing to build: '"'"'sudo $LAB'"'"' acts in a different tree than this one."')
report_green "W6 (behaviour-preserving): the refusal's opening line reworded" "$m" \
       "the wording of the first line is not the behaviour under test"

# --- H3: a bring-up that overlaps a teardown (ROLE-2, 2026-09-11) -----------------------------

# M30 restores H3: nothing records that a teardown is running, so the only reading a P4
# bring-up can take is the ports -- which look identical coming up and going down.
m=$(mutant m30 "$NDT" \
    '    mark_teardown_start

    say "ndt down"' \
    '    say "ndt down"')
# 🔴 Named case chosen after running the gate: "the marker is absent when `down` finishes" is
# satisfied by a `down` that never wrote one, so it cannot see this mutation at all. Only the
# cell that reads the marker from INSIDE the teardown can.
report "M30: the teardown records nothing again (H3)" "$m" \
       "  🔴 and it is present DURING the teardown, not just around it"

# M31: the marker is written and nobody refuses on it -- a guard wired to nothing, which is
# what every "the mechanism exists" check would have signed off (F8's lesson, one file over).
m=$(mutant m31 "$NDT" \
    '    guard_no_teardown_in_flight || bad=1' \
    '    :')
report "M31: the guard is not called from preflight" "$m" \
       "  🔴 P4 preflight refuses while a teardown runs"

# M32: the marker is never removed, so one teardown makes the lab permanently unstartable.
m=$(mutant m32 "$NDT" \
    '    mark_teardown_end
    return "$down_rc"' \
    '    return "$down_rc"')
report "M32: the teardown never removes its marker" "$m" \
       "  🔴 'ndt down' removes its own marker when it finishes"

# M33: STALENESS DROPPED -- the file's existence is the whole test. A `down` killed mid-run
# then blocks every later bring-up, which is worse than the overlap this fixes.
m=$(mutant m33 "$NDT" \
    '    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then' \
    '    if false; then')
report "M33: a stale marker refuses forever" "$m" \
       "  🔴 a marker whose pid is gone does NOT refuse"

# M34 (widening): every marker is stale, so the guard can never fire. It passes every "does it
# clear a dead marker" cell and none of the refusal cells.
m=$(mutant m34 "$NDT" \
    '    [[ -f "$f" ]] || return 1
    pid="$(sed -n '"'"'s/^pid=//p'"'"' "$f" | head -1)"' \
    '    [[ -f "$f" ]] || return 1
    return 1
    pid="$(sed -n '"'"'s/^pid=//p'"'"' "$f" | head -1)"')
report "M34 (widening): no teardown is ever in flight" "$m" \
       "  🔴 P4 preflight refuses while a teardown runs"

# M35: the marker is written before the refusals, so a `down` that refused to run claims to be
# running one -- and then blocks a bring-up that should have been allowed.
m=$(mutant m35 "$NDT" \
    '    held="$(foreign_claim)"
    if [[ -n "$held" && "$force" != "--force" ]]; then' \
    '    mark_teardown_start
    held="$(foreign_claim)"
    if [[ -n "$held" && "$force" != "--force" ]]; then')
report "M35: a refused teardown still claims to be running" "$m" \
       "  🔴 a refused 'ndt down' writes no marker"


# --- F1: the plane the rate is read for (F-OFFLINE-1 §1.14) -----------------------------------

# M36 restores F1: `sample_rate` is asked with no argument, so it looks the plane up -- and on a
# machine with an OVS fabric left up that prints OVSDB's number, or "samples NOTHING", under
# "(compiled into ndtwin_switch.json)".
m=$(mutant m36 "$NDT" \
    '    rate="$(sample_rate p4)"' \
    '    rate="$(sample_rate)"')
report "M36: up_p4 looks the plane up instead of naming it (F1)" "$m" \
       "  🔴 the plane is passed, not looked up"

# M37: the plane is named, and named wrong. "It passes an argument" is not the property.
m=$(mutant m37 "$NDT" \
    '    rate="$(sample_rate p4)"' \
    '    rate="$(sample_rate ovs)"')
report "M37: up_p4 asks for the OVS plane's rate" "$m" \
       "  🔴 and OVS's 'samples NOTHING' never appears there"


echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
