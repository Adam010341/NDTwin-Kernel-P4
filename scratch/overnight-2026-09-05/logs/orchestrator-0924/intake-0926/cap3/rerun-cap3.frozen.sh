#!/usr/bin/env bash
# Orchestrator rerun of the third cut (kernel) on the test merge 49214a2b (trunk 18c83aba + 86890c6a).
# Build and unit cells: one guard call each (JOBS=1 LOCK_WAIT=10800). The mutation gate guards each of its own
# cells and is NOT wrapped (an outer guard would hold the shared lock for the whole gate). sudo is a refusing
# tripwire; googletest comes from the local copy of the pinned commit (no download). [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-intake-cap3-86890c6a; O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/cap3; GUARD=$W/tools/build_guard/guarded_build.sh; M=49214a2b42167597e72eab67c0c37f2f501b58ab
GT=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/gtest/googletest-03597a01ee50ed33e9dfd640b249b4be3799d395
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER
export TMPDIR=/home/adam/.cache/cap3i; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
hdr() { { echo "$M"; echo "# $(date -u +%FT%TZ) df=$(df -h / | awk 'NR==2{print $4}') cmd $*"; } > "$1"; }
floor() { (( $(df --output=avail -B1M / | tail -1) >= $1 )); }
run() { local n=$1 mb=$2; shift 2; local log=$O/rerun-$n.${M:0:8}.log
  floor $mb || { echo "$n SKIPPED: disk under $mb MB"; return; }
  hdr "$log" "$@"; ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E 'PASSED|FAILED|mutation gate|survived|ok\(|/[0-9]+ ok' $log | tail -2 | tr '\n' ' ' | cut -c1-200)"; }
run build 3000 bash -c "cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=NoDebugInfo -DCMAKE_CXX_FLAGS_NODEBUGINFO=-O0 -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=$GT && cmake --build build --target test_routing_strategy ndtwin_kernel -j1"
run unit_full 1500 bash -c "build/bin/test_routing_strategy 2>&1 | tail -40"
run unit_caps 1500 bash -c "build/bin/test_routing_strategy --gtest_filter='*P4Capabilit*:*Capabilities*' 2>&1 | tail -30"
log=$O/rerun-mutate_p4_capabilities.${M:0:8}.log; if floor 1500; then hdr "$log" mutate_p4_capabilities; ( cd "$W" && JOBS=1 LOCK_WAIT=10800 bash tests/shell/mutate_p4_capabilities.sh ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"; echo "mutate_p4_capabilities $(tail -1 $log) | $(grep -E 'mutation gate' $log | tail -1)"; else echo "mutate SKIPPED: disk"; fi
run check_gate_anchors 1500 python3 tests/shell/check_gate_anchors.py 18c83aba $M
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean" || git -C "$W" status --porcelain --untracked-files=no
rm -rf "$W/build" "$TMPDIR"; echo "build dir removed; df $(df -h / | awk 'NR==2{print $4}')"; echo RERUN-DONE
