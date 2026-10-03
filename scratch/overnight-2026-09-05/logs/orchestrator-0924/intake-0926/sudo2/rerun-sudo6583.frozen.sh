#!/usr/bin/env bash
# Orchestrator rerun of sudo probe 6583c089 (trunk 9ef10250 is its ancestor, so the head is the test merge).
# One guard call per cell, sudo/curl tripwire first on PATH, own TMPDIR. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-intake-sudo-6583c089; O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/sudo2; GUARD=$W/tools/build_guard/guarded_build.sh; M=7b4a48b9a
M=$(git -C "$W" rev-parse HEAD); [[ "$M" == 6583c089e72fd028d0fcb1939af1efe2450b5c8d ]] || { echo "REFUSE: HEAD moved ($M)"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER KERNEL_DIR
export TMPDIR=/home/adam/.cache/sudoi; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.${M:0:8}.log
  (( $(df --output=avail -B1M / | tail -1) >= 1500 )) || { echo "$n SKIPPED: disk under 1.5 GB"; return; }
  { echo "$M"; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E 'Ran [0-9]+|survived|mutation gate|checks, [0-9]+ failed|ok\b.*/|ANCHOR|rc 0|FAILED' $log | tail -2 | tr '\n' ' ' | cut -c1-220)"; }
run test_ndt_sudo_surface bash tests/shell/test_ndt_sudo_surface.sh
run test_ndt_status_check_baseline bash tests/shell/test_ndt_status_check_baseline.sh
run mutate_ndt_sudo_surface bash tests/shell/mutate_ndt_sudo_surface.sh
run test_known_issues_references bash -c "p4_proxy/venv/bin/python tests/python/test_known_issues_references.py"
run test_l1_shell_scoring bash tests/shell/test_l1_shell_scoring.sh
run check_gate_anchors python3 tests/shell/check_gate_anchors.py 9ef10250 $M
run check_test_tmpdirs python3 tests/shell/check_test_tmpdirs.py
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean" || git -C "$W" status --porcelain --untracked-files=no
rm -rf "$TMPDIR"; echo RERUN-DONE
