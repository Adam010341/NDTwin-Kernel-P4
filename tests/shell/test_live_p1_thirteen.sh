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

#: What `live-p1/runs/` held BEFORE this suite ran. Section 6 asserts on the difference, never
#: on the count: a real `06` run leaves a directory there legitimately, and a cell that counted
#: them would go red forever after the first one -- taking the gate, which refuses to run over a
#: red baseline, with it (round-3 ruling 4).
RUNS_BEFORE="$(ls -d "$LIVE/runs"/*_06_thirteen 2>/dev/null | /usr/bin/grep -v '/1970-01-01T000000Z\.pid[0-9]*_06_thirteen$' | sort)"

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
# rc 1 with a verdict that is NOT a refusal: the red arm turning out not to be red.
v = os.environ.get("VERDICT_%s_%s" % (ex, which))
if v:
    verdict = v
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

# 🔴 rc 1 IS NOT ENOUGH: the two exception arms must exit 1 *on their designed refusal*
# (round-3 ruling 2). `flowcache/skeleton` that COMPILED prints `FAIL (1/1): the skeleton
# COMPILED` and exits 1; comparing rc only, the step called that a PASS -- for exactly the
# finding it exists to report.
OUT="$(run13 flowcache RC_flowcache_skeleton=1 \
       "VERDICT_flowcache_skeleton=FAIL (1/1): the skeleton COMPILED")"; RC=$?
check "🔴 rc 1 with a NON-refusal verdict is the finding, not a pass" "1" "$RC"
has   "  named as the refusal not having happened"       "its verdict is not a designed refusal" "$OUT"
has   "  and the verdict itself is quoted"               "FAIL (1/1): the skeleton COMPILED" "$OUT"

OUT="$(run13 basic_tunnel RC_basic_tunnel_skeleton=1 \
       "VERDICT_basic_tunnel_skeleton=FAIL (1/3)")"; RC=$?
check "🔴 same for basic_tunnel's entries actually installing" "1" "$RC"
has   "  and it says the red arm is not red"             "the red arm is not red" "$OUT"

# 🔴 THE VERDICT MUST *START* WITH `RED ARM`, not merely contain it. The driver's own failure
# text can name the thing it was expecting -- and a substring test would then read a FAILURE as
# the designed refusal, which is the exact confusion this assertion exists to prevent.
OUT="$(run13 flowcache RC_flowcache_skeleton=1 \
       "VERDICT_flowcache_skeleton=FAIL (1/1): expected RED ARM, but the skeleton COMPILED")"
RC=$?
check "🔴 a FAIL that merely mentions RED ARM is still a failure" "1" "$RC"
has   "  and is named as one"                            "its verdict is not a designed refusal" "$OUT"

# 🔴 THE CONTROL FOR BOTH: an arm whose rc is 0 is not subjected to the verdict test, because
# `want` is 0 there and a designed refusal is not what it is supposed to do.
OUT="$(run13 qos "VERDICT_qos_skeleton=PASS (4/4)")"
check "  a want-0 arm is not asked for a RED ARM verdict" "0" "$?"

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
# 🔴 A SET DIFFERENCE, NOT A COUNT (round-3 ruling 4). Counting every
# `live-p1/runs/*_06_thirteen` makes this cell -- and therefore the gate, which refuses to run
# over a red baseline -- fail forever the moment somebody runs 06 for real ONCE. What this
# suite can honestly assert is that IT created none; directories from real runs are evidence
# that the step works, not litter.
# 🔴 FIXTURE NAMES ARE NOT LITTER EITHER (§9 ruling 14a). The decoy below is deliberately
# inside the glob now, and another copy of this suite may have one live while this one runs;
# `1970-01-01T000000Z.pid<N>` is a name `06` itself can never write (it stamps UTC now), so it
# is filtered by SHAPE rather than by luck.
AFTER="$(ls -d "$LIVE/runs"/*_06_thirteen 2>/dev/null | /usr/bin/grep -v '/1970-01-01T000000Z\.pid[0-9]*_06_thirteen$' | sort)"
NEW="$(comm -13 <(printf '%s\n' "$RUNS_BEFORE") <(printf '%s\n' "$AFTER"))"
check "🔴 this suite wrote no run directory into the checkout" "" "$(printf '%s' "$NEW")"
has   "  and the raw really went to the fixture instead" "$FIX/runs" "$(run13 basic)"

# 🔴 AND A REAL RUN'S RAW IS NOT LITTER. This is the half that needs a fixture to be testable
# at all: with no directory there, "count them all" and "count only mine" agree. A decoy of the
# shape `06` really writes makes them disagree -- and the all-counting version is the one that
# would go red forever after the first real run of the step, taking the gate (which refuses to
# run over a red baseline) with it.
# 🔴 THE PID GOES BEFORE THE SUFFIX, AND THAT IS THE WHOLE FIX (TICKET-P3 §9 ruling 14a).
# Round 4 wrote `..._06_thirteen.pid$$` -- which no longer matches this suite's own glob
# `*_06_thirteen`, so BEFORE2 and AFTER2 never saw the decoy at all and the set-difference cell
# below answered the same whether it used `comm -13` or plain AFTER2. The cell went green
# because the fixture was INVISIBLE, which is the cheapest way there is to pass a test: remove
# the thing it was supposed to be about. The stamp still marks it a fixture; the pid still
# keeps it ours (two suites in one checkout must not race); and now it is inside the glob.
DECOY="$LIVE/runs/1970-01-01T000000Z.pid${$}_06_thirteen"
mkdir -p "$DECOY"
BEFORE2="$(ls -d "$LIVE/runs"/*_06_thirteen 2>/dev/null | sort)"
# 🔴 THE INJECTION IS ASSERTED, NOT ASSUMED. Without this, a decoy that the glob cannot see --
# a rename, a different stamp, a runs/ that does not exist -- makes every cell below vacuous
# and green. This is the cell round 4 did not have.
has   "🔴 the decoy really is visible to the suite's own glob" "$DECOY" "$BEFORE2"
run13 basic >/dev/null 2>&1
AFTER2="$(ls -d "$LIVE/runs"/*_06_thirteen 2>/dev/null | sort)"
NEW2="$(comm -13 <(printf '%s\n' "$BEFORE2") <(printf '%s\n' "$AFTER2"))"
check "🔴 a PREVIOUS real run's directory is not counted as ours" "" "$(printf '%s' "$NEW2")"
# ... and with a plain count it WOULD have been counted -- which is what makes the cell above
# a statement about the difference rather than about an empty directory listing.
check "  (and a count, rather than a difference, would have seen it)" "$DECOY" \
      "$(printf '%s\n' "$AFTER2" | /usr/bin/grep -F "$DECOY")"
rmdir "$DECOY" 2>/dev/null

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
