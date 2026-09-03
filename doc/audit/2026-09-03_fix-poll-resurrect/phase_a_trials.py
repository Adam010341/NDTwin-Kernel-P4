#!/usr/bin/env python3
"""Phase-A trials for FINDINGS #46: does a commanded power-off survive the next topology poll?

[Co-developed with claude code -- Adam]

THE RECIPE, unchanged from round3 08_/09_/11_ so the two rounds are comparable:
  fire the power-off ~1.5 s BEFORE the next poll, so the reply that poll applies still lists the
  switch. The poll period is 30 s once the kernel has converged, so "1.5 s before the next" means
  "28.5 s after the last one arrived". Round3 measured the losing arm at 8 of 14 and the winning
  arm (fire 2 s AFTER a poll, 28 s of slack) at 0 of 4, with every loss landing at t_off + 2.31 s.

WHAT MAKES THIS A MEASUREMENT AND NOT A DEMO
  * Both arms are run against BOTH BINARIES -- base (the merge base, defect present) and fixed --
    with this same script. A fix arm alone would only show that this harness cannot reproduce the
    defect, which is not the same claim.
  * The instrument is checked before it is used: --self-check watches the proxy's request log and
    prints the observed poll cadence. If the polls are not arriving ~30 s apart, the phase this
    script aims at does not exist and no trial below it means anything.
  * Every trial asserts the kill actually happened (the switch's gRPC port must close) before it
    is allowed to have an opinion about is_up. A trial where the process never died is recorded as
    VOID, not as KEPT: "the twin still says down" is not evidence when nothing was killed.

NEVER kills by name: no pkill, no pgrep. The only process this stops is stopped through the
kernel's own power API, or through the manifest helper by switch name.
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

NDT = os.environ.get("NDT_URL", "http://localhost:8000")
PROXY = os.environ.get("P4_PROXY_URL", "http://localhost:8081")

#: The shipped 4-host P4 model: s1..s10 at 192.168.123.11..20, gRPC 30051..30060.
SWITCHES = [
    {"name": f"s{i}", "ip": f"192.168.123.{10 + i}", "dpid": i, "grpc": 30050 + i}
    for i in range(1, 11)
]
BY_NAME = {s["name"]: s for s in SWITCHES}

POLL_PERIOD = 30.0  # kOnceConverged in TopologyAndFlowMonitor::run()
FIRE_AFTER_POLL = 28.5  # phase A: 1.5 s before the next one
WATCH_S = 40.0  # long enough to contain the next poll and the one after it
SAMPLE_HZ = 10.0

SWITCH_REQ = re.compile(r"/v1\.0/topology/switches")


def get_json(url, timeout=5.0):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode())


def post(url, timeout=40.0):
    """POST with no body; returns (status, body, seconds)."""
    req = urllib.request.Request(url, data=b"", method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode(), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), time.time() - t0


def is_up(dpid):
    """The twin's own answer, read the way every consumer reads it."""
    g = get_json(f"{NDT}/ndt/get_graph_data")
    for n in g.get("nodes", []):
        if n.get("dpid") == dpid and n.get("vertex_type") == 0:
            return bool(n.get("is_up"))
    return None


def proxy_lists(dpid):
    """Whether the control plane still names this switch. The mechanism half of #46."""
    try:
        for s in get_json(f"{PROXY}/v1.0/topology/switches", timeout=3.0):
            if int(s.get("dpid", "0"), 16) == dpid:
                return True
        return False
    except Exception:
        return None


def port_open(port, timeout=0.3):
    """Did the process really die? The bmv2 gRPC port is the only witness that is not the twin."""
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def bmv2_count():
    """`ps -eo comm=` and count. NOT pgrep -f: FINDINGS #26 measured `grep -c simple_switch_grpc`
    answering 3 on a machine with zero switches, all three of them self-matches."""
    out = subprocess.run(["ps", "-eo", "comm="], capture_output=True, text=True).stdout
    # /proc/<pid>/comm is capped at 15 characters, so the full name never appears.
    return sum(1 for line in out.splitlines() if line.strip() == "simple_switch_g")


class PollWatcher:
    """Timestamps every /v1.0/topology/switches request as it reaches the proxy's log.

    The proxy's log has no clock of its own worth trusting to sub-second precision, so the clock
    is this process's: the line is written when the request is served, and the tail sees it within
    a few milliseconds. That is the same reference round3 06_ used.
    """

    def __init__(self, path):
        self.path = path
        self.fh = open(path, "r", errors="replace")
        self.fh.seek(0, os.SEEK_END)
        self.arrivals = []

    def drain(self):
        for line in self.fh:
            if SWITCH_REQ.search(line):
                self.arrivals.append(time.time())
        return self.arrivals

    def wait_for_poll(self, timeout=90.0):
        """Blocks until a NEW poll arrives; returns its timestamp."""
        self.drain()
        n = len(self.arrivals)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if len(self.drain()) > n:
                return self.arrivals[-1]
            time.sleep(0.05)
        raise TimeoutError(f"no topology poll reached the proxy in {timeout}s")


def self_check(watcher, seconds, out):
    """The instrument, before anything is measured with it."""
    print(f"--- instrument check: watching poll arrivals for {seconds:.0f}s ---", file=out)
    t0 = time.time()
    while time.time() - t0 < seconds:
        watcher.drain()
        time.sleep(0.1)
    ts = watcher.arrivals
    if len(ts) < 2:
        print(f"    REFUSE: only {len(ts)} poll(s) seen. No phase to aim at.", file=out)
        return False
    gaps = [round(b - a, 2) for a, b in zip(ts, ts[1:])]
    print(f"    {len(ts)} polls, inter-arrival gaps: {gaps}", file=out)
    ok = all(abs(g - POLL_PERIOD) < 3.0 for g in gaps)
    print(f"    cadence within 3s of {POLL_PERIOD:.0f}s: {ok}", file=out)
    return ok


def trial(sw, watcher, out):
    r = {"switch": sw["name"], "verdict": "VOID"}
    poll_at = watcher.wait_for_poll()
    target = poll_at + FIRE_AFTER_POLL
    while time.time() < target:
        time.sleep(0.01)

    r["is_up_before"] = is_up(sw["dpid"])
    r["procs_before"] = bmv2_count()
    t_off = time.time()
    status, body, secs = post(f"{NDT}/ndt/set_switches_power_state?ip={sw['ip']}&action=off")
    r.update(t_off=t_off, off_status=status, off_body=body.strip(), off_secs=round(secs, 3),
             fired_at_poll_plus=round(t_off - poll_at, 2))

    # 10 Hz for WATCH_S: is_up (the claim) and the proxy's list (the mechanism).
    samples = []
    step = 1.0 / SAMPLE_HZ
    n = int(WATCH_S * SAMPLE_HZ)
    for i in range(n):
        due = t_off + i * step
        d = due - time.time()
        if d > 0:
            time.sleep(d)
        samples.append((round(time.time() - t_off, 2), is_up(sw["dpid"]), proxy_lists(sw["dpid"])))

    r["port_open_after"] = port_open(sw["grpc"])
    r["procs_after"] = bmv2_count()

    trans = [(t, prev[1], cur[1])
             for prev, cur in zip(samples, samples[1:])
             for t in [cur[0]] if prev[1] != cur[1]]
    r["transitions"] = trans
    r["final_is_up"] = samples[-1][1]
    listed = [t for t, _, p in samples if p]
    r["proxy_listed_until"] = max(listed) if listed else None

    if r["port_open_after"] or r["procs_after"] >= r["procs_before"]:
        # The kill did not happen. Nothing this trial says about is_up is evidence.
        r["verdict"] = "VOID"
        r["void_reason"] = "the switch process did not die, so is_up has nothing to be wrong about"
    elif r["final_is_up"]:
        r["verdict"] = "LOST"
    else:
        r["verdict"] = "KEPT"

    print(f"\n--- {sw['name']} phase A (fired at poll+{r['fired_at_poll_plus']}s) ---", file=out)
    print(f"    t_off={t_off:.3f}  API {status} {body.strip()} in {secs:.3f}s  "
          f"is_up_before={r['is_up_before']}  procs {r['procs_before']}->{r['procs_after']}",
          file=out)
    print(f"    process really died: :{sw['grpc']} open={r['port_open_after']}", file=out)
    print(f"    proxy still listed it until t_off+{r['proxy_listed_until']}s", file=out)
    print(f"    is_up transitions (t-t_off, from, to): {trans}", file=out)
    print(f"    final is_up={r['final_is_up']}  => {r['verdict']}", file=out)

    # --- restore, and say which route restored it ------------------------------------------
    st, bd, sec = post(f"{NDT}/ndt/set_switches_power_state?ip={sw['ip']}&action=on")
    print(f"    restore via API: {st} {bd.strip()} in {sec:.3f}s -> :{sw['grpc']} "
          f"open={port_open(sw['grpc'])}", file=out)
    r["restore_status"], r["restore_secs"] = st, round(sec, 3)
    if not port_open(sw["grpc"]):
        # Out of band, by NAME through the manifest helper -- never by pattern-matching a process.
        p = subprocess.run(["sudo", "-n", "/usr/local/sbin/ndtwin-p4-power", "on", sw["name"]],
                           capture_output=True, text=True)
        print(f"    API restore did not bring it back; helper: {p.stdout.strip()}"
              f"{p.stderr.strip()}", file=out)
        r["restore_needed_out_of_band"] = True
        time.sleep(2.0)
    else:
        r["restore_needed_out_of_band"] = False
    for _ in range(40):
        if is_up(sw["dpid"]):
            break
        time.sleep(1.0)
    print(f"    restored: :{sw['grpc']} open={port_open(sw['grpc'])}  twin is_up="
          f"{is_up(sw['dpid'])}  bmv2 procs={bmv2_count()}", file=out)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, help="base | fixed -- names the binary under test")
    ap.add_argument("--sha", required=True, help="sha256 of the ndtwin_kernel actually running")
    ap.add_argument("--trials", type=int, default=9)
    ap.add_argument("--proxy-log", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--self-check-seconds", type=float, default=65.0)
    a = ap.parse_args()

    with open(a.out, "w", buffering=1) as out:
        print(f"#### FINDINGS #46 phase-A trials -- arm={a.arm} ####", file=out)
        print(f"# kernel binary sha256 {a.sha}", file=out)
        print(f"# recipe: power-off fired {FIRE_AFTER_POLL}s after a poll arrival (= ~1.5s before "
              f"the next), then is_up sampled at {SAMPLE_HZ:.0f} Hz for {WATCH_S:.0f}s", file=out)
        print(f"# {time.strftime('%Y-%m-%dT%H:%M:%S%z')}  bmv2 procs = {bmv2_count()}", file=out)

        w = PollWatcher(a.proxy_log)
        if not self_check(w, a.self_check_seconds, out):
            print("REFUSING to run trials: the poll cadence this recipe aims at was not "
                  "observed.", file=out)
            return 2

        results = []
        for i in range(a.trials):
            sw = SWITCHES[5 + (i % 5)]  # s6..s10, as round3 used
            try:
                results.append(trial(sw, w, out))
            except Exception as e:  # noqa: BLE001 -- a failed trial must not lose the ones before
                print(f"    trial on {sw['name']} raised {e!r}", file=out)
                results.append({"switch": sw["name"], "verdict": "VOID", "void_reason": repr(e)})

        lost = sum(1 for r in results if r["verdict"] == "LOST")
        kept = sum(1 for r in results if r["verdict"] == "KEPT")
        void = sum(1 for r in results if r["verdict"] == "VOID")
        print(f"\n=== arm={a.arm} verdict ===", file=out)
        print(f"    LOST {lost} / KEPT {kept} / VOID {void}   "
              f"(failure rate {lost}/{lost + kept} of the trials that killed something)", file=out)
        with open(a.out + ".json", "w") as jf:
            json.dump({"arm": a.arm, "sha": a.sha, "results": results,
                       "lost": lost, "kept": kept, "void": void}, jf, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
