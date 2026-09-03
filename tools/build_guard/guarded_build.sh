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
#   2. flock       -- one build at a time. Two capped builds still add up.
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
# ENV
#   JOBS      parallel jobs the shims force            (default 2)
#   MEM_HIGH  MemoryHigh for the build's own cgroup    (default 3G) -- throttle+reclaim itself first
#   MEM_MAX   MemoryMax for the build's own cgroup     (default 4G)
#   LOCK      lock file, i.e. what counts as "a build" (default /tmp/ndtwin-build.lock)
#   NO_CGROUP=1  skip guard 3 (use only where systemd --user is unavailable; SAY SO in the log)
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

exec 9>"$LOCK" || { echo "guarded_build: cannot open lock $LOCK" >&2; exit 2; }
if ! flock -w "${LOCK_WAIT:-3600}" 9; then
    echo "guarded_build: another build has held $LOCK for ${LOCK_WAIT:-3600}s -- giving up" >&2
    exit 2
fi

run_it
rc=$?
echo "guarded_build: exit $rc" >&2
exit $rc
