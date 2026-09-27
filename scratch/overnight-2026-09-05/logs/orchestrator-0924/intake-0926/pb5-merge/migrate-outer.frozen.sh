#!/usr/bin/env bash
# p4_proxy/venv migration, protobuf 3.20.3 -> 5.29.6 (Adam's ruling I, 2026-09-27), run by the orchestrator.
# Step 0 and the guarded shell exactly as p4_proxy/requirements.txt (ab026ef0) prints them; the guarded
# shell reads HELPERS + steps 1-4 (inner-migrate.txt, the file's '#   $ ' lines, verbatim) from stdin,
# as the procedure's rehearsal fed them through a pipe. Step 5 (release) is run separately after the log
# is read. [Co-developed with claude code -- Adam]
cd /home/adam/Desktop/NDTwin-Kernel || exit 2
O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/pb5-merge
[ "$(git rev-parse --abbrev-ref HEAD)" = trunk ] || { echo "REFUSE: not on trunk"; exit 2; }
[ "$(git rev-parse HEAD^2 2>/dev/null)" = "$(git rev-parse fix/p4proxy-protobuf5-0927)" ] || { echo "REFUSE: trunk's head is not the pb5 merge"; exit 2; }
grep -qx 'protobuf==5.29.6' p4_proxy/requirements.txt && test -f p4_proxy/regen_p4runtime_pb2.py || { echo "REFUSE: the checkout does not carry the protobuf 5 file"; exit 2; }
cmp -s <(git show HEAD:p4_proxy/requirements.txt) p4_proxy/requirements.txt || { echo "REFUSE: requirements.txt differs from HEAD"; exit 2; }
echo "# $(date -u +%FT%TZ) trunk $(git rev-parse HEAD); old venv protobuf $(p4_proxy/venv/bin/python -c 'import google.protobuf as g; print(g.__version__)')"
export NDT_OWNER=p4-venv-migration NDT_MEASURING='p4_proxy venv migration: no runs, no gates'; [ -z "${LOCK:-}${TIMEOUT:-}" ] || echo "WARNING: LOCK='${LOCK:-}' TIMEOUT='${TIMEOUT:-}' are set: the guard uses them (another lock file locks nothing; TIMEOUT kills the shell) -- unset them unless you mean it"
tools/test_workflow/ndt claim 90 'p4_proxy venv migration' && JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh bash -i < "$O/inner-migrate.frozen.txt"
echo "# guarded shell rc=$? at $(date -u +%FT%TZ)"
