#!/usr/bin/env bash
# Everything that has to happen once the fix build gets the shared lock, in order, unattended.
# [Co-developed with claude code -- Adam]
set -u
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
WT=$SP/wt-topoval
GUARD=/home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh

# 1. wait for the fix build
until grep -q "guarded_build: exit" "$SP/build_fix.log"; do sleep 15; done
RC=$(sed -n 's/^guarded_build: exit \([0-9]*\)$/\1/p' "$SP/build_fix.log" | tail -1)
echo "STEP1 build rc=$RC"
if [[ "$RC" != 0 ]]; then
    echo "BUILD FAILED -- stopping. Last 40 lines:"; tail -40 "$SP/build_fix.log"
    echo "POST_BUILD_DONE step=build_failed"; exit 1
fi

cd "$WT" || exit 9

# 2. the suite, green
sha256sum build/bin/test_routing_strategy > "$SP/raw/green_binary.sha"
./build/bin/test_routing_strategy --gtest_filter='TopologyInputValidationTest.*' \
    > "$SP/raw/green_gtest.log" 2>&1
echo "STEP2 new suite rc=$?"

# 3. the whole gtest binary, then ctest
./build/bin/test_routing_strategy > "$SP/raw/full_gtest.log" 2>&1
echo "STEP3 full gtest rc=$?"
(cd build && timeout 1800 ctest --output-on-failure > "$SP/raw/ctest.log" 2>&1)
echo "STEP4 ctest rc=$?"

# 4. the real binary against the four topology files, sequentially, :8000 free between runs
mkdir -p "$SP/raw/after"
"$SP/repro/before_all.sh" "$WT/build/bin/ndtwin_kernel" "$SP/raw/after" > "$SP/raw/after_all.stdout" 2>&1
echo "STEP5 after-runs done"

# 5. the mutation gate -- under the guard, because it builds once per mutation
setsid env JOBS=2 "$GUARD" ./tests/shell/mutate_topology_input_is_validated.sh \
    > "$SP/raw/gate.log" 2>&1
echo "STEP6 gate rc=$(sed -n 's/^guarded_build: exit \([0-9]*\)$/\1/p' "$SP/raw/gate.log" | tail -1)"

echo "POST_BUILD_DONE step=all"
