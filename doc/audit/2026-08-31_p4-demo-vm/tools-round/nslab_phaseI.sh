#!/bin/bash
# H-26 phase I host side: close the autostart hole, reboot, and inventory EVERY listener cold.
# Then trim and power off, leaving a disk ready to repack.
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

echo "=== $(date -Is) phase I against vm pid $P ==="
scp -P 2296 $CO /home/nslab/guest_phaseI.sh $G:/home/tester/ || exit 1
S 'chmod +x /home/tester/guest_phaseI.sh && /home/tester/guest_phaseI.sh' 2>&1

echo
echo "=== reboot #2, and this time inventory EVERYTHING, not just the three ports I had in mind ==="
S 'sudo -n systemctl reboot' >/dev/null 2>&1
sleep 25
up=0
for i in $(seq 1 30); do S 'echo up' 2>/dev/null | grep -q up && { up=1; break; }; sleep 10; done
[ "$up" = 1 ] || { echo "🔴 guest did not come back"; exit 1; }
echo "guest back; qemu pid still $P and alive: $(kill -0 "$P" 2>/dev/null && echo yes || echo NO)"

echo
echo "############ COLD-BOOT LISTENER TABLE -- the whole thing ############"
S 'uptime | tr -s " "; sudo -n ss -tulnp' 2>&1 | sed 's/^/  /'
echo
echo "############ the specific ports this round could have opened ############"
S 'for p in 111 2049 8000 8001 8002 9000 20048; do printf "  :%-6s %s\n" "$p" "$(ss -tulnH | grep -c ":$p ")"; done
   echo "  nfs-server: enabled=$(systemctl is-enabled nfs-server 2>&1) active=$(systemctl is-active nfs-server 2>&1)"
   echo "  rpcbind:    enabled=$(systemctl is-enabled rpcbind.socket 2>&1) active=$(systemctl is-active rpcbind.socket 2>&1)"'

echo
echo "############ and it must STILL work on demand after a cold boot ############"
S 'sudo -n systemctl start ndtwin-spm; sleep 10
   echo "  ndtwin-spm active=$(systemctl is-active ndtwin-spm) :9000=$(ss -tlnH | grep -c ":9000")"
   sudo -n systemctl stop ndtwin-spm; sleep 2
   sudo -n umount /mnt/nfs/sim /mnt/nfs/app 2>/dev/null
   sudo -n systemctl stop nfs-server nfs-mountd rpcbind.socket rpcbind.service 2>/dev/null
   echo "  after stopping again, :9000=$(ss -tlnH | grep -c ":9000") :2049=$(ss -tulnH | grep -c ":2049")"'

echo
echo "############ final trim, then power off cleanly ############"
S 'rm -f /home/tester/phase*.out /home/tester/guest_*.sh /tmp/*.out 2>/dev/null
   sudo -n apt-get clean; sudo -n journalctl --rotate --vacuum-time=1s >/dev/null 2>&1
   sudo -n fstrim -av 2>&1 | head -4; sync'
sleep 3
S 'sudo -n poweroff' >/dev/null 2>&1
for i in $(seq 1 24); do kill -0 "$P" 2>/dev/null || break; sleep 5; done
if kill -0 "$P" 2>/dev/null; then
  echo "🔴 qemu $P still alive after poweroff -- NOT killing it blindly; look before acting"
else
  echo "qemu $P exited cleanly after $((i*5))s"
fi
echo "overlay final: $(stat -c%s "$W/work.qcow2") bytes apparent, $(du -sh "$W/work.qcow2" | cut -f1) on disk"
rm -f "$W/.ask"
echo "PHASE_I_HOST_DONE"
