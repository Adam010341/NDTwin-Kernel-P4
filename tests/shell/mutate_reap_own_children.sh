#!/usr/bin/env bash
#
# Mutation gate for tests/shell/lib_reap_own_children.sh: the reaper that test_ndt_apps_liveness.sh
# and test_ndt_helper_apps_window.sh both end their cleanup with. Each way of getting it wrong must
# turn a NAMED check red in BOTH suites -- until 2026-10-03 the liveness suite carried its own copy
# and only the window suite had checks on it.
#
# [Co-developed with claude code -- Adam]
#
# Five mutations, each a way a reaper that kills process groups goes wrong:
#   M1  it kills each child's REAL process group, whether or not the child leads it -- a child that
#       does not lead one (a parent held before its exec) then takes the suite's own group, the
#       suite and whoever called it, down with it
#   M2  it has no guard against being called from a subshell, where its answer and the substitution
#       it runs in are among the children it kills
#   M3  a child that does not lead a group is not killed at all
#   M4  a child that leads a group is killed by its pid alone, and what it forked outlives it
#   M5  kill_group_if_leader, which the window suite's reap_two_layer uses, aims the group form at
#       a process that leads no group: it fails, and a parent held before its exec is not reaped
# and a control, a reworded comment, that must change nothing.
#
# 🔴 Mutants that kill groups. Each mutation goes to a COPY of the lib in a temp dir (the suites
# take it through REAP_OWN_CHILDREN_LIB_UNDER_TEST), and each suite runs in a session of its own
# (`setsid --wait`), so the one group M1 can reach is that session's: this gate's shell, its caller
# and the user's terminal are in other groups. The reaper's own selftest runs in a second session
# inside that one. The real lib is never written; a sha256 line at the end says so.
# 🔴 Never kills anything by name. Touches no lab, builds nothing.
#
# A mutation caught by a check other than the one named for it is a SURVIVOR, not a kill.
#
# Usage: tests/shell/mutate_reap_own_children.sh
#   TEST_TIMEOUT=300   seconds allowed per suite run
# Exit: 0 every mutation was caught by its named check in both suites, the control survived
#       1 a mutation survived or was caught by the wrong check
#       2 no verdict (baseline red, anchor drift, hang, harness)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib_reap_own_children.sh"
LIVENESS="$HERE/test_ndt_apps_liveness.sh"
WINDOW="$HERE/test_ndt_helper_apps_window.sh"
PY="${PY:-/usr/bin/python3}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"

if ! bash -n "${BASH_SOURCE[0]}"; then echo "🔴 this script does not parse" >&2; exit 2; fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
command -v setsid >/dev/null || { echo "🔴 setsid is required: the mutants kill groups" >&2; exit 2; }
[[ -f "$LIB" && -f "$LIVENESS" && -f "$WINDOW" ]] || { echo "🔴 missing the lib or a suite" >&2; exit 2; }

BK=$(mktemp -d "${TMPDIR:-/tmp}/reap-own-children-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
BASE_SHA=$(sha256sum "$LIB" | cut -d' ' -f1)
MY_SID=$(ps -o sid= -p $$ | tr -d ' ')

MUTATIONS=0
SURVIVORS=0
VERDICT=0

# A suite, in a session of its own, against whichever copy of the lib it is handed.
run_suite() {   # $1 = suite, $2 = lib
    REAP_OWN_CHILDREN_LIB_UNDER_TEST="$2" setsid --wait timeout "$TEST_TIMEOUT" bash "$1" 2>&1
}

judge() {   # $1 = mutation name, $2 = the lib to use, $3 = the check that must go red, $4... = suites
    local name="$1" lib="$2" want="$3" s out rc
    shift 3
    MUTATIONS=$((MUTATIONS + 1))
    for s in "$@"; do
        out=$(run_suite "$s" "$lib"); rc=$?
        if [[ "$rc" == 124 ]]; then
            printf '  🔴 %-52s %s HUNG -- never a catch\n' "$name" "${s##*/}" >&2; VERDICT=2; continue
        fi
        if [[ "$rc" -ne 0 ]] && grep -qF "  FAILED   $want" <<<"$out"; then
            printf '  caught   %-52s %s: %s went red\n' "$name" "${s##*/}" "$want"
        else
            SURVIVORS=$((SURVIVORS + 1)); VERDICT=1
            printf '  SURVIVED %-52s %s: %s stayed green -- that case proves nothing\n' "$name" "${s##*/}" "$want" >&2
            grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /' >&2
        fi
    done
}
report() { judge "$1" "$2" "$3" "$LIVENESS" "$WINDOW"; }          # both suites must catch it
report_window() { judge "$1" "$2" "$3" "$WINDOW"; }               # the liveness suite has no use for it

control() {  # $1 = name, $2 = mutated lib -- must NOT go red, in either suite
    local s out rc
    MUTATIONS=$((MUTATIONS + 1))
    for s in "$LIVENESS" "$WINDOW"; do
        out=$(run_suite "$s" "$2"); rc=$?
        if [[ "$rc" -eq 0 ]]; then
            printf '  SURVIVED %-52s %s (control, as required)\n' "$1" "${s##*/}"
        else
            printf '  🔴 %-52s %s: CONTROL WENT RED -- this gate measures "the file changed"\n' "$1" "${s##*/}" >&2
            grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /' >&2
            VERDICT=2
        fi
    done
}

mutant() {   # $1 = name, $2 = anchor \x1f replacement; prints the path to the mutated copy
    local out="$BK/lib.$1.sh"; cp "$LIB" "$out"
    "$PY" - "$out" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p).read()
assert s.count(old) == 1, "anchor is not unique (%d matches): %r" % (s.count(old), old[:70])
open(p, "w").write(s.replace(old, new))
PY
    # The hunk, into the gate's own log: a red nobody can read the edit of is a number.
    diff -u "$LIB" "$out" | tail -n +3 | sed 's/^/      /' >&2
    echo "$out"
}

echo "baseline (must be green in both suites before any mutation), gate's session $MY_SID:"
for s in "$LIVENESS" "$WINDOW"; do
    out=$(run_suite "$s" "$LIB"); rc=$?
    printf '  %s rc %s: %s\n' "${s##*/}" "$rc" "$(tail -1 <<<"$out")"
    [[ "$rc" -eq 0 ]] || { echo "  🔴 baseline is RED -- nothing below is interpretable" >&2; grep -E '^  FAILED' <<<"$out" | sed 's/^/    /' >&2; exit 2; }
done
echo

m1=$(mutant m1 '        if [[ "$OWN_PGID" == "$c" ]]; then kill -KILL -- "-$c" 2>/dev/null; else kill -KILL "$c" 2>/dev/null; fi'$'\x1f''        kill -KILL -- "-$OWN_PGID" 2>/dev/null')
report "M1: each child's real group is killed, leader or not" "$m1" \
       "reaper:   its group is left alone, and the shell lives to say so"

m2=$(mutant m2 '    [[ $BASHPID == "$$" ]] || { echo "  FAILED   ${FUNCNAME[0]} called outside this suite'"'"'s own shell (BASHPID $BASHPID, suite $$): not reaping" >&2; return 1; }'$'\x1f''    :')
report "M2: no guard against a call from a subshell" "$m2" \
       "reaper: a call from a subshell is refused"

m3=$(mutant m3 'else kill -KILL "$c" 2>/dev/null; fi'$'\x1f''else :; fi')
report "M3: a child that leads no group is not killed" "$m3" \
       "reaper: a child that does not lead one goes, by its pid"

m4=$(mutant m4 'then kill -KILL -- "-$c" 2>/dev/null;'$'\x1f''then kill -KILL "$c" 2>/dev/null;')
report "M4: a group leader is killed by its pid alone" "$m4" \
       "reaper: a child that leads a group goes, and what it forked with it"

# 🔴 Aimed at the helper reap_two_layer calls. Window suite only: the liveness suite does not use it.
m5=$(mutant m5 '    if [[ "$s" == "$1" ]]; then kill -KILL -- "-$1" 2>/dev/null; else kill -KILL "$1" 2>/dev/null; fi'$'\x1f''    kill -KILL -- "-$1" 2>/dev/null')
report_window "M5: the group form is aimed at any process" "$m5" \
       "  and signals a parent that leads no group by its pid alone"

c1=$(mutant c1 '# reap_own_children -- KILL whatever this shell forked that is still there.'$'\x1f''# reap_own_children -- KILL whatever this shell forked and that is still there.')
control "C1 (control): a comment is reworded" "$c1"

echo
NOW_SHA=$(sha256sum "$LIB" | cut -d' ' -f1)
if [[ "$NOW_SHA" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes  $LIB (never written; every mutation went to a copy)"
else
    echo "🔴 $LIB WAS WRITTEN -- $BASE_SHA -> $NOW_SHA" >&2
    VERDICT=2
fi

echo
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
case "$VERDICT" in
    0) echo "VERDICT: every mutation was caught by the check named for it, in both suites; the control survived" ;;
    1) echo "VERDICT: at least one mutation survived or was caught by the wrong check" >&2 ;;
    *) echo "VERDICT: no verdict -- the gate could not run cleanly" >&2 ;;
esac
exit "$VERDICT"
