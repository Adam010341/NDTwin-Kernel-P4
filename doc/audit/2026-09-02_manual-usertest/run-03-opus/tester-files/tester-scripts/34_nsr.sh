#!/bin/bash
cd ~/Network-State-Recorder
echo "########## E11/E12: the stop script, with nothing running ##########"
./stop_network_state_recorder.sh
echo "STOP_EXIT=$?"
echo "-- E12: did it flip display_on_console back to true? --"
grep display_on_console setting/recorder_setting.yaml
echo
echo "########## E09: Option 2 (foreground) with the venv the manual told me to make ##########"
tmux kill-session -t NSR 2>/dev/null
tmux new-session -d -s NSR -x 200 -y 50
tmux send-keys -t NSR 'cd ~/Network-State-Recorder && source ~/nsr-env/bin/activate && python3 network_state_recorder.py' Enter
sleep 25
echo "-- pane --"
tmux capture-pane -t NSR -p | tail -18
echo
echo "-- E10 status check now --"
pgrep -af network_state_recorder.py || echo "   (no match)"
echo "-- E13: recorded_info/ --"
ls -la recorded_info/ 2>&1 | head -8
echo "-- E15: logs/ --"
ls -la logs/ 2>&1 | head -5
echo "-- E16: JSON structure of what it wrote --"
for f in recorded_info/*.json; do
  echo "  file: $f  ($(wc -l < "$f") lines, $(wc -c < "$f") bytes)"
  head -c 300 "$f"; echo; echo "  ---"
done 2>/dev/null | head -20
date +%H:%M:%S
