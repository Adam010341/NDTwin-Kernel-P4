#!/usr/bin/env bash
# gated2.sh <tag> <clone> <cwd> <cmd...>: wait for guard.sh exit 0 (sleep 60 loop on 1; stop on 2) AND for nothing to listen on
# 8000 / 30051-30060 (NOLISTEN_RECHECK), then log header (clone HEAD, status --porcelain, ss -ltn), run the command, log rc.
# Files: r2/<tag>.guard.log r2/<tag>.ss.txt r2/<tag>.log.   [Co-developed with claude code -- Adam]
G=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015/guard.sh
D=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-port-guard-offline/r2
tag="$1"; clone="$2"; cwd="$3"; shift 3
while :; do
  bash "$G" "$D/$tag.guard.log"; rc=$?
  if [[ $rc -eq 2 ]]; then echo "guard rc=2: stop signal blocked" > "$D/$tag.log"; exit 2; fi
  if [[ $rc -eq 0 ]]; then
    if ss -ltnH | grep -qE ':(8000|3005[1-9]|30060)\b'; then rc=1; echo "$(date -Is) something listens on 8000/30051-30060; waiting" >> "$D/$tag.guard.log"; fi
  fi
  [[ $rc -eq 0 ]] && break
  sleep 60
done
ss -ltn > "$D/$tag.ss.txt"
cd "$cwd" || exit 3
{ echo "start $(date -Is)"; echo "clone $clone HEAD $(git -C "$clone" rev-parse HEAD)"; echo "status --porcelain:"; git -C "$clone" status --porcelain
  echo "ss -ltn archived: $D/$tag.ss.txt (8000/3005x/3006x listeners: $(grep -cE ':(8000|3005[1-9]|30060)\b' "$D/$tag.ss.txt"))"
  echo "cmd: $*"; "$@" 2>&1; echo "rc=$?"; } > "$D/$tag.log"
