#!/usr/bin/env bash
#
# P1 live acceptance ③ -- exercises/p4runtime with its OWN controller, beside a live proxy.
#
# [Co-developed with claude code -- Adam]
#
# Goal condition ③: the exercise's `mycontroller.py` and NDTwin's proxy coexist, and the proxy
# does NOT wipe the exercise's tables. The measurement that makes that a claim rather than a
# hope is the 2026-08-13 one written up in p4_client.py's mastership note: a second client
# presenting the primary's election id is accepted by bmv2 and its pipeline push CLEARS every
# table. So the assertion here is a COUNT, taken twice, with the proxy asked to push in between.
#
# The steps, and what each one is for:
#   1  convert + pre-flight -- the same two commands step 02 runs, on the external package.
#   2  `ndt up p4 --app` -- the fabric comes up EMPTY on purpose. `mode: external` means the
#      proxy opens no arbitration stream, pushes no pipeline, writes nothing, sends no LLDP and
#      installs no route; switch_state.control_plane.skipped names every one of those, and
#      every ping fails at this point. [3/3] says so instead of failing.
#   3  the exercise's controller, under setsid, through B's adapter -- which rewrites its
#      hardcoded 127.0.0.1:5005N / device N-1 onto this fabric's ports, on the CONTROLLER side.
#   4  h1 -> h2 and h2 -> h1 must be 0% loss over 5 packets each. That is the proof that the
#      exercise's controller is primary and its rules are in.
#      🔴 THE LOSS IS PARSED OUT OF PING, not read off `ndt`'s dataplane_ok: that helper is
#      `ping -c 2 -W 2` and its rc 0 means AT LEAST ONE of two replies arrived, which is
#      equally true of 50% loss. `ndt`'s own check is still run and recorded, beside it.
#   5  count s1's entries with the THIRD-PARTY client (p4runtime_mastership_probe.py's read
#      fragment -- `channel` and `count_entries`, no writes, no scenarios: scenarios 2 and 3 of
#      that file are DESTRUCTIVE by design and are not run here).
#   6  POST /p4/readopt/1 -- the proxy is asked to adopt the switch, which is the code path that
#      pushes a pipeline. Under an external package it must refuse, naming itself.
#   7  count again, and ping again. Same count, still 0% over 5 both ways => coexistence
#      without a wipe.
#
# 🔴 A CONTROL IS BUILT IN, and without it step 7 proves nothing: if step 5's count were 0 --
# because the controller never ran, or because the read failed -- then "the count did not
# change" would be true of a switch with no tables at all. The count must be > 0 before the
# readopt, and the ping must already be 0% loss both ways.
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/03_app_p4runtime.sh
# Exit: 0 PASS, 1 FAIL (the last line says which), 2 refused before anything was started.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/p4runtime}"
PKG="$PKG_ROOT/p4runtime"
PROBE="$REPO/p4_proxy/reference/p4runtime_mastership_probe.py"

start_step 03_app_p4runtime

# count_s1 -- s1's non-default table entries, read with the third-party client.
#
# 🔴 THE THIRD-PARTY CLIENT, not proxy_agent/p4_client.py. A repro written on top of the suspect
# client proves nothing -- p4runtime_mastership_probe.py's own docstring, and the reason it
# exists. Only `channel` and `count_entries` are used: both are reads, neither opens a stream,
# and NEITHER of the destructive scenarios in that file is invoked.
count_s1() {
    "$PY" - "$PROBE" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ch = m.channel("127.0.0.1:%d" % m.grpc_port(1))
stub = m.p4runtime_pb2_grpc.P4RuntimeStub(ch)
print(m.count_entries(stub, 1))
PY
}

# --- 1. the package ----------------------------------------------------------------------------
say "converting $EXERCISE -> $PKG"
[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR= to point elsewhere)"
[[ -r "$EXERCISE/mycontroller.py" ]] || die "no mycontroller.py in $EXERCISE -- step 3 has nothing to run"
rm -rf "$PKG"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" \
      --topology topology.json --p4 advanced_tunnel.p4 --out "$PKG" \
      > "$RUN/10_convert.txt" 2>&1 || die "convert.py failed -- see $(basename "$RUN")/10_convert.txt"
tail -2 "$RUN/10_convert.txt" | sed 's/^/   /'

say "pre-flight"
set +e
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG" > "$RUN/11_preflight.txt" 2>&1
PF_RC=$?
set -e
tail -1 "$RUN/11_preflight.txt" | sed 's/^/   /'
(( PF_RC != 0 )) && { sed 's/^/   /' "$RUN/11_preflight.txt"; die "pre-flight FAILED (rc $PF_RC); nothing was started."; }

# 🔴 THE CLAIM IS TAKEN HERE, after convert and pre-flight -- neither touches the lab, and a
# package that will not pre-flight must not have held the lab while it was being rejected.
take_claim "P1 live acceptance 3: --app p4runtime, external control plane"

# --- 2. the fabric, brought up EMPTY -------------------------------------------------------------
say "ndt up p4 --app $PKG   (external: it comes up empty on purpose)"
set +e
"$NDT" up p4 --app "$PKG" > "$RUN/20_up.txt" 2>&1
UP_RC=$?
set -e
note "rc=$UP_RC -> $(basename "$RUN")/20_up.txt"
tail -10 "$RUN/20_up.txt" | sed 's/^/     /'
(( UP_RC != 0 )) && fail "'ndt up p4 --app' exited $UP_RC (see 20_up.txt)"

SS0="$RUN/30_switch_state_before.json"
get_json "$PROXY_URL/p4/switch_state" "$SS0" || fail "no switch_state"
"$NDT" status > "$RUN/31_status.txt" 2>&1 || true
if [[ -s "$SS0" ]]; then
    MODE="$(jqp "$SS0" "(d.get('control_plane') or {}).get('mode')")"
    SKIPPED="$(jqp "$SS0" "sorted((d.get('control_plane') or {}).get('skipped') or [])")"
    ENTRIES="$(jqp "$SS0" "sorted({s.get('entries_recorded') for s in ((d.get('switches') or {}).values() if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})")"
    N_SW="$(jqp "$SS0" "len(d.get('switches') or [])")"
    note "control_plane.mode  $MODE"
    note "control_plane.skipped $SKIPPED"
    note "entries_recorded    $ENTRIES"
    note "switches            $N_SW"
    [[ "$MODE" == external ]] || fail "control_plane.mode is '$MODE', want external"
    [[ "$N_SW" == 3 ]]        || fail "switch_state names $N_SW switches, this package declares 3"
    [[ "$ENTRIES" == "[0]" ]] || fail "entries_recorded is $ENTRIES -- an external package brings its own entries"
    # Every step the proxy did NOT take has to be named. A short list is a proxy that did half
    # the work of a control plane while reporting that it did none.
    for s in pipeline_push clone_session lldp link_watchdog initial_routes; do
        /usr/bin/grep -qF "'$s'" <<<"$SKIPPED" || fail "control_plane.skipped does not name '$s': $SKIPPED"
    done
fi

# --- 3. the exercise's own controller -------------------------------------------------------------
say "starting the exercise controller under setsid"
# 🔴 NOT $PY. The tutorials' p4runtime_lib imports p4.tmp.p4config_pb2, which the proxy venv does
# not carry (checked 2026-09-18: p4_proxy/venv -> ModuleNotFoundError: No module named 'p4.tmp';
# /home/adam/p4dev-python-venv -> imports ok). The import is proved here, in the interpreter
# that will run the controller, so a missing module is a named refusal and not "the controller
# exited within 10s".
CTRL_PY="${CTRL_PY:-/home/adam/p4dev-python-venv/bin/python}"
[[ -x "$CTRL_PY" ]] || fail "no controller interpreter at $CTRL_PY (set CTRL_PY= to point elsewhere)"
TUTORIALS_UTILS="$(dirname "$(dirname "$EXERCISE")")/utils"
if ! "$CTRL_PY" -c "import sys; sys.path.insert(0, '$TUTORIALS_UTILS'); import grpc, p4runtime_lib.bmv2, p4runtime_lib.helper; from p4.tmp import p4config_pb2" \
        > "$RUN/39_controller_imports.txt" 2>&1; then
    sed 's/^/     /' "$RUN/39_controller_imports.txt"
    fail "$CTRL_PY cannot import the tutorials' p4runtime_lib from $TUTORIALS_UTILS -- the controller would die at import"
fi
note "controller interpreter $CTRL_PY imports p4runtime_lib + p4.tmp"
CTRL_LOG="$RUN/40_controller.log"
setsid "$CTRL_PY" "$REPO/tools/p4_exercise/run_external_controller.py" "$PKG" mycontroller.py \
    > "$CTRL_LOG" 2>&1 < /dev/null &
CTRL_PID=$!
note "pid $CTRL_PID -> $(basename "$CTRL_LOG")   (the EXIT trap stops it by this pid; never pkill)"
sleep 10
if ! kill -0 "$CTRL_PID" 2>/dev/null; then
    sed 's/^/     /' "$CTRL_LOG"
    CTRL_PID=""
    fail "the controller exited within 10s -- see 40_controller.log"
fi
head -20 "$CTRL_LOG" | sed 's/^/     /'

# --- 4. it forwards ---------------------------------------------------------------------------------
H1_IP="$(model_hosts "$PKG" | sed -n '1p' | cut -d' ' -f2)"
H2_IP="$(model_hosts "$PKG" | sed -n '2p' | cut -d' ' -f2)"
[[ -n "$H1_IP" && -n "$H2_IP" ]] || die "could not read h1's and h2's addresses out of the package's model"

# both_ways <label> -- h1 -> h2 and h2 -> h1, five packets each, EXACTLY 0% loss and 5/5
# received required. Prints OK, or the reasons. Raw goes to <label>_ping_raw.txt.
#
# Both directions, because the tunnel rules mycontroller.py writes are per-direction: one
# direction working is a half-programmed switch, and a single-direction check would call that a
# pass. One function, called twice, so the before and the after are the same measurement.
both_ways() {
    local label="$1" raw="$RUN/${label}_ping_raw.txt" r why="" p h d
    local probes=("h1 $H2_IP" "h2 $H1_IP")
    for p in "${probes[@]}"; do
        read -r h d <<<"$p"
        r="$(ping_loss "$h" "$d" 5 "$raw")"
        case "$r" in
            "0 5/5")   ;;
            UNTESTED*) why="${why}${why:+; }$h -> $d: $r" ;;
            *)         why="${why}${why:+; }$h -> $d: ${r%% *}% loss, ${r#* } received" ;;
        esac
    done
    [[ -z "$why" ]] && { echo OK; return 0; }
    echo "$why"; return 1
}

say "ndt's own dataplane_ok (recorded, not the loss evidence)"
set +e
( set +e; source "$NDT" >/dev/null 2>&1; dataplane_ok h1 "$H2_IP"; echo "DATAPLANE_RC=$?  why=${NDT_DATAPLANE_WHY:-}" ) \
    > "$RUN/41_dataplane_ok_before.txt" 2>&1
set -e
sed 's/^/   /' "$RUN/41_dataplane_ok_before.txt"

say "h1 <-> h2, ping -c 5 each way, loss parsed from ping"
set +e
PING_BEFORE="$(both_ways 42_before)"
set -e
note "$PING_BEFORE   (raw: $(basename "$RUN")/42_before_ping_raw.txt)"
if [[ "$PING_BEFORE" != OK ]]; then
    fail "h1 <-> h2 is not 0% loss with the exercise controller running ($PING_BEFORE) -- steps 5-7 would be measuring an empty fabric"
fi

# --- 5. the control: there is something to wipe -------------------------------------------------------
say "counting s1's entries with the third-party client"
N_BEFORE="$(count_s1)"
note "s1 entries before the readopt: ${N_BEFORE:-<read failed>}"
printf '%s\n' "${N_BEFORE:-READ-FAILED}" > "$RUN/50_s1_entries_before.txt"
if [[ ! "$N_BEFORE" =~ ^[0-9]+$ ]] || (( N_BEFORE == 0 )); then
    fail "s1 has ${N_BEFORE:-no readable} entries BEFORE the readopt -- 'the count did not change' would then be true of a switch with no tables, so the rest of this step could prove nothing"
fi

# --- 6. the proxy is asked to adopt the switch ----------------------------------------------------------
say "POST /p4/readopt/1 -- the proxy's own pipeline-push path"
set +e
curl -s -o "$RUN/60_readopt_body.txt" -w '%{http_code}' -X POST --max-time 20 \
     "$PROXY_URL/p4/readopt/1" > "$RUN/60_readopt_code.txt" 2>"$RUN/60_readopt.err"
set -e
RO_CODE="$(cat "$RUN/60_readopt_code.txt" 2>/dev/null)"
note "http $RO_CODE"
sed 's/^/     /' "$RUN/60_readopt_body.txt" 2>/dev/null | head -8
case "$RO_CODE" in
    4??|5??) note "refused, which is what an external control plane must do" ;;
    *)       fail "readopt answered http $RO_CODE; under an external package the proxy must refuse to adopt a switch it does not control" ;;
esac
# 🔴 The REASON, not just the refusal. P1-A §4-8: this used to fail closed for the wrong stated
# reason -- the mastership gate, whose message describes a race this proxy LOST, when in fact it
# is configured never to enter one. An operator retries or power-cycles for the first and does
# nothing for the second.
if /usr/bin/grep -qiE 'external|read.?only|ControlPlaneReadOnly' "$RUN/60_readopt_body.txt" 2>/dev/null; then
    note "and it says why: the body names the external / read-only control plane"
else
    fail "the readopt refusal does not name the external control plane -- P1-A §4-8: a refusal that blames a mastership race describes a contest this proxy never entered"
fi

# --- 7. nothing was wiped ---------------------------------------------------------------------------------
say "counting again, and pinging again"
N_AFTER="$(count_s1)"
printf '%s\n' "${N_AFTER:-READ-FAILED}" > "$RUN/70_s1_entries_after.txt"
note "s1 entries after the readopt:  ${N_AFTER:-<read failed>}   (before: $N_BEFORE)"
if [[ ! "$N_AFTER" =~ ^[0-9]+$ ]]; then
    fail "s1's entries could not be read after the readopt -- an unreadable count is not an unchanged one"
elif (( N_AFTER != N_BEFORE )); then
    fail "s1 had $N_BEFORE entries and now has $N_AFTER -- the proxy's readopt changed the exercise's tables"
else
    note "unchanged"
fi
set +e
PING_AFTER="$(both_ways 71_after)"
set -e
note "$PING_AFTER   (raw: $(basename "$RUN")/71_after_ping_raw.txt)"
[[ "$PING_AFTER" == OK ]] || fail "h1 <-> h2 was 0% loss before the readopt and is not after it ($PING_AFTER)"

tail -20 "$CTRL_LOG" > "$RUN/72_controller_tail.txt" 2>/dev/null || true
say "done -- teardown follows (controller by pid, then ndt down)"
