#!/bin/bash
# ============================================================================================
# A-3 step 6: both acceptances, on the artefact that actually ships.
#
# TWO ACCEPTANCES, KEPT APART, because they answer different questions and one of them has no
# power over the other:
#   (1) DELIVERY  -- is what this round CHANGED actually in the file? doc/ gone, NTV on
#                    b5e039c, the declarations present and describing it. T-2 would pass
#                    identically whether or not any of that were true.
#   (2) REGRESSION-- did the changes break the fabric? T-2: 10 switches, 12 paths, 40 edges,
#                    pingall 0% dropped.
#
# JUDGED ON THE NAMED LINE, not the last line: `*** Results: 0% dropped`.
#
# ⚠️ The elapsed-seconds figure this driver prints has been wrong before -- it once reported
#    "T-2 reached its summary after 20s" for a run the guest file timestamps put at 130s, and
#    the cause was never found. So the wall-clock question is settled from the GUEST FILE
#    TIMESTAMPS below, and the printed figure is recorded but not trusted.
#
# The disk is an overlay over the extracted vmdk, so the payload stays byte-identical to the
# .ova and this run cannot be accused of having modified what it tested.
# [Co-developed with claude code -- Adam]
# ============================================================================================
set -u
OVA=/home/nslab/a3repack/out/NDTwin-P4-demo.ova
W=/home/nslab/a3accept
DRV=/home/nslab/guest_t2_run.sh
PORT=2299
EXPECT=c303adb57c99f87a7f4f4c77de9763dc7f369e0fabd580a1db6089823966c8e8

echo "=== $(date -Is) A-3 acceptance ==="
[ -s "$OVA" ] || { echo "no artefact"; exit 1; }
if ss -tlnH "( sport = :$PORT )" 2>/dev/null | grep -q .; then echo "🔴 :$PORT busy"; exit 1; fi

echo "=== artefact under test ==="
stat -c '  %n  %s bytes' "$OVA"
GOT=$(sha256sum "$OVA" | awk '{print $1}'); echo "  sha256 $GOT"
[ "$GOT" = "$EXPECT" ] || { echo "  🔴 not the artefact I packed"; exit 1; }
echo "  ✅ this is the file packed by step 5"

rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
echo
echo "=== unpack + overlay ==="
tar -xf "$OVA"
D=$(ls ./*.vmdk | head -1)
echo "  disk: ${D#./}  $(stat -c%s "$D") bytes"
qemu-img create -q -f qcow2 -b "$W/${D#./}" -F vmdk "$W/ov.qcow2" || exit 1

echo
echo "=== boot: SATA/AHCI, E1000, 4 vCPU, 6144 MB -- what the OVF declares ==="
setsid qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 4 \
  -device ahci,id=ahci0 \
  -drive id=d0,file="$W/ov.qcow2",if=none,format=qcow2 \
  -device ide-hd,drive=d0,bus=ahci0.0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${PORT}-:22 -device e1000,netdev=n0 \
  -display none -daemonize -pidfile "$W/vm.pid" || { echo "🔴 qemu failed"; exit 1; }
sleep 3
P=$(head -1 "$W/vm.pid" 2>/dev/null)
[ -d "/proc/$P" ] || { echo "🔴 qemu not running"; exit 1; }
echo "  qemu pid $P"

printf '#!/bin/sh\necho tester\n' > "$W/.ask"; chmod 700 "$W/.ask"
export SSH_ASKPASS="$W/.ask" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
S(){ ssh -p $PORT $CO tester@127.0.0.1 "$@"; }
up=0
for i in $(seq 1 40); do S 'echo up' 2>/dev/null | grep -q up && { up=1; break; }; sleep 10; done
[ "$up" = 1 ] || { echo "🔴 SSH DID NOT COME UP"; kill -TERM "$P"; exit 1; }
echo "  SSH up after ~$((i*10))s"
echo "  booted from: $(S 'df -h / | awk "NR==2{print \$1}"' 2>/dev/null)  (sd* = AHCI)"

# ============================================================================================
echo
echo "############ ACCEPTANCE 1 -- DELIVERY: is this round's work IN the file? ############"
S 'D=/home/tester/Desktop
   echo "  --- doc/ must be gone ---"
   if [ -e "$D/NDTwin-Kernel/doc" ]; then echo "    🔴 doc/ STILL PRESENT ($(find $D/NDTwin-Kernel/doc -type f | wc -l) files)"
   else echo "    ✅ doc/ absent: $(ls $D/NDTwin-Kernel/doc 2>&1)"; fi
   echo "  --- the four trees, still no .git ---"
   for r in Energy-Saving-App Simulation-Platform-Manager Traffic-Engineering-App Network-Traffic-Visualizer; do
     printf "    %-30s dir=%s .git=%s\n" "$r" "$([ -d "$D/$r" ] && echo yes || echo NO)" "$([ -d "$D/$r/.git" ] && echo PRESENT || echo absent)"
   done
   echo "  --- built artefacts (deleted before building, so their presence means a compiler ran) ---"
   for f in Energy-Saving-App/energy_saving_app Energy-Saving-App/energy_saving_simulator \
            Simulation-Platform-Manager/simulation_platform_manager Simulation-Platform-Manager/request_manager \
            Network-Traffic-Visualizer/target/NDTanimation-1.0-SNAPSHOT.jar; do
     printf "    %-58s %s bytes\n" "$f" "$(stat -c%s "$D/$f" 2>/dev/null || echo MISSING)"
   done
   echo "  --- NTV must be b5e039c: no WindowStateRestore anywhere in its source ---"
   n=$(grep -rl WindowStateRestore "$D/Network-Traffic-Visualizer/src" 2>/dev/null | wc -l)
   [ "$n" = 0 ] && echo "    ✅ 0 references (b5e039c predates it)" || echo "    🔴 $n file(s) still reference it"
   echo "  --- the jar you must pick is the one with a Main-Class ---"
   for j in "$D"/Network-Traffic-Visualizer/target/*.jar; do
     mc=$(unzip -p "$j" META-INF/MANIFEST.MF 2>/dev/null | tr -d "\r" | sed -n "s/^Main-Class: *//p")
     printf "    %-52s %s\n" "$(basename $j)" "${mc:-(no Main-Class -- the decoy)}"
   done
   echo "  --- the declarations, and whether they describe this content ---"
   printf "    %-46s %s bytes\n" "Desktop/PROVENANCE.txt" "$(stat -c%s $D/PROVENANCE.txt 2>/dev/null || echo MISSING)"
   printf "    %-46s %s bytes\n" "Desktop/NDTwin-Kernel/PROVENANCE.txt" "$(stat -c%s $D/NDTwin-Kernel/PROVENANCE.txt 2>/dev/null || echo MISSING)"
   echo "    NTV commit stated:      $(grep -oE "Network-Traffic-Visualizer +[a-f0-9]{7}" $D/PROVENANCE.txt | tr -s " ")"
   echo "    disable_switch named:   $(grep -c disable_switch $D/PROVENANCE.txt) time(s)"
   echo "    doc/ removal stated:    $(grep -c "doc/" $D/NDTwin-Kernel/PROVENANCE.txt) line(s)"
   echo "    public snapshot named:  $(grep -c NDTwin-Kernel-P4-public $D/NDTwin-Kernel/PROVENANCE.txt) time(s)"
   echo "  --- units still disabled: the image opens no ports on boot ---"
   for u in ndtwin-esa ndtwin-spm ndtwin-reqmgr; do printf "    %-14s %s\n" "$u" "$(systemctl is-enabled $u 2>&1)"; done
   echo "  --- what a cold boot is actually listening on ---"
   ss -tlnH | awk "{print \"    \" \$1, \$4}"' 2>/dev/null

# ============================================================================================
echo
echo "############ ACCEPTANCE 2 -- REGRESSION: the P4/BMv2 fabric ############"
scp -P $PORT $CO "$DRV" tester@127.0.0.1:/home/tester/guest_t2_run.sh >/dev/null 2>&1
S 'chmod +x /home/tester/guest_t2_run.sh; rm -f /home/tester/t2.log
   setsid bash -c "/home/tester/guest_t2_run.sh > /home/tester/t2run.log 2>&1" </dev/null >/dev/null 2>&1 &
   sleep 3; echo "    T-2 launched"' 2>/dev/null

T0=$(date +%s)
for i in $(seq 1 90); do
  sleep 20
  if S 'grep -qE "T-2 RESULT|failures:" /home/tester/t2run.log 2>/dev/null' 2>/dev/null; then
    echo "    driver says it reached the summary after $(( $(date +%s) - T0 ))s (host wall clock)"
    break
  fi
done

echo
echo "  --- ADJUDICATED ON GUEST FILE TIMESTAMPS, not on any printed figure ---"
S 'for f in /home/tester/t2run.log /home/tester/topo.log /home/tester/t2.log; do
     [ -e "$f" ] && printf "    %-32s first=%s last=%s\n" "$(basename $f)" \
       "$(stat -c %w "$f" 2>/dev/null | cut -d. -f1)" "$(stat -c %y "$f" | cut -d. -f1)"
   done' 2>/dev/null

echo
echo "  --- THE NAMED LINE (this is the criterion; not the last line of output) ---"
S 'grep -E "\*\*\* Results:" /home/tester/topo.log | tail -2 | sed "s/^/    /"' 2>/dev/null
echo
echo "  --- the four numbers ---"
S 'grep -iE "switches in manifest|switches verified|two consecutive|nodes=|PASS:|FAIL:|failures:" /home/tester/t2run.log | sed "s/^/    /"' 2>/dev/null

echo
echo "  --- verdict, computed from the named line ---"
if S 'grep -qE "\*\*\* Results: 0% dropped" /home/tester/topo.log' 2>/dev/null; then
  echo "    ✅ PASS: *** Results: 0% dropped"
else
  echo "    🔴 the named line does not say 0% dropped:"
  S 'grep -E "\*\*\* Results:" /home/tester/topo.log | tail -1 | sed "s/^/      /"' 2>/dev/null
fi

# ============================================================================================
echo
echo "############ SHUTDOWN ############"
rm -f "$W/.ask"
ssh -p $PORT $CO tester@127.0.0.1 'sudo -n poweroff' >/dev/null 2>&1
for _ in $(seq 1 90); do [ -d "/proc/$P" ] || break; sleep 2; done
if [ -d "/proc/$P" ]; then kill -TERM "$P"; sleep 8; fi
[ -d "/proc/$P" ] && echo "  🔴 qemu $P STILL RUNNING" || echo "  ✅ qemu $P gone"
ss -tlnH "( sport = :$PORT )" 2>/dev/null | grep -q . && echo "  🔴 :$PORT still listening" || echo "  ✅ :$PORT free"
echo "A3_ACCEPT_DONE $(date -Is)"
