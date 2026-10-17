#!/usr/bin/env bash
# pg.sh : the seen-red / green / control runs of tests.test_port_guard in the gate clone, holding the shared lock.
# [Co-developed with claude code -- Adam]
E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1016
G=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg16/gate
LOCK=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/heavy-step.lock
M4=a0805b84d6f5a14c0013cccd0c0608f9b81f8462; M5=5b83c8994ecf4b439e2e8f616ba4ac0a2f34e3cf
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg16/tmp
mkdir -p "$TMPDIR"
t0=$(date +%s); exec 9>>"$LOCK"; flock 9; echo "$(date -Is) pg: lock acquired after $(( $(date +%s)-t0 )) s" >> $E/pg.log
n=0; while ss -ltn | awk '{print $4}' | grep -qE '[:.]8081$'; do n=$((n+1)); [ $n -gt 120 ] && { echo "STOP: :8081 busy 2h" >> $E/pg.log; exit 2; }; echo "$(date -Is) pg: :8081 busy, wait $n" >> $E/pg.log; sleep 60; done
run() {  # run <name> <rev> <cmd...>
  local name="$1" rev="$2"; shift 2
  git -C "$G" checkout -q --detach "$rev" || { echo "checkout $rev failed" >> $E/pg.log; return 1; }
  ss -ltnp > "$E/pg_$name.ss.txt" 2>&1
  { echo "commit $(git -C $G rev-parse HEAD)  tracked-dirty=$(git -C $G status --porcelain --untracked-files=no | wc -l)"
    echo "cwd $G/p4_proxy  NDTWIN_PROXY_HOST=${NDTWIN_PROXY_HOST-<unset in runner env>}  command: $*"
    echo "ss :8081 listeners before: $(grep -cE '[:.]8081 ' "$E/pg_$name.ss.txt")"
  } > "$E/pg_$name.log"
  ( cd "$G/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 "$@" ) >> "$E/pg_$name.log" 2>&1 9>&-
  local rc=$?; echo "rc=$rc" >> "$E/pg_$name.log"; echo "$(date -Is) pg: $name rc=$rc" >> $E/pg.log
}
run red_at_M4 $M4 env NDTWIN_PROXY_HOST=not-an-address venv/bin/python -m unittest tests.test_port_guard -v
run green_at_M5 $M5 env NDTWIN_PROXY_HOST=not-an-address venv/bin/python -m unittest tests.test_port_guard -v
run control_at_M5 $M5 env -u NDTWIN_PROXY_HOST venv/bin/python -m unittest tests.test_port_guard -v
git -C "$G" checkout -q --detach $M5
echo "$(date -Is) pg: done; HEAD $(git -C $G rev-parse HEAD) tracked-dirty=$(git -C $G status --porcelain --untracked-files=no | wc -l)" >> $E/pg.log
flock -u 9
