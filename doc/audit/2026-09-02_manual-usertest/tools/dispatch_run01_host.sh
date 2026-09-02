#!/bin/bash
# A-7 run-01: bring the fresh VM up and stage the docs. Run ON nslab, from a file.
# Preconditions enforced here, not assumed: A-6 released (no qemu on prep61), RAM headroom, port free.
# [Co-developed with claude code -- Adam]
set -uo pipefail
export VM_DIR=$HOME/ndtwin-vm-usertest-01-sonnet
export VM_USER=ndt VM_CPUS=4 VM_MEM=6144 SSH_PORT=2311
DOCS_SRC=$HOME/Downloads/Manual-Installation-Test/NDTwin-Website
G="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p 2311 ndt@127.0.0.1"

echo "=== preflight $(date -Is) ==="
for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null) || continue; case "$e" in *qemu-system*) echo "qemu pid=$(basename $p) disk=$(tr '\0' ' ' < $p/cmdline | grep -oP 'file=\K[^,]+disk.qcow2' | head -1)";; esac; done
if for p in /proc/[0-9]*; do tr '\0' ' ' < "$p/cmdline" 2>/dev/null; done | grep -q "ndtwin-vm-prep61/disk.qcow2"; then echo "FATAL: A-6 (prep61) still running -- RAM gate"; exit 1; fi
AV=$(free -m | awk '/^Mem:/{print $7}'); echo "available MB: $AV"; [ "$AV" -ge 9000 ] || { echo "FATAL: need >= 9000 MB available"; exit 1; }
ss -tlnH "( sport = :2311 )" | grep -q . && { echo "FATAL: 2311 listening"; exit 1; }
[ -f "$VM_DIR/disk.qcow2" ] || { echo "FATAL: no disk"; exit 1; }
[ -f "$VM_DIR/qemu.pid" ] && { echo "FATAL: stale pidfile"; exit 1; }
grep -c Desktop "$VM_DIR/user-data" | grep -qx 0 || { echo "FATAL: seed still pre-creates Desktop"; exit 1; }
DOCS_COMMIT=$(git -C "$DOCS_SRC" log --format=%h -1); echo "docs commit: $DOCS_COMMIT"

echo "=== start ==="
~/ndtwin-vm.sh start < /dev/null
QPID=$(head -1 "$VM_DIR/qemu.pid"); echo "qemu pid=$QPID start=$(stat -c %y "$VM_DIR/qemu.pid")"
taskset -acp 16-19 "$QPID" >/dev/null && taskset -cp "$QPID"

echo "=== guest: confirm it is FRESH (M-1 seed stripped, nothing installed) ==="
$G 'echo "user=$(whoami) host=$(hostname)"; . /etc/os-release; echo "$PRETTY_NAME"; ls -d ~/Desktop 2>&1; ls ~; ls -d ~/miniconda3 ~/Desktop/NDTwin-Kernel 2>&1; which mn ovs-vsctl p4c-bm2-ss simple_switch_grpc 2>&1; python3 --version; df -h / | awk "NR==2{print \$4\" free\"}"; nproc; free -g | awk "/^Mem:/{print \$2\"Gi\"}"'

echo "=== stage the docs into the guest (~/ndtwin-docs) ==="
tar -C "$DOCS_SRC/content/en" -cf /tmp/ndtwin-docs.tar docs
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 2311 /tmp/ndtwin-docs.tar ndt@127.0.0.1:/tmp/ndtwin-docs.tar
rm -f /tmp/ndtwin-docs.tar
$G 'mkdir -p ~/ndtwin-docs && tar -C ~/ndtwin-docs --strip-components=1 -xf /tmp/ndtwin-docs.tar && rm -f /tmp/ndtwin-docs.tar && echo "docs: $(find ~/ndtwin-docs -name "*.md" | wc -l) md files" && ls ~/ndtwin-docs && printf "%s\n" "website commit: '"$DOCS_COMMIT"'" > ~/ndtwin-docs/DOCS-SNAPSHOT.txt && cat ~/ndtwin-docs/DOCS-SNAPSHOT.txt'

echo "=== state ==="
~/ndtwin-vm.sh status < /dev/null
free -m | sed -n 2p
echo "READY FOR TESTER: port 2311, docs $DOCS_COMMIT"
