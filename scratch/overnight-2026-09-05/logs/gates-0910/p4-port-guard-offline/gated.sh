#!/usr/bin/env bash
# gated.sh <guardlog> <outlog> <cwd> <cmd...>: wait until guard.sh says 0 (sleep 60 loop on 1; stop on 2), then run the command, logging rc.
# [Co-developed with claude code -- Adam]
G=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015/guard.sh
gl="$1"; out="$2"; cwd="$3"; shift 3
while :; do
  bash "$G" "$gl"; rc=$?
  [[ $rc -eq 0 ]] && break
  [[ $rc -eq 2 ]] && { echo "guard rc=2: stop signal blocked" > "$out"; exit 2; }
  sleep 60
done
cd "$cwd" || exit 3
{ echo "start $(date -Is) cwd=$cwd"; echo "cmd: $*"; "$@" 2>&1; echo "rc=$?"; } > "$out"
