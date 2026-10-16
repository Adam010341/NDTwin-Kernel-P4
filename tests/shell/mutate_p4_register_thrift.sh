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
# own replacement (28=27, 30=29, 38=37, 44=43, 46=45, 47=45, 49=48, 51=50, 58=57), and 60's is
# inside 59's, so check_gate_anchors.py counts fewer distinct anchors than this table has mutations.
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
        '            whole = await run_in_threadpool(bm_thrift.read_register, REGISTER_THRIFT_HOST, port,' \
        '            whole = (bm_thrift.read_register)(REGISTER_THRIFT_HOST, port,' \
        'test_the_range_read_runs_on_a_worker_thread_too'

    "$m" "3. the route's read loses its deadline" "$API" \
        '                                           full, start, RPC_TIMEOUT_S)]' \
        '                                           full, start, None)]' \
        'test_one_cell_is_one_bm_register_read_of_that_index_on_the_switchs_port'

    # Round 2: one budget for the whole call, not a fresh timeout per receive.
    "$m" "4. a receive gets a fresh timeout instead of what is left of the call's" "$BMT" \
        '        def read(self, sz):
            if self.handle is not None:
                self.handle.settimeout(self._left())' \
        '        def read(self, sz):
            if self.handle is not None:
                self.handle.settimeout(timeout_left_unused := 3.0)' \
        'test_a_peer_trickling_a_byte_every_2_s_is_cut_at_the_calls_deadline'

    "$m" "5. a value outside bit<W> is passed on" "$API" \
        '    outside = [v for v in raw if not 0 <= v < (1 << width)]' \
        '    outside = []' \
        'test_a_value_outside_the_registers_width_is_502_not_truncated'

    "$m" "6. the answer stops saying it came from bmv2's thrift" "$API" \
        '            "values": list(raw), "source": "bmv2-thrift"}' \
        '            "values": list(raw)}' \
        'test_one_cell_is_200_with_its_value_and_says_where_it_came_from'

    "$m" "7. a range is not sliced at its start" "$API" \
        '            raw = whole[start:start + count]' \
        '            raw = whole[:count]' \
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

    "$m" "11. a whole array of another size than p4info's is sliced anyway" "$API" \
        '            if len(whole) != size:' \
        '            if False:' \
        'test_a_whole_array_longer_than_p4info_says_is_502_before_slicing'

    "$m" "12. bmv2's refusal is reported as no answer" "$API" \
        '        raise _register_error(502, "register refused", dpid, full, str(err),' \
        '        raise _register_error(503, "register refused", dpid, full, str(err),' \
        'test_bmv2_refusing_the_name_is_502_with_its_code'

    "$m" "13. bytes that are not thrift are reported as an invalid answer" "$API" \
        '        raise _register_error(502, "register answer not understood", dpid, full, str(err),' \
        '        raise _register_error(502, "register answer invalid", dpid, full, str(err),' \
        'test_bytes_that_are_not_thrift_are_502_not_understood'

    "$m" "14. the refusal's code loses its name" "$API" \
        '                              code=bm_thrift.ERROR_NAMES.get(err.code, err.code),' \
        '                              code=err.code,' \
        'test_bmv2_refusing_the_name_is_502_with_its_code'

    "$m" "15. an answer that is not the answer is reported as no answer" "$API" \
        '        raise _register_error(502, "register answer invalid", dpid, full, str(err),' \
        '        raise _register_error(503, "register answer invalid", dpid, full, str(err),' \
        'test_an_answer_that_is_not_the_answer_is_502'

    "$m" "16. the wire names another context id" "$BMT" \
        '        proto.writeI32(0)' \
        '        proto.writeI32(1)' \
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
        '    if 1 in got:
        raise RegisterReadRefused(got[1])' \
        '    if False:
        raise RegisterReadRefused(got[1])' \
        'test_bmv2s_refusal_carries_its_code'

    "$m" "21. no result reads as 0" "$BMT" \
        '    if 0 not in got:
        raise ThriftAnswerInvalid("%s answered with no result" % name)' \
        '    if 0 not in got:
        return 0' \
        'test_no_result_at_all_is_invalid_not_a_zero'

    "$m" "22. the identity call reads the device id from another field" "$BMT" \
        '    got = _read_struct(proto, {1: (TType.I64, lambda p: p.readI64()),' \
        '    got = _read_struct(proto, {3: (TType.I64, lambda p: p.readI64()),' \
        'test_the_identity_call_is_the_generated_clients_bytes_and_its_answer_is_read'

    "$m" "23. an answer to another call is taken" "$BMT" \
        '    if rname != name or mtype != TMessageType.REPLY:' \
        '    if False:' \
        'test_an_answer_to_another_call_is_invalid'

    "$m" "24. a list of another type is decoded anyway" "$BMT" \
        '    if etype != TType.I64:' \
        '    if False:' \
        'test_a_list_of_another_type_is_invalid'

    "$m" "25. an answer cut short escapes as EOFError" "$BMT" \
        '    except (OSError, EOFError) as exc:' \
        '    except OSError as exc:' \
        'test_an_answer_cut_short_is_unreachable'

    "$m" "26. a refused connection escapes unwrapped" "$BMT" \
        '    except (TTransport.TTransportException, OSError) as exc:
        raise ThriftUnreachable("no thrift connection' \
        '    except ValueError as exc:
        raise ThriftUnreachable("no thrift connection' \
        'test_nothing_listening_is_unreachable'

    "$m" "27. the client is built without its switch's thrift port" "$MAIN" \
        '    client.thrift_port = thrift_port_for(dpid) if port_base == DEFAULT_GRPC_PORT_BASE else None' \
        '    client.thrift_port = None' \
        'test_the_client_carries_the_thrift_port_its_switch_listens_on'

    "$m" "28. another gRPC numbering gets p4_testbed_topo's thrift port anyway" "$MAIN" \
        '    client.thrift_port = thrift_port_for(dpid) if port_base == DEFAULT_GRPC_PORT_BASE else None' \
        '    client.thrift_port = thrift_port_for(dpid)' \
        'test_a_client_on_another_grpc_numbering_has_no_thrift_port'

    # Round 2: the thrift port must be this switch's (measured: a swapped port answered 200 with
    # the other switch's cells).
    "$m" "29. the thrift port's identity is not checked" "$API" \
        '        if (identity.get("device_id"), identity.get("thrift_port")) != (client.device_id, port):' \
        '        if False:' \
        'test_another_device_on_the_port_is_502_and_nothing_is_read'

    "$m" "30. only the device id is checked, not the port" "$API" \
        '        if (identity.get("device_id"), identity.get("thrift_port")) != (client.device_id, port):' \
        '        if identity.get("device_id") != client.device_id:' \
        'test_the_same_device_on_another_port_is_502'

    "$m" "31. the identity is asked before every read" "$API" \
        '        identity = getattr(client, "thrift_identity", None)' \
        '        identity = None' \
        'test_the_identity_is_asked_once_per_client'

    "$m" "32. the identity is never kept on the client" "$API" \
        '            client.thrift_identity = identity' \
        '            pass' \
        'test_the_identity_is_asked_once_per_client'

    "$m" "33. bytes that cannot be decoded are reported as no answer" "$BMT" \
        '    except (TProtocolException, UnicodeDecodeError, struct.error, ValueError, OverflowError) as exc:' \
        '    except (TProtocolException, UnicodeDecodeError, struct.error, ValueError, OverflowError) as exc:
        raise ThriftUnreachable(str(exc)) from exc' \
        'test_a_version_that_is_not_thrifts_is_not_understood'

    "$m" "34. a negative length is reported as no answer" "$BMT" \
        '        if exc.type in (TTransport.TTransportException.NEGATIVE_SIZE,' \
        '        if exc.type in (' \
        'test_a_negative_list_size_is_not_understood_and_not_unreachable'

    "$m" "35. thrift is imported when the module is" "$BMT" \
        'import struct
import time
' \
        'import struct
import time
import thrift.Thrift  # MUTANT: a hard import again
' \
        'test_the_proxy_imports_and_the_call_says_thrift_is_not_installed'

    "$m" "36. no thrift package is reported as no answer" "$API" \
        '        raise _register_error(503, "thrift not installed", dpid, full, str(err),' \
        '        raise _register_error(503, "register not read", dpid, full, str(err),' \
        'test_no_thrift_package_is_503_for_this_route_alone'

    # ---- half two: the bounds, the caps, the refusals before the switch ---------------

    "$m" "37. the index bound lets one past the end through" "$API" \
        '    if start + count > size:' \
        '    if start + count > size + 1:' \
        'test_an_index_past_the_end_is_400_and_says_the_size'

    "$m" "38. the index bound refuses the last cell" "$API" \
        '    if start + count > size:' \
        '    if start + count >= size:' \
        'test_the_last_index_is_read'

    "$m" "39. a start past the end is called an empty range" "$API" \
        '    if start >= size:' \
        '    if False:' \
        'test_a_start_past_the_end_is_400_index_out_of_range'

    "$m" "40. a negative index is read" "$API" \
        '    if start < 0:' \
        '    if False:' \
        'test_a_negative_index_is_400'

    "$m" "41. an empty range is read" "$API" \
        '    if count < 1:' \
        '    if False:' \
        'test_an_empty_range_is_400'

    "$m" "42. index and a range together are taken" "$API" \
        '    if index is not None and (start is not None or count is not None):' \
        '    if False:' \
        'test_index_with_a_range_is_400'

    "$m" "43. the cell cap is dropped" "$API" \
        '    if count > REGISTER_CELLS_MAX:' \
        '    if False:' \
        'test_more_cells_than_the_cap_is_413'

    "$m" "44. the cell cap refuses the cap itself" "$API" \
        '    if count > REGISTER_CELLS_MAX:' \
        '    if count >= REGISTER_CELLS_MAX:' \
        'test_the_cap_itself_is_read'

    "$m" "45. a range of a huge array is fetched whole" "$API" \
        '    if count > 1 and size > REGISTER_READ_ALL_MAX:' \
        '    if False:' \
        'test_a_range_of_an_array_too_big_to_fetch_whole_is_413'

    "$m" "46. one cell of a huge array is refused" "$API" \
        '    if count > 1 and size > REGISTER_READ_ALL_MAX:' \
        '    if size > REGISTER_READ_ALL_MAX:' \
        'test_one_cell_of_an_array_too_big_to_fetch_whole_is_read'

    "$m" "47. the fetch-whole limit refuses the limit itself" "$API" \
        '    if count > 1 and size > REGISTER_READ_ALL_MAX:' \
        '    if count > 1 and size >= REGISTER_READ_ALL_MAX:' \
        'test_the_fetch_whole_limit_itself_is_read_and_one_past_it_is_413'

    # Round 2, measured on both builds: a bit<64> cell at or above 2^63 reads as 2^63 - 1.
    "$m" "48. bit<64> is read again" "$API" \
        '    if width > 63:' \
        '    if width > 64:' \
        'test_a_bit64_register_is_501_and_says_why'

    "$m" "49. bit<63> is refused too" "$API" \
        '    if width > 63:' \
        '    if width > 62:' \
        'test_a_bit63_register_is_read_up_to_its_top'

    "$m" "50. an int<W> register is read as a bit<W> one" "$API" \
        '    if not reg.type_spec.HasField("bitstring") or not reg.type_spec.bitstring.HasField("bit"):' \
        '    if not reg.type_spec.HasField("bitstring"):' \
        'test_an_int_w_register_is_501'

    "$m" "51. a register that is not bit<W> is read" "$API" \
        '    if not reg.type_spec.HasField("bitstring") or not reg.type_spec.bitstring.HasField("bit"):' \
        '    if False:' \
        'test_a_register_that_is_not_bit_w_is_501'

    "$m" "52. a client with no thrift port is asked anyway" "$API" \
        '    if port is None:' \
        '    if False:' \
        'test_a_client_with_no_thrift_port_is_503'

    "$m" "53. a name that is no register is read as the first register" "$API" \
        '            return reg
    return None' \
        '            return reg
    return client.p4info.registers[0]' \
        'test_a_name_that_is_no_register_is_404'

    "$m" "54. the alias is not accepted" "$API" \
        '        if name in (reg.preamble.name, reg.preamble.alias):' \
        '        if name == reg.preamble.name:' \
        'test_the_alias_names_the_same_register_and_the_full_name_is_asked'

    "$m" "55. an unknown switch answers 200" "$API" \
        '        raise _register_error(404, "unknown switch", dpid, name,' \
        '        return {"values": []}
        raise _register_error(404, "unknown switch", dpid, name,' \
        'test_an_unknown_dpid_is_404'

    "$m" "56. no topology is answered 404" "$API" \
        '        raise _register_error(503, "no topology", dpid, name, "proxy has no topology yet")' \
        '        raise _register_error(404, "no topology", dpid, name, "proxy has no topology yet")' \
        'test_no_topology_is_503'

    # Registers are reset by a readopt's pipeline push.
    "$m" "57. a switch being re-adopted is read anyway" "$API" \
        '    if journals is not None and journals.pending(dpid):
        raise _register_error(503, "replay pending",' \
        '    if False:
        raise _register_error(503, "replay pending",' \
        'test_a_switch_being_readopted_is_503_replay_pending'

    "$m" "58. every switch is refused while one is re-adopted" "$API" \
        '    if journals is not None and journals.pending(dpid):
        raise _register_error(503, "replay pending",' \
        '    if journals is not None:
        raise _register_error(503, "replay pending",' \
        'test_another_switch_being_readopted_does_not_stop_this_read'

    # ---- registration --------------------------------------------------------------------

    "$m" "59. the route is not registered" "$API" \
        '@router.get("/p4/register/{name}")
' \
        '' \
        'test_the_path_and_method_are_on_the_router'

    # A write method on the read route would make the health check's R3 see a register WRITE.
    "$m" "60. the read route also answers POST" "$API" \
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
