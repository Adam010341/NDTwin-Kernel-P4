#!/usr/bin/env bash
# leftovers.sh -- raw evidence that nothing of this round is left: every live process whose
# environment carries the signal test's token (pid, comm, cmdline), every .spawn-gate-* copy in the
# worktree and the scratch trees, and every temp tree the signal test or the four /tmp suites would
# leave, with its owner and age. [Co-developed with claude code -- Adam]
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/traps
echo "## processes carrying NDT_SIGNAL_TEST_TOKEN= (pid comm cmdline):"
n=0
for f in $(grep -alsF -- "NDT_SIGNAL_TEST_TOKEN=" /proc/[0-9]*/environ 2>/dev/null); do
    p="${f#/proc/}"; p="${p%/environ}"; n=$((n+1))
    echo "  $p $(cat /proc/$p/comm 2>/dev/null) $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-150)"
done
echo "  count: $n"
echo "## .spawn-gate-* copies:"
m="$(find "$WT/tests/shell" "$SP" -name '.spawn-gate-*' 2>/dev/null)"; echo "${m:-  (none)}"; echo "  count: $(grep -c . <<<"$m")"
echo "## temp trees (the signal test's own, and the /tmp suites' prefixes), owner and mtime:"
t="$(ls -ld --time-style=+%FT%T /tmp/ndt-signal-ends-run-* /tmp/ndt-app-orphans-* /tmp/ndt-apps-liveness-* /tmp/ndtwin-lab-sweep-* /tmp/faults-topo-pid-* /tmp/ndt-helper-window-* /tmp/ndt-ovs-claim-* /tmp/ndt-down-ours-* 2>/dev/null)"
echo "${t:-  (none)}"; echo "  count: $(grep -c . <<<"$t")"
