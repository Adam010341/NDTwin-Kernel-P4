#!/usr/bin/env bash
# PREREG-B — the eight arms, in the frozen interleaved order.  Runs inside the guest.
# [Co-developed with claude code -- Adam]
#
# Order is A1 B1 C1 D1 A2 B2 C2 D2 (PREREG-B §2, frozen before any build existed).  It is
# interleaved rather than blocked so that a host-side drift over the run cannot be read as
# a between-arm difference: every arm's two replicates sit at opposite ends of the window.
#
# Each arm restarts the whole fabric.  Builds swap, and a switch that outlived its arm
# would make the next arm's numbers belong to two binaries.
#
# 🔴 This script does NOT decide anything.  It runs arms and stops on the first F1/F2/F3
# failure -- "carry on and sort it out later" is how an arm with an unverifiable binary
# ends up in a table.
set -uo pipefail
ROOT="$HOME/bnslab-B"
P4JSON="${P4JSON:-ndtwin_switch.json}"
SUITE="${SUITE:-b}"                     # b = the main round; c = the §C P4-program contrast
ARMS="${ARMS:-A:1 B:1 C:1 D:1 A:2 B:2 C:2 D:2}"

echo "=== PREREG-B eight arms  suite=$SUITE  json=$P4JSON  $(date -Is) ==="
echo "guest: $(hostname)  nproc=$(nproc)  load=$(awk '{print $1,$2,$3}' /proc/loadavg)"
echo "order (frozen): $ARMS"
echo ""

# Host quiet-check. The measurement is CPU-bound and shares memory bandwidth with anything
# else on the hypervisor; we cannot see the host from in here, so record what we CAN see
# and let the ledger carry the rest.
echo "guest MemAvailable: $(awk '/MemAvailable/{printf "%.1f GiB",$2/1048576}' /proc/meminfo)"
echo ""

t0=$(date +%s)
for spec in $ARMS; do
  arm="${spec%%:*}"; rep="${spec##*:}"
  label="${SUITE}_${arm}${rep}"
  echo "───────────────────────────────────────────────────────────"
  if ! "$ROOT/ladder_arm.sh" "$arm" "$label" "$P4JSON"; then
    echo "🔴🔴 arm $label FAILED. Stopping the round -- an arm whose binary or control"
    echo "     plane could not be verified must not be followed by more arms that share"
    echo "     its fabric assumptions."
    exit 1
  fi
done
t1=$(date +%s)

echo ""
echo "=== summary  $(date -Is)  (wall clock $(( (t1-t0)/60 ))m$(( (t1-t0)%60 ))s) ==="
printf '  %-8s %-10s %-16s %-24s %s\n' arm highest_M stop_reason binary_sha16 gate_M
for spec in $ARMS; do
  arm="${spec%%:*}"; rep="${spec##*:}"; m="$ROOT/raw/${SUITE}_${arm}${rep}/arm.meta"
  [ -f "$m" ] || { printf '  %-8s (no record)\n' "${SUITE}_${arm}${rep}"; continue; }
  printf '  %-8s %-10s %-16s %-24s %s\n' \
    "${SUITE}_${arm}${rep}" \
    "$(sed -n 's/^highest_clean_rung_mbit=//p' "$m")" \
    "$(sed -n 's/^ladder_stop_reason=//p' "$m")" \
    "$(sed -n 's/^binary_sha256=//p' "$m" | cut -c1-16)" \
    "$(sed -n 's/^sender_gate_mbit=//p' "$m")"
done
echo ""
echo "🔑 Eight arms, four binaries: the sha column must show exactly four distinct values,"
echo "   each appearing twice. Identical shas across arms would mean one binary ran"
echo "   throughout and every other identity record would still read correctly."
for spec in $ARMS; do arm="${spec%%:*}"; rep="${spec##*:}"
  sed -n 's/^binary_sha256=//p' "$ROOT/raw/${SUITE}_${arm}${rep}/arm.meta" 2>/dev/null
done | sort | uniq -c | sed 's/^/   /'
echo "=== done ==="
