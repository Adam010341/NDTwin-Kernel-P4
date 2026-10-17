#!/usr/bin/env bash
D=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-port-guard-offline/r2
G=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015
while :; do bash $G/guard.sh $D/clone.guard.log; rc=$?; [ $rc -eq 0 ] && break; [ $rc -eq 2 ] && { echo guard2 > $D/mkclone.log; exit 2; }; sleep 60; done
bash $G/mkclone.sh /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r2 383be526909be92e68fa565c40f78bba9ca5b46b $D/p4build.log > $D/mkclone.log 2>&1
echo "mkclone rc=$?" >> $D/mkclone.log
