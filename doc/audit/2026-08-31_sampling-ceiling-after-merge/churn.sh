#!/usr/bin/env bash
# Short-lived-process contamination, on purpose.  Each child burns CPU for a fraction of a second
# and exits, so almost none of them is alive at both ends of a 20s gate window -- which is exactly
# the population the pre-fix gate charged at zero cores.
#
# Self-terminating on a deadline: nothing here may outlive the experiment, and the project forbids
# pkill -f, so the loop must end by itself rather than by being hunted down.
set -u
secs="${1:-20}"
deadline=$(( $(date +%s) + secs ))
n=0
while [[ "$(date +%s)" -lt "$deadline" ]]; do
    for _ in 1 2 3 4; do
        bash -c 'x=0; for i in $(seq 1 120000); do x=$((x+i)); done' &
    done
    wait
    n=$(( n + 4 ))
done
echo "churn: spawned $n short-lived children over ${secs}s"
