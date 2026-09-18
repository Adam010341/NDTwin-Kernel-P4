#!/usr/bin/env bash
#
# Mutation gate for live-p1/06_thirteen.sh -- the loop that runs thirteen exercises on two arms
# and says whether each one behaved the way its exercise says it does.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THIS STEP HAD NO GATE AND NO TEST, AND ITS ONE DECISION WAS INVERTED. `expected_rc()`
# wanted rc 1 from every skeleton arm, so a completely correct round of twenty-six would have
# printed `FAIL 06_thirteen -- 11 of 26` (judge A2, TICKET-P3 §9 ruling 9). "Red" is a property
# of the EXPECTATIONS -- the skeleton arm asserts "h2 received 0 packets", "every reported port
# is 0", "the flow is NOT blocked" -- so a skeleton behaving as the exercise says meets all of
# them and the driver exits 0; the 09-08 and 09-18 real runs are exactly that.
#
# The suite drives this step against a STUB driver whose exit codes are a table, through
# THIRTEEN_UNDER_TEST and DRIVER_UNDER_TEST -- seams of the same shape NDT_UNDER_TEST and
# STACK_UNDER_TEST already are -- so nothing here reaches root, a lab, `ndt` or ~/tutorials.
#
# 🔴 A mutation that will not apply, a non-unique anchor, a mutant that does not PARSE, or the
# WRONG check going red counts as SURVIVOR -- never as skipped. A control that goes red makes
# the whole round void.
#
# Run:  bash tests/shell/mutate_live_p1_thirteen.sh
# Exit: 0 every mutation caught and the controls survived; 1 a mutation survived or a control
#       went red; 2 refused (baseline red); 3 stack.sh changed under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STEP="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh"
TEST="$HERE/test_live_p1_thirteen.sh"
[[ -r "$STEP" && -r "$TEST" ]] || { echo "refused: 06_thirteen.sh or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-13-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$STEP" | cut -d' ' -f1)"

# mutant <name> -- a copy of stack.sh with A/<name>.old replaced by A/<name>.new. The anchors
# travel as FILES so a shell word never has to survive two levels of quoting; the applier
# refuses a non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at
# run time.
mutant() {
    local name="$1" d="$BK/$name"
    mkdir -p "$d"
    cp "$STEP" "$d/06_thirteen.sh"
    python3 - "$d/06_thirteen.sh" "$A/$name.old" "$A/$name.new" <<'PY'
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

run_test() { THIRTEEN_UNDER_TEST="$1" timeout 900 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$STEP")"; BASE_RC=$?
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

# --- M1 (judge A2): a correct skeleton arm is expected to FAIL ------------------------------------
# The defect itself, restored. Eleven of twenty-six arms red on a round in which every exercise
# behaved exactly the way its own README says it does.
cat > "$A/m1.old" <<'EOF'
    [[ "$which" == solution ]] && { echo 0; return; }
    case "$ex" in
        flowcache)    echo 1 ;;
        basic_tunnel) echo 1 ;;          # both fabrics now; this script drives ndtwin
        *)            echo 0 ;;
    esac
EOF
cat > "$A/m1.new" <<'EOF'
    [[ "$which" == solution ]] && { echo 0; return; }
    echo 1
EOF
check_fires "M1: a correct skeleton arm is expected to fail" m1 \
            "  a correct pair of arms passes" \
            "🔴 neither arm of a correct pair wants a non-zero rc"

# --- M2 (widening): every skeleton rc is accepted --------------------------------------------------
# The opposite error, and the one that makes the whole step decorative: with nothing asserted
# about the skeleton arms, "the red arm is not red" is unobservable and twenty-six runs of a
# fabric that forwards everything pass.
cat > "$A/m2.old" <<'EOF'
    want="$(expected_rc "$ex" "$which")"
EOF
cat > "$A/m2.new" <<'EOF'
    want="$rc"
EOF
# 🔴 NOT the "FAILED an expectation" cell any more: with `want="$rc"` that arm now trips the
# by-design guard instead and fails with a DIFFERENT sentence. It still fails -- which is what
# these two cells assert -- and naming the sentence would be pinning the message, not the rule.
check_fires "M2 (widening): every arm is expected to do whatever it did" m2 \
            "🔴 a flowcache skeleton that exits 0 is the finding" \
            "🔴 and one that exits 0 is the finding"

# --- M3: the two designed-refusal arms lose their exception ------------------------------------------
# flowcache's skeleton stops at p4c and basic_tunnel's stops at pre-flight; both report
# `RED ARM (n/n): ... by design` and exit 1. Without the exception a correct round is red on two.
cat > "$A/m3.old" <<'EOF'
        flowcache)    echo 1 ;;
        basic_tunnel) echo 1 ;;          # both fabrics now; this script drives ndtwin
EOF
cat > "$A/m3.new" <<'EOF'
        __never__)    echo 1 ;;
EOF
check_fires "M3: the designed-refusal arms lose their exception" m3 \
            "  flowcache's skeleton is expected to exit 1" \
            "  basic_tunnel's skeleton is expected to exit 1 here"

# --- M4 (widening): the exception is granted to every skeleton --------------------------------------
# 🔴 THE CONTROL FOR M3. "rc 1 is fine for a skeleton" is the same defect as round 1's, worn as
# a tolerance instead of an expectation.
cat > "$A/m4.old" <<'EOF'
        *)            echo 0 ;;
EOF
cat > "$A/m4.new" <<'EOF'
        *)            echo 1 ;;
EOF
# 🔴 THE qos CELL CANNOT SEE THIS ONE ANY MORE, and that is not a weakening: with the exception
# granted to every skeleton, qos/skeleton rc 1 is now caught by the by-design guard instead
# (its verdict is a `FAIL`, not a `RED ARM`), so the step still fails and that cell still
# passes. What only M4 breaks is the arm that is supposed to exit 0.
check_fires "M4 (widening): every skeleton may exit 1" m4 \
            "  a correct pair of arms passes"

# --- M5: rc 2 is treated as a result -----------------------------------------------------------------
# A round that never ran -- pre-flight, claim, compile or root -- counted as evidence about the
# exercise. It is the one case where the table has nothing to say and must say so.
cat > "$A/m5.old" <<'EOF'
    elif [[ "$rc" == 2 ]]; then
        bad "$ex/$which exited 2 -- the round never ran (pre-flight, claim, compile or root)."
        bad "  That is not a result about the exercise, and it is not a pass."
EOF
cat > "$A/m5.new" <<'EOF'
    elif [[ "$rc" == 2 ]]; then
        bad "$ex/$which exited 2."
EOF
check_fires "M5: a round that never ran is reported like any other failure" m5 \
            "  and says it is not a result about the exercise"

# --- M6 (the instrument): the loop stops at the first failure ------------------------------------------
# 🔴 INVISIBLE TO EVERY VERDICT CELL -- the step still fails, and for the right arm. What it
# costs is the table: one broken exercise reported and nothing said about the other twelve,
# which is the opposite of what a table is for.
cat > "$A/m6.old" <<'EOF'
    run_arm "$ex" skeleton || true
    run_arm "$ex" solution || true
EOF
cat > "$A/m6.new" <<'EOF'
    run_arm "$ex" skeleton || break
    run_arm "$ex" solution || break
EOF
check_fires "M6: the loop stops at the first failing arm (the instrument)" m6 \
            "🔴 a failure does not stop the loop"

# --- M7: the `local` hazard comes back ------------------------------------------------------------------
# 🔴 THE SECOND LATENT BUG THIS SUITE FOUND. Under `set -u` bash 5.2 declares every name in a
# `local` list BEFORE assigning any of them, so `local ex="$1" which="$2" log="...${which}..."`
# expands an unset variable and run_arm dies on its first line. This step had never been run.
cat > "$A/m7.old" <<'EOF'
    local ex="$1" which="$2"
    local log rc want verdict report
    log="$RUN/${ex}_${which}.log"
EOF
cat > "$A/m7.new" <<'EOF'
    local ex="$1" which="$2" log="$RUN/${ex}_${which}.log" rc want verdict report
EOF
check_fires "M7: the set -u local hazard comes back" m7 \
            "  a correct pair of arms passes" \
            "  the table names each arm"

# --- M8 (round-3 ruling 2): rc 1 alone is accepted from the exception arms ------------------------
# 🔴 THE DEFECT THE JUDGE FOUND IN ROUND 2'S FIX. The two exception arms are expected to exit 1
# -- but an arm that FAILED an expectation exits 1 too. `flowcache/skeleton` that COMPILED
# prints `FAIL (1/1): the skeleton COMPILED` and exits 1; comparing rc only, this step printed
# PASS for exactly the finding it exists to report.
cat > "$A/m8.old" <<'EOF'
        if [[ "$want" == 1 && "$verdict" != "RED ARM"* ]]; then
EOF
cat > "$A/m8.new" <<'EOF'
        if false; then
EOF
check_fires "M8: rc 1 is accepted without a by-design verdict" m8 \
            "🔴 rc 1 with a NON-refusal verdict is the finding, not a pass" \
            "🔴 same for basic_tunnel's entries actually installing"

# --- M9 (widening): the verdict test is applied to the want-0 arms too ---------------------------
# 🔴 THE CONTROL FOR M8. Every other arm is supposed to exit 0 with `PASS (n/n)`; demanding a
# `RED ARM` verdict from them would fail the eleven arms that are behaving correctly.
cat > "$A/m9.old" <<'EOF'
        if [[ "$want" == 1 && "$verdict" != "RED ARM"* ]]; then
EOF
cat > "$A/m9.new" <<'EOF'
        if [[ "$verdict" != "RED ARM"* ]]; then
EOF
check_fires "M9 (widening): every arm must print a RED ARM verdict" m9 \
            "  a correct pair of arms passes" \
            "  a want-0 arm is not asked for a RED ARM verdict"

# --- M10: the verdict is read from the wrong end of the line -------------------------------------
# A `FAIL (1/1)` whose *reason* text happens to contain the words would pass a substring test;
# the assertion is that the verdict STARTS with `RED ARM`, which is what the driver prints.
cat > "$A/m10.old" <<'EOF'
        if [[ "$want" == 1 && "$verdict" != "RED ARM"* ]]; then
EOF
cat > "$A/m10.new" <<'EOF'
        if [[ "$want" == 1 && "$verdict" != *"RED ARM"* ]]; then
EOF
# 🔴 THE CELL THAT SEES IT IS THE ONE WHOSE VERDICT *MENTIONS* `RED ARM` WITHOUT BEING ONE.
# A plain `FAIL (1/1): the skeleton COMPILED` reads the same under prefix and substring, so the
# first named cell here proved nothing about the difference.
check_fires "M10: the by-design check becomes a substring match" m10 \
            "🔴 a FAIL that merely mentions RED ARM is still a failure" \
            "  and is named as one"

# --- (no M11) R3(b) lives in the TEST FILE, which this gate does not mutate ---------------------
# 🔴 SAID OUT LOUD RATHER THAN FAKED. The set-difference that keeps a real `06` run's raw from
# being reported as this suite's litter is in `tests/shell/test_live_p1_thirteen.sh`, not in
# `06_thirteen.sh`; this gate's subject is the STEP. A mutation here would have had to anchor
# in the test, and `check_gate_anchors.py` counts every anchor in the applier's subject -- it
# would have read as MISSING against 06. The evidence for R3(b) is the cell that plants a decoy
# run directory and asserts it is not counted ("a PREVIOUS real run's directory is not counted
# as ours"), which fails if the difference is replaced by a count.

# --- the control -----------------------------------------------------------------------------------------
cat > "$A/c1.old" <<'EOF'
expected_rc() {   # expected_rc <exercise> <which>
EOF
cat > "$A/c1.new" <<'EOF'
# which rc this arm should end on
expected_rc() {   # expected_rc <exercise> <which>
EOF
check_control "C1: a comment above expected_rc" c1

echo
NOW_SUM="$(sha256sum "$STEP" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 baseline CHANGED during the gate -- live-p1/06_thirteen.sh was written"
    echo "   before: $BASE_SUM"
    echo "   after:  $NOW_SUM"
    exit 3
fi
echo "baseline byte-identical: yes  live-p1/06_thirteen.sh  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived; $CONTROLS control(s), $CONTROLS_RED went red"
(( SURVIVED == 0 && CONTROLS_RED == 0 ))
