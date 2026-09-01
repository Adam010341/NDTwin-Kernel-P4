#!/bin/bash
# ============================================================================================
# A-3 step 5b (on nslab): power the guest off, flatten the overlay, repack with ovftool.
#
# WHAT THIS INHERITS RATHER THAN INVENTS. The .vmx is regenerated from the CURRENT shipping
# .ova, so the hardware declaration is the one already proven to import; only the disk is
# replaced. Hand-writing an OVF descriptor is what produced the manifest VMware rejects.
#
# --lax IS NOT USED. It wrote virtualhw.version = 99 and named the VM "x", and that shipped,
# because the negative control at the time varied the DISK HASH while the defect was in the
# HARDWARE DECLARATION. A control only covers the dimension it varies -- so there are two
# controls here, and one of them reads the declaration back.
#
# --verifyOnly IS NOT USED as evidence. It returns 0 on a truncated archive and on a
# byte-flipped one. What is checked is the CONVERSION path, ova -> vmx, which is what an
# import actually performs.
#
# 🔴 EACH ARM OF THE NEGATIVE CONTROL GETS ITS OWN FRESH EMPTY DIRECTORY. H-26 phase L left
#    imp-disk1.vmdk behind, so the POSITIVE arm died on "File already exists" before ovftool
#    read the archive at all: both arms returned 1, for unrelated reasons, and the pair had
#    zero discriminating power while looking reassuring. The assertion below is on the PAIR.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
set -u
T=/home/nslab/ovftool-dist/ovftool/ovftool
VM_DIR=/home/nslab/ndtwin-vm-a3
SRC=/home/nslab/repack/out/NDTwin-P4-demo.ova     # the current shipping artefact
W=/home/nslab/a3repack
ANN=/home/nslab/annotation.txt
SSH_PORT=2299

echo "=== $(date -Is) A-3 pack ==="

# --------------------------------------------------------------------------------------------
echo
echo "=== P0. power the guest off, and prove it is off ==="
export SSH_ASKPASS="$VM_DIR/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
ssh -p $SSH_PORT $CO tester@127.0.0.1 'sync; sudo -n poweroff' >/dev/null 2>&1
P=$(head -1 "$VM_DIR/qemu.pid" 2>/dev/null)
echo "  qemu pid was: ${P:-unknown}"
for i in $(seq 1 90); do [ -d "/proc/$P" ] || break; sleep 2; done
if [ -d "/proc/$P" ]; then
    echo "  still alive after 180s -- SIGTERM"; kill -TERM "$P" 2>/dev/null; sleep 10
fi
# state, not rc, and via /proc rather than any pattern match on a process list
if [ -d "/proc/$P" ]; then echo "  🔴 qemu $P STILL RUNNING -- refusing to read its disk"; exit 1
else echo "  ✅ qemu $P is gone (/proc/$P absent)"; fi
if ss -tlnH "( sport = :$SSH_PORT )" 2>/dev/null | grep -q .; then
    echo "  🔴 :$SSH_PORT still listening"; exit 1
else echo "  ✅ :$SSH_PORT is not listening"; fi

# --------------------------------------------------------------------------------------------
echo
echo "=== P1. flatten the overlay (backing chain is followed; the guest disk is not touched) ==="
rm -rf "$W"; mkdir -p "$W/out"
qemu-img info "$VM_DIR/disk.qcow2" | sed 's/^/  /'

echo
echo "=== P2. inherit the hardware declaration from the CURRENT shipping .ova ==="
echo "  source: $SRC ($(stat -c%s "$SRC") bytes)"
sha256sum "$SRC" | sed 's/^/  /'
"$T" "$SRC" "$W/NDTwin-P4-demo.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -3
grep -iE '^displayname|^virtualhw\.version|^memsize|^numvcpus|fileName|^sata|^ethernet0\.virtualDev|^guestOS' \
    "$W/NDTwin-P4-demo.vmx" | sed 's/^/  /'
OLDVMDK=$(grep -ioE '^sata0:0\.fileName = "[^"]+"' "$W/NDTwin-P4-demo.vmx" | sed 's/.*"\(.*\)"/\1/')
[ -z "$OLDVMDK" ] && OLDVMDK=$(ls "$W"/*.vmdk 2>/dev/null | head -1 | xargs -r basename)
echo "  the vmx points at: $OLDVMDK"

echo
echo "=== P3. replace ONLY the disk, with the flattened A-3 image ==="
ls -la "$W/$OLDVMDK" | sed 's/^/  before: /'
qemu-img convert -p -f qcow2 -O vmdk -o subformat=monolithicSparse \
    "$VM_DIR/disk.qcow2" "$W/$OLDVMDK.new" 2>&1 | tail -2
if [ ! -s "$W/$OLDVMDK.new" ]; then echo "  🔴 convert produced nothing -- STOP"; exit 1; fi
mv -f "$W/$OLDVMDK.new" "$W/$OLDVMDK"
ls -la "$W/$OLDVMDK" | sed 's/^/  after:  /'
qemu-img info "$W/$OLDVMDK" 2>&1 | grep -E 'file format|virtual size' | sed 's/^/    /'

# --------------------------------------------------------------------------------------------
echo
echo "=== P4. pack: no --lax, hardware version capped, annotation replaced ==="
echo "  annotation is $(wc -c < "$ANN") bytes, $(wc -w < "$ANN") words"
"$T" --maxVirtualHardwareVersion=14 --annotation="$(cat "$ANN")" \
    "$W/NDTwin-P4-demo.vmx" "$W/out/NDTwin-P4-demo.ova" 2>&1 \
    | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -4

if [ ! -s "$W/out/NDTwin-P4-demo.ova" ]; then echo "  🔴 no artefact produced -- STOP"; exit 1; fi

# --------------------------------------------------------------------------------------------
echo
echo "=== P5. CONTROL A -- read back what the product DECLARES (not whether files exist) ==="
rm -rf "$W/peek"; mkdir -p "$W/peek"; cd "$W/peek" || exit 1
tar -xf "$W/out/NDTwin-P4-demo.ova" --wildcards '*.ovf'
N=$(grep -oE '<Name>[^<]*' ./*.ovf | head -1 | sed 's/<Name>//')
V=$(grep -oE '<vssd:VirtualSystemType>[^<]*' ./*.ovf | head -1 | sed 's/.*>//')
[ "$N" = "NDTwin-P4-demo" ] && echo "  PASS: <Name> = $N" || echo "  🔴 FAIL: <Name> = '$N'"
[ "$V" = "vmx-14" ]         && echo "  PASS: VirtualSystemType = $V" || echo "  🔴 FAIL: VirtualSystemType = '$V'"
echo "  controller/NIC actually declared:"
grep -oE 'vmware\.sata\.ahci|E1000|PCNet32|lsilogic' ./*.ovf | sort -u | sed 's/^/    /'
echo "  cpu/mem declared:"
grep -oE '<rasd:VirtualQuantity>[0-9]*' ./*.ovf | head -3 | sed 's/^/    /'

echo
echo "  --- CONTROL C: does the declaration DESCRIBE the new content? ---"
echo "     (H-26 shipped an annotation that mentioned the four trees zero times)"
python3 - "$PWD" <<'PY'
import glob,sys,html,re
ovf=glob.glob(sys.argv[1]+'/*.ovf')[0]
t=open(ovf,encoding='utf-8',errors='replace').read()
m=re.search(r'<Info>[^<]*</Info>\s*<Annotation>(.*?)</Annotation>', t, re.S)
if not m: m=re.search(r'<Annotation>(.*?)</Annotation>', t, re.S)
ann=html.unescape(m.group(1)) if m else ''
print(f"    annotation length in the OVF: {len(ann)} chars")
checks={
 'doc/ removal stated':'doc/',
 'NTV pinned commit b5e039c':'b5e039c',
 'the absent endpoint named':'disable_switch',
 'public snapshot named':'NDTwin-Kernel-P4-public',
 'Energy-Saving-App':'Energy-Saving-App',
 'Simulation-Platform-Manager':'Simulation-Platform-Manager',
 'Traffic-Engineering-App':'Traffic-Engineering-App',
 'Network-Traffic-Visualizer':'Network-Traffic-Visualizer',
}
bad=0
for label,needle in checks.items():
    ok = needle in ann
    print(f"    [{'PASS' if ok else 'FAIL'}] {label}")
    if not ok: bad+=1
print("    ==> annotation describes the new content" if bad==0
      else f"    ==> 🔴 {bad} thing(s) the annotation fails to mention")
PY

# --------------------------------------------------------------------------------------------
echo
echo "=== P6. CONTROL B -- the import conversion, PAIRED, each arm in a fresh empty dir ==="
rm -rf "$W/cb_pos" "$W/cb_neg"; mkdir -p "$W/cb_pos" "$W/cb_neg"
echo "  positive dir contents before: $(ls -A "$W/cb_pos" | wc -l) (must be 0)"
echo "  negative dir contents before: $(ls -A "$W/cb_neg" | wc -l) (must be 0)"

echo
echo "  --- POSITIVE arm: the artefact as packed ---"
POUT=$("$T" "$W/out/NDTwin-P4-demo.ova" "$W/cb_pos/imp.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$')
echo "$POUT" | tail -3 | sed 's/^/    /'
PV=$(echo "$POUT" | grep -qE 'Completed successfully' && echo 0 || echo 1)
echo "    positive verdict (by outcome text, never a pipeline rc): $PV   <-- must be 0"

echo
echo "  --- NEGATIVE arm: one byte flipped mid-disk, own fresh dir ---"
cp "$W/out/NDTwin-P4-demo.ova" "$W/cb_neg/flip.ova"
SZ=$(stat -c%s "$W/cb_neg/flip.ova")
printf '\xff' | dd of="$W/cb_neg/flip.ova" bs=1 seek=$(( SZ / 2 )) count=1 conv=notrunc status=none
echo "    flipped byte at offset $(( SZ / 2 )) of $SZ"
NOUT=$("$T" "$W/cb_neg/flip.ova" "$W/cb_neg/z.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$')
echo "$NOUT" | tail -3 | sed 's/^/    /'
NV=$(echo "$NOUT" | grep -qE 'Completed successfully' && echo 0 || echo 1)
echo "    negative verdict: $NV   <-- must be 1"

echo
echo "  --- the assertion is on the PAIR ---"
if [ "$PV" = 0 ] && [ "$NV" = 1 ]; then
  echo "    ✅ PASS: the arms DIFFER (good=0, corrupted=1) -- the check discriminates"
  echo "$NOUT" | grep -i 'digest\|does not match\|error' | head -1 | sed 's/^/      why the bad one failed: /'
else
  echo "    🔴 FAIL: arms did not differ (positive=$PV negative=$NV) -- this proves nothing"
fi

echo
echo "  --- and for the record, what --verifyOnly says about the CORRUPTED file ---"
"$T" --verifyOnly "$W/cb_neg/flip.ova" >/dev/null 2>&1
echo "    ovftool --verifyOnly on the byte-flipped archive returned: $?  (0 here is why it is not used as evidence)"
rm -rf "$W/cb_pos" "$W/cb_neg"

# --------------------------------------------------------------------------------------------
echo
echo "=== P7. identity of the new artefact ==="
stat -c '  %n  %s bytes' "$W/out/NDTwin-P4-demo.ova"
sha256sum "$W/out/NDTwin-P4-demo.ova" | sed 's/^/  /'
OLD=$(stat -c%s "$SRC"); NEW=$(stat -c%s "$W/out/NDTwin-P4-demo.ova")
echo "  old: $OLD bytes"
echo "  new: $NEW bytes"
echo "  change: $(( (OLD - NEW) )) bytes  =  $(( (OLD - NEW) / 1048576 )) MiB smaller"
echo "PACK_DONE"
