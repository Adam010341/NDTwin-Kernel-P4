#!/usr/bin/env bash
# phase3_p4_smoke.sh -- full-stack round phase 3: P4 plane smoke on the promoted fast bmv2
# default. First `ndt up p4` through the new default path since d12641f's refuse-not-fallback;
# then binary identity from /proc, twin health, a five_tuple_live.sh regression rerun, and an
# sFlow liveness check.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail
export NDT_OWNER=review-0824
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; OUT="$DIR/phase3_p4_smoke.txt"
KERNEL=http://localhost:8000
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

say ""
say "# phase 3: P4 smoke -- $(date +%H:%M:%S)  commit $(git -C /home/adam/Desktop/NDTwin-Kernel rev-parse --short HEAD)"

ndt down >/dev/null 2>&1; sleep 3
if ! timeout 600 ndt up p4 > "$RAW/p3_up.out" 2>&1; then
    say "## ndt up p4: NONZERO EXIT -- see raw/p3_up.out"
fi
grep -E '^\s+(ok|XX)' "$RAW/p3_up.out" | sed 's/^/   /' | tee -a "$OUT" >/dev/null

say "## binary identity (from /proc, not config)"
pid=$(pgrep -f 'simple_switch_grp[c]' | head -1)
if [ -n "${pid:-}" ]; then
    exe=$(readlink /proc/$pid/exe 2>/dev/null || tr '\0' ' ' < /proc/$pid/cmdline | awk '{print $1}')
    say "   live switch binary: ${exe:-unreadable}"
else
    say "   no bmv2 process found"
fi

say "## twin health"
say "   kernel graph: $(curl -sf --max-time 5 $KERNEL/ndt/get_graph_data | python3 -c 'import json,sys; e=json.load(sys.stdin)["edges"]; print(len(e),"edges,",sum(1 for x in e if not x.get("is_up",True)),"down")' 2>/dev/null || echo unreachable)"

say "## five-tuple regression (rerun of the P2-5 live gate on this fresh fabric)"
if bash "$(git -C /home/adam/Desktop/NDTwin-Kernel rev-parse --show-toplevel)/doc/audit/2026-08-24_five-tuple-live/five_tuple_live.sh" > "$RAW/p3_five_tuple_rerun.txt" 2>&1; then
    say "   five_tuple_live.sh exit 0"
else
    say "   five_tuple_live.sh NONZERO exit -- see raw/p3_five_tuple_rerun.txt"
fi
grep -E 'rules with more than one match field|priority read back|pkts=|HTTP' "$RAW/p3_five_tuple_rerun.txt" | head -8 | sed 's/^/   /' | tee -a "$OUT" >/dev/null

say "## sFlow liveness (samples arriving at the kernel?)"
s1=$(curl -sf --max-time 5 "$KERNEL/ndt/get_detected_flow_data" | wc -c 2>/dev/null || echo 0)
sleep 10
s2=$(curl -sf --max-time 5 "$KERNEL/ndt/get_detected_flow_data" | wc -c 2>/dev/null || echo 0)
say "   get_detected_flow_data response bytes: $s1 -> $s2 (10s apart)"

ndt down >/dev/null 2>&1
say "# fabric torn down; phase 3 complete"
say "done -> $OUT"
