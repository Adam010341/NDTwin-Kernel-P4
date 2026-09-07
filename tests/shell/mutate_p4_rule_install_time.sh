#!/usr/bin/env bash
#
# Mutation gate for p4_proxy/tests/test_rule_install_times.py and the duration cases in
# p4_proxy/tests/test_ryu_flow_stats.py.
#
# [Co-developed with claude code -- Adam]
#
# KNOWN-ISSUES G-13. A bmv2 table entry has no age, so ryu_flow_stats hardcoded
# `duration_sec: 0, duration_nsec: 0` and every rule on the P4 plane looked equally new --
# measured 2026-09-07 (W16-3): a route installed, read back at +12 s and +32 s, 0/0 both times
# for it and for every rule already on the switch, while its counters moved. The fix is a record
# the proxy keeps at install time, which the flow-stats renderer subtracts from.
#
# 🔴 Two directions, because this defect's failure mode is silence. Every mutation labelled M
# puts one piece of the defect back. Every mutation labelled N is an implementation that records
# MORE or claims MORE -- one that dates a write the switch refused, one that restarts a rule's
# clock every time the link watchdog rewrites it, one that hands an unrecorded rule an age
# anyway. None of those is caught by the M cases, and every one of them ends with a number in
# `duration_sec` that is confidently wrong rather than honestly absent.
#
# 🔴 N2 and N3 are the two halves of "the clock restarts", and BOTH are now mutations. Adam
# ruled on 2026-09-08 (DECISIONS.md) that a P4 rule's duration is counted from the first write
# the switch accepted and never restarts -- for agreement with OVS, where duration is the
# switch's own and OpenFlow counts it from the ADD. An earlier version of this gate required a
# reroute to restart it; that requirement is now itself the thing that must go red.
#
# 🔴 And a third shape, the one specific to this fix: the write side and the read side must
# compute the SAME key. When they do not -- a table name spelled differently, a priority the
# switch reports as 0, raw bytes compared against a read-back bmv2 has canonicalised -- every
# lookup misses and every rule reports 0/0, which is *identical to the defect*. M8, M9 and N5
# are those, and they are the reason the tests drive the real client and then look the entry up
# in the shape read_table_entries returns.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY of p4_proxy under a temp dir
# and the tests are run there. Nothing under p4_proxy/ is written -- another session may be
# executing those files right now -- and the four source files are re-hashed at the end.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TIMES="$REPO/p4_proxy/proxy_agent/rule_install_times.py"
STATS="$REPO/p4_proxy/proxy_agent/ryu_flow_stats.py"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
TOPO="$REPO/p4_proxy/proxy_agent/topology_manager.py"
TEST_TIMES="$REPO/p4_proxy/tests/test_rule_install_times.py"
TEST_STATS="$REPO/p4_proxy/tests/test_ryu_flow_stats.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
TEST_STATE="$REPO/p4_proxy/tests/test_switch_state.py"
# One class of test_switch_state rather than the module: the rest of that file drives the
# background prober through real threads and costs about six seconds a run, which this gate pays
# once per mutation. Naming the class is more precise, not less -- the whole module still runs in
# the suite. [Co-developed with claude code -- Adam]
MODULES="tests.test_rule_install_times tests.test_ryu_flow_stats tests.test_p4_client_writes \
tests.test_switch_state.TheRuleClockOnTheLivenessPayloadTest"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up -- asked of git
# rather than spelled as somebody's home directory, which would make this gate runnable on one
# machine. Override with PROXY_PY= .
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no interpreter with fastapi/networkx/grpc. Set PROXY_PY=<path>." >&2
    echo "        A gate that cannot run its tests has not checked anything, so it does not" >&2
    echo "        get to exit 0." >&2
    exit 2
}
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-installtime-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_TIMES=$(sha256sum "$TIMES" | cut -d' ' -f1)
BASE_STATS=$(sha256sum "$STATS" | cut -d' ' -f1)
BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_TOPO=$(sha256sum "$TOPO" | cut -d' ' -f1)
BASE_TEST_TIMES=$(sha256sum "$TEST_TIMES" | cut -d' ' -f1)
BASE_TEST_STATS=$(sha256sum "$TEST_STATS" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TEST_STATE=$(sha256sum "$TEST_STATE" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

# The tests import proxy_agent the way the proxy is launched, so the mutant needs the package,
# the tests beside it, and mininet/ (imported for host_count_override and grpc_ports.py).
# PYTHONDONTWRITEBYTECODE so a mutant cannot be run from a .pyc of its unmutated self.
run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest $MODULES -v 2>&1 )
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-64s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-64s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole copy of p4_proxy's importable tree: the record, the renderer, the client
# and the route are four links in one chain, and a mutation to any of them has to be exercised
# through the real import rather than through a stub of the other three. The anchor must be
# unique, so a mutation cannot quietly land somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from a function's
# own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is not checking
# (finding #28).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself: no clock on the P4 plane ---------------------------------------------

m=$(mutant m1 "$CLIENT" \
    '            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Added route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")' \
    '            print(f"[{self.device_id}] Added route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")')
report "M1: an accepted route install is not recorded at all" "$m" \
       "test_an_accepted_route_install_is_dated"

m=$(mutant m2 "$STATS" \
    '        "duration_sec": duration_sec,
        "duration_nsec": duration_nsec,' \
    '        "duration_sec": 0,
        "duration_nsec": 0,')
report "M2: the renderer emits 0/0 again, record or no record (the line as it stood)" "$m" \
       "test_a_rule_this_proxy_installed_reports_how_long_ago"

m=$(mutant m3 "$TIMES" \
    '        if installed_at is None:
            return None
        return max(0.0, self._monotonic() - installed_at)' \
    '        if installed_at is None:
            return max(0.0, self._monotonic())
        return max(0.0, self._monotonic() - installed_at)')
report "M3: a rule nobody recorded is given an age anyway (widening)" "$m" \
       "test_a_rule_with_no_record_stays_zero_which_is_what_unknown_looks_like"

m=$(mutant m4 "$TIMES" \
    '    return (str(dpid), str(table), int(priority or 0), normalise_match(match))' \
    '    return (str(dpid), str(table), int(priority or 0))')
report "M4: the key drops the match, so one table is one rule" "$m" \
       "test_two_rules_in_one_table_at_one_priority_do_not_share_an_age"

m=$(mutant m5 "$ROUTES" \
    '        return ryu_flow_stats.render_flow_stats(dpid, client.read_table_entries(),
                                                install_times=client.rule_install_times)' \
    '        return ryu_flow_stats.render_flow_stats(dpid, client.read_table_entries())')
report "M5: the endpoint stops passing the record (finding #71 again)" "$m" \
       "test_a_rule_the_client_installed_comes_back_with_its_age"

m=$(mutant m6 "$CLIENT" \
    '            self._forget_route(dst_ip, prefix_len)
            print(f"[{self.device_id}] Deleted route: {dst_ip}/{prefix_len}")' \
    '            print(f"[{self.device_id}] Deleted route: {dst_ip}/{prefix_len}")')
report "M6: a deleted route keeps its stamp, to be inherited by the next rule" "$m" \
       "test_an_accepted_delete_takes_the_date_away"

m=$(mutant m7 "$CLIENT" \
    '            self.rule_install_times.record(
                self.device_id, self.FIVE_TUPLE_TABLE, priority, self._five_tuple_match(keys))
            print(f"[{self.device_id}] Added 5-tuple rule prio={priority} "' \
    '            print(f"[{self.device_id}] Added 5-tuple rule prio={priority} "')
report "M7: the 5-tuple branch does not record (nothing else knows)" "$m" \
       "test_an_accepted_five_tuple_install_is_dated"

# --- 🔴 the two sides drifting apart: the failure that looks exactly like the defect ---------

m=$(mutant m8 "$CLIENT" \
    '    LPM_ENTRY_PRIORITY = 0' \
    '    LPM_ENTRY_PRIORITY = 1')
report "M8: the write side records a priority the switch never reports" "$m" \
       "test_an_accepted_route_install_is_dated"

m=$(mutant m9 "$CLIENT" \
    '    IPV4_LPM_TABLE = "MyIngress.ipv4_lpm"' \
    '    IPV4_LPM_TABLE = "ipv4_lpm"')
report "M9: the write side spells the table name its own way" "$m" \
       "test_an_address_with_a_leading_zero_octet_is_found_after_bmv2_canonicalises_it"

m=$(mutant m10 "$CLIENT" \
    '                self.device_id, self.FIVE_TUPLE_TABLE, priority, self._five_tuple_match(keys))
            print(f"[{self.device_id}] Added 5-tuple rule prio={priority} "' \
    '                self.device_id, self.FIVE_TUPLE_TABLE, 0, self._five_tuple_match(keys))
            print(f"[{self.device_id}] Added 5-tuple rule prio={priority} "')
report "M10: the 5-tuple record drops the priority the entry is identified by" "$m" \
       "test_an_accepted_five_tuple_install_is_dated"

# --- 🔴 the other direction: record MORE, claim MORE, in seven shapes -------------------------
# Each of these passes every mutation above. Without them this gate would sign off on a record
# that is diligently kept and reports numbers nobody should believe.

m=$(mutant n1 "$CLIENT" \
    '            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Added route:' \
    '            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            print(f"[{self.device_id}] Added route:')
report "N1 (control): the stamp is written before the switch has accepted anything" "$m" \
       "test_a_refused_route_install_is_not_dated"

m=$(mutant n2 "$TIMES" \
    '            if key not in self._at:
                self._at[key] = self._monotonic()' \
    '            self._at[key] = self._monotonic()')
report "N2 (control): a second write of the same entry restarts the clock" "$m" \
       "test_an_idempotent_rewrite_does_not_restart_the_clock"

# Adam ruled on 2026-09-08 that duration never restarts, against this gate's earlier N3, which
# required a reroute to restart it. The mutation is therefore inverted: a modify that forgets
# first is the implementation Adam ruled out, and it must now go red. It is at the client layer
# because that is the only layer where a reroute is still a distinguishable call -- record()
# takes no action argument any more, so the record itself cannot tell one write from another.
m=$(mutant n3 "$CLIENT" \
    '            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Modified route:' \
    '            self._forget_route(dst_ip, prefix_len)
            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Modified route:')
report "N3 (control): a reroute restarts the clock (the design Adam ruled out)" "$m" \
       "test_an_app_rerouting_a_destination_does_not_make_the_rule_look_new"

m=$(mutant n4 "$CLIENT" \
    '        self.rule_install_times.clear()' \
    '        pass')
report "N4 (control): the pipeline wipe leaves stamps for rules it destroyed" "$m" \
       "test_the_pipeline_push_forgets_every_rule_it_destroyed"

m=$(mutant n5 "$TIMES" \
    '              if not is_dont_care(spec)]' \
    '              if True]')
report "N5 (control): the key keeps wildcards the renderer drops (the two sides drift)" "$m" \
       "test_a_zero_masked_ternary_field_is_not_part_of_the_entry"

m=$(mutant n6 "$STATS" \
    '    age = max(0.0, float(age_seconds))' \
    '    age = float(age_seconds)')
report "N6 (control): a negative age reaches an unsigned field" "$m" \
       "test_a_negative_age_can_never_reach_the_payload"

m=$(mutant n7 "$TIMES" \
    '        return max(0.0, self._monotonic() - installed_at)' \
    '        return self._monotonic() - installed_at')
report "N7 (control): the record itself can report a negative age" "$m" \
       "test_a_clock_that_went_backwards_reports_zero_rather_than_a_negative_age"

m=$(mutant n8 "$STATS" \
    '        "duration_nsec": duration_nsec,' \
    '        "duration_nsec": 0,')
report "N8 (control): the sub-second remainder is thrown away" "$m" \
       "test_the_sub_second_remainder_goes_into_duration_nsec"

m=$(mutant n9 "$TIMES" \
    '    return (str(dpid), str(table), int(priority or 0), normalise_match(match))' \
    '    return ("", str(table), int(priority or 0), normalise_match(match))')
report "N9 (control): the key forgets which switch, so ten switches share one table" "$m" \
       "test_a_different_switch_is_a_different_entry"

# --- 🔴 the denominator: is 0/0 an old rule, or one this proxy never wrote? -------------------
#
# Everything above makes the record correct. It does not make the record READABLE: `duration 0/0`
# on the wire is the same eleven characters whether the rule predates this proxy or was installed
# a moment ago, and an operator holding only /stats/flow/<dpid> cannot tell. GET /p4/switch_state
# answers it with `rules_timed` out of `rules_total`, and every mutation below is a way of
# serving that pair while saying less than it appears to say -- the field missing, the numerator
# taken from the denominator, an uncounted switch reported as an empty one, the reach of the
# record taken from the wrong end of it. None of them is caught by anything above.

m=$(mutant m11 "$TOPO" \
    '                    "rules_timed": rules_timed,
                    "rules_total": rules_total,
                    "rules_total_age_s": rules_total_age_s,' \
    '')
report "M11: the liveness payload does not carry the counts at all" "$m" \
       "test_the_count_is_of_records_not_of_the_rows_on_the_switch"

m=$(mutant m12 "$TOPO" \
    '                    rules_timed = len(install_times)' \
    '                    rules_timed = rules_total')
report "M12: rules_timed is taken from the row count, so every table looks fully dated" "$m" \
       "test_the_count_is_of_records_not_of_the_rows_on_the_switch"

m=$(mutant m13 "$CLIENT" \
    '        self._last_table_read = (len(entries), time.monotonic())
        return entries' \
    '        return entries')
report "M13: reading the table does not count its rows, so there is no denominator" "$m" \
       "test_a_table_read_records_how_many_rows_it_returned"

m=$(mutant n10 "$TOPO" \
    '                rules_total, rules_total_age_s = None, None' \
    '                rules_total, rules_total_age_s = 0, 0.0')
report "N10 (control): a switch nobody has read is reported as a switch with no rules" "$m" \
       "test_a_switch_whose_tables_nobody_has_read_reports_no_total_rather_than_zero"

m=$(mutant n11 "$TIMES" \
    '            oldest = min(self._at.values(), default=None)' \
    '            oldest = max(self._at.values(), default=None)')
report "N11 (control): the reach of the record is read off its newest stamp" "$m" \
       "test_the_oldest_stamp_is_reported_not_the_newest"

m=$(mutant n12 "$CLIENT" \
    '        # "nobody has counted since the wipe", until the next read counts.
        self._last_table_read = None' \
    '        # "nobody has counted since the wipe", until the next read counts.
        pass')
report "N12 (control): the pipeline wipe keeps the row count of the table it destroyed" "$m" \
       "test_the_pipeline_push_also_drops_the_row_count_that_record_is_reported_against"

m=$(mutant n13 "$CLIENT" \
    '        return rows, max(0.0, time.monotonic() - at)' \
    '        return rows, 0.0')
report "N13 (control): the row count is served with no age, so a stale one reads as fresh" "$m" \
       "test_the_age_of_the_count_advances_with_the_clock"

echo
[[ "$(sha256sum "$TIMES" | cut -d' ' -f1)" == "$BASE_TIMES" ]] || { echo "🔴 baseline CHANGED -- rule_install_times.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$STATS" | cut -d' ' -f1)" == "$BASE_STATS" ]] || { echo "🔴 baseline CHANGED -- ryu_flow_stats.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPO" | cut -d' ' -f1)" == "$BASE_TOPO" ]] || { echo "🔴 baseline CHANGED -- topology_manager.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_TIMES" | cut -d' ' -f1)" == "$BASE_TEST_TIMES" ]] || { echo "🔴 baseline CHANGED -- test_rule_install_times.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STATS" | cut -d' ' -f1)" == "$BASE_TEST_STATS" ]] || { echo "🔴 baseline CHANGED -- test_ryu_flow_stats.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STATE" | cut -d' ' -f1)" == "$BASE_TEST_STATE" ]] || { echo "🔴 baseline CHANGED -- test_switch_state.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (5 sources, 4 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
