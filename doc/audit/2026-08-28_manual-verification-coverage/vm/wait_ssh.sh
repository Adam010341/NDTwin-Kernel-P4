#!/bin/bash
# Block until the test VM answers SSH, or give up. Reports which it was.
#
# In a script file so the retry loop's argv cannot collide with anything the host is
# matching on, and so the wait is repeatable. [Co-developed with claude code -- Adam]
set -u
PORT=2222
USER=tester
DEADLINE="${1:-180}"

waited=0
while (( waited < DEADLINE )); do
    if ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=3 -o BatchMode=yes "$USER@localhost" true 2>/dev/null; then
        echo "SSH UP after ${waited}s"
        exit 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
done
echo "SSH DID NOT COME UP within ${DEADLINE}s"
exit 1
