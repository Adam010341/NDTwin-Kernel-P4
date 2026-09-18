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
        /usr/bin/grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
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
        /usr/bin/grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
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
