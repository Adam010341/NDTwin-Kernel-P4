#!/usr/bin/env bash
# Load context alongside the six-arm mirrored block, sampled by the auditor.
#
# WHY THIS EXISTS, and why it is separate from the block:
#   The mirrored layout cancels LINEAR drift exactly. It does not cancel a STEP. Today the
#   machine carries two qemu VMs (one running a 4-5 h p4c/bmv2 compile) plus the lab, with
#   ~4 G available and 8 G of swap already in use -- a neighbour whose load starts and stops
#   is precisely a step source. Without a load trace, a step and a real effect produce the
#   same reading and cannot be told apart afterwards.
#
#   This samples ONLY /proc. It does not touch the kernel, the fabric, any arm parameter, or
#   any file the block writes. It cannot change the experiment; it can only make a confound
#   detectable after the fact. Started after the block was already running, so it is a
#   post-hoc rescue of information that is otherwise gone at ~10:10 -- not part of the design.
#
# Correlate by TIMESTAMP against block.log's per-arm start/end lines.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

# One file per run. The first version wrote a fixed filename and opened it with `>`, so the
# second invocation truncated the first run's data -- which is what happened: this script was
# started at 09:36 for block 1, re-run at ~10:10 for block 2, and 09:36-10:10 is simply gone.
# A tool whose whole purpose is to preserve information that cannot be recovered afterwards
# destroyed exactly that. `>` is never right for a measurement file; the filename has to be
# unique per run, and the header appended only when the file is new.
RUN_ID="${1:-$(date +%Y%m%dT%H%M%S)}"
OUT="$(dirname "$0")/raw/load_context_auditor.${RUN_ID}.tsv"
INTERVAL_S=10
MAX_MIN=50                      # hard bound: cannot outlive the block by much

mkdir -p "$(dirname "$OUT")"

if [[ -e "$OUT" ]]; then
    echo "refusing to touch existing $OUT -- pass a different run id" >&2
    exit 1
fi

# Header names the units, so a reader does not have to guess which column is which.
printf 'iso_time\tload1\tmem_avail_mb\tswap_used_mb\tswap_in_kbps\tswap_out_kbps\tqemu_n\tqemu_rss_mb\n' >> "$OUT"

deadline=$(( $(date +%s) + MAX_MIN * 60 ))
prev_si=0; prev_so=0; first=1

while [[ $(date +%s) -lt $deadline ]]; do
    ts=$(date --iso-8601=seconds)
    load1=$(awk '{print $1}' /proc/loadavg)

    # MemAvailable is the honest one: "free" excludes reclaimable cache and reads alarmingly low.
    mem_avail_mb=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
    swap_total_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    swap_free_kb=$(awk '/^SwapFree:/  {print $2}' /proc/meminfo)
    swap_used_mb=$(( (swap_total_kb - swap_free_kb) / 1024 ))

    # pswpin/pswpout are cumulative pages; the rate is what indicates thrashing, not the total.
    si=$(awk '/^pswpin /  {print $2}' /proc/vmstat)
    so=$(awk '/^pswpout / {print $2}' /proc/vmstat)
    if [[ $first -eq 1 ]]; then
        si_rate="NA"; so_rate="NA"; first=0
    else
        si_rate=$(( (si - prev_si) * 4 / INTERVAL_S ))     # pages -> KB/s at 4 KB pages
        so_rate=$(( (so - prev_so) * 4 / INTERVAL_S ))
    fi
    prev_si=$si; prev_so=$so

    # The neighbour VMs are the named step source, so count them and total their RSS.
    # -f without -x: -x would demand the whole command line match and find nothing. That
    # exact flag pair reported a live kernel as dead this morning.
    qemu_n=$(pgrep -cf 'qemu-system' || true)
    qemu_rss_mb=$(ps -o rss= -C qemu-system-x86_64 2>/dev/null | awk '{s+=$1} END {printf "%d", s/1024}')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$load1" "$mem_avail_mb" "$swap_used_mb" "$si_rate" "$so_rate" \
        "${qemu_n:-0}" "${qemu_rss_mb:-0}" >> "$OUT"

    sleep "$INTERVAL_S"
done
