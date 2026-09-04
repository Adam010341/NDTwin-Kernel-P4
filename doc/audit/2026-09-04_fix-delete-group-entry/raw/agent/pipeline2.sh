#!/usr/bin/env bash
# Finding #1: green -> red -> restore -> gates. Guards its own baseline like the gates do:
# the working tree is left byte-identical to the committed fix on ANY exit.
SD=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
WT=$SD/wt-delgroup
G=/home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh
STRAT=src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
FILTER='GroupMeterFixture.*:GroupMeterEndpointTest.*'
cd $WT || exit 1
BASE_SHA=$(sha256sum $STRAT | cut -d' ' -f1)
restore() { cp $SD/HRSB.fixed.cpp $STRAT; touch $STRAT
  now=$(sha256sum $STRAT | cut -d' ' -f1)
  [[ "$now" == "$BASE_SHA" ]] && echo "restore ok ($now)" || echo "RESTORE FAILED: $now != $BASE_SHA"; }
trap restore EXIT

echo "### 0. configure ###"; date -Is
LOCK_WAIT=10800 JOBS=1 $G cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug 2>&1 | tail -4

echo "### 1. GREEN build (the committed fix) ###"; date -Is
LOCK_WAIT=10800 JOBS=1 $G cmake --build build --target test_routing_strategy -j1 2>&1 | tail -20
echo "### 2. GREEN run ###"
./build/bin/test_routing_strategy --gtest_filter="$FILTER" > $SD/green_run.log 2>&1; echo "GREEN_RC=$?"
tail -5 $SD/green_run.log
./build/bin/test_routing_strategy > $SD/green_all.log 2>&1; echo "ALL_RC=$?"; tail -3 $SD/green_all.log

echo "### 3. RED variant on disk (trunk behaviour, new seam kept so it COMPILES) ###"; date -Is
cp $SD/HRSB.red.cpp $STRAT; touch $STRAT
LOCK_WAIT=10800 JOBS=1 $G cmake --build build --target test_routing_strategy -j1 2>&1 | tail -10
echo "### 4. RED run -- these must FAIL ###"
./build/bin/test_routing_strategy --gtest_filter="$FILTER" > $SD/red_run.log 2>&1; echo "RED_RC=$?"
grep -E "^\[  FAILED  \]" $SD/red_run.log | sort -u
grep -E "^\[==========\].*ran|^\[  PASSED  \]|^\[  FAILED  \] [0-9]" $SD/red_run.log | tail -4

echo "### 5. restore + rebuild ###"; date -Is
restore
LOCK_WAIT=10800 JOBS=1 $G cmake --build build --target test_routing_strategy -j1 2>&1 | tail -5
./build/bin/test_routing_strategy --gtest_filter="$FILTER" > $SD/green_run2.log 2>&1; echo "GREEN2_RC=$?"
tail -3 $SD/green_run2.log

echo "### 6. gate: finding #1 ###"; date -Is
JOBS=1 bash tests/shell/mutate_delete_group_entry.sh > $SD/gate_delgroup.log 2>&1; echo "GATE_RC=$?"
tail -30 $SD/gate_delgroup.log
echo "### 7. gate: F-13 re-run ###"; date -Is
JOBS=1 bash tests/shell/mutate_f13_group_meter_existence.sh > $SD/gate_f13.log 2>&1; echo "F13_RC=$?"
tail -20 $SD/gate_f13.log
echo "### PIPELINE2 DONE ###"; date -Is
