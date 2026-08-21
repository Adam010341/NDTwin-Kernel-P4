#!/usr/bin/env bash
# Sweep install_all_pair_paths across model sizes on one constant fabric.
#
# [Co-developed with claude code -- Adam]
#
# The walk is driven by the MODEL, not by the fabric: install_all_pair_paths(self.static_net)
# walks a graph built entirely from the topology JSON, and the only thing it takes from the
# live fabric is self.switches -- ten datapaths, the same in every cell here. So sweeping the
# model while `ovs-topo-start` builds its fixed 128-host NTG fabric holds the noise floor
# constant and varies exactly one thing.
#
# 4 hosts is deliberately NOT in this sweep: `ndt up ovs 4` dispatches to a different fabric
# (ovs-topo-4host), so its cell would change two variables at once. Run it separately and label
# it as a different fabric.
#
# Commands live in a file rather than on the command line because a `pgrep`/`pkill` pattern
# typed at a prompt matches the shell running it -- three times in one day, 2026-08-20.
set -uo pipefail

# Every ndt call needs this, not just `claim`. Without it `foreign_claim` treats your OWN claim
# as somebody else's and `ndt down` refuses -- correctly, by its own rule, but the refusal
# message points at `--force` rather than at the variable, and taking that advice would tear
# down a lab somebody else really was holding. Exported once here so no cell can forget it.
export NDT_OWNER="${NDT_OWNER:-maindev-0821}"

REPO=/home/adam/Desktop/NDTwin-Kernel
OUT="$REPO/doc/audit/2026-08-21_ryu-topology-scaling/walk_sweep.txt"
LOG="$REPO/.test_run/logs/ryu.log"
SIZES="${*:-8 16 32 64 128}"

: > "$OUT"
{
    echo "# install_all_pair_paths walk sweep"
    echo "# date:   $(date -Is)"
    echo "# commit: $(cd "$REPO" && git rev-parse --short HEAD)"
    echo "# fabric: ovs-topo-start (NTG testbed_topo.py, fixed 128 hosts) for every cell"
    echo "# note:   the model varies; the fabric does not. See the header comment."
    echo
} >> "$OUT"

for n in $SIZES; do
    echo "=== $n hosts ===" | tee -a "$OUT"

    # Checked, not fired and forgotten. The first run of this script swallowed `ndt down`'s
    # output and its exit code, so a refused teardown left the previous fabric up and every
    # later cell failed with "a Mininet is already running" -- four wasted cells reported as
    # four separate failures rather than as the one that actually happened.
    if ! ndt down > /tmp/ndt_down_$n.out 2>&1; then
        echo "  DOWN FAILED before the $n-host cell; stopping" | tee -a "$OUT"
        tail -5 /tmp/ndt_down_$n.out | sed 's/^/    /' | tee -a "$OUT"
        exit 1
    fi
    sleep 2

    if ! timeout 600 ndt up ovs "$n" > /tmp/ndt_up_$n.out 2>&1; then
        echo "  UP FAILED (see /tmp/ndt_up_$n.out)" | tee -a "$OUT"
        tail -5 /tmp/ndt_up_$n.out | sed 's/^/    /' | tee -a "$OUT"
        continue
    fi

    # What the fabric actually is, independent of what ndt reported. 10 switches means 32
    # inter-switch ports, so host ports = total - 32.
    ifaces=$(ls /sys/class/net | grep -c '^s[0-9]*-eth')
    fabric_hosts=$(( ifaces - 32 ))
    echo "  fabric hosts (from veth count): $fabric_hosts" | tee -a "$OUT"

    grep "install_all_pair_paths done" "$LOG" | sed 's/^/  /' | tee -a "$OUT"
    grep -c "install_all_pair_paths done" "$LOG" \
        | sed 's/^/  walks logged: /' | tee -a "$OUT"
    echo | tee -a "$OUT"
done

ndt down >/dev/null 2>&1
echo "sweep complete -> $OUT"
