#!/usr/bin/env bash
#
# Mutation gate for the pidfile-cleanup half of tests/shell/test_supervise_exit_status.sh (R7 I-3).
#
# [Co-developed with claude code -- Adam]
#
# What the finding was, measured 2026-09-11 02:52:03 and again 02:52:27 -- 57 s and 81 s after the
# event, so not a race (hunt-0911/R7-reconciler.md round 14):
#
#     ryu.pid        20717    /proc/20717 does not exist
#     ryu.child.pid  20722    /proc/20722 does not exist
#     ryu.exit       at=2026-09-11T02:51:06  status=143  reason=terminated by SIGTERM (15)
#
# One directory, two files, opposite stories -- and .test_run/pids/ is not documentation: it is the
# registry `stack.sh down` signals and the one ndt's port_owner_local reads to decide whether a
# listener is "ours". A dead number left in it is the fuse under both.
#
# 🔴 THIS GATE EXISTS FOR BOTH DIRECTIONS, and the second one is why it is a gate and not a diff.
# M2 is the tidier fix -- remove <prefix>.pid too -- and it is WRONG: stop_one opens with
# `[[ -f "$pidfile" ]] || return 0`, and report_exit is behind that gate, so a component that died
# on its own would have its ending read by nobody. The file whose absence proves it is dead is
# also the file that makes anyone look. That is B-5's entire observability, removed as a side
# effect of tidying up a registry. It was tried here first and the suite said so.
#
# 🔴 Mutations are applied to a COPY in a temp dir and the suite is pointed at it with
# SUPERVISE_UNDER_TEST. tools/test_workflow/supervise.sh is never written -- a kernel or a Ryu may
# be running under it right now -- and the sha256 line at the bottom says so.
#
# 🔴 Only the groups that call $SUPERVISE_SH directly see a mutant. The start_bg/stop_one groups go
# through stack.sh, which finds supervise.sh beside itself; that is a property of the harness, not
# a gap, and it is why the cases named below are the ones in the direct groups.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SUP="$REPO/tools/test_workflow/supervise.sh"
TEST="$HERE/test_supervise_exit_status.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/supervise-pidfile-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SUP=$(sha256sum "$SUP" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { SUPERVISE_UNDER_TEST="$1/supervise.sh" timeout 600 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$SUP" "$d/supervise.sh"; chmod +x "$d/supervise.sh"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$SUP" "$base/supervise.sh"; chmod +x "$base/supervise.sh"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# M1: the defect verbatim -- the exit record is written and the pidfile naming a reaped pid is
# left behind, which is what R7 read out of .test_run/pids/ 57 s after the event.
m=$(mutant m1 "$SUP" \
    'rm -f "$PREFIX.child.pid"

exit "$RC"' \
    ':

exit "$RC"')
report "M1: the reaped child's pidfile is left in the registry (R7 I-3)" "$m" \
       "🔴 the child pidfile is gone once the ending is recorded"

# 🔴 M2: THE TIDIER ANSWER, AND THE DAMAGING ONE. Removing <prefix>.pid as well leaves the
# registry spotless and silences stop_one's report of a component that died on its own -- B-5's
# whole point -- because report_exit sits behind `[[ -f "$pidfile" ]] || return 0`.
m=$(mutant m2 "$SUP" \
    'rm -f "$PREFIX.child.pid"

exit "$RC"' \
    'rm -f "$PREFIX.child.pid" "$PREFIX.pid"

exit "$RC"')
report "M2 (widening): <prefix>.pid is reaped too, and stop_one goes blind" "$m" \
       "🔴 and <prefix>.pid is NOT removed -- stop_one needs it to report the ending"

# M3: the removal moved to where it cannot be right -- immediately after the child is recorded, so
# a RUNNING component has no pidfile naming its worker. "Remove the stale one" turning into
# "remove it" is the shape this control exists for.
m=$(mutant m3 "$SUP" \
    'echo "$CHILD" >"$PREFIX.child.pid"' \
    'echo "$CHILD" >"$PREFIX.child.pid"; rm -f "$PREFIX.child.pid"')
report "M3: it is removed while the child is still running" "$m" \
       "🔴 a RUNNING component still has its child pidfile"

echo
NOW_SUP=$(sha256sum "$SUP" | cut -d' ' -f1)
if [[ "$NOW_SUP" != "$BASE_SUP" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/supervise.sh was written"
    echo "   before: $BASE_SUP"
    echo "   after:  $NOW_SUP"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/supervise.sh  sha256 $BASE_SUP"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
