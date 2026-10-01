#!/usr/bin/env bash
#
# Mutation gate for the fixture-spawn helpers of six suites: a fixture that never takes its argv0
# must be a FAILED check the suite COUNTS, followed by a summary line and a non-zero exit.
#
# [Co-developed with claude code -- Adam]
#
# WHAT WENT WRONG (measured 2026-09-28). Each helper polled /proc for 1-2 s and then ran `exit 1`,
# but every caller wrote X="$(spawn_fixture ...)", so that exit left only the command substitution.
# The variable then held the helper's own "Ran N checks" text, the FAILED line the helper printed
# was never counted (test_ndt_apps_liveness.sh printed 23 FAILED lines under "Ran 51 checks, 17
# failed"), and test_ndtwin_lab_sweep.sh -- errexit is on there, left behind by the ndtwin-lab it
# sources -- stopped at the assignment without printing any summary.
#
# EACH MUTATION makes one suite's helper unable to recognise its fixture: the argv0 comparison gets
# a suffix no fixture wears, so the poll runs to its bound and gives up, the way it would for a
# fixture too slow to exec. The mutant must then
#   1. exit non-zero,
#   2. print a "Ran N checks, M failed" summary,
#   3. print a FAILED line for the fixture itself,
#   4. COUNT it -- M equals the number of FAILED lines it printed --
#   5. and not leave the fixture it gave up on running (every pid named after that FAILED line).
#
# A mutant is a copy BESIDE its suite (tests/shell/.spawn-gate-<pid>-<label>-<suite>), so every path
# the suite derives from its own location -- lib_probe_stub.sh, check_process_by_name.py,
# ../../tools -- is the real one; a copy anywhere else cannot find them, which is why two of these
# six went unmeasured the first time. Each copy is removed after its run and on exit. Each suite's
# CONTROL is an unmutated copy made the same way, and it must be green: a copy that lost a sibling
# would go red for that reason and read as a catch. The judge itself is held first to five synthetic
# runs, each built to come out one way.
#
# Usage: bash tests/shell/mutate_fixture_spawn_helpers.sh
#   TEST_TIMEOUT=600   seconds allowed per suite run
# Exit: 0 every mutation caught, every control green; 1 a mutation survived; 2 refused (a control
#       that did not come out as it must, an anchor not exactly once, harness)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORPHANS="$HERE/test_ndt_app_orphans.sh"
LIVENESS="$HERE/test_ndt_apps_liveness.sh"
SWEEP="$HERE/test_ndtwin_lab_sweep.sh"
WINDOW="$HERE/test_ndt_helper_apps_window.sh"
TOPO_PID="$HERE/test_faults_topo_pid.sh"
OVS_CLAIM="$HERE/test_ndt_ovs_claim.sh"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
command -v timeout >/dev/null 2>&1 || { echo "refused: GNU timeout is required"; exit 2; }
cd "$HERE/../.." || { echo "refused: cannot cd to the repo root"; exit 2; }
trap 'rm -f "$HERE"/.spawn-gate-$$-*' EXIT
SURVIVORS=0; MUTATIONS=0

# --- one run, and the rule that reads it -------------------------------------------------------
run_one() {   # run_one <file> -> RUN_OUT, RUN_RC, RUN_S
    local t0=$SECONDS
    RUN_OUT="$(timeout "$TEST_TIMEOUT" bash "$1" </dev/null 2>&1)"; RUN_RC=$?
    RUN_S=$(( SECONDS - t0 ))
}
# A fixture is still there if /proc has it, it is not a zombie, and it is still a `sleep`.
fixture_alive() { [[ "$(cat "/proc/$1/comm" 2>/dev/null)" == sleep ]] \
                  && [[ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]]; }
judge() {   # judge -> "caught (...)" or "SURVIVED (...)", read from RUN_OUT and RUN_RC
    local ran m printed fixline pid i left=""
    ran="$(grep -E '^Ran [0-9]+ checks' <<<"$RUN_OUT" | tail -1)"
    printed="$(grep -cE '^ *FAILED ' <<<"$RUN_OUT")"
    fixline="$(grep -m1 -E '^ *FAILED +fixture .*argv0' <<<"$RUN_OUT" | sed 's/^ *//')"
    m=""
    [[ "$ran" =~ ^Ran\ [0-9]+\ checks,\ ([0-9]+)\ failed ]] && m="${BASH_REMATCH[1]}"
    [[ "$ran" =~ ^Ran\ [0-9]+\ checks,\ all\ passed ]] && m=0
    (( RUN_RC != 0 )) || { echo "SURVIVED (rc 0)"; return; }
    [[ -n "$ran" ]] || { echo "SURVIVED (rc $RUN_RC, and no \"Ran N checks\" line at all)"; return; }
    [[ -n "$m" ]] || { echo "SURVIVED (a summary this gate cannot read: $ran)"; return; }
    [[ -n "$fixline" ]] || { echo "SURVIVED (no FAILED line names the fixture; $ran)"; return; }
    (( m == printed )) || { echo "SURVIVED ($printed FAILED line(s) printed, the summary counts $m: $ran)"; return; }
    for pid in $(sed -n '/^ *FAILED  *fixture .*argv0/,$p' <<<"$RUN_OUT" | grep -oE 'pid [0-9]+' | cut -d' ' -f2); do
        for i in 1 2 3 4 5 6 7 8 9 10; do fixture_alive "$pid" || break; sleep 0.3; done
        fixture_alive "$pid" && left="$left $pid"
    done
    [[ -z "$left" ]] || { echo "SURVIVED (the fixture it gave up on is still running: pid$left)"; return; }
    echo "caught (rc $RUN_RC; $ran; ${fixline:0:80})"
}

# --- the judge's own controls: each must come out as stated, or nothing below means anything ----
echo "the judge, on synthetic runs:"
jcontrol() {   # jcontrol <name> <rc> <output> <the glob the verdict must match>
    local v
    RUN_RC="$2"; RUN_OUT="$3"; v="$(judge)"
    # shellcheck disable=SC2053  # $4 IS a glob
    if [[ "$v" == $4 ]]; then printf '  ok       %s -> %s\n' "$1" "${v:0:100}"
    else printf '  refused: control "%s" answered "%s", not "%s"\n' "$1" "${v:0:100}" "$4"; exit 2; fi
}
jcontrol "J1: a FAILED fixture line the summary does not count" 1 \
    $'  FAILED   fixture never took argv0=x\nRan 3 checks, 0 failed' 'SURVIVED (1 FAILED line(s) printed, the summary counts 0*'
jcontrol "J2: no summary line at all" 1 \
    $'  FAILED   fixture never took argv0=x' 'SURVIVED (rc 1, and no "Ran N checks" line at all)'
jcontrol "J3: rc 0" 0 \
    $'  FAILED   fixture took argv0=x\nRan 2 checks, 1 failed' 'SURVIVED (rc 0)'
jcontrol "J4: a counted failure that is not the fixture's" 1 \
    $'  FAILED   something else\nRan 2 checks, 1 failed' 'SURVIVED (no FAILED line names the fixture*'
jcontrol "J5: the fixture's failure, counted" 1 \
    $'  ok       before\n  FAILED   fixture took argv0=x\n             expected: x\nRan 2 checks, 1 failed' 'caught (rc 1; Ran 2 checks, 1 failed;*'

# --- the suites --------------------------------------------------------------------------------
# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate. The control is
# the same copy without the replacement; both need the anchor exactly once.
gate_suite() {   # $1 = label, $2 = file (the suite), $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local ctl="$HERE/.spawn-gate-$$-control-$label-$(basename "$file")"
    local mut="$HERE/.spawn-gate-$$-$label-$(basename "$file")"
    local n r
    n="$(python3 - "$file" "$ctl" "$mut" "$old" "$new" <<'PY'
import sys
src, ctl, mut, a, b = sys.argv[1:6]
s = open(src).read()
if s.count(a) == 1:
    open(ctl, "w").write(s)
    open(mut, "w").write(s.replace(a, b, 1))
print(s.count(a))
PY
)"
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$n" != 1 ]]; then
        printf '  refused: %s -- the anchor occurs %s time(s) in %s, not once\n' "$label" "${n:-?}" "${file#"$HERE/"}"
        exit 2
    fi
    run_one "$ctl"; rm -f "$ctl"
    if (( RUN_RC != 0 )) || ! grep -qE '^Ran [0-9]+ checks, (0 failed|all passed)' <<<"$(grep -E '^Ran ' <<<"$RUN_OUT" | tail -1)" \
            || grep -qE '^ *FAILED ' <<<"$RUN_OUT"; then
        printf '  refused: %s -- the unmutated copy is not green (rc %s): %s\n' "$label" "$RUN_RC" \
               "$(grep -E '^ *FAILED |^Ran ' <<<"$RUN_OUT" | head -3 | paste -sd'|' -)"
        exit 2
    fi
    printf '  control  %-10s %s  (%ss)\n' "$label" "$(grep -E '^Ran ' <<<"$RUN_OUT" | tail -1)" "$RUN_S"
    run_one "$mut"; rm -f "$mut"
    r="$(judge)"
    [[ "$r" == SURVIVED* ]] && SURVIVORS=$((SURVIVORS+1))
    printf '  %-8s %-10s %s  (%ss)\n' "${r%% (*}" "$label" "(${r#* (}" "$RUN_S"
    printf '             its fixture FAILED line: %s\n' \
           "$(grep -m1 -E '^ *FAILED +fixture .*argv0' <<<"$RUN_OUT" | sed 's/^ *//' | cut -c1-110)"
    printf '             its last line:           %s\n' "$(tail -1 <<<"$RUN_OUT" | cut -c1-110)"
}

echo
echo "each suite: its unmutated copy green, then its helper made to never match (the poll's bound)"
gate_suite orphans   "$ORPHANS"   '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
gate_suite liveness  "$LIVENESS"  '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
gate_suite sweep     "$SWEEP"     '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
gate_suite window    "$WINDOW"    '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
gate_suite topo_pid  "$TOPO_PID"  '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
gate_suite ovs_claim "$OVS_CLAIM" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'

echo
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s)"
(( SURVIVORS == 0 ))
