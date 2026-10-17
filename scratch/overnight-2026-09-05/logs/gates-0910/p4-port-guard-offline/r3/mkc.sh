#!/usr/bin/env bash
D=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-port-guard-offline/r3
G=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015
while :; do
  free=$(df -m / | awk 'NR==2{print $4}')
  bash $G/guard.sh $D/clone.guard.log; rc=$?
  [ $rc -eq 2 ] && { echo guard2 > $D/mkclone.log; exit 2; }
  [ $rc -eq 0 ] && [ "$free" -ge 2500 ] && break
  sleep 60
done
bash $G/mkclone.sh /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r3 56371d1b5231aab24eeef5ea97fd1059f5745342 $D/p4build.log > $D/mkclone.log 2>&1
echo "mkclone rc=$? (df before: ${free} MB)" >> $D/mkclone.log
