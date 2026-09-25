#!/usr/bin/env bash
# Worker REQ (TICKET-p4proxy-requirements): run the p4_proxy suite and the tools/p4_exercise suite
# (with the real HOME, and with an empty HOME) under ONE named interpreter, on the worktree's HEAD.
# [Co-developed with claude code -- Adam]
#
#   run_suites.sh <label> <python>
#
# Same commands as the p4r rounds (scripts-p4r-177b9f03/final_gates_r3.sh, scripts-p4r-3ff87a10/
# final_gates_r2.sh), so the counts are comparable with theirs. Every suite goes through
# tools/build_guard/guarded_build.sh with JOBS=1 LOCK_WAIT=10800. Each writes
# <suite>_<label>.p4req-<sha8>.log; its FIRST line is the full HEAD sha and the interpreter's
# realpath, then the interpreter's version, protobuf backend and `pip freeze`. A log that exists
# is never overwritten. Refuses to run on a tree with tracked changes.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
label="${1:?label}"; PY="${2:?python}"
[[ -x "$PY" ]] || { echo "REFUSE: $PY is not executable"; exit 2; }
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain --untracked-files=no | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
export TMPDIR="$SP/tmp"; mkdir -p "$TMPDIR"
# The main checkout's p4_proxy/venv is READ-ONLY for this ticket (live runs use it): nothing run
# here, the header probes included, may drop a .pyc into its site-packages.
export PYTHONDONTWRITEBYTECODE=1 PIP_NO_INPUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1
EMPTYHOME="$SP/emptyhome"; mkdir -p "$EMPTYHOME"
# v2: `python -m pip`, not $(dirname PY)/pip -- a copied venv's pip script runs the ORIGINAL venv.
PIP_CMD=("$PY" -m pip)
fail=0
run() {   # run <suite> <cwd> <cmd...>
    local name="$1_$label" cwd="$2" log rc
    shift 2
    log="$L/$name.p4req-$sha.log"
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then
        echo "REFUSE: HEAD moved or tracked files changed (was $sha)"; exit 3
    fi
    find "$WT/p4_proxy" "$WT/tools" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    { echo "# HEAD $full  interpreter $(readlink -f "$PY")  ($PY)"
      echo "# worktree $WT  $(date -u +%FT%TZ)"
      echo "# python $("$PY" -c 'import sys; print(sys.version.replace(chr(10), " "))')"
      echo "# protobuf $("$PY" -c 'import google.protobuf as p; from google.protobuf.internal import api_implementation as a; print(p.__version__, "backend=" + a.Type())' 2>&1 | tail -1)"
      echo "# PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=${PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION:-<unset>}"
      echo "# pip freeze:"; "${PIP_CMD[@]}" freeze 2>&1 | sed 's/^/#   /'
      echo "# cwd $cwd"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; } > "$log"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-48s rc=%s  %s | %s\n' "$name" "$rc" \
        "$(/usr/bin/grep -E '^Ran [0-9]+ tests' "$log" | tail -1)" \
        "$(/usr/bin/grep -E '^(OK|FAILED)' "$log" | tail -1)"
    [[ "$rc" == 0 ]] || fail=1
}
MODS=$(ls "$WT"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
run p4_proxy_suite "$WT/p4_proxy" env PYTHONPATH="$WT/p4_proxy" PYTHONDONTWRITEBYTECODE=1 \
    "$PY" -m unittest $MODS
run p4_exercise_suite "$WT" env PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover \
    -s tools/p4_exercise/tests -t tools/p4_exercise/tests
run p4_exercise_suite_notutorials "$WT" env HOME="$EMPTYHOME" PYTHONDONTWRITEBYTECODE=1 "$PY" \
    -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests
echo "SUITES $label $sha: $([ $fail = 0 ] && echo ALL-GREEN || echo RED)"
exit $fail
