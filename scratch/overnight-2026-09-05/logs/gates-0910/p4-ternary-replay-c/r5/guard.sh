#!/usr/bin/env bash
# guard.sh <log> : before a mutate_*/probe/trial run. Appends to <log> the matching-process list, this shell's SigBlk (read with
# a plain command, as /proc/$$/status, the way round 4's wait.log did) and a child's own SigBlk (/proc/self/status of a grep, which
# is the mask a gate inherits); exits 1 if any mutate_/probe.py/simple_switch process is running or either mask & 0x4003 is not 0.
# [Co-developed with claude code -- Adam]
log="$1"
ps -eo pid,cmd | grep -E 'mutate_|probe\.py|simple_switch' | grep -v grep | grep -v "guard.sh" > "$log.procs.tmp"
{ echo "$(date +%T) guard: $(grep -c . "$log.procs.tmp") matching mutate_/probe.py/simple_switch process(es)"; cat "$log.procs.tmp"; } >> "$log"
grep SigBlk /proc/$$/status | sed 's/^/guard: shell $$ /' >> "$log"
grep SigBlk /proc/self/status | sed 's/^/guard: child of the shell, /' >> "$log"
# Not through $(...): a shell waiting inside a command substitution shows a different (its own, SIGINT) wait mask.
grep SigBlk /proc/$$/status > "$log.sb.tmp"; shell_blk=$(awk '{print $2}' "$log.sb.tmp")
grep SigBlk /proc/self/status > "$log.sb.tmp"; child_blk=$(awk '{print $2}' "$log.sb.tmp"); rm -f "$log.sb.tmp"
n=$(grep -c . "$log.procs.tmp"); rm -f "$log.procs.tmp"
m1=$(( 0x$shell_blk & 0x4003 )); m2=$(( 0x$child_blk & 0x4003 ))
echo "guard: SigBlk & 0x4003: shell $m1, child $m2" >> "$log"
[[ "$n" -eq 0 && "$m1" -eq 0 && "$m2" -eq 0 ]]
