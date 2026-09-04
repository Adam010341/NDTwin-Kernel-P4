#!/usr/bin/env bash
# Auditor's continuation of the delgroup agent's pipeline2.sh (steps 5-7), with the two gates
# run UNDER the build guard instead of bare cmake (the agent's version ran them outside the lock
# and outside the memory cap). Working tree is left byte-identical to the committed fix on exit.
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
W=$S/delgroup-work
WT=$S/wt-delgroup
G=/home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh
STRAT=src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
FILTER='GroupMeterFixture.*:GroupMeterEndpointTest.*'
cd $WT || exit 1
BASE_SHA=$(sha256sum $STRAT | cut -d' ' -f1)
restore() { cp $W/HRSB.fixed.cpp $STRAT; touch $STRAT
  now=$(sha256sum $STRAT | cut -d' ' -f1)
  [[ "$now" == "$BASE_SHA" ]] && echo "restore ok ($now)" || echo "RESTORE FAILED: $now != $BASE_SHA"; }
trap restore EXIT
echo "HEAD $(git rev-parse --short HEAD) dirty=$(git status --porcelain | wc -l) STRAT sha $BASE_SHA"
echo "### 5. rebuild after restore (guarded) ###"; date -Is
LOCK_WAIT=10800 JOBS=1 $G cmake --build build --target test_routing_strategy -j1 2>&1 | tail -5
./build/bin/test_routing_strategy --gtest_filter="$FILTER" > $W/green_run2.log 2>&1; echo "GREEN2_RC=$?"
tail -3 $W/green_run2.log
./build/bin/test_routing_strategy > $W/green_all2.log 2>&1; echo "ALL2_RC=$?"; tail -3 $W/green_all2.log
echo "### 6. gate: finding #1 (under guard) ###"; date -Is
LOCK_WAIT=10800 JOBS=1 $G bash tests/shell/mutate_delete_group_entry.sh > $W/gate_delgroup.log 2>&1; echo "GATE_RC=$?"
tail -30 $W/gate_delgroup.log
echo "### 7. gate: F-13 re-run (under guard) ###"; date -Is
LOCK_WAIT=10800 JOBS=1 $G bash tests/shell/mutate_f13_group_meter_existence.sh > $W/gate_f13.log 2>&1; echo "F13_RC=$?"
tail -20 $W/gate_f13.log
echo "tree dirty after: $(git status --porcelain | wc -l)"
echo "### PIPELINE3 DONE ###"; date -Is
