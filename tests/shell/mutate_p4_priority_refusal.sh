#!/usr/bin/env bash
#
# Mutation gate for the P4 priority refusal: a delete or modify naming a priority the
# destination table cannot honour must stop being answered as success.
#
# [Co-developed with claude code -- Adam]
# Written to match tests/shell/mutate_a7_dispatch_status.sh, including its divergence: every
# way of NOT proving a mutation is caught -- a non-unique anchor, a mutation that will not
# apply, the wrong test going red -- is counted as a SURVIVOR, never skipped. On a shared tree
# the tempting reading of "it did not run" is "it passed".
#
# 🔴 THE TWO-SIDED CLAIM. A refusal that refused everything would satisfy a one-sided gate:
# every "does it fire" mutation would still be caught, and the fabric would be dead. So the
# table below is deliberately half and half --
#
#   fires   : 1, 2, 3   the refusal must trigger for a priority ipv4_lpm cannot honour, and
#                       must trigger BEFORE the switch is touched
#   spares  : 4, 5, 6, 7 it must NOT trigger for the kernel's own priority-less delete, for
#                       makeModifyJob's absent-priority 0, for the -1 non-strict sentinel, or
#                       for a five-tuple match where the priority IS the entry's identity
#
# -- and mutations 4..7 are widenings, i.e. code that refuses MORE. A gate with only the first
# three would pass every one of them.
#
# [Co-developed with claude code -- Adam] Adam, 2026-10-16: a destination-only modify naming the
# priority its ipv4_lpm slot holds is honoured (slot_priority.py). Mutation 3 used to remove the
# modify's refusal from the handler; that refusal now lives in TopologyManager.modify_flow,
# under the slot's lock, so 3 is re-anchored there (the check moved after the write). 4 and 5
# follow `named_priority` into slot_priority.py, and 8 and 9 follow the 501 body into
# `_priority_refusal_detail`. Mutations 10.. are the ruling's own rules, two-sided again:
# honoured where the slot holds the named priority (13, 15, 17, 27), refused everywhere else
# (10, 11, 12, 14, 16, 26, 30, 31), forgotten after anything unconfirmed (18, 21, 22, 23, 24,
# 28, 29), atomic per slot and per slot only (19, 25), and in the stated order behind the
# switch's own refusals with a remedy true on OVS as well (20, 32, 33).
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any
# exit, byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD.
#
# Usage:
#   tests/shell/mutate_p4_priority_refusal.sh            the gate
#   tests/shell/mutate_p4_priority_refusal.sh --dry-run  anchors only, NOT a gate result
#
# No build lane and no build: the change is entirely in the proxy, because only the proxy knows
# which table a match compiles to (needs_five_tuple). See DECISION-P4-PRIORITY.md for why the
# refusal was not duplicated into the kernel.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only).
set -uo pipefail

API=p4_proxy/proxy_agent/api_routes.py
TOPO=p4_proxy/proxy_agent/topology_manager.py
SLOT=p4_proxy/proxy_agent/slot_priority.py
CLIENT=p4_proxy/proxy_agent/p4_client.py
FILES=("$API" "$TOPO" "$SLOT" "$CLIENT")
#: [Co-developed with claude code -- Adam] The two suites every mutation is judged by.
TEST_FILES=(test_flowentry_endpoints.py test_modify_at_slot_priority.py)

PROXY_PY="${PROXY_PY:-/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python3}"

MODE=full
case "${1:-}" in
    --dry-run) MODE=dryrun ;;
    "")        ;;
    *) echo "REFUSE: unknown argument '$1'. Use --dry-run." >&2; exit 2 ;;
esac

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
if [[ "$MODE" != dryrun ]]; then
    [[ -x "$PROXY_PY" ]] || {
        echo "REFUSE: proxy interpreter $PROXY_PY not found. Set PROXY_PY." >&2; exit 2; }
fi

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
# [Co-developed with claude code -- Adam] Over TEST_FILES. A file that exits nonzero with no
# FAIL/ERROR line (an import crash) reports CRASHED:<file>, which no expected name matches, so it
# can only ever count as a survivor.
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

    # ---- half one: the refusal must FIRE ---------------------------------------------

    # THE ORIGINAL DEFECT, reintroduced at the one line that now stops it: the refusal
    # becomes a no-op and a delete at 999 goes through against whatever entry is there.
    "$m" "1. the refusal never fires, as before the fix" "$API" \
        '    priority = _named_priority(data)
    if priority is None or needs_five_tuple(match):
        return' \
        '    priority = _named_priority(data)
    if True:
        return' \
        'test_a_delete_naming_a_priority_ipv4_lpm_cannot_honour_is_501'

    # Refused, but only after the entry is already gone -- the same defect wearing a status
    # code. Caught only by the test that asserts the topology was never called.
    "$m" "2. the delete is refused only after the switch has been written" "$API" \
        '    _refuse_unhonourable_priority(data, match, "delete")

    try:
        success = await run_in_threadpool(topology.unroute_flow, dpid, match,' \
        '    try:
        success = await run_in_threadpool(topology.unroute_flow, dpid, match,' \
        'test_the_refused_write_never_reaches_the_switch'

    # Same for the modify verb. Separate mutation because the two handlers each carry their
    # own call: removing one leaves the other, and a gate that tested only delete would
    # report the modify half as covered.
    # Re-anchored 2026-10-16: the modify's check is now in modify_flow, and this moves it
    # after the write -- the refusal still answers 501, and the slot was already edited.
    "$m" "3. the modify is refused only after the switch has been written" "$TOPO" \
        '                held = slots.held(dpid, ipv4_dst, client)
                if held != named:
                    raise SlotPriorityNotHeld(dpid, ipv4_dst, named, held)
            success = self._write_slot(
                dpid, ipv4_dst, client,
                lambda: client.modify_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port),
                slot_priority.KEEP)' \
        '                held = slots.held(dpid, ipv4_dst, client)
            success = self._write_slot(
                dpid, ipv4_dst, client,
                lambda: client.modify_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port),
                slot_priority.KEEP)
            if named is not None and held != named:
                raise SlotPriorityNotHeld(dpid, ipv4_dst, named, held)' \
        'test_the_refused_write_never_reaches_the_switch'

    # ---- half two: the refusal must NOT fire -----------------------------------------
    # Every one of these makes the code refuse MORE. A one-sided gate passes them all.

    # An absent priority becomes a named one, so the kernel's own priority-less delete --
    # every delete the control plane and the IntentTranslator make -- starts answering 501.
    "$m" "4. an absent priority counts as a named one, so the control plane's deletes 501" "$SLOT" \
        '    if raw is None:
        return None' \
        '    if raw is None:
        return 1' \
        'test_the_kernels_own_priority_less_delete_still_works'

    # 0 and -1 stop being sentinels. makeModifyJob defaults an ABSENT priority to 0, so this
    # refuses the entire modify path, and -1 is the non-strict delete sentinel.
    "$m" "5. 0 and -1 stop being the absent-priority sentinels" "$SLOT" \
        '    return priority if priority > 0 else None' \
        '    return priority' \
        'test_the_kernels_own_modify_at_the_absent_priority_default_still_works'

    # The table check is dropped, so a five-tuple match -- where the priority IS the entry's
    # identity and IS programmed -- is refused too. The refusal would then be about the verb
    # rather than about what the plane can honour, which is a different (and wrong) claim.
    "$m" "6. the table is not consulted, so honourable priorities are refused too" "$API" \
        '    if priority is None or needs_five_tuple(match):' \
        '    if priority is None:' \
        'test_a_five_tuple_match_at_the_same_priority_is_not_refused'

    # The refusal is widened to the install path, overturning T-15 Option 0 and the
    # 2026-08-30 §1.2 ruling silently. That is the owner's decision, not a maintenance edit,
    # so a test names the ruling and reddens when someone takes it.
    "$m" "7. the refusal is widened to the install path, overturning the standing ruling" "$API" \
        '    # 400 with the offending field names, rather than servicing a narrowed version of the rule' \
        '    _refuse_unhonourable_priority(data, match, "install")
    # 400 with the offending field names, rather than servicing a narrowed version of the rule' \
        'test_an_install_is_still_disclosed_rather_than_refused'

    # ---- half three: the refusal has to be READABLE where it is read ------------------
    # 🔴 2026-09-11, hunt-0911/ROLE-5-TRAFFIC-REPORT.md §S3. On a live fabric 2152 of 2152
    # deletes were refused here and every caller got HTTP 200 `queued`, because the kernel
    # answers before the southbound request is made. The single place the refusal surfaces is
    # get_flow_dispatch_status' recent_failures[].message, and what lands there is
    # briefly(body, 200) -- HttpRoutingStrategyBase.cpp:62-79. The captured record cut
    # mid-word at "data plan", 640 bytes short of what to do instead.

    # The field is gone: the body still explains the refusal, in prose that stops at byte 200.
    "$m" "8. the remedy field is dropped, so the window carries only the diagnosis" "$API" \
        '        **extra,
        "remedy": remedy,
' \
        '        **extra,
' \
        'test_the_remedy_is_inside_the_window_the_kernel_keeps'

    # 🔴 The sharper one, and the reason the test measures BYTES rather than asserting the key
    # exists. The field is still there and every reader of the proxy's own response sees it --
    # but an `error` string grown to be more helpful pushes it past the kernel's cut, and the
    # failure record goes back to carrying the diagnosis and nothing actionable. Nothing about
    # this edit looks like a regression.
    "$m" "9. a longer error string pushes the remedy out of the kernel window" "$API" \
        '        "error": "priority not honourable on this table",' \
        '        "error": "priority not honourable on this table, because ipv4_lpm is a longest-prefix-match table whose only tiebreak is the prefix length and which has no priority column at all, so the value cannot select an entry",' \
        'test_the_remedy_is_inside_the_window_the_kernel_keeps'

    # ---- half four: the slot's own priority (Adam, 2026-10-16) -------------------------
    # [Co-developed with claude code -- Adam] p4_proxy/tests/test_modify_at_slot_priority.py.

    # Refused everywhere else.
    "$m" "10. any named priority is honoured on a destination-only modify" "$TOPO" \
        '                if held != named:
                    raise SlotPriorityNotHeld(dpid, ipv4_dst, named, held)' \
        '                if False:
                    raise SlotPriorityNotHeld(dpid, ipv4_dst, named, held)' \
        'test_a_modify_at_777_on_the_proxys_own_route_is_still_501'

    "$m" "11. 10 is honoured without asking the slot" "$TOPO" \
        '                if held != named:' \
        '                if held != named and named != CONTROL_PLANE_ROUTE_PRIORITY:' \
        'test_a_modify_at_ten_after_an_install_at_100_is_501'

    "$m" "12. a slot with no record is taken to hold the control plane's route" "$TOPO" \
        '                held = slots.held(dpid, ipv4_dst, client)
                if held != named:' \
        '                held = slots.held(dpid, ipv4_dst, client)
                if held is None:
                    held = CONTROL_PLANE_ROUTE_PRIORITY
                if held != named:' \
        'test_a_slot_with_no_record_is_501'

    # Honoured where the slot holds it.
    "$m" "13. the refill does not record the control plane's priority" "$TOPO" \
        'lambda: client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port),
                        CONTROL_PLANE_ROUTE_PRIORITY)' \
        'lambda: client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port),
                        None)' \
        'test_a_modify_at_ten_on_the_proxys_own_route_is_honoured'

    "$m" "14. an install records 10 instead of the priority it asked for" "$TOPO" \
        '                slot_priority.install_priority(priority))' \
        '                CONTROL_PLANE_ROUTE_PRIORITY)' \
        'test_a_modify_at_ten_after_an_install_at_100_is_501'

    "$m" "15. the A-4d restore does not record the control plane's priority" "$TOPO" \
        'lambda: client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, restore_port),
                    CONTROL_PLANE_ROUTE_PRIORITY)' \
        'lambda: client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, restore_port),
                    None)' \
        'test_a_modify_at_ten_after_the_restore_is_honoured_again'

    "$m" "16. a removal keeps the removed entry's priority" "$TOPO" \
        'lambda: client.delete_ipv4_route(ipv4_dst, 32), None)' \
        'lambda: client.delete_ipv4_route(ipv4_dst, 32), slot_priority.KEEP)' \
        'test_a_removed_slot_has_no_record'

    "$m" "17. an honoured modify forgets the slot's priority" "$TOPO" \
        '                slot_priority.KEEP)' \
        '                None)' \
        'test_the_honoured_modify_keeps_the_slot_at_its_priority'

    # Forgotten after anything unconfirmed.
    "$m" "18. a write that raises keeps the old record" "$TOPO" \
        '        try:
            accepted = bool(write())
        finally:
            slots.settle(dpid, ipv4_dst, client, begun, accepted, after)' \
        '        accepted = bool(write())
        slots.settle(dpid, ipv4_dst, client, begun, accepted, after)' \
        'test_a_write_that_raises_forgets_the_slot'

    # Atomic per slot.
    "$m" "19. the modify checks and writes without the slot's lock" "$TOPO" \
        '        with slots.lock(dpid, ipv4_dst):
            if named is not None:' \
        '        with threading.Lock():
            if named is not None:' \
        'test_an_install_cannot_land_between_a_modifys_check_and_its_write'

    # Order: the switch's own refusals first.
    "$m" "20. the slot check runs ahead of the read-only and binding refusals" "$TOPO" \
        '                check = getattr(client, "check_route_write", None)
                if check is not None:
                    check("an ipv4_lpm route modify")
                held = slots.held(dpid, ipv4_dst, client)
                if held != named:
                    raise SlotPriorityNotHeld(dpid, ipv4_dst, named, held)' \
        '                held = slots.held(dpid, ipv4_dst, client)
                if held != named:
                    raise SlotPriorityNotHeld(dpid, ipv4_dst, named, held)
                check = getattr(client, "check_route_write", None)
                if check is not None:
                    check("an ipv4_lpm route modify")' \
        'test_a_modify_at_ten_on_a_read_only_switch_is_409'

    "$m" "21. a refused or failed write keeps the record" "$SLOT" \
        '            if not accepted or after is None or _push_epoch(client) != begun:' \
        '            if after is None or _push_epoch(client) != begun:' \
        'test_a_failed_modify_forgets_the_slot'

    "$m" "22. a write that overlapped a pipeline push is recorded" "$SLOT" \
        '            if not accepted or after is None or _push_epoch(client) != begun:' \
        '            if not accepted or after is None:' \
        'test_a_write_that_overlaps_a_push_is_not_recorded'

    "$m" "23. a record outlives a pipeline push" "$SLOT" \
        '        return ref() is client and epoch == _push_epoch(client)' \
        '        return ref() is client' \
        'test_a_push_on_one_switch_forgets_its_slots_and_no_other'

    "$m" "24. a record outlives the client it was written through (readopt)" "$SLOT" \
        '        return ref() is client and epoch == _push_epoch(client)' \
        '        return epoch == _push_epoch(client)' \
        'test_a_replaced_client_does_not_inherit_the_old_ones_records'

    "$m" "25. one lock for every slot" "$SLOT" \
        '        key = (dpid, ipv4_dst)
        with self._guard:
            lock = self._locks.get(key)' \
        '        key = None
        with self._guard:
            lock = self._locks.get(key)' \
        'test_another_slot_is_not_held_up'

    "$m" "26. an install with no priority is recorded as a priority-10 entry" "$SLOT" \
        '    if raw is None:
        return 0' \
        '    if raw is None:
        return 10' \
        'test_an_install_with_no_priority_is_not_a_priority_ten_entry'

    "$m" "27. the control plane's priority drifts from the OVS router's" "$SLOT" \
        'CONTROL_PLANE_ROUTE_PRIORITY = 10' \
        'CONTROL_PLANE_ROUTE_PRIORITY = 11' \
        'test_the_control_plane_priority_is_the_ovs_routers'

    "$m" "28. the push epoch moves only after a push that returned" "$CLIENT" \
        '        self.pipeline_push_epoch += 1
        try:
            self.stub.SetForwardingPipelineConfig(req, timeout=RPC_TIMEOUT_S)
        finally:
            self.pipeline_push_epoch += 1' \
        '        self.stub.SetForwardingPipelineConfig(req, timeout=RPC_TIMEOUT_S)
        self.pipeline_push_epoch += 2' \
        'test_a_push_moves_the_epoch_on_both_sides_of_the_rpc'

    "$m" "29. a push that times out does not move the epoch after it" "$CLIENT" \
        '        try:
            self.stub.SetForwardingPipelineConfig(req, timeout=RPC_TIMEOUT_S)
        finally:
            self.pipeline_push_epoch += 1' \
        '        self.stub.SetForwardingPipelineConfig(req, timeout=RPC_TIMEOUT_S)
        self.pipeline_push_epoch += 1' \
        'test_a_push_that_times_out_still_moves_it'

    "$m" "30. a strict delete at the control plane's priority is honoured" "$API" \
        '    if priority is None or needs_five_tuple(match):
        return
    raise HTTPException(' \
        '    if priority is None or needs_five_tuple(match) or priority == CONTROL_PLANE_ROUTE_PRIORITY:
        return
    raise HTTPException(' \
        'test_a_strict_delete_at_ten_is_still_501'

    "$m" "31. the handler does not answer SlotPriorityNotHeld as a 501" "$API" \
        '    except SlotPriorityNotHeld as err:
        # [Co-developed with claude code -- Adam] Adam, 2026-10-16.
        raise _slot_priority_not_held(err)
' \
        '' \
        'test_a_modify_naming_a_priority_ipv4_lpm_cannot_honour_is_501'

    "$m" "32. the modify remedy goes back to the P4-only advice" "$API" \
        '        remedy = ("match the full five-tuple, or name slot_priority: the priority this "' \
        '        remedy = ("omit priority, or match the full five-tuple; "' \
        'test_neither_verb_advises_omitting_the_priority'

    "$m" "33. the machine fields move behind the prose, out of the kernel window" "$API" \
        '        "requested_priority": priority,
        **extra,
        "remedy": remedy,
        "table": "ipv4_lpm",
        "message": message,' \
        '        "remedy": remedy,
        "table": "ipv4_lpm",
        "message": message,
        "requested_priority": priority,
        **extra,' \
        'test_the_modify_501_keeps_its_machine_fields_inside_the_kernel_window'
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
