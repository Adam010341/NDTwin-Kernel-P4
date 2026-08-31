#!/bin/bash
# H-26 phase K: boot the artefact that will actually ship, and check the two different things.
#
# 🔑 T-2 HAS ZERO DISCRIMINATING POWER FOR THE THING THAT CHANGED. It exercises mininet, ryu,
#    bmv2 and the kernel -- none of which this round touched. It would pass identically on the
#    old .ova. Running it alone and calling the artefact accepted would be the same mistake as
#    the arm that measured a switch that was powered off: the answer comes out as expected and
#    the reason is wrong.
#    ⇒ So there are two acceptances here, and they are kept apart:
#        (1) REGRESSION -- did adding the tools break the fabric? T-2, against 19:23's numbers.
#        (2) DELIVERY   -- are the tools actually in the file that ships? Checked directly,
#            on the booted artefact, by the properties Adam asked for: they exist, they build,
#            they start.
#
# The disk is an overlay over the extracted vmdk, so the payload stays byte-identical and this
# run cannot be accused of having modified what it tested.
#
# Pinned to cores 24-27 like the H-26 VM, for the same reason: the reviewer's measuring segment
# is waiting on this row, and bounded contention is the difference between "polluted" and
# "polluted in a way nobody can attribute".
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
OVA=/home/nslab/repack/out/NDTwin-P4-demo.ova
W=/home/nslab/t2final
DRV=/home/nslab/guest_t2_run.sh
[ -s "$OVA" ] || { echo "no artefact at $OVA -- phase J did not produce one"; exit 1; }
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

echo "=== artefact under test ==="
stat -c '  %n %s bytes' "$OVA"; sha256sum "$OVA" | sed 's/^/  /'

echo
echo "=== unpack and overlay (payload stays byte-identical) ==="
tar -xf "$OVA"
D=$(ls ./*.vmdk | head -1)
echo "  disk: $D $(stat -c%s "$D") bytes"
qemu-img create -q -f qcow2 -b "$W/${D#./}" -F vmdk "$W/ov.qcow2" || exit 1

echo
echo "=== boot on the hardware the OVF declares: SATA/AHCI, 4 vCPU, 6144 MB ==="
qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 4 \
  -device ahci,id=ahci0 \
  -drive id=d0,file="$W/ov.qcow2",if=none,format=qcow2 \
  -device ide-hd,drive=d0,bus=ahci0.0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2297-:22 -device e1000,netdev=n0 \
  -display none -daemonize -pidfile "$W/vm.pid"
sleep 2
P=$(cat "$W/vm.pid" 2>/dev/null)
kill -0 "$P" 2>/dev/null || { echo "FAILED to start"; exit 1; }
taskset -acp 24-27 "$P" >/dev/null 2>&1 && echo "  qemu pid $P, pinned to cores 24-27"

printf '#!/bin/sh\necho tester\n' > "$W/.ask"; chmod 700 "$W/.ask"
export SSH_ASKPASS="$W/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
G="tester@127.0.0.1"
S(){ ssh -p 2297 $CO $G "$@"; }
up=0
for i in $(seq 1 40); do S 'echo up' 2>/dev/null | grep -q up && { up=1; break; }; sleep 10; done
[ "$up" = 1 ] || { echo "SSH DID NOT COME UP"; kill -TERM "$P"; exit 1; }
echo "  SSH up after ~$((i*10))s"

echo
echo "############ ACCEPTANCE (2): are the tools IN the file that ships? ############"
S 'D=/home/tester/Desktop
   echo "  --- the four trees, and no .git among them ---"
   for r in Energy-Saving-App Simulation-Platform-Manager Traffic-Engineering-App Network-Traffic-Visualizer; do
     printf "    %-30s dir=%s .git=%s\n" "$r" "$([ -d "$D/$r" ] && echo yes || echo NO)" "$([ -d "$D/$r/.git" ] && echo 🔴PRESENT || echo absent)"
   done
   echo "  --- built artefacts exist (they were deleted before building, so this means a compiler ran) ---"
   for f in Energy-Saving-App/energy_saving_app Energy-Saving-App/energy_saving_simulator \
            Simulation-Platform-Manager/simulation_platform_manager Simulation-Platform-Manager/request_manager \
            Network-Traffic-Visualizer/target/NDTanimation-1.0-SNAPSHOT.jar; do
     printf "    %-56s %s bytes\n" "$f" "$(stat -c%s "$D/$f" 2>/dev/null || echo MISSING)"
   done
   echo "  --- the documents ---"
   printf "    %-30s %s lines\n" "README-NDTwin-tools.md" "$(wc -l < "$D/README-NDTwin-tools.md" 2>/dev/null || echo MISSING)"
   printf "    %-30s %s lines\n" "PROVENANCE.txt" "$(wc -l < "$D/PROVENANCE.txt" 2>/dev/null || echo MISSING)"
   printf "    %-30s %s\n" "NTV local patch" "$([ -s "$D/Network-Traffic-Visualizer/NDTwin-local-changes.patch" ] && echo present || echo MISSING)"
   echo "  --- units installed, disabled, and nothing listening cold ---"
   for u in ndtwin-esa ndtwin-spm ndtwin-reqmgr; do printf "    %-16s enabled=%s active=%s\n" "$u" "$(systemctl is-enabled $u 2>&1)" "$(systemctl is-active $u 2>&1)"; done
   for p in 111 2049 8001 8002 9000; do printf "    :%-6s %s listener(s)\n" "$p" "$(ss -tulnH | grep -c ":$p ")"; done
   echo "  --- and they start on demand ---"
   sudo -n systemctl start ndtwin-esa ndtwin-reqmgr; sleep 10
   printf "    ndtwin-esa=%s :8001=%s   ndtwin-reqmgr=%s :8002=%s\n" "$(systemctl is-active ndtwin-esa)" "$(ss -tlnH|grep -c :8001)" "$(systemctl is-active ndtwin-reqmgr)" "$(ss -tlnH|grep -c :8002)"
   sudo -n systemctl stop ndtwin-esa ndtwin-reqmgr; sudo -n umount /mnt/nfs/sim /mnt/nfs/app 2>/dev/null
   sudo -n systemctl stop nfs-server nfs-mountd rpcbind.socket rpcbind.service 2>/dev/null; true'

echo
echo "############ the Visualizer starts, on the artefact ############"
S 'cd /home/tester/Desktop/Network-Traffic-Visualizer
   Xvfb :79 -screen 0 1280x1024x24 > /tmp/k_x.out 2>&1 & XP=$!
   sleep 3
   DISPLAY=:79 java --module-path /usr/share/openjfx/lib --add-modules javafx.controls,javafx.fxml,javafx.swing,javafx.media,javafx.web -jar target/NDTanimation-1.0-SNAPSHOT.jar > /tmp/k_ntv.out 2>&1 & JP=$!
   sleep 22
   if kill -0 $JP 2>/dev/null; then echo "    PASS: NTV stays up on the artefact (pid $JP)"; head -2 /tmp/k_ntv.out | sed "s/^/      /";
   else echo "    FAIL: NTV exited"; tail -5 /tmp/k_ntv.out | sed "s/^/      /"; fi
   kill -TERM $JP 2>/dev/null; sleep 3; kill -0 $JP 2>/dev/null && kill -KILL $JP 2>/dev/null
   kill -TERM $XP 2>/dev/null; sleep 1; kill -0 $XP 2>/dev/null && kill -KILL $XP 2>/dev/null; true'

echo
echo "############ ACCEPTANCE (1): T-2 regression, same driver as 19:23 ############"
scp -P 2297 $CO "$DRV" $G:/home/tester/guest_t2_run.sh >/dev/null
S 'chmod +x /home/tester/guest_t2_run.sh && setsid bash -c "/home/tester/guest_t2_run.sh > /home/tester/t2run.log 2>&1" < /dev/null > /dev/null 2>&1 & sleep 3; echo launched'
for i in $(seq 1 90); do
  sleep 20
  S 'grep -qE "T-2 (done|finished)|=== summary|failures:" /home/tester/t2run.log 2>/dev/null' 2>/dev/null && { echo "T-2 reached its summary after $((i*20))s"; break; }
done
S 'grep -iE "switches in manifest|paths|edges|Results:|dropped|failures|PASS:|FAIL:" /home/tester/t2run.log' 2>/dev/null | sed 's/^/  /'

echo
echo "=== power off ==="
S 'sudo -n poweroff' >/dev/null 2>&1
for i in $(seq 1 24); do kill -0 "$P" 2>/dev/null || break; sleep 5; done
kill -0 "$P" 2>/dev/null && echo "🔴 qemu $P still alive -- look before acting" || echo "qemu $P exited cleanly"
rm -f "$W/.ask"
echo "PHASE_K_DONE"
