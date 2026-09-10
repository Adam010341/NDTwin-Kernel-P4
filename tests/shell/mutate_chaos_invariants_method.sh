#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_chaos_invariants_method.py (FINDINGS-ALL #17).
#
# [Co-developed with claude code -- Adam]
#
# The fix stops the chaos harness sending a method the kernel does not register, and stops the
# resulting 404/405 being read as a finding about NDTwin. Two ways a fix of that shape can be
# worthless, so the mutations run in BOTH directions:
#
#   M1-M8  put back one piece of the defect             -> a named case must go red
#   N1-N3  the OVER-CORRECTION, in three shapes         -> a named CONTROL case must go red
#
# The N block is the half that is easy to skip and the half that matters. "Refuse anything that
# is not a clean 200" passes every one of M1-M8 while turning INV-01 into a constant SKIPPED
# and breaking INV-03 and the B-3 control, both of which tolerate a non-200 on purpose. A
# constant SKIPPED is a worse instrument than the constant FAIL this change removes: it detects
# nothing and it looks careful. This harness has made that trade before -- a guard added to
# INV-06 on 2026-08-29 swallowed its own positive control within the hour.
#
# 🔴 Guards its own baseline. Mutations are applied to a COPY of the harness in a temp dir and
# the test is pointed at the copy with NDT_CHAOS_HARNESS; the files under
# doc/audit/2026-08-28_chaos-harness/harness/ are never written -- other sessions are reading
# this worktree right now. Anchor counts are still taken from the REAL files, so a reworded
# source reports a missing anchor here and in tests/shell/check_gate_anchors.py.
#
# NDT_KERNEL_REPO pins the route table to the real src/ndt_core/http/HttpSession.cpp, so a
# mutation to the harness never also mutates the authority the harness is checked against.
#
# Usage:  bash tests/shell/mutate_chaos_invariants_method.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

HARNESS_DIR=doc/audit/2026-08-28_chaos-harness/harness
PROBES="$HARNESS_DIR/probes.py"
INVARIANTS="$HARNESS_DIR/invariants.py"
ACTIONS="$HARNESS_DIR/actions.py"
TEST=tests/python/test_chaos_invariants_method.py
PY="${PY:-python3}"

BK="$(mktemp -d /tmp/chaos-method-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_PROBES="$(sha256sum "$PROBES" | cut -d' ' -f1)"
BASE_INV="$(sha256sum "$INVARIANTS" | cut -d' ' -f1)"
BASE_ACT="$(sha256sum "$ACTIONS" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0

# fresh_copy -- an unmutated copy of the harness in $BK/<tag>, and echo its path.
fresh_copy() {
    # Separate statements: `local a="$1" b="$BK/$a"` expands every word BEFORE assigning any,
    # so b would be built from an unset a -- which under `set -u` aborts inside a $( ) and
    # hands the caller an empty path.
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO/$HARNESS_DIR"/*.py "$dst"/
    echo "$dst"
}

# apply_exact <repo-relative file> <old> <new> <copy dir> -- assert the anchor is unique in the
# REAL file, then write the replacement into the copy. Never writes the real file. A
# substitution that matched nothing would leave the copy unmutated and score a green as
# "caught", which is the one result a gate must never produce by accident.
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
    out="$(NDT_CHAOS_HARNESS="$dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $want\b" <<<"$out"; then
        printf '  caught   %-62s (%s went red)\n' "$label" "$want"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-62s (%s stayed green -- that case proves nothing)\n' "$label" "$want"
        grep -E "^(FAIL|ERROR|OK|Ran )" <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base_dir="$(fresh_copy base)"
NDT_CHAOS_HARNESS="$base_dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" 2>&1 | tail -2 | sed 's/^/  /'
if ! NDT_CHAOS_HARNESS="$base_dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

# --- the defect itself: the wrong question, and the wrong reading of the answer -----------------

d="$(fresh_copy m1)"
apply_exact "$INVARIANTS" \
  '        _, dt = probes.api_post_checked_timed(' \
  '        _, dt = probes.api_get_timed(' "$d"
report "M1: back to GET at a POST-only route (the finding)" "$d" \
       "test_it_posts_with_ip_not_gets_with_dpid"

d="$(fresh_copy m2)"
apply_exact "$INVARIANTS" \
  '            f"/ndt/set_switches_power_state?ip={ip}&action=on", {})' \
  '            f"/ndt/set_switches_power_state?dpid={ip}&action=on", {})' "$d"
report "M2: back to dpid= at an ip-keyed handler" "$d" \
       "test_it_posts_with_ip_not_gets_with_dpid"

d="$(fresh_copy m3)"
apply_exact "$PROBES" \
  '    if table[name] != method:' \
  '    if False:' "$d"
report "M3: the guard stops comparing the verb" "$d" \
       "test_get_at_a_post_only_route_is_refused"

d="$(fresh_copy m4)"
apply_exact "$PROBES" \
  '    if name not in table:' \
  '    if False:' "$d"
report "M4: the guard stops checking that the route exists" "$d" \
       "test_an_unregistered_route_is_refused"

d="$(fresh_copy m5)"
apply_exact "$PROBES" \
  'class HarnessBug(Exception):' \
  'class HarnessBug(NotAnswered):' "$d"
report "M5: HarnessBug becomes a NotAnswered, so the lenient wrappers absorb it" "$d" \
       "test_harness_bug_is_not_a_notanswered"

d="$(fresh_copy m6)"
apply_exact "$INVARIANTS" \
  '                       f"the kernel refused this power-on rather than performing it ({e}), so "
                       f"no duration was measured and this check reaches no conclusion",' \
  '                       f"power-on answered in {e.status}; nothing was attempted (A-1 early return)",' "$d"
report "M6: the refusal is written up in the finding's own vocabulary" "$d" \
       "test_a_refusal_is_never_reported_as_an_early_return"

d="$(fresh_copy m7)"
apply_exact "$INVARIANTS" \
  '    except probes.NotAnswered as e:
        # 🔴 The wording is load-bearing' \
  '    except probes.NotAnswered as e:
        dt = 0.0
        return Finding("INV-01", FAIL,
                       f"power-on answered in {dt:.4f}s; nothing was attempted (A-1 early "
                       f"return)", {"elapsed_s": dt})
        # 🔴 The wording is load-bearing' "$d"
report "M7: a non-2xx is scored as the defect again" "$d" \
       "test_a_refusal_is_never_reported_as_an_early_return"

d="$(fresh_copy m8)"
apply_exact "$ACTIONS" \
  '                probes.api_post_checked(
                    f"/ndt/set_switches_power_state?ip={S1_MGMT_IP}&action=on", {})' \
  '                probes.api_get("/ndt/set_switches_power_state?dpid=1&action=on")' "$d"
report "M8: the FIFTH instance returns to _c01_undo's recovery path" "$d" \
       "test_every_kernel_call_uses_a_registered_method"

# --- 🔴 the other direction: the over-correction, in three shapes --------------------------------
# Every one of these passes M1-M8. Without the controls this gate would sign off on a harness
# that refuses everything -- which detects nothing and reads, in a report, exactly like a
# careful one.

d="$(fresh_copy n1)"
apply_exact "$PROBES" \
  '    if base != KERNEL:
        return' \
  '    if base != KERNEL:
        raise RouteNotRegistered(method, path, "not checked, so not permitted")' "$d"
report "N1 (control): the guard refuses everything it cannot verify" "$d" \
       "test_the_proxy_is_out_of_scope_and_passes"

d="$(fresh_copy n2)"
apply_exact "$PROBES" \
  '    try:
        return api_get_checked(path, base)
    except NotAnswered:
        return None' \
  '    return api_get_checked(path, base)' "$d"
report "N2 (control): every non-2xx refused, incl. a legitimate 404 for a missing flow" "$d" \
       "test_a_legitimate_404_still_comes_back_as_none"

d="$(fresh_copy n3)"
apply_exact "$INVARIANTS" \
  '    ev = {"elapsed_s": round(dt, 4), "ip": ip}' \
  '    return Finding("INV-01", SKIPPED, "cannot decide", {"elapsed_s": round(dt, 4)})
    ev = {"elapsed_s": round(dt, 4), "ip": ip}' "$d"
report "N3 (control): INV-01 becomes a constant SKIPPED and can never fire" "$d" \
       "test_a_genuine_fast_success_is_still_a_finding"

echo
ok=1
[[ "$(sha256sum "$PROBES"     | cut -d' ' -f1)" == "$BASE_PROBES" ]] || { echo "🔴 baseline CHANGED -- $PROBES was written during the gate"; ok=0; }
[[ "$(sha256sum "$INVARIANTS" | cut -d' ' -f1)" == "$BASE_INV"    ]] || { echo "🔴 baseline CHANGED -- $INVARIANTS was written during the gate"; ok=0; }
[[ "$(sha256sum "$ACTIONS"    | cut -d' ' -f1)" == "$BASE_ACT"    ]] || { echo "🔴 baseline CHANGED -- $ACTIONS was written during the gate"; ok=0; }
[[ "$ok" == 1 ]] || exit 3
echo "baseline byte-identical: yes (probes.py, invariants.py, actions.py)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
