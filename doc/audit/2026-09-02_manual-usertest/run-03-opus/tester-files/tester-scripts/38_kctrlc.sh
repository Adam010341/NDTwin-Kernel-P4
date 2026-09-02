#!/bin/bash
echo "########## B23: kernel Ctrl-C ##########"
tmux send-keys -t KERNEL C-c
sleep 12
echo "--- last 20 lines of the kernel pane ---"
tmux capture-pane -t KERNEL -p | grep -v '^$' | tail -20
echo "--- port 8000 now ---"
ss -lntp 2>/dev/null | grep ':8000' || echo "(8000 released)"
echo "--- any ndtwin_kernel process left? ---"
ps -eo pid,args= | grep '[n]dtwin_kernel' || echo "(none)"
echo
echo "########## ndt down: 'take it all down and prove the machine is clean' ##########"
~/.local/bin/ndt down 2>&1 | tail -30
echo "NDT_DOWN_EXIT=$?"
echo
echo "########## ndt status after down ##########"
~/.local/bin/ndt status 2>&1 | sed -n '/^running/,/^$/p'
date +%H:%M:%S
