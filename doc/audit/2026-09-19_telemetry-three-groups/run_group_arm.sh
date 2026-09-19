#!/usr/bin/env bash
# One ladder arm of the three-group telemetry round: the clean forwarding rate of ONE telemetry
# group at ONE Ethernet frame size, with per-process CPU sampled underneath it.
#
# Design is PREREG.md; read that first. Modelled on 2026-08-28_packet-size-sweep/run_size_arm.sh,
# with the parts that had to change stated here rather than left as a silent difference:
#
#   * FRAME size, not payload. iperf3 -l is UDP payload; frame = payload + 42 (14 Ethernet + 20
#     IPv4 + 8 UDP). 64/1024 B frames are -l 22/982. Both numbers go into arm.meta. PREREG 3.2.
#
#   * pps is read from delivered datagrams and duration, never back-derived from a bps figure
#     and a nominal size -- that computes the answer from the assumption. PREREG 3.3.
#
#   * THE GROUP IS PROVED, NOT ASSUMED. /p4/switch_state is read before and after and every
#     switch's telemetry.source must equal the group this arm claims to be. PREREG 2.
#
#   * AND SO IS WHETHER TELEMETRY ACTUALLY FLOWED, in both directions. `none` must ingest zero
#     samples and the others must ingest some. 2026-08-20 labelled two cells zero-sampling while
#     an orphaned multicast group kept cloning, and retracted every conclusion resting on them;
#     the same round's truncated-clone cell produced no telemetry at all and its CPU signature
#     was indistinguishable from having none. Both are invisible without these two assertions.
#     PREREG 2.1 + AMENDMENT-1 A1.2.
#
#   * The load gate is on FOREIGN CPU, and the residual subtracts kernel, proxy and emitter as
#     well as bmv2 and iperf3, because in THIS round those three are the treatment. It is
#     compared within the group, never across groups: `tc action sample` burns softirq charged
#     to no pid, so a global gate would demand a rerun of exactly the arms carrying the result.
#     PREREG 6. This script only produces the quantity; analyse.py applies the gate.
#
#   * CPU attribution takes pids from a manifest and a pidfile where it can, and exact `comm`
#     where it cannot. Never a pattern over argv: 08-28's own arm script read the switch binary
#     out of `pgrep -af`, and that is forbidden here (TICKET-P3 section 0 red line 1). The
#     binary comes out of /tmp/ndtwin_p4_switches.json instead.
#
# Usage:
#   NDT_OWNER="..." ./run_group_arm.sh --group <none|cooperative|link> --frame <64|1024> \
#                                      --arm <label> [--out <dir>] [--dry-run]
#
# Exit: 0 the arm produced a reading; 1 the arm is INVALID (PREREG section 7 -- the reason is in
#       arm.meta as invalid=); 2 refused before anything was started.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 🔴 NDT_REPO EXISTS BECAUSE THE LIVE STACK IS NOT NECESSARILY THIS CHECKOUT. The kernel binary,
# .test_run/pids and .test_run/lab.claim belong to whichever tree `ndt up` was run from, and a
# worktree's build/ is empty. Defaults to the tree this script is in, which is right once the
# branch is merged and the arms run from the main checkout; set NDT_REPO to run them from here.
REPO="${NDT_REPO:-$(cd "$HERE/../../.." && pwd)}"

GROUP=""; FRAME=""; ARM=""; OUT=""; DRY=0
while (( $# )); do
    case "$1" in
        --group) GROUP="${2:-}"; shift 2 ;;
        --frame) FRAME="${2:-}"; shift 2 ;;
        --arm)   ARM="${2:-}";   shift 2 ;;
        --out)   OUT="${2:-}";   shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '1,42p' "$0"; exit 0 ;;
        *) echo "🔴 unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$GROUP" && -n "$FRAME" && -n "$ARM" ]] || {
    echo "🔴 usage: run_group_arm.sh --group <none|cooperative|link> --frame <64|1024> --arm <label>" >&2
    exit 2; }
case "$GROUP" in
    none|cooperative|link) ;;
    *) echo "🔴 group must be none|cooperative|link, got '$GROUP'" >&2; exit 2 ;;
esac
[[ "$FRAME" =~ ^[0-9]+$ ]] || { echo "🔴 frame must be a byte count, got '$FRAME'" >&2; exit 2; }
PAYLOAD=$((FRAME - 42))
(( PAYLOAD > 0 )) || { echo "🔴 frame $FRAME is too small: payload would be $PAYLOAD" >&2; exit 2; }
OUT="${OUT:-$HERE/raw/$ARM}"

# --- the knobs: all overridable, all recorded ----------------------------------------------
STEP_S="${STEP_S:-8}"
CLEAN_PCT="${CLEAN_PCT:-0.5}"
AMB_HI="${AMB_HI:-2.0}"
RATES_KPPS="${RATES_KPPS:-1 2 3 5 8 12 20 30 45 70 110 160 240}"    # PREREG 4.1 = 08-28 7.5
SAT_STOP_PCT="${SAT_STOP_PCT:-25}"
BURNERS="${BURNERS:-0}"            # positive control only (PREREG 4.3 C3)
BURNER_RUNG="${BURNER_RUNG:-4}"
CPU_HZ="${CPU_HZ:-2}"
SRC_HOST="${SRC_HOST:-h1}"
DST_HOST="${DST_HOST:-h4}"
LOOPBACK="${LOOPBACK:-0}"          # sender control (PREREG 4.3 C1/C2): h1 -> h1, not via bmv2

KERNEL_URL="${KERNEL_URL:-http://localhost:8000}"
PROXY_URL="${PROXY_URL:-http://localhost:8081}"
SW_MANIFEST="${SW_MANIFEST:-/tmp/ndtwin_p4_switches.json}"
LT_MANIFEST="${LT_MANIFEST:-/tmp/ndtwin_link_telemetry.json}"
LT_LOG="${LT_LOG:-/tmp/ndtwin_link_telemetry.log}"
KERNEL_BIN="$REPO/build/bin/ndtwin_kernel"
BMV2_OVERRIDE="$REPO/p4_proxy/mininet/bmv2_binary_override"
PIPELINE_JSON="$REPO/p4_proxy/p4_src/build/ndtwin_switch.json"
PROBE="$HERE/cpu_arm_probe.py"

# The interpreter: the proxy venv where there is one (a worktree's is a symlink into the main
# checkout), else python3. Only stdlib json is used here, so either answers.
PY=""
for c in "${NDT_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$(command -v python3 || true)"; do
    [[ -n "$c" && -x "$c" ]] && { PY="$c"; break; }
done
[[ -n "$PY" ]] || { echo "🔴 no python3 interpreter" >&2; exit 2; }

# --- dry run: the plan and the exact commands, nothing executed -----------------------------
if (( DRY )); then
    printf '### DRY RUN -- run_group_arm.sh   (nothing started, nothing written)\n'
    printf 'arm                 %s\n' "$ARM"
    printf 'group               %s   (proved per switch from GET %s/p4/switch_state)\n' "$GROUP" "$PROXY_URL"
    printf 'frame_bytes         %s\n' "$FRAME"
    printf 'payload_bytes       %s   (frame = payload + 42; iperf3 -l takes the PAYLOAD)\n' "$PAYLOAD"
    printf 'host_pair           %s -> %s%s\n' "$SRC_HOST" "$DST_HOST" \
        "$( (( LOOPBACK )) && printf '   [LOOPBACK: does not traverse bmv2]' )"
    printf 'ladder_kpps         %s\n' "$RATES_KPPS"
    printf 'step_s              %s   clean <= %s%%   ambiguous band (0, %s%%] => 3 reps\n' "$STEP_S" "$CLEAN_PCT" "$AMB_HI"
    printf 'saturation stop     two consecutive rungs > %s%%\n' "$SAT_STOP_PCT"
    printf 'burners             %s%s\n' "$BURNERS" \
        "$( (( BURNERS > 0 )) && printf '   (started at rung %s -- the external gate positive control)' "$BURNER_RUNG" )"
    printf 'out                 %s\n\n' "$OUT"
    printf 'commands this arm would run, verbatim:\n'
    printf '  curl -sf --max-time 10 %s/p4/switch_state\n' "$PROXY_URL"
    printf '  curl -sf --max-time 10 %s/ndt/get_sflow_stats\n' "$KERNEL_URL"
    printf '  sha256sum %s\n' "$KERNEL_BIN"
    printf '  %s %s/manifest.py binary %s     # the argv is ONE STRING; shlex, not iteration\n' \
        "$PY" "$HERE" "$SW_MANIFEST"
    printf '  nm -DC $SWITCH_BIN | /usr/bin/grep -c EventLogger    # fast=0, stock=24 (1b section 3)\n'
    printf '  sha256sum %s\n' "$PIPELINE_JSON"
    printf '  %s %s --out %s/cpu.jsonl --duration <arm seconds> --hz %s \\\n' "$PY" "$PROBE" "$OUT" "$CPU_HZ"
    printf '      --comm iperf3=iperf3 --pid kernel=$KERNEL_PID --pid proxy=$PROXY_PID%s \\\n' \
        "$( [[ "$GROUP" == link ]] && printf ' --pid emitter=$EMITTER_PID' )"
    printf '      --pid bmv2-<device_id>=$PID ...   # pids from %s\n' "$SW_MANIFEST"
    printf '  sudo -n mnexec -a $DST_PID iperf3 -s -1 --daemon -p <port>\n'
    printf '  sudo -n mnexec -a $SRC_PID iperf3 -c <dst ip> -p <port> -u -b <kpps*%s*8> -t %s -l %s --json\n' \
        "$PAYLOAD" "$STEP_S" "$PAYLOAD"
    printf '  curl -sf --max-time 10 %s/ndt/get_sflow_stats\n' "$KERNEL_URL"
    printf '  curl -sf --max-time 10 %s/p4/switch_state\n' "$PROXY_URL"
    [[ "$GROUP" == link ]] && printf '  cp %s %s/emitter.log      # the next bring-up overwrites it\n' "$LT_LOG" "$OUT"
    printf '\nthis arm is INVALID (exit 1, reason in arm.meta) when:\n'
    printf '  * any switch telemetry.source != %s\n' "$GROUP"
    if [[ "$GROUP" == none ]]; then
        printf '  * get_sflow_stats addressed_total MOVED (then the group is not none -- 08-20 retraction)\n'
    else
        printf '  * get_sflow_stats addressed_total did NOT move (a silent outage looks exactly like none)\n'
    fi
    [[ "$GROUP" == link ]] && printf '  * link_emitter.alive is not true before or after\n'
    printf '  * the kernel sha256 differs between the start and the end of the arm\n'
    printf '  * the switch binary is not the one bmv2_binary_override names, or is not the fast signature\n'
    printf '  * any rung produced NO_MEASUREMENT\n'
    exit 0
fi

mkdir -p "$OUT" || { echo "🔴 cannot create $OUT" >&2; exit 2; }
META="$OUT/arm.meta"
INVALID=""
invalid() { [[ -n "$INVALID" ]] || INVALID="$*"; echo "🔴 INVALID: $*" >&2; }

# --- refusals, before anything is started ---------------------------------------------------
[[ -n "${NDT_OWNER:-}" ]] || { echo "🔴 NDT_OWNER unset" >&2; exit 2; }
claim_owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null | head -1)"
[[ "$claim_owner" == "$NDT_OWNER" ]] || {
    echo "🔴 lab.claim owner='$claim_owner' != NDT_OWNER='$NDT_OWNER' -- refusing" >&2; exit 2; }

# mininet host pids. $NF, not a substring: `h1` is a prefix of `h12`, and the last-field rule is
# also what keeps this awk from matching its own command line (stack.sh's note, measured 09-11).
host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
SRC_PID="$(host_pid "$SRC_HOST")"
DST_PID="$(host_pid "$DST_HOST")"
DST_IP="10.0.0.${DST_HOST#h}"
if (( LOOPBACK )); then DST_PID="$SRC_PID"; DST_IP="10.0.0.${SRC_HOST#h}"; fi
[[ -n "$SRC_PID" && -n "$DST_PID" ]] || {
    echo "🔴 host namespaces missing: $SRC_HOST=$SRC_PID $DST_HOST=$DST_PID -- is the fabric up?" >&2
    exit 2; }

get_json() {   # get_json <url> <file>; rc 0 only when the body parsed as JSON
    curl -sf --max-time 10 "$1" > "$2" 2>/dev/null || return 1
    "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$2" 2>/dev/null
}

# --- 1. the group, proved --------------------------------------------------------------------
STATE_BEFORE="$OUT/switch_state_before.json"
if ! get_json "$PROXY_URL/p4/switch_state" "$STATE_BEFORE"; then
    echo "🔴 GET /p4/switch_state gave nothing usable -- refusing to call this arm '$GROUP'" >&2
    exit 2
fi
GROUP_PROOF="$("$PY" - "$STATE_BEFORE" "$GROUP" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
want = sys.argv[2]
switches = state.get("switches") or {}
sources, bad = {}, []
for dpid, entry in sorted(switches.items(), key=lambda kv: int(kv[0])):
    telemetry = (entry or {}).get("telemetry") or {}
    source = telemetry.get("source")
    sources[dpid] = source
    if source != want:
        bad.append("%s=%s" % (dpid, source))
plane = ((state.get("control_plane") or {}).get("telemetry") or {})
emitter = plane.get("link_emitter") or {}
print("switch_count=%d" % len(switches))
print("telemetry_sources=%s" % ",".join("%s:%s" % (d, s) for d, s in sources.items()))
print("telemetry_knob=%s" % plane.get("knob"))
print("telemetry_package=%s" % plane.get("package"))
print("link_emitter_pid=%s" % emitter.get("pid"))
print("link_emitter_alive=%s" % emitter.get("alive"))
print("link_emitter_rate=%s" % emitter.get("rate"))
print("clone_sessions=%d" % sum(
    1 for e in switches.values() if ((e or {}).get("telemetry") or {}).get("clone_session")))
print("sflow_registered=%d" % sum(
    1 for e in switches.values() if ((e or {}).get("telemetry") or {}).get("sflow_registered")))
print("group_mismatch=%s" % (",".join(bad) if bad else "none"))
PY
)"
MISMATCH="$(sed -n 's/^group_mismatch=//p' <<<"$GROUP_PROOF")"
[[ "$MISMATCH" == "none" ]] || invalid "telemetry.source is not '$GROUP' on: $MISMATCH"
if [[ "$GROUP" == link ]]; then
    [[ "$(sed -n 's/^link_emitter_alive=//p' <<<"$GROUP_PROOF")" == "True" ]] \
        || invalid "group is link but control_plane.telemetry.link_emitter.alive is not true (before)"
fi

# --- 2. what is being measured, identified ---------------------------------------------------
# 🔴 THE MANIFEST'S `argv` IS ONE STRING, NOT A LIST OF TOKENS. This block used to
# iterate it -- and iterating a string yields CHARACTERS, so no token ever matched and every arm
# of the first real campaign was marked `invalid=no simple_switch binary ... this arm cannot
# name what it measured`, after none_f64_a had already measured a confirmed 30 kpps ceiling that
# then could not be used. The reader now lives in manifest.py, where it can be tested against
# the manifest the lab really writes (tests/fixtures/ndtwin_p4_switches.real.json, copied
# verbatim from the campaign's own /tmp/ndtwin_p4_switches.json). Ruling 27.
SWITCH_BIN="$("$PY" "$HERE/manifest.py" binary "$SW_MANIFEST")"
OVERRIDE_BIN="$(/usr/bin/grep -v '^[[:space:]]*#' "$BMV2_OVERRIDE" 2>/dev/null \
                | /usr/bin/grep -v '^[[:space:]]*$' | head -1 | xargs)"
if [[ -z "$SWITCH_BIN" ]]; then
    invalid "no simple_switch binary in $SW_MANIFEST -- this arm cannot name what it measured"
elif [[ "$SWITCH_BIN" != "$OVERRIDE_BIN" ]]; then
    invalid "manifest says '$SWITCH_BIN', bmv2_binary_override says '$OVERRIDE_BIN' -- refusing to guess"
fi
ELOG="$(nm -DC "$SWITCH_BIN" 2>/dev/null | /usr/bin/grep -c EventLogger)"
[[ "$ELOG" == "0" ]] \
    || invalid "the switch binary has $ELOG EventLogger symbols -- that is the stock signature, not bmv2-fast"

# `pid` and `device_id` ARE the manifest's own key names and are plain integers -- checked
# against the real file, not assumed this time.
mapfile -t SWROWS < <("$PY" "$HERE/manifest.py" rows "$SW_MANIFEST")
(( ${#SWROWS[@]} > 0 )) || invalid "no switch pids in $SW_MANIFEST"
# Cross-check against the exact comm. /proc/<pid>/comm truncates at 15 characters, so
# `simple_switch_grpc` reads back `simple_switch_g` -- matching the untruncated name silently
# misses every one of them, which is the trap cpu_probe.py's header records.
COMM_MISMATCH=0
for row in "${SWROWS[@]}"; do
    p="${row%% *}"
    c="$(cat "/proc/$p/comm" 2>/dev/null)"
    [[ "$c" == simple_switch* ]] || COMM_MISMATCH=$((COMM_MISMATCH + 1))
done
(( COMM_MISMATCH == 0 )) || invalid "$COMM_MISMATCH manifest pid(s) are not a simple_switch process now"

KERNEL_PID="$(cat "$REPO/.test_run/pids/kernel.child.pid" 2>/dev/null)"
PROXY_PID="$(cat "$REPO/.test_run/pids/p4_proxy.child.pid" 2>/dev/null)"
EMITTER_PID=""
if [[ "$GROUP" == link ]]; then
    EMITTER_PID="$(sed -n 's/^link_emitter_pid=//p' <<<"$GROUP_PROOF")"
    [[ "$EMITTER_PID" == "None" ]] && EMITTER_PID=""
fi

{
  echo "arm=$ARM"
  echo "group=$GROUP"
  echo "frame_bytes=$FRAME"
  echo "payload_bytes=$PAYLOAD"
  echo "started=$(date -u '+%FT%TZ')"
  echo "ladder_kpps=$RATES_KPPS"
  echo "step_s=$STEP_S"
  echo "clean_pct=$CLEAN_PCT"
  echo "rep_rule=nonzero-to-${AMB_HI}pct => 3 reps median; exact 0.0000 => 1 rep (3's AMENDMENT-2 11.1)"
  echo "host_pair=${SRC_HOST}->${DST_HOST} (${DST_IP})"
  echo "loopback=$LOOPBACK"
  echo "kernel_sha256_start=$(sha256sum "$KERNEL_BIN" 2>/dev/null | cut -d' ' -f1)"
  echo "switch_binary=$SWITCH_BIN"
  echo "switch_binary_override_agrees=$OVERRIDE_BIN"
  echo "switch_binary_sha256=$(sha256sum "$SWITCH_BIN" 2>/dev/null | cut -d' ' -f1)"
  echo "build_signature_EventLogger=$ELOG  # fast=0, stock=24 (1b section 3); asserted both ways"
  echo "pipeline_json_sha256=$(sha256sum "$PIPELINE_JSON" 2>/dev/null | cut -d' ' -f1)"
  echo "switch_count_manifest=${#SWROWS[@]}"
  echo "switch_pids=$(printf '%s ' "${SWROWS[@]%% *}")"
  echo "kernel_pid=${KERNEL_PID:-none}"
  echo "proxy_pid=${PROXY_PID:-none}"
  echo "emitter_pid=${EMITTER_PID:-none}"
  echo "burners=$BURNERS"
  echo "gate=external residual; kernel/proxy/emitter also subtracted; compared WITHIN group (PREREG 6)"
  printf '%s\n' "$GROUP_PROOF"
} > "$META"

# --- 3. the CPU sampler, pids passed in ------------------------------------------------------
# A generous upper bound on the arm's length: every rung can take three reps plus a one-second
# server start, and the confirmation adds three more. Over-running is free -- the probe is
# stopped at the end of the arm anyway -- while under-running would silently truncate the trace.
RUNGS=$(wc -w <<<"$RATES_KPPS")
PROBE_SECS=$(( (RUNGS * 3 + 4) * (STEP_S + 3) ))
PROBE_ARGS=(--out "$OUT/cpu.jsonl" --duration "$PROBE_SECS" --hz "$CPU_HZ" --comm "iperf3=iperf3")
[[ -n "$KERNEL_PID" ]]  && PROBE_ARGS+=(--pid "kernel=$KERNEL_PID")
[[ -n "$PROXY_PID" ]]   && PROBE_ARGS+=(--pid "proxy=$PROXY_PID")
[[ -n "$EMITTER_PID" ]] && PROBE_ARGS+=(--pid "emitter=$EMITTER_PID")
for row in "${SWROWS[@]}"; do PROBE_ARGS+=(--pid "bmv2-${row##* }=${row%% *}"); done
"$PY" "$PROBE" "${PROBE_ARGS[@]}" > "$OUT/cpu_probe.log" 2>&1 &
SAMPLER=$!
BURNER_PIDS=""
# Only pids this script started itself, signalled by their own pid. Never pkill/pgrep.
cleanup() {
    [[ -n "${SAMPLER:-}" ]] && kill "$SAMPLER" 2>/dev/null
    for b in ${BURNER_PIDS:-}; do kill "$b" 2>/dev/null; done
}
trap cleanup EXIT

snap_netdev() {
    /usr/bin/grep -E '^[[:space:]]*s[0-9]+-eth[0-9]+:' /proc/net/dev > "$OUT/netdev_$1.txt" 2>/dev/null
}
snap_netdev before
get_json "$KERNEL_URL/ndt/get_sflow_stats" "$OUT/sflow_before.json" \
    || echo '{"error":"no answer"}' > "$OUT/sflow_before.json"

# --- 4. the ladder ---------------------------------------------------------------------------
# rungs.tsv is what lets analyse.py slice cpu.jsonl by offered rate: CPU x offered pps is the
# third figure's x axis, and without a per-rep window the trace is one undifferentiated average
# over a ladder spanning a factor of 240.
printf 'kpps\trep\tt_start\tt_end\tloss\tsent_pps\trecv_pps\n' > "$OUT/rungs.tsv"

run_rep() {   # run_rep <kpps> <rep label> -> "<loss> <sent_pps> <recv_pps> <ok>"
    local kpps="$1" rep="$2" bps port t0 t1 line
    bps=$(awk -v k="$kpps" -v l="$PAYLOAD" 'BEGIN{printf "%d", k*1000*l*8}')
    port=$((5401 + (RANDOM % 150)))
    sudo -n mnexec -a "$DST_PID" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
    sleep 1
    t0=$(date +%s.%N)
    sudo -n mnexec -a "$SRC_PID" iperf3 -c "$DST_IP" -p "$port" -u -b "$bps" \
        -t "$STEP_S" -l "$PAYLOAD" --json > "$OUT/k${kpps}_rep${rep}.json" 2>&1
    t1=$(date +%s.%N)
    line="$("$PY" - "$OUT/k${kpps}_rep${rep}.json" <<'PY'
import json, sys
try:
    end = json.load(open(sys.argv[1]))["end"]
    sent, recv = end["sum_sent"], end["sum_received"]
    # pps from packets and seconds -- NOT from bits_per_second / (size*8), which would compute
    # the answer out of the assumption this round exists to test.
    print("%.4f %.1f %.1f 1" % (float(recv.get("lost_percent", 0.0)),
                                sent["packets"] / sent["seconds"],
                                recv["packets"] / recv["seconds"]))
except Exception:
    print("-1 -1 -1 0")          # no measurement is not a low-loss reading
PY
)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kpps" "$rep" "$t0" "$t1" \
        "$(cut -d' ' -f1 <<<"$line")" "$(cut -d' ' -f2 <<<"$line")" \
        "$(cut -d' ' -f3 <<<"$line")" >> "$OUT/rungs.tsv"
    printf '%s' "$line"
}

median3() { printf '%s\n' "$1" "$2" "$3" | sort -g | sed -n 2p; }

echo "### E arm $ARM  group $GROUP  frame ${FRAME}B (payload $PAYLOAD)  $SRC_HOST->$DST_HOST  step ${STEP_S}s  $(date -u '+%H:%M:%SZ')"
printf 'kpps_offered\treps\tloss_scored\tloss_reps\tsent_pps\trecv_pps\tclean\n' > "$OUT/ladder.tsv"

best_clean=""; hot=0; rung_i=0; no_measurement=0
for k in $RATES_KPPS; do
    rung_i=$((rung_i + 1))
    if (( BURNERS > 0 )) && (( rung_i == BURNER_RUNG )) && [[ -z "$BURNER_PIDS" ]]; then
        echo "  ⚡ starting $BURNERS CPU burner(s) -- the positive control for the external gate"
        for ((b = 0; b < BURNERS; b++)); do
            ( while :; do :; done ) & BURNER_PIDS="$BURNER_PIDS $!"
        done
    fi

    # 🔴 One get_sflow_stats read per RUNG, not per rep and not per second. The CPU fit's x axis
    # is samples/s, and samples/s has to be MEASURED per rung -- computing it from the offered
    # rate and an assumed 1/256 would put the model on both sides of the fit. One HTTP request
    # per rung is ~0.04 req/s against the 4 Hz poll that 08-20's POLL=off exists to remove, so it
    # is two orders of magnitude below the thing that was worth removing. It is still kernel work
    # served by the process being measured, and that is why it is per rung rather than per rep.
    get_json "$KERNEL_URL/ndt/get_sflow_stats" "$OUT/sflow_rung${k}_before.json" || true
    read -r l1 s1 v1 _ <<<"$(run_rep "$k" 1)"
    scored="$l1"; reps=1; all="$l1"
    if [[ "$l1" != "-1" ]] && awk "BEGIN{exit !($l1 > 0 && $l1 <= $AMB_HI)}"; then
        read -r l2 s2 v2 _ <<<"$(run_rep "$k" 2)"
        read -r l3 s3 v3 _ <<<"$(run_rep "$k" 3)"
        if [[ "$l2" == "-1" || "$l3" == "-1" ]]; then
            scored="-1"; all="$l1,$l2,$l3"
        else
            scored="$(median3 "$l1" "$l2" "$l3")"; all="$l1,$l2,$l3"
            s1="$(awk "BEGIN{printf \"%.1f\", ($s1+$s2+$s3)/3}")"
            v1="$(awk "BEGIN{printf \"%.1f\", ($v1+$v2+$v3)/3}")"
        fi
        reps=3
    fi
    get_json "$KERNEL_URL/ndt/get_sflow_stats" "$OUT/sflow_rung${k}_after.json" || true

    clean=no
    if [[ "$scored" == "-1" ]]; then
        clean=NO_MEASUREMENT; no_measurement=$((no_measurement + 1))
    elif awk "BEGIN{exit !($scored <= $CLEAN_PCT)}"; then
        clean=yes; best_clean="$k"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$reps" "$scored" "$all" "$s1" "$v1" "$clean" >> "$OUT/ladder.tsv"
    printf '  %5s kpps  reps %s  loss %8s%%  sent %9s pps  recv %9s pps  clean=%s\n' \
        "$k" "$reps" "$scored" "$s1" "$v1" "$clean"

    if [[ "$scored" != "-1" ]] && awk "BEGIN{exit !($scored > $SAT_STOP_PCT)}"; then
        hot=$((hot + 1))
        if (( hot >= 2 )); then
            echo "  ⚠️  two consecutive rungs above ${SAT_STOP_PCT}% -- stopping the climb at ${k} kpps."
            echo "     Rungs above ${k} kpps were NOT measured; the highest clean rung is already below."
            echo "ladder_truncated_at=$k" >> "$META"
            break
        fi
    else
        hot=0
    fi
done
/usr/bin/grep -q '^ladder_truncated_at=' "$META" || echo "ladder_truncated_at=not-truncated" >> "$META"

# top-rung re-confirmation with walk-down (3's AMENDMENT-2 11.1(b))
confirm=""
while [[ -n "$best_clean" ]]; do
    read -r c1 _ _ _ <<<"$(run_rep "$best_clean" c1)"
    read -r c2 _ _ _ <<<"$(run_rep "$best_clean" c2)"
    read -r c3 _ _ _ <<<"$(run_rep "$best_clean" c3)"
    if [[ "$c1" == "-1" || "$c2" == "-1" || "$c3" == "-1" ]]; then
        echo "  🔴 confirmation of ${best_clean} kpps produced no measurement"
        confirm="${confirm}${best_clean}:NO_MEASUREMENT "
        no_measurement=$((no_measurement + 1))
        break
    fi
    cmed="$(median3 "$c1" "$c2" "$c3")"
    confirm="${confirm}${best_clean}:${c1},${c2},${c3}=>${cmed} "
    if awk "BEGIN{exit !($cmed <= $CLEAN_PCT)}"; then
        echo "  ✅ confirmed ${best_clean} kpps  reps $c1,$c2,$c3  median ${cmed}% <= ${CLEAN_PCT}%"
        break
    fi
    echo "  ⚠️  ${best_clean} kpps FAILED confirmation (median ${cmed}% > ${CLEAN_PCT}%) -- walking down"
    best_clean="$(awk -F'\t' -v cur="$best_clean" '$7=="yes" && $1+0 < cur+0 {b=$1} END{print b}' "$OUT/ladder.tsv")"
done

# --- 5. after: the same readings, and the emitter's own log ----------------------------------
snap_netdev after
for b in $BURNER_PIDS; do kill "$b" 2>/dev/null; done
BURNER_PIDS=""
[[ -n "${SAMPLER:-}" ]] && kill "$SAMPLER" 2>/dev/null
SAMPLER=""
get_json "$KERNEL_URL/ndt/get_sflow_stats" "$OUT/sflow_after.json" \
    || echo '{"error":"no answer"}' > "$OUT/sflow_after.json"
get_json "$PROXY_URL/p4/switch_state" "$OUT/switch_state_after.json" || true
# 🔴 The emitter's statistics line lives in a file the NEXT bring-up overwrites, and its
# dropped_*/enobufs counters are the only mechanism evidence H-B3 may be attributed on
# (PREREG 5.2). Copied here or it is gone.
if [[ "$GROUP" == link ]]; then
    cp "$LT_LOG" "$OUT/emitter.log" 2>/dev/null || echo "🔴 could not copy $LT_LOG" >&2
    cp "$LT_MANIFEST" "$OUT/link_telemetry_manifest.json" 2>/dev/null || true
fi

KERNEL_SHA_END="$(sha256sum "$KERNEL_BIN" 2>/dev/null | cut -d' ' -f1)"
KERNEL_SHA_START="$(sed -n 's/^kernel_sha256_start=//p' "$META")"
[[ "$KERNEL_SHA_END" == "$KERNEL_SHA_START" ]] \
    || invalid "the kernel binary changed during the arm ($KERNEL_SHA_START -> $KERNEL_SHA_END)"
(( no_measurement == 0 )) || invalid "$no_measurement rung(s) produced NO_MEASUREMENT"

# --- 6. did telemetry flow, or did it actually not? (PREREG 2.1 + AMENDMENT-1 A1.2) ----------
SFLOW_DELTA="$("$PY" - "$OUT/sflow_before.json" "$OUT/sflow_after.json" <<'PY'
import json, sys


def counters(path):
    """The counter block, wherever worker A put it.

    Looked for at the top level and under telemetry_health, and WHICH level it was found at is
    printed: a reader must be able to tell "this build does not export it" from "I looked in
    the wrong place".
    """
    try:
        document = json.load(open(path))
    except Exception:
        return {}, "unreadable"
    health = document.get("telemetry_health")
    if isinstance(health, dict):
        merged = dict(health)
        for key, value in document.items():
            merged.setdefault(key, value)
        return merged, "telemetry_health"
    return document, "top-level"


before, level_before = counters(sys.argv[1])
after, level_after = counters(sys.argv[2])
print("sflow_counter_level=%s/%s" % (level_before, level_after))
for name in ("rx_total", "addressed_total", "sock_ovfl_total", "app_drop_total",
             "malformed_ipv4_ihl"):
    b, a = before.get(name), after.get(name)
    if isinstance(b, int) and isinstance(a, int):
        print("d_%s=%d" % (name, a - b))
    else:
        # `absent`, never 0. "This build does not export it" and "it did not move" are different
        # facts and must not share a spelling.
        print("d_%s=absent" % name)
family_before, family_after = before.get("samples_by_family"), after.get("samples_by_family")
if isinstance(family_before, dict) and isinstance(family_after, dict):
    for family in sorted(set(family_before) | set(family_after)):
        x, y = family_before.get(family), family_after.get(family)
        moved = (y - x) if isinstance(x, int) and isinstance(y, int) else "absent"
        print("d_family_%s=%s" % (family, moved))
else:
    print("d_family=absent   # worker A's samples_by_family is not in this build's answer")
PY
)"
D_ADDRESSED="$(sed -n 's/^d_addressed_total=//p' <<<"$SFLOW_DELTA")"
case "$GROUP" in
    none)
        if [[ "$D_ADDRESSED" == "absent" ]]; then
            invalid "cannot prove the none group ingested nothing: get_sflow_stats has no addressed_total"
        elif (( D_ADDRESSED != 0 )); then
            invalid "group is 'none' but the kernel ingested $D_ADDRESSED samples -- this is 08-20's retracted cell"
        fi ;;
    *)
        if [[ "$D_ADDRESSED" == "absent" ]]; then
            invalid "cannot prove telemetry flowed: get_sflow_stats has no addressed_total"
        elif (( D_ADDRESSED <= 0 )); then
            invalid "group is '$GROUP' but the kernel ingested 0 samples -- a silent telemetry outage looks exactly like 'none'"
        fi ;;
esac
if [[ "$GROUP" == link && -s "$OUT/switch_state_after.json" ]]; then
    alive_after="$("$PY" -c '
import json, sys
state = json.load(open(sys.argv[1]))
plane = (state.get("control_plane") or {}).get("telemetry") or {}
print((plane.get("link_emitter") or {}).get("alive"))' "$OUT/switch_state_after.json" 2>/dev/null)"
    [[ "$alive_after" == "True" ]] \
        || invalid "the link emitter is not alive at the end of the arm (alive=$alive_after)"
fi

# --- 7. the gate quantity (PREREG 6.1). analyse.py applies the threshold, within group. ------
"$PY" - "$OUT/cpu.jsonl" >> "$META" <<'PY'
import json, sys

header, rows = None, []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        document = json.loads(line)
    except ValueError:
        continue
    if header is None:
        header = document
        continue
    if "machine" in document:
        rows.append(document)
if header is None or len(rows) < 2:
    print("external=-1  # fewer than two CPU samples")
    raise SystemExit(0)

BUSY = ("user", "nice", "system", "irq", "softirq", "steal")


def group_of(key):
    label = key.rsplit(":", 1)[0]
    return "bmv2" if label.startswith("bmv2") else label


first, last = rows[0], rows[-1]
d_busy = sum(last["machine"][k] - first["machine"][k] for k in BUSY)
d_total = sum(last["machine"][k] - first["machine"][k] for k in last["machine"])
d_softirq = last["machine"]["softirq"] - first["machine"]["softirq"]
# Per-pid accumulator, not a snapshot sum. Every rung spawns fresh iperf3 processes that then
# exit, so "sum over whatever is alive now" falls back to ~0 between reps and last-minus-first
# reads zero -- 08-28 caught exactly that, and the unattributed generator cost then lands in
# `external`, where it is largest at the smallest frame, which is the treatment.
#
# 🔴 AND FIRST SIGHT IS NOT ONE FACT. A process present in the FIRST sample was alive before the
# arm, so its reading is a LIFETIME total and adding it would charge hours of CPU to one arm; a
# process that appears later started at zero inside the arm, so its reading IS its cost. The
# discriminator is membership in the first row, not the value.
present_at_start = set((rows[0].get("proc") or {}).keys())
seen, accumulated = {}, {}
for row in rows:
    for key, value in row.get("proc", {}).items():
        name = group_of(key)
        if key not in seen:
            accumulated[name] = accumulated.get(name, 0) + (0 if key in present_at_start else value)
        elif value >= seen[key]:
            accumulated[name] = accumulated.get(name, 0) + (value - seen[key])
        else:
            accumulated[name] = accumulated.get(name, 0) + value     # pid reused mid-arm
        seen[key] = value
if d_total <= 0:
    print("external=-1  # the machine clock did not move")
    raise SystemExit(0)
attributed = sum(accumulated.get(name, 0)
                 for name in ("bmv2", "iperf3", "kernel", "proxy", "emitter"))
print("cpu_samples=%d" % len(rows))
print("cpu_window_s=%.1f" % (last["t"] - first["t"]))
print("total_busy=%.4f" % (d_busy / d_total))
print("softirq_share=%.4f" % (d_softirq / d_total))
for name in ("bmv2", "iperf3", "kernel", "proxy", "emitter"):
    print("%s_share=%.4f" % (name, accumulated.get(name, 0) / d_total))
print("external=%.4f" % ((d_busy - attributed) / d_total))
PY

{
  echo "highest_clean_kpps=${best_clean:-none}"
  echo "top_rung_confirmation=$confirm"
  echo "kernel_sha256_end=$KERNEL_SHA_END"
  printf '%s\n' "$SFLOW_DELTA"
  echo "finished=$(date -u '+%FT%TZ')"
  echo "invalid=${INVALID:-no}"
} >> "$META"

tail -14 "$META" | sed 's/^/### /'
[[ -z "$INVALID" ]] || exit 1
exit 0
