#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_up_down_robust.sh.
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
# case goes red for a reason that has nothing to do with the mutation.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation behaved as declared, 1 one did not, 2 refused (baseline red /
#       harness / A MUTANT THAT IS NOT VALID BASH), 3 the file under test
#       changed while the gate ran.
#
# 🔴 2 AND 1 ARE DIFFERENT ANSWERS. 1 is "the suite let a real mutation through"; 2 is "this
# gate could not measure, so it is not answering". An earlier version collapsed the second into the first
# by incrementing SURVIVORS for a dead mutant while its comments and its report both
# said it refused -- and the verdict line then reported a measurement that never happened.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
# Named so check_gate_anchors.py can tell which file M95's anchor lives in. [Co-developed with claude code -- Adam]
PORTS="$REPO/tools/test_workflow/ports.sh"
# [Co-developed with claude code -- Adam] The module the refusal asks (ntg_config.py): every mutant dir carries a copy and the
# suite is pointed at it with NTG_MODULE_UNDER_TEST, so M145 can mutate it. Named so check_gate_anchors.py can read the gate.
NTGCFG="$REPO/p4_proxy/mininet/ntg_config.py"
TEST="$HERE/test_ndt_up_down_robust.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-updown-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
# [Co-developed with claude code -- Adam] ntg_config.py is a subject of the gate too (M145 and later): the end-of-run byte check covers it.
BASE_CFG=$(sha256sum "$NTGCFG" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0
#: Mutants that are not valid bash. 🔴 SEPARATE FROM SURVIVORS, AND IT DECIDES THE EXIT CODE.
#: An earlier version added the `bash -n` guard, wrote "refused, not a
#: survivor" in the comments AND in the report -- and then incremented SURVIVORS, so a dead
#: mutant still came out as `N mutations, N survived`, rc 1. That is the SAME defect one level
#: up: the gate saying one thing about itself and doing another. A dead mutant means the gate
#: could not measure this mutation at all, which is neither "caught" nor "survived": there is
#: no verdict line, and the exit code is 2 (refused), the code this gate already uses for a red
#: baseline.
DEAD=0

run_against() { NDT_UNDER_TEST="$1/ndt" NTG_MODULE_UNDER_TEST="$1/ntg_config.py" timeout 600 bash "$TEST" 2>&1; }

# [Co-developed with claude code -- Adam]
# 🔴 A MUTANT THAT DOES NOT PARSE IS NOT A MUTANT (the accounting that
# makes that true rather than merely stated is the DEAD count below). `bash -n` is the whole
# guard: a syntactically dead `ndt` reddens every cell for one reason -- it cannot run -- which
# looks exactly like "the suite is sensitive" while proving nothing, and leaves the NAMED cell
# absent from the output, which `report` cannot tell from green. That is how M9 was reported as
# a survivor for a defect that was in the GATE. Refuse instead: a gate that cannot say what it
# measured must not print a verdict.
syntax_ok() {   # $1 = mutant dir; prints the error when it is not
    # [Co-developed with claude code -- Adam] Every file in the mutant dir, not ndt alone: M95
    # mutates ports.sh, and an unparseable ports.sh would redden every cell and read as "caught".
    local f
    for f in "$1"/ndt "$1"/*.sh "$1"/*.env; do
        [[ -f "$f" ]] && bash -n "$f" 2>&1
    done
    # [Co-developed with claude code -- Adam] A mutated ntg_config.py that does not compile would make every
    # refusal cell fail for one reason and read as "caught": it is dead, like an unparseable ndt.
    [[ -f "$1/ntg_config.py" ]] && python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$1/ntg_config.py" 2>&1
    return 0
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc err
    MUTATIONS=$((MUTATIONS+1))
    if ! err="$(syntax_ok "$2")" || [[ -n "$err" ]]; then
        DEAD=$((DEAD+1))
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
        DEAD=$((DEAD+1))
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
# checking.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    cp "$NTGCFG" "$d/ntg_config.py"
    # 🔴 AN ANCHOR THAT WILL NOT APPLY IS A SURVIVOR, AND IT MUST SAY WHICH KIND. Until
    # 2026-09-12 this python ran bare: a stale anchor printed a traceback into the gate's own
    # log, the copy stayed UNMUTATED, the suite was green, and the gate said `SURVIVED -- that
    # case proves nothing`. "The assertion is not load-bearing" and "the gate can no longer find
    # that line" are very different diagnoses, and this gate once produced four of the second kind
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
cp "$NTGCFG" "$base/ntg_config.py"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- rollback, first half: the refusal moves back to before the machine is touched ----------------

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
# whole distinction exists to keep working.
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

# --- rollback, second half: the rollback ----------------------------------------------------------

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
    # [Co-developed with claude code -- Adam]
    # What the helper says on stderr is read as well as shown:' \
    '    # [Co-developed with claude code -- Adam]
    # What the helper says on stderr is read as well as shown:')
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
# 🔴 THE ANCHOR IS THE COMPLETE CALL, AND IT WAS NOT.
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

# --- sweep-rc: the sweep's exit status ------------------------------------------------------------

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

# --- verify-race: the teardown verify and the sweep it verifies --------------------------------------

# The assertion goes back to being taken at the instant of the sweep: "5 still running / not
# clean" over a machine that reads 0 a moment later.
# 🔴 Re-anchored 2026-09-12: `verify clean` is now handed the subject cmd_down
# measured before it acted, so the line this spans gained an argument. The mutation is the same
# one -- take the wait away -- said against the new call.
m=$(mutant m12 "$NDT" \
    '    wait_reaped "${NDT_REAP_WAIT:-20}" || true
    cmd_clean "$DOWN_SUBJECT"; local clean_rc=$?' \
    '    cmd_clean "$DOWN_SUBJECT"; local clean_rc=$?')
report "M12: 'ndt down' asserts at the instant of the sweep" "$m" \
       "🔴 processes reaped just after the sweep are not a failure"

# 🔴 The verify-race with the sign flipped, which is worse: the wait is allowed to decide. When it expires
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

# --- helper-copy: the installed helper ---------------------------------------------------------------

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
# the operator's decision, and a bring-up that will not run until somebody types a sudo command is a
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
# fabric would be built at a size it would not be built at. The same shape inside the
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

# --- H4: the model and the fabric are different networks (FIXED-ISSUES G-23, 2026-09-11) ------

# M24 restores H4 verbatim: the NDT_TOPO escape hatch checks only that the file EXISTS. That is
# the code a 2026-09-11 run of `NDT_TOPO=<128-host model> ndt up p4 4` met -- fabric built, kernel
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
# by side without comparing them.
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
        stage="${UP_STARTED[$i]}"; UP_RB_AT=$i
        case "$stage" in' \
    '    for (( i = ${#UP_STARTED[@]} - 1; i >= 0; i-- )); do
        stage="${UP_STARTED[$i]}"; UP_RB_AT=$i
        case "nothing" in')
report "N2 (widening, green): the rollback prints and does nothing" "$m" \
       "  stops the topo session"

# N3: `ndt down` always exits 0. The report above it is unchanged, so only an exit code tells
# the two apart -- and the exit code is what every caller reads.
# Anchor moved 2026-09-06: claim_note_down now sits between the two lines this used to
# span. The mutation is unchanged -- it still replaces cmd_down's only return with a constant 0.
# 🔴 Re-anchored 2026-09-11: H3 inserted `mark_teardown_end` between these two lines, and this
# anchor -- which spanned both -- silently stopped matching. The mutant then carried an
# UNMUTATED ndt, the suite was green, and the gate reported N3 as a survivor. That is
# tests/shell/README.md §1's case, and the reason the gate's verdict is the one we ship.
# 🔴 Re-anchored 2026-09-12: the teardown's single exit now returns down_verdict,
# which is down_rc except in the one case where nothing was there to tear down (rc 3).
# Re-anchored again: the exit now takes the signal traps off between the marker's removal and the return, so the
# anchor is the return line alone.
m=$(mutant n3 "$NDT" \
    '    return "$down_verdict"' \
    '    return 0')
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

# --- H3: a bring-up that overlaps a teardown (FIXED-ISSUES G-24, 2026-09-11) ------------------

# M30 restores H3: nothing records that a teardown is running, so the only reading a P4
# bring-up can take is the ports -- which look identical coming up and going down.
# Re-anchored: the traps' block now sits between the marker's call and `say "ndt down"`; the mutation still removes the call.
m=$(mutant m30 "$NDT" \
    '    mark_teardown_start || return 5
    # [Co-developed with claude code -- Adam] An INT, TERM or HUP says where the teardown was and ends it' \
    '    # [Co-developed with claude code -- Adam] An INT, TERM or HUP says where the teardown was and ends it')
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
    trap - EXIT INT TERM HUP' \
    '    trap - EXIT INT TERM HUP')
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
    pid="$(sed -n '"'"'s/^pid=//p'"'"' "$f" | head -1)"
    at="$(sed -n '"'"'s/^at=//p'"'"' "$f" | head -1)"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then' \
    '    [[ -f "$f" ]] || return 1
    return 1
    pid="$(sed -n '"'"'s/^pid=//p'"'"' "$f" | head -1)"
    at="$(sed -n '"'"'s/^at=//p'"'"' "$f" | head -1)"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then')
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


# --- FIXED-ISSUES G-42 (2026-09-12): the marker has an owner -----------------------------------

# M40 restores G-42's first half: mark_teardown_start writes `pid=$$` over whatever is there.
# A second `ndt down` then takes the record of the first one, and for as long as the first is
# alive every refusal a bring-up gets names the wrong process.
m=$(mutant m40 "$NDT" \
    '        if [[ "${tif%% *}" != "$$" ]]; then' \
    '        if false; then')
report "M40: the teardown marker is overwritten again" "$m" \
       "🔴 a second 'ndt down' is refused while one is still running"

# M41 restores the other half, and it is the half that actually removed the guard: an
# unconditional `rm -f`, so the teardown that finishes first deletes the marker of the one still
# running (02:07:32.687, with the next `ndt up p4 4` unrefused four milliseconds later).
m=$(mutant m41 "$NDT" \
    '    if [[ "$pid" == "$$" ]]; then rm -f "$f"; return 0; fi' \
    '    rm -f "$f"; return 0')
report "M41: mark_teardown_end removes anybody's marker" "$m" \
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


# --- FIXED-ISSUES G-43 (2026-09-12): the teardown rc is its ending, not a reading from the middle

# M43 restores the 7-of-7: nothing is deferred, so a live P4 teardown is red because [1/3] ran
# before the sweep that closes the very ports it is complaining about.
m=$(mutant m43 "$NDT" \
    '        ports_deferred="$(stack_down_deferrable_ports "$out")"' \
    '        ports_deferred=""')
report "M43: a mid-teardown port reading is the verdict again" "$m" \
       "🔴 ports [1/3] found open and [3/3] closed are not a failed teardown"

# M44 (widening): the ports are deferred and never re-read, so the half is simply forgiven --
# which passes every "a live P4 down is green" cell and no longer notices a real leftover. This
# is the mutation the stubbed-green cmd_clean cell exists for: with clean_rc inherited instead,
# this mutant would look identical to the fix.
m=$(mutant m44 "$NDT" \
    '            ndt_port_open "$dp" "$dproto"
            case $? in
                0) dstill="${dstill:+$dstill }$dp" ;;
                2) dunk="${dunk:+$dunk }$dp" ;;
            esac' \
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
# [Co-developed with claude code -- Adam] Repointed 2026-11-13: the note is three info lines now.
m=$(mutant w8 "$NDT" \
    '            info "  [3/3] has not swept the data plane yet, so they are read again after '"'"'verify clean'"'"';"' \
    '            info "  the data plane is swept at [3/3], so they are read again after '"'"'verify clean'"'"';"')
report_green "W8 (behaviour-preserving): the deferral note reworded" "$m" \
       "the note above the re-read is not the behaviour under test"

# [Co-developed with claude code -- Adam]
# --- 2026-11-12/13: a deferred port is not reported as somebody else's at [1/3] ----------------
# Three live P4 teardowns by a non-root user holding only the user guide's sudo grants printed
# stack.sh's report on every bmv2 port at [1/3] ("held by a process this user cannot see", "This
# script did not start it") and then exited 0.

# M153 restores it: the deferred status still prints stack.sh's port report in full.
m=$(mutant m153 "$NDT" \
    '        stack_down_lines "$(stack_down_without_port_report "$out")"' \
    '        stack_down_lines "$out"')
report "M153: a deferred port is called somebody else's at [1/3] again" "$m" \
       "🔴 a deferred port is not called somebody else's at [1/3]"

# M154 (widening): the report is left out whatever the status, so a port held by something this
# stack started -- stop_one failing, which no sweep addresses -- loses its holder line too.
m=$(mutant m154 "$NDT" \
    '    else
        stack_down_lines "$out"
    fi' \
    '    else
        stack_down_lines "$(stack_down_without_port_report "$out")"
    fi')
report "M154 (widening): stack.sh's port report is dropped when nothing is deferred" "$m" \
       "  🔴 so stack.sh's port lines are printed in full at [1/3]"

# M155 (widening): the filter drops every line -- "silence everything" -- so what stack.sh said
# about the kernel, the proxy and its registry goes with the ports.
m=$(mutant m155 "$NDT" \
    '        printf '"'"'%s\n'"'"' "$line"
    done <<<"$1"' \
    '        :
    done <<<"$1"')
report "M155 (widening): the [1/3] filter drops every line stack.sh printed" "$m" \
       "  🔴 and what stack.sh said about anything else is kept (first line)"

# M156: the foreign-holder line itself is no longer left out; only its tail is.
m=$(mutant m156 "$NDT" \
    '        [[ "$line" =~ ^\ \ :[0-9]+\ "$STACK_DOWN_FOREIGN_PORT"\  ]] && continue' \
    '        :')
report "M156: the deferred port's holder line is printed at [1/3] again" "$m" \
       "🔴 a deferred port is not called somebody else's at [1/3]"

# M157: a port still held after the sweep is named without its holder -- the re-read line, the
# one that names it for the failing teardown (a refused 'verify clean' names none), is gone.
m=$(mutant m157 "$NDT" \
    '                err "    :$dp is still listening, held by $(ndt_port_holder "$dp" "$(ndt_port_proto "$dp")")"' \
    '                :')
report "M157: a port still held after the sweep is named without its holder" "$m" \
       "  🔴 and naming the holder of each, after 'verify clean'"

# M158, M159: one entry of the filter's drop list deleted, so one line of stack.sh's report on a
# deferred port is printed again at [1/3]: the second half of the "did not start it" tail, and
# the advice's `ss -ltnp` line.
m=$(mutant m158 "$NDT" \
    '        ["    measure the wrong process, so this is reported rather than ignored."]=1' \
    '')
report "M158: the second line of the foreign-holder tail is printed at [1/3] again" "$m" \
       "  nor the second half of that tail"
m=$(mutant m159 "$NDT" \
    '        ["    ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh"]=1' \
    '')
report "M159: the advice's ss line is printed at [1/3] again" "$m" \
       "  nor the advice's ss line"

# M160 (widening): the holder-line pattern also takes any other line that starts "  :<port> ", so
# the unchecked-UDP warning (":6343 (udp) could NOT be checked") goes with the report.
m=$(mutant m160 "$NDT" \
    '        [[ "$line" =~ ^\ \ :[0-9]+\ "$STACK_DOWN_FOREIGN_PORT"\  ]] && continue' \
    '        [[ "$line" =~ ^\ \ :[0-9]+\  ]] && continue')
report "M160 (widening): the filter also drops the unchecked-UDP warning" "$m" \
       "  🔴 and an unchecked-UDP warning is kept, whole"

# M161: the empty-line guard is gone, so an empty line in stack.sh's output reaches the array lookup.
m=$(mutant m161 "$NDT" \
    '        [[ -n "$line" && -n "${drop[$line]:-}" ]] && continue' \
    '        [[ -n "${drop[$line]:-}" ]] && continue')
report "M161: an empty line in stack.sh's output reaches the drop-list lookup" "$m" \
       "  and an empty line in stack.sh's output raises no bash error"

# [Co-developed with claude code -- Adam]
# --- a failed 'ndt up' (P4 or OVS) rolls back reading stack.sh's port report the way 'ndt down' does ---
# `ndt up p4` records `fabric` before `stack`, so the rollback's `stack.sh down` ran while bmv2 was
# up and every failed fresh bring-up ended "rollback INCOMPLETE ... ndt down --deep"; over a reused
# fabric, which the rollback never stops, it always did, with --deep advice over that fabric.

# M162 puts the defect back: the rollback does not defer, so the fabric's ports fail it again.
m=$(mutant m162 "$NDT" \
    'then deferred="$(stack_down_deferrable_ports "$out")"; fi' \
    'then :; fi')
report "M162: a P4 rollback fails on the ports of the fabric it is about to stop" "$m" \
       "🔴 ports the fabric still held at the stack stage do not make the rollback incomplete"

# M163: a port still held after every stage has run is read as closed -- the honest half gone.
m=$(mutant m163 "$NDT" \
    '                       held="${held:+$held }$p"' \
    '                       :')
report "M163: a port still held after the rollback is not reported" "$m" \
       "🔴 a port still held after the fabric was stopped makes the rollback INCOMPLETE"

# M164: a port the second reading cannot read is read as closed.
m=$(mutant m164 "$NDT" \
    '                2) unread="${unread:+$unread }$p" ;;' \
    '                2) : ;;')
report "M164: a deferred port the rollback cannot re-read passes" "$m" \
       "🔴 a deferred port that cannot be re-read makes the rollback INCOMPLETE"

# M165 (widening): the fatal ending is hidden from the classifier, so a status that is not only
# about ports is deferred with them and the ending is lost from the rollback's verdict.
m=$(mutant m165 "$NDT" \
    'then deferred="$(stack_down_deferrable_ports "$out")"; fi' \
    'then deferred="$(stack_down_deferrable_ports "$(grep -vF -- "$STACK_DOWN_FATAL_ENDING" <<<"$out")")"; fi')
report "M165 (widening): the rollback defers a status that also carries a fatal ending" "$m" \
       "🔴 a fatal ending beside the ports is still an INCOMPLETE rollback"

# M166: up_p4 exits 0 after a rollback at the stack stage.
m=$(mutant m166 "$NDT" \
    '        rollback_up "stack.sh could not bring the proxy/kernel up over this fabric"
        return 1' \
    '        rollback_up "stack.sh could not bring the proxy/kernel up over this fabric"
        return 0')
report "M166: a failed 'ndt up p4' that rolled back exits 0" "$m" \
       "a failed fresh 'ndt up p4' is still red"

# M167: up_p4 does not record the fabric it starts, so the rollback leaves that fabric up. (Re-anchored: the line sits above the replace block now.)
m=$(mutant m167 "$NDT" \
    '        # must run the fabric stage, and not say that nothing had changed yet over a fabric half taken down.
        up_started fabric' \
    '        # must run the fabric stage, and not say that nothing had changed yet over a fabric half taken down.')
report "M167: a fresh P4 rollback does not stop the fabric it started" "$m" \
       "  it rolled back the fabric and the stack"

# M168 (widening): everything stack.sh said is dropped with the deferred report.
m=$(mutant m168 "$NDT" \
    '                    out="$(stack_down_without_port_report "$out")"' \
    '                    out=""')
report "M168 (widening): the rollback drops all of stack.sh's output with the port report" "$m" \
       "  what stack.sh said about anything else is kept"

# M169: M8's edit -- the fabric recorded before the reuse branch -- seen from the rollback's own line.
m=$(mutant m169 "$NDT" \
    '    # -- 1. fabric --
    say "[1/3] bmv2 fabric"' \
    '    # -- 1. fabric --
    say "[1/3] bmv2 fabric"
    up_started fabric')
report "M169: a reuse rollback says it started the fabric it reused" "$m" \
       "a reuse rollback rolls back only the stack"

# M170: the reused fabric's ports are counted as left behind.
m=$(mutant m170 "$NDT" \
    '                       kept="${kept:+$kept }$p"' \
    '                       held="${held:+$held }$p"')
report "M170: the reused fabric's own ports make the rollback incomplete" "$m" \
       "🔴 the reused fabric's ports do not make the rollback incomplete"

# M171 (widening): every held P4 port is the reused fabric's, the proxy's :8081 included.
m=$(mutant m171 "$NDT" \
    '        [[ "$plane" == p4 && "$owner" == "bmv2 "* ]] || continue' \
    '        [[ "$plane" == p4 ]] || continue')
report "M171 (widening): a stranger on a P4 port passes as the reused fabric's" "$m" \
       "🔴 a port the manifest lists but the table does not give to bmv2 is still held"

# M172 (widening): the exception no longer needs the switch manifest at all -- neither its presence nor
# its port list.
m=$(mutant m172 "$NDT" \
    '[[ "${UP_P4_FABRIC:-}" == reused && -e "$MANIFEST" ]] && grep -qx -- "$p" <<<"$mports" && ndt_port_is_bmv2 "$p"' \
    '[[ "${UP_P4_FABRIC:-}" == reused ]] && ndt_port_is_bmv2 "$p"')
report "M172 (widening): bmv2 ports are excused with no manifest saying a fabric is up" "$m" \
       "🔴 without the fabric's manifest its ports are not excused"

# W16 (behaviour-preserving): the manifest-present test alone is dropped. Its port list is read from the same
# file, so a missing manifest names no port and the port match already refuses; the test is a second guard.
m=$(mutant w16 "$NDT" \
    '[[ "${UP_P4_FABRIC:-}" == reused && -e "$MANIFEST" ]] && grep -qx' \
    '[[ "${UP_P4_FABRIC:-}" == reused ]] && grep -qx')
report_green "W16 (behaviour-preserving): the exception's manifest-present test dropped, the port match kept" "$m" \
       "a missing manifest names no port, so the port match refuses it already"

# M173 (widening): a rollback over a reused fabric is always complete.
m=$(mutant m173 "$NDT" \
    '    if (( rc == 0 && left == 0 )) && (( ${#UP_LEFT[@]} + ${#UP_REPLACED[@]} )); then' \
    '    if (( ${#UP_LEFT[@]} + ${#UP_REPLACED[@]} )); then')
report "M173 (widening): a reuse rollback is complete whatever was left" "$m" \
       "🔴 a reuse rollback whose stack did not stop cleanly is INCOMPLETE"

# M174: the reuse advice is gone, so it sends the user to --deep over that fabric again.
m=$(mutant m174 "$NDT" \
    '    elif [[ "${UP_P4_FABRIC:-}" == reused ]]; then' \
    '    elif false; then')
report "M174: a reuse rollback sends the user to --deep over the fabric it reused" "$m" \
       "  🔴 and the advice does not send the user to --deep"

# M175: a port left behind is named without its holder.
m=$(mutant m175 "$NDT" \
    '                err "    :$p is held by $(ndt_port_holder "$p" "$(ndt_port_proto "$p")")"' \
    '                :')
report "M175: a port the rollback left behind is named without its holder" "$m" \
       "  🔴 with its holder"

# [Co-developed with claude code -- Adam]
# M176-M178 (widening): the line that says the deferred ports are closed is printed beside a port that is
# held, unread or the reused fabric's -- one term of its guard dropped at a time.
m=$(mutant m176 "$NDT" \
    '        if [[ -z "$held$unread$kept" ]]; then' \
    '        if [[ -z "$held$unread" ]]; then')
report "M176 (widening): the ports are called closed beside the reused fabric's" "$m" \
       "  🔴 and they are not called closed"

m=$(mutant m177 "$NDT" \
    '        if [[ -z "$held$unread$kept" ]]; then' \
    '        if [[ -z "$held$kept" ]]; then')
report "M177 (widening): the ports are called closed beside one it could not read" "$m" \
       "  🔴 and does not say the ports are closed beside it"

m=$(mutant m178 "$NDT" \
    '        if [[ -z "$held$unread$kept" ]]; then' \
    '        if [[ -z "$unread$kept" ]]; then')
report "M178 (widening): the ports are called closed beside one still held" "$m" \
       "  🔴 and does not say the ports are closed beside the one that is held"

# M179: the closed ports are not named beside ones that are not.
m=$(mutant m179 "$NDT" \
    '        elif [[ -n "$closed" ]]; then' \
    '        elif false; then')
report "M179: the ports that closed are not named beside ones that did not" "$m" \
       "  the port that did close is named"

# M180 (widening): a bmv2-row port counts as the reused fabric's whether or not its manifest lists it.
m=$(mutant m180 "$NDT" \
    ' && grep -qx -- "$p" <<<"$mports" && ndt_port_is_bmv2 "$p"; then' \
    ' && ndt_port_is_bmv2 "$p"; then')
report "M180 (widening): a holder on a port the fabric's manifest does not list passes" "$m" \
       "🔴 a holder on a bmv2-row port the fabric's manifest does not list is reported as held, INCOMPLETE"

# M181 (widening): the exception no longer needs the fabric to be one this run REUSED.
m=$(mutant m181 "$NDT" \
    '0) if [[ "${UP_P4_FABRIC:-}" == reused && -e "$MANIFEST" ]]' \
    '0) if [[ -e "$MANIFEST" ]]')
report "M181 (widening): a manifest a fresh rollback left behind excuses the ports" "$m" \
       "🔴 a fresh rollback's ports are not excused by a manifest it left behind"

# M182: the success line over a reused fabric says the machine is back as it was.
m=$(mutant m182 "$NDT" \
    '    if (( rc == 0 && left == 0 )) && (( ${#UP_LEFT[@]} + ${#UP_REPLACED[@]} )); then' \
    '    if false; then')
report "M182: a reuse rollback says the machine is back to what it was" "$m" \
       "🔴 the line names what was taken down, newest first, and what was left running because it was up before"

# M183: the unread ports lose their colons.
m=$(mutant m183 "$NDT" \
    '            for p in $unread; do unread_c="${unread_c:+$unread_c }:$p"; done' \
    '            for p in $unread; do unread_c="${unread_c:+$unread_c }$p"; done')
report "M183: the ports it could not read are named without their colons" "$m" \
       "  🔴 every unread port carries its colon, and they are plural"

# M184: a port stack.sh named that the table has no row for is read as closed.
m=$(mutant m184 "$NDT" \
    '            if ! pproto="$(ndt_port_proto "$p")"; then unread="${unread:+$unread }$p"; continue; fi' \
    '            if ! pproto="$(ndt_port_proto "$p")"; then closed="${closed:+$closed }$p"; continue; fi')
report "M184: a deferred port with no row in the port table passes" "$m" \
       "🔴 a deferred port with no row in the port table makes the rollback INCOMPLETE"

# [Co-developed with claude code -- Adam]
# M185 (widening): the whole guard of the "closed now" line is gone, so it is printed whatever is held,
# unread or kept -- seen here from the cell where a stranger holds the proxy's :8081.
m=$(mutant m185 "$NDT" \
    '        if [[ -z "$held$unread$kept" ]]; then' \
    '        if true; then')
report "M185 (widening): the ports are called closed whatever is held" "$m" \
       "  🔴 and does not say the ports are closed beside the ones held"

# M186: the rollback does not stop the heartbeat it recorded.
# [Co-developed with claude code -- Adam] Re-anchored 2026-11-16: the listing is tested on the flag the
# stop step sets from the helper's answer (HB_STEP_STOPPED), no longer on a pidfile read before the stop.
m=$(mutant m186 "$NDT" \
    '                if heartbeat_stop_step "this bring-up is being rolled back"; then
                    (( HB_STEP_STOPPED )) && stopped="${stopped:+$stopped, }heartbeat"
                else
                    rc=1
                fi' \
    '                :')
report "M186: a reuse rollback leaves the heartbeat it recorded running" "$m" \
       "  and stops it"

# M187: the heartbeat is listed as stopped whether or not the helper said it stopped a daemon.
m=$(mutant m187 "$NDT" \
    '                    (( HB_STEP_STOPPED )) && stopped="${stopped:+$stopped, }heartbeat"' \
    '                    stopped="${stopped:+$stopped, }heartbeat"')
report "M187: a heartbeat that never ran is listed as stopped" "$m" \
       "🔴 the line does not name a heartbeat that never ran (helper rc 3)"

# M192: the stop step says it stopped a daemon whenever a pidfile was there and the helper answered rc 0
# (the test the listing used before it read the helper's answer): a stale or unreadable pidfile is listed.
m=$(mutant m192 "$NDT" \
    '    [[ "$out" == *"heartbeat stopped (pid "* ]] && HB_STEP_STOPPED=1; return 0' \
    '    HB_STEP_STOPPED=1; return 0')
report "M192 (widening): a pidfile the helper signalled nothing for is listed as stopped" "$m" \
       "🔴 the line does not name a heartbeat the helper signalled nothing for (stale)"

# M193: a failed heartbeat stop during a rollback is not counted: the rollback calls itself complete.
m=$(mutant m193 "$NDT" \
    '                    (( HB_STEP_STOPPED )) && stopped="${stopped:+$stopped, }heartbeat"
                else
                    rc=1
                fi' \
    '                    (( HB_STEP_STOPPED )) && stopped="${stopped:+$stopped, }heartbeat"
                else
                    :
                fi')
report "M193: a heartbeat stop that failed does not make the rollback incomplete" "$m" \
       "🔴 and is INCOMPLETE"

# M194: the rollback reads stack.sh's stop line for two of its three components only.
m=$(mutant m194 "$NDT" \
    "'^[[:space:]]*stopped (kernel|p4_proxy|ryu)\$'" \
    "'^[[:space:]]*stopped (kernel|p4_proxy)\$'")
report "M194: stack.sh's stop line for Ryu is not read" "$m" \
       "🔴 stack.sh's own line for ryu makes the rollback say the stack was stopped"

# M188: the stack is listed as stopped whether or not stack.sh down stopped a component.
m=$(mutant m188 "$NDT" \
    "                if grep -Eq '^[[:space:]]*stopped (kernel|p4_proxy|ryu)\$' <<<\"\$out\"; then stopped=" \
    '                if true; then stopped=')
report "M188: a stack that was not running is listed as stopped" "$m" \
       "🔴 a reuse rollback that stopped nothing says nothing was taken down"

# M189: the line over a reused fabric prints an empty list when nothing was taken down.
m=$(mutant m189 "$NDT" \
    '        line="rolled back: ${taken:-nothing} taken down"' \
    '        line="rolled back: ${taken} taken down"')
report "M189: a reuse rollback that stopped nothing prints an empty list" "$m" \
       "🔴 a reuse rollback that stopped nothing says nothing was taken down"

# M190: the deferral note claims every other stop has already succeeded.
m=$(mutant m190 "$NDT" \
    '                    info "  they are read again after the rollback'"'"'s other stages run."' \
    '                    info "  they are read again once everything else this bring-up started is stopped."')
report "M190: the deferral note says the other stops succeeded" "$m" \
       "  🔴 the note does not claim the other stops succeeded"

# M191: the manifest reader runs in the interpreter's default mode and imports from the working directory.
m=$(mutant m191 "$NDT" \
    '    python3 -I -c '"'"'
import json, sys
try:
    with open(sys.argv[1]) as fh:' \
    '    python3 -c '"'"'
import json, sys
try:
    with open(sys.argv[1]) as fh:')
report "M191: the manifest reader imports a module from the working directory" "$m" \
       "🔴 the manifest reader does not import a module from the working directory"

m=$(mutant w15 "$NDT" \
    '                    info "  they are read again after the rollback'"'"'s other stages run."' \
    '                    info "  read again after the rest of this rollback has run."')
report_green "W15 (behaviour-preserving): the rollback's deferral note reworded" "$m" \
       "the note above the re-read is not the behaviour under test"


# --- FIXED-ISSUES G-44: `ndt clean` during a teardown -------------------------------------------

# M48 restores G-44: `ndt clean` walks straight into a live teardown and reports the fabric
# being destroyed as residue, ending on the one piece of advice that would kill the operator's
# own processes. The named case is the refusal's TEXT, not its rc -- cmd_clean is already rc 1
# about a dirty machine, so the rc alone cannot see this mutation at all.
m=$(mutant m48 "$NDT" \
    '    if tif="$(teardown_in_flight_peek)" && [[ "${tif%% *}" != "$$" ]]; then' \
    '    if false; then')
report "M48: 'ndt clean' has no guard against a live teardown again" "$m" \
       "  naming what it is refusing on"

# M49 (widening): the guard reads the FILE instead of its owner, so it also refuses `ndt down`'s
# own `verify clean` -- the last step of every round -- while passing every refusal cell above.
m=$(mutant m49 "$NDT" \
    '    if tif="$(teardown_in_flight_peek)" && [[ "${tif%% *}" != "$$" ]]; then' \
    '    if tif="$(teardown_in_flight_peek)"; then')
report "M49 (widening): the clean guard refuses its own teardown too" "$m" \
       "🔴 'ndt down' is not refused by its own marker at verify clean"


# --- FIXED-ISSUES G-45: whose processes `ndt clean` is looking at -------------------------------

# M50 restores G-45's pidfile half: the registry is not consulted, so the kernel and proxy this
# stack started and recorded are summarised as "this stack did not start it".
m=$(mutant m50 "$NDT" \
    '                if [[ "$(port_owner_local "$cport" "$cproto")" == ours ]]; then' \
    '                if false; then')
report "M50: 'ndt clean' stops reading .test_run/pids/" "$m" \
       "🔴 a pid in .test_run/pids/ is not 'this stack did not start it'"

# M51 restores the other half: bmv2 is root-owned, so the pidfile test CANNOT answer for its
# twenty ports -- drop the manifest arm and the fabric's own ports are strangers again, which
# is most of the 74 lines a live `ndt clean` printed on 2026-09-12.
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


# --- F1: the plane the rate is read for ------------------------------------------------------

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



# --- FIXED-ISSUES G-47: a refused `ndt up p4 <n>` and the P4 host knob (section 18) ------------

# M53 is the defect itself, in the shape measured on 2026-09-12: the count is written through before
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
report "M53: the knob is written before the refusals again" "$m" \
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
# wrong fix for G-47 -- it removes the write from the refusal path by removing the request
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

# --- FIXED-ISSUES G-49: the claim note and the verdict (section 19) -----------------------------

# M59 is the defect itself: the note is written from the rc again. It survives every cell whose
# rc and verdict agree, which is why section 19 carries the one where they do not.
m=$(mutant m59 "$NDT" \
    '    claim_note_down "$down_rc" "$CLEAN_UNVERIFIED"' \
    '    claim_note_down "$down_rc" "$( (( down_rc == 0 )) || printf "the teardown" )"')
report "M59: the claim note is written from the rc again" "$m" \
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

# --- the one rc vocabulary across up, down and clean -------------------
#
# 2026-09-12. Every mutation below is a way of making the three words mean one word again,
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
    '        # 🔴 rc 5: refused. (2026-09-12)
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
    '        # guards, one code -- see the vocabulary note above preflight. (2026-09-12)
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

# --- 'ndt clean' answers 3 when it measured nothing (section 21) --------------------------------

# M73: the refusal goes back to 1, with every word of it unchanged.
m=$(mutant m73 "$NDT" \
    '        # 🔴 rc 5: refused. It outranks rc 3 -- a command that refused did not measure this
        # machine at all, so it has nothing to report about what is on it. (2026-09-12)
        return 5' \
    '        return 1')
report "M73: 'ndt clean' refuses with 1 again" "$m" \
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

# --- 'ndt down' answers 3 when it tore nothing down (section 22) --------------------------------

# M77: the teardown's refusals go back to 1, one site at a time. Every word of the refusal is
# unchanged; what a caller reads is not.
m=$(mutant m77 "$NDT" \
    '        # 🔴 rc 5: refused. Nothing on this machine was read, let alone changed -- the same
        # answer `ndt up` and `ndt clean` give for a guard. (2026-09-12)
        return 5' \
    '        return 1')
report "M77: a foreign claim refuses the teardown with 1 again" "$m" \
       "🔴 a foreign claim refuses the teardown with 5"
m=$(mutant m78 "$NDT" \
    '    mark_teardown_start || return 5' \
    '    mark_teardown_start || return 1')
report "M78: a second teardown is refused with 1 again" "$m" \
       "🔴 a second 'ndt down' is refused while one is still running"

# M79: the defect itself, put back. An already-down lab reports the same byte as a round that
# removed a fabric and proved it gone -- which is the state a 2026-09-12 table of live runs was in.
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
# verify. That sentence is a FILE, and a 2026-09-12 baseline arrived carrying the previous
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

# --- [3/3] says it ran the Mininet sweep (section 23) --------------------------------------------

# M82: the sentence goes. The teardown still does the sweep, and the manual still carries the
# hand-typed command -- which is the state the open question is about.
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

# --- the way IN is printed on both planes ------------------------------

# M84: the OVS bring-up stops printing it, which is the state reported at 11:23 --
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

# --- ndt_port_open rc 2, "cannot tell", at each caller (section 25) ---------------------------
# [Co-developed with claude code -- Adam]
# ports.sh says callers must not fold 2 into "closed". Each mutation puts one fold back.

# M88: the deferred-port re-read reads 2 as closed again, and then says [3/3] closed the port.
m=$(mutant m88 "$NDT" \
    '                2) dunk="${dunk:+$dunk }$dp" ;;' \
    '                2) ;;')
report "M88: the deferred re-read folds 'cannot tell' into closed" "$m" \
       "🔴 down: a deferred port the re-read cannot tell about keeps the teardown red"

# M89: preflight's ownership step skips 2 in silence again.
m=$(mutant m89 "$NDT" \
    '                    info "  :$p ($proto) could not be probed ($(ndt_port_blind_why)): whether it is held,"
                    info "     and by whom, is NOT checked. not refused, as for a holder we cannot see."' \
    '                    :')
report "M89: preflight skips a port it cannot probe without a word" "$m" \
       "  but the ownership step names it, with a reason"

# M90: the other direction -- preflight refuses on 2, which would refuse every bring-up on a
# machine without ss.
m=$(mutant m90 "$NDT" \
    '                    info "     and by whom, is NOT checked. not refused, as for a holder we cannot see."
                    continue' \
    '                    info "     and by whom, is NOT checked. not refused, as for a holder we cannot see."
                    foreign=1; continue')
report "M90: preflight refuses a port it cannot probe" "$m" \
       "🔴 preflight: a port that cannot be probed is not a refusal"

# M91: --deep names the port but no longer says why it could not look.
m=$(mutant m91 "$NDT" \
    'could not be probed ($(ndt_port_blind_why)) -- --deep cannot address it' \
    'could not be probed -- --deep cannot address it')
report "M91: deep_sweep drops the reason a port could not be probed" "$m" \
       "  deep_sweep: the port is named, with a reason"

# M92: ndt clean's ours/stranger split treats 2 as open and invents a stranger for it.
m=$(mutant m92 "$NDT" \
    '                ndt_port_open "$cport" "$cproto" || continue' \
    '                ndt_port_open "$cport" "$cproto"; (( $? == 1 )) && continue')
report "M92: ndt clean calls a port it could not probe a stranger's" "$m" \
       "🔴 clean: and it does not call it a stranger's"

# M93: the line that makes a SILENT blind residue not clean. Redundant whenever the residue printed
# its "could NOT be probed" line (that text alone makes cmd_clean red) -- so it is pinned by a case
# whose residue prints nothing.
m=$(mutant m93 "$NDT" \
    '    (( prc == 2 )) && rc=1' \
    '    :')
report "M93: a silent 'cannot tell' residue is clean" "$m" \
       "  clean (silent): a 'cannot tell' from the residue with no text is still not clean"

# M94: "ports closed" for any reading that is not "held" -- i.e. for "cannot tell" too.
m=$(mutant m94 "$NDT" \
    '    (( prc == 0 )) && ok "ports closed: $(ndt_port_label all)"' \
    '    (( prc != 1 )) && ok "ports closed: $(ndt_port_label all)"')
report "M94: 'ports closed' is printed for a reading that could not look" "$m" \
       "  clean: it does not say the ports are closed"

# M95: ports.sh's residue stops naming a port it could not probe (the mutant dir carries its own
# ports.sh, so this edits the copy).
m=$(mutant m95 "$PORTS" \
    '                   printf '"'"'residue: :%s (%s) could NOT be probed on this machine (%s) -- not a pass\n'"'"' \
                          "$port" "$proto" "$(ndt_port_blind_why)"
                   printf '"'"'         -> owner: %s\n'"'"' "$owner"' \
    '                   :')
report "M95: the residue's line for a port it could not probe is dropped" "$m" \
       "  clean: the residue names it as not probed"

# M96: BOTH of the port's rc sources in cmd_clean removed at once -- the residue branch's rc=1 and
# `(( prc == 2 )) && rc=1`. Each alone is redundant with the other; together they are the whole of
# "a port that cannot be probed is not clean", which this pins (the manifest is out of that case).
m=$(mutant m96 "$NDT" \
    '        rc=1
    fi
    # 2 is "could not look", not "nothing there". Treated as not-clean for the same reason
    # grpc_ports.py refuses on an unreadable ip_local_port_range: unknown is not safe.
    (( prc == 2 )) && rc=1' \
    '        :
    fi
    # 2 is "could not look", not "nothing there". Treated as not-clean for the same reason
    # grpc_ports.py refuses on an unreadable ip_local_port_range: unknown is not safe.
    :')
report "M96: neither the residue text nor prc == 2 makes ndt clean red" "$m" \
       "  clean: a port that cannot be probed is not clean"

# --- section 26: what a refused 'ndt up p4' puts back, and what it leaves alone ----------------
#
# [Co-developed with claude code -- Adam]
# Each of these deletes ONE condition or call of refusal_unwind / refusal_put_back /
# up_wrote_put_back / knob_restore and must turn the one cell that pins it red (the cells are
# section 26 of the suite). They are anchored by text, like the rest of this gate, so a later
# edit that moves or rewrites the line is told by check_gate_anchors.py instead of going unseen.
#
# The claim note is reverted only when all of these hold; each has its own cell, and the cells
# for the others cannot stop a mutant that drops this one:
#   M97 the owner is still NDT_OWNER      M98 the note is still the recorded sentence
#   M99 claim_note_up recorded a sentence (refusal_claim_written's rule)
#   M100 a sentence was recorded at all (the -n test; only an emptied note reaches it)
m=$(mutant m97 "$NDT" \
    '          && "$(claim_field owner)" == "$NDT_OWNER" && "$(claim_field note)" == "$REFUSAL_NOTE_WRITTEN" ]]; then
        if claim_rewrite note "$REFUSAL_NOTE_BEFORE"; then' \
    '          && "$(claim_field note)" == "$REFUSAL_NOTE_WRITTEN" ]]; then
        if claim_rewrite note "$REFUSAL_NOTE_BEFORE"; then')
report "M97: a claim that is no longer ours gets its note rewritten" "$m" \
       "🔴 a claim that is no longer ours keeps its note"

m=$(mutant m98 "$NDT" \
    '          && "$(claim_field owner)" == "$NDT_OWNER" && "$(claim_field note)" == "$REFUSAL_NOTE_WRITTEN" ]]; then
        if claim_rewrite note "$REFUSAL_NOTE_BEFORE"; then' \
    '          && "$(claim_field owner)" == "$NDT_OWNER" ]]; then
        if claim_rewrite note "$REFUSAL_NOTE_BEFORE"; then')
report "M98: a note that is no longer our sentence is reverted" "$m" \
       "🔴 a note that is no longer our sentence is kept"

m=$(mutant m99 "$NDT" \
    '    [[ -n "$REFUSAL_NOTE_TAKEN" && -n "$CLAIM_NOTE_UP_TEXT" && -f "$CLAIM" ]] || return 0
    [[ "$(claim_field note)" == "$CLAIM_NOTE_UP_TEXT" ]] && REFUSAL_NOTE_WRITTEN="$CLAIM_NOTE_UP_TEXT"' \
    '    [[ -n "$REFUSAL_NOTE_TAKEN" && -f "$CLAIM" ]] || return 0
    [[ "$(claim_field note)" == "$REFUSAL_NOTE_BEFORE" ]] || REFUSAL_NOTE_WRITTEN="$(claim_field note)"')
report "M99: 'the note changed' is read as 'claim_note_up wrote it'" "$m" \
       "🔴 a note this run did not write is not reverted"

m=$(mutant m100 "$NDT" \
    'if [[ -n "$REFUSAL_NOTE_WRITTEN" && -n "${NDT_OWNER:-}" && -f "$CLAIM" \
          && "$(claim_field owner)" == "$NDT_OWNER" && "$(claim_field note)" == "$REFUSAL_NOTE_WRITTEN" ]]; then
        if claim_rewrite note "$REFUSAL_NOTE_BEFORE"; then' \
    'if [[ -n "${NDT_OWNER:-}" && -f "$CLAIM" \
          && "$(claim_field owner)" == "$NDT_OWNER" && "$(claim_field note)" == "$REFUSAL_NOTE_WRITTEN" ]]; then
        if claim_rewrite note "$REFUSAL_NOTE_BEFORE"; then')
report "M100: an emptied note is filled in again (no sentence was recorded)" "$m" \
       "🔴 an emptied note is not filled in again"

# The three files are put back only while they hold what this run left in them.
#   M101 the changed-since test is gone (rewrites, creations and deletions are all undone)
#   M102 an ABSENT file is read as unchanged (only the deletion is undone)
#   M103 the up_wrote lines are put back whatever they hold now
m=$(mutant m101 "$NDT" \
    '    if [[ "$now" != "$after" ]]; then' \
    '    if false; then')
report "M101: a file changed during the sweep is put back over" "$m" \
       "🔴 their telemetry knob is left as they wrote it"

m=$(mutant m102 "$NDT" \
    '    if [[ -e "$p" ]]; then now="$(cat -- "$p" 2>/dev/null; printf x)"; else now=ABSENT; fi
    if [[ "$now" != "$after" ]]; then' \
    '    if [[ -e "$p" ]]; then now="$(cat -- "$p" 2>/dev/null; printf x)"; else now="$after"; fi
    if [[ "$now" != "$after" ]]; then')
report "M102: a file deleted during the sweep is written back" "$m" \
       "🔴 a deleted up.target is not written back"

m=$(mutant m103 "$NDT" \
    '    [[ "$UPW_MARK" == "$(round_baseline_field up_wrote)|$(round_baseline_field up_wrote_at)" ]] \
        || return 0
' \
    '')
report "M103: another bring-up's up_wrote lines are put back over" "$m" \
       "🔴 the lines another bring-up wrote are kept"

# The up_wrote lines go back with the host-count knob, on both of knob_restore's branches and on
# rollback_up's call.
#   M104 knob_restore's main branch   M105 its absent-snapshot branch   M106 rollback_up's call
m=$(mutant m104 "$NDT" \
    '    warn "host_count_override put back to $KNOB_ENTRY (it read $now): $why"
    up_wrote_put_back' \
    '    warn "host_count_override put back to $KNOB_ENTRY (it read $now): $why"')
report "M104: knob_restore's main branch leaves the up_wrote lines" "$m" \
       "🔴 the rollback put the baseline's up_wrote back"

m=$(mutant m105 "$NDT" \
    '        warn "removed $(short_repo_path "$f"): $why (this run created it)"
        up_wrote_put_back' \
    '        warn "removed $(short_repo_path "$f"): $why (this run created it)"')
report "M105: knob_restore's absent-snapshot branch leaves the up_wrote lines" "$m" \
       "🔴 and the baseline's up_wrote lines are back"

# [Co-developed with claude code -- Adam] M106 makes the same edit as M55 (rollback_up loses its
# knob_restore call) but is pinned by a different cell: M55 by the host-count knob's, M106 by the
# round baseline's up_wrote lines.
m=$(mutant m106 "$NDT" \
    '    knob_restore "this bring-up was rolled back"
' \
    '')
report "M106: rollback_up leaves the host-count knob and the up_wrote lines" "$m" \
       "🔴 the rollback put the baseline's up_wrote back"

# --- up_p4's call sites: each unwind, snapshot, mark and decision that the unwind relies on ------
#
# [Co-developed with claude code -- Adam]
# M97-M106 break the functions; these break the places up_p4 calls them from. Each must turn red
# the cell that pins that call, so a later edit that drops or reorders one is told by this gate.
# The two sites reached only with an app package (the app knob write and its read-back mark) are
# pinned in test_ndt_app_package.sh and mutated in mutate_ndt_app_package.sh. refusal_mark's own
# -r test is mutated too (M126): it matters only when a writer leaves the file unreadable, which
# the writers do not do on their own, so its cell stubs the telemetry writer to do it and is
# skipped for a user who can read a mode-000 file. It is not equivalent: without the line the
# earlier bytes are written back over the run's own.
#   M107-M111  each refusal_unwind in the write block and at the sweep goes back to the old knob_restore
m=$(mutant m107 "$NDT" \
    'set_host_count "$knob_wanted" "$knob_layout" || { refusal_unwind "the knob write itself was refused"; return 1; }' \
    'set_host_count "$knob_wanted" "$knob_layout" || { knob_restore "the knob write itself was refused"; return 1; }')
report "M107: a refused host-count write only restores the host-count knob" "$m" \
       "🔴 and up.target is back (the knob was never moved)"

m=$(mutant m108 "$NDT" \
    '            refusal_unwind "the app package knob could not be cleared"' \
    '            knob_restore "the app package knob could not be cleared"')
report "M108: an app knob that cannot be cleared only restores the host knob" "$m" \
       "🔴 and up.target and the host-count knob are back"

m=$(mutant m109 "$NDT" \
    '        refusal_unwind "the package'"'"'s telemetry source is not one this script knows"' \
    '        knob_restore "the package'"'"'s telemetry source is not one this script knows"')
report "M109: an unknown telemetry word only restores the host knob" "$m" \
       "🔴 an unknown telemetry word puts back up.target, the cleared app knob and the host-count knob"

m=$(mutant m110 "$NDT" \
    '        refusal_unwind "the telemetry knob could not be written"' \
    '        knob_restore "the telemetry knob could not be written"')
report "M110: a telemetry knob that cannot be written only restores the host knob" "$m" \
       "🔴 and up.target, the cleared app knob and the host-count knob are back"

m=$(mutant m111 "$NDT" \
    '                refusal_unwind "the orphan sweep ran but did not finish; nothing was built"' \
    '                knob_restore "the orphan sweep ran but did not finish; nothing was built"')
report "M111: a failed orphan sweep only restores the host knob" "$m" \
       "🔴 up.target, both knobs, the claim and the host-count knob are byte-identical"

#   M112-M119  the snapshot, the marks, the claim record, the up_wrote mark and the model check are gone
m=$(mutant m112 "$NDT" \
    '    refusal_snapshot
    record_up_target p4 "$hosts" "$topo" || return $?' \
    '    record_up_target p4 "$hosts" "$topo" || return $?')
report "M112: nothing is snapshotted before the writes" "$m" \
       "🔴 up.target, both knobs, the claim and the host-count knob are byte-identical"

m=$(mutant m113 "$NDT" \
    '    record_up_target p4 "$hosts" "$topo" || return $?
    refusal_mark "$(up_target_file)"
' \
    '    record_up_target p4 "$hosts" "$topo" || return $?
')
report "M113: up.target is never marked as this run's" "$m" \
       "🔴 up.target, both knobs, the claim and the host-count knob are byte-identical"

m=$(mutant m114 "$NDT" \
    '    fi
    refusal_mark "$(app_knob_path)"
' \
    '    fi
')
report "M114: the app knob is never marked after its write or clear" "$m" \
       "🔴 and up.target, the cleared app knob and the host-count knob are back"

m=$(mutant m115 "$NDT" \
    '    refusal_mark "$(telemetry_knob_path)"
' \
    '')
report "M115: the telemetry knob is never marked after its write" "$m" \
       "🔴 up.target, both knobs, the claim and the host-count knob are byte-identical"

m=$(mutant m116 "$NDT" \
    '        refusal_mark "$(telemetry_knob_path)"       # same reason as the app knob'"'"'s block above
' \
    '')
report "M116: a telemetry write that fails its read-back is not marked" "$m" \
       "🔴 the earlier telemetry knob is back and so is everything else"

m=$(mutant m117 "$NDT" \
    '    claim_note_up "$up_what"
    refusal_claim_written' \
    '    claim_note_up "$up_what"')
report "M117: the sentence claim_note_up wrote is never recorded" "$m" \
       "🔴 the note is back to what it was"

m=$(mutant m118 "$NDT" \
    '        up_wrote_mark
' \
    '')
report "M118: the up_wrote lines are never marked after set_host_count" "$m" \
       "🔴 up_wrote is what it was before this run"

m=$(mutant m119 "$NDT" \
    '    up_target_check p4 "$hosts" "$topo" || return $?
    n="$(bmv2_count)"' \
    '    n="$(bmv2_count)"')
report "M119: the model comparison no longer comes before the hoisted refusals" "$m" \
       "🔴 a mismatched model beats a live OVS fabric: rc 5"

#   M120-M121  the hoisted refusals lose their reuse condition   M122-M124  the UP_P4_FABRIC fresh/reused assignments
m=$(mutant m120 "$NDT" \
    '    if (( reuse )) && stale_pipeline; then' \
    '    if stale_pipeline; then')
report "M120: a stale build file refuses a fabric that is not being reused" "$m" \
       "🔴 a stale build file does not refuse a fabric that is not up"

m=$(mutant m121 "$NDT" \
    '    (( reuse )) || guard_no_live_ovs ||' \
    '    guard_no_live_ovs ||')
report "M121: the OVS guard refuses a fabric that is being reused" "$m" \
       "🔴 reusing a live fabric is not refused by the OVS guard"

m=$(mutant m122 "$NDT" \
    '        UP_P4_FABRIC=reused
' \
    '')
report "M122: a reused fabric is still called one this run started" "$m" \
       "🔴 a reused fabric: the ready line claims no mode"

m=$(mutant m123 "$NDT" \
    '    UP_P4_FABRIC=fresh
    if (( reuse )); then
        ok "already up: $n switches, $live_hosts hosts, reusing"
        UP_P4_FABRIC=reused
        up_left_running "bmv2 fabric ($live_hosts hosts)"
    else' \
    '    if (( reuse )); then
        ok "already up: $n switches, $live_hosts hosts, reusing"
        UP_P4_FABRIC=reused
        up_left_running "bmv2 fabric ($live_hosts hosts)"
    fi
    UP_P4_FABRIC=fresh
    if (( reuse )); then :
    else')
report "M123: 'fresh' is set after the reuse branch, overwriting 'reused'" "$m" \
       "🔴 a reused fabric: the ready line claims no mode"

m=$(mutant m124 "$NDT" \
    '    UP_P4_FABRIC=fresh
    if (( reuse )); then' \
    '    if (( reuse )); then')
report "M124: a fabric this run started is never called fresh" "$m" \
       "🔴 a fabric this run started: the ready line names the pane's mode"

#   M125  a file that cannot be read is snapshotted as an empty one
m=$(mutant m125 "$NDT" \
    '        if [[ -e "$p" && ! -r "$p" ]]; then REFUSAL_PRE[$p]=""; continue; fi
' \
    '')
report "M125: an unreadable file is snapshotted as an empty one" "$m" \
       "🔴 no empty app knob is written back over it"

#   M126  refusal_mark reads a file it cannot read as an empty one
m=$(mutant m126 "$NDT" \
    '    if [[ -e "$p" && ! -r "$p" ]]; then REFUSAL_AFTER[$p]=""; return 0; fi
' \
    '')
report "M126: a file this run left unreadable is read as empty and put back over" "$m" \
       "🔴 a knob this run left unreadable is not overwritten with the earlier bytes"

# [Co-developed with claude code -- Adam] Section 27: a failed `ndtwin-lab status` call (lab_session rc 2) is
# "cannot tell". Each site put back to reading it as "no session", then each site widened to refuse the
# answers it must not refuse. The sweep and the stop share a variable, so their anchors carry the next line.
#   M127  the orphan sweep reads rc 2 as "no session" and sweeps
m=$(mutant m127 "$NDT" \
    '            topo_session; sess_rc=$?
            if (( sess_rc == 2 )); then' \
    '            topo_session; sess_rc=$?; (( sess_rc == 2 )) && sess_rc=1
            if (( sess_rc == 2 )); then')
# (Not the rc cell: the stop before the new fabric, M128's site, refuses the same answer and keeps rc 1.)
report "M127: bmv2 with an unreadable session are swept as orphans" "$m" \
       "🔴 and cleanup was never run"

#   M128  the fabric start reads rc 2 as "no session to stop"
m=$(mutant m128 "$NDT" \
    '        topo_session; sess_rc=$?
        if (( sess_rc == 2 )); then' \
    '        topo_session; sess_rc=$?; (( sess_rc == 2 )) && sess_rc=1
        if (( sess_rc == 2 )); then')
# (Not the rc cell: a fabric that is started here never comes up on the stubbed machine, which is rc 1 too.)
report "M128: a fabric is started over a session that could not be looked at" "$m" \
       "🔴 and topo-start was never run"

#   M129  the rollback's last look reads rc 2 as "no session"
m=$(mutant m129 "$NDT" \
    '            2) err "rollback: cannot tell whether the topo session is still present (the '"'"'ndtwin-lab status'"'"' call failed)"; left=1 ;;' \
    '            2) : ;;')
# (Not the rc cell: the bring-up being rolled back failed, which is rc 1 whatever the last look says.)
report "M129: a rollback that cannot see the session reads clean" "$m" \
       "🔴 it says it cannot tell whether the topo session is still present"

#   M130  ndt clean reads rc 2 as "no topo session"
# [Co-developed with claude code -- Adam] Repointed 2026-11-06: the branch also records the session for the
# 'ndt up' record's decision, on a second line.
m=$(mutant m130 "$NDT" \
    '        *) err "cannot tell whether a topo session is present: the '"'"'ndtwin-lab status'"'"' call failed"; rc=1
           fabric_left "a topo session it could not read" ;;' \
    '        *) ok "no topo session" ;;')
report "M130: ndt clean says 'no topo session' for a status call that failed" "$m" \
       "🔴 'ndt clean' that cannot see the session is rc 1, not clean"

#   M131  lab_subject counts an unreadable session as nothing
m=$(mutant m131 "$NDT" \
    '        2) echo "whether a topo tmux session exists could not be checked (the '"'"'ndtwin-lab status'"'"' call failed)"; found=1 ;;' \
    '        2) : ;;')
report "M131: an unreadable session is not part of what a teardown is about" "$m" \
       "🔴 a lab whose session cannot be read is a subject (rc 0)"

#   N127..N131  the same sites widened until they refuse the answers they must not refuse
m=$(mutant n127 "$NDT" \
    '            topo_session; sess_rc=$?
            if (( sess_rc == 2 )); then' \
    '            topo_session; sess_rc=$?
            if (( sess_rc != 0 )); then')
report "N127: the sweep refuses whenever there is no session too" "$m" \
       "control: the same processes with no session ARE swept, and the bring-up goes on"

m=$(mutant n128 "$NDT" \
    '        topo_session; sess_rc=$?
        if (( sess_rc == 2 )); then' \
    '        topo_session; sess_rc=$?
        if (( sess_rc != 0 )); then')
report "N128: the fabric start refuses whenever there is no session too" "$m" \
       "control: no session and nothing to stop, the fabric starts"

m=$(mutant n129 "$NDT" \
    '            2) err "rollback: cannot tell whether the topo session is still present' \
    '            *) err "rollback: cannot tell whether the topo session is still present')
report "N129: the rollback cannot tell whenever the session is absent too" "$m" \
       "control: the same rollback with a readable, absent session is clean"

m=$(mutant n130 "$NDT" \
    '        1) ok "no topo session" ;;' \
    '        1) err "cannot tell whether a topo session is present: the '"'"'ndtwin-lab status'"'"' call failed"; rc=1 ;;')
report "N130: ndt clean cannot tell whenever the session is absent too" "$m" \
       "control: with a readable, absent session it says so"

m=$(mutant n131 "$NDT" \
    '        2) echo "whether a topo tmux session exists could not be checked' \
    '        *) echo "whether a topo tmux session exists could not be checked')
report "N131: lab_subject finds a session whenever there is none too" "$m" \
       "control: a lab with no session and nothing else is no subject (rc 1)"

#   M132  [Co-developed with claude code -- Adam] the whole-helper-refused `ndt down` (section 27) runs the real lab_session, so
#         a failed status call answered 1 ("no session") instead of 2 leaves cmd_down's verify step without "cannot tell".
#         (M130 mutates cmd_clean's rc-2 branch, which M132 used to repeat byte for byte.)
m=$(mutant m132 "$NDT" \
    '    out="$(TERM="${TERM:-dumb}" sudo -n "$LAB" status 2>/dev/null)" || return 2' \
    '    out="$(TERM="${TERM:-dumb}" sudo -n "$LAB" status 2>/dev/null)" || return 1')
report "M132: a failed status call is read as 'no session' by lab_session itself" "$m" \
       "  its verify step says it cannot tell whether a topo session is present"

# [Co-developed with claude code -- Adam] Section 28: an NTG mode NTG does not know or a hosts file that does not exist.
#   M133  the refusal is gone: the fabric is built, handed to NTG, and torn down after [3/3]
m=$(mutant m133 "$NDT" \
    '    (( reuse )) || ntg_up_refusal || return $?
' \
    '')
report "M133: a P4 bring-up builds over an NTG mode NTG does not know" "$m" \
       "🔴 an NTG mode NTG does not know refuses 'ndt up p4' with rc 5"

#   M134  (widening) a fabric this run reuses is refused over the config the next bring-up reads
m=$(mutant m134 "$NDT" \
    '    (( reuse )) || ntg_up_refusal || return $?' \
    '    ntg_up_refusal || return $?')
report "M134: a reused fabric is refused over the next bring-up's NTG mode" "$m" \
       "🔴 a reused fabric is not refused over the mode the next bring-up would read"

#   M135  (widening) every mode but cli is refused, custom_command included
m=$(mutant m135 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == ok && "$NTG_MODE" == cli ]] && return 0')
report "M135: a mode NTG knows is refused unless it is cli" "$m" \
       "🔴 a mode NTG knows is still built"

#   M136  (widening) a checkout whose config cannot be read is refused as if NTG would refuse it
m=$(mutant m136 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == ok ]] && return 0')
report "M136: a checkout with no NTG config is refused" "$m" \
       "🔴 a checkout without NTG's config is not a refusal"

# [Co-developed with claude code -- Adam] The refusal's place and its answer.
#   M137  (placement) the refusal sits below record_up_target: it still says rc 5, but up.target
#         has been rewritten by then
m=$(mutant m137 "$NDT" \
    '    (( reuse )) || ntg_up_refusal || return $?

    # What this run was asked for, written down before anything is built, so `status --check`
    # has a baseline that does not depend on reading a P4-only knob back afterwards.
    refusal_snapshot
    record_up_target p4 "$hosts" "$topo" || return $?
    refusal_mark "$(up_target_file)"' \
    '    # What this run was asked for, written down before anything is built, so `status --check`
    # has a baseline that does not depend on reading a P4-only knob back afterwards.
    refusal_snapshot
    record_up_target p4 "$hosts" "$topo" || return $?
    refusal_mark "$(up_target_file)"
    (( reuse )) || ntg_up_refusal || return $?')
report "M137: the NTG refusal is asked after up.target has been rewritten" "$m" \
       "🔴 up.target, both knobs, the claim and the host-count knob are byte-identical"

#   M138  (rc) the refusal answers 1, which ndt reads as "something measured dirty", not "a guard refused"
m=$(mutant m138 "$NDT" \
    '    err "  no fabric was started; up.target, the knobs and the claim note were not touched."
    return 5' \
    '    err "  no fabric was started; up.target, the knobs and the claim note were not touched."
    return 1')
report "M138: the NTG refusal answers 1 instead of 5" "$m" \
       "🔴 an NTG mode NTG does not know refuses 'ndt up p4' with rc 5"

#   M139  (widening) a hosts file this user cannot read is refused as if NTG would refuse it
m=$(mutant m139 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file || "$NTG_ST" == unreadable ]] || return 0')
report "M139: a hosts file this user cannot read is refused" "$m" \
       "🔴 a hosts file this user cannot read is not a refusal"

#   M140  (widening) a checkout whose NTG.yaml names no hosts file is refused
m=$(mutant m140 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file || "$NTG_ST" == unresolved ]] || return 0')
report "M140: a checkout whose hosts file cannot be resolved is refused" "$m" \
       "🔴 a checkout whose hosts file cannot be resolved is not a refusal"

#   M141  (widening) a checkout ndt cannot name is replaced by the built-in default, which the
#         bridge may not use at all
m=$(mutant m141 "$NDT" \
    'ntg_up_refusal() {
    local d
    d="$(lab_ntg_dir 2>/dev/null)"
    [[ -n "$d" ]] || return 0' \
    'ntg_up_refusal() {
    local d
    d="$(lab_ntg_dir 2>/dev/null)"
    [[ -n "$d" ]] || d="$LAB_DEFAULT_NTG_DIR"')
report "M141: a checkout ndt cannot name is read as the built-in default" "$m" \
       "🔴 a checkout ndt cannot name is not a refusal"

#   M142  the refusal stops saying which files it left alone
m=$(mutant m142 "$NDT" \
    '    err "  no fabric was started; up.target, the knobs and the claim note were not touched."' \
    '    err "  no fabric was started."')
report "M142: the NTG refusal stops saying up.target, the knobs and the claim note were not touched" "$m" \
       "  and says the files it concerns were not touched"

# [Co-developed with claude code -- Adam] The hosts file NTG.yaml names is not there.
#   M143  the no-host-file arm is gone: only a mode NTG does not know is refused
m=$(mutant m143 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode ]] || return 0')
report "M143: a bring-up builds over a hosts file that does not exist" "$m" \
       "🔴 a hosts file NTG.yaml names that is not there refuses 'ndt up p4' with rc 5"

#   M144  (widening) a checkout with no NTG.yaml is refused as well
m=$(mutant m144 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file || "$NTG_ST" == no-ntg-yaml ]] || return 0')
report "M144: a checkout with no NTG.yaml is refused" "$m" \
       "🔴 a checkout without NTG's config is not a refusal"

# [Co-developed with claude code -- Adam] A hosts file in a directory this user cannot search, and the other labelled states.
#   M145  "not there" goes back to os.path.isfile, which is False for a stat that fails with EACCES: a hosts file root
#         may well open is called missing, and refused
m=$(mutant m145 "$NTGCFG" \
    '    try:
        mode = os.stat(host).st_mode
    except ValueError:
        return None, "no-host-file"
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP, errno.ENAMETOOLONG):
            return None, "no-host-file"
        return None, "cannot read it: %s" % oserror(e)
    if not stat.S_ISREG(mode):
        return None, "no-host-file"' \
    '    if not os.path.isfile(host):
        return None, "no-host-file"')
report "M145: a hosts file in a directory this user cannot search is called missing" "$m" \
       "🔴 a hosts file in a directory this user cannot search is not a refusal"

#   M146..M149  (widening) one more labelled state added to the guard line
m=$(mutant m146 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file || "$NTG_ST" == hardware-mode ]] || return 0')
report "M146: a hardware-mode config is refused" "$m" "🔴 a hardware-mode config is not a refusal"
m=$(mutant m147 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file || "$NTG_ST" == no-mininet ]] || return 0')
report "M147: a no-mininet config is refused" "$m" "🔴 a no-mininet config is not a refusal"
m=$(mutant m148 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file || "$NTG_ST" == bad-mode ]] || return 0')
report "M148: a bad-mode config is refused" "$m" "🔴 a bad-mode config is not a refusal"
m=$(mutant m149 "$NDT" \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file ]] || return 0' \
    '    [[ "$NTG_ST" == unknown-mode || "$NTG_ST" == no-host-file || "$NTG_ST" == no-mode ]] || return 0')
report "M149: a no-mode config is refused" "$m" "🔴 a no-mode config is not a refusal"

# [Co-developed with claude code -- Adam] Paths that cannot name a file for anyone, root included, are "not there".
#   M150  a symlink loop (ELOOP) is read as unreadable instead of missing
m=$(mutant m150 "$NTGCFG" \
    '        if e.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP, errno.ENAMETOOLONG):' \
    '        if e.errno in (errno.ENOENT, errno.ENOTDIR, errno.ENAMETOOLONG):')
report "M150: a host_file that loops is read as unreadable, not missing" "$m" \
       "🔴 a host_file that loops (ELOOP) is refused like a missing one"
#   M151  a name longer than the system allows (ENAMETOOLONG) is read as unreadable
m=$(mutant m151 "$NTGCFG" \
    '        if e.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP, errno.ENAMETOOLONG):' \
    '        if e.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):')
report "M151: a host_file name that is too long is read as unreadable, not missing" "$m" \
       "🔴 a host_file name longer than the system allows is refused like a missing one"
#   M152  a NUL byte in the path (ValueError out of os.stat) is not caught: the probe crashes and the state is unresolved
m=$(mutant m152 "$NTGCFG" \
    '    except ValueError:
        return None, "no-host-file"
    except OSError as e:' \
    '    except OSError as e:')
report "M152: a host_file with a NUL byte crashes the probe" "$m" \
       "🔴 a host_file with a NUL byte in it is refused like a missing one"

# --- [Co-developed with claude code -- Adam] `ndt down` says which step did not run, keeps the record (section 29) ---
# 2026-11-06. Each mutation puts back one half of what a live run with the lab grant moved aside showed, or
# breaks the reading that tells "did not run" from "ran and failed".
m=$(mutant d1 "$NDT" \
    '    if (( stop_rc != 0 )); then
        lab_call_verdict "$stop_out"; stop_v=$?' \
    '    if false; then
        lab_call_verdict "$stop_out"; stop_v=$?')
report "D1: [2/3] drops the rc of topo-stop again" "$m" \
       "🔴 a topo-stop that failed makes 'ndt down' rc 1"

m=$(mutant d2 "$NDT" \
    '    if (( sweep_rc == 0 )) || [[ "$sweep_out" == *"cleanup INCOMPLETE"* ]]; then' \
    '    if true; then')
report "D2: [3/3] says it ran the sweep whatever happened (the live run)" "$m" \
       "🔴 refused helper: no ok line for a sweep that did not run"

m=$(mutant d3 "$NDT" \
    '    if (( sweep_rc == 0 )) || [[ "$sweep_out" == *"cleanup INCOMPLETE"* ]]; then' \
    '    if (( sweep_rc == 0 )); then')
report "D3 (control): a sweep that ran and did not finish loses its ok line" "$m" \
       "  it is said when the sweep ran and did not finish"

m=$(mutant d4 "$NDT" \
    '    ndt_sudo_refused && return 1
    ndt_sudo_unread && return 2
    return 0
}' \
    '    ndt_sudo_refused && return 0
    ndt_sudo_unread && return 2
    return 0
}')
report "D4: a call sudo refused reads as a call that ran" "$m" \
       "🔴 refused helper: [2/3] says it did not run, and what sudo refused"

m=$(mutant d5 "$NDT" \
    '    ndt_sudo_refused && return 1
    ndt_sudo_unread && return 2
    return 0
}' \
    '    ndt_sudo_refused && return 1
    ndt_sudo_unread && return 0
    return 0
}')
report "D5: an answer ndt cannot read reads as a call that ran" "$m" \
       "  it says the sweep may not have run"

m=$(mutant d6 "$NDT" \
    '               if (( lab_hint_said )); then' \
    '               if false; then')
report "D6: the sudoers line is printed under both steps" "$m" \
       "  the sudoers line is printed once, not under both steps"

m=$(mutant d7 "$NDT" \
    '    else
        up_target_kept "$CLEAN_FABRIC_LEFT"
    fi' \
    '    else
        clear_up_target
    fi')
report "D7: the record is cleared over a fabric still running (the live run)" "$m" \
       "🔴 refused helper: the 'ndt up' record is KEPT over a fabric still running"

m=$(mutant d8 "$NDT" \
    '    if [[ -z "$CLEAN_FABRIC_LEFT" ]]; then
        clear_up_target' \
    '    if [[ -z "$CLEAN_FABRIC_LEFT" ]]; then
        :')
report "D8 (control): the record is never cleared" "$m" \
       "control: a teardown that verified clean clears the record"

m=$(mutant d9 "$NDT" \
    '                refusal_unwind "the topo session could not be checked; nothing was swept or built" || return 1
                return 5' \
    '                refusal_unwind "the topo session could not be checked; nothing was swept or built" || return 1
                return 1')
report "D9: up_p4's 'cannot tell' over bmv2 processes is 1 again" "$m" \
       "🔴 bmv2 processes with an unreadable session are not swept: the bring-up is refused, rc 5"

m=$(mutant d10 "$NDT" \
    '            refusal_unwind "the topo session could not be checked; nothing was built" || return 1
            return 5' \
    '            refusal_unwind "the topo session could not be checked; nothing was built" || return 1
            return 1')
report "D10: up_p4's 'cannot tell' before topo-start is 1 again" "$m" \
       "🔴 a fabric is not started over a session that could not be looked at: rc 5"

m=$(mutant d11 "$NDT" \
    'err "up.target, the knobs and the claim note were not touched."; return "$grc"; }' \
    'err "up.target, the knobs and the claim note were not touched."; return 1; }')
report "D11: up_p4 flattens the guard's 5 to 1" "$m" \
       "🔴 up_p4 carries the guard's 'cannot tell' out as 5"

m=$(mutant d12 "$NDT" \
    '            refusal_unwind "the topo session could not be checked; nothing was built" || return 1' \
    '            refusal_unwind "the topo session could not be checked; nothing was built"')
report "D12: a put-back that failed is still reported as 5" "$m" \
       "control: a 'cannot tell' whose put-back failed has touched the files: 1, not 5"

# [Co-developed with claude code -- Adam] 2026-11-06, second pass: the record follows the fabric, the sweep's
# evidence is the closing line only, and the branches of the verdict each have a cell.
m=$(mutant d13 "$NDT" \
    '    if (( sweep_rc == 0 )) || [[ "$sweep_out" == *"cleanup INCOMPLETE"* ]]; then' \
    '    if (( sweep_rc == 0 )) || [[ "$sweep_out" == *"cleanup INCOMPLETE"* || "$sweep_out" == *"STILL RUNNING"* ]]; then')
report "D13: a STILL RUNNING (four of five kills come before mn -c) is taken as the sweep having run" "$m" \
       "🔴 STILL RUNNING (four of five kills come before mn -c) and no closing line, rc 137: no ok line"

m=$(mutant d14 "$NDT" \
    '    if [[ -z "$CLEAN_FABRIC_LEFT" ]]; then
        clear_up_target' \
    '    if (( clean_rc == 0 || clean_rc == 3 )); then
        clear_up_target')
report "D14: the record is kept on any red verify (a stranger strands it)" "$m" \
       "🔴 a stranger on a port is not the fabric: the record is cleared"

m=$(mutant d15 "$NDT" \
    '           fabric_left "a topo session it could not read" ;;' \
    '           : ;;')
report "D15: a session nobody could read is not counted as the fabric" "$m" \
       "🔴 a topo session it could not read keeps the record"

m=$(mutant d16 "$NDT" \
    'rc=1; fabric_left "$n host/switch process(es)"; fi' \
    'rc=1; fi')
report "D16: Mininet hosts or switches are not counted as the fabric" "$m" \
       "  Mininet hosts or switches left keep it too"

m=$(mutant d17 "$NDT" \
    '                refusal_unwind "the topo session could not be checked; nothing was swept or built" || return 1' \
    '                refusal_unwind "the topo session could not be checked; nothing was swept or built"')
report "D17: a failed put-back over bmv2 processes is still reported as 5" "$m" \
       "  and on the path over bmv2 processes it cannot place: 1, not 5"

m=$(mutant d18 "$NDT" \
    '    warn "  leaves it as it is); once the fabric is gone you can also remove it:  rm ${f#$REPO/}"' \
    '    :')
report "D18: a kept record names no way out once the fabric is gone" "$m" \
       "  and how it goes once the fabric is gone"

m=$(mutant d19 "$NDT" \
    '    command -v sudo >/dev/null 2>&1 || return 2
    NDT_SUDO_STDERR="$1"' \
    '    NDT_SUDO_STDERR="$1"')
report "D19: no sudo on the machine is read from the words of a shell error" "$m" \
       "no sudo on this machine: may not have run"

m=$(mutant d20 "$NDT" \
    '    stop_out="$(LC_ALL=C LANGUAGE=C sudo -n "$LAB" topo-stop 2>&1)"; stop_rc=$?' \
    '    stop_out="$(sudo -n "$LAB" topo-stop 2>&1)"; stop_rc=$?')
report "D20: topo-stop runs in the operator's locale, which the classifier cannot read" "$m" \
       "topo-stop runs under LC_ALL=C LANGUAGE=C"

m=$(mutant d21 "$NDT" \
    '        not_verified "the [2/3] topology stop (it failed or did not run)"' \
    '        :')
report "D21: the claim note does not name a stop that did not run" "$m" \
       "the claim note names the stop that did not run"

m=$(mutant d22 "$NDT" \
    '                   lab_status_failed_hint cleanup 1' \
    '                   :')
report "D22: [3/3] refused on its own prints no sudoers line" "$m" \
       "  and prints the sudoers line itself"

m=$(mutant d23 "$NDT" \
    '            2) err "[2/3] may not have run: topo-stop exited $stop_rc, and whether sudo let it run cannot be told."' \
    '            2) err "topo-stop exited $stop_rc"')
report "D23: [2/3] does not say it may not have run when sudo could not be read" "$m" \
       "[2/3] with an answer ndt cannot read: may not have run"

# [Co-developed with claude code -- Adam] 2026-11-06, third pass: the fourth fabric reading, the refused verify,
# the cleanup call's locale pin, and the advice for an unreadable session.
m=$(mutant d24 "$NDT" \
    'rc=1; fabric_left "the topo session" ;;' \
    'rc=1 ;;')
report "D24: a topo session still present is not counted as the fabric" "$m" \
       "🔴 a topo session still present keeps the record"

m=$(mutant d25 "$NDT" \
    '    sweep_out="$(LC_ALL=C LANGUAGE=C sudo -n "$LAB" cleanup 2>&1)"; sweep_rc=$?' \
    '    sweep_out="$(sudo -n "$LAB" cleanup 2>&1)"; sweep_rc=$?')
report "D25: cleanup runs in the operator's locale" "$m" \
       "and so does cleanup"

m=$(mutant d26 "$NDT" \
    '    CLEAN_FABRIC_LEFT="its own '"'"'verify clean'"'"' was refused because another '"'"'ndt down'"'"' is running, so nothing was measured"' \
    '    CLEAN_FABRIC_LEFT=""')
report "D26: a refused verify reads as one that found no fabric" "$m" \
       "🔴 a verify refused by another teardown keeps the record"

m=$(mutant d27 "$NDT" \
    '    if [[ "$1" == *"a topo session it could not read"* ]]; then' \
    '    if false; then')
report "D27: a kept record over an unreadable session gives no way to the call that would clear it" "$m" \
       "  and, for an unreadable session, to make the status call work and run down again"

m=$(mutant d28 "$NDT" \
    '        clear_up_target "'"'"'verify clean'"'"' found none of the fabric itself (no bmv2, Mininet or topo session)"' \
    '        clear_up_target')
report "D28: the clear does not say what it was decided on" "$m" \
       "  and on what"

m=$(mutant d29 "$NDT" \
    '    local why="$1" p rc=0
    for p in "$(up_target_file)" "$(app_knob_path)" "$(telemetry_knob_path)"; do' \
    '    local why="$1" p rc=0
    for p in "$(app_knob_path)" "$(telemetry_knob_path)"; do')
report "D29: a refused 'ndt up p4' leaves its own record over the one a down kept" "$m" \
       "  and one refused after it wrote the record (put back)"

m=$(mutant d30 "$NDT" \
    '    residue="$(ndt_port_residue all)"; local prc=$?' \
    '    residue="$(ndt_port_residue all)"; local prc=$?; [[ -n "$residue" ]] && fabric_left "a held port"')
report "D30: a port reading counts as the fabric" "$m" \
       "🔴 a port it cannot probe is not the fabric: the record is cleared"

m=$(mutant d31 "$NDT" \
    '    app_knob_clear "this checkout is being put back" || rc=1
    CLEAN_FABRIC_LEFT=""' \
    '    CLEAN_FABRIC_LEFT=""
    app_knob_clear "this checkout is being put back" || { rc=1; fabric_left "the app knob"; }')
report "D31: an app knob that cannot be removed counts as the fabric" "$m" \
       "🔴 an app knob it cannot remove is not the fabric: the record is cleared"

# --- section 33: what a rolled-back bring-up puts back ---------------------------------------------
#
# [Co-developed with claude code -- Adam]
# M195-M204 each take one piece of the put-back away or loosen it; N132/N133 are widenings (the
# put-back that does nothing, a rollback that drops the record it should keep); W17/W18 change no
# behaviour.
m=$(mutant m195 "$NDT" \
    '    refusal_put_back "$(app_knob_path)" "this bring-up was rolled back" || rc=1' \
    '    app_knob_clear "this bring-up was rolled back" || rc=1')
report "M195: the rollback clears the app knob instead of putting the earlier one back" "$m" \
       "🔴 33f the app knob is the one it was (package X, not cleared)"

m=$(mutant m196 "$NDT" \
    '    refusal_put_back "$(telemetry_knob_path)" "this bring-up was rolled back" || rc=1' \
    '    :')
report "M196: the rollback leaves the telemetry knob this run wrote" "$m" \
       "🔴 33f the telemetry knob is the one it was (link, not cooperative)"

m=$(mutant m197 "$NDT" \
    '        (( complete && ${#UP_REPLACED[@]} == 0 )) && before_ok=1' \
    '        before_ok=1')
report "M197: the old note is restored whatever the verdict of the rollback" "$m" \
       "🔴 33g the note is not 'down ... verified clean' over a half-torn lab"

m=$(mutant m198 "$NDT" \
    '    refusal_snapshot
    record_up_target ovs "$ovs_hosts" "$ovs_topo"; rut_rc=$?' \
    '    record_up_target ovs "$ovs_hosts" "$ovs_topo"; rut_rc=$?')
report "M198: up_ovs takes no snapshot, so its rollback has nothing to put back" "$m" \
       "🔴 33i the earlier record is back"

m=$(mutant m199 "$NDT" \
    '        refusal_put_back "$f" "$why" || rc=1' \
    '        :')
report "M199: a complete rollback keeps the record of the run that failed" "$m" \
       "🔴 33f up.target is the earlier record, not this run's"

m=$(mutant m200 "$NDT" \
    '    elif (( UP_FABRIC_GONE )); then' \
    '    elif false; then')
report "M200: the record is put back over a fabric this run replaced" "$m" \
       "🔴 33k the record is cleared, not put back over a fabric that is gone"

m=$(mutant m201 "$NDT" \
    '(( sess_rc == 0 )) && { up_replaced_fabric "${live_hosts:-?}"; info "stopping the existing topo session";' \
    '(( sess_rc == 0 )) && { info "stopping the existing topo session";')
report "M201: [1/3] stops a running fabric without recording that it replaced one" "$m" \
       "🔴 33k the note names what was replaced"

m=$(mutant m202 "$NDT" \
    '        up_left_running "bmv2 fabric ($live_hosts hosts)"' \
    '        :')
report "M202: a reused fabric is not recorded as left running" "$m" \
       "🔴 the reused fabric's ports do not make the rollback incomplete, and the line claims only what was done"

m=$(mutant m203 "$NDT" \
    '          && "$(claim_field owner)" == "$NDT_OWNER" && "$(claim_field note)" == "$REFUSAL_NOTE_WRITTEN" ]]; then
        # Everything the rollback stopped was this run'"'"'s, so a complete rollback that replaced nothing leaves' \
    '          && "$(claim_field owner)" == "$NDT_OWNER" ]]; then
        # Everything the rollback stopped was this run'"'"'s, so a complete rollback that replaced nothing leaves')
report "M203: the rollback rewrites a note somebody else rewrote during the run" "$m" \
       "🔴 33h2 a note somebody rewrote during the run is theirs"

m=$(mutant m204 "$NDT" \
    '    if [[ "$now" != "$after" ]]; then
        warn "$(short_repo_path "$p") left as it is: it changed after this run wrote it ($why)"' \
    '    if false; then
        warn "$(short_repo_path "$p") left as it is: it changed after this run wrote it ($why)"')
report "M204: a file somebody changed during the run is put back over" "$m" \
       "🔴 33h a telemetry knob changed during the run is left as it is"

m=$(mutant n132 "$NDT" \
    '    local complete="$1" why="$2" f rc=0 before_ok=0 text="" after now' \
    '    return 0
    local complete="$1" why="$2" f rc=0 before_ok=0 text="" after now')
report "N132 (widening): the record and note put-back is a no-op that returns 0" "$m" \
       "🔴 33f up.target is the earlier record, not this run's"

m=$(mutant n133 "$NDT" \
    '    if (( ! complete )); then
        [[ -e "$f" ]] && {' \
    '    if (( ! complete )); then rm -f "$f"
        [[ -e "$f" ]] && {')
report "N133 (widening): an INCOMPLETE rollback drops the record it should keep" "$m" \
       "  the record is kept on purpose"

m=$(mutant w17 "$NDT" \
    '    refusal_put_back "$(app_knob_path)" "this bring-up was rolled back" || rc=1
    refusal_put_back "$(telemetry_knob_path)" "this bring-up was rolled back" || rc=1' \
    '    refusal_put_back "$(telemetry_knob_path)" "this bring-up was rolled back" || rc=1
    refusal_put_back "$(app_knob_path)" "this bring-up was rolled back" || rc=1')
report_green "W17 (behaviour-preserving): the two knobs are put back in the other order" "$m" \
       "the files are independent of each other"

m=$(mutant w18 "$NDT" \
    'join_list() { local out="" x; for x in "$@"; do out+="${out:+, }$x"; done; printf '"'"'%s'"'"' "$out"; }' \
    'join_list() { local out="" x; for x in "$@"; do out="${out:+$out, }$x"; done; printf '"'"'%s'"'"' "$out"; }')
report_green "W18 (behaviour-preserving): the list joiner builds the string by assignment, not +=" "$m" \
       "the same comma-and-space join for every item, whatever it holds"

# --- section 33, the heartbeat: a daemon the previous run started is not this run's to stop ---
#
# [Co-developed with claude code -- Adam]
# M205-M207 each break one part of the ownership reading; N134 is the widening (the rollback never
# stops a heartbeat); W19/W20 change no behaviour.
m=$(mutant m205 "$NDT" \
    '    if [[ -n "$HB_BEFORE" ]]; then' \
    '    if false; then')
report "M205: the heartbeat stage is recorded whatever was running before" "$m" \
       "🔴 33a the rollback did not ask the helper to stop the heartbeat"

m=$(mutant m206 "$NDT" \
    '    [[ "${av[n-1]}" == daemon && "${av[n-2]##*/}" == heartbeat.py ]] || return 1' \
    '    :')
report "M206: any live process the pidfile names is taken for the daemon" "$m" \
       "33a2 a live process that is not the daemon: the stage is recorded, as before"

m=$(mutant m207 "$NDT" \
    '        pid="$(hb_report_pid)"' \
    '        pid=""')
report "M207: an unreadable pidfile is read as no heartbeat" "$m" \
       "33a3 an unreadable pidfile: the report names the daemon, and it is left running"

m=$(mutant n134 "$NDT" \
    '        up_started heartbeat
    fi' \
    '        :
    fi')
report "N134 (widening): the rollback never stops a heartbeat" "$m" \
       "33b a heartbeat this run started is in the stage list"

m=$(mutant w19 "$NDT" \
    ' -- a rollback leaves it as it is"' \
    ' -- the rollback does not stop it"')
report_green "W19 (behaviour-preserving): the tail of the left-running line reworded" "$m" \
       "the cells read the sentence up to the clause, not the clause"

m=$(mutant w20 "$NDT" \
    '    ticks="$(awk '"'"'{print $20}'"'"' <<<"$rest")"
    [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
    echo "$pid $ticks"' \
    '    ticks="$(cut -d" " -f20 <<<"$rest")"
    [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
    echo "$pid $ticks"')
report_green "W20 (behaviour-preserving): the start ticks read with cut instead of awk" "$m" \
       "field 20 either way"

# --- section 33, the stack: only what this run started is stopped ---------------------------
#
# [Co-developed with claude code -- Adam]
# M208-M216 each break one part of the ownership reading or what the rollback says about it; N135/N136
# are widenings (the snapshot records nothing; the rollback stops every component); W21/W22 change no
# behaviour.
m=$(mutant m208 "$NDT" \
    '                if (( ${#STACK_BEFORE[@]} )); then
                    if (( ${#STACK_STOPSET[@]} )); then' \
    '                if false; then
                    if (( ${#STACK_STOPSET[@]} )); then')
report "M208: the rollback brings the whole stack down whatever was running before" "$m" \
       "33c stack.sh was asked to stop the proxy, by name"

m=$(mutant m209 "$NDT" \
    '        elif [[ -n "$now" && "$now" == "$earlier" ]]; then' \
    '        elif false; then')
report "M209: a component that was running before and still is, is read as replaced" "$m" \
       "🔴 33c the kernel that was running before is still running"

m=$(mutant m210 "$NDT" \
    '            up_replaced "$name (was pid ${earlier%% *})"' \
    '            :')
report "M210: a replaced component is stopped but not named as replaced" "$m" \
       "🔴 33d the line says what was replaced and not restored, with the old pid"

m=$(mutant m211 "$NDT" \
    '            up_replaced "$name (was pid ${earlier%% *}, gone)"' \
    '            :')
report "M211: a component that was running before and is gone is not named" "$m" \
       "🔴 33n the line names the lost kernel with its old pid"

m=$(mutant m212 "$NDT" \
    '        elif [[ -n "$now" ]]; then
            STACK_STOPSET+=("$name")' \
    '        elif [[ -n "$now" ]]; then
            :')
report "M212: the new component that replaced a running one is left running" "$m" \
       "33d the new proxy is stopped by name"

m=$(mutant m213 "$NDT" \
    '                        deferred="$(stack_ports_of "${STACK_STOPSET[@]}")"' \
    '                        deferred=""')
report "M213: the ports of the components stopped by name are not read again" "$m" \
       "33c2 a port of what was stopped that is still held makes the rollback INCOMPLETE"

m=$(mutant m214 "$NDT" \
    '    if (( rc == 0 && left == 0 )) && (( ${#UP_LEFT[@]} + ${#UP_REPLACED[@]} )); then' \
    '    if false; then')
report "M214: a rollback that replaced something says the machine is back as it was" "$m" \
       "🔴 33d and never says the machine is back as it was"

m=$(mutant m215 "$NDT" \
    '        (( complete && ${#UP_REPLACED[@]} == 0 )) && before_ok=1' \
    '        (( complete )) && before_ok=1')
report "M215: the old note is put back although something was replaced" "$m" \
       "  33d the note says it too, instead of the old sentence"

m=$(mutant m216 "$NDT" \
    '    elif (( UP_FABRIC_GONE )); then' \
    '    elif (( ${#UP_REPLACED[@]} )); then')
report "M216: the record is cleared for any replaced component, not only a fabric" "$m" \
       "  33d the earlier record is back: only a replaced fabric clears it"

m=$(mutant m217 "$NDT" \
    '{ [[ -e "$pf" || -L "$pf" ]] && stack_pf_changed "$name"; }' \
    '{ [[ -e "$pf" || -L "$pf" ]]; }')
report "M217: a stale record that was there before is taken for this run's and cleared" "$m" \
       "🔴 33o a stale record from before is left as it was"

m=$(mutant n135 "$NDT" \
    '        id="$(stack_reg_id "$name")" && STACK_BEFORE+=("$name $id")' \
    '        id="$(stack_reg_id "$name")" && :')
report "N135 (widening): the snapshot records no component, so every rollback is a 'down'" "$m" \
       "33c stack.sh was asked to stop the proxy, by name"

m=$(mutant n136 "$NDT" \
    '    STACK_STOPSET=()
    for name in $STACK_COMPONENTS; do
        pf=' \
    '    STACK_STOPSET=($STACK_COMPONENTS)
    for name in $STACK_COMPONENTS; do
        pf=')
report "N136 (widening): every component is stopped, named or not" "$m" \
       "🔴 33c the kernel that was running before is still running"

m=$(mutant w21 "$NDT" \
    '                        [[ -n "$names" ]] && stopped="${stopped:+$stopped, }$names"' \
    '                        if [[ -n "$names" ]]; then stopped="${stopped:+$stopped, }$names"; fi')
report_green "W21 (behaviour-preserving): the stopped-names list written with an if" "$m" \
       "the same list either way"

m=$(mutant w22 "$NDT" \
    '                        info "stopping what this run started of the stack: ${STACK_STOPSET[*]}"' \
    '                        info "stopping the stack components this run started: ${STACK_STOPSET[*]}"')
report_green "W22 (behaviour-preserving): the line that names what is being stopped reworded" "$m" \
       "the cells read what stack.sh was asked, not this sentence"

# --- a running fabric is reused only when it was built from this run's inputs (section 34) -------------
#
# [Co-developed with claude code -- Adam]
# 🔴 EACH ONE PUTS BACK A WAY THE SAME COUNTS PASSED FOR THE SAME FABRIC. The identity is asked of
# stubs here (the real readings are tested in p4_proxy/tests); what these pin is what `up_p4` does
# with the answer, and where it asks.
m=$(mutant m218 "$NDT" \
    '            differ)
                reuse=0
' \
    '            differ)
                : 
')
report "M218: a fabric that differs is still reused" "$m" \
       "🔴 34b and it was NOT reused"

m=$(mutant m219 "$NDT" \
    '            *)
                reuse=0
                if [[ "${id_state#unknown }" == "there is no build record" ]]; then' \
    '            *)
                if [[ "${id_state#unknown }" == "there is no build record" ]]; then')
report "M219: a fabric whose build cannot be vouched for is reused (unknown read as match)" "$m" \
       "  34d and not reused"

m=$(mutant m220 "$NDT" \
    '            id_state="unknown it could not be worked out what this run would build the fabric from"' \
    '            id_state="match"')
report "M220: inputs that cannot be worked out are read as a match" "$m" \
       "🔴 34e inputs that cannot be worked out are not a match"

m=$(mutant m221 "$NDT" \
    '    for (( i = 0; i < ${#names[@]} && i < 4; i++ )); do' \
    '    for (( i = 0; i < ${#names[@]} && i < 99; i++ )); do')
report "M221: every component is named, however many" "$m" \
       "  34c four names and the count of the rest"

m=$(mutant m222 "$NDT" \
    '    (( ${#names[@]} > 4 )) && out+=" and $(( ${#names[@]} - 4 )) more"' \
    '    (( ${#names[@]} > 4 )) && out+=" and ${#names[@]} more"')
report "M222: the count of components left out counts the ones named" "$m" \
       "  34c four names and the count of the rest"

m=$(mutant m223 "$NDT" \
    '        want_id="$(fabric_identity_wanted "$app_dir" "$hosts" "$tel_word")"' \
    '        want_id="$(fabric_identity_wanted "$app_dir" "$hosts" auto)"')
report "M223: the run is compared as though it asked for the default telemetry word" "$m" \
       "  34f --telemetry link is the word the run is compared with"

m=$(mutant m224 "$NDT" \
    '    if (( reuse && ! tel_word_rc )); then
        local want_id id_state' \
    '    if (( ! tel_word_rc )); then
        local want_id id_state')
report "M224: the identity is read for a fabric the counts already rejected" "$m" \
       "🔴 34i and the identity was not asked for"

m=$(mutant m225 "$NDT" \
    '    export NDT_FABRIC_ID
' \
    '')
report "M225: the fabric id stays in ndt and never reaches stack.sh" "$m" \
       "🔴 34j a reused fabric's id reaches stack.sh"

m=$(mutant m226 "$NDT" \
    '    if [[ -z "$NDT_FABRIC_ID" && "$UP_P4_FABRIC" == fresh ]]; then' \
    '    if false; then')
report "M226: a fresh build reads the record once, before it can have been written" "$m" \
       "🔴 34j a record that appears just after the manifest is still read"

m=$(mutant m227 "$NDT" \
    '                if [[ "${id_state#unknown }" == "there is no build record" ]]; then' \
    '                if false; then')
report "M227: a fabric with no record is told it has a record that cannot be used" "$m" \
       "🔴 34d a fabric with no record of what it was built from is rebuilt"

m=$(mutant m228 "$NDT" \
    '$(fabric_identity_names "${id_state#differ }")' \
    '${id_state#differ }')
report "M228: the components are printed as the raw list, not as a sentence" "$m" \
       "  34b the line names the components that differ"

m=$(mutant m229 "$NDT" \
    '(( sess_rc == 0 )) && { up_replaced_fabric "${live_hosts:-?}"; info "stopping the existing topo session";' \
    '(( sess_rc == 0 )) && { info "stopping the existing topo session";')
report "M229: a rebuild over a running fabric does not record that the fabric was replaced" "$m" \
       "🔴 34k and the claim note says the old fabric was replaced and not restored"

# --- the order of the decision: above every write, below the stale-pipeline refusal (section 34) ---------
#
# [Co-developed with claude code -- Adam]
# Each ordering mistake is ONE mutation because the blocks are adjacent: the stale-pipeline refusal,
# then the identity decision, then the OVS and NTG guards, then the first write.
m=$(mutant m230 "$NDT" \
    '    if (( reuse )) && stale_pipeline; then
        # Reusing here would measure the old pipeline while every readout says the new one.
        err "the fabric predates the current build of ndtwin_switch.json."
        err "bmv2 loads the pipeline at exec time and never reloads, so these $n switches"
        err "are NOT running $(rate_label "$rate"). take it down and back up:  ndt down && ndt up"
        err "up.target, the knobs and the claim note were not touched."
        return 1
    fi
    # [Co-developed with claude code -- Adam]
    # 🔴 A FABRIC LEFT BY AN `ndt up` THAT DID NOT FINISH IS NOT REUSED, whatever it was built from: nothing verified
    # it, and what that bring-up had started when it died is not known (up_unfinished_look). It is rebuilt, through the
    # same path as a fabric whose inputs differ, and the line says why. Read here, above every write, beside the
    # stale-pipeline refusal and the identity decision. A record with no fabric running changes nothing: `reuse` is
    # already 0 then, and the record goes when a bring-up verifies.
    if (( reuse )) && up_unfinished_look; then
        reuse=0
        info "$(up_unfinished_what), and the lab has not been verified since: that fabric is rebuilt, not reused"
    fi
    # [Co-developed with claude code -- Adam]
    # 🔴 THE SAME COUNTS DO NOT MAKE THE SAME FABRIC. A fabric is kept only when it was built from the
    # inputs this run would build it from -- the model, package.json, each switch'"'"'s program and
    # table entries, the links the package shapes, the telemetry source each switch resolves to, the
    # bmv2 binary -- and the process that built it is still the one running it. Otherwise it is
    # rebuilt, and the line says what differs. This is read above every write below, so a refusal
    # that follows still leaves the files as they were. The stale-pipeline refusal above comes first and
    # stays: it is documented, and it is a refusal where this is a rebuild.
    if (( reuse && ! tel_word_rc )); then
        local want_id id_state
        want_id="$(fabric_identity_wanted "$app_dir" "$hosts" "$tel_word")"
        if [[ -z "$want_id" ]]; then
            id_state="unknown it could not be worked out what this run would build the fabric from"
        else
            id_state="$(fabric_identity_running "$want_id")"
        fi
        case "${id_state%% *}" in
            match) ;;
            differ)
                reuse=0
                info "the running fabric was built from different inputs ($(fabric_identity_names "${id_state#differ }")); rebuilding it" ;;
            *)
                reuse=0
                if [[ "${id_state#unknown }" == "there is no build record" ]]; then
                    info "the running fabric'"'"'s build record is missing (built before this check existed, or by hand); rebuilding it"
                else
                    info "the running fabric'"'"'s build record cannot be used (${id_state#unknown }); rebuilding it"
                fi ;;
        esac
    fi
' \
    '    # [Co-developed with claude code -- Adam]
    # 🔴 A FABRIC LEFT BY AN `ndt up` THAT DID NOT FINISH IS NOT REUSED, whatever it was built from: nothing verified
    # it, and what that bring-up had started when it died is not known (up_unfinished_look). It is rebuilt, through the
    # same path as a fabric whose inputs differ, and the line says why. Read here, above every write, beside the
    # stale-pipeline refusal and the identity decision. A record with no fabric running changes nothing: `reuse` is
    # already 0 then, and the record goes when a bring-up verifies.
    if (( reuse )) && up_unfinished_look; then
        reuse=0
        info "$(up_unfinished_what), and the lab has not been verified since: that fabric is rebuilt, not reused"
    fi
    # [Co-developed with claude code -- Adam]
    # 🔴 THE SAME COUNTS DO NOT MAKE THE SAME FABRIC. A fabric is kept only when it was built from the
    # inputs this run would build it from -- the model, package.json, each switch'"'"'s program and
    # table entries, the links the package shapes, the telemetry source each switch resolves to, the
    # bmv2 binary -- and the process that built it is still the one running it. Otherwise it is
    # rebuilt, and the line says what differs. This is read above every write below, so a refusal
    # that follows still leaves the files as they were. The stale-pipeline refusal above comes first and
    # stays: it is documented, and it is a refusal where this is a rebuild.
    if (( reuse && ! tel_word_rc )); then
        local want_id id_state
        want_id="$(fabric_identity_wanted "$app_dir" "$hosts" "$tel_word")"
        if [[ -z "$want_id" ]]; then
            id_state="unknown it could not be worked out what this run would build the fabric from"
        else
            id_state="$(fabric_identity_running "$want_id")"
        fi
        case "${id_state%% *}" in
            match) ;;
            differ)
                reuse=0
                info "the running fabric was built from different inputs ($(fabric_identity_names "${id_state#differ }")); rebuilding it" ;;
            *)
                reuse=0
                if [[ "${id_state#unknown }" == "there is no build record" ]]; then
                    info "the running fabric'"'"'s build record is missing (built before this check existed, or by hand); rebuilding it"
                else
                    info "the running fabric'"'"'s build record cannot be used (${id_state#unknown }); rebuilding it"
                fi ;;
        esac
    fi
    if (( reuse )) && stale_pipeline; then
        # Reusing here would measure the old pipeline while every readout says the new one.
        err "the fabric predates the current build of ndtwin_switch.json."
        err "bmv2 loads the pipeline at exec time and never reloads, so these $n switches"
        err "are NOT running $(rate_label "$rate"). take it down and back up:  ndt down && ndt up"
        err "up.target, the knobs and the claim note were not touched."
        return 1
    fi
')
report "M230: the identity is decided before the stale-pipeline refusal" "$m" \
       "🔴 34h a fabric older than the compiled pipeline is still refused"

m=$(mutant m231 "$NDT" \
    '    # [Co-developed with claude code -- Adam]
    # 🔴 THE SAME COUNTS DO NOT MAKE THE SAME FABRIC. A fabric is kept only when it was built from the
    # inputs this run would build it from -- the model, package.json, each switch'"'"'s program and
    # table entries, the links the package shapes, the telemetry source each switch resolves to, the
    # bmv2 binary -- and the process that built it is still the one running it. Otherwise it is
    # rebuilt, and the line says what differs. This is read above every write below, so a refusal
    # that follows still leaves the files as they were. The stale-pipeline refusal above comes first and
    # stays: it is documented, and it is a refusal where this is a rebuild.
    if (( reuse && ! tel_word_rc )); then
        local want_id id_state
        want_id="$(fabric_identity_wanted "$app_dir" "$hosts" "$tel_word")"
        if [[ -z "$want_id" ]]; then
            id_state="unknown it could not be worked out what this run would build the fabric from"
        else
            id_state="$(fabric_identity_running "$want_id")"
        fi
        case "${id_state%% *}" in
            match) ;;
            differ)
                reuse=0
                info "the running fabric was built from different inputs ($(fabric_identity_names "${id_state#differ }")); rebuilding it" ;;
            *)
                reuse=0
                if [[ "${id_state#unknown }" == "there is no build record" ]]; then
                    info "the running fabric'"'"'s build record is missing (built before this check existed, or by hand); rebuilding it"
                else
                    info "the running fabric'"'"'s build record cannot be used (${id_state#unknown }); rebuilding it"
                fi ;;
        esac
    fi
    # Refuse a live OVS fabric instead of quietly removing it. `up_ovs` already refuses the
    # mirror case ("starting Ryu under a live Mininet is the /stats/flow wedge trigger");
    # this side used to be a bare `topo-stop >/dev/null 2>&1`, so `ndt up` on a running OVS
    # fabric destroyed it with no message at all. The asymmetry was invisible because all
    # three ndtwin-lab verbs name their tmux session `topo`, so the session'"'"'s existence
    # cannot tell the two planes apart -- the bridges can.
    # The whole decision, including "could not tell", lives in guard_no_live_ovs so a test
    # can call it on its own.
    # [Co-developed with claude code -- Adam] Its rc is carried out: 1 for an OVS fabric it found, 5 for
    # one it could not look for.
    (( reuse )) || guard_no_live_ovs || { local grc=$?; err "up.target, the knobs and the claim note were not touched."; return "$grc"; }
    # [Co-developed with claude code -- Adam] A fabric this run builds is handed to NTG; a mode NTG
    # refuses takes that fabric down seconds after [3/3] passes (see ntg_up_refusal).
    (( reuse )) || ntg_up_refusal || return $?
' \
    '    # Refuse a live OVS fabric instead of quietly removing it. `up_ovs` already refuses the
    # mirror case ("starting Ryu under a live Mininet is the /stats/flow wedge trigger");
    # this side used to be a bare `topo-stop >/dev/null 2>&1`, so `ndt up` on a running OVS
    # fabric destroyed it with no message at all. The asymmetry was invisible because all
    # three ndtwin-lab verbs name their tmux session `topo`, so the session'"'"'s existence
    # cannot tell the two planes apart -- the bridges can.
    # The whole decision, including "could not tell", lives in guard_no_live_ovs so a test
    # can call it on its own.
    # [Co-developed with claude code -- Adam] Its rc is carried out: 1 for an OVS fabric it found, 5 for
    # one it could not look for.
    (( reuse )) || guard_no_live_ovs || { local grc=$?; err "up.target, the knobs and the claim note were not touched."; return "$grc"; }
    # [Co-developed with claude code -- Adam] A fabric this run builds is handed to NTG; a mode NTG
    # refuses takes that fabric down seconds after [3/3] passes (see ntg_up_refusal).
    (( reuse )) || ntg_up_refusal || return $?
    # [Co-developed with claude code -- Adam]
    # 🔴 THE SAME COUNTS DO NOT MAKE THE SAME FABRIC. A fabric is kept only when it was built from the
    # inputs this run would build it from -- the model, package.json, each switch'"'"'s program and
    # table entries, the links the package shapes, the telemetry source each switch resolves to, the
    # bmv2 binary -- and the process that built it is still the one running it. Otherwise it is
    # rebuilt, and the line says what differs. This is read above every write below, so a refusal
    # that follows still leaves the files as they were. The stale-pipeline refusal above comes first and
    # stays: it is documented, and it is a refusal where this is a rebuild.
    if (( reuse && ! tel_word_rc )); then
        local want_id id_state
        want_id="$(fabric_identity_wanted "$app_dir" "$hosts" "$tel_word")"
        if [[ -z "$want_id" ]]; then
            id_state="unknown it could not be worked out what this run would build the fabric from"
        else
            id_state="$(fabric_identity_running "$want_id")"
        fi
        case "${id_state%% *}" in
            match) ;;
            differ)
                reuse=0
                info "the running fabric was built from different inputs ($(fabric_identity_names "${id_state#differ }")); rebuilding it" ;;
            *)
                reuse=0
                if [[ "${id_state#unknown }" == "there is no build record" ]]; then
                    info "the running fabric'"'"'s build record is missing (built before this check existed, or by hand); rebuilding it"
                else
                    info "the running fabric'"'"'s build record cannot be used (${id_state#unknown }); rebuilding it"
                fi ;;
        esac
    fi
')
report "M231: the identity is decided after the OVS and NTG guards, so a rebuild skips them" "$m" \
       "🔴 34g a rebuild that a guard then refuses answers 5"

# --- the shell side of the fabric record, run for real (section 35), and an id that cannot be read (34l) ----
#
# [Co-developed with claude code -- Adam]
# Section 35 sources ndt with REPO at a fixture tree and asks its own functions about a record the
# topology script's writer made, so each of these puts back one way the glue between the shell and
# the two Python modules can be wrong while every stubbed section stays green.
m=$(mutant m232 "$NDT" \
    '    print("differ " + ",".join(detail))' \
    '    print("match")')
report "M232: a record that differs is reported as a match" "$m" \
       "🔴 35c an entries file edited in place is named"

m=$(mutant m233 "$NDT" \
    'sys.argv[2] or None, int(sys.argv[3]), sys.argv[4], binary_override=sys.argv[5],' \
    'sys.argv[2] or None, int(sys.argv[3]), "auto", binary_override=sys.argv[5],')
report "M233: the telemetry word the run asked for is not what it is compared with" "$m" \
       "🔴 35b the same inputs match the running fabric"

m=$(mutant m234 "$NDT" \
    ''"'"' "$REPO" "$1" "$FABRIC_RECORD" 2>/dev/null || echo "unknown the build record could not be read"' \
    ''"'"' "$REPO" "$1" /tmp/ndtwin_p4_fabric.json 2>/dev/null || echo "unknown the build record could not be read"')
report "M234: the running fabric is compared with the machine's record, not the one asked for" "$m" \
       "🔴 35b the same inputs match the running fabric"

m=$(mutant m235 "$NDT" \
    'bmv2_binary() {
    python3 -c '"'"'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "p4_proxy", "mininet"))
import app_package
print(app_package.bmv2_binary_named(os.path.join(sys.argv[1], "p4_proxy", "mininet", "bmv2_binary_override")))
'"'"' "$REPO" 2>/dev/null || echo "simple_switch_grpc (stock, PATH)"
}
' \
    'bmv2_binary() {
    local f="$REPO/p4_proxy/mininet/bmv2_binary_override" line
    [[ -f "$f" ]] || { echo "simple_switch_grpc (stock, PATH)"; return; }
    while read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        echo "$line"; return
    done < "$f"
    echo "simple_switch_grpc (stock, PATH)"
}
')
report "M235: bmv2_binary reads the override with its own loop again (a last line with no newline is lost)" "$m" \
       "🔴 35a an override whose last line has no newline names its binary"

m=$(mutant m236 "$NDT" \
    ''"'"' "$REPO" "$FABRIC_RECORD" 2>/dev/null' \
    ''"'"' "$REPO" /tmp/ndtwin_p4_fabric.json 2>/dev/null')
report "M236: the fabric's id is read from the machine's record, not the one asked for" "$m" \
       "🔴 35b the fabric's id is <digest>:<nonce>"

m=$(mutant m237 "$NDT" \
    '            NDT_FABRIC_ID="unrecorded:$(date +%s%N)"' \
    '            NDT_FABRIC_ID=""')
report "M237: a fresh build whose record cannot be read hands stack.sh an empty id" "$m" \
       "🔴 34l stack.sh is handed a one-off id, never an empty one"

m=$(mutant m238 "$NDT" \
    '            info "the new fabric'"'"'s build record could not be read; the proxy and the kernel will be restarted over it"' \
    '            :')
report "M238: a fresh build whose record cannot be read says nothing" "$m" \
       "🔴 34l the line says the record could not be read and what follows"

m=$(mutant m239 "$NDT" \
    '    if [[ -z "$NDT_FABRIC_ID" && "$UP_P4_FABRIC" == fresh ]]; then' \
    '    if [[ -z "$NDT_FABRIC_ID" ]]; then')
report "M239: a reused fabric whose id cannot be read is restarted over as well" "$m" \
       "  34l a reused fabric says nothing about an unreadable id"

m=$(mutant m240 "$NDT" \
    '    print("unknown " + detail)' \
    '    print("match")')
report "M240: a record that cannot be trusted is taken for a match" "$m" \
       "🔴 35d"

m=$(mutant m241 "$NDT" \
    'unrecorded:$(date +%s%N)' \
    'unrecorded:0')
report "M241: the one-off id is the same every time" "$m" \
       "  34l and it is not the same one-off id twice"

m=$(mutant w23 "$NDT" \
    '            match) ;;' \
    '            match) : ;;')
report_green "W23 (behaviour-preserving): the match arm written with a no-op" "$m" \
       "the arm does nothing either way"

m=$(mutant w24 "$NDT" \
    '        for fid_try in 1 2 3 4 5; do' \
    '        for fid_try in 1 2 3 4 5 6; do')
report_green "W24 (behaviour-preserving): the fresh build asks for the record once more" "$m" \
       "the cells read the id, not how many times it was asked for"

# --- one lab-changing verb at a time per checkout (section 31) ----------------------------------

# A bring-up that takes no marker: the second one runs over the first, which is the measured collision.
m=$(mutant m242 "$NDT" \
    '    run_take up "${NDT_RUN_ARGV:-ndt up}" || return $?' \
    '    :')
report "M242: a bring-up takes no marker, so a second one is not refused" "$m" \
       "🔴 31a a live 'ndt up' marker refuses"

# Staleness by kill -0 alone: a live pid that is another process now (the number was handed on) is
# read as the bring-up that wrote the marker.
m=$(mutant m243 "$NDT" \
    '        if [[ "$ticks" != "$RM_START" ]]; then' \
    '        if false; then')
report "M243: a marker is stale only when its pid is gone" "$m" \
       "🔴 31b a LIVE pid with another start time"

# The marker is released only when the bring-up succeeded: a failed one keeps the next caller out.
m=$(mutant m244 "$NDT" \
    '    run_leave up "$prev"' \
    '    (( rc == 0 )) && run_leave up "$prev"')
report "M244: the marker is released only on success" "$m" \
       "🔴 31d after rc 1 (the rollback path) the marker is gone as soon as the verb returns"

# The check and the write without the lock: two verbs started in the same instant both pass.
m=$(mutant m245 "$NDT" \
    '    lk="$(run_lock_file)"
    mkdir -p "$(dirname "$lk")" 2>/dev/null' \
    '    lk="$(run_lock_file)"
    mkdir -p "$(dirname "$lk")" 2>/dev/null
    "$@"; return $?')
report "M245: no flock around the check-then-write" "$m" \
       "🔴 31e a bring-up that cannot get the lock is refused with 5"

# The teardown marker's check-then-write was unlocked before this change; put it back.
m=$(mutant m246 "$NDT" \
    'mark_teardown_start() { run_with_wait with_run_lock mark_teardown_start_locked; }' \
    'mark_teardown_start() { run_with_wait mark_teardown_start_locked; }')
report "M246: the teardown's check-then-write is outside the lock" "$m" \
       "🔴 31e the teardown's check-then-write is under the same lock"

# The take checks and refuses but never writes: nobody can see the running bring-up.
m=$(mutant m247 "$NDT" \
    '    run_marker_write "$verb" "$argv"' \
    '    :')
report "M247: the marker is checked for and never written" "$m" \
       "🔴 31d the marker named this process while it ran (pid)"

# The owner never moves the phase: every refusal says "start".
m=$(mutant m248 "$NDT" \
    '    if sed "s|^phase=.*|phase=$2|" "$f" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$f" 2>/dev/null; fi' \
    '    :')
report "M248: the marker's phase is never rewritten" "$m" \
       "🔴 31d the phase is rewritten at each step"

# `ndt clean` inside `ndt down` takes a marker of its own: the re-entrancy test is gone.
m=$(mutant m249 "$NDT" \
    '    if [[ -z "$tif" || "${tif%% *}" != "$$" ]]; then' \
    '    if true; then')
report "M249: the clean inside a teardown takes its own marker" "$m" \
       "🔴 31c the clean inside it takes no marker of its own"

# `ndt down` over a running bring-up: the old marker could not see one.
m=$(mutant m250 "$NDT" \
    '    RUN_REMOVE_STALE=1 run_check_conflicts "tear down" up clean || return 1' \
    '    :')
report "M250: a teardown does not look for a running bring-up or clean" "$m" \
       "🔴 31c 'ndt down' beside a live 'ndt up' is refused with 5"

# A bring-up and a standalone clean no longer see each other's marker.
m=$(mutant m251 "$NDT" \
    '    RUN_REMOVE_STALE=1 run_check_conflicts "$action" down up clean || return 5' \
    '    RUN_REMOVE_STALE=1 run_check_conflicts "$action" down up || return 5')
report "M251: a running clean does not hold a bring-up off" "$m" \
       "🔴 31c 'ndt up' beside a live 'ndt clean' is refused with 5"

# The refusal is a dirty reading (1), not a guard's (5): nothing was built, and a script reads the difference.
m=$(mutant m252 "$NDT" \
    '    RUN_REMOVE_STALE=1 run_check_conflicts "$action" down up clean || return 5' \
    '    RUN_REMOVE_STALE=1 run_check_conflicts "$action" down up clean || return 1')
report "M252: the second caller's refusal is rc 1" "$m" \
       "🔴 31a a live 'ndt up' marker refuses"

# The kill line always names a group, though the running verb leads none: it would signal an unrelated one.
m=$(mutant m253 "$NDT" \
    '    if [[ "$RM_PGID" == "$RM_PID" ]]; then stop="kill -TERM -- -$RM_PID"; else stop="kill -TERM $RM_PID"; fi' \
    '    stop="kill -TERM -- -$RM_PID"')
report "M253: the kill line always names a process group" "$m" \
       "  31a and no group form when the pid leads no group of its own"

m=$(mutant m254 "$NDT" \
    '    if [[ "$RM_PGID" == "$RM_PID" ]]; then stop="kill -TERM -- -$RM_PID"; else stop="kill -TERM $RM_PID"; fi' \
    '    stop="kill -TERM $RM_PID"')
report "M254: the kill line never names a process group" "$m" \
       "  31a the group form when the marker's pgid is its pid"

# A stale marker of another verb is reported and left in place.
m=$(mutant m255 "$NDT" \
    '        warn "  that '"'"'ndt clean'"'"' ended without finishing."
    fi
    rm -f "$f"' \
    '        warn "  that '"'"'ndt clean'"'"' ended without finishing."
    fi')
report "M255: a stale marker is named and left in place" "$m" \
       "🔴 31b and it is gone"

# `ndt apps <name>` and `ndt ntg <mode>` stop looking at the markers.
m=$(mutant m256 "$NDT" \
    '            run_check_only "start an app" up down || return 1
            local a; for a in "$@"; do app_start "$a"; done' \
    '            local a; for a in "$@"; do app_start "$a"; done')
report "M256: an app is started under a running bring-up" "$m" \
       "🔴 31i 'ndt apps <name>' under a live bring-up is refused with 1"

m=$(mutant m257 "$NDT" \
    '    if [[ -n "$want" ]]; then run_check_only "edit NTG'"'"'s mode" up down || return 1; fi' \
    '    :')
report "M257: NTG's mode is edited under a running bring-up" "$m" \
       "🔴 31i 'ndt ntg cli' under a live bring-up is refused with 1"

# A subshell shares the owner's $$ and would take the marker with it.
m=$(mutant m258 "$NDT" \
    '    [[ "${BASHPID:-$$}" == "$$" && -f "$f" ]] || return 0
    [[ "$(run_marker_field "$f" pid)" == "$$" ]] && rm -f "$f"' \
    '    [[ -f "$f" ]] || return 0
    [[ "$(run_marker_field "$f" pid)" == "$$" ]] && rm -f "$f"')
report "M258: a subshell of the owner removes the owner's marker" "$m" \
       "🔴 31j a subshell copy of the owner"

# Release by anyone: the marker of a verb that is still running goes away.
m=$(mutant m259 "$NDT" \
    '    [[ "${BASHPID:-$$}" == "$$" && -f "$f" ]] || return 0
    [[ "$(run_marker_field "$f" pid)" == "$$" ]] && rm -f "$f"' \
    '    [[ "${BASHPID:-$$}" == "$$" && -f "$f" ]] || return 0
    rm -f "$f"')
report "M259: a process removes a marker that is not its own" "$m" \
       "🔴 31j a process that does not own a marker"

# NDT_RUN_WAIT is read and never waited for.
m=$(mutant m260 "$NDT" \
    '        (( waited >= w )) && return "$rc"' \
    '        return "$rc"')
report "M260: NDT_RUN_WAIT refuses at once whatever it says" "$m" \
       "  31g after one line saying it is waiting, and for how long"

# Without flock the marker is written unlocked and nothing says so.
m=$(mutant m261 "$NDT" \
    '        warn "flock is not on PATH -- this verb'"'"'s marker is checked and written WITHOUT a lock, so two"' \
    '        :')
report "M261: a missing flock is not said" "$m" \
       "🔴 31h but it is said, loudly"

# The lock timeout is a plain failure, not a refusal.
m=$(mutant m262 "$NDT" \
    '            exit 5
        fi
        "$@"
    ) 9>>"$lk"' \
    '            exit 1
        fi
        "$@"
    ) 9>>"$lk"')
report "M262: giving up on the lock is rc 1" "$m" \
       "🔴 31e a bring-up that cannot get the lock is refused with 5"

# No EXIT trap: a bring-up that leaves the shell without returning keeps its marker.
m=$(mutant m263 "$NDT" \
    "    trap 'up_exit_unverified; run_release up' EXIT" \
    '    :')
report "M263: a bring-up that exits the shell leaves its marker" "$m" \
       "🔴 31d the marker is still gone: the EXIT trap released it"

# --- the wait for a teardown, the kill line, the verbs that only look ------------------------------------

# `ndt down` takes the lock but never waits: the help says it does.
m=$(mutant m264 "$NDT" \
    'mark_teardown_start() { run_with_wait with_run_lock mark_teardown_start_locked; }' \
    'mark_teardown_start() { with_run_lock mark_teardown_start_locked; }')
report "M264: 'ndt down' does not wait for NDT_RUN_WAIT" "$m" \
       "🔴 31g and it waited: the one line says for how long"

# The verbs that only look offer a wait they do not have.
m=$(mutant m265 "$NDT" \
    '        "start an app"|"edit NTG'"'"'s mode") err "  wait for it to finish, then run this again." ;;' \
    '        "nothing") err "  wait for it to finish, then run this again." ;;')
report "M265: an app start's refusal offers NDT_RUN_WAIT" "$m" \
       "🔴 31i the apps refusal does not offer NDT_RUN_WAIT"

# A check-only verb deletes a stale teardown marker without holding the lock.
m=$(mutant m266 "$NDT" \
    '            else tif="$(teardown_in_flight_peek)" || continue; fi' \
    '            else tif="$(teardown_in_flight)" || continue; fi')
report "M266: a verb that only looks removes a stale teardown marker" "$m" \
       "🔴 31i 'ndt apps <name>' leaves a stale teardown marker where it was"

# A waiting teardown prints its refusal on every poll.
m=$(mutant m267 "$NDT" \
    '            [[ -n "${RUN_QUIET:-}" ]] && return 1   # a wait in progress: only the last attempt says it' \
    '            :')
report "M267: a waiting teardown prints the refusal on every poll" "$m" \
       "  31g and one refusal"

# The kill line offers INT, which alone does not end a verb.
m=$(mutant m268 "$NDT" \
    '    if [[ "$RM_PGID" == "$RM_PID" ]]; then stop="kill -TERM -- -$RM_PID"; else stop="kill -TERM $RM_PID"; fi' \
    '    if [[ "$RM_PGID" == "$RM_PID" ]]; then stop="kill -INT -- -$RM_PID"; else stop="kill -INT $RM_PID"; fi')
report "M268: the kill line offers INT" "$m" \
       "  31a and never INT"

# --- a clean that waits, a bounded wait, per-call switches, a peek that only reads --------------------------

# A standalone clean answers a running teardown at once: the help says it waits.
m=$(mutant m269 "$NDT" \
    '    run_with_wait clean_wait_teardown' \
    '    :')
report "M269: a standalone clean does not wait for a running teardown" "$m" \
       "🔴 31g and it waited, as the help says"

# "08" is read as an invalid octal number: every test of the bound errors out and the wait never ends.
m=$(mutant m270 "$NDT" \
    '    if [[ "$w" =~ ^[0-9]+$ ]]; then w=$((10#$w)); else w=0; fi   # 10#: "08" is eight seconds, not an octal error' \
    '    if [[ "$w" =~ ^[0-9]+$ ]]; then :; else w=0; fi')
report "M270: a wait with a leading zero has no bound" "$m" \
       "🔴 31g NDT_RUN_WAIT=08 beside a live bring-up ends: refused with 5"

# The two per-call switches are taken from the caller's environment.
m=$(mutant m271 "$NDT" \
    'RUN_REMOVE_STALE=""; RUN_QUIET=""' \
    ':')
report "M271: RUN_REMOVE_STALE and RUN_QUIET are read from the environment" "$m" \
       "🔴 31i an exported RUN_REMOVE_STALE does not let 'ndt apps' remove a stale teardown marker"

# The peek tests existence, not that it is a regular file: a FIFO at the marker's path blocks the reader.
m=$(mutant m272 "$NDT" \
    '    [[ -f "$f" ]] || return 1
    pid="$(sed -n '"'"'s/^pid=//p'"'"' "$f" | head -1)"
    at="$(sed -n '"'"'s/^at=//p'"'"' "$f" | head -1)"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1' \
    '    [[ -e "$f" ]] || return 1
    pid="$(sed -n '"'"'s/^pid=//p'"'"' "$f" | head -1)"
    at="$(sed -n '"'"'s/^at=//p'"'"' "$f" | head -1)"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1')
report "M272: the peek reads whatever is at the marker's path" "$m" \
       "🔴 31i a FIFO at down.inflight does not hang 'ndt apps'"

# --- the clean's own pre-check and the wait's own-marker test ---------------------------------------------

# The clean's pre-check removes a stale teardown marker itself, without holding the lock.
m=$(mutant m273 "$NDT" \
    '    if tif="$(teardown_in_flight_peek)" && [[ "${tif%% *}" != "$$" ]]; then' \
    '    if tif="$(teardown_in_flight)" && [[ "${tif%% *}" != "$$" ]]; then')
report "M273: a standalone clean removes a stale teardown marker without the lock" "$m" \
       "🔴 31e and it left the stale teardown marker for a lock holder"

# The wait takes a teardown's own marker for somebody else's: the teardown waits for its own verify clean.
m=$(mutant m274 "$NDT" \
    '    [[ "${t%% *}" == "$$" ]] && return 0' \
    '    :')
report "M274: a teardown's own verify clean waits for the teardown's own marker" "$m" \
       "🔴 31g 'ndt down' with NDT_RUN_WAIT does not wait for its own verify clean"

# --- section 32: a signal to 'ndt up' (INT, TERM, HUP) -------------------------------------------------

# Ctrl-C ends the bring-up where it stands, as it did before the handler.
m=$(mutant m275 "$NDT" \
    '    trap '"'"'up_on_signal INT 130'"'"' INT
' \
    '    :
')
report "M275: a bring-up holds no INT trap" "$m" \
       "🔴 32a the signal and where it came"

# Every signal answers 130 (bash's own code for INT): TERM and HUP are not told apart.
m=$(mutant m276 "$NDT" \
    '    trap '"'"'up_on_signal TERM 143'"'"' TERM
' \
    '    trap '"'"'up_on_signal TERM 130'"'"' TERM
')
report "M276: TERM ends the bring-up with 130" "$m" \
       "🔴 32b SIGTERM ends the bring-up with 143"

# ...and HUP.
m=$(mutant m277 "$NDT" \
    '    trap '"'"'up_on_signal HUP 129'"'"' HUP
' \
    '    trap '"'"'up_on_signal HUP 130'"'"' HUP
')
report "M277: HUP ends the bring-up with 130" "$m" \
       "🔴 32b SIGHUP ends the bring-up with 129"

# The handler reports the signal and exits: what was started stays up.
m=$(mutant m278 "$NDT" \
    '    rollback_up "interrupted by SIG$sig at $phase" || true
' \
    '    true
')
report "M278: the handler does not roll back" "$m" \
       "🔴 32a the rollback ran, over what was started"

# A signal to ndt's pid leaves the background stack.sh running: it goes on to start a kernel.
m=$(mutant m279 "$NDT" \
    '    up_bg_stack_stop
    rollback_up' \
    '    rollback_up')
report "M279: the OVS plane's background stack.sh is not stopped" "$m" \
       "🔴 32f and it did not go on to start a kernel when its prompt ended"

# The subshell that launched stack.sh dies and stack.sh, its child, does not.
m=$(mutant m280 "$NDT" \
    '            for k in ${PROC_KIDS[@]+"${PROC_KIDS[@]}"} "$pid"; do
' \
    '            for k in "$pid"; do
')
report "M280: only the subshell is stopped, not what runs under it" "$m" \
       "🔴 32f and it did not go on to start a kernel when its prompt ended"

# The handler names no step: every signal arrives at 'start'.
m=$(mutant m281 "$NDT" \
    '    RUN_PHASE="$1"
' \
    '    :
')
report "M281: the step a signal arrived at is not remembered" "$m" \
       "🔴 32a the signal and where it came"

# A second signal starts a second rollback inside the first instead of being noted.
m=$(mutant m282 "$NDT" \
    '    UP_ROLLING_BACK=1; RUN_PHASE=rollback; UP_RB_AT=${#UP_STARTED[@]}
' \
    '    RUN_PHASE=rollback; UP_RB_AT=${#UP_STARTED[@]}
')
report "M282: a rollback does not note that it is running" "$m" \
       "🔴 32e the second signal is said, and that the rollback goes on"

# A rollback that cannot be stopped from the keyboard.
m=$(mutant m283 "$NDT" \
    '        (( UP_SIG_COUNT >= 3 )) && up_abandon_rollback "$sig" "$code"
' \
    '        (( UP_SIG_COUNT >= 99 )) && up_abandon_rollback "$sig" "$code"
')
report "M283: the third signal does not abandon the rollback" "$m" \
       "🔴 32e2 the rollback is abandoned at the stage it was in, naming what is not undone"

# The note goes on saying the lab is in use, with no word of the abandoned rollback.
m=$(mutant m284 "$NDT" \
    '    up_note_rewrite "$note" || true
' \
    '    :
')
report "M284: an abandoned rollback leaves the claim note as it was" "$m" \
       "🔴 32e2 the note says so, and what to run"

# The stages left are not listed.
m=$(mutant m285 "$NDT" \
    '    for (( j = (UP_RB_AT < n ? UP_RB_AT : n) - 1; j >= 0; j-- )); do left+="${left:+, }${UP_STARTED[$j]}"; done
' \
    '    for (( j = -1; j >= 0; j-- )); do left+="${left:+, }${UP_STARTED[$j]}"; done
')
report "M285: an abandoned rollback names nothing as not undone" "$m" \
       "🔴 32e2 the rollback is abandoned at the stage it was in, naming what is not undone"

# The note gives no sign that nothing verified the lab.
m=$(mutant m286 "$NDT" \
    '        up_note_rewrite "$CLAIM_NOTE_UP_TEXT (interrupted during verify, not verified)" || true
' \
    '        :
')
report "M286: a bring-up interrupted at verify leaves the note as it was" "$m" \
       "🔴 32d the claim note says what is true"

# The lab is left up, and the run is silent about it.
m=$(mutant m287 "$NDT" \
    '        say "up, ${R}NOT verified${N} -- interrupted during $phase"
' \
    '        :
')
report "M287: a bring-up interrupted at verify does not say it was not verified" "$m" \
       "🔴 32d it says the lab is up and was not verified"

# Another verb reading the marker sees the step the bring-up was at before it failed.
m=$(mutant m288 "$NDT" \
    '    run_phase up rollback
' \
    '    :
')
report "M288: a rollback does not move the marker's phase" "$m" \
       "  32e3 the marker says the bring-up is rolling back"

# A shell that ran 'ndt up' keeps rolling back for the rest of its life.
m=$(mutant m289 "$NDT" \
    '    trap - INT TERM HUP
    [[ -n "$prev_sig" ]] && eval "$prev_sig"
' \
    '    :
')
report "M289: the traps stay set when the bring-up returns" "$m" \
       "🔴 32h and a bring-up that returns leaves none behind, nor an exit trap"

# An interrupted teardown says nothing about where it stopped.
m=$(mutant m290 "$NDT" \
    '    trap '"'"'down_on_signal INT 130'"'"' INT
' \
    '    :
')
report "M290: 'ndt down' holds no INT trap" "$m" \
       "🔴 32g it says where it stopped, and that the verb can be run again"

# The note goes on saying what an earlier bring-up wrote.
m=$(mutant m291 "$NDT" \
    '    if set_claim_note "down at $when interrupted at $phase; claim kept -- run '"'"'ndt down'"'"' again"; then
' \
    '    if false; then
')
report "M291: an interrupted teardown leaves the claim note as it was" "$m" \
       "🔴 32g the note says the teardown was interrupted, and where"

# The marker is left for the next verb to find stale.
m=$(mutant m292 "$NDT" \
    '    trap '"'"'mark_teardown_end'"'"' EXIT
' \
    '    :
')
report "M292: an interrupted teardown leaves its marker" "$m" \
       "🔴 32g the teardown's marker is released"

# Two files in $TMPDIR for every interrupted OVS bring-up.
m=$(mutant m293 "$NDT" \
    '    [[ -n "$UP_BG_FIFO$UP_BG_OUT" ]] && rm -f "$UP_BG_FIFO" "$UP_BG_OUT" 2>/dev/null
' \
    '    :
')
report "M293: the background stack.sh's FIFO and output file are left" "$m" \
       "🔴 32f its FIFO and output file are removed"

# The handler can be ended by the first line it writes: Ctrl-C also ended the tee its output goes to, and the write is a SIGPIPE.
m=$(mutant m294 "$NDT" \
    '    sig_output_check
    UP_SIG_COUNT=$(( ${UP_SIG_COUNT:-0} + 1 ))' \
    '    UP_SIG_COUNT=$(( ${UP_SIG_COUNT:-0} + 1 ))')
report "M294: the bring-up's signal handler does not protect itself from a dead output" "$m" \
       "🔴 32j the rollback ran although the reader of its output was gone: topo-start, topo-stop, cleanup"

m=$(mutant m295 "$NDT" \
    '    sig_output_check
    DOWN_SIG_COUNT=$(( ${DOWN_SIG_COUNT:-0} + 1 ))' \
    '    DOWN_SIG_COUNT=$(( ${DOWN_SIG_COUNT:-0} + 1 ))')
report "M295: the teardown's signal handler does not protect itself from a dead output" "$m" \
       "🔴 32k the note says the teardown was interrupted although the reader of its output was gone"

# --- section 32, more cells ------------------------------------------------------------------------------

# The fabric is recorded as started only after the old session is stopped: a signal in between says nothing had changed.
m=$(mutant m296 "$NDT" \
    '        up_started fabric
        # [Co-developed with claude code -- Adam] A fabric that was running is taken down here and
        # is not rebuilt if this run fails: the rollback says so by name and does not call the
        # machine back as it was (up_replaced is recorded before the call, like every stage).
        # [Co-developed with claude code -- Adam] stop_rc is what that topo-stop answered: 0 when nothing was stopped at all.
        local stop_rc=0
        (( sess_rc == 0 )) && { up_replaced_fabric "${live_hosts:-?}"; info "stopping the existing topo session"; heartbeat_stop_step "before the running topology is replaced" || true; sudo -n "$LAB" topo-stop >/dev/null 2>&1 || stop_rc=$?; }
' \
    '        # [Co-developed with claude code -- Adam] A fabric that was running is taken down here and
        # is not rebuilt if this run fails: the rollback says so by name and does not call the
        # machine back as it was (up_replaced is recorded before the call, like every stage).
        # [Co-developed with claude code -- Adam] stop_rc is what that topo-stop answered: 0 when nothing was stopped at all.
        local stop_rc=0
        (( sess_rc == 0 )) && { up_replaced_fabric "${live_hosts:-?}"; info "stopping the existing topo session"; heartbeat_stop_step "before the running topology is replaced" || true; sudo -n "$LAB" topo-stop >/dev/null 2>&1 || stop_rc=$?; }
        up_started fabric
')
report "M296: the fabric stage is recorded after the replace, not before" "$m" \
       "🔴 32m it does not say nothing had changed over a fabric it had begun to replace"

# The prompt's FIFO is closed before the background stack.sh is stopped: its prompt is answered and it goes on.
m=$(mutant m297 "$NDT" \
    '    local pid="$UP_BG_PID" line rest k kl pg ppid
' \
    '    local pid="$UP_BG_PID" line rest k kl pg ppid
    exec 3>&-
')
report "M297: the prompt's FIFO is closed before the background stack.sh is stopped" "$m" \
       "🔴 32f and it did not go on to start a kernel when its prompt ended"

# The remaining-signal count is always one.
m=$(mutant m298 "$NDT" \
    '        local more=$(( 3 - UP_SIG_COUNT ))
' \
    '        local more=1
')
report "M298: the line says one more signal abandons the rollback, whichever signal it was" "$m" \
       "🔴 32e3 and that two more signals abandon it (this was the first of the run)"

# --- widenings: the guard stops discriminating -------------------------------------------------------

# The lock never opens: every verb is refused.
m=$(mutant n137 "$NDT" \
    '        if ! flock -w "$w" 9; then' \
    '        if ! false; then')
report "N137: the run lock never opens" "$m" \
       "31d a bring-up that completes is rc 0"

# A marker whose pid is gone refuses for ever: a crashed bring-up would make every later one impossible.
m=$(mutant n138 "$NDT" \
    '    if ! kill -0 "$RM_PID" 2>/dev/null; then RM_WHY="pid $RM_PID is gone"; return 2; fi' \
    '    :')
report "N138: a marker whose process is gone still refuses" "$m" \
       "🔴 31b a marker whose pid is gone does not refuse"

# What only looks refuses on every call.
m=$(mutant n139 "$NDT" \
    '    run_check_conflicts "$action" "$@" || return 1
}' \
    '    run_check_conflicts "$action" "$@"; return 1
}')
report "N139: an app start is refused whatever is running" "$m" \
       "  31i control: with no marker the app is started"

# The same owner is let through: the measured pair was one owner, twice.
m=$(mutant n140 "$NDT" \
    '            0) run_refusal "$action" "$b"; return 5 ;;' \
    '            0) [[ -n "${NDT_OWNER:-}" && "$RM_BY" == "$NDT_OWNER" ]] || { run_refusal "$action" "$b"; return 5; } ;;')
report "N140: a marker of the same owner does not refuse" "$m" \
       "🔴 31a the same owner is refused too"

# A missing marker file reads as a live one.
m=$(mutant n141 "$NDT" \
    '    [[ -f "$f" ]] || return 1
    RM_PID="$(run_marker_field "$f" pid)"' \
    '    [[ -f "$f" ]] || return 0
    RM_PID="$(run_marker_field "$f" pid)"')
report "N141: no marker at all reads as a running verb" "$m" \
       "31d a bring-up that completes is rc 0"

# The peek's own liveness test: a dead pid read as live refuses an app start for ever.
m=$(mutant n142 "$NDT" \
    '    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1' \
    '    [[ "$pid" =~ ^[0-9]+$ ]] || return 1')
report "N142: a dead teardown's marker still refuses a verb that only looks" "$m" \
       "  31i and the stale marker does not refuse the start"

# ...and a live teardown the peek never sees.
m=$(mutant n143 "$NDT" \
    '    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1' \
    '    return 1')
report "N143: a verb that only looks never sees a live teardown" "$m" \
       "🔴 31i 'ndt apps <name>' under a live teardown is refused with 1"

# --- section 32 widenings ---------------------------------------------------------------------------

# Ctrl-C always undoes: a lab that came up and was only being read is torn down.
m=$(mutant n144 "$NDT" \
    '    if up_phase_is_verify "$phase"; then
' \
    '    if false; then
')
report "N144: an interrupt at verify rolls back too" "$m" \
       "🔴 32d it says the lab is up and was not verified"

# Two signals are enough to abandon it.
m=$(mutant n145 "$NDT" \
    '    UP_SIG_COUNT=$(( ${UP_SIG_COUNT:-0} + 1 ))
    echo
    warn "interrupted (SIG$sig) at $phase"
' \
    '    UP_SIG_COUNT=$(( ${UP_SIG_COUNT:-0} + 2 ))
    echo
    warn "interrupted (SIG$sig) at $phase"
')
report "N145: the second signal abandons the rollback" "$m" \
       "  32e and it was not abandoned (two signals are not three)"

# The files an interrupted run wrote before its first stage are not put back.
m=$(mutant n146 "$NDT" \
    '    rollback_up "interrupted by SIG$sig at $phase" || true
' \
    '    (( ${#UP_STARTED[@]} )) && { rollback_up "interrupted by SIG$sig at $phase" || true; }
')
report "N146: nothing is rolled back when nothing was started" "$m" \
       "🔴 32c nothing had been started, and it says so"

# On OVS an interrupt at the last step rolls the lab back.
m=$(mutant n147 "$NDT" \
    'up_phase_is_verify() { [[ "$1" == "[3/3]" || "$1" == "[4/4]" ]]; }
' \
    'up_phase_is_verify() { [[ "$1" == "[3/3]" ]]; }
')
report "N147: the OVS plane's last step is not the verify step" "$m" \
       "🔴 32i it says the lab is up and was not verified"

# --- an 'ndt up' that did not finish is kept as a record (section 36) ---------------------------------

# The stale marker is "kept" but nothing is written: the fact is gone before the next bring-up can act on it.
m=$(mutant m299 "$NDT" \
    '    if { cp -- "$1" "$tmp" && mv -f -T -- "$tmp" "$unf"; } 2>/dev/null; then return 0; fi
' \
    '    if :; then return 0; fi
')
report "M299: a stale up marker is said to be kept and nothing is written" "$m" \
       "🔴 36a the record is there, with the marker's own fields"

# 'ndt status' prints no run row and counts nothing.
m=$(mutant m300 "$NDT" \
    '    status_run_row
    (( ${#STATUS_RUN_PROBLEMS[@]} > 0 )) && problems+=("${STATUS_RUN_PROBLEMS[@]}")
' \
    '    :
')
report "M300: ndt status has no run row" "$m" \
       "🔴 36b a live bring-up is a row: its command, owner, pid, start and step"

# The row is there and --check does not count an unfinished bring-up.
m=$(mutant m301 "$NDT" \
    '        STATUS_RUN_PROBLEMS+=("$(up_unfinished_text) (${UF_FROM})")
' \
    '        :
')
report "M301: --check does not count an unfinished bring-up" "$m" \
       "🔴 36b --check counts it as a problem (rc 1)"

# A reading that removes what it reads: a stale marker is not a reader's to remove.
m=$(mutant m302 "$NDT" \
    '    if up_unfinished_look; then
        lines+=("$(up_unfinished_text)")
' \
    '    if up_unfinished_look; then
        rm -f "$(run_marker up)" "$(run_unfinished_file)"
        lines+=("$(up_unfinished_text)")
')
report "M302: ndt status removes the record it reads" "$m" \
       "🔴 36b status removes and moves nothing"

# The next bring-up reuses the fabric the record names, as before.
m=$(mutant m303 "$NDT" \
    '    if (( reuse )) && up_unfinished_look; then
' \
    '    if (( reuse )) && false; then
')
report "M303: the next bring-up reuses a fabric an unfinished bring-up left" "$m" \
       "🔴 36c and it was NOT reused"

# A bring-up that did not verify also removes the record.
m=$(mutant m304 "$NDT" \
    '    if (( rc == 0 )); then up_unfinished_clear "this bring-up verified"
    elif up_phase_is_verify "${RUN_PHASE:-}"; then up_unfinished_record; fi
' \
    '    up_unfinished_clear "this bring-up ended"
')
report "M304: a bring-up that failed or did not verify removes the record too" "$m" \
       "🔴 36d and the record stays"

# A bring-up that verified leaves the record where it was.
m=$(mutant m305 "$NDT" \
    '    if (( rc == 0 )); then up_unfinished_clear "this bring-up verified"
    elif up_phase_is_verify "${RUN_PHASE:-}"; then up_unfinished_record; fi
' \
    '    :
')
report "M305: a bring-up that verified leaves the record" "$m" \
       "🔴 36d and it removed the record"

# A teardown that verified clean leaves the record.
m=$(mutant m306 "$NDT" \
    '        up_unfinished_clear "'"'"'verify clean'"'"' found none of the fabric itself"
' \
    '        :
')
report "M306: a teardown that verified clean leaves the record" "$m" \
       "  36d out loud, and on what"

# A teardown removes the record over a fabric that is still there.
m=$(mutant m307 "$NDT" \
    '        up_target_kept "$CLEAN_FABRIC_LEFT"
    fi
' \
    '        up_target_kept "$CLEAN_FABRIC_LEFT"
        up_unfinished_clear "the teardown ended"
    fi
')
report "M307: a teardown removes the record over a fabric it did not take down" "$m" \
       "🔴 36d and the record is KEPT: it describes a fabric that is still there"

# A bring-up that abandoned its rollback leaves no record.
m=$(mutant m308 "$NDT" \
    '    up_unfinished_record
    up_note_rewrite "$note" || true' \
    '    up_note_rewrite "$note" || true')
report "M308: an abandoned rollback leaves no record" "$m" \
       "🔴 36e the record is there, written by the bring-up that abandoned it"

# The reuse rule reads the record and not a stale marker that nothing has moved yet.
m=$(mutant m309 "$NDT" \
    '    if (( lrc == 2 )); then
        f="$(run_marker up)"; UF_FROM="${f#$REPO/}"' \
    '    if false; then
        f="$(run_marker up)"; UF_FROM="${f#$REPO/}"')
report "M309: a stale up marker that nothing has moved yet does not stop a reuse" "$m" \
       "🔴 36c a stale up marker not yet moved forces the rebuild too"

# The removal line does not say the marker went anywhere.
m=$(mutant m310 "$NDT" \
    '        if up_unfinished_keep "$f"; then kept=", moved to ${unf#$REPO/}"; else kept=", NOT kept"; fi' \
    '        if up_unfinished_keep "$f"; then kept=""; else kept=", NOT kept"; fi')
report "M310: the removal line does not say the marker was kept" "$m" \
       "🔴 36a and the removal line says where it went"

# A signal writes the record at once, before the rollback has had a chance to finish.
m=$(mutant m311 "$NDT" \
    '    UP_SIG_COUNT=$(( ${UP_SIG_COUNT:-0} + 1 ))
    echo
    warn "interrupted (SIG$sig) at $phase"
' \
    '    UP_SIG_COUNT=$(( ${UP_SIG_COUNT:-0} + 1 ))
    echo
    warn "interrupted (SIG$sig) at $phase"
    up_unfinished_write
')
report "M311: the record is written at the first signal" "$m" \
       "  36e a rollback that is still running has made no record"

# The record is written with a copy that leaves its temporary file behind.
m=$(mutant m312 "$NDT" \
    '    if { cp -- "$1" "$tmp" && mv -f -T -- "$tmp" "$unf"; } 2>/dev/null; then return 0; fi
' \
    '    if { cp -- "$1" "$tmp" && cp -f -- "$tmp" "$unf"; } 2>/dev/null; then return 0; fi
')
report "M312: the record is copied into place and the temporary file stays" "$m" \
       "  36a no temporary file is left beside the record"

# Reading a stale marker removes it.
m=$(mutant m313 "$NDT" \
    '        f="$(run_marker up)"; UF_FROM="${f#$REPO/}"
' \
    '        f="$(run_marker up)"; UF_FROM="${f#$REPO/}"; rm -f "$f"
')
report "M313: reading a stale up marker removes it" "$m" \
       "  36c (it was only read: the marker is where it was)"

# --- widenings ---

# A fabric is never reused, record or not.
m=$(mutant n148 "$NDT" \
    '    if (( reuse )) && up_unfinished_look; then
' \
    '    if (( reuse )); then
')
report "N148: a running fabric is never reused" "$m" \
       "  36c (control) nothing was stopped or started"

# 'ndt status --check' calls a running verb a problem.
m=$(mutant n149 "$NDT" \
    '        (( lrc == 0 )) && lines+=("${RM_ARGV:-ndt $v} by ${RM_BY:-?}, pid $RM_PID, since ${RM_AT:-?}, at ${RM_PHASE:-?}")
' \
    '        (( lrc == 0 )) && { lines+=("${RM_ARGV:-ndt $v} by ${RM_BY:-?}, pid $RM_PID, since ${RM_AT:-?}, at ${RM_PHASE:-?}"); STATUS_RUN_PROBLEMS+=("a verb is running"); }
')
report "N149: a running verb is a --check problem" "$m" \
       "🔴 36b a bring-up that is running is not a --check problem"

# A stale marker of any verb becomes the record.
m=$(mutant n150 "$NDT" \
    '    if [[ "$1" == up ]]; then
        if up_unfinished_keep "$f"; then kept=' \
    '    if [[ "$1" == up || "$1" == clean ]]; then
        if up_unfinished_keep "$f"; then kept=')
report "N150: a stale clean marker is kept as an unfinished bring-up" "$m" \
       "🔴 36a and it leaves no record: only a bring-up that died is one"

# A standalone clean that finds nothing removes the record.
m=$(mutant n151 "$NDT" \
    '    say "${G}clean${N}"
    (( run_owned )) && run_leave clean "$run_prev_trap"
    return 0
}' \
    '    say "${G}clean${N}"
    up_unfinished_clear "the machine is clean"
    (( run_owned )) && run_leave clean "$run_prev_trap"
    return 0
}')
report "N151: a standalone clean removes the record" "$m" \
       "🔴 36d a standalone 'ndt clean' that finds nothing does not remove it"

# A record is read from a path that may be a FIFO.
m=$(mutant n152 "$NDT" \
    '    elif [[ -f "$f" ]]; then
        UF_FROM="${f#$REPO/}"' \
    '    elif [[ -e "$f" ]]; then
        UF_FROM="${f#$REPO/}"')
report "N152: the record is read from anything that exists" "$m" \
       "🔴 36b a FIFO at up.unfinished does not hang 'ndt status'"

# The record is announced whether or not there is a fabric to rebuild.
m=$(mutant n153 "$NDT" \
    '    if (( reuse )) && up_unfinished_look; then
' \
    '    if up_unfinished_look; then
')
report "N153: the rebuild line is printed over no fabric at all" "$m" \
       "  36c and says nothing about a fabric it did not find"

# The record is consulted before the stale-pipeline refusal.
m=$(mutant n154 "$NDT" \
    '    if (( reuse )) && stale_pipeline; then
' \
    '    (( reuse )) && up_unfinished_look && reuse=0
    if (( reuse )) && stale_pipeline; then
')
report "N154: the record is read before the stale-pipeline refusal" "$m" \
       "  36c the stale-pipeline refusal is still the first answer"

# Any interrupted bring-up leaves the record, finished rollback or not.
m=$(mutant n155 "$NDT" \
    '    rollback_up "interrupted by SIG$sig at $phase" || true
    UP_EXIT_DECIDED=1
    exit "$code"' \
    '    rollback_up "interrupted by SIG$sig at $phase" || true
    up_unfinished_write
    UP_EXIT_DECIDED=1
    exit "$code"')
report "N155: an interrupted bring-up whose rollback finished leaves the record" "$m" \
       "🔴 36e and it leaves no record"

# A bring-up that is running when a verb looks is recorded as one that died.
m=$(mutant n156 "$NDT" \
    '            0) run_refusal "$action" "$b"; return 5 ;;
' \
    '            0) up_unfinished_keep "$(run_marker "$b")"; run_refusal "$action" "$b"; return 5 ;;
')
report "N156: a live bring-up's marker is kept as a record by a refused verb" "$m" \
       "  36a (control) a live bring-up's marker makes no record"

# --- one rule: a fabric is reused only when the last bring-up verified it (section 36) ---

# An interrupt at the last step records nothing.
m=$(mutant m314 "$NDT" \
    '        up_unfinished_record
        UP_EXIT_DECIDED=1
        exit "$code"' \
    '        UP_EXIT_DECIDED=1
        exit "$code"')
report "M314: an interrupt at the last step leaves no record" "$m" \
       "🔴 36h and the record is there, from the bring-up that was interrupted"

# A rollback that ended INCOMPLETE records nothing (a fabric this run built).
m=$(mutant m315 "$NDT" \
    '        err "rollback INCOMPLETE -- see above. finish it by hand:  ndt down --deep"
        up_unfinished_record
' \
    '        err "rollback INCOMPLETE -- see above. finish it by hand:  ndt down --deep"
')
report "M315: an INCOMPLETE rollback records nothing" "$m" \
       "🔴 36g and leaves the record, from the rollback"

# ...and over a fabric this run reused.
m=$(mutant m316 "$NDT" \
    '        err "  without --deep, would take that fabric down too."
        up_unfinished_record
' \
    '        err "  without --deep, would take that fabric down too."
')
report "M316: an INCOMPLETE rollback over a reused fabric records nothing" "$m" \
       "🔴 36g and the record is left there as well"

# A verify that ran and failed records nothing.
m=$(mutant m317 "$NDT" \
    '    elif up_phase_is_verify "${RUN_PHASE:-}"; then up_unfinished_record; fi' \
    '    fi')
report "M317: a verify that ran and failed leaves no record" "$m" \
       "🔴 36f and it leaves the record, at its last step"

# The failed-verify record is written for the P4 step only.
m=$(mutant m318 "$NDT" \
    '    elif up_phase_is_verify "${RUN_PHASE:-}"; then up_unfinished_record; fi' \
    '    elif [[ "${RUN_PHASE:-}" == "[3/3]" ]]; then up_unfinished_record; fi')
report "M318: only the P4 plane's failed verify is recorded" "$m" \
       "🔴 36f and leaves the record, at its last step ([4/4])"

# Status names the older record over a newer stale marker.
m=$(mutant m319 "$NDT" \
    '    run_marker_look up; lrc=$?
    if (( lrc == 2 )); then' \
    '    run_marker_look up; lrc=$?
    if (( lrc == 2 )) && [[ ! -f "$f" ]]; then')
report "M319: status names the older record, not the newer stale marker" "$m" \
       "🔴 36i a stale marker newer than the record is the one named"

# A directory where the record belongs takes the temporary file (kept).
m=$(mutant m320 "$NDT" \
    '    if { cp -- "$1" "$tmp" && mv -f -T -- "$tmp" "$unf"; } 2>/dev/null; then return 0; fi' \
    '    if { cp -- "$1" "$tmp" && mv -f -- "$tmp" "$unf"; } 2>/dev/null; then return 0; fi')
report "M320: a directory at the record's path takes the moved marker" "$m" \
       "🔴 36i a directory where the record belongs is not reported as 'moved to'"

# ...and the abandoned-rollback writer.
m=$(mutant m321 "$NDT" \
    '          mv -f -T -- "$tmp" "$unf"; } 2>/dev/null && return 0' \
    '          mv -f -- "$tmp" "$unf"; } 2>/dev/null && return 0')
report "M321: a directory at the record's path takes the written record" "$m" \
       "🔴 36i writing the record over a directory fails, and says so"

# The clean verify's removal, caught by the cell that moves and removes in one teardown.
m=$(mutant m322 "$NDT" \
    '        up_unfinished_clear "'"'"'verify clean'"'"' found none of the fabric itself"
' \
    '        :
')
report "M322: the teardown that moved the record leaves it after its clean verify" "$m" \
       "🔴 36d and removed by the same teardown's clean verify"

# --- widening ---

# Any failed bring-up records, whatever step it ended at.
m=$(mutant n157 "$NDT" \
    '    elif up_phase_is_verify "${RUN_PHASE:-}"; then up_unfinished_record; fi' \
    '    else up_unfinished_record; fi')
report "N157: every bring-up that fails leaves a record" "$m" \
       "  36f (control) a failure whose rollback finished leaves no record"

# A rollback with nothing started records too.
m=$(mutant n158 "$NDT" \
    '        info "nothing to roll back: this '"'"'ndt up'"'"' had not changed the machine yet"
' \
    '        info "nothing to roll back: this '"'"'ndt up'"'"' had not changed the machine yet"
        up_unfinished_record
')
report "N158: an interrupt before anything was started leaves a record" "$m" \
       "  36h (control) an interrupt before anything was started leaves no record"

# --- the rule holds when only the EXIT trap sees the way out (section 36) ---

# The EXIT trap no longer records: a shell error or a SIGPIPE after a stage was started leaves no record.
m=$(mutant m323 "$NDT" \
    "    trap 'up_exit_unverified; run_release up' EXIT" \
    "    trap 'run_release up' EXIT")
report "M323: the exit trap records nothing" "$m" \
       "🔴 36j and the record is there, from the exit nothing decided"

# The signal handler's rollback exit is not marked as decided: the trap writes a record over a rollback that finished.
m=$(mutant m324 "$NDT" \
    '    rollback_up "interrupted by SIG$sig at $phase" || true
    UP_EXIT_DECIDED=1
' \
    '    rollback_up "interrupted by SIG$sig at $phase" || true
')
report "M324: an interrupted bring-up whose rollback finished is recorded by the exit trap" "$m" \
       "🔴 36e and it leaves no record"

# The record is written by the own-marker branch without -T: a directory at the path takes the file.
m=$(mutant m325 "$NDT" \
    '        { cp -- "$f" "$tmp" && mv -f -T -- "$tmp" "$unf"; } 2>/dev/null && return 0' \
    '        { cp -- "$f" "$tmp" && mv -f -- "$tmp" "$unf"; } 2>/dev/null && return 0')
report "M325: a directory at the record's path takes the record written from the bring-up's own marker" "$m" \
       "🔴 36l a failed verify that cannot write the record says so"

# The signal handler marks its exit as decided before the rollback and the record, as it once did: a way out inside them is
# not seen by the trap.
m=$(mutant m340 "$NDT" \
    '    if up_phase_is_verify "$phase"; then
        say "up, ${R}NOT verified${N} -- interrupted during $phase"' \
    '    UP_EXIT_DECIDED=1
    if up_phase_is_verify "$phase"; then
        say "up, ${R}NOT verified${N} -- interrupted during $phase"')
report "M340: the flag is set before the rollback and the record" "$m" \
       "🔴 36m and the record is there, at the rollback"

# The same, for the rollback a signal starts only.
m=$(mutant m341 "$NDT" \
    '    up_bg_stack_stop
    rollback_up "interrupted by SIG$sig at $phase" || true' \
    '    up_bg_stack_stop
    UP_EXIT_DECIDED=1
    rollback_up "interrupted by SIG$sig at $phase" || true')
report "M341: the flag is set before the rollback a signal starts" "$m" \
       "🔴 36m the record is there, written by the bring-up the signal ended"

# The same, for the interrupt at the last step only.
m=$(mutant m342 "$NDT" \
    '        say "up, ${R}NOT verified${N} -- interrupted during $phase"' \
    '        UP_EXIT_DECIDED=1
        say "up, ${R}NOT verified${N} -- interrupted during $phase"')
report "M342: the flag is set before the interrupt at the last step records" "$m" \
       "🔴 36m and the record is there, at [3/3]"

# The bring-up marks its own exit as decided as soon as the bring-up function returns, before the record of a failed verify:
# a way out in between is not seen by the trap.
m=$(mutant m343 "$NDT" \
    '    (( rc == 0 || UP_ROLLING_BACK )) && UP_EXIT_DECIDED=1
' \
    '    UP_EXIT_DECIDED=1
')
report "M343: the flag is set before the failed verify's record" "$m" \
       "🔴 36n and the record is there, at [3/3]"

# A rollback that finished is not marked as decided: a way out right after it records over a fabric that is as it was.
m=$(mutant m360 "$NDT" \
    '    (( rc == 0 || UP_ROLLING_BACK )) && UP_EXIT_DECIDED=1
' \
    '    (( rc == 0 )) && UP_EXIT_DECIDED=1
')
report "M360: a way out after a finished rollback leaves a record" "$m" \
       "🔴 36n (control) and it leaves no record"

# The exit is not marked as decided once the failed verify's record is written: a way out after the marker is released
# records again.
m=$(mutant m361 "$NDT" \
    '    UP_EXIT_DECIDED=1
    run_leave up "$prev"' \
    '    run_leave up "$prev"')
report "M361: the record of a failed verify is written again after the marker is released" "$m" \
       "🔴 36n and it was recorded once, not again after the marker was released"

# The exit trap records even when nothing was started.
m=$(mutant n159 "$NDT" \
    '    (( ${#UP_STARTED[@]} )) || return 0
    UP_EXIT_DECIDED=1' \
    '    :
    UP_EXIT_DECIDED=1')
report "N159: a shell error before anything was started leaves a record" "$m" \
       "  36j (control) a shell error before anything was started leaves no record"

# A topo session that appeared after the decision to build is stopped like one the decision saw: the new check removed.
m=$(mutant m326 "$NDT" \
    '        if (( sess_rc == 0 && dec_sess_rc != 0 )); then
' \
    '        if (( 0 )); then
')
report "M326: a session that appeared after the decision to build is stopped (the check removed)" "$m" \
       "🔴 31k a session that appeared after the decision to build refuses the bring-up with 5"

# A decision that could not tell (rc 2) counts as having seen the session.
m=$(mutant m328 "$NDT" \
    '        if (( sess_rc == 0 && dec_sess_rc != 0 )); then
' \
    '        if (( sess_rc == 0 && dec_sess_rc == 1 )); then
')
report "M328: a decision that could not tell counts as having seen the session" "$m" \
       "🔴 31k a decision that could not tell, then a session at [1/3]: refused with 5"

# The check ignores what the decision saw: every session found at [1/3] is refused.
m=$(mutant n160 "$NDT" \
    '        if (( sess_rc == 0 && dec_sess_rc != 0 )); then
' \
    '        if (( sess_rc == 0 )); then
')
report "N160: a session the decision saw is refused too" "$m" \
       "🔴 31k control: it is stopped, once"

# The already-running topo-start keeps `fabric` in the record: the rollback stops and sweeps the session that is there.
m=$(mutant m329 "$NDT" \
    '                up_unstarted fabric; UP_FOREIGN_SESSION=1
                up_foreign_session_lines
' \
    '                UP_FOREIGN_SESSION=1
                up_foreign_session_lines
')
report "M329: P4: the already-running topo-start rolls the fabric back again" "$m" \
       "🔴 31l the session that is there is not stopped"

# The already-running ovs verb keeps `fabric` in the record: the rollback stops and sweeps the session that is there.
m=$(mutant m330 "$NDT" \
    'then busy=1; up_unstarted fabric; UP_FOREIGN_SESSION=1; fi
' \
    'then busy=1; UP_FOREIGN_SESSION=1; fi
')
report "M330: OVS: the already-running verb rolls the fabric back again" "$m" \
       "🔴 31m the session that is there is not stopped"

# Any topo-start failure is read as the already-running one.
m=$(mutant m331 "$NDT" \
    '            if (( stop_rc == 0 )) && topo_busy_said "$tsout"; then
' \
    '            if (( stop_rc == 0 )) && true; then
')
report "M331: P4: any topo-start failure is treated as already-running" "$m" \
       "🔴 31l control: and it rolls back the fabric stage (topo-stop)"

# Any failure of the OVS fabric verb is read as the already-running one.
m=$(mutant m332 "$NDT" \
    '        if topo_busy_said "$ovs_err"; then busy=1;' \
    '        if true; then busy=1;')
report "M332: OVS: any fabric-verb failure is treated as already-running" "$m" \
       "🔴 31m control: and its rollback stops the topo session it may have left"

# A run that stopped a fabric of its own to build is refused as if it had stopped nothing: the fabric that is gone is not named.
m=$(mutant m333 "$NDT" \
    '                if (( ${#UP_STARTED[@]} == 0 && ${#UP_REPLACED[@]} == 0 )); then
' \
    '                if (( ${#UP_STARTED[@]} == 0 )); then
')
report "M333: P4: a replaced fabric is refused as if nothing had been replaced" "$m" \
       "🔴 31l the fabric that was taken down stays down, and is named"

# A decision that could not read the lab (rc 2) reuses the fabric whose counts match.
m=$(mutant m334 "$NDT" \
    '    (( dec_sess_rc == 0 )) && [[ "$n" -eq "$SWITCHES" && "$live_hosts" -eq "$hosts" ]] && reuse=1
' \
    '    (( dec_sess_rc != 1 )) && [[ "$n" -eq "$SWITCHES" && "$live_hosts" -eq "$hosts" ]] && reuse=1
')
report "M334: a decision that could not read the lab reuses the fabric" "$m" \
       "🔴 31k a decision that could not read the lab does not reuse the fabric whose counts match"

# ndt's copy of the helper's sentence is reworded: the refusal is never recognised.
m=$(mutant m335 "$NDT" \
    'LAB_TOPO_BUSY_TEXT="topo session already running (topo-stop first)"
' \
    'LAB_TOPO_BUSY_TEXT="a topo session is already running (topo-stop first)"
')
report "M335: ndt's copy of the helper's already-running sentence is reworded" "$m" \
       "31n ndt carries the sentence it matches"

# The OVS refusal exits 1 after its rollback.
m=$(mutant m336 "$NDT" \
    '            up_foreign_session_lines
            rollback_up "a topo session this bring-up did not start was there when $ovs_verb ran; it is left running" || return 1
            return 5
' \
    '            up_foreign_session_lines
            rollback_up "a topo session this bring-up did not start was there when $ovs_verb ran; it is left running" || return 1
            return 1
')
report "M336: OVS: the refusal over a session that is not this run's exits 1" "$m" \
       "🔴 31m an OVS bring-up whose fabric verb finds a session is refused with 5"

# The P4 refusal after a replace exits 1.
m=$(mutant m337 "$NDT" \
    '                rollback_up "a topo session this bring-up did not start was there when it ran topo-start; it is left running" || return 1
                return 5
' \
    '                rollback_up "a topo session this bring-up did not start was there when it ran topo-start; it is left running" || return 1
                return 1
')
report "M337: P4: the refusal after a replace exits 1" "$m" \
       "🔴 31l after a replace, a topo-start that finds another session is refused with 5"

# The already-running sentence is matched by any helper output that mentions the topo.
m=$(mutant n161 "$NDT" \
    'topo_busy_said() { [[ "$1" == *"$LAB_TOPO_BUSY_TEXT"* ]]; }
' \
    'topo_busy_said() { [[ "$1" == *topo* ]]; }
')
report "N161: any helper output that mentions the topo counts as already-running" "$m" \
       "31l control: another topo-start failure is rc 1"

# The exit trap records from a subshell too.
m=$(mutant w36 "$NDT" \
    '    [[ "${BASHPID:-$$}" == "$$" ]] || return 0
    (( ${UP_EXIT_DECIDED:-0} )) && return 0' \
    '    (( ${UP_EXIT_DECIDED:-0} )) && return 0')
report_green "W36 (behaviour-preserving): the exit trap without its subshell guard" "$m" \
       "a subshell never runs the parent's EXIT trap"

# The decision's reading kept with a separate assignment.
m=$(mutant w37 "$NDT" \
    '    topo_session || dec_sess_rc=$?
' \
    '    topo_session; dec_sess_rc=$?
')
report_green "W37 (behaviour-preserving): the decision's session reading kept by a separate assignment" "$m" \
       "the same rc is kept"

# The sentence is matched with grep instead of a pattern test.
m=$(mutant w38 "$NDT" \
    'topo_busy_said() { [[ "$1" == *"$LAB_TOPO_BUSY_TEXT"* ]]; }
' \
    'topo_busy_said() { grep -qF -- "$LAB_TOPO_BUSY_TEXT" <<<"$1"; }
')
report_green "W38 (behaviour-preserving): the already-running sentence matched with grep" "$m" \
       "the same fixed-string test"

# The helper's stderr is shown with an if instead of an && list.
m=$(mutant w40 "$NDT" \
    '    [[ -n "$ovs_err" ]] && printf '"'"'%s\n'"'"' "$ovs_err" >&2
' \
    '    if [[ -n "$ovs_err" ]]; then printf '"'"'%s\n'"'"' "$ovs_err" >&2; fi
')
report_green "W40 (behaviour-preserving): the helper's stderr shown with an if" "$m" \
       "the same print"

# [Co-developed with claude code -- Adam]
# The topo-stop this run asked for answered non-zero: the session is still there and is this run's. The sentence is taken at its word anyway.
m=$(mutant m344 "$NDT" \
    '            if (( stop_rc == 0 )) && topo_busy_said "$tsout"; then
' \
    '            if topo_busy_said "$tsout"; then
')
report "M344: P4: the already-running sentence is believed after a topo-stop that failed" "$m" \
       "🔴 31l a topo-stop that failed leaves the session this run's: the ordinary rollback, rc 1"

# The OVS refusal exits 5 although the rollback of the stack could not finish.
m=$(mutant m345 "$NDT" \
    '            rollback_up "a topo session this bring-up did not start was there when $ovs_verb ran; it is left running" || return 1
            return 5
' \
    '            rollback_up "a topo session this bring-up did not start was there when $ovs_verb ran; it is left running"
            return 5
')
report "M345: OVS: the refusal exits 5 over a rollback that did not finish" "$m" \
       "🔴 31m a rollback that cannot finish over a session that is not this run's is rc 1"

# The P4 refusal exits 5 although putting the files back failed.
m=$(mutant m346 "$NDT" \
    '                    refusal_unwind "a topo session this bring-up did not start was there when it ran topo-start; nothing was built" || return 1
' \
    '                    refusal_unwind "a topo session this bring-up did not start was there when it ran topo-start; nothing was built"
')
report "M346: P4: the refusal exits 5 although putting the files back failed" "$m" \
       "🔴 31l a refusal that could not put the claim note back is rc 1, not 5"

# The P4 refusal after a replace exits 5 although its rollback did not finish.
m=$(mutant m347 "$NDT" \
    '                rollback_up "a topo session this bring-up did not start was there when it ran topo-start; it is left running" || return 1
' \
    '                rollback_up "a topo session this bring-up did not start was there when it ran topo-start; it is left running"
')
report "M347: P4: the refusal after a replace exits 5 over a rollback that did not finish" "$m" \
       "🔴 31l after a replace, a rollback that could not put the claim note back is rc 1, not 5"

# The three lines are printed before the fabric is taken out of the record (P4).
m=$(mutant m348 "$NDT" \
    '                up_unstarted fabric; UP_FOREIGN_SESSION=1
                up_foreign_session_lines
' \
    '                up_foreign_session_lines
                up_unstarted fabric; UP_FOREIGN_SESSION=1
')
report "M348: P4: the three lines are printed before the fabric leaves the record" "$m" \
       "🔴 31l the session is known not to be this run's before the first of the three lines"

# The same, OVS.
m=$(mutant m349 "$NDT" \
    '        if topo_busy_said "$ovs_err"; then busy=1; up_unstarted fabric; UP_FOREIGN_SESSION=1; fi
        err "$ovs_verb failed"; up_bg_stack_stop
        if (( busy )); then
            up_foreign_session_lines
' \
    '        if topo_busy_said "$ovs_err"; then busy=1; fi
        err "$ovs_verb failed"; up_bg_stack_stop
        if (( busy )); then
            up_foreign_session_lines
            up_unstarted fabric; UP_FOREIGN_SESSION=1
')
report "M349: OVS: the three lines are printed before the fabric leaves the record" "$m" \
       "🔴 31m the session is known not to be this run's before the first of the three lines"

# What the helper says on stderr is not read by the P4 bring-up: the sentence never reaches the match.
m=$(mutant m350 "$NDT" \
    '        tsout="$(sudo -n "$LAB" topo-start 2>&1)"; tsrc=$?
' \
    '        tsout="$(sudo -n "$LAB" topo-start 2>/dev/null)"; tsrc=$?
')
report "M350: P4: the helper's stderr is not captured with its stdout" "$m" \
       "🔴 31l a topo-start that finds a session is refused with 5"

# An incomplete rollback over a session that is not this run's sends the operator to 'ndt down --deep'.
m=$(mutant m351 "$NDT" \
    '    elif (( UP_FOREIGN_SESSION )); then
' \
    '    elif false; then
')
report "M351: an incomplete rollback over a foreign session advises 'ndt down --deep'" "$m" \
       "🔴 31m it does not tell the operator to end the session with 'ndt down --deep'"

# ...and writes an unfinished-fabric record for a fabric this run never started.
m=$(mutant m352 "$NDT" \
    '        err "  '"'"'ndt down'"'"' would also stop the topology session that is not this run'"'"'s."
        rc=1
' \
    '        err "  '"'"'ndt down'"'"' would also stop the topology session that is not this run'"'"'s."
        up_unfinished_write
        rc=1
')
report "M352: an incomplete rollback over a foreign session records an unfinished fabric" "$m" \
       "🔴 31m no unfinished record: this run started no fabric"

# A rollback that finished over a session that is not this run's says the machine is back to what it was.
m=$(mutant m353 "$NDT" \
    '    elif (( rc == 0 && left == 0 && UP_FOREIGN_SESSION )); then
' \
    '    elif false; then
')
report "M353: a finished rollback over a foreign session says the machine is as it was" "$m" \
       "🔴 31m and it does not say the machine is back to what it was"

# The rollback does not say that the session that is there is left running.
m=$(mutant m354 "$NDT" \
    '    (( UP_FOREIGN_SESSION )) && info "the topology session that is there is not this run'"'"'s: it is left running"
' \
    '')
report "M354: the rollback does not say the foreign session is left running" "$m" \
       "🔴 31m the rollback says the session that is there is left running"

# With nothing of this run's left to take down, the rollback says nothing of it.
m=$(mutant m355 "$NDT" \
    '            info "nothing of this run'"'"'s is left to take down: the topology session that is there is not this run'"'"'s, and it is left running"
' \
    '')
report "M355: the empty rollback over a foreign session does not say so" "$m" \
       "🔴 31l and the rollback says nothing of this run's is left to take down"

# ...nor names the fabric this run had taken down and cannot put back.
m=$(mutant m356 "$NDT" \
    '            (( ${#UP_REPLACED[@]} )) && warn "replaced and not restored: $(join_list "${UP_REPLACED[@]}")"
        else
' \
    '        else
')
report "M356: the empty rollback over a foreign session does not name the fabric it replaced" "$m" \
       "🔴 31l and names the fabric it took down and cannot put back"

# A topo-stop that failed (rc 1) is still taken as 'nothing wrong': the busy sentence is believed up to rc 1.
m=$(mutant n162 "$NDT" \
    '            if (( stop_rc == 0 )) && topo_busy_said "$tsout"; then
' \
    '            if (( stop_rc <= 1 )) && topo_busy_said "$tsout"; then
')
report "N162: P4: a topo-stop that exited 1 is not held against the sentence" "$m" \
       "🔴 31l a topo-stop that failed leaves the session this run's: the ordinary rollback, rc 1"

# Every incomplete rollback is worded as one over a foreign session.
m=$(mutant n163 "$NDT" \
    '    elif (( UP_FOREIGN_SESSION )); then
' \
    '    elif true; then
')
report "N163: every incomplete rollback is worded as one over a foreign session" "$m" \
       "  and the advice is the usual one"

# The command named to stop this run's stack is always 'stack.sh down', which stops what was up before the run too.
m=$(mutant m357 "$NDT" \
    '    if (( ${#STACK_BEFORE[@]} == 0 )); then
        printf '"'"'%s'"'"' "bash tools/test_workflow/stack.sh down"
' \
    '    if true; then
        printf '"'"'%s'"'"' "bash tools/test_workflow/stack.sh down"
')
report "M357: the advice names 'stack.sh down' although part of the stack was up before the run" "$m" \
       "🔴 33p the advice does not name 'stack.sh down' (it would stop the kernel that was up before)"

# The line that says what is left of this run's is not printed.
m=$(mutant m358 "$NDT" \
    '            err "  what is left of this run'"'"'s: $what."
' \
    '')
report "M358: the incomplete rollback over a foreign session does not say what is left of this run's" "$m" \
       "🔴 33p and says what is left of this run's"

# Something of this run's is said to be left whatever the rollback did.
m=$(mutant m359 "$NDT" \
    '        if (( stack_left )); then
            local what="stack" cmd' \
    '        if true; then
            local what="stack" cmd')
report "M359: the incomplete rollback over a foreign session always says something of this run's is left" "$m" \
       "🔴 33p it does not say something of this run's is left"

# The unfinished-fabric record is written for a run that built no fabric, by whichever path asks.
m=$(mutant m362 "$NDT" \
    '    if (( UP_FOREIGN_SESSION )) && ! up_did_start fabric; then
        info "not recorded: this run built no fabric"' \
    '    if false; then
        info "not recorded: this run built no fabric"')
report "M362: the record is written over a foreign session that built no fabric" "$m" \
       "🔴 32e4 no unfinished record: this run built no fabric"

# An abandoned rollback over a foreign session sends the operator to 'ndt down'.
m=$(mutant m363 "$NDT" \
    '    if (( UP_FOREIGN_SESSION )); then
        # [Co-developed with claude code -- Adam] '"'"'ndt down'"'"' would end the topology session this run said is not its own.' \
    '    if false; then
        # [Co-developed with claude code -- Adam] '"'"'ndt down'"'"' would end the topology session this run said is not its own.')
report "M363: an abandoned rollback over a foreign session advises 'ndt down'" "$m" \
       "🔴 32e4 it does not send the operator to 'ndt down' to finish it"

# A refusal (rc 5) does not release the run marker.
m=$(mutant m364 "$NDT" \
    '    run_leave up "$prev"
    return "$rc"' \
    '    (( rc == 5 )) || run_leave up "$prev"
    return "$rc"')
report "M364: a bring-up that ends rc 5 keeps its run marker" "$m" \
       "🔴 31m and the run marker is released"

# The advice after an abandoned rollback names `stack.sh stop` with no name when nothing of the stack is known to be this run's.
m=$(mutant m365 "$NDT" \
    '    elif (( ${#STACK_STOPSET[@]} )); then
        printf '"'"'%s'"'"' "bash tools/test_workflow/stack.sh stop ${STACK_STOPSET[*]}"' \
    '    elif true; then
        printf '"'"'%s'"'"' "bash tools/test_workflow/stack.sh stop ${STACK_STOPSET[*]}"')
report "M365: an abandoned rollback over a foreign session names 'stack.sh stop' with no component" "$m" \
       "🔴 32e5 it names no 'stack.sh stop' (no part of the stack is known to be this run's)"

# The abandoned rollback's advice is 'stack.sh down' whatever was up before.
m=$(mutant m366 "$NDT" \
    '        cmd="$(up_foreign_stack_cmd)"
        (( open )) &&' \
    '        cmd="bash tools/test_workflow/stack.sh down"
        (( open )) &&')
report "M366: an abandoned rollback over a foreign session names 'stack.sh down' although the kernel was up before" "$m" \
       "🔴 32e6 and not 'stack.sh down' (the kernel from before would go with it)"

# A port of the stack this run stopped that cannot be read does not count as something of this run's left.
m=$(mutant m367 "$NDT" \
    '            left=1; stack_left=1
        fi
        if [[ -n "$held" ]]; then' \
    '            left=1
        fi
        if [[ -n "$held" ]]; then')
report "M367: a port that cannot be re-read is not something of this run's left" "$m" \
       "🔴 33r unreadable: it says what is left of this run's"

# A port of the stack this run stopped that is still held does not count as something of this run's left.
m=$(mutant m368 "$NDT" \
    '            done
            left=1; stack_left=1
' \
    '            done
            left=1
')
report "M368: a port still held is not something of this run's left" "$m" \
       "🔴 33r held: it says what is left of this run's"

# The fabric verb fails and the background stack.sh is only left without its FIFO.
m=$(mutant m369 "$NDT" \
    '        err "$ovs_verb failed"; up_bg_stack_stop
' \
    '        err "$ovs_verb failed"; exec 3>&-; rm -f "$fifo" "$out"
')
report "M369: a failed fabric verb leaves the background stack.sh running" "$m" \
       "🔴 33q busy refusal and it never went past its prompt (it did not go on to start a kernel)"

# The fabric has too few hosts and the background stack.sh is only signalled by pid.
m=$(mutant m370 "$NDT" \
    '        err "fabric has $live_hosts hosts, expected $ovs_hosts"
        up_bg_stack_stop
' \
    '        err "fabric has $live_hosts hosts, expected $ovs_hosts"
        exec 3>&-; kill "$stack_pid" 2>/dev/null; rm -f "$fifo" "$out"
')
report "M370: a fabric with too few hosts leaves the background stack.sh running" "$m" \
       "🔴 33q host count and it never went past its prompt (it did not go on to start a kernel)"

# Too few host/switch processes, same.
m=$(mutant m371 "$NDT" \
    '        err "fabric did not build: $n host/switch processes"
        up_bg_stack_stop
' \
    '        err "fabric did not build: $n host/switch processes"
        exec 3>&-; kill "$stack_pid" 2>/dev/null; rm -f "$fifo" "$out"
')
report "M371: a fabric with too few processes leaves the background stack.sh running" "$m" \
       "🔴 33q process count and it never went past its prompt (it did not go on to start a kernel)"

# stack.sh never reaches its prompt, same.
m=$(mutant m372 "$NDT" \
    '        up_bg_stack_stop
        rollback_up "Ryu never reached the Mininet prompt"' \
    '        exec 3>&-; kill "$stack_pid" 2>/dev/null; rm -f "$fifo" "$out"
        rollback_up "Ryu never reached the Mininet prompt"')
report "M372: a stack.sh that never reaches its prompt is left running" "$m" \
       "🔴 33q no prompt and it never went past its prompt (it did not go on to start a kernel)"

# `ndt help` does not say what the third signal does over a session that is not this run's.
m=$(mutant m373 "$NDT" \
    '                leaves the same record as a killed bring-up. Over a topology session that is
                not this run'"'"'s it names the stack command instead, when there is one ('"'"'ndt
                down'"'"' would end that session), and writes no record. A
' \
    '                leaves the same record as a killed bring-up. A
')
report "M373: ndt help does not name the abandoned rollback's exception" "$m" \
       "🔴 33s ndt help: over a session that is not this run's it names the stack command instead"

# Stopping the background stack.sh signals every process under it, including the components it started in sessions of their own.
m=$(mutant m374 "$NDT" \
    '                    [[ "$rest" == "$pg" ]] || continue
' \
    '                    true
')
report "M374: stopping the background stack.sh also stops Ryu, which the rollback then reports as not taken down" "$m" \
       "🔴 33t busy: the closing line says Ryu was taken down, and the kernel was left"

# `ndt help` says the stack command is named without condition.
m=$(mutant m375 "$NDT" \
    '                not this run'"'"'s it names the stack command instead, when there is one ('"'"'ndt
                down'"'"' would end that session), and writes no record. A
' \
    '                not this run'"'"'s it names the stack command instead ('"'"'ndt
                down'"'"' would end that session), and writes no record. A
')
report "M375: ndt help says the abandoned rollback always names the stack command" "$m" \
       "🔴 33s ndt help: the command is named only when there is one"

# The busy decision is made after the background stack.sh is stopped (a signal during the stop rolls back with the fabric still recorded).
m=$(mutant m376 "$NDT" \
    '        if topo_busy_said "$ovs_err"; then busy=1; up_unstarted fabric; UP_FOREIGN_SESSION=1; fi
        err "$ovs_verb failed"; up_bg_stack_stop
' \
    '        if topo_busy_said "$ovs_err"; then busy=1; fi
        err "$ovs_verb failed"; up_bg_stack_stop
        (( busy )) && { up_unstarted fabric; UP_FOREIGN_SESSION=1; }
')
report "M376: OVS: the busy decision is made after the background stack.sh is stopped" "$m" \
       "🔴 31m the session is known not to be this run's before the background stack.sh is stopped"

# The stop's answer kept by a separate assignment.
m=$(mutant w41 "$NDT" \
    'sudo -n "$LAB" topo-stop >/dev/null 2>&1 || stop_rc=$?; }' \
    'sudo -n "$LAB" topo-stop >/dev/null 2>&1; stop_rc=$?; }')
report_green "W41 (behaviour-preserving): the topo-stop's answer kept by a separate assignment" "$m" \
       "the same rc is kept"

# The two operands of the condition in the other order.
m=$(mutant w42 "$NDT" \
    '            if (( stop_rc == 0 )) && topo_busy_said "$tsout"; then
' \
    '            if topo_busy_said "$tsout" && (( stop_rc == 0 )); then
')
report_green "W42 (behaviour-preserving): the sentence and the stop's answer tested in the other order" "$m" \
       "neither test has a side effect"

# The stack advice written as an if.
m=$(mutant w43 "$NDT" \
    '            [[ -n "$cmd" ]] && err "  to stop only that:  $cmd"
' \
    '            if [[ -n "$cmd" ]]; then err "  to stop only that:  $cmd"; fi
')
report_green "W43 (behaviour-preserving): the stack advice written as an if" "$m" \
       "the same condition"

# --- rewordings and reorderings that must stay green ----------------------------------------------------

m=$(mutant w25 "$NDT" \
    '        *) err "  wait for it to finish; NDT_RUN_WAIT=<seconds> waits for it here instead of refusing." ;;' \
    '        *) err "  let it finish; or set NDT_RUN_WAIT=<seconds> to wait for it here." ;;')
report_green "W25 (behaviour-preserving): the wait advice reworded" "$m" \
       "the cells read who is running, not the advice"

m=$(mutant w26 "$NDT" \
    'printf '"'"'pid=%s\nat=%s\nby=%s\nstart=%s\npgid=%s\nverb=%s\nargv=%s\nphase=start\n'"'"' \
               "$$" "$(date '"'"'+%Y-%m-%dT%H:%M:%S%z'"'"')" "${NDT_OWNER:-unset}" "$ticks" "$pg" "$verb" "${argv//$'"'"'\n'"'"'/ }" > "$tmp" &&' \
    'printf '"'"'phase=start\nverb=%s\nargv=%s\npgid=%s\nstart=%s\nby=%s\nat=%s\npid=%s\n'"'"' \
               "$verb" "${argv//$'"'"'\n'"'"'/ }" "$pg" "$ticks" "${NDT_OWNER:-unset}" "$(date '"'"'+%Y-%m-%dT%H:%M:%S%z'"'"')" "$$" > "$tmp" &&')
report_green "W26 (behaviour-preserving): the marker's fields written in another order" "$m" \
       "every reader asks for a field by name"

m=$(mutant w28 "$NDT" \
    '    RUN_REMOVE_STALE=1 run_check_conflicts "$action" down up clean || return 5' \
    '    RUN_REMOVE_STALE=1 run_check_conflicts "$action" clean up down || return 5')
report_green "W28 (behaviour-preserving): the conflicting verbs asked in another order" "$m" \
       "any live one refuses"

# # The explanation under the verify line, reworded.
m=$(mutant w29 "$NDT" \
    '        info "everything was started and nothing is rolled back: the lab is up, and nothing has verified it."
' \
    '        info "nothing is rolled back: everything was started, so the lab is up and nothing has checked it."
')
report_green "W29 (behaviour-preserving): the verify handler's explanation reworded" "$m" \
       "the cells read the line that says it was not verified, not the explanation"

# The traps are set in another order.
m=$(mutant w30 "$NDT" \
    '    trap '"'"'up_on_signal TERM 143'"'"' TERM
    trap '"'"'up_on_signal HUP 129'"'"' HUP
' \
    '    trap '"'"'up_on_signal HUP 129'"'"' HUP
    trap '"'"'up_on_signal TERM 143'"'"' TERM
')
report_green "W30 (behaviour-preserving): TERM and HUP traps set in the other order" "$m" \
       "the order the three traps are set in changes nothing"

# The same comparison, written another way.
m=$(mutant w31 "$NDT" \
    '        (( UP_SIG_COUNT >= 3 )) && up_abandon_rollback "$sig" "$code"
' \
    '        (( UP_SIG_COUNT > 2 )) && up_abandon_rollback "$sig" "$code"
')
report_green "W31 (behaviour-preserving): the third signal counted as 'more than two'" "$m" \
       "the same count"

# The verbs asked for a live marker, in another order.
m=$(mutant w32 "$NDT" \
    '    for v in up down clean; do
        run_marker_look "$v"; lrc=$?' \
    '    for v in clean down up; do
        run_marker_look "$v"; lrc=$?')
report_green "W32 (behaviour-preserving): the run row looks at the verbs in another order" "$m" \
       "one verb is live at a time in every cell"

# The same test, written as two.
m=$(mutant w33 "$NDT" \
    '    [[ -e "$f" || -L "$f" ]] || return 0
' \
    '    [[ -e "$f" ]] || [[ -L "$f" ]] || return 0
')
report_green "W33 (behaviour-preserving): the record's existence test written as two" "$m" \
       "the same condition"

# The same comparison, written another way.
m=$(mutant w34 "$NDT" \
    '    if (( rc == 0 )); then up_unfinished_clear "this bring-up verified"
    elif up_phase_is_verify "${RUN_PHASE:-}"; then up_unfinished_record; fi
' \
    '    if (( ! rc )); then up_unfinished_clear "this bring-up verified"
    elif up_phase_is_verify "${RUN_PHASE:-}"; then up_unfinished_record; fi
')
report_green "W34 (behaviour-preserving): rc 0 tested as 'not rc'" "$m" \
       "the same count"

# The warning for a record that could not be written, reworded.
m=$(mutant w35 "$NDT" \
    '            warn "  the record could not be written, so the next '"'"'ndt up p4'"'"' cannot tell that this one died: it may reuse what is up."' \
    '            warn "  nothing could be written for it, so a later '"'"'ndt up'"'"' will not know this one died and may reuse what is up."')
report_green "W35 (behaviour-preserving): the could-not-record warning reworded" "$m" \
       "no cell reads that sentence"


echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
NOW_CFG=$(sha256sum "$NTGCFG" | cut -d' ' -f1)
if [[ "$NOW_CFG" != "$BASE_CFG" ]]; then
    echo "🔴 baseline CHANGED during the gate -- p4_proxy/mininet/ntg_config.py was written"
    echo "   before: $BASE_CFG"
    echo "   after:  $NOW_CFG"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_NDT"
echo "baseline byte-identical: yes  p4_proxy/mininet/ntg_config.py  sha256 $BASE_CFG"
# 🔴 A DEAD MUTANT MEANS THERE IS NO VERDICT TO PRINT. Not "0 survived" (it was
# never measured), not "1 survived" (that is a claim about the SUITE, and the suite never ran
# against a working mutant). The gate refuses, the way it refuses a red baseline -- and it must
# not print a `N mutations, N survived` line at all, because that line is what every reader,
# every log scraper and this gate's own report table take as the result.
if [[ "$DEAD" -gt 0 ]]; then
    echo "🔴 REFUSED: $DEAD mutant(s) are not valid bash -- see the DEAD line(s) above."
    echo "   A mutant that does not parse reddens every cell for one reason (it cannot run) and"
    echo "   leaves the named cell absent, which is indistinguishable from green. This gate"
    echo "   measured nothing for those mutations, so it prints no verdict for any of them."
    exit 2
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived, $DEAD dead"
[[ "$SURVIVORS" -eq 0 ]]
