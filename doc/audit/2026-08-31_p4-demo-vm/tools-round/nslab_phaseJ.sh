#!/bin/bash
# H-26 phase J: repack the modified disk into a .ova, and check the two things that have each
# already gone wrong once on this artefact.
#
# FAILURE 1, WHICH SHIPPED: `--lax` wrote virtualhw.version = "99" and <Name>x. It got past the
#   whole verification round because the negative control varied the DISK HASH while the defect
#   was in the HARDWARE DECLARATION. A control only covers the dimension it varies. So this run
#   has TWO controls: a flipped byte (disk integrity) and an explicit read-back of what the
#   product declares (hardware identity), and `--lax` is not used at all.
#
# FAILURE 2, WHICH ALMOST SHIPPED A FALSE PASS: `ovftool --verifyOnly` returns 0 on a truncated
#   archive and on a byte-flipped one. It is not used here. The check is the CONVERSION path --
#   ova -> vmx -- which is what an import actually does and what actually fails on bad data.
#
# NOT REUSED: `qemu-img convert -O raw src /dev/stdout | sha256sum`. It cannot resize a pipe, so
#   it converts nothing and the hash printed is e3b0c442... , the sha256 of zero bytes. It would
#   have declared any two images identical.
#
# The .vmx is regenerated from the CURRENT shipping .ova rather than hand-written, so the
# hardware declaration is the one already proven to import; only the disk is replaced.
#
# [Co-developed with claude code -- Adam]
set -u
T=/home/nslab/ovftool-dist/ovftool/ovftool
SRC=/home/nslab/NDTwin-P4-demo.ova
OVL=/home/nslab/addtools/work.qcow2
W=/home/nslab/repack
rm -rf "$W"; mkdir -p "$W/out"

echo "=== $(date -Is) phase J ==="
echo "source of the hardware declaration: $SRC ($(stat -c%s "$SRC") bytes)"
sha256sum "$SRC" | sed 's/^/  /'

echo
echo "=== J1. current .ova -> .vmx, to inherit its declaration ==="
"$T" "$SRC" "$W/NDTwin-P4-demo.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -4
echo "EXIT=${PIPESTATUS[0]}"
grep -iE '^displayname|^virtualhw\.version|^memsize|^numvcpus|fileName|^sata|^ethernet0\.virtualDev|^guestOS' "$W/NDTwin-P4-demo.vmx" | sed 's/^/  /'
OLDVMDK=$(grep -ioE '^sata0:0\.fileName = "[^"]+"' "$W/NDTwin-P4-demo.vmx" | sed 's/.*"\(.*\)"/\1/')
[ -z "$OLDVMDK" ] && OLDVMDK=$(ls "$W"/*.vmdk 2>/dev/null | head -1 | xargs -r basename)
echo "  disk the vmx points at: $OLDVMDK"
echo "  its ddb.adapterType: $(head -c 2048 "$W/$OLDVMDK" | strings | grep -i adapterType | head -1)"

echo
echo "=== J2. replace ONLY the disk, with the flattened overlay ==="
ls -la "$W/$OLDVMDK" | sed 's/^/  before: /'
qemu-img convert -p -f qcow2 -O vmdk -o subformat=monolithicSparse "$OVL" "$W/$OLDVMDK.new" 2>&1 | tail -2
if [ ! -s "$W/$OLDVMDK.new" ]; then echo "🔴 convert produced nothing -- STOP"; exit 1; fi
mv -f "$W/$OLDVMDK.new" "$W/$OLDVMDK"
ls -la "$W/$OLDVMDK" | sed 's/^/  after:  /'
echo "  sanity: does the new disk still contain a bootable filesystem?"
qemu-img info "$W/$OLDVMDK" 2>&1 | grep -E 'file format|virtual size' | sed 's/^/    /'

echo
echo "=== J3. vmx -> ova, WITHOUT --lax, hardware version capped explicitly ==="
"$T" --maxVirtualHardwareVersion=14 "$W/NDTwin-P4-demo.vmx" "$W/out/NDTwin-P4-demo.ova" 2>&1 \
  | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -5
echo "EXIT=${PIPESTATUS[0]}"

echo
echo "=== J4. CONTROL A (hardware identity): read back what the product declares ==="
rm -rf "$W/peek"; mkdir -p "$W/peek"; cd "$W/peek" || exit 1
tar -xf "$W/out/NDTwin-P4-demo.ova" --wildcards '*.ovf'
grep -oE '<Name>[^<]*|<vssd:VirtualSystemType>[^<]*|vmware\.sata\.ahci|E1000|<rasd:VirtualQuantity>[^<]*' ./*.ovf | head -10 | sed 's/^/  /'
echo "  --- the two values that shipped wrong last time ---"
N=$(grep -oE '<Name>[^<]*' ./*.ovf | head -1 | sed 's/<Name>//')
V=$(grep -oE '<vssd:VirtualSystemType>[^<]*' ./*.ovf | head -1 | sed 's/.*>//')
[ "$N" = "NDTwin-P4-demo" ] && echo "  PASS: <Name> = $N" || echo "  🔴 FAIL: <Name> = '$N' (expected NDTwin-P4-demo)"
[ "$V" = "vmx-14" ]         && echo "  PASS: VirtualSystemType = $V" || echo "  🔴 FAIL: VirtualSystemType = '$V' (expected vmx-14)"

echo
echo "=== J5. CONTROL B (disk integrity): the import conversion, then the same on a flipped byte ==="
"$T" "$W/out/NDTwin-P4-demo.ova" "$W/imp.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -3
echo "CONVERT_EXIT=${PIPESTATUS[0]}   <-- must be 0"
cp "$W/out/NDTwin-P4-demo.ova" "$W/flip.ova"
SZ=$(stat -c%s "$W/flip.ova")
printf '\xff' | dd of="$W/flip.ova" bs=1 seek=$(( SZ / 2 )) count=1 conv=notrunc status=none
"$T" "$W/flip.ova" "$W/z.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -3
echo "CONTROL_EXIT=${PIPESTATUS[0]}   <-- must be NON-zero"
rm -f "$W/flip.ova"; rm -rf "$W/z.vmx" "$W/imp.vmx"

echo
echo "=== J6. identity of the new artefact ==="
stat -c '  %n  %s bytes' "$W/out/NDTwin-P4-demo.ova"
sha256sum "$W/out/NDTwin-P4-demo.ova" | sed 's/^/  /'
md5sum    "$W/out/NDTwin-P4-demo.ova" | sed 's/^/  /'
df -h /home | tail -1
echo "PHASE_J_DONE"
