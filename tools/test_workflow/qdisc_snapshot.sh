#!/usr/bin/env bash
#
# qdisc_snapshot.sh -- assertable before/after snapshots of every interface's qdisc tree.
#
# [Co-developed with claude code -- Adam]
#
# Born from the 2026-08-13 overnight OVS round: `tc qdisc add dev X root netem` does not stack
# a layer, it silently REPLACES TCLink's htb -- shaping gone, and `tc qdisc del dev X root`
# restores the kernel default, not htb. The usual teardown check ("netem residue = 0") is
# blind to that damage, and the NOPASSWD grants cannot put htb back. A full-tree snapshot
# diff turns the injection tool's own side effects into something a run can assert on.
#
# Usage, wrapped around any fault-injection round:
#     tools/test_workflow/qdisc_snapshot.sh save /tmp/qdisc.before
#     ... tc netem on/off, power cycles, the whole round ...
#     tools/test_workflow/qdisc_snapshot.sh diff /tmp/qdisc.before   # exit 1 on any drift
#
# QDISC_SNAPSHOT_TC overrides the tc binary (the tests' seam; also handy for `ip netns exec`).

set -uo pipefail

usage() { echo "usage: $0 {save|diff} <snapshot-file>" >&2; exit 2; }

snap() { ${QDISC_SNAPSHOT_TC:-tc} qdisc show 2>/dev/null | LC_ALL=C sort; }

cmd="${1:-}"
file="${2:-}"
[[ -n "$cmd" && -n "$file" ]] || usage

case "$cmd" in
    save)
        snap > "$file"
        echo "saved $(wc -l < "$file") qdisc lines -> $file"
        ;;
    diff)
        [[ -f "$file" ]] || { echo "no snapshot to compare against: $file" >&2; exit 2; }
        if drift="$(diff -u "$file" <(snap))"; then
            echo "qdisc state unchanged ($(wc -l < "$file") lines)"
        else
            echo "$drift"
            echo "QDISC STATE CHANGED since the snapshot -- an injection left residue or" >&2
            echo "replaced a root qdisc (see doc/2026-07-29_environment_gotchas.md, htb entry)." >&2
            exit 1
        fi
        ;;
    *)
        usage
        ;;
esac
