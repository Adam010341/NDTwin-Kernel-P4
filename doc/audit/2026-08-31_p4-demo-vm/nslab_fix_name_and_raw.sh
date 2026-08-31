#!/bin/bash
# Two things, both about the same doubt: how much of this artefact is still the thing that
# passed its tests, and how much is a repack nobody has looked at.
#
# A. THE DISPLAY NAME. --name did not change the OVF's <Name>; it stayed "x", the filename of
#    the intermediate .vmx. VMware's import dialog pre-fills from it, so a user would import a
#    VM called "x". The name is set by the .vmx's displayname, which is taken from the target
#    filename -- which is how "x" got in. So convert to a correctly-named .vmx and back.
#    No --lax anywhere: the source is vmx-14 now, and if the round trip needs --lax again that
#    is a result worth seeing rather than suppressing.
#
# B. DID THE GUEST BYTES EVER CHANGE. The fabric acceptance (T-2: 32 links / 12 paths /
#    pingall 12/12) was run on the disk unpacked from the HAND-WRITTEN .ova. Every artefact
#    since is an ovftool repack of that disk, and the only check run on a repacked disk was a
#    boot that confirmed three binaries exist. "The binaries are there" is not "the fabric
#    forwards".
#    Re-running T-2 would answer it. Comparing the decompressed images answers it better and
#    cheaper: if the raw bytes are identical, T-2's result transfers as a fact rather than as
#    an inference, and no re-run can add anything. If they differ, T-2 must be re-run and the
#    difference explained first.
#    streamOptimized VMDKs are compressed, so their file hashes differ even for identical
#    content. Raw is the level where the question is meaningful.
#
# [Co-developed with claude code -- Adam]
set -u

T=/home/nslab/ovftool-dist/ovftool/ovftool
IN=/home/nslab/ovftool-check/fixed/NDTwin-P4-demo.ova
W=/home/nslab/ovftool-check/named
rm -rf "$W"; mkdir -p "$W"

echo "=== A1. ova -> correctly-named vmx ==="
"$T" "$IN" "$W/NDTwin-P4-demo.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -5
echo "EXIT=${PIPESTATUS[0]}"
grep -E '^displayname|^virtualhw\.version' "$W/NDTwin-P4-demo.vmx"

echo
echo "=== A2. vmx -> ova ==="
mkdir -p "$W/out"
"$T" "$W/NDTwin-P4-demo.vmx" "$W/out/NDTwin-P4-demo.ova" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -5
echo "EXIT=${PIPESTATUS[0]}"

echo
echo "=== A3. what the product declares now ==="
rm -rf /tmp/peek3; mkdir -p /tmp/peek3; cd /tmp/peek3 || exit 1
tar -xf "$W/out/NDTwin-P4-demo.ova" --wildcards '*.ovf'
grep -oE '<Name>[^<]*|<vssd:VirtualSystemType>[^<]*|vmware\.sata\.ahci|E1000' ./*.ovf | head -8
echo "--- annotation kept? (must be 1) ---"; grep -c 'PROVENANCE.txt' ./*.ovf

echo
echo "=== A4. import path + negative control ==="
"$T" "$W/out/NDTwin-P4-demo.ova" "$W/imp.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -3
echo "CONVERT_EXIT=${PIPESTATUS[0]}  <-- must be 0"
cp "$W/out/NDTwin-P4-demo.ova" "$W/flip.ova"
SZ=$(stat -c%s "$W/flip.ova")
printf '\xff' | dd of="$W/flip.ova" bs=1 seek=$(( SZ / 2 )) count=1 conv=notrunc status=none
"$T" "$W/flip.ova" "$W/z.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -3
echo "CONTROL_EXIT=${PIPESTATUS[0]}  <-- must be NON-zero"
rm -f "$W/flip.ova"

echo
echo "=== B. raw sha256 of the shipping disk ==="
rm -rf "$W/x"; mkdir -p "$W/x"; cd "$W/x" || exit 1
tar -xf "$W/out/NDTwin-P4-demo.ova" --wildcards '*.vmdk'
D=$(ls ./*.vmdk | head -1)
echo "vmdk: $D  $(stat -c%s "$D") bytes"
echo "vmdk sha256: $(sha256sum "$D" | cut -d' ' -f1)"
echo "decompressing to raw and hashing (60 GB stream, nothing written to disk)..."
qemu-img convert -f vmdk -O raw "$D" /dev/stdout | sha256sum
echo "^^ RAW_SHA256 of the ovftool-packed disk"

echo
echo "=== identity ==="
stat -c '%n %s bytes' "$W/out/NDTwin-P4-demo.ova"
md5sum "$W/out/NDTwin-P4-demo.ova"
sha256sum "$W/out/NDTwin-P4-demo.ova"
echo "NAMEFIX_DONE"
