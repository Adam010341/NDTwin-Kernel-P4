#!/bin/bash
LOG=~/logs/webgui_deploy.log
{
set -x
date +%H:%M
cd ~
git clone https://github.com/ndtwin-lab/Web-GUI.git
cd Web-GUI
ls -la
cp .env.example .env
echo "--- original .env ---"
cat .env
sed -i 's#^NDT_API_BASE_URL=.*#NDT_API_BASE_URL=http://127.0.0.1:8000#' .env
echo "--- edited .env ---"
cat .env
chmod +x web_gui_deploy.sh
./web_gui_deploy.sh
echo "DEPLOY_EXIT=$?"
date +%H:%M
echo WEBGUI_DEPLOY_DONE
} > "$LOG" 2>&1
echo "launched"
