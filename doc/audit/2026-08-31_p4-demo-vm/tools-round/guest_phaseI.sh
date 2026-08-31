#!/bin/bash
# H-26 phase I: close a hole I opened, and check the thing I should have checked the first time.
#
# 🔴 WHAT I GOT WRONG. Phase D ran `systemctl enable --now nfs-server` -- the `enable` was not
#    needed for anything, it was reflex. So the image boots with an NFS server and rpcbind
#    listening, on whatever network the recipient puts it on. The README I wrote in the same
#    round says this image "does not open ports without you saying so". Both were mine, three
#    hours apart, and the document was the one telling the truth about what I intended.
#
# 🔑 HOW IT SURFACED, because that is the reusable part. The phase H check asked "are 8001,
#    8002 and 9000 closed after a cold boot?" -- the three ports I had been thinking about --
#    and they were. It printed `nfs-server: active` only because I had put that line in beside
#    it as background. The question that had discriminating power was not "are my ports shut"
#    but "what is this image listening on at all", and I had not asked it.
#    ⇒ This phase asks the second question: the whole listener table, cold, with every row
#      attributed to either the original image or to this round.
#
# THE FIX IS `disable`, NOT `mask` OR `remove`. ndtwin-nfs-up starts nfs-server on demand, so
# the two apps still work; removing the packages would break them, and masking would make the
# helper fail in a way the README does not describe.
#
# [Co-developed with claude code -- Adam]
LOG=/home/tester/phaseI.out
exec > >(tee -a "$LOG") 2>&1
OK=0; BAD=0
ok(){ echo "  PASS: $*"; OK=$((OK+1)); }
bad(){ echo "  FAIL: $*"; BAD=$((BAD+1)); }

echo "=== phase I started $(date -Is) ==="

echo
echo "############ 1. the whole listener table as it stands now (the question I skipped) ############"
sudo -n ss -tulnp 2>/dev/null | sed 's/^/  /'

echo
echo "############ 2. stop auto-start for everything this round turned on ############"
for u in nfs-server nfs-mountd rpcbind.service rpcbind.socket rpc-statd; do
  before=$(systemctl is-enabled "$u" 2>&1)
  sudo -n systemctl disable "$u" >/dev/null 2>&1
  after=$(systemctl is-enabled "$u" 2>&1)
  printf '  %-18s %s -> %s\n' "$u" "$before" "$after"
done
sudo -n systemctl stop nfs-server nfs-mountd rpc-statd >/dev/null 2>&1
sudo -n systemctl stop rpcbind.socket rpcbind.service >/dev/null 2>&1

echo
echo "############ 3. ndtwin-nfs-up must still work with them disabled -- otherwise the README lies ############"
if sudo -n /usr/local/sbin/ndtwin-nfs-up; then
  ok "ndtwin-nfs-up still brings NFS up on demand after disabling autostart"
  mountpoint -q /mnt/nfs/sim && mountpoint -q /mnt/nfs/app && ok "both mounts are live" || bad "mounts not live"
else
  bad "ndtwin-nfs-up FAILED with autostart disabled -- disable was the wrong fix"
fi
sudo -n systemctl start ndtwin-esa; sleep 8
if systemctl is-active --quiet ndtwin-esa && ss -tlnH | grep -q ':8001'; then
  ok "ndtwin-esa still starts and serves :8001 through the disabled path"
else
  bad "ndtwin-esa broken after disabling nfs autostart"; sudo -n journalctl -u ndtwin-esa -n 6 --no-pager | sed 's/^/    /'
fi
sudo -n systemctl stop ndtwin-esa
sudo -n umount /mnt/nfs/sim /mnt/nfs/app 2>/dev/null
sudo -n systemctl stop nfs-server nfs-mountd >/dev/null 2>&1
sudo -n systemctl stop rpcbind.socket rpcbind.service >/dev/null 2>&1
echo "PHASE_I_DONE"
