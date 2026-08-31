#!/usr/bin/env bash
# §E — fine ladder over the one coarse rung [360, 540), fast build only.
# Design: PREREG-E-fine-ladder-fast-ceiling.md (stamped 8fcea54, zero data).
# [Co-developed with claude code -- Adam]
#
# 🔴 D arms ONLY. No stock arm is re-measured, so this round cannot produce a new R --
# that is the structural answer to the objection that a finer ruler after the fact reads
# as rescue. If you add an A arm here, you have changed what this round is.
#
# Order Dn1 Df1 Dn2 Df2 alternates the P4 program so a drift over the run cannot line up
# with the program under test -- the failure the B round's C-before-D ordering had to be
# argued away with a separate drift control.
set -uo pipefail
ROOT="$HOME/bnslab-B"
FINE="360 380 400 420 440 460 480 500 520 540"

echo "=== §E fine ladder  $(date -Is) ==="
echo "rungs (frozen): $FINE"
echo "guest load: $(awk '{print $1,$2,$3}' /proc/loadavg)   avail: $(awk '/MemAvailable/{printf "%.1f GiB",$2/1048576}' /proc/meminfo)"

for spec in "e_Dn1:ndtwin_switch.json" "e_Df1:firewall.json" \
            "e_Dn2:ndtwin_switch.json" "e_Df2:firewall.json"; do
  label="${spec%%:*}"; json="${spec##*:}"
  echo "───────────────────────────────────────────────────────────"
  if ! RATES="$FINE" "$ROOT/ladder_arm.sh" D "$label" "$json"; then
    echo "🔴🔴 arm $label FAILED -- stopping the round."
    exit 1
  fi
done

echo ""
echo "=== §E summary  $(date -Is) ==="
printf '  %-8s %-10s %-12s %-24s %s\n' arm highest_M program stop_reason gate_M
for spec in "e_Dn1:ndtwin" "e_Df1:firewall" "e_Dn2:ndtwin" "e_Df2:firewall"; do
  label="${spec%%:*}"; prog="${spec##*:}"; m="$ROOT/raw/$label/arm.meta"
  [ -f "$m" ] || { printf '  %-8s (no record)\n' "$label"; continue; }
  printf '  %-8s %-10s %-12s %-24s %s\n' "$label" \
    "$(sed -n 's/^highest_clean_rung_mbit=//p' "$m")" "$prog" \
    "$(sed -n 's/^ladder_stop_reason=//p' "$m")" \
    "$(sed -n 's/^sender_gate_mbit=//p' "$m")"
done

echo ""
echo "--- registered readout: are the two programs STRICTLY separated? ---"
python3 - "$ROOT" <<'PY'
import os, sys
root = sys.argv[1]
def rd(l):
    p = os.path.join(root, "raw", l, "arm.meta")
    if not os.path.exists(p): return None
    for ln in open(p):
        if ln.startswith("highest_clean_rung_mbit="):
            v = ln.strip().split("=",1)[1]
            return None if v == "NONE" else int(v)
    return None
n = [rd("e_Dn1"), rd("e_Dn2")]; f = [rd("e_Df1"), rd("e_Df2")]
print(f"    ndtwin  {n}")
print(f"    firewall {f}")
if any(v is None for v in n + f):
    print("    ⇒ INCONCLUSIVE: an arm produced no reading."); raise SystemExit
if min(n) > max(f) or min(f) > max(n):
    print("    🔴 STRICTLY SEPARATED ⇒ the fast build IS still program-sensitive at 20 Mbit")
    print("       resolution. Section C's mechanism claim is refuted and must be rewritten.")
else:
    print("    ⇒ NOT strictly separated: at 20 Mbit resolution the two programs' fast arms")
    print("      coincide. Section C's claim survives AT THIS RESOLUTION.")
    print("      🔑 Still not 'the bottleneck is I/O' -- that needs an experiment that")
    print("         changes the I/O path without changing the program. Nobody has run one.")
PY
echo "=== done ==="
