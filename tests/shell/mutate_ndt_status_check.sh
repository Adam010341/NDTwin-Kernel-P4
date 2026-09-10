#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_status_check_baseline.sh (finding #8, decision N12 (a)).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of #8 -- the `ndt status --check` that reported a healthy
# 4-host OVS fabric as "the kernel graph does not match the topology file" because its baseline
# came from a P4-only knob, and that went green comparing an OVS fabric against a P4 model file
# because its whole comparison was (hosts, edges) -- and must turn its named case red. A
# mutation nobody catches means that case proves nothing.
#
# 🔴 Two directions, because "compare more things" has wrong answers that look like fixes. The
# mutations labelled (widening) are the ones that stay GREEN where the suite requires RED: a
# --check that compares nothing at all, one that treats a missing baseline as a pass, one that
# prints every comparison and reports no difference. Each of those satisfies every "did it go
# red on the broken fixture" question a fires-only gate asks, and each would put back exactly
# the property #8 is about -- a check with no discriminating power that looks like a check.
#
# 🔴 THE WIRING IS MUTATED TOO (M6/M7/M8). The record can exist, be readable, and be compared
# correctly while nothing ever writes it; --check then answers "could not check" for ever and
# every case above it still passes. Existence is not wiring, so the calls in up_ovs, up_p4 and
# cmd_down are deleted here and the suite has to notice.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it right now -- and the sha256 lines at the bottom say so.
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
TEST="$HERE/test_ndt_status_check_baseline.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-checkbase-mutate-XXXXXX")
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
# function's own `local ... file="$2" old="$3"` line. A gate it cannot read is a gate it is not
# checking -- finding #28, and the shape this file was first written in (the
# mutate_ndt_up_target.sh style, anchors in heredoc files) is one it reports as NO-ANCHORS.
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

# --- the defect itself ---------------------------------------------------------------------

# #8 exactly: the baseline goes back to being derived from p4_proxy/mininet/host_count_override,
# a P4-only knob that `ndt up ovs4` never writes. On a healthy ovs4 that is the false red.
m=$(mutant m1 "$NDT" \
    '    plane="$(up_target_field plane)";       hosts="$(up_target_field hosts)"' \
    '    plane="$(up_target_field plane)";       hosts="$(host_count)"')
report "M1: the host baseline comes from the P4 knob again" "$m" \
       "a healthy ovs4 exits 0"

# The second half of #8, and the reason a "which file" fix alone is not one: the data plane kind
# is printed but not compared, so the comparison is (hosts, edges) again -- a pair that the P4
# and OVS 4-host models share, and therefore a pair that cannot tell the two planes apart.
m=$(mutant m2 "$NDT" \
    '        *)       _ut_row "dataplane" "$kind" "$plane" ;;' \
    '        *)       printf "  %-14s %s\n" "dataplane" "$kind" ;;')
report "M2: the data plane is shown but not compared" "$m" \
       "🔴 a P4 fabric under an ovs4 record is not ok"

# "Could not check" collapses back into "checked, and it does not match" -- the two answers this
# fix separates. A reader who sees the mismatch sentence believes a comparison happened.
m=$(mutant m3 "$NDT" \
    '        return 3
    fi
    local plane hosts topo sum m_hosts m_edges at by' \
    '        return 1
    fi
    local plane hosts topo sum m_hosts m_edges at by')
report "M3: no record is reported as a mismatch" "$m" \
       "🔴 no baseline exits 3, not 0 and not 1"

# A reading that failed is reported as a value rather than as a failure: 0 host namespaces
# becomes "the fabric has 0 hosts". Same shape verify_p4 was fixed for on 08-30 -- the branch
# that let an unverifiable check print a verdict.
# 🔴 The anchor carries the comment line above it because the two lines below are BYTE
# IDENTICAL to verify_p4s own fabric-side assertion -- check_gate_anchors.py caught the
# duplicate, which is what it is for.
m=$(mutant m4 "$NDT" \
    '    #    (same rule as the model/fabric assertion in verify_p4).
    local live_hosts; live_hosts="$(fabric_host_count)"
    if [[ ! "$live_hosts" =~ ^[0-9]+$ ]] || [[ "$live_hosts" -eq 0 ]]; then' \
    '    #    (same rule as the model/fabric assertion in verify_p4).
    local live_hosts; live_hosts="$(fabric_host_count)"
    if [[ ! "$live_hosts" =~ ^[0-9]+$ ]]; then')
report "M4: a failed fabric reading becomes a host count of 0" "$m" \
       "  named as not compared, not as agreement"

# The model file can be edited under a running kernel and nothing says so. The kernel pulls its
# topology once and never retries, so this is invisible in every other field.
m=$(mutant m5 "$NDT" \
    '            UP_TARGET_PROBLEMS+=("topology file: $topo has been edited since the ndt up that loaded it; the kernel pulls once and never retries")
            bad=1' \
    '            :')
report "M5: a model file edited since up is not reported" "$m" \
       "the model file edited under a running kernel is red"

# --- the wiring: the record exists and nothing writes it -------------------------------------

m=$(mutant m6 "$NDT" \
    '    record_up_target ovs "$ovs_hosts" "$ovs_topo"' \
    '    :')
report "M6: ndt up ovs stops recording its target" "$m" \
       "'ndt up ovs4' records its target"

m=$(mutant m7 "$NDT" \
    '    record_up_target p4 "$hosts" "$topo"' \
    '    :')
report "M7: ndt up p4 stops recording its target" "$m" \
       "'ndt up p4' records its target too"

m=$(mutant m8 "$NDT" \
    '    clear_up_target

    echo
    say "verify clean"' \
    '    echo
    say "verify clean"')
report "M8: ndt down leaves a stale baseline behind" "$m" \
       "'ndt down' drops the record"

# Finding #7s conflation, inside the new code: a refused `sudo -n ovs-vsctl` read as "there is
# no OVS here". That answer is indistinguishable from a live P4 fabric, so a check built on it
# reports a plane the machine never told it.
m=$(mutant m9 "$NDT" \
    '    (( brc != 0 )) && { echo unknown; return 0; }' \
    '    (( brc != 0 )) && { echo none; return 0; }')
report "M9: a refused ovs-vsctl becomes no OVS here" "$m" \
       "🔴 a refused ovs-vsctl is 'unknown', not 'none'"

# --- widenings: mutants that stay GREEN where the suite requires RED --------------------------

# N1, the control: --check compares nothing at all and calls every lab healthy. It passes every
# fires-side case above, because a check that never fails cannot fail on the wrong fixture.
m=$(mutant n1 "$NDT" \
    '    UP_TARGET_PROBLEMS=()
    local f; f="$(up_target_file)"' \
    '    UP_TARGET_PROBLEMS=()
    return 0
    local f; f="$(up_target_file)"')
report "N1 (control, always green): --check compares nothing" "$m" \
       "🔴 a P4 fabric under an ovs4 record is not ok"

# N2: no baseline is silently a pass -- "could not check" reported as "checked and matched",
# which is the confusion the third exit code exists to prevent.
m=$(mutant n2 "$NDT" \
    '        return 3
    fi
    local plane hosts topo sum m_hosts m_edges at by' \
    '        return 0
    fi
    local plane hosts topo sum m_hosts m_edges at by')
report "N2 (widening, green): no baseline is a pass" "$m" \
       "🔴 no baseline exits 3, not 0 and not 1"

# N3: every field is compared, every difference is printed, and none is ever reported. The
# output is indistinguishable from a working check -- printing a comparison is not making one.
m=$(mutant n3 "$NDT" \
    '            _ut_differs "$field" "$live" "$want"' \
    '            :')
report "N3 (widening, green): differences printed, never reported" "$m" \
       "a 128-host graph under a 4-host record is red"

# --- F9: the suite reads its own tree (F-OFFLINE-1 §1.13) -------------------------------------

# The sim evidence log stops being derived from the tree the LAB acts in and is hard-coded to
# the main checkout, which is what this suite was reading until 2026-09-11 -- a 148717-byte
# root-owned file. The F9 cells exist to make that a red rather than a hidden input, and this
# is the mutation that asks them to prove it.
m=$(mutant m10 "$NDT" \
    '        sim)    printf '"'"'%s/.test_run/logs/app_sim.log'"'"' "$(lab_kernel_dir)" ;;' \
    '        sim)    printf '"'"'%s/.test_run/logs/app_sim.log'"'"' /home/adam/Desktop/NDTwin-Kernel ;;')
report "M10: sim's evidence log is hard-coded to the main checkout (F9)" "$m" \
       "  🔴 sim's evidence log is inside the fixture"


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
