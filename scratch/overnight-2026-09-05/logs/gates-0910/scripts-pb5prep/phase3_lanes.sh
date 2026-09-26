#!/usr/bin/env bash
# Worker pb5prep, phase 3b: l1_unit_tests.sh's Python lanes with P4_PROXY_PY=<python>.
#   phase3_lanes.sh <label> <python> [--with-3b]
# This worker may not build C++, so it runs l1_derive.py's copy of HEAD's l1_unit_tests.sh:
# sections 0 (gate anchors), 0b (test temp paths), 3 (P4 proxy Python tests) and, with --with-3b,
# 3b (kernel-side Python and shell tests); the C++ sections are cut (see l1_derive.py). NOT the
# CI-shaped copy: the probe order is the original's ($P4_PROXY_PY first). Through JOBS=1
# LOCK_WAIT=10800 guarded_build.sh; PYTHONDONTWRITEBYTECODE=1. With --with-3b, HB_PIN_VENVS is set
# to <python> so tests/shell/test_ndtwin_lab_heartbeat.sh's pin runs under the venv being tested
# rather than falling back to the main checkout's venv, which it names by path.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
label="${1:?label}"; PY="${2:?python}"; with3b=""; [[ "${3:-}" == --with-3b ]] && with3b=--with-3b
[[ -x "$PY" ]] || { echo "REFUSE: $PY"; exit 2; }
d="$W/l1_local_derived${with3b:+_3b}.sh"
python3 "$S/l1_derive.py" "$WT/tools/test_workflow/l1_unit_tests.sh" "$d" $with3b >/dev/null || exit 2
f=$(new_log "l1_python_lanes_${label}${with3b:+_with3b}" "l1 sections 0,0b,3${with3b:+,3b} (C++ cut) with P4_PROXY_PY=$PY") || exit 2
{ echo "# derived script $d sha256 $(sha256sum < "$d" | cut -c1-64), from l1_unit_tests.sh sha256 $(git -C "$WT" show HEAD:tools/test_workflow/l1_unit_tests.sh | sha256sum | cut -c1-64)"
  echo "# $(pyid "$PY")"
  echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; } >> "$f"
find "$WT/p4_proxy" "$WT/tools" "$WT/tests" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
( export P4_PROXY_PY="$PY" PYTHONDONTWRITEBYTECODE=1 LOG_DIR="$W/l1logs/$label${with3b:+_3b}" NO_COLOR=1
  [[ -n "$with3b" ]] && export HB_PIN_VENVS="$PY"
  mkdir -p "$LOG_DIR"
  cd "$WT" && JOBS=1 LOCK_WAIT=10800 "$GUARD" bash "$d" ) >> "$f" 2>&1
rc=$?
echo "rc=$rc" >> "$f"
grep -E 'FAIL|PROVED|SKIPPED|NO TESTS|gate anchors|temp paths|L1 PYTHON' "$f" | head -40
echo "lanes $label: rc=$rc"
exit $rc
