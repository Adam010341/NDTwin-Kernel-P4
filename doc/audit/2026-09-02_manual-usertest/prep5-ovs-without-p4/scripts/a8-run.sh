#!/bin/bash
# Helper that lives on nslab: push a script into the prep5 guest and run it, teeing to ~/a8-logs/ in the guest.
# usage: a8-run.sh /tmp/a8_NN_name.sh NN_name.log [timeout_seconds]
# [Co-developed with claude code -- Adam]
S="$1"; L="$2"; T="${3:-600}"
B=$(basename "$S")
O="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"
scp $O -P 2301 "$S" ndt@127.0.0.1:/tmp/"$B" || { echo "SCP_FAILED"; exit 1; }
ssh $O -o ServerAliveInterval=15 -o ServerAliveCountMax=$((T/15+4)) -p 2301 ndt@127.0.0.1 \
  "mkdir -p ~/a8-logs && bash /tmp/$B 2>&1 | tee ~/a8-logs/$L" < /dev/null
echo "RUNNER_SSH_EXIT=$?"
