#!/bin/bash
# run-03 tester bootstrap
mkdir -p ~/logs
cd ~
if [ ! -f ~/JOURNAL.md ]; then
cat > ~/JOURNAL.md <<'HDR'
# NDTwin install + use journal (run-03)

Tester: graduate student, first contact with NDTwin.
Machine: fresh Ubuntu 24.04 VM, user `ndt`, passwordless sudo.
Docs: ~/ndtwin-docs (website commit bcf98f5).
Working over ssh, no desktop, no browser.

HDR
fi
touch ~/BUGS.md ~/CHECKLIST.md
echo "--- date ---"; date
echo "--- section 1: system requirements check ---"
lsb_release -d
uname -m
echo "-- sudo --"; sudo -n true && echo "sudo works (passwordless)"
echo "-- Desktop dir? --"; ls -ld ~/Desktop 2>&1
echo "-- disk free --"; df -h / | tail -1
echo "-- internet? --"; curl -fsS -o /dev/null -w 'github.com -> %{http_code}\n' https://github.com 2>&1
curl -fsS -o /dev/null -w 'repo.anaconda.com -> %{http_code}\n' https://repo.anaconda.com/miniconda/ 2>&1
echo "-- existing conda? --"; which conda 2>&1; ls -d ~/miniconda3 2>&1
echo "-- python3 --"; python3 --version
echo "-- gcc --"; gcc --version | head -1
