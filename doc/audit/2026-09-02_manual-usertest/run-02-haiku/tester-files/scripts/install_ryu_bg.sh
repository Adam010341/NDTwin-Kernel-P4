#!/bin/bash
set -e
source ~/miniconda3/etc/profile.d/conda.sh
conda activate ryu-env

echo "Starting Ryu installation at $(date)" >> ~/logs/ryu_install.log

sudo apt update >> ~/logs/ryu_install.log 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential python3-dev libssl-dev libffi-dev libxml2-dev libxslt1-dev >> ~/logs/ryu_install.log 2>&1

pip install --upgrade "pip<24" "setuptools<68" wheel >> ~/logs/ryu_install.log 2>&1
pip install ryu >> ~/logs/ryu_install.log 2>&1
pip install eventlet==0.30.2 >> ~/logs/ryu_install.log 2>&1
pip install "greenlet<3" >> ~/logs/ryu_install.log 2>&1
pip install "dnspython<2.3" >> ~/logs/ryu_install.log 2>&1

echo "Ryu packages installed, checking installation" >> ~/logs/ryu_install.log
pip list | grep -E "eventlet|greenlet|dnspython|ryu" >> ~/logs/ryu_install.log 2>&1

pip install -U networkx >> ~/logs/ryu_install.log 2>&1
pip install -U "requests<2.29" "urllib3<2" >> ~/logs/ryu_install.log 2>&1

echo "Ryu installation complete at $(date)" >> ~/logs/ryu_install.log
conda deactivate
