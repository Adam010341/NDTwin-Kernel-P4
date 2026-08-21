#!/usr/bin/env bash
# l0_l4_fast_build.sh -- B2 (3)'s acceptance gate: the whole L0-L4 ladder on the fast bmv2.
#
# [Co-developed with claude code -- Adam]
#
# The promotion criterion written on the 8/20 slide is "L0-L4 passes on the fast build" --
# upstream's own build-behavioral-model.sh warns the fast flag set "cannot be used to achieve
# passing results on all p4c tests", so the ladder run IS the evidence, not a formality.
#
# Two boots:
#   1. OVS at NDTWIN_RYU_SETTLE_S=60, to capture the L4 reference (.test_run/baseline/ovs was
#      empty -- no reference has ever been captured on this machine). settle=60 because the
#      committed settle=10 default has a known regression: Ryu learns no host IPv4s, the
#      kernel graph reports 256 host edges down, and a baseline captured in that state would
#      bake the regression into the L4 reference. 60 is the bring-up session's verified-good
#      configuration (their report: 128/128 hosts, 288 up / 0 down).
#   2. P4 at 128 hosts on the fast bmv2 (the configured binary -- identity printed from the
#      running processes, not from the config), then `run_layers.sh full p4 --traffic`:
#      L0 build, L1 units, L2 API contract, L3 component contract, log allowlist, capture,
#      L4 OVS/P4 differential.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0821}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-21_l0-l4-fast-build"
OUT="$DIR/l0_l4_run.txt"
RL="$REPO/tools/test_workflow/run_layers.sh"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "# L0-L4 on the fast bmv2 build (B2 (3) acceptance gate)"
say "# date:   $(date -Is)"
say "# commit: $(cd "$REPO" && git rev-parse --short HEAD)"
say ""

say "## 1. OVS baseline capture (settle=60, see header)"
ndt down > /tmp/l4_down1.out 2>&1 || { say "DOWN FAILED"; exit 1; }
sleep 2
if ! env NDTWIN_RYU_SETTLE_S=60 timeout 900 ndt up ovs > /tmp/l4_up_ovs.out 2>&1; then
    say "OVS UP FAILED (/tmp/l4_up_ovs.out)"; tail -5 /tmp/l4_up_ovs.out | sed 's/^/  /' | tee -a "$OUT"
    exit 1
fi
say "  ovs up; kernel graph state (the regression check):"
# The graph's key is `edges`, not `links`. The first run of this script read the wrong key
# and printed "links 0 total, 0 down" -- a vacuous check on an empty default that LOOKS
# clean, which is the worst failure mode a regression check can have. The healthy verdict
# for that run rests on counting the banked capture itself
# (.test_run/baseline/ovs/get_graph_data.json: 288 edges, 0 down, 128 hosts with IPs),
# done independently twice. Caught by the review session; fixed here.
curl -sf --max-time 10 http://localhost:8000/ndt/get_graph_data 2>/dev/null \
  | python3 -c "
import json,sys
try: g=json.load(sys.stdin)
except Exception: print('    (graph endpoint unreadable)'); sys.exit()
e=g.get('edges',[]); down=[x for x in e if not x.get('is_up',True)]
with_ip=sum(1 for x in e if x.get('dst_ip'))
print(f'    edges {len(e)} total, {len(down)} down, {with_ip} with dst_ip')
if not e: print('    WARNING: zero edges -- either the fabric is empty or this parser is wrong; do not read as clean')" | tee -a "$OUT"

if ! bash "$RL" baseline ovs --traffic >> "$OUT" 2>&1; then
    say "  OVS BASELINE CAPTURE FAILED -- L4 will be skipped; continuing to P4 ladder anyway"
fi

say ""
say "## 2. P4 full ladder on the fast build"
ndt down > /tmp/l4_down2.out 2>&1 || { say "DOWN FAILED"; exit 1; }
sleep 2
if ! timeout 900 ndt up p4 128 > /tmp/l4_up_p4.out 2>&1; then
    say "P4 UP FAILED (/tmp/l4_up_p4.out)"; tail -5 /tmp/l4_up_p4.out | sed 's/^/  /' | tee -a "$OUT"
    exit 1
fi
# Name the binary from the running processes, not the config (benchmark-must-name-the-binary).
say "  bmv2 binary actually running:"
for p in /proc/[0-9]*/cmdline; do
    tr '\0' ' ' < "$p" 2>/dev/null
    echo
done | grep -o '[^ ]*simple_switch_grpc' | sort | uniq -c | sed 's/^/    /' | tee -a "$OUT"
say "  manifest (if placed):"
cat /usr/local/bmv2-fast/BUILD-MANIFEST 2>/dev/null | sed 's/^/    /' | tee -a "$OUT" \
  || say "    (no BUILD-MANIFEST at prefix -- backfill still pending Adam's sudo)"

bash "$RL" full p4 --traffic >> "$OUT" 2>&1
rc=$?
say ""
say "run_layers full p4 exit code: $rc"

ndt down >/dev/null 2>&1
say "ladder complete -> $OUT"
