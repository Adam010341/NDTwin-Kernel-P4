"""The mechanism, executed: file stdout + SIGTERM = the buffer is discarded.

Same shape as _start_receiver/_stop_receiver: stdout -> a file, then
proc.terminate() on OUR OWN child handle (never pkill -f), then wait.
"""
import os, subprocess, sys, time
VENV_PY = "/home/adam/p4dev-python-venv/bin/python"
SP = os.path.dirname(os.path.abspath(__file__))
child = os.path.join(SP, "childlike_receive.py")

def run(argv, tag):
    path = os.path.join(SP, "demo-%s.log" % tag)
    fh = open(path, "wb")
    p = subprocess.Popen(argv, stdout=fh, stderr=subprocess.STDOUT)
    time.sleep(1.5)
    p.terminate()
    p.wait(timeout=10)
    fh.flush(); fh.close()
    size = os.path.getsize(path)
    first = open(path, errors="replace").readline().rstrip()
    print("%-28s -> %s  %4d B  first line: %r" % (" ".join(argv[1:-1]) or "(no flag)", tag, size, first))

print("interpreter:", VENV_PY)
print(subprocess.run([VENV_PY, "-VV"], capture_output=True, text=True).stdout.strip())
run([VENV_PY, child], "buffered")
run([VENV_PY, "-u", child], "unbuffered")

# ---- childlike_receive.py ----
# # Shaped like exercises/link_monitor/receive.py:16-28: it prints and never flushes.
# import time
# print("sniffing on eth0")
# for i in range(8):
#     print("Switch %d - Port 1: 1.5 Mbps" % (i + 1))
#     time.sleep(0.05)
# time.sleep(30)
