#!/bin/bash
LOG=~/logs/webgui_docker_install.log
{
set -x
date +%H:%M
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "--- literal transcription of the manual's next line, which chmods docker.asc, not docker.gpg -- testing whether this is a real bug ---"
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "CHMOD_ASC_EXIT=$?"
ls -la /etc/apt/keyrings/
echo "--- effective permissions on the file the manual actually created ---"
stat -c "%a %U:%G %n" /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo groupadd docker 2>&1 || echo "docker group already exists"
sudo usermod -aG docker $USER
sudo systemctl start docker
sudo systemctl enable docker
docker --version
docker compose version
date +%H:%M
echo WEBGUI_DOCKER_INSTALL_DONE
} > "$LOG" 2>&1
cat "$LOG"
