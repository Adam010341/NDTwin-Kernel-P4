#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_apps_stop_kills_the_group.sh.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of findings #6/#48 -- the `ndt apps stop` that stopped the
# wrapper, reported `ok viz stopped` with rc 0, and left two JVMs running for 1h54m -- and must
# turn its named case red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Two directions, because "stop harder" has a wrong answer that looks like a fix. The signal
# this change adds is `kill -TERM -<pgid>`, and the group `ndt` itself is in contains `ndt`, the
# shell that ran it, and everything else in that session. The mutations labelled (control) are
# the over-reaching implementations -- signal your own group, refuse every group, never believe
# a stop worked -- and each must turn a control case red. A gate with only the first kind would
# sign off on a tool that kills its own caller, or on one that can never report a clean stop.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it right now -- and the two sha256 lines at the bottom say so.
#
# 🔴 A mutant directory carries ports.sh and sudo_surface.sh too. ndt sources both from beside
# itself, so a copy without them exits 2 at source time and every case in the suite goes red for
# a reason that has nothing to do with the mutation -- which is how three gates went red during
# the 09-03 merge (MERGE-LOG.md).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_apps_stop_kills_the_group.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-appsgroup-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$TEST" 2>&1; }

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

# A mutant is a whole directory: ndt sources ports.sh and sudo_surface.sh from beside itself, so
# they travel with it, unmutated. The anchor must be unique, so a mutation cannot quietly land
# somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from a function's
# own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is not checking
# (finding #28 -- two gates written the same night extracted zero anchors and nobody knew).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
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
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself: a wrapper is not the app ------------------------------------------------

m=$(mutant m1 "$NDT" \
    '    ( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 ) &' \
    '    ( cd "$dir" && exec nohup "$@" >>"$log" 2>&1 ) &')
report "M1: app_spawn leaves the app in ndt's own process group" "$m" \
       "the app is its own process group leader"

m=$(mutant m2 "$NDT" \
    '                app_kill_group "$pgid" "$name" "$corr"; grc=$?' \
    '                grc=0')
# Named on the GROUP and not on the tree: the mutant still kills every pid the survivor scan
# listed, so "nothing of the tree survives" stays green. What it cannot reach is the child the
# fixture hands off to when the worker is TERMed -- born after that list was taken, and in the
# group. That is the difference between a group signal and a pid list, and it is the only case
# in the suite that can see it. (Measured: with the case named on the tree, M2 survived.)
report "M2: stop signals the leader and not the group" "$m" \
       "🔴 the app's process group is empty"

m=$(mutant m3 "$NDT" \
    '    if (( ${#APP_SURVIVORS[@]} > 0 )); then
        err "$name is STILL RUNNING after stop' \
    '    if false; then
        err "$name is STILL RUNNING after stop')
report "M3: the verifier reports clean whatever it found" "$m" \
       "🔴 the verifier says NO while the app is running"

m=$(mutant m4 "$NDT" \
    '        (( (flags & 3) != 0 )) || continue' \
    '        :')
report "M4: any fd on the log counts, not only a writable one" "$m" \
       "a reader of the log is NOT a writer"

# 2026-09-07 (lw351): re-anchored. apps_orphans now SUBTRACTS the pids app_probe already
# accounted for before it reports anything, so the list this guard measures is `unnamed`, not
# the raw channel output. Same guard, same meaning, same mutation.
m=$(mutant m5 "$NDT" \
    '        (( ${#unnamed[@]} == 0 )) && continue' \
    '        continue')
report "M5: apps orphans stops consulting the new channels" "$m" \
       "🔴 apps orphans exits 1 (it answered 0 on 09-02)"

m=$(mutant m6 "$NDT" \
    '>>"$log" 2>&1 ) &' \
    '>"$log" 2>&1 ) &')
report "M6: the log is opened without O_APPEND again" "$m" \
       "🔴 the running app resumes at offset 0"

m=$(mutant m7 "$NDT" \
    '    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -d "/proc/$pid" ]] || return 0
        sleep 0.5
    done' \
    '    for i in 1 2 3 4 5 6 7 8 9 10; do
        pid_is_app "$pid" "$name" || return 0
        sleep 0.5
    done')
report "M7: 'gone' is asked of pid_is_app, which cannot see a JVM" "$m" \
       "  and it really is gone"

m=$(mutant m8 "$NDT" \
    '    (( n <= APP_SURVIVOR_MAX )) && return 0' \
    '    return 0')
report "M8: a channel that names the whole machine is believed" "$m" \
       "a channel naming 199 processes is discarded"

# --- 🔴 the other direction: the tool must not be its own target ---------------------------------
# Every one of these passes the eight mutations above. They are caught only by the controls, and
# without them this gate would sign off on an `ndt` that kills the shell that ran it.

m=$(mutant n1 "$NDT" \
    '    if [[ -n "$mine" && "$pgid" == "$mine" ]]; then' \
    '    if false; then')
report "N1 (control): the group signal is sent to ndt's own group" "$m" \
       "🔴 app_kill_group refuses its own group -- the caller lives"

m=$(mutant n2 "$NDT" \
    '    if (( corroborated == 0 )); then' \
    '    if false; then')
report "N2 (control): a group id known only from a stale file is signalled" "$m" \
       "an uncorroborated .pgid group is refused"

# One line, not two: the two-line form (the TERM plus the loop header under it) stopped
# resolving the moment a comment was written between them, and `mutant` would then have shipped
# an UNMUTATED copy and reported N3 as a survivor -- a gate quietly checking nothing, which is
# finding #19 exactly. tests/shell/check_gate_anchors.py caught it; keep anchors minimal.
m=$(mutant n3 "$NDT" \
    '    kill -TERM "-$pgid" 2>/dev/null' \
    '    return 2')
report "N3 (control): no group is ever signalled, so nothing can be stopped" "$m" \
       "🔴 the app's process group is empty"

# 🔴 The first draft of this one mutated the loop's `&& break` to `:`, and it SURVIVED --
# correctly, because that mutation changes nothing except how long the verifier waits: the
# decision below the loop re-reads APP_SURVIVORS and is still right. A mutation that alters no
# observable behaviour is a badly chosen mutation, not a hole in the suite, and the honest fix
# is to mutate the DECISION. Same anchor as M3, opposite direction: M3 makes it always say
# clean, this makes it never say clean.
m=$(mutant n4 "$NDT" \
    '    if (( ${#APP_SURVIVORS[@]} > 0 )); then
        err "$name is STILL RUNNING after stop' \
    '    if true; then
        err "$name is STILL RUNNING after stop')
report "N4 (control): the verifier never says clean, so no stop ever succeeds" "$m" \
       "stop returns 0"

# 2026-09-07 (lw351): re-anchored with M5, and for the same reason.
m=$(mutant n5 "$NDT" \
    '        (( ${#unnamed[@]} == 0 )) && continue
        found=$(( found + 1 ))' \
    '        found=$(( found + 1 ))')
report "N5 (control): every app is reported as an orphan, always" "$m" \
       "a clean machine has no orphans (rc 0)"

echo
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (tools/test_workflow/ndt)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
