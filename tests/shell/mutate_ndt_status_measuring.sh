#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_status_measuring.sh: `ndt status --measuring`, the light
# "is anyone measuring" that ndt serve's page probes once a minute while a measurement runs.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way the light read could stop being what Adam ruled (2026-10-01): a
# probe that is the full report again, a second copy of the answer that drifts from plain status,
# a sudo or a kernel request on the probe's path, a declaration read differently -- and must turn
# its NAMED case red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir, and the test is pointed
# at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written, and the sha256 line at the
# end says so. A mutant directory carries ports.sh, sudo_surface.sh and components.env too: ndt
# sources them from beside itself.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran. The last line is the exit code.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_status_measuring.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-measuring-mutate-XXXXXX")
# [Co-developed with claude code -- Adam] How a run ENDS is part of its record. A run stopped by a
# signal, or one that ends before its verdict line, says INCOMPLETE and never exits 0: the EXIT trap
# alone printed rc=0 for a page gate killed with SIGTERM (10-01), which reads as a pass.
# the end lines go to the stdout this gate STARTED with (fd 7): a trap that fires while a command
# redirected to a file is running prints into that file -- the rebuild gate's went into ci.log
exec 7>&1
GATE_SIGNAL=""
GATE_VERDICT=0
trap 'GATE_SIGNAL=TERM; exit 143' TERM
trap 'GATE_SIGNAL=INT; exit 130' INT
trap 'GATE_SIGNAL=HUP; exit 129' HUP
gate_end() {   # the EXIT trap; $1 = the status the shell is exiting with
    local rc="$1"
    rm -rf "$BK"
    if [[ -n "$GATE_SIGNAL" ]]; then
        echo "INCOMPLETE: stopped by SIG$GATE_SIGNAL before its verdict -- not a verdict" >&7
    elif (( ! GATE_VERDICT )); then
        echo "INCOMPLETE: ended before its verdict line -- not a verdict" >&7
        (( rc != 0 )) || rc=2
    fi
    echo "rc=$rc" >&7
    exit "$rc"
}
trap 'gate_end $?' EXIT
# what this run is about, printed by the gate itself; "?" when git cannot say
git_head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null) || git_head="?"
if git_status=$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null); then
    git_dirty=$(grep -c . <<<"$git_status")
else
    git_dirty="?"
fi
echo "head $git_head"
echo "porcelain $git_dirty tracked file(s) differ from HEAD"
echo "date $(date -Is)"
BASE_SHA=$(sha256sum "$NDT" "$TEST")

SURVIVORS=0
MUTATIONS=0

run_against() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == NOAPPLY ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (the mutation did not apply -- the anchor moved)\n' "$1"
        return
    fi
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-62s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
       "$REPO/tools/test_workflow/components.env" "$d/"
    if ! python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.stderr.write("anchor not unique (%d hits): %s\n" % (s.count(a), a[:70]))
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
    then
        echo "NOAPPLY"
        return
    fi
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
   "$REPO/tools/test_workflow/components.env" "$base/"
out=$(run_against "$base"); brc=$?
printf '  %s\n' "$(tail -1 <<<"$out")"
(( brc == 0 )) || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the light read is the light read ----------------------------------------------------------

# The probe is the full report again: every sudo, the kernel graph and the switch queries of a
# plain `ndt status` land on each probe of a running measurement -- the cost Adam ruled out.
m=$(mutant L1 "$NDT" \
    '    if [[ "${1:-}" == "--measuring" ]]; then
        local problems=()' \
    '    if false; then
        local problems=()')
report "L1: --measuring is the full report (sudo and the kernel graph on every probe)" "$m" \
       "🔴 --measuring ran no sudo, curl, OVS or bmv2 command (8 states)"

# A second copy of the answer in the light path, right for an idle lab and wrong for every
# measurement -- the drift one shared function exists to make impossible.
m=$(mutant L2 "$NDT" \
    '        local problems=()
        status_measuring_rows
        return 0' \
    '        local problems=()
        printf '\''  %-14s %s\n'\'' "measuring" "nothing"
        return 0')
report "L2: --measuring answers from its own copy (always nothing)" "$m" \
       "in_flight only: the same measuring row as plain status"

# The other side of the same drift: plain status stops calling the shared rows and keeps an
# idle-lab copy of its own.
m=$(mutant L3 "$NDT" \
    '    status_measuring_rows
    git_lines' \
    '    printf '\''  %-14s %s\n'\'' "measuring" "nothing"
    git_lines')
report "L3: plain status stops using the shared rows" "$m" \
       "in_flight only: --measuring's rows are plain status's, line for line"

# A sudo on the shared path: it lands on plain status AND on every probe.
m=$(mutant L4 "$NDT" \
    'status_measuring_rows() {
    # Declared beside observed' \
    'status_measuring_rows() {
    sudo -n ovs-vsctl list-br >/dev/null 2>&1
    # Declared beside observed')
report "L4: a sudo OVS query on the measuring rows' path" "$m" \
       "🔴 --measuring ran no sudo, curl, OVS or bmv2 command (8 states)"

# A request to the kernel under measurement on the shared path (ndt's own graph fetch).
m=$(mutant L5 "$NDT" \
    'status_measuring_rows() {
    # Declared beside observed' \
    'status_measuring_rows() {
    http_get_graph >/dev/null
    # Declared beside observed')
report "L5: a kernel get_graph_data request on the measuring rows' path" "$m" \
       "🔴 --measuring ran no sudo, curl, OVS or bmv2 command (8 states)"

# A bmv2 query on the shared path: the simple_switch_CLI a P4 status uses for its tables.
m=$(mutant L5b "$NDT" \
    'status_measuring_rows() {
    # Declared beside observed' \
    'status_measuring_rows() {
    echo "show_tables" | simple_switch_CLI --thrift-port 9090 >/dev/null 2>&1
    # Declared beside observed')
report "L5b: a bmv2 CLI query on the measuring rows' path" "$m" \
       "🔴 --measuring ran no sudo, curl, OVS or bmv2 command (8 states)"

m=$(mutant L6 "$NDT" \
    '        status_measuring_rows
        return 0
    fi' \
    '        status_measuring_rows
        return 1
    fi')
report "L6: --measuring answers 1 (ndt serve would read a failure, not a report)" "$m" \
       "nothing: --measuring answers rc 0"

# --- the answer itself, as both print it ------------------------------------------------------

# Both lose the declaration: the two agree, so only the "what they must say" check sees it.
m=$(mutant L7 "$NDT" \
    '    local declared; declared="$(measuring_declared)"
    [[ -n "$declared" ]] && printf '\''  %-14s %s\n'\'' "declared" \' \
    '    local declared; declared=""
    [[ -n "$declared" ]] && printf '\''  %-14s %s\n'\'' "declared" \')
report "L7: the measuring rows drop the declaration" "$m" \
       "declared only: the declared row"

# Only your own claim's declaration counts: somebody else's measurement no longer pauses the page.
m=$(mutant L8 "$NDT" \
    'measuring_declared() {
    [[ -f "$CLAIM" ]] || return 0' \
    'measuring_declared() {
    [[ -f "$CLAIM" ]] || return 0
    [[ "$(claim_field owner)" == "${NDT_OWNER:-}" ]] || return 0')
report "L8: somebody else's claim declares nothing" "$m" \
       "somebody else's claim: the declared row"

# An expired claim's declaration outlives its lease (honesty gate M17's mutation, here for the probe).
m=$(mutant L9 "$NDT" \
    '    local exp; exp="$(claim_field expires)"
    [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > $(date +%s) )) || return 0
    claim_field measuring' \
    '    claim_field measuring')
report "L9: an expired claim still declares a measurement" "$m" \
       "expired claim: the declared row"

# A driver with no fabric is reported as measuring: the page would stay paused on a leftover.
m=$(mutant L10 "$NDT" \
    '        if [[ "$(mn_count)" -eq 0 ]]; then
            printf '\''  %-14s %s\n'\'' "orphaned"' \
    '        if false; then
            printf '\''  %-14s %s\n'\'' "orphaned"')
report "L10: an orphaned driver reads as a measurement" "$m" \
       "orphaned (no fabric): the measuring row"

# The process table stops being read: only declared measurements are seen.
m=$(mutant L11 "$NDT" \
    '    local busy; busy="$(in_flight)"
    if [[ -n "$busy" ]]; then
        local extra;' \
    '    local busy; busy=""
    if [[ -n "$busy" ]]; then
        local extra;')
report "L11: the measuring rows stop reading the process table" "$m" \
       "in_flight only: the measuring row"

m=$(mutant L12 "$NDT" \
    '            printf '\''  %-14s %s\n'\'' "measuring" "$(printf '\''%s'\'' "$busy" | head -1 | cut -c1-72)"
            (( extra > 1 )) && printf '\''  %-14s %s\n'\'' "" "+ $(( extra - 1 )) more process(es)"' \
    '            printf '\''  %-14s %s\n'\'' "measuring" "$(printf '\''%s'\'' "$busy" | head -1 | cut -c1-72)"')
report "L12: the '+ N more' row of a measurement is lost" "$m" \
       "two drivers: the '+ 1 more' row, as plain status prints it"

# --- ndt help ---------------------------------------------------------------------------------

m=$(mutant L13 "$NDT" \
    '  status [--check | --measuring]' \
    '  status [--check]')
report "L13: ndt help does not name --measuring" "$m" \
       "ndt help names status --measuring"

echo
if [[ "$(sha256sum "$NDT" "$TEST")" != "$BASE_SHA" ]]; then
    echo "a file under test CHANGED while this gate ran -- the results above are about two versions"
    exit 3
fi
echo "files under test unchanged by this gate:"
sha256sum "$NDT" "$TEST" | sed "s|$REPO/||; s/^/  /"
echo
GATE_VERDICT=1
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s)"
(( SURVIVORS == 0 ))
