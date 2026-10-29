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
# read put on the event loop (half three).
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
    out=$(cd p4_proxy/tests && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. \
              "$PROXY_PY" test_table_entry_read.py 2>&1); rc=$?
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
        'test_a_value_wider_than_its_field_is_unrendered_not_narrowed'

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
        '        priority = te.priority if has_priority and not te.is_default_action else None' \
        '        priority = None' \
        'test_a_ternary_entry_reads_back_with_its_mask_and_its_priority'

    # The writer refuses a priority on a default entry, so it could not be sent back.
    "$m" "17. the default entry of a priority table reads back with priority 0" "$CLIENT" \
        '        priority = te.priority if has_priority and not te.is_default_action else None' \
        '        priority = te.priority if has_priority else None' \
        'test_a_default_entry_on_a_priority_table_has_no_priority'

    "$m" "18. the default entry is not marked as one" "$CLIENT" \
        '                "default_action": te.is_default_action}' \
        '                "default_action": False}' \
        'test_an_empty_table_reads_back_as_its_default_entry_alone'

    "$m" "19. the action is named by its alias" "$CLIENT" \
        '            action_name = action.preamble.name' \
        '            action_name = action.preamble.alias' \
        'test_an_lpm_entry_reads_back_as_value_and_prefix_with_a_mac_and_a_port'

    "$m" "20. the answer echoes the alias instead of the table's name" "$CLIENT" \
        '        return {"table": table.preamble.name, "entries": entries, "unrendered": unrendered}' \
        '        return {"table": name, "entries": entries, "unrendered": unrendered}' \
        'test_an_alias_names_the_same_table_and_the_answer_gives_the_full_name'

    "$m" "21. an entry read back carries no dpid, so it is not a POST body" "$API" \
        '            "entries": [dict({"dpid": dpid}, **entry) for entry in reading["entries"]],' \
        '            "entries": reading["entries"],' \
        'test_an_lpm_entry_reads_back_as_value_and_prefix_with_a_mac_and_a_port'

    # ---- half two: an entry the writer cannot say is listed, not dressed up or dropped -------

    "$m" "22. an entry that cannot be rendered is dropped without a word" "$CLIENT" \
        '                unrendered.append({"default_action": te.is_default_action,
                                   "priority": te.priority, "reason": str(err)})' \
        '                pass' \
        'test_an_action_profile_entry_is_listed_as_unrendered_not_dropped'

    "$m" "23. an action-profile entry is reported as an entry with no action" "$CLIENT" \
        '        if which is not None and which != "action":' \
        '        if False:' \
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
        '            if action is None:
                raise TableEntryInvalid(
                    f"{where}: the switch sent action id' \
        '            if action is None:
                return {"table": where, "match": match, "action_name": None,
                        "action_params": {}, "priority": None, "default_action": False}
                raise TableEntryInvalid(
                    f"{where}: the switch sent action id' \
        'test_an_action_this_p4info_does_not_describe_is_unrendered'

    "$m" "27. an action missing a parameter is reported without it" "$CLIENT" \
        '                if param.id not in values:
                    raise TableEntryInvalid(' \
        '                if param.id not in values:
                    continue
                    raise TableEntryInvalid(' \
        'test_an_action_without_one_of_its_parameters_is_unrendered'

    "$m" "28. a parameter the action does not declare is ignored" "$CLIENT" \
        '            if values:
                raise TableEntryInvalid(' \
        '            if False:
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
        'test_a_switch_being_readopted_is_503_replay_pending_and_reads_nothing'

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
        '    try:
        reading = client.read_table(table)' \
        '    owned = [t for t in client.p4info.tables if table in (t.preamble.name, t.preamble.alias)]
    if owned and client.table_owned_by_ndtwin(owned[0]):
        raise _table_read_error(409, "owned by NDTwin", dpid, table, "owned")
    try:
        reading = client.read_table(table)' \
        'test_a_table_ndtwin_owns_is_still_read'

    "$m" "38. an external control plane is refused" "$API" \
        '    try:
        reading = client.read_table(table)' \
        '    if not client.arbitration:
        raise _table_read_error(409, "external control plane", dpid, table, "read only")
    try:
        reading = client.read_table(table)' \
        'test_an_external_control_plane_can_still_read'

    "$m" "39. the read runs on the event loop" "$API" \
        'def read_table_entry(dpid: int, table: str = Query(..., min_length=1)):' \
        'async def read_table_entry(dpid: int, table: str = Query(..., min_length=1)):' \
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
