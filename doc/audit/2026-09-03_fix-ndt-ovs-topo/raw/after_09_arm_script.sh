#!/usr/bin/env bash
# FIX-NDT-OVS-TOPO #77 -- LIVE ARM 'AFTER'.
#
# What this runs and what it does NOT run, stated up front so the log cannot be over-read:
#   * The TOPOLOGY is this branch's file, started with the argv the fixed `ovs-topo-start`
#     hands tmux:  <NTG_PY> <KERNEL_DIR>/testbed_topo.py   with cwd = <KERNEL_DIR>.
#   * The LAUNCHER is `sudo -n mnexec` (an already-granted sudoers rule), NOT ndtwin-lab:
#     `ndt` hardcodes LAB=/usr/local/sbin/ndtwin-lab, and installing the fixed script there
#     needs a root install, which is Adam's action. So this arm proves the FILE and the BANNER,
#     not the tmux plumbing (which the test's recorder proves separately).
#   * Ryu + kernel come from stack.sh in the MAIN checkout, driven exactly as ndt's up_ovs
#     drives it (fifo on stdin, wait for the [2/3] banner, start Mininet, press Enter).
set -uo pipefail
SC="$(cd "$(dirname "$0")" && pwd)"
WT="$SC/wt-ovstopo"
MAIN=/home/adam/Desktop/NDTwin-Kernel
RAW="$SC/raw"
NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python
TOPO="$WT/testbed_topo.py"
mkdir -p "$RAW"
say() { echo "[$(date +%H:%M:%S)] $*"; }

say "AFTER arm start"
say "topology under test: $TOPO"
sha256sum "$TOPO" "$MAIN/testbed_topo.py" /home/adam/Network-Traffic-Generator/testbed_topo.py

OUT="$RAW/after_02_stack.log"
FIFO="$SC/after_stack.fifo"; rm -f "$FIFO"; mkfifo "$FIFO"
TFIFO="$SC/after_topo.fifo"; rm -f "$TFIFO"; mkfifo "$TFIFO"
TOPOLOG="$RAW/after_03_topo_stdout.log"

say "[1/4] control plane (Ryu) via stack.sh in the main checkout"
( cd "$MAIN" && NO_COLOR=1 CONVERGE_WAIT=400 bash tools/test_workflow/stack.sh up ovs > "$OUT" 2>&1 < "$FIFO" ) &
STACK_PID=$!
exec 3> "$FIFO"
for i in $(seq 1 120); do
    grep -q '2/3' "$OUT" && break
    kill -0 "$STACK_PID" 2>/dev/null || { say "stack.sh exited early"; cat "$OUT"; exit 1; }
    sleep 1
done
grep -q '2/3' "$OUT" || { say "Ryu never reached the Mininet prompt"; cat "$OUT"; exit 1; }
say "  Ryu up, prompt reached"

say "[2/4] data plane -- THIS BRANCH's testbed_topo.py, argv as the fixed ovs-topo-start builds it"
exec 4<> "$TFIFO"         # <> not >: opening a fifo write-only BLOCKS until a reader
                          # appears, and the reader is started below. Closing fd 4 later leaves
                          # no writer, which is the EOF the CLI needs.
( cd "$WT" && exec sudo -n /usr/bin/mnexec "$NTG_PY" "$TOPO" ) > "$TOPOLOG" 2>&1 < "$TFIFO" &
TOPO_JOB=$!
say "  started (job $TOPO_JOB), stdout -> $TOPOLOG"

for i in $(seq 1 300); do
    n="$(ps -eo args= | grep -c '^mininet:h' || true)"
    [[ "$n" -ge 128 ]] && break
    (( i % 15 == 0 )) && say "  building: $n host namespaces so far"
    sleep 1
done
n="$(ps -eo args= | grep -c '^mininet:h' || true)"
say "  fabric: $n host namespaces"

{
  echo "=== ps: the topology process actually running (AFTER arm) ==="
  date -Is
  ps -eo pid=,args= | grep -E 'testbed_topo\.py' | grep -v grep
  echo
  echo "=== /proc/<pid>/cmdline, NUL-separated, the authority ==="
  for p in $(ps -eo pid=,args= | grep -E 'testbed_topo\.py' | grep -v grep | awk '{print $1}'); do
      echo "-- pid $p"
      sudo -n /usr/bin/mnexec /usr/bin/cat "/proc/$p/cmdline" 2>/dev/null | tr '\0' '\n'
  done
} > "$RAW/after_04_processes.log" 2>&1
say "  captured $RAW/after_04_processes.log"
grep -E 'testbed_topo\.py' "$RAW/after_04_processes.log" | head -4

say "[3/4] hand the prompt back to stack.sh (kernel)"
echo >&3
for i in $(seq 1 400); do
    kill -0 "$STACK_PID" 2>/dev/null || break
    (( i % 20 == 0 )) && say "  stack.sh still working ($(tail -1 "$OUT" | cut -c1-70))"
    sleep 1
done
wait "$STACK_PID"; STACK_RC=$?
say "  stack.sh rc=$STACK_RC"
exec 3>&-

say "[4/4] status + banner"
( cd "$MAIN" && NDT_OWNER=ovstopo timeout 120 ./tools/test_workflow/ndt status ) > "$RAW/after_05_ndt_status.log" 2>&1
tail -20 "$RAW/after_05_ndt_status.log"

say "banner so far (the topology's own stdout):"
tail -20 "$TOPOLOG"

say "closing the topology's stdin (CLI EOF -> net.stop)"
exec 4>&-
for i in $(seq 1 180); do
    kill -0 "$TOPO_JOB" 2>/dev/null || break
    sleep 1
done
say "topology exited"
say "AFTER arm captured"
