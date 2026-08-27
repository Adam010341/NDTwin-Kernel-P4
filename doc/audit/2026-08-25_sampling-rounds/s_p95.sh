#!/usr/bin/env bash
# Ticket S prerequisite: does poll_veth2.sh keep its cadence on a saturated machine?
# Registered in PREREG.md amendment S-1 BEFORE this ran.  [Co-developed with claude code -- Adam]
#
# Three arms over ONE shared load, so arm-to-arm differences cannot be blamed on the load:
#   A1  new poller          A2  old poller (the CONTROL that must fail)          A3  new poller again
#
# The control is the point.  "New poller p95 < 3 s" is worthless on its own -- it is exactly what a
# too-weak load generator also produces.  A2 has to show the 3 s+ gaps or the run says nothing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OLD="$HERE/../2026-08-25_large-scale-concurrent/poll_veth.sh"
NEW="$HERE/poll_veth2.sh"
OUT="$HERE/raw_s"; mkdir -p "$OUT"
NLOAD="${NLOAD:-28}"; DUR="${DUR:-120}"; IVL="${IVL:-2}"
PIDF="$OUT/load_pids.txt"
say() { echo "[$(date +%H:%M:%S)] $*"; }

cleanup() {
    [ -f "$PIDF" ] || return 0
    while read -r p; do kill "$p" 2>/dev/null || true; done < "$PIDF"
    sleep 1
    local left=0
    while read -r p; do kill -0 "$p" 2>/dev/null && { left=$((left+1)); echo "STILL ALIVE: $p"; }; done < "$PIDF"
    say "load cleanup: $left of $(wc -l < "$PIDF") still alive (want 0)"
    rm -f "$PIDF"
}
# An interrupted run must not leave 28 spinners burning on someone else's machine.
trap cleanup EXIT INT TERM

[ -x "$OLD" ] || { echo "old poller not found/executable: $OLD"; exit 1; }
say "starting $NLOAD spinners on $(nproc) cores"
: > "$PIDF"
for _ in $(seq 1 "$NLOAD"); do bash "$HERE/s_spin.sh" & echo $! >> "$PIDF"; done
alive=0
while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done < "$PIDF"
say "  $alive of $NLOAD spinners confirmed alive"
[ "$alive" -eq "$NLOAD" ] || { say "ABORT: load did not start"; exit 1; }

say "letting the load settle (10 s)"
sleep 10

run_arm() {                                   # name  poller
    local name=$1 poller=$2
    python3 "$HERE/cell_env.py" snap "$OUT/env_${name}_a"
    say "arm $name: $(basename "$poller") for ${DUR}s"
    bash "$poller" "$OUT/${name}.tsv" "$DUR" "$IVL" 2>"$OUT/${name}.stderr" || true
    python3 "$HERE/cell_env.py" snap "$OUT/env_${name}_b"
    say "  $(cat "$OUT/${name}.stderr")"
}

run_arm A1 "$NEW"
run_arm A2 "$OLD"
run_arm A3 "$NEW"

cleanup
trap - EXIT INT TERM
say "done -- parse with s_p95_parse.py"
