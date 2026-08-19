#!/usr/bin/env bash
# How often does F-5 actually fire?
#
# F-5's signature is the absence of evidence: on OVS a rejected rule leaves nothing in any
# log. So frequency cannot be read from logs -- it has to be measured by comparing the
# kernel's own flow-table view against the switch's real table and counting divergences.
#
# Read-only. Touches no product code, installs nothing, changes no state.
#
# Usage:  measure_f5_frequency.sh [seconds_between_samples] [total_minutes]
# Output: a line per sample; DIVERGENCE lines are the finding.
#
# [Co-developed with claude code -- Adam]
set +e
cd /home/adam/Desktop/NDTwin-Kernel
PY=p4_proxy/venv/bin/python
INTERVAL="${1:-10}"
MINUTES="${2:-60}"
OUT="${OUT:-/home/adam/Desktop/NDTwin-Kernel/scratch/f5_frequency.log}"

echo "# F-5 divergence measurement  interval=${INTERVAL}s duration=${MINUTES}min" | tee "$OUT"
echo "# kernel view = /ndt/get_switch_openflow_table_entries" | tee -a "$OUT"
echo "# ground truth = ovs-ofctl dump-flows (per bridge)" | tee -a "$OUT"

END=$(( $(date +%s) + MINUTES * 60 ))
samples=0; diverged=0

while [ "$(date +%s)" -lt "$END" ]; do
    samples=$((samples+1))
    ts=$(date '+%H:%M:%S')

    # --- ground truth first, and in one pass, so the two views are as close in time as
    #     possible. Reading them minutes apart is what makes a "comparison" meaningless.
    truth=""
    for br in $(sudo -n ovs-vsctl list-br 2>/dev/null | sort -V); do
        dpid=${br#s}
        n=$(sudo -n mnexec -a 1 ovs-ofctl -O OpenFlow13 dump-flows "$br" 2>/dev/null | grep -c cookie)
        prios=$(sudo -n mnexec -a 1 ovs-ofctl -O OpenFlow13 dump-flows "$br" 2>/dev/null \
                | grep -oE 'priority=[0-9]+' | cut -d= -f2 | sort -n | uniq -c | tr '\n' ' ')
        truth="${truth}${dpid}:${n}:${prios}|"
    done

    kern=$(curl -s --max-time 8 'http://localhost:8000/ndt/get_switch_openflow_table_entries' \
      | $PY -c "
import json,sys
from collections import Counter
try: d=json.load(sys.stdin)
except Exception: print('ERR'); raise SystemExit
out=[]
for sw in sorted(d, key=lambda x: x['dpid']):
    rules=[r for t in sw['flows'].values() for r in t]
    c=Counter(r.get('priority') for r in rules)
    prios=' '.join(f'{n} {p}' for p,n in sorted(c.items()))
    out.append(f\"{sw['dpid']}:{len(rules)}:{prios} \")
print('|'.join(out)+'|')
" 2>/dev/null)

    if [ "$kern" = "$truth" ]; then
        printf '%s sample %-4s MATCH\n' "$ts" "$samples" | tee -a "$OUT"
    else
        diverged=$((diverged+1))
        {
          printf '%s sample %-4s *** DIVERGENCE ***\n' "$ts" "$samples"
          printf '   kernel: %s\n' "$kern"
          printf '   truth : %s\n' "$truth"
        } | tee -a "$OUT"
    fi
    sleep "$INTERVAL"
done

echo "# ==> $diverged divergence(s) in $samples samples over ${MINUTES} min" | tee -a "$OUT"
