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
echo "interpreter: $PY"

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-e-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT

BASE_ANALYSE="$(sha256sum "$ANALYSE" | cut -d' ' -f1)"
BASE_PLOT="$(sha256sum "$PLOT" | cut -d' ' -f1)"
BASE_TEST_A="$(sha256sum "$HERE/test_analyse.py" | cut -d' ' -f1)"
BASE_TEST_P="$(sha256sum "$HERE/test_plot.py" | cut -d' ' -f1)"
BASE_SYNTH="$(sha256sum "$HERE/synthetic.py" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0

copy_tree() {   # copy_tree <destination>
    local d="$1"
    mkdir -p "$d/tests"
    cp "$ANALYSE" "$PLOT" "$d/"
    cp "$HERE"/*.py "$HERE"/*.sh "$d/tests/" 2>/dev/null
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
    echo "$d"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
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
for pair in "$ANALYSE:$BASE_ANALYSE" "$PLOT:$BASE_PLOT" \
            "$HERE/test_analyse.py:$BASE_TEST_A" "$HERE/test_plot.py:$BASE_TEST_P" \
            "$HERE/synthetic.py:$BASE_SYNTH"; do
    file="${pair%:*}"; want="${pair##*:}"
    now="$(sha256sum "$file" | cut -d' ' -f1)"
    [[ "$now" == "$want" ]] || {
        echo "🔴 $file changed while this gate was running -- its verdict is about a tree that no longer exists"
        exit 3; }
done

echo
echo "mutations: $MUTATIONS   survivors: $SURVIVORS"
(( SURVIVORS == 0 )) || exit 1
exit 0
