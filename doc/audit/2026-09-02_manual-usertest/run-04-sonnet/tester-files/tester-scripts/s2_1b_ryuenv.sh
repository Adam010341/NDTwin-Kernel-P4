#!/bin/bash
exec > ~/logs/s2_1b_ryuenv.log 2>&1
set -x
date +%H:%M
source ~/miniconda3/etc/profile.d/conda.sh
conda --version
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
conda create -n ryu-env python=3.8 -y
conda activate ryu-env
echo "ACTIVATED, checking python version:"
python --version
which python
echo "CONDA_DEFAULT_ENV=$CONDA_DEFAULT_ENV"
date +%H:%M
