#!/usr/bin/env bash
# §B (P-2) — the TCP control for ③, on ③'s own bmv2 plane.
# Design: PREREG-hardening-three-small-rounds.md §B, PLUS the amendment recorded in
# AMENDMENT-loopback-control.md in this directory.  Read both before reading this file.
# [Co-developed with claude code -- Adam]
#
# 🔴 WHAT THE AMENDMENT ADDS, AND WHY IT IS NOT OPTIONAL.
# §B reads T(16)/T(1).  A collapse in that ratio is meant to say something about the SWITCH.
# But sixteen concurrent TCP connections on one host collapse for reasons that have nothing
# to do with any switch: sender-side scheduling, receiver socket pressure, cwnd interaction.
# §A died today because the sender's own signature was numerically identical to the
# hypothesis under test (R_gate = 0.970, inside H1's registered interval).  The same class of
# error is available here, so the same class of guard goes in FIRST:
#
#   CONTROL: run the identical n=1 / n=16 comparison over h1's LOOPBACK, no switch in path.
#   Registered reading, written before any data:
#     * loopback T(16)/T(1) >= 0.9  -> the host does not collapse on its own; a collapse
#                                      measured through the fabric is attributable to it.
#     * loopback T(16)/T(1) <= 0.5  -> 🔴 the HOST collapses without any switch. §B cannot
#                                      attribute a fabric collapse. Report as uninterpretable.
#     * in between                  -> the control is itself ambiguous; report the fabric
#                                      number ONLY alongside the control number, never alone.
#
# 🔑 The control runs FIRST and its result is printed before any fabric cell, so that the
# order of the transcript matches the order of the reasoning.  A control run afterwards is
# a control you can decide not to look at.
#
# Usage: NDT_OWNER="..." ./run_tcp_cell.sh <mode: loopback|fabric> <n> <label>
set -uo pipefail

MODE="${1:?usage: run_tcp_cell.sh <loopback|fabric> <n> <label>}"
N="${2:?flow count}"
LABEL="${3:?arm label, e.g. tcp_fab_n16_a}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="$HERE/raw/$LABEL"; mkdir -p "$OUT"

DUR="${DUR:-10}"
REPS="${REPS:-3}"
C=h1; S=h65
SIP="10.0.0.65"

# ---------------------------------------------------------------- claim (same guard as ③)
owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ -n "${NDT_OWNER:-}" ]] || { echo "🔴 NDT_OWNER unset"; exit 1; }
[[ "$owner" == "$NDT_OWNER" ]] || { echo "🔴 lab.claim owner='$owner' != NDT_OWNER='$NDT_OWNER'"; exit 1; }

host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
CP=$(host_pid "$C"); SP=$(host_pid "$S")
[[ -n "$CP" ]] || { echo "🔴 h1 namespace missing"; exit 1; }
if [[ "$MODE" == fabric ]]; then
  [[ -n "$SP" ]] || { echo "🔴 h65 namespace missing"; exit 1; }
  TARGET="$SIP"; SRV_NS="$SP"
else
  TARGET="127.0.0.1"; SRV_NS="$CP"      # server and client both inside h1: no switch in path
fi

# ---------------------------------------------------------------- provenance, recorded not assumed
# benchmark-must-name-the-binary-it-measured: the switch binary is named from /proc, not argv.
{
  echo "label=$LABEL"
  echo "mode=$MODE"
  echo "n_flows=$N"
  echo "duration_s=$DUR"
  echo "reps=$REPS"
  echo "host_pair=${C}->${S} ($TARGET)"
  echo "started=$(date -Is)"
  echo "loadavg_at_start=$(awk '{print $1,$2,$3}' /proc/loadavg)"
  for swpid in $(ps -eo pid,comm | awk '$2 ~ /^simple_switch/{print $1}'); do
    echo "switch_pid=$swpid exe=$(readlink -f /proc/$swpid/exe 2>/dev/null || echo UNREADABLE)"
    echo "switch_sha256=$(sha256sum "$(readlink -f /proc/$swpid/exe 2>/dev/null)" 2>/dev/null | cut -d' ' -f1)"
    break
  done
  echo "bmv2_binary_override=$(sed -n '/^[^#]/p' "$REPO/p4_proxy/mininet/bmv2_binary_override" 2>/dev/null | head -1)"
} > "$OUT/cell.meta"

# ---------------------------------------------------------------- the cell
run_rep() {  # $1 = rep index; prints aggregate goodput Mbit, or -1 for no measurement
  local rep="$1" base=$((6100 + rep * 100)) i
  for ((i=0; i<N; i++)); do
    sudo -n mnexec -a "$SRV_NS" iperf3 -s -1 --daemon -p $((base+i)) >/dev/null 2>&1
  done
  sleep 1
  for ((i=0; i<N; i++)); do
    sudo -n mnexec -a "$CP" iperf3 -c "$TARGET" -p $((base+i)) -t "$DUR" --json \
      > "$OUT/r${rep}_f${i}.json" 2>&1 &
  done
  wait
  python3 - "$OUT" "$rep" "$N" <<'PY'
import json, os, sys
out, rep, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
tot, ok = 0.0, 0
for i in range(n):
    p = os.path.join(out, f"r{rep}_f{i}.json")
    try:
        d = json.load(open(p))
        # TCP goodput = RECEIVER's bits_per_second. sum_sent counts bytes handed to the
        # socket, which on a lossy path is not what arrived. Same rule as the UDP rounds.
        tot += d["end"]["sum_received"]["bits_per_second"] / 1e6
        ok += 1
    except Exception:
        pass
# A partially-failed cell must not masquerade as a low reading.
print(f"{tot:.1f}" if ok == n else "-1")
PY
}

vals=()
for rep in $(seq 1 "$REPS"); do
  v=$(run_rep "$rep")
  vals+=("$v")
  echo "  $LABEL rep$rep: $v Mbit"
done
med=$(printf '%s\n' "${vals[@]}" | sort -g | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
echo "aggregate_goodput_mbit_median=$med" >> "$OUT/cell.meta"
echo "reps_raw=${vals[*]}"                >> "$OUT/cell.meta"
echo "finished=$(date -Is)"               >> "$OUT/cell.meta"
echo "  ⇒ $LABEL median = $med Mbit  (reps: ${vals[*]})"
