#!/usr/bin/env bash
#
# tests/shell/mutate_ndt_up_down_robust.sh's OWN accounting, driven directly.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS FILE EXISTS (TICKET-P3 §9 ruling 12a). Round 3 added a `bash -n` guard to that gate
# so a mutant that does not parse would be REFUSED rather than counted -- and wrote that in the
# gate's own comments and in the ticket's report -- while the code incremented `SURVIVORS`. So a
# dead mutant still came out as `N mutations, N survived`, rc 1: the gate said one thing about
# itself and did another, which is the same defect it exists to catch, one level up.
#
# 🔴 THE GUARD HAD NEVER BEEN SEEN RED. Every mutant in that gate parses, so the branch had
# never executed in anger; "0 survived" was consistent with the guard being dead code. This file
# makes it execute, on purpose, in both directions:
#
#     * a mutant whose `ndt` does NOT parse  => a DEAD line, exit 2, and NO verdict line;
#     * a mutant that parses                 => NOT reported dead (the control -- without it,
#                                               a `syntax_ok` that always failed would pass
#                                               every assertion above).
#
# 🔴 IT DOES NOT RUN THE GATE. A full run is 106 mutations x a 424-check suite. What is under
# test here is the ACCOUNTING, so the gate's own `report`/`report_green`/verdict text is lifted
# out of the file by its own source and evaluated against a stub suite -- the shape
# tests/shell/test_ndt_app_package.sh's section 18 already uses for stack.sh's assignment. The
# functions are therefore the production ones, not copies: if somebody edits the gate, this
# test sees the edit.
#
# Run:  bash tests/shell/test_mutate_gate_dead_mutant.sh
# Env:  GATE_UNDER_TEST=<path>   (a mutation gate can point this at a copy)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE_UNDER_TEST:-$HERE/mutate_ndt_up_down_robust.sh}"
#: Section 4 re-enters this file once, against a deliberately broken copy of the gate. The flag
#: stops that copy from re-entering again (and keeps its output out of the outer count).
SELFTEST_INNER="${SELFTEST_INNER:-0}"
#: The interpreter the stdin-only wrapper in section 5 delegates to.
REAL_PY="$(cd "$HERE/../.." && pwd)/p4_proxy/venv/bin/python"
[[ -r "$GATE" ]] || { echo "  FAILED   no gate at $GATE"; echo "Ran 1 checks, 1 failed"; exit 1; }

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
# 🔴 THE VERDICT LINE HAS A SHAPE: `<n> mutations, <n> survived` at the start of a line. A
# substring test for "mutations," also matches the refusal's own prose, which is how a cell can
# look strict and assert nothing.
hasnt_verdict() {   # <name> <text>
    if /usr/bin/grep -qE '^[0-9]+ mutations,' <<<"$2"; then
        FAIL=$((FAIL+1)); printf '  FAILED   %s\n             a verdict line was printed\n' "$1"
    else
        PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    fi
}

FIX="$(mktemp -d "${TMPDIR:-/tmp}/gate-dead-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM

# --- the two mutant dirs ----------------------------------------------------------------------
# 🔴 THE DEAD ONE IS THE SHAPE THAT ACTUALLY HAPPENED, not a random syntax error: M9's anchor
# had become a PREFIX of the real call, so the replacement landed mid-line and left the rest of
# the arguments dangling after a closing brace.
mkdir -p "$FIX/dead" "$FIX/live"
cat > "$FIX/dead/ndt" <<'DEADNDT'
#!/usr/bin/env bash
up_p4() {
    verify_p4 "$topo" "$want_paths" || { rollback_up "verification failed"; return 1; } "$app_mode" "$app_pipe"
    if [[ -z "$x" ; then
        :
    fi
}
DEADNDT
cat > "$FIX/live/ndt" <<'LIVENDT'
#!/usr/bin/env bash
up_p4() {
    verify_p4 "$topo" "$want_paths" "$app_mode" "$app_pipe" || { rollback_up "no"; return 1; }
}
LIVENDT
chmod +x "$FIX/dead/ndt" "$FIX/live/ndt"

# --- the gate's own functions, lifted out by its own source -----------------------------------
# `report` calls `run_against`, which runs the real 424-check suite; that is not what is under
# test, so it is replaced AFTER the definitions are sourced. Everything else -- syntax_ok, the
# counters, both report functions, the verdict block -- is the gate's own text.
# 🔴 EXTRACTED FROM THE GATE ITSELF, NOT COPIED. These are the production functions: an edit to
# the gate changes what this test runs. Every one of them starts at column 0 and ends with a `}`
# at column 0, so `sed` can take them exactly; the verdict block is taken between its first and
# last line the same way.
lift() {   # lift <sed-address-range>
    sed -n "$1" "$GATE"
}

FUNCS="$FIX/funcs.sh"
{
    echo 'SURVIVORS=0; MUTATIONS=0; DEAD=0'
    lift '/^syntax_ok() {/,/^}/p'
    lift '/^report() {/,/^}/p'
    lift '/^report_green() {/,/^}/p'
} > "$FUNCS"

# the three things the lifted code needs from the gate's environment, stubbed so that ONLY the
# accounting is under test: the suite (not this file's subject), and the baseline sha check.
cat > "$FIX/env.sh" <<'ENVSH'
run_against() { printf '  FAILED   the named case
'; return 1; }
NDT=/dev/null
BASE_NDT=$(sha256sum /dev/null | cut -d' ' -f1)
ENVSH

harness() {   # harness <mutant-dir> <report-fn>
    {
        cat "$FIX/env.sh"
        cat "$FUNCS"
        printf '%s "M-probe: the mutation under test" "%s" "the named case"\n' "$2" "$1"
        # 🔴 ANCHORED ON `NOW_NDT=`, WHICH IS UNIQUE. A bare `/^echo$/` matched the FIRST of
        # many bare `echo` lines in the gate and dragged a whole block of mutation definitions
        # into the harness -- which then reported the PARSEABLE mutant dead, i.e. the control
        # caught a defect in the test, exactly as it is supposed to.
        lift '/^NOW_NDT=/,/^\[\[ "\$SURVIVORS" -eq 0 \]\]$/p'
    } > "$FIX/run.sh"
    bash "$FIX/run.sh" 2>&1
}

# =============================================================================================
section "1. 🔴 a mutant that does not parse is REFUSED, not counted"
# =============================================================================================
OUT="$(harness "$FIX/dead" report 2>&1)"; RC=$?
check "  the gate exits 2 (refused), not 1 (a survivor)" "2" "$RC"
has   "🔴 it says the mutant is DEAD"                    "🔴 DEAD" "$OUT"
has   "  and why that is not a measurement"              "it measures nothing" "$OUT"
has   "  the refusal is spelled out"                     "REFUSED: 1 mutant(s) are not valid bash" "$OUT"
hasnt "🔴 and it prints NO verdict line at all"          "mutation gate:" "$OUT"
hasnt "🔴 in particular it does not say anything survived" "survived" "$OUT"

OUT="$(harness "$FIX/dead" report_green 2>&1)"; RC=$?
check "  report_green refuses the same way"              "2" "$RC"
has   "  with the same DEAD line"                        "🔴 DEAD" "$OUT"
hasnt "  and no verdict line either"                     "mutation gate:" "$OUT"

# =============================================================================================
section "2. 🔴 THE CONTROL: a mutant that DOES parse is not reported dead"
# =============================================================================================
# Without this, a `syntax_ok` that failed unconditionally -- or a guard wired to the wrong
# variable -- would satisfy every assertion in section 1 while refusing the whole gate forever.
OUT="$(harness "$FIX/live" report 2>&1)"; RC=$?
check "  a parseable mutant lets the gate reach its verdict" "0" "$RC"
hasnt "🔴 it is NOT called dead"                         "🔴 DEAD" "$OUT"
hasnt "  and the gate does not refuse"                   "REFUSED" "$OUT"
has   "  the verdict line is printed"                    "mutation gate:" "$OUT"
has   "  and it counts the dead separately"              "0 dead" "$OUT"
has   "  the mutation itself was caught"                 "caught" "$OUT"

# =============================================================================================
section "3. the counters are three, not two"
# =============================================================================================
# 🔴 THE REGRESSION ITSELF. Round 3 incremented SURVIVORS in the dead branch, so `N survived`
# reported a measurement that never happened. If the dead branch ever touches SURVIVORS again,
# section 1's `hasnt survived` passes (there is no verdict line) -- this is what catches it.
check "🔴 both report functions increment DEAD, not SURVIVORS" "2" \
      "$(/usr/bin/grep -c 'DEAD=$((DEAD+1))' "$GATE")"
# 🔴 THE REGRESSION, CHECKED WHERE IT LIVES: the line right after each DEAD increment must be
# the DEAD printf, never a SURVIVORS one. `grep -A1` reads across the line break that -F cannot.
check "🔴 and no SURVIVORS increment sits in a dead branch" "0" \
      "$(/usr/bin/grep -A1 'DEAD=$((DEAD+1))' "$GATE" | /usr/bin/grep -c 'SURVIVORS=')"
has   "  the verdict is gated on DEAD"                   'if [[ "$DEAD" -gt 0 ]]; then' "$(cat "$GATE")"

# =============================================================================================
section "5. 🔴 mutate_drive_exercise.sh answers about ITSELF, not about its subject"
# =============================================================================================
# TICKET-P3 §9 rulings 14d and 15①. Two separate defects, one symptom.
#
#   * round 4: PREP/DRIVER were RELATIVE, so run from another checkout the gate read THAT
#     checkout's drive_exercise.py, found no anchors, and said `ANCHOR IS NOT UNIQUE (0
#     matches) -- Fix the anchor`: true about the file it opened, false about its subject.
#   * round 5: the refusal added for that was `exit 2` INSIDE `anchor_count`, which is only
#     ever called as `n=$(anchor_count ...)`. `exit` ends the command substitution, not the
#     gate. The parent read `n=""`, `[[ "" -ne 1 ]]` was true, and the gate printed 87 lines of
#     `🔴  matches`, `ANCHORS: BROKEN -- 87 anchor(s) have moved` and `86 mutations, 87
#     survived`, rc 1. The fix was cosmetic and the test that "proved" it ran the gate only in
#     ANCHOR_CHECK mode -- which exits 2 unconditionally, so the rc-2 cell was vacuous and the
#     `ANCHOR IS NOT UNIQUE` text it asserted absent is never printed in that mode at all.
#
# 🔴 SO THIS RUNS THE GATE IN GATE MODE. It is cheap: with a broken interpreter the gate must
# refuse before it runs a single mutation.
DRVGATE="${DRVGATE_UNDER_TEST:-$HERE/mutate_drive_exercise.sh}"
if [[ -r "$DRVGATE" ]]; then
    mkdir -p "$FIX/badpy"
    printf '#!/bin/sh\necho "ImportError: no pathlib here" >&2\nexit 1\n' > "$FIX/badpy/python"
    chmod +x "$FIX/badpy/python"

    # 🔴 (a) GATE MODE, broken interpreter: refuse, and say nothing that sounds like a result.
    OUT="$(PYTHON="$FIX/badpy/python" timeout 600 bash "$DRVGATE" 2>&1)"; RC=$?
    check "🔴 gate mode with a dead interpreter exits 2"     "2" "$RC"
    hasnt_verdict "🔴 and prints NO verdict line"            "$OUT"
    hasnt "🔴 no 'ANCHOR IS NOT UNIQUE' about the subject"   "ANCHOR IS NOT UNIQUE" "$OUT"
    hasnt "🔴 no empty-count line"                           "( matches)" "$OUT"
    hasnt "🔴 and no 'anchor(s) have moved'"                 "have moved" "$OUT"
    has   "  it is named as the gate's own refusal"          "REFUSED" "$OUT"

    # 🔴 (b) THE anchor_count PATH SPECIFICALLY. (a) refuses at the baseline suite, which is
    # earlier; this interpreter runs unittest normally and fails ONLY on the `-` (stdin) script
    # that anchor_count uses, so the refusal has to come from anchor_count's own return.
    cat > "$FIX/badpy/stdin-only" <<PYWRAP
#!/bin/sh
for a in "\$@"; do [ "\$a" = "-" ] && { echo "SyntaxError: refused stdin" >&2; exit 1; }; done
exec "$REAL_PY" "\$@"
PYWRAP
    chmod +x "$FIX/badpy/stdin-only"
    OUT="$(PYTHON="$FIX/badpy/stdin-only" timeout 900 bash "$DRVGATE" 2>&1)"; RC=$?
    check "🔴 an anchor_count that cannot run exits 2"       "2" "$RC"
    has   "  named as anchor_count's failure"                "REFUSED: anchor_count could not run" "$OUT"
    has   "  and the parent shell acts on it"                "the gate could not count anchors" "$OUT"
    hasnt_verdict "🔴 no verdict line"                       "$OUT"
    hasnt "🔴 not folded into 'the anchor is stale'"         "ANCHOR IS NOT UNIQUE" "$OUT"

    # 🔴 (c) FROM A FOREIGN CWD the subject is still the right file (round 4's defect).
    OUT="$(ANCHOR_CHECK=1 timeout 600 env -C /tmp bash "$DRVGATE" 2>&1)"
    has   "🔴 run from /tmp every anchor still resolves"     "ANCHORS: ok" "$OUT"
    hasnt "  nothing reported as a stale anchor"             "ANCHOR IS NOT UNIQUE" "$OUT"
    has   "  and the header names the cwd it ran in"         "cwd        : /tmp" "$OUT"
    has   "  the resolved subject"                           "drive_exercise.py" "$OUT"
    has   "  and the subject's sha"                          "subject sha:" "$OUT"
else
    FAIL=$((FAIL+1)); printf '  FAILED   no mutate_drive_exercise.sh at %s\n' "$DRVGATE"
fi

if [[ "$SELFTEST_INNER" == 1 ]]; then
    printf '\n'
    echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
    (( FAIL == 0 )); exit
fi

# =============================================================================================
section "4. 🔴 the lift must FAIL LOUDLY when the gate's shape changes"
# =============================================================================================
# The judge's scenario (§9 ruling 14c). Everything above is built on `sed` pulling the gate's
# own functions out by name. If somebody renames `run_against`, or moves the verdict block, the
# lift silently produces something that does not run -- and a harness that quietly produced
# nothing would report... nothing, which `hasnt` reads as success. So: rename it in a copy and
# assert the harness goes RED rather than quietly passing.
RENAMED="$FIX/gate-renamed.sh"
sed 's/^run_against()/run_against_RENAMED()/; s/out=$(run_against /out=$(run_against_RENAMED /' \
    "$GATE" > "$RENAMED"
check "  the rename really changed the copy"             "0" \
      "$(/usr/bin/grep -qF 'run_against_RENAMED' "$RENAMED"; echo $?)"
OUT="$(SELFTEST_INNER=1 GATE_UNDER_TEST="$RENAMED" timeout 300 bash "${BASH_SOURCE[0]}" 2>&1)"; RC=$?
check "🔴 a gate whose shape moved makes THIS suite red, not green" "1" "$RC"
has   "  and it is visible as a failure, not as silence" "FAILED" "$OUT"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
