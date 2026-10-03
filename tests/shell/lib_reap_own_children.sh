#!/usr/bin/env bash
# Sourced by test_ndt_apps_liveness.sh and test_ndt_helper_apps_window.sh: the part of their cleanup
# that kills what the suite's own shell forked and has not yet written down.
#
# [Co-developed with claude code -- Adam]
#
# Both suites used to carry the same functions, and only the window suite had checks on them, so a
# regression in the liveness copy would have stayed green (2026-10-03). One file now, and
# reap_own_children_selftest, which both suites call, puts the reaper and kill_group_if_leader to
# seventeen checks in a shell of its own. tests/shell/mutate_reap_own_children.sh holds those checks
# to it: each way of getting either wrong must turn a named check red in BOTH suites.
#
# Source it from a suite's own shell, after anything else that defines functions (ndt does), so
# that nothing can shadow these, as
#     source "${REAP_OWN_CHILDREN_LIB_UNDER_TEST:-<this directory>/lib_reap_own_children.sh}"
# The line must not use HERE, which ndt rebinds. REAP_OWN_CHILDREN_LIB_UNDER_TEST is the seam the
# mutation gate uses to hand a suite a mutated copy of this file; each suite says so on stderr when
# it is set, so that a stray value shows in a log.
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

# kill_group_if_leader <pid> -- KILL that process, and its whole group if it leads one. A process
# that does not lead its group is killed by its pid alone, because its group is somebody else's:
# for the suite's own children, this suite's -- and the caller's. The pgid is read here and used
# here, with nothing forked in between.
# 🔴 Refuses (returns 1, signals nothing) a pid that is not above 1 -- `kill -- -1` is a broadcast
# to everything the user may signal -- this shell, the shell it runs in, its parent, and the
# process group this shell is in: whatever the caller meant, those are never its to kill.
kill_group_if_leader() {
    local p s mine=""
    [[ "$1" =~ ^[0-9]{1,10}$ ]] || { echo "kill_group_if_leader: '$1' is not a pid: refused" >&2; return 1; }
    p=$((10#$1))
    { read -r mine < "/proc/$BASHPID/stat"; } 2>/dev/null
    mine="${mine##*) }"; mine="${mine#* }"; mine="${mine#* }"; mine="${mine%% *}"      # this shell's own pgrp
    (( p > 1 )) || { echo "kill_group_if_leader: refusing pid $p" >&2; return 1; }
    [[ "$p" == "$$" || "$p" == "$BASHPID" || "$p" == "$PPID" ]] && { echo "kill_group_if_leader: refusing $p, this shell or its parent" >&2; return 1; }
    [[ "$p" == "$mine" ]] && { echo "kill_group_if_leader: refusing $p, the group this shell is in" >&2; return 1; }
    { read -r s < "/proc/$p/stat"; } 2>/dev/null || return 1
    s="${s##*) }"; s="${s#* }"; s="${s#* }"; s="${s%% *}"      # the pgrp
    if [[ "$s" == "$p" ]]; then kill -KILL -- "-$p" 2>/dev/null; else kill -KILL "$p" 2>/dev/null; fi
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

# reap_own_children_selftest -- checks on the reaper and on kill_group_if_leader, in a bash of its own.
# 🔴 That shell leads a session (setsid), so a reaper that kills a group it should not kill can
# only reach the group that shell leads: what this suite's shell, its caller and whatever runs
# them lead stays out of it. The checks are read from what that shell prints; a reaper that kills
# the shell it runs in leaves nothing to read, and every check below goes red.
# The shell runs under `set -uo pipefail`, as the suites do, and waits for its fixtures by polling
# (5 s at most, and a SETUP line says which one did not come), not for a fixed time.
# kill_group_if_leader's refusals are tried in a third shell, one that leads no group and is not
# the child of its group's leader, so that "this shell", "its parent" and "its group" are three
# different pids; `kill` is a function there that only writes down what it was asked, so a refusal
# that fails cannot signal anything -- pid 1 least of all.
_REAP_REFUSAL_BODY='
source "$1"
kill() { echo "SENT $*"; }
refused() {   # <name> <rc> <what the stubbed kill saw>
    if [[ "$2" -ne 0 && -z "$3" ]]; then echo "$1 refused"; else echo "$1 NOT refused: rc $2, kill was asked [$3]"; fi
}
own_pgrp() { local s; { read -r s < "/proc/$1/stat"; } 2>/dev/null; s="${s##*) }"; s="${s#* }"; s="${s#* }"; echo "${s%% *}"; }
echo "REFPREM $([[ "$(own_pgrp $$)" == "$2" && "$$" != "$2" && "$PPID" != "$2" ]] && echo yes || echo no)"
out="$(kill_group_if_leader 1 2>/dev/null)"; refused REFONE $? "$out"
out="$(kill_group_if_leader 0 2>/dev/null)"; r0=$?
out2="$(kill_group_if_leader "" 2>/dev/null)"; r1=$?
out3="$(kill_group_if_leader abc 2>/dev/null)"; r2=$?
refused REFJUNK "$((r0 && r1 && r2))" "$out$out2$out3"
out="$(kill_group_if_leader $$ 2>/dev/null)"; refused REFSELF $? "$out"
out="$(kill_group_if_leader "$BASHPID" 2>/dev/null)"; refused REFSUB $? "$out"
out="$(kill_group_if_leader "$PPID" 2>/dev/null)"; refused REFPARENT $? "$out"
out="$(kill_group_if_leader "$2" 2>/dev/null)"; refused REFGROUP $? "$out"
# the stub is wired: a process that does lead a group is asked for by that group
setsid sleep 30 >/dev/null 2>&1 & P=$!
for ((i = 0; i < 100; i++)); do [[ "$(own_pgrp $P)" == "$P" ]] && break; sleep 0.05; done
out="$(kill_group_if_leader "$P" 2>/dev/null)"
echo "REFCTRL $([[ "$out" == "SENT -KILL -- -$P" ]] && echo yes || echo "no [$out]")"
builtin kill -KILL "$P" 2>/dev/null
'
_REAP_SELFTEST_BODY='
source "$1"
A="" B="" C="" D="" E="" G="" H=""
# Whatever is still there when this shell ends -- by an error, say -- goes with it, and does not hold
# the output open for the 25 s its sleep would last.
leftovers() { local p; for p in "$B" "$C" "$D"; do [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; for p in "$A" "$E"; do [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL -- "-$p" 2>/dev/null; done; return 0; }
trap leftovers EXIT
alive() { local s; { read -r s < "/proc/$1/stat"; } 2>/dev/null || return 1; s="${s##*) }"; [[ "${s%% *}" != Z ]]; }
state() { alive "$1" && echo alive || echo dead; }
# settle <pids> -- until none of them is alive (3 s at most)
settle() { local i p n; for ((i = 0; i < 60; i++)); do n=0; for p in "$@"; do alive "$p" && n=1; done; ((n)) || return 0; sleep 0.05; done; return 1; }
# kid_of <pid> -> G, the first child it has forked (5 s at most)
kid_of() { local i; G=""; for ((i = 0; i < 100; i++)); do { read -r G _ < "/proc/$1/task/$1/children"; } 2>/dev/null; [[ -n "$G" ]] && return 0; sleep 0.05; done; echo "SETUP no child of $1 within 5 s"; return 1; }
# B: a child that leads no group of its own -- the same shape as a parent held before its exec.
sleep 25 >/dev/null 2>&1 & B=$!
# C: a bystander in this shell'"'"'s group that is NOT its child.
C="$( ( sleep 26 >/dev/null 2>&1 & echo $! ) )"
# A: a child that leads a group, and G: what it forked into it.
setsid bash -c "sleep 27 & wait" >/dev/null 2>&1 & A=$!
kid_of "$A"
echo "PREMISE leader=$([[ "$(awk "{print \$5}" /proc/$A/stat)" == "$A" ]] && echo yes || echo no)" \
     "plain=$([[ "$(awk "{print \$5}" /proc/$B/stat)" != "$B" ]] && echo yes || echo no)" \
     "grandchild=$([[ "$(awk "{print \$5}" /proc/$G/stat 2>/dev/null)" == "$A" ]] && echo yes || echo no)"
r="$(reap_own_children 2>&1)"
echo "REFUSED $([[ "$r" == *"outside this suite'"'"'s own shell"* ]] && echo yes || echo no)"
echo "KEPT B=$(state $B) A=$(state $A) G=$(state $G)"
reap_own_children
settle "$A" "$G" "$B"
echo "LEADER A=$(state $A) G=$(state $G)"
echo "PLAIN B=$(state $B)"
echo "BYSTANDER C=$(state $C)"
echo "SURVIVED yes"
# kill_group_if_leader: D leads nothing, E leads a group and H is in it
sleep 28 >/dev/null 2>&1 & D=$!
setsid bash -c "sleep 29 & wait" >/dev/null 2>&1 & E=$!
kid_of "$E"; H="$G"
kill_group_if_leader "$D"
kill_group_if_leader "$E"
settle "$D" "$E" "$H"
echo "KGLPLAIN D=$(state $D) C=$(state $C)"
echo "KGLLEADER E=$(state $E) H=$(state $H)"
echo "SURVIVED2 yes"
bash -c "bash -c \"\$1\" _ \"\$2\" \"\$3\"; :" _ "$2" "$1" "$$" 2>&1
kill -KILL "$C" 2>/dev/null
'
# _reap_selftest_line <what the shell printed> <word> -- the rest of the first line that begins with it
_reap_selftest_line() { grep -m1 "^$2 " <<<"$1" | cut -d' ' -f2-; }
reap_own_children_selftest() {
    local out mine theirs
    out="$(setsid --wait bash -uo pipefail -c "$_REAP_SELFTEST_BODY" _ "$_REAP_OWN_CHILDREN_LIB" "$_REAP_REFUSAL_BODY" 2>&1)"
    check "reaper: the fixtures it is tried on are a leader with a child, a plain child and a bystander" \
          "leader=yes plain=yes grandchild=yes" "$(_reap_selftest_line "$out" PREMISE)$(grep -m1 '^SETUP' <<<"$out" | sed 's/^/ -- /')"
    check "reaper: a call from a subshell is refused" yes "$(_reap_selftest_line "$out" REFUSED)"
    check "reaper:   and the refusal kills nothing" "B=alive A=alive G=alive" "$(_reap_selftest_line "$out" KEPT)"
    check "reaper: a child that leads a group goes, and what it forked with it" "A=dead G=dead" "$(_reap_selftest_line "$out" LEADER)"
    check "reaper: a child that does not lead one goes, by its pid" "B=dead" "$(_reap_selftest_line "$out" PLAIN)"
    check "reaper:   its group is left alone, and the shell lives to say so" "C=alive yes" \
          "$(_reap_selftest_line "$out" BYSTANDER) $(_reap_selftest_line "$out" SURVIVED)"
    check "kill_group_if_leader: a process that leads no group goes by its pid, its group is left alone" "D=dead C=alive" \
          "$(_reap_selftest_line "$out" KGLPLAIN)"
    check "kill_group_if_leader: a process that leads a group goes with it" "E=dead H=dead" "$(_reap_selftest_line "$out" KGLLEADER)"
    check "kill_group_if_leader:   and the shell lives to say so" yes "$(_reap_selftest_line "$out" SURVIVED2)"
    check "kill_group_if_leader: its refusals are tried in a shell that leads no group, with kill stubbed that does ask" \
          "yes yes" "$(_reap_selftest_line "$out" REFPREM) $(_reap_selftest_line "$out" REFCTRL)"
    check "kill_group_if_leader: pid 1 is refused and nothing is sent" refused "$(_reap_selftest_line "$out" REFONE)"
    check "kill_group_if_leader: pid 0, an empty argument and a word are refused" refused "$(_reap_selftest_line "$out" REFJUNK)"
    check "kill_group_if_leader: the shell's own pid is refused" refused "$(_reap_selftest_line "$out" REFSELF)"
    check "kill_group_if_leader: the pid of the subshell it runs in is refused" refused "$(_reap_selftest_line "$out" REFSUB)"
    check "kill_group_if_leader: the shell's parent is refused" refused "$(_reap_selftest_line "$out" REFPARENT)"
    check "kill_group_if_leader: the group the shell is in (its leader's pid) is refused" refused "$(_reap_selftest_line "$out" REFGROUP)"
    # What the checks above ran is this file in a shell of its own; what the suite's cleanup calls
    # is whatever is defined in the suite's shell now. Sourced before something that defines a
    # function of the same name, they differ and nothing above would say so.
    mine="$(declare -f own_child kill_group_if_leader reap_own_children)"
    theirs="$(bash -c 'source "$1"; declare -f own_child kill_group_if_leader reap_own_children' _ "$_REAP_OWN_CHILDREN_LIB" 2>&1)"
    check "reaper: the functions this suite calls are the lib's own, nothing defined after it shadows them" same \
          "$([[ "$mine" == "$theirs" ]] && echo same || echo "different: $(diff <(echo "$mine") <(echo "$theirs") | head -n 3 | tr '\n' ' ')")"
}
