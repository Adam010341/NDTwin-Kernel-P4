#!/usr/bin/env bash
# rerun_contracts_corrected.sh -- L2-L4 again with the first run's two invocation bugs fixed.
#
# [Co-developed with claude code -- Adam]
#
# The first ladder run (l0_l4_run.txt) failed L2/L3/L4 for reasons that trace to THIS
# HARNESS'S INVOCATION, not to the fabric or the fast binary:
#   * TOPO_P4 was left at its 4-host default while the fabric ran 128 hosts, so every
#     graph-shape check compared a correct 128-host answer against the wrong declared file.
#   * --traffic was passed with no traffic generator running (on both planes), so every
#     flow-presence check failed by construction.
# This rerun sets TOPO_P4 to the 128-host file and drops --traffic. What remains red after
# this is the honest P4-plane gap list (allowlist candidates) plus anything actually
# attributable to the fast binary.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0821}"
export TOPO_P4=/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
REPO=/home/adam/Desktop/NDTwin-Kernel
OUT="$REPO/doc/audit/2026-08-21_l0-l4-fast-build/l2_l4_corrected.txt"
RL="$REPO/tools/test_workflow/run_layers.sh"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "# L2-L4 rerun, corrected invocation (TOPO_P4=128-host file, no --traffic)"
say "# date:   $(date -Is)"
say "# commit: $(cd "$REPO" && git rev-parse --short HEAD)"
say ""

ndt down > /tmp/rerun_down.out 2>&1 || { say "DOWN FAILED"; exit 1; }
sleep 2
if ! timeout 900 ndt up p4 128 > /tmp/rerun_up.out 2>&1; then
    say "P4 UP FAILED"; tail -5 /tmp/rerun_up.out | sed 's/^/  /' | tee -a "$OUT"; exit 1
fi
say "bmv2 binary actually running:"
for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$p" 2>/dev/null; echo; done \
  | grep -o '[^ ]*simple_switch_grpc' | sort | uniq -c | sed 's/^/  /' | tee -a "$OUT"

say ""
say "## api p4 (L2 + L3 + log check)"
bash "$RL" api p4 >> "$OUT" 2>&1
say "api exit: $?"

say ""
say "## baseline p4 (capture for L4)"
bash "$RL" baseline p4 >> "$OUT" 2>&1
say "baseline exit: $?"

say ""
say "## L4 compare (against the settle=60 OVS capture, both idle)"
bash "$RL" compare >> "$OUT" 2>&1
say "compare exit: $?"

ndt down >/dev/null 2>&1
say "corrected rerun complete -> $OUT"
