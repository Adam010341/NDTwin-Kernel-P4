#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_honesty.sh (09-05 night round: I-1/W12).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of the finding -- the `ndt status`/`--check` that answered
# "no 'ndt up' has run in this checkout" and named a P4 model file, minutes after an OVS fabric
# had been built and torn down in that same checkout -- and must turn its NAMED case red. A
# mutation nobody catches means that case proves nothing.
#
# 🔴 Two directions. The mutations labelled (widening) are the ones that stay GREEN where the
# suite requires RED: one that claims a `down` happened whether or not anything says so, and
# one that answers "could not check" to everything. Each satisfies every "did it go red on the
# broken fixture" question a fires-only gate asks, and each puts back the property the finding
# is about -- a report that states things it was never told.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it right now, and the lab was in use the night this was added --
# and the sha256 line at the bottom says so.
#
# 🔴 A mutant directory carries ports.sh and sudo_surface.sh too. ndt sources both from beside
# itself, so a copy without them exits 2 at source time and every case goes red for a reason
# that has nothing to do with the mutation (MERGE-LOG.md, 09-03).
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_honesty.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-honesty-mutate-XXXXXX")
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
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole directory: ndt sources ports.sh and sudo_surface.sh from beside itself, so
# they travel with it, unmutated. The anchor must be unique, so a mutation cannot quietly land
# somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
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

# --- I-1: the report states things it was never told -----------------------------------------

# The evidence is stopped being read at all. Everything downstream then honestly says "this
# checkout cannot tell" -- which is right for 1C and wrong for 1A, where the file is there.
m=$(mutant m1 "$NDT" \
    'kernel_exit_file() { echo "${NDT_KERNEL_EXIT:-$REPO/.test_run/pids/kernel.exit}"; }' \
    'kernel_exit_file() { echo "${NDT_KERNEL_EXIT:-$REPO/.test_run/pids/never-written}"; }')
report "M1: the exit record is no longer read" "$m" \
       "🔴 the record line names the clearing, and when"

# I-1 verbatim: the absence of a record rendered as a claim about history.
m=$(mutant m2 "$NDT" \
    '"${Y}none -- the last '\''ndt up'\'' record was cleared by '\''ndt down'\'' at $kx_at; history is in .test_run/pids/*.exit${N}  (${f#$REPO/})"' \
    '"${Y}none -- no '\''ndt up'\'' has run in this checkout${N}  (${f#$REPO/})"')
report "M2: 'no ndt up has run in this checkout' comes back" "$m" \
       "🔴 the sentence that was false is gone"

# The other half of I-1, and the carrier that actually misled a script: the P4-only knob's model
# file printed on the `topology` row, where a reader takes it for the plane that just ran.
m=$(mutant m3 "$NDT" \
    'printf '\''  %-14s %s\n'\'' "topology" "unknown (no up.target); last kernel.exit ran $kx_plane"' \
    'printf '\''  %-14s %s\n'\'' "topology" "${topo#$REPO/}   (the P4 model that knob selects)"')
report "M3: the P4 model is printed as the topology again" "$m" \
       "🔴 no P4 model file is printed -- that path was the carrier"

# The plane is asserted rather than read. A constant satisfies every OVS case in the suite,
# which is why 1D exists.
m=$(mutant m4 "$NDT" \
    '        kx_plane="$(last_kernel_plane)"; kx_at="$(kernel_exit_field at)"' \
    '        kx_plane=ovs; kx_at="$(kernel_exit_field at)"')
report "M4: the plane is a constant, not a reading" "$m" \
       "'last kernel.exit ran p4' after a P4 run"

# Finding #7's conflation in a new place: a command this script cannot classify turned into a
# plane anyway. "I could not tell" and "it was ovs" are different answers.
m=$(mutant m5 "$NDT" \
    '        *StaticNetworkTopologyP4_*)  echo p4;  return 0 ;;
    esac
    return 1' \
    '        *StaticNetworkTopologyP4_*)  echo p4;  return 0 ;;
    esac
    echo ovs; return 0')
report "M5: an unclassifiable command becomes a plane" "$m" \
       "  rather than picking one"

# --- I-4: the note outlives the fact it describes ---------------------------------------------

# The repair that caused I-2 residue #1: correcting a sentence through `ndt claim`, which
# rewrites the whole file and pushes the lease out by another window. The note is then true and
# the expiry is fiction.
m=$(mutant m6 "$NDT" \
    '    tmp="$f.$$.tmp"' \
    '    cmd_claim 180 "$text" >/dev/null 2>&1; return $?
    tmp="$f.$$.tmp"')
report "M6: the note is corrected by re-claiming, moving the lease" "$m" \
       "🔴 expires is byte-identical -- not pushed out"

m=$(mutant m7 "$NDT" \
    '    [[ -n "${NDT_OWNER:-}" && "$owner" == "$NDT_OWNER" ]] || return 1' \
    '    :')
report "M7: any session may rewrite anyone's note" "$m" \
       "someone else's claim is refused"

m=$(mutant m8 "$NDT" \
    '    [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > $(date +%s) )) || return 1' \
    '    [[ "$exp" =~ ^[0-9]+$ ]] || return 1')
report "M8: an expired claim is still narrated" "$m" \
       "an expired claim is refused"

# 🔴 THE WIRING. set_claim_note can exist, be correct, and be called by nothing -- and then the
# note goes on saying whatever the last arm_*.sh wrapper wrote, which is I-4 exactly.
m=$(mutant m9 "$NDT" \
    '    claim_note_up "ovs $ovs_hosts"' \
    '    :')
report "M9: ndt up ovs stops writing the note" "$m" \
       "the note says the lab is in use"

m=$(mutant m10 "$NDT" \
    '    claim_note_up "p4 $hosts"' \
    '    :')
report "M10: ndt up p4 stops writing the note" "$m" \
       "the note names the P4 target"

m=$(mutant m11 "$NDT" \
    '    claim_note_down "$down_rc" "$CLEAN_UNVERIFIED"' \
    '    :')
report "M11: ndt down leaves 'in use' standing over an empty lab" "$m" \
       "🔴 it no longer says the lab is in use"

# The same conflation this repository keeps finding: an unverified outcome reported as a
# verified one. "down" and "down, and something survived" license opposite actions.
#
# 🔴 REPOINTED 2026-09-11: this anchor was `set_claim_note "down at $when; claim kept"`, and the
# T5 commit appended the cleared-measuring suffix to that line. check_gate_anchors.py HEAD read
# MISSING:1 for it -- which is what the checker is for, and which the gate itself would have
# reported as a SURVIVOR because an applier that cannot apply is a hole and never a skip.
# 🔴 REPOINTED AGAIN 2026-09-12 (FIX-NDT-7 item 3): the branch now turns on what `verify clean`
# could not verify rather than on the rc, and its sentence gained the half that failed. The
# mutation is the same one -- take the "did not verify" branch away -- said against the new
# condition.
# 🔴 REPOINTED AGAIN 2026-09-12 (FIX-NDT-8): a teardown that had nothing to tear down now has
# its own branch above this one, so the "verified clean" branch is an `elif`. The mutation is
# unchanged -- take the "did not verify" branch away.
m=$(mutant m12 "$NDT" \
    '    elif [[ -z "$unverified" ]]; then' \
    '    elif true; then')
report "M12: a teardown that did not verify is reported as clean" "$m" \
       "🔴 a teardown that did not verify says so"

# --- O-4: the teardown command reaps the evidence ---------------------------------------------

# The tidy-up that would put O-4 back from the other end: `ndt clean` deleting the rotated
# generations. It looks like housekeeping and it destroys the record of the run you have just
# finished -- at exactly the moment you are about to write it up.
m=$(mutant m13 "$NDT" \
    'cmd_clean() {
    local rc=0 n p' \
    'cmd_clean() {
    local rc=0 n p
    rm -f "$REPO"/.test_run/logs/kernel.log.[0-9]*')
report "M13: 'ndt clean' tidies away the rotated kernel logs" "$m" \
       "🔴 every rotated generation is still there"

# --- R4-2 / R4-5: the check that would not run, and the verdict that said too little ----------

# R4-2 verbatim: the refusal goes back to the process table, so any iperf3 client blocks the one
# command that needs traffic in order to say anything.
m=$(mutant m14 "$NDT" \
    '    local declared; declared="$(measuring_declared)"
    if [[ -n "$declared" && "${1:-}" != "--force" ]]; then' \
    '    local declared; declared="$(in_flight)"
    if [[ -n "$declared" && "${1:-}" != "--force" ]]; then')
report "M14: 'ndt check' refuses on observed traffic again" "$m" \
       "🔴 iperf3 clients with nothing declared: rc 0"

# 🔴 THE OTHER DIRECTION, and the one that would do real damage: no refusal at all. Every case in
# 4B passes, and the sampling-rate matrix loses the guard that stops this 4 Hz poll refilling a
# poll-off cell. "Stop refusing so much" has exactly this wrong answer.
m=$(mutant m15 "$NDT" \
    '    if [[ -n "$declared" && "${1:-}" != "--force" ]]; then' \
    '    if false; then')
report "M15 (widening): 'ndt check' never refuses at all" "$m" \
       "a declared measurement is refused, rc 1"

m=$(mutant m16 "$NDT" \
    '        "${NDT_MEASURING:-}" > "$CLAIM"' \
    '        "" > "$CLAIM"')
report "M16: the claim stops carrying the declaration" "$m" \
       "NDT_MEASURING lands in the claim file"

# An expired claim holds nothing, so it declares nothing. Without this, a declaration outlives
# the lease that authorised it and blocks `ndt check` for ever.
m=$(mutant m17 "$NDT" \
    '    local exp; exp="$(claim_field expires)"
    [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > $(date +%s) )) || return 0
    claim_field measuring' \
    '    claim_field measuring')
report "M17: an expired claim still declares a measurement" "$m" \
       "🔴 an expired claim declares nothing"

# 🔴 The regression this whole design exists to avoid: `status` reporting only what was declared.
# I-4 was caught because that row showed 16 iperf3 processes next to a note saying "lab free". A
# status that renders declarations only would have shown nothing at all.
m=$(mutant m18 "$NDT" \
    '    local busy; busy="$(in_flight)"
    if [[ -n "$busy" ]]; then
        local extra;' \
    '    local busy; busy="$(measuring_declared)"
    if [[ -n "$busy" ]]; then
        local extra;')
report "M18: 'ndt status' renders declarations instead of processes" "$m" \
       "🔴 undeclared traffic is still reported by status"

# R4-5's tempting wrong fix, which Adam ruled against in grill round 4: narrow the band until the
# 12/12 low readings go red. That turns a double-count tripwire into a calibration check it was
# never designed to be, and the fix chosen instead was to say how big the gap is.
m=$(mutant m19 "$NDT" \
    '    elif ratio < 0.5:' \
    '    elif ratio < 0.9:')
report "M19 (wrong fix): the ok band narrowed to catch R4-5" "$m" \
       "🔴 the band did not move: 0.85 is still ok"

m=$(mutant m20 "$NDT" \
    '        "  ratio=%.3f           (twin %.1f / ground truth %.1f Mbit/s)"' \
    '        ""')
report "M20: the ratio and its two sides are not printed" "$m" \
       "R4-5's own numbers: the ratio is printed as a value"

m=$(mutant m21 "$NDT" \
    '        % ("under" if ratio < 1.0 else "over", abs(1.0 - ratio) * 100.0,' \
    '        % ("over" if ratio < 1.0 else "under", abs(1.0 - ratio) * 100.0,')
report "M21: under-reporting is reported as over-reporting" "$m" \
       "🔴 and the size of the gap in words"

# --- #17: the tripwire named a mechanism it had not observed, and its rc said nothing ---------
#
# 🔴 NUMBERED FROM M40, and the gap is deliberate: this gate already had an M22-M28 (F12/B10/
# F9/F10, from FIX-NDT-2) and the first draft of this block reused those labels. Both sets ran
# and both were caught -- the mutant directory is created immediately before each run, so no
# verdict was wrong -- but the LOG then carried two different "M22" lines, and a log you cannot
# read back is not evidence. Found by grepping this gate's own output for duplicate labels
# (2026-09-11, FIX-NDT-4).
#
# ROLE-5 2026-09-11 (logs/ROLE-5/18-posctrl-L2-live.log): one netem link failure read 1.60 and
# the tripwire called it `clone replicas stacked`, with `check rc=0`. Each mutation below puts
# back one half of that.

m=$(mutant m40 "$NDT" \
    '        verdict = "DOUBLE-COUNTING -- twin is %.2fx ground truth" % ratio' \
    '        verdict = "DOUBLE-COUNTING -- clone replicas stacked"')
report "M40: the verdict names a mechanism it did not observe" "$m" \
       "🔴 but it does NOT name clone replicas as the finding"

m=$(mutant m41 "$NDT" \
    '    ] + (cause_lines(ratio, shape) if ratio > 1.5 else [])' \
    '    ]')
report "M41: the two causes are never printed at all" "$m" \
       "🔴 it names the twin lagging the truth as a cause"

m=$(mutant m42 "$NDT" \
    '    shape = window_shape(subs)' \
    '    shape = None')
report "M42: the window shape never reaches the verdict" "$m" \
       "🔴 and the window shape really reaches it"

# (widening) Every ratio over the band is called a lag, including the constant factor over a
# steady truth that this tripwire exists for. A verdict that only ever says "two things could
# have done this" is not a tripwire.
m=$(mutant m43 "$NDT" \
    '    if hot == subs and steady:' \
    '    if False:')
report "M43 (widening): a constant factor is called a transient too" "$m" \
       "🔴 a constant factor over a steady truth IS the stack shape"

# (widening) The other direction on the same decision: everything is called the stack shape,
# so ROLE-5's link failure is reported as replicas again with an evidence line under it.
m=$(mutant m44 "$NDT" \
    '    steady = hi <= lo * 1.25' \
    '    steady = True
    hot = subs')
report "M44 (widening): every window is called steady and hot" "$m" \
       "🔴 with the evidence that separates them"

m=$(mutant m45 "$NDT" \
    '    if twin_bps / truth_bps > 1.5:
        sys.exit(4)' \
    '    pass')
report "M45: the block stops carrying the verdict out" "$m" \
       "🔴 the block exits 4 when the ratio is over the band"

m=$(mutant m46 "$NDT" \
    '        err "ndt check: rc $vrc -- read the ratio block above; this is not '"'"'the check failed to run'"'"'"
        return "$vrc"' \
    '        :')
report "M46: the command swallows the rc the block produced" "$m" \
       "🔴 a DOUBLE-COUNTING verdict reaches the caller as rc 4"

# --- widenings: mutants that stay GREEN where the suite requires RED --------------------------

# N1: a `down` is announced whether or not anything recorded one. It passes every fires-side
# case in 1A/1B, because a report that always says the new sentence cannot fail to say it.
m=$(mutant n1 "$NDT" \
    '        if [[ -n "$kx_at" ]]; then
            printf' \
    '        if true; then
            printf')
report "N1 (widening, green): a teardown is announced unconditionally" "$m" \
       "🔴 no 'cleared by ndt down' without a record of one"

# N2, the control: --check answers "could not check" to everything. Every case in 1A-1D is about
# the no-record path, so all of them stay green while the check stops checking.
m=$(mutant n2 "$NDT" \
    '    say "up target"
    if [[ ! -f "$f" ]]; then' \
    '    say "up target"
    if true; then')
report "N2 (control, never checks): every lab has no baseline" "$m" \
       "  and --check checks: rc 0, not 3"

# --- F12 / B10: the help text, which nothing was reading (F-OFFLINE-1 §1.12, §1.24) ----------

# F12 verbatim. Until 2026-09-11 the help defined rc 3 with the very sentence W12 had removed
# from the output as false, and 78 green cells in this suite said nothing, because not one of
# them looked at `ndt help`. This mutation puts it back.
m=$(mutant m22 "$NDT" \
    'message names it); 3 nothing was compared, because there is
                  no baseline RIGHT NOW' \
    'message names it); 3 nothing was compared, because no '\''ndt up'\''
                  has run in THIS checkout')
report "M22: help defines rc 3 by history again (F12)" "$m" \
       "  🔴 the sentence W12 removed from the output is gone from the help too"

# The half of F12 that a "delete the offending words" fix would leave broken: rc 3 has TWO
# return sites (no record, ndt:2991; a record nobody can read, ndt:3001) and the help has to
# name both. This mutation keeps the tense honest and drops the second cause.
m=$(mutant m23 "$NDT" \
    'ordinary up->down clears it) or unreadable.' \
    'ordinary up->down clears it).')
report "M23: help names only one of rc 3's two causes" "$m" \
       "  🔴 and 'unreadable' as the other -- rc 3 has two return sites"

# B10. The blanket claim comes back -- the one the overnight-hunt skill sent a whole round to
# falsify, which is true only of the failure mode it names and reads as "this cannot happen".
m=$(mutant m24 "$NDT" \
    'It does NOT make the 4-host-model-against-a-128-host-fabric mistake
  impossible: inside one tree the host count is whatever that file says' \
    'The 4-host-model-against-a-128-host-fabric mistake cannot be made by forgetting an
  environment variable: inside one tree the host count is whatever that file says')
report "M24: the blanket host_count_override claim comes back (B10)" "$m" \
       "  🔴 the blanket 'cannot be made' claim is gone"

# The other direction on B10: the scope is right and the counter-example is dropped, so the
# help says what the knob does not do without saying that it has already been done.
m=$(mutant m25 "$NDT" \
    "and on 09-05 setting it built exactly that pair (R3-3)." \
    "and nobody has ever done so.")
report "M25: B10 loses its 09-05 counter-example" "$m" \
       "  with the 09-05 counter-example"

# --- F9: the suite reads its own tree (F-OFFLINE-1 §1.13) -------------------------------------

# The sim evidence log stops being derived from the tree the LAB acts in and is hard-coded to
# the main checkout, which is what this suite was reading until 2026-09-11 -- a 148717-byte
# root-owned file. The F9 cells exist to make that a red rather than a hidden input, and this
# is the mutation that asks them to prove it.
m=$(mutant m26 "$NDT" \
    '        sim)    printf '"'"'%s/.test_run/logs/app_sim.log'"'"' "$(lab_kernel_dir)" ;;' \
    '        sim)    printf '"'"'%s/.test_run/logs/app_sim.log'"'"' /home/adam/Desktop/NDTwin-Kernel ;;')
report "M26: sim's evidence log is hard-coded to the main checkout (F9)" "$m" \
       "  🔴 sim's evidence log is inside the fixture"


# --- F10: the default round's model (F-OFFLINE-1 §1.15) ---------------------------------------

# M27 restores F10: last_kernel_plane matches only OVS_* and P4_*, so the model the DEFAULT
# round loads -- StaticNetworkTopologyMininet_10Switches.json, 128 hosts -- is unclassifiable,
# and `ndt up; ndt down` cannot say what plane just ran.
m=$(mutant m27 "$NDT" \
    '        *StaticNetworkTopologyMininet_*) echo ovs; return 0 ;;' \
    '        ' )
report "M27: the default round's Mininet_* model is unclassifiable again (F10)" "$m" \
       "  🔴 a Mininet_* model reads as ovs"

# M28 (widening): everything is ovs. It satisfies both Mininet_* cells and destroys 1D/1F --
# "I could not tell" and "it was ovs" are different answers, which is what this block is for.
m=$(mutant m28 "$NDT" \
    '        *StaticNetworkTopologyMininet_*) echo ovs; return 0 ;;
        *StaticNetworkTopologyP4_*)  echo p4;  return 0 ;;
    esac
    return 1' \
    '        *StaticNetworkTopologyMininet_*) echo ovs; return 0 ;;
        *StaticNetworkTopologyP4_*)  echo p4;  return 0 ;;
    esac
    echo ovs; return 0')
report "M28 (widening): every command is read as ovs" "$m" \
       "  🔴 a physical-mode command is still rc 1"

# --- F2 / F4: the help's rc tables (F-OFFLINE-1 §1.16) ----------------------------------------

# M29 restores F2: the help says residue found is rc 1, full stop -- false in the state every
# round ENDS in, because `ndt down` clears the baseline and the whole report is then rc 3.
m=$(mutant m29 "$NDT" \
    '                  residue FOUND is a problem, and it is rc 1 ONLY while there is a' \
    '                  residue FOUND is a problem (rc 1). and it is rc 1 whenever there is a')
report "M29: help says residue found is always rc 1 (F2)" "$m" \
       "  🔴 rc 1 is scoped to 'while there is a baseline'"

# M30 restores F4: the `apps orphans` table presents itself as disjoint, so a gate reads rc 2
# as "no residue" -- and rc 2 is the ordinary answer on this machine.
m=$(mutant m30 "$NDT" \
    '                    🔴 THE CODES ARE NOT DISJOINT IN PRACTICE: the PROCESS answer' \
    '                    The codes are disjoint: the PROCESS answer')
report "M30: help calls the orphans rc table disjoint again (F4)" "$m" \
       "  🔴 the rc table says it is not disjoint"


# --- T1: the claim was a check-then-write two sessions could both win (ROLE-4) ----------------

# The lock is not taken at all, which is 2026-09-11 01:53 exactly: check, then write, with a
# window in between that two same-second claims both got through.
m=$(mutant mc1 "$NDT" \
    '        flock -w "$w" 9 || {' \
    '        true || {')
report 'MC1: the claim is written without taking the lock' "$m" \
       '🔴 it gives up rather than writing'


# 🔴 The lock WITHOUT the second reading, which is the shape a fix that only reaches for flock
# arrives in: the critical section is serialised and then decides on a value read before it.
m=$(mutant mc2 "$NDT" \
    'claim_take() {   # claim_take <mins> <note> <the pre-lock foreign_claim reading> -- under the lock
    local mins="$1" note="$2" before="$3"
    local other; other="$(foreign_claim)"' \
    'claim_take() {   # claim_take <mins> <note> <the pre-lock foreign_claim reading> -- under the lock
    local mins="$1" note="$2" before="$3"
    local other=""')
report 'MC2: the reading inside the lock is not taken -- only the one before it' "$m" \
       '🔴 the loser is refused'


# 🔴 The other direction. "Say it was a race" satisfies MC2's cell and tells everyone refused by
# an hour-old claim to go looking for a session that is not there.
m=$(mutant mc3 "$NDT" \
    '        if [[ -z "$before" ]]; then' \
    '        if true; then')
report 'MC3 (widening): every refusal says somebody just beat you to it' "$m" \
       '🔴 not '"'"'beaten to it'"'"' -- that points the reader at the wrong minute'


# R7 I-2: lab.claim was the one state file overwritten with nothing kept, so a claim that changed
# hands mid-round left no trace in any interface.
m=$(mutant mc4 "$NDT" \
    '    if [[ -f "$CLAIM" ]]; then
        cp -f "$CLAIM" "$CLAIM.prev" 2>/dev/null \' \
    '    if false; then
        cp -f "$CLAIM" "$CLAIM.prev" 2>/dev/null \')
report 'MC4: the claim being replaced is overwritten with no copy kept (R7 I-2)' "$m" \
       '🔴 and the claim it replaced is still readable'


# The readback goes and the lock stays. Every cell about the lock passes; the writer this tool's
# own header invites -- a script writing .test_run/lab.claim directly, holding no lock -- is back
# to overwriting a claim whose owner is then told it holds the lab.
m=$(mutant mc5 "$NDT" \
    '    if [[ "$back" != "$NDT_OWNER" ]]; then' \
    '    if false; then')
report 'MC5: the write is not read back, so a direct writer wins silently' "$m" \
       'a claim that is not ours after the write is refused'


# --- T2 / T2d: measuring= enforced, and a rescue command that can be pasted ------------------

# 2026-09-11 01:57:27 verbatim: claim says `measuring=ROLE-4 reader nsr, do not tear down`, the
# owner's own `ndt down` tears the fabric out, prints clean, exits 0, kills the declared reader
# and never mentions the field.
m=$(mutant mc6 "$NDT" \
    '    if [[ -n "$declared" && "$force" != "--force" ]]; then
        err "refusing to tear down: this claim DECLARES a measurement in progress."' \
    '    if false; then
        err "refusing to tear down: this claim DECLARES a measurement in progress."')
report 'MC6: the teardown stops reading measuring= (T2d verbatim)' "$m" \
       'a declared measurement refuses the teardown, rc 5'


# 🔴 A guard any second flag switches off. --deep is what an operator reaches for when a teardown
# did not reach clean -- which is when a declared measurement is most likely to still be there.
m=$(mutant mc7 "$NDT" \
    '    if [[ -n "$declared" && "$force" != "--force" ]]; then
        err "refusing to tear down: this claim DECLARES a measurement in progress."
        err "    measuring=$declared"' \
    '    if [[ -n "$declared" && "$force" != "--force" && -z "$deep" ]]; then
        err "refusing to tear down: this claim DECLARES a measurement in progress."
        err "    measuring=$declared"')
report 'MC7 (widening): --deep turns the guard off as well as --force' "$m" \
       '🔴 --deep does not override a declaration'


# 01:56:53 verbatim: `NDT_OWNER=overnight-0905 (until 02:36:24, ROLE-4 T2/T3: reader running) ndt
# down`, printed under "set the same owner and retry", which bash reads as a subshell.
m=$(mutant mc8 "$NDT" \
    '        err "$(printf '"'"'    NDT_OWNER=%q ndt down'"'"' "$holder")"' \
    '        err "    NDT_OWNER=$held ndt down"')
report 'MC8: the rescue line interpolates the description again (T2 verbatim)' "$m" \
       '🔴 that line parses as shell -- it is printed to be pasted'


# `ndt status` had a row for measuring= and the message that stops somebody tearing the lab down
# did not -- so the one sentence the holder wrote FOR this moment was missing at it.
m=$(mutant mc9 "$NDT" \
    '        declared="$(measuring_declared)"
        if [[ -n "$declared" ]]; then
            err "and they DECLARED what is running, which is what this would destroy:"' \
    '        declared="$(measuring_declared)"
        if false; then
            err "and they DECLARED what is running, which is what this would destroy:"')
report 'MC9: the foreign refusal stops quoting what they declared' "$m" \
       '🔴 and the foreign refusal quotes the declaration'


# --- T5: the note that failed silently, the declaration that outlived its teardown -----------

# 01:55:07 against 01:59:53: the same `ndt up ovs 4`, and with NDT_OWNER unset it built a fabric
# while the note went on describing the previous round, silently.
m=$(mutant mc10 "$NDT" \
    'claim_note_unwritten() {
    [[ -f "$CLAIM" ]] || return 0' \
    'claim_note_unwritten() {
    return 0
    [[ -f "$CLAIM" ]] || return 0')
report 'MC10: the failed note write is swallowed again (T5 verbatim)' "$m" \
       '🔴 a live claim we do not hold: warned, not swallowed'


# 🔴 "Stop swallowing failures" with no thought about which failures: a line on every teardown of
# an unreserved lab, which is how a warning stops being read before the one that matters.
m=$(mutant mc11 "$NDT" \
    'claim_note_unwritten() {
    [[ -f "$CLAIM" ]] || return 0
    local exp; exp="$(claim_field expires)"
    [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > $(date +%s) )) || return 0' \
    'claim_note_unwritten() {
    local exp; exp="$(claim_field expires)"')
report 'MC11 (widening): it warns even when there is no claim to narrate' "$m" \
       '🔴 no claim at all: silent, there is nothing to narrate'


# 01:57:54 verbatim: `measuring=ROLE-4 reader nsr, do not tear down` still in the claim after the
# down that killed that reader -- the declaration outlived the teardown that disproved it.
m=$(mutant mc12 "$NDT" \
    '            claim_rewrite measuring "" \' \
    '            true \')
report 'MC12: the teardown leaves the declaration it just falsified' "$m" \
       '🔴 measuring= is empty afterwards'

# 🔴 RE-ANCHORED 2026-09-11 (FIX-NDT-4 #20): the five fields now have ONE writer, claim_write,
# because lab.claim and lab.claim.prev were coming out of two printfs in different orders
# (R7-reconciler.md section 3b). The mutation is the same defect -- the note appended, so it
# migrates to the last line every time it is corrected -- applied at the one call site left.
m=$(mutant mc13 "$NDT" \
    '        claim_write "$owner" "$exp" "$note" "$ecpu" "$meas"' \
    '        sed '"'"'/^note=/d'"'"' "$f"; printf '"'"'note=%s\n'"'"' "$note"')
report 'MC13: the note is appended again, so it migrates to the last line' "$m" \
       '🔴 and note did not migrate to the last line'


# 🔴 The data loss dressed as a tidy-up: this file's own header invites scripts to write it, so a
# rewrite that knows only its five fields deletes whatever else is in there.
m=$(mutant mc14 "$NDT" \
    '        grep -v -e '"'"'^owner='"'"' -e '"'"'^expires='"'"' -e '"'"'^note='"'"' -e '"'"'^exclusive_cpu='"'"' -e '"'"'^measuring='"'"' "$f" || true' \
    '        true')
report 'MC14: a field another script wrote is dropped by the rewrite' "$m" \
       '  a field another script wrote is carried through'


# --- T3 / T4: two sentences that described the tool wrongly ----------------------------------

# The sentence and the code that disproves it were in the same file: cmd_down's [0/3] gate is
# app_probe, so an untracked app is exactly the one it stops (G-6), measured 01:57:54.
m=$(mutant mc15 "$NDT" \
    '        printf '"'"'  %-14s %s\n'"'"' "" "'"'"'ndt down'"'"' does stop these -- it scans for them rather than"' \
    '        printf '"'"'  %-14s %s\n'"'"' "" "these survive '"'"'ndt down'"'"'; stop them with '"'"'ndt apps stop <name>'"'"'"')
report 'MC15: status says untracked apps survive a teardown again (T3)' "$m" \
       '🔴 the sentence that round'"'"'s teardown disproved is gone'


# T4 is NOT fixed -- whether the API should read the claim is Adam's decision -- so the help
# saying so is the whole of the deliverable, and a paragraph with no test is what F12 was.
m=$(mutant mc16 "$NDT" \
    '    a claim only blocks the '"'"'ndt'"'"' verbs. It is not the northbound API and it is not' \
    '    a claim is how sessions keep out of each other'"'"'s way.')
report 'MC16: the help stops saying what a claim does not cover (T4)' "$m" \
       '  the help scopes the claim to this tool'"'"'s own verbs'


# --- 09-12: the three paragraphs ROLE-11 and ROLE-12 put into the rc tables --------------------

# MD1: the `down` table stops saying that a port held at [1/3] is not by itself a failure. The
# rc changed under the operator on 09-12 (7 of 7 live P4 teardowns were red, then green); a
# table that does not carry the reason is how the next reader reconciles the two by guessing.
m=$(mutant md1 "$NDT" \
    '                  🔴 A PORT HELD AT [1/3] IS NOT BY ITSELF A FAILED TEARDOWN.' \
    '                  A port still held anywhere in the teardown is a failed teardown.')
# 🔴 The named case is the HEADING cell, repointed 2026-09-12 03:58 after this gate reported
# MD1 as a survivor twice: the body cells all read sentences this mutation leaves alone, so the
# only cell that can see it is the one that reads the claim the paragraph is making.
report 'MD1: the down table drops the port-at-[1/3] paragraph (ROLE-12)' "$m" \
       '  🔴 the paragraph says its claim in its own heading'

# MD2: the `clean` table stops documenting the refusal. A guard nobody is told about is read as
# a malfunction the first time it fires, and this one fires on the command the manual sends a
# first-time reader to.
m=$(mutant md2 "$NDT" \
    '                  🔴 it REFUSES while an '"'"'ndt down'"'"' from this checkout is running,' \
    '                  it is safe to run at any time,')
report 'MD2: the clean table drops the refusal (ROLE-12 cell 3)' "$m" \
       '  🔴 the refusal is documented at all'

# MD3: the --deep line's size is TYPED beside the table instead of read out of it. Every text
# cell about that sentence still passes; it goes stale again the day a row is added, which is
# exactly how it came to say three while deep_sweep swept 27.
# 🔴 Anchored on the ASSIGNMENT, repointed 2026-09-12 03:58. Rewriting the heredoc's `$NDT_DEEP_SIZE`
# into the same literal changes no output and leaves the computation in the file, so the gate
# reported it as a survivor -- correctly. What the cell is about is where the number COMES FROM.
m=$(mutant md3 "$NDT" \
    '        NDT_DEEP_SIZE="$(ndt_port_table_size all)"' \
    '        NDT_DEEP_SIZE="9 rule(s), 27 port(s)"')
report 'MD3: the --deep size is typed rather than computed (ROLE-11 F7)' "$m" \
       '  the size in the help is computed, not typed'


# --- FIX-NDT-8: the three rc tables say one thing (Adam, 2026-09-12) ---------------------------

# MD4: `up` loses its rc table again. It had none at all until today, which is why a refused
# bring-up and a bring-up that found a stray both read as "1" to every script in this repo.
m=$(mutant md4 "$NDT" \
    '                  exit 0 the fabric came up and verified; 1 something was MEASURED and' \
    '                  (this command prints what it found; read the block above.)')
report 'MD4: the up table is removed again' "$m" \
       '  🔴 up has an rc table at all'

# MD5: the table keeps 5 and drops the sentence that says what 5 IS. A code with no meaning
# beside it is a number an operator guesses at -- and the guess available here is "worse than 1".
m=$(mutant md5 "$NDT" \
    '                  🔴 1 AND 5 ARE DIFFERENT QUESTIONS. 1 says this command looked at the' \
    '                  🔴 1 and 5 are both failures. Read the block above for which.')
report 'MD5: the up table stops saying what 1 and 5 separate' "$m" \
       '  🔴 and 1 is scoped to a reading, not to failure in general'

# MD6: the precedence sentence goes. preflight folds several checks into one answer, so "which
# wins" is a decision the code makes on every run; unwritten, the next reader re-decides it.
# 🔴 Re-anchored 2026-09-12 after this gate reported MD6 as a SURVIVOR: the first anchor was the
# line ABOVE the sentence, and the cell reads the sentence -- so the mutation left the needle
# exactly where it was. The anchor is now the line that carries the ruling, and the replacement
# is the OTHER ruling rather than a deletion, which is the form an operator could actually meet.
m=$(mutant md6 "$NDT" \
    '                  answer is 5, because the one action that helps is waiting for that' \
    '                  answer is 1, because a held port is a fact whoever else is running and')
report 'MD6: the precedence between a refusal and a dirty reading is unwritten' "$m" \
       '  🔴 with the precedence when both are true'

# MD7: the clean table loses rc 3 again. The command's behaviour is unchanged; what goes is the
# only place an operator or a gate author is told that 0 now means "there WAS something here".
m=$(mutant md7 "$NDT" \
    '                  3 THERE WAS NOTHING TO JUDGE: no fabric, nothing in' \
    '                  (anything else means the machine was not readable): no fabric, nothing in')
report 'MD7: the clean table drops rc 3 (FIX-NDT-8)' "$m" \
       '  🔴 3 is in the clean table'

# MD8: the table keeps 3 and calls it clean. This is the sentence, not the code -- and the
# sentence is the whole of Adam's ruling: "沒量" 不是 "乾淨".
m=$(mutant md8 "$NDT" \
    '                  🔴 3 IS NOT A CLEAN BILL OF HEALTH, and until 09-12 this command' \
    '                  🔴 3 means the same as 0 when nothing is running. Until 09-12 this command')
report 'MD8: the clean table says 3 is a clean bill of health' "$m" \
       '  🔴 and 3 is not read as a clean bill'

# MD9: the down table loses rc 3. The third of the three tables, and the one whose 0 a night
# round reads on every restore -- run_cells.sh's restore accepts 0 and 3 because of this row.
m=$(mutant md9 "$NDT" \
    '                  3 THERE WAS NOTHING TO TEAR DOWN: no fabric, no registry entry in' \
    '                  (an empty lab answers 0 as usual): no fabric, no registry entry in')
report 'MD9: the down table drops rc 3 (FIX-NDT-8)' "$m" \
       '  🔴 3 is in the down table'

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
