#!/usr/bin/env bash
# Ground truth veth counters, in a form that survives a saturated machine.
# Ticket S prerequisite. [Co-developed with claude code -- Adam]
#
# Usage: poll_veth2.sh <out.tsv> <seconds> [interval]
# Output is byte-identical in shape to poll_veth.sh, so analyze.py consumes it unchanged.
#
# WHY A NEW FILE RATHER THAN AN EDIT.  poll_veth.sh is running right now -- 8/27 mainDev's ticket
# P holds it (pid 737004, cell P_B14, a 380 s window).  Editing a script mid-flight is how you
# corrupt someone else's round, and their data must stay comparable to itself.  The old poller
# also stays valid for the rounds that already used it; this is an additional instrument, not a
# replacement.
#
# WHAT WAS ACTUALLY WRONG.  Not the reads -- the PROCESS SPAWNS.  The original opens
# /sys/class/net/<iface>/statistics/{rx,tx}_bytes with a `cat` each, so a 160-interface fabric
# costs ~320 fork+execs per sweep.  On a box with all fourteen cores pegged those spawns queue
# behind the load, and ticket N measured the result directly: sweep gaps of 2.3, 2.8, 24.7, 8.4
# seconds, the 24.7 landing exactly when the flows started.  analyze.py then refused to produce a
# number from half a dataset, correctly.
#
# THE FIX.  /proc/net/dev carries every interface in ONE file, so a sweep is one read and one awk
# -- two processes instead of 321.  Field 1 is "iface:", field 2 is rx_bytes, field 10 is
# tx_bytes; the leading header lines are skipped by requiring the colon.
#
# WHY NOT nice -n -20.  Negative nice needs CAP_SYS_NICE, and this machine's sudoers grants only
# a fixed list that does not include renice or chrt.  Raising priority is therefore not available
# without asking Adam for a new sudoers entry, and the spawn fix alone is measured below to be
# sufficient.  Recorded so nobody re-derives it.
set -euo pipefail
OUT="${1:?out.tsv}"; DUR="${2:?seconds}"; IVL="${3:-2}"

printf 'ts\tiface\trx_bytes\ttx_bytes\n' > "$OUT"
end=$(( $(date +%s) + DUR ))
n=0
while [ "$(date +%s)" -lt "$end" ]; do
    # One read, one awk. `date` is a builtin-free spawn too, so the timestamp comes from awk's
    # own clock via systime() -- keeping the per-sweep process count at exactly one.
    awk -v OFS='\t' '
        BEGIN { ts = systime() }
        /:/ {
            split($1, f, ":")
            name = f[1] != "" ? f[1] : $1
            gsub(/:/, "", name)
            if (name ~ /^s[0-9]+-eth[0-9]+$/) {
                # With "iface:" glued to the first number, awk sees one field fewer.
                if (f[2] != "") print ts, name, f[2], $9
                else            print ts, name, $2, $10
            }
        }' /proc/net/dev >> "$OUT"
    n=$((n+1))
    sleep "$IVL"
done
# A poller that produced one sample and one that produced 150 look identical from the outside,
# and "the file exists" has been read as "the run happened" in this repo before.
echo "veth2: $n sweeps, $(( $(wc -l < "$OUT") - 1 )) rows, $(awk -F'\t' 'NR>1{print $2}' "$OUT" | sort -u | wc -l) interfaces" >&2
