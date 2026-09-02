#!/bin/bash
exec > ~/logs/s2_1_miniconda.log 2>&1
set -x
date +%H:%M
mkdir -p ~/miniconda3
curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
    -o ~/miniconda3/miniconda.sh
ls -la ~/miniconda3/miniconda.sh
bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3
rm ~/miniconda3/miniconda.sh
echo "MINICONDA_INSTALL_EXIT=$?"
date +%H:%M
ls ~/miniconda3/bin/conda && echo "CONDA BINARY EXISTS"
