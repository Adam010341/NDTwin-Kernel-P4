#!/usr/bin/env bash
# t6_punt_window.sh -- discriminate WHY Ryu never learns host IPv4 after boot on OVS.
#
# Hypothesis (review session, 2026-08-21): the host tracker learns IPv4 only from
# packet-ins; once the all-pairs rules are installed nothing IPv4 ever punts again,
# and static ARP closes the ARP path. So the learning window ends when rules land.
# Both macro arms already measured today: settle=10 -> 0/128 learned (persistent),
# settle=60 -> 128/128 (L4 baseline capture). This probes the mechanism directly:
#   control arm: ping with rules intact           -> must NOT teach Ryu
#   test arm:    delete s1's rule to 10.0.0.33,   -> same ping now punts at s1;
#                ping again                          h1 (the src) must appear with ipv4
set -uo pipefail
export NDT_OWNER="${NDT_OWNER:-review-0821}"
OUT="${1:-/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/80663333-dc9c-42bd-9c05-499d63b60be1/scratchpad/t6_punt_window.txt}"
RYU=http://localhost:8080
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

hosts_with_ip() {
    curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" | python3 -c "
import json,sys
hs=json.load(sys.stdin)
withip=[h for h in hs if h.get('ipv4')]
print(f'{len(withip)}/{len(hs)} hosts with ipv4', end='')
if withip: print(' -- with:', ','.join(sorted(ip for h in withip for ip in h['ipv4'])[:6]), end='')
print()"
}

say "# T6 punt-window discriminator, OVS 128 hosts, settle=default(10)"
say "# date: $(date -Is)   commit: $(git -C /home/adam/Desktop/NDTwin-Kernel rev-parse --short HEAD)"
ndt claim 25 "punt-window discriminator (review session)" >/dev/null 2>&1 || true
say "## boot"
if ! timeout 600 ndt up ovs > /tmp/t6_up.out 2>&1; then
    say "UP FAILED"; tail -5 /tmp/t6_up.out | tee -a "$OUT"; exit 1
fi
say "  up ok ($(grep -c '^ok' /tmp/t6_up.out) checks)"

say "## step 1: baseline learning state (expect ~0/128 at settle=10)"
say "  $(hosts_with_ip)"

say "## step 2: table-miss entry on s1 (packet-in path exists at all?)"
curl -sf --max-time 5 "$RYU/stats/flow/1" | python3 -c "
import json,sys
fl=json.load(sys.stdin).get('1',[])
miss=[f for f in fl if f.get('priority')==0]
ctrl=[f for f in miss if any('CONTROLLER' in str(a) for a in f.get('actions',[]))]
print(f'  s1: {len(fl)} flows, priority-0 entries: {len(miss)}, of those to CONTROLLER: {len(ctrl)}')
for f in miss[:2]: print('   miss entry actions:', f.get('actions'))" | tee -a "$OUT"

H1PID=$(pgrep -f 'mininet:h1$' | head -1)
say "## step 3: CONTROL -- ping h1->10.0.0.33 with rules intact (must NOT teach)"
say "  h1 pid: ${H1PID:-NOT FOUND}"
sudo -n mnexec -a "$H1PID" ping -c 3 -i 0.3 -W 1 10.0.0.33 > /tmp/t6_ping1.out 2>&1
say "  ping: $(grep -E 'transmitted' /tmp/t6_ping1.out)"
sleep 8
say "  after control ping: $(hosts_with_ip)"

say "## step 4: delete s1's rule toward 10.0.0.33 (make the same ping punt)"
before=$(curl -sf "$RYU/stats/flow/1" | python3 -c "import json,sys; print(sum(1 for f in json.load(sys.stdin)['1'] if f.get('match',{}).get('nw_dst')=='10.0.0.33' or f.get('match',{}).get('ipv4_dst')=='10.0.0.33'))")
curl -sf -X POST -d '{"dpid":1,"table_id":0,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.33"}}' \
    "$RYU/stats/flowentry/delete" > /dev/null 2>&1
sleep 1
after=$(curl -sf "$RYU/stats/flow/1" | python3 -c "import json,sys; print(sum(1 for f in json.load(sys.stdin)['1'] if f.get('match',{}).get('nw_dst')=='10.0.0.33' or f.get('match',{}).get('ipv4_dst')=='10.0.0.33'))")
say "  s1 rules matching dst 10.0.0.33: $before -> $after"
if [[ "$after" != "0" ]]; then
    say "  DELETE DID NOT TAKE -- aborting test arm (control arm result above still stands)"
else
    say "## step 5: TEST -- same ping, now punting at s1"
    sudo -n mnexec -a "$H1PID" ping -c 5 -i 0.3 -W 1 10.0.0.33 > /tmp/t6_ping2.out 2>&1
    say "  ping: $(grep -E 'transmitted' /tmp/t6_ping2.out)"
    sleep 8
    say "  after punting ping: $(hosts_with_ip)"
    say "  (hypothesis: 10.0.0.1 -- the packet-in's src -- appears; nothing else does)"
fi

say "## step 6: kernel graph host-edge count 35s later (does the learned host's edge flip up?)"
sleep 35
curl -sf --max-time 5 http://localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys
g=json.load(sys.stdin)
e=g.get('edges',[])
hostup=[x for x in e if (x.get('dst_dpid')==0 or x.get('src_dpid')==0) and x.get('is_up')]
print(f'  host edges up: {len(hostup)}/256')
for x in hostup[:4]: print('   up:', x.get('src_dpid'), '->', x.get('dst_ip') or x.get('dst_dpid'))" | tee -a "$OUT"

say "## teardown"
ndt down > /tmp/t6_down.out 2>&1 && say "  down ok" || say "  DOWN FAILED (see /tmp/t6_down.out)"
ndt release >/dev/null 2>&1 || true
say "done -> $OUT"
