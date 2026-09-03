#!/usr/bin/env bash
# Per-module, because a single `unittest discover` collapses 54 modules into one verdict and a
# module that fails to import is reported the same way as one that has no tests.
# [Co-developed with claude code -- Adam]
set -u
WT=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-topoval
VENV=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
OUT="$1"
: > "$OUT"

pass=0; fail=0; failed_names=""

echo "########## tests/python (system python3, per module) ##########" >> "$OUT"
cd "$WT" || exit 9
for f in tests/python/test_*.py; do
    name=$(basename "$f")
    if [[ "$name" == "test_sflow_stats_endpoint.py" ]]; then
        PY="$VENV"
    else
        PY=python3
    fi
    log=$(timeout 300 "$PY" -m unittest "$f" 2>&1); rc=$?
    tail1=$(grep -E '^(OK|FAILED|Ran )' <<<"$log" | tr '\n' ' ')
    if [[ $rc -eq 0 ]]; then
        printf '  ok    %-46s %s\n' "$name" "$tail1" >> "$OUT"; pass=$((pass+1))
    else
        printf '  FAIL  %-46s rc=%d %s\n' "$name" "$rc" "$tail1" >> "$OUT"; fail=$((fail+1))
        failed_names="$failed_names tests/python/$name"
        echo "----- $name -----" >> "$OUT.detail"
        tail -40 <<<"$log" >> "$OUT.detail"
    fi
done

echo >> "$OUT"
echo "########## p4_proxy/tests (venv python, per module) ##########" >> "$OUT"
cd "$WT/p4_proxy" || exit 9
for f in tests/test_*.py; do
    name=$(basename "$f")
    log=$(timeout 300 "$VENV" -m unittest "$f" 2>&1); rc=$?
    tail1=$(grep -E '^(OK|FAILED|Ran )' <<<"$log" | tr '\n' ' ')
    if [[ $rc -eq 0 ]]; then
        printf '  ok    %-46s %s\n' "$name" "$tail1" >> "$OUT"; pass=$((pass+1))
    else
        printf '  FAIL  %-46s rc=%d %s\n' "$name" "$rc" "$tail1" >> "$OUT"; fail=$((fail+1))
        failed_names="$failed_names p4_proxy/tests/$name"
        echo "----- p4_proxy $name -----" >> "$OUT.detail"
        tail -40 <<<"$log" >> "$OUT.detail"
    fi
done

{
  echo
  echo "########## TALLY ##########"
  echo "  modules green: $pass"
  echo "  modules red:   $fail"
  [[ -n "$failed_names" ]] && echo "  red modules:  $failed_names"
} >> "$OUT"
echo "PY_SUITES_DONE pass=$pass fail=$fail"
