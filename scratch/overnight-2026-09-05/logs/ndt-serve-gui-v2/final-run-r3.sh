#!/usr/bin/env bash
# r3 final run at a frozen head: every gate and suite, each log written only by its command, with
# its own provenance; this script's own log says the order, start/end times and each rc.
# usage: final-run-r3.sh <worktree> <phase: A|B>      [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; PH="$2"; L="$(cd "$(dirname "$0")" && pwd)"
cd "$WT" || exit 2
H=$(git rev-parse HEAD); S=${H:0:8}
P38="$HOME/miniconda3/envs/ryu-env/bin/python3.8"
step() {   # <log name> <command...>
    local log="$L/$1"; shift
    echo "$(date -Is) start $(basename "$log"): $*"
    "$@" > "$log" 2>&1; local rc=$?
    echo "$(date -Is) end   $(basename "$log"): rc=$rc"
}
suites() {   # <python>
    local py="$1"
    echo "head $(git rev-parse HEAD)"; echo "porcelain $(git status --porcelain --untracked-files=no | grep -c .)"
    echo "date $(date -Is)"; echo "dir $WT"; echo "python $py $($py -c 'import sys; print(sys.version.split()[0])')"
    for t in test_ndt_serve test_ndt_serve_cells test_ndt_serve_gui test_ndt_serve_web; do
        $py tests/python/$t.py > "$L/.suite.out" 2>&1; local rc=$?
        echo "$t: $(grep -E '^Ran [0-9]+' "$L/.suite.out" | tail -1), $(tail -1 "$L/.suite.out"), rc=$rc"
    done; rm -f "$L/.suite.out"
}
shellgate() {   # <script> -- an ndt shell test or gate, with provenance and rc
    echo "head $(git rev-parse HEAD)"; echo "porcelain $(git status --porcelain --untracked-files=no | grep -c .)"
    echo "date $(date -Is)"; echo "dir $WT"; echo "bash $(bash --version | head -1)"; echo "cmd bash $1"
    bash "$1"; echo "rc=$?"
}
anchors() {
    echo "head $(git rev-parse HEAD)"; echo "porcelain $(git status --porcelain --untracked-files=no | grep -c .)"
    echo "date $(date -Is)"; echo "python /usr/bin/python3.12"
    echo "cmd check_gate_anchors.py --gates-from HEAD --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh mutate_ndt_status_measuring.sh mutate_ndt_honesty.sh -- HEAD"
    /usr/bin/python3.12 tests/shell/check_gate_anchors.py --gates-from HEAD --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh \
        mutate_ndt_status_measuring.sh mutate_ndt_honesty.sh -- HEAD; echo "rc=$?"
    echo; echo "cmd check_gate_anchors.py HEAD   (every gate)"
    /usr/bin/python3.12 tests/shell/check_gate_anchors.py HEAD | tail -3; echo "rc=${PIPESTATUS[0]}"
}
echo "# final-run-r3 phase $PH at $H, porcelain $(git status --porcelain --untracked-files=no | grep -c .), df $(df -h / | tail -1)"
if [[ $PH == A ]]; then
    step "main-gate-r3-py312-$S.log" env PYTHON=/usr/bin/python3.12 bash tests/shell/mutate_ndt_serve.sh
    step "main-gate-r3-py38-$S.log" env PYTHON="$P38" bash tests/shell/mutate_ndt_serve.sh
    step "suites-r3-py312-$S.log" suites /usr/bin/python3.12
    step "suites-r3-py38-$S.log" suites "$P38"
    step "ndt-measuring-test-r3-$S.log" shellgate tests/shell/test_ndt_status_measuring.sh
    step "ndt-measuring-gate-r3-$S.log" shellgate tests/shell/mutate_ndt_status_measuring.sh
    step "ndt-honesty-gate-r3-$S.log" shellgate tests/shell/mutate_ndt_honesty.sh
    step "ndt-status-check-gate-r3-$S.log" shellgate tests/shell/mutate_ndt_status_check.sh
    step "ndt-round-baseline-gate-r3-$S.log" shellgate tests/shell/mutate_ndt_round_baseline.sh
    step "ndt-sudo-surface-gate-r3-$S.log" shellgate tests/shell/mutate_ndt_sudo_surface.sh
    step "ndt-lab-handoff-test-r3-$S.log" shellgate tests/shell/test_lab_handoff.sh
    step "ndt-residue-row-test-r3-$S.log" shellgate tests/shell/test_ndt_status_residue_row.sh
    step "anchors-r3-$S.log" anchors
    step "gn7-red-first-r3-$S.log" bash "$L/gn7-red-first.sh" "$WT"
    step "merged-tree-r3-$S.log" bash "$L/merged-tree-run-r3.sh" "$WT" "$H" "$L"
elif [[ $PH == D ]]; then
    # 10-02 round 4: what the round-4 commit touches -- the measuring test and gate, the main and
    # rebuild gates (their own sha line), anchors
    step "ndt-measuring-test-r4-$S.log" shellgate tests/shell/test_ndt_status_measuring.sh
    step "ndt-measuring-gate-r4-$S.log" shellgate tests/shell/mutate_ndt_status_measuring.sh
    step "main-gate-r4-py312-$S.log" env PYTHON=/usr/bin/python3.12 bash tests/shell/mutate_ndt_serve.sh
    step "main-gate-r4-py38-$S.log" env PYTHON="$P38" bash tests/shell/mutate_ndt_serve.sh
    step "anchors-r4-$S.log" anchors
    df -h / | tail -1
    step "rebuild-gate-r4-$S.log" bash tests/shell/rebuild_ndt_serve_web.sh
elif [[ $PH == C ]]; then
    # 10-02: after the trap fix -- what it touches (main and measuring gates), the suites, anchors
    step "main-gate-r3-py312-$S.log" env PYTHON=/usr/bin/python3.12 bash tests/shell/mutate_ndt_serve.sh
    step "main-gate-r3-py38-$S.log" env PYTHON="$P38" bash tests/shell/mutate_ndt_serve.sh
    step "suites-r3-py312-$S.log" suites /usr/bin/python3.12
    step "suites-r3-py38-$S.log" suites "$P38"
    step "ndt-measuring-test-r3-$S.log" shellgate tests/shell/test_ndt_status_measuring.sh
    step "ndt-measuring-gate-r3-$S.log" shellgate tests/shell/mutate_ndt_status_measuring.sh
    step "anchors-r3-$S.log" anchors
else
    df -h / | tail -1
    step "rebuild-gate-r3-$S.log" bash tests/shell/rebuild_ndt_serve_web.sh
    step "page-suite-r3-$S.log" env JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh env PYTHONDONTWRITEBYTECODE=1 python3 tests/browser/test_ndt_serve_page.py
    step "page-gate-r3-$S.log" bash tests/shell/mutate_ndt_serve_page.sh
fi
echo "# $(date -Is) phase $PH done; head now $(git rev-parse HEAD), porcelain $(git status --porcelain --untracked-files=no | grep -c .)"
