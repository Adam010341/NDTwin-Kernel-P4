#!/bin/bash
# H-26 phase H host side: strip, reboot, prove the reboot claim, T-2 regression, trim.
#
# THE REBOOT IS PART OF THE TEST, NOT A CHORE. Phase G asserted the units are "installed but not
# enabled". That claim is about what happens at the NEXT boot, and until a boot happens it is a
# claim about `systemctl is-enabled` output, not about the image. So the image is rebooted and
# the ports are read again from a cold start.
#
# The qemu process is NOT restarted -- a guest reboot keeps pid 60778, so the working point
# registered in the ledger (4 vCPU / 6144 MB / cores 24-27) stays exactly what was declared.
#
# T-2 IS RUN WITH THE SAME DRIVER AS THE BASELINE, /home/nslab/guest_t2_run.sh from 19:22,
# untouched. A regression run with a different driver cannot tell a changed image from a
# changed harness.
#
# [Co-developed with claude code -- Adam]
set -u
W=/home/nslab/addtools
P=$(cat "$W/vm.pid" 2>/dev/null)
kill -0 "$P" 2>/dev/null || { echo "VM $P not running -- stop"; exit 1; }
printf '#!/bin/sh\necho tester\n' > "$W/.ask"; chmod 700 "$W/.ask"
export SSH_ASKPASS="$W/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
G="tester@127.0.0.1"
S(){ ssh -p 2296 $CO $G "$@"; }

echo "=== $(date -Is) phase H against running vm pid $P ==="
echo "overlay before: $(stat -c%s "$W/work.qcow2") bytes"

scp -P 2296 $CO /home/nslab/guest_phaseH.sh /home/nslab/guest_t2_run.sh $G:/home/tester/ || exit 1
S 'chmod +x /home/tester/guest_phaseH.sh /home/tester/guest_t2_run.sh && /home/tester/guest_phaseH.sh' 2>&1

echo
echo "=== reboot the guest (qemu pid stays $P, so the registered working point does not change) ==="
S 'sudo -n systemctl reboot' >/dev/null 2>&1
sleep 25
up=0
for i in $(seq 1 30); do
  S 'echo up' 2>/dev/null | grep -q up && { up=1; break; }
  sleep 10
done
[ "$up" = 1 ] || { echo "🔴 guest did not come back after reboot"; exit 1; }
echo "guest back after ~$((25 + i*10))s; qemu pid still $(cat "$W/vm.pid") and alive: $(kill -0 "$P" 2>/dev/null && echo yes || echo NO)"

echo
echo "############ the claim under test: a cold boot opens nothing ############"
S 'uptime | tr -s " "; echo "  listeners on 8001/8002/9000: $(ss -tlnH | grep -cE ":(8001|8002|9000) ")  (expect 0)"
   echo "  nfs-server after reboot: $(systemctl is-active nfs-server)"
   for u in ndtwin-esa ndtwin-spm ndtwin-reqmgr; do printf "  %-18s enabled=%s active=%s\n" "$u" "$(systemctl is-enabled $u 2>&1)" "$(systemctl is-active $u 2>&1)"; done
   echo "  and it still starts on request:"; sudo -n systemctl start ndtwin-esa; sleep 8
   echo "    ndtwin-esa active=$(systemctl is-active ndtwin-esa) :8001=$(ss -tlnH | grep -c ":8001")"
   sudo -n systemctl stop ndtwin-esa; sudo -n umount /mnt/nfs/sim /mnt/nfs/app 2>/dev/null; true'

echo
echo "############ T-2 regression, same driver as the 19:23 baseline ############"
S 'setsid bash -c "/home/tester/guest_t2_run.sh > /home/tester/t2run.log 2>&1" < /dev/null > /dev/null 2>&1 & sleep 3; echo launched'
for i in $(seq 1 90); do
  sleep 20
  S 'grep -qE "T-2 (done|finished)|=== summary|failures:" /home/tester/t2run.log 2>/dev/null' 2>/dev/null && { echo "T-2 reached its summary after $((i*20))s"; break; }
done
S 'cat /home/tester/t2run.log' 2>/dev/null

echo
echo "############ THE FOUR NUMBERS (compare against: 10 switches / 12 paths / 40 edges / 0% dropped 12/12 / failures: 1) ############"
S 'grep -iE "links|edges|paths|switches|Results:|dropped|failures|PASS:|FAIL:" /home/tester/t2run.log' 2>/dev/null

echo
echo "############ trim: discard=unmap is on the drive, so fstrim should shrink the overlay ############"
S 'rm -f /home/tester/t2run.log /home/tester/phase*.out /home/tester/phase*.drv /home/tester/guest_*.sh /home/tester/ntv-windowstate-workaround.patch /home/tester/README-NDTwin-tools.md /home/tester/99-ndtwin-tools /tmp/*.out 2>/dev/null
   sudo -n fstrim -av 2>&1 | head -4; sync'
sleep 5
echo "overlay after fstrim: $(stat -c%s "$W/work.qcow2") bytes (apparent), $(du -sh "$W/work.qcow2" | cut -f1) on disk"

echo
echo "=== leaving the VM UP; nothing has been powered off ==="
