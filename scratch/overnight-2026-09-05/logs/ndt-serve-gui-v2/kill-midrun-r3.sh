#!/usr/bin/env bash
# Starts a gate in its own session and process group, waits for a line that says it is mid-run,
# sends SIGTERM to that group (and only that group), and reports how the gate ended: its exit
# status, its last lines, whether it printed rc=0 or a totals line, and what is left of the group.
# usage: kill-midrun-r3.sh <worktree> <gate path relative to it> <marker regex> <seconds after marker> <gate log>
#        [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; G="$2"; MARK="$3"; AFTER="$4"; LOG="$5"
cd "$WT" || exit 2
echo "date $(date -Is)"; echo "head $(git rev-parse HEAD)"; echo "porcelain $(git status --porcelain --untracked-files=no | grep -c .)"
echo "gate $G sha256 $(sha256sum "$G" | cut -c1-16)"; echo "gate log $LOG"; df -h / | tail -1
setsid bash "$G" > "$LOG" 2>&1 < /dev/null &
pid=$!
echo "gate pid $pid, pgid $(ps -o pgid= -p $pid | tr -d ' ')"
for i in $(seq 1 1800); do grep -qE "$MARK" "$LOG" && break; kill -0 $pid 2>/dev/null || break; sleep 1; done
grep -qE "$MARK" "$LOG" && echo "marker seen after ~$i s: $(grep -m1 -E "$MARK" "$LOG" | cut -c1-100)" || echo "MARKER NOT SEEN"
sleep "$AFTER"
echo "$(date -Is) kill -TERM -- -$pid"
kill -TERM -- -"$pid"
wait "$pid"; st=$?
echo "gate exit status: $st"
sleep 3
left=$(ps -eo pid=,pgid= | awk -v g="$pid" '$2 == g {print $1}' | tr '\n' ' ')
echo "left in its process group 3 s later: ${left:-none}"
echo "--- last 4 lines of the gate's log:"; tail -4 "$LOG" | cut -c1-160 | sed 's/^/  | /'
echo "--- verdict-shaped lines: rc=0 $(grep -c '^rc=0$' "$LOG"), totals $(grep -cE 'mutation\(s\), [0-9]+ survivor|^OK: the committed bundle' "$LOG"), INCOMPLETE $(grep -c '^INCOMPLETE' "$LOG")"
