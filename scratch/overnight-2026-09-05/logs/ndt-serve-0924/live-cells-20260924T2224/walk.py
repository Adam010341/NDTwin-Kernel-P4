#!/usr/bin/env python3
"""Walk one cell through ndt serve's guided mode up to -- not through -- the verdict step, keeping
every response. The verdict is Adam's. [Co-developed with claude code -- Adam]"""
import http.client, json, os, sys, time
port, cell, out = 8765, sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
tok = open(os.path.expanduser("~/.config/ndt-serve/token")).read().strip()
n = 0
def call(method, path, body=None):
    global n
    n += 1
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=900)
    data = json.dumps(body).encode() if body is not None else b""
    h = {"Host": "127.0.0.1:%d" % port}
    if method == "POST":
        h.update({"Content-Type": "application/json", "X-NDT-Token": tok})
    c.request(method, path, body=data, headers=h)
    r = c.getresponse(); raw = r.read(); c.close()
    with open(os.path.join(out, "%02d-%s-%s.json" % (n, method, path.strip("/").replace("/", "_")[:60])), "wb") as f:
        f.write(("# %s %s -> %d at %s\n" % (method, path, r.status, time.strftime("%H:%M:%S"))).encode() + raw)
    return r.status, json.loads(raw)
st, j = call("POST", "/api/v1/cells/%s/guided" % cell, {})
gid = j["walk"]["id"]; print("walk", gid, [s["step"] for s in j["walk"]["steps"]], flush=True)
while True:
    while True:
        st, j = call("GET", "/api/v1/guided/" + gid)
        w = j["walk"]; cur = w["current"]
        if cur is None or w["steps"][cur]["state"] != "running":
            break
        time.sleep(1)
    if w["done"] or w["blocked"]:
        print("stop: done=%s blocked=%s" % (w["done"], w["blocked"]), flush=True); break
    step = w["steps"][cur]["step"]
    if step == "verdict":
        print("stop at the verdict step -- it is Adam's", flush=True); break
    st, j = call("POST", "/api/v1/guided/%s/next" % gid, {})
    s = j["walk"]["steps"][cur]
    print("  %-8s -> HTTP %d  state=%s  %s" % (step, st, s["state"], json.dumps({k: (s["result"] or {}).get(k) for k in ("rc", "rc_class", "ok")})), flush=True)
st, j = call("GET", "/api/v1/guided/" + gid)
for s in j["walk"]["steps"]:
    r = s["result"] or {}
    extra = ""
    if s["step"] == "compare" and r:
        extra = "red_to_green=%s still_red=%s" % (r.get("red_to_green"), r.get("still_red"))
    if s["step"] == "run" and r:
        extra = "cell_verdict=%s" % ((r.get("cell_verdict") or {}).get("line"))
    print("  %-8s %-8s %s" % (s["step"], s["state"], extra))
print("GID", gid)
