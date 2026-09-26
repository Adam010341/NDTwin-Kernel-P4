#!/usr/bin/env bash
# fix/hb-followups-r2-0927 (round 2b): every gate on the worktree's HEAD. [Co-developed with claude code -- Adam]
# Each through guarded_build (JOBS=1 LOCK_WAIT=10800) into logs/gates-0910/<gate>.p4hbr2b-<sha8>.log:
# first line the full sha, last line `# rc=<n>`. The scripts that run are the copies in
# logs/gates-0910/scripts-p4hbr2b-<sha8>/ (with their sha256).
# 🔴 NO LAB CONTACT: PATH starts with a sudo that records and refuses and a curl that records and
# refuses the lab's :8000/:8081 (found this round: test_live_p1_common's 5e cells start a real
# iperf in a live fabric); the tripwire log is itself the last gate.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hb-followups-r2-0927
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
TAG=p4hbr2b
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
S="$L/scripts-$TAG-$sha"; mkdir -p "$S/nolab"
cp "${BASH_SOURCE[0]}" "$SP/redfirst_r2b.sh" "$SP/embedded_sweep2.py" "$SP/embedded_cover2.py" \
   "$SP/cover_run2.sh" "$SP/runtime_check2.sh" "$SP/hbsnap.sha256" "$S/"
cp "$SP/nolab/sudo" "$SP/nolab/curl" "$S/nolab/"
( cd "$S" && sha256sum *.sh *.py hbsnap.sha256 nolab/* > SHA256SUMS )
export PATH="$S/nolab:$PATH" NOLAB_LOG="$S/nolab/tripwire.log"
unset SELFTEST_PROBE_SUDO NDT_MEASURING
: > "$NOLAB_LOG"
SNAP="$SP/tmp/hbsnap"
TMP_LONG="$SP/tmp"; mkdir -p "$TMP_LONG"
TMP_SHORT=/tmp/claude-1000/nd6e0a; mkdir -p "$TMP_SHORT"   # test_ndt_serve: short and real (see the ndtserve round)
fail=0
run() {   # run <gate> <expected rc> <why, or -> <TMPDIR> <cmd...>
    local name="$1" want="$2" why="$3" tmp="$4" log="$L/$1.$TAG-$sha.log" rc
    shift 4
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then echo "REFUSE: HEAD moved or tracked files changed"; exit 3; fi
    { echo "$full"; echo "# worktree $WT  $(date -u +%FT%TZ)"; echo "# cwd $WT  TMPDIR $tmp"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; echo "# PATH starts $S/nolab (sudo refused, lab curl refused)"
      [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$WT" && TMPDIR="$tmp" JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-24s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: |^files restored' "$log" | tail -1 | cut -c1-150)"
    [[ "$rc" == "$want" ]] || fail=1
}
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
SPIKE=doc/audit/2026-09-25_p4-heartbeat/spike
FILES5=("$LIVE/08_heartbeat.sh" "$LIVE/07_roles_basic.sh" "$LIVE/_common.sh" "$SPIKE/S_heartbeat_spike.sh" "$SPIKE/oldcode_selftest.sh")
run live08_selftest 0 - "$TMP_LONG" bash "$LIVE/08_heartbeat.sh" --self-test
run live07_selftest 0 - "$TMP_LONG" env SELFTEST_HB_RUN="$SNAP/run" SELFTEST_HB_PKGS="$SNAP/pkgs" \
    bash "$LIVE/07_roles_basic.sh" --self-test
run redfirst_r2b 0 - "$TMP_LONG" bash "$S/redfirst_r2b.sh" "$WT" "$SNAP" "$S/hbsnap.sha256"
run mutate_p4_heartbeat_w 0 - "$TMP_LONG" bash tests/shell/mutate_p4_heartbeat_w.sh
run mutate_roles_binding 0 - "$TMP_LONG" bash tests/shell/mutate_roles_binding.sh
run check_gate_anchors 0 - "$TMP_LONG" python3 tests/shell/check_gate_anchors.py "$sha"
run test_ndt_serve 0 - "$TMP_SHORT" python3 tests/python/test_ndt_serve.py -v
run test_ndt_serve_cells 0 - "$TMP_SHORT" python3 tests/python/test_ndt_serve_cells.py -v
run mutate_ndt_serve 0 - "$TMP_SHORT" bash tests/shell/mutate_ndt_serve.sh
run embedded_compile 0 - "$TMP_LONG" python3 "$S/embedded_sweep2.py" --strict --py /usr/bin/python3 \
    --py "$WT/p4_proxy/venv/bin/python" "${FILES5[@]}"
run embedded_cover 0 - "$TMP_LONG" env SELFTEST_HB_RUN="$SNAP/run" SELFTEST_HB_PKGS="$SNAP/pkgs" \
    bash "$S/cover_run2.sh" "$WT" "$SP/tmp/cover_$sha" "$S/embedded_cover2.py"
run runtime_check 0 - "$TMP_LONG" bash "$S/runtime_check2.sh" "$WT"
# every row no self-test executed is one runtime_check ran
run runtime_covers_not 0 - "$TMP_LONG" python3 -c '
import re, sys
cover, rt = open(sys.argv[1]).read(), open(sys.argv[2]).read()
nots = {f"{m.group(1)}:{m.group(2)}" for m in re.finditer(r"^  (\S+)\s+(\d+) \S+\s+NOT ", cover, re.M)}
covered = set(re.search(r"^COVERED: (.*)$", rt, re.M).group(1).split())
print("NOT executed by a self-test:", " ".join(sorted(nots)))
print("run by runtime_check:       ", " ".join(sorted(covered)))
left = sorted(nots - covered)
print("RUNTIME-COVERS-NOT:", "every NOT row ran in runtime_check" if not left else "NOT RUN ANYWHERE: " + " ".join(left))
sys.exit(1 if left or not nots <= covered else 0)' "$L/embedded_cover.$TAG-$sha.log" "$L/runtime_check.$TAG-$sha.log"
rm -rf "${TMP_SHORT:?}"/*
run nolab_tripwire 0 - "$TMP_LONG" bash -c '
echo "calls the gates above made through the nolab shims:"; sed "s/^/  /" "$1"
n_sudo=$(/usr/bin/grep -c " sudo " "$1"); n_lab=$(/usr/bin/grep -cE "localhost:(8000|8081)|127\.0\.0\.1:(8000|8081)" "$1")
echo "NOLAB-TRIPWIRE: $n_sudo sudo call(s), $n_lab curl(s) at the lab endpoints (all refused)"
(( n_sudo == 0 && n_lab == 0 ))' _ "$NOLAB_LOG"
echo "FINAL-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
