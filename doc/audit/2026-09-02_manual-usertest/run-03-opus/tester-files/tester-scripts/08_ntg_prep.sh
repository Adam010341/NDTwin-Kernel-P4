#!/bin/bash
date +%H:%M
cd ~
echo "############ F02: clone NTG ############"
git clone https://github.com/ndtwin-lab/Network-Traffic-Generator.git 2>&1 | tail -2
cd ~/Network-Traffic-Generator && git log -1 --format='%h %ci %s'
echo "--- files (compare with manual's Files Overview) ---"; ls -a
echo "############ F01: venv ~/ntg-env + the 9 packages ############"
cd ~
python3 -m venv ~/ntg-env
source ~/ntg-env/bin/activate
pip install -q --upgrade pip 2>&1 | tail -1
pip install loguru prompt_toolkit nornir nornir-utils pyyaml numpy pandas paramiko requests pydantic 2>&1 | tail -3
pip list 2>/dev/null | grep -Ei "^(loguru|prompt_toolkit|nornir|nornir-utils|PyYAML|numpy|pandas|paramiko|requests|pydantic) "
deactivate
echo "############ F03/F04: shipped NTG.yaml + setting/Mininet.yaml ############"
cd ~/Network-Traffic-Generator
echo "--- NTG.yaml ---"; cat NTG.yaml
echo "--- setting/Mininet.yaml ---"; cat setting/Mininet.yaml
echo "--- flow_template.json (first 40 lines) ---"; head -40 flow_template.json
echo "############ F06: manual claim -- `python` is not a command ############"
python network_traffic_generator.py 2>&1 | head -2
echo "############ F07: manual claim -- sudo ./testbed_topo.py -> ModuleNotFoundError loguru ############"
cd ~/Network-Traffic-Generator && sudo ./testbed_topo.py 2>&1 | head -5
date +%H:%M
