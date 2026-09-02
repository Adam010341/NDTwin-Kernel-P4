#!/bin/bash
# A-8 stop and release. qemu pid recorded at start = 404441.
# [Co-developed with claude code -- Adam]
set -u
QPID_BEFORE=$(cat "$HOME/ndtwin-vm-prep5/qemu.pid" 2>/dev/null)
echo "=== A-8 STOP prep5  $(date -u +%FT%TZ) / $(date +%FT%T%z) ==="
echo "QPID_BEFORE=$QPID_BEFORE"
echo "--- free before stop ---"; free -m | head -2
echo
S=$(date +%s)
VM_DIR=$HOME/ndtwin-vm-prep5 SSH_PORT=2301 "$HOME/ndtwin-vm.sh" stop < /dev/null
echo "STOP_EXIT=$?"
echo "STOP_DURATION=$(( $(date +%s) - S ))s"
echo
echo "--- is the qemu pid gone? ---"
if [ -n "${QPID_BEFORE:-}" ] && [ -d "/proc/$QPID_BEFORE" ]; then
  echo "QEMU_PID_STILL_PRESENT=yes"; readlink "/proc/$QPID_BEFORE/exe"
else
  echo "QEMU_PID_GONE=yes  ([ -d /proc/$QPID_BEFORE ] is false)"
fi
echo
echo "--- port 2301 ---"
ss -tlnpH 'sport = :2301' 2>/dev/null | grep -q . && { echo "PORT_2301=OCCUPIED"; ss -tlnpH 'sport = :2301'; } || echo "PORT_2301=no listener"
echo
echo "--- remaining qemu processes on the host (readlink /proc/*/exe, no pgrep -f) ---"
n=0
for p in /proc/[0-9]*; do
  e=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$e" in *qemu-system*)
    n=$((n+1)); cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    echo "PID=${p#/proc/} $(printf '%s' "$cmd" | tr ' ' '\n' | grep -o '[^,]*\.qcow2' | head -1)";;
  esac
done
echo "QEMU_COUNT_AFTER=$n  (expected 1 = Adam's ndtwin-vm-adam)"
echo
echo "--- free after stop ---"; free -m | head -2
echo "--- /home ---"; df -h /home | tail -1
echo
echo "--- image size kept ---"
du -b "$HOME/ndtwin-vm-prep5/disk.qcow2"
qemu-img info "$HOME/ndtwin-vm-prep5/disk.qcow2" | sed -n '1,8p'
echo "--- snapshots? ---"
qemu-img snapshot -l "$HOME/ndtwin-vm-prep5/disk.qcow2" 2>&1 | head -5
echo "STOP_SCRIPT_EXIT=0"
