# mk_mut.py <clone> <mode>: writes <clone>/p4_proxy/tests/test_pg_mut_<mode>.py from the committed test_port_guard.py with one mutation.
# modes: nokernelurl (drop NDT_URL), base100 (child moves base to base+100), oldlisten (pre-fix _nothing_listens), oldversion (c7f17564 file)
# [Co-developed with claude code -- Adam]
import subprocess, sys
c, mode = sys.argv[1], sys.argv[2]
t = c + "/p4_proxy/tests/"
s = open(t + "test_port_guard.py").read()
def sub(old, new):
    global s
    assert s.count(old) == 1, (mode, old)
    s = s.replace(old, new)
if mode == "nokernelurl":
    sub('               NDT_URL="http://127.0.0.1:%d" % (base + BLOCK_SIZE),\n', '')
elif mode == "base100":
    sub('"BASE": str(base),', '"BASE": str(base + 100),')
elif mode == "oldlisten":
    a = s.index("def _nothing_listens"); b = s.index("def free_block")
    s = s[:a] + '''def _nothing_listens(port: int) -> bool:
    for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        s = socket.socket(family, socket.SOCK_STREAM)
        s.settimeout(0.3)
        try:
            err = s.connect_ex((addr, port))
        except OSError:
            continue
        finally:
            s.close()
        if err != errno.ECONNREFUSED:
            return False
    return True


''' + s[b:]
elif mode == "oldversion":
    s = subprocess.check_output(["git", "-C", "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-port-guard-offline", "show", "c7f17564a4b91aa0838d3e4b8a3a1db299abd41a:p4_proxy/tests/test_port_guard.py"], text=True)
else:
    raise SystemExit("bad mode")
open(t + "test_pg_mut_%s.py" % mode, "w").write(s)
print("wrote", t + "test_pg_mut_%s.py" % mode)
