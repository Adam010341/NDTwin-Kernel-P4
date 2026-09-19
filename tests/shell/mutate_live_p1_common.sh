#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_live_p1_common.sh -- live-p1/03's check that the twin's
# liveness follows the exercise controller's own pipeline pushes.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THREE DIRECTIONS, and this gate needs all three.
#   * FIRES: M1 makes an empty expectation pass, which is the check going vacuous -- and it is
#     the one that matters most, because the expectation is PARSED and a parser that stops
#     matching produces exactly that empty set. M4 misreads `s10` as `s1`, so the expectation
#     itself becomes wrong while still looking like a set.
#   * WIDENS: M2 turns the exact match into "at least these", so a twin calling a switch up that
#     nobody ever programmed passes -- the defect this check replaces, in a new costume. M3
#     makes the timeout a success, so a twin that never agreed is reported as one that did.
#   * THE INSTRUMENT: M5 takes the wait away (one look instead of a loop). Every message cell
#     stays green because the messages are right; what catches it is the poll count, which is
#     there so that "it waited" cannot be a sentence this harness always says.
#
# 🔴 A mutation that will not apply, a non-unique anchor, a mutant that does not PARSE, or the
# WRONG check going red counts as SURVIVOR -- never as skipped. A control that goes red makes
# the whole round void.
#
# 🔴 `bash -n` ON EVERY MUTANT: the suite sources _common.sh with its output discarded, so a
# mutant with a syntax error defines no functions at all and every cell goes red -- which looks
# exactly like a mutation this gate caught.
#
# Bare, not wrapped: nothing here compiles anything. live-p1/_common.sh is never written --
# mutants are whole copies in a temp dir, reached through COMMON_UNDER_TEST -- and the sha256
# line at the end says so.
#
# Run:  bash tests/shell/mutate_live_p1_common.sh
# Exit: 0 every mutation caught and the controls survived; 1 a mutation survived or a control
#       went red; 2 refused (baseline red); 3 _common.sh changed under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
COMMON="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh"
TEST="$HERE/test_live_p1_common.sh"
[[ -r "$COMMON" && -r "$TEST" ]] || { echo "refused: _common.sh or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-common-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$COMMON" | cut -d' ' -f1)"

# mutant <name> -- a copy of _common.sh with A/<name>.old replaced by A/<name>.new. The anchors
# travel as FILES so a shell word never has to survive two levels of quoting; the applier refuses
# a non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at run time.
mutant() {
    local name="$1" d="$BK/$name"
    mkdir -p "$d"
    cp "$COMMON" "$d/_common.sh"
    python3 - "$d/_common.sh" "$A/$name.old" "$A/$name.new" <<'PY'
import sys, io
target, oldf, newf = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(target, encoding='utf-8').read()
o = io.open(oldf, encoding='utf-8').read()
n = io.open(newf, encoding='utf-8').read()
c = s.count(o)
if c != 1:
    print("ANCHOR:%d" % c); sys.exit(0)
io.open(target, 'w', encoding='utf-8').write(s.replace(o, n, 1))
print(target)
PY
}

run_test() { COMMON_UNDER_TEST="$1" timeout 600 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$COMMON")"; BASE_RC=$?
BASE_RAN="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$BASE_OUT" | tail -1)"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0; CONTROLS=0; CONTROLS_RED=0

check_fires() {   # <label> <name> <check text that MUST go red> [<more>...]
    local label="$1" name="$2"; shift 2
    local wants=("$@") want missing=() d out rc ran
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-56s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if ! bash -n "$d" 2>/dev/null; then
        printf '  SURVIVED %-56s (the mutant does not PARSE -- a bash -n failure is not a catch)\n' "$label"
        SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    ran="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        printf '  SURVIVED %-56s (the run did not finish: "%s" vs baseline "%s")\n' "$label" "$ran" "$BASE_RAN"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite still green)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    for want in "${wants[@]}"; do
        /usr/bin/grep -qF "FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-56s (%d named check(s) went red)\n' "$label" "${#wants[@]}"
        printf '             red: %s\n' "${wants[@]}"
        /usr/bin/grep '^  FAILED' <<<"$out" | sed 's/^  FAILED   /             also red: /'
        CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on every named check)\n' "$label"
        printf '             still green: %s\n' "${missing[@]}"
        # 🔴 `^  FAILED`, ANCHORED. A bare `grep FAILED` also matches cells that PASSED and
        # merely have the word in their label -- "🔴 a FAILED pre-flight leaves the telemetry
        # knob alone" is one, and on 2026-09-19 it was printed under a SURVIVED verdict and
        # read by the orchestrator as the named check that stayed green. The line that names
        # that check is the `still green:` one above; this one is context, and context that
        # shows passing cells as failures is worse than no context.
        /usr/bin/grep '^  FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVED=$((SURVIVED+1))
    fi
}

check_control() {   # <label> <name> -- behaviour-preserving; the suite must stay GREEN
    local label="$1" name="$2" d out rc
    CONTROLS=$((CONTROLS+1))
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  🔴 CONTROL %-53s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    if ! bash -n "$d" 2>/dev/null; then
        printf '  🔴 CONTROL %-53s (the control does not PARSE -- it is not behaviour-preserving)\n' "$label"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  control  %-56s (stayed green, as it must)\n' "$label"
    else
        printf '  🔴 CONTROL %-53s (went RED -- this harness reddens for any edit)\n' "$label"
        # 🔴 `^  FAILED`, ANCHORED. A bare `grep FAILED` also matches cells that PASSED and
        # merely have the word in their label -- "🔴 a FAILED pre-flight leaves the telemetry
        # knob alone" is one, and on 2026-09-19 it was printed under a SURVIVED verdict and
        # read by the orchestrator as the named check that stayed green. The line that names
        # that check is the `still green:` one above; this one is context, and context that
        # shows passing cells as failures is worse than no context.
        /usr/bin/grep '^  FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        CONTROLS_RED=$((CONTROLS_RED+1))
    fi
}

# --- M1: an empty expectation is accepted ------------------------------------------------------
# 🔴 THE ONE THAT MATTERS MOST. The expectation is parsed out of the controller's log, so the
# empty set is exactly what a broken parser, a controller that never started and a controller
# that failed to connect all produce -- and `await` would then be comparing two empty sets and
# calling that agreement. The step would go green over a fabric with nothing on it.
cat > "$A/m1.old" <<'EOF'
    if [[ -z "$expected" ]]; then
EOF
cat > "$A/m1.new" <<'EOF'
    if false; then
EOF
check_fires "M1: an empty expected set is accepted" m1 \
            "🔴 an EMPTY expected set is refused, not satisfied" \
            "🔴 and it refuses WITHOUT reading the graph at all" \
            "🔴 a controller that programmed nothing fails the step"

# --- M2 (widening): the match stops being exact -------------------------------------------------
# "At least the ones the controller programmed" passes a twin that also calls s3 up -- a switch
# nobody ever loaded a program onto, whose liveness the twin therefore has no evidence for. That
# is the defect this check exists to replace, wearing the new check as a disguise.
cat > "$A/m2.old" <<'EOF'
            if [[ "$got" == "$expected" ]]; then
EOF
cat > "$A/m2.new" <<'EOF'
            if [[ -n "$got" ]]; then
EOF
check_fires "M2 (widening): any non-empty up set counts as a match" m2 \
            "🔴 a THIRD switch reported up is not a match" \
            "  s3 up while 1,2 were expected is not a match"

# --- M3: the timeout is a success ---------------------------------------------------------------
# The twin never agreed with the controller and the step says it did. Worse than not checking:
# the capture file is written either way, so there is a `36_` artefact saying what was expected
# next to a run that passed without reaching it.
cat > "$A/m3.old" <<'EOF'
    bad "the kernel's up set never became '$expected' within ${timeout}s (last: $last) -- see $(basename "$out")"
    return 1
EOF
cat > "$A/m3.new" <<'EOF'
    bad "the kernel's up set never became '$expected' within ${timeout}s (last: $last) -- see $(basename "$out")"
    return 0
EOF
check_fires "M3: giving up is reported as agreement" m3 \
            "🔴 a set that never arrives is a failure" \
            "🔴 a THIRD switch reported up is not a match"

# --- M4: `s10` is read as `s1` --------------------------------------------------------------------
# The expectation itself becomes wrong while still looking like a perfectly good set, so the
# step fails (or passes) about the wrong switches. pod-topo has four switches today and the
# exercises are free to grow; `s1` is a prefix of `s10` and of nothing else that matters yet.
cat > "$A/m4.old" <<'EOF'
    m = re.search(r'Installed P4 Program using SetForwardingPipelineConfig on s([0-9]+)\b', line)
EOF
cat > "$A/m4.new" <<'EOF'
    m = re.search(r'Installed P4 Program using SetForwardingPipelineConfig on s([0-9])', line)
EOF
check_fires "M4: s10 is parsed as dpid 1" m4 \
            "🔴 s10 is dpid 10, not dpid 1"

# --- M5 (the instrument): the wait is a single look ----------------------------------------------
# 🔴 INVISIBLE TO EVERY MESSAGE CELL. The sentences are all still right; what changes is that a
# twin one second away from agreeing is recorded as one that never did. It is here to prove the
# poll counter reads the machine rather than printing a constant.
cat > "$A/m5.old" <<'EOF'
    for (( i = 0; i < timeout; i++ )); do
EOF
cat > "$A/m5.new" <<'EOF'
    for (( i = 0; i < 1; i++ )); do
EOF
check_fires "M5: the wait is one look (the instrument)" m5 \
            "🔴 it waits until the up set becomes the expected one" \
            "  which took three polls, not one"

# --- M6: an unreadable graph is reported as 'nothing is up' ---------------------------------------
# `kernel_up_set` answers the empty string for both, and only the rc tells them apart. Folding
# them makes "the twin says nothing is up" and "I could not ask the twin" the same reading --
# and on an external fabric, where nothing being up is the ordinary state, the second would
# never be noticed again.
cat > "$A/m6.old" <<'EOF'
if not sw:
    raise SystemExit(1)
EOF
cat > "$A/m6.new" <<'EOF'
if not sw:
    sw = []
EOF
check_fires "M6: a graph with no switches reads as an empty up set" m6 \
            "🔴 a graph with no switches in it is rc 1 too"

# --- M7 (widening): "at least these" one layer down ---------------------------------------------
# await_kernel_up_set's M2 turns the equality into "anything non-empty"; this is the narrower and
# more plausible version of the same mistake -- every expected switch is up, and extra ones are
# tolerated. It is the shape somebody writes on purpose when a check is "too strict".
cat > "$A/m7.old" <<'EOF'
            if [[ "$got" == "$expected" ]]; then
EOF
cat > "$A/m7.new" <<'EOF'
            if [[ ",$got," == *",${expected%%,*},"* ]]; then
EOF
# Named on the superset cell only: the "s3 up while 1,2 were expected" cell stays green under
# this mutation and correctly so -- `3` does not contain `1` either, so that one still times out.
# A subset test is wrong about supersets, not about disjoint sets.
check_fires "M7 (widening): the expected set only has to be a subset" m7 \
            "🔴 a THIRD switch reported up is not a match"

# --- M8: the probe universe is the literal 1,2,3 again ------------------------------------------
# 🔴 THE FIX THIS ROUND EXISTS FOR, restored. The SET stays computed from the controller's log
# and the thing it is subtracted from becomes typed, so a package with a fourth switch has that
# switch silently unchecked -- and the sentence "s3 is computed, not typed" stays half true.
cat > "$A/m8.old" <<'EOF'
    universe="$(model_switch_dpids "$pkg")"
EOF
cat > "$A/m8.new" <<'EOF'
    universe="$(printf '1\n2\n3\n')"
EOF
check_fires "M8: the probe universe is hardcoded again" m8 \
            "🔴 the fourth switch of a four-switch package IS checked" \
            "  and it is the one named"

# --- M9: only the programmed half is checked -----------------------------------------------------
# The switches the controller touched answer, and nothing asks about the ones it did not. A twin
# reporting a switch alive that nobody ever loaded a program onto is exactly the evidence-free
# liveness this whole ticket replaced, and this is the proxy-side half of it.
cat > "$A/m9.old" <<'EOF'
            note "$label: switch $d probe_ok $pok   (no controller ever loaded a program onto it)"
            [[ "$pok" == False ]] || { fail "$label: switch $d never got a program and its probe_ok is '$pok', want False"; rc=1; }
EOF
cat > "$A/m9.new" <<'EOF'
            note "$label: switch $d probe_ok $pok   (no controller ever loaded a program onto it)"
EOF
check_fires "M9: the switches nobody programmed are not checked" m9 \
            "🔴 a switch answering that nobody programmed is red" \
            "🔴 the fourth switch of a four-switch package IS checked"

# --- M10: an empty expected set is accepted on the proxy side too ---------------------------------
# M1's twin. Both halves of the check have to refuse it, or the one that does not becomes the
# green half of a step that prints two ticks.
cat > "$A/m10.old" <<'EOF'
    if [[ -z "$want" ]]; then
EOF
cat > "$A/m10.new" <<'EOF'
    if false; then
EOF
# 🔴 NOT the rc cell: with the refusal gone the helper still returns 1, because every switch
# then falls into the "nobody programmed this" half and the two that are answering fail it. Same
# exit code, a completely different reason, over a fabric it should never have read. The cells
# that see it are the sentence and the fact that no probe was read at all.
check_fires "M10: an empty expected set is accepted by the probe half" m10 \
            "  for the same reason" \
            "🔴 and it refuses without reading a single probe"

# --- M11: an unreadable model is treated as an empty universe -------------------------------------
# Nothing is then checked at all and the helper returns 0. The "unchecked is not passed" rule,
# on the one input this helper cannot do without.
cat > "$A/m11.old" <<'EOF'
    if [[ -z "$universe" ]]; then
        fail "$label: could not read the switch dpids the package's model declares, so there is no universe to check the probes against"
        return 1
    fi
EOF
cat > "$A/m11.new" <<'EOF'
    if [[ -z "$universe" ]]; then
        return 0
    fi
EOF
check_fires "M11: an unreadable model checks nothing and passes" m11 \
            "🔴 an unreadable model is refused, not assumed" \
            "  saying there is no universe to check against"

# --- the controls --------------------------------------------------------------------------------
# 🔴 Without these the round says nothing: a harness that reddened for ANY edit would print
# `6 caught, 0 survived` while catching nothing at all.
cat > "$A/c1.old" <<'EOF'
        printf 'REFUSED: empty expected set\n' > "$out"
        return 1
EOF
cat > "$A/c1.new" <<'EOF'
        printf 'REFUSED: empty expected set\n' > "$out"
        return 1   # the expectation came from a log that named no switch
EOF
check_control "C1: a comment beside the refusal" c1

cat > "$A/c2.old" <<'EOF'
    local expected="$1" timeout="${2:-20}" out="$3"
EOF
cat > "$A/c2.new" <<'EOF'
    local expected="$1"
    local timeout="${2:-20}"
    local out="$3"
EOF
check_control "C2: the parameters unpacked one per line" c2


# =================================================================================================
# TICKET-P3 §2.7: the generic cell -- link usage follows the iperf path.
#
# 🔴 THIS CELL'S FAILURE MODE IS A GREEN RUN. Every mutation below leaves the step printing the
# same sentences over the same fabric; what changes is that a twin reporting nothing, a twin
# reporting everything, or a twin reporting a link nobody used all pass.
# =================================================================================================

# --- M12: the on-path threshold becomes zero ------------------------------------------------------
# LLDP, ARP and the proxy's probes keep every link faintly busy, so with a threshold of 0 every
# interface in the fabric is on every path -- and the off-path half of the assertion, which is the
# half with teeth, has nothing left to be about.
cat > "$A/m12.old" <<'EOF'
: "${LINK_USAGE_ONPATH_BYTES:=10000}"
EOF
cat > "$A/m12.new" <<'EOF'
: "${LINK_USAGE_ONPATH_BYTES:=0}"
EOF
check_fires "M12: every interface with a byte on it is on the path" m12 \
            "🔴 only the interfaces that moved bytes are on the path"

# --- M13 (M-D5): the off-path assertion is dropped ------------------------------------------------
# 🔴 THE HALF THAT HAS TEETH. "Usage is non-zero where the flow went" is satisfied by a twin that
# reports non-zero EVERYWHERE -- which is exactly what a double-counting collector, a stale rate
# and a fabric sampling on every port look like.
cat > "$A/m13.old" <<'EOF'
        if [[ "$(awk "BEGIN{print ($bits >= $floor) ? 1 : 0}")" == 1 ]]; then
EOF
cat > "$A/m13.new" <<'EOF'
        if false; then
EOF
check_fires "M13 (M-D5): links OFF the path are not checked at all" m13 \
            "🔴 an inter-switch link off the path carrying the FLOW is red" \
            "  naming it, the bits and the floor"

# --- M14: an on-path interface the twin does not model is skipped ----------------------------------
# 🔴 THE MOST IMPORTANT THING THIS CELL CAN FIND, turned into silence. "The twin has no edge for a
# link that carried the flow" reported as a clean run is the gap reporting itself as its own fix.
# 🔴 THE ANCHOR MOVED WITH THE CLASSES (§9 ruling 20①): an unmodelled link is now red only
# when it is PRIMARY -- a MINOR one is printed, because a side branch the sampler cannot see is
# not evidence that the twin is missing an edge.
cat > "$A/m14.old" <<'EOF'
        if [[ -z "$kind" ]]; then
            if [[ "$cls" == P ]]; then
                fail "$label: $key carried the flow and the twin has NO edge for it -- the link is not modelled, which is a gap this cell exists to find"
                rc=1
EOF
cat > "$A/m14.new" <<'EOF'
        if [[ -z "$kind" ]]; then
            if false; then
                fail "$label: $key carried the flow and the twin has NO edge for it -- the link is not modelled, which is a gap this cell exists to find"
                rc=1
EOF
check_fires "M14: an unmodelled on-path link is skipped instead of red" m14 \
            "🔴 an on-path interface with NO twin edge is red" \
            "  and says the link is not modelled"

# --- M15: an empty on-path set is accepted ----------------------------------------------------------
# With nothing measured as on-path, "every on-path edge is non-zero" is vacuous and "every
# off-path edge is zero" is true of a fabric that moved no packet at all -- which is what a broken
# iperf, a missing sudo grant and a dead switch all produce.
cat > "$A/m15.old" <<'EOF'
    if [[ ! -s "$onpath" ]]; then
        fail "$label: the on-path interface set is EMPTY -- nothing measurably carried the flow, so 'usage follows the path' is a sentence about a fabric that moved no packets"
        return 1
    fi
EOF
cat > "$A/m15.new" <<'EOF'
    if false; then
        return 1
    fi
EOF
# 🔴 NOT THE rc CELL. With the refusal gone the loop still runs, every edge falls into the
# off-path half, and the host-facing one is over the ARP allowance -- so rc is 1 for a completely
# different reason, over a window this helper should never have judged. What sees it is the
# sentence and the fact that no edge was judged at all. (mutate_live_p1_common.sh's own M10
# carries the same note about the probe half.)
check_fires "M15: an EMPTY on-path set passes the cell" m15 \
            "  saying why" \
            "🔴 and it refuses WITHOUT judging a single edge"

# --- M16 (M-D6): the positive control stops discriminating --------------------------------------------
# 🔴 WITHOUT THE CONTROL THE CELL ABOVE IS UNFALSIFIABLE. `none` is the group with no sampling at
# all; a twin that still reported usage there is a twin whose numbers do not come from the
# telemetry source the round selected, and every "link usage follows the path" green afterwards
# would be about something else.
cat > "$A/m16.old" <<'EOF'
        if [[ "$(awk "BEGIN{print ($bits != 0) ? 1 : 0}")" == 1 ]]; then
            fail "$label (control): telemetry is off and the twin still integrated $bits bit on $key, which carried the flow -- the cell above has no discriminating power"
            rc=1
EOF
cat > "$A/m16.new" <<'EOF'
        if false; then
            rc=1
EOF
check_fires "M16 (M-D6): the positive control accepts a twin that still reports" m16 \
            "🔴 telemetry off and the twin still reporting is RED" \
            "  because the cell above would then prove nothing"

# --- M17 (widening): the floor becomes the flow itself -------------------------------------------------
# 🔴 THE FLOOR IS A BOUND, NOT A BLANK CHEQUE (TICKET-P3 §9 ruling 9, R4). At 2% of the smallest
# on-path integral it sits two orders of magnitude above a sampled LLDP beacon and two below the
# flow; at 100% it is the flow, and an off-path link carrying the WHOLE flow passes.
cat > "$A/m17.old" <<'EOF'
: "${LINK_USAGE_OFFPATH_FRACTION:=0.02}"
EOF
cat > "$A/m17.new" <<'EOF'
: "${LINK_USAGE_OFFPATH_FRACTION:=1.0}"
EOF
check_fires "M17 (widening): the off-path floor becomes the whole flow" m17 \
            "🔴 an inter-switch link off the path carrying the FLOW is red" \
            "  naming it, the bits and the floor"

# --- M18: a window in which the graph never answered is an empty integral ------------------------------
# rc 0 with no rows, which the assertion then reads as "the twin models none of these links" --
# a completely different finding, from a window in which nothing was asked.
cat > "$A/m18.old" <<'EOF'
sys.exit(0 if n else 1)
EOF
cat > "$A/m18.new" <<'EOF'
sys.exit(0)
EOF
check_fires "M18: a graph that never answered reads as an empty integral" m18 \
            "🔴 a graph that never answered is rc 1, not an empty integral" \
            "  saying there is no twin reading for the window"

# --- M19: the host->switch direction is integrated too --------------------------------------------------
# Its key is `s0-ethN`, which is no interface at all: /proc/net/dev has nothing to join it to, so
# every such edge becomes an on-path interface the twin models and nothing measured -- or an
# off-path edge with usage on it. Either way the assertion is about a key that cannot exist.
cat > "$A/m19.old" <<'EOF'
        if e["src_dpid"] not in sw:
            continue                      # host->switch direction: no sN-ethP carries it
EOF
cat > "$A/m19.new" <<'EOF'
        if False:
            continue
EOF
check_fires "M19: the host->switch direction gets an sN-ethP key" m19 \
            "🔴 the host->switch direction has no sN-ethP to be"

# --- M20: every edge is called inter-switch -------------------------------------------------------------
# The host-facing links then fall under the exact-zero rule, and a run is red for the ARP that is
# always there -- the failure mode the allowance exists to prevent, reached from the other side.
cat > "$A/m20.old" <<'EOF'
        kind[key] = "switch" if e.get("dst_dpid") in sw else "host"
EOF
cat > "$A/m20.new" <<'EOF'
        kind[key] = "switch"
EOF
# 🔴 Named on the INTEGRAL cell only: the ARP-allowance cells above feed the assertion a
# handmade integral file, so they are about the rule and not about the classifier. This mutation
# is in the classifier.
check_fires "M20: host-facing edges are classified as inter-switch" m20 \
            "  a host-facing edge integrates its rate over the window"

# --- M21: an interface present in only one reading is treated as starting at zero ------------------------
# "The interface went away mid-window" and "it moved 2 MB" are different facts, and the second one
# is manufactured from the first.
# 🔴 RE-ANCHORED ON THE CLASSIFYING LOOP (§9 ruling 20①): the old one-name-per-line loop is
# gone, but the mutation is the same one -- an interface present in only the AFTER reading is
# measured from zero, so "the interface appeared mid-window" is silently turned into "it moved
# all of those bytes".
cat > "$A/m21.old" <<'EOF'
deltas = {k: a[k] - b[k] for k in sorted(set(b) & set(a))}
EOF
cat > "$A/m21.new" <<'EOF'
deltas = {k: a[k] - b.get(k, 0) for k in sorted(set(a))}
EOF
check_fires "M21: an interface seen once is measured from zero" m21 \
            "  and it is not on the path"

# --- M22: the named destination is ignored --------------------------------------------------------
# 🔴 THE TWO EXERCISES THIS PARAMETER EXISTS FOR. exercises/multicast's sig-topo group
# replicates ports 1,2,3 -- adding the fourth is README:122's own TODO -- and
# exercises/p4runtime's controller wires h1<->h2 and never contacts s3. With the caller's
# destination dropped, both measure to the model's LAST host, which on those two fabrics is
# unreachable by design: an empty on-path set, and the cell refuses about the wrong thing.
cat > "$A/m22.old" <<'EOF'
    if [[ -n "$want_dst" ]]; then
EOF
cat > "$A/m22.new" <<'EOF'
    if false; then
EOF
check_fires "M22: the caller's destination host is ignored" m22 \
            "  a named destination is the one the flow runs to"

# --- M23: a destination the model does not declare falls back to the last host ----------------------
# Silently measuring between two hosts nobody asked about, and reporting the result under the
# caller's label.
cat > "$A/m23.old" <<'EOF'
        if [[ -z "$dst_ip" ]]; then
            fail "$label: the package model declares no host '$want_dst' to run a flow to"
            return 1
        fi
EOF
cat > "$A/m23.new" <<'EOF'
        if [[ -z "$dst_ip" ]]; then
            read -r dst dst_ip < <(model_hosts "$pkg" | tail -1)
        fi
EOF
check_fires "M23: an unknown destination falls back to the last host" m23 \
            "🔴 a destination the model does not declare is refused" \
            "  rather than silently falling back to another host"

# --- M24: the floor is the absolute 5 kbit, whatever the flow ------------------------------------
# 🔴 THE HALF THAT KEEPS A CORRECT FABRIC GREEN. Without the relative term a single sampled LLDP
# beacon -- ~500 bit at 1/256, banked as ~128 kbit on a link that carried nothing -- reds every
# run of the generic cell, at random, on a fabric doing exactly what it is supposed to do.
cat > "$A/m24.old" <<'EOF'
print("%.3f" % max(floor_abs, frac * min(vals)) if vals else "%.3f" % floor_abs)
EOF
cat > "$A/m24.new" <<'EOF'
print("%.3f" % floor_abs)
EOF
check_fires "M24: the floor loses its relative term" m24 \
            "🔴 and with a real 16 Mbit flow it is 2% of it, not 5 kbit" \
            "🔴 one sampled LLDP beacon off the path is NOT a failure"

# --- M25: the floor loses its absolute term -------------------------------------------------------
# The other half. In a window where the flow itself was small, 2% of it is a handful of bits and
# an off-path link with real traffic on it slips under -- the bound has to have a floor of its own.
cat > "$A/m25.old" <<'EOF'
floor_abs = float(sys.argv[3]); frac = float(sys.argv[4])
EOF
cat > "$A/m25.new" <<'EOF'
floor_abs = 0.0; frac = float(sys.argv[4])
EOF
# 🔴 NOT THE rc CELL. With floor_abs gone the quiet window's floor is 2% of 8000 = 160 bit and
# the 6000 bit off-path edge is still over it -- rc 1 either way, a different number in the
# message. What sees it is the floor the run PRINTS, which is the number the verdict used.
check_fires "M25: the floor loses its absolute term" m25 \
            "  the floor with a 16 kbit smallest on-path integral" \
            "  naming that floor"

# --- M26: the floor is computed from the LARGEST on-path integral --------------------------------
# On a fabric whose on-path edges differ -- the host-facing one carries the flow once, an
# inter-switch one may carry it twice -- taking the max raises the bound above traffic the cell
# is supposed to catch. `min` is the conservative end and is the one written down.
cat > "$A/m26.old" <<'EOF'
print("%.3f" % max(floor_abs, frac * min(vals)) if vals else "%.3f" % floor_abs)
EOF
cat > "$A/m26.new" <<'EOF'
print("%.3f" % max(floor_abs, frac * max(vals)) if vals else "%.3f" % floor_abs)
EOF
check_fires "M26: the floor is taken from the largest on-path integral" m26 \
            "  the floor follows the SMALLEST on-path integral" \
            "🔴 and 100 kbit off the path is red against it"

# --- M27: the off-path integrals are not recorded ---------------------------------------------------
# 🔴 A FLOOR ONLY MEANS SOMETHING BESIDE THE NUMBERS IT WAS APPLIED TO. With the reading gone,
# "under the bound" and "exactly zero" read identically in the raw and the margin -- which is
# the whole question once the bound is not zero -- is not in the record at all.
cat > "$A/m27.old" <<'EOF'
        note "$label: off-path $key  $bits bit  ($kind)"
EOF
cat > "$A/m27.new" <<'EOF'
        :
EOF
check_fires "M27: the off-path edges' raw integrals are not recorded" m27 \
            "  with the edge's own integral beside it"

# --- M28: the floor is not printed ------------------------------------------------------------------
cat > "$A/m28.old" <<'EOF'
    note "$label: off-path floor $floor bit   = max(${LINK_USAGE_NOISE_BITS}, ${LINK_USAGE_OFFPATH_FRACTION} x the smallest on-path integral)"
EOF
cat > "$A/m28.new" <<'EOF'
    :
EOF
check_fires "M28: the floor the verdict used is not in the raw" m28 \
            "  and the floor it was judged against is in the raw"

# --- (no mutation) the `local` hazard scanner is in the TEST FILE -------------------------------
# 🔴 §9 ruling 12d is a change to tests/shell/test_live_p1_common.sh (the scanner now fails when
# its INTERPRETER fails, instead of printing nothing and being read as a clean scan). This
# gate's subject is `live-p1/_common.sh`; an anchor in the test file would be counted against
# _common.sh by check_gate_anchors.py and read as MISSING. The scanner is covered inside the
# suite instead, by four cells that are each other's controls: empty PATH => rc 3, an
# interpreter that exits 1 => rc 3, a working interpreter => rc 0 and no SCANNER-FAILED, and
# the positive/negative shape controls that were already there.

# --- M29 (§9 ruling 19②): finish() loses its `set +e` --------------------------------------------
# 🔴 THE LIVE DEFECT, RESTORED. Under `set -euo pipefail` a non-zero `ndt down` ends the EXIT
# trap half way: live 02's log stops at `== teardown`, live 03's at "stopping the exercise
# controller" -- no `ndt down rc=`, no `ndt release`, and no verdict line, while the README
# promises the last line is PASS or FAIL. A teardown is the one place where every step must run
# BECAUSE an earlier one failed.
cat > "$A/m29.old" <<'EOF'
    set +e
    trap - EXIT INT TERM
EOF
cat > "$A/m29.new" <<'EOF'
    trap - EXIT INT TERM
EOF
check_fires "M29: finish() runs under set -e again" m29 \
            "🔴 'ndt release' still ran -- the lab is not left claimed" \
            "🔴 and the LAST line is the verdict, as the README promises"

# --- M30: the failing `ndt down` stops reaching the verdict ----------------------------------------
# The other half: `set +e` alone would let the teardown finish while saying nothing about WHY.
cat > "$A/m30.old" <<'EOF'
        (( down_rc == 0 )) || fail "'ndt down' exited $down_rc -- see $(basename "$RUN")/90_down.txt"
EOF
cat > "$A/m30.new" <<'EOF'
        :
EOF
check_fires "M30: a non-zero 'ndt down' is not folded into the verdict" m30 \
            "🔴 its rc is folded into the verdict"

# --- M31 (§9 ruling 20①): every interface over 10 kB is PRIMARY again ------------------------
# 🔴 THE LIVE DEFECT, RESTORED. With the share at 0 the 15,120 B side branch is primary again
# and the cell demands a non-zero twin integral on it -- while a 1/256 sampler is expected to
# catch 0.04 samples from ten packets. That is qos/solution's real reading going red on a twin
# that was right.
cat > "$A/m31.old" <<'EOF'
: "${LINK_USAGE_PRIMARY_FRACTION:=0.05}"
EOF
cat > "$A/m31.new" <<'EOF'
: "${LINK_USAGE_PRIMARY_FRACTION:=0}"
EOF
check_fires "M31: every interface over the byte threshold is primary again" m31 \
            "🔴 s1-eth4 is MINOR, not primary" \
            "🔴 the real qos/solution reading PASSES"

# --- M32 (widening): nothing is primary ------------------------------------------------------
# 🔴 THE CONTROL FOR M31. At a share of 1.0 only the single largest interface is primary, so
# the OTHER end of the same flow stops being asserted -- and "usage follows the path" would be
# a claim about one interface.
cat > "$A/m32.old" <<'EOF'
: "${LINK_USAGE_PRIMARY_FRACTION:=0.05}"
EOF
cat > "$A/m32.new" <<'EOF'
: "${LINK_USAGE_PRIMARY_FRACTION:=1.5}"
EOF
check_fires "M32 (widening): the share is so high nothing is primary" m32 \
            "🔴 s1-eth3 is PRIMARY" \
            "🔴 s2-eth1 is PRIMARY"

# --- M33: a failed `ndt release` only warns ----------------------------------------------------
# 🔴 A ROUND MUST NOT PRINT PASS WITH THE LAB STILL CLAIMED. `bad` prints and leaves the verdict
# alone, so the step ends green while the next person to want the lab finds it held.
cat > "$A/m33.old" <<'EOF'
            || fail "'ndt release' did not take -- THE LAB IS STILL CLAIMED; run it by hand"
EOF
cat > "$A/m33.new" <<'EOF'
            || bad "'ndt release' did not take -- run it by hand"
EOF
check_fires "M33: a failed 'ndt release' only warns" m33 \
            "🔴 a failing 'ndt release' fails the round" \
            "🔴 and the LAST line is FAIL, not PASS"

# --- the controls for this half --------------------------------------------------------------------------
cat > "$A/c3.old" <<'EOF'
    (( rc == 0 )) && note "$label: link usage follows the iperf path (off-path under $floor bit)"
    return $rc
EOF
cat > "$A/c3.new" <<'EOF'
    # the on-path and off-path halves have both had their say by here
    (( rc == 0 )) && note "$label: link usage follows the iperf path (off-path under $floor bit)"
    return $rc
EOF
check_control "C3: a comment above the cell's verdict" c3

# 🔴 THE ANCHOR IS THE CONTROL'S SIGNATURE PLUS ITS OWN FIRST MESSAGE. The two assert_
# functions declare the same locals, so the declaration alone matches twice -- which this gate
# scores as a SURVIVOR, and correctly: a control that mutated whichever site came first would
# not be the control anybody wrote.
cat > "$A/c4.old" <<'EOF'
    local onpath="$1" integral="$2" label="$3" rc=0 key bits kind cls delta
    if [[ ! -s "$onpath" ]]; then
        fail "$label (control): the on-path interface set is EMPTY -- with no traffic measured, 'the twin reports nothing' is true of any twin at all"
EOF
cat > "$A/c4.new" <<'EOF'
    local onpath="$1" integral="$2" label="$3"
    local rc=0 key bits kind
    if [[ ! -s "$onpath" ]]; then
        fail "$label (control): the on-path interface set is EMPTY -- with no traffic measured, 'the twin reports nothing' is true of any twin at all"
EOF
check_control "C4: the cell's locals declared on two lines" c4

echo
NOW_SUM="$(sha256sum "$COMMON" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 baseline CHANGED during the gate -- live-p1/_common.sh was written"
    echo "   before: $BASE_SUM"
    echo "   after:  $NOW_SUM"
    exit 3
fi
echo "baseline byte-identical: yes  live-p1/_common.sh  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived; $CONTROLS control(s), $CONTROLS_RED went red"
(( SURVIVED == 0 && CONTROLS_RED == 0 ))
