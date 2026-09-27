#!/usr/bin/env bash
# Orchestrator rerun on the test merge d3409c22 (trunk 7746832e -- protobuf 5 merged, venv migrated -- +
# feat/ndt-serve-gui-0927 fcd4f69a, tree 73fd1c85): ndt serve's suites and gates, the browser page suite
# under the guard and outside it (CI has no guard and no Chrome: it must SKIP), the anchors, the two
# static checkers. TMPDIR is short on purpose: test_claim_note_reaches_ndt_as_one_argv_element is known
# to go red under a TMPDIR past ~55 chars (queued to the peer). Through the guard, sudo/curl tripwire
# outermost on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/gui; GUARD=$W/tools/build_guard/guarded_build.sh
M=d3409c223e2ea8e772fd76b5894141379cf51ad0
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER
export TMPDIR=/home/adam/.cache/gui-intake; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.d3409c22.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran [0-9]+|OK|FAILED|mutation gate|.*cells ok|.*[0-9]+ survived)' $log | tail -2 | tr '\n' ' ')"; }
for t in test_ndt_serve test_ndt_serve_cells test_ndt_serve_gui; do run $t python3 tests/python/$t.py; done
run page_suite_guard python3 tests/browser/test_ndt_serve_page.py
log=$O/rerun-page_suite_noguard.d3409c22.log; { git -C "$W" rev-parse HEAD; echo "# outside the guard, as CI runs"; } > $log
( cd "$W" && python3 tests/browser/test_ndt_serve_page.py ) >> $log 2>&1; echo "# rc=$?" >> $log
echo "page_suite_noguard $(tail -1 $log) | $(grep -E '^(Ran|OK|FAILED)' $log | tr '\n' ' ')"
run mutate_ndt_serve bash tests/shell/mutate_ndt_serve.sh
run mutate_ndt_serve_page bash tests/shell/mutate_ndt_serve_page.sh
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
run check_process_by_name python3 tests/shell/check_process_by_name.py tests/browser/test_ndt_serve_page.py tests/shell/mutate_ndt_serve_page.sh tests/python/test_ndt_serve_gui.py
run check_test_tmpdirs python3 tests/shell/check_test_tmpdirs.py tests/browser/test_ndt_serve_page.py tests/shell/mutate_ndt_serve_page.sh tests/python/test_ndt_serve_gui.py
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
ps -eo pid,args | grep -iE 'chrom|ndt_serve|serve\.py' | grep -v grep | head -5; echo "(above: leftover chrome/serve processes, if any)"
rm -rf "$TMPDIR"; echo RERUN-GUI-DONE
