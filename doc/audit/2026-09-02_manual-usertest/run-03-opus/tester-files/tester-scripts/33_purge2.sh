#!/bin/bash
B=http://localhost:8000
n(){ curl -sS $B/ndt/get_detected_flow_data | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null; }
echo "baseline records: $(n)"
echo "-- 10-second burst h1 -> h50 --"
tmux send-keys -t MN 'h50 iperf3 -s -p 5401 &' Enter
sleep 2
tmux send-keys -t MN 'h1 iperf3 -c h50 -p 5401 -t 10 &' Enter
sleep 6
echo "during burst: $(n) records   $(date +%H:%M:%S)"
echo "-- waiting for the 10s transfer to end --"
sleep 8
END=$(date +%s); echo "transfer ended about $(date +%H:%M:%S)"
for i in $(seq 1 20); do
  c=$(n); now=$(date +%s)
  echo "  t+$((now-END))s after last packet : $c records"
  if [ "$c" = "0" ]; then echo "  -> purged between t+$(( now-END-2 ))s and t+$((now-END))s"; break; fi
  sleep 2
done
echo
echo "########## NSR end to end (E07-E16) ##########"
cd ~/Network-State-Recorder
echo "-- E06: config as shipped --"; grep -E "ndtwin_kernel|display_on_console|request_interval|storage_interval" setting/recorder_setting.yaml
echo "-- E07: the manual's Option 1, background mode --"
./start_network_state_recorder.sh
echo "START_SCRIPT_EXIT=$?"
sleep 8
echo "-- E08: did it flip display_on_console to false? --"
grep display_on_console setting/recorder_setting.yaml
echo "-- E10: the manual's status check --"
pgrep -af network_state_recorder.py || echo "   (NO MATCH -- nothing running)"
echo "-- E13/E15: did any data or log appear? --"
ls -la recorded_info/ 2>&1 | head -6
ls -la logs/ 2>&1 | head -6
echo "-- what did nohup capture? --"
tail -12 nohup.out 2>&1
date +%H:%M:%S
