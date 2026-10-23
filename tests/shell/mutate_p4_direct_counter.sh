#!/usr/bin/env bash
#
# Mutation gate for GET /p4/direct_counter and for GET /p4/counter's deadline, pointer and thread
# (p4_proxy/tests/test_direct_counter_route.py).
#
# [Co-developed with claude code -- Adam]
# Written to match tests/shell/mutate_p4_priority_refusal.sh (and through it
# mutate_a7_dispatch_status.sh): every way of NOT proving a mutation is caught -- a non-unique
# anchor, a mutation that will not apply, the wrong test going red -- is counted as a SURVIVOR.
#
# 🔴 TWO DIRECTIONS. A read that says something the switch did not: a failed read reported as an
# empty table, a deadline dropped, a read moved onto the event loop, another table's entries
# reported under this counter, a 0 for a unit the counter does not count or for an entry the
# switch sent no data for, an answer that could not be rendered reported as a read failure, an
# unknown counter or switch answered 200 (half one). A route that refuses what it can read: an
# owner check or an external-mode refusal grown onto a READ, an empty table answered 503, every
# switch refused while one is re-adopted (half two). A gate with only the first kind would pass
# every one of the second. Then the 404 pointers, each both ways, and the registration.
#
# 🔴 SHARED ANCHORS. Five mutations start from exactly the anchor of an earlier one, each with its
# own replacement: 15 repeats 10 (the byte line), 23 and 25 repeat 22 (the replay check), 28
# repeats 27 (the indexed-counter pointer), 30 repeats 29 (GET /p4/counter's pointer). So
# check_gate_anchors.py counts five fewer DISTINCT anchors than this table has mutations. Other
# anchors overlap without being identical (3 inside 24, 21 inside 26, 32 inside 31). Mutation 32
# gives the same signal as 31: the route's path changes, TheRouteIsRegisteredTest finds no
# /p4/direct_counter/{name} and raises IndexError, so a greedy parameter's wrong answer is not
# itself tested.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD -- run it in a
# clone or a worktree nobody else is using.
#
# Usage:
#   tests/shell/mutate_p4_direct_counter.sh            the gate
#   tests/shell/mutate_p4_direct_counter.sh --dry-run  anchors only, NOT a gate result
#   PROXY_PY=/path/to/python tests/shell/mutate_p4_direct_counter.sh
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only).
set -uo pipefail

CLIENT=p4_proxy/proxy_agent/p4_client.py
API=p4_proxy/proxy_agent/api_routes.py
FILES=("$CLIENT" "$API")

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
              "$PROXY_PY" test_direct_counter_route.py 2>&1); rc=$?
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

    # ---- half one: the read must say exactly what the switch said --------------------

    "$m" "1. the direct read loses its deadline" "$CLIENT" \
        '            for response in self.stub.Read(req, timeout=timeout_s):' \
        '            for response in self.stub.Read(req):' \
        'test_the_read_carries_a_deadline'

    # The defect this branch found in passing: GET /p4/counter's Read had no deadline at all.
    "$m" "2. the indexed read loses its deadline again" "$CLIENT" \
        '            for response in self.stub.Read(req, timeout=RPC_TIMEOUT_S):' \
        '            for response in self.stub.Read(req):' \
        'test_the_indexed_read_carries_a_deadline_too'

    # Same body either way; only the thread differs, and with it whether one stopped switch
    # freezes every endpoint.
    "$m" "3. the direct read runs on the event loop" "$API" \
        '        reading = await run_in_threadpool(client.read_direct_counter, name)' \
        '        reading = client.read_direct_counter(name)' \
        'test_the_direct_read_runs_on_a_worker_thread'

    "$m" "4. the indexed read runs on the event loop" "$API" \
        '        reading = await run_in_threadpool(client.read_egress_counter, index, name)' \
        '        reading = client.read_egress_counter(index, name)' \
        'test_the_indexed_read_runs_on_a_worker_thread'

    "$m" "5. the read names table 0 instead of the counter's own table" "$CLIENT" \
        '        req.entities.add().direct_counter_entry.table_entry.table_id = table_id' \
        '        req.entities.add().direct_counter_entry.table_entry.table_id = 0' \
        'test_the_request_is_one_wildcard_read_over_the_counters_own_table'

    "$m" "6. another table's entries are reported under this counter" "$CLIENT" \
        '                if dce.table_entry.table_id != table_id:
                    continue
' \
        '' \
        'test_an_entity_of_another_table_is_not_reported'

    # The one the three-outcome contract exists for: "the switch did not answer" read as "the
    # table is empty".
    "$m" "7. a failed read becomes an empty table" "$CLIENT" \
        '                            "zero", name, e)
            return None' \
        '                            "zero", name, e)
            return {"counter": counter.preamble.name, "table": self._table_name(table_id),
                    "unit": unit, "entries": []}' \
        'test_a_failed_read_is_503_and_says_it_is_not_a_zero'

    "$m" "8. an answer that cannot be rendered is reported as a failed read" "$CLIENT" \
        '        except Exception as e:
            raise DirectCounterUnrenderable(' \
        '        except Exception as e:
            return None
            raise DirectCounterUnrenderable(' \
        'test_an_answer_this_p4info_cannot_render_is_502_and_not_a_read_failure'

    "$m" "9. an entry with no data reads as 0 / 0" "$CLIENT" \
        '                has_data = dce.HasField("data")' \
        '                has_data = True' \
        'test_an_entry_the_switch_sent_no_data_for_is_null_not_zero'

    "$m" "10. a packets-only counter reports 0 bytes" "$CLIENT" \
        '                    "bytes": dce.data.byte_count if has_data and counts_bytes else None,' \
        '                    "bytes": dce.data.byte_count if has_data else None,' \
        'test_a_packets_only_counter_reports_no_bytes_and_says_its_unit'

    "$m" "11. a bytes-only counter reports 0 packets" "$CLIENT" \
        '                    "packets": dce.data.packet_count if has_data and counts_packets else None,' \
        '                    "packets": dce.data.packet_count if has_data else None,' \
        'test_a_bytes_only_counter_reports_no_packets'

    "$m" "12. a packets-only counter is reported as counting both" "$CLIENT" \
        '    p4info_pb2.CounterSpec.PACKETS: ("packets", False, True),' \
        '    p4info_pb2.CounterSpec.PACKETS: ("both", True, True),' \
        'test_a_packets_only_counter_reports_no_bytes_and_says_its_unit'

    "$m" "12b. a counter with no declared unit is reported as counting both" "$CLIENT" \
        '            counter.spec.unit, ("unspecified", True, True))' \
        '            counter.spec.unit, ("both", True, True))' \
        'test_a_counter_with_no_declared_unit_passes_both_numbers_on_and_says_so'

    "$m" "13. match values stay bytes (not JSON)" "$CLIENT" \
        '    return {name: {k: (int.from_bytes(v, "big") if isinstance(v, bytes) else v)' \
        '    return {name: {k: v' \
        'test_every_match_kind_is_rendered_as_integers_with_the_priority'

    "$m" "14. the priority is dropped" "$CLIENT" \
        '                    "priority": dce.table_entry.priority,' \
        '                    "priority": 0,' \
        'test_every_match_kind_is_rendered_as_integers_with_the_priority'

    "$m" "15. bytes reported as packets" "$CLIENT" \
        '                    "bytes": dce.data.byte_count if has_data and counts_bytes else None,' \
        '                    "bytes": dce.data.packet_count if has_data and counts_bytes else None,' \
        'test_a_reading_is_200_with_every_entry_of_the_table'

    "$m" "16. the alias is no longer accepted" "$CLIENT" \
        '        for counter in self.p4info.direct_counters:
            if name in (counter.preamble.name, counter.preamble.alias):' \
        '        for counter in self.p4info.direct_counters:
            if name == counter.preamble.name:' \
        'test_an_alias_names_the_same_counter'

    "$m" "17. the answer echoes the alias instead of the counter's name" "$CLIENT" \
        '        return {"counter": counter.preamble.name, "table": self._table_name(table_id),' \
        '        return {"counter": name, "table": self._table_name(table_id),' \
        'test_an_alias_names_the_same_counter'

    "$m" "18. an unknown direct counter reads as an empty table" "$CLIENT" \
        '        if counter is None:
            raise CounterNotFound(
                "direct counter %r' \
        '        if counter is None:
            return {"counter": name, "table": None, "unit": "both", "entries": []}
            raise CounterNotFound(
                "direct counter %r' \
        'test_a_name_that_is_no_direct_counter_is_404_and_reads_nothing'

    "$m" "19. an unknown switch answers 200 with no entries" "$API" \
        '    if client is None:
        raise HTTPException(status_code=404, detail={
            "error": "unknown switch", "dpid": dpid,' \
        '    if client is None:
        return {"dpid": dpid, "counter": name, "table": None, "unit": None, "entries": []}
        raise HTTPException(status_code=404, detail={
            "error": "unknown switch", "dpid": dpid,' \
        'test_an_unknown_dpid_is_404_and_reads_nothing'

    "$m" "20. no topology yet is answered 404, as if the switch were gone" "$API" \
        '        raise HTTPException(status_code=503, detail={
            "error": "no topology",' \
        '        raise HTTPException(status_code=404, detail={
            "error": "no topology",' \
        'test_no_topology_is_503'

    "$m" "21. a failed read is answered with a success code" "$API" \
        '        raise HTTPException(status_code=503, detail={
            "error": "direct counter not read",' \
        '        raise HTTPException(status_code=200, detail={
            "error": "direct counter not read",' \
        'test_a_failed_read_is_503_and_says_it_is_not_a_zero'

    # A read during a readopt reports entries missing that are about to come back.
    "$m" "22. a switch being re-adopted is read anyway" "$API" \
        '    if table_journals is not None and table_journals.pending(dpid):' \
        '    if False:' \
        'test_a_switch_being_readopted_is_503_replay_pending_and_reads_nothing'

    # ---- half two: the route must not refuse what it can read -------------------------

    "$m" "23. every switch is refused while any one is re-adopted" "$API" \
        '    if table_journals is not None and table_journals.pending(dpid):' \
        '    if table_journals is not None:' \
        'test_another_switch_being_readopted_does_not_stop_this_read'

    # V7 grown onto a read: NDTwin's own direct counters (what GET /stats/flow reports) refused.
    "$m" "24. an owner check refuses NDTwin's own direct counters" "$API" \
        '    try:
        reading = await run_in_threadpool(client.read_direct_counter, name)' \
        '    dc = client.direct_counter_by_name(name)
    if dc is not None and any(client.table_owned_by_ndtwin(t) for t in client.p4info.tables
                              if t.preamble.id == dc.direct_table_id):
        raise HTTPException(status_code=409, detail={"error": "owned by NDTwin"})
    try:
        reading = await run_in_threadpool(client.read_direct_counter, name)' \
        'test_a_counter_on_a_table_ndtwin_owns_is_still_read'

    # The write endpoints' 409 under `external`, copied onto a read that needs no mastership.
    "$m" "25. an external control plane is refused" "$API" \
        '    if table_journals is not None and table_journals.pending(dpid):' \
        '    if not client.arbitration:
        raise HTTPException(status_code=409, detail={"error": "external control plane"})
    if table_journals is not None and table_journals.pending(dpid):' \
        'test_a_read_only_client_answers_200'

    "$m" "26. an empty table is answered 503" "$API" \
        '    if reading is None:
        raise HTTPException(status_code=503, detail={
            "error": "direct counter not read",' \
        '    if reading is None or not reading["entries"]:
        raise HTTPException(status_code=503, detail={
            "error": "direct counter not read",' \
        'test_an_empty_table_is_200_with_no_entries'

    # ---- the 404 pointers, both ways ---------------------------------------------------

    "$m" "27. an indexed counter is called absent instead of pointed at /p4/counter" "$API" \
        '    if client.direct_counter_by_name(name) is None and _counter_kind(client, name) == "indexed":' \
        '    if False:' \
        'test_an_indexed_counter_is_404_and_points_at_the_counter_route'

    "$m" "28. a name that is both kinds is sent away instead of read" "$API" \
        '    if client.direct_counter_by_name(name) is None and _counter_kind(client, name) == "indexed":' \
        '    if _counter_kind(client, name) == "indexed":' \
        'test_a_name_that_is_both_kinds_is_read_as_the_direct_counter'

    "$m" "29. every unknown counter is called a direct counter (K1-neg's word lost)" "$API" \
        '    if _counter_kind(client, name) == "direct":' \
        '    if _counter_kind(client, name) != "indexed":' \
        'test_a_name_that_is_neither_keeps_the_old_404'

    "$m" "30. a direct counter's name is called absent again" "$API" \
        '    if _counter_kind(client, name) == "direct":' \
        '    if False:' \
        'test_a_direct_counter_name_is_404_and_points_at_the_direct_route'

    # ---- registration --------------------------------------------------------------------

    "$m" "31. the route is not registered" "$API" \
        '@router.get("/p4/direct_counter/{name}")
' \
        '' \
        'test_the_path_and_method_are_on_the_router'

    # Weak by construction: the test reads the convertor's class name, so it pins the spelling
    # of the decorator rather than a request that a greedy parameter would answer differently.
    "$m" "32. the name becomes a greedy path parameter" "$API" \
        '@router.get("/p4/direct_counter/{name}")' \
        '@router.get("/p4/direct_counter/{name:path}")' \
        'test_the_name_is_a_plain_path_parameter'
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
