#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_run_layers_topology_from_fabric.sh (KNOWN-ISSUES L-1).
#
# [Co-developed with claude code -- Adam]
#
# Both directions, because "the suite is green now" is the failure being repaired:
#
#   M1  the original defect -- ignore the fabric, serve the configured model     (red)
#   M2  a fabric size no model describes falls back silently instead of refusing (red)
#   M3  the family is dropped from the query, so an OVS run can pick a P4 model  (red)
#   M4  the host counter counts every process line                              (red)
#   M5  the host counter drops the all-digits check (`mininet:host` counts)     (red)
#
# M2 is the important one. Making the selector return a path in every case is the cheapest way
# to a green suite and it recreates L-1 one level further out: a suite that cannot know which
# network it is testing must say so, not test the wrong one.
#
# 🔴 Guards its own baseline: the mutations go into a COPY of run_layers.sh in a temp dir and
# the test is pointed at it with RUN_LAYERS_UNDER_TEST. tools/test_workflow/run_layers.sh is
# never written -- another session may be executing it right now. Anchor counts are taken from
# the real file, so a reworded source still reports a missing anchor here and in
# tests/shell/check_gate_anchors.py.
#
# Usage:  bash tests/shell/mutate_run_layers_topology_from_fabric.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

RUNLAYERS=tools/test_workflow/run_layers.sh
COMPONENTS_ENV=tools/test_workflow/components.env
TEST=tests/shell/test_run_layers_topology_from_fabric.sh

BK="$(mktemp -d /tmp/run-layers-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$RUNLAYERS" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0

# fresh_copy <tag> -- run_layers.sh plus the components.env it sources, in $BK/<tag>.
# Echoes the path of the copied run_layers.sh.
fresh_copy() {
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO/$RUNLAYERS" "$dst/run_layers.sh"
    cp "$REPO/$COMPONENTS_ENV" "$dst/components.env"
    echo "$dst/run_layers.sh"
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

# report <label> <mutated copy> <check that must go red>
report() {
    local label="$1" copy="$2" want="$3" out rc
    MUTATIONS=$((MUTATIONS + 1))
    out="$(RUN_LAYERS_UNDER_TEST="$copy" bash "$TEST" 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $want" <<<"$out"; then
        printf '  caught   %-58s (red)\n' "$label"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (stayed green -- that check proves nothing)\n' "$label"
        grep -E '^  (ok|FAILED)|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base="$(fresh_copy base)"
RUN_LAYERS_UNDER_TEST="$base" bash "$TEST" 2>&1 | tail -1 | sed 's/^/  /'
if ! RUN_LAYERS_UNDER_TEST="$base" bash "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

c="$(fresh_copy m1)"
apply_exact "$RUNLAYERS" \
  '    derived="$(topo_for_hosts "$live" "$mode")"' \
  '    derived="$configured"' "$c"
report "M1: ignore the fabric, serve the configured model (the defect)" "$c" \
       "128-host fabric selects the 128-host P4 model, not the configured 4-host one"

c="$(fresh_copy m2)"
apply_exact "$RUNLAYERS" \
  '        return 3' \
  '        echo "$configured"; return 0' "$c"
report "M2: fall back silently instead of refusing" "$c" \
       "a fabric size no model describes is refused (rc 3), not served the default"

c="$(fresh_copy m3)"
apply_exact "$RUNLAYERS" \
  '    [[ "$mode" != p4 ]] && pats="StaticNetworkTopologyOVS_*.json StaticNetworkTopologyMininet_*.json"' \
  '    [[ "$mode" != p4 ]] && pats="StaticNetworkTopologyP4_*.json StaticNetworkTopologyOVS_*.json StaticNetworkTopologyMininet_*.json"' "$c"
report "M3: drop the family from the query" "$c" \
       "an OVS run never picks a P4 model of the same size"

c="$(fresh_copy m4)"
apply_exact "$RUNLAYERS" \
  '        [[ "$last" == "$tag"* && "${last#$tag}" =~ ^[0-9]+$ ]] && n=$(( n + 1 ))' \
  '        [[ -n "$line" ]] && n=$(( n + 1 ))' "$c"
report "M4: count every process line as a host" "$c" \
       "fabric_hosts_in counts host namespaces only (3 of 9 lines)"

c="$(fresh_copy m5)"
apply_exact "$RUNLAYERS" \
  '&& "${last#$tag}" =~ ^[0-9]+$ ]]' \
  ' ]]' "$c"
report "M5: prefix only, so mininet:host counts as a host" "$c" \
       "fabric_hosts_in counts host namespaces only (3 of 9 lines)"

echo
if [[ "$(sha256sum "$RUNLAYERS" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes"
else
    echo "🔴 baseline CHANGED -- $RUNLAYERS was written during the gate"
    exit 3
fi
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
