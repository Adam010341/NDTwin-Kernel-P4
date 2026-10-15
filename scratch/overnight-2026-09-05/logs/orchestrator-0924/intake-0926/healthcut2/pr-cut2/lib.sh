# shared helpers
K=/home/adam/Desktop/NDTwin-Kernel
I=$K/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926
OUT=$I/healthcut2/pr-cut2
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/prcut2
waitdisk() {  # $1 = label ; df -m / Avail must be >= 1700 else poll every 5 min
  while :; do a=$(df -m / | awk 'NR==2{print $4}'); echo "[df] $(date '+%F %T') before $1: ${a} MB avail" >> $OUT/cmds.log
    [ "$a" -ge 1700 ] && return; echo "[df] under 1700, waiting 300 s" >> $OUT/cmds.log; sleep 300; done; }
x() { echo "[cmd] $(date '+%F %T') \$ $*" >> $OUT/cmds.log; "$@"; r=$?; echo "[cmd]   exit $r" >> $OUT/cmds.log; return $r; }
