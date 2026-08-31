#!/usr/bin/env bash
# ndtwin-virt-root.sh -- the ONE permanent root step for the VM route.
# [Co-developed with claude code -- Adam]
#
# After this, Claude can create/destroy/snapshot VMs and hold root INSIDE them
# without ever needing the host password again. The host's own root surface is
# NOT widened: no NOPASSWD entries are added, no sudoers file is touched.
#
# Run:  sudo bash ~/ndtwin-virt-root.sh
#
# What it does, and why each piece:
#   qemu-system-x86  -- the hypervisor itself
#   qemu-utils       -- qemu-img, for creating and snapshotting qcow2 disks
#   cloud-image-utils-- cloud-localds, to build the cloud-init seed ISO that
#                       injects our ssh key into the guest on first boot
#   usermod -aG kvm  -- /dev/kvm is crw-rw---- root:kvm, so group membership is
#                       what turns "needs root to run a VM" into "does not".
#
# Deliberately NOT done:
#   * no libvirt/virsh -- one more daemon running as root on a shared box, for a
#     convenience layer we do not need; plain qemu + qemu-img is enough.
#   * no bridge, no tap, no firewall rules -- the guest uses QEMU user-mode (SLIRP)
#     networking, which gives it outbound NAT and NO layer-2 presence on
#     10.10.10.0/24. See the honesty note printed at the end: this is better than
#     bare metal but it is NOT a hard block on reaching the lab subnet.
set -uo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
LOG="$TARGET_HOME/ndtwin-virt-root.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== ndtwin-virt-root.sh  $(date -Is)  host=$(hostname)  for=$TARGET_USER ==="

[ "$(id -u)" -eq 0 ] || { echo "FATAL: must run as root (sudo bash $0)"; exit 1; }

PKGS=(qemu-system-x86 qemu-utils cloud-image-utils)

echo "--- apt update ---"
apt-get update -qq || echo "WARN: apt update rc=$? (continuing; acceptance is dpkg state)"

echo "--- apt install ---"
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
echo "apt-get rc=$?  (NOT the acceptance criterion)"

echo "--- group membership ---"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx kvm; then
    echo "  $TARGET_USER already in kvm"
else
    usermod -aG kvm "$TARGET_USER" && echo "  added $TARGET_USER to kvm"
fi

echo
echo "=== ACCEPTANCE (state, not exit codes) ==="
fail=0
for p in "${PKGS[@]}"; do
    st=$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || echo not-installed)
    [ "$st" = installed ] && printf '  OK       pkg %s\n' "$p" \
                          || { printf '  MISSING  pkg %s (%s)\n' "$p" "$st"; fail=$((fail+1)); }
done
for c in qemu-system-x86_64 qemu-img cloud-localds; do
    if command -v "$c" >/dev/null 2>&1; then printf '  OK       bin %-20s %s\n' "$c" "$(command -v "$c")"
    else printf '  MISSING  bin %s\n' "$c"; fail=$((fail+1)); fi
done
printf '  /dev/kvm: %s\n' "$(stat -c '%A %U:%G' /dev/kvm 2>/dev/null || echo ABSENT)"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx kvm; then
    echo "  OK       $TARGET_USER is in group kvm"
else
    echo "  MISSING  $TARGET_USER not in group kvm"; fail=$((fail+1))
fi

echo
echo "=== root surface UNCHANGED -- proof ==="
echo "  sudoers.d files now present:"
ls -1 /etc/sudoers.d/ 2>/dev/null | sed 's/^/    /'
echo "  (ndtwin-lab is milestone-1's scoped whitelist. No new file should appear here.)"

echo
echo "=== HONESTY NOTE -- what this does and does not isolate ==="
echo "  DOES:     guest has no layer-2 presence on 10.10.10.0/24; it cannot be seen by"
echo "            the lab switches, cannot ARP, cannot be a traffic endpoint by accident."
echo "  DOES NOT: SLIRP routes guest traffic through the HOST's socket layer, so a"
echo "            deliberate connection to 10.10.10.x from inside the guest would still"
echo "            work and would look like it came from server8. A hard block needs"
echo "            tap+nftables, which is a later refinement, not done here."

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT: PASS -- VM route enabled on $(hostname)."
    echo "NOTE: the kvm group applies to NEW logins only. Existing ssh sessions must reconnect."
else
    echo "RESULT: FAIL -- $fail item(s) missing above."
fi
echo "log: $LOG"
