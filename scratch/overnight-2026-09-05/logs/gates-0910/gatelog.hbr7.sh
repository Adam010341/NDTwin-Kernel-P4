#!/usr/bin/env bash
# gatelog.sh <log file> <command...> -- run <command> in the r7 worktree under
# env -u SELFTEST_PROBE_SUDO -u FAULTS_TC; line 1 = the full sha tested, last line = its real rc.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hb-spike-r7-0926
log="$1"; shift
cd "$WT" || exit 99
{
    git rev-parse HEAD
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) worktree $WT, branch $(git rev-parse --abbrev-ref HEAD)"
    echo "# status (uncommitted): $(git status --porcelain | paste -sd' ')"
    echo "# run under: env -u SELFTEST_PROBE_SUDO -u FAULTS_TC, cwd $WT"
    echo "# \$ $*"
} > "$log"
env -u SELFTEST_PROBE_SUDO -u FAULTS_TC "$@" >> "$log" 2>&1
rc=$?
echo "# rc=$rc  $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
echo "rc=$rc -> $log"
exit 0
