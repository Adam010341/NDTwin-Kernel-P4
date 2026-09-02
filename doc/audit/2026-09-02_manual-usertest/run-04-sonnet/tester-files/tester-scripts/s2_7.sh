#!/bin/bash
exec > ~/logs/s2_7.log 2>&1
set -x
date +%H:%M
source ~/miniconda3/etc/profile.d/conda.sh
conda activate ryu-env
python --version
pip install -U networkx
pip install -U "requests<2.29" "urllib3<2"
pip list | grep -E "networkx|requests|urllib3"
date +%H:%M
echo STEP_2_7_DONE
