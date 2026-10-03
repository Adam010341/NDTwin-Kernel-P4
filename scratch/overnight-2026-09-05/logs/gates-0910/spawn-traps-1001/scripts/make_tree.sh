#!/usr/bin/env bash
# make_tree.sh <rev> <dir> [<published-path>=<source-file>]... -- a full copy of <rev>'s tracked
# tree (git archive) at <dir>, never the worktree itself, with each listed file copied in over it.
# Records what it holds in <dir>/.tree-id. [Co-developed with claude code -- Adam]
set -euo pipefail
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001
rev="$1"; dir="$2"; shift 2
[[ "$dir" == /tmp/claude-1000/*/scratchpad/traps/* ]] || { echo "refusing a tree outside the scratchpad: $dir"; exit 2; }
rm -rf "$dir"; mkdir -p "$dir"
git -C "$WT" archive "$rev" | tar -x -C "$dir"
id="$(git -C "$WT" rev-parse "$rev")"
for kv in "$@"; do
    cp "${kv#*=}" "$dir/${kv%%=*}"
    id="$id + ${kv%%=*} from ${kv#*=} (sha256 $(sha256sum "${kv#*=}" | cut -c1-16))"
done
echo "$id" > "$dir/.tree-id"
echo "tree $dir = $id"
