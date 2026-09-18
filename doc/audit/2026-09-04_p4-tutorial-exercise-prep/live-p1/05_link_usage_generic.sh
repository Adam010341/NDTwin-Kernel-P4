#!/usr/bin/env bash
#
# P3 live acceptance ⑤ -- the GENERIC cell: link usage follows the iperf path, three groups.
#
# [Co-developed with claude code -- Adam]
#
# TICKET-P3 §2.7. Every other live step in this directory is a claim about one exercise's
# program. This one is a claim about NDTwin: while a flow crosses the fabric, the twin's
# `link_bandwidth_usage_bps` must be non-zero exactly on the interfaces that carried it and zero
# on the inter-switch interfaces that did not -- whatever program the switches are running.
#
# 🔴 THREE GROUPS, AND THE THIRD IS THE ONE THAT MAKES THE OTHER TWO MEAN ANYTHING.
#
#   1  link         exercises/basic's package (the exercise's OWN program on every switch),
#                   `--telemetry link`: the samples come from `tc ... action sample` on the
#                   switch-side veths and the root psample emitter. This is the group the whole
#                   of TICKET-P3 §2.2 exists for -- a program with no cooperative header at all,
#                   and link usage measured anyway.
#   2  cooperative  the SAME exercise converted with `--ndtwin-pipeline`, so every switch runs
#                   NDTwin's own program and the samples come from the pipeline's clone to the
#                   CPU port. `basic`'s own program has no packet_in header, so `cooperative`
#                   over group 1's package would be refused at startup (§2.1) -- which is why
#                   this group changes the PACKAGE and not just the word.
#   3  none         the same fabric as group 2 with `--telemetry none`. Nothing samples, and the
#                   assertion inverts: every interface that carried the flow must integrate to
#                   EXACTLY zero in the twin. Without it, "usage follows the path" is satisfied
#                   by a twin that reports a constant non-zero on every edge, for ever.
#
# 🔴 THE ON-PATH SET IS MEASURED IN EVERY GROUP, not carried over from the first. It is the
# tx_bytes delta on each `sN-ethP` across that group's own window; a path this script decided
# once and reused would be this script agreeing with itself across three different fabrics.
#
# 🔴 NOTHING HERE USES pkill/pgrep. The iperf server each round starts is stopped by the pid
# link_usage_round holds; the fabric is torn down by `ndt down`.
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/05_link_usage_generic.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/basic}"
PKG_FOREIGN="$PKG_ROOT/basic"
PKG_NDTWIN="$PKG_ROOT/basic-ndtwin-pipeline"
P4C="${P4C:-/usr/local/bin/p4c-bm2-ss}"

start_step 05_link_usage_generic

[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR=)"
[[ -x "$P4C" ]]      || die "no p4c at $P4C -- the packages below have to be compiled first"

# --- 0. build both packages BEFORE the lab is touched ------------------------------------------
# 🔴 The same order 02 and 02b use: convert and pre-flight decide whether this round can run at
# all and neither touches the lab, so a package that will not pre-flight must not have held the
# claim while it was being rejected.
say "compiling exercises/basic (solution) and converting it twice"
mkdir -p "$EXERCISE/build" "$EXERCISE/logs" "$EXERCISE/pcaps"
"$P4C" --p4v 16 --p4runtime-files "$EXERCISE/build/basic.p4.p4info.txtpb" \
       -o "$EXERCISE/build/basic.json" "$EXERCISE/solution/basic.p4" \
       > "$RUN/10_p4c.txt" 2>&1 || die "p4c failed -- see $(basename "$RUN")/10_p4c.txt"
note "build/basic.json sha256 $(sha256sum "$EXERCISE/build/basic.json" | cut -c1-16)  (the SOLUTION, compiled to the skeleton's name)"

rm -rf "$PKG_FOREIGN" "$PKG_NDTWIN"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" \
      --topology pod-topo/topology.json --p4 solution/basic.p4 --out "$PKG_FOREIGN" \
      > "$RUN/11_convert_foreign.txt" 2>&1 || die "convert.py (--p4) failed -- see $(basename "$RUN")/11_convert_foreign.txt"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" \
      --topology pod-topo/topology.json --p4 solution/basic.p4 --ndtwin-pipeline --out "$PKG_NDTWIN" \
      > "$RUN/12_convert_ndtwin.txt" 2>&1 || die "convert.py (--ndtwin-pipeline) failed -- see $(basename "$RUN")/12_convert_ndtwin.txt"
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG_FOREIGN" > "$RUN/13_preflight_foreign.txt" 2>&1 \
    || die "pre-flight FAILED for $PKG_FOREIGN -- see $(basename "$RUN")/13_preflight_foreign.txt"
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG_NDTWIN" > "$RUN/14_preflight_ndtwin.txt" 2>&1 \
    || die "pre-flight FAILED for $PKG_NDTWIN -- see $(basename "$RUN")/14_preflight_ndtwin.txt"
note "both packages pre-flight PASS"

# 🔴 THE TWO PACKAGES REALLY ARE THE TWO CASES, asserted rather than assumed. If
# --ndtwin-pipeline did not null the pipelines, group 2 would be group 1 under a different
# package name and "cooperative" would be a word this script printed.
FPIPE="$(run_app_pipeline_kind "$PKG_FOREIGN")"
NPIPE="$(run_app_pipeline_kind "$PKG_NDTWIN")"
note "pipeline kinds: --p4 -> $FPIPE   --ndtwin-pipeline -> $NPIPE"
[[ "$FPIPE" == foreign:* ]] || die "refusing: $PKG_FOREIGN is '$FPIPE', not a foreign pipeline -- group 1 would not be the case it is for"
[[ "$NPIPE" == ndtwin ]]    || die "refusing: $PKG_NDTWIN is '$NPIPE', not NDTwin's own pipeline -- group 2 would be group 1 again"

# 🔴 THE TELEMETRY KNOB IS SNAPSHOT BY start_step AND PUT BACK BY THE EXIT TRAP, beside the host
# knob (_common.sh's snapshot_telemetry_knob / restore_telemetry_knob). This step moves it three
# times and nothing downstream refuses over it: `ndt down` leaves it and `ndt release` does not
# read it, so the trap is the only thing that keeps this round from deciding the next one's
# telemetry source.

take_claim "live-p1/05: three telemetry groups over exercises/basic"

# group <n> <label> <package> <telemetry word> <follows|absent> -- one bring-up, one measurement.
group() {
    local n="$1" label="$2" pkg="$3" word="$4" expect="$5" dir="$RUN/${n}_${label}"
    say "group $n: $label   (package $(basename "$pkg"), --telemetry $word, expect $expect)"
    if ! "$NDT" up p4 --app "$pkg" --telemetry "$word" > "$dir.up.txt" 2>&1; then
        sed 's/^/     /' "$dir.up.txt" | tail -25
        fail "group $n ($label): 'ndt up p4 --app --telemetry $word' failed -- see $(basename "$dir").up.txt"
        "$NDT" down > "$dir.down.txt" 2>&1 || true
        return 1
    fi
    tail -6 "$dir.up.txt" | sed 's/^/     /'
    get_json "$PROXY_URL/p4/switch_state" "$dir.switch_state.json" || true
    "$NDT" status > "$dir.status.txt" 2>&1 || true
    sed -n '/^ *telemetry/,/^ *link shaping/p' "$dir.status.txt" | sed 's/^/     /'
    link_usage_round "$pkg" "$label" "$dir" "$expect"
    local rc=$?
    "$NDT" down > "$dir.down.txt" 2>&1 || bad "group $n ($label): 'ndt down' did not exit 0"
    return $rc
}

group 20 link        "$PKG_FOREIGN" link        follows || fail "group 1 (link): the twin's link usage did not follow the iperf path"
group 30 cooperative "$PKG_NDTWIN"  cooperative follows || fail "group 2 (cooperative): the twin's link usage did not follow the iperf path"

# 🔴 THE POSITIVE CONTROL, AND IT IS NOT OPTIONAL. Without it the two greens above are satisfied
# by a twin that reports a constant non-zero on every edge -- which is what a stale collector, a
# double-counted clone and a rate that never decays all look like.
group 40 none        "$PKG_NDTWIN"  none        absent  || fail "positive control (none): telemetry is off and the twin still reported usage on the path -- the two groups above have no discriminating power"
