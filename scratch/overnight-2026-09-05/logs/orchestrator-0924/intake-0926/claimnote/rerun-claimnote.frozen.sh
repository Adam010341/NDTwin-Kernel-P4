#!/usr/bin/env bash
# Orchestrator rerun on the test merge 6ee2451e (trunk f186ce98 + fix/ndt-serve-claim-note-tmpdir-0927 c0411e16,
# tree 4ed9641e = the branch's tree). The subject: test_claim_note_reaches_ndt_as_one_argv_element must be green
# under a LONG TMPDIR (105 chars, red on f186ce98 per the peer) and a short one; the three ndt serve suites;
# mutate_ndt_serve (M17 is the mutant this case kills) and the page gate (it hashes this file); anchors and the
# two static checkers. Through the guard, sudo/curl tripwire first on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/claimnote; GUARD=$W/tools/build_guard/guarded_build.sh
M=6ee2451e81098ad08cfe77ea1ab250260b5e94b7
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER
SHORT=/home/adam/.cache/cn-s
LONG=/home/adam/.cache/claim-note-intake-a-deliberately-long-temporary-directory-name-to-pass-fifty-five-chars-xxxxxxxxxx
echo "LONG is ${#LONG} chars, SHORT is ${#SHORT} chars"
run() { local n=$1 td=$2; shift 2; local log=$O/rerun-$n.6ee2451e.log
  rm -rf "$td"; mkdir -p "$td"
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) TMPDIR=$td (${#td}) cmd $*"; } > "$log"
  ( cd "$W" && TMPDIR="$td" JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran [0-9]+|OK|FAILED)|survivor|cells ok|test_claim_note' $log | tail -3 | tr '\n' ' ')"; }
run test_ndt_serve_LONG "$LONG" python3 tests/python/test_ndt_serve.py -v
run test_ndt_serve_SHORT "$SHORT" python3 tests/python/test_ndt_serve.py -v
run test_ndt_serve_cells "$SHORT" python3 tests/python/test_ndt_serve_cells.py
run test_ndt_serve_gui "$SHORT" python3 tests/python/test_ndt_serve_gui.py
run mutate_ndt_serve "$SHORT" bash tests/shell/mutate_ndt_serve.sh
run mutate_ndt_serve_page "$SHORT" bash tests/shell/mutate_ndt_serve_page.sh
run check_gate_anchors "$SHORT" python3 tests/shell/check_gate_anchors.py $M
run check_process_by_name "$SHORT" python3 tests/shell/check_process_by_name.py tests/python/test_ndt_serve.py
run check_test_tmpdirs "$SHORT" python3 tests/shell/check_test_tmpdirs.py tests/python/test_ndt_serve.py
grep -E 'M17' $O/rerun-mutate_ndt_serve.6ee2451e.log | head -3
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
ps -eo pid,args | grep -E 'ndt_serve|serve\.py|headless' | grep -v -e grep -e claude | head -5; echo "(above: leftover serve/headless processes, if any)"
rm -rf "$SHORT" "$LONG"; echo RERUN-CLAIMNOTE-DONE
