#!/usr/bin/env bash
#
# Mutation gate for E-2 / KNOWN-ISSUES G-15 -- the kernel reports the model it loaded, and
# run_layers.sh asks it instead of guessing.
#
# Covers both halves, because the defect spans them and either half alone is decoration:
#
#   tests/test_TopologyLoadedModelReported.cpp   the kernel's answer
#   tests/shell/test_run_layers_asks_kernel.sh   the consumer that has to act on it
#
# [Co-developed with claude code -- Adam]
#
#   M1  the kernel reports no digest, only a path                                (C++, red)
#   M2  the digest is taken over the PATH STRING instead of the file's bytes     (C++, red)
#   M3  the digest is recomputed from disk on every request                      (C++, red)
#   M4  run_layers ignores the kernel's answer and derives as before             (sh,  red)
#   M5  run_layers carries on when the digest no longer matches                  (sh,  red)
#   M6  WIDENING: run_layers refuses when the kernel does not say                (sh,  red)
#   M7  get_graph_data never merges the record, so the wire carries nothing      (C++, red)
#   M8  WIDENING: the kernel invents the three keys with nothing loaded          (C++, red)
#
# 🔴 M2 is the one that matters most on the kernel side. Hashing the path produces a field that
# is present, plausible, stable and useless: it answers "has this file changed?" with a
# permanent no, and every caller that only checks the field exists would report a healthy
# system. A digest that cannot change is worse than no digest, because it occupies the slot
# where the real answer would go.
#
# 🔴 M6 and M8 are the widenings, and they are why this gate has two control cells. Baseline
# `28b8b13` reports none of the three keys. Refusing to run against such a kernel (M6), or
# inventing the keys when nothing has loaded (M8), are both the cheapest ways to make the new
# tests greener -- and both destroy the one distinction the change is for: absence means "the
# kernel did not say", never "there is nothing to check" and never "here is an answer".
#
# 🔴 Guards its own baselines, in two different ways because the two files have different
# hazards. The C++ sources are snapshotted and restored by an EXIT trap, and byte-identity is
# asserted at the end (the mutate_a2_poll_round.sh pattern). run_layers.sh is never written at
# all: the mutations go into a COPY in a temp dir and the test is pointed at it with
# RUN_LAYERS_UNDER_TEST, because another session may be executing that script right now.
# Anchor counts are always taken from the REAL file, so a reworded source reports a missing
# anchor here and in tests/shell/check_gate_anchors.py.
#
# Usage:  tests/shell/mutate_kernel_reports_loaded_model.sh
#         BUILD_DIR=build-asan tests/shell/mutate_kernel_reports_loaded_model.sh
#         ANCHOR_CHECK=1 tests/shell/mutate_kernel_reports_loaded_model.sh  # NOT a gate result
#         SHELL_ONLY=1 tests/shell/mutate_kernel_reports_loaded_model.sh    # skip the rebuilds
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
# Exit:    0 all mutations caught, 1 a mutation survived, 2 refused (baseline red, anchor moved,
#          baseline not restored, or anchor-check mode -- which never produces a verdict).
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='TopologyLoadedModel.*:TopologyLoadedModelWire.*'

SRC=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
HTTP=src/ndt_core/http/HttpSession.cpp
FILES=("$SRC" "$HTTP")

RUNLAYERS=tools/test_workflow/run_layers.sh
COMPONENTS_ENV=tools/test_workflow/components.env
SHELLTEST=tests/shell/test_run_layers_asks_kernel.sh

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

for f in "${FILES[@]}" "$RUNLAYERS" "$SHELLTEST"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done

MUTATIONS=0
SURVIVORS=0

# anchor_count <file> <literal> -- how many times the literal occurs. python rather than
# `grep -c -F`, which splits a multi-line pattern into several and counts matching LINES.
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# --- the C++ mutation table -------------------------------------------------------------------
# Declared once so the anchor check and the gate cannot disagree about what is being tested.
# Fields: label, file, anchor, replacement, the test that must go red.

MUT_LABEL=(); MUT_FILE=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=()
add() {
    MUT_LABEL+=("$1"); MUT_FILE+=("$2"); MUT_ANCHOR+=("$3")
    MUT_REPL+=("$4");  MUT_EXPECT+=("$5")
}

# M1. A path and a timestamp, and no digest. The path is identical before and after the edit
#     this exists to catch, so what is left cannot answer the question at all -- and it looks
#     like a working feature to anything that checks the field is present.
add "M1: the kernel reports no digest, only a path" \
    "$SRC" \
    '    return json{{"topology_file", m_loadedTopology.path},
                {"topology_sha256", m_loadedTopology.sha256},
                {"topology_loaded_at", m_loadedTopology.loadedAt}};' \
    '    return json{{"topology_file", m_loadedTopology.path},
                {"topology_loaded_at", m_loadedTopology.loadedAt}};' \
    'TopologyLoadedModel.ThePathTheHashAndTheTimeAreRecordedAtLoad'

# M2. 🔴 The digest of the NAME. Present, plausible, 64 hex digits, and constant for the life of
#     the file -- so "has this been edited?" is answered no, for ever, by construction.
add "M2: the digest is taken over the path string, not the file bytes" \
    "$SRC" \
    '    noteLoadedTopology(path, bytes);' \
    '    noteLoadedTopology(path, path);' \
    'TopologyLoadedModel.TheHashIsOfTheFileBytesNotOfItsPath'

# M3. Re-read per request. The kernel then reports what is on DISK rather than what it is
#     SERVING, which is exactly the quantity the consumer is trying to compare against -- so
#     the one accident the digest exists to expose becomes invisible.
add "M3: the digest is recomputed from disk on every request" \
    "$SRC" \
    '    return json{{"topology_file", m_loadedTopology.path},
                {"topology_sha256", m_loadedTopology.sha256},
                {"topology_loaded_at", m_loadedTopology.loadedAt}};' \
    '    std::ifstream mutantIn(m_loadedTopology.path, std::ios::binary);
    const std::string mutantBytes((std::istreambuf_iterator<char>(mutantIn)),
                                  std::istreambuf_iterator<char>());
    return json{{"topology_file", m_loadedTopology.path},
                {"topology_sha256", sha256Hex(mutantBytes)},
                {"topology_loaded_at", m_loadedTopology.loadedAt}};' \
    'TopologyLoadedModel.TheRecordDoesNotFollowTheFileAfterTheLoad'

# M7. The record is knowable and never served. Every monitor-level case stays green and the
#     endpoint carries nothing -- which is the whole of the change, from the consumer's side.
add "M7: get_graph_data never merges the record onto the response" \
    "$HTTP" \
    '    result.update(m_topologyAndFlowMonitor->loadedTopologyJson());' \
    '    // MUTANT: the response never carries the model the kernel loaded' \
    'TopologyLoadedModelWire.TheThreeKeysAreServedByGetGraphData'

# M8. WIDENING. Answering when there is nothing to answer with: the three keys appear on a
#     kernel that has loaded no topology, so "absent" stops meaning "the kernel did not say"
#     and a consumer reading an empty path has no way to know it is reading nothing.
add "M8: WIDENING -- the keys are served even when nothing has been loaded" \
    "$SRC" \
    '    if (!m_loadedTopology.recorded)
    {
        return json::object();
    }' \
    '    if (false)
    {
        return json::object();
    }' \
    'TopologyLoadedModelWire.AKernelWithNoTopologyServesTheBaselineShape'

# --- the shell mutation table -----------------------------------------------------------------
# Kept as its own list because these are applied to a COPY and need no build. Fields: label,
# file, anchor, replacement, the check line that must read FAILED.
#
# The file is carried in its own array rather than baked into the applier, for the same reason
# the C++ table above carries MUT_FILE: it is what lets tests/shell/check_gate_anchors.py PIN
# each anchor to one file instead of counting it across every path this gate declares.

SH_LABEL=(); SH_FILE=(); SH_ANCHOR=(); SH_REPL=(); SH_EXPECT=()
sh_add() {
    SH_LABEL+=("$1"); SH_FILE+=("$2"); SH_ANCHOR+=("$3")
    SH_REPL+=("$4");  SH_EXPECT+=("$5")
}

# M4. The defect itself: derive, never ask. The suite then validates whatever model the host
#     count happens to name, which for two models of equal cardinality is a coin toss.
sh_add "M4: run_layers ignores the kernel and derives as before" \
    "$RUNLAYERS" \
    '    from_kernel="$(topo_from_kernel)"; krc=$?' \
    '    from_kernel=""; krc=1' \
    'the model the kernel says it loaded is the model used'

# M5. The path is used and the digest is not checked. The twin serves the old contents, the
#     layers read the new ones, and every difference is reported as a product defect.
sh_add "M5: run_layers carries on when the digest no longer matches" \
    "$RUNLAYERS" \
    '    if [[ -n "$sha" && "$sha" != "$local_sha" ]]; then' \
    '    if false; then' \
    'a topology whose sha256 no longer matches is refused (rc 3)'

# M6. 🔴 WIDENING. Refusing where the baseline must still run: every pre-E-2 kernel, and every
#     offline layer, is taken out of the harness by a check that was supposed to add a question.
sh_add "M6: WIDENING -- refuse instead of deriving when the kernel does not say" \
    "$RUNLAYERS" \
    '        echo "before E-2), so the model below is DERIVED from the running fabric -- guessing.${N}" >&2
        return 1' \
    '        echo "before E-2), so this run refuses to choose a model.${N}" >&2
        return 3' \
    'a pre-E-2 kernel falls back to the derivation and says it is guessing'

# --- anchor check (never a verdict) -------------------------------------------------------------

if [[ "$ANCHOR_CHECK" != "0" ]]; then
    echo "================================================================"
    echo " ANCHOR CHECK ONLY -- THIS IS NOT A GATE RESULT."
    echo " Nothing was built, no mutation was applied, no test was run."
    echo " The exit code is 2 on purpose so this can never be mistaken for"
    echo " a passing gate."
    echo "================================================================"
    broken=0
    for i in "${!MUT_LABEL[@]}"; do
        n=$(anchor_count "${MUT_FILE[$i]}" "${MUT_ANCHOR[$i]}")
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${MUT_LABEL[$i]}"
        else
            printf '  🔴 %s matches in %s  (%s)\n' "$n" "${MUT_FILE[$i]}" "${MUT_LABEL[$i]}"
            broken=$((broken + 1))
        fi
    done
    for i in "${!SH_LABEL[@]}"; do
        n=$(anchor_count "${SH_FILE[$i]}" "${SH_ANCHOR[$i]}")
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${SH_LABEL[$i]}"
        else
            printf '  🔴 %s matches in %s  (%s)\n' "$n" "${SH_FILE[$i]}" "${SH_LABEL[$i]}"
            broken=$((broken + 1))
        fi
    done
    if [[ "$broken" -eq 0 ]]; then
        echo "ANCHORS: ok -- all $(( ${#MUT_LABEL[@]} + ${#SH_LABEL[@]} )) resolve to one site each."
    else
        echo "ANCHORS: BROKEN -- $broken anchor(s) have moved. Fix them before running the gate."
    fi
    echo "(still exiting 2: an anchor check is not a gate result)"
    exit 2
fi

# --- shell half: mutations into a copy, never into the tree -------------------------------------

BK="$(mktemp -d /tmp/e2-mutate-XXXXXX)"
RUNLAYERS_SHA="$(sha256sum "$RUNLAYERS" | cut -d' ' -f1)"

# fresh_copy <tag> -- run_layers.sh plus the components.env it sources, in $BK/<tag>. Echoes the
# path of the copied run_layers.sh.
fresh_copy() {
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$RUNLAYERS" "$dst/run_layers.sh"
    cp "$COMPONENTS_ENV" "$dst/components.env"
    echo "$dst/run_layers.sh"
}

# apply_exact <file> <old> <new> <copy> -- assert the anchor occurs exactly once in the REAL
# file, then write the replacement into the copy. Never writes the real file. A substitution
# that matched nothing would leave the copy unmutated and score an untouched tree as "caught".
apply_exact() {
    local file="$1" from="$2" to="$3" dst="$4" n
    n=$(anchor_count "$file" "$from")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: anchor appears $n time(s) in $file, expected 1"
        echo "     anchor: $from"
        exit 2
    fi
    FROM="$from" TO="$to" python3 - "$file" "$dst" <<'PY'
import os, pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text()
assert text.count(os.environ["FROM"]) == 1, "anchor is not unique at write time"
dst.write_text(text.replace(os.environ["FROM"], os.environ["TO"], 1))
PY
}

# sh_report <label> <mutated copy> <check that must go red>
sh_report() {
    local label="$1" copy="$2" want="$3" out rc
    MUTATIONS=$((MUTATIONS + 1))
    out="$(RUN_LAYERS_UNDER_TEST="$copy" bash "$SHELLTEST" 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $want" <<<"$out"; then
        printf '  caught   %-62s (red)\n' "$label"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-62s (stayed green -- that check proves nothing)\n' "$label"
        grep -E '^  (ok|FAILED)|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

echo "=== shell half: tests/shell/test_run_layers_asks_kernel.sh ==="
echo "baseline (must be green before any mutation):"
base="$(fresh_copy base)"
RUN_LAYERS_UNDER_TEST="$base" bash "$SHELLTEST" 2>&1 | tail -1 | sed 's/^/  /'
if ! RUN_LAYERS_UNDER_TEST="$base" bash "$SHELLTEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    rm -rf "$BK"
    exit 2
fi
echo

for i in "${!SH_LABEL[@]}"; do
    c="$(fresh_copy "m$i")"
    apply_exact "${SH_FILE[$i]}" "${SH_ANCHOR[$i]}" "${SH_REPL[$i]}" "$c"
    sh_report "${SH_LABEL[$i]}" "$c" "${SH_EXPECT[$i]}"
done

if [[ "$(sha256sum "$RUNLAYERS" | cut -d' ' -f1)" != "$RUNLAYERS_SHA" ]]; then
    echo "🔴 baseline CHANGED -- $RUNLAYERS was written during the gate"
    rm -rf "$BK"
    exit 3
fi
echo "  $RUNLAYERS byte-identical: yes"
rm -rf "$BK"

if [[ "${SHELL_ONLY:-0}" != "0" ]]; then
    echo
    echo "SHELL_ONLY=1 -- the C++ half was not run, so this is NOT a full gate result."
    exit 2
fi

# --- C++ half: mutations in place, snapshot and restore ------------------------------------------

echo
echo "=== C++ half: tests/test_TopologyLoadedModelReported.cpp ==="
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2; exit 2; }

SNAP=$(mktemp -d)
snap() { echo "$SNAP/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        # cp -p restores the ORIGINAL mtime, which is older than the object built from the
        # mutant -- ninja would then see nothing to do and the next run would test the mutant
        # while the source on disk is pristine. touch is what actually restores the build.
        touch "$f"
    done
}
trap 'restore; rm -rf "$SNAP"' EXIT

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

# red_tests -- the names of the tests that failed. rc is taken from the binary directly, never
# through a pipe.
red_tests() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z]*\.[A-Za-z]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

echo "baseline (must be green before any mutation):"
if ! build; then
    echo "  the tree does not build -- nothing below would mean anything"
    exit 2
fi
if [[ -n "$(red_tests)" ]]; then
    echo "  baseline is RED: $(red_tests)"
    exit 2
fi
echo "  green"

# mutate <label> <file> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" file="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); restore; return
    fi
    MUTATIONS=$((MUTATIONS + 1))

    if ! ANCHOR="$anchor" REPL="$repl" python3 - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    if ! build; then
        # A mutant that never reached the compiler established nothing about the tests. It is
        # not a free pass either: the mutation it was meant to make did not happen.
        echo "  🔴 MUTANT DOES NOT COMPILE -- the behaviour it was aimed at is still untested."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -8 | sed 's/^/    /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    restore
    if [[ -z "$failed" ]]; then
        echo "  🔴 SURVIVED -- every test stayed green"
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi
    if ! grep -qw -- "$expected" <<<"$failed"; then
        echo "  🔴 WRONG TEST WENT RED. expected $expected, got: $failed"
        echo "     A gate that fires without establishing what it claims is not a gate."
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi
    echo "  caught by: $failed"
}

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_FILE[$i]}" "${MUT_ANCHOR[$i]}" \
           "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}"
done

echo
echo "restoring and rebuilding the baseline..."
restore
if ! build; then
    echo "🔴 the tree does not build after restore -- the baseline was NOT restored"
    exit 2
fi
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "🔴 $f was NOT restored byte-for-byte"
        exit 2
    fi
done
if [[ -n "$(red_tests)" ]]; then
    echo "🔴 the restored tree is RED: $(red_tests)"
    exit 2
fi
echo "baseline restored, byte-identical, green."

echo
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
