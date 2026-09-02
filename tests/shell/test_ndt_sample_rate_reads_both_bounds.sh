#!/usr/bin/env bash
#
# Tests for ndt's sample_rate(): does the instrument see a pipeline that samples NOTHING?
#
# [Co-developed with claude code -- Adam]
#
# The compiled pipeline draws random(lo, hi) and clones when the draw is 0. sample_rate() used
# to read only hi and print "1/256" for a JSON whose lo had been set to 1 -- the exact artefact
# a failed restore of the 09-01 zero cell or the 09-02 paired A/B leaves behind, observed live
# at 12:23 on 2026-09-02 (RESTORE-SWEEP). An instrument that reports a rate for a pipeline with
# no sampling is worse than one that reports nothing: `ndt status` is the check an operator runs
# to answer "is the lab back at production", and it answered yes.
#
# No fabric, no lab claim, no ndt subcommand: the JSON is a fixture and only the functions are
# called. The function reads $REPO at call time, so the fixture root is swapped in after sourcing.
#
# Run:  bash tests/shell/test_ndt_sample_rate_reads_both_bounds.sh
# Env:  NDT_UNDER_TEST=<path>  test another copy of ndt (the mutation gate and the red run use it)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"

PASS=0; FAIL=0
t_ok()   { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad()  { FAIL=$((FAIL+1)); printf '  FAILED   %s\n    %s\n' "$1" "$2"; }

# shellcheck source=/dev/null
source "$NDT" || { echo "  FAILED   could not source $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

TMPROOT="$(mktemp -d /tmp/ndt-sample-rate-XXXXXX)"
cleanup() { [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-sample-rate-* ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT
mkdir -p "$TMPROOT/p4_proxy/p4_src/build"
REPO="$TMPROOT"   # sample_rate() and source_ahead_of_build() read this at call time
BUILT="$TMPROOT/p4_proxy/p4_src/build/ndtwin_switch.json"
SRC="$TMPROOT/p4_proxy/p4_src/ndtwin_switch.p4"

# The primitive exactly as p4c emits it (copied from a real build: actions[15].primitives[0]).
write_json() {   # $1 = lo hexstr, $2 = hi hexstr
    cat > "$BUILT" <<JSON
{"actions":[{"name":"sample","primitives":[{"op":"modify_field_rng_uniform","parameters":[{"type":"field","value":["scalars","metadata.sample_rand"]},{"type":"hexstr","value":"$1"},{"type":"hexstr","value":"$2"}]}]}]}
JSON
}

# --- 1. production: lo=0 hi=255 -> 1 in 256 -------------------------------------------------
write_json 0x0000 0x00ff
out="$(sample_rate)"
[[ "$out" == "256" ]] && t_ok "production lo=0 hi=255 reads 256" || t_bad "production lo=0 hi=255 reads 256" "got: $out"

# --- 2. the lie: lo=1 hi=255 samples nothing, and must NOT read as 256 ---------------------
write_json 0x0001 0x00ff
out="$(sample_rate)"
if [[ "$out" != "256" && "$out" == *DISABLED* ]]; then
    t_ok "lo=1 hi=255 is reported DISABLED, not 1/256"
else
    t_bad "lo=1 hi=255 is reported DISABLED, not 1/256" "got: $out"
fi

# --- 3. the upper bound is still read (regression for the 08-20 drift catch) ----------------
write_json 0x0000 0x03ff
out="$(sample_rate)"
[[ "$out" == "1024" ]] && t_ok "lo=0 hi=1023 reads 1024" || t_bad "lo=0 hi=1023 reads 1024" "got: $out"

# --- 4. the label the four print sites use never says 1/DISABLED ---------------------------
if declare -F rate_label >/dev/null; then
    l1="$(rate_label 256)"; l2="$(rate_label "$(write_json 0x0001 0x00ff; sample_rate)")"
    if [[ "$l1" == "1/256" && "$l2" == *DISABLED* && "$l2" != 1/* ]]; then
        t_ok "rate_label: 1/256 for a rate, DISABLED text (not 1/DISABLED) for a dead pipeline"
    else
        t_bad "rate_label: 1/256 for a rate, DISABLED text (not 1/DISABLED) for a dead pipeline" "got: [$l1] [$l2]"
    fi
else
    t_bad "rate_label: 1/256 for a rate, DISABLED text (not 1/DISABLED) for a dead pipeline" "rate_label is not defined"
fi

# --- 5. source_ahead_of_build: the R1 direction stale_pipeline() cannot see ----------------
if declare -F source_ahead_of_build >/dev/null; then
    write_json 0x0000 0x00ff
    touch -d '2026-01-01 00:00:00' "$SRC"; touch -d '2026-01-02 00:00:00' "$BUILT"
    if source_ahead_of_build; then t_bad "source older than build -> not ahead" "returned true"; else t_ok "source older than build -> not ahead"; fi
    touch -d '2026-01-03 00:00:00' "$SRC"
    if source_ahead_of_build; then t_ok "source newer than build -> ahead (restored .p4, never recompiled)"; else t_bad "source newer than build -> ahead (restored .p4, never recompiled)" "returned false"; fi
else
    t_bad "source_ahead_of_build exists" "function is not defined"
fi

echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
