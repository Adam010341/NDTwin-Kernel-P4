#!/usr/bin/env bash
# pg.sh : the seen-red / green / control runs of tests.test_port_guard in the gate clone, holding the shared lock.
# [Co-developed with claude code -- Adam]
E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1016
G=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg16/gate
LOCK=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/heavy-step.lock
M4=a0805b84d6f5a14c0013cccd0c0608f9b81f8462; M5=cc0bca4bde02d6611935508ae49a3d3790d6ffbe
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg16/tmp
mkdir -p "$TMPDIR"
t0=$(date +%s); exec 9>>"$LOCK"; flock 9; echo "$(date -Is) pg: lock acquired after $(( $(date +%s)-t0 )) s" >> $E/pg2.log
n=0; while ss -ltn | awk '{print $4}' | grep -qE '[:.]8081$'; do n=$((n+1)); [ $n -gt 120 ] && { echo "STOP: :8081 busy 2h" >> $E/pg2.log; exit 2; }; echo "$(date -Is) pg: :8081 busy, wait $n" >> $E/pg2.log; sleep 60; done
run() {  # run <name> <rev> <cmd...>
  local name="$1" rev="$2"; shift 2
  git -C "$G" checkout -q --detach "$rev" || { echo "checkout $rev failed" >> $E/pg2.log; return 1; }
  ss -ltnp > "$E/pg2_$name.ss.txt" 2>&1
  { echo "commit $(git -C $G rev-parse HEAD)  tracked-dirty=$(git -C $G status --porcelain --untracked-files=no | wc -l)"
    echo "cwd $G/p4_proxy  NDTWIN_PROXY_HOST=${NDTWIN_PROXY_HOST-<unset in runner env>}  command: $*"
    echo "ss :8081 listeners before: $(grep -cE '[:.]8081 ' "$E/pg2_$name.ss.txt")"
  } > "$E/pg2_$name.log"
  ( cd "$G/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 "$@" ) >> "$E/pg2_$name.log" 2>&1 9>&-
  local rc=$?; echo "rc=$rc" >> "$E/pg2_$name.log"; echo "$(date -Is) pg: $name rc=$rc" >> $E/pg2.log
}
run red_at_M4 $M4 env NDTWIN_PROXY_HOST=not-an-address venv/bin/python -m unittest tests.test_port_guard -v
run green_at_M5p $M5 env NDTWIN_PROXY_HOST=not-an-address venv/bin/python -m unittest tests.test_port_guard -v
run control_at_M5p $M5 env -u NDTWIN_PROXY_HOST venv/bin/python -m unittest tests.test_port_guard -v
git -C "$G" checkout -q --detach $M5
echo "$(date -Is) pg: done; HEAD $(git -C $G rev-parse HEAD) tracked-dirty=$(git -C $G status --porcelain --untracked-files=no | wc -l)" >> $E/pg2.log
# the new test alone, in a scratch copy of M4's tree with M5' 's test file over it (NOT in the clone), then the same with the
# dialed_ports filter line removed (a mutant: must go red)
SC=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg16/ptest
rm -rf "$SC"; mkdir -p "$SC"
git -C "$G" archive $M4 p4_proxy/tests p4_proxy/mininet | tar -x -C "$SC"
git -C "$G" show $M5:p4_proxy/tests/test_port_guard.py > "$SC/p4_proxy/tests/test_port_guard.py"
for v in newtest_at_M4 newtest_mutant_no_filter; do
  if [ $v = newtest_mutant_no_filter ]; then grep -v 'HTTP API listening on" not in line' "$SC/p4_proxy/tests/test_port_guard.py" > "$SC/x" && mv "$SC/x" "$SC/p4_proxy/tests/test_port_guard.py"; fi
  ss -ltnp > "$E/pg2_$v.ss.txt" 2>&1
  { echo "scratch copy $SC (M4 tree p4_proxy/tests + p4_proxy/mininet, test_port_guard.py from M5'$( [ $v = newtest_mutant_no_filter ] && echo ', filter line deleted'))"
    echo "command: cd $SC/p4_proxy; $G/p4_proxy/venv/bin/python -m unittest tests.test_port_guard.DialedPortsTest.test_the_listen_line_is_not_a_dial -v"; } > "$E/pg2_$v.log"
  ( cd "$SC/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 "$G/p4_proxy/venv/bin/python" -m unittest tests.test_port_guard.DialedPortsTest.test_the_listen_line_is_not_a_dial -v ) >> "$E/pg2_$v.log" 2>&1 9>&-
  echo "rc=$?" >> "$E/pg2_$v.log"; echo "$(date -Is) pg: $v $(tail -1 $E/pg2_$v.log)" >> $E/pg2.log
done
rm -rf "$SC"
flock -u 9
