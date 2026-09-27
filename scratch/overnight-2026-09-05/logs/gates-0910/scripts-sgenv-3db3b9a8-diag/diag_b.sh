#!/usr/bin/env bash
# diag_b.sh <worktree> <out dir> -- round (b), 09-27: WHY are four suites red under the mandated gate
# environment? Each suite runs under four environments, every output KEPT; what changes between them
# is the cause. [Co-developed with claude code -- Adam]
#   E1  as a gate runs it: inside the guard, the full nolab shims (make_shims.sh) first on PATH
#   E2  the guard, only the MANDATED shims (sudo and curl)
#   E3  E2 with the guard's own variables taken away (JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT
#       MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP) -- still inside the guard's scope
#   E4  E3 with a short, real TMPDIR (/tmp/claude-1000/dgb) instead of the scratchpad's long one
# Then, for test_gate_exit_code_not_tee, the two cases that go red, re-run with their output kept
# (the suite sends it to /dev/null), and for the two whose red does not depend on the environment,
# the history of the code they test.
set -u
WT="$1"; OUT="$2"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SUITES=(test_build_guard.sh test_l1_shell_scoring.sh test_gate_exit_code_not_tee.sh test_start_bg_log_rotation.sh)
cd "$WT" || exit 2
rm -rf "$OUT"; mkdir -p "$OUT/shims_full" "$OUT/shims_min"
bash "$HERE/make_shims.sh" "$OUT/shims_full" >/dev/null
cp "$OUT/shims_full/sudo" "$OUT/shims_full/curl" "$OUT/shims_min/"
# the driver's own nolab shim dir is on PATH already; take it off, so E2-E4 really carry only sudo+curl
BASEPATH="$(tr ':' '\n' <<<"$PATH" | /usr/bin/grep -vE '/scripts-[^/]*/shims$' | paste -sd: -)"
echo "PATH the environments are built on: $BASEPATH" | cut -c1-200
GUARDVARS=(-u JOBS -u SHIM_JOBS -u NDTWIN_GUARD_HELD -u LOCK -u LOCK_WAIT -u MEM_HIGH -u MEM_MAX -u TIMEOUT -u NO_CGROUP)
SHORT=/tmp/claude-1000/dgb; mkdir -p "$SHORT"
echo "HEAD $(git rev-parse HEAD)"
echo "the guard's variables as the suites inherit them: $(env | /usr/bin/grep -E '^(JOBS|SHIM_JOBS|NDTWIN_GUARD_HELD|LOCK|LOCK_WAIT|MEM_HIGH|MEM_MAX|TIMEOUT|NO_CGROUP)=' | tr '\n' ' ')"
for s in "${SUITES[@]}"; do
    echo; echo "== $s"
    for e in E1 E2 E3 E4; do
        mkdir -p "$OUT/$e"
        case $e in
            E1) env PATH="$OUT/shims_full:$BASEPATH" NOLAB_LOG="$OUT/$e/$s.calls" bash "tests/shell/$s" ;;
            E2) env PATH="$OUT/shims_min:$BASEPATH" NOLAB_LOG="$OUT/$e/$s.calls" bash "tests/shell/$s" ;;
            E3) env "${GUARDVARS[@]}" PATH="$OUT/shims_min:$BASEPATH" NOLAB_LOG="$OUT/$e/$s.calls" bash "tests/shell/$s" ;;
            E4) env "${GUARDVARS[@]}" TMPDIR="$SHORT" PATH="$OUT/shims_min:$BASEPATH" NOLAB_LOG="$OUT/$e/$s.calls" bash "tests/shell/$s" ;;
        esac < /dev/null > "$OUT/$e/$s.out" 2>&1
        rc=$?
        printf '   %s rc %s  %-40s  red: %s\n' "$e" "$rc" "$(tail -1 "$OUT/$e/$s.out" | cut -c1-40)" \
            "$(/usr/bin/grep -cE '^ *FAILED' "$OUT/$e/$s.out")"
    done
done
rm -rf "${SHORT:?}"/*

echo; echo "== test_gate_exit_code_not_tee: its red cases with their output KEPT (E2)"
env PATH="$OUT/shims_min:$BASEPATH" NOLAB_LOG="$OUT/gate_tee.calls" bash -c '
set -uo pipefail
ROUND_DIR="tests/shell/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"
T=$(mktemp -d); trap "rm -rf $T" EXIT
export ROUND="$ROUND_DIR" LOG="$T/test.log" DRY_RUN=0
. "$ROUND_DIR/round.env" >/dev/null 2>&1 || true
LOG="$T/test.log"; . "$ROUND_DIR/lib_e.sh"; LOG="$T/test.log"
echo "PY_PLOT=${PY_PLOT:-unset} ($( [[ -x "${PY_PLOT:-}" ]] && echo executable || echo NOT executable))"
GATE=(env PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$ROUND_DIR/ratio_gate.py")
echo "--- case 1: run_gate ratio_gate.py --check t008_poll --expect green"
run_gate "${GATE[@]}" --check t008_poll --expect green; echo "rc=$?"
echo "--- the gate itself, no run_gate"
"${GATE[@]}" --check t008_poll --expect green; echo "rc=$?"
echo "--- the log run_gate wrote"; cat "$LOG" 2>/dev/null | tail -20
' 2>&1 | sed 's/^/   /' | cut -c1-220

echo; echo "== history of the code under test, for the suites red in every environment"
for pair in "test_start_bg_log_rotation.sh:tools/test_workflow/stack.sh" "test_l1_shell_scoring.sh:tests/shell"; do
    t="${pair%%:*}"; c="${pair#*:}"
    echo "   $t last changed: $(git log -1 --format='%h %ad %s' --date=short -- "tests/shell/$t" | cut -c1-110)"
    echo "   $c last changed: $(git log -1 --format='%h %ad %s' --date=short -- "$c" | cut -c1-110)"
done
echo "   rotate_log's .prev / timestamp history:"
git log --format='      %h %ad %s' --date=short -S'.prev2' -- tools/test_workflow/stack.sh | head -5 | cut -c1-140
echo "DIAG-B: done"
