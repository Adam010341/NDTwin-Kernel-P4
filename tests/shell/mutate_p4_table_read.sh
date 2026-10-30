#!/usr/bin/env bash
#
# Mutation gate for GET /p4/table_entry, the read-back of a table's entries in the shape
# POST /p4/table_entry takes (p4_proxy/tests/test_table_entry_read.py).
#
# [Co-developed with claude code -- Adam]
# The machinery is tests/shell/mutate_p4_direct_counter.sh's: every way of NOT proving a mutation
# is caught -- a non-unique anchor, a mutation that will not apply, the wrong test going red -- is
# counted as a SURVIVOR.
#
# 🔴 THREE HALVES. A value read back in a form the writer would not take back, or would take back
# as another entry: an address or a MAC shown as an integer, a width taken from the byte count, a
# value wider than its field narrowed, an lpm prefix, a mask or a range bound lost, the default
# entry lost or reported twice, another table's entries reported under this one (half one). An
# entry the writer's shape cannot say reported as if it could, or dropped without saying so
# (half two). The route: a refusal answered 200, a failed read answered as an empty table, a
# read refused that needs no ownership or mastership, a query parameter no longer checked, the
# read put on the event loop, a readopt during the read not noticed (half three). Then the reads'
# own pool and per-switch slots, which keep a switch that stops answering from holding up anyone
# else, and the idle timeout an entry has to carry back.
#
# 🔴 SHARED ANCHORS. 9 and 10 share one, as do 14 and 51, 39 and 62, 43 and 44, 46 and 47, 57
# and 77, 58 and 59, 65 and 66, and 35 and 89; 37, 38 and 63 share one, as do 84, 85 and 88, and
# 40, 41 and 60 share the route's signature line. check_gate_anchors.py counts each distinct anchor once.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD -- run it in a
# clone or a worktree nobody else is using.
#
# Usage:
#   tests/shell/mutate_p4_table_read.sh            the gate
#   tests/shell/mutate_p4_table_read.sh --dry-run  anchors only, NOT a gate result
#   PROXY_PY=/path/to/python tests/shell/mutate_p4_table_read.sh
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only).
set -uo pipefail

CLIENT=p4_proxy/proxy_agent/p4_client.py
API=p4_proxy/proxy_agent/api_routes.py
SHAPE=p4_proxy/proxy_agent/match_shape.py
FILES=("$CLIENT" "$API" "$SHAPE")
MODE=full
case "${1:-}" in
    --dry-run) MODE=dryrun ;;
    "")        ;;
    *) echo "REFUSE: unknown argument '$1'. Use --dry-run." >&2; exit 2 ;;
esac

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
# The interpreter, found the way tests/shell/mutate_telemetry_by_name.sh finds it: a git worktree
# has no venv of its own (p4_proxy/venv/ is ignored and lives in the main checkout), so the main
# worktree is consulted before giving up. Override with PROXY_PY= .
MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
FOUND_PY=""
for c in "${PROXY_PY:-}" "p4_proxy/venv/bin/python" "p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, grpc' >/dev/null 2>&1 || continue
    FOUND_PY="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"; break
done
if [[ -z "$FOUND_PY" ]]; then
    if [[ "$MODE" != dryrun ]]; then
        echo "REFUSE: found no interpreter with fastapi/grpc. Set PROXY_PY=<path>. A gate that" >&2
        echo "        cannot run its tests has not checked anything." >&2
        exit 2
    fi
    FOUND_PY="$(command -v python3)"
fi
PROXY_PY="$FOUND_PY"
echo "interpreter: $PROXY_PY"

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done

# A .pyc whose source is edited back to the same length within the same second keeps its
# mtime+size validation stamp, so the interpreter serves the MUTANT's bytecode from a
# pristine-looking file. PYTHONDONTWRITEBYTECODE=1 is set on every run below as well; both,
# because either alone has a hole.
clear_pyc() {
    find p4_proxy -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
    return 0
}

restore() {
    local f
    for f in "${FILES[@]}"; do cp -p "$(snap "$f")" "$f"; touch "$f"; done
    clear_pyc
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0

anchor_count() {
    ANCHOR="$2" "$PROXY_PY" - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# Prints the space-separated identities of the tests that failed, empty if green. rc is taken
# from the process directly, never through a pipe, so a crash cannot be read as a pass.
red_proxy() {
    local out rc
    clear_pyc
    # Two suites: the read's own, and the writer's, whose registration test now has to tell the
    # writer's route from the read's on the same path.
    out=$(cd p4_proxy/tests && { PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. \
              "$PROXY_PY" test_table_entry_read.py 2>&1; r1=$?
          PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. "$PROXY_PY" test_table_entry_route.py 2>&1; r2=$?
          exit $(( r1 | r2 )); }); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_0-9]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <file> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" file="$2" anchor="$3" repl="$4" expected="$5"

    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing, so it is"
        echo "     counted as a survivor rather than skipped. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    ANCHOR="$anchor" REPL="$repl" "$PROXY_PY" - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    if [[ $? -ne 0 ]]; then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    clear_pyc

    local failed; failed=$(red_proxy)
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

DRY_BAD=0
dry_one() {
    local label="$1" file="$2" anchor="$3"
    local n; n=$(anchor_count "$file" "$anchor")
    if [[ "$n" -eq 1 ]]; then printf '  ✅ 1x  %s\n' "$label"
    else printf '  🔴 %sx  %s\n            %s\n' "$n" "$label" "$file"; DRY_BAD=$((DRY_BAD + 1)); fi
}

# --- the mutation table -------------------------------------------------------------------
# Callback signature: <label> <file> <anchor> <replacement> <expected-test>
each_mutation() {
    local m="$1"

    # ---- half one: every value reads back in the form the writer takes back ----------------

    "$m" "1. a bit<32> value reads back as an integer, not an address" "$SHAPE" \
        '    if bitwidth == 32:
        return socket.inet_ntoa' \
        '    if False:
        return socket.inet_ntoa' \
        'test_an_lpm_entry_reads_back_as_value_and_prefix_with_a_mac_and_a_port'

    "$m" "2. a bit<48> value reads back as an integer, not a MAC" "$SHAPE" \
        '    if bitwidth == 48:
        return ":".join' \
        '    if False:
        return ":".join' \
        'test_an_exact_mac_reads_back_as_a_mac'

    # The width taken from the bytes the switch sent rather than from the p4info.
    "$m" "3. a MAC is laid out by the bytes sent, not by the field's width" "$SHAPE" \
        '        return ":".join(f"{b:02x}" for b in number.to_bytes(6, "big"))' \
        '        return ":".join(f"{b:02x}" for b in bytes(raw))' \
        'test_values_sent_without_their_leading_zero_bytes_read_the_same'

    "$m" "4. an address is laid out by the bytes sent, not by the field's width" "$SHAPE" \
        '        return socket.inet_ntoa(number.to_bytes(4, "big"))' \
        '        return socket.inet_ntoa(bytes(raw).rjust(4, b"\x00")[-4:]) if len(raw) == 4 else number' \
        'test_values_sent_without_their_leading_zero_bytes_read_the_same'

    "$m" "5. a value wider than its field is shown anyway" "$SHAPE" \
        '    if number >= (1 << bitwidth):
        raise TableEntryInvalid(
            f"the switch sent' \
        '    if False:
        raise TableEntryInvalid(
            f"the switch sent' \
        'test_a_mac_wider_than_48_bits_is_unrendered_not_an_error'

    "$m" "6. an lpm entry loses its prefix length" "$SHAPE" \
        '        return [render_value(wire[1], bitwidth), int(wire[2])]' \
        '        return [render_value(wire[1], bitwidth), int(bitwidth)]' \
        'test_an_lpm_entry_reads_back_as_value_and_prefix_with_a_mac_and_a_port'

    "$m" "7. a ternary mask or a range's high bound is lost" "$SHAPE" \
        '        return [render_value(wire[1], bitwidth), render_value(wire[2], bitwidth)]' \
        '        return [render_value(wire[1], bitwidth), render_value(wire[1], bitwidth)]' \
        'test_a_ternary_entry_reads_back_with_its_mask_and_its_priority'

    # POST takes an exact value as a one-element list too; the read gives the plain form.
    "$m" "8. an exact value reads back as a one-element list" "$SHAPE" \
        '    if kind in ("EXACT", "OPTIONAL"):
        return render_value(wire[1], bitwidth)' \
        '    if kind in ("EXACT", "OPTIONAL"):
        return [render_value(wire[1], bitwidth)]' \
        'test_an_exact_value_of_another_width_reads_back_as_a_plain_integer'

    "$m" "9. the default entry is never read" "$CLIENT" \
        '        for default in (False, True):' \
        '        for default in (False,):' \
        'test_an_empty_table_reads_back_as_its_default_entry_alone'

    "$m" "10. the default entry is read first" "$CLIENT" \
        '        for default in (False, True):' \
        '        for default in (True, False):' \
        'test_the_default_entry_comes_last_and_carries_what_was_written'

    # Both reads wildcard: bmv2 answers neither with the default.
    "$m" "11. the second read does not ask for the default" "$CLIENT" \
        '            wanted.is_default_action = default' \
        '            wanted.is_default_action = False' \
        'test_the_two_reads_are_of_this_table_one_for_its_entries_one_for_its_default'

    "$m" "12. every table is read instead of this one" "$CLIENT" \
        '            wanted.table_id = table_id' \
        '            wanted.table_id = 0' \
        'test_the_two_reads_are_of_this_table_one_for_its_entries_one_for_its_default'

    "$m" "13. another table's entries are reported under this one" "$CLIENT" \
        '                    and entity.table_entry.table_id == table_id
' \
        '' \
        'test_an_entry_of_another_table_is_not_reported'

    "$m" "14. a default the wildcard read returned is reported twice" "$CLIENT" \
        '                    and entity.table_entry.is_default_action == default)' \
        '                    )' \
        'test_a_default_returned_by_the_wildcard_read_is_not_reported_twice'

    "$m" "15. the reads lose their deadline" "$CLIENT" \
        '            replies = self.stub.Read(req, timeout=timeout_s)' \
        '            replies = self.stub.Read(req)' \
        'test_every_read_carries_a_deadline'

    "$m" "16. a priority table's entry reads back without its priority" "$CLIENT" \
        '        return te.priority if has_priority and not te.is_default_action else None' \
        '        return None' \
        'test_a_ternary_entry_reads_back_with_its_mask_and_its_priority'

    # The writer refuses a priority on a default entry, so it could not be sent back.
    "$m" "17. the default entry of a priority table reads back with priority 0" "$CLIENT" \
        '        return te.priority if has_priority and not te.is_default_action else None' \
        '        return te.priority if has_priority else None' \
        'test_a_default_entry_on_a_priority_table_has_no_priority'

    "$m" "18. the default entry is not marked as one" "$CLIENT" \
        '                "default_action": te.is_default_action}' \
        '                "default_action": False}' \
        'test_an_empty_table_reads_back_as_its_default_entry_alone'

    "$m" "19. the action is named by its alias" "$CLIENT" \
        '        spec = {"table": where, "match": match, "action_name": action.preamble.name,' \
        '        spec = {"table": where, "match": match, "action_name": action.preamble.alias,' \
        'test_an_lpm_entry_reads_back_as_value_and_prefix_with_a_mac_and_a_port'

    "$m" "20. the answer echoes the alias instead of the table's name" "$API" \
        '    return {"dpid": dpid, "table": reading["table"],' \
        '    return {"dpid": dpid, "table": table,' \
        'test_an_alias_names_the_same_table_and_the_answer_gives_the_full_name'

    "$m" "21. an entry read back carries no dpid, so it is not a POST body" "$API" \
        '            "entries": [dict({"dpid": dpid}, **entry) for entry in reading["entries"]],' \
        '            "entries": reading["entries"],' \
        'test_an_lpm_entry_reads_back_as_value_and_prefix_with_a_mac_and_a_port'

    # ---- half two: an entry the writer cannot say is listed, not dressed up or dropped -------

    "$m" "22. an entry that cannot be rendered is dropped without a word" "$CLIENT" \
        '                unrendered.append({"default_action": te.is_default_action,
                                   "priority": self._read_priority(te, has_priority),
                                   "reason": str(err)})' \
        '                pass' \
        'test_an_action_profile_entry_is_listed_as_unrendered_not_dropped'

    "$m" "23. an action-profile entry is reported as an entry with no action" "$CLIENT" \
        '        if which != "action":
            raise TableEntryInvalid(' \
        '        if False:
            raise TableEntryInvalid(' \
        'test_an_action_profile_entry_is_listed_as_unrendered_not_dropped'

    "$m" "24. a match field id this p4info does not describe is not caught" "$CLIENT" \
        '        if None in spelled or len(spelled) != len(te.match):' \
        '        if False:' \
        'test_a_match_field_id_this_p4info_does_not_describe_is_unrendered'

    "$m" "25. a match of another kind is rendered as the declared kind" "$CLIENT" \
        '            if got["type"].upper() != kind:' \
        '            if False:' \
        'test_a_match_of_another_kind_than_the_p4info_declares_is_unrendered'

    "$m" "26. an action id this p4info does not describe is not caught" "$CLIENT" \
        '        if action is None:
            raise TableEntryInvalid(
                f"{where}: the switch sent action id' \
        '        if action is None:
            return {"table": where, "match": match, "action_name": None,
                    "action_params": {}, "priority": None, "default_action": False}
            raise TableEntryInvalid(
                f"{where}: the switch sent action id' \
        'test_an_action_this_p4info_does_not_describe_is_unrendered'

    "$m" "27. an action missing a parameter is reported without it" "$CLIENT" \
        '            if param.id not in values:
                raise TableEntryInvalid(' \
        '            if param.id not in values:
                continue
                raise TableEntryInvalid(' \
        'test_an_action_without_one_of_its_parameters_is_unrendered'

    "$m" "28. a parameter the action does not declare is ignored" "$CLIENT" \
        '        if values:
            raise TableEntryInvalid(' \
        '        if False:
            raise TableEntryInvalid(' \
        'test_a_parameter_the_action_does_not_declare_is_unrendered'

    # ---- half three: the route --------------------------------------------------------------

    "$m" "29. an unknown switch answers 200 with no entries" "$API" \
        '    if client is None:
        raise _table_read_error(404, "unknown switch",' \
        '    if client is None:
        return {"dpid": dpid, "table": table, "entries": [], "unrendered": []}
        raise _table_read_error(404, "unknown switch",' \
        'test_an_unknown_dpid_is_404_and_reads_nothing'

    "$m" "30. a table not in this pipeline is answered 503, as if it might come back" "$API" \
        '        raise _table_read_error(404, "not in this pipeline", dpid, table,' \
        '        raise _table_read_error(503, "not in this pipeline", dpid, table,' \
        'test_a_table_this_pipeline_does_not_have_is_404_and_reads_nothing'

    # The one the 503 exists for: "the switch did not answer" read as "the table is empty".
    "$m" "31. a failed read becomes an empty table" "$API" \
        '            raise
        raise _table_read_error(503, "table not read",' \
        '            raise
        return {"dpid": dpid, "table": table, "entries": [], "unrendered": []}
        raise _table_read_error(503, "table not read",' \
        'test_a_switch_that_is_not_connected_is_503_with_the_grpc_status_name'

    "$m" "32. the 503 loses the gRPC status name" "$API" \
        '                                f"NOT an empty table", grpc_status=reason)' \
        '                                f"NOT an empty table")' \
        'test_a_switch_that_is_not_connected_is_503_with_the_grpc_status_name'

    "$m" "33. a bug that is not the switch is reported as a failed read" "$API" \
        '        if reason is None:
            raise
        raise _table_read_error(503, "table not read",' \
        '        if reason is None:
            reason = type(err).__name__
        raise _table_read_error(503, "table not read",' \
        'test_an_error_that_is_not_grpc_is_not_called_a_failed_read'

    "$m" "34. a switch being re-adopted is read anyway" "$API" \
        '    if readopting:' \
        '    if False:' \
        'test_a_switch_being_readopted_is_answered_without_waiting_for_a_slot'

    "$m" "35. every switch is refused while any one is re-adopted" "$API" \
        '    readopting = table_journals is not None and table_journals.pending(dpid)' \
        '    readopting = table_journals is not None' \
        'test_another_switch_being_readopted_does_not_stop_this_read'

    "$m" "36. no topology yet is answered 404, as if the switch were gone" "$API" \
        '        raise _table_read_error(503, "no topology", dpid, table,' \
        '        raise _table_read_error(404, "no topology", dpid, table,' \
        'test_no_topology_is_503'

    # The write rule (409 owned_by_ndtwin) grown onto a read.
    "$m" "37. an owner check refuses NDTwin's own tables" "$API" \
        '    slots = _table_read_slot(dpid)' \
        '    owned = [t for t in client.p4info.tables if table in (t.preamble.name, t.preamble.alias)]
    if owned and client.table_owned_by_ndtwin(owned[0]):
        raise _table_read_error(409, "owned by NDTwin", dpid, table, "owned")
    slots = _table_read_slot(dpid)' \
        'test_a_table_ndtwin_owns_is_still_read'

    "$m" "38. an external control plane is refused" "$API" \
        '    slots = _table_read_slot(dpid)' \
        '    if not client.arbitration:
        raise _table_read_error(409, "external control plane", dpid, table, "read only")
    slots = _table_read_slot(dpid)' \
        'test_an_external_control_plane_can_still_read'

    "$m" "39. the read runs on the event loop" "$API" \
        '    reader = asyncio.get_running_loop().run_in_executor(
        _table_read_executor(dpid), client.read_table, full_name)' \
        '    reader = asyncio.get_running_loop().create_future()
    reader.set_result(client.read_table(full_name))' \
        'test_the_read_runs_off_the_event_loop'

    "$m" "40. an empty table name is no longer refused" "$API" \
        'def read_table_entry(dpid: int, table: str = Query(..., min_length=1)):' \
        'def read_table_entry(dpid: int, table: str = Query(...)):' \
        'test_an_empty_table_name_is_422'

    "$m" "41. the table is no longer required" "$API" \
        'def read_table_entry(dpid: int, table: str = Query(..., min_length=1)):' \
        'def read_table_entry(dpid: int, table: str = Query("", min_length=0)):' \
        'test_a_missing_table_is_422'

    "$m" "42. the route is not registered" "$API" \
        '@router.get("/p4/table_entry")
' \
        '' \
        'test_get_p4_table_entry_is_on_the_router'

    # The read shares its path with the writer; a POST must still reach the writer.
    "$m" "43. the writer is no longer registered beside the read" "$API" \
        '@router.post("/p4/table_entry")
' \
        '' \
        'test_post_still_reaches_the_writer'

    "$m" "44. the writer's registration test no longer sees the writer" "$API" \
        '@router.post("/p4/table_entry")
' \
        '' \
        'test_post_p4_table_entry_is_on_the_router'

    # ---- wide values, unrendered priorities, a missing default, a readopt during the read, ---
    # ---- the writer's own check, the error bodies and the query parameters ---------------

    "$m" "45. an unrendered entry carries the switch's raw priority" "$CLIENT" \
        '                                   "priority": self._read_priority(te, has_priority),
                                   "reason": str(err)})' \
        '                                   "priority": te.priority,
                                   "reason": str(err)})' \
        'test_an_unrendered_entry_has_the_priority_an_entry_would_have'

    "$m" "46. the hex threshold moves up to 64 bits" "$SHAPE" \
        'JSON_EXACT_INT_BITS = 53' \
        'JSON_EXACT_INT_BITS = 64' \
        'test_a_bit64_value_above_2_53_and_a_bit128_value_read_back_as_hex_strings'

    "$m" "47. the hex threshold moves down to 52 bits" "$SHAPE" \
        'JSON_EXACT_INT_BITS = 53' \
        'JSON_EXACT_INT_BITS = 52' \
        'test_up_to_53_bits_is_an_integer_and_from_54_bits_a_hex_string'

    "$m" "48. a wide value is a JSON number again" "$SHAPE" \
        '    if bitwidth > JSON_EXACT_INT_BITS:
        return f"0x{number:x}"' \
        '    if False:
        return f"0x{number:x}"' \
        'test_a_wide_value_survives_a_json_reader_that_parses_numbers_as_doubles'

    # Padding a stripped value on the wrong side shifts it: 0.0.255.0 sent as ff00 reads ff.00.00.00.
    "$m" "49. a value sent without its leading zeros is padded on the right" "$SHAPE" \
        '    number = _as_int(bytes(raw))' \
        '    number = _as_int(bytes(raw).ljust((bitwidth + 7) // 8, b"\x00"))' \
        'test_masks_range_bounds_and_optionals_sent_without_leading_zeros_read_the_same'

    "$m" "50. a default entry the switch did not return goes unmentioned" "$CLIENT" \
        '        if not any(te.is_default_action for te in answered):' \
        '        if False:' \
        'test_a_default_read_that_returns_nothing_is_listed_in_unrendered'

    "$m" "51. an unflagged entry from the default read is taken as an entry" "$CLIENT" \
        '                    and entity.table_entry.is_default_action == default)' \
        '                    )' \
        'test_a_default_read_that_returns_an_unflagged_entry_is_listed_in_unrendered'

    "$m" "52. a readopt during the read is not looked for" "$API" \
        '    if not still_this_switch:' \
        '    if False:' \
        'test_a_readopt_that_begins_during_the_read_is_503_replay_pending'

    "$m" "53. a client replaced during the read is not noticed" "$API" \
        '    still_this_switch = (topology.switches.get(dpid) is client' \
        '    still_this_switch = (True' \
        'test_a_client_replaced_during_the_read_is_503_replay_pending'

    "$m" "54. a readopt that began during the read is not noticed" "$API" \
        '                         and not (table_journals is not None and table_journals.pending(dpid)))' \
        '                         and True)' \
        'test_a_readopt_that_begins_during_the_read_is_503_replay_pending'

    "$m" "55. a KeyError anywhere in the read is called a missing table" "$API" \
        '    try:
        reading = await asyncio.shield(reader)
    except Exception as err:' \
        '    try:
        reading = await asyncio.shield(reader)
    except KeyError as err:
        raise _table_read_error(404, "not in this pipeline", dpid, table, str(err))
    except Exception as err:' \
        'test_a_key_error_while_rendering_is_not_called_a_missing_table'

    "$m" "56. an entry is listed without the writer having built it" "$CLIENT" \
        '            self.build_table_entry(spec)
        except (TableEntryInvalid, TableEntryUnsupported) as err:' \
        '            pass
        except (TableEntryInvalid, TableEntryUnsupported) as err:' \
        'test_a_field_with_no_width_is_unrendered'

    "$m" "57. an entry with no action is blamed on an action profile" "$CLIENT" \
        '        if which is None:
            raise TableEntryInvalid(' \
        '        if False:
            raise TableEntryInvalid(' \
        'test_an_entry_with_no_action_is_unrendered'

    "$m" "58. an error body no longer names the switch" "$API" \
        '        {"error": error, "dpid": dpid, "table": table, "message": message}, **extra))' \
        '        {"error": error, "table": table, "message": message}, **extra))' \
        'test_every_error_body_carries_the_dpid_and_the_table_asked_for'

    "$m" "59. an error body no longer names the table" "$API" \
        '        {"error": error, "dpid": dpid, "table": table, "message": message}, **extra))' \
        '        {"error": error, "dpid": dpid, "message": message}, **extra))' \
        'test_every_error_body_carries_the_dpid_and_the_table_asked_for'

    "$m" "60. dpid is no longer checked to be an integer" "$API" \
        'def read_table_entry(dpid: int, table: str = Query(..., min_length=1)):' \
        'def read_table_entry(dpid: str, table: str = Query(..., min_length=1)):' \
        'test_a_missing_or_non_integer_dpid_is_422'

    "$m" "61. a field the entry does not match on is filled in" "$CLIENT" \
        '        which = te.action.WhichOneof("type")' \
        '        if not te.is_default_action:
            match.update({f.name: None for f in table.match_fields if f.name not in match})
        which = te.action.WhichOneof("type")' \
        'test_a_field_left_out_stays_left_out'

    # ---- the reads' own pool and per-switch slots ------------------------------------------

    # Measured on bmv2 1.15.5, 2026-10-30: a stopped switch's reads on the shared pool hold
    # every POST and /stats/flow behind them.
    "$m" "62. the read goes back to FastAPI's shared pool" "$API" \
        '    reader = asyncio.get_running_loop().run_in_executor(
        _table_read_executor(dpid), client.read_table, full_name)' \
        '    reader = asyncio.ensure_future(run_in_threadpool(client.read_table, full_name))' \
        'test_a_post_and_a_flow_stats_poll_on_another_switch_answer_at_once'

    # Other switches are kept apart by the per-switch pools; the slots are what bound one
    # switch's own reads and turn a long wait into 503 switch busy.
    "$m" "63. one switch's reads are not limited" "$API" \
        '    slots = _table_read_slot(dpid)' \
        '    slots = asyncio.Semaphore(1000)' \
        'test_a_get_that_cannot_get_a_slot_is_503_switch_busy'

    "$m" "64. a slot is never given back" "$API" \
        '    reader.add_done_callback(lambda _finished: slots.release())' \
        '    pass' \
        'test_a_slot_is_given_back_after_every_read'

    "$m" "65. a GET waits for a slot forever" "$API" \
        '        await asyncio.wait_for(slots.acquire(), timeout=TABLE_READ_WAIT_S)' \
        '        await slots.acquire()' \
        'test_a_get_that_cannot_get_a_slot_is_503_switch_busy'

    "$m" "66. a GET that cannot start at once is refused" "$API" \
        '        await asyncio.wait_for(slots.acquire(), timeout=TABLE_READ_WAIT_S)' \
        '        await asyncio.wait_for(slots.acquire(), timeout=0)' \
        'test_a_healthy_switchs_concurrent_reads_are_all_answered'

    # A caller that hangs up must not free the slot of a read that is still running.
    "$m" "67. the slot goes back when the request ends, not when the read does" "$API" \
        '        reading = await asyncio.shield(reader)' \
        '        reading = await reader' \
        'test_a_read_whose_caller_gave_up_still_holds_its_slot'

    # ---- idle timeouts -------------------------------------------------------------------------

    "$m" "68. POST does not write the idle timeout" "$CLIENT" \
        '        if idle:
            entry.idle_timeout_ns = idle' \
        '        if False:
            entry.idle_timeout_ns = idle' \
        'test_post_writes_the_idle_timeout'

    "$m" "69. GET does not return the idle timeout" "$CLIENT" \
        '            spec["idle_timeout_ns"] = self._idle_timeout_as_json(te.idle_timeout_ns)' \
        '            pass' \
        'test_an_entry_read_back_and_sent_as_a_modify_keeps_its_idle_timeout'

    "$m" "70. an idle timeout is taken on a table that keeps none" "$CLIENT" \
        '        if idle and not self.table_ages_entries(table):' \
        '        if False:' \
        'test_an_idle_timeout_on_a_table_without_timeout_support_is_400_and_writes_nothing'

    "$m" "71. an idle timeout is taken on a default entry" "$CLIENT" \
        '        if idle and is_default:' \
        '        if False:' \
        'test_an_idle_timeout_on_a_default_entry_is_400'

    "$m" "72. the route drops idle_timeout_ns from the body" "$API" \
        '            ("table", "match", "action_name", "action_params", "default_action", "priority",
             "idle_timeout_ns")' \
        '            ("table", "match", "action_name", "action_params", "default_action", "priority")' \
        'test_post_writes_the_idle_timeout'

    "$m" "73. an idle timeout that is not an integer is taken" "$CLIENT" \
        '        if isinstance(idle, bool) or not isinstance(idle, int):' \
        '        if False:' \
        'test_an_idle_timeout_that_is_not_a_non_negative_integer_is_400'

    "$m" "74. a negative or too large idle timeout is taken" "$CLIENT" \
        '        if not 0 <= idle <= self.IDLE_TIMEOUT_NS_MAX:' \
        '        if False:' \
        'test_an_idle_timeout_that_is_not_a_non_negative_integer_is_400'

    "$m" "75. the idle timeout is read back on every entry of every table" "$CLIENT" \
        '        if self.table_ages_entries(table) and not te.is_default_action:' \
        '        if True:' \
        'test_the_default_entry_and_other_tables_carry_no_idle_timeout_key'

    "$m" "76. every table is taken to keep idle timeouts" "$CLIENT" \
        '        return table.idle_timeout_behavior != p4info_pb2.Table.NO_TIMEOUT' \
        '        return True' \
        'test_an_idle_timeout_on_a_table_without_timeout_support_is_400_and_writes_nothing'

    # An indirect table's default as bmv2 1.15.5 returned it (measured 2026-10-30): flagged,
    # no action at all.
    "$m" "77. an indirect table's default is blamed on an action profile" "$CLIENT" \
        '        if which is None:
            raise TableEntryInvalid(' \
        '        if False:
            raise TableEntryInvalid(' \
        'test_the_default_with_no_action_is_unrendered_saying_so'

    # Existing callers send no idle_timeout_ns; for them nothing may change.
    "$m" "78. a POST without the key is given a timeout" "$CLIENT" \
        '        if idle is None:
            return 0' \
        '        if idle is None:
            idle = 1' \
        'test_post_without_the_key_writes_no_timeout'

    # ---- a readopt during the wait for a slot, the relay's deadline, many stopped switches -----

    "$m" "79. a GET that waited through a readopt reads through the closed channel" "$API" \
        '    if _readopt_seen(dpid, client):
        slots.release()' \
        '    if False:
        slots.release()' \
        'test_a_get_that_waited_through_a_readopt_is_503_and_reads_nothing'

    "$m" "80. a read that a readopt broke is answered 500" "$API" \
        '        if _readopt_seen(dpid, client):
            raise _table_read_error(503, "replay pending", dpid, table,' \
        '        if False:
            raise _table_read_error(503, "replay pending", dpid, table,' \
        'test_a_read_that_fails_because_of_a_readopt_is_503_not_500'

    "$m" "81. a replaced client is not noticed after the wait" "$API" \
        '    if topology.switches.get(dpid) is not client:
        return True' \
        '    if False:
        return True' \
        'test_a_read_that_fails_because_of_a_readopt_is_503_not_500'

    # A wait of two read deadlines would let a GET run 20 s and meet the relay's 504.
    "$m" "82. the slot wait grows past the kernel relay's deadline" "$API" \
        'TABLE_READ_WAIT_S = 3.0' \
        'TABLE_READ_WAIT_S = 2 * RPC_TIMEOUT_S' \
        'test_a_whole_get_answers_inside_the_kernel_relays_15_s'

    # One pool of 32 workers for every switch is filled by 8 stopped switches.
    "$m" "83. one pool of 32 for every switch again" "$API" \
        '    pool = _table_read_pools.get(dpid)
    if pool is None:
        pool = ThreadPoolExecutor(max_workers=TABLE_READS_PER_SWITCH,' \
        '    dpid = "every switch"
    pool = _table_read_pools.get(dpid)
    if pool is None:
        pool = ThreadPoolExecutor(max_workers=32,' \
        'test_reads_of_another_switch_go_on_while_ten_switches_are_stopped'

    "$m" "84. a wide idle timeout is a JSON number again" "$CLIENT" \
        '        if idle >= 1 << match_shape.JSON_EXACT_INT_BITS:' \
        '        if False:' \
        'test_from_2_53_it_reads_back_a_hex_string'

    "$m" "85. 2^53 itself is a JSON number" "$CLIENT" \
        '        if idle >= 1 << match_shape.JSON_EXACT_INT_BITS:' \
        '        if idle > 1 << match_shape.JSON_EXACT_INT_BITS:' \
        'test_from_2_53_it_reads_back_a_hex_string'

    "$m" "86. POST no longer takes the hex form back" "$CLIENT" \
        '        if isinstance(idle, str) and idle[:2].lower() == "0x":' \
        '        if False:' \
        'test_post_takes_the_hex_string_and_a_read_back_round_trips'

    "$m" "87. a hex string that does not parse escapes as a fault" "$CLIENT" \
        '                idle = int(idle[2:], 16)
            except ValueError:' \
        '                idle = int(idle[2:], 16)
            except KeyError:' \
        'test_a_string_that_is_not_hex_is_400'

    "$m" "88. an idle timeout below 2^53 reads back as a string" "$CLIENT" \
        '        if idle >= 1 << match_shape.JSON_EXACT_INT_BITS:' \
        '        if idle >= 1 << 52:' \
        'test_below_2_53_it_reads_back_an_integer'

    # The check before the wait and the one after it both stop looking at `pending`: the read then
    # goes ahead, and only the check after the read turns it away.
    "$m" "89. a switch being re-adopted is read before it is turned away" "$API" \
        '    readopting = table_journals is not None and table_journals.pending(dpid)' \
        '    readopting = False
    _readopt_seen = lambda d, c: topology.switches.get(d) is not c' \
        'test_a_switch_being_readopted_is_503_replay_pending_and_reads_nothing'
}

# --- run ------------------------------------------------------------------------------------

if [[ "$MODE" == dryrun ]]; then
    echo "DRY RUN -- anchors only. This is NOT a gate result."
    each_mutation dry_one
    echo
    if [[ "$DRY_BAD" -ne 0 ]]; then echo "🔴 $DRY_BAD anchor(s) not unique."; exit 1; fi
    echo "✅ all anchors unique."; exit 0
fi

# A red baseline makes every later result meaningless: a test already failing "catches"
# everything. Refuse rather than report.
echo "=== baseline (must be green before any mutation) ==="
BASE=$(red_proxy)
if [[ -n "$BASE" ]]; then
    echo "REFUSE: baseline is red -- [$BASE]. Nothing this gate reports would mean anything." >&2
    exit 2
fi
echo "  ✅ green"

each_mutation mutate

echo
echo "=== baseline restored? ==="
for f in "${FILES[@]}"; do
    if cmp -s "$f" "$(snap "$f")"; then echo "  ✅ $f byte-identical"
    else echo "  🔴 $f WAS LEFT MUTATED"; SURVIVORS=$((SURVIVORS + 1)); fi
done

echo
echo "$MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]] || exit 1
