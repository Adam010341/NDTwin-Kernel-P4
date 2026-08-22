#!/usr/bin/env bash
# settle_gate_acceptance.sh -- P0-1 acceptance for the host-discovery gate.
#
# [Co-developed with claude code -- Adam]
#
# What is under test: intelligent_router.py no longer sleeps a fixed NDTWIN_RYU_SETTLE_S before
# the all-pairs walk. It waits for the event the sleep was accidentally protecting -- every host
# having an IPv4 in Ryu's host table -- with SETTLE_S demoted to a deadline (default 90).
#
# The regression it fixes, measured 2026-08-21 with one variable changed:
#     settle=60 -> Ryu knows 128/128 host IPv4s -> kernel graph 288 up /   0 down
#     settle=10 -> Ryu knows   0/128            -> kernel graph  32 up / 256 down
# and pinned to a mechanism 2026-08-22 (e5e4980): IPv4 is learned only from packet-in, the
# all-pairs rules end every punt, static ARP closes the ARP path, so the learning window IS the
# settle window and nothing can teach Ryu a host after it shuts.
#
# Two things this run must produce, and they are not the same claim:
#   (a) correctness at the DEFAULT configuration -- 128/128 learned, kernel graph 288/0. The
#       previous healthy capture needed a hand-set NDTWIN_RYU_SETTLE_S=60; that workaround is
#       what this is meant to retire, so the script asserts the variable is unset rather than
#       trusting that it is.
#   (b) boot cost, n=3, so the 手冊 and the 8/27 deck can quote a defensible OVS number again.
#
# Assert the injection landed (injections-must-assert-their-own-success): a run that silently
# tested the OLD code would produce a perfectly plausible-looking 0/128 and read as "the fix
# does not work". So every boot greps ryu.log for the gate's own log line, which only the new
# code can emit, and says NO GATE LINE loudly if it is absent.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_settle-gate-acceptance"
OUT="$DIR/acceptance.txt"
RAW="$DIR/raw"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RUNS="${RUNS:-3}"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "# P0-1 acceptance: host-discovery gate at DEFAULT settings"
say "# date:   $(date -Is)"
say "# commit: $(git -C "$REPO" rev-parse --short HEAD) (+ uncommitted gate patch if not yet committed)"
say ""

# --- the environment assertion, before anything expensive runs ----------------------------
if [[ -n "${NDTWIN_RYU_SETTLE_S:-}" ]]; then
    say "ABORT: NDTWIN_RYU_SETTLE_S is set to '${NDTWIN_RYU_SETTLE_S}' in this environment."
    say "       This run is supposed to prove the DEFAULT works. Unset it and re-run."
    exit 2
fi
say "env check: NDTWIN_RYU_SETTLE_S unset -> the gate runs at its compiled-in default"
say "code check: $(grep -c '_await_host_discovery' "$REPO/intelligent_router.py") references to _await_host_discovery in intelligent_router.py (expect 3: def, call, comment)"
say "            default deadline = $(grep -oP 'NDTWIN_RYU_SETTLE_S", "\K[0-9]+' "$REPO/intelligent_router.py")"
say ""

# --- one boot: time it, then read the three numbers that matter ---------------------------
one_boot() {
    local label="$1" verb="$2" expect_hosts="$3"
    say "## $label"

    ndt down > /dev/null 2>&1
    sleep 3

    local t0 t1 elapsed
    t0=$(date +%s)
    if ! timeout 900 ndt up $verb > "$RAW/${label}_up.out" 2>&1; then
        say "  UP FAILED -- see raw/${label}_up.out"
        tail -8 "$RAW/${label}_up.out" | sed 's/^/    /' | tee -a "$OUT"
        return 1
    fi
    t1=$(date +%s)
    elapsed=$(( t1 - t0 ))
    say "  boot wall time: ${elapsed}s"

    # The gate's own line. Only the new code emits it; its absence means this boot tested
    # something other than what the run claims to test.
    local gate
    gate="$(grep -E 'host discovery (complete|incomplete)' "$REPO/.test_run/logs/ryu.log" | tail -1)"
    if [[ -z "$gate" ]]; then
        say "  !! NO GATE LINE in ryu.log -- this boot did NOT run the gated code."
        say "     Treat every number below as measuring the old behaviour."
    else
        say "  gate: ${gate#*] }"
    fi

    # Ryu's view: how many hosts have an IPv4 at all.
    curl -sf --max-time 10 "$RYU/v1.0/topology/hosts" -o "$RAW/${label}_hosts.json"
    python3 - "$RAW/${label}_hosts.json" "$expect_hosts" <<'PY' | tee -a "$OUT"
import json, sys
hs = json.load(open(sys.argv[1])); want = int(sys.argv[2])
withip = [h for h in hs if h.get("ipv4")]
withv6 = [h for h in hs if h.get("ipv6")]
verdict = "PASS" if len(withip) >= want else "FAIL"
print(f"  ryu hosts: {len(withip)}/{len(hs)} have ipv4 (want {want}) -- {verdict}"
      f"   [ipv6-only: {len(withv6) - len(withip)}]")
PY

    # The kernel's view: the graph the twin actually serves.
    curl -sf --max-time 10 "$KERNEL/ndt/get_graph_data" -o "$RAW/${label}_graph.json"
    python3 - "$RAW/${label}_graph.json" <<'PY' | tee -a "$OUT"
import json, sys
try:
    g = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  kernel graph: UNREADABLE ({e})"); raise SystemExit
e = g.get("edges", [])
down = [x for x in e if not x.get("is_up", True)]
print(f"  kernel graph: {len(e)} edges, {len(down)} down")
if not e:
    print("  WARNING: zero edges -- empty fabric or wrong parser key; do not read as clean")
PY
    say ""
    return 0
}

# --- 128 hosts, n=3 -----------------------------------------------------------------------
ndt claim 90 "P0-1 settle-gate acceptance" > /dev/null 2>&1 || true
for i in $(seq 1 "$RUNS"); do
    one_boot "ovs128_run$i" "ovs" 128
done

# --- 4 hosts, once. The gate can only regress a small fabric if its discovery burst never
#     happens; ovs_4host_topo.py has one, so this should exit early like the 128 case. It is
#     here because a deadline that is never reached on 128 could still be reached on 4.
one_boot "ovs4" "ovs4" 4

ndt down > /dev/null 2>&1
ndt release > /dev/null 2>&1 || true
say "done -> $OUT"
