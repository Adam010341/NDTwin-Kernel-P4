#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_l3_dispatch_drift.py (KNOWN-ISSUES L-5).
#
# [Co-developed with claude code -- Adam]
#
# The fix widened scan_kernel_dispatch()'s regex to recognise `utils::pathIs(target, "...")`,
# so --check-drift stopped reporting two live-200 endpoints as deleted. The risk in a fix of
# that shape is obvious and it is the reason this gate exists: the cheapest way to silence a
# false alarm is to make the detector answer "in sync" unconditionally, and the suite would be
# just as green. So the mutations run in BOTH directions --
#
#   M1  restores the original defect          -> the pathIs form must go unseen  (red)
#   M2  deletes the "table lists it, source does not" branch                     (red)
#   M3  deletes the "source registers it, table omits it" branch                 (red)
#   M4  stops comparing the verb                                                 (red)
#   M5  widens the capture past /ndt/ so the scan invents routes                 (red)
#
# M2/M3/M4 are the ones that matter: each is a way of making the checker agree with anything,
# and if any of them SURVIVES then the corresponding case is decorative and the L-5 fix bought
# a green light instead of a working detector.
#
# 🔴 Guards its own baseline. The mutations are applied to a COPY of tools/contract_test/ in a
# temp dir and the test is pointed at the copy with NDT_CONTRACT_DIR. components.py itself is
# never written -- other sessions are reading and running it right now. The anchor counts are
# still taken from the real file, so a reworded source still reports a missing anchor here and
# in tests/shell/check_gate_anchors.py.
#
# Usage:  bash tests/shell/mutate_l3_dispatch_drift.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

COMPONENTS=tools/contract_test/components.py
TEST=tests/python/test_l3_dispatch_drift.py
PY="${PY:-python3}"

BK="$(mktemp -d /tmp/l3-drift-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$COMPONENTS" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0

# fresh_copy -- an unmutated copy of tools/contract_test in $BK/<tag>, and echo its path.
fresh_copy() {
    # Separate statements: `local a="$1" b="$BK/$a"` expands every word BEFORE assigning any,
    # so b would be built from an unset a -- which under `set -u` aborts inside a $( ) and
    # hands the caller an empty path.
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO"/tools/contract_test/*.py "$REPO"/tools/contract_test/*.txt "$dst"/ 2>/dev/null
    echo "$dst"
}

# apply_exact <repo-relative file> <old> <new> -- assert the anchor is unique in the REAL file,
# then write the replacement into the copy. Never writes the real file. A substitution that
# matched nothing would leave the tree unmutated and the run would score a green as "caught".
apply_exact() {
    local file="$1" from="$2" to="$3" dst="$4" n base
    base="$(basename "$file")"
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: anchor appears $n time(s) in $file, expected 1"
        echo "     anchor: $from"
        exit 2
    fi
    FROM="$from" TO="$to" perl -0777 -pe 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' \
        "$file" > "$dst/$base"
}

# report <label> <copy dir> <test case that must go red>
report() {
    local label="$1" dir="$2" want="$3" out rc
    MUTATIONS=$((MUTATIONS + 1))
    out="$(NDT_CONTRACT_DIR="$dir" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $want\b" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$label" "$want"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$label" "$want"
        grep -E "^(FAIL|ERROR|OK|Ran )" <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base_dir="$(fresh_copy base)"
NDT_CONTRACT_DIR="$base_dir" "$PY" "$TEST" 2>&1 | tail -2 | sed 's/^/  /'
if ! NDT_CONTRACT_DIR="$base_dir" "$PY" "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

d="$(fresh_copy m1)"
apply_exact "$COMPONENTS" \
  '|(?:\w+::)*pathIs\s*\(\s*target(?:_path)?\s*,\s*' \
  '|(?:\w+::)*NEVER_MATCHES\s*\(\s*target(?:_path)?\s*,\s*' "$d"
report "M1: the original defect -- pathIs is not a registration" "$d" \
       "test_path_is_form_is_found"

d="$(fresh_copy m2)"
apply_exact "$COMPONENTS" \
  '    for name in sorted(KERNEL_ENDPOINTS):' \
  '    for name in []:' "$d"
report "M2: never report a route the source dropped" "$d" \
       "test_an_unregistered_name_in_the_table_still_drifts"

d="$(fresh_copy m3)"
apply_exact "$COMPONENTS" \
  '        if name not in KERNEL_ENDPOINTS:' \
  '        if False:' "$d"
report "M3: never report a route the table omits" "$d" \
       "test_a_pathis_route_missing_from_the_table_still_drifts"

d="$(fresh_copy m4)"
apply_exact "$COMPONENTS" \
  '        elif KERNEL_ENDPOINTS[name] != verb:' \
  '        elif False:' "$d"
report "M4: stop comparing the verb" "$d" \
       "test_a_wrong_verb_still_drifts"

d="$(fresh_copy m5)"
apply_exact "$COMPONENTS" \
  '"(?P<path>/ndt/[^"]*)"' \
  '"(?P<path>[^"]*)"' "$d"
report "M5: capture any quoted string, not just /ndt/ routes" "$d" \
       "test_a_non_ndt_pathis_is_not_invented_into_the_table"

echo
if [[ "$(sha256sum "$COMPONENTS" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes"
else
    echo "🔴 baseline CHANGED -- $COMPONENTS was written during the gate"
    exit 3
fi
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
