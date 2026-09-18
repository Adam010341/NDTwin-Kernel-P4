#!/usr/bin/env bash
#
# live-p1/06_thirteen.sh, driven OFFLINE against a stub driver.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS FILE EXISTS. 06 had no test at all, and the one decision it makes was inverted:
# `expected_rc()` wanted rc 1 from every skeleton arm, so a completely correct round of
# twenty-six arms would have printed `FAIL 06_thirteen -- 11 of 26` (judge A2, TICKET-P3
# section 9 ruling 9). Nothing in the repo would have said so before the lab did.
#
# 🔴 "RED" IS A PROPERTY OF THE EXPECTATIONS, NOT OF THE EXIT CODE. drive_exercise.py's
# skeleton arms assert the red things -- "h2 received 0 packets", "every reported port is 0",
# "the flow is NOT blocked" -- so a skeleton behaving the way the exercise says it does meets
# every one of them and the driver exits 0. The 2026-09-08 and 2026-09-18 real runs are exactly
# that: `>>> PASS (2/2)` and `PASS (4/4)` on skeleton arms, exit 0, in live-p1/../runs/.
# The two exceptions are the arms whose red is a REFUSAL: flowcache's skeleton (p4c) and
# basic_tunnel's skeleton on NDTwin (pre-flight), which report `RED ARM (n/n): ... by design`
# and exit 1.
#
# The driver is replaced by a stub on PATH whose rc is a table this file writes, so nothing
# here reaches root, a lab, `ndt`, Mininet or ~/tutorials. `ONLY=` keeps each case to the arms
# it is about.
#
# Run:  bash tests/shell/test_live_p1_thirteen.sh
# Env:  THIRTEEN_UNDER_TEST=<path>   (tests/shell/mutate_live_p1_thirteen.sh points it at a copy)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
LIVE="$REAL_REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1"
STEP="${THIRTEEN_UNDER_TEST:-$LIVE/06_thirteen.sh}"
[[ -r "$STEP" ]] || { echo "  FAILED   no 06_thirteen.sh at $STEP"; echo "Ran 1 checks, 1 failed"; exit 1; }

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has()   { /usr/bin/grep -qF -- "$2" <<<"$3" && { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; } \
          || { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"; }; }
hasnt() { /usr/bin/grep -qF -- "$2" <<<"$3" && { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             unexpected: [%s]\n' "$1" "$2"; } \
          || { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-13-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM

# --- the stub driver -----------------------------------------------------------------------
# 🔴 IT PRINTS WHAT THE REAL ONE PRINTS. 06 reads two lines out of each run -- the `>>> ` verdict
# and the `report: ` path -- and nothing else, so the stub emits both; a stub that printed
# neither would make every "the table carries the verdict" cell pass over a step that had
# stopped reading them.
cat > "$FIX/driver.py" <<'STUB'
#!/usr/bin/env python3
import os, sys
ex = sys.argv[1]
which = sys.argv[sys.argv.index("--which") + 1]
rc = int(os.environ.get("RC_%s_%s" % (ex, which), "0"))
verdict = {0: "PASS (4/4)", 1: "FAIL (1/4)", 2: "ERROR"}[rc]
if rc == 1 and os.environ.get("BY_DESIGN_%s_%s" % (ex, which)):
    verdict = "RED ARM (1/1): the skeleton does not get past the control plane, by design"
print(">>> %s" % verdict)
print("report: /nowhere/%s_%s.md" % (ex, which))
sys.exit(rc)
STUB
chmod +x "$FIX/driver.py"

# 06 runs "$VENV_PY" "$DRIVER"; both are overridable, and the step derives DRIVER from its own
# location -- so the copy under test is handed the stub explicitly.
run13() {   # run13 <ONLY list> [<extra env assignments>...]
    local only="$1"; shift
    env -i PATH="/usr/bin:/bin" HOME="$FIX" TMPDIR="$FIX" NO_COLOR=1 \
        NDT_OWNER=t ONLY="$only" VENV_PY="/usr/bin/python3" \
        DRIVER_UNDER_TEST="$FIX/driver.py" RUNS_DIR="$FIX/runs" "$@" \
        bash "$STEP" 2>&1
}

# =============================================================================================
section "1. 🔴 a correct SKELETON arm exits 0, and the step expects that"
# =============================================================================================
# The whole of judge A2. With rc 1 expected from every skeleton, a completely correct round is
# reported as a failure -- eleven of twenty-six, one per exercise whose red arm is a data-plane
# reading rather than a refusal.
OUT="$(run13 basic)"
check "  a correct pair of arms passes"                  "0" "$?"
has   "  and says so"                                    "PASS 06_thirteen" "$OUT"
# 🔴 `hasnt`, NOT `has "rc=0 (want 0)"`. The SOLUTION arm prints that line too, so a `has`
# would be satisfied by it while the skeleton arm wanted 1 -- which is exactly the defect.
hasnt "🔴 neither arm of a correct pair wants a non-zero rc" "(want 1)" "$OUT"

OUT="$(run13 basic RC_basic_skeleton=1)"; RC=$?
check "🔴 a skeleton arm that FAILED an expectation is the finding" "1" "$RC"
has   "  named as the red arm not being red"             "Its expectations ARE the red ones" "$OUT"

OUT="$(run13 basic RC_basic_solution=1)"; RC=$?
check "  and a solution arm that failed is a failure too" "1" "$RC"

# =============================================================================================
section "2. 🔴 the two arms whose red is a REFUSAL are the exceptions"
# =============================================================================================
OUT="$(run13 flowcache RC_flowcache_skeleton=1 BY_DESIGN_flowcache_skeleton=1)"
check "  flowcache's skeleton is expected to exit 1"     "0" "$?"
has   "  and the table carries the by-design verdict"    "by design" "$OUT"
OUT="$(run13 flowcache)"; RC=$?
check "🔴 a flowcache skeleton that exits 0 is the finding" "1" "$RC"
has   "  because p4c was supposed to refuse it"          "rc=0 (want 1)" "$OUT"

OUT="$(run13 basic_tunnel RC_basic_tunnel_skeleton=1 BY_DESIGN_basic_tunnel_skeleton=1)"
check "  basic_tunnel's skeleton is expected to exit 1 here" "0" "$?"
OUT="$(run13 basic_tunnel)"; RC=$?
check "🔴 and one that exits 0 is the finding"            "1" "$RC"

# 🔴 THE CONTROL: the exception is per exercise, not a blanket "1 is fine for skeletons".
OUT="$(run13 qos RC_qos_skeleton=1)"; RC=$?
check "🔴 qos's skeleton exiting 1 is still a failure"    "1" "$RC"

# =============================================================================================
section "3. 🔴 rc 2 is not evidence either way"
# =============================================================================================
OUT="$(run13 basic RC_basic_solution=2)"; RC=$?
check "  a round that never ran fails the step"          "1" "$RC"
has   "  and says it is not a result about the exercise" "That is not a result about the exercise" "$OUT"

# =============================================================================================
section "4. the table, and what the step reads out of each run"
# =============================================================================================
OUT="$(run13 basic,calc)"
check "  two exercises is four arms"                     "0" "$?"
has   "  the table names each arm"                       "basic" "$OUT"
has   "  with the verdict the driver printed"            "PASS (4/4)" "$OUT"
has   "  and the report path"                            "/nowhere/calc_solution.md" "$OUT"
has   "  the count is arms, not exercises"               "4 arm(s)" "$OUT"

# 🔴 EVERY ARM RUNS EVEN AFTER ONE FAILS. A loop that stopped at the first red would report one
# broken exercise and say nothing about the other twelve, which is the opposite of what a table
# is for.
OUT="$(run13 basic,calc RC_basic_skeleton=1)"
has   "🔴 a failure does not stop the loop"              "/nowhere/calc_solution.md" "$OUT"

# =============================================================================================
section "5. the refusals, before anything is written"
# =============================================================================================
OUT="$(env -i PATH="/usr/bin:/bin" HOME="$FIX" TMPDIR="$FIX" NO_COLOR=1 NDT_OWNER=t \
        VENV_PY="/nowhere/python" DRIVER_UNDER_TEST="$FIX/driver.py" RUNS_DIR="$FIX/runs" \
        bash "$STEP" 2>&1)"; RC=$?
check "🔴 no interpreter with scapy is rc 2"             "2" "$RC"
has   "  naming it"                                      "no interpreter at" "$OUT"

# =============================================================================================
section "6. 🔴 this suite leaves nothing in the checkout"
# =============================================================================================
# R3 with the repo as the target instead of /tmp: every run of this file used to leave a
# `live-p1/runs/<UTC>_06_thirteen/` directory behind, because 06 derives its raw directory from
# its own location. RUNS_DIR is the seam; this is the assertion that the cells above used it.
LEFT="$(ls -d "$LIVE/runs"/*_06_thirteen 2>/dev/null | wc -l)"
check "🔴 no run directory was written into the checkout" "0" "$LEFT"
has   "  and the raw really went to the fixture instead" "$FIX/runs" "$(run13 basic)"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
