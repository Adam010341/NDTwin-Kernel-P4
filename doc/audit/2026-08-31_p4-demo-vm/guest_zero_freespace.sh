#!/bin/bash
# Overwrite free space, because fstrim did not finish the job.
#
# After deleting .git and running `fstrim -av`, 11 of 12 packfile samples were gone from
# the rebuilt image but `packed-refs` survived at a byte offset -- so discard reached most
# of the freed extents and not all of them. "Mostly overwritten" is not a property worth
# shipping, and the next check would have to argue about which surviving bytes matter.
# Writing zeros over the free space removes the argument.
#
# First: find out whether the survivor is free-space residue or a live file. If some log
# or backup still references it, zeroing free space would not touch it and the re-scan
# would come back dirty with no explanation.
#
# [Co-developed with claude code -- Adam]
set -u

echo "=== 1. is the survivor in a LIVE file? ==="
echo "  searching for the packed-refs sha 8034783f3964b364f4"
sudo grep -rl '8034783f3964b364f4' / --exclude-dir=/proc --exclude-dir=/sys \
     --exclude-dir=/dev 2>/dev/null | head -10
echo "  (empty above = not in any live file, i.e. it is free-space residue)"

echo
echo "=== 2. also check for any surviving .git ==="
sudo find / -xdev -name '.git' 2>/dev/null | wc -l

echo
echo "=== 3. before ==="
df -h / | tail -1

echo
echo "=== 4. overwrite free space with zeros ==="
# ENOSPC is the expected exit here, not a failure: the point is to fill it.
sudo dd if=/dev/zero of=/zerofill bs=1M status=none 2>/dev/null
echo "  zerofill grew to $(sudo stat -c%s /zerofill 2>/dev/null) bytes"
sync
sudo rm -f /zerofill
sync
# and the smaller filesystems, which have their own free space
for m in /boot /boot/efi; do
  sudo dd if=/dev/zero of="$m/.zf" bs=1M status=none 2>/dev/null
  sudo rm -f "$m/.zf"
done
sync

echo
echo "=== 5. discard, so the zeros become holes rather than 50 GB of stored zeros ==="
sudo fstrim -av 2>&1

echo
echo "=== 6. after ==="
df -h / | tail -1
sync
echo "=== ZEROFILL_DONE ==="
