#!/usr/bin/env bash
# phase2_ovs_smoke.sh -- full-stack round phase 2: OVS plane end-to-end smoke on a healthy
# boot. Boot until converged (<=4 attempts at the measured 40% success rate), then:
#   1. the 404-transient regression series (10 samples, 12 s apart, expect at most an
#      early 404 then 200s -- P1-3's shape)
#   2. northbound install -> forwarding actually changes -> delete -> reverts (Round-6 gate)
#   3. failover drill: netem an inter-switch link via the sudoers tc form, time the
#      detection at defaults, then heal and confirm reconvergence
# Leaves the fabric UP on success for phase 3 hand-off inspection.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail
export NDT_OWNER=review-0824
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; OUT="$DIR/phase2_ovs_smoke.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

links_n() { curl -sf --max-time 4 "$RYU/v1.0/topology/links" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?"; }

say ""
say "# phase 2: OVS smoke -- $(date +%H:%M:%S)  commit $(git -C /home/adam/Desktop/NDTwin-Kernel rev-parse --short HEAD)"

booted=0
for attempt in 1 2 3 4; do
    ndt down >/dev/null 2>&1; sleep 3
    if timeout 600 ndt up ovs > "$RAW/p2_boot${attempt}_up.out" 2>&1; then
        if grep -q 'up. ready' "$RAW/p2_boot${attempt}_up.out"; then
            say "## boot attempt $attempt: CONVERGED"
            booted=1; break
        fi
    fi
    say "## boot attempt $attempt: failed (expected at ~60%), retrying"
done
[ "$booted" = 1 ] || { say "no healthy boot in 4 attempts -- aborting phase 2"; exit 1; }

say "## 1. get_path_switch_count series (10 samples, 12s apart, first query after boot)"
for i in $(seq 1 10); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$KERNEL/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.2")
    say "   sample $i: HTTP $code"
    [ "$i" -lt 10 ] && sleep 12
done

say "## 2. northbound install -> forwarding changes -> delete -> reverts"
mnexec_h1() { sudo -n mnexec -a "$(pgrep -f 'mininet:h1$' | head -1)" "$@"; }
before=$(mnexec_h1 ping -c 2 -W 1 10.0.0.2 >/dev/null 2>&1 && echo ok || echo FAIL)
say "   baseline h1->h2: $before"
inst=$(curl -s -o "$RAW/p2_install.json" -w '%{http_code}' --max-time 8 -X POST "$KERNEL/ndt/install_flow_entry" \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"table_id":0,"priority":300,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.2"},"actions":[{"type":"OUTPUT","port":3}]}')
say "   install (divert h2 traffic at s1 -> port 3 = h1's own port, a deterministic dead end): HTTP $inst"
sleep 2
after=$(mnexec_h1 ping -c 2 -W 1 10.0.0.2 >/dev/null 2>&1 && echo still-ok || echo diverted)
say "   h1->h2 after divert: $after   (expect diverted -- the rule outranks the route)"
del=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST "$KERNEL/ndt/delete_flow_entry" \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"table_id":0,"priority":300,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.2"}}')
sleep 2
healed=$(mnexec_h1 ping -c 2 -W 1 10.0.0.2 >/dev/null 2>&1 && echo ok || echo STILL-BROKEN)
say "   delete: HTTP $del ; h1->h2 after delete: $healed   (expect ok -- no install-then-delete black hole)"

say "## 3. failover drill at defaults (netem 100% loss on s1-eth2, time link-down detection)"
t0=$(date +%s)
sudo -n /usr/sbin/tc qdisc add dev s1-eth2 root netem loss 100% 2>&1 | head -1
det="none"
for i in $(seq 1 90); do
    sleep 1
    n=$(links_n)
    if [ "$n" != "?" ] && [ "$n" -lt 32 ] 2>/dev/null; then det=$(( $(date +%s) - t0 )); break; fi
done
say "   link-down detected after: ${det}s (links now $(links_n); idle-defaults expectation ~45-50s)"
sudo -n /usr/sbin/tc qdisc del dev s1-eth2 root 2>&1 | head -1
rec="none"
t1=$(date +%s)
for i in $(seq 1 120); do
    sleep 1
    n=$(links_n)
    if [ "$n" = "32" ]; then rec=$(( $(date +%s) - t1 )); break; fi
done
say "   healed and re-discovered after: ${rec}s (links $(links_n)/32)"
say "   kernel graph after drill: $(curl -sf --max-time 5 $KERNEL/ndt/get_graph_data | python3 -c 'import json,sys; e=json.load(sys.stdin)["edges"]; print(len(e),"edges,",sum(1 for x in e if not x.get("is_up",True)),"down")' 2>/dev/null)"

say "# fabric left UP for phase 3 hand-off"
say "done -> $OUT"
