#!/bin/bash
# Run the fabric acceptance on the artefact that actually ships.
#
# WHY THIS IS NOT ALREADY DONE
#   T-2 (32 links / 12 paths / pingall 12/12) was run on the disk unpacked from the
#   HAND-WRITTEN .ova. Everything since is an ovftool repack, and the only check any repacked
#   disk has had is a boot that confirmed three binaries exist on $PATH. "The binaries are
#   there" and "the fabric forwards" are different claims, and the second is the one the
#   download page makes.
#
#   The cheaper substitute -- hashing both decompressed images and showing they match -- was
#   tried first and failed in the worst way: `qemu-img convert -O raw ... /dev/stdout` cannot
#   resize a pipe, so it wrote nothing, and the pipeline still printed a sha256. That hash was
#   e3b0c442..., the hash of zero bytes, which looks exactly like a real answer. So: test the
#   purpose instead of the proxy for it.
#
# BOOT CONFIGURATION MATCHES WHAT THE OVF DECLARES, not what is convenient:
#   SATA/AHCI (not virtio), 4 vCPU, 6144 MB. The point of running this on the shipping
#   artefact is defeated by booting it on hardware the shipping artefact does not describe.
#
# The disk is an overlay over the extracted vmdk, so the payload stays byte-identical to the
# .ova and this run cannot be accused of having modified what it tested.
#
# [Co-developed with claude code -- Adam]
set -u

OVA=/home/nslab/ovftool-check/named/out/NDTwin-P4-demo.ova
W=/home/nslab/t2check
DRV=/home/nslab/guest_t2_run.sh
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

echo "=== artefact under test ==="
stat -c '%n %s bytes' "$OVA"
sha256sum "$OVA"

echo
echo "=== unpack ==="
tar -xf "$OVA"
ls -la
D=$(ls ./*.vmdk | head -1)
qemu-img create -q -f qcow2 -b "$W/${D#./}" -F vmdk "$W/ov.qcow2" || exit 1

echo
echo "=== boot: SATA/AHCI, 4 vCPU, 6144 MB -- the hardware the OVF declares ==="
qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 4 \
  -device ahci,id=ahci0 \
  -drive id=d0,file="$W/ov.qcow2",if=none,format=qcow2 \
  -device ide-hd,drive=d0,bus=ahci0.0 \
  -netdev user,id=n0,hostfwd=tcp::2299-:22 -device e1000,netdev=n0 \
  -display none -daemonize -pidfile "$W/vm.pid"
sleep 2
P=$(cat "$W/vm.pid" 2>/dev/null)
kill -0 "$P" 2>/dev/null && echo "qemu pid $P" || { echo "FAILED to start"; exit 1; }

printf '#!/bin/sh\necho tester\n' > "$W/.ask"; chmod 700 "$W/.ask"
export SSH_ASKPASS="$W/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"

up=0
for i in $(seq 1 40); do
  if ssh -p 2299 $CO tester@127.0.0.1 'echo up' 2>/dev/null | grep -q up; then up=1; break; fi
  sleep 10
done
[ "$up" = 1 ] || { echo "SSH DID NOT COME UP"; kill -TERM "$P"; exit 1; }
echo "SSH UP after $((i*10))s"

echo
echo "=== the disk it actually booted from (must be sd*, i.e. AHCI, not vd*) ==="
ssh -p 2299 $CO tester@127.0.0.1 'df -h / | tail -1; lsblk -no NAME,TYPE 2>/dev/null | head -5; ip -br link | head -4'

echo
echo "=== ship the T-2 driver in and run it ==="
scp -P 2299 $CO "$DRV" tester@127.0.0.1:/home/tester/guest_t2_run.sh
ssh -p 2299 $CO tester@127.0.0.1 'chmod +x /home/tester/guest_t2_run.sh && \
  setsid bash -c "/home/tester/guest_t2_run.sh > /home/tester/t2run.log 2>&1" < /dev/null > /dev/null 2>&1 &
  sleep 3; echo launched'

for i in $(seq 1 90); do
  sleep 20
  if ssh -p 2299 $CO tester@127.0.0.1 'grep -qE "T-2 (done|finished)|=== summary|failures:" /home/tester/t2run.log 2>/dev/null' 2>/dev/null; then
    echo "T-2 reached its summary after $((i*20))s"; break
  fi
done

echo
echo "############ T-2 OUTPUT ############"
ssh -p 2299 $CO tester@127.0.0.1 'cat /home/tester/t2run.log' 2>/dev/null

echo
echo "############ THE FOUR NUMBERS ############"
ssh -p 2299 $CO tester@127.0.0.1 'grep -iE "links|paths|Results:|dropped|failures|PASS:|FAIL:" /home/tester/t2run.log' 2>/dev/null

rm -f "$W/.ask"
ssh -p 2299 $CO tester@127.0.0.1 'sudo -n poweroff' >/dev/null 2>&1
for _ in $(seq 1 90); do kill -0 "$P" 2>/dev/null || break; sleep 2; done
kill -0 "$P" 2>/dev/null && { kill -TERM "$P"; sleep 5; }
kill -0 "$P" 2>/dev/null && echo "STILL RUNNING $P" || echo "vm stopped"
echo "T2_SHIPPING_DONE"
