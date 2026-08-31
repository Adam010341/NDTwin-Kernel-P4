#!/bin/bash
# Repair two defects the rebuild introduced, both invisible to the check that passed.
#
# WHAT WENT WRONG
#   Rebuilding through an intermediate .vmx was done with --lax, which prints
#   "Hardware compatibility check is disabled" and then writes virtualhw.version = "99"
#   into the .vmx. The .ova built from that .vmx therefore declares
#   <vssd:VirtualSystemType>vmx-99 -- a hardware version no VMware product implements.
#   The hand-written descriptor it replaced declared vmx-14. So the rebuild that fixed the
#   manifest regressed the hardware declaration, and the intermediate also carried the
#   target filename through as the VM's display name: <Name>x.
#
# WHY "Completed successfully" DID NOT CATCH IT
#   The check was ovftool reading an archive ovftool had just written. It confirms the
#   archive is self-consistent; it cannot confirm the hardware version is one that exists,
#   because ovftool is the tool that was told not to look. The negative control that did
#   work tested the DISK HASH -- a different dimension entirely. Verifying the mechanism
#   (does ovftool accept this) is not verifying the purpose (will a user's VMware import it).
#
# ACCEPTANCE, on the artefact this produces rather than on its ancestor:
#   1. the OVF declares vmx-14 and the VM is named NDTwin-P4-demo
#   2. the annotation and all four hardware facts survive (4 vCPU / 6144 MB / AHCI / E1000)
#   3. the full conversion path -- the one a user's import takes -- completes
#   4. a flipped byte on that same path still fails
#
# [Co-developed with claude code -- Adam]
set -u

T=/home/nslab/ovftool-dist/ovftool/ovftool
SRC=/home/nslab/NDTwin-P4-demo.ova
OUT=/home/nslab/ovftool-check/fixed
rm -rf "$OUT"; mkdir -p "$OUT"

echo "=== 0. what the source declares (the defect, stated before the fix) ==="
rm -rf /tmp/ovfpeek; mkdir -p /tmp/ovfpeek; cd /tmp/ovfpeek || exit 1
tar -xf "$SRC" --wildcards '*.ovf'
grep -oE '<vssd:VirtualSystemType>[^<]*|<Name>[^<]*' ./*.ovf

echo
echo "=== 1. rebuild with the hardware version capped and the name set ==="
"$T" --lax --name=NDTwin-P4-demo --maxVirtualHardwareVersion=14 \
     "$SRC" "$OUT/NDTwin-P4-demo.ova" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$'
echo "REBUILD_EXIT=${PIPESTATUS[0]}"
ls -la "$OUT"

echo
echo "=== 2. what the product declares ==="
rm -rf /tmp/ovfpeek2; mkdir -p /tmp/ovfpeek2; cd /tmp/ovfpeek2 || exit 1
tar -xf "$OUT/NDTwin-P4-demo.ova" --wildcards '*.ovf'
grep -oE '<vssd:VirtualSystemType>[^<]*|<Name>[^<]*' ./*.ovf
echo "--- hardware ---"
grep -oE 'virtual CPU\(s\)|[0-9]+MB of memory|vmware\.sata\.ahci|E1000|<rasd:VirtualQuantity>[0-9]+' ./*.ovf | head -12
echo "--- annotation present? ---"
grep -c 'PROVENANCE.txt' ./*.ovf

echo
echo "=== 3. the real import path (convert to VMware's own format) ==="
rm -rf "$OUT/t"; mkdir -p "$OUT/t"
"$T" "$OUT/NDTwin-P4-demo.ova" "$OUT/t/imported.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -8
echo "CONVERT_EXIT=${PIPESTATUS[0]}   <-- must be 0, and note: NO --lax this time"
echo "--- the hardware version VMware wrote for itself ---"
grep -E '^virtualhw\.version|^displayname|^numvcpus|^memsize|^sata0:0\.present|^ethernet0\.virtualdev' "$OUT/t/imported.vmx"

echo
echo "=== 4. NEGATIVE CONTROL on that same path ==="
cp "$OUT/NDTwin-P4-demo.ova" "$OUT/flip.ova"
SZ=$(stat -c%s "$OUT/flip.ova")
printf '\xff' | dd of="$OUT/flip.ova" bs=1 seek=$(( SZ / 2 )) count=1 conv=notrunc status=none
rm -rf "$OUT/tc"; mkdir -p "$OUT/tc"
"$T" "$OUT/flip.ova" "$OUT/tc/z.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -4
echo "CONTROL_EXIT=${PIPESTATUS[0]}   <-- must be NON-zero"
rm -f "$OUT/flip.ova"; rm -rf "$OUT/tc"

echo
echo "=== 5. identity of the artefact ==="
stat -c '%n %s bytes' "$OUT/NDTwin-P4-demo.ova"
md5sum "$OUT/NDTwin-P4-demo.ova"
sha256sum "$OUT/NDTwin-P4-demo.ova"
echo "HWFIX_DONE"
