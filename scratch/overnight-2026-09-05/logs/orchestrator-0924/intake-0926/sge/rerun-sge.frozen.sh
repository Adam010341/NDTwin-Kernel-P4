#!/usr/bin/env bash
# Orchestrator rerun on the test merge 17fbdd7f (trunk 8746c1bc + d271f5b8): test_build_guard red at trunk
# and green at the merge, both UNDER the guard (the gate environment), plus reentrant and the mutation gate.
# [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/sge; GUARD=$W/tools/build_guard/guarded_build.sh
[[ "$(git -C "$W" rev-parse HEAD)" == 17fbdd7fb0861df9bb0f4be03ada7ab47158dc1c ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-sge; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.17fbdd7f.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '(checks|failed|mutations|survived)' $log | tail -1)"; }
git -C "$W" show 8746c1bc:tests/shell/test_build_guard.sh > "$W/tests/shell/.redfirst-sge-test_build_guard.sh"
run test_build_guard_TRUNK_expect_red bash tests/shell/.redfirst-sge-test_build_guard.sh
rm -f "$W/tests/shell/.redfirst-sge-test_build_guard.sh"
run test_build_guard bash tests/shell/test_build_guard.sh
run test_guarded_build_reentrant bash tests/shell/test_guarded_build_reentrant.sh
run mutate_build_guard bash tests/shell/mutate_build_guard.sh
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=all -- tests/)" ]] && echo "tests/ clean after the gates" || git -C "$W" status --porcelain --untracked-files=all -- tests/
echo RERUN-SGE-DONE
