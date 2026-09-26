#!/usr/bin/env bash
# Worker pb5prep, phase 5: rehearse the ROLLBACK and ROLLBACK IN PLACE blocks of requirements.txt,
# on the stand-in phase 2 left (the new venv at V, the old one parked at OLD). Run after every
# phase that uses the new 3.13 venv, since the ROLLBACK moves it away.
#   ROLLBACK (verbatim) -> the old venv back at V; fp() must equal the fingerprint block 1 wrote.
#   [rehearsal] an in-place `pip install -r` on the restored old venv (the upgrade the procedure
#   warns against) -> the l1 probe must fail; regen_p4runtime_pb2.py (the repair the header names)
#   -> 5.29.6 upb.
#   ROLLBACK IN PLACE (verbatim) -> 3.20.3 python, with the regen tool probed after grpcio-tools is
#   uninstalled (refusal path, rc 2) and at the end (protobuf-3.x no-op path, rc 0); pip check; the
#   freeze compared with the old venv's.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
cd "$WT" || exit 2
[[ -f "$W/rehearsal-$SHA.vars" ]] || { echo "REFUSE: no $W/rehearsal-$SHA.vars (phase 2 not run)"; exit 2; }
git show HEAD:p4_proxy/requirements.txt > "$W/requirements.HEAD.rollback.txt"
gen="$W/rehearsal_rollback.gen.sh"
python3 "$S/gen_rehearsal.py" "$W/requirements.HEAD.rollback.txt" rollback "$W/rehearsal-$SHA.vars" "$gen" || exit 2
f=$(new_log rehearsal_rollback "the procedure's ROLLBACK and ROLLBACK IN PLACE blocks run verbatim on the stand-in, through JOBS=1 LOCK_WAIT=10800 guarded_build.sh") || exit 2
{ echo "# vars: $(tr '\n' ' ' < "$W/rehearsal-$SHA.vars")"
  echo "# requirements.txt @ HEAD sha256 $(sha256sum < "$W/requirements.HEAD.rollback.txt" | cut -c1-64)"
  echo "# generated script $gen sha256 $(sha256sum < "$gen" | cut -c1-64); its text:"
  sed 's/^/#| /' "$gen"; echo "# ---- run ----"; } >> "$f"
( JOBS=1 LOCK_WAIT=10800 "$GUARD" bash "$gen" ) >> "$f" 2>&1
grc=$?
python3 - "$f" "$grc" >> "$f" <<'PY'
import re, sys
log, grc = open(sys.argv[1]).read(), int(sys.argv[2])
run = log.split("# ---- run ----", 1)[1]
rb, rest = run.split("### [rehearsal] in-place upgrade", 1)
inpl, rbi = rest.split("### ROLLBACK IN PLACE", 1)
def rcs(t): return re.findall(r"^\[rc=(\d+)\]$", t, re.M)
probes = re.findall(r"^\[rehearsal probe rc=(\d+)\] \(want ([^)]*)\)", run, re.M)
extra = re.findall(r"^\[rehearsal rc=(\d+)\] \(want (\d+)\)", run, re.M)
checks = {
    "guard exit 0": grc == 0,
    "fp() defined + ROLLBACK's 2 commands rc=0": rcs(rb) == ["0", "0", "0"],
    "old venv restored unchanged": "old venv restored unchanged" in rb,
    "restored venv is 3.20.3 python": re.search(r"^3\.20\.3 python$", rb, re.M) is not None,
    "restored venv's pip runs from V": re.search(r"^pip \S+ from \S*/scratch/pb5prep/rehearsal-[0-9a-f]{8}/p4_proxy/venv/", rb, re.M) is not None,
    "in-place pip install -r and regen rc=0": rcs(inpl) == ["0", "0"],
    "in-place: probe failed before regen (TypeError)": "Descriptors cannot be created directly" in inpl
        and any(p[0] != "0" and p[1].startswith("nonzero") for p in probes),
    "in-place: 5.29.6 upb after regen": re.search(r"^5\.29\.6 upb$", inpl, re.M) is not None,
    "ROLLBACK IN PLACE's 4 commands rc=0": rcs(rbi) == ["0", "0", "0", "0"],
    "ROLLBACK IN PLACE ends on 3.20.3 python": re.search(r"^3\.20\.3 python", rbi, re.M) is not None,
    "regen with grpcio-tools gone: rc 2": len(extra) >= 1 and extra[0] == ("2", "2"),
    "regen on protobuf 3.x: rc 0, nothing to regenerate": len(extra) >= 2 and extra[1] == ("0", "0")
        and "nothing to regenerate" in rbi,
    "pip check clean at the end": "No broken requirements found." in rbi,
}
for k, v in checks.items():
    print(f"CHECK {'ok  ' if v else 'FAIL'} {k}")
print(f"RESULT {'GREEN' if all(checks.values()) else 'RED'}")
sys.exit(0 if all(checks.values()) else 1)
PY
vrc=$?
echo "rc=$vrc" >> "$f"
grep -E '^(CHECK|RESULT|rc=)' "$f"
exit $vrc
