#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_check_sample_rate.sh (X-1 / X-2, decision D-2).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of the two findings -- `ndt status` printing the bmv2 build
# artefact's 1/256 while the OVS fabric it was describing was set to 1/64
# (logs/x1-22-status-blind-to-ovs-rate.log), and `ndt check` printing `ok` at a ratio of 0.65
# with nothing beside it to say that 0.75 is what 1/1024 produces -- or one of the wrong answers
# "read the right plane" invites, and must turn its NAMED case red.
#
# 🔴 TWO DIRECTIONS. The mutations marked (widening) stay GREEN where the suite requires RED:
# one reads OVSDB on every plane, which breaks P4 and the no-fabric case while satisfying every
# "the OVS rate is read" case; one invents a shortfall for a rate X1 never measured, which
# satisfies every "the expected shortfall is printed" case with a number nobody stood behind.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the suite is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written.
#
# 🔴 A mutant directory carries ports.sh, sudo_surface.sh and components.env: ndt sources them
# from beside itself and exits 2 without them, so every case would go red for the wrong reason.
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
SH_TEST="$HERE/test_ndt_check_sample_rate.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/rate-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_sh() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$SH_TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
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

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_sh "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- X-2: which plane's rate is reported ------------------------------------------------------

# 🔴 The finding verbatim: the OVS plane answered out of the bmv2 build artefact.
m=$(mutant p1 "$NDT" \
    '        ovs) ovs_sample_rate ;;' \
    '        ovs) p4_sample_rate ;;')
report "P1: the OVS plane reads the bmv2 build artefact again" "$m" \
       "ten sflow records all saying 64 -> 64"

# (widening) OVSDB on every plane. Satisfies every "the OVS rate is read" case, and answers
# nonsense on P4 -- where the compiled pipeline really is the rate -- and on an idle machine.
m=$(mutant p2 "$NDT" \
    '        *)   p4_sample_rate ;;' \
    '        *)   ovs_sample_rate ;;')
report "P2 (widening): every plane reads OVSDB" "$m" \
       "the P4 plane still reads the built json"

# The plane is worked out but never used, so `status` describes a fabric it did not ask about.
m=$(mutant p3 "$NDT" \
    '    rate="$(sample_rate "$plane_now")"' \
    '    rate="$(sample_rate p4)"')
report "P3: 'ndt status' asks for the P4 rate whatever is running" "$m" \
       "🔴 ndt status on an OVS fabric prints 1/64"

# The provenance row disappears, which is the whole reason X-2 survived for months.
# 🔴 The row moved into status_rate_rows at P2-C (TICKET-P2 §5.5) -- `status` and the package
# pipeline now decide between two sources, and the printer is one function so the two rows
# cannot describe different fabrics. The anchor follows it; the mutation is the same one.
m=$(mutant p4 "$NDT" \
    '    printf '\''  %-14s %s\n'\'' "rate source" "$(rate_source "$plane")"' \
    '    :')
report "P4: the row stops saying where the number came from" "$m" \
       "  with a source row beside it"

# --- what ten sflow records can say -----------------------------------------------------------

# 🔴 An interrupted sweep leaves a fabric with no single rate. Reporting the first record hides
# it behind a number that looks exactly like a healthy one.
m=$(mutant p5 "$NDT" \
    '        *) echo "OVS-DISAGREE:$(printf '\''%s'\'' "$vals" | tr '\''\n'\'' '\'','\'')" ;;' \
    '        *) printf '\''%s\n'\'' "$vals" | head -1 ;;')
report "P5: ten disagreeing records report the first one" "$m" \
       "an interrupted sweep is reported as DISAGREE"

# A fabric with no sflow record at all samples NOTHING; answering with a rate says the opposite.
m=$(mutant p6 "$NDT" \
    '        0) echo "OVS-NOSFLOW" ;;' \
    '        0) echo 256 ;;')
report "P6: a fabric with no sflow record is given a rate" "$m" \
       "no sflow record at all"

# 🔴 "Could not ask" reported as a value -- finding #7's shape, on the reading that decides
# every bandwidth number.
m=$(mutant p7 "$NDT" \
    '    if (( rc != 0 )); then echo "UNREADABLE:sudo -n ovs-vsctl would not answer"; return 0; fi' \
    '    if (( rc != 0 )); then echo 256; return 0; fi')
report "P7: a refused ovs-vsctl becomes a number" "$m" \
       "a refused ovs-vsctl is UNREADABLE"

# The defect the suite caught while it was being written: [:space:] eats the newlines too, so
# ten records saying 64 come back as one value, 64646464646464646464.
m=$(mutant p8 "$NDT" \
    "    vals=\"\$(printf '%s\\n' \"\$out\" | tr -d ' \\t\\r' | grep -E '^[0-9]+\$' | sort -un)\"" \
    "    vals=\"\$(printf '%s\\n' \"\$out\" | tr -d '[:space:]' | grep -E '^[0-9]+\$' | sort -un)\"")
report "P8: the record separator is deleted with the spaces" "$m" \
       "ten sflow records all saying 64 -> 64"

# The three non-rates stop being --check problems: printed, and green.
# 🔴 They moved into status_rate_problems at P2-C, which prints them and leaves cmd_status to
# collect them -- a foreign package pipeline raises none of them, and that exemption is its own
# mutation (mutate_ndt_app_package.sh M23). This one is unchanged: the OVS case stops being
# raised at all.
m=$(mutant p9 "$NDT" \
    '        OVS-NOSFLOW)    echo "no sFlow record exists on any OVS bridge' \
    '        OVS-NOSFLOW)    : "no sFlow record exists on any OVS bridge')
report "P9: a fabric that samples nothing leaves --check green" "$m" \
       "🔴 a fabric with no sflow record is a --check problem"

# --- X-1: what the ratio is expected to be at this rate ---------------------------------------

m=$(mutant p10 "$NDT" \
    '    check_rate_lines "$crate" "$cplane"' \
    '    :')
report "P10: 'ndt check' stops printing the rate at all" "$m" \
       "  and prints both"

# (widening) A shortfall is invented for every rate. Satisfies every "the expected shortfall is
# printed" case with a number no experiment produced -- and the curve saturates, so it is wrong.
m=$(mutant p11 "$NDT" \
    '        *)    return 1 ;;' \
    '        *)    echo "0.900 10.0 0" ;;')
report "P11 (widening): an unmeasured rate gets an invented shortfall" "$m" \
       "🔴 an unmeasured rate says so instead of guessing"

# A transcription guard: these three numbers are the only reason the line is worth printing.
m=$(mutant p12 "$NDT" \
    '        1024) echo "0.753 24.8 4" ;;' \
    '        1024) echo "0.900 10.0 4" ;;')
report "P12: the measured shortfall is misquoted" "$m" \
       "1/1024"

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
