#!/usr/bin/env bash
#
# Mutation gate for tests/test_OpenflowCapacityReport.cpp -- both its unit cases and the two
# CapacityEndpointTest wiring cases at the bottom of the same file (W17).
#
# [Co-developed with claude code -- Adam]
#
# W17's claim is narrow and easy to fake: `get_openflow_capacity` reports the ceiling of the
# pipeline THE RUNNING SWITCH LOADED. A single `= 1024;` anywhere below satisfies every
# eyeball test on this fabric today -- 1024 is the right answer for the artifact in this
# repository -- and stops being right the moment `size = 1024;` in ndtwin_switch.p4 moves. So the
# mutations below are aimed at the four ways a read can quietly become a constant:
#
#   * the number itself is a literal                       -> M1, M2
#   * the read looks right but hits the wrong key/table    -> M3
#   * the read is attempted and a literal catches the fall -> M4
#   * the read happens and nothing calls it                -> M12
#
# and at the two claims that share the response with it:
#
#   * unknown occupancy is reported as unknown, not 0      -> M5
#   * the artifact comes from the process table            -> M6, M7, M8
#
# 🔴 Anything that stops the tests RUNNING counts as SURVIVED, never as a warning: an anchor that
# no longer matches, a mutation that will not apply, a mutant that does not compile. In all three
# the behaviour is exactly as unproven as if the suite had stayed green.
#
# The four WIDENINGS at the end must stay GREEN. A gate made only of deletions proves the tests
# notice absence; the widenings are what stop the assertions from being pinned to a spelling.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD, so this runs
# against an uncommitted fix. Restore is `cp -p` then `touch`, because cp -p puts the ORIGINAL
# mtime back -- older than the object built from the mutant -- and ninja would then decide there
# was nothing to do and score the next mutation against the previous mutant's binary.
#
# Usage:  LOCK_WAIT=10800 JOBS=1 tools/build_guard/guarded_build.sh \
#             ./tests/shell/mutate_capacity_reads_running_artifact.sh
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
#          Run it under the build guard: this laptop's systemd-oomd killed the user's own
#          application during an unguarded build on 2026-09-02.
# Exit:    0 all mutations caught and all widenings green
#          1 a mutation survived -- including one that failed to build or whose anchor moved
#          2 refused (baseline red, tree unbuildable, or a source not restored byte-identically)
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
# 🔴 The suite name matters: the first run of this gate filtered on `HttpSessionCapacityTest.*`,
# which matches NOTHING -- the endpoint cases are `CapacityEndpointTest`. The gate was green on a
# baseline that never ran the two tests M12 exists to check, and M12 could not have been caught
# whatever the code did. A filter that matches nothing is a filter that proves nothing.
FILTER='OpenflowCapacity*:CapacityEndpointTest.*'

REPORT=src/ndt_core/http/OpenflowCapacityReport.cpp
SESSION=src/ndt_core/http/HttpSession.cpp
FILES=("$REPORT" "$SESSION")

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2; exit 2; }

BK=$(mktemp -d)
snap() { echo "$BK/$(echo "$1" | tr '/' '_')"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
WIDENINGS=0
WIDENINGS_RED=0

# anchor_count <file> <literal>. python, not `grep -c -F`: grep splits a multi-line -F pattern
# into several patterns and counts matching LINES, so a multi-line anchor would report >1 and be
# rejected as "not unique".
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

apply_anchor() {
    ANCHOR="$2" REPL="$3" python3 - "$1" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

red_tests() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <file> <old> <new> <expected-test>
mutate() {
    local label="$1" file="$2" old="$3" new="$4" expected="$5"
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! apply_anchor "$file" "$old" "$new"; then
        echo "  🔴 mutation could not be applied. NOT a pass. SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 MUTANT DOES NOT COMPILE -- the test never ran, so this counts as SURVIVED."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | grep -E 'error|Error' | head -5 |
            sed 's/^/       /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    local failed; failed=$(red_tests)
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

# widen <label> <file> <old> <new> <why-behaviour-is-preserved>
widen() {
    local label="$1" file="$2" old="$3" new="$4" why="$5"
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== WIDENING: %s ===\n' "$label"
    printf '  %s\n' "$why"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    WIDENINGS=$((WIDENINGS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this widening proves nothing. Counted red."
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi
    apply_anchor "$file" "$old" "$new"
    if ! build; then
        echo "  🔴 WIDENING DOES NOT COMPILE -- counted red; a rewrite this suite forbids at"
        echo "     compile time is as pinned as one it forbids at run time."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | grep -E 'error|Error' | head -5 |
            sed 's/^/       /'
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi
    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  ✅ stayed green, as it must"
    else
        printf '  🔴 WENT RED: %s\n' "$failed"
        echo "     The suite is pinned to the spelling, not to the behaviour."
        WIDENINGS_RED=$((WIDENINGS_RED + 1))
    fi
    restore
}

echo "W17 mutation gate -- get_openflow_capacity reports the pipeline the running switch loaded"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET"
echo "  filter    : $FILTER"
for f in "${FILES[@]}"; do printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"; done
echo
echo "baseline (unmutated) must build and be green:"
if ! build; then
    echo "  REFUSE: the unmutated tree does not build. Nothing below would mean anything."
    cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    exit 2
fi
"$BIN" --gtest_filter="$FILTER" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

# --- killing mutations -----------------------------------------------------------------------

# 1. THE DEFECT, in its narrowest form: the ceiling is known rather than read. 1024 is the RIGHT
#    answer for the artifact in this repository, which is exactly why a test written against 1024
#    would have missed this.
mutate "1. the plane's ceiling is a constant" \
    "$REPORT" \
    '    plane["max_entries"] = haveMax ? nlohmann::json(flowTable->second) : nlohmann::json(nullptr);' \
    '    plane["max_entries"] = 1024;' \
    'OpenflowCapacityTest.TheCeilingIsWhateverTheRunningPipelineSays'

# 2. The same constant one level down. A fix applied to the headline number and not to the
#    per-switch rows would leave the two disagreeing, and the per-switch rows are what a planner
#    actually reads.
mutate "2. the per-switch ceiling is a constant" \
    "$REPORT" \
    '        one["max_entries"] = haveMax ? nlohmann::json(flowTable->second) : nlohmann::json(nullptr);' \
    '        one["max_entries"] = 1024;' \
    'OpenflowCapacityTest.TheCeilingIsWhateverTheRunningPipelineSays'

# 3. The read that looks right and is not: bmv2 artifacts have no `size` key, so this reads
#    nothing while every line of the code still says it is reading the artifact.
mutate "3. the artifact is read under the wrong key" \
    "$REPORT" \
    '!table.contains("max_size") || !table.at("max_size").is_number_integer()' \
    '!table.contains("size") || !table.at("size").is_number_integer()' \
    'OpenflowCapacityTest.TheCeilingIsWhateverTheRunningPipelineSays'

# 4. "Read it, and if that fails use 1024." The tempting shape, and the one that turns an
#    unreadable pipeline into a confident wrong answer -- which is what the vendor catalogue was.
mutate "4. an unreadable artifact falls back to a literal" \
    "$REPORT" \
    '    std::map<std::string, long long> sizes;' \
    '    std::map<std::string, long long> sizes{{kFlowEntryTable, 1024}};' \
    'OpenflowCapacityTest.AnUnreadableArtifactRefusesToGuess'

# 5. Unknown occupancy reported as an empty table. "All 512 free" about a switch this kernel has
#    never polled is a different sentence from "I do not know", and only one of them is true.
# Written as "report zero" rather than "take the else branch": inverting the condition would
# dereference rows.end(), and a mutant that crashes produces no [ FAILED ] line at all, which this
# gate would then have to score as a survivor. A mutation has to be wrong, not undefined.
mutate "5. a switch nothing has polled is reported as empty" \
    "$REPORT" \
    '            one["in_use"] = nullptr;
            one["available"] = nullptr;' \
    '            one["in_use"] = 0;
            one["available"] =
                haveMax ? nlohmann::json(flowTable->second) : nlohmann::json(nullptr);' \
    'OpenflowCapacityTest.ASwitchNothingHasPolledYetIsUnknownNotEmpty'

# 6. The provenance, removed: stop walking the process table and answer with the build artifact
#    every time. Same number on this laptop today; a different claim, and wrong the moment a
#    switch is running something else.
mutate "6. the running switch's argv is ignored" \
    "$REPORT" \
    '        for (std::filesystem::directory_iterator it(procRoot, ec), last; it != last; ++it)' \
    '        for (std::filesystem::directory_iterator it, last; it != last; ++it)' \
    'OpenflowCapacityProcTest.TheArtifactIsTheOneARunningSwitchHasLoaded'

# 7. Any process that names a pipeline JSON is taken for a switch. The P4 proxy agent and p4c both
#    carry that path on their command lines, so this reports a pipeline nothing is running.
mutate "7. anything naming the artifact is taken for a switch" \
    "$REPORT" \
    '    return base.rfind("simple_switch", 0) == 0;' \
    '    return !base.empty();' \
    'OpenflowCapacityArgvTest.AProcessThatMerelyNamesTheArtifactIsNotASwitch'

# 8. The FIRST .json on the command line instead of the last. bmv2's own argv ends
#    `<pipeline>.json -- --grpc-server-addr ...`, and any --log-file or --p4info in front of it
#    would then be reported as the pipeline.
mutate "8. the first .json on the command line wins" \
    "$REPORT" \
    '    for (auto it = argv.rbegin(); it != argv.rend(); ++it)' \
    '    for (auto it = argv.begin(); it != argv.end(); ++it)' \
    'OpenflowCapacityArgvTest.TheLastJsonWinsWhenAnOptionValueIsAlsoAJsonFile'

# 9. The catalogue stops saying it is a catalogue. Three numbers nobody measured here, served
#    beside three that were measured, with nothing to tell them apart -- the flat surface this
#    whole change exists to break up.
mutate "9. the vendor rows stop declaring their provenance" \
    "$REPORT" \
    '            brand.value()["source"] = "vendor table";' \
    '            brand.value()["source_note_removed"] = true;' \
    'OpenflowCapacityReportTest.TheVendorRowsSayTheyAreACatalogueAndKeepTheirNumbers'

# 10. A bmv2 block on a fabric with no bmv2 switches: an empty per_switch list and a ceiling for a
#     plane that is not there, which reads as "you have 512 free" on an OVS deployment.
mutate "10. the bmv2 plane is described on a fabric that has none" \
    "$REPORT" \
    '    if (!bmv2Dpids.empty())
    {
        vendorCatalogue["bmv2"] = buildBmv2Plane(bmv2Dpids, src, artifact, rowsPerDpid(tableView));
    }' \
    '    vendorCatalogue["bmv2"] = buildBmv2Plane(bmv2Dpids, src, artifact, rowsPerDpid(tableView));' \
    'OpenflowCapacityReportTest.TheBmv2BlockAppearsOnlyWhenTheTopologyHasBmv2Switches'

# 11. The artifact is located and then not read. Every provenance string in the response stays
#     truthful and every number goes null -- "we know where it is" is not "we read it".
mutate "11. the located artifact is never opened" \
    "$REPORT" \
    '                    in >> artifact;' \
    '                    (void)in;' \
    'OpenflowCapacityReadTest.TheReportIsAssembledFromTheFilesTheSourcesNameAndNoOthers'

# 12. THE WIRING. Everything above is correct and the handler serves the old file verbatim again
#     -- decided correctly, connected to nothing, which is the shape this repository has paid for
#     more than once. This is the one mutation that rebuilds HttpSession.cpp; it is worth it.
mutate "12. the handler goes back to dumping the catalogue file" \
    "$SESSION" \
    '    const json report =
        ofcapacity::readCapacityReport(m_capacitySources, bmv2Dpids, tableView, &outcome);' \
    '    json report;
    {
        std::ifstream verbatim(m_capacitySources.vendorCataloguePath);
        outcome.vendorCatalogueRead = static_cast<bool>(verbatim);
        verbatim >> report;
    }' \
    'CapacityEndpointTest'

# --- widenings: behaviour-preserving, must stay green ------------------------------------------

# W1. The ceiling through a named local. If this reddens, something is reading the source text.
widen "W1. the ceiling named before it is served" \
    "$REPORT" \
    '    plane["max_entries"] = haveMax ? nlohmann::json(flowTable->second) : nlohmann::json(nullptr);' \
    '    const nlohmann::json ceiling =
        haveMax ? nlohmann::json(flowTable->second) : nlohmann::json(nullptr);
    plane["max_entries"] = ceiling;' \
    "same value, one indirection out -- nothing about the behaviour changes"

# W2. The prefix test spelled with find() instead of rfind(..., 0). Identical predicate.
widen "W2. the argv0 prefix test spelled the other way" \
    "$REPORT" \
    '    return base.rfind("simple_switch", 0) == 0;' \
    '    return base.compare(0, 13, "simple_switch") == 0;' \
    "both are 'the basename starts with simple_switch'"

# W3. The note reworded. The assertions must own the numbers and the provenance, never the prose.
widen "W3. the response note reworded" \
    "$REPORT" \
    '        "max_entries is the compiled pipeline'"'"'s own max_size for " + std::string(kFlowEntryTable) +' \
    '        "W17: max_entries is the compiled pipeline'"'"'s own max_size for " + std::string(kFlowEntryTable) +' \
    "a message may be improved without breaking a test"

# W4. The two plane keys written in the other order. Both are plain assignments into a json
#     object, whose serialisation order this suite must not depend on.
widen "W4. the plane's first two keys assigned in the other order" \
    "$REPORT" \
    '    plane["plane"] = "bmv2";
    plane["flow_entry_table"] = kFlowEntryTable;' \
    '    plane["flow_entry_table"] = kFlowEntryTable;
    plane["plane"] = "bmv2";' \
    "two independent assignments; nothing reads them in order"

# --- restore and verify -------------------------------------------------------------------------

restore
echo
echo "restoring and rebuilding the pristine tree:"
if ! build; then
    echo "  REFUSE: the restored tree does not build. The working tree may be damaged."
    exit 2
fi
DIRTY=0
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "  🔴 NOT RESTORED: $f differs from its pre-run snapshot."
        DIRTY=1
    fi
done
[[ $DIRTY -eq 0 ]] && echo "  ok       all ${#FILES[@]} sources byte-identical to the pre-run snapshot"
FINAL_RED=$(red_tests)
if [[ -n "$FINAL_RED" ]]; then
    echo "  🔴 the restored tree is RED: $FINAL_RED"
    DIRTY=1
fi

echo
echo "================================================================"
printf 'mutations : %d\n' "$MUTATIONS"
printf 'survivors : %d\n' "$SURVIVORS"
printf 'widenings : %d green of %d\n' "$((WIDENINGS - WIDENINGS_RED))" "$WIDENINGS"
echo "================================================================"

[[ $DIRTY -ne 0 ]] && exit 2
[[ $SURVIVORS -eq 0 && $WIDENINGS_RED -eq 0 ]] || exit 1
echo "all mutations caught, all widenings green"
exit 0
