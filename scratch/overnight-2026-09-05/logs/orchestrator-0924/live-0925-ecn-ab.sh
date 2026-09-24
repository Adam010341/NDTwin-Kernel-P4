#!/usr/bin/env bash
# live-0925-ecn-ab.sh -- A/B for the one 06 arm that moved (ecn solution: ECN mark seen in 5/5 arms
# before R, 1/4 after). A = trunk as merged (R in), B = R's eight production files put back to
# 9d63af2e (the trunk before R) IN THE MAIN CHECKOUT, interleaved A B A B A B. The EXIT trap puts
# every file back to HEAD and checks it; nothing is committed. Everything else identical (same kernel
# binary, bmv2, p4c, compiled ecn.json).
# [Co-developed with claude code -- Adam]
set -u
G=/home/adam/Desktop/NDTwin-Kernel; L=$G/scratch/overnight-2026-09-05/logs/orchestrator-0924/live-0925
cd "$G" || exit 9; export NDT_OWNER=orch-0924
F="p4_proxy/proxy_agent/api_routes.py p4_proxy/proxy_agent/main.py p4_proxy/proxy_agent/p4_client.py
   p4_proxy/proxy_agent/ryu_flow_stats.py p4_proxy/proxy_agent/topology_manager.py
   tools/p4_exercise/common.py tools/p4_exercise/convert.py tools/p4_exercise/preflight.py"
[[ -z "$(git status --porcelain -- $F)" ]] || { echo "REFUSE: those files are not clean at HEAD"; exit 2; }
restore() { git checkout HEAD -- $F; git diff --quiet HEAD -- $F && echo "== restored: $F clean at $(git rev-parse --short HEAD)" || echo "🔴 RESTORE FAILED"; }
trap restore EXIT
for i in 1 2 3; do
  for arm in A B; do
    if [[ $arm == B ]]; then git checkout 9d63af2e -- $F; else git checkout HEAD -- $F; fi
    tag="$arm$i"; echo "== $(date '+%T') $tag main.py $(sha256sum p4_proxy/proxy_agent/main.py | cut -c1-12)"
    ONLY=ecn bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh > "$L/06_ecn_ab_$tag.log" 2>&1
    echo "   rc=$?  $(grep -E '^   ecn +solution' "$L/06_ecn_ab_$tag.log" | cut -c1-60)"
  done
done
echo "== DONE"
