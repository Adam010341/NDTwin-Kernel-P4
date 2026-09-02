# nslab-side: fetch /tmp/run03-guest.tgz out of guest 2313 into nslab /tmp. [Co-developed with claude code -- Adam]
set -u
O="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"
scp $O -P 2313 ndt@127.0.0.1:/tmp/run03-guest.tgz /tmp/run03-guest.tgz
ls -l /tmp/run03-guest.tgz; md5sum /tmp/run03-guest.tgz
