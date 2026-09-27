#!/usr/bin/env bash
# Orchestrator rerun on the test merge e5d0e024 (trunk 7746832e + fix/queued-notes-0927 bbb9fd41, tree d82a79be),
# in its own intake worktree: the suites and gates the branch changed, plus one red arm of my own --
#   NOTE A: delete test_ndt_ovs_topo_script.sh's final 'summary' call (:305) in this worktree; group C must go
#   red naming that suite (it was vacuously green at b005bf50, per the stale judge's check 1); restore after.
# Through the guard, sudo/curl tripwire outermost on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-queued-intake-0927
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/queued; GUARD=$W/tools/build_guard/guarded_build.sh
M=e5d0e024903d7cb23b35ca76d0fb402620b7c3b1
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_SAMPLING_RAW_DIR
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-queued; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.e5d0e024.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '(Ran [0-9]+|mutation|survivor|killed|cells ok|SKIP|OK$|FAILED)' $log | tail -2 | tr '\n' ' ')"; }
# red arm (NOTE A)
F=$W/tests/shell/test_ndt_ovs_topo_script.sh; cp "$F" "$TMPDIR/topo.orig"
[[ "$(sed -n 305p "$F")" == summary ]] || { echo "REFUSE: :305 is not the summary call"; exit 2; }
sed -i '305d' "$F"
run NOTEA_topo305_deleted bash tests/shell/test_l1_shell_scoring.sh
cp "$TMPDIR/topo.orig" "$F"; git -C "$W" diff --quiet -- tests/shell/test_ndt_ovs_topo_script.sh && echo "topo_script restored"
grep -E 'test_ndt_ovs_topo_script' $O/rerun-NOTEA_topo305_deleted.e5d0e024.log | head -3
# the branch's suites and gates
for s in test_l1_shell_scoring test_gate_exit_code_not_tee test_ndt_sudo_surface          test_apps_stop_kills_the_group test_cell_gate_suspect_wiring test_lab_handoff test_ndt_app_orphans test_ndt_honesty test_ndt_sample_rate_reads_both_bounds; do
  run $s bash tests/shell/$s.sh
done
for g in mutate_l1_shell_scoring mutate_gate_exit_code mutate_probe_stubs mutate_ndt_sudo_surface; do run $g bash tests/shell/$g.sh; done
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"; cat "$SH/tripwire.log" | head -5
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
echo RERUN-QUEUED-DONE
