#!/bin/bash
# H-26 phase G: make the root/NFS requirement supported rather than merely documented, and
# write down which commit of each tool shipped -- before the .git directories are deleted.
#
# ADAM'S RULING was "README + MOTD, and also give a systemd unit". Both halves matter for a
# different reason:
#   * The prose alone is what we had, and it is what a recipient reads AFTER the binary has
#     already exited with `Mount NFS Failed`. It arrives too late to be the fix.
#   * The unit alone hides the requirement: it works, and the recipient never learns that these
#     two programs mount NFS at startup and abort if it fails, so the first time they run the
#     binary by hand it looks broken for no reason.
#
# 🔴 THE UNITS ARE INSTALLED BUT NOT ENABLED, DELIBERATELY. An image handed to strangers must
#    not boot listening on :8001/:9000 and serving NFS to whatever network the recipient
#    happens to be on. `systemctl enable` is left as their decision, and the README says so.
#
# 🔴 EXPORTS STAY BOUND TO localhost. Simulation-Platform-Manager ships an etc.exports pinned to
#    192.168.50.21 -- a lab address. Copying that into a distributed image would export a
#    writable share to whoever is on the recipient's subnet at that address.
#
# THE MOUNTS ARE MADE BY ExecStartPre, NOT fstab. Mounting localhost NFS at boot is
# order-sensitive and a failure there would stall a demo VM's boot for a service nobody asked
# to run. Mounting when the service actually starts costs a second and cannot wedge the boot.
#
# PROVENANCE IS WRITTEN NOW because phase H deletes the .git directories, and after that this
# file is the only remaining record of which commit shipped. Writing it afterwards would mean
# writing it from memory.
#
# [Co-developed with claude code -- Adam]
LOG=/home/tester/phaseG.out
exec > >(tee -a "$LOG") 2>&1
D=/home/tester/Desktop
OK=0; BAD=0
ok(){ echo "  PASS: $*"; OK=$((OK+1)); }
bad(){ echo "  FAIL: $*"; BAD=$((BAD+1)); }
sec(){ echo; echo "############ $* ############"; }

echo "=== phase G started $(date -Is) ==="

sec "1. one idempotent helper both units call"
sudo -n tee /usr/local/sbin/ndtwin-nfs-up >/dev/null <<'HELPER'
#!/bin/sh
# Bring up the NFS shares that energy_saving_app and simulation_platform_manager mount at
# startup. Both abort if the mount fails, so this runs before them, and is safe to run twice.
#
# The exports are bound to localhost on purpose. The upstream Simulation-Platform-Manager repo
# ships an etc.exports pinned to 192.168.50.21; this image goes to people who are not on that
# lab's network, and an export offered to whoever holds that address is an export to strangers.
#
# [Co-developed with claude code -- Adam]
set -e
mkdir -p /srv/nfs/sim/power /mnt/nfs/sim /mnt/nfs/app
chmod 777 /srv/nfs/sim /srv/nfs/sim/power
systemctl is-active --quiet nfs-server || systemctl start nfs-server
exportfs -ra
mountpoint -q /mnt/nfs/sim || mount -t nfs localhost:/srv/nfs/sim /mnt/nfs/sim
mountpoint -q /mnt/nfs/app || mount -t nfs localhost:/srv/nfs/sim/power /mnt/nfs/app
mountpoint -q /mnt/nfs/sim && mountpoint -q /mnt/nfs/app
HELPER
sudo -n chmod 755 /usr/local/sbin/ndtwin-nfs-up
sudo -n sh -n /usr/local/sbin/ndtwin-nfs-up && ok "helper parses" || bad "helper has a syntax error"

sec "2. three units, installed and left disabled"
sudo -n tee /etc/systemd/system/ndtwin-esa.service >/dev/null <<'U1'
[Unit]
Description=NDTwin Energy-Saving-App (needs root: it mounts NFS at startup and aborts if that fails)
Documentation=file:///home/tester/Desktop/README-NDTwin-tools.md
After=network-online.target nfs-server.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/tester/Desktop/Energy-Saving-App
ExecStartPre=/usr/local/sbin/ndtwin-nfs-up
ExecStart=/home/tester/Desktop/Energy-Saving-App/energy_saving_app
Restart=no

[Install]
WantedBy=multi-user.target
U1
sudo -n tee /etc/systemd/system/ndtwin-spm.service >/dev/null <<'U2'
[Unit]
Description=NDTwin Simulation-Platform-Manager (needs root: it mounts NFS at startup and aborts if that fails)
Documentation=file:///home/tester/Desktop/README-NDTwin-tools.md
After=network-online.target nfs-server.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/tester/Desktop/Simulation-Platform-Manager
ExecStartPre=/usr/local/sbin/ndtwin-nfs-up
ExecStart=/home/tester/Desktop/Simulation-Platform-Manager/simulation_platform_manager
Restart=no

[Install]
WantedBy=multi-user.target
U2
sudo -n tee /etc/systemd/system/ndtwin-reqmgr.service >/dev/null <<'U3'
[Unit]
Description=NDTwin request_manager (serves :8002; does NOT need root and does NOT need NFS)
Documentation=file:///home/tester/Desktop/README-NDTwin-tools.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tester
WorkingDirectory=/home/tester/Desktop/Simulation-Platform-Manager
ExecStart=/home/tester/Desktop/Simulation-Platform-Manager/request_manager
Restart=no

[Install]
WantedBy=multi-user.target
U3
sudo -n systemctl daemon-reload
for u in ndtwin-esa ndtwin-spm ndtwin-reqmgr; do
  st=$(systemctl is-enabled "$u" 2>&1)
  if systemctl cat "$u" >/dev/null 2>&1 && [ "$st" = "disabled" ]; then
    ok "$u installed and DISABLED (is-enabled says: $st)"
  else
    bad "$u -- systemd sees it as '$st', expected 'disabled'"
  fi
done

sec "3. do the units actually work? start each, check the thing it is for, stop it"
sudo -n systemctl start ndtwin-esa 2>&1 | tail -3
sleep 10
if systemctl is-active --quiet ndtwin-esa && ss -tlnH 2>/dev/null | grep -q ':8001'; then
  ok "ndtwin-esa active AND :8001 is listening (state, not a log line)"
else
  bad "ndtwin-esa: active=$(systemctl is-active ndtwin-esa), :8001=$(ss -tlnH 2>/dev/null | grep -c ':8001')"
  sudo -n journalctl -u ndtwin-esa -n 6 --no-pager 2>&1 | sed 's/^/    /'
fi
sudo -n systemctl stop ndtwin-esa; sleep 2

sudo -n systemctl start ndtwin-spm 2>&1 | tail -3
sleep 10
if systemctl is-active --quiet ndtwin-spm && ss -tlnH 2>/dev/null | grep -q ':9000'; then
  ok "ndtwin-spm active AND :9000 is listening"
else
  bad "ndtwin-spm: active=$(systemctl is-active ndtwin-spm), :9000=$(ss -tlnH 2>/dev/null | grep -c ':9000')"
  sudo -n journalctl -u ndtwin-spm -n 6 --no-pager 2>&1 | sed 's/^/    /'
fi
sudo -n systemctl stop ndtwin-spm; sleep 2

sudo -n systemctl start ndtwin-reqmgr 2>&1 | tail -3
sleep 8
if systemctl is-active --quiet ndtwin-reqmgr && ss -tlnH 2>/dev/null | grep -q ':8002'; then
  ok "ndtwin-reqmgr active AND :8002 is listening"
else
  bad "ndtwin-reqmgr: active=$(systemctl is-active ndtwin-reqmgr), :8002=$(ss -tlnH 2>/dev/null | grep -c ':8002')"
  sudo -n journalctl -u ndtwin-reqmgr -n 6 --no-pager 2>&1 | sed 's/^/    /'
fi
sudo -n systemctl stop ndtwin-reqmgr; sleep 2
sudo -n umount /mnt/nfs/sim /mnt/nfs/app 2>/dev/null
echo "  nothing of phase G left listening: $(ss -tlnH 2>/dev/null | grep -cE ':(8001|8002|9000) ') on 8001/8002/9000 (expect 0)"

sec "4. PROVENANCE.txt -- written while .git still exists"
{
  echo "NDTwin P4/BMv2 demo VM -- provenance of the tools under ~/Desktop"
  echo "written $(date -Is) on the image itself"
  echo
  echo "Each tree below was cloned from GitHub into this image. The .git directories are"
  echo "REMOVED before packaging -- a repository carries every blob it ever held, and an image"
  echo "is a filesystem, so shipping them ships history nobody inspected. That deletion is also"
  echo "why this file exists: after it, this is the only record of which commit you have."
  echo
  printf '%-34s %-10s %-12s %s\n' "TREE" "COMMIT" "DATE" "ORIGIN"
  for r in Energy-Saving-App Simulation-Platform-Manager Traffic-Engineering-App Network-Traffic-Visualizer; do
    p="/home/tester/Desktop/$r"
    [ -d "$p/.git" ] || { printf '%-34s %s\n' "$r" "(no .git -- cannot report)"; continue; }
    printf '%-34s %-10s %-12s %s\n' "$r" \
      "$(git -C "$p" rev-parse --short HEAD)" \
      "$(git -C "$p" log -1 --format=%ad --date=short)" \
      "$(git -C "$p" remote get-url origin 2>/dev/null)"
  done
  echo
  echo "Network-Traffic-Visualizer is the one that is NOT a clean checkout, and here is why."
  echo
  echo "  Its main branch does not compile. WindowStateRestore is called from four places"
  echo "  (SideBar.java x3, InfoDialog.java x1) and is declared nowhere in the repository; it"
  echo "  never existed in its history. The regression was introduced by 9ef655f (2026-03-31)"
  echo "  and main is 9b56b30 (2026-04-20), so the public tip has not compiled since March."
  echo
  echo "  NDTwin-local-changes.patch in that directory is the workaround, and it is not ours:"
  echo "  it is a byte-for-byte copy of the uncommitted edits the NDTwin author runs locally,"
  echo "  dated 2026-06-09. It comments out the four calls and restores the work each of them"
  echo "  was wrapping. Run 'git apply -R NDTwin-local-changes.patch' to get back to upstream."
  echo
  echo "  What the patch costs you: nothing measurable. The two commits after b5e039c add no"
  echo "  feature -- they wrap already-existing dialogs in window-state preservation, add"
  echo "  NetworkTopologyApp.getPrimaryStage(), and add a licence header. Behaviour with the"
  echo "  patch applied is the behaviour of b5e039c."
  echo
  echo "Running the two that need root:"
  echo "  energy_saving_app and simulation_platform_manager mount NFS at startup and abort if"
  echo "  that fails. systemd units are installed for both (ndtwin-esa, ndtwin-spm) and are"
  echo "  DISABLED -- see README-NDTwin-tools.md before enabling them."
} | tee "$D/PROVENANCE.txt" | sed 's/^/    /'
[ -s "$D/PROVENANCE.txt" ] && ok "PROVENANCE.txt written ($(wc -l < "$D/PROVENANCE.txt") lines)" || bad "PROVENANCE.txt empty"

sec "SUMMARY (phase G)"
echo "  PASS=$OK  FAIL=$BAD"
echo "PHASE_G_DONE"
