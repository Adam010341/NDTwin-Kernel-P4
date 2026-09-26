#!/usr/bin/env bash
# Worker pb5prep, phase 2: rehearse requirements.txt's "UPGRADING AN EXISTING VENV" on Python
# 3.13.13 (the development machine's base interpreter, /home/adam/miniconda3/bin/python3), on a
# stand-in for p4_proxy/venv under this worktree's scratch/ -- never on the real one.
#   R0  the stand-in: a venv at RV built from trunk 580767a8's requirements.txt (protobuf 3.20.3),
#       by the two-command install that file documents. PARK (the procedure's $HOME) is $W/park.
#   R1-R3  blocks 1, 2 and 3 of the procedure, extracted from HEAD's committed file and run
#       verbatim by gen_rehearsal.py's script (the only edit: V and PARK), through the build guard.
# The venv this leaves at RV is the "new 3.13 venv" every later phase uses; phase 5 rolls it back.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
cd "$WT" || exit 2
RV=scratch/pb5prep/rehearsal-$SHA/p4_proxy/venv      # relative to the repo root, like the procedure's V
PARK=$W/park-$SHA
BASE=/home/adam/miniconda3/bin/python3
[[ -e "$WT/$RV" || -e "$PARK" ]] && { echo "REFUSE: $RV or $PARK exists"; exit 2; }
mkdir -p "$(dirname "$WT/$RV")" "$PARK"

# R0 --------------------------------------------------------------------------------------------
f=$(new_log rehearsal_r0_standin_old_venv "stand-in for the development machine's venv: $RV from requirements.txt @ $TRUNK, 2-command install, base $BASE") || exit 2
rc=0
{
  git show "$TRUNK:p4_proxy/requirements.txt" > "$W/requirements.trunk.txt"
  echo "# requirements.txt @ trunk sha256 $(sha256sum < "$W/requirements.trunk.txt" | cut -c1-64); pins:"
  grep -E '^[A-Za-z]' "$W/requirements.trunk.txt" | sed 's/^/#   /'
  echo "# base $($BASE -VV) realpath $(readlink -f $BASE)"
  echo "\$ $BASE -m venv $RV"; $BASE -m venv "$RV"; r=$?; echo "rc=$r"; [[ $r == 0 ]] || rc=1
  echo "\$ $RV/bin/pip install -r <trunk requirements.txt>"
  "$RV/bin/pip" install -r "$W/requirements.trunk.txt" > "$W/pip_install_r0.out" 2>&1; r=$?
  tail -3 "$W/pip_install_r0.out"; echo "pip install rc=$r"; [[ $r == 0 ]] || rc=1
  echo "pip fetched: $(grep -c '^ *Downloading ' "$W/pip_install_r0.out") Downloading, $(grep -c '^ *Using cached ' "$W/pip_install_r0.out") Using cached"
  echo "--- identity (want protobuf 3.20.3 backend=python)"; pyid "$RV/bin/python"
  "$RV/bin/python" -c 'import p4.v1.p4runtime_pb2'; r=$?; echo "l1 probe rc=$r (want 0)"; [[ $r == 0 ]] || rc=1
  echo "--- pip freeze --all"; "$RV/bin/python" -m pip freeze --all
} >> "$f" 2>&1
echo "rc=$rc" >> "$f"; grep -E 'rc=|venv .* protobuf' "$f"
[[ $rc == 0 ]] || exit 1

# R1-R3 -----------------------------------------------------------------------------------------
git show HEAD:p4_proxy/requirements.txt > "$W/requirements.HEAD.txt"
gen="$W/rehearsal_forward.gen.sh"
python3 "$S/gen_rehearsal.py" "$W/requirements.HEAD.txt" forward "$RV" "$PARK" "$W/rehearsal-$SHA.vars" "$gen" || exit 2
f=$(new_log rehearsal_forward "the procedure's blocks 1-3 run verbatim on the stand-in (V=$RV, PARK=$PARK), through JOBS=1 LOCK_WAIT=10800 guarded_build.sh") || exit 2
{ echo "# requirements.txt @ HEAD sha256 $(sha256sum < "$W/requirements.HEAD.txt" | cut -c1-64)"
  echo "# generated script $gen sha256 $(sha256sum < "$gen" | cut -c1-64); its text:"
  sed 's/^/#| /' "$gen"; echo "# ---- run ----"; } >> "$f"
( JOBS=1 LOCK_WAIT=10800 "$GUARD" bash "$gen" ) >> "$f" 2>&1
grc=$?
# Verdict from what the run printed. Every procedure command must answer rc=0; the probe before
# regen must fail and the one after must pass; block 3's notes must be what it prints.
python3 - "$f" "$grc" >> "$f" <<'PY'
import re, sys
log, grc = open(sys.argv[1]).read(), int(sys.argv[2])
run = log.split("# ---- run ----", 1)[1]
rcs = re.findall(r"^\[rc=(\d+)\]$", run, re.M)
probes = re.findall(r"^\[rehearsal probe rc=(\d+)\] \(want (\S+)", run, re.M)
checks = {
    "guard exit 0": grc == 0,
    f"all {len(rcs)} procedure commands rc=0 (want 12)": len(rcs) == 12 and set(rcs) == {"0"},
    "probe before regen failed": len(probes) == 2 and probes[0][0] != "0",
    "probe after regen passed": len(probes) == 2 and probes[1][0] == "0",
    "parked: printed": re.search(r"^parked: ", run, re.M) is not None,
    "pip check clean": "No broken requirements found." in run,
    "5.29.6 upb": re.search(r"^5\.29\.6 upb$", run, re.M) is not None,
    "regen rerun already current": "already current" in run,
    "regen ok": re.search(r"^ok: .* imports on the default backend", run, re.M) is not None,
    "both suites end OK (skipped=1)": len(re.findall(r"^Ran \d+ tests.*\n\nOK \(skipped=1\)$", run, re.M)) == 2,
    "TypeError shown by the probe before regen": "TypeError" in run.split("l1 probe after regen")[0],
}
for k, v in checks.items():
    print(f"CHECK {'ok  ' if v else 'FAIL'} {k}")
ran = re.findall(r"^Ran (\d+) tests", run, re.M)
print("suite counts:", ran)
print(f"RESULT {'GREEN' if all(checks.values()) else 'RED'}")
sys.exit(0 if all(checks.values()) else 1)
PY
vrc=$?
echo "rc=$vrc" >> "$f"
grep -E '^(CHECK|RESULT|suite counts|rc=)' "$f"
exit $vrc
