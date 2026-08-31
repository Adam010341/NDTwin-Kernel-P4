#!/bin/bash
# H-26 phase L: the front door was still describing the old image.
#
# 🔴 WHAT PHASE J SHIPPED AND I ONLY NOTICED AFTERWARDS. The OVF annotation -- the text a
#    VMware user reads in the import dialog, before anything else -- survived the repack
#    unchanged, and it now says two things that are no longer true:
#      * it lists the kernel, Ryu, Mininet, OVS, p4c and BMv2, and does not mention that four
#        application repositories were added and built;
#      * it says the provenance of the stripped trees is in
#        ~/Desktop/NDTwin-Kernel/PROVENANCE.txt -- which covers the kernel only. I deleted the
#        .git of four MORE trees tonight and recorded them in a different file. So the index a
#        recipient is pointed at is now an index that omits most of what it claims to cover.
#
# 🔑 The check that would have caught it is not a harder check, it is a different question. I
#    verified what the artefact DECLARES about its hardware, because that is where it went
#    wrong last time. Nobody verified what it declares about its CONTENTS, because that had
#    never gone wrong before. A round of fixes tends to grow controls for the previous defect.
#
# The disk has to be reconverted (any guest edit changes the qcow2), so the phase J output is
# discarded rather than patched. That costs one convert plus one pack.
#
#
# 🔴 THE FORWARD IS BOUND TO 127.0.0.1, AND IT WAS NOT DURING THE RUN THIS SCRIPT RECORDS.
#   Every VM in tonight's round was started with `hostfwd=tcp::<port>-:22`. qemu documents the
#   host address as optional and treats an omitted one as "bind on all interfaces", so what
#   was actually listening was 0.0.0.0:<port>, forwarding to a guest whose password is
#   tester/tester. Measured, not inferred: `ss -tlnH "( sport = :2297 )"` returned
#   `LISTEN 0 1 0.0.0.0:2297`. Exposure was for the life of each VM, on the lab network.
#
# 🔑 It surfaced sideways, and that is the part worth keeping. The ndtwin-vm.sh `adopt` verb
#   reported `port=2222` for a VM whose argv says 2296, under a banner reading "Read out of
#   its argv, not typed in". Its regex requires `hostfwd=tcp:127.0.0.1:` because that is the
#   form its own scripts emit. Chasing why the parser missed my VM is what showed that the
#   difference between the two forms is not formatting -- it is whether the port is reachable
#   from off the host. A parser that only understands its own output cannot warn you about
#   the input it does not recognise, which is exactly the input worth warning about.
# [Co-developed with claude code -- Adam]
set -u
T=/home/nslab/ovftool-dist/ovftool/ovftool
W=/home/nslab/addtools
R=/home/nslab/repack
OVL="$W/work.qcow2"
[ -s "$OVL" ] || { echo "no overlay -- stop"; exit 1; }

echo "=== $(date -Is) phase L ==="
echo "=== L1. boot the overlay again to fix the two documents ==="
qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 4 \
  -device ahci,id=ahci0 \
  -drive id=d0,file="$OVL",if=none,format=qcow2,discard=unmap \
  -device ide-hd,drive=d0,bus=ahci0.0,discard_granularity=512 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2296-:22 -device e1000,netdev=n0 \
  -display none -daemonize -pidfile "$W/vm.pid"
sleep 2
P=$(cat "$W/vm.pid" 2>/dev/null)
kill -0 "$P" 2>/dev/null || { echo "FAILED to start"; exit 1; }
taskset -acp 24-27 "$P" >/dev/null 2>&1
echo "  qemu pid $P, pinned 24-27 (same working point as the registered H-26 row)"
printf '#!/bin/sh\necho tester\n' > "$W/.ask"; chmod 700 "$W/.ask"
export SSH_ASKPASS="$W/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
G="tester@127.0.0.1"
S(){ ssh -p 2296 $CO $G "$@"; }
up=0; for i in $(seq 1 40); do S 'echo up' 2>/dev/null | grep -q up && { up=1; break; }; sleep 10; done
[ "$up" = 1 ] || { echo "SSH DID NOT COME UP"; exit 1; }
echo "  ssh up after ~$((i*10))s"

echo
echo "=== L2. is the file the old annotation points at even there? ==="
S 'ls -la /home/tester/Desktop/NDTwin-Kernel/PROVENANCE.txt 2>&1 | tail -1
   echo "  it covers:"; grep -icE "energy|simulation-platform|traffic-engineering|visualizer" /home/tester/Desktop/NDTwin-Kernel/PROVENANCE.txt 2>/dev/null'

echo
echo "=== L3. make ~/Desktop/PROVENANCE.txt the single entry point ==="
scp -P 2296 $CO /home/nslab/provenance_tail.txt $G:/home/tester/ >/dev/null
S 'cat /home/tester/provenance_tail.txt >> /home/tester/Desktop/PROVENANCE.txt
   rm -f /home/tester/provenance_tail.txt
   echo "  PROVENANCE.txt is now $(wc -l < /home/tester/Desktop/PROVENANCE.txt) lines"
   tail -12 /home/tester/Desktop/PROVENANCE.txt | sed "s/^/    /"'

echo
echo "=== L4. trim and power off ==="
S 'sudo -n apt-get clean; sudo -n journalctl --rotate --vacuum-time=1s >/dev/null 2>&1
   rm -f /tmp/*.out 2>/dev/null; sudo -n fstrim -av 2>&1 | head -3; sync'
S 'sudo -n poweroff' >/dev/null 2>&1
for i in $(seq 1 24); do kill -0 "$P" 2>/dev/null || break; sleep 5; done
kill -0 "$P" 2>/dev/null && { echo "🔴 qemu $P still alive -- look before acting"; exit 1; }
echo "  qemu $P exited cleanly; overlay $(du -sh "$OVL" | cut -f1) on disk"
rm -f "$W/.ask"

echo
echo "=== L5. reconvert the disk ==="
rm -rf "$R/out" "$R/peek"; mkdir -p "$R/out"
qemu-img convert -f qcow2 -O vmdk -o subformat=monolithicSparse "$OVL" "$R/NDTwin-P4-demo-disk1.vmdk.new" 2>&1 | tail -1
[ -s "$R/NDTwin-P4-demo-disk1.vmdk.new" ] || { echo "convert produced nothing -- STOP"; exit 1; }
mv -f "$R/NDTwin-P4-demo-disk1.vmdk.new" "$R/NDTwin-P4-demo-disk1.vmdk"
echo "  vmdk: $(stat -c%s "$R/NDTwin-P4-demo-disk1.vmdk") bytes"

echo
echo "=== L6. rewrite the annotation, and assert the rewrite took ==="
python3 - "$R/NDTwin-P4-demo.vmx" /home/nslab/annotation.txt <<'PY'
import sys
vmx, ann = sys.argv[1], sys.argv[2]
new = open(ann, encoding="utf-8").read().strip().replace('"', "'")
lines = open(vmx, encoding="utf-8").read().splitlines()
hit = 0
for i, l in enumerate(lines):
    if l.lower().startswith("annotation ="):
        lines[i] = 'annotation = "%s"' % new; hit += 1
if hit != 1:
    print("  FAIL: expected exactly 1 annotation line, found %d -- not writing" % hit); sys.exit(1)
open(vmx, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("  annotation line replaced (1 of 1)")
PY
[ $? -eq 0 ] || exit 1
grep -c 'Network-Traffic-Visualizer' "$R/NDTwin-P4-demo.vmx" | sed 's/^/  vmx now mentions the apps: /'

echo
echo "=== L7. pack, then both controls again ==="
"$T" --maxVirtualHardwareVersion=14 "$R/NDTwin-P4-demo.vmx" "$R/out/NDTwin-P4-demo.ova" 2>&1 \
  | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -4
echo "EXIT=${PIPESTATUS[0]}"

mkdir -p "$R/peek"; cd "$R/peek" || exit 1
tar -xf "$R/out/NDTwin-P4-demo.ova" --wildcards '*.ovf'
N=$(grep -oE '<Name>[^<]*' ./*.ovf | head -1 | sed 's/<Name>//')
V=$(grep -oE '<vssd:VirtualSystemType>[^<]*' ./*.ovf | head -1 | sed 's/.*>//')
[ "$N" = "NDTwin-P4-demo" ] && echo "  PASS: <Name> = $N" || echo "  🔴 FAIL: <Name> = '$N'"
[ "$V" = "vmx-14" ]         && echo "  PASS: VirtualSystemType = $V" || echo "  🔴 FAIL: type = '$V'"
echo "  --- CONTROL C (contents, the one that was missing): does the annotation describe what is inside? ---"
for k in Energy-Saving-App Simulation-Platform-Manager Traffic-Engineering-App Network-Traffic-Visualizer 'Desktop/PROVENANCE.txt' 'README-NDTwin-tools.md'; do
  c=$(grep -c "$k" ./*.ovf)
  [ "$c" -ge 1 ] && echo "    PASS: annotation names $k" || echo "    🔴 FAIL: annotation does not name $k"
done

echo
echo "  --- CONTROL B (integrity) ---"
"$T" "$R/out/NDTwin-P4-demo.ova" "$R/imp.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -2
echo "  CONVERT_EXIT=${PIPESTATUS[0]}   <-- must be 0"
cp "$R/out/NDTwin-P4-demo.ova" "$R/flip.ova"
SZ=$(stat -c%s "$R/flip.ova")
printf '\xff' | dd of="$R/flip.ova" bs=1 seek=$(( SZ / 2 )) count=1 conv=notrunc status=none
"$T" "$R/flip.ova" "$R/z.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$' | tail -2
echo "  CONTROL_EXIT=${PIPESTATUS[0]}   <-- must be NON-zero"
rm -rf "$R/flip.ova" "$R/z.vmx" "$R/imp.vmx"

echo
echo "=== L8. identity ==="
stat -c '  %n  %s bytes' "$R/out/NDTwin-P4-demo.ova"
sha256sum "$R/out/NDTwin-P4-demo.ova" | sed 's/^/  /'
md5sum    "$R/out/NDTwin-P4-demo.ova" | sed 's/^/  /'
echo "PHASE_L_DONE"
