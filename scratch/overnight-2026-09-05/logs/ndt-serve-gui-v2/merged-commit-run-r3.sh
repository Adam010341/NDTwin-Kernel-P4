#!/usr/bin/env bash
# r3: trunk and the branch no longer merge clean (merge-tree rc 1: five files, all line citations).
# This runs the suites, the main gate, the ndt --measuring test and gate, and the anchor check on a
# MERGE COMMIT that resolves them (built with commit-tree; parents trunk and the branch head),
# extracted with git archive. Each log says the commit, its parents, its tree, the extraction and rc.
# usage: merged-commit-run-r3.sh <worktree> <merge commit> <logdir>   [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; MC="$2"; L="$3"
cd "$WT" || exit 2
TREE=$(git rev-parse "$MC^{tree}"); P1=$(git rev-parse "$MC^1"); P2=$(git rev-parse "$MC^2")
M=$(mktemp -d "${TMPDIR:-/tmp}/mergedc-XXXXXX"); trap 'rm -rf "$M"' EXIT
git archive "$MC" tools/ndt_serve tools/test_workflow tests/python tests/shell tests/browser | tar -C "$M" -xf -
S=${MC:0:8}
hdr() {
    echo "date $(date -Is)"
    echo "merge commit $MC: tree $TREE, parents $P1 (trunk $(git rev-parse trunk)) and $P2 (branch head $(git rev-parse HEAD))"
    echo "extracted: git archive $MC tools/ndt_serve tools/test_workflow tests/python tests/shell tests/browser | tar -C $M -xf -"
    echo "dir $M"
}
for py in /usr/bin/python3.12 "$HOME/miniconda3/envs/ryu-env/bin/python3.8"; do
    v=$($py -c 'import sys; print("%d%d" % sys.version_info[:2])')
    { hdr; echo "python $py $($py -c 'import sys; print(sys.version.split()[0])')"
      for t in test_ndt_serve_web test_ndt_serve test_ndt_serve_gui test_ndt_serve_cells; do
          (cd "$M" && $py tests/python/$t.py > "$M/.out" 2>&1); rc=$?
          echo "$t: $(grep -E '^Ran [0-9]+' "$M/.out" | tail -1), $(tail -1 "$M/.out"), rc=$rc"
      done; } > "$L/mergedc-$S-suites-py$v.log" 2>&1
    { hdr; (cd "$M" && PYTHON="$py" bash tests/shell/mutate_ndt_serve.sh); echo "gate exit rc=$?"; } > "$L/mergedc-$S-main-gate-py$v.log" 2>&1
done
{ hdr; echo "bash $(bash --version | head -1)"
  (cd "$M" && bash tests/shell/test_ndt_status_measuring.sh > "$M/.out" 2>&1); rc=$?
  echo "test_ndt_status_measuring.sh: $(tail -1 "$M/.out"), rc=$rc"
  (cd "$M" && bash tests/shell/mutate_ndt_status_measuring.sh); echo "gate exit rc=$?"; } > "$L/mergedc-$S-ndt-measuring.log" 2>&1
{ hdr; echo "cmd check_gate_anchors.py --gates-from $MC --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh mutate_ndt_status_measuring.sh mutate_ndt_honesty.sh -- $MC"
  /usr/bin/python3.12 tests/shell/check_gate_anchors.py --gates-from "$MC" --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh \
      mutate_ndt_status_measuring.sh mutate_ndt_honesty.sh -- "$MC"; echo "rc=$?"
  echo "cmd check_gate_anchors.py $MC  (every gate)"; /usr/bin/python3.12 tests/shell/check_gate_anchors.py "$MC" | tail -2; echo "rc=${PIPESTATUS[0]}"
} > "$L/mergedc-$S-anchors.log" 2>&1
echo "$MC"
