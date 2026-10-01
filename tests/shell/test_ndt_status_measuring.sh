#!/usr/bin/env bash
#
# Tests for `ndt status --measuring`: the light read of "is anyone measuring".
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS EXISTS. While a measurement runs, ndt serve's page pauses its 10 s refresh and probes
# once a minute. Until 2026-10-01 the probe was a plain `ndt status`: measured on this laptop with
# a P4 fabric up and iperf3 running, 564 tasks, 6 sudo calls and one get_graph_data request to the
# kernel under measurement, per probe (logs/ndt-serve-gui-v2/live-probe-cost/RESULTS.md). Adam
# ruled the probe must ask only "is anyone measuring": the claim's measuring= and the process
# table, with no sudo, no request to the kernel and no OVS or bmv2 query.
#
# Two things are pinned here, and each is half of the ruling:
#   1. THE SAME ANSWER. `--measuring` prints the rows plain `ndt status` prints for the question
#      -- `declared`, `measuring`, or `orphaned` -- line for line, in every fixture state below,
#      and each state's rows are also checked against what they must say (two copies that agree
#      on a wrong answer would pass the first check alone).
#   2. NOTHING HEAVY. Every command the ruling names is a recording shim on PATH, and `--measuring`
#      calls none of them in any state; plain `ndt status`, run with the same shims, does call them
#      -- the control that says the shims are on PATH and recording.
#
# The process table is a fixture: a `ps` shim answers the three listings ndt's scans read
# (in_flight: pid,comm,args; mn_count and the host count: args; bmv2_count: comm) from a file, and
# anything else goes to the real ps. The real in_flight and mn_count parse it -- only their input
# is fixed, so no iperf3 or Mininet of this machine's decides a verdict.
#
# Driven against the real script in a copy shaped like the repo (REPO resolves to the sandbox), so
# the claim file is the sandbox's and the shared .test_run is never touched.
#
# Env:  NDT_UNDER_TEST=<path>   (tests/shell/mutate_ndt_status_measuring.sh points this at a copy)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT_SRC="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

[[ -f "$NDT_SRC" ]] || { echo "  FAILED   no ndt at $NDT_SRC"; echo "Ran 1 checks, 1 failed"; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-status-measuring-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/tools/test_workflow" "$SANDBOX/.test_run" "$SANDBOX/shim"
cp "$NDT_SRC" "$SANDBOX/tools/test_workflow/ndt"
# ndt sources these from beside itself; without them it exits 2 before any subcommand
for sib in ports.sh sudo_surface.sh components.env; do
    cp "$(dirname "$NDT_SRC")/$sib" "$SANDBOX/tools/test_workflow/$sib" \
        || { echo "  FAILED   $sib is not beside $NDT_SRC"; echo "Ran 1 checks, 1 failed"; exit 1; }
done
NDT="$SANDBOX/tools/test_workflow/ndt"
CLAIM="$SANDBOX/.test_run/lab.claim"
FIXTURE="$SANDBOX/ps.fixture"
LIGHT_CALLS="$SANDBOX/light.calls"
FULL_CALLS="$SANDBOX/full.calls"
: > "$LIGHT_CALLS"; : > "$FULL_CALLS"

# --- the shims -------------------------------------------------------------------------------
REAL_PS="$(type -P ps)"
[[ -n "$REAL_PS" ]] || { echo "  FAILED   no ps on PATH"; echo "Ran 1 checks, 1 failed"; exit 1; }
cat > "$SANDBOX/shim/ps" <<EOF
#!/bin/bash
# the process table of the fixture, for the three listings ndt's scans read; the rest is real
if [[ -f '$FIXTURE' ]]; then
    case "\$*" in
        "-eo pid=,comm=,args=") awk -F'\t' '{ printf "%7s %s %s\n", \$1, \$2, \$3 }' '$FIXTURE'; exit 0 ;;
        "-eo args=")            cut -f3 '$FIXTURE'; exit 0 ;;
        "-eo comm=")            cut -f2 '$FIXTURE'; exit 0 ;;
    esac
fi
exec '$REAL_PS' "\$@"
EOF
# What the ruling names -- sudo, a request to the kernel, an OVS or bmv2 query -- plus the lab's own
# helpers. Each records its argv in \$CALLS_LOG and refuses: sudo in sudo's own words (ndt reads
# that as a refused grant, tests/shell/lib_probe_stub.sh), the rest with rc 1. None answers, so a
# plain `ndt status` here never sees a lab.
FORBIDDEN=(sudo curl wget nc ncat ovs-vsctl ovs-ofctl ovs-appctl ovs-dpctl simple_switch
           simple_switch_grpc simple_switch_CLI mnexec ndtwin-lab tc)
for c in "${FORBIDDEN[@]}"; do
    cat > "$SANDBOX/shim/$c" <<EOF
#!/bin/bash
printf '%s %s\n' '$c' "\$*" >> "\${CALLS_LOG:-/dev/null}"
[[ '$c' == sudo ]] && echo "sudo: a password is required" >&2
exit 1
EOF
done
chmod +x "$SANDBOX/shim"/*
SHIMMED_PATH="$SANDBOX/shim:$PATH"

export NDT_OWNER=fixture-me
light() { (cd "$SANDBOX" && CALLS_LOG="$LIGHT_CALLS" PATH="$SHIMMED_PATH" NO_COLOR=1 bash "$NDT" status --measuring 2>/dev/null); }
full()  { (cd "$SANDBOX" && CALLS_LOG="$FULL_CALLS" PATH="$SHIMMED_PATH" NO_COLOR=1 bash "$NDT" status 2>/dev/null); }

# The value of a row as ndt serve reads it (serve.py MEASURING_LINE / DECLARED_LINE): the first
# `  <name>  <value>` line, trailing blanks dropped; "-" when there is no such row.
row() {   # <name> <text>
    local v
    v="$(printf '%s\n' "$2" | sed -n "s/^  $1  *//p" | head -1 | sed 's/[[:space:]]*$//')"
    printf '%s' "${v:--}"
}

# --- the fixture states ----------------------------------------------------------------------
no_claim() { rm -f "$CLAIM"; }
claim() {   # <owner> <expires epoch> <measuring=>
    printf 'owner=%s\nexpires=%s\nnote=fixture note\nexclusive_cpu=no\nmeasuring=%s\n' "$1" "$2" "$3" > "$CLAIM"
}
LIVE="$(( $(date +%s) + 3600 ))"
IPERF=$'4242\tiperf3\tiperf3 -c 10.0.0.2 -p 5201 -t 480 -i 30'
MEASURE_SH=$'4243\tbash\tbash tools/test_workflow/measure.sh cell-3'
FABRIC=$'4300\tbash\tbash --norc -is mininet:h1'
OTHER=$'4400\tbash\tbash -c sleep 600'
procs() { if (( $# )); then printf '%s\n' "$@" > "$FIXTURE"; else : > "$FIXTURE"; fi; }

# state <label> <declared row> <measuring row> <orphaned row> -- runs both and compares
state() {
    local label="$1" want_decl="$2" want_meas="$3" want_orph="$4" L F rc bad
    L="$(light)"; rc=$?
    F="$(full)"
    check "$label: --measuring answers rc 0" "0" "$rc"
    # 1. the same answer: a block plain status prints, line for line, and the same rows
    if [[ -n "$L" && $'\n'"$F"$'\n' == *$'\n'"$L"$'\n'* ]]; then
        check "$label: --measuring's rows are plain status's, line for line" "yes" "yes"
    else
        check "$label: --measuring's rows are plain status's, line for line" "$L" "(not a block of plain status: $F)"
    fi
    check "$label: the same declared row as plain status"  "$(row declared "$F")"  "$(row declared "$L")"
    check "$label: the same measuring row as plain status" "$(row measuring "$F")" "$(row measuring "$L")"
    check "$label: the same orphaned row as plain status"  "$(row orphaned "$F")"  "$(row orphaned "$L")"
    # ... and what they must say
    check "$label: the declared row"  "$want_decl" "$(row declared "$L")"
    check "$label: the measuring row" "$want_meas" "$(row measuring "$L")"
    check "$label: the orphaned row"  "$want_orph" "$(row orphaned "$L")"
    # 2. the measuring rows and nothing else (17 blanks: a row's continuation, printf "  %-14s %s" with an empty name)
    bad="$(printf '%s\n' "$L" | grep -vE '^  (declared|measuring|orphaned) |^ {17}[^ ]' || true)"
    check "$label: --measuring prints the measuring rows and nothing else" "" "$bad"
    LAST_LIGHT="$L"; LAST_FULL="$F"
}

DECL_TAIL="   (claim measuring=; 'ndt check' refuses while set)"
IPERF_ROW="iperf3 -c 10.0.0.2 -p 5201 -t 480 -i 30"

echo "ndt status --measuring: the same answer as plain status"

no_claim; procs "$OTHER"
state "nothing" "-" "nothing" "-"

claim fixture-me "$LIVE" "matrix cell 3/8"; procs "$OTHER"
state "declared only" "matrix cell 3/8$DECL_TAIL" "nothing" "-"

no_claim; procs "$OTHER" "$IPERF" "$FABRIC"
state "in_flight only" "-" "$IPERF_ROW" "-"

claim fixture-me "$LIVE" "matrix cell 3/8"; procs "$IPERF" "$FABRIC"
state "declared and in_flight" "matrix cell 3/8$DECL_TAIL" "$IPERF_ROW" "-"

# an expired claim declares nothing, as it holds nothing (measuring_declared)
claim fixture-me 1 "a declaration past its lease"; procs "$OTHER"
state "expired claim" "-" "nothing" "-"

# somebody else's live claim: what it declares is declared all the same
claim someone-else "$LIVE" "their sampling matrix"; procs "$IPERF" "$FABRIC"
state "somebody else's claim" "their sampling matrix$DECL_TAIL" "$IPERF_ROW" "-"

# a driver with no fabric is a leftover, not a measurement: no measuring row at all
no_claim; procs "$IPERF"
state "orphaned (no fabric)" "-" "-" "$IPERF_ROW"
check "orphaned (no fabric): says they are leftovers" "yes" \
      "$(grep -q 'no fabric is running, so these are leftovers' <<<"$LAST_LIGHT" && echo yes || echo no)"

no_claim; procs "$IPERF" "$MEASURE_SH" "$FABRIC"
state "two drivers" "-" "$IPERF_ROW" "-"
check "two drivers: the '+ 1 more' row, as plain status prints it" "yes" \
      "$(grep -q '^ \{17\}+ 1 more process(es)$' <<<"$LAST_LIGHT" && echo yes || echo no)"

echo
echo "ndt status --measuring: no sudo, no kernel request, no OVS or bmv2 query"
check "🔴 --measuring ran no sudo, curl, OVS or bmv2 command (8 states)" "" "$(sort -u "$LIGHT_CALLS")"
# the control: the same shims, the same states, plain status -- they are on PATH and recording
check "  control: plain status, through the same shims, calls sudo" "yes" \
      "$(grep -q '^sudo ' "$FULL_CALLS" && echo yes || echo no)"
check "  control: the process table both read is the fixture" "$IPERF_ROW" "$(row measuring "$LAST_FULL")"

echo
echo "ndt help"
HELP="$(bash "$NDT" help 2>&1)"
check "ndt help names status --measuring" "yes" \
      "$(grep -qF 'status [--check | --measuring]' <<<"$HELP" && echo yes || echo no)"
check "  and says what it reads and what it does not" "yes" \
      "$(tr -s ' \n' ' ' <<<"$HELP" | grep -qF 'It reads the claim file and the process table and nothing else: no sudo, no kernel request, no OVS or bmv2 query.' && echo yes || echo no)"

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
