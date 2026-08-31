#!/usr/bin/env bash
# PREREG-B — ONE arm of the eight-arm ladder.  Runs INSIDE the nslab guest.
# Design: PREREG-B-nslab-build.md §2 (arms, F1/F2/F3) and §3 (ladder, clean rule,
# sender gate).  Ladder + clean rule + 3-rep median + saturation stop are taken verbatim
# from the study's run_flowcount_arm.sh so the two rounds stay comparable.
# [Co-developed with claude code -- Adam]
#
# Usage: ./ladder_arm.sh <arm A|B|C|D> <label> [p4_json_basename]
#
# What this file is responsible for that the study's runner is not:
#   F1/F2  the switch that is RUNNING must be the arm's build, asserted from
#          /proc/<pid>/exe at the START and again at the END of the arm.  Recording the
#          build artefact's sha256 alone cannot falsify "all eight arms ran one binary":
#          every identity record would still read correctly.
#   F3     at least one rule must be PROGRAMMED and visible on a SOUTHBOND direct read.
#          Here that is `table_dump` over thrift -- the switch's own view, not a cache.
#          "the control plane process exists" is not this assertion.
set -uo pipefail

ARM="${1:?usage: ladder_arm.sh <A|B|C|D> <label> [p4_json]}"
LABEL="${2:?arm label, e.g. b_A1}"
P4JSON="${3:-ndtwin_switch.json}"
ROOT="$HOME/bnslab-B"
OUT="$ROOT/raw/$LABEL"; mkdir -p "$OUT"

STEP_S="${STEP_S:-8}"
CLEAN_PCT="${CLEAN_PCT:-0.5}"
AMB_HI="${AMB_HI:-2.0}"
RATES="${RATES:-1 2 3 5 8 12 20 30 45 70 110 160 240 360}"
SAT_STOP_PCT="${SAT_STOP_PCT:-25}"
RUNAWAY_MAX="${RUNAWAY_MAX:-40}"
LEN=1400                        # PREREG-B §3 working point: 1400 B payload = 1442 B frame

die() { echo "🔴 ABORT[$LABEL]: $*" | tee -a "$OUT/abort.txt"; teardown; exit 1; }

BIN=$(sed -n 's/^binary=//p' "$ROOT/identity_${ARM}.meta")
[ -n "$BIN" ] && [ -f "$BIN" ] || { echo "🔴 arm $ARM has no binary in its identity record"; exit 1; }
WANT_SHA=$(sha256sum "$BIN" | cut -d' ' -f1)

teardown() {
  touch "$ROOT/STOP" 2>/dev/null || true
  local i
  for i in $(seq 1 30); do [ -f "$ROOT/READY" ] || break; sleep 1; done
  sudo -n mn -c >/dev/null 2>&1 || true
  rm -f "$ROOT/STOP"
}

# ---------------------------------------------------------------- bring the fabric up
echo "### PREREG-B arm $ARM label=$LABEL json=$P4JSON  $(date -Is)"
printf '%s\n' "$BIN" > "$ROOT/bmv2_binary_override"
rm -f "$ROOT/READY" "$ROOT/STOP"
sudo -n mn -c >/dev/null 2>&1 || true

BNSLAB_NONINTERACTIVE=1 BNSLAB_P4_JSON="$P4JSON" \
  setsid sudo -n -E python3 "$ROOT/bnslab_topo.py" > "$OUT/topo.log" 2>&1 &
for i in $(seq 1 60); do [ -f "$ROOT/READY" ] && break; sleep 2; done
[ -f "$ROOT/READY" ] || die "fabric did not become READY in 120 s -- see $OUT/topo.log"
cp "$ROOT/READY" "$OUT/ready.txt"
# 🔴 bmv2=, not node_s1=. The node pid's /proc/<pid>/exe is /usr/bin/bash -- see the
# comment in bnslab_topo.py. Reading the wrong pid here would make F1/F2 assert against
# the shell, which can only ever fail; reading argv instead would make it always pass.
SWPID=$(sed -n 's/^bmv2=//p' "$ROOT/READY")
H1=$(sed -n 's/^h1=//p' "$ROOT/READY")
H2=$(sed -n 's/^h2=//p' "$ROOT/READY")
[ -n "$SWPID" ] || die "READY has no bmv2= line -- topology did not identify the switch process"
echo "  fabric ready: bmv2=$SWPID (node shell $(sed -n 's/^node_s1=//p' "$ROOT/READY")) h1=$H1 h2=$H2"

# ---------------------------------------------------------------- F1/F2 assertion, entry
assert_running_binary() {  # $1 = "entry" | "exit"
  local exe live
  exe=$(sudo -n readlink -f "/proc/$SWPID/exe" 2>/dev/null) \
    || die "F1/F2 $1: cannot read /proc/$SWPID/exe -- identity unverifiable, not assumed"
  [ -n "$exe" ] || die "F1/F2 $1: /proc/$SWPID/exe empty"
  live=$(sudo -n sha256sum "$exe" | cut -d' ' -f1)
  echo "  F1/F2 $1: pid=$SWPID exe=$exe sha=${live:0:16} (want ${WANT_SHA:0:16})"
  echo "f1f2_$1=$live exe=$exe pid=$SWPID" >> "$OUT/arm.meta"
  [ "$live" = "$WANT_SHA" ] || die "F1/F2 $1: RUNNING BINARY IS NOT ARM $ARM's BUILD"
}
: > "$OUT/arm.meta"
assert_running_binary entry

# ---------------------------------------------------------------- program rules + F3
cli() { sudo -n simple_switch_CLI --thrift-port 9090 2>/dev/null; }
{
  echo "table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.0.1/32 => 00:00:00:00:00:01 1"
  echo "table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.0.2/32 => 00:00:00:00:00:02 2"
} | cli > "$OUT/table_add.txt" 2>&1

# F3: SOUTHBOUND DIRECT READ. The switch's own table, over thrift. Not a northbound view.
echo "table_dump MyIngress.ipv4_lpm" | cli > "$OUT/table_dump.txt" 2>&1
ENTRIES=$(grep -c '^\s*Dumping entry\|^Dumping entry' "$OUT/table_dump.txt" || true)
echo "  F3: ipv4_lpm entries visible on southbound direct read: $ENTRIES"
echo "f3_entries=$ENTRIES" >> "$OUT/arm.meta"
[ "$ENTRIES" -ge 2 ] || die "F3: only $ENTRIES entries visible -- the control plane is not
    functionally alive. (existence-is-not-wiring: a live process is not a programmed rule.)"

# and prove the programmed rule actually forwards -- a rule in a table that does not move
# a packet is the same failure one layer up.
PING=$(sudo -n mnexec -a "$H1" ping -c 3 -W 2 10.0.0.2 2>&1 | tail -2 | head -1)
echo "  F3 forwarding check: $PING"
echo "f3_ping=$PING" >> "$OUT/arm.meta"
case "$PING" in *" 0% packet loss"*) : ;; *) die "F3: rule is in the table but does not forward -- $PING" ;; esac

# ---------------------------------------------------------------- sender gate  PREREG-B §3
# G = direct sender->sink ceiling INSIDE the VM, loopback, NOT through bmv2.
# Registered rule: any rung X with G < 5*X is sender-limited and does not enter the
# clean judgement. The formula was frozen in v1.0; only the constant is measured here.
GPORT=5999
sudo -n mnexec -a "$H1" iperf3 -s -1 --daemon -p $GPORT >/dev/null 2>&1
sleep 1
sudo -n mnexec -a "$H1" iperf3 -c 127.0.0.1 -p $GPORT -u -b 0 -t 5 -l $LEN --json \
  > "$OUT/gate.json" 2>&1
G=$(python3 -c "
import json
try:
    d=json.load(open('$OUT/gate.json'))
    print('%.0f' % (d['end']['sum']['bits_per_second']/1e6))
except Exception as e:
    print('-1')
")
echo "  sender gate G = $G Mbit  (rungs above $(python3 -c "print(f'{max(0,int($G)//5)}')") Mbit are sender-limited)"
echo "sender_gate_mbit=$G" >> "$OUT/arm.meta"
[ "$G" != "-1" ] || die "sender gate produced no measurement -- PREREG-B abandon criterion"

# ---------------------------------------------------------------- the ladder
run_rep() {  # $1=rate $2=rep -> "<loss> <sent> <recv>"; -1 sentinel for no measurement
  local rate="$1" rep="$2" port=$((5201 + RANDOM % 2000))
  sudo -n mnexec -a "$H2" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
  sleep 1
  sudo -n mnexec -a "$H1" iperf3 -c 10.0.0.2 -p "$port" -u -b "${rate}M" \
    -t "$STEP_S" -l $LEN --json > "$OUT/r${rate}M_rep${rep}.json" 2>&1
  python3 - "$OUT" "$rate" "$rep" <<'PY'
import json, os, sys
out, rate, rep = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    e = json.load(open(os.path.join(out, f"r{rate}M_rep{rep}.json")))["end"]
    # NOT end.sum: for UDP that object is the SENDER's rate with the RECEIVER's loss
    # merged in, a hybrid whose name looks like the answer.
    s, r = e["sum_sent"], e["sum_received"]
    print(f"{float(r.get('lost_percent', 0.0)):.4f} {s['bits_per_second']/1e6:.2f} {r['bits_per_second']/1e6:.2f}")
except Exception:
    print("-1 -1 -1")
PY
}
median3() { printf '%s\n' "$1" "$2" "$3" | sort -g | sed -n 2p; }

printf 'rate_mbit\treps\tloss_scored\tloss_reps\tsent\trecv\tclean\tsender_limited\n' > "$OUT/ladder.tsv"
best_clean=""; hot=0; n_rungs=0
for r in $RATES; do
  n_rungs=$((n_rungs+1))
  [ "$n_rungs" -le "$RUNAWAY_MAX" ] || { echo "  🔴 RUNAWAY_MAX hit -- this arm's reading is NOT a saturation reading"; echo "runaway=yes" >> "$OUT/arm.meta"; break; }

  # sender gate, applied BEFORE spending 8 s on the rung
  slim=no
  awk -v g="$G" -v x="$r" 'BEGIN{exit !(g < 5*x)}' && slim=yes

  read -r l1 s1 v1 <<<"$(run_rep "$r" 1)"
  scored="$l1"; reps=1; all="$l1"
  if [ "$l1" != "-1" ] && awk -v a="$l1" -v hi="$AMB_HI" 'BEGIN{exit !(a > 0 && a <= hi)}'; then
    read -r l2 s2 v2 <<<"$(run_rep "$r" 2)"
    read -r l3 s3 v3 <<<"$(run_rep "$r" 3)"
    if [ "$l2" = "-1" ] || [ "$l3" = "-1" ]; then scored="-1"; all="$l1,$l2,$l3"
    else
      scored="$(median3 "$l1" "$l2" "$l3")"; all="$l1,$l2,$l3"
      s1=$(awk -v a="$s1" -v b="$s2" -v c="$s3" 'BEGIN{printf "%.2f",(a+b+c)/3}')
      v1=$(awk -v a="$v1" -v b="$v2" -v c="$v3" 'BEGIN{printf "%.2f",(a+b+c)/3}')
    fi
    reps=3
  fi

  clean=no
  if [ "$scored" = "-1" ]; then clean=NO_MEASUREMENT
  elif [ "$slim" = "yes" ]; then clean=SENDER_LIMITED
  elif awk -v a="$scored" -v c="$CLEAN_PCT" 'BEGIN{exit !(a <= c)}'; then clean=yes; best_clean="$r"; fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$reps" "$scored" "$all" "$s1" "$v1" "$clean" "$slim" >> "$OUT/ladder.tsv"
  printf '  %5s M  reps %s  loss %8s%%  sent %8s  recv %8s  clean=%s%s\n' \
    "$r" "$reps" "$scored" "$s1" "$v1" "$clean" "$([ "$slim" = yes ] && echo ' [sender-limited]')"

  # saturation stop: two CONSECUTIVE rungs above 25%
  if [ "$scored" != "-1" ] && awk -v a="$scored" -v p="$SAT_STOP_PCT" 'BEGIN{exit !(a > p)}'; then
    hot=$((hot+1)); [ "$hot" -ge 2 ] && { echo "  saturation stop: two consecutive rungs > ${SAT_STOP_PCT}%"; break; }
  else hot=0; fi
done

# ---------------------------------------------------------------- F1/F2 assertion, exit
assert_running_binary exit

{
  echo "arm=$ARM"
  echo "label=$LABEL"
  echo "p4_json=$P4JSON"
  echo "binary=$BIN"
  echo "binary_sha256=$WANT_SHA"
  echo "highest_clean_rung_mbit=${best_clean:-NONE}"
  echo "ladder_rungs_walked=$n_rungs"
  echo "step_s=$STEP_S clean_pct=$CLEAN_PCT payload=$LEN"
  echo "finished=$(date -Is)"
  echo "guest_loadavg_at_end=$(awk '{print $1,$2,$3}' /proc/loadavg)"
} >> "$OUT/arm.meta"

echo "  ⇒ arm $LABEL highest clean rung = ${best_clean:-NONE} Mbit"
teardown
echo "### arm $LABEL done  $(date -Is)"
