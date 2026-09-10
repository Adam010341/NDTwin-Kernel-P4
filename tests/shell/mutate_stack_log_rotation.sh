#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_stack_log_rotation.sh (09-05 night round: O-4).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of O-4 -- two generations of kernel.log, one `ndt up` away
# from erasing the evidence five fix tickets were judged on -- or one of the wrong answers that
# "keep more generations" invites, and must turn its NAMED case red.
#
# 🔴 Two directions. M2 and M6 are the wrong fixes: one prunes by the clock rather than by the
# era, so a generation someone greps or copies survives at the cost of the newest one; the other
# widens the glob until the pruner deletes files this scheme never created. Both keep exactly
# five files around and look like a working rotation. N1 is the control that never rotates at
# all -- every pruning case in the suite passes vacuously if the log is simply left in place.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with STACK_UNDER_TEST. tools/test_workflow/stack.sh is never written -- the lab
# was in use the night this was added and another session may be executing it -- and the sha256
# line at the bottom says so.
#
# 🔴 A mutant directory carries components.env too: stack.sh sources it from beside itself, so a
# copy without it dies at source time and every case goes red for the wrong reason.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="$REPO/tools/test_workflow/stack.sh"
TEST="$HERE/test_stack_log_rotation.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/stack-rot-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_STACK=$(sha256sum "$STACK" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { STACK_UNDER_TEST="$1/stack.sh" timeout 600 bash "$TEST" 2>&1; }

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
    cp "$STACK" "$d/stack.sh"; chmod +x "$d/stack.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    cp "$REPO/tools/test_workflow/supervise.sh" "$d/supervise.sh"
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
cp "$STACK" "$base/stack.sh"; chmod +x "$base/stack.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
cp "$REPO/tools/test_workflow/supervise.sh" "$base/supervise.sh"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- O-4 itself ------------------------------------------------------------------------------

# The defect verbatim: two generations, renamed on every restart. It also removes the wiring, so
# this one mutation puts back both halves of what start_bg used to do.
m=$(mutant m1 "$STACK" \
    '    if [[ -s "$log" ]]; then
        rotate_log "$log"
    fi' \
    '    if [[ -s "$log" ]]; then
        [[ -s "$log.prev" ]] && mv -f "$log.prev" "$log.prev2"
        mv -f "$log" "$log.prev"
    fi')
report "M1: back to .prev/.prev2, and start_bg stops calling rotate_log" "$m" \
       "start_bg left a stamped generation behind"

# A wrong fix that keeps the right NUMBER of files: order taken from the clock instead of from
# the era. Reading, copying or grepping a generation then promotes it and evicts a newer one.
m=$(mutant m2 "$STACK" \
    '    done < <(ls -1 "$log".[0-9]* 2>/dev/null | LC_ALL=C sort -r | tail -n +$(( keep + 1 )))' \
    '    done < <(ls -1t "$log".[0-9]* 2>/dev/null | tail -n +$(( keep + 1 )))')
report "M2 (wrong fix, still five files): pruned by mtime, not by era" "$m" \
       "🔴 the newest seeded era survives (mtime says it is the oldest)"

# The other wrong fix, and the one that would have destroyed the very evidence O-4 is about: the
# glob widened past the generations this function writes, so anything parked beside the log goes.
m=$(mutant m6 "$STACK" \
    'ls -1 "$log".[0-9]* 2>/dev/null | LC_ALL=C sort -r' \
    'ls -1 "$log".* 2>/dev/null | LC_ALL=C sort -r') 2>/dev/null
report "M6 (wrong fix): the pruner deletes what it did not create" "$m" \
       "🔴 a .prev from the old scheme is not swept up"

# A rotation that never prunes is not a rotation; it is an unbounded directory that passes every
# "is the era still there" question in the suite.
m=$(mutant m3 "$STACK" \
    '        [[ -n "$old" ]] && rm -f "$old"' \
    '        :')
report "M3: nothing is ever pruned" "$m" \
       "eight generations are pruned to five"

# Depth 0 was the whole finding, so the one value the knob must refuse is the one that restores
# it. An unguarded NDT_LOG_KEEP puts the trap back in the hands of whoever exports it.
m=$(mutant m4 "$STACK" \
    '    [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 1 )) || keep=5' \
    '    [[ "$keep" =~ ^[0-9]+$ ]] || keep=5')
report "M4: NDT_LOG_KEEP=0 is honoured" "$m" \
       "🔴 NDT_LOG_KEEP=0 falls back to five, not to none"

# Two restarts inside one second: without the collision loop the second `mv` lands on the first
# generation's name and the era in between is gone with no trace that it existed.
m=$(mutant m5 "$STACK" \
    '    while [[ -e "$log.$stamp" ]]; do n=$(( n + 1 )); stamp="$(date +%Y%m%d-%H%M%S)-$n"; done' \
    '    :')
report "M5: same-second restarts overwrite each other" "$m" \
       "both generations exist"

# --- the control ------------------------------------------------------------------------------

# N1: nothing is rotated at all. Every pruning case in the suite is then satisfied vacuously --
# there is never more than one file to prune -- which is why 3A asks the question directly.
m=$(mutant n1 "$STACK" \
    '    mv -f "$log" "$log.$stamp" || return 1' \
    '    return 0')
report "N1 (control, never rotates): the log is left in place" "$m" \
       "the live log is moved aside, not left in place"

echo
NOW_STACK=$(sha256sum "$STACK" | cut -d' ' -f1)
if [[ "$NOW_STACK" != "$BASE_STACK" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/stack.sh was written"
    echo "   before: $BASE_STACK"
    echo "   after:  $NOW_STACK"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/stack.sh  sha256 $BASE_STACK"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
