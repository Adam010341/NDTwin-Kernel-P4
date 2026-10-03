#!/usr/bin/env bash
# gates_b9.sh -- extb9: feat/external-detect-only-0927 after the settled() fix (iperf's server total). The gates
# that run or read live-p1/external_evidence.py, on B's head: its suite, its mutation gate, the anchor check, the
# survey of the 34 frozen rounds, and the new suite against 9b5c0607's tool (expected red: rc 1).
# One guard per gate (JOBS=1 LOCK_WAIT=10800); disk floor 1536 MB before queueing and again under the lock;
# extb8's nolab shims on PATH. Each log: first line the full sha, last `# rc=<n>`.
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
D=$L/extb9
GUARD=$W/tools/build_guard/guarded_build.sh
LP=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
sha=$(git -C $W rev-parse --short=8 HEAD); full=$(git -C $W rev-parse HEAD)
TAG=extb9
export TMPDIR=$D/tmp; mkdir -p "$TMPDIR"
unset NDT_MEASURING
bash $D/make_shims.sh $D/shims > /dev/null; : > $D/tripwire.log
SHIMPATH="$D/shims:$PATH"
FLOOR_MB=1536
free_mb() { df --output=avail -BM / | tail -1 | tr -dc 0-9; }
fail=0
run() {   # run <name> <expected rc> <cmd...>
    local name="$1" want="$2" log="$L/$1.$TAG-$sha.log" rc; shift 2
    [[ -e "$log" ]] && { echo "REFUSE: $log exists"; exit 2; }
    (( $(free_mb) >= FLOOR_MB )) || { echo "DISK-FLOOR: $(free_mb) MB before $name -- stopping"; exit 97; }
    [[ "$(git -C $W rev-parse HEAD)" == "$full" && -z "$(git -C $W status --porcelain | grep -v '^??')" ]] || { echo "REFUSE: HEAD moved or tracked files changed"; exit 3; }
    { echo "$full"; echo "# $(date -u +%FT%TZ) cwd $W TMPDIR $TMPDIR via guard-nolab JOBS=1 LOCK_WAIT=10800; disk $(free_mb) MB, floor $FLOOR_MB MB"
      echo "# cmd $*"; [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want"; } > "$log"
    ( cd $W && PATH="$SHIMPATH" NOLAB_LOG=$D/tripwire.log NOLAB_SUITE=$name NOLAB_PASS=$TAG NOLAB_FAKE_FABRIC=0 \
        JOBS=1 LOCK_WAIT=10800 "$GUARD" bash -c \
        'a=$(df --output=avail -BM / | tail -1 | tr -dc 0-9); echo "# disk under the lock: $a MB free"; (( a >= $0 )) || { echo "DISK-FLOOR: $a MB < $0 MB -- not run"; exit 97; }; exec "$@"' \
        "$FLOOR_MB" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-34s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" "$(grep -vE '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-140)"
    (( rc == 97 )) && { echo "DISK-FLOOR under the lock at $name -- stopping"; exit 97; }
    [[ "$rc" == "$want" ]] || fail=1
}
# 9b5c0607's tool, beside its own code_identity.py and survey, for the red-first run
OLD=$D/old-9b5c0607; rm -rf "$OLD"; mkdir -p "$OLD"
for f in external_evidence.py code_identity.py external_survey.py external_survey_34.tsv; do git -C $W show 9b5c0607:$LP/$f > "$OLD/$f"; done
run redfirst_b9 1 env EVIDENCE_UNDER_TEST=$OLD/external_evidence.py bash tests/shell/test_live_p1_external_evidence.sh
run test_live_p1_external_evidence 0 bash tests/shell/test_live_p1_external_evidence.sh
run survey_34 0 env PYTHONDONTWRITEBYTECODE=1 python3 $LP/external_survey.py /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep
run check_gate_anchors 0 python3 tests/shell/check_gate_anchors.py "$sha"
run mutate_live_p1_external_evidence 0 bash tests/shell/mutate_live_p1_external_evidence.sh
rm -rf "$OLD"
echo "tripwire lines: $(wc -l < $D/tripwire.log)"
echo "GATES-$TAG $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
