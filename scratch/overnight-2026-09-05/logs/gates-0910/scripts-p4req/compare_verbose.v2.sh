#!/usr/bin/env bash
# Worker REQ: equal counts are not equal results. Run both suites under two interpreters on the
# worktree's HEAD, record test id -> verdict (verdicts.py), and diff per test, so a pass that
# turned into a skip -- or a different test skipping -- cannot hide behind an unchanged
# "Ran N / OK (skipped=1)". Each run goes through guarded_build.sh, JOBS=1 LOCK_WAIT=10800.
# [Co-developed with claude code -- Adam]
#
#   compare_verbose.sh <labelA> <pythonA> <labelB> <pythonB>
# Logs: <suite>_verdicts_<label>.p4req-<sha8>.log (+ .tsv with the verdicts).
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD=$WT/tools/build_guard/guarded_build.sh
export TMPDIR="$SP/tmp" PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1
[[ -z "$(git -C "$WT" status --porcelain --untracked-files=no | head -1)" ]] || { echo "REFUSE: tracked changes"; exit 2; }
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
MODS=$(ls "$WT"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
one() {   # one <label> <python> <suite> -> tsv path on stdout
    local label="$1" PY="$2" suite="$3" log tsv
    log="$L/${suite}_verdicts_$label.p4req-$sha.log"; tsv="${log%.log}.tsv"
    [[ -e "$log" ]] && { echo "REFUSE: $log exists" >&2; echo "$tsv"; return; }
    find "$WT/p4_proxy" "$WT/tools" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    { echo "# HEAD $full  interpreter $(readlink -f "$PY")  ($PY)  $(date -u +%FT%TZ)"
      echo "# protobuf $("$PY" -c 'import google.protobuf as p; from google.protobuf.internal import api_implementation as a; print(p.__version__, "backend=" + a.Type())' 2>&1 | tail -1)"
      echo "# PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=${PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION:-<unset>}"
      echo "# verdicts -> $tsv"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; } > "$log"
    if [[ "$suite" == p4_proxy_suite ]]; then
        ( cd "$WT/p4_proxy" && JOBS=1 LOCK_WAIT=10800 "$GUARD" env PYTHONPATH="$WT/p4_proxy" \
            "$PY" "$HERE/verdicts.py" "$tsv" modules $MODS ) >> "$log" 2>&1
    else
        ( cd "$WT" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$PY" "$HERE/verdicts.py" "$tsv" discover \
            tools/p4_exercise/tests tools/p4_exercise/tests ) >> "$log" 2>&1
    fi
    echo "# rc=$?" >> "$log"
    echo "$tsv"
}
rc=0
for suite in p4_proxy_suite p4_exercise_suite; do
    a=$(one "$1" "$2" "$suite"); b=$(one "$3" "$4" "$suite")
    # v2 (fix): a suite that dies while LOADING writes no verdict file. v1 let `diff` fail on
    # stderr, printed "per-test diff lines: 0" and did not set rc -- silence read as agreement.
    missing=""
    for t in "$a" "$b"; do [[ -s "$t" ]] || missing+=" $(basename "$t")"; done
    if [[ -n "$missing" ]]; then
        printf '%-18s RED: no verdicts (the suite did not load):%s\n' "$suite" "$missing"; rc=1; continue
    fi
    d=$(diff "$a" "$b")
    printf '%-18s %s: %s ids (%s skip, %s not ok)  %s: %s ids (%s skip, %s not ok)  per-test diff lines: %s\n' \
        "$suite" "$1" "$(wc -l < "$a")" "$(/usr/bin/grep -c $'\tskip' "$a")" "$(/usr/bin/grep -vcE $'\t(ok|skip)' "$a")" \
        "$3" "$(wc -l < "$b")" "$(/usr/bin/grep -c $'\tskip' "$b")" "$(/usr/bin/grep -vcE $'\t(ok|skip)' "$b")" \
        "$(printf '%s' "$d" | /usr/bin/grep -c '^[<>]')"
    [[ -n "$d" ]] && { printf '%s\n' "$d" | head -60; rc=1; }
done
exit $rc
