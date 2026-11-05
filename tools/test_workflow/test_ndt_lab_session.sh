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
# [Co-developed with claude code -- Adam] Not "sudo -n failed": a failed call returns 2 before this match
# is reached (the real function is driven below). What reaches the match with nothing in it is a
# status call that succeeded and printed nothing, and that is "no session".
check FALSE topo   ""       "empty output (the call succeeded, printed nothing)"
check FALSE energy "$NONE"  "no sessions at all"

echo "must not be satisfied by a near miss"
check FALSE topo   $'topology: 1 windows\nbmv2: 0  mininet: 0'  "a session named 'topology'"
check FALSE sim    $'simulator: 1 windows\nbmv2: 0  mininet: 0' "a session named 'simulator'"
check FALSE topo   $'energy: 1 windows -- topo: in mid-line\nbmv2: 0' "'topo:' only mid-line"

# [Co-developed with claude code -- Adam]
# On 2026-09-02 `ndtwin-lab status` gained a first line naming the config source and the
# KERNEL_DIR in use, so this file's claim to cover "every shape status can produce" needs the
# new shape or it stops being true. Two directions matter: the extra line must not hide a
# session that is there, and -- because it carries a PATH, which is attacker-adjacent in the
# sense that it is whatever the config file said -- it must not manufacture one that is not.
CFG='config: /etc/ndtwin-lab.conf (KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel)'
CFG_TOPO="$CFG"$'\n'"$TOPO"
CFG_NONE="$CFG"$'\n'"$NONE"

echo "the config line does not change any answer"
check TRUE  topo   "$CFG_TOPO" "config line + topo"
check FALSE energy "$CFG_TOPO" "config line + topo"
check FALSE topo   "$CFG_NONE" "config line + no sessions"
# A KERNEL_DIR that happens to contain a session name followed by a colon is the near-miss the
# config line makes newly possible, and it is a path an operator chooses, not this script.
check FALSE topo   "config: /etc/ndtwin-lab.conf (KERNEL_DIR=/home/adam/topo:2)"$'\n'"$NONE" \
      "a KERNEL_DIR containing 'topo:'"

echo "the implementation has not drifted from what is tested here"
if grep -qF "$EXPR" "$NDT" 2>/dev/null; then
    printf '  ok    %-44s\n' "expression still present verbatim in ndt"; pass=$(( pass + 1 ))
else
    printf '  FAIL  %-44s\n' "ndt no longer contains the tested expression"; fail=$(( fail + 1 ))
fi

# [Co-developed with claude code -- Adam]
# The real lab_session, not the copy of its expression above: ndt is sourced through its own seam and
# `sudo` is a shell function that stands for the status call. 0 = listed, 1 = not listed, 2 = the call
# itself failed -- and a failed call is "cannot tell" whatever it printed before it failed.
real() {   # real '<body of the fake sudo>'  -> lab_session topo's rc
    bash -c "source '$NDT' >/dev/null 2>&1; sudo() { $1; }; lab_session topo; echo \$?" 2>/dev/null | tail -1
}
rcheck() {   # rcheck <want rc> <label> '<body of the fake sudo>'
    local want="$1" label="$2" got
    got="$(real "$3")"
    if [[ "$got" == "$want" ]]; then
        printf '  ok    %-60s -> rc %s\n' "$label" "$got"; pass=$(( pass + 1 ))
    else
        printf '  FAIL  %-60s -> rc %s (want %s)\n' "$label" "$got" "$want"; fail=$(( fail + 1 ))
    fi
}
echo "the real lab_session: a failed status call is rc 2, not 'no session'"
rcheck 2 "the call is refused (rc 1, no output)"            'return 1'
rcheck 2 "the call fails after printing a topo line"        'printf "topo: 1 windows\n"; return 3'
rcheck 2 "the call fails after printing 'no lab sessions'"  'printf "no lab sessions\n"; return 1'
rcheck 0 "control: a topo session is listed"                'printf "config: c\ntopo: 1 windows\nbmv2: 4  mininet: 0\n"'
rcheck 1 "control: 'no lab sessions'"                       'printf "no lab sessions\nbmv2: 0  mininet: 0\n"'
rcheck 1 "control: the call succeeded and printed nothing"  'return 0'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
