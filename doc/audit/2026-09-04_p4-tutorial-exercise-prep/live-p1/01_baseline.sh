#!/usr/bin/env bash
#
# P1 live acceptance ① -- the BASELINE fabric, with the merged tree and NO app package.
#
# [Co-developed with claude code -- Adam]
#
# What this is for: goal condition ① is "`ndt up p4 4`'s switch_state and get_graph_data are
# cell-for-cell what they were before this feature". This step takes that reading.
#
# 🔴 WHAT IT CANNOT DO, said here and in the README rather than discovered afterwards: THERE IS
# NO SAVED "BEFORE". Nothing under scratch/overnight-2026-09-05/logs or hunt-0911/logs holds a
# capture of GET /p4/switch_state at all -- searched for `probe_ok`, `probe_age_s` and
# `switch_state`, and every hit is a proxy log or a C++ source -- and the newest saved
# get_graph_data from a BMv2 fabric is 2026-09-07 at 128 hosts, not the 4-host fabric this
# condition is about. So this step is the FIRST baseline, not the second half of a comparison.
# What it can prove is that the merged tree is self-consistent: the two documented new keys are
# present and empty (control_plane, entries_recorded), and the structural numbers match the
# model the kernel was handed. It is written to runs/ so that the NEXT change to this code has
# the verbatim "before" this one did not.
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/01_baseline.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

start_step 01_baseline

# --- 0. the knob must not be there --------------------------------------------------------
# 🔴 ABOVE take_claim, like every other refusal: a step that refuses must not have taken the
# lab, and must not leave a teardown for its own EXIT trap to run.
say "the app package knob must be absent"
if [[ -e "$APP_KNOB" ]]; then
    sed 's/^/   /' "$APP_KNOB"
    die "refusing: p4_proxy/mininet/app_package_override exists. This step is the BASELINE
       reading; with that file in place the proxy and the topology script build somebody's
       exercise fabric and every number below would describe it. 'ndt down' removes it."
fi
note "absent -- this is the baseline fabric"

take_claim "P1 live acceptance 1: baseline p4 4, no app package"

# --- 1. bring it up -------------------------------------------------------------------------
say "ndt up p4 4"
set +e
"$NDT" up p4 4 > "$RUN/10_up.txt" 2>&1
UP_RC=$?
set -e
note "rc=$UP_RC  -> $(basename "$RUN")/10_up.txt"
tail -6 "$RUN/10_up.txt" | sed 's/^/     /'
(( UP_RC != 0 )) && fail "'ndt up p4 4' exited $UP_RC (see 10_up.txt)"

# 🔴 The first forty lines of the proxy's log, kept whatever happened. The line this feature
# adds is printed at import -- `[Proxy Agent] app package: baseline (mode ndtwin, ...)` -- and
# it is the only place the proxy states which fabric it believes it is serving.
say "proxy log, first 40 lines"
if [[ -s "$REPO/.test_run/logs/p4_proxy.log" ]]; then
    head -40 "$REPO/.test_run/logs/p4_proxy.log" > "$RUN/11_proxy_log_head.txt"
    /usr/bin/grep -m1 'app package' "$RUN/11_proxy_log_head.txt" | sed 's/^/   /' \
        || bad "the proxy printed no 'app package' line -- profile.py announces one at import"
else
    bad "no proxy log at .test_run/logs/p4_proxy.log"
    fail "the proxy wrote no log"
fi

# --- 2. the two endpoints ---------------------------------------------------------------------
say "capturing the endpoints"
get_json "$PROXY_URL/p4/switch_state"      "$RUN/20_switch_state.json"  || fail "no switch_state"
get_json "$KERNEL_URL/ndt/get_graph_data"  "$RUN/21_get_graph_data.json" || fail "no get_graph_data"
"$NDT" status > "$RUN/22_status.txt" 2>&1 || true
set +e
run_verify_p4 "$REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json" 12 ndtwin \
    > "$RUN/23_verify_p4.txt" 2>&1
V_RC=$?
set -e
note "verify_p4 rc=$V_RC -> $(basename "$RUN")/23_verify_p4.txt"
tail -4 "$RUN/23_verify_p4.txt" | sed 's/^/     /'
(( V_RC != 0 )) && fail "verify_p4 exited $V_RC"

# --- 3. what the capture has to say -----------------------------------------------------------
#
# Structural fields only, and the two new keys. Timestamps and age fields (probe_age_s,
# last_lldp_age_s, anything ending _at) are NOT compared and never will be: they are readings of
# when the capture was taken.
say "reading the baseline capture"
SS="$RUN/20_switch_state.json"
GD="$RUN/21_get_graph_data.json"
if [[ -s "$SS" ]]; then
    N_SW="$(jqp "$SS" "len(d.get('switches') or [])")"
    MODE="$(jqp "$SS" "(d.get('control_plane') or {}).get('mode')")"
    PKG="$(jqp "$SS" "repr((d.get('control_plane') or {}).get('package'))")"
    SKIPPED="$(jqp "$SS" "repr((d.get('control_plane') or {}).get('skipped'))")"
    ENTRIES="$(jqp "$SS" "sorted({s.get('entries_recorded') for s in ((d.get('switches') or {}).values() if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})")"
    PROBES="$(jqp "$SS" "sorted({bool(s.get('probe_ok')) for s in ((d.get('switches') or {}).values() if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})")"
    note "switches            $N_SW"
    note "control_plane.mode  $MODE"
    note "control_plane.package $PKG"
    note "control_plane.skipped $SKIPPED"
    note "entries_recorded    $ENTRIES   (distinct values across the switches)"
    note "probe_ok            $PROBES"
    [[ "$N_SW" == 10 ]]        || fail "switch_state names $N_SW switches, the 4-host model declares 10"
    [[ "$MODE" == ndtwin ]]    || fail "control_plane.mode is '$MODE', not 'ndtwin' -- this is the baseline fabric"
    [[ "$PKG" == None ]]       || fail "control_plane.package is $PKG, not null -- something is running a package"
    [[ "$SKIPPED" == "[]" ]]   || fail "control_plane.skipped is $SKIPPED, not [] -- the baseline skips nothing"
    [[ "$ENTRIES" == "[0]" ]]  || fail "entries_recorded is $ENTRIES, not 0 everywhere -- the baseline records no package entries"
    # 🔴 A FAILURE, not a warning. probe_ok is what the kernel's p4LivenessFor reads to decide
    # whether a switch is up at all (DeviceConfigurationAndPowerManager.cpp:668); a baseline
    # capture taken over a fabric where some switch was not answering is a baseline of a
    # half-built lab, and every structural number under it inherits that.
    [[ "$PROBES" == "[True]" ]] || fail "probe_ok is $PROBES -- not every switch answered its liveness probe, so this is not a reading of a healthy baseline"
fi
if [[ -s "$GD" ]]; then
    MODEL="$REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"
    G_SW="$(jqp "$GD" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==0])")"
    G_H="$(jqp  "$GD" "len([n for n in d.get('nodes',[]) if n.get('vertex_type')==1])")"
    G_E="$(jqp  "$GD" "len(d.get('edges',[]))")"
    G_B="$(jqp  "$GD" "sorted({n.get('brand_name') for n in d.get('nodes',[]) if n.get('vertex_type')==0})")"
    G_EN="$(jqp "$GD" "sorted({bool(n.get('is_enabled')) for n in d.get('nodes',[]) if n.get('vertex_type')==0})")"
    G_UP="$(jqp "$GD" "sorted({bool(n.get('is_up')) for n in d.get('nodes',[]) if n.get('vertex_type')==0})")"
    note "graph               $G_SW switches, $G_H hosts, $G_E edges, brand $G_B"
    note "is_up / is_enabled  $G_UP / $G_EN   (distinct values across the switches)"
    M_H="$(jqp "$MODEL" "len([n for n in d['nodes'] if n.get('vertex_type')==1])")"
    M_S="$(jqp "$MODEL" "len([n for n in d['nodes'] if n.get('vertex_type')==0])")"
    M_E="$(jqp "$MODEL" "len(d['edges'])")"
    note "the model declares  $M_S switches, $M_H hosts, $M_E edges"
    [[ "$G_SW" == "$M_S" ]] || fail "the kernel graph has $G_SW switches, the model it was handed declares $M_S"
    [[ "$G_H"  == "$M_H" ]] || fail "the kernel graph has $G_H hosts, the model it was handed declares $M_H"
    # 🔴 EDGES, compared rather than printed. The precedent is on disk: the only saved BMv2-plane
    # graph capture (logs/x2-sweep/001_GET_ndt_get_graph_data.json, 2026-09-06, the 128-host
    # model) has 288 edges and that model declares 288 -- so the kernel does carry the model's
    # edge list through one for one, and an inequality here is a real difference, not a known
    # transformation.
    [[ "$G_E"  == "$M_E" ]] || fail "the kernel graph has $G_E edges, the model it was handed declares $M_E"
    [[ "$G_B"  == "['BMv2']" ]] || fail "the graph's switch brand is $G_B, not BMv2 -- this is not the P4 plane"
    [[ "$G_UP" == "[True]" ]] || fail "is_up is $G_UP -- not every switch is up in the kernel's graph"
    # 🔴 UNIFORM, not a particular value, and the reason is a contradiction on disk that this
    # step cannot settle. verify_p4's own line says `is_enabled=N/10 -- expected in P4 mode,
    # nothing calls inform_switch_entered`, i.e. it expects FALSE; the one saved BMv2-plane
    # capture (x2-sweep, 2026-09-06) has is_enabled TRUE on all ten. Asserting either value
    # would be this script picking a side of a question it has not measured. What it CAN assert
    # is that the ten switches agree with each other -- a split set means some of them were
    # registered and some were not, which is a half-built lab whatever the right value is --
    # and the value itself is recorded above so the next reader has it.
    case "$G_EN" in
        "[True]"|"[False]") note "is_enabled is uniform across the switches ($G_EN); verify_p4 expects False here, the 09-06 128-host capture on disk has True -- recorded, not adjudicated" ;;
        *) fail "is_enabled is $G_EN -- the switches disagree with each other, so some were registered and some were not" ;;
    esac
fi

say "done -- teardown follows"
