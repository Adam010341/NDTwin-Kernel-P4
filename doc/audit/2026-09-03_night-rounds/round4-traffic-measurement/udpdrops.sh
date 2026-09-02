#!/usr/bin/env bash
# Independent channel for socket-level loss on :6343: the kernel's own per-socket `drops`
# column in /proc/net/udp. Not the collector's counter -- a second source for the same fact.
# [Co-developed with claude code -- Adam]
python3 - <<'PY'
for i, line in enumerate(open("/proc/net/udp")):
    if i == 0:
        continue
    f = line.split()
    if int(f[1].split(":")[1], 16) == 6343:
        print("local=%s rx_queue=%s inode=%s drops=%s" %
              (f[1], f[4].split(":")[1], f[9], f[-1]))
PY
