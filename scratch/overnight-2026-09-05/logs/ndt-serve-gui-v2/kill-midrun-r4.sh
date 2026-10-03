#!/usr/bin/env bash
# r4 of kill-midrun-r3.sh: the signal is a parameter (TERM or INT), and after the kill /proc and
# /tmp are scanned for what the run made -- every /tmp entry of this user that appeared while it ran
# (named in a list, read before the start and again just before the kill), and every process
# whose command line or cwd still names one of them.
# usage: kill-midrun-r4.sh <worktree> <gate> <marker regex> <seconds after marker> <TERM|INT> <gate log>
#        [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; G="$2"; MARK="$3"; AFTER="$4"; SIG="$5"; LOG="$6"
cd "$WT" || exit 2
echo "date $(date -Is)"; echo "head $(git rev-parse HEAD)"; echo "porcelain $(git status --porcelain --untracked-files=no | grep -c .)"
echo "gate $G sha256 $(sha256sum "$G" | cut -c1-16)"; echo "gate log $LOG"; echo "signal SIG$SIG"; df -h / | tail -1
T="${TMPDIR:-/tmp}"
before=$(find "$T" -mindepth 1 -maxdepth 1 -user "$(id -u)" -printf '%f\n' 2>/dev/null | sort)
# An async command of a non-interactive shell starts with SIGINT ignored, and a signal ignored at
# entry cannot be trapped -- so the gate is exec'd from a launcher that puts INT back to default and
# starts a new session (pid = pgid = the gate's). Found 10-02: the first INT run here was ignored.
python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.setsid()
os.execvp("bash", ["bash", sys.argv[1]])' "$G" > "$LOG" 2>&1 < /dev/null &
pid=$!
echo "gate pid $pid, pgid $(ps -o pgid= -p $pid | tr -d ' ')"
for i in $(seq 1 1800); do grep -qE "$MARK" "$LOG" && break; kill -0 $pid 2>/dev/null || break; sleep 1; done
grep -qE "$MARK" "$LOG" && echo "marker seen after ~$i s: $(grep -m1 -E "$MARK" "$LOG" | cut -c1-100)" || echo "MARKER NOT SEEN"
sleep "$AFTER"
during=$(find "$T" -mindepth 1 -maxdepth 1 -user "$(id -u)" -printf '%f\n' 2>/dev/null | sort)
new=$(comm -13 <(echo "$before") <(echo "$during"))
# only the names these gates and their suites make (mktemp prefixes); other sessions share /tmp
made=$(grep -E '^(ndt-serve-mutate-|ndt-measuring-mutate-|ndt-status-measuring-|ndt-page-gate-|ndt-page-|ndt-serve-test-|ndt-serve-rebuild-|ndt-honesty-)' <<<"$new")
echo "made in $T while it ran (this gate's prefixes): $(echo $made)"
echo "other new $T entries of this user (not counted): $(grep -cvE '^(ndt-serve-mutate-|ndt-measuring-mutate-|ndt-status-measuring-|ndt-page-gate-|ndt-page-|ndt-serve-test-|ndt-serve-rebuild-|ndt-honesty-)|^$' <<<"$new")"
echo "$(date -Is) kill -$SIG -- -$pid"
kill -"$SIG" -- -"$pid"
wait "$pid"; st=$?
echo "gate exit status: $st"
sleep 3
left=$(ps -eo pid=,pgid= | awk -v g="$pid" '$2 == g {print $1}' | tr '\n' ' ')
echo "left in its process group 3 s later: ${left:-none}"
still=""; holders=""
for m in $made; do
    [[ -e "$T/$m" ]] && still+="$m "
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        if { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null | grep -qF "$T/$m" || [[ "$(readlink "$d/cwd" 2>/dev/null)" == "$T/$m"* ]]; then
            holders+="$p($m) "
        fi
    done
done
echo "its $T entries still there: ${still:-none}"
echo "processes naming them (cmdline or cwd): ${holders:-none}"
echo "--- last 4 lines of the gate's log:"; tail -4 "$LOG" | cut -c1-160 | sed 's/^/  | /'
echo "--- verdict-shaped lines: rc=0 $(grep -c '^rc=0$' "$LOG"), totals $(grep -cE 'mutation\(s\), [0-9]+ survivor|^OK: the committed bundle' "$LOG"), INCOMPLETE $(grep -c '^INCOMPLETE' "$LOG")"
