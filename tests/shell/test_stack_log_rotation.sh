#!/usr/bin/env bash
#
# How many generations of a component log survive a restart, and who is allowed to delete them?
#
# [Co-developed with claude code -- Adam]
#
# 09-05 night round, O-4. start_bg kept two generations, .prev and .prev2, a depth chosen for a
# debugging loop ("restart, it recurred, restart again" -- KNOWN-ISSUES A-5). A night of
# experiments is a different shape: seven `ndt up`s ran in one checkout inside three hours, and
# the kernel.log that five fix tickets (W1/W4/W5/W6/W7) were judged on had already become the
# .prev twenty minutes after it was written. It survived only because it was copied by hand at
# 15:53. Later the same evening one arm wrote 151557 lines / 2.78 MB in eleven minutes, so a
# single rotation would have buried a whole load test.
#
# The finding's second half is why it kept happening: with no up.target `ndt status` advised
# "bring the lab up from this checkout first", and following that advice is what rotated the
# log. The instrument recommended the action that destroyed the evidence.
#
# 🔴 THREE DIRECTIONS, because "keep more" has wrong answers that look like fixes:
#   * a rotation that never prunes fills the disk and is not a rotation (group 3B);
#   * a rotation that prunes by mtime drops the wrong generation the moment anyone greps,
#     copies or opens one -- so the order is taken from the stamp, which is the era's own start
#     time (3B seeds out-of-order mtimes on purpose);
#   * a pruner that deletes everything beside the log deletes evidence this scheme did not
#     create and does not own (3D).
#
# Offline. RUN_DIR/LOG_DIR/PID_DIR are redirected into a temp dir, `setsid` is stubbed so
# nothing is ever spawned, and no component is started. No lab, no sudo, no port -- the lab was
# in use the night this was written.
#
# Env:  STACK_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_stack_log_rotation.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${STACK_UNDER_TEST:-$HERE/../../tools/test_workflow/stack.sh}"
[[ -r "$STACK" ]] || { echo "no stack.sh at $STACK"; exit 2; }
# stack.sh sources components.env from beside itself; a copy without it dies at source time and
# every case below goes red for a reason that has nothing to do with the subject.
[[ -r "$(dirname "$STACK")/components.env" ]] \
    || { echo "stack.sh needs components.env beside it; not at $(dirname "$STACK")/components.env"; exit 2; }

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/stack-rot-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/logs" "$FIX/pids"
LOG="$FIX/logs/kernel.log"

# --- the seam -----------------------------------------------------------------------------
# stack.sh returns at its own source seam. The run directories are redirected before sourcing
# (components.env assigns them with `: "${VAR:=...}"`, so an exported value wins), and setsid is
# replaced by a no-op so start_bg's wiring can be driven without spawning anything at all.
run() {   # <shell code, run with stack.sh sourced>
    RUN_DIR="$FIX" LOG_DIR="$FIX/logs" PID_DIR="$FIX/pids" \
    bash -c "source '$STACK' >/dev/null 2>&1
setsid() { :; }
warn() { :; }
info() { :; }
$1" 2>&1
}

# Generations, named the way rotate_log names them, with mtimes in a DELIBERATELY WRONG order:
# the oldest stamp is touched last. A pruner that sorts by mtime keeps this one and drops the
# newest era, which is the failure mode the stamp exists to remove.
seed() {   # <stamp>...  -- oldest stamp first
    local s i
    for s in "$@"; do printf 'era %s\n' "$s" > "$LOG.$s"; done
    # Touched in REVERSE, so mtime order is the exact inverse of era order. Under `ls -t` the
    # oldest era now looks like the newest file, which is what makes 3B able to tell a pruner
    # that reads the stamp from one that reads the clock.
    for (( i = $#; i >= 1; i-- )); do touch "$LOG.${!i}"; sleep 0.01; done
}
gens() { ls -1 "$LOG".[0-9]* 2>/dev/null | wc -l; }
newest() { ls -1 "$LOG".[0-9]* 2>/dev/null | LC_ALL=C sort -r | head -1; }
reset_fix() { rm -f "$LOG" "$LOG".* ; }

# ==========================================================================================
section "3A. a rotation names the generation by the era's own start time"
reset_fix
printf 'era one\n' > "$LOG"
run 'rotate_log "'"$LOG"'"' >/dev/null
check "the live log is moved aside, not left in place" "gone" \
      "$( [[ -e "$LOG" ]] && echo present || echo gone )"
check "  exactly one generation exists"                "1" "$(gens)"
check "  it is stamped YYYYmmdd-HHMMSS"                "yes" \
      "$( [[ "$(basename "$(newest)")" =~ ^kernel\.log\.[0-9]{8}-[0-9]{6}$ ]] && echo yes || echo no )"
check "  and it holds what the log held"               "era one" "$(cat "$(newest)")"

section "3B. 🔴 five generations, not two -- and the newest five, by era, not by mtime"
reset_fix
seed 20260901-000001 20260901-000002 20260901-000003 20260901-000004 \
     20260901-000005 20260901-000006 20260901-000007
printf 'era eight\n' > "$LOG"
run 'rotate_log "'"$LOG"'"' >/dev/null
check "eight generations are pruned to five"           "5" "$(gens)"
check "  the era just rotated is kept"                 "era eight" "$(cat "$(newest)")"
check "  the 4th-oldest is kept"                       "present" \
      "$( [[ -e "$LOG.20260901-000004" ]] && echo present || echo gone )"
check "🔴 the oldest era is gone"                      "gone" \
      "$( [[ -e "$LOG.20260901-000001" ]] && echo present || echo gone )"
check "  and so is the second oldest"                  "gone" \
      "$( [[ -e "$LOG.20260901-000002" ]] && echo present || echo gone )"
check "🔴 the newest seeded era survives (mtime says it is the oldest)" "present" \
      "$( [[ -e "$LOG.20260901-000007" ]] && echo present || echo gone )"

section "3C. NDT_LOG_KEEP sets the depth, and cannot set it to zero"
reset_fix
seed 20260901-000001 20260901-000002 20260901-000003 20260901-000004
printf 'era five\n' > "$LOG"
NDT_LOG_KEEP=2 run 'rotate_log "'"$LOG"'"' >/dev/null
check "NDT_LOG_KEEP=2 keeps two"                       "2" "$(gens)"
reset_fix
seed 20260901-000001 20260901-000002 20260901-000003 20260901-000004 20260901-000005 20260901-000006
printf 'era seven\n' > "$LOG"
NDT_LOG_KEEP=0 run 'rotate_log "'"$LOG"'"' >/dev/null
check "🔴 NDT_LOG_KEEP=0 falls back to five, not to none" "5" "$(gens)"
reset_fix
seed 20260901-000001 20260901-000002 20260901-000003 20260901-000004 20260901-000005 20260901-000006
printf 'era seven\n' > "$LOG"
NDT_LOG_KEEP=nonsense run 'rotate_log "'"$LOG"'"' >/dev/null
check "  and so does a value that is not a number"     "5" "$(gens)"

section "3D. 🔴 it prunes only what it created"
reset_fix
printf 'old scheme\n' > "$LOG.prev"
printf 'older scheme\n' > "$LOG.prev2"
printf 'someone kept this\n' > "$LOG.keepme"
printf 'ryu\n' > "$FIX/logs/ryu.log"
seed 20260901-000001 20260901-000002
printf 'era three\n' > "$LOG"
NDT_LOG_KEEP=1 run 'rotate_log "'"$LOG"'"' >/dev/null
check "one stamped generation is left"                 "1" "$(gens)"
check "🔴 a .prev from the old scheme is not swept up" "old scheme" "$(cat "$LOG.prev" 2>/dev/null)"
check "🔴 nor .prev2"                                  "older scheme" "$(cat "$LOG.prev2" 2>/dev/null)"
check "🔴 nor a file somebody parked beside it"        "someone kept this" "$(cat "$LOG.keepme" 2>/dev/null)"
check "🔴 and another component's log is untouched"    "ryu" "$(cat "$FIX/logs/ryu.log" 2>/dev/null)"

section "3E. 🔴 two restarts inside one second do not overwrite each other"
reset_fix
printf 'first\n' > "$LOG"
run 'rotate_log "'"$LOG"'"; printf "second\n" > "'"$LOG"'"; rotate_log "'"$LOG"'"' >/dev/null
check "both generations exist"                         "2" "$(gens)"
check "  and both eras are readable"                   "first second" \
      "$(cat $(ls -1 "$LOG".[0-9]* | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')"

section "3F. 🔴 the wiring: start_bg rotates -- a rotator nothing calls keeps nothing"
# Driven through start_bg itself, far enough to reach the rotation and no further: setsid is a
# no-op, so nothing is spawned and the component is never started.
reset_fix
rm -f "$FIX/pids/fixture.pid"
printf 'the era before the restart\n' > "$LOG"
run 'start_bg fixture "'"$LOG"'" /bin/true' >/dev/null
check "start_bg left a stamped generation behind"      "1" "$(gens)"
check "  holding the era that was running before it"   "the era before the restart" "$(cat "$(newest)")"
check "  named by its start time, not .prev"           "gone" \
      "$( [[ -e "$LOG.prev" ]] && echo present || echo gone )"

# --- done ---------------------------------------------------------------------------------
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
