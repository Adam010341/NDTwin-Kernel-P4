#!/usr/bin/env bash
# Acceptance test for ndt's lab_session predicate. No lab, no tmux, no sudo -- it drives the
# expression against every shape `ndtwin-lab status` can produce.
#
# [Co-developed with claude code -- Adam]
#
# Why this file exists. `lab_session` answers "is that lab tmux session running", and it has
# given a wrong answer twice, a week apart, for two different reasons:
#
#   2026-08-20  `... | grep -q '^topo:'`      -- grep -q exits at the first match, ndtwin-lab
#                                                still has its counts line to write, SIGPIPE,
#                                                and pipefail makes 141 the pipeline status.
#                                                A live session read as absent.
#   2026-08-21  `[[ "$out" == topo:* ]]`      -- the fix for the above, wrong in a new way.
#                                                status is one line per session sorted by name
#                                                and energy < sim < topo, so with any app
#                                                running the blob does not start with "topo:".
#                                                A live session read as absent, again.
#
# The second one was expensive: `up_p4` sweeps when `! topo_session`, so it ran `cleanup` on a
# healthy ten-switch fabric and announced it as an orphan sweep.
#
# So the property under test is not "does it find topo" but "does it stay correct when the
# output grows extra lines in front". Run:  bash tools/test_workflow/test_ndt_lab_session.sh
set -uo pipefail

NDT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/ndt"

# The expression under test, kept identical to ndt's by asserting it below rather than by
# sourcing (ndt dispatches on argv at the bottom, so it cannot be sourced).
match() { [[ $'\n'"$2"$'\n' == *$'\n'"$1":* ]]; }
EXPR='[[ $'"'"'\n'"'"'"$out"$'"'"'\n'"'"' == *$'"'"'\n'"'"'"$1":* ]]'

pass=0; fail=0
check() {
    local want="$1" name="$2" blob="$3" label="$4" got
    if match "$name" "$blob"; then got=TRUE; else got=FALSE; fi
    if [[ "$got" == "$want" ]]; then
        printf '  ok    %-44s %-7s -> %s\n' "$label" "$name" "$got"; pass=$(( pass + 1 ))
    else
        printf '  FAIL  %-44s %-7s -> %s (want %s)\n' "$label" "$name" "$got" "$want"; fail=$(( fail + 1 ))
    fi
}

NONE=$'no lab sessions\nbmv2: 0  mininet: 0'
TOPO=$'topo: 1 windows (created X)\nbmv2: 10  mininet: 138'
ETOPO=$'energy: 1 windows (created X)\ntopo: 1 windows (created X)\nbmv2: 10  mininet: 138'
EST=$'energy: 1 windows (created X)\nsim: 1 windows (created X)\ntopo: 1 windows (created X)\nbmv2: 10  mininet: 138'
ES=$'energy: 1 windows (created X)\nsim: 1 windows (created X)\nbmv2: 0  mininet: 0'

echo "the shape every test before 2026-08-21 exercised"
check TRUE  topo   "$TOPO"  "topo alone"
check FALSE energy "$TOPO"  "topo alone"

echo "the regression: an app session sorts ahead of topo"
check TRUE  topo   "$ETOPO" "energy + topo"
check TRUE  topo   "$EST"   "energy + sim + topo"
check TRUE  energy "$EST"   "energy + sim + topo"
check TRUE  sim    "$EST"   "energy + sim + topo"

echo "must still say absent when it genuinely is"
check FALSE topo   "$ES"    "energy + sim, topo gone"
check FALSE topo   "$NONE"  "no sessions at all"
check FALSE topo   ""       "empty output (sudo -n failed)"
check FALSE energy "$NONE"  "no sessions at all"

echo "must not be satisfied by a near miss"
check FALSE topo   $'topology: 1 windows\nbmv2: 0  mininet: 0'  "a session named 'topology'"
check FALSE sim    $'simulator: 1 windows\nbmv2: 0  mininet: 0' "a session named 'simulator'"
check FALSE topo   $'energy: 1 windows -- topo: in mid-line\nbmv2: 0' "'topo:' only mid-line"

echo "the implementation has not drifted from what is tested here"
if grep -qF "$EXPR" "$NDT" 2>/dev/null; then
    printf '  ok    %-44s\n' "expression still present verbatim in ndt"; pass=$(( pass + 1 ))
else
    printf '  FAIL  %-44s\n' "ndt no longer contains the tested expression"; fail=$(( fail + 1 ))
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
