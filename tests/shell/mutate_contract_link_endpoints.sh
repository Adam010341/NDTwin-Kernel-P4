#!/usr/bin/env bash
#
# Mutation gate for Adam's ruling E-21: the four link endpoints in the L2 contract.
#
# [Co-developed with claude code -- Adam]
#
# What E-21 bought is one field on the wire: `declaration_retained`. It is the only thing that
# tells a caller "this kernel deliberately left your link down" -- the status line is 200 whether
# the recovery was applied or declined, deliberately, because Ryu's on_link_add logs "NDT REJECTED
# this notification ... the kernel's view is now stale" on any 4xx. Before this ticket the field
# was documented in doc/2026-01-02_ndt_api.md §2, emitted by HttpSession.cpp, and named by no
# schema anywhere, so it could have been dropped without a single check going red.
#
# So the mutations run in BOTH directions, because the cheap way to make a contract green is to
# make it agree with anything:
#
#   direction 1 -- weaken the contract, and the suite must go red
#     M1   the schema stops naming declaration_retained at all
#     M2   the check that reads it answers nothing            (the headline: E-21's own field)
#     M3   a dpid-0 door stops requiring 400                  (E-18's four doors)
#     M4   an endpoint path is mistyped                       (a door that guards nothing)
#     M5   the endpoint table is sorted, so the sequence loses its order
#     M6   the tc report no longer has to cover both ends     (faults.txt L-2)
#     M7   "skipped (not MININET)" becomes a free-form excuse
#     M8   the injection stops naming the one endpoint that can end it
#     M9   the PAIRED withdrawal check answers nothing        (the over-fitting direction)
#     M10  the chosen link no longer has to be switch-to-switch
#     M11  a topology with no switch link is guessed at instead of refused
#     M12  the declined step gets its sibling's invariant      (the copy-paste)
#     M13  a kernel that never says the failure is sticky passes
#     M14  inject_link_failure is a READ, so a read-only run cuts a link
#     M15  the sequence ends on an endpoint that cannot end an injection
#
#   direction 2 -- a change that must NOT redden anything, or these tests are change detectors
#     W1   a comment
#     W2   the same finding, reworded
#     W3   an extra optional field in the response schema
#
# Two lanes, and both of them run, because a lane that never executes proves nothing:
#
#   spec      tests/python/test_contract_spec.py     the endpoint table and the schemas
#   selftest  run_contract_test.py --self-test       the schemas and invariants against the
#                                                    examples in doc/2026-01-02_ndt_api.md
#
# 🔴 Guards its own baseline the way tests/shell/mutate_l3_dispatch_drift.sh does: every mutation
# is applied to a COPY of tools/contract_test/ in a temp dir and the lanes are pointed at the copy
# with NDT_CONTRACT_DIR. tools/contract_test/*.py is never written -- other sessions are reading
# and running it right now. Anchor counts are still taken from the REAL file, so a reworded source
# reports a missing anchor here and in tests/shell/check_gate_anchors.py rather than silently
# mutating nothing and scoring the resulting green as "caught".
#
# Needs no build and no kernel: both lanes are pure Python over stdlib.
#
# Usage:  bash tests/shell/mutate_contract_link_endpoints.sh
# Exit:   0 every mutation caught and every widening survived
#         1 a mutation survived, or a widening was wrongly caught
#         2 refused (harness fault only: missing file or interpreter, red baseline, anchor drift,
#           or a real file written)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SPEC=tools/contract_test/spec.py
FIXTURES=tools/contract_test/selftest_fixtures.py
TEST=tests/python/test_contract_spec.py

# The repo's own venv interpreter, per the project rule for Python tests. A missing interpreter is
# a harness fault, not a survivor -- it proves nothing.
PY="${PY:-$REPO/p4_proxy/venv/bin/python}"

for f in "$SPEC" "$FIXTURES" "$TEST"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -x "$PY" ]] || { echo "REFUSE: interpreter $PY not found. Set PY." >&2; exit 2; }

BK="$(mktemp -d /tmp/contract-link-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
SPEC_SHA="$(sha256sum "$SPEC" | cut -d' ' -f1)"
FIXTURES_SHA="$(sha256sum "$FIXTURES" | cut -d' ' -f1)"

MUTATIONS=0
SURVIVORS=0
WIDENINGS=0
WRONGLY_CAUGHT=0

# fresh_copy -- an unmutated copy of tools/contract_test in $BK/<tag>, and echo its path.
fresh_copy() {
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO"/tools/contract_test/*.py "$REPO"/tools/contract_test/*.txt "$dst"/ 2>/dev/null
    echo "$dst"
}

# apply_exact <repo-relative file> <old> <new> <copy dir> -- assert the anchor is unique in the
# REAL file, then write the replacement into the copy. Never writes the real file. A substitution
# that matched nothing would leave the copy unmutated and the run would score a green as "caught".
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

# --- the two lanes. Each prints the identities that went red, empty if the lane is green. ------
# rc comes from the process directly, never through a pipe, so a crash cannot be read as a pass
# by a summary line that was never printed. PYTHONDONTWRITEBYTECODE, because a .pyc whose source
# is rewritten to the same length within one second keeps its validation stamp and the interpreter
# would serve the MUTANT's bytecode from a pristine-looking file.

red_spec() {
    local dir="$1" out rc
    out="$(NDT_CONTRACT_DIR="$dir" PYTHONDONTWRITEBYTECODE=1 "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_0-9]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

red_selftest() {
    local dir="$1" out rc
    out="$(cd "$dir" && PYTHONDONTWRITEBYTECODE=1 NO_COLOR=1 "$PY" ./run_contract_test.py \
              --self-test 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^  FAIL  \(.*\)$/\1/p' <<<"$out" | sort -u | tr '\n' '|'
}

red_for() {
    case "$1" in
        spec)     red_spec "$2" ;;
        selftest) red_selftest "$2" ;;
        *) echo "HARNESS-FAULT-unknown-lane-$1" ;;
    esac
}

# report <label> <lane> <copy dir> <identity that must go red>
report() {
    local label="$1" lane="$2" dir="$3" want="$4" failed
    MUTATIONS=$((MUTATIONS + 1))
    failed="$(red_for "$lane" "$dir")"
    if [[ -z "$failed" ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (%s lane stayed green -- that behaviour is untested)\n' \
               "$label" "$lane"
    elif grep -qF -- "$want" <<<"$failed"; then
        printf '  caught   %-58s (%s: %s)\n' "$label" "$lane" "$want"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  🔴 WRONG %-58s (%s went red instead of %s)\n' "$label" "$failed" "$want"
        echo "           The gate fires, but not for the reason this mutation claims."
    fi
}

# widen <label> <lane> <copy dir> -- a change that must leave the lane GREEN.
widen() {
    local label="$1" lane="$2" dir="$3" failed
    WIDENINGS=$((WIDENINGS + 1))
    failed="$(red_for "$lane" "$dir")"
    if [[ -z "$failed" ]]; then
        printf '  ✅ survived %-55s (%s stayed green, as it must)\n' "$label" "$lane"
    else
        WRONGLY_CAUGHT=$((WRONGLY_CAUGHT + 1))
        printf '  🔴 WRONGLY CAUGHT %-46s (%s went red: %s)\n' "$label" "$lane" "$failed"
        echo "           These tests are change detectors, not a specification."
    fi
}

# --- baseline ----------------------------------------------------------------------------------

echo "E-21 link-endpoint contract mutation gate"
printf '  baseline : %s %s\n' "$(sha256sum "$SPEC" | cut -c1-16)" "$SPEC"
printf '  baseline : %s %s\n' "$(sha256sum "$FIXTURES" | cut -c1-16)" "$FIXTURES"
printf '  python   : %s\n\n' "$PY"
echo "baseline (must be green before any mutation):"
base_dir="$(fresh_copy base)"
for lane in spec selftest; do
    base_red="$(red_for "$lane" "$base_dir")"
    if [[ -n "$base_red" ]]; then
        echo "  REFUSE: the $lane baseline is RED before any mutation: $base_red"
        echo "          Mutations prove nothing on a red baseline."
        exit 2
    fi
    printf '  ok       %s baseline green\n' "$lane"
done
echo
echo "direction 1 -- weakening the contract must go red:"

# --- direction 1 -------------------------------------------------------------------------------

d="$(fresh_copy m1)"
apply_exact "$SPEC" \
  '    "declaration_retained": Bool(),
    "detail": Str(nonempty=True),' \
  '    "detail": Str(nonempty=True),' "$d"
report "M1: the schema stops naming declaration_retained" spec "$d" \
       "test_a_truthy_string_is_not_declaration_retained"

d="$(fresh_copy m2)"
apply_exact "$SPEC" \
  '    if data.get("declaration_retained") is not True:' \
  '    return []  # MUTANT
    if data.get("declaration_retained") is not True:' "$d"
report "M2: the check that reads the field answers nothing" spec "$d" \
       "test_the_declined_recovery_must_report_declaration_retained"

d="$(fresh_copy m3)"
apply_exact "$SPEC" \
  '         path="/ndt/inject_link_failure", body=HOST_EDGE_PAYLOAD,
         request_schema=LINK_REQUEST,
         category=ERRORPATH, expect_status=[400],' \
  '         path="/ndt/inject_link_failure", body=HOST_EDGE_PAYLOAD,
         request_schema=LINK_REQUEST,
         category=ERRORPATH, expect_status=[404],' "$d"
report "M3: a dpid-0 door stops requiring 400" spec "$d" \
       "test_the_dpid_zero_doors_accept_only_400"

d="$(fresh_copy m4)"
apply_exact "$SPEC" \
  '         path="/ndt/link_recovery_detected", body=HOST_EDGE_PAYLOAD,' \
  '         path="/ndt/link_recovery_detectd", body=HOST_EDGE_PAYLOAD,' "$d"
report "M4: an endpoint path is mistyped" spec "$d" \
       "test_all_four_endpoints_have_a_dpid_zero_door"

d="$(fresh_copy m5)"
apply_exact "$SPEC" \
  '    return [e for e in ENDPOINTS if e["category"] in wanted]' \
  '    return sorted([e for e in ENDPOINTS if e["category"] in wanted], key=lambda e: e["name"])' \
  "$d"
report "M5: the table is sorted, so the sequence loses its order" spec "$d" \
       "test_the_six_steps_run_in_the_order_the_pairing_rule_needs"

d="$(fresh_copy m6)"
apply_exact "$SPEC" \
  '    if len(tc) != 2:' \
  '    if False:' "$d"
report "M6: the tc report need not cover both ends" selftest "$d" \
       "tc_half_is_reported_per_interface: catches one end cut instead of two"

d="$(fresh_copy m7)"
apply_exact "$SPEC" \
  '                  Str(allowed=("skipped (not MININET)",)))' \
  '                  Str(nonempty=True))' "$d"
report "M7: the skipped-tc string becomes a free-form excuse" spec "$d" \
       "test_the_tc_report_accepts_both_documented_shapes_and_no_third"

d="$(fresh_copy m8)"
apply_exact "$SPEC" \
  '    "until": Str(allowed=("/ndt/inject_link_recovery",)),' \
  '    "until": Str(nonempty=True),' "$d"
report "M8: the injection stops naming what can end it" spec "$d" \
       "test_the_injection_reply_must_name_the_only_endpoint_that_ends_it"

d="$(fresh_copy m9)"
apply_exact "$SPEC" \
  '    if data.get("declaration_retained"):' \
  '    return []  # MUTANT
    if data.get("declaration_retained"):' "$d"
report "M9: the PAIRED withdrawal check answers nothing" spec "$d" \
       "test_the_paired_withdrawal_must_not_decline"

d="$(fresh_copy m10)"
apply_exact "$SPEC" \
  '        if e.get("src_dpid") and e.get("dst_dpid")' \
  '        if True' "$d"
report "M10: the chosen link need not be switch-to-switch" spec "$d" \
       "test_the_mutating_sequence_names_one_switch_to_switch_link_of_this_topology"

d="$(fresh_copy m11)"
apply_exact "$SPEC" \
  '    return dict(link) if link else dict(NO_LINK_CHOSEN_PAYLOAD)' \
  '    return dict(link) if link else {"src_dpid": 1, "src_interface": 1, "dst_dpid": 5,
                                       "dst_interface": 1}' "$d"
report "M11: a topology with no switch link is guessed at" spec "$d" \
       "test_a_topology_with_no_switch_to_switch_link_is_refused_not_guessed"

d="$(fresh_copy m12)"
apply_exact "$SPEC" \
  '         invariants=[inv_recovery_was_declined_and_said_so],' \
  '         invariants=[inv_recovery_withdrew_the_declaration],' "$d"
report "M12: the declined step gets its sibling's invariant" spec "$d" \
       "test_the_declined_step_is_checked_by_the_invariant_written_for_it"

d="$(fresh_copy m13)"
apply_exact "$SPEC" \
  '    if "down_reason" not in data or "until" not in data:' \
  '    return []  # MUTANT
    if "down_reason" not in data or "until" not in data:' "$d"
report "M13: a kernel that never says the failure is sticky passes" selftest "$d" \
       "declared_failure_says_who_can_withdraw_it: reports trunk's bare status"

d="$(fresh_copy m14)"
apply_exact "$SPEC" \
  '         category=MUTATE, schema=LINK_FAILURE_INJECTED,' \
  '         category=READ, schema=LINK_FAILURE_INJECTED,' "$d"
report "M14: a read-only run would cut a real link" spec "$d" \
       "test_every_step_of_the_sequence_needs_allow_mutations"

d="$(fresh_copy m15)"
apply_exact "$SPEC" \
  '    dict(name="inject_link_recovery_cleanup", method="POST", path="/ndt/inject_link_recovery",' \
  '    dict(name="inject_link_recovery_cleanup", method="POST", path="/ndt/link_recovery_detected",' \
  "$d"
report "M15: the sequence ends where an injection cannot be ended" spec "$d" \
       "test_the_sequence_ends_with_a_withdrawal_that_needs_no_agreement"

# --- direction 2: widenings that must survive ---------------------------------------------------

echo
echo "direction 2 -- these must stay GREEN, or the tests are change detectors:"

d="$(fresh_copy w1)"
apply_exact "$SPEC" \
  '    if data.get("declaration_retained") is not True:' \
  '    # MUTANT: a comment, and nothing else.
    if data.get("declaration_retained") is not True:' "$d"
widen "W1: a comment" spec "$d"

d="$(fresh_copy w2)"
apply_exact "$SPEC" \
  '            "the recovery report was not declined: a failure injected through "' \
  '            "this recovery report did not decline: a failure injected through "' "$d"
widen "W2: the same finding, reworded" spec "$d"

d="$(fresh_copy w3)"
apply_exact "$SPEC" \
  '    "declaration_retained": Bool(),' \
  '    "declaration_retained": Bool(),
    "note": Str(),' "$d"
widen "W3: an added optional field" spec "$d"

d="$(fresh_copy w4)"
apply_exact "$FIXTURES" \
  '#: §2 success, the paired withdrawal.' \
  '#: §2 success -- the withdrawal that pairs with a reported failure.' "$d"
widen "W4: a reworded fixture comment" selftest "$d"

# --- verdict ------------------------------------------------------------------------------------

echo
if [[ "$(sha256sum "$SPEC" | cut -d' ' -f1)" == "$SPEC_SHA" &&
      "$(sha256sum "$FIXTURES" | cut -d' ' -f1)" == "$FIXTURES_SHA" ]]; then
    echo "baseline byte-identical: yes (no real file was written)"
else
    echo "🔴 baseline CHANGED -- a real file was written during the gate. Do NOT commit."
    exit 3
fi

echo
echo "=== verdict ==="
printf '  %s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %s widenings, %s wrongly caught\n' "$WIDENINGS" "$WRONGLY_CAUGHT"
[[ "$SURVIVORS" -eq 0 && "$WRONGLY_CAUGHT" -eq 0 ]]
