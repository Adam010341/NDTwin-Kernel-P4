#!/usr/bin/env bash
# Ground truth: kernel NIC byte counters for every sN-ethM veth in the root namespace.
#
# These sit UNDERNEATH the twin, the proxy and bmv2, so they cannot be wrong in the same
# direction as the thing under test. Read straight out of /sys, one line of TSV per sample.
#
# In a script file rather than inline, so its argv is a path -- a `pgrep -f` from any other
# session cannot match the pattern this contains. That has bitten three times.
#
# Usage: poll_veth.sh <out.tsv> <seconds> [interval]
# [Co-developed with claude code -- Adam]
set -euo pipefail
OUT="${1:?out.tsv}"; DUR="${2:?seconds}"; IVL="${3:-2}"

printf 'ts\tiface\trx_bytes\ttx_bytes\n' > "$OUT"
end=$(( $(date +%s) + DUR ))
n=0
while [ "$(date +%s)" -lt "$end" ]; do
    ts=$(date +%s.%N)
    for d in /sys/class/net/s*-eth*; do
        [ -e "$d/statistics/rx_bytes" ] || continue
        i=${d##*/}
        printf '%s\t%s\t%s\t%s\n' "$ts" "$i" \
            "$(cat "$d/statistics/rx_bytes")" "$(cat "$d/statistics/tx_bytes")"
    done >> "$OUT"
    n=$((n+1))
    sleep "$IVL"
done
# Say how much was collected. A poller that produced one sample and a poller that produced 150
# look identical from the outside, and "the file exists" has been read as "the run happened".
echo "veth: $n samples, $(( $(wc -l < "$OUT") - 1 )) rows, $(awk -F'\t' 'NR>1{print $2}' "$OUT" | sort -u | wc -l) interfaces" >&2
