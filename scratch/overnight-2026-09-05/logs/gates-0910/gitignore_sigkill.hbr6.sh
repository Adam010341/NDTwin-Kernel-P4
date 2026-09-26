#!/usr/bin/env bash
# sigkill_leftovers.sh -- round-5 finding 4, the real failure mode: SIGKILL the oldcode tool while its
# copies exist, then ask git whether they can be swept into a commit. Only processes this script
# started are killed (by their process group, never by name); leftovers are removed by exact name.
set -u
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
D=doc/audit/2026-09-25_p4-heartbeat/spike
K="$SP/killtest"; rm -rf "$K"; mkdir -p "$K"
TMPDIR="$K" setsid bash "$D/oldcode_selftest.sh" R4-3 > "$K/tool.out" 2>&1 &
pid=$!
echo "started the tool: pid $pid (its own session and process group via setsid; TMPDIR=$K)"
for (( i = 0; i < 300; i++ )); do compgen -G "$D/.oldcode-$pid-*" >/dev/null && break; sleep 0.1; done
echo "process group $pid before the kill:"; ps -o pid=,pgid=,args= -g "$pid" | sed 's/^/    /'
kill -9 -- "-$pid"; sleep 1
echo "after kill -9 -- -$pid: processes left in group $pid: $(ps -o pid= -g "$pid" | wc -l)"
echo "leftover copies in the spike dir:"; ls -la "$D" | grep -F ".oldcode-$pid-" | sed 's/^/    /'
n=$(compgen -G "$D/.oldcode-$pid-*" | wc -l)
echo "--- git status --porcelain --untracked-files=all (must not list them):"
git status --porcelain --untracked-files=all | sed 's/^/    /'
u=$(git status --porcelain --untracked-files=all | grep -c 'oldcode-')
echo "--- git status --porcelain --ignored -- $D:"
git status --porcelain --ignored --untracked-files=all -- "$D" | sed 's/^/    /'
echo "--- git add --dry-run -- $D/ (a directory pathspec; must add nothing):"
a="$(git add --dry-run -- "$D/")"; printf '%s\n' "$a" | sed 's/^/    /'
echo "--- git check-ignore -v:"; git check-ignore -v -- "$D"/.oldcode-"$pid"-* | sed 's/^/    /'
rm -f -- "$D"/.oldcode-"$pid"-*; rm -rf -- "$K"
echo "removed the leftovers by name; left: $(compgen -G "$D/.oldcode-$pid-*" | wc -l); scratch TMPDIR removed"
if (( n >= 1 && u == 0 )) && [[ -z "$a" ]]; then
    echo "LEFTOVERS OF A SIGKILLED RUN ($n) ARE IGNORED: not untracked, not added by a directory pathspec"; exit 0
else
    echo "NOT AS IT MUST: leftovers $n, listed as untracked $u, dry-run add '$a'"; exit 1
fi
