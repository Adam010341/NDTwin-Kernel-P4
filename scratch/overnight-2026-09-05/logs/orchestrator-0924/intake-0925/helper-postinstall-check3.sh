#!/usr/bin/env bash
# helper-postinstall-check3.sh -- judge's post-install check 3: on NDTwin's own fabric,
# `ndtwin-lab heartbeat start` must refuse (rc 1) and name ndtwin_switch.json.
# claim -> up p4 4 -> start (want 1) -> status (want 3) -> down -> release.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
export NDT_OWNER=orch-0924
NDT=/home/adam/.local/bin/ndt
H=/usr/local/sbin/ndtwin-lab
step() { echo; echo "## $* ($(date +%T))"; }
echo "# HEAD $(git rev-parse HEAD) helper $(sha256sum $H | cut -d' ' -f1) $(date -Is)"
step "claim 20"; $NDT claim 20 "helper post-install check 3: heartbeat start must refuse on NDTwin's fabric"; c=$?; echo "# rc=$c"
(( c == 0 )) || { echo "ABORT: claim refused"; exit 2; }
step "up p4 4"; $NDT up p4 4; u=$?; echo "# rc=$u"
if (( u == 0 )); then
  step "check 3: heartbeat start on NDTwin's fabric (want rc 1, names ndtwin_switch.json)"; sudo -n $H heartbeat start; echo "# rc=$?"
  step "heartbeat status (want rc 3)"; sudo -n $H heartbeat status; echo "# rc=$?"
fi
step "down"; $NDT down; echo "# rc=$?"
step "release"; $NDT release; echo "# rc=$?"
step "status after"; $NDT status 2>&1 | sed -n 1,8p
echo DONE
