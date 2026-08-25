#!/usr/bin/env bash
# verify_allowlist.sh -- P1-3 closeout acceptance: does the startup 404 now pass the contract test?
#
# [Co-developed with claude code -- Adam]
#
# The change under test is spec.py's get_path_switch_count entry gaining
# expect_status=[200, 404]. Before it, expect_status defaulted to [200] and the first query after
# bring-up failed with "HTTP status 404, expected 200".
#
# Two arms, because "it passes now" alone proves nothing -- it would also pass if the 404 simply
# did not occur on this boot:
#
#   after   spec.py as committed          -> must PASS, and must actually have seen a 404
#   before  expect_status forced to [200] -> must FAIL on exactly this endpoint
#
# The second arm is the mutation check: if it also passes, the 404 did not reproduce this run and
# NEITHER arm is evidence. That distinction is the whole point -- a green result whose cause you
# cannot name is not an acceptance.
#
# Each arm boots its own fabric, because the 404 is a first-query-after-boot transient: querying a
# fabric that has been up for minutes cannot exercise it.
set -uo pipefail

export NDT_OWNER=maindev-v3
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/verify_allowlist.txt"
CT="$REPO/tools/contract_test"
TOPO="$REPO/setting/StaticNetworkTopologyMininet_10Switches.json"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

say ""
say "# P1-3 acceptance: startup 404 vs the contract gate"
say "# date: $(date +%Y-%m-%dT%H:%M:%S%z)  commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)"

run_arm() {   # $1 = after|before
    local arm="$1"
    say ""
    say "=== arm: $arm ==="

    ndt down >/dev/null 2>&1; sleep 3
    local up_rc=0
    timeout 600 ndt up ovs > "$RAW/verify_${arm}_up.out" 2>&1 || up_rc=$?

    # A setup failure must not be a log line you scroll past. The first version of this script
    # only said "ndt up exited nonzero" and carried on -- and the `after` arm DID exit nonzero,
    # which means a reader had to take on trust that the 404 came from the startup transient
    # rather than from a broken fabric. Found by the post-commit shadow review of dd2ea62.
    #
    # Not a hard abort, because the observed nonzero was `XX kernel: 10 switches, 0 up, 0 enabled`
    # on a fabric whose graph matched (128 hosts / 288 edges) and whose data plane forwarded --
    # the known benign verify transient catalogued as HEALTHY-XX in the summoning round. Killing
    # the run on that would discard good arms. Instead the arm is CLASSIFIED, so the distinction
    # is in the artefact rather than in the reader's head.
    if (( up_rc != 0 )); then
        if grep -q "data plane: h1 -> 10.0.0.2 forwards" "$RAW/verify_${arm}_up.out" \
           && grep -q "kernel graph matches the model file" "$RAW/verify_${arm}_up.out"; then
            say "  ⚠️ setup=DEGRADED (ndt up rc=$up_rc) but graph matched and data plane forwards"
            say "     -> arm usable; the 404 is not attributable to a dead fabric"
        else
            say "  🔴 setup=BROKEN (ndt up rc=$up_rc), graph or forwarding failed"
            say "     -> ARM VOID: a 404 here proves nothing about the startup transient"
        fi
    else
        say "  setup=CLEAN (ndt up rc=0)"
    fi

    # Query IMMEDIATELY. The transient is the point; any delay here can silently make the run
    # meaningless, which is how this defect was first filed as "did not reproduce, n=1".
    local raw_status
    raw_status=$(curl -s -o "$RAW/verify_${arm}_gpsc.json" -w '%{http_code}' --max-time 10 \
        "http://localhost:8000/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.2" 2>/dev/null)
    say "  first direct query returned HTTP $raw_status"

    ( cd "$CT" && timeout 600 python3 run_contract_test.py \
        --url http://localhost:8000 --topology "$TOPO" ) \
        > "$RAW/verify_${arm}_contract.out" 2>&1
    local rc=$?

    local line
    line=$(grep -iE "get_path_switch_count" "$RAW/verify_${arm}_contract.out" | head -3)
    say "  contract rc=$rc"
    say "  ${line:-  (no get_path_switch_count line found)}"
    ndt down >/dev/null 2>&1
}

# --- arm 1: as committed --------------------------------------------------------------------
run_arm after

# --- arm 2: mutation -- force the old behaviour and require it to fail ----------------------
cp -f "$CT/spec.py" "$RAW/spec.py.bak"
# Narrow, reversible edit: only this endpoint's expect_status line.
sed -i 's/^         expect_status=\[200, 404\],$/         expect_status=[200],/' "$CT/spec.py"
if grep -q "expect_status=\[200\]," "$CT/spec.py"; then
    say ""
    say "# mutation applied: expect_status -> [200]"
else
    say "# 🔴 MUTATION DID NOT APPLY -- arm 2 would be meaningless; restoring and aborting"
    cp -f "$RAW/spec.py.bak" "$CT/spec.py"; exit 3
fi

run_arm before

cp -f "$RAW/spec.py.bak" "$CT/spec.py"
if git -C "$REPO" diff --quiet -- tools/contract_test/spec.py; then
    say "# spec.py restored: matches HEAD"
else
    say "# spec.py restored to the working-tree version (uncommitted changes present, expected)"
fi
say ""
say "# READ THIS BEFORE BELIEVING THE RESULT:"
say "#   valid   -> 'after' saw HTTP 404 and passed, 'before' saw 404 and failed on this endpoint"
say "#   invalid -> neither arm saw a 404; the transient did not occur and nothing was tested"
say "done -> $OUT"
