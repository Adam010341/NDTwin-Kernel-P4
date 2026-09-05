#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_honesty.sh (09-05 night round: I-1/W12).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of the finding -- the `ndt status`/`--check` that answered
# "no 'ndt up' has run in this checkout" and named a P4 model file, minutes after an OVS fabric
# had been built and torn down in that same checkout -- and must turn its NAMED case red. A
# mutation nobody catches means that case proves nothing.
#
# 🔴 Two directions. The mutations labelled (widening) are the ones that stay GREEN where the
# suite requires RED: one that claims a `down` happened whether or not anything says so, and
# one that answers "could not check" to everything. Each satisfies every "did it go red on the
# broken fixture" question a fires-only gate asks, and each puts back the property the finding
# is about -- a report that states things it was never told.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it right now, and the lab was in use the night this was added --
# and the sha256 line at the bottom says so.
#
# 🔴 A mutant directory carries ports.sh and sudo_surface.sh too. ndt sources both from beside
# itself, so a copy without them exits 2 at source time and every case goes red for a reason
# that has nothing to do with the mutation (MERGE-LOG.md, 09-03).
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_honesty.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-honesty-mutate-XXXXXX")
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
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
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

# --- I-1: the report states things it was never told -----------------------------------------

# The evidence is stopped being read at all. Everything downstream then honestly says "this
# checkout cannot tell" -- which is right for 1C and wrong for 1A, where the file is there.
m=$(mutant m1 "$NDT" \
    'kernel_exit_file() { echo "${NDT_KERNEL_EXIT:-$REPO/.test_run/pids/kernel.exit}"; }' \
    'kernel_exit_file() { echo "${NDT_KERNEL_EXIT:-$REPO/.test_run/pids/never-written}"; }')
report "M1: the exit record is no longer read" "$m" \
       "🔴 the record line names the clearing, and when"

# I-1 verbatim: the absence of a record rendered as a claim about history.
m=$(mutant m2 "$NDT" \
    '"${Y}none -- the last '\''ndt up'\'' record was cleared by '\''ndt down'\'' at $kx_at; history is in .test_run/pids/*.exit${N}  (${f#$REPO/})"' \
    '"${Y}none -- no '\''ndt up'\'' has run in this checkout${N}  (${f#$REPO/})"')
report "M2: 'no ndt up has run in this checkout' comes back" "$m" \
       "🔴 the sentence that was false is gone"

# The other half of I-1, and the carrier that actually misled a script: the P4-only knob's model
# file printed on the `topology` row, where a reader takes it for the plane that just ran.
m=$(mutant m3 "$NDT" \
    'printf '\''  %-14s %s\n'\'' "topology" "unknown (no up.target); last kernel.exit ran $kx_plane"' \
    'printf '\''  %-14s %s\n'\'' "topology" "${topo#$REPO/}   (the P4 model that knob selects)"')
report "M3: the P4 model is printed as the topology again" "$m" \
       "🔴 no P4 model file is printed -- that path was the carrier"

# The plane is asserted rather than read. A constant satisfies every OVS case in the suite,
# which is why 1D exists.
m=$(mutant m4 "$NDT" \
    '        kx_plane="$(last_kernel_plane)"; kx_at="$(kernel_exit_field at)"' \
    '        kx_plane=ovs; kx_at="$(kernel_exit_field at)"')
report "M4: the plane is a constant, not a reading" "$m" \
       "'last kernel.exit ran p4' after a P4 run"

# Finding #7's conflation in a new place: a command this script cannot classify turned into a
# plane anyway. "I could not tell" and "it was ovs" are different answers.
m=$(mutant m5 "$NDT" \
    '        *StaticNetworkTopologyP4_*)  echo p4;  return 0 ;;
    esac
    return 1' \
    '        *StaticNetworkTopologyP4_*)  echo p4;  return 0 ;;
    esac
    echo ovs; return 0')
report "M5: an unclassifiable command becomes a plane" "$m" \
       "  rather than picking one"

# --- widenings: mutants that stay GREEN where the suite requires RED --------------------------

# N1: a `down` is announced whether or not anything recorded one. It passes every fires-side
# case in 1A/1B, because a report that always says the new sentence cannot fail to say it.
m=$(mutant n1 "$NDT" \
    '        if [[ -n "$kx_at" ]]; then
            printf' \
    '        if true; then
            printf')
report "N1 (widening, green): a teardown is announced unconditionally" "$m" \
       "🔴 no 'cleared by ndt down' without a record of one"

# N2, the control: --check answers "could not check" to everything. Every case in 1A-1D is about
# the no-record path, so all of them stay green while the check stops checking.
m=$(mutant n2 "$NDT" \
    '    say "up target"
    if [[ ! -f "$f" ]]; then' \
    '    say "up target"
    if true; then')
report "N2 (control, never checks): every lab has no baseline" "$m" \
       "  and --check checks: rc 0, not 3"

echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
