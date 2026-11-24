#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_ndtwin_sdk_of.py (`k.of.write`, sdk/python/ndtwin/of.py).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way `k.of.write` can tell an app something the kernel did not say:
# a refusal read as "may have landed" or the reverse, a POST sent twice, a write that
# returns before the kernel's dispatch record says what happened, a switch said to hold a rule on
# OVS, a lab claim read from the wrong place, an entry sent that the kernel or the controller would
# not do as written, a reply the SDK cannot read taken as an answer. Each must turn its NAMED test red; a mutation caught by some other test says
# nothing about the test that was supposed to own it.
#
# 🔴 Mutations are applied to COPIES of sdk/python/ndtwin in a temp dir, and the suite is pointed
#    at a copy with NDTWIN_SDK_UNDER_TEST; no source file is written, and the sha256 of every SDK
#    file is compared at the end. The suite runs with PYTHONDONTWRITEBYTECODE=1, so nothing is
#    written under the worktree either.
# 🔴 Each mutated copy must compile (`python -m py_compile`) and `import ndtwin` before it is
#    scored: one that does not is NOT APPLIED, never caught. A mutation that will not apply, a
#    non-unique anchor, or the wrong test going red fails the gate. A comment-only edit is the
#    control and must stay green.
# 🔴 Touches no lab and no network beyond 127.0.0.1: the suite's kernel is an in-process fake.
#
# Env:  PYTHON=<interpreter>       the suite's interpreter (default python3)
#       MUTANT_EVIDENCE=<dir>      keeps each mutant as <label>.patch and the suite's output as <label>.log
# Exit: 0 every mutation caught and the control stayed green, 1 a mutation survived or was not
#       applied (or the control went red), 2 refused (baseline red / harness), 3 the SDK changed
#       while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SDK="$REPO/sdk/python/ndtwin"
OF="$REPO/sdk/python/ndtwin/of.py"
SUITE="$REPO/tests/python/test_ndtwin_sdk_of.py"
PY="${PYTHON:-python3}"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndtwin-sdk-of-mutate-XXXXXX")
trap 'rm -rf "${BK:?}"' EXIT

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$OF" && -f "$SUITE" ]] || { echo "🔴 missing $OF or $SUITE" >&2; exit 2; }
sdk_sums() { (cd "$SDK" && sha256sum ./*.py); }
BASE_SUMS=$(sdk_sums)

CAUGHT=0
SURVIVED=0
NOT_APPLIED=0
CONTROL_RED=0

run_suite() {   # <copy dir> -- the suite against that copy's SDK
    (cd "$REPO" && NDTWIN_SDK_UNDER_TEST="$1/sdk/python" PYTHONDONTWRITEBYTECODE=1 \
        timeout 300 "$PY" "$SUITE" -v 2>&1)
}

tree() {   # <dir> -- a copy of the SDK package in the repo's layout
    mkdir -p "$1/sdk/python"
    cp -r "$SDK" "$1/sdk/python/"
    find "$1/sdk/python" -name __pycache__ -prune -exec rm -rf {} +
}

red_test() {   # <log text> <Class.test> -- whether that test FAILED or ERRORed
    local cls="${2%%.*}" fn="${2#*.}"
    grep -qE "^(FAIL|ERROR): ${fn} \\(__main__\\.${cls}[.)]" <<<"$1"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test that must go red (Class.test)
    local out rc
    if [[ ! -f "$2/APPLIED" ]]; then
        NOT_APPLIED=$((NOT_APPLIED+1))
        printf '  NOT APPLIED %-62s (the mutant did not apply, compile or import)\n' "$1"; return
    fi
    out=$(run_suite "$2"); rc=$?
    if [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        { printf '%s\nthe test that must go red: %s\n\n' "$1" "$3"; printf '%s\n' "$out"
          echo "exit code: $rc"; } > "$MUTANT_EVIDENCE/$(basename "$2").log"
    fi
    if [[ "$rc" -ne 0 ]] && red_test "$out" "$3"; then
        CAUGHT=$((CAUGHT+1))
        printf '  caught      %-62s (%s went red)\n' "$1" "$3"
    else
        SURVIVED=$((SURVIVED+1))
        printf '  SURVIVED    %-62s (%s stayed green -- that test proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR):|^Ran ' <<<"$out" | sed 's/^/                /'
    fi
}

control() {   # $1 = name, $2 = mutant dir -- must NOT turn the suite red
    local out rc
    if [[ ! -f "$2/APPLIED" ]]; then
        CONTROL_RED=$((CONTROL_RED+1)); printf '  🔴 CONTROL NOT APPLIED %s\n' "$1"; return
    fi
    out=$(run_suite "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green       %-62s (control, as required)\n' "$1"
    else
        CONTROL_RED=$((CONTROL_RED+1))
        printf '  🔴 CONTROL WENT RED %s\n' "$1"
        grep -E '^(FAIL|ERROR):|^Ran ' <<<"$out" | sed 's/^/                /'
    fi
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    tree "$d"
    local target="$d/${file#"$REPO"/}"
    if python3 - "$target" "$old" "$new" <<'PY' >&2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        if "$PY" -m py_compile "$target" >&2 \
                && (cd "$d" && PYTHONPATH="$d/sdk/python" PYTHONDONTWRITEBYTECODE=1 \
                    "$PY" -c "import ndtwin" >&2); then
            touch "$d/APPLIED"
        fi
        find "$d/sdk/python" -name __pycache__ -prune -exec rm -rf {} +
        if [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
            mkdir -p "$MUTANT_EVIDENCE"
            diff -u --label "a/${file#"$REPO"/}" --label "b/${file#"$REPO"/}" "$file" "$target" \
                > "$MUTANT_EVIDENCE/$label.patch"
        fi
    fi
    echo "$d"
}

echo "interpreter: $("$PY" -c 'import sys; print(sys.executable, sys.version.split()[0])')"
echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; tree "$base"
base_out=$(run_suite "$base"); base_rc=$?
grep -E '^Ran |^OK|^FAILED' <<<"$base_out" | sed 's/^/  /'
[[ "$base_rc" -eq 0 ]] || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- the POST -----------------------------------------------------------------------------------
m=$(mutant o1 "$OF" \
    '    if err.status == 400 and body.get("error") == "JSON parsing error":' \
    '    if False:')
report "O1: a 400 JSON parsing error is read as Refused" "$m" \
       "PostRepliesTest.test_a_json_parsing_error_is_outcome_unknown_and_not_sent_again"

m=$(mutant o2 "$OF" \
    '    if err.status >= 500:' \
    '    if err.status >= 500:
        return _again(Refused, err, "refused", True)
    if False:')
report "O2: a POST 500 is read as Refused" "$m" \
       "PostRepliesTest.test_a_500_is_outcome_unknown_and_not_sent_again"

m=$(mutant o3 "$OF" \
    '            reply = self._http.call("POST", path, body=dict(entry))' \
    '            try:
                reply = self._http.call("POST", path, body=dict(entry))
            except NDTwinError:
                reply = self._http.call("POST", path, body=dict(entry))')
report "O3: the POST is sent again after a 500" "$m" \
       "PostRepliesTest.test_a_500_is_outcome_unknown_and_not_sent_again"

m=$(mutant o4 "$OF" \
    '    if err.status == 501:' \
    '    if False:')
report "O4: the kernel's 501 before queueing is read as may-have-landed" "$m" \
       "PostRepliesTest.test_each_row"

m=$(mutant o5 "$OF" \
    '          "modify": "/ndt/modify_flow_entry",' \
    '          "modify": "/ndt/install_flow_entry",')
report "O5: a modify goes to the install route" "$m" \
       "WriteSendsTest.test_each_op_sends_the_entry_as_is_to_its_own_route"

m=$(mutant o6 "$OF" \
    '                           lab_claim=body.get("lab_claim"))' \
    '                           lab_claim=reply.lab_claim)')
report "O6: lab_claim is read from the header, not the body" "$m" \
       "WriteSendsTest.test_the_return_carries_the_bodys_request_id_accepted_and_lab_claim"

# --- the wait -----------------------------------------------------------------------------------
m=$(mutant o7 "$OF" \
    '        record = self._wait(result, path, wait_s)' \
    '        return result')
report "O7: the dispatch wait is skipped" "$m" \
       "WaitTest.test_it_waits_until_the_record_is_complete"

m=$(mutant o8 "$OF" \
    '        if _is_int(enqueued) and enqueued > 0 and accepted == enqueued:' \
    '        if True:')
report "O8: on_switch True on OVS" "$m" \
       "WaitTest.test_it_waits_until_the_record_is_complete"

m=$(mutant o9 "$OF" \
    '        if wait_s == 0:' \
    '        if False:')
report "O9: wait_s=0 still reads the record" "$m" \
       "WaitTest.test_wait_s_0_returns_after_the_post_and_reads_no_record"

m=$(mutant o10 "$OF" \
    '            if left <= 0:' \
    '            if left <= 0:
                return record
            if False:')
report "O10: a record still incomplete at wait_s returns normally" "$m" \
       "WaitFailsTest.test_a_record_still_incomplete_at_wait_s_is_outcome_unknown_with_the_request_id"

m=$(mutant o11 "$OF" \
    '            if record.get("dispatcher_running") is False:' \
    '            if False:')
report "O11: a stopped dispatcher is not noticed" "$m" \
       "WaitFailsTest.test_a_stopped_dispatcher_is_outcome_unknown_at_once"

m=$(mutant o12 "$OF" \
    '                raise unknown(f"its dispatch record could not be read: {err}") from err' \
    '                raise')
report "O12: an unknown request_id is raised as NotFound (nothing written)" "$m" \
       "WaitFailsTest.test_an_unknown_request_id_is_outcome_unknown"

# --- the failure records ------------------------------------------------------------------------
m=$(mutant o13 "$OF" \
    '        return OutcomeUnknown, None, "the controller did not answer in time; it may still apply it"' \
    '        return Refused, True, "the controller did not answer in time; it may still apply it"')
report "O13: controller_status 0 is read as Refused" "$m" \
       "DispatchFailureTest.test_each_row"

m=$(mutant o14 "$OF" \
    '            return NotFound, True, ("the controller answered 404: usually the switch is not "' \
    '            return Refused, True, ("the controller answered 404: usually the switch is not "')
report "O14: Ryu's 404 is a plain Refused, not NotFound" "$m" \
       "DispatchFailureTest.test_ryu_404_is_not_found_and_says_the_switch_is_not_connected"

m=$(mutant o15 "$OF" \
    '        return NDTwinError, True, "the kernel could not send it"' \
    '        return OutcomeUnknown, None, "the kernel could not send it"')
report "O15: a 500 with no refused_by (curl never ran) is read as may-have-landed" "$m" \
       "DispatchFailureTest.test_each_row"

m=$(mutant o16 "$OF" \
    '        if not failures and not failed:' \
    '        if not failures:')
report "O16: failures the kernel no longer keeps read as success" "$m" \
       "DispatchFailureTest.test_a_failure_the_kernel_no_longer_keeps_is_outcome_unknown"

m=$(mutant o17 "$OF" \
    '            result.on_switch = True' \
    '            result.on_switch = None')
report "O17: on_switch never True on bmv2" "$m" \
       "P4PlaneTest.test_accepted_by_the_switch_is_on_switch_true"

m=$(mutant o18 "$OF" \
    '        return OutcomeUnknown, None, ("the P4 proxy reported the write as failed, which does not "' \
    '        return Refused, True, ("the P4 proxy reported the write as failed, which does not "')
report "O18: a write the proxy reports failed is read as refused" "$m" \
       "P4PlaneTest.test_a_write_the_proxy_reports_failed_is_outcome_unknown"

m=$(mutant o18n "$OF" \
    '        return OutcomeUnknown, None, ("the P4 proxy reported the write as failed, which does not "' \
    '        return OutcomeUnknown, True, ("the P4 proxy reported the write as failed, which does not "')
report "O18n: a write the proxy reports failed says nothing was written" "$m" \
       "P4PlaneTest.test_a_write_the_proxy_reports_failed_is_outcome_unknown"

m=$(mutant o30 "$OF" \
    '            return NotFound, True, "the P4 proxy does not know the switch"' \
    '            return Refused, True, "the P4 proxy does not know the switch"')
report "O30: the proxy's 404 is a plain Refused" "$m" \
       "P4PlaneTest.test_a_switch_the_proxy_does_not_know_is_not_found"

m=$(mutant o31 "$OF" \
    '        return OutcomeUnknown, None, "the P4 proxy failed while handling it"' \
    '        return Refused, True, "the P4 proxy failed while handling it"')
report "O31: a proxy 5xx other than 502 is read as refused" "$m" \
       "P4PlaneTest.test_a_proxy_5xx_other_than_502_is_outcome_unknown"

m=$(mutant o26 "$OF" \
    '    if not _is_int(status):' \
    '    if False:')
report "O26: a record without an integer status is not caught" "$m" \
       "DispatchFailureTest.test_a_record_without_a_readable_status_is_outcome_unknown"

m=$(mutant o32 "$OF" \
    '        return Refused, True, "the kernel refused it"' \
    '        return OutcomeUnknown, None, "the kernel refused it"')
report "O32: a 4xx with no refused_by is read as may-have-landed" "$m" \
       "DispatchFailureTest.test_a_4xx_with_no_refused_by_is_refused"

m=$(mutant o34 "$OF" \
    '    return OutcomeUnknown, None, "an outcome the SDK cannot read"' \
    '    return NDTwinError, True, "an outcome the SDK cannot read"')
report "O34: a record status the SDK cannot place says nothing was written" "$m" \
       "DispatchFailureTest.test_a_status_the_sdk_cannot_place_is_outcome_unknown"

m=$(mutant o29 "$OF" \
    '                raise unknown(f"its dispatch record is not readable: {json.dumps(record)[:200]}")' \
    '                return {}')
report "O29: a record that is not a dict reads as success" "$m" \
       "WaitFailsTest.test_a_record_that_is_not_a_dict_is_outcome_unknown"

m=$(mutant o27 "$OF" \
    '                and _is_int(body.get("request_id")) and body["request_id"] > 0):' \
    '                and _is_int(body.get("request_id"))):')
report "O27: a queued reply with request_id 0 is taken" "$m" \
       "PostRepliesTest.test_a_queued_reply_without_a_positive_request_id_is_outcome_unknown"

m=$(mutant o28 "$OF" \
    '            err = OutcomeUnknown(f"POST {path}: a 2xx the SDK cannot read: "' \
    '            err = Refused(f"POST {path}: a 2xx the SDK cannot read: "')
report "O28: a 2xx that is not queued says nothing was written" "$m" \
       "PostRepliesTest.test_a_2xx_that_is_not_queued_is_outcome_unknown"

m=$(mutant o33 "$OF" \
    '    return _again(OutcomeUnknown, err, "an answer the SDK cannot read", None)' \
    '    return _again(Refused, err, "an answer the SDK cannot read", True)')
report "O33: a POST reply the SDK cannot read says nothing was written" "$m" \
       "PostRepliesTest.test_a_reply_the_sdk_cannot_read_is_outcome_unknown"

m=$(mutant o19 "$OF" \
    '        err.remedy = next((f["remedy"] for f in failures if f.get("remedy")), None)' \
    '        err.remedy = None')
report "O19: the proxy's remedy is dropped" "$m" \
       "P4PlaneTest.test_a_package_pipeline_is_refused_with_the_proxys_remedy"

# --- refused before sending ---------------------------------------------------------------------
m=$(mutant o20 "$OF" \
    '        if not _is_int(match[key]):' \
    '        if False:')
report "O20: a string eth_type is sent" "$m" \
       "RefusedBeforeSendingTest.test_a_string_eth_type_is_refused"

m=$(mutant o20p "$OF" \
    '        if not _is_int(match[key]):' \
    '        if False:')
report "O20p: a string TCP or UDP port is sent" "$m" \
       "RefusedBeforeSendingTest.test_a_string_port_is_refused"

m=$(mutant o21 "$OF" \
    '    if op == "delete" and not match and not all_rules:' \
    '    if False:')
report "O21: a match-all delete is sent without all_rules" "$m" \
       "RefusedBeforeSendingTest.test_a_delete_with_no_match_needs_all_rules"

m=$(mutant o22 "$OF" \
    '    extra = sorted(set(entry) - _KEYS[op])' \
    '    extra = []')
report "O22: keys the kernel drops (cookie, hard_timeout) are sent" "$m" \
       "RefusedBeforeSendingTest.test_each_case"

m=$(mutant o23 "$OF" \
    '         "modify": {"dpid", "priority", "match", "actions"},' \
    '         "modify": {"dpid", "priority", "match", "actions", "idle_timeout"},')
report "O23: idle_timeout is sent on a modify" "$m" \
       "RefusedBeforeSendingTest.test_each_case"

m=$(mutant o24 "$OF" \
    '    unknown = sorted(k for k in match if k not in MATCH_KEYS)' \
    '    unknown = []')
report "O24: a match key Ryu drops is sent" "$m" \
       "RefusedBeforeSendingTest.test_each_case"

m=$(mutant o25 "$OF" \
    '            if not isinstance(action, dict) or action.get("type") not in ACTION_TYPES:' \
    '            if not isinstance(action, dict):')
report "O25: an action type Ryu drops is sent" "$m" \
       "RefusedBeforeSendingTest.test_each_case"

# --- the control --------------------------------------------------------------------------------
m=$(mutant o0 "$OF" \
    '_POLL_MAX_S = 0.5        # the longest one' \
    '_POLL_MAX_S = 0.5        # the longest one (x)')
control "O0: a comment-only edit" "$m"

echo
NOW_SUMS=$(sdk_sums)
if [[ "$NOW_SUMS" != "$BASE_SUMS" ]]; then
    echo "🔴 the SDK CHANGED during the gate -- a source file was written"
    diff <(echo "$BASE_SUMS") <(echo "$NOW_SUMS") | sed 's/^/   /'
    exit 3
fi
echo "SDK byte-identical: yes  of.py sha256 $(sha256sum "$OF" | cut -d' ' -f1)"
echo "mutation gate: $((CAUGHT+SURVIVED+NOT_APPLIED)) mutations: $CAUGHT caught, $SURVIVED survived," \
     "$NOT_APPLIED not applied; control $([[ $CONTROL_RED -eq 0 ]] && echo green || echo RED)"
[[ "$SURVIVED" -eq 0 && "$NOT_APPLIED" -eq 0 && "$CONTROL_RED" -eq 0 ]]
