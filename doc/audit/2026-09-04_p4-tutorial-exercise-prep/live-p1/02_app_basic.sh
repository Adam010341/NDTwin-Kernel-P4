#!/usr/bin/env bash
#
# P1/P2 live acceptance ② -- exercises/basic (pod-topo) with the EXERCISE'S OWN pipeline.
#
# [Co-developed with claude code -- Adam]
#
# WHAT CHANGED AT P2 (TICKET-P2 §5.4). In phase one a package's `pipeline` was null on every
# switch and this step's own header said so: 0% loss proved the fabric forwarded between the
# addresses the package declared, and NOT that NDTwin was running basic.p4. G4 and G5 are what
# make that sentence testable, so the same command now says something stronger -- `convert.py
# --p4` gives every switch build/basic.json, the proxy pushes it, and the exercise's own
# sX-runtime.json entries are APPLIED rather than merely counted.
#
# The phase-one property did not stop being worth checking; it moved to 02b_app_basic_ndtwin.sh,
# which converts the same exercise with `--ndtwin-pipeline` and asserts exactly what this file
# used to: `skipped == []`, five entries recorded and none applied, 0% loss.
#
# 🔴 WHAT IS AND IS NOT PROVEN HERE.
#   * 0% loss over every ordered pair, five packets each, says the fabric forwards. Under
#     basic.p4 that is the exercise's own program doing it: `install_initial_routes` is one of
#     the things the proxy SKIPS on a foreign pipeline, so nothing NDTwin wrote is carrying
#     these packets -- the sX-runtime.json entries are.
#   * `control_plane.skipped` naming exactly lldp_discovery, link_watchdog and
#     install_initial_routes is the disclosure that goes with that: those three ride on
#     packet-in/packet-out, and a tutorials p4info declares no controller_packet_metadata at
#     all (ndtwin_switch declares two, basic declares zero). A short list here would be a proxy
#     that did half the work of a control plane while reporting that it did none.
#   * The per-switch skips (clone_session, sflow_telemetry) are on each switch's own row and
#     NOT in the fabric-wide list -- TICKET-P2 §7-7: in a mixed fabric a neighbouring NDTwin
#     switch still has its clone session, and a fabric-wide `clone_session` would be saying
#     something about the whole fabric that is true of only part of it.
#   * NOT proven: that the firewall or the source-routing exercises behave. This is `basic`,
#     four switches, one program. The exercises are drive_exercise.py's subject.
#
# 🔴 THE PACKAGE IS BUILT HERE, from ~/tutorials, and not read out of somebody's scratch
# directory -- and since P2 the artefacts it carries are COMPILED here too: `--p4` copies
# build/basic.json and build/basic.p4.p4info.txtpb into the package, and a package built around
# whatever was left in that directory by an earlier round would be a pipeline nobody can name.
# The two sha256s are printed for that reason.
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/02_app_basic.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/basic}"
PKG="$PKG_ROOT/basic"
P4C="${P4C:-/usr/local/bin/p4c-bm2-ss}"

# The names below are proxy_agent/main.py's own SKIP_* constants (:288-293), not prose:
#   SKIP_PIPELINE=pipeline_push   SKIP_CLONE=clone_session   SKIP_TELEMETRY=sflow_telemetry
#   SKIP_LLDP=lldp_discovery      SKIP_WATCHDOG=link_watchdog
#   SKIP_ROUTES=install_initial_routes
# Written out here rather than read from that file: a check that derives its expectation from
# the code under test agrees with it by construction.
FABRIC_SKIPS="['install_initial_routes', 'link_watchdog', 'lldp_discovery']"   # sorted
SWITCH_SKIPS="[\"('clone_session', 'sflow_telemetry')\"]"                      # per switch

start_step 02_app_basic

# sw_set <switch_state.json> <python expr over s> -- that expression's DISTINCT values across
# every switch, sorted. One value in the answer means every switch agrees; two means they do
# not, and the check that reads it says which was expected.
sw_set() {
    jqp "$1" "sorted({repr($2) for s in (list((d.get('switches') or {}).values()) if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})"
}

# --- 1. compile the exercise, then build the package -------------------------------------------
say "compiling $EXERCISE/solution/basic.p4 -> build/basic.json"
[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR= to point elsewhere)"
[[ -x "$P4C" ]]      || die "no p4c-bm2-ss at $P4C (set P4C= to point elsewhere)"
mkdir -p "$EXERCISE/build"
# Exactly the exercises' own Makefile recipe (utils/Makefile:47), and the same one
# drive_exercise.py's compile_prog() runs: the solution is compiled TO THE SKELETON'S OUTPUT
# NAME, because pod-topo/sX-runtime.json names build/basic.p4.p4info.txtpb and nothing else.
( cd "$EXERCISE" && "$P4C" --p4v 16 \
        --p4runtime-files build/basic.p4.p4info.txtpb -o build/basic.json solution/basic.p4 ) \
    > "$RUN/09_compile.txt" 2>&1 || { sed 's/^/   /' "$RUN/09_compile.txt"; die "p4c failed -- see $(basename "$RUN")/09_compile.txt"; }
for f in "$EXERCISE/build/basic.json" "$EXERCISE/build/basic.p4.p4info.txtpb"; do
    [[ -s "$f" ]] || die "p4c reported success and $f is not there"
    note "$(sha256sum "$f" | cut -c1-16)  $f"
done

say "converting $EXERCISE -> $PKG   (--p4: every switch runs basic.p4)"
rm -rf "$PKG"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" \
      --topology pod-topo/topology.json --p4 solution/basic.p4 --out "$PKG" \
      > "$RUN/10_convert.txt" 2>&1 || die "convert.py failed -- see $(basename "$RUN")/10_convert.txt"
tail -2 "$RUN/10_convert.txt" | sed 's/^/   /'
# The package must actually carry a pipeline, or every assertion below is about phase one with
# a P2 banner on it. Read out of the package's own manifest, before anything is started.
PIPES="$("$PY" -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(sorted({repr((v or {}).get('pipeline')) for v in m['switches'].values()}))" "$PKG/package.json")"
note "package.json switches[*].pipeline: $PIPES"
case "$PIPES" in
    *"'p4info': 'build/basic.p4.p4info.txtpb'"*) note "every switch names the exercise's own program" ;;
    *) die "the package's switches do not name build/basic.* -- convert.py --p4 did not take: $PIPES" ;;
esac

say "pre-flight"
set +e
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG" > "$RUN/11_preflight.txt" 2>&1
PF_RC=$?
set -e
tail -1 "$RUN/11_preflight.txt" | sed 's/^/   /'
(( PF_RC != 0 )) && { sed 's/^/   /' "$RUN/11_preflight.txt"; die "pre-flight FAILED (rc $PF_RC). 'ndt up p4 --app' would refuse this too, with the same table; nothing was started."; }

# 🔴 THE CLAIM IS TAKEN HERE, after convert and pre-flight -- neither touches the lab, and a
# package that will not pre-flight must not have held the lab while it was being rejected.
take_claim "P2 live acceptance 2: --app basic (pod-topo), the exercise's own pipeline"

# --- 2. bring it up on the package -------------------------------------------------------------
say "ndt up p4 --app $PKG"
set +e
"$NDT" up p4 --app "$PKG" > "$RUN/20_up.txt" 2>&1
UP_RC=$?
set -e
note "rc=$UP_RC -> $(basename "$RUN")/20_up.txt"
tail -8 "$RUN/20_up.txt" | sed 's/^/     /'
(( UP_RC != 0 )) && fail "'ndt up p4 --app' exited $UP_RC (see 20_up.txt)"

say "what the knob and the proxy say"
if [[ -e "$APP_KNOB" ]]; then
    sed 's/^/   /' "$APP_KNOB"
    KNOB_SAYS="$(/usr/bin/grep -v '^[[:space:]]*#' "$APP_KNOB" | /usr/bin/grep -v '^[[:space:]]*$' | head -1)"
    [[ "$KNOB_SAYS" == "$PKG" ]] || fail "the knob names '$KNOB_SAYS', not $PKG"
else
    fail "p4_proxy/mininet/app_package_override was not written"
fi
if [[ -s "$REPO/.test_run/logs/p4_proxy.log" ]]; then
    head -40 "$REPO/.test_run/logs/p4_proxy.log" > "$RUN/21_proxy_log_head.txt"
    /usr/bin/grep -m1 'app package' "$RUN/21_proxy_log_head.txt" | sed 's/^/   /' \
        || fail "the proxy printed no 'app package' line -- it may be serving the baseline fabric"
fi
note "host_count_override is now: $(tr -d '\n' < "$KNOB")"

# --- 3. the endpoint ---------------------------------------------------------------------------
say "GET /p4/switch_state"
SS="$RUN/30_switch_state.json"
get_json "$PROXY_URL/p4/switch_state" "$SS" || fail "no switch_state"
"$NDT" status > "$RUN/31_status.txt" 2>&1 || true
get_json "$KERNEL_URL/ndt/get_graph_data" "$RUN/32_get_graph_data.json" || fail "no get_graph_data"

if [[ -s "$SS" ]]; then
    N_SW="$(jqp "$SS" "len(d.get('switches') or [])")"
    MODE="$(jqp "$SS" "(d.get('control_plane') or {}).get('mode')")"
    PKG_SAID="$(jqp "$SS" "(d.get('control_plane') or {}).get('package')")"
    SKIPPED="$(jqp "$SS" "sorted((d.get('control_plane') or {}).get('skipped') or [])")"
    ENTRIES="$(jqp "$SS" "sorted({s.get('entries_recorded') for s in ((d.get('switches') or {}).values() if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})")"
    NDTWIN="$(sw_set "$SS" "(s.get('pipeline') or {}).get('ndtwin')")"
    SHAS="$(sw_set "$SS" "(s.get('pipeline') or {}).get('p4info_sha256')")"
    SW_SKIPPED="$(sw_set "$SS" "tuple(sorted((s.get('pipeline') or {}).get('skipped') or []))")"
    APPLIED="$(sw_set "$SS" "(s.get('table_entries') or {}).get('applied')")"
    FAILED="$(sw_set "$SS" "(s.get('table_entries') or {}).get('failed')")"
    RECORDED="$(sw_set "$SS" "(s.get('table_entries') or {}).get('recorded')")"
    note "switches            $N_SW"
    note "control_plane.mode  $MODE"
    note "control_plane.package $PKG_SAID"
    note "control_plane.skipped $SKIPPED"
    note "entries_recorded    $ENTRIES   (distinct values across the switches)"
    note "pipeline.ndtwin     $NDTWIN"
    note "pipeline.p4info_sha256 $SHAS"
    note "pipeline.skipped    $SW_SKIPPED"
    note "table_entries       recorded=$RECORDED applied=$APPLIED failed=$FAILED"
    [[ "$MODE" == ndtwin ]]   || fail "control_plane.mode is '$MODE', want ndtwin"
    [[ "$PKG_SAID" == "$PKG" ]] || fail "control_plane.package is '$PKG_SAID', want $PKG"
    [[ "$N_SW" == 4 ]]        || fail "switch_state names $N_SW switches, pod-topo declares 4"
    # 🔴 THE FABRIC-WIDE LIST IS THE THREE THAT RIDE ON THE CPU PORT, and nothing else
    # (TICKET-P2 §2.2, §7-7). Sorted on both sides so the assertion is about the SET.
    [[ "$SKIPPED" == "$FABRIC_SKIPS" ]] \
        || fail "control_plane.skipped is $SKIPPED, want $FABRIC_SKIPS -- a foreign pipeline has no controller header, so LLDP, the watchdog and the initial routes are what cannot run"
    # Every switch is on the exercise's program, and says so with a stable identifier.
    [[ "$NDTWIN" == "['False']" ]] \
        || fail "pipeline.ndtwin is $NDTWIN, want ['False'] on every switch -- the package named build/basic.* for all four"
    [[ "$SHAS" != "['None']" ]] \
        || fail "no switch reported a pipeline.p4info_sha256 -- the one stable identifier a pipeline has"
    [[ "$SW_SKIPPED" == "$SWITCH_SKIPS" ]] \
        || fail "per-switch pipeline.skipped is $SW_SKIPPED, want $SWITCH_SKIPS (§7-7: the per-switch skips live on the switch's own row, not in the fabric-wide list)"
    # 🔴 5 per switch, and at P2 they are APPLIED. pod-topo's four sX-runtime.json files carry
    # five entries each; phase one recorded them without applying one of them, and that is now
    # the other script's assertion (02b), not this one's.
    [[ "$ENTRIES" == "[5]" ]] || fail "entries_recorded is $ENTRIES, want 5 on every switch"
    [[ "$RECORDED" == "['5']" ]] || fail "table_entries.recorded is $RECORDED, want 5 on every switch"
    [[ "$APPLIED" == "['5']" ]] \
        || fail "table_entries.applied is $APPLIED, want 5 on every switch -- the exercise's own entries are what forwards here, and 0% loss below would otherwise be somebody else's routes"
    [[ "$FAILED" == "['0']" ]] || fail "table_entries.failed is $FAILED, want 0 on every switch"
fi
G="$RUN/32_get_graph_data.json"
if [[ -s "$G" ]]; then
    G_SW="$(jqp "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==0])")"
    G_H="$(jqp  "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==1])")"
    note "kernel graph        $G_SW switches, $G_H hosts"
    [[ "$G_SW" == 4 ]] || fail "the kernel graph has $G_SW switches, the package's model declares 4"
    [[ "$G_H"  == 4 ]] || fail "the kernel graph has $G_H hosts, the package's model declares 4"
fi

# `ndt status` under a foreign pipeline: the sampling rate is NOT the built json's number.
# Recorded and asserted here because this is the only place a live fabric can say it
# (TICKET-P2 §5.5; tests/shell/test_ndt_app_package.sh section 14 drives the same two rows
# offline).
if [[ -s "$RUN/31_status.txt" ]]; then
    /usr/bin/grep -E '^ +(sample rate|rate source|app package)' "$RUN/31_status.txt" | sed 's/^/   /' || true
    /usr/bin/grep -qF 'n/a (package pipeline)' "$RUN/31_status.txt" \
        || fail "'ndt status' printed a sampling rate for a fabric running the package's own pipeline -- that number is decoded from p4_proxy/p4_src/build/ndtwin_switch.json, which these switches never loaded"
fi

# --- 4. forwarding ------------------------------------------------------------------------------
say "verify_p4 (ndt's own [3/3], run again)"
set +e
run_verify_p4 "$PKG/ndtwin/topology.json" 12 ndtwin > "$RUN/40_verify_p4.txt" 2>&1
V_RC=$?
set -e
note "rc=$V_RC -> $(basename "$RUN")/40_verify_p4.txt"
tail -5 "$RUN/40_verify_p4.txt" | sed 's/^/     /'
(( V_RC != 0 )) && fail "verify_p4 exited $V_RC over the package fabric"

# ndt's own check first, recorded and NOT cited as the loss evidence -- its ping is -c 2 and
# its rc 0 means at least one of the two replies arrived.
say "ndt's own dataplane_ok over every ordered pair (not the loss measurement)"
set +e
pingall_via_ndt "$PKG" > "$RUN/41_dataplane_ok.txt" 2>&1
set -e
sed 's/^/   /' "$RUN/41_dataplane_ok.txt"
DO="$(tail -1 "$RUN/41_dataplane_ok.txt")"
case "$DO" in
    NDT_DATAPLANE_OK*dead=0*untested=0*) note "ndt's own check found no dead pair and no untested one" ;;
    *) fail "ndt's dataplane_ok: $DO" ;;
esac

# --- 🔴 THE ACCEPTANCE MEASUREMENT: 0% LOSS, from ping's own summary ---------------------------
#
# Acceptance (2) is `pingall` 0% loss. That is a RATE, and the check above cannot produce one:
# `ping -c 2` exiting 0 says at least one of two replies arrived, which is equally true of 50%
# loss. So every ordered pair is pinged again with -c 5 inside its own namespace and the
# `N% packet loss` line is parsed; the requirement is EXACTLY 0 on every pair, with no pair
# left untested -- an untested pair is not a passed one.
say "pingall -- every ordered host pair, ping -c 5, loss parsed from ping"
set +e
pingall_loss "$PKG" 5 "$RUN/43_ping_raw.txt" > "$RUN/42_pingall_loss.txt" 2>&1
set -e
sed 's/^/   /' "$RUN/42_pingall_loss.txt"
note "every ping's raw output: $(basename "$RUN")/43_ping_raw.txt"
PA="$(tail -1 "$RUN/42_pingall_loss.txt")"
case "$PA" in
    "PINGALL_LOSS pairs=12 zero_loss=12 lossy=0 untested=0")
        note "0% packet loss on all 12 ordered pairs, 5 packets each" ;;
    PINGALL_LOSS*)
        fail "pingall is not 0% loss on every pair: $PA (detail above, raw in 43_ping_raw.txt)" ;;
    *)  fail "pingall_loss produced no verdict line" ;;
esac

say "done -- teardown follows (it must leave no app_package_override behind)"
