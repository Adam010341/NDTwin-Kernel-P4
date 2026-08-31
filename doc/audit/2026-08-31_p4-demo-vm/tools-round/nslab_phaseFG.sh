#!/bin/bash
# H-26 phases F+G host side. The VM is already running (adopted, pid in addtools/vm.pid), so
# this only pushes work into it -- it does not boot anything and does not change the working
# point that is registered in the ledger.
#
# [Co-developed with claude code -- Adam]
set -u
W=/home/nslab/addtools
P=$(cat "$W/vm.pid" 2>/dev/null)
kill -0 "$P" 2>/dev/null || { echo "VM $P is not running -- stop, do not boot a second one"; exit 1; }
echo "=== $(date -Is) working against the ALREADY-RUNNING vm pid $P ==="

printf '#!/bin/sh\necho tester\n' > "$W/.ask"; chmod 700 "$W/.ask"
export SSH_ASKPASS="$W/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
G="tester@127.0.0.1"

ssh -p 2296 $CO $G 'echo GUEST_UP' || { echo "guest ssh down"; exit 1; }

scp -P 2296 $CO /home/nslab/guest_phaseF.sh /home/nslab/guest_phaseG.sh \
      /home/nslab/ntv-windowstate-workaround.patch /home/nslab/README-NDTwin-tools.md \
      /home/nslab/99-ndtwin-tools $G:/home/tester/ || exit 1

echo
echo "=== phase F: Visualizer to main + Adam's patch ==="
ssh -p 2296 $CO $G 'chmod +x /home/tester/guest_phaseF.sh && setsid /home/tester/guest_phaseF.sh > /home/tester/phaseF.drv 2>&1 < /dev/null & echo started'
for i in $(seq 1 100); do
  ssh -p 2296 $CO $G 'grep -q PHASE_F_DONE /home/tester/phaseF.out 2>/dev/null' 2>/dev/null && break
  sleep 20
done
ssh -p 2296 $CO $G 'cat /home/tester/phaseF.out' 2>/dev/null

echo
echo "=== install README + MOTD (plain copies, no heredoc inside heredoc) ==="
ssh -p 2296 $CO $G 'set -e
  cp /home/tester/README-NDTwin-tools.md /home/tester/Desktop/README-NDTwin-tools.md
  sudo -n cp /home/tester/99-ndtwin-tools /etc/update-motd.d/99-ndtwin-tools
  sudo -n chmod 755 /etc/update-motd.d/99-ndtwin-tools
  echo "  README: $(wc -l < /home/tester/Desktop/README-NDTwin-tools.md) lines on the Desktop"
  echo "  MOTD renders as:"
  sudo -n run-parts /etc/update-motd.d/ 2>/dev/null | tail -12 | sed "s/^/    /"
'

echo
echo "=== phase G: units, exports, provenance ==="
ssh -p 2296 $CO $G 'chmod +x /home/tester/guest_phaseG.sh && setsid /home/tester/guest_phaseG.sh > /home/tester/phaseG.drv 2>&1 < /dev/null & echo started'
for i in $(seq 1 60); do
  ssh -p 2296 $CO $G 'grep -q PHASE_G_DONE /home/tester/phaseG.out 2>/dev/null' 2>/dev/null && break
  sleep 10
done
ssh -p 2296 $CO $G 'cat /home/tester/phaseG.out' 2>/dev/null

echo
echo "=== VM left UP (pid $P) ==="
df -h /home | tail -1
