#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_cpu_gate_lifetime.py.
#
# [Co-developed with claude code -- Adam]
#
# A test nobody has seen fail is not delivered. Each mutation below reintroduces one of the three
# holes the 2026-09-01 lifetime change closed (KNOWN-ISSUES "CPU 汙染閘門有三個洞"), or disables
# one of the reporting guards that make the fix legible, and names the case that must go red.
# A mutation that SURVIVES means that case is decorative.
#
# 🔴 Two outcomes that look alike are kept apart here and are not in the older mutate_*.sh
# scripts: a mutation that did not APPLY (the perl pattern missed, the file is byte-identical to
# the snapshot) is reported as DID-NOT-APPLY and fails the run, not as SURVIVED. Otherwise a
# harness whose patterns rotted would print a wall of "survived" and indict the tests for a
# defect in the harness.
#
# 🔴 The harness guards its own baseline: snapshot before the first mutation, EXIT trap restores
# on any exit including interrupt, and the run ends by asserting byte-identity. The baseline is
# the WORKING TREE, not HEAD, so this runs against an uncommitted fix -- and this file lives in a
# worktree other sessions write to.
#
# Usage:  bash tests/shell/mutate_cpu_gate_lifetime.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

GATE=doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py
TEST=tests/python/test_cpu_gate_lifetime.py
PY="$REPO/p4_proxy/venv/bin/python"     # the interpreter the round uses (round.env PY_PROXY)
BK=$(mktemp -d)

cp "$GATE" "$BK/gate"
restore() { cp "$BK/gate" "$GATE"; }
trap 'restore; rm -rf "$BK"' EXIT

run() { "$PY" -m unittest "$TEST" 2>&1; }

SURVIVORS=0
NOT_APPLIED=0
report() {   # $1 = mutation name, $2 = test case that must fail
    local out rc
    if cmp -s "$BK/gate" "$GATE"; then
        printf '  DID-NOT-APPLY %-58s (pattern missed; nothing was tested)\n' "$1"
        NOT_APPLIED=$((NOT_APPLIED + 1))
        return
    fi
    out=$(run); rc=$?
    # 🔴 Third outcome: the mutant broke the module (SyntaxError, ImportError), unittest never
    # ran a case, and "no named case went red" would read as SURVIVED. A test that never ran has
    # not been beaten. Detected by the absence of unittest's own "Ran N tests" line.
    if ! grep -qE '^Ran [0-9]+ tests' <<<"$out"; then
        printf '  TEST-DID-NOT-RUN %-55s (mutant broke the module; harness error, not a survivor)\n' "$1"
        grep -E 'Error|error' <<<"$out" | head -3 | sed 's/^/                /'
        NOT_APPLIED=$((NOT_APPLIED + 1))
        restore
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $2 " <<<"$out"; then
        printf '  caught        %-58s (%s went red)\n' "$1" "$2"
    else
        printf '  SURVIVED      %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$2"
        grep -E '^(FAIL|ERROR):|^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/                /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "baseline (unmutated) must be green:"
if run | tail -1 | grep -q '^OK'; then
    echo "  ok       baseline green ($(run | grep -oE 'Ran [0-9]+ tests'))"
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run | tail -8 | sed 's/^/    /'
    exit 2
fi
echo
echo "mutations:"

# ---- hole (1): lifetime blindness --------------------------------------------------------------
# 1. The headline defect: a process that started mid-window is skipped instead of charged.
perl -0pi -e 's/(midwindow = True\n\s+counts\["midwindow_attributed"\] \+= 1\n\s+)delta = ticks_b/${1}continue/' "$GATE"
report "mid-window process skipped (old 'if pid not in a: continue')" "test_midwindow_process_is_attributed_in_full"

# 2. A process older than the window with no opening read is dropped silently, not counted.
perl -0pi -e 's/counts\["excluded_no_baseline"\] \+= 1\n(\s+)continue/pass\n${1}continue/' "$GATE"
report "no-baseline process dropped without being counted" "test_process_older_than_the_window_without_a_baseline_is_counted_not_dropped"

# ---- hole (2): the floor filters before summing --------------------------------------------------
# 3. The listing floor becomes a counting floor again: sub-floor processes leave the total.
perl -0pi -e 's/(\n        named_ticks \+= delta)/\n        if delta \/ CLK \/ elapsed <= LIST_FLOOR:\n            continue$1/' "$GATE"
report "0.005 floor applied before summing (counting floor)" "test_sub_floor_processes_count_toward_the_total_without_being_listed"

# ---- hole (3): identity is (pid, comm) -----------------------------------------------------------
# 4. A renamed kworker is treated as a recycled pid and its CPU is dropped.
perl -0pi -e 's/if start_a != start_b:/if _comm_a != comm:/' "$GATE"
report "identity reverts to (pid, comm)" "test_kworker_rename_is_not_a_pid_reuse"

# ---- the reporting guards that make the fix legible ---------------------------------------------
# 5. suspect never fires, so a green verdict beside a 3-core residual reads as a quiet cell.
perl -0pi -e 's/suspect = residual >= suspect_at/suspect = False/' "$GATE"
report "suspect never fires" "test_suspect_fires_while_the_verdict_stays_green"

# 6. The UNACCOUNTED line is printed only when there is something to report -- so a cell with
#    nothing unaccounted and a cell whose gate forgot to look print the same thing.
perl -0pi -e 's/(verdict=\{verdict\} suspect=\{str\(suspect\)\.lower\(\)\}"\)\n    )print\(_unaccounted_line\(\)\)/${1}if residual: print(_unaccounted_line())/' "$GATE"
report "UNACCOUNTED line only printed when non-zero" "test_unaccounted_line_prints_even_when_there_is_nothing_to_report"

# 7. A baseline recorded by another gate version is accepted; excess becomes a version delta.
perl -0pi -e 's/if bl\.get\("gate_version"\) != GATE_VERSION:/if False:/' "$GATE"
report "baseline version check removed" "test_baseline_from_another_gate_version_is_refused"

# 8. A gate pointed at a fabricated procfs stops saying so in its record.
perl -0pi -e 's/if PROCFS != "\/proc":\n(\s+)provenance\["procfs"\] = PROCFS/if False:\n${1}provenance["procfs"] = PROCFS/' "$GATE"
report "procfs seam no longer recorded" "test_procfs_seam_is_recorded_whenever_it_is_not_proc"

# 9. An unrunnable measurement exits 0 -- the one failure that mimics a pass.
perl -0pi -e 's/(verdict=UNRUNNABLE err=\{e!r\}"\)\n        )return 2/${1}return 0/' "$GATE"
report "UNRUNNABLE exits 0" "test_unrunnable_measure_exits_two_not_zero"

# 10. The record goes back to the bare name, so a reader cannot tell which total it holds.
perl -0pi -e 's/foreign_cores_attributable=total, baseline_cores=baseline/foreign_cores=total, baseline_cores=baseline/' "$GATE"
report "record key reverts to bare foreign_cores" "test_record_reports_attributable_and_no_longer_the_bare_total"

# 11. The residual is folded into the attributable total, turning a bound into an attribution.
#     Named case is the residual test; if this SURVIVES, no case guards the separation and that
#     is a finding, not a harness error.
perl -0pi -e 's/foreign_cores_attributable=round\(foreign_total, 3\)/foreign_cores_attributable=round(foreign_total + unattributed, 3)/' "$GATE"
report "residual folded into foreign_cores_attributable" "test_residual_is_system_busy_minus_everything_named"

restore
echo
if cmp -s "$BK/gate" "$GATE"; then
    echo "baseline restored: cpu_gate.py byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/gate" "$GATE" | head -20
    exit 1
fi
echo "survivors=$SURVIVORS  harness-errors(did-not-apply / test-did-not-run)=$NOT_APPLIED"
[[ "$SURVIVORS" -eq 0 && "$NOT_APPLIED" -eq 0 ]]
