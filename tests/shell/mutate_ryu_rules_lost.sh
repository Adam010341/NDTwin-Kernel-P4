#!/usr/bin/env bash
#
# Mutation gate for p4_proxy/tests/test_ryu_rules_lost.py.
#
# [Co-developed with claude code -- Adam]
#
# KNOWN-ISSUES A-4c: a pipeline push that empties a switch reports the
# rules it took of those written through /stats/flowentry/*, and replays none. Each mutation below
# puts back one way of getting that wrong -- silent again, loud about the wrong rules, or quietly
# replaying -- and must turn its named case red.
#
# Guards its own baseline: every mutation is applied to a COPY of p4_proxy under a temp dir and the
# test runs there. Nothing under p4_proxy/ is written, and the source files are re-hashed at the
# end. An anchor that no longer matches exactly once is reported as ANCHOR and fails the gate: a
# mutant that could not be applied is the baseline, and would otherwise read as a survivor that
# says nothing about the test.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
TOPO="$REPO/p4_proxy/proxy_agent/topology_manager.py"
JOURNAL="$REPO/p4_proxy/proxy_agent/rule_journal.py"
TEST="$REPO/p4_proxy/tests/test_ryu_rules_lost.py"
MODULE="tests.test_ryu_rules_lost"

MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python3"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || { echo "REFUSE: no interpreter with fastapi/networkx/grpc; set PROXY_PY" >&2; exit 2; }
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-ryu-lost-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
ln -s "$REPO/setting" "$BK/setting"
declare -A BASE
for f in "$MAIN" "$TOPO" "$JOURNAL" "$TEST"; do BASE[$f]=$(sha256sum "$f" | cut -d' ' -f1); done

SURVIVORS=0
MUTATIONS=0
CONTROL_RED=0

run_against() {
    ( cd "$1" && NDTWIN_RULE_JOURNAL_PATH="$1/.rule_journal.jsonl" PYTHONPATH="$1" \
        PYTHONDONTWRITEBYTECODE=1 timeout 300 "$PY" -m unittest "$MODULE" -v 2>&1 )
}

copy_proxy() {
    mkdir -p "$1"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$1/"
    [[ -e "$REPO/p4_proxy/p4_src" ]] && cp -rL "$REPO/p4_proxy/p4_src" "$1/" 2>/dev/null
    find "$1" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
}

# $1 label, $2 file, $3 anchor, $4 replacement, $5 the case that must go red
mutate() {
    local label="$1" file="$2" old="$3" new="$4" must="$5" d="$BK/$1" out rc
    MUTATIONS=$((MUTATIONS+1))
    copy_proxy "$d"
    if ! python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(a) != 1:
    sys.exit("anchor hits %d" % s.count(a))
open(p, "w").write(s.replace(a, b))
PY
    then
        SURVIVORS=$((SURVIVORS+1)); printf '  ANCHOR   %-66s (could not be applied)\n' "$label"; return
    fi
    out=$(run_against "$d"); rc=$?
    if [[ "$must" == "-" ]]; then
        # A control: a change that changes nothing. Red here means the gate reports red for
        # everything, and its "caught" lines prove nothing. [Co-developed with claude code -- Adam]
        MUTATIONS=$((MUTATIONS-1))
        if [[ "$rc" -eq 0 ]]; then
            printf '  control  %-66s (stayed green, as it must)\n' "$label"
        else
            CONTROL_RED=$((CONTROL_RED+1))
            printf '  🔴 CONTROL RED %-60s\n' "$label"
            grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
        fi
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $must " <<<"$out"; then
        printf '  caught   %-66s (%s went red)\n' "$label" "$must"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (%s stayed green)\n' "$label" "$must"
        grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
copy_proxy "$BK/base"
base_out=$(run_against "$BK/base"); base_rc=$?
grep -E '^(Ran |OK|FAILED)' <<<"$base_out"
[[ "$base_rc" -eq 0 ]] || { echo "  baseline is RED -- mutations prove nothing on a red baseline"; exit 2; }
echo

mutate "R1: a wipe marker does not close the switch's generation" "$JOURNAL" \
'            since, unreadable = [], 0' \
'            unreadable = 0' \
  test_only_records_after_the_last_marker_count

mutate "R2: every generation's records count (no cookie check)" "$JOURNAL" \
'        if entry.get("op") not in _FOLD_OP or not _same_cookie(entry.get("cookie"), cookie):' \
'        if entry.get("op") not in _FOLD_OP:' \
  test_a_record_of_another_generation_is_not_counted

mutate "R3: a record without a cookie matches a switch without one" "$JOURNAL" \
'    if recorded is None or wiped is None:
        return False' \
'    if recorded is None or wiped is None:
        return recorded == wiped' \
  test_a_record_without_a_cookie_is_never_counted

mutate "R4: records are listed, not folded (install+delete still lost)" "$JOURNAL" \
'    for item in fold_records(records):' \
'    for item in records:' \
  test_an_install_later_deleted_is_not_lost

mutate "R5: wiped() reports but leaves no marker" "$JOURNAL" \
'                        self._append_marker_locked(marker_line)' \
'                        pass' \
  test_a_second_push_of_the_same_switch_finds_nothing_left

mutate "R6: record() stops writing the cookie" "$JOURNAL" \
'            "cookie": cookie,
            "rule": rule,' \
'            "rule": rule,' \
  test_the_cookie_is_recorded_with_each_write

mutate "R7: the record lists every lost rule (no cap)" "$JOURNAL" \
'            "rules": list(lost[:LOST_RULES_SHOWN]),' \
'            "rules": list(lost),' \
  test_the_count_is_whole_and_the_list_is_capped

mutate "R8: replay hands markers to its applier" "$JOURNAL" \
'        entries = [e for e in entries if e.get("op") != WIPED_OP]
' \
'' \
  test_a_replay_never_hands_a_marker_to_its_applier

mutate "R9: a net delete is reported as a lost rule" "$JOURNAL" \
'        if item["op"] == "delete":
            continue
' \
'' \
  test_a_lone_delete_is_not_a_loss

mutate "R10: an unreadable line before the mark is counted again" "$JOURNAL" \
'            since, unreadable = [], 0' \
'            since = []' \
  test_a_torn_line_before_the_mark_is_not_counted_again

mutate "R11: the fold ignores the recorded rule identity" "$JOURNAL" \
'    if rule is not None:' \
'    if False:' \
  test_a_recorded_rule_identity_outranks_match_and_priority

mutate "R12: a failed push marks the switch anyway" "$JOURNAL" \
'                if mark:' \
'                if True:' \
  test_an_unmarked_wipe_leaves_the_rules_for_the_next_one

mutate "R13: a COOKIE_ONLY that failed for any reason reads as a fresh bmv2" "$JOURNAL" \
'    if "FAILED_PRECONDITION" in text:' \
'    if True:' \
  test_a_switch_that_could_not_be_asked_reports_an_unknown_count

mutate "R14: a fresh bmv2 is treated as a switch that could not be asked" "$JOURNAL" \
'    if "FAILED_PRECONDITION" in text:' \
'    if False:' \
  test_a_fresh_bmv2_reports_nothing

mutate "T1: the manager journals writes without their client's cookie" "$TOPO" \
'                                 cookie=getattr(self.switches.get(dpid), "pipeline_cookie",
                                                None),' \
'                                 cookie=None,' \
  test_a_ryu_write_is_journaled_under_its_clients_cookie

mutate "T2: readopt never closes the generation (silent again)" "$TOPO" \
'            ryu_lost = self.close_ryu_generation(dpid, getattr(old, "pipeline_cookie", None),
                                                 "readopt", new)' \
'            ryu_lost = None' \
  test_a_readopt_reports_the_rules_it_wiped

mutate "T3: the close replays what it found" "$TOPO" \
'        lost, unreadable = self._journal.wiped(dpid, wiped_cookie, cause, mark=not push_failed)
' \
'        lost, unreadable = self._journal.wiped(dpid, wiped_cookie, cause, mark=not push_failed)
        for _r in lost:
            self.route_flow(dpid, _r["match"], _r["actions"], _r["priority"])
' \
  test_a_readopt_replays_nothing

mutate "T4: switch_liveness drops the key" "$TOPO" \
'                    "ryu_rules_lost": self._ryu_rules_lost.get(dpid),' \
'' \
  test_before_any_push_the_switch_reports_null

mutate "T5: the record is not kept for switch_state" "$TOPO" \
'        self._ryu_rules_lost[dpid] = record' \
'        pass' \
  test_the_record_reaches_switch_state

mutate "T6: the restore branch of a delete is not journaled" "$TOPO" \
'                return self._note_in_journal("delete", dpid, match_dict, [], priority, success)' \
'                return success' \
  test_install_then_nonstrict_delete_on_a_routed_destination_loses_nothing

mutate "T7: an ipv4_lpm entry is keyed by priority as well as destination" "$TOPO" \
'    return ["ipv4_lpm", dst]' \
'    return ["ipv4_lpm", dst, priority]' \
  test_install_then_nonstrict_delete_on_an_unrouted_destination_loses_nothing

mutate "T8: the same, seen through install then modify" "$TOPO" \
'    return ["ipv4_lpm", dst]' \
'    return ["ipv4_lpm", dst, priority]' \
  test_install_then_modify_is_one_lost_rule

mutate "T9: a write the journal refused is not counted" "$TOPO" \
'            self._journal_write_failures[dpid] = self._journal_write_failures.get(dpid, 0) + 1' \
'            pass' \
  test_a_write_the_journal_refused_marks_the_next_count_incomplete

mutate "T10: a readopt whose push raised reports nothing" "$TOPO" \
'                if pushing:' \
'                if False:' \
  test_a_readopt_whose_push_raised_reports_an_unknown_count

mutate "T11: readopt swaps the client in before it closes the generation" "$TOPO" \
'            ryu_lost = self.close_ryu_generation(dpid, getattr(old, "pipeline_cookie", None),' \
'            with self._liveness_lock:
                self.switches[dpid] = new
            ryu_lost = self.close_ryu_generation(dpid, getattr(old, "pipeline_cookie", None),' \
  test_the_generation_is_closed_before_the_new_client_takes_writes

mutate "T12: a count the proxy cannot know is reported as known" "$TOPO" \
'                                          count_known=reason is None, unknown_reason=reason,' \
'                                          count_known=True, unknown_reason=reason,' \
  test_a_switch_whose_push_raised_reports_an_unknown_count

mutate "S1: startup never closes the generation (silent again)" "$MAIN" \
'        close = getattr(topo, "close_ryu_generation", None)' \
'        close = None' \
  test_a_restart_over_a_running_switch_reports_its_rules

mutate "S2: startup uses the cookie it just pushed, not the one the switch held" "$MAIN" \
'            close(i, before["cookie"], "proxy_restart", client, cookie_unknown=before["unknown"])' \
'            close(i, client.pipeline_cookie, "proxy_restart", client, cookie_unknown=before["unknown"])' \
  test_a_restart_over_a_running_switch_reports_its_rules

mutate "S3: confirm_fabric does not record what each switch held" "$MAIN" \
'    _cookies_before_push.update(seen_before)' \
'    pass' \
  test_a_restart_over_a_running_switch_reports_its_rules

mutate "S4: a switch whose push raised reports nothing" "$MAIN" \
'                close(i, before["cookie"], "proxy_restart", client, push_failed=True)' \
'                pass' \
  test_a_switch_whose_push_raised_reports_an_unknown_count

mutate "S5: startup forgets why the cookie could not be read" "$MAIN" \
'            close(i, before["cookie"], "proxy_restart", client, cookie_unknown=before["unknown"])' \
'            close(i, before["cookie"], "proxy_restart", client)' \
  test_a_switch_that_could_not_be_asked_reports_an_unknown_count

mutate "C1: control -- a comment above the unreadable-line scan (must stay green)" "$JOURNAL" \
'def _since_last_wipe(scanned, dpid):' \
'# control: nothing changes here
def _since_last_wipe(scanned, dpid):' \
  -

echo
for f in "$MAIN" "$TOPO" "$JOURNAL" "$TEST"; do
    [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "${BASE[$f]}" ]] || { echo "🔴 baseline CHANGED -- $f"; exit 3; }
done
echo "baseline byte-identical: yes (main.py, topology_manager.py, rule_journal.py, the test)"
if [[ "$SURVIVORS" -eq 0 && "$CONTROL_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; control green"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROL_RED control(s) red"; exit 1
fi
