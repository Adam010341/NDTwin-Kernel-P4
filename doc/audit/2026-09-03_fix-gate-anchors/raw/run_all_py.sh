#!/usr/bin/env bash
WT=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-anchors
VENV=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
cd "$WT" || exit 2
pass=0; fail=0
for f in tests/python/test_*.py; do
    py=python3
    [[ "$(basename "$f")" == "test_sflow_stats_endpoint.py" ]] && py="$VENV"
    out=$(timeout 600 "$py" "$f" 2>&1); rc=$?
    last=$(grep -E '^(OK|FAILED)' <<<"$out" | tail -1)
    if [[ $rc -eq 0 ]]; then pass=$((pass+1)); st=PASS; else fail=$((fail+1)); st=FAIL; fi
    printf '%-6s rc=%-3s %-46s %s\n' "$st" "$rc" "$(basename "$f")" "$last"
done
echo "---"
echo "files: pass=$pass fail=$fail total=$((pass+fail))"
