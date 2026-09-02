#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_chaos_c07_control.py (KNOWN-ISSUES G-3).
#
# [Co-developed with claude code -- Adam]
#
# G-3 was three independently fatal ingredients producing one control that passed whether or
# not the defect existed. Fixing one ingredient and leaving the others is how the shape
# survives a repair, so every ingredient gets its own mutation and each must go red:
#
#   M1  the route goes back to a name the kernel does not register        (red)
#   M2  a request that never landed is scored as a reproduction           (red)
#   M3  the probe swallows a non-2xx again                                (red)
#   M4  a kernel that really records is still scored as B-3               (red)
#   M5  a reply with no `recording` field is scored instead of refused    (red)
#   M6  the retraction is downgraded to a note                            (red)
#
# M4 is the one to watch. It is the direction the original control could never reach -- every
# answer it was capable of receiving satisfied `rows == 0` -- so if M4 survives, the fix bought
# a green light and not a working control.
#
# 🔴 Guards its own baseline: the mutations go into a COPY of the harness in a temp dir and the
# test is pointed at it with NDT_CHAOS_HARNESS. Nothing under doc/audit/2026-08-28_chaos-harness
# is written. Anchor counts are taken from the real files, so a reworded source still reports a
# missing anchor here and in tests/shell/check_gate_anchors.py.
#
# Usage:  bash tests/shell/mutate_chaos_c07_control.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

ROUND=doc/audit/2026-08-28_chaos-harness
ACTIONS=doc/audit/2026-08-28_chaos-harness/harness/actions.py
PROBES=doc/audit/2026-08-28_chaos-harness/harness/probes.py
CLAIM=doc/audit/2026-08-28_chaos-harness/05_first-live-run.md
TEST=tests/python/test_chaos_c07_control.py
PY="${PY:-python3}"

BK="$(mktemp -d /tmp/chaos-c07-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$ACTIONS" "$PROBES" "$CLAIM" | sha256sum | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0

# fresh_copy <tag> -- the harness .py files plus the claim document, laid out so that the
# test's `dirname(NDT_CHAOS_HARNESS)/05_first-live-run.md` finds the copy. Echoes the harness
# directory to pass as NDT_CHAOS_HARNESS.
fresh_copy() {
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst/harness"
    cp "$REPO/$ROUND"/harness/*.py "$dst/harness/"
    cp "$REPO/$CLAIM" "$dst/"
    echo "$dst/harness"
}

# apply_exact <repo-relative file> <old> <new> <destination file> -- assert the anchor occurs
# exactly once in the REAL file, then write the replacement to the destination. Never writes
# the real file. A substitution that matched nothing would leave the copy unmutated and score
# an untouched tree as "caught".
apply_exact() {
    local file="$1" from="$2" to="$3" dst="$4" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: anchor appears $n time(s) in $file, expected 1"
        echo "     anchor: $from"
        exit 2
    fi
    FROM="$from" TO="$to" perl -0777 -pe 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' \
        "$file" > "$dst"
}

# report <label> <harness dir> <test case that must go red>
report() {
    local label="$1" dir="$2" want="$3" out rc
    MUTATIONS=$((MUTATIONS + 1))
    out="$(NDT_CHAOS_HARNESS="$dir" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $want\b" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$label" "$want"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$label" "$want"
        grep -E "^(FAIL|ERROR|OK|Ran )" <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base="$(fresh_copy base)"
NDT_CHAOS_HARNESS="$base" "$PY" "$TEST" 2>&1 | tail -2 | sed 's/^/  /'
if ! NDT_CHAOS_HARNESS="$base" "$PY" "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

d="$(fresh_copy m1)"
apply_exact "$ACTIONS" \
  'HISTORICAL_LOGGING = "/ndt/historical_logging"' \
  'HISTORICAL_LOGGING = "/ndt/set_historical_logging"' "$d/actions.py"
report "M1: back to a route the kernel does not register" "$d" \
       "test_the_control_names_no_phantom_route"

d="$(fresh_copy m2)"
apply_exact "$ACTIONS" \
  '        return ActionResult(False, f"cannot read the recording state back, so B-3 is neither "' \
  '        return ActionResult(True, f"cannot read the recording state back, so B-3 is neither "' "$d/actions.py"
report "M2: a request that never landed counts as a reproduction" "$d" \
       "test_a_404_is_refused_not_scored_as_a_reproduction"

d="$(fresh_copy m3)"
apply_exact "$PROBES" \
  '    if not 200 <= status < 300:' \
  '    if False:' "$d/probes.py"
report "M3: the probe swallows a non-2xx again" "$d" \
       "test_404_raises_and_carries_the_status"

d="$(fresh_copy m4)"
apply_exact "$ACTIONS" \
  '    if recording:' \
  '    if False:' "$d/actions.py"
report "M4: a kernel that really records is still scored as B-3" "$d" \
       "test_a_recording_kernel_does_not_reproduce_b3"

d="$(fresh_copy m5)"
apply_exact "$ACTIONS" \
  '            False, f"the reply carries no boolean `recording`, so it cannot say whether a row "' \
  '            True, f"the reply carries no boolean `recording`, so it cannot say whether a row "' "$d/actions.py"
report "M5: an undecidable reply is scored instead of refused" "$d" \
       "test_a_reply_without_the_recording_field_is_refused"

d="$(fresh_copy m6)"
apply_exact "$CLAIM" \
  '> ❌ **RETRACTED 2026-09-03 — KNOWN-ISSUES G-3.**' \
  '> **Note 2026-09-03 — KNOWN-ISSUES G-3.**' "$(dirname "$d")/05_first-live-run.md"
report "M6: the retraction is downgraded to a note" "$d" \
       "test_h9_is_marked_retracted"

echo
if [[ "$(sha256sum "$ACTIONS" "$PROBES" "$CLAIM" | sha256sum | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes"
else
    echo "🔴 baseline CHANGED -- a harness file was written during the gate"
    exit 3
fi
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
