#!/bin/bash
date +%H:%M
cd ~/Desktop/NDTwin-Kernel/build
echo "############ B15: no TTY + missing flags -> usage message, not block ############"
sudo ./bin/ndtwin_kernel < /dev/null 2>&1 | head -8
echo "B15_EXIT=${PIPESTATUS[0]}"
echo "############ B15b: piped output + missing flags ############"
sudo ./bin/ndtwin_kernel 2>&1 < /dev/null | cat | head -5
echo "############ B16: --ai with no OPENAI_API_KEY ############"
sudo ./bin/ndtwin_kernel --mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --ai --loglevel info < /dev/null 2>&1 | head -12
echo "############ bad flag value ############"
sudo ./bin/ndtwin_kernel --mode banana --no-ai < /dev/null 2>&1 | head -5
echo "############ nonexistent topology file ############"
sudo ./bin/ndtwin_kernel --mode mininet --topology ../setting/NOPE.json --no-ai < /dev/null 2>&1 | head -8
echo "############ J06: API while kernel not running ############"
curl -sS -m 5 -X GET http://localhost:8000/ndt/get_graph_data 2>&1 | head -3
echo "CURL_EXIT=$?"
echo "############ B01: ndt launcher present? ############"
ls -l ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt 2>&1
mkdir -p ~/.local/bin
ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
ls -l ~/.local/bin/ndt
echo "--- is ~/.local/bin on PATH? ---"; echo "$PATH" | tr ':' '\n' | grep -c "$HOME/.local/bin"
echo "--- ndt with no args ---"
~/.local/bin/ndt 2>&1 | head -30
date +%H:%M
