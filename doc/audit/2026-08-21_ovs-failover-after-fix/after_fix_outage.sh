#!/usr/bin/env bash
# after_fix_outage.sh [reps] -- the OVS failover with the fix ON, measured the same way the
# "before" was.
#
# [Co-developed with claude code -- Adam]
#
# The before/after comparison needs an "after" measured with the same instrument as the
# before: ping-gap outage via measure_failover.sh, the exact protocol behind the n=10
# 51.75 s (2026-08-19) and the 4-host 15.70 s. The detection-only numbers (44.86 -> 11.51 s,
# DETECTION.md) are terms, not the user-visible outage; this measures the outage.
#
# Fix under evaluation: NDTWIN_RYU_LLDP_GUARD=0.01 only. The backoff stays off -- it is
# default-off, its detection gain is unmeasured, and an "after" with two knobs cannot say
# which one did it. The walk's O(1) token (4810e8f) is committed code, present in both
# "after" cells and absent from every "before" -- stated in the record because the epochs
# differ there and pretending otherwise is how ledgers stop balancing.
#
# Predictions, written before running (from measured terms):
#   128 hosts: detect 11.51 + debounce 3 + walk 0.25 => outage ~15 s   (before: 51.75)
#   4 hosts:   sweep is 36 ports x 0.01 s, so detection floors at LINK_TIMEOUT ~10 s + phase
#              => outage ~13-14 s (before: 15.70) -- the fix helps little at 4 hosts because
#              the guard term was already small; THAT asymmetry is the whole point of the
#              comparison figure.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0821}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-21_ovs-failover-after-fix"
OUT="$DIR/after_fix_outage.txt"
MEASURE="$REPO/doc/audit/2026-08-17_p4-vs-ovs-matched-topology/measure_failover.sh"
LOG="$REPO/.test_run/logs/ryu.log"
REPS="${1:-3}"
mkdir -p "$DIR/raw"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

outage_of() {
    python3 - "$1" <<'PY'
import re, sys
ts = [float(m.group(1)) for line in open(sys.argv[1], errors="replace")
      if (m := re.match(r"\[([\d.]+)\].*bytes from", line))]
print(f"{max((b - a for a, b in zip(ts, ts[1:])), default=0.0):.2f}" if len(ts) > 1 else "n/a")
PY
}

: > "$OUT"
say "# OVS failover outage with NDTWIN_RYU_LLDP_GUARD=0.01, by fabric size"
say "# date:   $(date -Is)"
say "# commit: $(cd "$REPO" && git rev-parse --short HEAD)"
say "# protocol: measure_failover.sh (same instrument as the 51.75 s / 15.70 s 'before' cells)"
say ""

for size in 128 4; do
    if [[ "$size" == 128 ]]; then verb="ovs"; dst=10.0.0.33; else verb="ovs4"; dst=10.0.0.4; fi
    say "## ${size} hosts (ndt up $verb, guard=0.01)"

    ndt down > /tmp/after_down.out 2>&1 || { say "   DOWN FAILED; aborting"; exit 1; }
    sleep 2
    if ! env NDTWIN_RYU_LLDP_GUARD=0.01 timeout 600 ndt up "$verb" > "/tmp/after_up_$size.out" 2>&1; then
        say "   UP FAILED (/tmp/after_up_$size.out)"
        tail -4 "/tmp/after_up_$size.out" | sed 's/^/     /' | tee -a "$OUT"
        continue
    fi
    if ! grep -q "LLDP_SEND_GUARD overridden to 0.01" "$LOG"; then
        say "   KNOB NOT ANNOUNCED in ryu log -- cell not configured; skipping"
        continue
    fi
    say "   knob: $(grep -m1 'LLDP_SEND_GUARD overridden' "$LOG")"
    ifaces=$(ls /sys/class/net | grep -c '^s[0-9]*-eth')
    say "   fabric: $ifaces switch ports (veth count)"

    for rep in $(seq 1 "$REPS"); do
        ping_log="$DIR/raw/after_ovs${size}_run${rep}.log"
        if ! bash "$MEASURE" ovs "$dst" 60 "$ping_log" > "/tmp/after_meas_${size}_${rep}.out" 2>&1; then
            say "   rep $rep INVALID:"
            sed 's/^/     /' "/tmp/after_meas_${size}_${rep}.out" | tee -a "$OUT"
            sleep 20; continue
        fi
        say "   rep $rep  outage=$(outage_of "$ping_log")s  ($(grep -m1 'iface=' "/tmp/after_meas_${size}_${rep}.out"))"
        # Let routes re-settle on the healed link before the next injection.
        sleep $(( size == 4 ? 20 : 45 ))
    done
    say ""
done

ndt down >/dev/null 2>&1
say "done -> $OUT"
