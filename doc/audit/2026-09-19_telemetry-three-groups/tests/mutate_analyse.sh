#!/usr/bin/env bash
#
# Mutation gate for the E round's analysis and figures.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration, and this round's tests are exactly the
# kind that are trivially green whatever the code does: they mostly assert that something is NOT
# done -- a ratio is not computed for an unresolved cell, an absence is not drawn as a zero, a
# mechanism is not attributed when its counter never moved, a residual is not compared across
# groups. So every registered branch of PREREG gets a mutation that removes it, and each one
# names the single test case that must go red.
#
# 🔴 THE MUTANT IS A COPY. Every mutation is applied under a temp dir; nothing in this directory
# is written, because another session may be reading these files right now. The sources are
# re-hashed at the end and a change underneath the gate exits 3.
#
# 🔴 EACH MUTATION IS A CHANGE TO PRODUCTION CODE, NEVER TO A TEST. Mutating a test proves that
# the test file is loaded, which is not the question.
#
# Usage:  tests/mutate_analyse.sh
#         PROXY_PY=/path/to/python tests/mutate_analyse.sh
# Exit:   0 every mutation caught, 1 a mutation survived, 2 refused (no interpreter, or the
#         baseline was red), 3 a source file changed underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$ROUND/../../.." && pwd)"

ANALYSE="$ROUND/analyse.py"
PLOT="$ROUND/plot.py"
DRIVER="$ROUND/drive_e.sh"
SCANNER="$HERE/hazard_scan.py"
MANIFEST="$ROUND/manifest.py"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up -- asked of git
# rather than spelled as somebody's home directory. Override with PROXY_PY= .
MAIN_WT="$(git -C "$ROUND" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python" "$(command -v python3 || true)"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import json, math, tempfile, unittest' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no usable interpreter. Set PROXY_PY=<path>." >&2
    echo "        A gate that cannot run its tests has not checked anything, so it does not" >&2
    echo "        get to exit 0." >&2
    exit 2
}
# 🔴 THE SAME HEADER EVERY OTHER LOG IN THIS ROUND CARRIES (ruling 24(5)). A gate log that
# does not say which tree and which head it ran against is a number without a subject.
printf '### mutation gate -- doc/audit/2026-09-19_telemetry-three-groups\n'
printf '# tree:        %s\n' "$ROUND"
printf '# head:        %s\n' "$(git -C "$ROUND" rev-parse HEAD 2>/dev/null || echo '?')"
printf '# when:        %s\n' "$(date -u '+%F %T UTC')"
printf '# interpreter: %s\n' "$PY"
printf '###\n'

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-e-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT

BASE_ANALYSE="$(sha256sum "$ANALYSE" | cut -d' ' -f1)"
BASE_PLOT="$(sha256sum "$PLOT" | cut -d' ' -f1)"
BASE_TEST_A="$(sha256sum "$HERE/test_analyse.py" | cut -d' ' -f1)"
BASE_TEST_P="$(sha256sum "$HERE/test_plot.py" | cut -d' ' -f1)"
BASE_SYNTH="$(sha256sum "$HERE/synthetic.py" | cut -d' ' -f1)"
BASE_DRIVER="$(sha256sum "$DRIVER" | cut -d' ' -f1)"
BASE_SCANNER="$(sha256sum "$SCANNER" | cut -d' ' -f1)"
BASE_TEST_OFF="$(sha256sum "$HERE/test_drive_e_offline.sh" | cut -d' ' -f1)"
BASE_MANIFEST="$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
# ruling 35(3): the structural reconciliation and the shape extractor it uses are under the
# gate too -- a change to either while it runs would make this verdict about a different tree.
BASE_TEST_SHAPE="$(sha256sum "$HERE/test_real_shape.py" | cut -d' ' -f1)"
BASE_INVENTORY="$(sha256sum "$HERE/inventory.py" | cut -d' ' -f1)"
BASE_REAL_INV="$(sha256sum "$HERE/fixtures/real_run_inventory.json" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
DRIFTS=0

copy_tree() {   # copy_tree <destination>
    local d="$1"
    mkdir -p "$d/tests"
    cp "$ANALYSE" "$PLOT" "$d/"
    # the three shell scripts too: since ruling 21 the gate also mutates the DRIVER, and
    # tests/test_drive_e_offline.sh finds them beside itself exactly as it does in the round.
    cp "$ROUND/drive_e.sh" "$ROUND/run_group_arm.sh" "$ROUND/sample_error.sh" \
       "$ROUND/manifest.py" "$d/"
    chmod +x "$d"/*.sh
    cp "$HERE"/*.py "$HERE"/*.sh "$d/tests/" 2>/dev/null
    # 🔴 AND THE FIXTURES. test_manifest.py reads the real switch manifest out of
    # tests/fixtures/, and a mutant without it fails for a harness reason -- which this gate
    # correctly refused a verdict over (baseline RED) rather than scoring. Ruling 27's fixture
    # is the whole point of that test; leaving it behind would make every mutant meaningless.
    if [[ -d "$HERE/fixtures" ]]; then
        mkdir -p "$d/tests/fixtures"
        cp "$HERE"/fixtures/* "$d/tests/fixtures/" 2>/dev/null
    fi
    chmod +x "$d"/tests/*.sh 2>/dev/null
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
}

run_against() {   # run_against <mutant dir>
    ( cd "$1" && PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest discover -s tests -t tests -v 2>&1 )
}

# The parameters are NAMED rather than positional so tests/shell/check_gate_anchors.py can read
# this gate the way it reads the others: it learns which argument is the anchor and which is the
# file from a function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"
    copy_tree "$d"
    "$PY" - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
path, anchor, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
source = open(path).read()
count = source.count(anchor)
assert count == 1, "anchor is not unique (%d hits): %s" % (count, anchor[:70])
open(path, "w").write(source.replace(anchor, replacement))
PY
    local apply_rc=$?
    # 🔴 AN ANCHOR THAT NO LONGER MATCHES IS NOT A SURVIVOR. The apply step asserts the
    # anchor occurs exactly once; when a later edit reworded the target, that assert fails, the
    # copy is left UNMUTATED, and the suite then passes -- which this gate used to print as
    # "SURVIVED", i.e. as evidence about a test. It is the opposite: no mutation was made, so
    # there is no verdict to give. Measured here on 2026-09-19: M-E21's anchor drifted when
    # round 3 rewrote the release block, and the gate reported a survivor that never existed.
    # (Ruling 24(5) candidate, taken because it produced a wrong verdict in this round's own run.)
    if (( apply_rc != 0 )); then
        echo "DRIFT"
        return 3
    fi
    echo "$d"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    if [[ "$2" == DRIFT ]]; then
        DRIFTS=$((DRIFTS + 1))
        printf '  🔴 DRIFT  %-72s (its anchor no longer matches -- NO mutation was made,\n' "$1"
        printf '                   %-72s  so this is not a verdict about the tests)\n' ""
        return
    fi
    MUTATIONS=$((MUTATIONS + 1))
    out="$(run_against "$2")"; rc=$?
    # 🔴 A SUITE THAT DID NOT FINISH IS NOT A VERDICT, in either direction. `timeout 300` returns
    # 124, and unittest prints its FAIL section at the END -- so a mutant that hangs produces no
    # named failure and would be scored a survivor of nothing.
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  🔴 HUNG   %-72s (the suite never finished -- never a catch)\n' "$1"
        return
    fi
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-72s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-72s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# The shell half of the gate. A mutation to drive_e.sh cannot be caught by a python unittest, so
# it is run against tests/test_drive_e_offline.sh -- the one that drives a whole round offline.
# mutant_tests -- same as mutant(), for a file that lives in tests/ rather than beside the
# round's scripts. The destination path matters: copy_tree puts tests/*.py under tests/.
mutant_tests() {   # $1 = label, $2 = file under tests/, $3 = anchor, $4 = replacement
    local label="$1"
    local file="$2"
    local old="$3"
    local new="$4"
    local d="$BK/$label"
    copy_tree "$d"
    "$PY" - "$d/tests/$(basename "$file")" "$old" "$new" <<'PYMT'
import sys
path, anchor, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
source = open(path).read()
count = source.count(anchor)
assert count == 1, "anchor is not unique (%d hits): %s" % (count, anchor[:70])
open(path, "w").write(source.replace(anchor, replacement))
PYMT
    local apply_rc=$?
    # 🔴 AN ANCHOR THAT NO LONGER MATCHES IS NOT A SURVIVOR. The apply step asserts the
    # anchor occurs exactly once; when a later edit reworded the target, that assert fails, the
    # copy is left UNMUTATED, and the suite then passes -- which this gate used to print as
    # "SURVIVED", i.e. as evidence about a test. It is the opposite: no mutation was made, so
    # there is no verdict to give. Measured here on 2026-09-19: M-E21's anchor drifted when
    # round 3 rewrote the release block, and the gate reported a survivor that never existed.
    # (Ruling 24(5) candidate, taken because it produced a wrong verdict in this round's own run.)
    if (( apply_rc != 0 )); then
        echo "DRIFT"
        return 3
    fi
    echo "$d"
}

report_shell() {   # $1 = mutation name, $2 = mutant dir, $3.. = EVERY cell that must go red
    local name="$1"
    local dir="$2"
    shift 2
    local out rc missing=""
    if [[ "$dir" == DRIFT ]]; then
        DRIFTS=$((DRIFTS + 1))
        printf '  🔴 DRIFT  %-72s (its anchor no longer matches -- NO mutation was made,\n' "$name"
        printf '                   %-72s  so this is not a verdict about the tests)\n' ""
        return
    fi
    MUTATIONS=$((MUTATIONS + 1))
    out="$( cd "$dir" && PYTHONDONTWRITEBYTECODE=1 timeout 900 ./tests/test_drive_e_offline.sh 2>&1 )"
    rc=$?
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  🔴 HUNG   %-72s (the offline round never finished -- never a catch)\n' "$name"
        return
    fi
    # 🔴 ALL of them, not any of them. Ruling 22(2) asked for M-E19 to be killed by
    # BEHAVIOUR rather than by an assertion about the call log, and the honest way to record that
    # is to require both: the behavioural cell proves the mutation changes what the round DOES,
    # the call-log cell says which call it changed. (Ruling 24(2).)
    local cell
    for cell in "$@"; do
        /usr/bin/grep -qF "  FAIL  $cell" <<<"$out" || missing="$missing
             still green: $cell"
    done
    if [[ "$rc" -ne 0 && -z "$missing" ]]; then
        printf '  caught   %-72s (%d cell(s) went red)\n' "$name" "$#"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-72s%s\n' "$name" "$missing"
        /usr/bin/grep -E '^(  FAIL|passed:)' <<<"$out" | sed 's/^/             /'
    fi
}

control() {   # $1 = name, $2 = mutant dir -- a change that must NOT be caught
    local out rc
    out="$(run_against "$2")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  control  %-72s (stayed green, as a control must)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  🔴 CONTROL WENT RED %-59s (the suite is fragile, not sensitive)\n' "$1"
        /usr/bin/grep -E '^(FAIL|ERROR)' <<<"$out" | sed 's/^/             /'
    fi
}

# --- --self-test: does this gate report correctly when it CANNOT test? ----------------------
# 🔴 AN INSTRUMENT NOBODY HAS SEEN FAIL IS A DECORATION, and that applies to the gate's own
# refusal paths. Two of them exist and neither had ever been exercised in a saved run:
#
#   (a) ANCHOR DRIFT. A mutation whose anchor no longer matches is not applied at all, and the
#       suite then passes -- which this gate used to print as SURVIVED, i.e. as evidence about a
#       test. It is the opposite. Measured for real on 2026-09-19: M-E21's anchor drifted when
#       round 3 rewrote the release block and the gate reported a survivor that never existed.
#   (b) PARTIAL RED. report_shell takes several cells and requires ALL of them red; if only some
#       go red the mutation is NOT caught, and saying otherwise would credit a cell that stayed
#       green.
#
# Both run the real functions on the real tree. (Ruling 25(3) and 25(4).)
if [[ "${1:-}" == "--self-test" ]]; then
    echo "self-test (a): a mutation whose anchor cannot be found"
    m=$(mutant st_drift "$ANALYSE" \
        'MEDIAN_OVER_SD = 0.674   ### no such line exists' \
        'MEDIAN_OVER_SD = 1.0')
    report "ST-1: an anchor that matches nothing" "$m" \
           "test_the_shot_noise_prediction_is_the_registered_formula"
    drift_after=$DRIFTS
    echo
    echo "self-test (b): two required cells, only ONE of which can go red"
    # The driver mutation really does redden the first cell; the second names a cell that does
    # not exist, so it can never be red. report_shell must therefore NOT call this caught.
    m=$(mutant st_partial "$DRIVER" \
        '            FAILURES+=("$gen: '"'"'ndt status --check'"'"' rc=1 -- see $gen/11_verify.txt; the arms of this generation ran under it")' \
        '            :')
    surv_before=$SURVIVORS
    report_shell "ST-2: one cell red, one cell that cannot be" "$m" \
           "🔴 a generation whose status --check said rc 1 does NOT end in PASS" \
           "  a cell name that does not exist in the suite"
    echo
    echo "--- self-test expectations"
    st_rc=0
    if (( drift_after == 1 )); then
        echo "  ok    (a) an unmatchable anchor was reported as DRIFT, not as a survivor"
    else
        echo "  FAIL  (a) the drift path did not fire (drifted=$drift_after)"; st_rc=1
    fi
    if (( SURVIVORS == surv_before + 1 )); then
        echo "  ok    (b) a partially-red mutation was reported SURVIVED, not caught"
    else
        echo "  FAIL  (b) a partially-red mutation was scored as caught"; st_rc=1
    fi
    echo
    echo "mutations: $MUTATIONS   survivors: $SURVIVORS   drifted: $DRIFTS"
    if (( st_rc != 0 )); then
        echo "🔴 SELF-TEST FAILED: this gate does not refuse the way it says it does."
        printf '\n### rc=1\n'
        exit 1
    fi
    echo "🔴 REFUSING A VERDICT: $DRIFTS mutation(s) could not be applied at all. Fix their"
    echo "   anchors and run this again -- a gate that did not mutate has not tested anything."
    echo "   (this is the self-test: both refusal paths fired, which is the pass condition)"
    printf '\n### rc=2\n'
    exit 2
fi

echo "baseline (must be green before any mutation):"
base="$BK/base"; copy_tree "$base"
run_against "$base" | /usr/bin/grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || {
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the registered intervals ----------------------------------------------------------------

m=$(mutant m1 "$ANALYSE" \
    'RATIO_LO, RATIO_HI = 0.60, 1.67' \
    'RATIO_LO, RATIO_HI = 0.667, 1.50')
report "M-E1: the ceiling interval is the NOMINAL 1.5x ladder step, not the realised 1.667x" "$m" \
       "test_the_interval_boundaries_are_the_realised_step_not_the_nominal_one"

m=$(mutant m2 "$ANALYSE" \
    '                entry["resolved"] = entry["rung_gap"] <= 1' \
    '                entry["resolved"] = True')
report "M-E2: a cell is resolved however far apart its two arms landed" "$m" \
       "test_a_cell_whose_arms_are_six_rungs_apart_is_NOT_resolved"

m=$(mutant m3 "$ANALYSE" \
    '            elif not cell["resolved"] or not base["resolved"]:' \
    '            elif False:')
report "M-E3: an unresolved cell still gets a ratio (1b section 4's missing branch, restored)" "$m" \
       "test_an_unresolved_cell_produces_NO_ratio_at_all"

# --- the absence that must not become a number -------------------------------------------------

m=$(mutant m4 "$ANALYSE" \
    '            row["note"] = ("n/a -- the none group has no twin readings; "' \
    '            row["median_abs_error"] = 0.0
            row["median_signed_error"] = 0.0
            row["note"] = ("n/a -- the none group has no twin readings; "')
report "M-E4: the none group's missing sampling error is reported as 0.0" "$m" \
       "test_the_none_group_is_n_a_and_is_NOT_zero"

m=$(mutant m5 "$PLOT" \
    '                bars.append({"tick": tick, "value": None, "label": "n/a", "na": True})' \
    '                bars.append({"tick": tick, "value": 0.0, "label": "0.0", "na": False})')
report "M-E5: figure 2 draws the none group as a zero bar instead of n/a" "$m" \
       "test_the_none_group_is_drawn_as_n_a_and_NOT_as_a_zero_bar"

m=$(mutant m6 "$PLOT" \
    '                label = "%.1f*" % mean if not arms else "%.1f* (%s)" % (
                    mean, "/".join("%g" % a for a in arms))' \
    '                label = "%.1f" % mean')
report "M-E6: figure 1 labels an unresolved cell with a mean no arm measured" "$m" \
       "test_an_unresolved_cell_is_marked_and_shows_BOTH_arm_values"

# --- the shot-noise prediction and the mechanism attribution -----------------------------------

m=$(mutant m7 "$ANALYSE" \
    'MEDIAN_OVER_SD = 0.674' \
    'MEDIAN_OVER_SD = 1.0')
report "M-E7: the shot-noise prediction uses the sd rather than the median of |X|" "$m" \
       "test_the_shot_noise_prediction_is_the_registered_formula"

m=$(mutant m8 "$ANALYSE" \
    '            if dropped > 0:' \
    '            if True:')
report "M-E8: sample loss is attributed with every drop counter at zero (the ROLE-5 failure)" "$m" \
       "test_sample_loss_is_NOT_attributed_when_every_drop_counter_is_zero"

# --- the CPU arithmetic -------------------------------------------------------------------------

m=$(mutant m9 "$ANALYSE" \
    '                accumulated[name] = accumulated.get(name, 0) + (0 if key in present_at_start
                                                                else value)' \
    '                accumulated[name] = accumulated.get(name, 0) + value')
report "M-E9: a process alive before the window is charged its whole lifetime to that window" "$m" \
       "test_a_process_alive_before_the_window_is_not_charged_its_lifetime"

m=$(mutant m10 "$ANALYSE" \
    '    return (a - b) / elapsed' \
    '    return 5 * kpps * 1000.0 / 256.0')
report "M-E10: samples/s is assumed from the offered rate instead of read from the counter" "$m" \
       "test_samples_per_second_comes_from_the_rung_pair_not_from_the_offered_rate"

m=$(mutant m11 "$ANALYSE" \
    '            if row["resolved"]:
                points.append((row["samples_per_s"], delta))' \
    '            points.append((row["samples_per_s"], delta))')
report "M-E11: a line is fitted through deltas smaller than their own spread (H-C0 removed)" "$m" \
       "test_a_delta_smaller_than_its_spread_is_H_C0_and_no_line_is_fitted"

m=$(mutant m12 "$ANALYSE" \
    '    if share is not None and share <= FIXED_SHARE_PER_SAMPLE:
        return "H-C2 cost is per sample (08-20'"'"'s fixed component does not reproduce here)"
    return "H-C3 mixed -- the decomposition IS the result (PREREG 5.3)"' \
    '    return "H-C2 cost is per sample (08-20'"'"'s fixed component does not reproduce here)"')
report "M-E12: the mixed decomposition has no branch of its own (08-28 section 4's H3 lesson)" "$m" \
       "test_the_cpu_verdict_names_a_mixed_decomposition_as_a_result"

# --- the load gate -------------------------------------------------------------------------------

m=$(mutant m13 "$ANALYSE" \
    '    for group, members in sorted(by_group.items()):
        reference = median([a["external"] for a in members])' \
    '    everyone = [a["external"] for members in by_group.values() for a in members]
    for group, members in sorted(by_group.items()):
        reference = median(everyone)')
report "M-E13: the foreign-CPU gate compares an arm to the median of ALL arms, across groups" "$m" \
       "test_the_gate_is_within_group_so_the_link_treatment_does_not_fire_it"

# --- the reconciliations --------------------------------------------------------------------------

m=$(mutant m14 "$ANALYSE" \
    '    for group in ("none", "cooperative"):
        cell = cells.get((group, 1024))' \
    '    for group in ("none",):
        cell = cells.get((group, 1024))')
report "M-E14: reconciliation (a) drops the condition-matched cooperative pairing" "$m" \
       "test_a_is_reported_for_BOTH_the_none_and_the_cooperative_cell"

m=$(mutant m15 "$ANALYSE" \
    'SENDER_CONTROL_FACTOR = 5.0' \
    'SENDER_CONTROL_FACTOR = 1.0')
report "M-E15: the generator control passes at 1x instead of the registered 5x" "$m" \
       "test_a_sender_control_below_five_times_FAILS"

m=$(mutant m16 "$ANALYSE" \
    'OLD_MARGINAL_US_PER_SAMPLE = 206.0' \
    'OLD_MARGINAL_US_PER_SAMPLE = 20.6')
report "M-E16: reconciliation (b) compares against the wrong 08-20 figure" "$m" \
       "test_b_compares_the_marginal_slope_against_08_20s_206_microseconds"

# --- the driver (ruling 21). Each of these is a defect that really happened. --------------

m=$(mutant m17 "$DRIVER" \
    '    verify_generation "$group" "$gen"' \
    '    "$NDT" verify_p4 > "$RUN/$gen/11_verify.txt" 2>&1')
report_shell "M-E17: the generation check calls ndt verify_p4, which is not a subcommand" "$m" \
       "🔴 verify_p4 is never invoked"

m=$(mutant m18 "$DRIVER" \
    '    local id="$1"
    local frame="$2"
    local payload
    local out
    payload=$((frame - 42))
    out="$RUN/controls/$id"' \
    '    local id="$1" frame="$2" payload=$((frame - 42)) out="$RUN/controls/$id"')
report_shell "M-E18: the four locals of the sender control are re-joined onto one line" "$m" \
       "🔴 C1 ran (the set -u local hazard would have killed the shell here)"

m=$(mutant m19 "$DRIVER" \
    '    declare_measuring off || true
    "$NDT" down > "$log" 2>&1' \
    '    "$NDT" down > "$log" 2>&1')
report_shell "M-E19: the teardown stops retracting measuring= (ndt down then refuses, rc 5)" "$m" \
       "  it reached its own verdict, and it is a PASS" \
       "🔴 every teardown is preceded by a claim that retracts measuring="

m=$(mutant m20 "$DRIVER" \
    '            FAILURES+=("$gen: '"'"'ndt status --check'"'"' rc=1 -- see $gen/11_verify.txt; the arms of this generation ran under it")
            ;;' \
    '            ;;')
report_shell "M-E20: a status --check rc 1 goes back to being a note, so PASS can coexist with it" "$m" \
       "🔴 a generation whose status --check said rc 1 does NOT end in PASS"

m=$(mutant m21 "$DRIVER" \
    '        if (( knob_restored )); then
            declare_measuring off "$FINAL_CLAIM_MINUTES"
        else' \
    '        if false; then
            declare_measuring off "$FINAL_CLAIM_MINUTES"
        else')
report_shell "M-E21: the final re-claim is dropped, so the release compares against a stale baseline" "$m" \
       "🔴 the release is not refused, so the lab is actually given back"

m=$(mutant m22 "$DRIVER" \
    '            FAILURES+=("final: '"'"'ndt release'"'"' refused (rc $release_rc) -- the lab is still claimed; see 95_release.txt")' \
    '            :')
report_shell "M-E22: a refused release is printed but never reaches the verdict" "$m" \
       "🔴 a refused release means the round does NOT pass"

m=$(mutant m23 "$DRIVER" \
    '    local knob_restored=1
    restore_host_knob || knob_restored=0' \
    '    local knob_restored=1
    restore_host_knob || true')
report_shell "M-E23: a failed knob restore goes back to being swallowed by || true" "$m" \
       "🔴 a round whose knob did not go back does NOT pass"

# 🔴 M-E24 RETIRED (ruling 25(2)). It flipped `if (( knob_restored ))` to `if true`, and
# that is BEHAVIOURALLY IDENTICAL: teardown_fabric's retraction has already written the round
# baseline from the pre-restore knob, so the extra claim changes no outcome -- the release
# compares 4 against 4 either way. It was killed only by the message string, and its label said
# "release guard vacuous", which was the same wrong reasoning. A mutation whose only detectable
# effect is a log line is not evidence about behaviour.
#
# What replaces it is a mutation with a real effect: the final retraction renewing for ten hours
# instead of ten minutes, which is exactly what locks a lab after a refused release.
m=$(mutant m24 "$DRIVER" \
    'FINAL_CLAIM_MINUTES="${FINAL_CLAIM_MINUTES:-10}"' \
    'FINAL_CLAIM_MINUTES="${FINAL_CLAIM_MINUTES:-$CLAIM_MINUTES}"')
report_shell "M-E24: the final retraction renews by CLAIM_MINUTES again (a refused release locks the lab)" "$m" \
       "  the final claim renews for FINAL_CLAIM_MINUTES, not CLAIM_MINUTES"

m=$(mutant_tests m25 "$SCANNER" \
    '    if could_not_read:
        sys.exit(2)' \
    '    if False:
        sys.exit(2)')
report_shell "M-E25: an unreadable path is counted as a clean scan (rc 0)" "$m" \
       "🔴 a path that cannot be read is rc 2, not rc 0"

m=$(mutant m26 "$MANIFEST" \
    '    if isinstance(argv, str):
        try:
            return shlex.split(argv)
        except ValueError:
            return argv.split()' \
    '    if isinstance(argv, str):
        return argv')
report_shell "M-E26: a string argv is not split, so iterating it yields characters (ruling 27)" "$m" \
       "🔴 the binary is found in a string argv"

m=$(mutant m27 "$MANIFEST" \
    '    if previous is not None and previous.startswith("-"):
        return False' \
    '    if False:
        return False')
# 🔴 report, NOT report_shell, and bound to the DOT-LESS cell. Two ways to get this wrong were
# taken before the right one, and both are the same mistake: binding a mutation to a cell that
# cannot go red for it.
#   1. a shell cell that merely checks the FIXTURE's type() -- it never runs the rule at all;
#   2. the --log-file /tmp/simple_switch.log cell -- the "no dot in the basename" rule already
#      rejects that one, so removing the "follows an option" rule changes NOTHING and the
#      mutation is EQUIVALENT. A gate reporting a survivor there is reporting about a rule that
#      nothing tests.
# test_a_DOT_LESS_option_value_is_still_not_the_binary uses `--log-dir /var/log/
# simple_switch_grpc`, where this rule is the only thing standing between the reader and the
# wrong answer. (Rulings 27 and 29; same family as M-E10 and M-E19.)
report "M-E27: a dot-less option VALUE (--log-dir /var/log/simple_switch_grpc) is taken for the binary" "$m" \
       "test_a_DOT_LESS_option_value_is_still_not_the_binary"

# --- ruling 32: the control arms, the label collision, and the verdict over an unfinished round ---
# All five of these are defects the fourth campaign's own raw or log showed, not invented ones.

m=$(mutant m28 "$ANALYSE" \
    '    cells = {}
    for arm in arms:
        if arm.get("control"):
            continue' \
    '    cells = {}
    for arm in arms:')
report "M-E28: C3's throwaway ladders are pooled into the none|1024 cell again" "$m" \
       "test_the_none_1024_cell_is_the_two_ladder_arms_only"

m=$(mutant m29 "$ANALYSE" \
    '    by_group = {}
    for arm in arms:
        if arm.get("control"):
            continue
        if arm["external"] is None or arm["external"] < 0:' \
    '    by_group = {}
    for arm in arms:
        if arm["external"] is None or arm["external"] < 0:')
report "M-E29: the load gate's own positive control is back in the group median it moves" "$m" \
       "test_the_none_group_gate_median_counts_the_ladder_arms_only"

# 🔴 THE PRE-FIX RULE, PUT BACK WHERE IT WAS. plot.py:207-213 judged a collision as "closer than
# 3% of the spread of the end values" and staggered by a fixed +/-9 points. It is written out
# here rather than approximated, so that what this mutation restores is the code that drew the
# fourth campaign's figure 3 and not a caricature of it.
m=$(mutant m30 "$PLOT" \
    '        final = natural if previous is None else max(natural, previous + label_points)' \
    '        _span = ordered[-1][0] - ordered[0][0]
        _collides = index > 0 and (_span == 0 or abs(y - ordered[index - 1][0]) < 0.03 * _span)
        final = natural + (9.0 if _collides and index % 2 else (-9.0 if _collides else 0.0))')
report "M-E30: figure 3 judges label collisions as 3% of the end values' spread again" "$m" \
       "test_three_ends_within_a_label_height_get_three_different_offsets"

m=$(mutant m31 "$DRIVER" \
    'trap finish EXIT
trap '"'"'SIGNALLED=INT; finish'"'"' INT
trap '"'"'SIGNALLED=TERM; finish'"'"' TERM' \
    'trap finish EXIT INT TERM')
report_shell "M-E31: the traps stop recording WHICH signal ended the round (the 18:54 shape)" "$m" \
       "🔴 an interrupted round says it was interrupted, and by which signal"

m=$(mutant m32 "$DRIVER" \
    '    if (( arms_seen != arms_expected )); then' \
    '    if false; then')
report_shell "M-E32: the arm count is no longer compared against the selection" "$m" \
       "🔴 a round that measured fewer arms than it selected does NOT pass" \
       "🔴 and the verdict says how many of how many"

# --- ruling 35: the sample count and the label that left the axes --------------------------------

# 🔴 THE DEFECT EXACTLY AS IT WAS. `links=len(window["keys"])` counted all 32 inter-switch ports
# of the fabric instead of the 4 the flow crossed, so N was eight times too large, the predicted
# median 2.83x too tight, and five of the fourth campaign's six treated cells were reported
# outside a band they were inside.
m=$(mutant m33 "$ANALYSE" \
    '    peaks = window.get("per_edge_peak_bps") or {}
    carrying = sorted(key for key, value in peaks.items() if value)' \
    '    peaks = window.get("per_edge_peak_bps") or {}
    carrying = sorted(window.get("keys") or [])')
report "M-E33: N counts every edge in the fabric again, not the ones that carried the flow" "$m" \
       "test_N_counts_the_edges_that_carried_the_flow_not_every_edge_in_the_fabric"

# The axes stop being given room, which is how this round's own label fix pushed the bmv2
# panel's top label 8.2 pt above the frame and onto the panel title.
m=$(mutant m34 "$PLOT" \
    '            needed = max(needed, (y - low) * height_points / headroom)' \
    '            needed = needed')
report "M-E34: the axes are not raised, so a staggered top label is drawn outside them" "$m" \
       "test_no_label_is_drawn_above_the_top_of_its_own_axes"

# --- ruling 37: the fold that ran in production and never in a test ------------------------------
# 🔴 THIS GATE HAD NO MUTATION ON label_of AT ALL. Ten switches' CPU is folded into one class by
# it and summed; every bmv2 number in the round depends on that, and until now the sum could
# have been a max, a first, or a mean and all 34 mutations would still have been caught. The
# fixture's ten weights are unequal (42,30,20,16,12,10,8,6,4,2 = 150), so dropping bmv2-3 takes
# exactly 20 off the folded total -- the expected value follows from the weights.
m=$(mutant m35 "$ANALYSE" \
    '    return "bmv2" if name.startswith("bmv2") else name' \
    '    return "bmv2" if name.startswith("bmv2") and name != "bmv2-3" else name')
report "M-E35: one switch falls out of the bmv2 class, so the fold stops being a sum of ten" "$m" \
       "test_the_ten_bmv2_processes_are_folded_into_one_class_and_SUMMED"

# 🔴 THE DISHONEST VERSION OF THE FIT. This clamps every label to sit under the axes top, which
# is what "silently returning a limit the labels do not fit under" would look like from the
# outside: the overflow disappears from the return and the caller cannot tell any more. The
# characterisation case for the headroom <= 0 branch is what refuses it. (Ruling 37(5).)
m=$(mutant m36 "$PLOT" \
    '        final = natural if previous is None else max(natural, previous + label_points)' \
    '        final = min(natural if previous is None else max(natural, previous + label_points),
                    height_points - label_points / 2.0)')
report "M-E36: the stack is clamped to the axes, so an overflow stops being visible to the caller" "$m" \
       "test_a_stack_taller_than_its_axes_is_not_reported_as_fitting"

# --- the controls: changes that must NOT be caught -------------------------------------------------
# A suite that goes red on a comment is not sensitive, it is fragile, and a fragile suite gets
# ignored -- which costs more than the mutations it catches.

m=$(mutant c1 "$ANALYSE" \
    'GROUPS = ("none", "cooperative", "link")' \
    '# the three telemetry sources of PREREG section 1, in the order they are reported
GROUPS = ("none", "cooperative", "link")')
control "C-E1: a comment added above GROUPS (semantics unchanged)" "$m"

m=$(mutant c2 "$PLOT" \
    '    bars = []
    for frame in sorted({frame for (_g, frame) in parsed}):' \
    '    bars = []
    for frame in sorted({size for (_g, size) in parsed}):')
control "C-E2: a comprehension variable renamed in figure1_data (semantics unchanged)" "$m"

# --- nothing underneath the gate moved while it ran ---------------------------------------------
# 🔴 EVERY FILE THIS GATE MUTATES OR RUNS, not just the python half (ruling 25(4)). The
# driver, the scanner and the offline suite are all under the gate now; a change to any of them
# while it ran would make its verdict about a tree that no longer exists.
for pair in "$ANALYSE:$BASE_ANALYSE" "$PLOT:$BASE_PLOT" \
            "$DRIVER:$BASE_DRIVER" "$SCANNER:$BASE_SCANNER" "$MANIFEST:$BASE_MANIFEST" \
            "$HERE/test_drive_e_offline.sh:$BASE_TEST_OFF" \
            "$HERE/test_analyse.py:$BASE_TEST_A" "$HERE/test_plot.py:$BASE_TEST_P" \
            "$HERE/synthetic.py:$BASE_SYNTH" \
            "$HERE/test_real_shape.py:$BASE_TEST_SHAPE" "$HERE/inventory.py:$BASE_INVENTORY" \
            "$HERE/fixtures/real_run_inventory.json:$BASE_REAL_INV"; do
    file="${pair%:*}"; want="${pair##*:}"
    now="$(sha256sum "$file" | cut -d' ' -f1)"
    [[ "$now" == "$want" ]] || {
        echo "🔴 $file changed while this gate was running -- its verdict is about a tree that no longer exists"
        exit 3; }
done

echo
echo "mutations: $MUTATIONS   survivors: $SURVIVORS   drifted: $DRIFTS"
if (( DRIFTS > 0 )); then
    echo "🔴 REFUSING A VERDICT: $DRIFTS mutation(s) could not be applied at all. Fix their"
    echo "   anchors and run this again -- a gate that did not mutate has not tested anything."
    printf '\n### rc=2\n'
    exit 2
fi
if (( SURVIVORS == 0 )); then
    printf '\n### rc=0\n'
    exit 0
fi
printf '\n### rc=1\n'
exit 1
