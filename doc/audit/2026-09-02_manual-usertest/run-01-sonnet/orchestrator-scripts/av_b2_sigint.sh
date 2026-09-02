#!/bin/bash
# auditor 4(b) RE-RUN with kpid() fixed (first run: kpid empty, arm2 and cleanup acted on ""). Does SIGINT reach the kernel through the `setsid nohup sudo` wrapper? Two launches, three arms.
# Needs the manual OVS path up first (Ryu in ryu-env + testbed_topo.py under a pty). Run as ndt: bash /tmp/av_b_sigint.sh
# [Co-developed with claude code -- Adam]
set -u
OUT=$HOME/auditor-verification/b2; mkdir -p "$OUT" "$HOME/logs"; cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
RYU=$HOME/miniconda3/envs/ryu-env/bin/ryu-manager; TM="tmux -L a7v"
host_count() { ps -eo args= | awk '{print $NF}' | grep -c '^mininet:h[0-9]*$'; }
$TM kill-server 2>/dev/null; sudo -n mn -c > /dev/null 2>&1
$TM new-session -d -s ryu -c "$PWD" "$RYU intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link 2>&1 | tee $HOME/logs/av2_ryu.log"
sleep 10
$TM new-session -d -s topo -c "$PWD" "sudo -n python3 testbed_topo.py 2>&1 | tee $HOME/logs/av2_topo.log"
for i in $(seq 1 150); do grep -q "all-destination paths installed" "$HOME/logs/av2_ryu.log" 2>/dev/null && break; sleep 2; done
{ echo "### fabric: converged-line count=$(grep -c 'all-destination paths installed' "$HOME/logs/av2_ryu.log") after ~$((i*2))s; hosts=$(host_count)"; } > "$OUT/b0_fabric.txt" 2>&1
kpid() { sudo -n ss -tlnpH "( sport = :8000 )" | grep -o "pid=[0-9]*" | head -1 | cut -d= -f2; }   # /proc/<root pid>/exe is unreadable to ndt (first run: empty pid); the :8000 owner is the kernel
launch() { setsid nohup sudo -n ./build/bin/ndtwin_kernel --mode mininet --topology setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info > "$1" 2>&1 < /dev/null & echo $!; }
arm() {  # $1 label, $2 target pid, $3 kernel pid, $4 log
  local i; kill -INT "$2"; local t0; t0=$(date +%T.%N)
  for i in $(seq 1 30); do sleep 0.5; [ -d "/proc/$3" ] || break; done
  { echo "### $1: kill -INT $2 at $t0"; echo "kernel $3 alive after $((i/2))s: $([ -d /proc/$3 ] && echo YES || echo no)"
    echo "--- shutdown lines in log ---"; grep -n "All subsystems stopped\|Exiting\.\|terminate called\|signal\|SIGINT" "$4" | tail -6
    echo "--- :8000 ---"; sudo -n ss -tlnpH "( sport = :8000 )"; [ -d "/proc/$3" ] && { echo "--- State/Sig (post) ---"; grep -E "^(State|Sig)" "/proc/$3/status"; }
  } >> "$OUT/$1.txt" 2>&1
}
for round in 1 2; do
  LOG=$HOME/logs/av2_kernel_$round.log; W=$(launch "$LOG"); sleep 15; K=$(kpid)
  { echo "### round $round"; echo "wrapper(\$!)=$W exe=$(readlink /proc/$W/exe 2>/dev/null) cmd=$(tr '\0' ' ' < /proc/$W/cmdline 2>/dev/null | cut -c1-120)"
    echo "kernel=$K ppid=$(awk '/^PPid/{print $2}' /proc/$K/status 2>/dev/null) cmd=$(tr '\0' ' ' < /proc/$K/cmdline 2>/dev/null | cut -c1-120)"
    echo "--- kernel Sig* (pre) ---"; grep -E "^(State|Sig|Shd)" "/proc/$K/status" 2>&1; echo "--- wrapper Sig* (pre) ---"; grep -E "^(Name|Sig)" "/proc/$W/status" 2>&1
    echo "--- :8000 ---"; sudo -n ss -tlnpH "( sport = :8000 )"; echo "--- topology lines ---"; grep -n "topology from the control plane\|Pulled" "$LOG" | tail -2
  } > "$OUT/b${round}_pre.txt" 2>&1
  arm "b${round}_arm1_wrapper" "$W" "$K" "$LOG"
  if [ -d "/proc/$K" ]; then arm "b${round}_arm2_kernelpid" "$K" "$K" "$LOG"; else echo "arm2 skipped: kernel exited on arm1" > "$OUT/b${round}_arm2_kernelpid.txt"; fi
  if [ -d "/proc/$K" ]; then { echo "### still alive after both arms -> SIGTERM then SIGKILL (cleanup)"; sudo -n kill -TERM "$K"; sleep 5; [ -d "/proc/$K" ] && sudo -n kill -KILL "$K"; sleep 1; echo "alive: $([ -d /proc/$K ] && echo YES || echo no)"; } >> "$OUT/b${round}_arm2_kernelpid.txt" 2>&1; fi
  sleep 3
done
$TM send-keys -t topo "exit" Enter; sleep 12; sudo -n mn -c > /dev/null 2>&1; $TM kill-server 2>/dev/null
{ echo "### teardown: hosts=$(host_count) :8000=$(sudo -n ss -tlnH '( sport = :8000 )' | wc -l) :6633=$(ss -tlnH '( sport = :6633 )' | wc -l)"; } > "$OUT/b9_teardown.txt" 2>&1
date -u +%FT%TZ > "$OUT/B2_DONE"
