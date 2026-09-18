#!/usr/bin/env bash
#
# P2 live acceptance ②b -- exercises/basic (pod-topo) on NDTWIN'S OWN pipeline.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS FILE EXISTS (TICKET-P2 §5.4). Phase one could only bring a package up on NDTwin's
# own pipeline, and 02_app_basic.sh was the live assertion of what that did: the package
# supplies the topology, the host addresses and the host commands, the pipeline stays NDTwin's,
# the exercise's runtime entries are RECORDED and not applied, and every host pair still
# forwards at 0% loss. G4 made `--p4` the ordinary case and 02 moved to it, so that property
# now has nowhere to be measured -- and it is the one that says the package format did not stop
# being able to express "somebody else's topology on our data plane".
#
# 🔴 THE DIFFERENCE FROM 02 IS ONE FLAG. `--ndtwin-pipeline` writes `pipeline: null` on every
# switch (convert.py's switch_pipelines(), case one). Everything else -- same exercise, same
# topology, same entries, same commands -- is identical, which is what makes the two runs a
# comparison rather than two unrelated readings:
#
#                             02 (--p4)                    02b (--ndtwin-pipeline)
#   pipeline.ndtwin           false on every switch        true on every switch
#   control_plane.skipped     lldp, watchdog, routes       [] (nothing is skipped)
#   per-switch skipped        clone_session, telemetry     []
#   table_entries             recorded 5, applied 5        recorded 5, applied 0
#   ndt status sample rate    n/a (package pipeline)       the compiled rate, as always
#   pingall                   0%                           0%
#
# 🔴 AND THE 0% MEANS SOMETHING DIFFERENT IN EACH. Here it is NDTwin's own routes carrying the
# packets -- install_initial_routes ran -- so this run says nothing at all about basic.p4.
# `entries_recorded: 5` is DISCLOSURE, not a result: read it as "the package declared five
# entries per switch and this fabric applied none of them".
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/02b_app_basic_ndtwin_pipeline.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/basic}"
PKG="$PKG_ROOT/basic-ndtwin-pipeline"
P4C="${P4C:-/usr/local/bin/p4c-bm2-ss}"

start_step 02b_app_basic_ndtwin_pipeline

# sw_set <switch_state.json> <python expr over s> -- that expression's DISTINCT values across
# every switch, sorted. One value means every switch agrees.
sw_set() {
    jqp "$1" "sorted({repr($2) for s in (list((d.get('switches') or {}).values()) if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})"
}

# --- 1. the package ----------------------------------------------------------------------------
#
# The compile is still needed even though no switch will run the result: pod-topo's
# sX-runtime.json files name build/basic.p4.p4info.txtpb as the program their entries were
# written against, convert.py copies whatever they name into the package, and pre-flight reads
# it. What changes is that nothing loads it.
say "compiling $EXERCISE/solution/basic.p4 -> build/basic.json (for the entries' p4info)"
[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR= to point elsewhere)"
[[ -x "$P4C" ]]      || die "no p4c-bm2-ss at $P4C (set P4C= to point elsewhere)"
mkdir -p "$EXERCISE/build"
( cd "$EXERCISE" && "$P4C" --p4v 16 \
        --p4runtime-files build/basic.p4.p4info.txtpb -o build/basic.json solution/basic.p4 ) \
    > "$RUN/09_compile.txt" 2>&1 || { sed 's/^/   /' "$RUN/09_compile.txt"; die "p4c failed -- see $(basename "$RUN")/09_compile.txt"; }
note "$(sha256sum "$EXERCISE/build/basic.p4.p4info.txtpb" | cut -c1-16)  build/basic.p4.p4info.txtpb"

say "converting $EXERCISE -> $PKG   (--ndtwin-pipeline: every switch stays on NDTwin's)"
rm -rf "$PKG"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" \
      --topology pod-topo/topology.json --p4 solution/basic.p4 --ndtwin-pipeline --out "$PKG" \
      > "$RUN/10_convert.txt" 2>&1 || die "convert.py failed -- see $(basename "$RUN")/10_convert.txt"
tail -2 "$RUN/10_convert.txt" | sed 's/^/   /'
# 🔴 The flag has to have taken, or this whole run is 02 again under another name.
PIPES="$("$PY" -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(sorted({repr((v or {}).get('pipeline')) for v in m['switches'].values()}))" "$PKG/package.json")"
note "package.json switches[*].pipeline: $PIPES"
[[ "$PIPES" == "['None']" ]] \
    || die "--ndtwin-pipeline did not null every switch: $PIPES -- this run would be 02 with a different package name"

say "pre-flight"
set +e
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG" > "$RUN/11_preflight.txt" 2>&1
PF_RC=$?
set -e
tail -1 "$RUN/11_preflight.txt" | sed 's/^/   /'
(( PF_RC != 0 )) && { sed 's/^/   /' "$RUN/11_preflight.txt"; die "pre-flight FAILED (rc $PF_RC). 'ndt up p4 --app' would refuse this too, with the same table; nothing was started."; }

# 🔴 THE CLAIM IS TAKEN HERE, after convert and pre-flight -- neither touches the lab.
take_claim "P2 live acceptance 2b: --app basic (pod-topo) on NDTwin's own pipeline"

# --- 2. bring it up ----------------------------------------------------------------------------
say "ndt up p4 --app $PKG"
set +e
"$NDT" up p4 --app "$PKG" > "$RUN/20_up.txt" 2>&1
UP_RC=$?
set -e
note "rc=$UP_RC -> $(basename "$RUN")/20_up.txt"
tail -8 "$RUN/20_up.txt" | sed 's/^/     /'
(( UP_RC != 0 )) && fail "'ndt up p4 --app' exited $UP_RC (see 20_up.txt)"

if [[ -e "$APP_KNOB" ]]; then
    KNOB_SAYS="$(/usr/bin/grep -v '^[[:space:]]*#' "$APP_KNOB" | /usr/bin/grep -v '^[[:space:]]*$' | head -1)"
    [[ "$KNOB_SAYS" == "$PKG" ]] || fail "the knob names '$KNOB_SAYS', not $PKG"
else
    fail "p4_proxy/mininet/app_package_override was not written"
fi
note "host_count_override is now: $(tr -d '\n' < "$KNOB")"

# --- 3. the endpoint: the phase-one properties, one at a time ----------------------------------
say "GET /p4/switch_state"
SS="$RUN/30_switch_state.json"
get_json "$PROXY_URL/p4/switch_state" "$SS" || fail "no switch_state"
"$NDT" status > "$RUN/31_status.txt" 2>&1 || true

if [[ -s "$SS" ]]; then
    N_SW="$(jqp "$SS" "len(d.get('switches') or [])")"
    MODE="$(jqp "$SS" "(d.get('control_plane') or {}).get('mode')")"
    SKIPPED="$(jqp "$SS" "repr((d.get('control_plane') or {}).get('skipped'))")"
    ENTRIES="$(jqp "$SS" "sorted({s.get('entries_recorded') for s in ((d.get('switches') or {}).values() if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})")"
    NDTWIN="$(sw_set "$SS" "(s.get('pipeline') or {}).get('ndtwin')")"
    SW_SKIPPED="$(sw_set "$SS" "tuple(sorted((s.get('pipeline') or {}).get('skipped') or []))")"
    RECORDED="$(sw_set "$SS" "(s.get('table_entries') or {}).get('recorded')")"
    APPLIED="$(sw_set "$SS" "(s.get('table_entries') or {}).get('applied')")"
    note "switches            $N_SW"
    note "control_plane.mode  $MODE"
    note "control_plane.skipped $SKIPPED"
    note "entries_recorded    $ENTRIES"
    note "pipeline.ndtwin     $NDTWIN"
    note "pipeline.skipped    $SW_SKIPPED"
    note "table_entries       recorded=$RECORDED applied=$APPLIED"
    [[ "$MODE" == ndtwin ]] || fail "control_plane.mode is '$MODE', want ndtwin"
    [[ "$N_SW" == 4 ]]      || fail "switch_state names $N_SW switches, pod-topo declares 4"
    # 🔴 NOTHING IS SKIPPED. An NDTwin pipeline has the CPU port LLDP, the watchdog and the
    # initial routes ride on, so a name in this list would be the proxy declining work it can do.
    [[ "$SKIPPED" == "[]" ]] \
        || fail "control_plane.skipped is $SKIPPED -- on NDTwin's own pipeline nothing is skipped"
    [[ "$NDTWIN" == "['True']" ]] \
        || fail "pipeline.ndtwin is $NDTWIN, want ['True'] on every switch -- --ndtwin-pipeline nulled them all"
    # main.py:369 (trunk 78067633): `[] if ndtwin else sorted(FOREIGN_PIPELINE_SWITCH_SKIPS)`,
    # and the key is emitted either way -- an absent key cannot be told from a proxy too old to
    # have one.
    [[ "$SW_SKIPPED" == "['()']" ]] \
        || fail "per-switch pipeline.skipped is $SW_SKIPPED, want () on every switch: a clone session and the sFlow sampler both work on this pipeline"
    # 🔴 RECORDED AND NOT APPLIED, which is the phase-one sentence this file exists to keep.
    [[ "$ENTRIES" == "[5]" ]] || fail "entries_recorded is $ENTRIES, want 5 on every switch"
    [[ "$RECORDED" == "['5']" ]] || fail "table_entries.recorded is $RECORDED, want 5 on every switch"
    [[ "$APPLIED" == "['0']" ]] \
        || fail "table_entries.applied is $APPLIED, want 0 on every switch -- these entries were written against basic.p4's p4info and no switch here is running basic.p4"
fi

# The control for 02's own `ndt status` assertion: with every switch on NDTwin's pipeline the
# sampling rate IS the compiled artefact's number, and the row must not say n/a.
if [[ -s "$RUN/31_status.txt" ]]; then
    /usr/bin/grep -E '^ +(sample rate|rate source|app package)' "$RUN/31_status.txt" | sed 's/^/   /' || true
    /usr/bin/grep -qF 'n/a (package pipeline)' "$RUN/31_status.txt" \
        && fail "'ndt status' says the rate is n/a, but every switch in this package is on NDTwin's own pipeline -- that row is for a foreign one"
    /usr/bin/grep -qE '^ +sample rate +1/[0-9]+' "$RUN/31_status.txt" \
        || fail "'ndt status' printed no sampling rate at all for a fabric running ndtwin_switch.json"
fi

# --- 4. forwarding -----------------------------------------------------------------------------
say "verify_p4 (ndt's own [3/3], run again)"
set +e
run_verify_p4 "$PKG/ndtwin/topology.json" 12 ndtwin > "$RUN/40_verify_p4.txt" 2>&1
V_RC=$?
set -e
note "rc=$V_RC -> $(basename "$RUN")/40_verify_p4.txt"
tail -5 "$RUN/40_verify_p4.txt" | sed 's/^/     /'
(( V_RC != 0 )) && fail "verify_p4 exited $V_RC over the package fabric"

say "pingall -- every ordered host pair, ping -c 5, loss parsed from ping"
set +e
pingall_loss "$PKG" 5 "$RUN/43_ping_raw.txt" > "$RUN/42_pingall_loss.txt" 2>&1
set -e
sed 's/^/   /' "$RUN/42_pingall_loss.txt"
note "every ping's raw output: $(basename "$RUN")/43_ping_raw.txt"
PA="$(tail -1 "$RUN/42_pingall_loss.txt")"
case "$PA" in
    "PINGALL_LOSS pairs=12 zero_loss=12 lossy=0 untested=0")
        note "0% packet loss on all 12 ordered pairs, 5 packets each -- NDTwin's own routes" ;;
    PINGALL_LOSS*)
        fail "pingall is not 0% loss on every pair: $PA (detail above, raw in 43_ping_raw.txt)" ;;
    *)  fail "pingall_loss produced no verdict line" ;;
esac

say "done -- teardown follows (it must leave no app_package_override behind)"
