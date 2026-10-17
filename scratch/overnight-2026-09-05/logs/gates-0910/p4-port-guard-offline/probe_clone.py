import sys, subprocess, time, re
sys.path.insert(0, sys.argv[1] + "/p4_proxy/tests")
import test_port_guard as t
argv, env, base = t.offline_proxy(python=sys.argv[1] + "/p4_proxy/venv/bin/python")
print("block", base, "..", base + t.BLOCK_SIZE, flush=True)
p = subprocess.Popen(argv, cwd=t.PROXY_DIR, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
import threading, queue
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
time.sleep(float(sys.argv[2])); p.terminate(); p.wait(15)
out = ""
while not q.empty(): out += q.get()
print(out[:6000])
print("DIALED PORTS:", sorted(t.dialed_ports(out)))
