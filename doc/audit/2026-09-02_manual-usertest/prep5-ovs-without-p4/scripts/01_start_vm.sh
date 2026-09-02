#!/bin/bash
# A-8 step 1: start ndtwin-vm-prep5 (port 2301, 4 vCPU / 6144 MB), pin to CPUs 16-19.
# ndtwin-vm.sh does NOT read CONFIG -- env is passed explicitly. Every verb gets < /dev/null.
# [Co-developed with claude code -- Adam]
set -u
echo "=== A-8 START prep5 $(date -u +%FT%TZ) / $(date +%FT%T%z) ==="
cat "$HOME/ndtwin-vm-prep5/OWNER" 2>/dev/null
echo "--- CONFIG (informational only; ndtwin-vm.sh does not read it) ---"
cat "$HOME/ndtwin-vm-prep5/CONFIG" 2>/dev/null
echo
echo "--- pre-start image ---"
du -b "$HOME/ndtwin-vm-prep5/disk.qcow2"
qemu-img info "$HOME/ndtwin-vm-prep5/disk.qcow2" 2>/dev/null | sed -n '1,12p'
echo
echo "--- start ---"
VM_DIR=$HOME/ndtwin-vm-prep5 SSH_PORT=2301 VM_CPUS=4 VM_MEM=6144 "$HOME/ndtwin-vm.sh" start < /dev/null
echo "START_EXIT=$?"
echo
echo "--- pidfile ---"
QPID=$(cat "$HOME/ndtwin-vm-prep5/qemu.pid" 2>/dev/null)
echo "QEMU_PID=$QPID"
if [ -n "${QPID:-}" ] && [ -d "/proc/$QPID" ]; then
  echo "PROC_EXISTS=yes"
  readlink "/proc/$QPID/exe"
  tr '\0' ' ' < "/proc/$QPID/cmdline"; echo
  echo "--- affinity: pin to 16-19 ---"
  taskset -acp 16-19 "$QPID"
  echo "TASKSET_EXIT=$?"
  taskset -acp "$QPID" | head -8
else
  echo "PROC_EXISTS=no"
fi
echo
echo "--- listener on 2301 ---"
ss -tlnpH 'sport = :2301' || true
echo
echo "--- free after start ---"
free -m
echo "START_SCRIPT_EXIT=0"
