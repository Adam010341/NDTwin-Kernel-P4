#!/bin/bash
# Helper on nslab: pull everything in the guest's ~/a8-logs/ down to nslab:~/a8-logs-prep5/
# [Co-developed with claude code -- Adam]
O="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"
mkdir -p "$HOME/a8-logs-prep5"
scp $O -P 2301 -r ndt@127.0.0.1:'~/a8-logs/*' "$HOME/a8-logs-prep5/" 2>&1
echo "PULL_EXIT=$?"
ls -la "$HOME/a8-logs-prep5/"
echo "--- sha256 on the nslab side ---"
sha256sum "$HOME/a8-logs-prep5/"* 2>/dev/null
