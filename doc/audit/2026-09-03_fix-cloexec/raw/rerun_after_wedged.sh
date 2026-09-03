#!/usr/bin/env bash
#
# Re-runs the after-wedgedproxy arm on its own.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS EXISTS, AND WHY IT IS NOT A DO-OVER OF A RESULT I DID NOT LIKE
# run_all_arms.sh ran before-wedgedproxy and then after-wedgedproxy back to back with no gap. The
# second arm printed "REFUSING TO START: :8000 or :6343 is already bound" and stopped, and its
# holders were `curl` and `sh` -- the orphans the FIRST arm's last unfixed kernel had left behind.
# The defect ate its own experiment. That refusal is kept in after-wedgedproxy.log.first-attempt.
#
# The fix is a settle wait BETWEEN arms, placed in this runner rather than in
# port_release_experiment.sh, so that the measurement script is byte-identical across all four
# arms and no arm can be accused of having been measured by a different program.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AFTER_BIN="${AFTER_BIN:?after binary}"
TRIALS="${TRIALS:-8}"

ports_busy() {
    [[ -n "$(ss -H -ltn 'sport = :8000' 2>/dev/null)$(ss -H -uln 'sport = :6343' 2>/dev/null)" ]]
}

echo "### settle: waiting for :8000 and :6343 to be free"
for i in $(seq 1 120); do
    ports_busy || break
    sleep 0.5
done
if ports_busy; then
    echo "### still busy after 60 s; holders:"
    ss -H -ltnp 'sport = :8000'; ss -H -ulnp 'sport = :6343'
    exit 2
fi
echo "### settled after ${i} polls of 0.5 s"

python3 "$HERE/blackhole_8081.py" > "$HERE/blackhole.rerun.out" 2>&1 </dev/null &
BH=$!
trap 'kill -TERM "$BH" 2>/dev/null' EXIT
for i in $(seq 1 40); do
    [[ -n "$(ss -H -ltn 'sport = :8081' 2>/dev/null)" ]] && break
    sleep 0.25
done
echo "### blackhole pid $BH on :8081"

bash "$HERE/port_release_experiment.sh" "$AFTER_BIN" after-wedgedproxy "$TRIALS" \
    "$HERE/after-wedgedproxy" > "$HERE/after-wedgedproxy.log" 2>&1 </dev/null
echo "### arm after-wedgedproxy exit $?"

kill -TERM "$BH" 2>/dev/null
for i in $(seq 1 40); do [[ -d "/proc/$BH" ]] || break; sleep 0.25; done
echo "### blackhole stopped; :8081 listeners now: $(ss -H -ltn 'sport = :8081' | wc -l)"
