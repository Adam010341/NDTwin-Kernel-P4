#!/bin/bash
echo "=== did ~/.local/bin exist before I mkdir'd it? evidence ==="
ls -la ~/.local/
stat -c '%n  birth=%w  ctime=%z' ~/.local ~/.local/bin 2>&1
echo "=== is ~/.local/bin on PATH in a LOGIN shell (what a desktop user gets)? ==="
bash -lc 'echo "$PATH" | tr ":" "\n" | grep -n local/bin' 2>&1
bash -lc 'command -v ndt' 2>&1 || echo "(ndt NOT found on PATH in login shell)"
echo "=== ~/.profile PATH stanza ==="
grep -n -A3 'local/bin' ~/.profile 2>&1 | head -12
echo "=== any stray kernel left from my CLI probes? ==="
ss -lntp 2>/dev/null | grep -E ':8000|:8080|:8081' || echo "(nothing listening on 8000/8080/8081)"
ps -eo pid,etimes,args= | grep '[n]dtwin_kernel' || echo "(no ndtwin_kernel process)"
echo "=== full ndt usage tail ==="
~/.local/bin/ndt 2>&1 | tail -20
echo "=== ndt status (nothing running yet) ==="
~/.local/bin/ndt status 2>&1 | head -40
date +%H:%M
