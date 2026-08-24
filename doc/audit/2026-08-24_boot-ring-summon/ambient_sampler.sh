#!/usr/bin/env bash
# Sample ambient CPU load every 5s for the duration of the summoning run.
# The quiet arm is only quiet if nothing ELSE is loading the machine. Another session shares
# this worktree (three writers seen today), and the coordination message reached the auditer
# only as a queued item -- so "they agreed to stay off" is not evidence they were off.
# This records what was actually true, per boot, after the fact. [Co-developed with claude code -- Adam]
out="$(dirname "$0")/raw/ambient_load.tsv"
printf "epoch\tiso\tload1\tmy_workers\ttop_nonmine_cpu\ttop_nonmine_cmd\n" > "$out"
while :; do
    l1=$(awk '{print $1}' /proc/loadavg)
    mine=$(ps -eo args | grep -c "[n]dtwin_summon_busyloop")
    read -r c n <<< "$(ps -eo pcpu,comm --sort=-pcpu --no-headers \
        | grep -vE "bash|ps$|awk|pgrep" | head -1)"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$(date +%s)" "$(date +%H:%M:%S)" "$l1" "${mine:-0}" "${c:-0}" "${n:-none}" >> "$out"
    sleep 5
done
