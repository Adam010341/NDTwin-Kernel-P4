#!/usr/bin/env bash
# Worker pb5prep, phase 4: checks on the FILE and the new venv that the suites cannot make.
#   phase4_misc.sh <new venv python (3.13)>
#   a. import coverage (REQ's check_imports_vs_requirements.py, unchanged): every third-party
#      import of p4_proxy/ and tools/p4_exercise/ is named in HEAD's requirements.txt. The header
#      says so, and grpcio-tools is now one of them (regen_p4runtime_pb2.py imports grpc_tools).
#      Negative control: the same file without its grpcio-tools line must be RED.
#   b. pins vs venvs (REQ's check_pins_vs_venv.py, unchanged): HEAD's file vs the new venv's freeze
#      (every line must MATCH) and vs the main venv's freeze -- expected RED on protobuf and
#      grpcio-tools: the header's "the development machine's venv is still the older set".
#   c. the bmv2 thrift CLI recipe in requirements.txt (PYTHONPATH=p4dev site-packages), import
#      only, under the new venv and the main venv: does it still import, and whose protobuf.
# PYTHONDONTWRITEBYTECODE=1 throughout (main venv and p4dev-python-venv are read-only here).
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
NEWPY="${1:?new venv python}"
export PYTHONDONTWRITEBYTECODE=1
cd "$WT" || exit 2
git show HEAD:p4_proxy/requirements.txt > "$W/req.HEAD.txt"
grep -v '^grpcio-tools==' "$W/req.HEAD.txt" > "$W/req.HEAD.minus-grpcio-tools.txt"

# a ---------------------------------------------------------------------------------------------
f=$(new_log check_imports_file-HEAD "import coverage of HEAD's requirements.txt, mapped under $NEWPY; then the minus-grpcio-tools control") || exit 2
{ echo "# $(pyid "$NEWPY")"
  echo "== HEAD's file (want GREEN)"; "$NEWPY" "$S/check_imports_vs_requirements.py" "$WT" "$W/req.HEAD.txt"; a=$?; echo "rc=$a"
  echo "== control: HEAD's file without grpcio-tools (want RED, MISSING grpcio-tools)"
  "$NEWPY" "$S/check_imports_vs_requirements.py" "$WT" "$W/req.HEAD.minus-grpcio-tools.txt"; b=$?; echo "rc=$b"
  [[ $a == 0 && $b != 0 ]]; echo "verdict: file GREEN and control RED -> $([[ $a == 0 && $b != 0 ]] && echo PASS || echo FAIL)"
  [[ $a == 0 && $b != 0 ]]; echo "rc=$?"; } >> "$f" 2>&1
grep -E '^(==|RESULT|MISSING|UNRESOLVED|verdict|rc=)' "$f"

# b ---------------------------------------------------------------------------------------------
f=$(new_log check_pins_file-HEAD "HEAD's requirements.txt vs pip freeze of the new venv (want GREEN) and of the main venv (want RED on protobuf, grpcio-tools)") || exit 2
{ "$NEWPY" -m pip freeze --all > "$W/freeze.new313.txt"
  "$MAINPY" -m pip freeze --all > "$W/freeze.main.txt"
  echo "== vs new venv ($(pyid "$NEWPY"))"; python3 "$S/check_pins_vs_venv.py" "$W/req.HEAD.txt" "$W/freeze.new313.txt"; a=$?; echo "rc=$a"
  echo "== vs main venv ($(pyid "$MAINPY"))"; python3 "$S/check_pins_vs_venv.py" "$W/req.HEAD.txt" "$W/freeze.main.txt"; b=$?; echo "rc=$b"
  echo "== main venv lines that do not MATCH:"; python3 "$S/check_pins_vs_venv.py" "$W/req.HEAD.txt" "$W/freeze.main.txt" | grep -v '^MATCH'
  bad=$(python3 "$S/check_pins_vs_venv.py" "$W/req.HEAD.txt" "$W/freeze.main.txt" | grep -v '^MATCH' | grep -v '^RESULT' | awk '{print $2}' | sort | tr '\n' ' ')
  echo "main-venv mismatches: $bad (want: grpcio-tools protobuf)"
  [[ $a == 0 && $b != 0 && "$bad" == "grpcio-tools protobuf " ]]; echo "rc=$?"; } >> "$f" 2>&1
grep -E '^(==|RESULT|main-venv|rc=)' "$f"

# c ---------------------------------------------------------------------------------------------
f=$(new_log thrift_cli_recipe_imports "requirements.txt's bmv2 CLI recipe, import only: PYTHONPATH=p4dev site-packages, under the new venv and the main venv") || exit 2
SPD=/home/adam/p4dev-python-venv/lib/python3.13/site-packages
rc=0
{ for py in "$NEWPY" "$MAINPY"; do
    echo "== $(pyid "$py")"
    PYTHONPATH="$SPD" "$py" -c 'import sys
import sswitch_CLI, runtime_CLI, bmpy_utils, bm_runtime, sswitch_runtime, thrift
print("imports ok; thrift from", thrift.__file__)
pb = sys.modules.get("google.protobuf")
print("google.protobuf loaded:", pb.__file__ if pb else "no")'
    r=$?; echo "rc=$r"; [[ $r == 0 ]] || rc=1
  done; echo "rc=$rc"; } >> "$f" 2>&1
grep -E '^(==|imports ok|google.protobuf|rc=)' "$f"
