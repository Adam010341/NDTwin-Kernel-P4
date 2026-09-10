#!/usr/bin/env bash
#
# guarded_build.sh -- run anything that builds, without taking the machine down with it.
#
# WHY THIS EXISTS
# On 2026-09-02 a `-j6` build on this 14-core / 15 GB laptop was killed by systemd-oomd, and
# oomd took the user's own running application with it. 23 call sites in this repo hardcode
# `-j$(nproc)` (= -j14 here) or `-j4`; several of them are mutation-gate anchors that
# tools/.../check_gate_anchors.py parses, so editing them would move the anchors and quietly
# stop those gates from checking anything. A PATH shim needs no edit at any call site.
#
# THREE GUARDS, EACH FOR A DIFFERENT FAILURE
#   1. PATH shims  -- cap parallelism, whatever -j the caller hardcoded.
#   2. flock       -- one build at a time. Two capped builds still add up. RE-ENTRANT: see below.
#   3. a cgroup    -- an explicit MemoryMax so the kernel kills THIS build rather than letting
#                     oomd choose a victim by its own heuristic. This is the guard that
#                     protects the user's application, and the only one that survives a build
#                     step that ignores -j entirely (a vendored script, a recursive make).
#
# USAGE
#   tools/build_guard/guarded_build.sh cmake --build build --target test_routing_strategy
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_bx_flow_liveness.sh
#   JOBS=3 MEM_HIGH=4G MEM_MAX=6G tools/build_guard/guarded_build.sh ninja -C build
#
# RE-ENTRANCY (2026-09-11)
# Most mutation gates in tests/shell call this script themselves, once per build. Wrapping such
# a gate in an outer guard used to deadlock: the outer layer holds $LOCK, the inner layer opens
# its own fd on the same file and waits out the whole LOCK_WAIT, and the gate reports the
# resulting rc 2 as "the mutant does not compile". It cost 3 hours on 2026-09-04 and 9 minutes
# (with every mutation INVALID) on 2026-09-10. So this script now remembers which locks the
# process tree it is in already holds, in NDTWIN_GUARD_HELD, and nests inside them: no second
# flock and no second cgroup scope, because the caller's scope already contains us and
# MemoryHigh is inherited. A DIFFERENT $LOCK is still taken normally -- the point of guard 2 is
# that two builds do not run at once, and only the lock we ourselves hold is safe to skip.
# The claim is true only while the ancestor that exported it is alive (it is the one holding
# fd 9), which normally follows from its descendants living in the scope it created. See
# README.md §2026-09-11 for the one gap -- a SIGKILLed NO_CGROUP=1 outer guard with an orphaned
# child -- which this does not detect.
#
# ENV
#   JOBS      parallel jobs the shims force            (default 2)
#   MEM_HIGH  MemoryHigh for the build's own cgroup    (default 3G) -- throttle+reclaim itself first
#   MEM_MAX   MemoryMax for the build's own cgroup     (default 4G)
#   LOCK      lock file, i.e. what counts as "a build" (default /tmp/ndtwin-build.lock)
#   NO_CGROUP=1  skip guard 3 (use only where systemd --user is unavailable; SAY SO in the log)
#   NDTWIN_GUARD_HELD  set BY this script, ':'-separated: the locks already held above us. Not
#                      something to set by hand -- doing so tells the guard it holds a lock it
#                      does not, which is exactly the parallel build guard 2 exists to prevent.
#
# Exit: the wrapped command's exit code. 124 = the wrapped command timed out (TIMEOUT env).
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/shims"

[[ $# -gt 0 ]] || { sed -n '/^# USAGE/,/^# ENV/p' "${BASH_SOURCE[0]}" >&2; exit 2; }

JOBS="${JOBS:-2}"
# 2026-09-03 17:50: a build under this guard with MemoryMax=5G still got the desktop app killed.
# MemoryMax bounds the build's OWN usage; it does nothing about the pressure the build puts on
# the whole user slice before it reaches that bound, and systemd-oomd (limit 50% on
# user@1000.service) then kills the child cgroup with the most reclaim -- which was the app.
# MemoryHigh makes the build's cgroup throttle and reclaim ITSELF first, so both the pressure
# and the pgscan land on this scope and oomd's victim is the build, not the user's application.
MEM_HIGH="${MEM_HIGH:-3G}"
MEM_MAX="${MEM_MAX:-4G}"
LOCK="${LOCK:-/tmp/ndtwin-build.lock}"
TIMEOUT="${TIMEOUT:-}"

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "guarded_build: JOBS must be a positive integer, got '$JOBS'" >&2; exit 2; }

# NDTWIN_GUARD_HELD is a LIST, not the last lock taken. Keeping only the most recent one loses
# the outer entry as soon as a nested call uses a different lock, and then a third level asking
# for the outermost lock is the 09-04 deadlock again. ':' is the separator, so a lock path
# containing one is refused rather than silently splitting into two entries -- one of which
# might match some other lock and skip a flock that was needed.
[[ "$LOCK" != *:* ]] || { echo "guarded_build: LOCK must not contain ':', got '$LOCK'" >&2; exit 2; }
HELD="${NDTWIN_GUARD_HELD:-}"
reentrant=0
[[ ":$HELD:" == *":$LOCK:"* ]] && reentrant=1

# The shims must come FIRST, and the caller's PATH must survive underneath them: a gate that
# needs the venv python still needs to find it.
export PATH="$SHIM:$PATH"
export SHIM_JOBS="$JOBS"

cmd=("$@")
[[ -n "$TIMEOUT" ]] && cmd=(timeout "$TIMEOUT" "${cmd[@]}")

run_it() {
    if [[ "${NO_CGROUP:-0}" == 1 ]]; then
        echo "guarded_build: NO_CGROUP=1 -- running WITHOUT a memory cap (guard 3 is off)" >&2
        "${cmd[@]}"
        return $?
    fi
    if ! command -v systemd-run >/dev/null 2>&1; then
        echo "guarded_build: no systemd-run -- running WITHOUT a memory cap (guard 3 is off)" >&2
        "${cmd[@]}"
        return $?
    fi
    # --scope, not --unit: a scope keeps this shell as the parent, so the exit code comes back
    # and stdout/stderr stay attached. --collect removes the unit even when it fails.
    systemd-run --user --scope --collect --quiet \
        --unit="ndtwin-build-$$" \
        --property=MemoryHigh="$MEM_HIGH" \
        --property=MemoryMax="$MEM_MAX" \
        --property=MemorySwapMax=0 \
        -- "${cmd[@]}"
}

echo "guarded_build: jobs=$JOBS mem_high=$MEM_HIGH mem_max=$MEM_MAX lock=$LOCK" >&2
echo "guarded_build: \$ ${cmd[*]}" >&2

# Guard 2, re-entrant half: a lock this process tree already holds is not contention, and the
# scope that took it already caps us. Guards 1 (PATH shims, set above) and 3 (the outer scope's
# MemoryHigh, inherited by every descendant cgroup) both still apply here.
if [[ $reentrant == 1 ]]; then
    echo "guarded_build: $LOCK is already held above us -- nesting (no second flock, no second scope)" >&2
    "${cmd[@]}"
    rc=$?
    echo "guarded_build: exit $rc" >&2
    exit $rc
fi

exec 9>"$LOCK" || { echo "guarded_build: cannot open lock $LOCK" >&2; exit 2; }
if ! flock -w "${LOCK_WAIT:-3600}" 9; then
    echo "guarded_build: another build has held $LOCK for ${LOCK_WAIT:-3600}s -- giving up" >&2
    exit 2
fi
# Only now, holding it: an exported claim to a lock we do not have would let a descendant skip
# a flock it needed. (Nothing is spawned between the export and the flock either way.)
export NDTWIN_GUARD_HELD="${HELD:+$HELD:}$LOCK"

run_it
rc=$?
echo "guarded_build: exit $rc" >&2
exit $rc
