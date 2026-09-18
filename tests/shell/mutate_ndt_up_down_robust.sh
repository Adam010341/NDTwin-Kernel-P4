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

# 🔴 A MUTANT THAT DOES NOT PARSE IS NOT A MUTANT (round-3 ruling 3). `bash -n` is the whole
# guard: a syntactically dead `ndt` reddens every cell for one reason -- it cannot run -- which
# looks exactly like "the suite is sensitive" while proving nothing, and leaves the NAMED cell
# absent from the output, which `report` cannot tell from green. That is how M9 was reported as
# a survivor for a defect that was in the GATE. Refuse instead: a gate that cannot say what it
# measured must not print a verdict.
syntax_ok() {   # $1 = mutant dir; prints the error when it is not
    bash -n "$1/ndt" 2>&1
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc err
    MUTATIONS=$((MUTATIONS+1))
    if ! err="$(syntax_ok "$2")" || [[ -n "$err" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 DEAD   %-58s (the mutant is not valid bash -- it measures nothing)\n' "$1"
        sed 's/^/             /' <<<"$err"
        return
    fi
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        if [[ -f "$2/.unapplied" ]]; then
            printf '  SURVIVED %-58s (anchor could not be applied -- the gate cannot find that line any more)\n' "$1"
            sed 's/^/             /' "$2/.apply.err"
        else
            printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        fi
        grep -E '^  FAILED|passed, ' <<<"$out" | sed 's/^/             /'
    fi
}

# The W* direction. Same accounting, opposite expectation: an edit that changes no behaviour
# must leave the suite GREEN, and a red here is the suite over-fitted to the implementation's
# text rather than to what it does.
report_green() {   # $1 = mutation name, $2 = mutant dir, $3 = why it changes nothing
    local out rc err
    MUTATIONS=$((MUTATIONS+1))
    if ! err="$(syntax_ok "$2")" || [[ -n "$err" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 DEAD   %-58s (the mutant is not valid bash -- it measures nothing)\n' "$1"
        sed 's/^/             /' <<<"$err"
        return
    fi
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-58s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        if [[ -f "$2/.unapplied" ]]; then
            printf '  RED      %-58s (anchor could not be applied, so this red is about nothing)\n' "$1"
            sed 's/^/             /' "$2/.apply.err"
        else
            printf '  RED      %-58s (behaviour is unchanged, so this is the suite reading text)\n' "$1"
        fi
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
    # 🔴 AN ANCHOR THAT WILL NOT APPLY IS A SURVIVOR, AND IT MUST SAY WHICH KIND. Until
    # 2026-09-12 this python ran bare: a stale anchor printed a traceback into the gate's own
    # log, the copy stayed UNMUTATED, the suite was green, and the gate said `SURVIVED -- that
    # case proves nothing`. "The assertion is not load-bearing" and "the gate can no longer find
    # that line" are very different diagnoses, and this ticket produced four of the second kind
    # in one round. tests/shell/mutate_live_cells.sh has said it this way since 09-11.
    if ! python3 - "$d/$(basename "$file")" "$old" "$new" > "$d/.apply.err" 2>&1 <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        printf 'ANCHOR-NOT-APPLIED %s\n' "$label" > "$d/.unapplied"
    fi
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
# 🔴 THE ANCHOR IS THE COMPLETE CALL, AND IT WAS NOT (TICKET-P3 round-3 ruling 3).
# `verify_p4 "$topo" "$want_paths"` became a PREFIX of the real line when verify_p4 grew two
# more arguments (`ndt:3307` now passes "$app_mode" "$app_pipe"). The mutant therefore became
#     verify_p4 "$topo" "$want_paths" || { ... } "$app_mode" "$app_pipe"
# -- a bash syntax error. The whole of `ndt` then failed to parse, all 424 cells went red, and
# the NAMED cell never printed at all, so `report` read it as "stayed green" and called M9 a
# survivor. A gate whose mutant does not PARSE is measuring nothing; the bash -n below turns
# that into a refusal instead of a survivor, and this anchor stops it happening here.
m=$(mutant m9 "$NDT" \
    '    say "[3/3] verify"
    verify_p4 "$topo" "$want_paths" "$app_mode" "$app_pipe"' \
    '    say "[3/3] verify"
    verify_p4 "$topo" "$want_paths" "$app_mode" "$app_pipe" || { rollback_up "verification failed"; return 1; }')
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
# 🔴 Re-anchored 2026-09-12 (FIX-NDT-8): `verify clean` is now handed the subject cmd_down
# measured before it acted, so the line this spans gained an argument. The mutation is the same
# one -- take the wait away -- said against the new call.
m=$(mutant m12 "$NDT" \
    '    wait_reaped "${NDT_REAP_WAIT:-20}" || true
    cmd_clean "$DOWN_SUBJECT"; local clean_rc=$?' \
    '    cmd_clean "$DOWN_SUBJECT"; local clean_rc=$?')
report "M12: 'ndt down' asserts at the instant of the sweep" "$m" \
       "🔴 processes reaped just after the sweep are not a failure"

# 🔴 #49 with the sign flipped, which is worse: the wait is allowed to decide. When it expires
# the assertion is skipped and the teardown reports success over a live leftover.
m=$(mutant m13 "$NDT" \
    '    wait_reaped "${NDT_REAP_WAIT:-20}" || true
    cmd_clean "$DOWN_SUBJECT"; local clean_rc=$?
    # Both halves count.' \
    '    wait_reaped "${NDT_REAP_WAIT:-20}" || return 0
    cmd_clean "$DOWN_SUBJECT"; local clean_rc=$?
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
#
# 🔴 REPOINTED TWICE, and the second time is the lesson. This anchor used to start at the
# `both="$(...)"` line; the H4-newline fix put a ten-line comment between that line and the two
# below it, so the anchor went to 0 hits and this gate reported SURVIVED -- correctly, because an
# applier that cannot apply is a hole and never a skip. check_gate_anchors.py had said ok(45)
# minutes before, counting against a HEAD that did not yet carry the fix. The anchor is now the
# two lines that unpack the reading, which are adjacent and stay adjacent; the packed read above
# is left to run and have its result discarded, and the plain substitution below is what puts
# F8's shape back.
m=$(mutant m26 "$NDT" \
    '    topo="${both%%$'"'"'\t'"'"'*}"; topo="${topo%%$'"'"'\n'"'"'*}"; rest="${both#*$'"'"'\t'"'"'}"
    trc="${rest%%$'"'"'\t'"'"'*}"; TOPO_REFUSAL="${rest#*$'"'"'\t'"'"'}"' \
    '    topo="$(topo_for_hosts "$hosts" p4)"; trc=$?')
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
# 🔴 Re-anchored 2026-09-12 (FIX-NDT-8): the teardown's single exit now returns down_verdict,
# which is down_rc except in the one case where nothing was there to tear down (rc 3).
m=$(mutant n3 "$NDT" \
    '    mark_teardown_end
    return "$down_verdict"' \
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
    '    mark_teardown_start || return 5

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
    '    guard_no_teardown_in_flight || { bad=1; refused=5; }' \
    '    :')
report "M31: the guard is not called from preflight" "$m" \
       "  🔴 P4 preflight refuses while a teardown runs"

# M32: the marker is never removed, so one teardown makes the lab permanently unstartable.
m=$(mutant m32 "$NDT" \
    '    mark_teardown_end
    return "$down_verdict"' \
    '    return "$down_verdict"')
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


# --- ROLE-12 (2026-09-12): the marker has an owner --------------------------------------------

# M40 restores ROLE-12's first half: mark_teardown_start writes `pid=$$` over whatever is there.
# A second `ndt down` then takes the record of the first one, and for as long as the first is
# alive every refusal a bring-up gets names the wrong process.
m=$(mutant m40 "$NDT" \
    '        if [[ "${tif%% *}" != "$$" ]]; then' \
    '        if false; then')
report "M40: the teardown marker is overwritten again (ROLE-12)" "$m" \
       "🔴 a second 'ndt down' is refused while one is still running"

# M41 restores the other half, and it is the half that actually removed the guard: an
# unconditional `rm -f`, so the teardown that finishes first deletes the marker of the one still
# running (02:07:32.687, with the next `ndt up p4 4` unrefused four milliseconds later).
m=$(mutant m41 "$NDT" \
    '    if [[ "$pid" == "$$" ]]; then rm -f "$f"; return 0; fi' \
    '    rm -f "$f"; return 0')
report "M41: mark_teardown_end removes anybody's marker (ROLE-12)" "$m" \
       "🔴 mark_teardown_end does not remove a marker that is not its own"

# M42: the refusal is printed and not acted on -- F8's shape, a third time. The operator sees
# the whole message and the teardown runs anyway.
m=$(mutant m42 "$NDT" \
    '    mark_teardown_start || return 5' \
    '    mark_teardown_start || true')
report "M42: the second teardown's refusal is not carried to the rc" "$m" \
       "  🔴 so no stack.sh teardown ran"

# W7 (behaviour-preserving): the explanation under that refusal reworded. Nothing asserts on it,
# and a suite that went red here would be reading the sentence rather than the refusal.
m=$(mutant w7 "$NDT" \
    '            err "  two teardowns of one lab do not take turns. The second would overwrite this"' \
    '            err "  one lab does not take two teardowns at once. The second would overwrite this"')
report_green "W7 (behaviour-preserving): the second-teardown explanation reworded" "$m" \
       "the wording under the refusal is not the behaviour under test"


# --- ROLE-12 (2026-09-12): the teardown rc is its ending, not a reading from the middle -------

# M43 restores the 7-of-7: nothing is deferred, so a live P4 teardown is red because [1/3] ran
# before the sweep that closes the very ports it is complaining about.
m=$(mutant m43 "$NDT" \
    '        ports_deferred="$(stack_down_deferrable_ports "$out")"' \
    '        ports_deferred=""')
report "M43: a mid-teardown port reading is the verdict again (ROLE-12)" "$m" \
       "🔴 ports [1/3] found open and [3/3] closed are not a failed teardown"

# M44 (widening): the ports are deferred and never re-read, so the half is simply forgiven --
# which passes every "a live P4 down is green" cell and no longer notices a real leftover. This
# is the mutation the stubbed-green cmd_clean cell exists for: with clean_rc inherited instead,
# this mutant would look identical to the fix.
m=$(mutant m44 "$NDT" \
    '            ndt_port_open "$dp" "$dproto" && dstill="${dstill:+$dstill }$dp"' \
    '            :')
report "M44 (widening): the deferred ports are never re-read" "$m" \
       "🔴 a port STILL held after [3/3] keeps the teardown red"

# M45: the fatal-ending exclusion dropped. A crash is delivered ONCE, out of a .exit record
# report_exit then deletes, so an rc that swallowed it would lose it for good.
m=$(mutant m45 "$NDT" \
    '    grep -qF -- "$STACK_DOWN_FATAL_ENDING" <<<"$out" && return 0' \
    '    :')
report "M45: a fatal ending is deferred along with the ports" "$m" \
       "🔴 a fatal ending alongside the ports keeps the teardown red"

# M46: the other exclusion dropped -- a port held by a process this stack STARTED is stop_one
# failing, and no sweep of the data plane addresses it.
m=$(mutant m46 "$NDT" \
    '    grep -qF -- "$STACK_DOWN_OUR_PORT"     <<<"$out" && return 0' \
    '    :')
report "M46: 'stop_one could not stop it' is deferred too" "$m" \
       "🔴 a port this stack STARTED still holds keeps the teardown red"

# M47: the RETURN-SITE pin dropped, so the reader is back to a vocabulary -- any mention of a
# still-listening port defers, wherever in stack.sh's output it came from.
m=$(mutant m47 "$NDT" \
    '    grep -qF -- "$STACK_DOWN_RETURNED_ON_PORTS" <<<"$out" || return 0' \
    '    :')
report "M47: the classification stops being pinned to a return site" "$m" \
       "🔴 ports named outside that branch defer nothing"

# W8 (behaviour-preserving): the explanation printed with the deferral reworded. The cells read
# the deferral and the re-read, not this sentence.
m=$(mutant w8 "$NDT" \
    '            warn "  [1/3] runs BEFORE the data-plane sweep in [3/3], so on a live P4 fabric this"' \
    '            warn "  [1/3] happens ahead of the data-plane sweep in [3/3], so on a live P4 fabric this"')
report_green "W8 (behaviour-preserving): the deferral note reworded" "$m" \
       "the note above the re-read is not the behaviour under test"


# --- ROLE-12 cell 3: `ndt clean` during a teardown --------------------------------------------

# M48 restores cell 3: `ndt clean` walks straight into a live teardown and reports the fabric
# being destroyed as residue, ending on the one piece of advice that would kill the operator's
# own processes. The named case is the refusal's TEXT, not its rc -- cmd_clean is already rc 1
# about a dirty machine, so the rc alone cannot see this mutation at all.
m=$(mutant m48 "$NDT" \
    '    if tif="$(teardown_in_flight)" && [[ "${tif%% *}" != "$$" ]]; then' \
    '    if false; then')
report "M48: 'ndt clean' has no guard against a live teardown again (ROLE-12)" "$m" \
       "  naming what it is refusing on"

# M49 (widening): the guard reads the FILE instead of its owner, so it also refuses `ndt down`'s
# own `verify clean` -- the last step of every round -- while passing every refusal cell above.
m=$(mutant m49 "$NDT" \
    '    if tif="$(teardown_in_flight)" && [[ "${tif%% *}" != "$$" ]]; then' \
    '    if tif="$(teardown_in_flight)"; then')
report "M49 (widening): the clean guard refuses its own teardown too" "$m" \
       "🔴 'ndt down' is not refused by its own marker at verify clean"


# --- ROLE-11 F5: whose processes `ndt clean` is looking at ------------------------------------

# M50 restores F5's pidfile half: the registry is not consulted, so the kernel and proxy this
# stack started and recorded are summarised as "this stack did not start it".
m=$(mutant m50 "$NDT" \
    '                if [[ "$(port_owner_local "$cport" "$cproto")" == ours ]]; then' \
    '                if false; then')
report "M50: 'ndt clean' stops reading .test_run/pids/ (ROLE-11 F5)" "$m" \
       "🔴 a pid in .test_run/pids/ is not 'this stack did not start it'"

# M51 restores the other half: bmv2 is root-owned, so the pidfile test CANNOT answer for its
# twenty ports -- drop the manifest arm and the fabric's own ports are strangers again, which
# is most of the 74 lines ROLE-11 was shown.
m=$(mutant m51 "$NDT" \
    '                elif [[ "$cplane" == p4 && -e "$MANIFEST" ]]; then' \
    '                elif false; then')
report "M51: the switch manifest stops answering for bmv2's ports" "$m" \
       "🔴 a bmv2 port under this stack's own manifest is not a stranger either"

# M52 (widening): everything is ours, so the sentence is never printed at all. That passes
# every F5 cell and takes away the report that a stray :8000 makes the next round measure the
# wrong kernel -- the defect ports.sh exists for, with the sign flipped.
m=$(mutant m52 "$NDT" \
    '                    strangers+=("$cport")' \
    '                    mine+=(":$cport")')
report "M52 (widening): every holder is called this stack's own" "$m" \
       "🔴 a holder that is NOT in the registry still gets the old sentence"


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


# --- H4 regression: the stray newline inside the packed reading (section 11) -------------------

# M38 puts the regression back on the P4 site, verbatim as 76b5d434 shipped it. It is the mutation
# that asks section 11 to prove it has power, because the eight cells section 8 already had did
# not: they test topo_for_hosts directly, and topo_for_hosts was never wrong.
m=$(mutant m38 "$NDT" \
    '    topo="${both%%$'"'"'\t'"'"'*}"; topo="${topo%%$'"'"'\n'"'"'*}"; rest="${both#*$'"'"'\t'"'"'}"' \
    '    topo="${both%%$'"'"'\t'"'"'*}"; rest="${both#*$'"'"'\t'"'"'}"')
report "M38: the P4 path keeps the newline from the middle of the packed string" "$m" \
       "🔴 the path verify_p4 is handed passes [[ -f ]]"

# M39: the same on the OVS site. Two copies of three lines, so one plane fixed is not both --
# the same reason M9 and M10 exist separately in mutate_ndt_honesty.sh.
m=$(mutant m39 "$NDT" \
    '    ovs_topo="${ovs_both%%$'"'"'\t'"'"'*}"; ovs_topo="${ovs_topo%%$'"'"'\n'"'"'*}"; ovs_rest="${ovs_both#*$'"'"'\t'"'"'}"' \
    '    ovs_topo="${ovs_both%%$'"'"'\t'"'"'*}"; ovs_rest="${ovs_both#*$'"'"'\t'"'"'}"')
report "M39: the OVS path keeps it too" "$m" \
       "🔴 with a real sha, on the OVS plane as well"

# 🔴 The widening direction -- strip the newline by dropping the packing, so TOPO_REFUSAL dies
# in the subshell again -- is M26 above, whose anchor this fix moved and which was REPOINTED here
# rather than left drifting. It reported SURVIVED on the first run of this gate after the fix,
# which is what an anchor that will not apply looks like: check_gate_anchors.py had said ok(45)
# minutes earlier, because it was counting against a HEAD that did not yet carry the fix.



# --- ROLE-9: a refused `ndt up p4 <n>` and the P4 host knob (section 18) -----------------------

# M53 is the defect itself, in the shape ROLE-9 measured: the count is written through before
# anything has been checked. The later write is then a no-op, so this mutation changes WHEN and
# nothing else -- which is the whole finding.
m=$(mutant m53 "$NDT" \
    '    KNOB_SAVED=""
    hosts="$(host_count)"
    KNOB_ENTRY="$hosts"' \
    '    KNOB_SAVED=""
    hosts="$(host_count)"
    KNOB_ENTRY="$hosts"
    [[ -n "${1:-}" ]] && { set_host_count "$1" >/dev/null 2>&1; hosts="$(host_count)"; }')
report "M53: the knob is written before the refusals again (ROLE-9)" "$m" \
       "🔴 and the knob is byte-for-byte what this run found it"

# M54: the refusal goes back to quoting the knob rather than the count it was given. With M53
# not applied the file really is unchanged, so this is the SENTENCE half on its own -- the half
# a reader acts on.
m=$(mutant m54 "$NDT" \
    '        err "  p4_proxy/mininet/host_count_override is UNCHANGED at $KNOB_ENTRY: the knob is"' \
    '        err "  the fabric is built from p4_proxy/mininet/host_count_override ($hosts), and the"')
report "M54: the refusal quotes the knob instead of what the operator arrived with" "$m" \
       "  the refusal names the value the operator arrived with"

# M55: the rollback stops putting it back. This is the path where the knob really was written,
# so it is the only one where a missing restore can be seen at all.
m=$(mutant m55 "$NDT" \
    '    knob_restore "this bring-up was rolled back"' \
    '    :')
report "M55: a rolled-back bring-up keeps the count it wrote" "$m" \
       "🔴 and the rollback put the knob back too"

# M56 (widening): the restore restores the VALUE. Every cell that reads a bare `4\n` stays green
# -- which is why section 18's rollback cell is the one with a comment line in the file.
m=$(mutant m56 "$NDT" \
    '    if ! cp -p "$KNOB_SAVED" "$f" 2>/dev/null; then' \
    '    if ! printf '"'"'%s\n'"'"' "$KNOB_ENTRY" > "$f"; then')
report "M56 (widening): the knob is rewritten from the value, not the bytes" "$m" \
       "  bytes, so the comment survived the round trip"

# M57 (widening): knob_restore never does anything. It keeps its name, its call sites and its
# rc, and it is the shape this project keeps re-finding -- a step that reports success without
# having a way to fail.
m=$(mutant m57 "$NDT" \
    '    [[ -n "$KNOB_SAVED" ]] || return 0
    if [[ "$KNOB_SAVED" == "(absent)" ]]; then' \
    '    return 0
    if [[ "$KNOB_SAVED" == "(absent)" ]]; then')
report "M57 (widening): the restore is a no-op that still returns 0" "$m" \
       "🔴 and the rollback put the knob back too"

# M58: the size on the command line stops deciding, and the knob decides instead. That is the
# wrong fix for ROLE-9 -- it removes the write from the refusal path by removing the request
# from the check -- and it puts H4 itself back: `ndt up p4 128` with the knob at 4 would compare
# a 4-host NDT_TOPO against 4, agree, and build a fabric of a different network.
m=$(mutant m58 "$NDT" \
    '        knob_wanted="$1"
        hosts="$1"' \
    '        knob_wanted="$1"')
report "M58: the refusal is decided from the knob, not from what was asked for" "$m" \
       "🔴 and nothing was built"

# W9 (behaviour-preserving): the put-back reason is reworded. Section 18 asserts the sentence
# that names the file and the value, not this clause, so the suite must stay green.
m=$(mutant w9 "$NDT" \
    'knob_restore "this bring-up was rolled back"' \
    'knob_restore "the bring-up did not stand"')
report_green "W9 (behaviour-preserving): the rollback's put-back reason reworded" "$m" \
       "the reason is prose; the file and the value are what is asserted"

# --- ROLE-9 / ROLE-11 F6: the claim note and the verdict (section 19) --------------------------

# M59 is the defect itself: the note is written from the rc again. It survives every cell whose
# rc and verdict agree, which is why section 19 carries the one where they do not.
m=$(mutant m59 "$NDT" \
    '    claim_note_down "$down_rc" "$CLEAN_UNVERIFIED"' \
    '    claim_note_down "$down_rc" "$( (( down_rc == 0 )) || printf "the teardown" )"')
report "M59: the claim note is written from the rc again (ROLE-11 F6)" "$m" \
       "🔴 a clean machine is not written down as unverified"

# M60: one half stops being recorded. The note then says a teardown that could not finish its
# sweep verified clean -- the direction that licenses the next round to start.
m=$(mutant m60 "$NDT" \
    '        not_verified "the [3/3] sweep"' \
    '        :')
report "M60: a sweep that did not finish is written down as clean" "$m" \
       "🔴 and the note names the sweep"

# M61 (widening): nothing is ever recorded, so every teardown's note says verified clean. The
# function keeps its name and its call sites and has no way to fail.
m=$(mutant m61 "$NDT" \
    'not_verified() { CLEAN_UNVERIFIED="${CLEAN_UNVERIFIED:+$CLEAN_UNVERIFIED, }$1"; }' \
    'not_verified() { :; }')
report "M61 (widening): every teardown verified clean" "$m" \
       "🔴 and its note says it did not verify clean"

# M62: the halves collapse into one name. The note goes on saying "did NOT verify clean", so a
# gate that only read that phrase would stay green while sending the reader to the wrong half.
m=$(mutant m62 "$NDT" \
    'not_verified "the residue check"' \
    'not_verified "the [3/3] sweep"')
report "M62: the residue check is reported as the sweep" "$m" \
       "  naming the half that could not verify"

# M63: the note stops carrying the non-zero it ended on. "Verified clean" over a round that
# exited 1 with no second half is the same conflation the other way round.
m=$(mutant m63 "$NDT" \
    '        (( rc != 0 )) && also="; this teardown still exits $rc, for something other than residue"' \
    '        :')
report "M63: a non-zero ending disappears from the note" "$m" \
       "  while the non-zero it did end on is not hidden"

# W10 (behaviour-preserving): the info line ndt prints about the note is reworded. Section 19
# asserts the FILE, so the suite must stay green.
m=$(mutant w10 "$NDT" \
    'info "claim note now says the lab is down and verified clean (owner and expiry unchanged)"' \
    'info "the claim note now records a verified-clean teardown (owner and expiry unchanged)"')
report_green "W10 (behaviour-preserving): the note's on-screen announcement reworded" "$m" \
       "section 19 reads .test_run/lab.claim, not the screen"

# --- FIX-NDT-8: the one rc vocabulary across up, down and clean (section 20) -------------------
#
# Adam, 2026-09-12. Every mutation below is a way of making the three words mean one word again,
# and each of them leaves the product looking exactly as it does now: the same refusals, the
# same prose, the same guards -- and a caller that cannot tell "I declined to act" from "I
# looked and it was dirty".

# M64: the refusal code preflight answers with is flattened back to 1. Every message is
# unchanged; only the byte a script reads moves.
m=$(mutant m64 "$NDT" \
    '    guard_no_teardown_in_flight || { bad=1; refused=5; }' \
    '    guard_no_teardown_in_flight || bad=1')
report "M64: a refused bring-up exits 1 again (H3)" "$m" \
       "  🔴 P4 preflight refuses while a teardown runs"

# M65 (widening): preflight answers 5 for everything non-zero. The refusal cells all stay green
# and the distinction is gone in the other direction -- a stray on :8000 now reads as "wait for
# a teardown that is not running".
m=$(mutant m65 "$NDT" \
    '    (( refused != 0 )) && return "$refused"
    return 1' \
    '    return 5')
report "M65 (widening): every preflight failure is a refusal" "$m" \
       "🔴 a stray holding :8000 is a dirty reading, still 1"

# M66: up_p4 flattens what preflight answered. This is the shape the code had for months --
# `|| return 1` -- and it is invisible from inside preflight, which is still perfectly correct.
m=$(mutant m66 "$NDT" \
    '    preflight p4 || return $?' \
    '    preflight p4 || return 1')
report "M66: up_p4 flattens preflight's answer" "$m" \
       "🔴 up_p4 carries preflight's refusal code out"

# M67: the real trap, written the way it is easy to write. `rm -f ...; return $?` returns the rc
# of `rm` -- 0 -- so a refused OVS bring-up reports SUCCESS. Every message still prints.
m=$(mutant m67 "$NDT" \
    '    local pf_rc
    preflight ovs; pf_rc=$?
    (( pf_rc != 0 )) && { rm -f "$fifo" "$out"; return "$pf_rc"; }' \
    '    preflight ovs || { rm -f "$fifo" "$out"; return $?; }')
report "M67: up_ovs reads the rc after its own rm -f" "$m" \
       "🔴 up_ovs carries it out too, past its own rm -f"

# M68/M69/M70/M71: one refusal at a time back to 1. Four sites, because "the vocabulary is
# implemented" is a claim about all of them and a single site left behind is the state this
# gate exists to see.
m=$(mutant m68 "$NDT" \
    '        # 🔴 rc 5: refused. (Adam, 2026-09-12)
        return 5' \
    '        return 1')
report "M68: a foreign claim refuses with 1 again" "$m" \
       "🔴 a lab claimed by somebody else refuses with rc 5"
m=$(mutant m69 "$NDT" \
    '        # 🔴 rc 5: a refusal, not a dirty reading -- nothing on the machine was looked at.
        return 5' \
    '        return 1')
report "M69: H4 refuses with 1 again on the P4 side" "$m" \
       "  🔴 'ndt up p4 4' with a 128-host NDT_TOPO is refused"
m=$(mutant m70 "$NDT" \
    '        # 🔴 rc 5: the same refusal up_p4 gives. One plane changed is not both.
        return 5' \
    '        return 1')
report "M70: H4 refuses with 1 again on the OVS side" "$m" \
       "🔴 H4 refuses with 5 on the OVS side too"
m=$(mutant m71 "$NDT" \
    '        # guards, one code -- see the vocabulary note above preflight. (Adam, 2026-09-12)
        return 5' \
    '        return 1')
report "M71: the second H4 guard answers 1 again" "$m" \
       "  🔴 record_up_target refuses hosts=4 against model_hosts=128"

# M72 (widening): a DIRTY READING starts calling itself a refusal. This is the direction the
# controls in section 20 exist for -- it makes every refusal cell greener, not redder.
m=$(mutant m72 "$NDT" \
    '        err "take it down first:  ndt down"
        rm -f "$fifo" "$out"; return 1' \
    '        err "take it down first:  ndt down"
        rm -f "$fifo" "$out"; return 5')
report "M72 (widening): a live Mininet reports itself as a refusal" "$m" \
       "🔴 a live Mininet is a dirty reading, still 1"

# W11 (behaviour-preserving): the local that carries preflight's answer in up_ovs is renamed.
# Section 20 asserts the rc that comes out, not the name it travelled in.
m=$(mutant w11 "$NDT" \
    '    local pf_rc
    preflight ovs; pf_rc=$?
    (( pf_rc != 0 )) && { rm -f "$fifo" "$out"; return "$pf_rc"; }' \
    '    local preflight_rc
    preflight ovs; preflight_rc=$?
    (( preflight_rc != 0 )) && { rm -f "$fifo" "$out"; return "$preflight_rc"; }')
report_green "W11 (behaviour-preserving): the rc-carrying local is renamed" "$m" \
       "the suite asserts the code that comes out, not the variable it came in"

# --- FIX-NDT-8: 'ndt clean' answers 3 when it measured nothing (section 21) --------------------

# M73: the refusal goes back to 1, with every word of it unchanged.
m=$(mutant m73 "$NDT" \
    '        # 🔴 rc 5: refused. It outranks rc 3 -- a command that refused did not measure this
        # machine at all, so it has nothing to report about what is on it. (Adam, 2026-09-12)
        return 5' \
    '        return 1')
report "M73: 'ndt clean' refuses with 1 again (ROLE-12 cell 3)" "$m" \
       "🔴 'ndt clean' is refused while a teardown is running"

# M74: the defect itself, put back -- an assertion with no subject prints `clean` and exits 0.
# Nothing else about the command changes, which is the whole reason it went unnoticed: every
# line of its output is correct, and the one byte a script reads is a different statement.
m=$(mutant m74 "$NDT" \
    '    if [[ -z "$subject_known" && -z "$(pid_registry_entries)" ]]; then
        say "${Y}nothing to judge${N}"' \
    '    if false; then
        say "${Y}nothing to judge${N}"')
report "M74: an empty machine is called clean again" "$m" \
       "🔴 an empty machine is rc 3, not rc 0"

# M75 (widening): the caller's subject is ignored, so the LAST STEP OF EVERY TEARDOWN reports
# "nothing to judge". That is this fix with the sign flipped -- "I removed it and proved it
# gone" downgraded to "there was never anything here" -- and every cell about the empty machine
# stays green through it.
m=$(mutant m75 "$NDT" \
    '    local subject_known="${1:-}"' \
    '    local subject_known=""')
report "M75 (widening): every teardown ends on 'nothing to judge'" "$m" \
       "🔴 the teardown's own verify clean still ends on 'clean'"

# M76 (widening): the registry half of the subject is dropped. A checkout with a live kernel
# registered in .test_run/pids/ and nothing on the ports then reads as "nothing was ever here",
# which is the file `ndt down` acts on being invisible to the command that judges the machine.
m=$(mutant m76 "$NDT" \
    'pid_registry_entries() {
    local f
    for f in "$REPO"/.test_run/pids/*.pid; do' \
    'pid_registry_entries() {
    local f
    return 0
    for f in "$REPO"/.test_run/pids/*.pid; do')
report "M76 (widening): the registry stops counting as a subject" "$m" \
       "🔴 a pidfile in the registry is a subject: rc 0"

# W12 (behaviour-preserving): the last sentence of the rc-3 block is reworded. Section 21 reads
# the verdict LINE with grep -x and one needle from the block above it.
m=$(mutant w12 "$NDT" \
    "        info \"  it at all. A teardown that removed a fabric and proved it gone still says clean.\"" \
    "        info \"  it at all. A teardown that took a fabric out and proved it gone says clean.\"")
report_green "W12 (behaviour-preserving): the rc-3 explanation reworded" "$m" \
       "the cells read the verdict line and the population sentence, not this one"

# --- FIX-NDT-8: 'ndt down' answers 3 when it tore nothing down (section 22) --------------------

# M77: the teardown's refusals go back to 1, one site at a time. Every word of the refusal is
# unchanged; what a caller reads is not.
m=$(mutant m77 "$NDT" \
    '        # 🔴 rc 5: refused. Nothing on this machine was read, let alone changed -- the same
        # answer `ndt up` and `ndt clean` give for a guard. (Adam, 2026-09-12)
        return 5' \
    '        return 1')
report "M77: a foreign claim refuses the teardown with 1 again" "$m" \
       "🔴 a foreign claim refuses the teardown with 5"
m=$(mutant m78 "$NDT" \
    '    mark_teardown_start || return 5' \
    '    mark_teardown_start || return 1')
report "M78: a second teardown is refused with 1 again (ROLE-12)" "$m" \
       "🔴 a second 'ndt down' is refused while one is still running"

# M79: the defect itself, put back. An already-down lab reports the same byte as a round that
# removed a fabric and proved it gone -- which is the state ROLE-12's table was in.
m=$(mutant m79 "$NDT" \
    '    if (( down_rc == 0 )) && [[ -z "$DOWN_SUBJECT" ]]; then
        say "${Y}nothing was up to tear down${N}"' \
    '    if false; then
        say "${Y}nothing was up to tear down${N}"')
report "M79: an already-down lab is green again" "$m" \
       "🔴 tearing down an already-down lab is rc 3, not rc 0"

# M80 (widening): the subject reading is lost -- taken too late to mean anything, or never
# taken. Every reading in this function after [3/3] answers "nothing", which is the whole
# reason the question is asked at the top, and with it gone EVERY teardown reports 3.
m=$(mutant m80 "$NDT" \
    '    DOWN_SUBJECT="$(lab_subject)"' \
    '    DOWN_SUBJECT=""')
report "M80 (widening): every teardown reports 'nothing was up'" "$m" \
       "🔴 a teardown with something to remove is still rc 0"

# M81: the note goes back to saying "verified clean" after a teardown that had nothing to
# verify. That sentence is a FILE, and ROLE-9's baseline arrived carrying the previous
# session's copy of it.
m=$(mutant m81 "$NDT" \
    '    if [[ -z "$unverified" && -z "$subject" ]]; then' \
    '    if false; then')
report "M81: an empty teardown writes 'verified clean' into the claim" "$m" \
       "🔴 the note does not claim a clean machine was verified"

# W13 (behaviour-preserving): one explanatory line of the rc-3 block is reworded. Section 22
# reads the verdict line and the population sentence.
m=$(mutant w13 "$NDT" \
    "        info \"  'the lab was already down' and 'this round ended clean' are two statements, and\"" \
    "        info \"  being already down and having ended a clean round are two statements, and\"")
report_green "W13 (behaviour-preserving): the rc-3 explanation reworded" "$m" \
       "section 22 reads the verdict line, not this one"

# --- FIX-NDT-8: [3/3] says it ran the Mininet sweep (section 23) -------------------------------

# M82: the sentence goes. The teardown still does the sweep, and the manual still carries the
# hand-typed command -- which is the state Adam's Q3 is about.
m=$(mutant m82 "$NDT" \
    '    ok "this step ran the Mininet sweep (mn -c) for you"' \
    '    :')
report "M82: [3/3] does the Mininet sweep and does not say so" "$m" \
       "🔴 [3/3] says it ran the Mininet sweep"

# M83 (widening): the new sentence is taken as a licence to stop filtering stack.sh's advice, so
# the teardown says it did the sweep AND tells the operator to do it by hand. One output, two
# instructions, and the second one is the wrong one inside a teardown.
m=$(mutant m83 "$NDT" \
    "(reverse order\\)\$|Mininet was started manually" \
    "(reverse order\\)\$")
report "M83 (widening): the hand-typed advice comes back beside the sentence" "$m" \
       "🔴 stack.sh's hand-typed advice is still filtered out"

# W14 (behaviour-preserving): one explanatory line under the sentence is reworded.
m=$(mutant w14 "$NDT" \
    "    info \"  [1/3] filters it out.\"" \
    "    info \"  [1/3] drops it.\"")
report_green "W14 (behaviour-preserving): the [3/3] explanation reworded" "$m" \
       "section 23 reads the sentence and the verb, not this line"

# --- FIX-NDT-8: the way IN is printed on both planes (section 24) ------------------------------

# M84: the OVS bring-up stops printing it, which is the state Adam asked about at 11:23 --
# 128 hosts on the default plane and no line saying how to reach them.
m=$(mutant m84 "$NDT" \
    '        lab_entry_points ovs' \
    '        :')
report "M84: the OVS bring-up does not say how to get in" "$m" \
       "  up_ovs calls it"

# M85: the P4 plane's own line is lost in the consolidation. Moving two sentences into one
# function is exactly when one of them quietly stops being printed.
m=$(mutant m85 "$NDT" \
    '        lab_entry_points p4' \
    '        :')
report "M85: the P4 bring-up loses the line it already had" "$m" \
       "  and up_p4 calls it"

# M86: the attach command drifts from the helper's. A session name typed twice is a command an
# operator pastes and watches fail on the day one of the two moves.
m=$(mutant m86 "$NDT" \
    "lab_attach_cmd() { printf 'sudo tmux -L ndtwinlab attach -t topo\\n'; }" \
    "lab_attach_cmd() { printf 'sudo tmux -L ndtwinlab attach -t ndtwin\\n'; }")
report "M86: the attach command no longer matches ndtwin-lab's own" "$m" \
       "🔴 that command is what ndtwin-lab itself prints, at all three launch verbs"

# M87 (widening): OVS is told it has a proxy. :8081 is the P4 proxy; on this plane nothing is
# listening there, and a ready line that names it sends the reader to a closed port.
m=$(mutant m87 "$NDT" \
    '        ovs) info "Ryu :8080   kernel :8000   Mininet CLI: $(lab_attach_cmd)" ;;' \
    '        ovs) info "proxy :8081   kernel :8000   Mininet CLI: $(lab_attach_cmd)" ;;')
report "M87 (widening): the OVS line names a proxy that is not there" "$m" \
       "  and Ryu's, which is the OVS plane's control plane"

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
