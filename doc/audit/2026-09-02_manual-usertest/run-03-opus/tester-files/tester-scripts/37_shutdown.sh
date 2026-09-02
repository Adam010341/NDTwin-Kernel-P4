#!/bin/bash
echo "=== PIDs before shutdown ==="
RYU=$(ss -lntp 2>/dev/null | grep ':6633' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
KER=$(ss -lntp 2>/dev/null | grep ':8000' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
echo "ryu pid=$RYU   kernel pid(from ss)=$KER"
ps -eo pid,args= | grep '[n]dtwin_kernel' | head -2
KPID=$(ps -eo pid,args= | grep '[n]dtwin_kernel' | awk '{print $1}' | head -1)
echo "kernel pid=$KPID"
echo "$RYU $KPID" > /tmp/pids.txt
echo
echo "########## Manual step 1: type 'exit' in Terminal 2 (Mininet) ##########"
tmux send-keys -t MN 'exit' Enter
sleep 20
tmux capture-pane -t MN -p | tail -14
echo "--- manual step 2 claim: 'The script will automatically remove the IP alias' ---"
ip addr show lo | grep -E 'inet ' | head -5
echo
echo "--- are ryu and kernel still alive after the mininet exit? ---"
[ -d /proc/$RYU ] && echo "ryu ALIVE" || echo "ryu gone"
[ -d /proc/$KPID ] && echo "kernel ALIVE" || echo "kernel gone"
echo
echo "########## Manual step 3: sudo mn -c ##########"
sudo mn -c 2>&1 | tail -12
echo
echo "--- B22 claim: 'Step 3 already killed your Ryu controller' ---"
[ -d /proc/$RYU ] && echo "ryu ALIVE (claim NOT reproduced)" || echo "ryu GONE (claim reproduced)"
[ -d /proc/$KPID ] && echo "kernel ALIVE" || echo "kernel gone"
echo "--- what the Ryu pane shows now ---"
tmux capture-pane -t RYU -p | grep -v '^$' | tail -5
echo "--- ports ---"
ss -lntp 2>/dev/null | grep -E ':6633|:8080|:8000' || echo "(none of 6633/8080/8000 listening)"
date +%H:%M:%S
