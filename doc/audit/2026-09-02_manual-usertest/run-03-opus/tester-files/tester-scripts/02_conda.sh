#!/bin/bash
# Section 2 prerequisite + 2.1 : Miniconda and ryu-env
set -x
date +%H:%M
mkdir -p ~/miniconda3
curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
    -o ~/miniconda3/miniconda.sh
bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3
rm ~/miniconda3/miniconda.sh
echo "=== 2.1 make conda usable ==="
source ~/miniconda3/etc/profile.d/conda.sh
conda --version
echo "=== accept ToS ==="
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
echo "=== create ryu-env ==="
conda create -n ryu-env python=3.8 -y
conda activate ryu-env
python --version
date +%H:%M
