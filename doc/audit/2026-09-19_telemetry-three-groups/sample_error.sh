#!/usr/bin/env bash
# One sampling-error window: a fixed-rate UDP flow across the fabric while the twin and
# /proc/net/dev are read against each other, for ONE telemetry group at ONE offered rate.
#
# Design is PREREG.md section 3.4 and 5.2.
#
# 🔴 THE METHOD IS `ndt check`'s, DELIBERATELY AND LINE FOR LINE (tools/test_workflow/ndt, the
# python block under "sampling the twin and /proc/net/dev"):
#
#     * the twin publishes a RATE (link_bandwidth_usage_bps), never a cumulative byte count, so
#       the comparison is rate against rate: integrate the twin's rate time-weighted (value x dt,
#       not one sample per change) and take ground truth from the tx_bytes delta over the window;
#     * both sides are summed over the SAME key set -- the intersection of the twin's
#       inter-switch edges with /proc/net/dev. They genuinely differ, and a mismatched population
#       shows up as a skewed ratio and reads as double-counting, which is the one thing that
#       comparison exists to detect;
#     * 4 Hz, because the twin refreshes usage once a second and the sampler must be above it.
#
# WHY NOT JUST CALL `ndt check` (PREREG 3.4):
#     (a) its output is a screen of prose a driver cannot read -- its own comment says so;
#     (b) it REFUSES while lab.claim carries `measuring=`, and this round must declare one;
#     (c) it emits one ratio, and a window here needs the twin integral, the ground truth, the
#         per-edge readings, the count of non-zero twin readings and the get_sflow_stats deltas.
#
# 🔴 `none` IS n/a, NOT ZERO. The group has no twin readings; a 0 would be a reading. What is
# recorded for it instead is the count of non-zero twin readings, which must be 0 -- the
# assertion 2026-08-20's retracted "no clone session" cell did not have.
#
# Usage:
#   NDT_OWNER="..." ./sample_error.sh --group <g> --rate <mbit> --window <n> [--out <dir>] [--dry-run]
#
# Exit: 0 the window produced a reading; 1 the window is INVALID (reason in window.json);
#       2 refused before anything was started.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${NDT_REPO:-$(cd "$HERE/../../.." && pwd)}"

GROUP=""; RATE=""; WINDOW=""; OUT=""; DRY=0
while (( $# )); do
    case "$1" in
        --group)  GROUP="${2:-}";  shift 2 ;;
        --rate)   RATE="${2:-}";   shift 2 ;;
        --window) WINDOW="${2:-}"; shift 2 ;;
        --out)    OUT="${2:-}";    shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '1,33p' "$0"; exit 0 ;;
        *) echo "🔴 unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$GROUP" && -n "$RATE" && -n "$WINDOW" ]] || {
    echo "🔴 usage: sample_error.sh --group <none|cooperative|link> --rate <mbit> --window <n>" >&2
    exit 2; }
case "$GROUP" in
    none|cooperative|link) ;;
    *) echo "🔴 group must be none|cooperative|link, got '$GROUP'" >&2; exit 2 ;;
esac
[[ "$RATE" =~ ^[0-9]+$ ]] || { echo "🔴 rate must be an integer Mbit/s, got '$RATE'" >&2; exit 2; }

DUR_S="${DUR_S:-8}"                 # = ndt check's NDT_CHECK_SECS default
HZ="${HZ:-4}"                       # = ndt check's HZ
PAYLOAD="${PAYLOAD:-1400}"          # frame 1442 B, the size 08-20 used
SRC_HOST="${SRC_HOST:-h1}"
DST_HOST="${DST_HOST:-h4}"
KERNEL_URL="${KERNEL_URL:-http://localhost:8000}"
PROXY_URL="${PROXY_URL:-http://localhost:8081}"
LT_LOG="${LT_LOG:-/tmp/ndtwin_link_telemetry.log}"
OUT="${OUT:-$HERE/raw/se_${GROUP}_${RATE}M_${WINDOW}}"

PY=""
for c in "${NDT_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$(command -v python3 || true)"; do
    [[ -n "$c" && -x "$c" ]] && { PY="$c"; break; }
done
[[ -n "$PY" ]] || { echo "🔴 no python3 interpreter" >&2; exit 2; }

if (( DRY )); then
    printf '### DRY RUN -- sample_error.sh   (nothing started, nothing written)\n'
    printf 'group               %s\n' "$GROUP"
    printf 'offered rate        %s Mbit/s   UDP, -l %s (frame %s B)\n' "$RATE" "$PAYLOAD" "$((PAYLOAD + 42))"
    printf 'window              %s, %ss at %s Hz   (= ndt check NDT_CHECK_SECS / HZ)\n' "$WINDOW" "$DUR_S" "$HZ"
    printf 'metric              |twin_integral/tx_bytes - 1| over the SAME inter-switch key set\n'
    printf '                    %s\n' \
        "$( [[ "$GROUP" == none ]] && printf 'n/a for this group -- it has no twin readings; a 0 would be a reading' \
                                   || printf 'signed (ratio-1) recorded beside it: 12 consecutive LOW readings are the prior' )"
    printf 'out                 %s\n\n' "$OUT"
    printf 'commands this window would run, verbatim:\n'
    printf '  curl -sf --max-time 10 %s/ndt/get_sflow_stats\n' "$KERNEL_URL"
    printf '  curl -sf --max-time 10 %s/p4/switch_state\n' "$PROXY_URL"
    printf '  sudo -n mnexec -a $DST_PID iperf3 -s -1 --daemon -p <port>\n'
    printf '  sudo -n mnexec -a $SRC_PID iperf3 -c 10.0.0.%s -p <port> -u -b %sM -t %s -l %s --json\n' \
        "${DST_HOST#h}" "$RATE" "$((DUR_S + 4))" "$PAYLOAD"
    printf '  # concurrently, for %ss: GET %s/ndt/get_graph_data at %s Hz + /proc/net/dev each sample\n' \
        "$DUR_S" "$KERNEL_URL" "$HZ"
    printf '  curl -sf --max-time 10 %s/ndt/get_sflow_stats\n' "$KERNEL_URL"
    [[ "$GROUP" == link ]] && printf '  cp %s %s/emitter.log\n' "$LT_LOG" "$OUT"
    printf '\nthis window is INVALID when:\n'
    printf '  * any switch telemetry.source != %s\n' "$GROUP"
    if [[ "$GROUP" == none ]]; then
        printf '  * any non-zero twin link_bandwidth_usage_bps reading, or addressed_total moved\n'
    else
        printf '  * no non-zero twin reading, or addressed_total did not move\n'
    fi
    printf '  * ground truth under 1 Mbit/s over the window (ndt check: the ratio is not meaningful)\n'
    exit 0
fi

mkdir -p "$OUT" || { echo "🔴 cannot create $OUT" >&2; exit 2; }
[[ -n "${NDT_OWNER:-}" ]] || { echo "🔴 NDT_OWNER unset" >&2; exit 2; }
claim_owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null | head -1)"
[[ "$claim_owner" == "$NDT_OWNER" ]] || {
    echo "🔴 lab.claim owner='$claim_owner' != NDT_OWNER='$NDT_OWNER' -- refusing" >&2; exit 2; }

host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
SRC_PID="$(host_pid "$SRC_HOST")"
DST_PID="$(host_pid "$DST_HOST")"
[[ -n "$SRC_PID" && -n "$DST_PID" ]] || {
    echo "🔴 host namespaces missing: $SRC_HOST=$SRC_PID $DST_HOST=$DST_PID" >&2; exit 2; }
DST_IP="10.0.0.${DST_HOST#h}"

get_json() {
    curl -sf --max-time 10 "$1" > "$2" 2>/dev/null || return 1
    "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$2" 2>/dev/null
}
get_json "$PROXY_URL/p4/switch_state" "$OUT/switch_state.json" || true
get_json "$KERNEL_URL/ndt/get_sflow_stats" "$OUT/sflow_before.json" \
    || echo '{"error":"no answer"}' > "$OUT/sflow_before.json"

PORT=$((5601 + (RANDOM % 150)))
sudo -n mnexec -a "$DST_PID" iperf3 -s -1 --daemon -p "$PORT" >/dev/null 2>&1
sleep 1
# The flow runs LONGER than the measured window on both ends: the integration must sit inside a
# steady flow, not straddle its ramp. 08-20 discarded the first ~6 s of every trace for exactly
# this and found that including those zero-windows inverted its variance conclusion.
sudo -n mnexec -a "$SRC_PID" iperf3 -c "$DST_IP" -p "$PORT" -u -b "${RATE}M" \
    -t "$((DUR_S + 4))" -l "$PAYLOAD" --json > "$OUT/iperf3.json" 2>&1 &
IPERF=$!
cleanup() { [[ -n "${IPERF:-}" ]] && kill "$IPERF" 2>/dev/null; }
trap cleanup EXIT
sleep 2

"$PY" - "$OUT/window.json" "$DUR_S" "$HZ" "$KERNEL_URL/ndt/get_graph_data" "$GROUP" "$RATE" \
        "$WINDOW" "$PAYLOAD" <<'PY'
"""The twin/veth integration, the same arithmetic ndt check's cmd_check performs.

Kept as one block so the two sides cannot drift apart: the integral, the ground truth and the
key set are computed from the same samples in the same loop.
"""
import json, re, sys, time, urllib.request

out_path, dur, hz, url, group, rate, window, payload = (
    sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4],
    sys.argv[5], float(sys.argv[6]), sys.argv[7], int(sys.argv[8]))
IFACE = re.compile(r"^s\d+-eth\d+$")


def netdev():
    counters = {}
    for line in open("/proc/net/dev"):
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        name = name.strip()
        if IFACE.match(name):
            counters[name] = int(rest.split()[8])        # tx_bytes
    return counters


def twin_rates(graph, switch_dpids):
    # Inter-switch edges only, keyed the way /proc/net/dev names the interface, so both sides are
    # summed over exactly the same links.
    return {"s%s-eth%s" % (e["src_dpid"], e["src_interface"]): e["link_bandwidth_usage_bps"]
            for e in graph["edges"]
            if e["src_dpid"] in switch_dpids and e["dst_dpid"] in switch_dpids}


result = {"group": group, "offered_mbit": rate, "window": window, "payload_bytes": payload,
          "frame_bytes": payload + 42, "duration_s": dur, "hz": hz, "invalid": None}
try:
    graph0 = json.load(urllib.request.urlopen(url, timeout=10))
except Exception as exc:                                   # noqa: BLE001
    result["invalid"] = "cannot read the twin: %s" % exc
    json.dump(result, open(out_path, "w"), indent=2, sort_keys=True)
    raise SystemExit(1)

switch_dpids = {n["dpid"] for n in graph0["nodes"] if n.get("vertex_type") == 0}
netdev0 = netdev()
keys = sorted(set(twin_rates(graph0, switch_dpids)) & set(netdev0))
excluded = sorted(set(netdev0) - set(twin_rates(graph0, switch_dpids)))

t0 = time.time()
integral = 0.0                 # bit-seconds from the twin's reported rate
nonzero_readings = 0           # how many per-edge readings were not 0 (the `none` assertion)
samples = 0
per_edge_peak = {}
previous_t, previous_value = None, None
end = t0 + dur
while time.time() < end:
    now = time.time()
    try:
        rates = twin_rates(json.load(urllib.request.urlopen(url, timeout=10)), switch_dpids)
    except Exception:                                      # noqa: BLE001
        time.sleep(1.0 / hz)
        continue
    samples += 1
    for key in keys:
        value = rates.get(key, 0.0)
        if value:
            nonzero_readings += 1
            per_edge_peak[key] = max(per_edge_peak.get(key, 0.0), value)
    total = sum(rates.get(key, 0.0) for key in keys)
    if previous_t is not None:
        integral += previous_value * (now - previous_t)   # value x dt, not one sample per change
    previous_t, previous_value = now, total
    slack = 1.0 / hz - (time.time() - now)
    if slack > 0:
        time.sleep(slack)
t1 = time.time()
netdev1 = netdev()
if previous_t is not None:
    integral += previous_value * (t1 - previous_t)

elapsed = t1 - t0
truth_bits = sum(netdev1.get(k, 0) - netdev0.get(k, 0) for k in keys) * 8
twin_bps = integral / elapsed if elapsed > 0 else 0.0
truth_bps = truth_bits / elapsed if elapsed > 0 else 0.0

result.update({
    "keys": keys,
    "excluded_host_facing": excluded,
    "twin_samples": samples,
    "nonzero_twin_readings": nonzero_readings,
    "per_edge_peak_bps": per_edge_peak,
    "elapsed_s": round(elapsed, 3),
    "twin_bps": twin_bps,
    "truth_bps": truth_bps,
    "truth_bytes": truth_bits // 8,
})
if truth_bps < 1e6:
    # ndt check's own floor: under 1 Mbit/s across the fabric the ratio is not meaningful.
    result["invalid"] = "ground truth %.2f Mbit/s is under the 1 Mbit/s floor" % (truth_bps / 1e6)
elif group == "none":
    # 🔴 n/a, never 0. The group has no twin readings, and "no reading" is not "an error of zero".
    result["ratio"] = None
    result["abs_error"] = None
    result["signed_error"] = None
    result["ratio_note"] = ("n/a -- the none group has no twin readings; reporting 0 would turn "
                            "an absence into a measurement")
    if nonzero_readings:
        result["invalid"] = ("group is 'none' but the twin reported %d non-zero readings -- this "
                             "is 2026-08-20's retracted cell" % nonzero_readings)
else:
    ratio = twin_bps / truth_bps
    result["ratio"] = ratio
    result["abs_error"] = abs(ratio - 1.0)
    result["signed_error"] = ratio - 1.0
    if nonzero_readings == 0:
        result["invalid"] = ("group is '%s' but every twin reading was zero -- a silent telemetry "
                             "outage looks exactly like 'none'" % group)
json.dump(result, open(out_path, "w"), indent=2, sort_keys=True)
print("  window %s  group %-11s %5.0f Mbit/s offered   twin %8.2f  truth %8.2f Mbit/s  %s"
      % (window, group, rate, twin_bps / 1e6, truth_bps / 1e6,
         "n/a (none)" if result.get("ratio") is None
         else "|ratio-1| = %.4f  (ratio %.3f)" % (result["abs_error"], result["ratio"])))
raise SystemExit(0)
PY
RC=$?

wait "$IPERF" 2>/dev/null
IPERF=""
get_json "$KERNEL_URL/ndt/get_sflow_stats" "$OUT/sflow_after.json" \
    || echo '{"error":"no answer"}' > "$OUT/sflow_after.json"
[[ "$GROUP" == link ]] && { cp "$LT_LOG" "$OUT/emitter.log" 2>/dev/null || true; }

# The group proof and the ingest deltas, appended to window.json so one file answers "what group
# was this, and did the kernel actually receive anything".
"$PY" - "$OUT/window.json" "$OUT/switch_state.json" "$OUT/sflow_before.json" \
       "$OUT/sflow_after.json" "$GROUP" <<'PY'
import json, sys

window_path, state_path, before_path, after_path, group = sys.argv[1:6]
try:
    result = json.load(open(window_path))
except Exception:                                          # noqa: BLE001
    raise SystemExit(0)


def counters(path):
    try:
        document = json.load(open(path))
    except Exception:                                      # noqa: BLE001
        return {}
    health = document.get("telemetry_health")
    if isinstance(health, dict):
        merged = dict(health)
        for key, value in document.items():
            merged.setdefault(key, value)
        return merged
    return document


before, after = counters(before_path), counters(after_path)
deltas = {}
for name in ("rx_total", "addressed_total", "sock_ovfl_total", "app_drop_total",
             "malformed_ipv4_ihl"):
    b, a = before.get(name), after.get(name)
    deltas[name] = (a - b) if isinstance(b, int) and isinstance(a, int) else "absent"
family_before, family_after = before.get("samples_by_family"), after.get("samples_by_family")
if isinstance(family_before, dict) and isinstance(family_after, dict):
    deltas["samples_by_family"] = {
        f: ((family_after.get(f, 0) - family_before.get(f, 0))
            if isinstance(family_after.get(f), int) and isinstance(family_before.get(f), int)
            else "absent")
        for f in sorted(set(family_before) | set(family_after))}
else:
    deltas["samples_by_family"] = "absent"
result["sflow_deltas"] = deltas

try:
    state = json.load(open(state_path))
    switches = state.get("switches") or {}
    sources = {d: ((e or {}).get("telemetry") or {}).get("source")
               for d, e in switches.items()}
    result["telemetry_sources"] = sources
    bad = sorted(d for d, s in sources.items() if s != group)
    if bad and not result.get("invalid"):
        result["invalid"] = "telemetry.source is not '%s' on dpid(s) %s" % (group, ",".join(bad))
except Exception:                                          # noqa: BLE001
    result["telemetry_sources"] = None

addressed = deltas.get("addressed_total")
if isinstance(addressed, int) and not result.get("invalid"):
    if group == "none" and addressed != 0:
        result["invalid"] = ("group is 'none' but the kernel ingested %d samples in the window"
                             % addressed)
    if group != "none" and addressed <= 0:
        result["invalid"] = "group is '%s' but the kernel ingested 0 samples in the window" % group

json.dump(result, open(window_path, "w"), indent=2, sort_keys=True)
if result.get("invalid"):
    print("  🔴 INVALID: %s" % result["invalid"])
    raise SystemExit(1)
raise SystemExit(0)
PY
POST_RC=$?

(( RC == 0 && POST_RC == 0 )) || exit 1
exit 0
