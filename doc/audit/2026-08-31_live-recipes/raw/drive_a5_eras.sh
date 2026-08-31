#!/usr/bin/env bash
# A-5 live recipe driver: three kernel eras via two restarts.
# Recipe source: doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md section 6.
# Verbatim recipe is:
#   ndt up p4                      # era 1
#   ndt down && ndt up p4          # era 2
#   ndt down && ndt up p4          # era 3
# ndt up/down kill the calling shell (exit 144), so this whole script runs under setsid and
# every verdict is taken from the log's "up. ready" marker, never from a return code.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
export NDT_OWNER=live-recipes
R=doc/audit/2026-08-31_live-recipes/raw
L=.test_run/logs/kernel.log

note() { printf '\n===== %s =====\n' "$*"; }

note "ERA 1: ndt up p4"
tools/test_workflow/ndt up p4 2>&1 || echo "(rc=$? -- ignored by design, verdict is the ready marker)"
note "ERA 1 state"
ls -l $L* 2>/dev/null
head -1 $L > $R/era1_firstline.txt 2>/dev/null
echo "era1 first line: $(cat $R/era1_firstline.txt 2>/dev/null)"

note "ERA 2: ndt down && ndt up p4"
tools/test_workflow/ndt down 2>&1 || echo "(down rc=$? -- ignored)"
tools/test_workflow/ndt up p4 2>&1 || echo "(rc=$? -- ignored)"
note "ERA 2 state"
ls -l $L* 2>/dev/null
head -1 $L > $R/era2_firstline.txt 2>/dev/null
echo "era2 first line: $(cat $R/era2_firstline.txt 2>/dev/null)"

note "ERA 3: ndt down && ndt up p4"
tools/test_workflow/ndt down 2>&1 || echo "(down rc=$? -- ignored)"
tools/test_workflow/ndt up p4 2>&1 || echo "(rc=$? -- ignored)"
note "ERA 3 state"
ls -l $L* 2>/dev/null
head -1 $L > $R/era3_firstline.txt 2>/dev/null
echo "era3 first line: $(cat $R/era3_firstline.txt 2>/dev/null)"

note "A-5 ASSERTIONS"
echo "--- three generations readable? ---"
for f in $L $L.prev $L.prev2; do
    if [[ -r "$f" ]]; then echo "READABLE $f ($(stat -c %s "$f") bytes)"; else echo "MISSING  $f"; fi
done
echo "--- .prev3 must NOT exist (bounded disk) ---"
if [[ -e "$L.prev3" ]]; then echo "FAIL: $L.prev3 EXISTS"; else echo "OK: no $L.prev3"; fi
echo "--- head -1 of each generation ---"
echo "kernel.log        : $(head -1 $L 2>/dev/null)"
echo "kernel.log.prev   : $(head -1 $L.prev 2>/dev/null)"
echo "kernel.log.prev2  : $(head -1 $L.prev2 2>/dev/null)"
note "DONE"
