#!/usr/bin/env bash
# Driver for the OvS flow-count control. Design = PREREG.md (read it first).
# Phases: patch shaping out -> boot OVS/64 -> sender gates -> 6 unshaped arms (mirrored) ->
# restore shaping -> reboot -> shaped n16 positive control -> restore host_count -> summary.
# ndt down/up kill their calling shell (exit 144) => every call wrapped in setsid; success is
# verified on state (bridges, host namespaces), never on rc. [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
RAW="$HERE/raw"; mkdir -p "$RAW"
export NDT_OWNER="${NDT_OWNER:-8/29 poster-reviewer}"

TOPO="$REPO/testbed_topo.py"
HCO="$REPO/p4_proxy/mininet/host_count_override"
BASE_RATES="1 2 3 5 8 12 20 30 45 70 110 160 240 360 540 810 1215"

die() { echo "🔴 ABORT: $*"; exit 1; }

# ---------- claim guard (the whole driver refuses to start unless we hold the lab)
owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ "$owner" == "$NDT_OWNER" ]] || die "lab.claim owner='$owner' != '$NDT_OWNER' — claim first"

# ---------- record originals (restored in phase 4; also on any abort via trap)
cp "$TOPO" "$RAW/testbed_topo.py.orig"
cp "$HCO" "$RAW/host_count_override.orig" 2>/dev/null || echo "128" > "$RAW/host_count_override.orig"
sha_orig="$(sha256sum "$TOPO" | cut -c1-16)"
restore_all() {
  cp "$RAW/testbed_topo.py.orig" "$TOPO"
  cp "$RAW/host_count_override.orig" "$HCO" 2>/dev/null || true
}
trap restore_all EXIT

boot_ovs() {  # $1 = tag
  setsid bash -c "NDT_OWNER='$NDT_OWNER' ndt down"    > "$RAW/ndt_down_$1.log" 2>&1 || true
  sleep 3
  setsid bash -c "NDT_OWNER='$NDT_OWNER' ndt up ovs" > "$RAW/ndt_up_$1.log"   2>&1 || true
  local i br h1p h33p
  for i in $(seq 1 36); do
    br=$(sudo -n ovs-vsctl list-br 2>/dev/null | wc -l)
    h1p=$(ps -eo args | awk '$NF=="mininet:h1"'  | wc -l)
    h33p=$(ps -eo args | awk '$NF=="mininet:h65"' | wc -l)
    [[ "$br" -ge 10 && "$h1p" -ge 1 && "$h33p" -ge 1 ]] && { echo "  boot[$1] ok: $br bridges, h1+h33 present (waited $((i*5))s)"; return 0; }
    sleep 5
  done
  die "boot[$1]: bridges=$br h1=$h1p h33=$h33p after 180s (see $RAW/ndt_up_$1.log)"
}

hpid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }

warm_path() {  # reactive control plane: warm h1<->h33 before any measurement
  local cp; cp=$(hpid h1)
  sudo -n mnexec -a "$cp" ping -c 3 -W 2 10.0.0.33 > "$RAW/warm_$1.txt" 2>&1 || true
  tail -2 "$RAW/warm_$1.txt" | head -1
}

# ---------- Phase 1: patch shaping OUT, boot, verify unshaped
echo "=== PHASE 1: unshaped fabric  $(date '+%F %T') ==="
sed -i 's/, bw=1000//g; s/, bw=10000//g' "$TOPO"
python3 -m py_compile "$TOPO" || die "patched testbed_topo.py does not compile"
diff "$RAW/testbed_topo.py.orig" "$TOPO" > "$RAW/topo_patch.diff" || true
echo "  patch: $(grep -c '^[<>]' "$RAW/topo_patch.diff") diff lines; sha $(sha256sum "$TOPO" | cut -c1-16) (orig $sha_orig)"
boot_ovs unshaped
warm_path unshaped
# unshaped assertion: no htb qdisc on switch interfaces
htb=$(sudo -n tc -s qdisc show 2>/dev/null | grep -c "htb" || true)
echo "  htb qdisc count on fabric: $htb (expect 0 on unshaped)" | tee "$RAW/htb_unshaped.txt"
[[ "$htb" -eq 0 ]] || die "unshaped fabric still shows $htb htb qdiscs — patch did not take effect"

# ---------- Phase 2: sender-side gates (loopback inside h1, not through OvS)  PREREG §3
echo "=== PHASE 2: sender gates ==="
CP=$(hpid h1)
gate_one() {  # $1 = n; prints agg sent Mbit median of 3
  local n="$1" rep r base port vals=()
  for rep in 1 2 3; do
    base=$((7001 + rep * 100))
    for ((r=0; r<n; r++)); do
      sudo -n mnexec -a "$CP" iperf3 -s -1 --daemon -p $((base+r)) >/dev/null 2>&1
    done
    sleep 1
    for ((r=0; r<n; r++)); do
      sudo -n mnexec -a "$CP" iperf3 -c 127.0.0.1 -p $((base+r)) -u -b 0 -t 5 -l 1400 --json \
        > "$RAW/gate_n${n}_rep${rep}_f${r}.json" 2>&1 &
    done
    wait
    vals+=("$(python3 - "$n" "$RAW" "$n" "$rep" <<'PY'
import json,sys,os
n,raw,_,rep=int(sys.argv[1]),sys.argv[2],sys.argv[3],sys.argv[4]
t=0.0
for r in range(n):
    try: t+=json.load(open(os.path.join(raw,f"gate_n{n}_rep{rep}_f{r}.json")))["end"]["sum_sent"]["bits_per_second"]/1e6
    except Exception: pass
print(f"{t:.0f}")
PY
)")
  done
  printf '%s\n' "${vals[@]}" | sort -g | sed -n 2p
}
: > "$RAW/gates.tsv"
for n in 1 4 16; do
  g=$(gate_one "$n")
  echo -e "${n}\t${g}" >> "$RAW/gates.tsv"
  echo "  gate n=$n : loopback agg ${g} Mbit  => per-flow cap $(awk "BEGIN{printf \"%.0f\", $g/5/$n}") Mbit"
done

rates_for() {  # $1 = n → gate-capped ladder
  local n="$1" g cap out="" r
  g=$(awk -v n="$n" '$1==n{print $2}' "$RAW/gates.tsv")
  [[ -n "$g" && "$g" != "0" ]] || die "gate for n=$n missing/zero — PREREG abandon criterion"
  cap=$(awk "BEGIN{printf \"%.4f\", $g/5/$n}")
  for r in $BASE_RATES; do awk -v r="$r" -v c="$cap" 'BEGIN{exit !(r<=c)}' && out="$out $r"; done
  [[ -n "$out" ]] || die "gate cap $cap below lowest rung for n=$n"
  echo "$out"
}

# ---------- Phase 3: six unshaped arms, interleaved mirrored  PREREG §2
echo "=== PHASE 3: arms ==="
for spec in "1 ovs_n1_a" "4 ovs_n4_a" "16 ovs_n16_a" "16 ovs_n16_b" "4 ovs_n4_b" "1 ovs_n1_b"; do
  set -- $spec
  RATES="$(rates_for "$1")" "$HERE/run_ovs_arm.sh" "$1" "$2" || echo "🔴 arm $2 failed rc=$? — continuing (its raw says why)"
done

# ---------- Phase 4: restore shaping, reboot, shaped n16 positive control  PREREG §2 last block
echo "=== PHASE 4: shaped positive control ==="
cp "$RAW/testbed_topo.py.orig" "$TOPO"
[[ "$(sha256sum "$TOPO" | cut -c1-16)" == "$sha_orig" ]] || die "topo restore not byte-exact"
boot_ovs shaped
warm_path shaped
htb2=$(sudo -n tc -s qdisc show 2>/dev/null | grep -c "htb" || true)
echo "  htb qdisc count on fabric: $htb2 (expect >0 on shaped)" | tee "$RAW/htb_shaped.txt"
RATES="1 2 3 5 8 12 20 30 45 70 110 160" "$HERE/run_ovs_arm.sh" 16 ovs_n16_shaped || \
  echo "🔴 shaped arm failed rc=$? — its raw says why"

# ---------- Phase 5: restore host count + summary (topo already restored)
cp "$RAW/host_count_override.orig" "$HCO"
echo "=== SUMMARY  $(date '+%F %T') ==="
printf '%-16s %-4s %-14s %-12s %s\n' arm n clean_perflow aggregate top_offered
for m in "$RAW"/ovs_*/arm.meta; do
  a=$(sed -n 's/^arm=//p' "$m"); n=$(sed -n 's/^n_flows=//p' "$m")
  c=$(sed -n 's/^highest_clean_per_flow_mbit=//p' "$m"); g=$(sed -n 's/^aggregate_clean_mbit=//p' "$m")
  t=$(sed -n 's/^ladder_top_offered=\([0-9]*\).*/\1/p' "$m")
  printf '%-16s %-4s %-14s %-12s %s\n' "$a" "$n" "$c" "$g" "$t"
done
echo "=== DRIVER DONE (topo sha now $(sha256sum "$TOPO" | cut -c1-16); host_count restored to $(cat "$HCO" 2>/dev/null)) ==="
