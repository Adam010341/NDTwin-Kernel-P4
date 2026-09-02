#!/bin/bash
echo "=== prove the catch-22 with four one-liners ==="
echo -n "system python3 + mininet : "; sudo python3 -c "import mininet; print('OK')" 2>&1 | tail -1
echo -n "system python3 + loguru  : "; sudo python3 -c "import loguru; print('OK')" 2>&1 | tail -1
echo -n "ntg-env python + mininet : "; sudo ~/ntg-env/bin/python -c "import mininet; print('OK')" 2>&1 | tail -1
echo -n "ntg-env python + loguru  : "; sudo ~/ntg-env/bin/python -c "import loguru; print('OK')" 2>&1 | tail -1
echo
echo "=== workaround: a venv that can see the apt-installed mininet ==="
python3 -m venv --system-site-packages ~/ntg-env2
~/ntg-env2/bin/pip install -q --upgrade pip 2>&1 | tail -1
~/ntg-env2/bin/pip install -q loguru prompt_toolkit nornir nornir-utils pyyaml numpy pandas paramiko requests pydantic 2>&1 | tail -2
echo -n "ntg-env2 + mininet : "; sudo ~/ntg-env2/bin/python -c "import mininet; print('OK')" 2>&1 | tail -1
echo -n "ntg-env2 + loguru  : "; sudo ~/ntg-env2/bin/python -c "import loguru; print('OK')" 2>&1 | tail -1
echo
echo "=== retry NTG topology with ntg-env2 ==="
echo "NTG2_START $(date +%H:%M:%S)"
tmux kill-session -t NTG 2>/dev/null
tmux new-session -d -s NTG -x 200 -y 50
tmux send-keys -t NTG 'cd ~/Network-Traffic-Generator && sudo ~/ntg-env2/bin/python testbed_topo.py' Enter
sleep 90
tmux capture-pane -t NTG -p | grep -v '^$' | tail -22
echo "--bridges--"; sudo ovs-vsctl list-br | tr '\n' ' '; echo
date +%H:%M:%S
