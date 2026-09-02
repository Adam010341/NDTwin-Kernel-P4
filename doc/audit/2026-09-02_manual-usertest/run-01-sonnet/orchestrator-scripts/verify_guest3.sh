set -u
echo "=== BUG-005 state after my reproduction ==="; tmux ls 2>&1 | head -3; sudo -n tmux -L ndtwinlab ls 2>&1 | head -5; ls -la ~/Desktop/NDTwin-Kernel/.test_run/pids/ 2>&1 | head; tail -5 ~/Desktop/NDTwin-Kernel/.test_run/logs/app_sim.log 2>&1 | cut -c1-160
echo "=== sim / esa processes (start time, cmd) ==="; for pid in 431581 431726; do [ -d /proc/$pid ] && echo "pid=$pid start=$(stat -c %y /proc/$pid | cut -c1-19) :: $(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-100) ppid=$(awk '/^PPid/{print $2}' /proc/$pid/status)"; done
echo "=== BUG-010: kernel_p4.log structure ==="; grep -n "main.cpp" ~/logs/kernel_p4.log | grep -i "start\|exiting\|listening\|version\|mode" | cut -c1-170 | head -12; echo "-- terminate/abort lines --"; grep -n "terminate called\|Aborted\|core dumped" ~/logs/kernel_p4.log | head -5; echo "-- line count / first+last timestamps --"; wc -l < ~/logs/kernel_p4.log; head -1 ~/logs/kernel_p4.log | cut -c1-60; tail -1 ~/logs/kernel_p4.log | cut -c1-120
echo "-- kernel_sim.log bind error --"; grep -n "Address already in use\|bind" ~/logs/kernel_sim.log 2>/dev/null | head -3 | cut -c1-170; head -2 ~/logs/kernel_sim.log 2>/dev/null | cut -c1-80
echo "=== ~/.local/bin/ndt ==="; ls -la ~/.local/bin/ndt 2>&1
echo "=== saved artefacts from the tester (json, screenshots) ==="; ls -la ~/*.json ~/*.png ~/*.xwd /tmp/*.json /tmp/*.png 2>/dev/null | head -8
echo "=== what the tester changed in each tool repo ==="; for d in ~/Desktop/Network-State-Recorder ~/Desktop/Network-Traffic-Generator ~/Desktop/Network-Traffic-Visualizer ~/Desktop/Web-GUI ~/Energy-Saving-App ~/Simulation-Platform-Manager; do echo "-- $d"; git -C "$d" status --porcelain | head -4; git -C "$d" diff | grep "^[-+]" | grep -v "^+++\|^---" | head -6 | cut -c1-150; done
echo "=== logs sizes ==="; ls -la --time-style=+%H:%M ~/logs | awk '{print $5, $6, $7}' | column -t | head -30
echo "=== disk ==="; df -h / | tail -1
