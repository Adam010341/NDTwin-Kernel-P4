#!/usr/bin/env bash
# guard.sh <log> : the global preconditions before a step. Appends to <log>:
#   - the mutate_/probe.py/simple_switch/driver.sh process list (ps), minus grep and guard.sh themselves and the merged-head
#     driver (mgrun.sh, which never matches); the df -m / and MemAvailable figures; this shell's SigBlk/SigIgn and a child's own
#     (the grep reads /proc/self/status, i.e. its own, the mask a child inherits). NOT through $(...): a shell waiting inside a
#     command substitution shows a different (its own, SIGINT) wait mask.
# Exit 0 = all clear. Exit 1 = a matching process, or df < 1800 MB, or MemAvailable < 1800 MB (wait and retry).
# Exit 2 = SigBlk & 0x4203 != 0 (SIGHUP, SIGINT, SIGUSR1, SIGTERM blocked): waiting does not help.
# Based on p4-ternary-replay-c/r5/guard.sh; 0x4003 -> 0x4203, driver.sh added, SigIgn, df and memory added.
# [Co-developed with claude code -- Adam]
log="$1"
ps -eo pid,cmd | grep -E 'mutate_|probe\.py|simple_switch|driver\.sh' | grep -v grep | grep -v "guard.sh" > "$log.procs.tmp"
free_mb=$(df -m / | awk 'NR==2{print $4}')
mem_mb=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
{ echo "$(date -Is) guard: $(grep -c . "$log.procs.tmp") matching mutate_/probe.py/simple_switch/driver.sh process(es); df -m / free ${free_mb} MB; MemAvailable ${mem_mb} MB"; cat "$log.procs.tmp"; } >> "$log"
grep -E '^Sig(Blk|Ign)' /proc/$$/status | sed 's/^/guard: shell '"$$"' /' >> "$log"
grep -E '^Sig(Blk|Ign)' /proc/self/status | sed 's/^/guard: child of the shell, /' >> "$log"
grep SigBlk /proc/$$/status > "$log.sb.tmp"; shell_blk=$(awk '{print $2}' "$log.sb.tmp")
grep SigBlk /proc/self/status > "$log.sb.tmp"; child_blk=$(awk '{print $2}' "$log.sb.tmp"); rm -f "$log.sb.tmp"
n=$(grep -c . "$log.procs.tmp"); rm -f "$log.procs.tmp"
m1=$(( 0x$shell_blk & 0x4203 )); m2=$(( 0x$child_blk & 0x4203 ))
echo "guard: SigBlk & 0x4203: shell $m1, child $m2" >> "$log"
[[ "$m1" -eq 0 && "$m2" -eq 0 ]] || { echo "guard: REFUSED: a stop signal is blocked" >> "$log"; exit 2; }
[[ "$n" -eq 0 && "$free_mb" -ge 1800 && "$mem_mb" -ge 1800 ]] || exit 1
exit 0
