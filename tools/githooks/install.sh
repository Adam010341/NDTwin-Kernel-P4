#!/usr/bin/env bash
# Install this repo's versioned hooks into .git/hooks.
#
# Symlinks rather than copies, so editing tools/githooks/pre-commit takes effect immediately and
# there is no second stale copy to wonder about. The link is relative to .git/hooks so it
# survives the repo being moved.
#
# 🔴 It does NOT set core.hooksPath. That would point git at tools/githooks wholesale and
# silently retire .git/hooks/post-commit, which is the agy review trigger and is deliberately
# local-only (never committed, per-machine). Installing one hook must not disable another.
#
# Idempotent. Refuses to clobber an existing non-symlink hook -- if someone hand-wrote one, that
# is a fact worth seeing rather than overwriting.
#
# [Co-developed with claude code -- Adam]
set -euo pipefail
REPO="$(git rev-parse --show-toplevel)"
SRC="$REPO/tools/githooks"
DST="$REPO/$(git rev-parse --git-path hooks)"     # --git-path: inside a linked worktree .git is
                                                  # a file, so "$REPO/.git/hooks" is not a dir
mkdir -p "$DST"
rc=0
for h in pre-commit; do
    [[ -f "$SRC/$h" ]] || continue
    chmod +x "$SRC/$h"
    if [[ -e "$DST/$h" && ! -L "$DST/$h" ]]; then
        echo "🔴 $DST/$h exists and is not a symlink -- leaving it alone."
        echo "   Move it aside and rerun if you want the versioned one."
        rc=1; continue
    fi
    ln -sfn "$(realpath --relative-to="$DST" "$SRC/$h")" "$DST/$h"
    echo "✅ $h -> $(readlink "$DST/$h")"
done

# Report the state rather than assume the loop above achieved it: the whole point of this hook is
# that an uninstalled gate is indistinguishable from an installed one until it fails to fire.
echo
echo "live hooks in $DST:"
ls -l "$DST" | grep -v '\.sample' | tail -n +2 | sed 's/^/  /'
exit $rc
