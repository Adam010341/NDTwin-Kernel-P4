#!/bin/bash
LOG=~/logs/trafficvis_install.log
{
set -x
date +%H:%M
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y openjdk-21-jdk xvfb
java -version
cd ~
git clone https://github.com/ndtwin-lab/Network-Traffic-Visualizer.git
cd Network-Traffic-Visualizer
git checkout b5e039c
chmod +x ./mvnw ./network_traffic_visualizer.sh 2>&1
./mvnw -version
./mvnw clean package
echo "MVN_EXIT=$?"
ls -la target/*.jar
date +%H:%M
echo TRAFFICVIS_INSTALL_DONE
} > "$LOG" 2>&1
cat "$LOG"
