#!/usr/bin/env bash
# r4: everything the round-3 review asked for, on a MERGE COMMIT extracted whole with git archive.
# Each log opens with the commit, its parents, its tree, the extraction command, the directory; each
# step prints its own rc. merge-tree's rc is printed as command output, for the branch head and for
# the merge commit, against trunk as it is when this runs.
# usage: merged-commit-run-r4.sh <worktree> <merge commit> <logdir>   [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; MC="$2"; L="$3"
cd "$WT" || exit 2
MC=$(git rev-parse "$MC"); TREE=$(git rev-parse "$MC^{tree}"); P1=$(git rev-parse "$MC^1"); P2=$(git rev-parse "$MC^2")
S=${MC:0:8}
M=$(mktemp -d "${TMPDIR:-/tmp}/mergedc-XXXXXX"); trap 'rm -rf "$M"' EXIT
EXTRACT="git archive $MC | tar -C $M -xf -"
git archive "$MC" | tar -C "$M" -xf - || { echo "extraction failed"; exit 2; }
P38="$HOME/miniconda3/envs/ryu-env/bin/python3.8"
hdr() {
    echo "date $(date -Is)"
    echo "merge commit $MC: tree $TREE, parents $P1 and $P2"
    echo "trunk now $(git rev-parse trunk); branch head now $(git rev-parse HEAD)"
    echo "extracted: $EXTRACT"
    echo "dir $M"
}
{ hdr
  for c in "$(git rev-parse HEAD)" "$MC"; do
      echo "\$ git merge-tree --write-tree trunk $c"
      git merge-tree --write-tree --name-only trunk "$c" | grep -v '^Auto-merging' | sed 's/^/  /'
      echo "  rc=${PIPESTATUS[0]}"
  done; } > "$L/mergedc-$S-merge-tree.log" 2>&1
for py in /usr/bin/python3.12 "$P38"; do
    v=$($py -c 'import sys; print("%d%d" % sys.version_info[:2])')
    { hdr; echo "python $py $($py -c 'import sys; print(sys.version.split()[0])')"
      for t in test_ndt_serve_web test_ndt_serve test_ndt_serve_gui test_ndt_serve_cells; do
          (cd "$M" && $py tests/python/$t.py > "$M/.out" 2>&1); rc=$?
          echo "$t: $(grep -E '^Ran [0-9]+' "$M/.out" | tail -1), $(tail -1 "$M/.out"), rc=$rc"
      done; } > "$L/mergedc-$S-suites-py$v.log" 2>&1
    { hdr; (cd "$M" && PYTHON="$py" bash tests/shell/mutate_ndt_serve.sh); echo "gate exit rc=$?"; } > "$L/mergedc-$S-main-gate-py$v.log" 2>&1
done
shell() {   # <log suffix> <script>
    { hdr; echo "bash $(bash --version | head -1)"; echo "cmd bash $2"
      (cd "$M" && bash "$2"); echo "exit rc=$?"; } > "$L/mergedc-$S-$1.log" 2>&1
}
shell measuring-test tests/shell/test_ndt_status_measuring.sh
shell measuring-gate tests/shell/mutate_ndt_status_measuring.sh
shell status-check-gate tests/shell/mutate_ndt_status_check.sh
shell honesty-gate tests/shell/mutate_ndt_honesty.sh
shell residue-row-test tests/shell/test_ndt_status_residue_row.sh
shell lab-handoff-test tests/shell/test_lab_handoff.sh
{ hdr; echo "cmd check_gate_anchors.py --gates-from $MC --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh mutate_ndt_status_measuring.sh mutate_ndt_honesty.sh -- $MC"
  /usr/bin/python3.12 tests/shell/check_gate_anchors.py --gates-from "$MC" --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh \
      mutate_ndt_status_measuring.sh mutate_ndt_honesty.sh -- "$MC"; echo "rc=$?"
  echo "cmd check_gate_anchors.py $MC  (every gate)"; /usr/bin/python3.12 tests/shell/check_gate_anchors.py "$MC" | tail -2; echo "rc=${PIPESTATUS[0]}"
} > "$L/mergedc-$S-anchors.log" 2>&1
# the page suite last: it is timed, and it waits for the build guard's lock
{ hdr; df -h / | tail -1
  (cd "$M" && JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh env PYTHONDONTWRITEBYTECODE=1 python3 tests/browser/test_ndt_serve_page.py)
  echo "exit rc=$?"; } > "$L/mergedc-$S-page-suite.log" 2>&1
echo "$MC done"
