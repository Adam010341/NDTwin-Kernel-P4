#!/usr/bin/env bash
# Orchestrator rerun of N7 on 7b4a48b9 (a fast-forward of trunk fed37cff, so the test merge is the head itself).
# One guard call per cell, sudo/curl tripwire first on PATH, own TMPDIR. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-intake-n7-7b4a48b9; O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/n7; GUARD=$W/tools/build_guard/guarded_build.sh; M=7b4a48b9a
M=$(git -C "$W" rev-parse HEAD); [[ "$M" == 7b4a48b9* ]] || { echo "REFUSE: HEAD moved ($M)"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER KERNEL_DIR
export TMPDIR=/home/adam/.cache/n7i; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
MAINSHA_BEFORE=$(sha256sum $R/doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env $R/doc/audit/2026-08-31_f5-fine-grid-round/round.env | sha256sum)
run() { local n=$1; shift; local log=$O/rerun-$n.${M:0:8}.log
  (( $(df --output=avail -B1M / | tail -1) >= 1500 )) || { echo "$n SKIPPED: disk under 1.5 GB"; return; }
  { echo "$M"; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E 'Ran [0-9]+|survived|mutation gate|checks, [0-9]+ failed|ok\b.*/|ANCHOR|rc 0|FAILED' $log | tail -2 | tr '\n' ' ' | cut -c1-220)"; }
run suite_head bash tests/shell/test_round_env_kernel_dir.sh
run suite_base_redfirst env E_ROUND_ENV_UNDER_TEST=$O/base-env/e.env F5_ROUND_ENV_UNDER_TEST=$O/base-env/f.env bash tests/shell/test_round_env_kernel_dir.sh
run mutate_round_env_kernel_dir bash tests/shell/mutate_round_env_kernel_dir.sh
run test_gate_exit_code_not_tee bash tests/shell/test_gate_exit_code_not_tee.sh
run test_cell_gate_suspect_wiring bash tests/shell/test_cell_gate_suspect_wiring.sh
run mutate_gate_exit_code bash tests/shell/mutate_gate_exit_code.sh
run mutate_cell_gate_suspect_wiring bash tests/shell/mutate_cell_gate_suspect_wiring.sh
run mutate_log_suffix_idempotent bash tests/shell/mutate_log_suffix_idempotent.sh
run check_gate_anchors python3 tests/shell/check_gate_anchors.py fed37cff $M
run check_process_by_name python3 tests/shell/check_process_by_name.py
run check_test_tmpdirs python3 tests/shell/check_test_tmpdirs.py
MAINSHA_AFTER=$(sha256sum $R/doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env $R/doc/audit/2026-08-31_f5-fine-grid-round/round.env | sha256sum)
[[ "$MAINSHA_BEFORE" == "$MAINSHA_AFTER" ]] && echo "main checkout round.env unchanged" || echo "🔴 main checkout round.env CHANGED"
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean" || git -C "$W" status --porcelain --untracked-files=no
rm -rf "$TMPDIR"; echo RERUN-DONE
