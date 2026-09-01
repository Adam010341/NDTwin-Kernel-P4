#!/usr/bin/env bash
# §B driver -- owns the witness lifetime AND every cell, in one process.
# [Co-developed with claude code -- Adam]
#
# Why a driver instead of separate calls: a witness started in one shell and cells run from
# the next is a witness that can die between them without anyone noticing. It did, today --
# `setsid host_witness.sh 5 400 &` produced five samples and stopped when the calling shell
# went away, and only a two-reads-apart line count showed it. One process, one lifetime.
#
# Order is the amendment's order and is not negotiable: the loopback control runs FIRST and
# its verdict prints BEFORE any fabric cell. A control run afterwards is a control you can
# decide not to look at.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
RAW="$HERE/raw"; mkdir -p "$RAW"
: "${NDT_OWNER:?NDT_OWNER must be set}"

# SUF appends to every label so a re-run cannot overwrite the first run's arms.
# It changes the NAME of the output directory and nothing that is measured.
SUF="${SUF:-}"


echo "=== §B TCP control -- $(date -Is) ==="

# --------------------------------------------------------------- witness, as a direct child
# Direct child, so $! is the witness itself and not a wrapper. Stopped by that recorded pid
# at the end -- never by pattern.
bash "$REPO/tools/remote-lab/host_witness.sh" 5 400 > "$RAW/host_witness$SUF.log" 2>&1 &
WPID=$!
sleep 6
[ "$(wc -l < "$RAW/host_witness$SUF.log")" -ge 2 ] || { echo "🔴 witness produced nothing"; exit 1; }
echo "witness pid=$WPID, $(wc -l < "$RAW/host_witness$SUF.log") lines so far"

cleanup() {
  if kill -0 "$WPID" 2>/dev/null; then kill "$WPID" 2>/dev/null; sleep 2; fi
  echo "witness stopped; $(wc -l < "$RAW/host_witness$SUF.log") samples total"
}
trap cleanup EXIT

cell() {  # cell <mode> <n> <label>
  echo; echo "--- $3$SUF ($1, n=$2) $(date +%T) ---"
  NDT_OWNER="$NDT_OWNER" bash "$HERE/run_tcp_cell.sh" "$1" "$2" "$3$SUF" 2>&1 | sed 's/^/    /'
  sleep 3
}

med() { sed -n 's/^aggregate_goodput_mbit_median=//p' "$RAW/$1$SUF/cell.meta" 2>/dev/null; }

# --------------------------------------------------------------- 1. the registered control
echo; echo "############ CONTROL (loopback, no switch in path) -- runs first ############"
cell loopback 1  tcp_loop_n1_a
cell loopback 16 tcp_loop_n16_a
cell loopback 1  tcp_loop_n1_b
cell loopback 16 tcp_loop_n16_b

L1A=$(med tcp_loop_n1_a);  L16A=$(med tcp_loop_n16_a)
L1B=$(med tcp_loop_n1_b);  L16B=$(med tcp_loop_n16_b)
echo; echo "############ CONTROL VERDICT (registered before data) ############"
printf '  loopback  n=1  : %s / %s Mbit\n' "$L1A" "$L1B"
printf '  loopback  n=16 : %s / %s Mbit\n' "$L16A" "$L16B"
python3 - "$L1A" "$L16A" "$L1B" "$L16B" <<'PY'
import sys
a1,a16,b1,b16 = (float(x) for x in sys.argv[1:5])
if min(a1,a16,b1,b16) < 0:
    print("  🔴 a cell failed to measure (-1). The control is void; do not read the fabric cells.")
    raise SystemExit
r = ((a16/a1)+(b16/b1))/2
print(f"  T(16)/T(1) per arm: {a16/a1:.3f} / {b16/b1:.3f}   mean {r:.3f}")
if   r >= 0.9: print("  ✅ >= 0.9 -- the host does not collapse on its own; a fabric collapse is ATTRIBUTABLE.")
elif r <= 0.5: print("  🔴 <= 0.5 -- the HOST collapses with no switch in path. §B is UNINTERPRETABLE; report as such.")
else:          print("  ⚠️  0.5-0.9 -- control itself ambiguous; fabric numbers may only appear BESIDE it.")
PY

# --------------------------------------------------------------- 2. the fabric cells
echo; echo "############ FABRIC (h1 -> h65, five switches, exp-3's plane) ############"
cell fabric 1  tcp_fab_n1_a
cell fabric 16 tcp_fab_n16_a
cell fabric 1  tcp_fab_n1_b
cell fabric 16 tcp_fab_n16_b

F1A=$(med tcp_fab_n1_a);  F16A=$(med tcp_fab_n16_a)
F1B=$(med tcp_fab_n1_b);  F16B=$(med tcp_fab_n16_b)
echo; echo "############ FABRIC READOUT ############"
printf '  fabric    n=1  : %s / %s Mbit\n' "$F1A" "$F1B"
printf '  fabric    n=16 : %s / %s Mbit\n' "$F16A" "$F16B"
python3 - "$F1A" "$F16A" "$F1B" "$F16B" <<'PY'
import sys
a1,a16,b1,b16 = (float(x) for x in sys.argv[1:5])
if min(a1,a16,b1,b16) < 0:
    print("  🔴 a cell failed to measure (-1). Not a low reading -- a missing one.")
    raise SystemExit
r = ((a16/a1)+(b16/b1))/2
print(f"  T(16)/T(1) per arm: {a16/a1:.3f} / {b16/b1:.3f}   mean {r:.3f}")
# PREREG-hardening §B.4, registered before any data.
if r <= 0.5:
    print("  => SAME SHAPE: TCP aggregate collapses too; exp-3's finding is not a UDP artefact.")
elif r >= 0.9:
    print("  => 🔴 UDP-SPECIFIC: no TCP collapse. Exp-3's claim must carry the word 'UDP',")
    print("     and Chen et al. may NOT be cited as corroboration. Unfavourable to us -- report it.")
else:
    print("  => INDETERMINATE (0.5-0.9). Report the interval; do not pick a side.")
PY

echo; echo "=== done $(date -Is) ==="
