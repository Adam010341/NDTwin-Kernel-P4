#!/bin/bash
LOG=~/logs/ntg_install.log
{
set -x
date +%H:%M
python3 -m venv --system-site-packages ~/ntg-env
source ~/ntg-env/bin/activate
pip install --upgrade pip
pip install loguru prompt_toolkit nornir nornir-utils pyyaml numpy pandas paramiko requests pydantic
cd ~
git clone https://github.com/ndtwin-lab/Network-Traffic-Generator.git
cd Network-Traffic-Generator
cat NTG.yaml
echo "--- setting dir ---"
ls setting/
python3 -c "import mininet; print('mininet importable from ntg-env:', mininet.__file__)"
date +%H:%M
echo NTG_INSTALL_DONE
} > "$LOG" 2>&1
cat "$LOG"
