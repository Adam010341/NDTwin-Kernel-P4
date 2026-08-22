#!/usr/bin/env bash
# rebank_l4_ovs.sh -- P0-1 (d): recapture the L4 OVS reference at the fixed default.
#
# [Co-developed with claude code -- Adam]
#
# The banked baseline in .test_run/baseline/ovs was taken 2026-08-21 with a hand-set
# NDTWIN_RYU_SETTLE_S=60, because the committed default (10) produced a fabric whose twin could
# not see its own hosts. That workaround is what the settle work retired: the default is now 40
# and a 128-host boot comes up 128/128, 288 up / 0 down, n=3.
#
# A baseline captured under a hand-set environment variable is a baseline nobody can reproduce
# by running the documented command. Recapturing at the default is the point of this script.
#
# NO --traffic, deliberately. `--traffic` adds --with-traffic, which requires flows, paths and
# rates to be present -- and the 2026-08-21 ladder passed it with no generator running, so every
# flow-presence check failed by construction and L4 reported 48 differences that were the
# harness's own. Traffic-loaded contract runs are a separate round (they need NTG, which has a
# one-actor-at-a-time rule). What matters here is that the OVS reference and the P4 candidate
# are captured the SAME way; the stock-binary ladder that consumes this must also omit it.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_settle-gate-acceptance"
OUT="$DIR/rebank_l4.txt"
RL="$REPO/tools/test_workflow/run_layers.sh"
BASE="$REPO/.test_run/baseline/ovs"
RYU=http://localhost:8080
KERNEL=http://localhost:8000

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

if [[ -n "${NDTWIN_RYU_SETTLE_S:-}" ]]; then
    say "ABORT: NDTWIN_RYU_SETTLE_S='${NDTWIN_RYU_SETTLE_S}' is set."
    say "       The whole point is to capture at the DEFAULT. Unset it and re-run."
    exit 2
fi
say "# L4 OVS baseline recapture at the default settle"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# default in source: $(grep -oP 'NDTWIN_RYU_SETTLE_S", "\K[0-9]+' "$REPO/intelligent_router.py")"
say ""

# Keep the old capture rather than letting it be overwritten silently -- if the new one turns
# out worse, the comparison has to still be possible.
if [[ -d "$BASE" ]]; then
    stamp=$(date +%Y%m%d-%H%M%S)
    cp -r "$BASE" "$BASE.pre-rebank-$stamp"
    say "kept the settle=60-era capture at $(basename "$BASE.pre-rebank-$stamp")"
    say "  ($(ls "$BASE" | wc -l) files)"
fi
say ""

ndt down > /dev/null 2>&1
sleep 3
t0=$(date +%s)
if ! timeout 900 ndt up ovs > "$DIR/raw/rebank_up.out" 2>&1; then
    say "UP FAILED -- see raw/rebank_up.out"; tail -6 "$DIR/raw/rebank_up.out" | sed 's/^/  /' | tee -a "$OUT"
    exit 1
fi
say "boot: $(( $(date +%s) - t0 ))s at the default"

# Health gate BEFORE capturing. Banking a blind fabric as the reference is how the settle
# regression would have been baked into every future L4 comparison.
sleep 20   # past one kernel poll (5s cadence for its first 90s)
health=$(curl -sf --max-time 10 "$KERNEL/ndt/get_graph_data" | python3 -c "
import json,sys
g=json.load(sys.stdin); e=g.get('edges',[])
down=sum(1 for x in e if not x.get('is_up',True))
print(f'{len(e)},{down}')")
ryu=$(curl -sf --max-time 10 "$RYU/v1.0/topology/hosts" | python3 -c "
import json,sys
hs=json.load(sys.stdin); print(sum(1 for h in hs if h.get('ipv4')))")
say "health: ryu $ryu/128 with ipv4, kernel graph ${health%,*} edges / ${health#*,} down"

if [[ "$ryu" != "128" || "${health#*,}" != "0" ]]; then
    say "REFUSING TO BANK: this fabric is not healthy, and a bad reference is worse than none."
    ndt down > /dev/null 2>&1
    exit 1
fi
say ""

bash "$RL" baseline ovs >> "$OUT" 2>&1
rc=$?
say ""
say "run_layers baseline ovs exit: $rc"
say "captured $(ls "$BASE" 2>/dev/null | wc -l) files into .test_run/baseline/ovs"

ndt down > /dev/null 2>&1
say ""
say "done -> $OUT"
