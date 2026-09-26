#!/usr/bin/env bash
# The python half of L1's kernel lane (tools/test_workflow/l1_unit_tests.sh, "kernel-side Python
# and shell tests"), for tests/python only: the same interpreter probe, each file run as
# `$PY file -v` from the tree's root, the same verdict per file (l1_lane_verdict: rc != 0, any
# skip, nothing ran). No build, no ctest, no shell tests. One line per file, then the files that
# are not PASS -- to be set against CI's problem groups. [Co-developed with claude code -- Adam]
set -u
WT="$1"; OUT="${2:-${TMPDIR:-/tmp}/py_lane}"; mkdir -p "$OUT"
PY_KERNEL="$(command -v python3)"
for c in "${RYU_PY:-}" "$HOME/miniconda3/envs/ryu-env/bin/python" "${P4_PROXY_PY:-}" python3; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1 && "$c" -c "import networkx, ryu" >/dev/null 2>&1; then
        PY_KERNEL="$c"; break
    fi
done
echo "HEAD $(git -C "$WT" rev-parse HEAD)   interpreter $PY_KERNEL ($("$PY_KERNEL" --version 2>&1))"
bad=()
for f in "$WT"/tests/python/test_*.py; do
    name="$(basename "$f")"; log="$OUT/${name%.py}.log"
    (cd "$WT" && timeout 900 "$PY_KERNEL" "$f" -v) > "$log" 2>&1; rc=$?
    ran=$(grep -oE '^Ran [0-9]+' "$log" | tail -1 | grep -oE '[0-9]+'); ran=${ran:-0}
    skipped=$(grep -cE '\.\.\. skipped' "$log")
    ss=$(grep -oE '\(skipped=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+')
    [[ -n "$ss" && "$ss" -gt "$skipped" ]] && skipped=$ss
    if   (( rc != 0 )); then v="FAIL (exit $rc, ran=$ran)"
    elif (( skipped > 0 )); then v="FAIL $skipped skip(s)"
    elif (( ran == 0 )); then v="NO TESTS RAN"
    else v="PASS $ran ran and passed"; fi
    printf '  %-40s %s\n' "$name" "$v"
    [[ "$v" == PASS* ]] || { bad+=("$name"); grep -E '^(FAIL|ERROR):' "$log" | head -4 | cut -c1-160 | sed 's/^/        /'; }
done
echo "PY-LANE: ${#bad[@]} file(s) not PASS: ${bad[*]:-none}"
exit $(( ${#bad[@]} > 0 ? 1 : 0 ))
