#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_derive_p4_topology_json.py (the size check in
# tools/test_workflow/derive_p4_topology_json.py).
#
# [Co-developed with claude code -- Adam]
#
# Each mutant breaks one decision the script makes and must turn one NAMED cell red:
#
#   D1  the name check is removed                                   (a mislabelled file is written)
#   D2  every name that carries a size is refused                   (a matching name is refused)
#   D3  the refusal is printed but the exit status is 0             (a caller cannot tell)
#   D4  hosts are counted as switches                               (the declared size is wrong)
#   D5  the name check runs after the file is written               (a refusal leaves a file behind)
#   D6  a declared count of 128 is read as 28                       (only the 128-host model breaks)
#   D7  the brand check is removed                                  (a P4 model is derived again)
#   D8  a name with no size is checked too                          (the script refuses other names)
#
# D6 is the one that breaks a single cell: D2 and D4 also turn the 8-host cell red, and a gate
# whose only scored cell for the 128-host model sat behind them would never show that cell red
# on its own.
#
# The cell "the shipped sources are what these cells assume" guards the data in setting/, not
# the script, so no mutant of the script can turn it red.
#
# 🔴 Guards its own baseline: the mutations go into a COPY of derive_p4_topology_json.py in a
# temp dir and the test is pointed at it with DERIVE_UNDER_TEST. The real script is never
# written. Anchor counts are taken from the real file, so a reworded source still reports a
# missing anchor here and in tests/shell/check_gate_anchors.py.
#
# Usage:  bash tests/shell/mutate_derive_p4_topology_json.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

DERIVE=tools/test_workflow/derive_p4_topology_json.py
TEST=tests/python/test_derive_p4_topology_json.py

BK="$(mktemp -d /tmp/derive-p4-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$DERIVE" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0

# fresh_copy <tag> -- the script in $BK/<tag>. Echoes the path of the copy.
fresh_copy() {
    local dst="$BK/$1"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO/$DERIVE" "$dst/derive_p4_topology_json.py"
    echo "$dst/derive_p4_topology_json.py"
}

# apply_exact <repo-relative file> <old> <new> <copy> -- assert the anchor occurs exactly once
# in the REAL file, then write the replacement into the copy. Never writes the real file. A
# substitution that matched nothing would leave the copy unmutated and the run would score an
# untouched tree as "caught".
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

# report <label> <mutated copy> <cell that must go red>
# Caught means: the test exits non-zero AND unittest names exactly that cell as FAIL (an import
# error, a crash of the runner or another cell does not count).
report() {
    local label="$1" copy="$2" want="$3" out rc nred
    MUTATIONS=$((MUTATIONS + 1))
    out="$(DERIVE_UNDER_TEST="$copy" python3 -B "$TEST" 2>&1)"; rc=$?
    nred="$(grep -cE '^(FAIL|ERROR): ' <<<"$out")"
    if [[ "$rc" -ne 0 ]] && grep -qF "FAIL: $want (" <<<"$out"; then
        printf '  caught   %-58s (red: %s cell(s))\n' "$label" "$nred"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (not red on the named cell -- that cell proves nothing)\n' "$label"
        grep -E '^(FAIL|ERROR): |^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base="$(fresh_copy base)"
DERIVE_UNDER_TEST="$base" python3 -B "$TEST" 2>&1 | tail -1 | sed 's/^/  /'
if ! DERIVE_UNDER_TEST="$base" python3 -B "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

c="$(fresh_copy d1)"
apply_exact "$DERIVE" \
  '        if int(named) != declared:' \
  '        if False:' "$c"
report "D1: the name check is removed" "$c" \
       "test_the_128_host_model_into_a_name_for_8_hosts_is_refused_and_nothing_is_written"

c="$(fresh_copy d2)"
apply_exact "$DERIVE" \
  '        if int(named) != declared:' \
  '        if True:' "$c"
report "D2: every name that carries a size is refused" "$c" \
       "test_the_8_host_ovs_model_into_a_name_for_8_hosts_is_derived"

c="$(fresh_copy d3)"
apply_exact "$DERIVE" \
  $'            raise SystemExit(\n                f"refusing: {os.path.basename(dst)} is named' \
  $'            return print(\n                f"refusing: {os.path.basename(dst)} is named' "$c"
report "D3: the refusal is printed but the exit status is 0" "$c" \
       "test_the_128_host_model_into_a_name_for_8_hosts_is_refused_and_nothing_is_written"

c="$(fresh_copy d4)"
apply_exact "$DERIVE" \
  'node.get("vertex_type") == HOST)' \
  'node.get("vertex_type") == SWITCH)' "$c"
report "D4: hosts are counted as switches" "$c" \
       "test_the_8_host_ovs_model_into_a_name_for_8_hosts_is_derived"

c="$(fresh_copy d5)"
apply_exact "$DERIVE" \
  "    # The size the output's name claims" \
  $'    with open(dst, \'w\') as fh: json.dump(model, fh)\n    # The size the output\'s name claims' "$c"
report "D5: the name check runs after the file is written" "$c" \
       "test_the_128_host_model_into_a_name_for_8_hosts_is_refused_and_nothing_is_written"

c="$(fresh_copy d6)"
apply_exact "$DERIVE" \
  '        if int(named) != declared:' \
  '        if int(named) != declared % 100:' "$c"
report "D6: a declared count of 128 is read as 28" "$c" \
       "test_the_128_host_model_into_a_name_for_128_hosts_is_derived"

c="$(fresh_copy d7)"
apply_exact "$DERIVE" \
  '            if node.get("brand_name") != "OVS":' \
  '            if False:' "$c"
report "D7: the brand check is removed" "$c" \
       "test_the_brand_check_still_refuses_a_model_that_is_not_ovs"

c="$(fresh_copy d8)"
apply_exact "$DERIVE" \
  'r"_(\d+)Hosts"' \
  'r"_(\d*)Hosts"' "$c"
report "D8: a name with no size is checked too" "$c" \
       "test_a_name_that_says_nothing_about_a_size_is_not_checked"

echo
if [[ "$(sha256sum "$DERIVE" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes"
else
    echo "🔴 baseline CHANGED -- $DERIVE was written during the gate"
    exit 3
fi
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
