#!/usr/bin/env bash
# gate_discriminator.sh -- why did the gate read 0/128 for 90s on a fabric that ended 128/128?
#
# [Co-developed with claude code -- Adam]
#
# First live run of the host-discovery gate (2026-08-22, ovs128_run1):
#     gate:  "host discovery incomplete after 90s: 0/128 hosts have an IPv4"
#     REST:  128/128 have ipv4, kernel graph 288 edges / 0 down
# The end state is the one the fix is for. The gate did not produce it -- it ran its deadline
# out, which makes it a 90-second fixed sleep wearing a gate's name.
#
# Two stories fit that observation, and they need opposite fixes:
#
#   H1 THE GATE'S READ IS BROKEN. `_hosts_with_ipv4` calls `get_all_host(self)`, while every
#      other topology-API call in this file passes `self.topology_api_app`. If that returns an
#      empty list, the gate is blind and 0 is not a measurement of anything.
#      -> fix the call.
#
#   H2 THE GATE'S READ IS HONEST. `load_static_topology` fires when the 10th switch connects,
#      which is long before Mininet has finished creating 128 hosts and its 16256 static ARP
#      entries. Nothing has sent a packet yet, so 0 is correct, and the burst simply lands
#      after the 90s deadline -- meaning the deadline is too short, not the read wrong.
#      -> raise the deadline (and explain why the fabric still ended up healthy).
#
# The discriminator is a second observer. Poll Ryu's OWN REST host table from outside, every 2s,
# through the whole boot, and lay it beside the gate's internal per-poll log line:
#     REST > 0 while the gate says 0   -> H1
#     REST = 0 while the gate says 0   -> H2   (and the REST series dates the burst)
# Same table, two readers: whichever disagrees with the other is the broken one.
#
# Assert the instrumented code is what ran: without the 10s progress lines in ryu.log this run
# produces a REST series with nothing to compare it against, which would look like a result.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_settle-gate-acceptance"
OUT="$DIR/discriminator.txt"
SERIES="$DIR/raw/rest_host_series.txt"
RYU=http://localhost:8080

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"; : > "$SERIES"

if [[ -n "${NDTWIN_RYU_SETTLE_S:-}" ]]; then
    say "ABORT: NDTWIN_RYU_SETTLE_S='${NDTWIN_RYU_SETTLE_S}' -- this must run at the default."
    exit 2
fi
if ! grep -q 'host discovery: %d/%d after %ss' "$REPO/intelligent_router.py"; then
    say "ABORT: the 10s progress log is not in intelligent_router.py."
    say "       Without it the gate's internal series does not exist and there is nothing to"
    say "       compare the REST series against."
    exit 2
fi

say "# gate discriminator: REST host table vs the gate's own reading, same boot"
say "# date:   $(date -Is)"
say "# commit: $(git -C "$REPO" rev-parse --short HEAD) + uncommitted gate work"
say ""

ndt down > /dev/null 2>&1
sleep 3

# The external observer. Starts before the boot so t=0 is the boot, not the first host.
(
    t0=$(date +%s)
    while true; do
        n=$(curl -sf --max-time 3 "$RYU/v1.0/topology/hosts" 2>/dev/null | python3 -c "
import json,sys
try: hs=json.load(sys.stdin)
except Exception: print('-,-'); raise SystemExit
print(f\"{sum(1 for h in hs if h.get('ipv4'))},{len(hs)}\")" 2>/dev/null || echo "x,x")
        printf '%s %s\n' "$(( $(date +%s) - t0 ))" "$n" >> "$SERIES"
        sleep 2
    done
) &
POLLER=$!
trap 'kill $POLLER 2>/dev/null' EXIT

t0=$(date +%s)
timeout 900 ndt up ovs > "$DIR/raw/discriminator_up.out" 2>&1
rc=$?
say "boot rc=$rc, wall $(( $(date +%s) - t0 ))s"

sleep 5
kill $POLLER 2>/dev/null
trap - EXIT

say ""
say "## the gate's own series (from ryu.log, one line per 10s of waiting)"
grep -E "host discovery" "$REPO/.test_run/logs/ryu.log" | sed 's/^/  /' | tee -a "$OUT"

say ""
say "## the REST series (external observer, every 2s: 'boot_elapsed with_ipv4,total')"
say "   printed only where it changes, plus the first and last sample"
python3 - "$SERIES" <<'PY' 2>&1 | tee -a "$OUT"
import sys
# Rows are "<elapsed> <with_ipv4>,<total>", but a curl that fails mid-boot writes a row with a
# missing or malformed field. The first version of this unpacked straight into (t, v) and died
# on the first such row -- with stderr going nowhere, so the report printed ONE line and looked
# like a finished series. A parser that can end early must say so on stdout.
# [Co-developed with claude code -- Adam]
rows, bad = [], 0
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) == 2:
        rows.append(parts)
    elif line.strip():
        bad += 1
prev = None
for i, (t, v) in enumerate(rows):
    if v != prev or i in (0, len(rows) - 1):
        print(f"  t+{t:>4}s  {v}")
        prev = v
print(f"  ({len(rows)} well-formed samples, {bad} malformed and skipped)")
PY

say ""
say "## verdict input"
first_nonzero=$(awk -F'[ ,]' '$2 ~ /^[0-9]+$/ && $2 > 0 {print $1; exit}' "$SERIES")
say "  first REST sample with any host carrying an ipv4: t+${first_nonzero:-never}s"
say "  (compare against the gate's lines above: if the gate still reads 0 at that time, the"
say "   gate's read is broken -- H1. If both are 0 together, the burst is late -- H2.)"

ndt down > /dev/null 2>&1
say ""
say "done -> $OUT"
