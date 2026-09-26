#!/usr/bin/env bash
# Worker pb5prep, phase 3a: both suites under ONE interpreter, one verdict per test id.
#   phase3_suites.sh <label> <python>
# Suites, the way the p4r/REQ rounds ran them (counts comparable): p4_proxy (all 41 test_*.py as
# modules, cwd p4_proxy, PYTHONPATH=p4_proxy); tools/p4_exercise (discover, real HOME); the same
# with an empty HOME. Each through JOBS=1 LOCK_WAIT=10800 guarded_build.sh, via verdicts.py (REQ's
# tool, copied here unchanged -- FROM-scripts-p4req.sha256), which prints unittest's own summary
# and writes <suite>_verdicts_<label>.pb5prep-<sha>.tsv. PYTHONDONTWRITEBYTECODE=1 for every run:
# the main checkout's venv is read-only for this worker, and the other venvs get the same setting.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
label="${1:?label}"; PY="${2:?python}"
[[ -x "$PY" ]] || { echo "REFUSE: $PY"; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
EMPTYHOME="$W/emptyhome"; mkdir -p "$EMPTYHOME"
fail=0
run() {   # run <suite> <cwd> <cmd...>
    local suite="$1" cwd="$2" f rc
    shift 2
    f=$(new_log "${suite}_$label" "suite $suite under $PY") || { fail=1; return; }
    find "$WT/p4_proxy" "$WT/tools" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    { echo "# $(pyid "$PY")"
      echo "# PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=${PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION:-<unset>}  HOME=${HOME_OVERRIDE:-$HOME}"
      echo "# pip freeze --all:"; "$PY" -m pip freeze --all 2>&1 | sed 's/^/#   /'
      echo "# cwd $cwd"; echo "# cmd $*"; echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; } >> "$f"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$f" 2>&1; rc=$?
    echo "rc=$rc" >> "$f"
    printf '%-44s rc=%s  %s | %s\n' "${suite}_$label" "$rc" "$(grep -E '^Ran [0-9]+ tests' "$f" | tail -1)" "$(grep -E '^(OK|FAILED)' "$f" | tail -1)"
    [[ $rc == 0 ]] || fail=1
}
tsv() { echo "$L/$1_verdicts_$label.pb5prep-$SHA.tsv"; }
MODS=$(ls "$WT"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
run p4_proxy_suite "$WT/p4_proxy" env PYTHONPATH="$WT/p4_proxy" "$PY" "$S/verdicts.py" "$(tsv p4_proxy_suite)" modules $MODS
run p4_exercise_suite "$WT" "$PY" "$S/verdicts.py" "$(tsv p4_exercise_suite)" discover tools/p4_exercise/tests tools/p4_exercise/tests
HOME_OVERRIDE=$EMPTYHOME run p4_exercise_suite_emptyhome "$WT" env HOME="$EMPTYHOME" "$PY" "$S/verdicts.py" "$(tsv p4_exercise_suite_emptyhome)" discover tools/p4_exercise/tests tools/p4_exercise/tests
echo "SUITES $label @$SHA: $([ $fail = 0 ] && echo ALL-GREEN || echo RED)"
exit $fail
