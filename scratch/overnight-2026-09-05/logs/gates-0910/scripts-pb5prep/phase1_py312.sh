#!/usr/bin/env bash
# Worker pb5prep, phase 1: the CI-shaped check on Python 3.12 (/usr/bin/python3.12, what the
# manual's P4 path gave a tester on Ubuntu 24.04.4 and what ci.yml's setup-python pins).
#   1. a fresh venv from HEAD's requirements.txt: `python -m venv`, `pip install -r` -- the first two
#      of the three install commands; the l1 probe `import p4.v1.p4runtime_pb2` must FAIL here;
#   2. l1's P4 Python lane, CI-shaped (no p4_proxy/venv, no p4dev-python-venv, python3 = this venv),
#      BEFORE the third command -- ci.yml's comment says this is red;
#   3. the third command, regen_p4runtime_pb2.py; the probe must pass; pip check; freeze;
#   4. the same CI-shaped lane AFTER it -- must be green;
#   5. the regen tool's prefix refusal (one of its never-executed paths, judge #12): a python whose
#      prefix does not contain the p4 package it imports must be refused, rc 2, nothing written.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
cd "$WT" || exit 2
V=$W/venv312-$SHA
BASE=/usr/bin/python3.12
[[ -e "$V" ]] && { echo "REFUSE: $V exists"; exit 2; }

# 1 ---------------------------------------------------------------------------------------------
f=$(new_log venv_create_py312 "venv $V from $BASE; commands 1-2 of the install, then the l1 probe (must FAIL before regen)") || exit 2
rc=0
{
  echo "# base $($BASE -VV)  realpath $(readlink -f $BASE)"
  echo "# requirements.txt sha256: HEAD $(git show HEAD:p4_proxy/requirements.txt | sha256sum | cut -c1-64)  worktree $(sha256sum < p4_proxy/requirements.txt | cut -c1-64)"
  echo "\$ $BASE -m venv $V"; $BASE -m venv "$V"; r=$?; echo "venv rc=$r"; [[ $r == 0 ]] || rc=1
  "$V/bin/pip" --version
  echo "\$ $V/bin/pip install -r p4_proxy/requirements.txt"
  "$V/bin/pip" install -r p4_proxy/requirements.txt 2>&1 | tee "$W/pip_install_py312.out"; r=${PIPESTATUS[0]}
  echo "pip install rc=$r"; [[ $r == 0 ]] || rc=1
  echo "pip fetched: $(grep -c '^ *Downloading ' "$W/pip_install_py312.out") 'Downloading' lines, $(grep -c '^ *Using cached ' "$W/pip_install_py312.out") 'Using cached' lines"
  grep '^ *Downloading ' "$W/pip_install_py312.out" | sed 's/^/  DOWNLOADED: /'
  echo "--- l1 probe BEFORE regen (must FAIL): $V/bin/python -c 'import p4.v1.p4runtime_pb2'"
  "$V/bin/python" -c 'import p4.v1.p4runtime_pb2' 2>&1 | tail -4; r=${PIPESTATUS[0]}
  echo "probe rc=$r (want nonzero)"; [[ $r != 0 ]] || rc=1
  echo "$(pyid "$V/bin/python")"
} >> "$f" 2>&1
echo "rc=$rc" >> "$f"; tail -12 "$f"

# 2 / 4: the CI-shaped lane ---------------------------------------------------------------------
lane() {   # lane <label> <want rc>
    local label="$1" want="$2" g d
    d="$W/l1_ci_derived.sh"
    python3 "$S/l1_derive.py" "$WT/tools/test_workflow/l1_unit_tests.sh" "$d" --ci >/dev/null || return 2
    g=$(new_log "l1_python_lanes_ci_py312_$label" "l1's sections 0,0b,3 (P4 lane), CI-shaped: P4_PROXY_PY=/nonexistent, p4dev path replaced, PATH=$V/bin first; want rc=$want") || return 2
    { echo "# derived script $d sha256 $(sha256sum < "$d" | cut -c1-64), from l1_unit_tests.sh sha256 $(git show HEAD:tools/test_workflow/l1_unit_tests.sh | sha256sum | cut -c1-64)"
      echo "# python3 on PATH -> $(PATH="$V/bin:$PATH" command -v python3)   $(pyid "$V/bin/python")"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; } >> "$g"
    ( export P4_PROXY_PY=/nonexistent/ci-has-no/p4_proxy/venv/bin/python PATH="$V/bin:$PATH" \
             LOG_DIR="$W/l1logs/ci_py312_$label" NO_COLOR=1
      mkdir -p "$LOG_DIR"
      JOBS=1 LOCK_WAIT=10800 "$GUARD" bash "$d" ) >> "$g" 2>&1
    local r=$?
    echo "rc=$r" >> "$g"
    tail -8 "$g"
    [[ $r == "$want" ]]
}
lane preregen 1 || echo "NOTE: pre-regen lane rc differs from the expected 1"

# 3 ---------------------------------------------------------------------------------------------
f=$(new_log venv_regen_py312 "command 3 of the install on $V, then the l1 probe, pip check, freeze") || exit 2
rc=0
{
  echo "\$ $V/bin/python p4_proxy/regen_p4runtime_pb2.py"
  "$V/bin/python" p4_proxy/regen_p4runtime_pb2.py; r=$?; echo "regen rc=$r"; [[ $r == 0 ]] || rc=1
  echo "--- l1 probe AFTER regen (must pass)"
  "$V/bin/python" -c 'import p4.v1.p4runtime_pb2'; r=$?; echo "probe rc=$r"; [[ $r == 0 ]] || rc=1
  echo "--- identity"; pyid "$V/bin/python"
  "$V/bin/python" -c 'import p4.v1.p4runtime_pb2 as m; print(open(m.__file__).read().splitlines()[4])'
  echo "--- rerun (idempotence)"; "$V/bin/python" p4_proxy/regen_p4runtime_pb2.py; r=$?; echo "rerun rc=$r"; [[ $r == 0 ]] || rc=1
  echo "--- pip check"; "$V/bin/python" -m pip check; r=$?; echo "pip check rc=$r"; [[ $r == 0 ]] || rc=1
  echo "--- grpcio-tools declares:"; "$V/bin/python" -c 'from importlib.metadata import requires; print([r for r in requires("grpcio-tools") if "protobuf" in r])'
  echo "--- pip freeze --all"; "$V/bin/python" -m pip freeze --all
  echo "--- regenerated modules"; (cd "$V/lib/python3.12/site-packages" && sha256sum p4/v1/*_pb2*.py p4/config/v1/*_pb2*.py)
} >> "$f" 2>&1
echo "rc=$rc" >> "$f"; grep -E 'rc=|protobuf|ok:|already' "$f" | tail -12

lane postregen 0 || echo "NOTE: post-regen lane rc differs from the expected 0"

# 5 ---------------------------------------------------------------------------------------------
f=$(new_log regen_refusal_prefix_py312 "regen tool run by $BASE (prefix /usr) with PYTHONPATH=$V site-packages: must refuse rc 2 and write nothing") || exit 2
{
  SPK="$V/lib/python3.12/site-packages"
  before=$(cd "$SPK/p4" && find . -type f -printf '%p %s %T@\n' | sort | sha256sum | cut -c1-64)
  echo "p4 package fingerprint before: $before"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$SPK" $BASE p4_proxy/regen_p4runtime_pb2.py; r=$?
  echo "tool rc=$r (want 2)"
  after=$(cd "$SPK/p4" && find . -type f -printf '%p %s %T@\n' | sort | sha256sum | cut -c1-64)
  echo "p4 package fingerprint after:  $after"
  [[ $r == 2 && "$before" == "$after" ]]; echo "rc=$?"
} >> "$f" 2>&1
tail -5 "$f"
