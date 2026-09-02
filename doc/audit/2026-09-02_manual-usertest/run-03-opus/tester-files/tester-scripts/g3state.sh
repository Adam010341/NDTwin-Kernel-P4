set -u
echo "=== guest date / uptime ==="; date '+%F %T %Z'; uptime
echo "=== tester files ==="; for f in ~/JOURNAL.md ~/BUGS.md ~/CHECKLIST.md ~/TEST_PLAN.md ~/SUMMARY_FINDINGS.md; do [ -f "$f" ] && printf '%-28s %5s lines  mtime %s\n' "$(basename $f)" "$(wc -l < $f)" "$(stat -c %y "$f" | cut -c1-19)"; done
echo "=== last 25 lines of JOURNAL ==="; tail -25 ~/JOURNAL.md 2>/dev/null
echo "=== tmux ==="; tmux ls 2>&1 | head -10
echo "=== listening ports ==="; ss -tlnH 2>/dev/null | awk '{print $4}' | sort -u | head -20
echo "=== logs dir ==="; ls -la --time-style=+%m-%d_%H:%M ~/logs 2>/dev/null | tail -25
echo "=== disk ==="; df -h / | tail -1
