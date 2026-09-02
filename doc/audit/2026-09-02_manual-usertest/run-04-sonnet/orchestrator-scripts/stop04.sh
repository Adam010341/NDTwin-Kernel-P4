# run-04 stop + release evidence. Runs ON nslab. Touches only ndtwin-vm-usertest-04-sonnet.
# [Co-developed with claude code -- Adam]
set -u
echo "=== BEFORE ==="; date -u +%FT%TZ; date +%F' '%T' '%Z
echo "qemu 342820: $([ -d /proc/342820 ] && echo ALIVE || echo GONE)"
ls -l --block-size=1 ~/ndtwin-vm-usertest-04-sonnet/disk.qcow2
free -m | head -2
echo "--- other qemu on host (informational, no action) ---"
for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < $p/cmdline 2>/dev/null); case "$c" in
  *qemu-system*) echo "  ${p#/proc/}: $(echo "$c" | grep -o '\-name [^ ]*' | head -1) $(echo "$c" | grep -o 'ndtwin-vm[^/ ]*' | head -1)";; esac; done
echo
echo "=== STOP ==="
VM_DIR=$HOME/ndtwin-vm-usertest-04-sonnet SSH_PORT=2314 ~/ndtwin-vm.sh stop < /dev/null
echo "STOP_EXIT=$?"
echo
echo "=== AFTER ==="; date +%F' '%T' '%Z
echo "qemu 342820: $([ -d /proc/342820 ] && echo STILL_ALIVE || echo GONE)"
echo "port 2314 listeners:"; ss -tlnpH 'sport = :2314' 2>&1; echo "  (empty above = nobody listening)"
ls -l --block-size=1 ~/ndtwin-vm-usertest-04-sonnet/disk.qcow2
du -h --apparent-size ~/ndtwin-vm-usertest-04-sonnet/disk.qcow2; du -h ~/ndtwin-vm-usertest-04-sonnet/disk.qcow2
qemu-img info ~/ndtwin-vm-usertest-04-sonnet/disk.qcow2 2>&1 | head -12
free -m | head -2
df -h /home | tail -1
echo "--- qemu still on host ---"
for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < $p/cmdline 2>/dev/null); case "$c" in
  *qemu-system*) echo "  ${p#/proc/}: $(echo "$c" | grep -o 'ndtwin-vm[^/ ]*' | head -1)";; esac; done
