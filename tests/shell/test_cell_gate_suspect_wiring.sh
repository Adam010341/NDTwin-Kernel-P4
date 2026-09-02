#!/usr/bin/env bash
#
# Tests for cell_cpu_gate_finish(): does the E round's per-cell reader see the whole gate record?
#
# [Co-developed with claude code -- Adam]
#
# The lifetime version of cpu_gate.py (2026-09-01) added `suspect` and `unattributed_cores` to
# every record. The reader in lib_e.sh kept reading verdict= and excess= and nothing else, so a
# GREEN beside 3.6 unattributed cores was logged as a quiet cell. That is the downstream half of
# KNOWN-ISSUES "CPU 汙染閘門有三個洞": the gate's arithmetic was one hole, the reader that took
# verdict= for the total was the one that made it invisible.
#
# Case 3 is the one that matters most in the long run. A record with NO suspect field comes from
# a gate that never looked, and the absence of a warning must not be what makes a cell citable --
# so it is listed as UNKNOWN, never read as false. Same family as the sentinel-equality trap:
# two "could not read" values that compare equal and pass.
#
# No fabric, no lab claim: the gate records are fixtures. EVERY call runs in a subshell with
# FORCED_ABORT=1: abort() exits 9, and outside a subshell that kills the whole test file, so a
# reader that wrongly aborted on suspect would leave no red case behind -- the mutation gate saw
# exactly that on its first run. FORCED_ABORT makes abort() skip restore_production.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_DIR="$HERE/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"

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

# --- source the SHIPPED reader, never a copy of it ----------------------------------------------
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export ROUND="$ROUND_DIR"
export LOG="$T/test.log"
export DRY_RUN=0
# shellcheck source=/dev/null
. "$ROUND_DIR/round.env" >/dev/null 2>&1 || true
LOG="$T/test.log"
# shellcheck source=/dev/null
. "$ROUND_DIR/lib_e.sh"
LOG="$T/test.log"
OUT="$T/out"              # round.env points OUT at the real raw/; every write here goes to tmp
mkdir -p "$OUT"

if ! declare -F cell_cpu_gate_finish >/dev/null; then
    echo "FAILED   lib_e.sh does not define cell_cpu_gate_finish -- the reader under test is gone"
    exit 1
fi
if [[ ! -x "${PY_PROXY:-}" ]]; then
    echo "SKIP: PY_PROXY (${PY_PROXY:-unset}) is not present; the reader cannot parse records"
    exit 0
fi

# A gate record as cpu_gate.py writes it -- one JSON object per line, last line wins.
record() {   # record <file> <verdict> <excess> [suspect-json-or-omit] [unattributed]
    local f="$1" verdict="$2" excess="$3" suspect="${4:-omit}" unatt="${5:-0.0}"
    if [[ "$suspect" == omit ]]; then
        printf '{"label":"cell_x","verdict":"%s","excess_cores":%s,"covariates":{"chrome":0.1}}\n' \
            "$verdict" "$excess" >"$f"
    else
        printf '{"label":"cell_x","verdict":"%s","excess_cores":%s,"suspect":%s,"unattributed_cores":%s,"covariates":{"chrome":0.1}}\n' \
            "$verdict" "$excess" "$suspect" "$unatt" >"$f"
    fi
}
CELL_GATE_PID=""

# --- case 1: suspect=true.  Said, listed, and NOT an abort. -------------------------------------
: >"$LOG"; rm -f "$OUT/cell_cpu/SUSPECT_CELLS"
record "$T/c1.jsonl" GREEN 0.196 true 3.635
CELL_GATE_OUT="$T/c1.jsonl"
( FORCED_ABORT=1; cell_cpu_gate_finish c1 ) >/dev/null 2>&1
check "case 1a suspect=true -> the reader returns 0 (suspect is not an abort)" 0 "$?"
check "case 1b suspect=true -> a SUSPECT line reaches the log" 1 "$(grep -c 'SUSPECT:' "$LOG")"
check "case 1c suspect=true -> the cell is listed in cell_cpu/SUSPECT_CELLS" 1 \
      "$(grep -c '^c1 true' "$OUT/cell_cpu/SUSPECT_CELLS" 2>/dev/null || echo 0)"

# --- case 2: suspect=false.  Nothing said, nothing listed. --------------------------------------
: >"$LOG"; rm -f "$OUT/cell_cpu/SUSPECT_CELLS"
record "$T/c2.jsonl" GREEN 0.01 false 0.12
CELL_GATE_OUT="$T/c2.jsonl"
( FORCED_ABORT=1; cell_cpu_gate_finish c2 ) >/dev/null 2>&1
check "case 2a suspect=false -> returns 0" 0 "$?"
check "case 2b suspect=false -> no SUSPECT line" 0 "$(grep -c 'SUSPECT:' "$LOG")"
check "case 2c suspect=false -> not listed" 0 "$(grep -c '^c2' "$OUT/cell_cpu/SUSPECT_CELLS" 2>/dev/null || echo 0)"

# --- case 3: NO suspect field.  A gate that never looked is UNKNOWN, not clean. -----------------
: >"$LOG"; rm -f "$OUT/cell_cpu/SUSPECT_CELLS"
record "$T/c3.jsonl" GREEN 0.01
CELL_GATE_OUT="$T/c3.jsonl"
( FORCED_ABORT=1; cell_cpu_gate_finish c3 ) >/dev/null 2>&1
check "case 3a no suspect field -> returns 0" 0 "$?"
check "case 3b no suspect field -> readout says UNKNOWN, not false" 1 "$(grep -c 'suspect: *UNKNOWN' "$LOG")"
check "case 3c no suspect field -> listed as UNKNOWN (absence is not a clean bill)" 1 \
      "$(grep -c '^c3 UNKNOWN' "$OUT/cell_cpu/SUSPECT_CELLS" 2>/dev/null || echo 0)"

# --- case 4: RED still aborts.  suspect handling must not have softened the verdict path. -------
: >"$LOG"
record "$T/c4.jsonl" RED 1.2 false 0.1
CELL_GATE_OUT="$T/c4.jsonl"
( FORCED_ABORT=1; cell_cpu_gate_finish c4 ) >/dev/null 2>&1
check "case 4  RED -> abort (exit 9), unchanged by the wiring" 9 "$?"

# --- case 5: UNREADABLE still aborts. ------------------------------------------------------------
: >"$LOG"
printf 'not json\n' >"$T/c5.jsonl"
CELL_GATE_OUT="$T/c5.jsonl"
( FORCED_ABORT=1; cell_cpu_gate_finish c5 ) >/dev/null 2>&1
check "case 5  UNREADABLE -> abort (exit 9), unchanged by the wiring" 9 "$?"

# --- case 6: the readout carries the number, not just the flag. --------------------------------
: >"$LOG"; rm -f "$OUT/cell_cpu/SUSPECT_CELLS"
CELL_GATE_OUT="$T/c1.jsonl"
( FORCED_ABORT=1; cell_cpu_gate_finish c6 ) >/dev/null 2>&1
check "case 6  the suspect line carries unattributed_cores" 1 "$(grep -c 'suspect: *true unattributed=3.635' "$LOG")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
