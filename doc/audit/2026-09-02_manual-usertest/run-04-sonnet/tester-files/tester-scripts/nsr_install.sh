#!/bin/bash
LOG=~/logs/nsr_install.log
{
set -x
date +%H:%M
cd ~
git clone https://github.com/ndtwin-lab/Network-State-Recorder.git
cd Network-State-Recorder
python3 -m venv ~/nsr-env
source ~/nsr-env/bin/activate
pip install nornir loguru orjson requests
chmod +x start_network_state_recorder.sh stop_network_state_recorder.sh
ls -l start_network_state_recorder.sh stop_network_state_recorder.sh
cat NSR.yaml
echo "---recorder_setting---"
cat setting/recorder_setting.yaml
date +%H:%M
echo NSR_INSTALL_DONE
} > "$LOG" 2>&1
cat "$LOG"
