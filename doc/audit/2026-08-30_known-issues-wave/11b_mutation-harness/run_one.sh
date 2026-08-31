#!/usr/bin/env bash
# One mutation, six steps, no exceptions:
#   restore-clean -> apply -> assert-on-disk -> rebuild -> run FULL filter
#   -> classify -> restore -> REBUILD -> assert 46/46
#
# RESTORE IS AN ATOMIC, SHA256-VERIFIED COPY FROM pristine/, NOT `git checkout --`, NOT `cp`.
#  - `git checkout -- <file>` restores from the INDEX; the fix is UNSTAGED, so it reverts to
#    1208d22 and deletes the fix. It did exactly that once during bring-up (recovered
#    byte-for-byte; see 11b §1.1).
#  - plain `cp` truncates in place, and the root filesystem is oscillating at 100% -- another
#    agent's `cp` produced a 0-byte file under it. restore.py writes a temp, fsyncs, checks
#    size AND sha256, then os.replace()s.
# Every restore is then double-witnessed: sha256 (restore.py) and git's blob hash (below).
set -u
set -o pipefail

MID="$1"
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/258e9ef7-6035-4abb-b378-8b2ab1aa8200/scratchpad/mutrun
W=/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a2c2a6601f812a7eb
# The build tree lives in tmpfs: the root filesystem hit 100% (6.7 MB free on 98 GB) during
# this run, and a 170 MB relink cannot happen there. Sources are still read from, and mutated
# in, the worktree on disk -- only the object files and the binary are in RAM.
B=/dev/shm/ndtmut/build
BIN="$B/bin/test_routing_strategy"
FILTER='P4PowerStrategyTest.*:RoutingStrategyFixture.*:RequestDeadlines.*'
L="$S/logs"
PY=python3

say() { printf '### %s\n' "$*"; }

# ---------- pre-flight: stop flag, and the root filesystem ----------------
# The root partition has been oscillating at 100%. Another agent's `cp` truncated a file to
# 0 bytes under it. Every source write below lands on that filesystem, so a short write is a
# live hazard, not a hypothetical -- refuse to start a row without headroom.
if [ -f "$S/STOP" ]; then
  echo "STOP flag present -- not starting $MID"
  exit 34
fi
AVAIL_KB=$(df --output=avail / | tail -1)
echo "root free: ${AVAIL_KB} KB"
if [ "$AVAIL_KB" -lt 524288 ]; then
  echo "ROOT-FILESYSTEM-TOO-FULL (${AVAIL_KB} KB < 512 MB) -- refusing to run $MID"
  exit 33
fi

restore_pristine() {
  # atomic write + sha256 verify per file (restore.py); then a SECOND, independent witness
  # using git's blob hash, so one hash implementation cannot vouch for itself.
  $PY "$S/restore.py" || return 1
  local bad=0
  while read -r h f flat; do
    local now
    now=$(git -C "$W" hash-object "$f")
    if [ "$now" != "$h" ]; then
      echo "RESTORE-BLOBHASH-MISMATCH $f got=$now want=$h"
      bad=1
    fi
  done < "$S/pristine/HASHES"
  return $bad
}

# ---------- 0. clean start (hash-verified) --------------------------------
restore_pristine > "$L/$MID.restore0.log" 2>&1 || { cat "$L/$MID.restore0.log"; exit 9; }

# ---------- 1. apply ------------------------------------------------------
say "$MID step1 apply"
$PY "$S/mutations.py" apply "$MID" > "$L/$MID.apply.log" 2>&1
APPLY_RC=$?
cat "$L/$MID.apply.log"
if [ "$APPLY_RC" -ne 0 ]; then
  echo "VERDICT $MID SKIP-NOT-APPLIED (apply rc=$APPLY_RC) -- NOT a pass, NOT a failure"
  restore_pristine
  exit 20
fi

# ---------- 2. assert the mutation text is on disk ------------------------
say "$MID step2 disk assertion"
$PY "$S/mutations.py" assert "$MID" > "$L/$MID.diskassert.log" 2>&1
DA_RC=$?
cat "$L/$MID.diskassert.log"
if [ "$DA_RC" -ne 0 ]; then
  echo "VERDICT $MID SKIP-NOT-ON-DISK (assert rc=$DA_RC) -- NOT a pass, NOT a failure"
  restore_pristine
  exit 21
fi
# second, independent witness: the mutant marker must be greppable on disk
say "$MID grep witness"
grep -rn "MUTANT_$MID" $(for f in $($PY "$S/mutations.py" files "$MID"); do echo "$W/$f"; done) \
  | tee "$L/$MID.grep.log" | sed 's/^/    /'
GREP_HITS=$(wc -l < "$L/$MID.grep.log")
echo "grep witness hits=$GREP_HITS"
if [ "$GREP_HITS" -lt 1 ]; then
  echo "VERDICT $MID SKIP-NO-GREP-WITNESS -- NOT a pass, NOT a failure"
  restore_pristine
  exit 22
fi

# ---------- 3. rebuild ----------------------------------------------------
say "$MID step3 rebuild"
cmake --build "$B" -j8 --target test_routing_strategy > "$L/$MID.build.log" 2>&1
BUILD_RC=$?
echo "build rc=$BUILD_RC"
[ "$BUILD_RC" -ne 0 ] && grep -E "error:|Error" "$L/$MID.build.log" | head -20

# ---------- 4. run the FULL filter ----------------------------------------
say "$MID step4 run"
if [ "$BUILD_RC" -eq 0 ]; then
  "$BIN" --gtest_filter="$FILTER" > "$L/$MID.test.log" 2>&1
  TEST_RC=$?
else
  : > "$L/$MID.test.log"
  TEST_RC=-1
fi
echo "test rc=$TEST_RC"

# ---------- 5. classify ---------------------------------------------------
PRED=$($PY "$S/mutations.py" predicted "$MID" | paste -sd, -)
$PY "$S/classify.py" "$MID" "$BUILD_RC" "$TEST_RC" "$L/$MID.test.log" "$PRED" | tee "$L/$MID.verdict.json"

# ---------- 6. restore (hash-verified) ------------------------------------
say "$MID step6 restore"
if restore_pristine; then echo "RESTORE-HASHES-OK"; else echo "RESTORE-HASHES-BAD -- STOPPING"; exit 31; fi
# and the mutant text must be gone from disk
if grep -rq "MUTANT_$MID" $(for f in $($PY "$S/mutations.py" files "$MID"); do echo "$W/$f"; done); then
  echo "MUTANT TEXT STILL ON DISK AFTER RESTORE -- STOPPING"; exit 32
fi
echo "mutant-text-gone OK"

# ---------- 7. REBUILD after restore, then assert the 46/46 baseline ------
say "$MID step7 rebuild after restore"
cmake --build "$B" -j8 --target test_routing_strategy > "$L/$MID.rebuild.log" 2>&1
RB_RC=$?
echo "restore-build rc=$RB_RC"
[ "$RB_RC" -ne 0 ] && grep -E "error:" "$L/$MID.rebuild.log" | head -20

"$BIN" --gtest_filter="$FILTER" > "$L/$MID.baseline.log" 2>&1
BL_RC=$?
BL_RAN=$(grep -cE '^\[=+\] 46 tests from 3 test suites ran\.' "$L/$MID.baseline.log")
BL_PASS=$(grep -cE '^\[  PASSED  \] 46 tests\.' "$L/$MID.baseline.log")
echo "baseline rc=$BL_RC ran46=$BL_RAN passed46=$BL_PASS"
if [ "$RB_RC" -eq 0 ] && [ "$BL_RC" -eq 0 ] && [ "$BL_RAN" -eq 1 ] && [ "$BL_PASS" -eq 1 ]; then
  echo "BASELINE-RESTORED $MID OK"
else
  echo "BASELINE-RESTORED $MID *** FAILED *** -- STOPPING"
  exit 30
fi
exit 0
