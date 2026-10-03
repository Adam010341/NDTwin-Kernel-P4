#!/usr/bin/env bash
# Runs the four ndt serve suites (3.12 and 3.8) and the main gate (3.12) on the tree that
# `git merge-tree --write-tree trunk <head>` writes, extracted with git archive. Each log says
# how the tree was made, where it was extracted, and each rc.
# usage: merged-tree-run.sh <worktree> <head> <logdir>     [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; H="$2"; L="$3"
cd "$WT" || exit 2
TRUNK=$(git rev-parse trunk); TREE=$(git merge-tree --write-tree trunk "$H" | head -1); mt_rc=${PIPESTATUS[0]}
M=$(mktemp -d "${TMPDIR:-/tmp}/merged-XXXXXX"); trap 'rm -rf "$M"' EXIT
git archive "$TREE" tools/ndt_serve tools/test_workflow tests/python tests/shell tests/browser | tar -C "$M" -xf -
hdr() {
    echo "date $(date -Is)"
    echo "merge-tree: git merge-tree --write-tree trunk $H -> tree $TREE (rc=$mt_rc); trunk $TRUNK"
    echo "extracted: git archive $TREE tools/ndt_serve tools/test_workflow tests/python tests/shell tests/browser | tar -C $M -xf -"
    echo "dir $M"
}
for py in /usr/bin/python3.12 "$HOME/miniconda3/envs/ryu-env/bin/python3.8"; do
    v=$($py -c 'import sys; print("%d%d" % sys.version_info[:2])')
    out="$L/merged-${TREE:0:8}-suites-py$v.log"
    { hdr; echo "python $py $($py -c 'import sys; print(sys.version.split()[0])')"
      for t in test_ndt_serve_web test_ndt_serve test_ndt_serve_gui test_ndt_serve_cells; do
          (cd "$M" && $py tests/python/$t.py > "$M/.out" 2>&1); rc=$?
          echo "$t: $(grep -E '^Ran [0-9]+' "$M/.out" | tail -1), $(tail -1 "$M/.out"), rc=$rc"
      done; } > "$out" 2>&1
done
out="$L/merged-${TREE:0:8}-main-gate-py312.log"
{ hdr; (cd "$M" && PYTHON=/usr/bin/python3.12 bash tests/shell/mutate_ndt_serve.sh); echo "gate exit rc=$?"; } > "$out" 2>&1
echo "$TREE"
