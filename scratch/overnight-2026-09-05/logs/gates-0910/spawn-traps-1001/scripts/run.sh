#!/usr/bin/env bash
# run.sh <log-name> <dir> <command...> -- run one command from <dir> (the worktree or a scratch tree)
# under the build guard (JOBS=1, its own lock: nothing here builds) with the nolab sudo/curl tripwire
# first on PATH (and EXTRA_PATH before it, if set). Log: line 1 the worktree HEAD, line 2 its
# porcelain count, then the tree, the sha256 of each argument that is a file in <dir>, the
# tripwire count, the output, last line rc=<n>.
# [Co-developed with claude code -- Adam]
set -uo pipefail
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001
log="$L/$1"; dir="$2"; shift 2
{
    git -C "$WT" rev-parse HEAD
    echo "porcelain-lines: $(git -C "$WT" status --porcelain | wc -l)"
    echo "# dir: $dir$([[ -f "$dir/.tree-id" ]] && echo " = $(cat "$dir/.tree-id")")"
    for a in "$@"; do [[ -f "$dir/$a" ]] && echo "# sha256 $(cd "$dir" && sha256sum "$a")"; done
    [[ -n "${EXTRA_PATH:-}" ]] && echo "# EXTRA_PATH=$EXTRA_PATH (first on PATH)"
    echo "# tripwire lines before: $(wc -l < "$L/tripwire.log")"
    echo "# \$ $*"
    echo "# started $(date -Is)"
    cd "$dir" || exit 99
    PATH="${EXTRA_PATH:+$EXTRA_PATH:}$L/nolab:$PATH" JOBS=1 LOCK=/tmp/claude-1000/spawn-traps-1001.lock LOCK_WAIT=10800 \
        /home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh "$@"
    rc=$?
    echo "# ended $(date -Is); tripwire lines after: $(wc -l < "$L/tripwire.log")"
    echo "rc=$rc"
} > "$log" 2>&1 </dev/null
tail -1 "$log"
