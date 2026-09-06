#!/usr/bin/env bash
#
# Mutation gate for the per-node identity half of inv_graph_matches_topology (W3b-3).
#
# [Co-developed with claude code -- Adam]
#
# The invariant compared three cardinalities and the dpid SET. Four of R0b's six deliberately
# broken topology models (rounds/05-R0b-postmerge2.md 2.1) keep every count and every dpid,
# and it returned an EMPTY LIST for all four -- while run_layers.sh picks the model by
# (mode, live host count) rather than by asking the kernel which file it loaded, so validating
# a fabric against a model that is not the one it is running is reachable rather than
# hypothetical (KNOWN-ISSUES L-1's family).
#
# Two directions, because this can go wrong both ways and the second way is worse:
#
#   W1-W9  take a piece of the comparison out         -> a named case must go red
#   X1-X3  WIDEN it without breaking the contract     -> every case must stay GREEN
#   U1     an inert edit                              -> must SURVIVE
#
# 🔴 The X block is not decoration here. A device_name that disagrees with the model file is a
# NORMAL state of a healthy fabric -- modify_nickname/modify_device_name persist, into
# .test_run/nickname_overlay/ after W10 -- so a version of this check that failed on a rename
# would turn every renamed switch into a red L2 run, and would be removed within a week. The
# contract is: brand and addresses fail, names are accounted for, and fields the graph does
# not carry are out of reach and said to be.
#
# U1 is the scorer's own control: if the baseline were red every line would read "caught".
#
# 🔴 An UNAPPLICABLE mutation is scored a SURVIVOR, never a catch.
#
# 🔴 Guards its own baseline. Mutations go into a COPY of tools/contract_test/ in a temp dir
# and the test is pointed at it with NDT_CONTRACT_TOOLS; tools/contract_test/ is never written
# -- other sessions are reading this worktree right now. Anchor counts come from the REAL
# files, so a reworded source reports a missing anchor here and in
# tests/shell/check_gate_anchors.py. The topology models and the captured graph payload the
# test reads stay in the real repo: the authority a mutated tool is judged against must not be
# mutated with it.
#
# Usage:  bash tests/shell/mutate_contract_per_node_identity.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

TOOLS_DIR=tools/contract_test
SPEC="$TOOLS_DIR/spec.py"
RUNNER="$TOOLS_DIR/run_contract_test.py"
TEST=tests/python/test_contract_spec.py
PY="${PY:-python3}"

BK="$(mktemp -d /tmp/contract-identity-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SPEC="$(sha256sum "$SPEC" | cut -d' ' -f1)"
BASE_RUNNER="$(sha256sum "$RUNNER" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
WIDENINGS=0
BROKEN_WIDENINGS=0
UNAPPLICABLE=0

fresh_copy() {
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO/$TOOLS_DIR"/*.py "$dst"/
    echo "$dst"
}

# apply_exact <repo-relative file> <old> <new> <copy dir> -- assert the anchor is unique in the
# REAL file, then write the replacement into the copy. A substitution that matched nothing would
# leave the copy unmutated and score a green as "caught", so a missing or duplicated anchor is
# reported UNAPPLICABLE and counted as a survivor.
apply_exact() {
    local file="$1" from="$2" to="$3" dst="$4" n base
    base="$(basename "$file")"
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 UNAPPLICABLE: anchor appears $n time(s) in $file, expected 1 -- counted as a"
        echo "     SURVIVOR, because this gate has proved nothing about that mutation."
        echo "     anchor: $from"
        UNAPPLICABLE=$((UNAPPLICABLE + 1))
        return 1
    fi
    FROM="$from" TO="$to" perl -0777 -pe 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' \
        "$file" > "$dst/$base"
}

report() {
    local label="$1" dir="$2" want="$3" out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ ! -d "$dir" ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (never applied)\n' "$label"
        return
    fi
    out="$(NDT_CONTRACT_TOOLS="$dir" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $want\b" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$label" "$want"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$label" "$want"
        grep -E "^(FAIL|ERROR|OK|Ran )" <<<"$out" | sed 's/^/             /'
    fi
}

must_survive() {
    local label="$1" dir="$2" out rc
    WIDENINGS=$((WIDENINGS + 1))
    out="$(NDT_CONTRACT_TOOLS="$dir" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  survived %-58s (all green, as required)\n' "$label"
    else
        BROKEN_WIDENINGS=$((BROKEN_WIDENINGS + 1))
        printf '  🔴 KILLED %-57s (the suite went red on a change the contract permits)\n' "$label"
        grep -E "^(FAIL|ERROR)" <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base_dir="$(fresh_copy base)"
NDT_CONTRACT_TOOLS="$base_dir" "$PY" "$TEST" 2>&1 | tail -2 | sed 's/^/  /'
if ! NDT_CONTRACT_TOOLS="$base_dir" "$PY" "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
# The runner's own --self-test exercises the same invariant through selftest_fixtures.py. Not
# scored below (this gate scores one file), but a red one here would mean the baseline is not
# what it looks like.
"$PY" "$base_dir/run_contract_test.py" --self-test 2>&1 | tail -1 | sed 's/^/  /'
if ! "$PY" "$base_dir/run_contract_test.py" --self-test >/dev/null 2>&1; then
    echo "  --self-test is RED on the baseline copy"
    exit 2
fi
echo

# --- W: the comparison, taken out one piece at a time --------------------------------------------

d="$(fresh_copy w1)"
apply_exact "$SPEC" \
  '    out += _switch_identity(switches, ctx)' \
  '    out += []' "$d" || d=""
report "W1: switch identity is never consulted" "$d" \
       "test_a_switch_with_no_address_in_the_model_is_now_named"

d="$(fresh_copy w2)"
apply_exact "$SPEC" \
  '    out += _host_identity(hosts, ctx)' \
  '    out += []' "$d" || d=""
report "W2: host identity is never consulted" "$d" \
       "test_two_hosts_served_under_one_mac_are_named"

d="$(fresh_copy w3)"
apply_exact "$SPEC" \
  '        if s.get("brand_name", "") != want["brand_name"]:' \
  '        if False:' "$d" || d=""
report "W3: brand_name is not compared" "$d" \
       "test_a_switch_with_the_wrong_brand_in_the_model_is_now_named"

d="$(fresh_copy w4)"
apply_exact "$SPEC" \
  '        got_ips = address_set(s)
        if got_ips != want["ips"]:' \
  '        got_ips = address_set(s)
        if False:' "$d" || d=""
report "W4: a switch address set is not compared" "$d" \
       "test_a_switch_with_no_address_in_the_model_is_now_named"

d="$(fresh_copy w5)"
apply_exact "$SPEC" \
  '    return ".".join(str((value >> (8 * i)) & 0xFF) for i in range(4))' \
  '    return ".".join(str((value >> (8 * (3 - i))) & 0xFF) for i in range(4))' "$d" || d=""
report "W5: the address decoding reads the wrong end" "$d" \
       "test_the_first_octet_is_the_low_byte"

d="$(fresh_copy w6)"
apply_exact "$SPEC" \
  '            out.append(ACCOUNTED_FOR + f"switch dpid ' \
  '            out.append(f"switch dpid ' "$d" || d=""
report "W6: a rename becomes a hard failure" "$d" \
       "test_a_renamed_switch_is_reported_and_does_not_fail_the_check"

d="$(fresh_copy w7)"
apply_exact "$SPEC" \
  '    return frozenset(dotted_ip(v) for v in (node.get("ip") or []))' \
  '    return tuple(dotted_ip(v) for v in (node.get("ip") or []))' "$d" || d=""
report "W7: address order becomes part of identity" "$d" \
       "test_the_address_set_is_a_set_because_four_aliases_have_no_promised_order"

d="$(fresh_copy w8)"
apply_exact "$RUNNER" \
  '        if repeated:' \
  '        if False:' "$d" || d=""
report "W8: a repeated key silently drops a node instead of refusing" "$d" \
       "test_a_model_whose_hosts_share_a_mac_yields_no_verdict_instead_of_a_wrong_one"

d="$(fresh_copy w9)"
apply_exact "$RUNNER" \
  '        return {key_of(n): value_of(n) for n in nodes}, None' \
  '        return None, None' "$d" || d=""
report "W9: the runner stops building the maps at all" "$d" \
       "test_the_runner_builds_both_maps_for_every_shipped_model"

echo

# --- 🔴 X: widenings the contract permits. Every one of these must stay GREEN --------------------

d="$(fresh_copy x1)"
apply_exact "$SPEC" \
  ' -- brand_name decides power and telemetry "
                       f"dispatch, so this is a different machine, not a different label")' \
  ' REWORDED")' "$d"
must_survive "X1 (widening): the brand failure text is rewritten" "$d"

d="$(fresh_copy x2)"
apply_exact "$SPEC" \
  'f"addresses {sorted(got_ips)}, topology file says "' \
  'f"REWORDED {sorted(got_ips)} vs "' "$d"
must_survive "X2 (widening): the host address failure text is rewritten" "$d"

d="$(fresh_copy x3)"
apply_exact "$RUNNER" \
  '            lambda h: {"device_name": h.get("device_name", ""),
                       "ips": spec.address_set(h)})' \
  '            lambda h: {"device_name": h.get("device_name", ""),
                       "brand_name": h.get("brand_name", ""),
                       "ips": spec.address_set(h)})' "$d"
must_survive "X3 (widening): the host identity records an extra field" "$d"

d="$(fresh_copy u1)"
apply_exact "$SPEC" \
  '# 🔴 WHY THE COUNTS ARE NOT ENOUGH, and what the two functions below add.' \
  '# Reworded comment, no behaviour change at all (the scorer control).' "$d"
must_survive "U1 (control): an inert edit -- a survivor must be reportable" "$d"

echo
ok=1
[[ "$(sha256sum "$SPEC"   | cut -d' ' -f1)" == "$BASE_SPEC"   ]] || { echo "🔴 baseline CHANGED -- $SPEC was written during the gate"; ok=0; }
[[ "$(sha256sum "$RUNNER" | cut -d' ' -f1)" == "$BASE_RUNNER" ]] || { echo "🔴 baseline CHANGED -- $RUNNER was written during the gate"; ok=0; }
[[ "$ok" == 1 ]] || exit 3
echo "baseline byte-identical: yes (spec.py, run_contract_test.py)"
echo "widening controls: $WIDENINGS, $BROKEN_WIDENINGS killed (a kill here means the suite is pinned to prose, not behaviour)"
[[ "$UNAPPLICABLE" -eq 0 ]] || echo "unapplicable mutations: $UNAPPLICABLE (each counted as a survivor)"
if [[ "$SURVIVORS" -eq 0 && "$BROKEN_WIDENINGS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
