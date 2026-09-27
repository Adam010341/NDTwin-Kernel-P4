#!/usr/bin/env bash
# live-accept.sh -- ruling I's acceptance: a live 01 and 06 on trunk 5dc7fc9a (protobuf 5 merged) with the
# development machine's p4_proxy/venv migrated to 5.29.6 (the default P4_PROXY_PY; nothing overridden).
# Records the venv's identity beside the raw (judge note 12: the stack changed; never mix before/after).
# The live scripts claim and release the lab themselves. Workers paused throughout.
# [Co-developed with claude code -- Adam]
set -u
G=/home/adam/Desktop/NDTwin-Kernel; L=$G/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/pb5-merge
D=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
cd "$G" || exit 9
export NDT_OWNER=orch-0927
unset L1_POLL_S SELFTEST_HB_RUN SELFTEST_HB_PKGS SELFTEST_PROBE_SUDO P4_PROXY_PY PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION PYTHONPATH
say() { echo "== $(date '+%F %T %z') $*"; }
[[ "$(git rev-parse HEAD)" == 5dc7fc9a657cf58b12729ec14e2ead02f7afdab5 ]] || { say "REFUSE: HEAD is $(git rev-parse --short HEAD)"; exit 2; }
V=$G/p4_proxy/venv
id="$("$V/bin/python" -c 'import google.protobuf as g, p4.v1.p4runtime_pb2; from google.protobuf.internal import api_implementation as a; print(g.__version__, a.Type())')"
[[ "$id" == "5.29.6 upb" ]] || { say "REFUSE: venv says '$id', not 5.29.6 upb"; exit 2; }
"$V/bin/python" -m pip freeze --all > "$L/venv-after.freeze"
(cd "$V" && { find . -mindepth 1 -printf '%y %p %l\n'; find . -type f -exec sha256sum {} +; } | LC_ALL=C sort | sha256sum | cut -c1-64) > "$L/venv-after.fingerprint"
say "trunk $(git rev-parse HEAD); venv $id; fingerprint $(cat "$L/venv-after.fingerprint" | cut -c1-16); helper $(sha256sum /usr/local/sbin/ndtwin-lab | cut -c1-16); disk $(df -h / | awk 'NR==2{print $4}')"
cat p4_proxy/mininet/host_count_override > "$L/knob-before.txt" 2>&1
tools/test_workflow/ndt status > "$L/status-before.txt" 2>&1
say "start 01"; bash "$D/01_baseline.sh" > "$L/01.log" 2>&1; rc1=$?; say "end 01 rc=$rc1 last: $(tail -1 "$L/01.log")"
say "01 run dir: $(ls -d "$G/$D"/runs/*_01_baseline | tail -1)"
say "start 06"; bash "$D/06_thirteen.sh" > "$L/06.log" 2>&1; rc6=$?; say "end 06 rc=$rc6 last: $(tail -1 "$L/06.log")"
say "06 run dir: $(ls -d "$G/$D"/runs/*_06_thirteen | tail -1)"
tools/test_workflow/ndt status > "$L/status-after.txt" 2>&1; sed -n 2,4p "$L/status-after.txt"
cat p4_proxy/mininet/host_count_override > "$L/knob-after.txt" 2>&1
cmp -s "$L/knob-before.txt" "$L/knob-after.txt" && say "knob unchanged ($(cat "$L/knob-after.txt"))" || say "🔴 knob CHANGED"
(cd "$V" && { find . -mindepth 1 -printf '%y %p %l\n'; find . -type f -exec sha256sum {} +; } | LC_ALL=C sort | sha256sum | cut -c1-64) > "$L/venv-after-live.fingerprint"
cmp -s "$L/venv-after.fingerprint" "$L/venv-after-live.fingerprint" && say "venv fingerprint unchanged by the live runs" || say "venv fingerprint CHANGED by the live runs (byte-code?)"
say "DONE rc01=$rc1 rc06=$rc6"
