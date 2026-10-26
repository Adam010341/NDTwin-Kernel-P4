#!/usr/bin/env bash
#
# Mutation gate for prefix destinations on the proxy's Ryu-compatible routing path
# (p4_proxy/tests/test_cidr_destination.py).
#
# [Co-developed with claude code -- Adam]
# A CIDR destination on a destination-only match is accepted and installed into ipv4_lpm as that
# prefix, the longest prefix wins, and a /32 behaves exactly as before. Most of the new tests were
# seen red against the pre-change code (it refused every prefix). The ones that pin what is STILL
# refused were green there by construction, so this gate is where they are seen red; the rest are
# re-checked against one specific wrong implementation each.
#
# Shape of tests/shell/mutate_p4_priority_refusal.sh: every way of NOT proving a mutation is
# caught -- a non-unique anchor, a mutation that will not apply, the wrong test going red -- is
# counted as a SURVIVOR. The baseline is the WORKING TREE, snapshotted first and restored on any
# exit; byte-identity is asserted at the end. A red baseline is refused.
#
# Usage:
#   tests/shell/mutate_cidr_destination.sh            the gate
#   tests/shell/mutate_cidr_destination.sh --dry-run  anchors only, NOT a gate result
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only).
set -uo pipefail

TOPO=p4_proxy/proxy_agent/topology_manager.py
SLOT=p4_proxy/proxy_agent/slot_priority.py
RT=p4_proxy/proxy_agent/ryu_topology.py
API=p4_proxy/proxy_agent/api_routes.py
FILES=("$TOPO" "$SLOT" "$RT" "$API")
TEST_FILES=(test_cidr_destination.py test_unsupported_match.py test_delete_restores_route.py)

# The proxy's venv sits in the main checkout (it is untracked, so a linked worktree has none):
# look beside this script's checkout first, then in the checkout the worktree belongs to.
if [[ -z "${PROXY_PY:-}" ]]; then
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    COMMON=$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/.." 2>/dev/null && pwd)
    for cand in "$ROOT/p4_proxy/venv/bin/python3" "$COMMON/p4_proxy/venv/bin/python3"; do
        if [[ -x "$cand" ]]; then PROXY_PY=$cand; break; fi
    done
fi
PROXY_PY="${PROXY_PY:-}"

MODE=full
case "${1:-}" in
    --dry-run) MODE=dryrun ;;
    "")        ;;
    *) echo "REFUSE: unknown argument '$1'. Use --dry-run." >&2; exit 2 ;;
esac

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -n "$PROXY_PY" && -x "$PROXY_PY" ]] || {
    echo "REFUSE: proxy interpreter '${PROXY_PY}' not found. Set PROXY_PY." >&2; exit 2; }

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done

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
REDDENED=" "

anchor_count() {
    ANCHOR="$2" "$PROXY_PY" - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# The identities of the tests that failed, space-separated; empty if green. A file that exits
# nonzero with no FAIL/ERROR line reports CRASHED:<file>, which no expected name matches.
red_proxy() {
    local out rc f names=""
    clear_pyc
    for f in "${TEST_FILES[@]}"; do
        out=$(cd p4_proxy/tests && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. \
                  "$PROXY_PY" "$f" 2>&1); rc=$?
        [[ $rc -eq 0 ]] && continue
        local got
        got=$(sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_0-9]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' ')
        [[ -n "$got" ]] || got="CRASHED:$f "
        names+="$got"
    done
    echo "$names"
}

# mutate <label> <file> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" file="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- counted as a survivor. Fix the anchor."
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
    REDDENED+="$failed "
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -qw -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
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

each_mutation() {
    local m="$1"

    # ---- what is still refused --------------------------------------------------------
    "$m" "1. any prefix length is accepted (/33)" "$SLOT" \
        '    if not MIN_PREFIX_LEN <= prefix_len <= MAX_PREFIX_LEN:' \
        '    if False:' \
        'test_a_malformed_prefix_is_refused_by_every_verb_before_any_write'

    "$m" "2. the endpoint half of 1: /33 answers 200" "$SLOT" \
        '    if not MIN_PREFIX_LEN <= prefix_len <= MAX_PREFIX_LEN:' \
        '    if prefix_len > 99:' \
        'test_the_endpoint_answers_400_for_a_malformed_prefix'

    "$m" "3. the length is parsed with int(): ' 24', '+24' and non-ASCII digits pass" "$SLOT" \
        '    if not (1 <= len(length) <= 2 and all("0" <= c <= "9" for c in length)):' \
        '    if not length.strip().lstrip("+-").isdigit():' \
        'test_a_malformed_prefix_is_refused_by_every_verb_before_any_write'

    "$m" "4. /0 is accepted" "$SLOT" \
        'MIN_PREFIX_LEN = 1' \
        'MIN_PREFIX_LEN = 0' \
        'test_a_malformed_prefix_is_refused_by_every_verb_before_any_write'

    "$m" "5. a prefix passes on a five-tuple match" "$TOPO" \
        '    prefix_ok = not needs_five_tuple(match_dict)' \
        '    prefix_ok = True' \
        'test_a_prefix_on_a_five_tuple_match_is_refused_and_says_why'

    # A source always makes the match a five-tuple one (prefix_ok false), so dropping only the
    # field test is an equivalent mutant (measured: it survived). The guard is kept as defence in
    # depth, and this mutation removes both halves, which is the behaviour the test pins.
    "$m" "6. a prefix passes on a source address" "$TOPO" \
        '        if prefix_ok and field in DESTINATION_MATCH_FIELDS:' \
        '        if True:' \
        'test_a_prefix_on_a_source_is_refused'

    "$m" "7. a refused destination gets the exact-address sentence" "$TOPO" \
        '                                               prefix_allowed=True) from None' \
        '                                               ) from None' \
        'test_the_400_says_what_a_destination_may_be'

    # ---- accepted, and written as the prefix ------------------------------------------
    "$m" "8. every prefix is refused again" "$TOPO" \
        '    prefix_ok = not needs_five_tuple(match_dict)' \
        '    prefix_ok = False' \
        'test_route_flow_writes_the_network_and_its_length'

    "$m" "9. an install writes /32 whatever the prefix" "$TOPO" \
        '                lambda: client.insert_ipv4_route(address, prefix_len, next_hop_mac, out_port),' \
        '                lambda: client.insert_ipv4_route(address, 32, next_hop_mac, out_port),' \
        'test_add_delete_and_modify_of_a_prefix'

    "$m" "10. a modify writes /32 whatever the prefix" "$TOPO" \
        'lambda: client.modify_ipv4_route(address, prefix_len, next_hop_mac, out_port),' \
        'lambda: client.modify_ipv4_route(address, 32, next_hop_mac, out_port),' \
        'test_modify_moves_the_prefix_and_its_record'

    "$m" "11. a delete removes the /32 of the network address" "$TOPO" \
        'lambda: client.delete_ipv4_route(address, prefix_len),' \
        'lambda: client.delete_ipv4_route(address, 32),' \
        'test_unroute_removes_the_prefix_and_leaves_the_host_routes'

    "$m" "12. host bits are not cleared" "$SLOT" \
        '    network = socket.inet_ntoa((raw & mask).to_bytes(4, "big"))' \
        '    network = socket.inet_ntoa(raw.to_bytes(4, "big"))' \
        'test_host_bits_are_cleared_as_ovs_does'

    "$m" "13. a /32 keys as \"a.b.c.d/32\", not the bare address" "$SLOT" \
        '    return network if prefix_len == MAX_PREFIX_LEN else f"{network}/{prefix_len}"' \
        '    return f"{network}/{prefix_len}"' \
        'test_a_slash_32_is_the_bare_address'

    "$m" "14. the record and the request lose the prefix" "$TOPO" \
        '            canon = slot_priority.canonical_route_key(value)' \
        '            canon = slot_priority.split_route_key(slot_priority.canonical_route_key(value))[0]' \
        'test_the_record_is_keyed_by_the_prefix'

    "$m" "15. the slot of a prefix is the slot of its network address" "$SLOT" \
        '    return dpid, canonical_route_key(ipv4_dst)' \
        '    return dpid, canonical_route_key(ipv4_dst).partition("/")[0]' \
        'test_a_modify_naming_the_prefixs_install_priority_is_honoured'

    "$m" "16. a prefix out of a host port carries a zero MAC" "$TOPO" \
        '                    return address, prefix_len, self.net.nodes[neighbour].get("mac", zero)' \
        '                    return address, prefix_len, zero' \
        'test_a_prefix_out_of_a_host_port_carries_that_hosts_mac'

    # ---- the A-4d restore ---------------------------------------------------------------
    "$m" "17. a prefix's withdrawal is handed back to the control plane" "$TOPO" \
        '                            if prefix_len == slot_priority.MAX_PREFIX_LEN else None)' \
        '                            if True else None)' \
        'test_unroute_of_a_prefix_is_never_a_control_plane_restore'

    "$m" "18. a /32's withdrawal is never restored" "$TOPO" \
        '                            if prefix_len == slot_priority.MAX_PREFIX_LEN else None)' \
        '                            if prefix_len != slot_priority.MAX_PREFIX_LEN else None)' \
        'test_deleting_a_hosts_slash_32_still_restores_the_control_plane_route'

    # ---- the path view: longest prefix ------------------------------------------------
    "$m" "19. the path view ignores prefixes" "$RT" \
        '    routes = prefixes.get(dpid)' \
        '    routes = None' \
        'test_the_slash_24_carries_the_rest'

    "$m" "20. the shortest prefix wins" "$RT" \
        '        routes.sort(key=lambda r: -r[0])' \
        '        routes.sort(key=lambda r: r[0])' \
        'test_the_lookup_alone_picks_the_longest'

    "$m" "21. a covering prefix beats the /32" "$RT" \
        '    port = installed.get((dpid, dst_ip))
    if port is not None:
        return port
    routes = prefixes.get(dpid)' \
        '    port = installed.get((dpid, dst_ip))
    routes = prefixes.get(dpid)
    if port is not None and not routes:
        return port' \
        'test_the_slash_32_wins_for_its_host'

    "$m" "22. installed_path builds no prefix index of its own" "$RT" \
        '    if prefixes is None:
        prefixes = prefix_routes(installed)' \
        '    if prefixes is None:
        prefixes = {}' \
        'test_installed_path_follows_a_prefix'

    "$m" "23. render_destination_paths passes an empty index" "$RT" \
        '    prefixes = prefix_routes(installed) if installed else {}' \
        '    prefixes = {}' \
        'test_a_slash_32_removed_for_good_falls_back_to_the_prefix_in_the_path_view'

    # ---- readopt -----------------------------------------------------------------------
    "$m" "24. a readopt keeps the re-pushed switch's prefix records" "$TOPO" \
        '                    del self._installed_routes[key]' \
        '                    pass' \
        'test_a_readopt_drops_that_switchs_prefix_records_only'

    "$m" "25. a readopt drops every switch's prefix records" "$TOPO" \
        '                            if k[0] == dpid and "/" in str(k[1])]:' \
        '                            if "/" in str(k[1])]:' \
        'test_a_readopt_drops_that_switchs_prefix_records_only'

    # ---- full dotted quads only (the kernel's address check) ----------------------------
    "$m" "26. the address half is read with inet_aton again (10.0.1/24 is 10.0.0.1/24)" "$SLOT" \
        '        socket.inet_pton(socket.AF_INET, text)
    except (OSError, ValueError):' \
        '        socket.inet_aton(text)
    except (OSError, ValueError):' \
        'test_a_malformed_prefix_is_refused_by_every_verb_before_any_write'

    "$m" "27. a source address is read with inet_aton again" "$TOPO" \
        '        if not (isinstance(value, str) and slot_priority.is_dotted_quad(value)):' \
        '        if not (isinstance(value, str) and (socket.inet_aton(value) or True)):' \
        'test_short_and_hex_forms_are_refused_as_the_kernel_refuses_them'

    # ---- a present address field must be readable ---------------------------------------
    "$m" "28. an empty or null destination is skipped again" "$TOPO" \
        '        value = match_dict[field]
        if prefix_ok and field in DESTINATION_MATCH_FIELDS:' \
        '        value = match_dict[field]
        if not value:
            continue
        if prefix_ok and field in DESTINATION_MATCH_FIELDS:' \
        'test_an_empty_or_null_destination_is_refused_by_every_verb'

    "$m" "29. an empty or null source is skipped" "$TOPO" \
        '        if not (isinstance(value, str) and slot_priority.is_dotted_quad(value)):' \
        '        if value and not (isinstance(value, str) and slot_priority.is_dotted_quad(value)):' \
        'test_an_empty_or_null_source_is_refused'

    "$m" "30. an empty destination falls through to the other spelling" "$TOPO" \
        '        value = match_dict[field]
        if prefix_ok and field in DESTINATION_MATCH_FIELDS:' \
        '        value = match_dict[field]
        if not value and any(other in match_dict for other in DESTINATION_MATCH_FIELDS - {field}):
            return
        if prefix_ok and field in DESTINATION_MATCH_FIELDS:' \
        'test_an_empty_destination_does_not_fall_through_to_the_other_spelling'

    "$m" "31. the 400 for an empty destination is lost at the endpoint" "$TOPO" \
        '        value = match_dict[field]
        if prefix_ok and field in DESTINATION_MATCH_FIELDS:' \
        '        value = match_dict[field]
        if value is None or value == "":
            continue
        if prefix_ok and field in DESTINATION_MATCH_FIELDS:' \
        'test_the_endpoints_answer_400_for_an_empty_destination'

    "$m" "32. the refusal of an empty destination does not name the operation" "$TOPO" \
        '                raise MalformedMatchValueError(field, value, action,' \
        '                raise MalformedMatchValueError(field, value, "installed",' \
        'test_the_400_names_the_field_and_what_was_not_done'

    # ---- the two spellings of one field must agree --------------------------------------
    "$m" "33. conflicting spellings are not refused" "$TOPO" \
        '                raise ConflictingMatchValueError((first, second), (a, b), action)' \
        '                pass' \
        'test_different_destinations_are_refused_by_every_verb'

    "$m" "34. conflicting sources are not checked" "$TOPO" \
        'ADDRESS_SPELLING_PAIRS = (("nw_dst", "ipv4_dst"), ("nw_src", "ipv4_src"))' \
        'ADDRESS_SPELLING_PAIRS = (("nw_dst", "ipv4_dst"),)' \
        'test_different_sources_are_refused'

    "$m" "35. spellings are compared as written, not as normalised (host bits, /32)" "$TOPO" \
        '            if _normalised_address(a, prefix_ok and first in DESTINATION_MATCH_FIELDS) != \
                    _normalised_address(b, prefix_ok and second in DESTINATION_MATCH_FIELDS):' \
        '            if a != b:' \
        'test_the_same_destination_in_both_spellings_is_accepted'

    "$m" "36. the same source in both spellings is refused" "$TOPO" \
        '    return socket.inet_pton(socket.AF_INET, value)
' \
        '    return object()
' \
        'test_the_same_source_in_both_spellings_is_accepted'

    # ---- an absent field stays absent ---------------------------------------------------
    "$m" "37. an absent address field is read as an empty one" "$TOPO" \
        '    for field in sorted(match_dict):
        if field in IN_PORT_MATCH_FIELDS:' \
        '    for field in sorted(set(match_dict) | {"nw_dst"}):
        if field in IN_PORT_MATCH_FIELDS:' \
        'test_an_absent_field_is_still_absent'

    # ---- the strict-delete refusal tells the truth about a prefix ------------------------
    "$m" "38. the refusal promises a restore for a prefix" "$API" \
        '    prefix = _names_a_prefix(match)' \
        '    prefix = False' \
        'test_a_prefix_refusal_does_not_promise_a_restore'

    "$m" "39. the refusal denies the restore for a /32" "$API" \
        '    prefix = _names_a_prefix(match)' \
        '    prefix = True' \
        'test_a_slash_32_refusal_still_says_the_route_is_restored'

    "$m" "40. a malformed prefix gets the restore wording" "$API" \
        '        return True  # "10.0.1.0/33" and the like: not a /32 either, and nothing is restored' \
        '        return False' \
        'test_a_prefix_refusal_does_not_promise_a_restore'
}

if [[ "$MODE" == dryrun ]]; then
    echo "DRY RUN -- anchors only. This is NOT a gate result."
    each_mutation dry_one
    echo
    if [[ "$DRY_BAD" -ne 0 ]]; then echo "🔴 $DRY_BAD anchor(s) not unique."; exit 1; fi
    echo "✅ all anchors unique."; exit 0
fi

echo "=== baseline (must be green before any mutation) ==="
BASE=$(red_proxy)
if [[ -n "$BASE" ]]; then
    echo "REFUSE: baseline is red -- [$BASE]. Nothing this gate reports would mean anything." >&2
    exit 2
fi
echo "  ✅ green"

each_mutation mutate

# Every test in the new file must have gone red under at least one mutation here, or have a
# recorded red against the pre-change code; the list is printed, not judged, because the second
# half of that record lives outside this script.
echo
echo "=== new tests never reddened by this gate ==="
NEVER=0
for t in $(cd p4_proxy/tests && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. "$PROXY_PY" -c '
import unittest, test_cidr_destination as m
s = unittest.defaultTestLoader.loadTestsFromModule(m)
def walk(x):
    for y in x:
        if isinstance(y, unittest.TestSuite): yield from walk(y)
        else: yield y._testMethodName
print(" ".join(sorted(set(walk(s)))))'); do
    if [[ "$REDDENED" != *" $t "* ]]; then echo "  - $t"; NEVER=$((NEVER + 1)); fi
done
[[ $NEVER -eq 0 ]] && echo "  (none)"

echo
echo "=== baseline restored? ==="
BAD=0
for f in "${FILES[@]}"; do
    if cmp -s "$f" "$(snap "$f")"; then echo "  ✅ $f byte-identical"
    else echo "  🔴 $f DIFFERS from its snapshot"; BAD=1; fi
done
echo
echo "$MUTATIONS mutations, $SURVIVORS survived"
[[ $BAD -ne 0 ]] && exit 2
[[ $SURVIVORS -ne 0 ]] && exit 1
exit 0
