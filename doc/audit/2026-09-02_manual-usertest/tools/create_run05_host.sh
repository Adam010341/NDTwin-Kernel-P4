#!/bin/bash
# A-7 run-05: create_run_host.sh PLUS the one variable this round deliberately changes --
# the tester VM no longer has blanket passwordless sudo.
#
# Why: rounds 01-04 all ran with `sudo: ALL=(ALL) NOPASSWD:ALL`, which is the reason none of
# them could see ndt's sudo defects -- every `sudo -n` inside ndt succeeded, so the guards that
# fail closed on a real user's machine never fired. See NSLAB-USAGE-RULES.md row A-11.
#
# What a real reader's machine actually looks like: they are in the sudo group and they have a
# password. So: `sudo: ALL=(ALL) ALL` and a real password. The sudoers rule the manual teaches
# (NOPASSWD for /usr/local/sbin/ndtwin-lab) is deliberately NOT pre-installed -- the manual tells
# the reader to add it, and pre-adding it would walk part of the path under test for them.
#
# ssh_pwauth stays false: the password is for sudo only, never for logging in. qemu binds the
# forward to 127.0.0.1, so the guest's ssh port is not reachable off nslab either way.
#
#   RUN_DIR=ndtwin-vm-usertest-05-opus SSH_PORT=2315 BASE_FROM=ndtwin-vm-usertest-04-sonnet \
#   MODEL=opus RUN=run-05 GUEST_PW=ndt bash /tmp/create_run05_host.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
cd ~
D=$HOME/${RUN_DIR:?set RUN_DIR}; P=${SSH_PORT:?set SSH_PORT}; B=$HOME/${BASE_FROM:?set BASE_FROM}
PW=${GUEST_PW:?set GUEST_PW}
[ -e "$D" ] && { echo "FATAL: $D exists"; exit 1; }
ss -tlnH "( sport = :$P )" | grep -q . && { echo "FATAL: $P listening"; exit 1; }
mkdir -p "$D"
echo "=== base image reuse ==="; sha256sum $B/noble-base.img | cut -c1-16
cp --reflink=auto $B/noble-base.img "$D/noble-base.img" && echo "copied $(stat -c %s "$D/noble-base.img") bytes"
echo "=== create $(date +%T) ==="
VM_DIR="$D" VM_USER=ndt SSH_PORT=$P VM_DISK=120G ~/ndtwin-vm.sh create < /dev/null 2>&1 | tail -12
echo "create rc=${PIPESTATUS[0]}"

echo "=== patch the seed: strip Desktop (as every round) AND remove blanket NOPASSWD (this round only) ==="
cp "$D/user-data" "$D/user-data.as-created"
python3 - "$D/user-data" "$PW" <<'PY'
import sys
p,pw=sys.argv[1],sys.argv[2]
L=open(p).read().split('\n')
drop=('DELIBERATE DEVIATION','install manual uses ~/Desktop','We create it here','re-test M-1','/home/ndt/Desktop')
keep=[l for l in L if not any(d in l for d in drop)]
print("dropped Desktop lines:", len(L)-len(keep))
out=[]; nop=lock=0
for l in keep:
    if 'NOPASSWD:ALL' in l:
        out.append(l.replace('ALL=(ALL) NOPASSWD:ALL','ALL=(ALL) ALL')); nop+=1
    elif l.strip()=='lock_passwd: true':
        ind=l[:len(l)-len(l.lstrip())]
        out.append(ind+'lock_passwd: false'); out.append(ind+'plain_text_passwd: '+pw); lock+=1
    else:
        out.append(l)
print("NOPASSWD lines rewritten:", nop, " lock_passwd lines rewritten:", lock)
assert nop==1 and lock==1, "seed did not look like the expected shape -- refusing"
open(p,'w').write('\n'.join(out))
PY
[ $? -eq 0 ] || { echo "FATAL: seed patch failed"; exit 1; }
cloud-localds "$D/seed.iso" "$D/user-data" "$D/meta-data" && echo "seed rebuilt"

echo "=== assert the seed says what we think, in the seed.iso not just the yaml ==="
echo "  Desktop     user-data=$(grep -c Desktop "$D/user-data")  seed.iso=$(strings "$D/seed.iso" | grep -c Desktop)  (both must be 0)"
echo "  NOPASSWD    user-data=$(grep -c NOPASSWD "$D/user-data")  seed.iso=$(strings "$D/seed.iso" | grep -c NOPASSWD)  (both must be 0)"
echo "  sudo line   $(grep -n 'sudo:' "$D/user-data")"
echo "  passwd      $(grep -n 'lock_passwd\|plain_text_passwd' "$D/user-data")"
echo "  ssh_pwauth  $(grep -n 'ssh_pwauth' "$D/user-data")   (must stay false)"
echo "  as-created kept the original: NOPASSWD=$(grep -c NOPASSWD "$D/user-data.as-created")"
diff "$D/user-data.as-created" "$D/user-data"

printf 'cpus=4\nmem=6144\ndisk=120G\nport=%s\n' "$P" > "$D/CONFIG"
printf 'owner: adam (campaign A-7, '"${RUN:?set RUN}"', tester model: '"${MODEL:?set MODEL}"')\nsince: '"$(date +%F)"'\nport:  '"$P"'\nnote:  Fresh Ubuntu 24.04 cloud image. Seed rebuilt WITHOUT the ~/Desktop pre-creation.\nnote:  THIS ROUND ONLY: no blanket passwordless sudo. ndt is in the sudo group with a password.\nnote:  See NSLAB-USAGE-RULES.md row A-11 and doc/audit/2026-09-02_manual-usertest/.\n' > "$D/OWNER"; chmod 600 "$D/OWNER"
echo "=== result ==="; ls -la "$D" | awk '{print $5, $6, $7, $8, $9}'; qemu-img info "$D/disk.qcow2" | grep -i "virtual size\|disk size\|backing"
df -h ~ | tail -1
