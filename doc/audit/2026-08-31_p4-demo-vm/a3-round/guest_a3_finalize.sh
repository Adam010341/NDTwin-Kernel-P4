#!/bin/bash
# ============================================================================================
# A-3 step 5a (in-guest): remove this round working files, then reclaim free space.
#
# 🔴 THIS FILE EXISTS BECAUSE THE ONE-LINER VERSION OF IT RAN ON THE WRONG MACHINE.
#    It was passed to ssh inside a single-quoted argument, and a comment in the body
#    contained an apostrophe. That apostrophe closed the quote, so everything after it was
#    executed by the LOCAL shell instead of the guest: it walked the local process table,
#    deleted the local ~/.bash_history, and attempted `sudo mn -c` and `systemctl stop`
#    against another session live BMv2 fabric. Only the absence of passwordless sudo on that
#    host stopped it. The repo already records this lesson once -- "bracket expressions do not
#    survive three levels of shell quoting; a script file does" -- and this is the same lesson
#    with a bigger blast radius. Write the file, copy the file, run the file.
#
# The zero-fill is not decoration. The official 17.9 GB build is what happens when the
# discard step is skipped: freed extents keep their old contents, the vmdk stores them, and
# the user downloads gigabytes of deleted files. fstrim alone was measured in H-26 to leave
# residue at some offsets, so zeros go down first and fstrim turns them into holes.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
set -u
echo "=== A-3 finalize $(date -Is) on $(hostname) as $(whoami) ==="

# --- refuse to run anywhere but the guest -------------------------------------------------
if [ ! -d /home/tester/Desktop/NDTwin-Kernel ]; then
    echo "REFUSING: this is not the demo guest (no /home/tester/Desktop/NDTwin-Kernel)"
    exit 1
fi
if [ "$(whoami)" != "tester" ]; then
    echo "REFUSING: expected to run as tester, am $(whoami)"
    exit 1
fi
echo "  guard passed: running as tester inside the demo guest"
cd /home/tester || exit 1

echo
echo "--- files this round added to the guest, being removed ---"
for f in guest_a3_step1.sh guest_a3_step1b.sh guest_a3_step1c.sh guest_a3_step23.sh \
         guest_a3_step3b.sh guest_a3_step3c.sh check_docrefs.sh check_docrefs2.sh \
         a3_step1.log a3_step1b.log a3_step1c.log a3_step23.log a3_step3b.log a3_step3c.log \
         a3_step1_outer.log a3_step1b_outer.log a3_step1c_outer.log a3_step23_outer.log \
         a3_step3b_outer.log a3_topo.log a3_proxy.log a3_kernel.log a3b_topo.log a3b_proxy.log \
         a3b_kernel.log a3b_te.log a3c_topo.log a3c_proxy.log a3c_kernel.log a3_te.log \
         a3_ntv_build.log a3_ntv_run.log a3_ntv_mvnrun.log a3_ntv_cp_pos.log a3_b_pos.log; do
  if [ -e "$f" ]; then rm -f "$f"; echo "    removed $f"; fi
done
rm -f /tmp/kernel_eps.txt /tmp/a3_graph.json /tmp/mn_stdin_a3 /tmp/mn_stdin_a3b /tmp/mn_stdin_a3c
rm -rf /tmp/ntv-up /tmp/kpub /tmp/ntvdate
echo "--- verifying by state, not by rc ---"
echo "    my files still in /home/tester: $(ls a3_*.log guest_a3_*.sh check_docrefs*.sh 2>/dev/null | wc -l)  (want 0)"

echo
echo "--- nothing of this round should still be running IN THE GUEST ---"
found=0
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null)
  case "$c" in
    *ndtwin_kernel*|*proxy_agent*|*NDTanimation*|*Xvfb*|*p4_testbed_topo*|*simple_switch*)
      echo "    STILL RUNNING ${p#/proc/}: $(echo "$c" | cut -c1-70)"; found=1 ;;
  esac
done
[ "$found" = 0 ] && echo "    none"
echo "    listeners that should be gone:"
ss -tlnH | grep -E ":(8000|8001|8002|8081|9000)\b" | sed "s/^/      /" || echo "      none"
sudo -n systemctl stop ndtwin-esa ndtwin-spm ndtwin-reqmgr 2>/dev/null
sudo -n mn -c >/dev/null 2>&1

echo
echo "--- unit enablement must stay OFF (this image opens no ports on boot) ---"
for u in ndtwin-esa ndtwin-spm ndtwin-reqmgr; do
  printf "    %-16s enabled=%s active=%s\n" "$u" "$(systemctl is-enabled $u 2>&1)" "$(systemctl is-active $u 2>&1)"
done

echo
echo "--- shell history and caches ---"
rm -f /home/tester/.bash_history
sudo -n journalctl --rotate >/dev/null 2>&1
sudo -n journalctl --vacuum-time=1s >/dev/null 2>&1
sudo -n apt-get clean >/dev/null 2>&1

echo
echo "=== BEFORE ==="; df -h / | tail -1
echo
echo "=== zero-fill free space (ENOSPC is the goal here, not a failure) ==="
sudo -n dd if=/dev/zero of=/zerofill bs=1M status=none 2>/dev/null
echo "  zerofill reached $(sudo -n stat -c%s /zerofill 2>/dev/null) bytes"
sync; sudo -n rm -f /zerofill; sync
for m in /boot /boot/efi; do
  [ -d "$m" ] || continue
  sudo -n dd if=/dev/zero of="$m/.zf" bs=1M status=none 2>/dev/null
  sudo -n rm -f "$m/.zf"
done
sync
echo
echo "=== fstrim: turn those zeros into holes ==="
sudo -n fstrim -av 2>&1 | sed "s/^/  /"
echo
echo "=== AFTER ==="; df -h / | tail -1
sync
echo "A3_FINALIZE_DONE"
