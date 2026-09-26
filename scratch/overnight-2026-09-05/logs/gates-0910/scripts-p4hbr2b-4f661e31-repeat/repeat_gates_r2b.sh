#!/usr/bin/env bash
# fix/hb-followups-r2-0927 (round 2b), REPEAT gate: the exact configuration that went red once
# (redfirst_r2b, 08 at HEAD not a clean PASS, output not kept) ten more times under the guard,
# every failing output kept. flake08_guard (20/20) and redfirst_r2b_keep (green) did not reproduce it. [Co-developed with claude code -- Adam]
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
S="$L/scripts-$TAG-$sha-repeat"; mkdir -p "$S/nolab"
cp "${BASH_SOURCE[0]}" "$SP/redfirst_r2b.sh" "$SP/redfirst_repeat.sh" "$SP/hbsnap.sha256" "$S/"
cp "$SP/nolab/sudo" "$SP/nolab/curl" "$S/nolab/"
( cd "$S" && sha256sum *.sh hbsnap.sha256 nolab/* > SHA256SUMS )
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
run redfirst_r2b_repeat 0 - "$TMP_LONG" env KEEP_ROOT="$SP/tmp/redfirst_repeat_$sha" bash "$S/redfirst_repeat.sh" 10 "$S/redfirst_r2b.sh" "$WT" "$SNAP" "$S/hbsnap.sha256"
run nolab_tripwire_repeat 0 - "$TMP_LONG" bash -c '
n_sudo=$(/usr/bin/grep -c " sudo " "$1"); n_lab=$(/usr/bin/grep -cE "localhost:(8000|8081)|127\.0\.0\.1:(8000|8081)" "$1")
echo "  ($(/usr/bin/grep -c "curl .* file://" "$1") file:// curls; nothing else recorded: $(/usr/bin/grep -vc "curl .* file://" "$1") other line(s))"
echo "NOLAB-TRIPWIRE: $n_sudo sudo call(s), $n_lab curl(s) at the lab endpoints (all refused)"
(( n_sudo == 0 && n_lab == 0 ))' _ "$NOLAB_LOG"
echo "REPEAT-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
