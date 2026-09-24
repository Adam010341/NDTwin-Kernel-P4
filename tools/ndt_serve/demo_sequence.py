#!/usr/bin/env python3
"""Drive the TICKET section 4 live sequence through a running ndt serve, and keep every byte.

[Co-developed with claude code -- Adam]

    python3 tools/ndt_serve/demo_sequence.py --port 8765 --out <dir>

status -> claim -> up (ovs 4) -> status -> apps -> nsr start -> apps -> nsr stop -> down ->
release -> status, all over HTTP. Four probes ride along, and each is built so that it CANNOT
reach ndt whatever state the lab is in: a write with no token (403 at the token check), a request
with a foreign Host (403 at the Host check), `GET /status?check=1` with no token while the fabric
is up (403 -- `--check` POSTs lock probes to the kernel, judge 09-24 finding 1), and a GET of
/health while `up` runs, which shows the job holding the one slot.

🔴 The slot probe used to be a real `POST /down` with the token (judge 09-24, finding 3): had
`up` ended in the moment before it -- an rc 1 in a second -- the slot would have been free and
the probe would have been an `ndt down` under this driver's own claim.

For every request <out>/NN-<step>.http holds the request as sent and the response as received,
headers and body in full. 🔴 The token is the one thing that is NOT kept: it is replaced by
<token> in the transcript, because this directory is evidence other people read and the token is
a credential for the running server. For every job, <out>/NN-<step>.stdout / .stderr are the
job's own logs fetched back through the API, byte for byte.

Exit 0 when the sequence ran to the end. It does not judge the lab: the rc of each ndt step is
in summary.json and in the transcripts, and the report reads them.
"""
import argparse
import http.client
import json
import os
import sys
import time

TOKEN_HEADER = "X-NDT-Token"


class Driver:
    def __init__(self, port, out, token_file):
        self.port, self.out, self.token_file = port, out, token_file
        self.n = 0
        self.summary = []
        os.makedirs(out, exist_ok=True)

    def token(self):
        with open(self.token_file) as f:
            return f.read().strip()

    def call(self, step, method, path, body=None, token=True, host=None, raw_path=False):
        self.n += 1
        name = "%02d-%s" % (self.n, step)
        data = json.dumps(body).encode() if body is not None else b""
        headers = [("Host", host or "127.0.0.1:%d" % self.port)]
        if token:
            headers.append((TOKEN_HEADER, self.token()))
        if method == "POST":
            headers.append(("Content-Type", "application/json"))
            headers.append(("Content-Length", str(len(data))))
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=900)
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for k, v in headers:
            conn.putheader(k, v)
        t0 = time.time()
        conn.endheaders(data)
        r = conn.getresponse()
        payload = r.read()
        t1 = time.time()
        conn.close()
        with open(os.path.join(self.out, name + ".http"), "wb") as f:
            f.write(("# %s  sent %s  answered %.3f s later\n" % (
                name, time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t0)), t1 - t0)).encode())
            f.write(("%s %s HTTP/1.1\n" % (method, path)).encode())
            for k, v in headers:
                f.write(("%s: %s\n" % (k, "<token>" if k == TOKEN_HEADER else v)).encode())
            f.write(b"\n" + data + b"\n\n")
            f.write(("HTTP/1.0 %d %s\n" % (r.status, r.reason)).encode())
            for k, v in r.getheaders():
                f.write(("%s: %s\n" % (k, v)).encode())
            f.write(b"\n" + payload)
        try:
            j = json.loads(payload)
        except ValueError:
            j = None
        row = {"n": self.n, "step": step, "method": method, "path": path, "http": r.status}
        self.summary.append(row)
        print("%s  %s %s -> %d" % (name, method, path, r.status), flush=True)
        return r.status, j, payload, row, name

    def job(self, step, path, body=None):
        st, j, _, row, name = self.call(step, "POST", path, body if body is not None else {})
        if st != 202:
            row["job"] = None
            return st, j, None
        job_id = j["job"]["id"]
        return st, j, self.finish(step, job_id, row)

    def finish(self, step, job_id, row):
        while True:   # ?wait= is capped at 300 s by the server
            _, w, _, _, _ = self.call(step + "-wait", "GET", "/api/v1/jobs/%s?wait=300" % job_id)
            job = w["job"]
            if job["state"] != "running":
                break
        for stream in ("stdout", "stderr"):
            _, _, blob, _, _ = self.call(step + "-" + stream, "GET", "/api/v1/jobs/%s/log/%s" % (job_id, stream))
            with open(os.path.join(self.out, "%s.%s" % (step, stream)), "wb") as f:
                f.write(blob)
        row.update({"job": job_id, "argv": job["argv"], "state": job["state"], "rc": job["rc"],
                    "rc_class": job["rc_class"], "meaning": job["meaning"],
                    "seconds": round((job["ended_at"] or 0) - (job["started_at"] or 0), 1)})
        print("    job %s  %s  rc=%s (%s)" % (job_id, " ".join(job["argv"][1:]), job["rc"], job["rc_class"]), flush=True)
        return job


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--out", required=True)
    ap.add_argument("--token-file", default=os.path.expanduser("~/.config/ndt-serve/token"))
    ap.add_argument("--note", default="ndt-serve-0924 live demo over the API")
    a = ap.parse_args()
    d = Driver(a.port, a.out, a.token_file)

    d.call("health", "GET", "/api/v1/health")
    d.call("status-before", "GET", "/api/v1/status")
    d.call("probe-no-token", "POST", "/api/v1/down", {}, token=False)
    d.call("probe-foreign-host", "GET", "/api/v1/status", host="rebind.attacker.test:%d" % a.port)

    st, j, claim = d.job("claim", "/api/v1/claim", {"minutes": 30, "note": a.note})
    if not claim or claim["rc"] != 0:
        print("the claim did not take -- stopping before anything touches the lab", flush=True)
        _dump(d)
        return 3

    # up, with a look at the slot while it runs
    st, j, _, row, _ = d.call("up", "POST", "/api/v1/up", {"plane": "ovs", "hosts": 4})
    if st == 202:
        up_id = j["job"]["id"]
        d.call("probe-slot-while-up", "GET", "/api/v1/health", token=False)
        d.finish("up", up_id, row)
    d.call("probe-check-no-token", "GET", "/api/v1/status?check=1", token=False)
    d.call("status-after-up", "GET", "/api/v1/status")
    d.call("apps-before", "GET", "/api/v1/apps")
    d.job("nsr-start", "/api/v1/apps/nsr/start")
    time.sleep(5)   # let it poll the kernel a few times
    d.call("apps-while-nsr", "GET", "/api/v1/apps")
    d.job("nsr-stop", "/api/v1/apps/nsr/stop")
    d.job("down", "/api/v1/down")
    d.job("release", "/api/v1/release")
    d.call("status-after", "GET", "/api/v1/status")
    d.call("jobs", "GET", "/api/v1/jobs?limit=20")
    _dump(d)
    return 0


def _dump(d):
    with open(os.path.join(d.out, "summary.json"), "w") as f:
        json.dump(d.summary, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    sys.exit(main())
