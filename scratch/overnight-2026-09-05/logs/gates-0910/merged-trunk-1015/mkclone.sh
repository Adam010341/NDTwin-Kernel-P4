#!/usr/bin/env bash
# mkclone.sh <dir> <rev> [p4build.log] : the gate clone of the shared repo at <rev>, detached; the venv and the C++ build dir linked
# (as p4-health-locale/r3/mkclone.sh did); the P4 build made (p4-ternary-replay-c/r2/p4build.log line 2).
# [Co-developed with claude code -- Adam]
set -e
R=/home/adam/Desktop/NDTwin-Kernel
d="$1"; rev="$2"; log="${3:-/dev/null}"
git clone -q --no-hardlinks "$R" "$d"
cd "$d"
git checkout -q --detach "$rev"
ln -s "$R/p4_proxy/venv" p4_proxy/venv
ln -s "$R/build" build
mkdir -p p4_proxy/p4_src/build
{ echo "commit $(git rev-parse HEAD)"
  echo "command: p4c-bm2-ss --arch v1model -o p4_proxy/p4_src/build/ndtwin_switch.json --p4runtime-files p4_proxy/p4_src/build/ndtwin_switch.p4info.txt p4_proxy/p4_src/ndtwin_switch.p4"
  p4c-bm2-ss --version 2>&1
  rc=0
  p4c-bm2-ss --arch v1model -o p4_proxy/p4_src/build/ndtwin_switch.json --p4runtime-files p4_proxy/p4_src/build/ndtwin_switch.p4info.txt p4_proxy/p4_src/ndtwin_switch.p4 2>&1 || rc=$?
  echo "rc=$rc"; } > "$log"
echo "clone $d at $(git rev-parse HEAD)"
tail -1 "$log" | grep -qx 'rc=0'
