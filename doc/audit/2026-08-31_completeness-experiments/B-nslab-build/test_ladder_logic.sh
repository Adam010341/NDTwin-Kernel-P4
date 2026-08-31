#!/usr/bin/env bash
# Mutation-gated self-test for the ladder loop in ladder_arm.sh.  Runs in the guest.
# [Co-developed with claude code -- Adam]
#
# 🔴 It drives THE REAL SCRIPT through LADDER_STUB, not a re-implementation.  PREREG-1b
# records that the original ladder was "verified in isolation against a stub before any
# arm ran"; the extension rule here is new code and decides where every arm stops, so it
# gets the same treatment.
#
# 🔑 Case 0 is the force-red control.  A suite where every case passes tells you nothing
# unless you have also seen it fail for the right reason.
set -uo pipefail
ROOT="$HOME/bnslab-B"
T="$ROOT/raw/stub"; mkdir -p "$T"
pass=0; fail=0
ck() {  # ck <name> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ✅ %-52s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  🔴 %-52s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
run() {  # run <label> <stubfile> [env...] -> echoes "highest|stop|rungs"
  local label="$1" stub="$2"; shift 2
  env "$@" LADDER_STUB="$stub" bash "$ROOT/ladder_arm.sh" D "$label" >"$T/$label.log" 2>&1
  local m="$ROOT/raw/$label/arm.meta"
  printf '%s|%s|%s' \
    "$(sed -n 's/^highest_clean_rung_mbit=//p' "$m" 2>/dev/null)" \
    "$(sed -n 's/^ladder_stop_reason=//p' "$m" 2>/dev/null)" \
    "$(sed -n 's/^ladder_rungs_walked=//p' "$m" 2>/dev/null)"
}

echo "=== ladder logic self-test  $(date -Is) ==="

echo ""
echo "--- next_rung: ×1.5 to two significant figures (the registered extension) ---"
nr() { awk -v p="$1" 'BEGIN{v=p*1.5; e=int(log(v)/log(10)); s=10^(e-1); printf "%d\n", int(v/s+0.5)*s}'; }
ck "360 -> 540"   540   "$(nr 360)"
ck "540 -> 810"   810   "$(nr 540)"
ck "810 -> 1200"  1200  "$(nr 810)"
ck "1200 -> 1800" 1800  "$(nr 1200)"
ck "1800 -> 2700" 2700  "$(nr 1800)"

echo ""
echo "--- case 1: climbs PAST the registered top, stops on two consecutive dirty rungs ---"
printf '1200 40.0\n1800 55.0\n' > "$T/s1.txt"
IFS='|' read -r h s n <<<"$(run stub_extend "$T/s1.txt")"
ck "highest clean rung"        810          "$h"
ck "stop reason"               saturation   "$s"
ck "rungs walked (14 base + 540,810,1200,1800)" 18 "$n"

echo ""
echo "--- case 0 (FORCE-RED CONTROL): with an override list the climb must NOT extend ---"
echo "    If this reports 810 too, the suite cannot tell extension from no extension."
IFS='|' read -r h s n <<<"$(run stub_noextend "$T/s1.txt" RATES="1 2 3 5 8 12 20 30 45 70 110 160 240 360")"
ck "highest clean rung (must be 360, NOT 810)" 360 "$h"
ck "stop reason"    override_list_exhausted "$s"
ck "rungs walked"   14                      "$n"

echo ""
echo "--- case 2: a single dirty rung does NOT stop the climb (must be CONSECUTIVE) ---"
printf '45 40.0\n110 40.0\n1200 40.0\n1800 40.0\n' > "$T/s2.txt"
IFS='|' read -r h s n <<<"$(run stub_nonconsec "$T/s2.txt")"
ck "highest clean rung"  810        "$h"
ck "stop reason"         saturation "$s"

echo ""
echo "--- case 3: the sender gate ends the climb, and does so BEFORE spending a rung ---"
printf '' > "$T/s3.txt"
IFS='|' read -r h s n <<<"$(run stub_gate "$T/s3.txt" STUB_G=1000)"
ck "highest clean rung (G=1000 => rungs >200 are sender-limited)" 160 "$h"
ck "stop reason"  sender_limited_at_240 "$s"

echo ""
echo "--- case 4: the clean rule is <=0.5%, not <25% ---"
printf '70 0.6000\n110 0.6000\n1200 40.0\n1800 40.0\n' > "$T/s4.txt"
IFS='|' read -r h s n <<<"$(run stub_clean "$T/s4.txt")"
ck "highest clean rung (70 and 110 are dirty at 0.6%)" 810 "$h"

echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
