#!/usr/bin/env bash
# Wave-2 merged-tree verification (auditor). Step A: phantomovs red arm on the merged tree --
# reverse-apply that branch's source hunks (NOT `checkout trunk --`, the tree also carries noip's
# DCPM changes), put test_PendingEntryFilter.cpp back to trunk (it uses the new API), rebuild the
# test binary, run the 12 PhantomOvsFixture cases: they must FAIL. Restore, then step B: the
# generic merged-tree pipeline (full build, gtest, ctest -j2, gates under guard, python suites).
export LOCK_WAIT=10800; export JOBS=1
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
W=$S/wave2-work; T=$S/wt-integrate; G=/home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh
cd $T || exit 2
SRC=(include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp
     include/ndt_core/routing_management/DispatchOutcomeLog.hpp
     include/ndt_core/routing_management/IRoutingStrategy.hpp
     include/ndt_core/routing_management/OpResult.hpp
     include/ndt_core/routing_management/OpenFlowRoutingStrategy.hpp
     include/ndt_core/routing_management/P4RoutingStrategy.hpp
     src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
     src/ndt_core/routing_management/Controller.cpp
     src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp)
PEF=tests/test_PendingEntryFilter.cpp
restore() { git checkout HEAD -- "${SRC[@]}" "$PEF"; touch "${SRC[@]}" "$PEF"; echo "restored: dirty=$(git status --porcelain | wc -l)"; }
trap restore EXIT
echo "=== A0. merged tree $(git rev-parse --short HEAD) dirty=$(git status --porcelain | wc -l) $(date '+%T') ==="
[[ $(git status --porcelain | wc -l) == 0 ]] || { echo "STOP: tree dirty"; exit 2; }
echo "=== A1. reverse-apply phantomovs source hunks + trunk's $PEF ==="
git diff trunk...fix/phantom-filter-covers-ovs -- "${SRC[@]}" > $W/phantom_src.diff
git apply -R --check $W/phantom_src.diff && git apply -R $W/phantom_src.diff || { echo "STOP: reverse apply failed"; exit 2; }
git checkout trunk -- "$PEF"
echo "red tree dirty=$(git status --porcelain | wc -l) (expect 10)"; git status --porcelain | sed 's/^/   /'
echo "=== A2. guarded build test_routing_strategy (RED tree) $(date '+%T') ==="
$G cmake --build build --target test_routing_strategy -j1 > $W/build_red.log 2>&1
gx=$(grep -oE 'guarded_build: exit [0-9]+' $W/build_red.log | tail -1 | awk '{print $3}'); echo "red build guard exit=${gx:-none} $(date '+%T')"
if [[ "$gx" == 0 ]]; then
  echo "=== A3. run PhantomOvsFixture.* on the RED tree (must fail) ==="
  timeout 600 build/bin/test_routing_strategy --gtest_filter='PhantomOvsFixture.*' > $W/run_red.log 2>&1; echo "RED rc=$?"
  grep -E '^\[  (PASSED|FAILED)  \] [0-9]+|^\[  FAILED  \] Phantom' $W/run_red.log | sort -u
else
  grep -E 'error' $W/build_red.log | head -8; echo "RED BUILD FAILED -- the 12 cases do not compile against trunk headers (agent's -fsyntax-only claim not upheld)"
fi
restore; trap - EXIT
[[ $(git status --porcelain | wc -l) == 0 ]] || { echo "STOP: restore left the tree dirty"; exit 2; }
echo "=== B. generic merged pipeline $(date '+%T') ==="
exec bash $S/verify_merged_generic.run.sh wave2 mutate_phantom_filter_covers_ovs mutate_cpu_report_no_ip mutate_delete_group_entry mutate_f13_group_meter_existence mutate_f1_mininet_health_metrics
