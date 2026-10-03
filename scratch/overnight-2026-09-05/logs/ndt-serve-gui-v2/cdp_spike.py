"""Spike: can a stdlib-only Python drive headless Chrome over --remote-debugging-pipe (fd 3/4,
NUL-separated JSON), and which way makes a page's document.visibilityState 'hidden'?
[Co-developed with claude code -- Adam]"""
import json, os, subprocess, sys, tempfile, time, shutil, select, signal
prof = tempfile.mkdtemp(prefix="cdp-spike-", dir=os.path.dirname(os.path.abspath(__file__)))
r_to_chrome, w_to_chrome = os.pipe()     # chrome reads fd 3
r_from_chrome, w_from_chrome = os.pipe() # chrome writes fd 4
def child():
    os.dup2(r_to_chrome, 3); os.dup2(w_from_chrome, 4)
p = subprocess.Popen(["google-chrome", "--headless=new", "--no-first-run", "--no-default-browser-check",
                      "--user-data-dir=" + prof, "--remote-debugging-pipe", "--disable-background-networking",
                      "--disable-component-update", "--disable-sync", "--password-store=basic", "about:blank"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     pass_fds=(3, 4), preexec_fn=child, start_new_session=True)
os.close(r_to_chrome); os.close(w_from_chrome)
buf = b""; mid = 0
def send(method, params=None, session=None):
    global mid
    mid += 1
    msg = {"id": mid, "method": method, "params": params or {}}
    if session: msg["sessionId"] = session
    os.write(w_to_chrome, json.dumps(msg).encode() + b"\0")
    return mid
def wait(i, timeout=10):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        while b"\0" in buf:
            raw, buf = buf.split(b"\0", 1)
            m = json.loads(raw)
            if m.get("id") == i:
                return m
        r, _, _ = select.select([r_from_chrome], [], [], 0.2)
        if r:
            buf += os.read(r_from_chrome, 65536)
    raise TimeoutError(i)
def call(method, params=None, session=None):
    return wait(send(method, params, session))
try:
    print("version:", call("Browser.getVersion")["result"]["product"])
    def page():
        t = call("Target.createTarget", {"url": "about:blank"})["result"]["targetId"]
        s = call("Target.attachToTarget", {"targetId": t, "flatten": True})["result"]["sessionId"]
        return t, s
    def vis(s):
        return call("Runtime.evaluate", {"expression": "document.visibilityState"}, s)["result"]["result"]["value"]
    t1, s1 = page()
    print("a fresh target:", vis(s1))
    t2, s2 = page()
    print("after creating a 2nd target: first=%s second=%s" % (vis(s1), vis(s2)))
    call("Target.activateTarget", {"targetId": t2})
    print("after activateTarget(2nd): first=%s" % vis(s1))
    r = call("Page.setWebLifecycleState", {"state": "frozen"}, s1)
    print("setWebLifecycleState frozen:", "error" in r and r["error"]["message"] or "ok")
    call("Page.setWebLifecycleState", {"state": "active"}, s1)
    r = call("Emulation.setFocusEmulationEnabled", {"enabled": True}, s1)
    print("setFocusEmulationEnabled:", "error" in r and r["error"]["message"] or "ok", "vis:", vis(s1))
    # the page-side override: what the app would see
    call("Runtime.evaluate", {"expression": "Object.defineProperty(document,'visibilityState',{configurable:true,get:()=>'hidden'});document.dispatchEvent(new Event('visibilitychange'));1"}, s1)
    print("after the page-side override:", vis(s1))
    # a click through Input
    call("Runtime.evaluate", {"expression": "document.body.innerHTML='<button id=b onclick=\"window.x=1\">b</button>';1"}, s1)
    print("Input.dispatchMouseEvent available:", "error" not in call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": 5, "y": 5}, s1))
finally:
    try: call("Browser.close")
    except Exception as e: print("close:", e)
    try: p.wait(10)
    except subprocess.TimeoutExpired: os.killpg(p.pid, signal.SIGKILL); p.wait(10)
    left = [d for d in os.listdir("/proc") if d.isdigit() and os.path.exists("/proc/%s/stat" % d)
            and open("/proc/%s/stat" % d).read().rsplit(")", 1)[1].split()[3] == str(p.pid)]
    print("rc", p.returncode, "left in session:", left)
    shutil.rmtree(prof, ignore_errors=True)
