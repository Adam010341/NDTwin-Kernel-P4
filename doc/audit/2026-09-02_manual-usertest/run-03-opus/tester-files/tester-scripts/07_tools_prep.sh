#!/bin/bash
date +%H:%M
cd ~
echo "############ E01: clone Network-State-Recorder ############"
git clone https://github.com/ndtwin-lab/Network-State-Recorder.git 2>&1 | tail -3
cd ~/Network-State-Recorder && git log -1 --format='%h %ci %s'
echo "--- files ---"; ls
echo "############ E03: does a bare pip really fail on 24.04? (manual's claim) ############"
pip install loguru 2>&1 | tail -4
echo "############ E02: venv ~/nsr-env ############"
cd ~
python3 -m venv ~/nsr-env
source ~/nsr-env/bin/activate
python --version
pip install -q --upgrade pip 2>&1 | tail -2
pip install nornir loguru orjson requests 2>&1 | tail -3
pip list 2>/dev/null | grep -Ei "^(nornir|loguru|orjson|requests) "
deactivate
echo "############ E04: what interpreter is written INSIDE start_network_state_recorder.sh? ############"
cat ~/Network-State-Recorder/start_network_state_recorder.sh
echo "--- and the stop script ---"
cat ~/Network-State-Recorder/stop_network_state_recorder.sh
echo "############ E05: chmod +x ############"
cd ~/Network-State-Recorder
chmod +x start_network_state_recorder.sh stop_network_state_recorder.sh
ls -l *.sh
echo "############ E06: recorder_setting.yaml as shipped ############"
cat setting/recorder_setting.yaml 2>&1
echo "--- NSR.yaml ---"
cat NSR.yaml 2>&1
date +%H:%M
