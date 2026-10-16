#!/usr/bin/env bash
#
# Mutation gate for GET /p4/register and its bmv2 thrift client (p4_proxy/tests/test_register_route.py,
# test_bm_thrift.py, and test_app_package_proxy.py's thrift-port case).
#
# [Co-developed with claude code -- Adam]
# Built on tests/shell/mutate_p4_direct_counter.sh's machinery: every way of NOT proving a mutation
# is caught -- a non-unique anchor, a mutation that will not apply, the wrong test going red -- is
# counted as a SURVIVOR.
#
# 🔴 TWO DIRECTIONS. A read that says something bmv2 did not: no answer turned into a number, a
# signed i64 passed on as a bit<64> value, an alias sent to bmv2, a short answer accepted, the
# deadline dropped, the read moved onto the event loop, the wire bytes changed (half one). A route
# that refuses what it can read, or lets through what it cannot: the bounds off by one either
# way, the caps, the width and type checks, the replay check removed or widened (half two). Then
# the registration (a read route must stay GET-only: the health check's R3 looks for a WRITE).
#
# 🔴 SHARED ANCHORS. Some mutations start from exactly the anchor of an earlier one, each with its
# own replacement (6=5, 11=10, 13=12, 29=28, 31=30, 34=33, 36=35, 45=44), and 47's is inside
# 46's, so check_gate_anchors.py counts fewer distinct anchors than this table has mutations.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD -- run it in a
# clone or a worktree nobody else is using.
#
# Usage:
#   tests/shell/mutate_p4_register_thrift.sh            the gate
#   tests/shell/mutate_p4_register_thrift.sh --dry-run  anchors only, NOT a gate result
#   PROXY_PY=/path/to/python tests/shell/mutate_p4_register_thrift.sh
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only).
set -uo pipefail

API=p4_proxy/proxy_agent/api_routes.py
BMT=p4_proxy/proxy_agent/bm_thrift.py
MAIN=p4_proxy/proxy_agent/main.py
FILES=("$API" "$BMT" "$MAIN")

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
    local out all="" rc t
    clear_pyc
    for t in test_register_route.py test_bm_thrift.py test_app_package_proxy.py; do
        out=$(cd p4_proxy/tests && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. \
                  "$PROXY_PY" "$t" 2>&1); rc=$?
        [[ $rc -eq 0 ]] && continue
        all+=" $(sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_0-9]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' ')"
        # a file that failed without naming a test (an import error, a crash) still went red
        grep -qE '^(FAIL|ERROR):' <<<"$out" || all+=" CRASH:$t"
    done
    sed 's/^ *//; s/ *$//' <<<"$all"
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

    # ---- half one: the read must say exactly what bmv2 said ---------------------------

    "$m" "1. one cell is read on the event loop" "$API" \
        '            raw = [await run_in_threadpool(bm_thrift.read_register, REGISTER_THRIFT_HOST, port,' \
        '            raw = [bm_thrift.read_register(REGISTER_THRIFT_HOST, port,' \
        'test_the_thrift_read_runs_on_a_worker_thread'

    "$m" "2. a range is read on the event loop" "$API" \
        '            raw = (await run_in_threadpool(bm_thrift.read_register, REGISTER_THRIFT_HOST, port,' \
        '            raw = (bm_thrift.read_register(REGISTER_THRIFT_HOST, port,' \
        'test_the_range_read_runs_on_a_worker_thread_too'

    "$m" "3. the route's read loses its deadline" "$API" \
        '                                           full, start, RPC_TIMEOUT_S)]' \
        '                                           full, start, None)]' \
        'test_one_cell_is_one_bm_register_read_of_that_index_on_the_switchs_port'

    "$m" "4. the socket loses its timeout" "$BMT" \
        '    sock.setTimeout(int(timeout_s * 1000))' \
        '    pass' \
        'test_a_server_that_never_answers_costs_one_deadline'

    "$m" "5. bmv2's signed i64 is passed on as the value" "$API" \
        '            "values": [v & mask for v in raw], "source": "bmv2-thrift"}' \
        '            "values": list(raw), "source": "bmv2-thrift"}' \
        'test_a_64_bit_value_comes_back_unsigned'

    "$m" "6. the answer stops saying it came from bmv2's thrift" "$API" \
        '            "values": [v & mask for v in raw], "source": "bmv2-thrift"}' \
        '            "values": [v & mask for v in raw]}' \
        'test_one_cell_is_200_with_its_value_and_says_where_it_came_from'

    "$m" "7. a range is not sliced at its start" "$API" \
        '                                           full, None, RPC_TIMEOUT_S))[start:start + count]' \
        '                                           full, None, RPC_TIMEOUT_S))[:count]' \
        'test_a_range_is_sliced_from_the_array'

    "$m" "8. a short answer is accepted" "$API" \
        '    if len(raw) != count:' \
        '    if False:' \
        'test_a_short_answer_is_502_not_a_short_list'

    "$m" "9. the alias, not the register's name, is sent to bmv2" "$API" \
        '    full, size = reg.preamble.name, reg.size' \
        '    full, size = name, reg.size' \
        'test_the_alias_names_the_same_register_and_the_full_name_is_asked'

    # The one this route exists to get right: "bmv2 did not answer" read as a value.
    "$m" "10. no answer is answered with a success code" "$API" \
        '        raise _register_error(503, "register not read", dpid, full,' \
        '        raise _register_error(200, "register not read", dpid, full,' \
        'test_no_answer_is_503_and_not_a_zero'

    "$m" "11. no answer is reported as a refusal" "$API" \
        '        raise _register_error(503, "register not read", dpid, full,' \
        '        raise _register_error(502, "register not read", dpid, full,' \
        'test_no_answer_is_503_and_not_a_zero'

    "$m" "12. bmv2's refusal is reported as no answer" "$API" \
        '        raise _register_error(502, "register refused", dpid, full, str(err),' \
        '        raise _register_error(503, "register refused", dpid, full, str(err),' \
        'test_bmv2_refusing_the_name_is_502_with_its_code'

    "$m" "13. bmv2's refusal is answered 200" "$API" \
        '        raise _register_error(502, "register refused", dpid, full, str(err),' \
        '        raise _register_error(200, "register refused", dpid, full, str(err),' \
        'test_bmv2_refusing_the_name_is_502_with_its_code'

    "$m" "14. the refusal's code loses its name" "$API" \
        '                              code=bm_thrift.ERROR_NAMES.get(err.code, err.code),' \
        '                              code=err.code,' \
        'test_bmv2_refusing_the_name_is_502_with_its_code'

    "$m" "15. an answer that is not the answer is reported as no answer" "$API" \
        '        raise _register_error(502, "register answer invalid", dpid, full, str(err),' \
        '        raise _register_error(503, "register answer invalid", dpid, full, str(err),' \
        'test_an_answer_that_is_not_the_answer_is_502'

    "$m" "16. the wire names another context id" "$BMT" \
        '    proto.writeFieldBegin("cxt_id", TType.I32, 1)
    proto.writeI32(0)' \
        '    proto.writeFieldBegin("cxt_id", TType.I32, 1)
    proto.writeI32(1)' \
        'test_one_cell_is_the_generated_clients_bytes'

    "$m" "17. the register name goes out under another field id" "$BMT" \
        '    proto.writeFieldBegin("register_array_name", TType.STRING, 2)' \
        '    proto.writeFieldBegin("register_array_name", TType.STRING, 4)' \
        'test_the_whole_array_is_the_generated_clients_bytes'

    "$m" "18. the call goes to another thrift service" "$BMT" \
        'SERVICE = "standard"' \
        'SERVICE = "simple_switch"' \
        'test_one_cell_is_the_generated_clients_bytes'

    "$m" "19. the index is left off the one-cell call" "$BMT" \
        '    if index is not None:
        proto.writeFieldBegin("idx", TType.I32, 3)' \
        '    if False:
        proto.writeFieldBegin("idx", TType.I32, 3)' \
        'test_one_cell_is_the_generated_clients_bytes'

    "$m" "20. bmv2's refusal is ignored" "$BMT" \
        '    if ouch is not None:
        raise RegisterReadRefused(ouch)' \
        '    if False:
        raise RegisterReadRefused(ouch)' \
        'test_bmv2s_refusal_carries_its_code'

    "$m" "21. no result reads as 0" "$BMT" \
        '    if not have_success:
        raise ThriftAnswerInvalid("%s answered with no result" % name)' \
        '    if not have_success:
        return 0' \
        'test_no_result_at_all_is_invalid_not_a_zero'

    "$m" "22. a 0 reads as no result" "$BMT" \
        '    if not have_success:' \
        '    if not success:' \
        'test_a_zero_is_a_zero_and_not_a_missing_result'

    "$m" "23. an answer to another call is taken" "$BMT" \
        '    if rname != name or mtype != TMessageType.REPLY:' \
        '    if False:' \
        'test_an_answer_to_another_call_is_invalid'

    "$m" "24. a list of another type is decoded anyway" "$BMT" \
        '            if etype != TType.I64:' \
        '            if False:' \
        'test_a_list_of_another_type_is_invalid'

    "$m" "25. an answer cut short escapes as EOFError" "$BMT" \
        '    except (TTransport.TTransportException, OSError, EOFError) as exc:' \
        '    except (TTransport.TTransportException, OSError) as exc:' \
        'test_an_answer_cut_short_is_unreachable'

    "$m" "26. a refused connection escapes unwrapped" "$BMT" \
        '    except (TTransport.TTransportException, OSError) as exc:
        raise ThriftUnreachable("no thrift connection' \
        '    except ValueError as exc:
        raise ThriftUnreachable("no thrift connection' \
        'test_nothing_listening_is_unreachable'

    "$m" "27. the client is built without its switch's thrift port" "$MAIN" \
        '    client.thrift_port = thrift_port_for(dpid)' \
        '    client.thrift_port = None' \
        'test_the_client_carries_the_thrift_port_its_switch_listens_on'

    # ---- half two: the bounds, the caps, the refusals before the switch ---------------

    "$m" "28. the index bound lets one past the end through" "$API" \
        '    if start + count > size:' \
        '    if start + count > size + 1:' \
        'test_an_index_past_the_end_is_400_and_says_the_size'

    "$m" "29. the index bound refuses the last cell" "$API" \
        '    if start + count > size:' \
        '    if start + count >= size:' \
        'test_the_last_index_is_read'

    "$m" "30. a negative index is read" "$API" \
        '    if start < 0 or count < 1:' \
        '    if count < 1:' \
        'test_a_negative_index_is_400'

    "$m" "31. an empty range is read" "$API" \
        '    if start < 0 or count < 1:' \
        '    if start < 0:' \
        'test_an_empty_range_is_400'

    "$m" "32. index and a range together are taken" "$API" \
        '    if index is not None and (start is not None or count is not None):' \
        '    if False:' \
        'test_index_with_a_range_is_400'

    "$m" "33. the cell cap is dropped" "$API" \
        '    if count > REGISTER_CELLS_MAX:' \
        '    if False:' \
        'test_more_cells_than_the_cap_is_413'

    "$m" "34. the cell cap refuses the cap itself" "$API" \
        '    if count > REGISTER_CELLS_MAX:' \
        '    if count >= REGISTER_CELLS_MAX:' \
        'test_the_cap_itself_is_read'

    "$m" "35. a range of a huge array is fetched whole" "$API" \
        '    if count > 1 and size > REGISTER_READ_ALL_MAX:' \
        '    if False:' \
        'test_a_range_of_an_array_too_big_to_fetch_whole_is_413'

    "$m" "36. one cell of a huge array is refused" "$API" \
        '    if count > 1 and size > REGISTER_READ_ALL_MAX:' \
        '    if size > REGISTER_READ_ALL_MAX:' \
        'test_one_cell_of_an_array_too_big_to_fetch_whole_is_read'

    "$m" "37. a register wider than 64 bits is read" "$API" \
        '    if width > 64:' \
        '    if False:' \
        'test_a_register_wider_than_64_bits_is_501'

    "$m" "38. a register that is not bit<W> is read" "$API" \
        '    if not reg.type_spec.HasField("bitstring") or not reg.type_spec.bitstring.HasField("bit"):' \
        '    if False:' \
        'test_a_register_that_is_not_bit_w_is_501'

    "$m" "39. a client with no thrift port is asked anyway" "$API" \
        '    if port is None:' \
        '    if False:' \
        'test_a_client_with_no_thrift_port_is_503'

    "$m" "40. a name that is no register is read as the first register" "$API" \
        '            return reg
    return None' \
        '            return reg
    return client.p4info.registers[0]' \
        'test_a_name_that_is_no_register_is_404'

    "$m" "41. the alias is not accepted" "$API" \
        '        if name in (reg.preamble.name, reg.preamble.alias):' \
        '        if name == reg.preamble.name:' \
        'test_the_alias_names_the_same_register_and_the_full_name_is_asked'

    "$m" "42. an unknown switch answers 200" "$API" \
        '        raise _register_error(404, "unknown switch", dpid, name,' \
        '        return {"values": []}
        raise _register_error(404, "unknown switch", dpid, name,' \
        'test_an_unknown_dpid_is_404'

    "$m" "43. no topology is answered 404" "$API" \
        '        raise _register_error(503, "no topology", dpid, name, "proxy has no topology yet")' \
        '        raise _register_error(404, "no topology", dpid, name, "proxy has no topology yet")' \
        'test_no_topology_is_503'

    # Registers are reset by a readopt's pipeline push.
    "$m" "44. a switch being re-adopted is read anyway" "$API" \
        '    if table_journals is not None and table_journals.pending(dpid):
        raise _register_error(503, "replay pending",' \
        '    if False:
        raise _register_error(503, "replay pending",' \
        'test_a_switch_being_readopted_is_503_replay_pending'

    "$m" "45. every switch is refused while one is re-adopted" "$API" \
        '    if table_journals is not None and table_journals.pending(dpid):
        raise _register_error(503, "replay pending",' \
        '    if table_journals is not None:
        raise _register_error(503, "replay pending",' \
        'test_another_switch_being_readopted_does_not_stop_this_read'

    # ---- registration --------------------------------------------------------------------

    "$m" "46. the route is not registered" "$API" \
        '@router.get("/p4/register/{name}")
' \
        '' \
        'test_the_path_and_method_are_on_the_router'

    # A write method on the read route would make the health check's R3 see a register WRITE.
    "$m" "47. the read route also answers POST" "$API" \
        '@router.get("/p4/register/{name}")' \
        '@router.api_route("/p4/register/{name}", methods=["GET", "POST"])' \
        'test_the_path_and_method_are_on_the_router'
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
