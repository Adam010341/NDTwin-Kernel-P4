#!/usr/bin/env bash
# Scratch driver (NOT committed). Waits for the configure to clear the machine-wide build lock,
# then produces the whole evidence chain in order:
#
#   1. RED   -- trunk's four dereferences restored verbatim, new suite present
#   2. GREEN -- the fix back in place
#   3. GATE  -- tests/shell/mutate_cpu_report_no_ip.sh
#
# Every build goes through tools/build_guard/guarded_build.sh at JOBS=1. The source is restored
# on any exit, so an interrupted run never leaves the worktree mutated.
set -uo pipefail
W=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-noip
OUT=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/noip-work
GUARD=/home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh
SRC=$W/src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
BIN=$W/build/bin/test_routing_strategy
FILTER='NoIpSwitchTest.*'

cd "$W"
cp "$SRC" "$OUT/pipeline.src.fixed"
restore() { cp "$OUT/pipeline.src.fixed" "$SRC"; }
trap restore EXIT

say() { echo "[$(date +%H:%M:%S)] $*"; }

build() {   # $1 = log file
    LOCK_WAIT=10800 JOBS=1 "$GUARD" cmake --build build --target test_routing_strategy -j1 \
        > "$1" 2>&1
    tail -1 "$1" | grep -q "guarded_build: exit 0"
}

say "waiting for the configure to finish"
until grep -q "guarded_build: exit" "$OUT/configure.log" 2>/dev/null; do sleep 15; done
if ! grep -q "guarded_build: exit 0" "$OUT/configure.log"; then
    say "REFUSE: configure did not succeed"
    tail -20 "$OUT/configure.log"
    exit 2
fi
say "configure ok"

# ---------------------------------------------------------------- 1. RED
say "building the RED tree (trunk's dereferences restored)"
python3 "$OUT/make_red_source.py" > "$OUT/red_source.log" 2>&1
if [[ $? -ne 0 ]]; then
    say "REFUSE: could not build the red source"; cat "$OUT/red_source.log"; exit 2
fi
cat "$OUT/red_source.log"

if build "$OUT/build_red.log"; then
    say "red build ok; running $FILTER"
    "$BIN" --gtest_filter="$FILTER" > "$OUT/run_red.log" 2>&1
    say "RED run exit=$? (see run_red.log)"
else
    say "REFUSE: the red tree did not build"
    tail -30 "$OUT/build_red.log"
    restore
    exit 2
fi

# ---------------------------------------------------------------- 2. GREEN
restore
say "building the GREEN tree (the fix)"
if build "$OUT/build_green.log"; then
    say "green build ok; running $FILTER"
    "$BIN" --gtest_filter="$FILTER" > "$OUT/run_green.log" 2>&1
    say "GREEN run exit=$? (see run_green.log)"
    say "running the two neighbouring suites over the same files"
    "$BIN" --gtest_filter='SimulatedDeviceMetricsTest.*:PowerManagerShutdown*:TopologyInputValidation*' \
        > "$OUT/run_neighbours.log" 2>&1
    say "neighbours exit=$? (see run_neighbours.log)"
    say "running the whole binary"
    "$BIN" > "$OUT/run_all.log" 2>&1
    say "full suite exit=$? (see run_all.log)"
else
    say "REFUSE: the green tree did not build"
    tail -30 "$OUT/build_green.log"
    exit 2
fi

# ---------------------------------------------------------------- 3. GATE
say "running the mutation gate (this is the long one: 14 guarded builds)"
bash tests/shell/mutate_cpu_report_no_ip.sh > "$OUT/gate.log" 2>&1
say "GATE exit=$? (see gate.log)"

say "PIPELINE DONE"
