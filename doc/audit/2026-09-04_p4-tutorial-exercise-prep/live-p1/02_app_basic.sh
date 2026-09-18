#!/usr/bin/env bash
#
# P1 live acceptance ② -- exercises/basic (pod-topo) on NDTwin's OWN control plane.
#
# [Co-developed with claude code -- Adam]
#
# Goal condition ②: `--app basic` comes up and `pingall` is 0% loss, with NDTwin's own pipeline
# and NDTwin's own routes. The package supplies the topology, the host addresses and the host
# commands; the pipeline stays NDTwin's, because a package's `pipeline` field is null in phase
# one (G4 is phase two).
#
# 🔴 THE PACKAGE IS BUILT HERE, from ~/tutorials, and not read out of somebody's scratch
# directory. It goes to .test_run/packages/basic, which is gitignored: a package under version
# control would be a copy of ONF's exercise, and a package read from another worktree would
# make this step green or absent depending on who had run convert.py that day.
#
# 🔴 WHAT IS NOT PROVEN HERE. 0% loss says the fabric forwards between the addresses the
# package declares. It does NOT say NDTwin is running basic.p4's pipeline -- it is not, and
# cannot be until G4 -- nor that the exercise's own runtime entries were applied. They are
# RECORDED and not applied in phase one, which is what `entries_recorded` on every switch says
# out loud. Read that number as disclosure, not as a result.
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/02_app_basic.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/basic}"
PKG="$PKG_ROOT/basic"

start_step 02_app_basic

# --- 1. build the package --------------------------------------------------------------------
say "converting $EXERCISE -> $PKG"
[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR= to point elsewhere)"
rm -rf "$PKG"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" \
      --topology pod-topo/topology.json --p4 solution/basic.p4 --out "$PKG" \
      > "$RUN/10_convert.txt" 2>&1 || die "convert.py failed -- see $(basename "$RUN")/10_convert.txt"
tail -2 "$RUN/10_convert.txt" | sed 's/^/   /'

say "pre-flight"
set +e
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG" > "$RUN/11_preflight.txt" 2>&1
PF_RC=$?
set -e
tail -1 "$RUN/11_preflight.txt" | sed 's/^/   /'
(( PF_RC != 0 )) && { sed 's/^/   /' "$RUN/11_preflight.txt"; die "pre-flight FAILED (rc $PF_RC). 'ndt up p4 --app' would refuse this too, with the same table; nothing was started."; }

# 🔴 THE CLAIM IS TAKEN HERE, after convert and pre-flight -- neither touches the lab, and a
# package that will not pre-flight must not have held the lab while it was being rejected.
take_claim "P1 live acceptance 2: --app basic (pod-topo), ndtwin control plane"

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
    SKIPPED="$(jqp "$SS" "repr((d.get('control_plane') or {}).get('skipped'))")"
    ENTRIES="$(jqp "$SS" "sorted({s.get('entries_recorded') for s in ((d.get('switches') or {}).values() if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})")"
    note "switches            $N_SW"
    note "control_plane.mode  $MODE"
    note "control_plane.package $PKG_SAID"
    note "control_plane.skipped $SKIPPED"
    note "entries_recorded    $ENTRIES   (distinct values across the switches)"
    [[ "$MODE" == ndtwin ]]   || fail "control_plane.mode is '$MODE', want ndtwin"
    [[ "$PKG_SAID" == "$PKG" ]] || fail "control_plane.package is '$PKG_SAID', want $PKG"
    [[ "$SKIPPED" == "[]" ]]  || fail "control_plane.skipped is $SKIPPED -- an ndtwin package skips nothing"
    [[ "$N_SW" == 4 ]]        || fail "switch_state names $N_SW switches, pod-topo declares 4"
    # 🔴 5 per switch, and it is DISCLOSURE, not a result: pod-topo's four sX-runtime.json files
    # carry five entries each, and phase one records them without applying one of them.
    [[ "$ENTRIES" == "[5]" ]] || fail "entries_recorded is $ENTRIES, want 5 on every switch"
fi
G="$RUN/32_get_graph_data.json"
if [[ -s "$G" ]]; then
    G_SW="$(jqp "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==0])")"
    G_H="$(jqp  "$G" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==1])")"
    note "kernel graph        $G_SW switches, $G_H hosts"
    [[ "$G_SW" == 4 ]] || fail "the kernel graph has $G_SW switches, the package's model declares 4"
    [[ "$G_H"  == 4 ]] || fail "the kernel graph has $G_H hosts, the package's model declares 4"
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
