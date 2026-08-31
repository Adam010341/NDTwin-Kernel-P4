#!/bin/bash
# Verify the hand-written .ova with VMware's own tool -- the one check this project could not
# perform until now, and the one the README has been carrying as an open item all day.
#
# The OVF descriptor and manifest in this archive were written by hand, without ovftool,
# because it was not obtainable here. Every prior check used a different implementation
# (qemu boots the disk, VirtualBox parsed the descriptor). Those establish that the artefact
# is coherent; none of them establish that VMware accepts it, and VMware is what the download
# page tells readers to use.
#
# NEGATIVE CONTROLS, because "verifyOnly passed" is worth nothing from a checker that passes
# anything. Two, testing different layers:
#   C1 truncated archive  -> must fail. Tests that it reads past the descriptor at all.
#   C2 one flipped byte in the disk -> must fail on the manifest's SHA256. Tests that the
#      manifest is actually being checked rather than merely present. C1 alone would not
#      catch a tool that validates structure and ignores hashes.
# If either control passes, every result in this run is void.
#
# [Co-developed with claude code -- Adam]
set -u

OVFTOOL=/home/nslab/ovftool-dist/ovftool/ovftool
OVA=/home/nslab/NDTwin-P4-demo.ova
WORK=/home/nslab/ovftool-check
mkdir -p "$WORK"

echo "############ 0. tool ############"
"$OVFTOOL" --version

echo
echo "############ 1. --verifyOnly on the real artefact ############"
"$OVFTOOL" --verifyOnly "$OVA"
echo "VERIFY_EXIT=$?"

echo
echo "############ 2. --schemaValidate ############"
"$OVFTOOL" --schemaValidate --verifyOnly "$OVA" 2>&1
echo "SCHEMA_EXIT=$?"

echo
echo "############ 3. translate to VMware's own format (.vmx) ############"
echo "# the strongest of the three: VMware writing its own config from this descriptor,"
echo "# which exercises fields --verifyOnly never has to interpret"
rm -rf "$WORK/vmx"; mkdir -p "$WORK/vmx"
"$OVFTOOL" --lax --noSSLVerify "$OVA" "$WORK/vmx/NDTwin-P4-demo.vmx"
echo "CONVERT_EXIT=$?"
echo "--- produced ---"
ls -la "$WORK/vmx/" 2>/dev/null
echo "--- the .vmx VMware generated ---"
cat "$WORK/vmx/NDTwin-P4-demo.vmx" 2>/dev/null | head -40

echo
echo "############ C1. NEGATIVE CONTROL: truncated archive ############"
head -c 200000000 "$OVA" > "$WORK/truncated.ova"
"$OVFTOOL" --verifyOnly "$WORK/truncated.ova" 2>&1 | tail -5
echo "C1_EXIT=${PIPESTATUS[0]}  <-- must be NON-zero"

echo
echo "############ C2. NEGATIVE CONTROL: one flipped byte in the disk ############"
cp "$OVA" "$WORK/flipped.ova"
SZ=$(stat -c%s "$WORK/flipped.ova")
OFF=$((SZ / 2))
printf '\xff' | dd of="$WORK/flipped.ova" bs=1 seek="$OFF" count=1 conv=notrunc status=none
echo "flipped one byte at offset $OFF of $SZ"
"$OVFTOOL" --verifyOnly "$WORK/flipped.ova" 2>&1 | tail -5
echo "C2_EXIT=${PIPESTATUS[0]}  <-- must be NON-zero (manifest SHA256 mismatch)"

rm -f "$WORK/truncated.ova" "$WORK/flipped.ova"
echo
echo "OVFTOOL_CHECK_DONE"
