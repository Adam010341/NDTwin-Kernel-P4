#!/usr/bin/env bash
#
# p4_coverage_gate.sh -- P4Testgen statement coverage as a gate on ndtwin_switch.p4.
#
# [Co-developed with claude code -- Adam]
#
# p4testgen ships with the installed p4c (/usr/local/bin/p4testgen), so this costs no install
# and needs no bmv2, no kernel, no Mininet -- only the .p4 file. It symbolically executes the
# program and reports which IR statement nodes any generated test reaches.
#
# What it is actually for. The baseline says 85.2%, and the missing 14.8% is not a to-do list:
# it is the eight consecutive lines of the egress clone branch that assemble packet_in for a
# sampled packet. A clone is a second egress execution, and the symbolic engine walks one
# packet down one path, so those lines are unreachable *in principle*. The gate therefore
# watches the shape of the uncovered set, not just the number: a longer list means new code
# landed that no generated test can ever reach, and that should be a deliberate decision
# rather than a discovery six weeks later.
#
# Only runs when the .p4 actually changed (git hash-object against the recorded baseline),
# because a full run takes minutes and a check people skip is not a check. Unchanged is a
# sub-second no-op, which is what makes it safe to wire into local_ci.sh.
#
# Usage:
#   tools/test_workflow/p4_coverage_gate.sh                    # gate (skips if unchanged)
#   tools/test_workflow/p4_coverage_gate.sh --force            # measure even if unchanged
#   tools/test_workflow/p4_coverage_gate.sh --update-baseline  # accept current as the baseline
#
# P4TESTGEN overrides the binary (the tests' seam).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P4_FILE="${P4_FILE:-$ROOT/p4_proxy/p4_src/ndtwin_switch.p4}"
BASELINE="${BASELINE:-$ROOT/tools/test_workflow/p4_coverage_baseline.txt}"
P4TESTGEN="${P4TESTGEN:-p4testgen}"
MIN_COVERAGE="${MIN_COVERAGE:-0.85}"

if [[ -t 1 ]]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; D=""; N=""
fi

baseline_field() { grep -E "^$1 " "$BASELINE" 2>/dev/null | head -1 | cut -d' ' -f2-; }

measure() {
    # Echoes "<coverage> <uncovered line numbers...>"; returns p4testgen's exit code, which is
    # nonzero when --assert-min-coverage is not met.
    local out log rc
    out="$(mktemp -d)"
    log="$out/p4testgen.log"
    (cd "$(dirname "$P4_FILE")" && "$P4TESTGEN" --target bmv2 --arch v1model --max-tests 0 \
        --track-coverage STATEMENTS --only-covering-tests --print-coverage \
        --assert-min-coverage "$MIN_COVERAGE" --test-backend PTF \
        --out-dir "$out" "$(basename "$P4_FILE")") >"$log" 2>&1
    rc=$?
    local coverage uncovered
    coverage="$(grep -oE 'Nodes covered: [0-9.]+' "$log" | tail -1 | grep -oE '[0-9.]+$')"
    # The uncovered block is the last one printed, after the final "Not covered program nodes:".
    uncovered="$(awk '/Not covered program nodes:/{buf=""} /\.p4\\[0-9]+:/{
                        match($0, /\\[0-9]+:/); n=substr($0, RSTART+1, RLENGTH-2); buf=buf" "n}
                      END{print buf}' "$log")"
    echo "${coverage:-0}${uncovered}"
    cat "$log" >"$ROOT/.test_run/logs/p4_coverage_gate.log" 2>/dev/null || true
    rm -rf "$out"
    return $rc
}

mode="${1:-gate}"
[[ -f "$P4_FILE" ]] || { echo "${R}no such .p4: $P4_FILE${N}" >&2; exit 2; }

# p4testgen ships with p4c but a machine may not have p4c at all. Absent is a skip, not a
# failure: this gate is a bonus check, and failing the whole run for a missing optional tool is
# how a CI stops being read.
if ! command -v "$P4TESTGEN" >/dev/null 2>&1; then
    echo "${D}p4 coverage: $P4TESTGEN not installed; skipping${N}"
    exit 0
fi

sha="$(git -C "$ROOT" hash-object "$P4_FILE")"
base_sha="$(baseline_field sha)"
base_cov="$(baseline_field coverage)"
base_uncov="$(baseline_field uncovered)"

if [[ "$mode" == "gate" && "$sha" == "$base_sha" ]]; then
    echo "${D}p4 coverage: ndtwin_switch.p4 unchanged since baseline (${base_cov}); skipping${N}"
    exit 0
fi

result="$(measure)"; rc=$?
coverage="$(awk '{print $1}' <<<"$result")"
uncovered="$(cut -d' ' -f2- <<<"$result")"
[[ "$uncovered" == "$coverage" ]] && uncovered=""   # nothing uncovered at all

if [[ "$mode" == "--update-baseline" ]]; then
    tmp="$(mktemp)"
    grep -vE '^(sha|coverage|uncovered) ' "$BASELINE" > "$tmp"
    { echo "sha $sha"; echo "coverage $coverage"; echo "uncovered$( [[ -n "$uncovered" ]] && echo " $uncovered")"; } >> "$tmp"
    mv "$tmp" "$BASELINE"
    echo "${G}baseline updated${N}: coverage $coverage, uncovered [${uncovered# }]"
    exit 0
fi

echo "p4 coverage: ${coverage}  (baseline ${base_cov}, floor ${MIN_COVERAGE})"

if [[ $rc -ne 0 ]]; then
    echo "${R}FAIL${N} p4testgen refused the run: coverage below ${MIN_COVERAGE}" >&2
    exit 1
fi

# Compare the *shape* of the uncovered set, not only the number.
new_lines=""
for line in $uncovered; do
    grep -qw "$line" <<<"$base_uncov" || new_lines="$new_lines $line"
done
gone_lines=""
for line in $base_uncov; do
    grep -qw "$line" <<<"$uncovered" || gone_lines="$gone_lines $line"
done

if [[ -n "$new_lines" ]]; then
    echo "${R}FAIL${N} new unreachable line(s):${new_lines}" >&2
    echo "  No generated test can reach these. If that is intended (a clone/recirculate path," >&2
    echo "  say), record it: $0 --update-baseline" >&2
    exit 1
fi
if [[ -n "$gone_lines" ]]; then
    echo "${Y}note${N} previously unreachable, now covered:${gone_lines} — run --update-baseline"
fi
echo "${G}PASS${N} uncovered set unchanged [${base_uncov}]"
