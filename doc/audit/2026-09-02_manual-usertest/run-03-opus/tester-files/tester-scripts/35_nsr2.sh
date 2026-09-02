#!/bin/bash
cd ~/Network-State-Recorder
echo "-- console output? (display_on_console is true) --"
tmux capture-pane -t NSR -p -S -200 | grep -v '^$' | tail -12
echo "-- generate traffic so flowinfo has something to record --"
tmux send-keys -t MN 'h50 iperf3 -s -p 5501 &' Enter
sleep 2
tmux send-keys -t MN 'h1 iperf3 -c h50 -p 5501 -t 150 &' Enter
echo "-- wait past storage_interval (2 min) to see rotation + zip --"
for i in $(seq 1 9); do
  sleep 20
  echo "$(date +%H:%M:%S)  recorded_info: $(ls recorded_info/ 2>/dev/null | tr '\n' ' ')"
  echo "            logs dir: $(ls logs/ 2>/dev/null | tr '\n' ' ' || echo MISSING)"
done
echo
echo "-- E14: zip archives present? --"
ls -la recorded_info/*.zip 2>&1 | head
echo "-- E16: flowinfo content now --"
for f in recorded_info/*flowinfo.json; do echo "  $f : $(wc -c < "$f") bytes, $(wc -l < "$f") lines"; head -c 400 "$f"; echo; done 2>/dev/null | head -12
echo
echo "=== p4 build ==="
date +%H:%M
grep -c P4_INSTALL_FINISHED ~/logs/06a_p4.log
tail -1 ~/logs/06a_p4.log | head -c 150; echo
