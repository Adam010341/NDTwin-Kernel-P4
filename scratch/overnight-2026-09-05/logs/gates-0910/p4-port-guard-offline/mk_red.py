# mk_red.py <clone>: writes <clone>/p4_proxy/tests/test_port_guard_old_launch.py = the new test file with offline_proxy()
# put back to the old launch (python MAIN, os.environ + PYTHONPATH, default switch base/kernel URL). [Co-developed with claude code -- Adam]
import sys
c = sys.argv[1]
s = open(c + "/p4_proxy/tests/test_port_guard.py").read()
marker = "    return argv, env, base\n"
assert s.count(marker) == 1
s = s.replace(marker, '''    argv = [python or _python(), MAIN]  # MUTATION: the old launch
    env = dict(os.environ, PYTHONPATH=PROXY_DIR, PYTHONUNBUFFERED="1")
''' + marker)
open(c + "/p4_proxy/tests/test_port_guard_old_launch.py", "w").write(s)
print("wrote mutated copy")
