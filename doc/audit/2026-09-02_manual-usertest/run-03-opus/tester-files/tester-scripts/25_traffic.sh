#!/bin/bash
echo "=== B17: start iperf3 exactly as the manual shows, inside the Mininet CLI ==="
tmux send-keys -t MN 'h1 iperf3 -s &' Enter
sleep 3
tmux send-keys -t MN 'h2 iperf3 -c h1 -t 300 &' Enter
sleep 12
echo "--- mininet pane ---"
tmux capture-pane -t MN -p | tail -12
echo
echo "=== B18: query while the transfer is still running ==="
date +%H:%M:%S
curl -sS -X GET http://localhost:8000/ndt/get_detected_flow_data > /tmp/flows.json
echo "bytes returned: $(wc -c < /tmp/flows.json)"
python3 - <<'PY'
import json,struct
d=json.load(open('/tmp/flows.json'))
print("records:",len(d))
def ip(v): return '.'.join(str(b) for b in struct.pack('<I',v))
for r in d:
    print(f"  {ip(r['src_ip'])}:{r['src_port']} -> {ip(r['dst_ip'])}:{r['dst_port']} proto={r['protocol_id']} "
          f"rate_bps_last_sec={r['estimated_flow_sending_rate_bps_in_the_last_sec']} hops={len(r['path'])} "
          f"first={r['first_sampled_time']} latest={r['latest_sampled_time']}")
PY
echo
echo "=== B19: the manual's decoder one-liner on its own example value ==="
python3 -c "import struct,sys; print('.'.join(str(b) for b in struct.pack('<I',int(sys.argv[1]))))" 16777226
date +%H:%M:%S
