#!/usr/bin/env bash
# Orchestrator rerun of CI-L1 ca233796 on the test merge onto trunk 149c8234.
# One guard call per cell, sudo/curl tripwire first on PATH, own TMPDIR. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-intake-cil1-ca233796; O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/cil1; GUARD=$W/tools/build_guard/guarded_build.sh; M=7b4a48b9a
M=$(git -C "$W" rev-parse HEAD); [[ "$M" == add20e879e7af3b61dcdb65ce8196f9f752b7616 ]] || { echo "REFUSE: HEAD moved ($M)"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER KERNEL_DIR
export TMPDIR=/home/adam/.cache/cil1i; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.${M:0:8}.log
  (( $(df --output=avail -B1M / | tail -1) >= 1500 )) || { echo "$n SKIPPED: disk under 1.5 GB"; return; }
  { echo "$M"; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E 'Ran [0-9]+|survived|mutation gate|checks, [0-9]+ failed|ok\b.*/|ANCHOR|rc 0|FAILED' $log | tail -2 | tr '\n' ' ' | cut -c1-220)"; }
run test_l1_shell_scoring bash tests/shell/test_l1_shell_scoring.sh
run mutate_l1_shell_scoring bash tests/shell/mutate_l1_shell_scoring.sh
run test_ndt_ovs_topo_script bash tests/shell/test_ndt_ovs_topo_script.sh
run test_grpc_port_block bash -c "p4_proxy/venv/bin/python tests/python/test_grpc_port_block.py"
run test_ovs4_sflow bash -c "p4_proxy/venv/bin/python tests/python/test_ovs4_sflow.py"
run p4_route_binding_lab bash -c "cd p4_proxy && venv/bin/python tests/test_route_binding.py"
run p4_fabric_bring_up_lab bash -c "cd p4_proxy && venv/bin/python tests/test_fabric_bring_up.py"
run check_gate_anchors python3 tests/shell/check_gate_anchors.py 149c8234 $M
run check_test_tmpdirs python3 tests/shell/check_test_tmpdirs.py
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean" || git -C "$W" status --porcelain --untracked-files=no
rm -rf "$TMPDIR"; echo RERUN-DONE
