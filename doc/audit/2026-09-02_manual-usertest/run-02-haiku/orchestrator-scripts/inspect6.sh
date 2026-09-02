set -u
echo "=== guest date / uptime / mem ==="; date -u '+%FT%TZ'; uptime; free -m | head -2
echo "=== build: pid 97778 alive? log size/tail ==="; [ -d /proc/97778 ] && echo "ALIVE start=$(stat -c %y /proc/97778 | cut -c1-19)" || echo "GONE"
ls -l --time-style=+%H:%M:%S ~/logs/p4dev_v8.log 2>&1; wc -c < ~/logs/p4dev_v8.log; tail -c 400 ~/logs/p4dev_v8.log | tr -c '[:print:]\n' '?' | tail -4
grep -c "^\[.*\] make\|Building\|Compiling" ~/logs/p4dev_v8.log 2>/dev/null | head -1
grep -n "STEP\|=====\|Installing\|install-p4dev" ~/logs/p4dev_v8.log | tail -8 | cut -c1-120
echo "=== ~/logs listing (mtime) ==="; ls -l --time-style=+%m-%d_%H:%M:%S ~/logs | awk '{print $6, $5, $7}' | sort
echo "=== tester files ==="; for f in ~/JOURNAL.md ~/BUGS.md ~/CHECKLIST.md; do [ -f "$f" ] && echo "$f $(wc -l < $f) lines mtime=$(stat -c %y $f | cut -c12-19)" || echo "$f MISSING"; done
ls -l --time-style=+%H:%M:%S ~/*.md ~/*.sh 2>/dev/null
echo "=== test_XX.log first/last line each ==="; for f in ~/logs/test_*.log; do echo "-- $f ($(wc -l < $f) lines, $(stat -c %y $f | cut -c12-19))"; head -2 "$f" | cut -c1-140; tail -1 "$f" | cut -c1-140; done 2>/dev/null
echo "=== CHECKLIST verdict counts ==="; grep -o "WORKS-BUT\|WORKS\|BROKEN\|NOT-TRIED\|BLOCKED\|UNCLEAR" ~/CHECKLIST.md 2>/dev/null | sort | uniq -c
echo "=== BUGS.md headings ==="; grep -n "^#\|^BUG\|^\*\*BUG\|^- \*\*BUG\|^| BUG" ~/BUGS.md 2>/dev/null | head -30 | cut -c1-150
echo "=== tmux (user) / tmux (root ndtwinlab) ==="; tmux ls 2>&1 | head -5; sudo -n tmux -L ndtwinlab ls 2>&1 | head -5
echo "=== ndtwin processes ==="; for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null) || continue; c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-110); case "$c" in *ndtwin_kernel*|*ryu-manager*|*testbed_topo*|*run_comprehensive*|*energy_saving*|*simulation_platform*|*install-p4dev*|*make*) echo "${p#/proc/} $(stat -c %y $p | cut -c12-19) :: $c";; esac; done 2>/dev/null | sort -n | head -40
echo "=== :8000 ==="; ss -tlnpH 2>/dev/null | grep -E ':8000|:6653|:8080' | cut -c1-140
echo "=== kernel.log tail ==="; K=~/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log; [ -f $K ] && { wc -l < $K; tail -3 $K | cut -c1-160; } || echo "no $K"; ls ~/Desktop/NDTwin-Kernel/.test_run/ 2>/dev/null
echo "=== fabric hosts ==="; ps -eo args | grep -c "mininet:h[0-9]*$"
echo "=== journal errors last 30 min ==="; journalctl --since "-40min" -p err --no-pager 2>/dev/null | tail -8 | cut -c1-160
echo "=== disk ==="; df -h / | tail -1
