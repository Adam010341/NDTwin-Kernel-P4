#!/bin/bash
# A-7 run-NN: make a FRESH tester VM directory (base image reflink, create, seed rebuilt WITHOUT the ~/Desktop
# pre-creation so finding M-1 is really tested). Run ON nslab, from a file, BEFORE dispatch_run_host.sh:
#   RUN_DIR=ndtwin-vm-usertest-04-fable SSH_PORT=2314 BASE_FROM=ndtwin-vm-usertest-03-opus MODEL=fable RUN=run-04 bash /tmp/create_run_host.sh
# (this is the script used for run-02 and run-03, parametrised; it lived only in the orchestrator scratchpad before)
# [Co-developed with claude code -- Adam]
set -uo pipefail
cd ~
D=$HOME/${RUN_DIR:?set RUN_DIR=ndtwin-vm-usertest-NN-<model>}; P=${SSH_PORT:?set SSH_PORT}; B=$HOME/${BASE_FROM:?set BASE_FROM=<existing vm dir with noble-base.img>}
[ -e "$D" ] && { echo "FATAL: $D exists"; exit 1; }
ss -tlnH "( sport = :$P )" | grep -q . && { echo "FATAL: $P listening"; exit 1; }
mkdir -p "$D"
echo "=== base image reuse ==="; sha256sum $B/noble-base.img | cut -c1-16
cp --reflink=auto $B/noble-base.img "$D/noble-base.img" && echo "copied $(stat -c %s "$D/noble-base.img") bytes"
echo "=== create $(date +%T) ==="
VM_DIR="$D" VM_USER=ndt SSH_PORT=$P VM_DISK=120G ~/ndtwin-vm.sh create < /dev/null 2>&1 | tail -12
echo "create rc=${PIPESTATUS[0]}"
echo "=== strip the Desktop pre-creation from the seed ==="
cp "$D/user-data" "$D/user-data.as-created"
python3 - "$D/user-data" <<'PY'
import sys
p=sys.argv[1]; L=open(p).read().split('\n')
drop=('DELIBERATE DEVIATION','install manual uses ~/Desktop','We create it here','re-test M-1','/home/ndt/Desktop')
keep=[l for l in L if not any(d in l for d in drop)]
print("dropped lines:", len(L)-len(keep))
open(p,'w').write('\n'.join(keep))
PY
cloud-localds "$D/seed.iso" "$D/user-data" "$D/meta-data" && echo "seed rebuilt"
echo "Desktop in user-data: $(grep -c Desktop "$D/user-data")   in seed.iso strings: $(strings "$D/seed.iso" | grep -c Desktop)   in as-created: $(grep -c Desktop "$D/user-data.as-created")"
diff "$D/user-data.as-created" "$D/user-data" | head -12
printf 'cpus=4\nmem=6144\ndisk=120G\nport=$P\n' > "$D/CONFIG"
printf 'owner: adam (campaign A-7, '"${RUN:?set RUN}"', tester model: '"${MODEL:?set MODEL}"')\nsince: 2026-09-02\nport:  '"$P"'\nnote:  Fresh Ubuntu 24.04 cloud image. Seed rebuilt WITHOUT the ~/Desktop pre-creation (user-data.as-created keeps the original) so finding M-1 is really tested.\nnote:  See NSLAB-USAGE-RULES.md row A-7 / '"$RUN"' and doc/audit/2026-09-02_manual-usertest/.\n' > "$D/OWNER"; chmod 600 "$D/OWNER"
echo "=== result ==="; ls -la "$D" | awk '{print $5, $6, $7, $8, $9}'; qemu-img info "$D/disk.qcow2" | grep -i "virtual size\|disk size\|backing"
df -h ~ | tail -1
