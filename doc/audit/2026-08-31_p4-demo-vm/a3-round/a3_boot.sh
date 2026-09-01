#!/bin/bash
# A-3 step 0: boot the SHIPPING artefact on the hardware its own OVF declares.
#
# The VM tool (ndtwin-vm.sh) cannot be used to boot this: its `start` hard-codes
# virtio-blk + virtio-net + a cloud-init seed + user `ndt`, and the whole point of
# this round is to run the acceptance on SATA/AHCI + E1000 + 4 vCPU / 6144 MB,
# which is what the OVF declares. So the boot is the proven invocation from
# nslab_t2_on_shipping_artefact.sh, and the tool's REGISTRY (OWNER/CONFIG/qemu.pid
# inside $VM_DIR) is written in the tool's own format so that `ndtwin-vm.sh status`
# and every other session's port_guard see this claim correctly.
#
# Payload stays byte-identical to the .ova: the guest writes to a qcow2 overlay.
#
# [Co-developed with claude code -- Adam]
set -u

VM_DIR=/home/nslab/ndtwin-vm-a3
SSH_PORT=2299
NDT_OWNER=install-manual
OVA=/home/nslab/repack/out/NDTwin-P4-demo.ova
EXPECT_SHA=72fac12806416869dc91037d6dd310dd6d2d9690d6294f0b36fe22f3ffbede79

echo "=== $(date -Is) A-3 boot ==="

# --- refuse to touch anything that is not ours -------------------------------
for d in /home/nslab/ndtwin-vm /home/nslab/ndtwin-vm-a2 /home/nslab/ndtwin-vm-reviewer-B; do
  [ "$d" = "$VM_DIR" ] && { echo "🔴 VM_DIR collides with a protected dir"; exit 1; }
done
if ss -tlnH "( sport = :$SSH_PORT )" 2>/dev/null | grep -q .; then
  echo "🔴 REFUSED -- 127.0.0.1:$SSH_PORT already listening"; exit 1
fi

# --- identity of the thing under test ---------------------------------------
echo "--- artefact under test ---"
stat -c '  %n  %s bytes' "$OVA" || exit 1
GOT=$(sha256sum "$OVA" | awk '{print $1}')
echo "  sha256 $GOT"
[ "$GOT" = "$EXPECT_SHA" ] || { echo "🔴 WRONG ARTEFACT (expected $EXPECT_SHA)"; exit 1; }
echo "  ✅ matches the artefact A-3 was assigned"

mkdir -p "$VM_DIR/ova" || exit 1

# --- registry, in ndtwin-vm.sh's own format ---------------------------------
if [ ! -f "$VM_DIR/OWNER" ]; then
  printf 'owner: %s\nsince: %s\nport:  %s\nnote:  %s\n' \
    "$NDT_OWNER" "$(date -Is)" "$SSH_PORT" \
    "A-3: strip doc/, pin NTV b5e039c, repack + re-accept the P4 demo .ova" \
    > "$VM_DIR/OWNER"
fi
printf 'cpus=%s\nmem=%s\ndisk=%s\nport=%s\n' 4 6144 60G "$SSH_PORT" > "$VM_DIR/CONFIG"
echo "--- registry written ---"; sed 's/^/  /' "$VM_DIR/OWNER"

# --- unpack (payload is never modified; the guest writes to an overlay) ------
echo "--- unpack ---"
tar -xf "$OVA" -C "$VM_DIR/ova" || exit 1
ls -la "$VM_DIR/ova" | sed 's/^/  /'
D=$(ls "$VM_DIR"/ova/*.vmdk | head -1)
[ -s "$D" ] || { echo "🔴 no vmdk in the archive"; exit 1; }
echo "  backing disk: $D"

rm -f "$VM_DIR/disk.qcow2"
qemu-img create -q -f qcow2 -b "$D" -F vmdk "$VM_DIR/disk.qcow2" || exit 1
qemu-img info "$VM_DIR/disk.qcow2" | sed 's/^/  /'

# --- boot: exactly the hardware the OVF declares ----------------------------
echo "--- boot: SATA/AHCI, E1000, 4 vCPU, 6144 MB ---"
rm -f "$VM_DIR/qemu.pid"
setsid qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 4 \
  -name ndtwin-p4-demo-a3 \
  -device ahci,id=ahci0 \
  -drive id=d0,file="$VM_DIR/disk.qcow2",if=none,format=qcow2 \
  -device ide-hd,drive=d0,bus=ahci0.0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 -device e1000,netdev=n0 \
  -display none -serial "file:$VM_DIR/qemu.log" \
  -daemonize -pidfile "$VM_DIR/qemu.pid" || { echo "🔴 qemu failed to launch"; exit 1; }

sleep 3
P=$(head -1 "$VM_DIR/qemu.pid" 2>/dev/null)
# state, not rc: read /proc directly (never pgrep -f)
if [ -n "$P" ] && [ -r "/proc/$P/exe" ] && [ -r "/proc/$P/cmdline" ] \
   && tr '\0' ' ' < "/proc/$P/cmdline" | grep -q "$VM_DIR/disk.qcow2"; then
  echo "  qemu pid $P  exe=$(readlink -f /proc/$P/exe)"
else
  echo "🔴 qemu is not running"; tail -20 "$VM_DIR/qemu.log" 2>/dev/null; exit 1
fi

# --- wait for ssh (password auth; the .ova ships no key) --------------------
printf '#!/bin/sh\necho tester\n' > "$VM_DIR/.ask"; chmod 700 "$VM_DIR/.ask"
export SSH_ASKPASS="$VM_DIR/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
up=0
for i in $(seq 1 40); do
  if ssh -p $SSH_PORT $CO tester@127.0.0.1 'echo up' 2>/dev/null | grep -q up; then up=1; break; fi
  sleep 10
done
[ "$up" = 1 ] || { echo "🔴 SSH DID NOT COME UP"; tail -30 "$VM_DIR/qemu.log"; exit 1; }
echo "  SSH UP after $((i*10))s"

echo "--- the hardware it actually booted on (sd* = AHCI, not vd*) ---"
ssh -p $SSH_PORT $CO tester@127.0.0.1 \
  'echo "  root: $(df -h / | awk "NR==2{print \$1, \$4\" free\"}")"
   echo "  disks: $(lsblk -no NAME,TYPE | tr "\n" " ")"
   echo "  nic:  $(ip -br link | awk "NR>1{print \$1}" | tr "\n" " ")"
   echo "  cpus: $(nproc)   mem: $(free -m | awk "/^Mem:/{print \$2}") MB"
   echo "  os:   $(. /etc/os-release; echo $PRETTY_NAME)"' 2>/dev/null
echo "A3_BOOT_DONE"
