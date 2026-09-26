#!/usr/bin/env bash
# Worker pb5prep: the main checkout's p4_proxy/venv fingerprint, read-only (find -printf; nothing
# is executed from the venv). mainvenv_fp.sh <label>. Same method as the 09-26 live trial.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
f=$(new_log "mainvenv_fingerprint_$1" "main p4_proxy/venv fingerprint (find -type f -printf '%P %s %T@' | sort | sha256sum), read-only") || exit 2
{ echo "fingerprint $(main_fp)"
  echo "newest: $(find "$MAIN_REPO/p4_proxy/venv" -type f -printf '%TY-%Tm-%Td+%TT %P\n' | sort | tail -1)"
  echo "files: $(find "$MAIN_REPO/p4_proxy/venv" -type f | wc -l)"
  [[ -n "${2:-}" ]] && echo "files newer than $2: $(find "$MAIN_REPO/p4_proxy/venv" -newer "$2" -type f | wc -l)" && find "$MAIN_REPO/p4_proxy/venv" -newer "$2" -type f | head -20
  echo "rc=0"; } >> "$f"
cat "$f"
