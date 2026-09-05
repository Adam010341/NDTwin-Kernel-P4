#!/usr/bin/env bash
#
# Mutation gate for OV-1 in tests/test_NicknameDoesNotRewriteTheFile.cpp:
# a rename changes the field it was asked to change, and nothing else.
#
# [Co-developed with claude code -- Adam]
#
# Measured 2026-09-04: one POST /ndt/modify_nickname rewrote all 3998 lines of
# setting/StaticNetworkTopologyMininet_10Switches.json -- a file the repository tracks -- with
# the JSON semantically unchanged, and `ndt status --check` then reported the kernel's own
# rewrite as "the topology file has been edited since the ndt up that loaded it". Repeated the
# same night on the P4 plane against a different file: it follows activeTopologyPath(), so it is
# a property of the writer.
#
# 🔴 Three of the six mutations are the over-reaching fixes, and they are the reason this gate
# exists rather than a single "does it still reorder" check:
#   * M2/M3 delete the persistence. Every byte-level assertion in the suite passes when the file
#     is never written at all -- "the file did not change" is exactly what you get.
#   * M4 deletes the in-memory half instead, which no file-based assertion can see.
#   * M6 always writes a trailing newline. Invisible line by line, and a different sha256 to the
#     check that started this.
# A gate with only M1 would sign off on a kernel that had quietly stopped renaming anything.
#
# 🔴 The twins get a mutation each (M2 nickname, M3 device_name). They share a helper now, but
# they are still two call sites, and one mutation covering both would be satisfied by a suite
# that only ever exercised one of them.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end, tree rebuilt from the restored source. Baseline is the
# WORKING TREE, not HEAD. Every build goes through tools/build_guard/guarded_build.sh with
# JOBS=1 -- so DO NOT wrap this script in guarded_build.sh, it takes that lock itself.
#
# Usage:  bash tests/shell/mutate_nickname_does_not_rewrite_the_file.sh
# Exit:   0 all caught, controls green   1 a survivor or a red control   2 baseline red / anchor moved
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
FILES=("$SRC")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="${BIN:-$BUILD_DIR/bin/$TARGET}"
FILTER="${FILTER:-NicknamePersistenceTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; touch "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
INVALID=0

apply() { ANCHOR="$2" REPL="$3" perl -0777 -i -pe 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"; }

# 🔴 The two write call sites are textually identical, so every anchor that names one of them is
# multi-line and carries something only that one has next to it. The uniqueness assertion is on
# that distinguishing line.
assert_unique() {
    local n
    n=$(grep -c -F -- "$2" "$1")
    if [[ "$n" -ne 1 ]]; then
        printf '  INVALID  anchor matches %s times in %s (want 1): %s\n' "$n" "$1" "$2"
        return 1
    fi
    return 0
}

build() {
    if [[ "${NO_GUARD:-0}" == "1" || ! -x "$GUARD" ]]; then
        cmake --build "$BUILD_DIR" --target "$TARGET" >"$BK/build.log" 2>&1
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" \
            cmake --build "$BUILD_DIR" --target "$TARGET" -j1 >"$BK/build.log" 2>&1
    fi
}

run_suite() { "$BIN" --gtest_filter="$FILTER" >"$BK/run.log" 2>&1; }

echo "OV-1 mutation gate -- a rename changes one field, not the whole file"
printf '  baseline  : %s  sha256 %s\n' "$SRC" "$(sha256sum "$SRC" | cut -c1-16)"
echo "baseline (unmutated) must build and be green:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline build failed (rc=$rc)."; tail -40 "$BK/build.log" | sed 's/^/    /'; exit 2
fi
run_suite; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline is not green (rc=$rc):"; grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'; exit 2
fi
if ! grep -qE '^\[  PASSED  \] [1-9]' "$BK/run.log"; then
    echo "  REFUSE: the filter '$FILTER' ran no tests."; exit 2
fi
printf '  ok       baseline green (%s)\n\n' "$(grep -E '^\[  PASSED  \]' "$BK/run.log" | tail -1)"

mutate_must_die() {   # name, must-fail test, file, anchor, replacement, [uniqueness line]
    local name="$1" must_fail="$2" file="$3" anchor="$4" repl="$5" uniq="${6:-$4}"
    local rc
    MUTATIONS=$((MUTATIONS + 1))
    if ! assert_unique "$file" "$uniq"; then INVALID=$((INVALID + 1)); restore; return; fi
    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-46s (anchor did not apply)\n' "$name"; INVALID=$((INVALID + 1)); restore; return
    fi
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-46s (mutant does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'; INVALID=$((INVALID + 1)); restore; return
    fi
    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $must_fail" "$BK/run.log"; then
        printf '  caught   %-46s (%s went red)\n' "$name" "$must_fail"
    else
        printf '  SURVIVED %-46s (%s stayed green)\n' "$name" "$must_fail"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             also red: /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

mutate_must_live() {   # name, file, anchor, replacement, [uniqueness line]
    local name="$1" file="$2" anchor="$3" repl="$4" uniq="${5:-$3}"
    local rc
    MUTATIONS=$((MUTATIONS + 1))
    if ! assert_unique "$file" "$uniq"; then INVALID=$((INVALID + 1)); restore; return; fi
    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-46s (anchor did not apply)\n' "$name"; INVALID=$((INVALID + 1)); restore; return
    fi
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-46s (control does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'; INVALID=$((INVALID + 1)); restore; return
    fi
    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok       %-46s (control stayed green, as it must)\n' "$name"
    else
        printf '  SURVIVED %-46s (control went RED -- this gate measures the text, not behaviour)\n' "$name"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "mutations:"

# --- M1: OV-1 itself -- the document comes back in dictionary order ----------------------------
# Parsed into the std::map-backed json first, then converted: the sorted order survives the
# conversion, which is precisely what the defect did.
mutate_must_die \
    "M1 the document is re-ordered on the way in" \
    "NicknamePersistenceTest.AModifyNicknameChangesExactlyOneLineOfTheTopologyFile" \
    "$SRC" \
    '    out.json = nlohmann::ordered_json::parse(raw);' \
    '    out.json = nlohmann::ordered_json(nlohmann::json::parse(raw));'

# --- M2/M3: the persistence deleted, one twin at a time ----------------------------------------
mutate_must_die \
    "M2 the nickname is never written to the file" \
    "NicknamePersistenceTest.TheNicknameIsStillWrittenToTheTopologyFile" \
    "$SRC" \
    '        // Safely write the modified JSON data back to the file.
        // [Co-developed with claude code -- Adam]
        writeTopologyFileWithLayout(activeTopologyPath(), doc);' \
    '        // Safely write the modified JSON data back to the file.
        // [Co-developed with claude code -- Adam]
        (void)doc;' \
    '        // Safely write the modified JSON data back to the file.'

mutate_must_die \
    "M3 the device name is never written to the file" \
    "NicknamePersistenceTest.AModifyDeviceNameChangesExactlyOneLineOfTheTopologyFile" \
    "$SRC" \
    '        writeTopologyFileWithLayout(activeTopologyPath(), doc);
    }
}

void
TopologyAndFlowMonitor::setVertexNickname' \
    '        (void)doc;
    }
}

void
TopologyAndFlowMonitor::setVertexNickname' \
    'TopologyAndFlowMonitor::setVertexNickname(Graph::vertex_descriptor v, std::string nickname)'

# --- M4: 🔴 the over-fix -- the in-memory half goes too ----------------------------------------
mutate_must_die \
    "M4 the graph is not updated either" \
    "NicknamePersistenceTest.ANicknameChangeStillReachesTheGraph" \
    "$SRC" \
    '        (*m_graph)[v].nickName = nickname;' \
    '        (void)nickname;'

# --- M5: 🔴 order preserved, layout not -- the half-fix ----------------------------------------
# This is what "just use ordered_json" gets you: 5 of 13 shipped files instead of 9, because the
# 4-space ones are reformatted line by line and their sha256 changes just as much.
mutate_must_die \
    "M5 the indent is assumed rather than read" \
    "NicknamePersistenceTest.EveryShippedTopologyKeepsItsContentThroughARename" \
    "$SRC" \
    '            return static_cast<int>(spaces);' \
    '            return 2;'

# --- M6: 🔴 a trailing newline nobody can see line by line -------------------------------------
mutate_must_die \
    "M6 a trailing newline is always appended" \
    "NicknamePersistenceTest.TheMininetTopologyKeepsItsBytesToo" \
    "$SRC" \
    '        if (doc.endsWithNewline)' \
    '        if (true)'

echo
echo "controls (behaviour-preserving; these must stay GREEN):"

mutate_must_live \
    "C1 the newline test is spelled differently" \
    "$SRC" \
    '    out.endsWithNewline = !raw.empty() && raw.back() == '"'"'\n'"'"';' \
    '    out.endsWithNewline = raw.size() > 0 && raw[raw.size() - 1] == '"'"'\n'"'"';'

mutate_must_live \
    "C2 the comment above the writer is reworded" \
    "$SRC" \
    '/// Writes to a temp file and renames, so a reader never sees a half-written topology.' \
    '/// Temp file plus rename: no reader ever observes a partially written topology.'

echo
ok=1
for f in "${FILES[@]}"; do cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }; done
[[ "$ok" == 1 ]] && echo "baseline restored: $SRC byte-identical to the pre-run snapshot"

echo "rebuilding from the restored source:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  🔴 rebuild after restore failed (rc=$rc)"; tail -20 "$BK/build.log" | sed 's/^/    /'; ok=0
else
    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then echo "  ok       green again from the restored source"
    else echo "  🔴 NOT green after restore (rc=$rc):"; grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'; ok=0; fi
fi

echo
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
if [[ "$INVALID" -gt 0 ]]; then
    printf '%d could not be applied or built -- neither caught nor survived; a human must look\n' "$INVALID"
fi
[[ "$SURVIVORS" -eq 0 && "$INVALID" -eq 0 && "$ok" == 1 ]]
