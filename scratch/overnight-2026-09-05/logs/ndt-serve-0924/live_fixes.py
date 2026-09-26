#!/usr/bin/env python3
"""The judge's live re-checks (orchestrator 09-24, item 9), through a running ndt serve.

[Co-developed with claude code -- Adam]

    python3 live_fixes.py --out <dir> --worktree <wt>

Pins non-zero rcs on the REAL ndt, which no stub can:
  claim (ours) -> POST /down on a down lab -> rc 3 (nothing)
              -> POST /apps/nsr/stop with nsr not running -> rc 2 (nothing)
              -> release
  a FOREIGN claim (another owner, straight to ndt) -> POST /up -> rc 5 (refused, nothing built)
              -> the foreign claim released, straight to ndt
Every request and response is kept (token redacted) by demo_sequence.Driver.
"""
import argparse
import os
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(a.worktree, "tools", "ndt_serve"))
    from demo_sequence import Driver, _dump
    d = Driver(a.port, a.out, os.path.expanduser("~/.config/ndt-serve/token"))
    ndt = os.path.expanduser("~/.local/bin/ndt")

    def direct(name, owner, *args):
        """Straight to ndt, as the control and for the foreign claim. setsid, stdin /dev/null."""
        with open(os.path.join(a.out, name + ".stdout"), "wb") as o, \
             open(os.path.join(a.out, name + ".stderr"), "wb") as e:
            rc = subprocess.run(["setsid", "-w", "env", "NDT_OWNER=" + owner, ndt] + list(args),
                                stdin=subprocess.DEVNULL, stdout=o, stderr=e).returncode
        with open(os.path.join(a.out, name + ".rc"), "w") as f:
            f.write("%d\n" % rc)
        print("direct %s: ndt %s (owner %s) -> rc %d" % (name, " ".join(args), owner, rc), flush=True)
        return rc

    d.call("status-before", "GET", "/api/v1/status")
    st, j, claim = d.job("claim", "/api/v1/claim", {"minutes": 15, "note": "ndt-serve-0924 judge re-checks: rc 3 / rc 2 / rc 5"})
    if not claim or claim["rc"] != 0:
        print("the claim did not take -- stopping", flush=True)
        _dump(d)
        return 3
    d.job("down-on-a-down-lab", "/api/v1/down")                  # expect rc 3
    d.job("nsr-stop-not-running", "/api/v1/apps/nsr/stop")       # expect rc 2
    d.job("release", "/api/v1/release")
    # rc 5: another owner holds the lab
    if direct("foreign-claim", "ndt-serve-0924-foreign", "claim", "5", "ndt serve rc-5 probe: up must be refused") == 0:
        # the claim field while it is held -- proof the claim is NOT this server's owner's
        d.call("status-under-the-foreign-claim", "GET", "/api/v1/status")
        d.job("up-under-a-foreign-claim", "/api/v1/up", {"plane": "ovs", "hosts": 4})   # expect rc 5
        direct("foreign-release", "ndt-serve-0924-foreign", "release")
        d.call("status-after-the-foreign-release", "GET", "/api/v1/status")
    d.call("status-after", "GET", "/api/v1/status")
    d.call("jobs", "GET", "/api/v1/jobs?limit=20")
    _dump(d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
