#!/usr/bin/env bash
#
# Mutation gate for W10 -- the nickname overlay.
#
# [Co-developed with claude code -- Adam]
#
# THE PROPERTY, in three parts, because a gate for one of them signs off on a broken kernel:
#   1. renaming a device does not write the model file. Not "writes one line" -- does not write.
#   2. the name is kept somewhere else, and a fresh load lays it back on. Part 1 alone is
#      satisfied by a kernel that simply stopped saving anything.
#   3. `ndt status --check` names that somewhere-else and does NOT compare it. Parts 1 and 2
#      alone are satisfied by a check that folds the overlay back into its sha256, which puts
#      the operator back where W10 started: red for having named a switch.
#
# MEASURED. 2026-09-04: one POST /ndt/modify_nickname produced a 3998-insertion /
# 3998-deletion diff on a tracked topology file (OV-1). That was fixed down to one line.
# 2026-09-05, live on OVS: one nickname change, a two-line diff, and `ndt status --check` rc=1
# -- "the topology file has been edited since the ndt up that loaded it". Renaming and renaming
# BACK was green, so the file's bytes were the whole of it: while the kernel wrote that file,
# "one line" and "--check green" were not simultaneously reachable.
#
# 🔴 THE OVER-FIXES GET A MUTATION EACH, and they are why this gate is not four lines long:
#   * M2 stops writing the overlay altogether. EVERY byte-level assertion passes -- "the model
#     file did not change" is exactly what a kernel that saves nothing gives you.
#   * M3 stops applying the overlay at load. Every write-side assertion passes; the rename just
#     silently does not outlive the process.
#   * M6 files hosts under their dpid. Every shipped topology gives every host "dpid": 0, so
#     one host rename becomes all four -- and nothing about switches notices.
#   * M9 makes an unreadable overlay refuse the load, which trades a cosmetic file for a fabric.
#
# 🔴 M14 IS HERE BECAUSE A LIVE RUN FOUND WHAT THIS GATE MISSED (2026-09-06 07:15). Every case
# in the suite pointed NDTWIN_NICKNAME_OVERLAY at a temp file, so none of them exercised the
# default path; the two that did ran from the repo root, where the working directory and the
# checkout are the same directory and the bug cannot show. stack.sh starts the kernel in
# build/. The mutation and the case it names both move the working directory somewhere the two
# cannot be confused.
#
# 🔴 THE TWINS GET A MUTATION EACH (M1 nickname, M4 device_name). They are near-duplicates, and
# a single mutation covering both would be answered by a suite that only ever drove one.
#
# 🔴 The `ndt` mutations are written as `m=$(ndt_mutant ...)` followed by a call, and not as one
# nested expression, because that is the shape tests/shell/check_gate_anchors.py can read. Written
# nested, this gate reported ok(12) for fifteen anchors -- the three `ndt` ones were not checked
# and nothing said so, which is finding #28 exactly.
#
# 🔴 TWO SUBJECTS, TWO HARNESSES. The kernel mutations are applied to the WORKING TREE and the
# gtest suite is rebuilt for each one; the `ndt` mutations are applied to a COPY (ndt sources
# ports.sh and sudo_surface.sh from beside itself, so a mutant is a directory) and need no
# build. Every build goes through tools/build_guard/guarded_build.sh with JOBS=1 -- so DO NOT
# wrap this script in guarded_build.sh, it takes that lock itself.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any
# exit, byte-identity asserted at the end, tree rebuilt from the restored source. The baseline
# is the WORKING TREE, not HEAD.
#
# Usage:  bash tests/shell/mutate_nickname_overlay.sh
# Exit:   0 all caught, controls green   1 a survivor or a red control   2 baseline red / anchor moved
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
NDT="$REPO/tools/test_workflow/ndt"
NDT_TEST="$HERE/test_ndt_status_check_baseline.sh"
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
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
INVALID=0

apply() { ANCHOR="$2" REPL="$3" perl -0777 -i -pe 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"; }

# The two setters are textually near-identical, so every anchor that names one of them carries
# the line only that one has, and this asserts the whole anchor occurs exactly once before it is
# applied. A mutation that could land in two places is not the mutation it says it is.
#
# 🔴 Counts the anchor as ONE STRING. `grep -c -F -- "$multi_line_anchor"` does not:
# grep -F reads a pattern containing newlines as SEVERAL patterns and counts lines matching ANY
# of them. Measured on this gate's first full run (2026-09-06): five multi-line anchors came
# back 3, 5, 3, 24 and 3 and were all reported INVALID, so five mutations -- including both
# host-keying ones and the "an unreadable overlay refuses the load" one -- were never applied
# and the gate exited 1 having measured nothing about them. Each of those anchors occurs exactly
# once; tests/shell/check_gate_anchors.py, which counts with Python's str.count() on the exact
# literal, said ok(15) for the same file in the same commit. That disagreement is what exposed
# it. Counting the same way the anchor checker does keeps the two from disagreeing again, and
# means a multi-line anchor no longer needs a hand-picked single-line stand-in.
assert_unique() {
    local n
    n=$(ANCHOR="$2" python3 -c '
import os, sys
print(open(sys.argv[1], encoding="utf-8").read().count(os.environ["ANCHOR"]))' "$1")
    if [[ "$n" != "1" ]]; then
        printf '  INVALID  anchor occurs %s times in %s (want 1): %s\n' "${n:-?}" "$1" "${2%%$'\n'*}"
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

echo "W10 mutation gate -- the model file is read-only and the names live in an overlay"
printf '  baseline  : %s  sha256 %s\n' "$SRC" "$(sha256sum "$SRC" | cut -c1-16)"
printf '  baseline  : %s  sha256 %s\n' "tools/test_workflow/ndt" "${BASE_NDT:0:16}"
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
printf '  ok       gtest baseline green (%s)\n' "$(grep -E '^\[  PASSED  \]' "$BK/run.log" | tail -1)"

# The shell half's baseline, through the same copy-directory harness the mutants use.
ndt_dir() {   # $1 = destination dir -- ndt plus the three files it sources from beside itself
    mkdir -p "$1"
    cp "$NDT" "$1/ndt"; chmod +x "$1/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$1/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$1/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$1/components.env"
}
run_ndt_suite() { NDT_UNDER_TEST="$1/ndt" timeout 900 bash "$NDT_TEST" 2>&1; }
ndt_dir "$BK/ndt-base"
if ! run_ndt_suite "$BK/ndt-base" >"$BK/ndt-base.log" 2>&1; then
    echo "  REFUSE: the ndt baseline is RED -- mutations prove nothing on a red baseline:"
    grep -E '^  FAILED|^Ran ' "$BK/ndt-base.log" | sed 's/^/    /'; exit 2
fi
printf '  ok       ndt baseline green (%s)\n\n' "$(grep -E '^Ran ' "$BK/ndt-base.log" | tail -1)"

mutate_must_die() {   # name, must-fail test, file, anchor, replacement, [uniqueness line]
    local name="$1" must_fail="$2" file="$3" anchor="$4" repl="$5" uniq="${6:-$4}"
    local rc
    MUTATIONS=$((MUTATIONS + 1))
    if ! assert_unique "$file" "$uniq"; then INVALID=$((INVALID + 1)); restore; return; fi
    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-52s (anchor did not apply)\n' "$name"; INVALID=$((INVALID + 1)); restore; return
    fi
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-52s (mutant does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'; INVALID=$((INVALID + 1)); restore; return
    fi
    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $must_fail" "$BK/run.log"; then
        printf '  caught   %-52s (%s went red)\n' "$name" "$must_fail"
    else
        printf '  SURVIVED %-52s (%s stayed green)\n' "$name" "$must_fail"
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
        printf '  INVALID  %-52s (anchor did not apply)\n' "$name"; INVALID=$((INVALID + 1)); restore; return
    fi
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-52s (control does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'; INVALID=$((INVALID + 1)); restore; return
    fi
    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok       %-52s (control stayed green, as it must)\n' "$name"
    else
        printf '  SURVIVED %-52s (control went RED -- this gate measures the text, not behaviour)\n' "$name"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# The `ndt` half. A mutant is a whole directory, never the working tree, so an interrupted run
# cannot leave the repo's ndt mutated.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py
# can read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
ndt_mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"
    ndt_dir "$d"
    if ! python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        # An anchor that did not apply is NOT a mutation that survived and not one
        # that was caught. Returning nothing makes the caller say so.
        echo ""
        return 1
    fi
    echo "$d"
}

ndt_must_die() {   # name, mutant dir, the case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ -z "$2" || ! -x "$2/ndt" ]]; then
        printf '  INVALID  %-52s (anchor did not apply)\n' "$1"; INVALID=$((INVALID + 1)); return
    fi
    out=$(run_ndt_suite "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-52s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-52s (%s stayed green)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

echo "mutations -- the kernel:"

# --- M1: 🔴 the defect itself -- the model file is written again ------------------------------
# The overlay's contents go to the model file instead of the overlay. That is what "the kernel
# writes setting/*.json" is, expressed in the code as it now stands.
mutate_must_die \
    "M1 a nickname is written to the model file again" \
    "NicknamePersistenceTest.AModifyNicknameLeavesTheTopologyFileByteIdentical" \
    "$SRC" \
    '    setOverlayName(overlay, isSwitch, key, kOverlayNicknameKey, nickname);
    writeJsonFileAtomically(overlayPath, overlay);' \
    '    setOverlayName(overlay, isSwitch, key, kOverlayNicknameKey, nickname);
    writeJsonFileAtomically(overlayPath, overlay);
    writeJsonFileAtomically(activeTopologyPath(), overlay);' \
    '    setOverlayName(overlay, isSwitch, key, kOverlayNicknameKey, nickname);'

# --- M2: 🔴 the over-fix -- nothing is persisted at all ---------------------------------------
# Every byte-level assertion in the suite passes for this mutant, because a file that is never
# written is a file that did not change. Only the overlay-side cases see it.
mutate_must_die \
    "M2 nothing is persisted anywhere" \
    "NicknamePersistenceTest.TheNicknameIsWrittenToTheOverlayUnderTheSwitchsDpid" \
    "$SRC" \
    '    setOverlayName(overlay, isSwitch, key, kOverlayNicknameKey, nickname);
    writeJsonFileAtomically(overlayPath, overlay);
}' \
    '    setOverlayName(overlay, isSwitch, key, kOverlayNicknameKey, nickname);
    (void)overlayPath;
}' \
    '    setOverlayName(overlay, isSwitch, key, kOverlayNicknameKey, nickname);'

# --- M3: 🔴 the other over-fix -- written, never applied --------------------------------------
# The write side is intact and every overlay assertion passes; the rename simply does not
# survive the process. This is the mutation that makes "the overlay is applied at load" a
# tested statement rather than a claim in a comment.
mutate_must_die \
    "M3 the overlay is never applied at load" \
    "NicknamePersistenceTest.AFreshLoadPicksTheNicknameBackUp" \
    "$SRC" \
    '    applyNicknameOverlayNoLock();' \
    '    (void)0;'

# --- M4: the device_name twin stops persisting ------------------------------------------------
mutate_must_die \
    "M4 the device name is not persisted" \
    "NicknamePersistenceTest.TheDeviceNameGoesToTheSameEntryAndDoesNotEvictTheNickname" \
    "$SRC" \
    '    setOverlayName(overlay, isSwitch, key, kOverlayDeviceNameKey, name);
    writeJsonFileAtomically(overlayPath, overlay);' \
    '    setOverlayName(overlay, isSwitch, key, kOverlayDeviceNameKey, name);
    (void)overlayPath;' \
    '    setOverlayName(overlay, isSwitch, key, kOverlayDeviceNameKey, name);'

# --- M5: 🔴 the in-memory half goes instead ----------------------------------------------------
# No file-based assertion can see this one.
mutate_must_die \
    "M5 the graph is not updated either" \
    "NicknamePersistenceTest.ANicknameChangeStillReachesTheGraph" \
    "$SRC" \
    '        vp.nickName = nickname;
        isSwitch = vp.vertexType == VertexType::SWITCH;' \
    '        (void)nickname;
        isSwitch = vp.vertexType == VertexType::SWITCH;'

# --- M6: 🔴 hosts filed under their dpid -------------------------------------------------------
# Every host in every shipped topology has "dpid": 0, so this files all four hosts of an ovs4
# fabric under the one key. Nothing about switches changes, which is what makes it dangerous.
mutate_must_die \
    "M6 a host is keyed by dpid on the write side" \
    "NicknamePersistenceTest.AHostIsKeyedByItsMacAndNotByItsDpid" \
    "$SRC" \
    '        vp.nickName = nickname;
        isSwitch = vp.vertexType == VertexType::SWITCH;
        key = isSwitch ? vp.dpid : vp.mac;' \
    '        vp.nickName = nickname;
        isSwitch = vp.vertexType == VertexType::SWITCH;
        key = vp.dpid;'

# --- M7: the reader disagrees with the writer --------------------------------------------------
# Written under the mac, looked up under the dpid. Both halves are individually reasonable and
# the pair is broken -- exactly the failure only a round-trip case can see.
mutate_must_die \
    "M7 the loader looks hosts up by dpid" \
    "NicknamePersistenceTest.AFreshLoadPicksAHostsNicknameBackUpUnderItsMac" \
    "$SRC" \
    '        const std::string key = std::to_string(isSwitch ? vp.dpid : vp.mac);' \
    '        const std::string key = std::to_string(vp.dpid);'

# --- M8: one overlay for every model -----------------------------------------------------------
# dpids 1-10 exist in BOTH the OVS and the P4 topology, so a shared overlay puts OVS nicknames
# onto a bmv2 fabric. That collision has already corrupted a topology file once (see the
# comment above activeTopologyPath()).
mutate_must_die \
    "M8 all models share one overlay" \
    "NicknamePersistenceTest.TheOverlayPathFollowsTheActiveTopology" \
    "$SRC" \
    '    return (root / kNameOverlayDir / (model.stem().string() + ".names.json")).string();' \
    '    return (root / kNameOverlayDir / "names.json").string();'

# --- M14: 🔴 the overlay follows the process's cwd again ----------------------------------------
# THE DEFECT A LIVE RUN FOUND AND THIS GATE DID NOT, 2026-09-06 07:15. stack.sh starts the
# kernel with `cd '$KERNEL_DIR/build' && exec ./bin/ndtwin_kernel`, so a relative overlay
# directory resolves under build/ -- where `ndt status --check` does not look and `rm -rf build`
# reaches. Every case that pointed NDTWIN_NICKNAME_OVERLAY at a temp file stayed green through
# it, which is exactly why the mutation names the one case that changes the working directory.
mutate_must_die \
    "M14 the overlay follows the process's cwd" \
    "NicknamePersistenceTest.TheOverlayIsAnchoredToTheCheckoutNotTheProcessWorkingDirectory" \
    "$SRC" \
    '    const std::filesystem::path model(activeTopologyPath());
    const std::filesystem::path dir = model.parent_path();
    const std::filesystem::path root =
        dir.filename() == kShippedTopologyDirName ? dir.parent_path() : dir;
    return (root / kNameOverlayDir / (model.stem().string() + ".names.json")).string();' \
    '    const std::filesystem::path model(activeTopologyPath());
    return (std::filesystem::path(kNameOverlayDir) / (model.stem().string() + ".names.json"))
        .string();'

# --- M9: the overlay moves back inside setting/ -------------------------------------------------
# Which is the directory `ndt status --check` hashes. The whole decision, undone by one string.
mutate_must_die \
    "M9 the overlay is inside setting/" \
    "NicknamePersistenceTest.TheDefaultOverlayPathIsOutsideSettingAndNamedAfterTheModel" \
    "$SRC" \
    'static constexpr const char* kNameOverlayDir = ".test_run/nickname_overlay";' \
    'static constexpr const char* kNameOverlayDir = "setting/nickname_overlay";'

# --- M10: 🔴 a cosmetic file takes the fabric down ----------------------------------------------
mutate_must_die \
    "M10 an unreadable overlay refuses the load" \
    "NicknamePersistenceTest.AnUnreadableOverlayDoesNotStopTheTopologyFromLoading" \
    "$SRC" \
    '                           err.what(),
                           activeTopologyPath());
        return;' \
    '                           err.what(),
                           activeTopologyPath());
        throw;'

echo
echo "controls (behaviour-preserving; these must stay GREEN):"

mutate_must_live \
    "C1 the empty-value test is spelled differently" \
    "$SRC" \
    '    const char* custom = std::getenv("NDTWIN_NICKNAME_OVERLAY");
    if (custom != nullptr && custom[0] != '"'"'\0'"'"')' \
    '    const char* custom = std::getenv("NDTWIN_NICKNAME_OVERLAY");
    if (custom != nullptr && std::string(custom) != "")'

mutate_must_live \
    "C2 the comment above the atomic writer is reworded" \
    "$SRC" \
    '/// Writes to a temp file beside the target and renames, so no reader -- including the next' \
    '/// Temp file beside the target plus a rename, so that no reader -- including the next'

echo
echo "mutations -- ndt status --check:"

# --- M11: 🔴 --check folds the overlay into the model file's sha256 ------------------------------
# The precise regression W10 exists to prevent: the operator names a switch and the environment
# check answers "the topology file has been edited".
m=$(ndt_mutant m11 "$NDT" \
    '        now="$(sha256sum "$path" 2>/dev/null | cut -d'"'"' '"'"' -f1)"' \
    '        now="$(cat "$path" "$overlay" 2>/dev/null | sha256sum | cut -d'"'"' '"'"' -f1)"')
ndt_must_die "M11 --check hashes the overlay with the model file" "$m" \
    "🔴 renaming two switches leaves --check GREEN"

# --- M12: the row is printed and also graded ----------------------------------------------------
# Printing a comparison and making one are two acts. This mutant keeps the row exactly as it
# reads and turns it into a verdict, which is the same red by a different door.
m=$(ndt_mutant m12 "$NDT" \
    '    _ut_overlay_row "$overlay"' \
    '    _ut_overlay_row "$overlay"
    [[ -f "$overlay" ]] && { UP_TARGET_PROBLEMS+=("device names: an overlay exists"); bad=1; }')
ndt_must_die "M12 the overlay row becomes part of the verdict" "$m" \
    "🔴 renaming two switches leaves --check GREEN"

# --- M13: the row stops saying it was left out on purpose ---------------------------------------
# A silence is not a statement. Without the words, a reader cannot tell "not compared" from
# "forgot to compare", and nothing fails when the next change folds it in.
m=$(ndt_mutant m13 "$NDT" \
    '            "not compared -- the model file is the baseline"' \
    '            ""')
ndt_must_die "M13 the row no longer says it was not compared" "$m" \
    "  and the row says it was left out on purpose"

echo
ok=1
for f in "${FILES[@]}"; do cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }; done
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 NOT RESTORED: tools/test_workflow/ndt changed while this gate ran"; ok=0
fi
[[ "$ok" == 1 ]] && echo "baseline restored: $SRC and tools/test_workflow/ndt byte-identical to the pre-run snapshot"

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
