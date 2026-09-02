#!/bin/bash
# A-8 RAM gate: enumerate running qemu processes on the nslab HOST.
# Never uses pgrep -f / pkill -f. Walks /proc/*/exe instead.
# [Co-developed with claude code -- Adam]
echo "=== A-8 RAM GATE $(date -u +%FT%TZ) / $(date +%FT%T%z) ==="
echo "--- host: $(hostname) ---"
echo
echo "### qemu processes (readlink /proc/*/exe, match qemu-system) ###"
found=0
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$exe" in
    *qemu-system*)
      found=$((found+1))
      cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
      # disk path from -drive/file= arguments
      disk=$(printf '%s\n' "$cmd" | tr ' ' '\n' | grep -o '[^,]*\.img' | head -3 | tr '\n' ' ')
      rss=$(awk '/^VmRSS:/{print $2" "$3}' "$p/status" 2>/dev/null)
      echo "PID=$pid EXE=$exe"
      echo "  RSS=$rss"
      echo "  DISK=$disk"
      echo "  CMDLINE=$cmd"
      echo
      ;;
  esac
done
echo "QEMU_COUNT=$found"
echo
echo "### free -m ###"
free -m
echo
echo "### listening ports of interest (ss -tlnpH) ###"
ss -tlnpH 2>/dev/null | grep -E ':(2301|2313|2314|2312|2311)\b' || echo "(none of 2301/2311/2312/2313/2314 listening)"
echo
echo "### /home free ###"
df -h /home | tail -2
echo
echo "### VM dirs present ###"
ls -d "$HOME"/ndtwin-vm* 2>/dev/null
echo
echo "### prep5 image ###"
ls -l "$HOME/ndtwin-vm-prep5/" 2>/dev/null
du -sb "$HOME/ndtwin-vm-prep5/"*.img 2>/dev/null
echo "GATE_SCRIPT_EXIT=0"
