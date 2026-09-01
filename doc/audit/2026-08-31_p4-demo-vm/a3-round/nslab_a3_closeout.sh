#!/bin/bash
# A-3 closeout evidence. Everything here is a STATE check, not an exit code.
# [Co-developed with claude code -- Adam]
set -u
echo "=== A-3 closeout $(date -Is) on $(hostname) ==="

echo
echo "--- 1. port 2299 must not be listening ---"
OUT=$(ss -tlnH "( sport = :2299 )" 2>/dev/null)
[ -z "$OUT" ] && echo "  OK: :2299 is not listening" || { echo "  STILL LISTENING:"; echo "$OUT"; }

echo
echo "--- 2. no qemu of mine, found via /proc/*/exe (never pgrep -f) ---"
found=0
for p in /proc/[0-9]*; do
  e=$(readlink -f "$p/exe" 2>/dev/null) || continue
  case "$e" in
    *qemu-system*)
      c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
      mine=no
      case "$c" in *ndtwin-vm-a3*|*a3accept*|*a3repack*|*2299*) mine=yes;; esac
      echo "  qemu pid ${p#/proc/}  mine=$mine"
      echo "     $(echo "$c" | grep -oE '\-pidfile [^ ]+|hostfwd=[^ ]+' | tr '\n' ' ')"
      [ "$mine" = yes ] && found=1 ;;
  esac
done
[ "$found" = 0 ] && echo "  OK: no qemu belonging to A-3 is running"

echo
echo "--- 3. the other sessions' VMs must be untouched ---"
for d in /home/nslab/ndtwin-vm /home/nslab/ndtwin-vm-a2 /home/nslab/ndtwin-vm-reviewer-B; do
  printf '  %-38s exists=%s  owner=%s\n' "$d" "$([ -d "$d" ] && echo yes || echo NO)" \
    "$(awk '/^owner:/{print $2}' "$d/OWNER" 2>/dev/null || echo -)"
done
echo "  port 2298 (the a2 session, must still be theirs):"
ss -tlnH "( sport = :2298 )" 2>/dev/null | sed 's/^/    /' || echo "    not listening"

echo
echo "--- 4. the A-3 disk is KEPT, not destroyed ---"
ls -la /home/nslab/ndtwin-vm-a3/ 2>/dev/null | sed 's/^/  /'
echo "  OWNER file:"; sed 's/^/    /' /home/nslab/ndtwin-vm-a3/OWNER 2>/dev/null

echo
echo "--- 5. the artefacts ---"
for f in /home/nslab/repack/out/NDTwin-P4-demo.ova /home/nslab/a3repack/out/NDTwin-P4-demo.ova; do
  [ -e "$f" ] || { echo "  MISSING $f"; continue; }
  printf '  %s\n    %s bytes\n    sha256 %s\n' "$f" "$(stat -c%s "$f")" "$(sha256sum "$f" | awk '{print $1}')"
done

echo
echo "--- 6. disk headroom left behind ---"
df -h /home/nslab | tail -1 | sed 's/^/  /'
echo "CLOSEOUT_DONE"
