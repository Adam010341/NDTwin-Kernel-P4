# shared helpers (adapted from healthcut2/pr-cut2/lib.sh: OUT, SP, disk floor 1800, mutate_/probe.py scan)
K=/home/adam/Desktop/NDTwin-Kernel
I=$K/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926
OUT=$I/ternary/pr-cut-a
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/pr-cuta
waitdisk() {  # $1 = label ; df -m / Avail must be >= 1800 else poll every 5 min
  while :; do a=$(df -m / | awk 'NR==2{print $4}'); echo "[df] $(date '+%F %T') before $1: ${a} MB avail" >> $OUT/cmds.log
    [ "$a" -ge 1800 ] && break; echo "[df] under 1800, waiting 300 s" >> $OUT/cmds.log; sleep 300; done
  waitgate "$1"; }
# scan /proc ourselves (skip own shell); any process whose cmdline names a mutate_*.sh or probe.py counts; poll 5 min, give up after 3 h
waitgate() { t0=$(date +%s)
  while :; do n=0; for d in /proc/[0-9]*; do p=${d#/proc/}; [ "$p" = "$$" ] && continue; [ "$p" = "$BASHPID" ] && continue
      gc=$(tr '\0' ' ' < $d/cmdline 2>/dev/null) || continue
      case "$gc" in *waitgate*|*lib.sh*) continue;; esac
      case "$gc" in *mutate_*|*probe.py*) n=$((n+1)); echo "[gate-proc] $p ${gc:0:160}" >> $OUT/cmds.log;; esac; done
    echo "[mutate_/probe.py processes before $1 at $(date '+%F %T'): $n]" >> $OUT/cmds.log
    [ "$n" -eq 0 ] && return 0
    [ $(( $(date +%s) - t0 )) -ge 10800 ] && { echo "STOPPED: mutate_/probe.py process still running after 3 h" >> $OUT/cmds.log; exit 9; }
    sleep 300; done; }
x() { echo "[cmd] $(date '+%F %T') \$ $*" >> $OUT/cmds.log; "$@"; r=$?; echo "[cmd]   exit $r" >> $OUT/cmds.log; return $r; }
