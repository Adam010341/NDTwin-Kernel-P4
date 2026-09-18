#!/usr/bin/env bash
# [Co-developed with claude code -- Adam]
#
# spike.sh -- does psample deliver samples for traffic crossing a veth when a
#             `tc ... matchall action sample` filter is attached, at the configured rate?
#
# ONE COMMAND:   sudo bash spike.sh
#
# Everything happens inside two throwaway network namespaces (ndtspike-a, ndtspike-b)
# joined by one veth pair (spk-a/spk-b).  No host interface, bridge, netns or qdisc that
# existed before this script ran is read, written or deleted; `ndt` and Mininet are never
# invoked.  Both namespaces are destroyed in an EXIT trap, so a Ctrl-C leaves nothing.
#
# This proves ONE thing: samples arrive, and their count matches the configured 1/4 rate.
# It says nothing about bmv2, sFlow, accuracy under load, or CPU cost -- see README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/out"
LISTENER="${SCRIPT_DIR}/psample_listen.py"

NS_A="ndtspike-a"
NS_B="ndtspike-b"
VETH_A="spk-a"
VETH_B="spk-b"
ADDR_A="10.99.0.1/24"
ADDR_B="10.99.0.2/24"
IP_B="10.99.0.2"

RATE="${RATE:-4}"
TRUNC="${TRUNC:-128}"
GROUP_EGRESS="${GROUP_EGRESS:-7}"
GROUP_INGRESS="${GROUP_INGRESS:-8}"
PING_COUNT="${PING_COUNT:-200}"
PING_INTERVAL="${PING_INTERVAL:-0.02}"
LISTEN_SECONDS="${LISTEN_SECONDS:-20}"
BURST_SECONDS="${BURST_SECONDS:-10}"
TOLERANCE="${TOLERANCE:-0.30}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="${OUT_DIR}/REPORT-${STAMP}.md"
SAMPLES="${OUT_DIR}/samples.jsonl"
LISTENER_ERR="${OUT_DIR}/listener.stderr"
BURST_SAMPLES="${OUT_DIR}/samples-burst.jsonl"
BURST_ERR="${OUT_DIR}/burst-listener.stderr"
CONTEXT="${OUT_DIR}/context.json"
TRANSCRIPT="${OUT_DIR}/commands-${STAMP}.txt"

LISTENER_PID=""
BURST_PID=""
NC_SERVER_PID=""
NS_A_CREATED=0
NS_B_CREATED=0

# --------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------
log()  { printf '[spike] %s\n' "$*"; }
fail() { printf '[spike] FATAL: %s\n' "$*" >&2; exit 1; }

# Every privileged command goes through run() so the report can quote exactly what ran.
run() {
    printf '%s\n' "$*" >>"${TRANSCRIPT}"
    "$@"
}

cleanup() {
    local rc=$?
    set +e
    # Only PIDs this script started are ever signalled. `pkill -f`/`pgrep -f` are banned
    # in this repo (CLAUDE.md) and would be wrong here anyway -- they would match any
    # other psample_listen.py on the machine.
    for pid in "${LISTENER_PID}" "${BURST_PID}" "${NC_SERVER_PID}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null
            wait "${pid}" 2>/dev/null
        fi
    done
    if [[ "${NS_A_CREATED}" -eq 1 ]]; then ip netns del "${NS_A}" 2>/dev/null; fi
    if [[ "${NS_B_CREATED}" -eq 1 ]]; then ip netns del "${NS_B}" 2>/dev/null; fi
    # The veth pair is destroyed with the namespaces; nothing to unwind on the host.
    set -e
    return $rc
}
trap cleanup EXIT

# --------------------------------------------------------------------------------------
# pre-flight
# --------------------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
: >"${TRANSCRIPT}"

log "pre-flight"

[[ "$(id -u)" -eq 0 ]] || fail "must run as root: sudo bash ${BASH_SOURCE[0]}"
[[ -f "${LISTENER}" ]] || fail "psample_listen.py not found next to this script (${LISTENER})"

for tool in ip tc ping "${PYTHON_BIN}"; do
    command -v "${tool}" >/dev/null 2>&1 || fail "missing required tool: ${tool}"
done
"${PYTHON_BIN}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)' \
    || fail "${PYTHON_BIN} is older than 3.7"

KERNEL_RELEASE="$(uname -r)"
TC_VERSION="$(tc -V 2>&1 | head -1)"
IP_VERSION="$(ip -V 2>&1 | head -1)"
PYTHON_VERSION="$("${PYTHON_BIN}" -V 2>&1 | head -1)"
LSMOD_BEFORE="$(lsmod | awk '$1=="psample" || $1=="act_sample"' || true)"
MODINFO_ACT_SAMPLE="$(modinfo act_sample 2>&1 | awk -F': *' '$1 ~ /^(filename|vermagic|srcversion)/' || true)"
PSAMPLE_HEADER="absent"
[[ -f /usr/include/linux/psample.h ]] && PSAMPLE_HEADER="/usr/include/linux/psample.h"

# uid 0 is not the same thing as real root: inside `unshare -r` you are uid 0 in a private
# user namespace. The report must not claim a privileged run it did not have.
SELF_USERNS="$(readlink /proc/self/ns/user 2>/dev/null || echo unknown)"
INIT_USERNS="$(readlink /proc/1/ns/user 2>/dev/null || echo unknown)"
if [[ "${SELF_USERNS}" == "${INIT_USERNS}" && "${SELF_USERNS}" != "unknown" ]]; then
    PRIVILEGE_CONTEXT="real root (initial user namespace ${SELF_USERNS})"
else
    PRIVILEGE_CONTEXT="uid 0 inside a NON-initial user namespace (${SELF_USERNS}, init is ${INIT_USERNS})"
fi

log "privilege   ${PRIVILEGE_CONTEXT}"
log "kernel      ${KERNEL_RELEASE}"
log "tc          ${TC_VERSION}"
log "python      ${PYTHON_VERSION}"
log "psample.h   ${PSAMPLE_HEADER}"
log "modules before: ${LSMOD_BEFORE:-<neither psample nor act_sample loaded>}"

# Refuse rather than clobber: a leftover ndtspike* namespace means a previous run died.
EXISTING_NS="$(ip netns list 2>/dev/null | awk '{print $1}' | grep '^ndtspike' || true)"
if [[ -n "${EXISTING_NS}" ]]; then
    printf '[spike] FATAL: a network namespace named ndtspike* already exists:\n' >&2
    printf '%s\n' "${EXISTING_NS}" >&2
    printf '[spike] refusing to touch it. If it is a leftover from a crashed run, delete it with:\n' >&2
    while read -r leftover; do
        [[ -n "${leftover}" ]] && printf '    sudo ip netns del %s\n' "${leftover}" >&2
    done <<<"${EXISTING_NS}"
    exit 1
fi

# The veth pair is created directly inside the namespaces, so these names should never be
# visible on the host -- but check, so we can never collide with something that is.
for dev in "${VETH_A}" "${VETH_B}"; do
    if ip link show "${dev}" >/dev/null 2>&1; then
        fail "a host interface named ${dev} already exists; refusing to proceed"
    fi
done

# --------------------------------------------------------------------------------------
# topology: two private namespaces, one veth pair, nothing on the host
# --------------------------------------------------------------------------------------
log "creating namespaces ${NS_A} and ${NS_B}"
run ip netns add "${NS_A}"; NS_A_CREATED=1
run ip netns add "${NS_B}"; NS_B_CREATED=1

# Created straight into the namespaces: neither end ever appears in the root netns.
run ip -netns "${NS_A}" link add "${VETH_A}" type veth peer name "${VETH_B}" netns "${NS_B}"

# IPv6 off inside both namespaces: MLD/RS/DAD chatter would land in the sample counts and
# make "exactly 200 echo requests" untrue. These sysctls are per-netns; the host is untouched.
run ip netns exec "${NS_A}" sysctl -qw net.ipv6.conf.all.disable_ipv6=1
run ip netns exec "${NS_A}" sysctl -qw net.ipv6.conf.default.disable_ipv6=1
run ip netns exec "${NS_B}" sysctl -qw net.ipv6.conf.all.disable_ipv6=1
run ip netns exec "${NS_B}" sysctl -qw net.ipv6.conf.default.disable_ipv6=1

run ip -netns "${NS_A}" addr add "${ADDR_A}" dev "${VETH_A}"
run ip -netns "${NS_B}" addr add "${ADDR_B}" dev "${VETH_B}"
run ip -netns "${NS_A}" link set lo up
run ip -netns "${NS_B}" link set lo up
run ip -netns "${NS_A}" link set "${VETH_A}" up
run ip -netns "${NS_B}" link set "${VETH_B}" up

IFINDEX_A="$(ip netns exec "${NS_A}" cat "/sys/class/net/${VETH_A}/ifindex")"
IFINDEX_B="$(ip netns exec "${NS_B}" cat "/sys/class/net/${VETH_B}/ifindex")"
log "${VETH_A} ifindex ${IFINDEX_A} (in ${NS_A}), ${VETH_B} ifindex ${IFINDEX_B} (in ${NS_B})"

# --------------------------------------------------------------------------------------
# the sampler
# --------------------------------------------------------------------------------------
log "attaching clsact + matchall action sample (rate 1/${RATE}, trunc ${TRUNC})"
run ip netns exec "${NS_A}" tc qdisc add dev "${VETH_A}" clsact
# egress = what a SENDS; ingress = what a RECEIVES. Two groups so the directions are
# separable in one sample stream.
run ip netns exec "${NS_A}" tc filter add dev "${VETH_A}" egress \
    matchall action sample rate "${RATE}" group "${GROUP_EGRESS}" trunc "${TRUNC}"
run ip netns exec "${NS_A}" tc filter add dev "${VETH_A}" ingress \
    matchall action sample rate "${RATE}" group "${GROUP_INGRESS}" trunc "${TRUNC}"

LSMOD_AFTER="$(lsmod | awk '$1=="psample" || $1=="act_sample"' || true)"
log "modules after tc: ${LSMOD_AFTER:-<none>}"

FILTERS_EGRESS="$(ip netns exec "${NS_A}" tc -s filter show dev "${VETH_A}" egress 2>&1)"
FILTERS_INGRESS="$(ip netns exec "${NS_A}" tc -s filter show dev "${VETH_A}" ingress 2>&1)"

# --------------------------------------------------------------------------------------
# phase 1 -- the verdict run: exactly PING_COUNT echo requests out, PING_COUNT replies in
# --------------------------------------------------------------------------------------
# The listener runs INSIDE ns a. psample notifications are multicast with
# genlmsg_multicast_netns() to the netns owning the psample group, and the group itself is
# looked up per-net, so a listener on the host would see exactly zero of these samples.
log "starting listener inside ${NS_A} for ${LISTEN_SECONDS}s -> ${SAMPLES}"
: >"${SAMPLES}"
ip netns exec "${NS_A}" "${PYTHON_BIN}" "${LISTENER}" \
    --seconds "${LISTEN_SECONDS}" --json --data-prefix 32 \
    >"${SAMPLES}" 2>"${LISTENER_ERR}" &
LISTENER_PID=$!
printf 'ip netns exec %s %s psample_listen.py --seconds %s --json --data-prefix 32\n' \
    "${NS_A}" "${PYTHON_BIN}" "${LISTEN_SECONDS}" >>"${TRANSCRIPT}"

sleep 2   # let the socket join the multicast group before any traffic moves

log "ping: ${PING_COUNT} echo requests at ${PING_INTERVAL}s"
PING_OUTPUT="$(run ip netns exec "${NS_A}" ping -c "${PING_COUNT}" -i "${PING_INTERVAL}" \
    -q "${IP_B}" 2>&1 || true)"
printf '%s\n' "${PING_OUTPUT}" | sed 's/^/[spike]   /'

log "waiting for the listener to reach its deadline"
wait "${LISTENER_PID}" || true
LISTENER_PID=""

TC_STATS_EGRESS="$(ip netns exec "${NS_A}" tc -s filter show dev "${VETH_A}" egress 2>&1)"
TC_STATS_INGRESS="$(ip netns exec "${NS_A}" tc -s filter show dev "${VETH_A}" ingress 2>&1)"

# --------------------------------------------------------------------------------------
# phase 2 -- informational burst, NOT part of the verdict
# --------------------------------------------------------------------------------------
# Kept in its own listener run and its own file: mixing it into phase 1 would blow past the
# "200 packets / rate 4 = 50 samples" arithmetic the verdict is built on.
BURST_STATUS="skipped (nc not found)"
if command -v nc >/dev/null 2>&1; then
    log "burst phase (informational): dd 1400B x 2000 over UDP"
    : >"${BURST_SAMPLES}"
    ip netns exec "${NS_A}" "${PYTHON_BIN}" "${LISTENER}" \
        --seconds "${BURST_SECONDS}" --json --data-prefix 0 \
        >"${BURST_SAMPLES}" 2>"${BURST_ERR}" &
    BURST_PID=$!
    ip netns exec "${NS_B}" nc -u -l 9999 >/dev/null 2>&1 &
    NC_SERVER_PID=$!
    sleep 2
    if ip netns exec "${NS_A}" sh -c \
        "dd if=/dev/zero bs=1400 count=2000 status=none | nc -u -w 2 ${IP_B} 9999" \
        >/dev/null 2>&1; then
        BURST_STATUS="ran (2000 x 1400B UDP writes)"
    else
        BURST_STATUS="attempted, nc/dd returned non-zero (informational only)"
    fi
    printf 'ip netns exec %s sh -c "dd if=/dev/zero bs=1400 count=2000 status=none | nc -u -w 2 %s 9999"\n' \
        "${NS_A}" "${IP_B}" >>"${TRANSCRIPT}"
    wait "${BURST_PID}" || true
    BURST_PID=""
    if [[ -n "${NC_SERVER_PID}" ]] && kill -0 "${NC_SERVER_PID}" 2>/dev/null; then
        kill -TERM "${NC_SERVER_PID}" 2>/dev/null || true
        wait "${NC_SERVER_PID}" 2>/dev/null || true
    fi
    NC_SERVER_PID=""
else
    log "nc not found -- skipping the burst phase cleanly"
    : >"${BURST_SAMPLES}"
    : >"${BURST_ERR}"
fi

# --------------------------------------------------------------------------------------
# context for the verdict
# --------------------------------------------------------------------------------------
export PRIVILEGE_CONTEXT
export KERNEL_RELEASE TC_VERSION IP_VERSION PYTHON_VERSION PSAMPLE_HEADER
export LSMOD_BEFORE LSMOD_AFTER MODINFO_ACT_SAMPLE NS_A NS_B VETH_A VETH_B
export IFINDEX_A IFINDEX_B RATE TRUNC GROUP_EGRESS GROUP_INGRESS PING_COUNT
export PING_INTERVAL LISTEN_SECONDS BURST_SECONDS TOLERANCE PING_OUTPUT
export FILTERS_EGRESS FILTERS_INGRESS TC_STATS_EGRESS TC_STATS_INGRESS BURST_STATUS STAMP

"${PYTHON_BIN}" - "${CONTEXT}" <<'PYCTX'
import json, os, sys
keys = ["PRIVILEGE_CONTEXT", "KERNEL_RELEASE", "TC_VERSION", "IP_VERSION", "PYTHON_VERSION", "PSAMPLE_HEADER",
        "LSMOD_BEFORE", "LSMOD_AFTER", "MODINFO_ACT_SAMPLE", "NS_A", "NS_B",
        "VETH_A", "VETH_B", "IFINDEX_A", "IFINDEX_B", "RATE", "TRUNC",
        "GROUP_EGRESS", "GROUP_INGRESS", "PING_COUNT", "PING_INTERVAL",
        "LISTEN_SECONDS", "BURST_SECONDS", "TOLERANCE", "PING_OUTPUT",
        "FILTERS_EGRESS", "FILTERS_INGRESS", "TC_STATS_EGRESS", "TC_STATS_INGRESS",
        "BURST_STATUS", "STAMP"]
json.dump({k: os.environ.get(k, "") for k in keys}, open(sys.argv[1], "w"), indent=2)
PYCTX

# --------------------------------------------------------------------------------------
# verdict + report
# --------------------------------------------------------------------------------------
set +e
"${PYTHON_BIN}" - "${CONTEXT}" "${SAMPLES}" "${LISTENER_ERR}" "${BURST_SAMPLES}" \
                "${BURST_ERR}" "${TRANSCRIPT}" "${REPORT}" <<'PYVERDICT'
import json
import sys

ctx_path, samples_path, listener_err, burst_path, burst_err, transcript, report_path = sys.argv[1:8]
ctx = json.load(open(ctx_path))


def read_jsonl(path):
    rows = []
    try:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    except FileNotFoundError:
        pass
    return rows


def read_text(path):
    try:
        with open(path) as handle:
            return handle.read().rstrip("\n")
    except FileNotFoundError:
        return ""


samples = read_jsonl(samples_path)
burst = read_jsonl(burst_path)

rate = int(ctx["RATE"] or 4)
g_out = int(ctx["GROUP_EGRESS"] or 7)
g_in = int(ctx["GROUP_INGRESS"] or 8)
ping_count = int(ctx["PING_COUNT"] or 200)
tol = float(ctx["TOLERANCE"] or 0.30)
ifindex_a = int(ctx["IFINDEX_A"] or 0)
veth_a = ctx["VETH_A"]

expected = ping_count / rate
lo, hi = expected * (1 - tol), expected * (1 + tol)

by_group = {}
for s in samples:
    by_group.setdefault(s.get("group"), []).append(s)
n_out = len(by_group.get(g_out, []))
n_in = len(by_group.get(g_in, []))

rates_seen = sorted({s.get("rate") for s in samples if s.get("rate") is not None})
sizes = [s["origsize"] for s in samples if "origsize" in s]

checks = []


def check(name, ok, detail):
    checks.append((name, bool(ok), detail))
    return bool(ok)


check("samples arrived at all", len(samples) > 0, "%d samples in %s" % (len(samples), samples_path))
check("group %d (egress) count within +/-%d%% of %.1f" % (g_out, tol * 100, expected),
      lo <= n_out <= hi,
      "%d samples, window [%.1f, %.1f]" % (n_out, lo, hi))
check("group %d (ingress) count within +/-%d%% of %.1f" % (g_in, tol * 100, expected),
      lo <= n_in <= hi,
      "%d samples, window [%.1f, %.1f]" % (n_in, lo, hi))
check("every sample carries SAMPLE_RATE=%d" % rate,
      bool(samples) and rates_seen == [rate],
      "rates seen: %s" % (rates_seen or "none"))

# ifindex mapping. Measured 2026-09-17: the kernel writes IIFINDEX/OIFINDEX with
# nla_put_u16(), so compare against the low 16 bits of the real ifindex; and an EGRESS
# sample carries OIFINDEX only while an INGRESS sample carries IIFINDEX only.
want = ifindex_a & 0xFFFF
bad_out = [s for s in by_group.get(g_out, []) if s.get("oifindex") != want]
bad_in = [s for s in by_group.get(g_in, []) if s.get("iifindex") != want]
check("every group-%d sample's OIFINDEX == %s ifindex %d (low 16 bits %d)"
      % (g_out, veth_a, ifindex_a, want),
      bool(by_group.get(g_out)) and not bad_out,
      "%d of %d mismatched; values seen: %s"
      % (len(bad_out), n_out,
         sorted({s.get("oifindex") for s in by_group.get(g_out, [])})))
check("every group-%d sample's IIFINDEX == %s ifindex %d (low 16 bits %d)"
      % (g_in, veth_a, ifindex_a, want),
      bool(by_group.get(g_in)) and not bad_in,
      "%d of %d mismatched; values seen: %s"
      % (len(bad_in), n_in,
         sorted({s.get("iifindex") for s in by_group.get(g_in, [])})))

verdict = "PASS" if all(ok for _, ok, _ in checks) else "FAIL"

widths = sorted({s[k] for s in samples for k in ("iifindex_width", "oifindex_width") if k in s})
names = sorted({s.get(k) for s in samples for k in ("iifname", "oifname") if s.get(k)})

lines = []
add = lines.append
add("# psample / `tc action sample` feasibility spike -- %s" % verdict)
add("")
add("Run %s (UTC). Generated by `spike.sh`; raw samples in `samples.jsonl`." % ctx["STAMP"])
add("")
add("## Verdict")
add("")
add("**%s**" % verdict)
add("")
add("| check | result | detail |")
add("|---|---|---|")
for name, ok, detail in checks:
    add("| %s | %s | %s |" % (name, "PASS" if ok else "**FAIL**", detail))
add("")
add("## Numbers")
add("")
add("| quantity | value |")
add("|---|---|")
add("| total samples (phase 1) | %d |" % len(samples))
add("| group %d (egress, what %s sent) | %d |" % (g_out, veth_a, n_out))
add("| group %d (ingress, what %s received) | %d |" % (g_in, veth_a, n_in))
add("| expected per direction | %d / %d = %.2f (window [%.1f, %.1f]) |"
    % (ping_count, rate, expected, lo, hi))
add("| SAMPLE_RATE values seen | %s |" % (rates_seen or "none"))
add("| ORIGSIZE min / max / mean | %s / %s / %s |"
    % (min(sizes) if sizes else "-", max(sizes) if sizes else "-",
       "%.2f" % (sum(sizes) / len(sizes)) if sizes else "-"))
add("| ifindex attribute width (bytes) | %s |" % (widths or "none"))
add("| interface names resolved from ifindex | %s |" % (", ".join(names) or "none"))
add("| burst phase (informational) | %s, %d samples |" % (ctx["BURST_STATUS"], len(burst)))
add("")
add("Sampling is per-packet Bernoulli with p = 1/%d, so the counts are random variables, "
    "not fixed quotients. For n = %d and p = 1/%d the standard deviation is about %.1f "
    "samples; the +/-%d%% window is roughly +/-%.1f sigma."
    % (rate, ping_count, rate,
       (ping_count * (1.0 / rate) * (1 - 1.0 / rate)) ** 0.5,
       tol * 100,
       (tol * expected) / max(1e-9, (ping_count * (1.0 / rate) * (1 - 1.0 / rate)) ** 0.5)))
add("")
add("The ping also puts one ARP request on the wire in each direction, so the true "
    "packet counts are %d, not %d; the expected value above deliberately uses the round "
    "number the spike was specified with." % (ping_count + 1, ping_count))
add("")
add("## Environment")
add("")
add("| item | value |")
add("|---|---|")
add("| privilege context | %s |" % ctx["PRIVILEGE_CONTEXT"])
add("| kernel | `%s` |" % ctx["KERNEL_RELEASE"])
add("| tc | `%s` |" % ctx["TC_VERSION"])
add("| ip | `%s` |" % ctx["IP_VERSION"].replace("\n", " "))
add("| python | `%s` |" % ctx["PYTHON_VERSION"])
add("| psample uapi header | `%s` |" % ctx["PSAMPLE_HEADER"])
add("| %s ifindex (in %s) | %s |" % (ctx["VETH_A"], ctx["NS_A"], ctx["IFINDEX_A"]))
add("| %s ifindex (in %s) | %s |" % (ctx["VETH_B"], ctx["NS_B"], ctx["IFINDEX_B"]))
add("")
add("Modules before attaching the filter:")
add("")
add("```")
add(ctx["LSMOD_BEFORE"] or "(neither psample nor act_sample loaded)")
add("```")
add("")
add("Modules after attaching the filter (this is where `tc` autoloads `act_sample`):")
add("")
add("```")
add(ctx["LSMOD_AFTER"] or "(none)")
add("```")
add("")
add("```")
add(ctx["MODINFO_ACT_SAMPLE"] or "(modinfo act_sample produced nothing)")
add("```")
add("")
add("## Exact commands")
add("")
add("```")
add(read_text(transcript))
add("```")
add("")
add("## tc filter state after the run")
add("")
add("```")
add(ctx["TC_STATS_EGRESS"])
add("")
add(ctx["TC_STATS_INGRESS"])
add("```")
add("")
add("## ping")
add("")
add("```")
add(ctx["PING_OUTPUT"])
add("```")
add("")
add("## Listener stderr (phase 1)")
add("")
add("```")
add(read_text(listener_err))
add("```")
add("")
if burst:
    add("## Listener stderr (burst phase, informational)")
    add("")
    add("```")
    add(read_text(burst_err))
    add("```")
    add("")
add("## First three samples verbatim")
add("")
add("```")
for s in samples[:3]:
    add(json.dumps(s, sort_keys=True))
if not samples:
    add("(no samples)")
add("```")
add("")
add("## What this does not say")
add("")
add("Nothing here involves bmv2, Mininet, `ndt`, sFlow, or any NDTwin process. It does "
    "not measure sampling accuracy under load, CPU cost, or behaviour at line rate, and "
    "it does not show that a veth index can be mapped to a (dpid, port) pair. See "
    "`README.md`.")
add("")

open(report_path, "w").write("\n".join(lines) + "\n")

print("")
print("=" * 78)
for name, ok, detail in checks:
    print("  [%s] %s -- %s" % ("PASS" if ok else "FAIL", name, detail))
print("=" * 78)
print("%s: group %d = %d, group %d = %d, expected %.1f each (window [%.1f, %.1f]); "
      "rates seen %s; ORIGSIZE %s..%s"
      % (verdict, g_out, n_out, g_in, n_in, expected, lo, hi,
         rates_seen or "none",
         min(sizes) if sizes else "-", max(sizes) if sizes else "-"))
print("report: %s" % report_path)
print("=" * 78)
sys.exit(0 if verdict == "PASS" else 2)
PYVERDICT
VERDICT_RC=$?
set -e

log "report written: ${REPORT}"
log "raw samples:    ${SAMPLES}"
exit "${VERDICT_RC}"
