#!/usr/bin/env bash
# five_tuple_live.sh -- P2-5 step 5: does one 5-tuple rule actually override LPM on a real switch?
#
# [Co-developed with claude code -- Adam]
#
# Steps 1-4 built the translation layer, the P4Runtime ternary writes, the routing decision and
# the counter readback, all unit-tested with mutation gates. None of that proves the pipeline
# behaves the way the code assumes: flow_5tuple is applied before ipv4_lpm and falls through on
# NoAction (ndtwin_switch.p4:307-325), which is a claim about a compiled program running on a
# real bmv2, not about Python.
#
# What this run has to show, in order:
#
#   1. A baseline: with only the LPM route present, traffic to a destination leaves by port X.
#   2. Install ONE 5-tuple rule for a single flow (dst + proto + L4 port) pointing at port Y.
#   3. That flow now leaves by Y -- the ternary table won -- while OTHER traffic to the SAME
#      destination still leaves by X. Both halves matter: a rule that changed everything would
#      be indistinguishable from having widened the LPM entry, which is the exact defect the
#      whole 5-tuple effort exists to fix.
#   4. The flow_5tuple entry's own counter moved, and the read-back priority is the one written
#      -- the original bug report was "the table read back priority 0 rather than 100".
#   5. Delete it and the flow returns to X, proving the override is removable and that delete
#      addresses the right entry (priority is part of a ternary entry's identity).
#
# Evidence is read from the switch, not inferred from the proxy's return codes: the proxy
# answering 200 while installing a narrower or wider rule than asked is the failure this
# feature was built to end, so a 200 is not accepted as proof of anything here.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-24_five-tuple-live"
OUT="$DIR/five_tuple_live.txt"
PROXY=http://localhost:8081

mkdir -p "$DIR/raw"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

trap 'ndt down >/dev/null 2>&1 || ndt down --force >/dev/null 2>&1' EXIT

say "# 5-tuple live proof: does the ternary table override LPM on a real bmv2?"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say ""

ndt down > /dev/null 2>&1
sleep 3
say "## boot p4, 4 hosts"
t0=$(date +%s)
if ! timeout 900 ndt up p4 4 > "$DIR/raw/up.out" 2>&1; then
    say "UP FAILED -- see raw/up.out"; tail -8 "$DIR/raw/up.out" | sed 's/^/  /' | tee -a "$OUT"
    exit 1
fi
say "  boot: $(( $(date +%s) - t0 ))s"

# Name the binary that is actually running, not the one configured.
say "  bmv2 in use: $(for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$p" 2>/dev/null; echo; done \
      | grep -o '/[^ ]*simple_switch_grpc' | sort -u | head -1)"
say ""

# ---- helper: dump s1's tables in the Ryu shape the proxy serves --------------------------
dump() {
    curl -sf --max-time 10 "$PROXY/stats/flow/1" -o "$DIR/raw/$1.json" 2>/dev/null
    python3 - "$DIR/raw/$1.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"    (unreadable: {e})"); raise SystemExit
flows = d.get("1", [])
print(f"    {len(flows)} flow(s) reported")
for f in flows:
    m = f.get("match", {})
    if not m:
        continue
    acts = ",".join(str(a) for a in f.get("actions", []))
    print(f"      prio={f.get('priority')} match={m} -> {acts} "
          f"pkts={f.get('packet_count')} bytes={f.get('byte_count')}")
PY
}

say "## 1. baseline: s1's tables before any 5-tuple rule"
dump baseline | tee -a "$OUT"
say ""

# ---- the host pair and the port to steal --------------------------------------------------
say "## 2. the flow under test"
H1=$(pgrep -f 'mininet:h1$' | head -1)
say "  h1 pid: ${H1:-NOT FOUND}"
if [[ -z "$H1" ]]; then
    say "  ABORT: no h1 to send from."
    exit 1
fi
# Read the destination AND its port off the switch's own table, not out of the topology model.
# The model's `ip` field is the management network (192.168.123.x) while the data plane runs
# 10.0.0.x, so deriving the target from the file aimed the rule at an address no packet carries
# and left the port as "?". This script's header says to read evidence from the switch; this is
# the line that was not doing it. [Co-developed with claude code -- Adam]
read -r H2IP LPM_PORT <<< "$(python3 - "$DIR/raw/baseline.json" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))
out = " "
for f in d.get("1", []):
    m = f.get("match", {})
    dst = m.get("nw_dst") or m.get("ipv4_dst")
    if not dst or not dst.endswith(".2"):
        continue
    for a in f.get("actions", []):
        digits = "".join(c for c in str(a) if c.isdigit())
        if "OUTPUT" in str(a).upper() and digits:
            out = f"{dst} {digits}"
            break
    break
print(out)
PYX
)"
say "  LPM currently sends $H2IP out of port: $LPM_PORT"
if [[ -z "${LPM_PORT// }" || "$LPM_PORT" == "?" ]]; then
    say "  ABORT: could not read the LPM port off the switch; nothing to override."
    exit 1
fi
say ""

say "## 3. install ONE 5-tuple rule: $H2IP + tcp/5001 -> a different port, priority 100"
ALT_PORT=$(( LPM_PORT == 1 ? 2 : 1 ))
say "  (steering only that flow to port $ALT_PORT; every other packet to $H2IP must keep port $LPM_PORT)"
curl -sf --max-time 10 -X POST "$PROXY/stats/flowentry/add" \
     -H 'Content-Type: application/json' \
     -d "{\"dpid\":1,\"priority\":100,
          \"match\":{\"dl_type\":2048,\"nw_dst\":\"$H2IP\",\"nw_proto\":6,\"tp_dst\":5001},
          \"actions\":[{\"type\":\"OUTPUT\",\"port\":$ALT_PORT}]}" \
     -o "$DIR/raw/install.json" -w '  HTTP %{http_code}\n' | tee -a "$OUT"
cat "$DIR/raw/install.json" 2>/dev/null | sed 's/^/    /' | tee -a "$OUT"
say ""
sleep 2

say "## 4. read the switch back -- a 200 is not evidence"
dump after_install | tee -a "$OUT"
say ""
python3 - "$DIR/raw/after_install.json" "$H2IP" "$ALT_PORT" <<'PY' | tee -a "$OUT"
import json, sys
d = json.load(open(sys.argv[1])); want, alt = sys.argv[2], sys.argv[3]
# A 5-tuple rule is one keyed on more than destination+ethertype. The first version used
# len(match) > 1, which counts every LPM entry too (nw_dst + dl_type = 2 fields) and printed
# "priority read back: 0 (installed with OpenFlow 100)" against rules nobody installed with
# 100 -- an analysis line that manufactured its own contradiction.
FIVE = {"nw_proto", "ip_proto", "nw_src", "ipv4_src", "tp_src", "tp_dst",
        "tcp_src", "tcp_dst", "udp_src", "udp_dst", "in_port"}
five = [f for f in d.get("1", []) if FIVE & set(f.get("match", {}))]
print(f"  rules with more than one match field: {len(five)}")
for f in five:
    print(f"    priority read back: {f.get('priority')}  (installed with OpenFlow 100)")
    print(f"    match: {f.get('match')}")
    print(f"    actions: {f.get('actions')}")
if not five:
    print("  NO multi-field rule on the switch -- the write did not land, whatever HTTP said.")
PY
say ""

say "## 5. does traffic follow it? (counters before/after a matching flow)"
# Independent proof that packets were actually emitted, so a zero counter cannot be confused
# with a probe that never sent anything. nc against a closed port still emits SYNs, and those
# match the rule -- what matters is that they leave h1. [Co-developed with claude code -- Adam]
H1IF=$(sudo -n mnexec -a "$H1" sh -c "ls /sys/class/net | grep -v lo | head -1" 2>/dev/null)
TX_BEFORE=$(sudo -n mnexec -a "$H1" sh -c "cat /sys/class/net/$H1IF/statistics/tx_packets" 2>/dev/null || echo 0)
say "  sending tcp/5001 from h1 -> $H2IP  (h1 iface $H1IF, tx before $TX_BEFORE)"
for _ in 1 2 3; do
    sudo -n mnexec -a "$H1" timeout 4 bash -c "echo probe | nc -w 2 $H2IP 5001" \
         >> "$DIR/raw/probe.out" 2>&1
done
TX_AFTER=$(sudo -n mnexec -a "$H1" sh -c "cat /sys/class/net/$H1IF/statistics/tx_packets" 2>/dev/null || echo 0)
say "  h1 tx_packets: $TX_BEFORE -> $TX_AFTER  (delta $(( TX_AFTER - TX_BEFORE )))"
if (( TX_AFTER - TX_BEFORE == 0 )); then
    say "  WARNING: h1 sent nothing, so a zero counter below says nothing about the rule."
fi
sleep 3
dump after_traffic | tee -a "$OUT"
say ""

say "## 6. delete it and confirm the override is removable"
curl -sf --max-time 10 -X POST "$PROXY/stats/flowentry/delete" \
     -H 'Content-Type: application/json' \
     -d "{\"dpid\":1,\"priority\":100,
          \"match\":{\"dl_type\":2048,\"nw_dst\":\"$H2IP\",\"nw_proto\":6,\"tp_dst\":5001}}" \
     -o "$DIR/raw/delete.json" -w '  HTTP %{http_code}\n' | tee -a "$OUT"
sleep 2
dump after_delete | tee -a "$OUT"
say ""
say "## verdict inputs"
say "  Compare sections 1, 4 and 6: the multi-field rule must be absent in 1, present in 4 with"
say "  priority 101 (OpenFlow 100 shifted), and absent again in 6. Section 5's counters say"
say "  whether traffic actually matched it."
say ""
say "done -> $OUT"
