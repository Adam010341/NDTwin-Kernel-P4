#!/usr/bin/env bash
# Batch-compile every fix-design branch in ONE detached build worktree, run the branch's new
# gtests, then its mutate_*.sh gate. Sequential on purpose: one ninja at a time, so a parallel
# storm cannot contaminate anyone's measurement. Refuses to start while the lab is claimed.
# [Co-developed with claude code -- Adam]
set -uo pipefail
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/4e0e8cb4-1c72-4731-b5fe-2989d7af1d65/scratchpad
BW="$SP/buildwt"; REPO=/home/adam/Desktop/NDTwin-Kernel; OUT="$SP/batch-out"; mkdir -p "$OUT"
JOBS="${JOBS:-6}"

# --- gate 0: nobody may be measuring ---
cl=$(NDT_OWNER=auditor timeout 30 "$REPO/tools/test_workflow/ndt" status 2>/dev/null | awk '$1=="claim"{$1="";print}' | sed 's/^ //')
if [[ -n "$cl" && "$cl" != none && "$cl" != EXPIRED* && "$cl" != *auditor* && "${FORCE:-0}" != 1 ]]; then
    echo "REFUSING: lab claim = '$cl' (set FORCE=1 to override -- only if you know the claim is stale)"; exit 3
fi

# --- configure once (same generator/type as the main tree) ---
cd "$BW" || exit 9
if [[ ! -f build/build.ninja ]]; then
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE="${BUILD_TYPE:-Debug}" -DCMAKE_CXX_COMPILER_LAUNCHER=ccache > "$OUT/configure.log" 2>&1; echo "configure rc=$?"
fi

printf '%-46s %-9s %-8s %-8s %-10s %s\n' BRANCH HEAD BUILD GTEST MUTATE NOTE | tee "$OUT/SUMMARY.tsv"
while IFS=$'\t' read -r branch id hint; do
    [[ -z "$branch" ]] && continue
    git checkout -q --detach "$branch" 2>/dev/null || { printf '%-46s %-9s %s\n' "$branch" "-" "CHECKOUT-FAILED" | tee -a "$OUT/SUMMARY.tsv"; continue; }
    head=$(git rev-parse --short HEAD); tag=$(echo "$id" | tr '/' '_')
    # build everything the branch registered (incremental; ninja decides what changed)
    cmake --build build -j "$JOBS" > "$OUT/$tag.build.log" 2>&1; brc=$?
    if [[ $brc -ne 0 ]]; then
        printf '%-46s %-9s %-8s %-8s %-10s %s\n' "$branch" "$head" "FAIL($brc)" "-" "-" "see $tag.build.log" | tee -a "$OUT/SUMMARY.tsv"
        grep -m3 -E 'error:' "$OUT/$tag.build.log" | cut -c1-140 | sed 's/^/      /'
        continue
    fi
    # run only the tests this branch ADDED (new files under tests/), by ctest regex on their names
    # every gtest links into ONE binary (test_routing_strategy) and gtest_discover_tests registers
    # each case as "Suite.Case" -- so select by the SUITE names declared in the files this branch added/changed
    suites=$(git diff --name-only 4cbec52d..HEAD -- tests | grep -E '^tests/test_.*\.cpp$' | xargs -r grep -hoE '^TEST(_F)?\(\s*[A-Za-z0-9_]+' | sed -E 's/^TEST(_F)?\(\s*//' | sort -u | tr '\n' '|' | sed 's/|$//')
    if [[ -n "$suites" ]]; then
        ( cd build && ctest --output-on-failure -R "^($suites)\." > "$OUT/$tag.gtest.log" 2>&1 ); grc=$?
        gsum=$(grep -E 'tests passed|tests failed' "$OUT/$tag.gtest.log" | tail -1 | cut -c1-40)
    else
        grc=0; gsum="(no new test file; existing targets modified)"
    fi
    # the branch's own mutation gate, if it shipped one
    mut=$(git diff --name-only 4cbec52d..HEAD -- tests/shell | grep -E '^tests/shell/mutate_.*\.sh$' | head -1)
    if [[ -n "$mut" ]]; then
        BUILD_DIR=build bash "$mut" > "$OUT/$tag.mutate.log" 2>&1; mrc=$?
        msum=$(grep -E 'mutations?,|survived' "$OUT/$tag.mutate.log" | tail -1 | cut -c1-30)
    else
        mrc=-; msum="(no mutate script)"
    fi
    printf '%-46s %-9s %-8s %-8s %-10s %s\n' "$branch" "$head" "ok" "rc=$grc" "rc=$mrc" "$gsum | $msum" | tee -a "$OUT/SUMMARY.tsv"
done < "$SP/branches.txt"
echo; echo "logs in $OUT/"
