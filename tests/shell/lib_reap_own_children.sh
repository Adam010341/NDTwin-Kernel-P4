#!/usr/bin/env bash
# Sourced by test_ndt_apps_liveness.sh and test_ndt_helper_apps_window.sh: the part of their cleanup
# that kills what the suite's own shell forked and has not yet written down.
#
# [Co-developed with claude code -- Adam]
#
# Both suites used to carry the same functions, and only the window suite had checks on them, so a
# regression in the liveness copy would have stayed green (2026-10-03). One file now, and
# reap_own_children_selftest, which both suites call, puts the reaper to six checks in a shell of
# its own. tests/shell/mutate_reap_own_children.sh holds those checks to it: each way of getting
# the reaper wrong must turn a named check red in BOTH suites.
#
# Source it from a suite's own shell, before anything that rebinds HERE (ndt does), as
#     source "${REAP_OWN_CHILDREN_LIB_UNDER_TEST:-<this directory>/lib_reap_own_children.sh}"
# REAP_OWN_CHILDREN_LIB_UNDER_TEST is the seam the mutation gate uses to hand a suite a mutated
# copy of this file.
#
# What a suite must define before it calls reap_own_children_selftest: check <what> <expected>
# <actual>, as both do.

_REAP_OWN_CHILDREN_LIB="${BASH_SOURCE[0]}"

# own_child <pid> -- true if that process is one this shell forked itself: its parent is $$. Its
# process group is left in OWN_PGID. A child's number is not given to another process until bash
# has reaped it, and bash reaps on its own schedule, so whatever is done with the answer is done at
# once, with nothing forked in between. Before the child has exec'd its argv is still this
# suite's own, and this still knows it.
own_child() {
    local s
    OWN_PGID=""
    { read -r s < "/proc/$1/stat"; } 2>/dev/null || return 1
    s="${s##*) }"; s="${s#* }"          # "<ppid> <pgrp> ..."
    [[ "${s%% *}" == "$$" ]] || return 1
    s="${s#* }"; OWN_PGID="${s%% *}"
}

# reap_own_children -- KILL whatever this shell forked that is still there. On the way out the
# suite's own foreground commands have all been waited for, so its remaining children are what it
# started in the background, and nothing needs to have been written down first: a signal that
# lands between a fork and the line that records its pid still finds it (2026-10-03; the window
# suite: between spawn_two_layer's `&` and its TWO_PARENT=$!, and a held parent; the liveness suite:
# between app_spawn's fork and spawn_app_fixture adding the pid to SPAWNED).
# A child that leads its own process group is killed BY that group, which holds it and anything
# it forked; any other child by its pid alone. Only from this suite's own shell: in a subshell, $$
# names a parent whose children include that subshell.
reap_own_children() {
    [[ $BASHPID == "$$" ]] || { echo "  FAILED   ${FUNCNAME[0]} called outside this suite's own shell (BASHPID $BASHPID, suite $$): not reaping" >&2; return 1; }
    local f c
    for f in /proc/[0-9]*/stat; do
        c="${f#/proc/}"; c="${c%/stat}"
        own_child "$c" || continue
        if [[ "$OWN_PGID" == "$c" ]]; then kill -KILL -- "-$c" 2>/dev/null; else kill -KILL "$c" 2>/dev/null; fi
    done
    return 0
}

# reap_own_children_selftest -- six checks on the reaper, in a bash of its own.
# 🔴 That shell leads a session (setsid), so a reaper that kills a group it should not kill can
# only reach the group that shell leads: what this suite's shell, its caller and whatever runs
# them lead stays out of it. The checks are read from what that shell prints; a reaper that kills
# the shell it runs in leaves nothing to read, and every check below goes red.
_REAP_SELFTEST_BODY='
source "$1"
alive() { local s; { read -r s < "/proc/$1/stat"; } 2>/dev/null || return 1; s="${s##*) }"; [[ "${s%% *}" != Z ]]; }
state() { alive "$1" && echo alive || echo dead; }
# B: a child that leads no group of its own -- the same shape as a parent held before its exec.
sleep 25 & B=$!
# C: a bystander in this shell'"'"'s group that is NOT its child.
C="$( ( sleep 26 >/dev/null 2>&1 & echo $! ) )"
# A: a child that leads a group, and G: what it forked into it.
setsid bash -c "sleep 27 & wait" >/dev/null 2>&1 & A=$!
sleep 0.4
read -r G _ < "/proc/$A/task/$A/children"
echo "PREMISE leader=$([[ "$(awk "{print \$5}" /proc/$A/stat)" == "$A" ]] && echo yes || echo no)" \
     "plain=$([[ "$(awk "{print \$5}" /proc/$B/stat)" != "$B" ]] && echo yes || echo no)" \
     "grandchild=$([[ "$(awk "{print \$5}" /proc/$G/stat 2>/dev/null)" == "$A" ]] && echo yes || echo no)"
r="$(reap_own_children 2>&1)"
echo "REFUSED $([[ "$r" == *"outside this suite'"'"'s own shell"* ]] && echo yes || echo no)"
echo "KEPT B=$(state $B) A=$(state $A) G=$(state $G)"
reap_own_children
sleep 0.3
echo "LEADER A=$(state $A) G=$(state $G)"
echo "PLAIN B=$(state $B)"
echo "BYSTANDER C=$(state $C)"
echo "SURVIVED yes"
kill -KILL "$C" 2>/dev/null
'
reap_own_children_selftest() {
    local out
    out="$(setsid --wait bash -c "$_REAP_SELFTEST_BODY" _ "$_REAP_OWN_CHILDREN_LIB" 2>&1)"
    line() { grep -m1 "^$1 " <<<"$out" | cut -d' ' -f2-; }
    check "reaper: the fixtures it is tried on are a leader with a child, a plain child and a bystander" \
          "leader=yes plain=yes grandchild=yes" "$(line PREMISE)"
    check "reaper: a call from a subshell is refused" yes "$(line REFUSED)"
    check "reaper:   and the refusal kills nothing" "B=alive A=alive G=alive" "$(line KEPT)"
    check "reaper: a child that leads a group goes, and what it forked with it" "A=dead G=dead" "$(line LEADER)"
    check "reaper: a child that does not lead one goes, by its pid" "B=dead" "$(line PLAIN)"
    check "reaper:   its group is left alone, and the shell lives to say so" "C=alive yes" \
          "$(line BYSTANDER) $(line SURVIVED)"
}
