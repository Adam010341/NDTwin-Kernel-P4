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
FILES=("$API")

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
red_proxy() {
    local out rc
    clear_pyc
    out=$(cd p4_proxy/tests && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. \
              "$PROXY_PY" test_flowentry_endpoints.py 2>&1); rc=$?
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
    "$m" "3. the modify is refused only after the switch has been written" "$API" \
        '    _refuse_unhonourable_priority(data, match, "modify")

' \
        '' \
        'test_a_modify_naming_a_priority_ipv4_lpm_cannot_honour_is_501'

    # ---- half two: the refusal must NOT fire -----------------------------------------
    # Every one of these makes the code refuse MORE. A one-sided gate passes them all.

    # An absent priority becomes a named one, so the kernel's own priority-less delete --
    # every delete the control plane and the IntentTranslator make -- starts answering 501.
    "$m" "4. an absent priority counts as a named one, so the control plane's deletes 501" "$API" \
        '    raw = data.get("priority")
    if raw is None:
        return None' \
        '    raw = data.get("priority")
    if raw is None:
        return 1' \
        'test_the_kernels_own_priority_less_delete_still_works'

    # 0 and -1 stop being sentinels. makeModifyJob defaults an ABSENT priority to 0, so this
    # refuses the entire modify path, and -1 is the non-strict delete sentinel.
    "$m" "5. 0 and -1 stop being the absent-priority sentinels" "$API" \
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
