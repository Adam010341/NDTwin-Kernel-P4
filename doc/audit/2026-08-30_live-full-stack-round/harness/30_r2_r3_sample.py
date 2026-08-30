#!/usr/bin/env python3
"""
30_r2_r3_sample.py -- the sampler for R-2 (path recompute 1 kHz -> 1 Hz) and for R-3's
"are they still serving" evidence.

WRITTEN, NOT RUN.  Syntax-checked with `python3 -m py_compile` only.

WHAT IT DOES
    Polls the kernel and the control plane on a fixed schedule and writes one JSONL record per
    sample to <OUT>/r2_samples.jsonl.gz, keeping the FULL response body of every sample.
    Analysis lives in 35_r2_r3_analyse.py and never re-fetches, so the round can be re-analysed
    without re-running the fabric.

WHY IT KEEPS EVERYTHING
    memory: evidence-must-outlive-the-handoff.  A digest computed at sample time answers only
    the question we thought of at sample time.  The 08-18 round's sharpest finding (F-5) turned
    on the SHAPE of a field -- a JSON object among 130 strings -- which no counter would have
    preserved.  Raw bodies are gzipped; on a 4-host fabric this is a few MB an hour.

R-2 AND WHAT IT CAN ACTUALLY SHOW
    R-2 is a change of internal recompute rate from 1 kHz to 1 Hz.  Nothing exposes the
    recompute rate directly; what is observable is how often the flowPath a consumer reads
    CHANGES.  So this sampler measures change intervals, and 35_... reports what a consumer
    polling at cadence C would have seen.

    Three things must be held apart in the analysis, and the sampler records what each needs:

      (a) the recompute rate itself           -- unobservable from outside; do not claim it
      (b) how often the value a consumer      -- measurable: inter-change intervals, below
          reads actually changes
      (c) the refresh thread's ceiling        -- memory: destination-paths-not-monotonic says a
                                                 refresh thread bounds staleness at ~60 s, and
                                                 that its downgrade condition is "non-empty",
                                                 not "converged", so 99.8% of the time it LOOKS
                                                 converged.  A ~60 s periodicity in the change
                                                 intervals is that thread, NOT the recompute.

    🔴 PREREG §3 R-2 says "Consumers poll on a 15 s cadence, so the registered expectation is
    no observable difference."  Measured from the apps' own source on 2026-08-30, no app polls
    at 15 s: energy 60 s, sim never (event-driven), nsr 5 s, viz 1 s, te 1 s.  Three of five are
    FASTER than 1 Hz.  The premise of the registered expectation does not hold.  This sampler
    therefore samples fast enough (default 0.5 s) to answer the question at every real cadence,
    and 35_... reports the registered 15 s figure AND the measured ones side by side.  It does
    not choose between them: amending a pre-registration is the auditor's call.

H-CORRESPONDENCE
    H-17  no process signalling at all.  Liveness of the apps is read from artefacts and ports.
    H-18  no log grepping here; every field is read from a parsed JSON body by key.  Where a key
          may be absent, the record says "absent" -- distinct from a value of zero.
    H-19  the HTTP status and the transport error are recorded in SEPARATE fields on every
          sample (`http` and `err`).  A 404 is recorded as a 404, never as "no data".
    H-20  the output file is created fresh and refuses to append to an existing one, so a
          previous run's samples cannot be read as this run's.
    H-21  n/a (no shell pipelines); the exit status reflects whether sampling completed.
    H-22  nothing is forked.
    H-23  n/a (no regexes).
    H-24  the process is unbuffered (PYTHONUNBUFFERED is exported by lib.sh, and gzip is flushed
          every FLUSH_EVERY samples) so a reader tailing the file sees what has happened rather
          than what happened to be flushed.  The 08-30 round read a 706-line log with no HTTP
          lines in it and concluded the server had served nothing.

USAGE
    OUT=<dir> ./30_r2_r3_sample.py --seconds 900 --interval 0.5 --fabric p4

[Co-developed with claude code -- Adam]
"""

import argparse
import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.request

FLUSH_EVERY = 20


def probe(url, timeout=5.0):
    """One HTTP GET.

    H-19: returns a dict in which a transport failure and an HTTP status are different
    fields.  There is deliberately no single 'ok' boolean, because collapsing the two is how
    "the kernel did not answer" was concluded from a kernel that answered 404.
    """
    t0 = time.time()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            raw = r.read()
            return {"http": r.status, "err": None, "ms": round((time.time() - t0) * 1000, 1),
                    "body": _parse(raw), "bytes": len(raw)}
    except urllib.error.HTTPError as e:
        raw = b""
        try:
            raw = e.read()
        except Exception:
            pass
        return {"http": e.code, "err": None, "ms": round((time.time() - t0) * 1000, 1),
                "body": _parse(raw), "bytes": len(raw)}
    except Exception as e:                                  # transport: refused, timeout, DNS
        return {"http": None, "err": f"{type(e).__name__}: {e}",
                "ms": round((time.time() - t0) * 1000, 1), "body": None, "bytes": 0}


def _parse(raw):
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        # Keep the text.  A body that does not parse is evidence too -- the kernel has been
        # observed logging "JSON parsing failed ... last read: '<'".
        return {"__unparsed__": raw.decode("utf-8", "replace")[:4000]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=900,
                    help="total sampling duration; default 900 = 15 min = 15 energy cycles")
    ap.add_argument("--interval", type=float, default=0.5,
                    help="seconds between samples; must be < the fastest consumer cadence (1 s) "
                         "and < the R-2 recompute period (1 s), or the sampler cannot resolve "
                         "what it is measuring")
    ap.add_argument("--fabric", choices=["p4", "ovs"], required=True)
    ap.add_argument("--ndt", default=os.environ.get("NDT_URL", "http://localhost:8000"))
    ap.add_argument("--proxy", default=os.environ.get("P4_PROXY_URL", "http://localhost:8081"))
    ap.add_argument("--ryu", default=os.environ.get("RYU_URL", "http://localhost:8080"))
    ap.add_argument("--out", default=os.environ.get("OUT", "."))
    args = ap.parse_args()

    # The sampler must out-resolve its subject.  A ladder shorter than the thing it measures is
    # a recurring shape in this project (memory: instrument-must-not-mimic-its-own-finding).
    if args.interval >= 1.0:
        sys.stderr.write(
            "REFUSING: --interval %.2f s cannot resolve a 1 Hz recompute or a 1 s consumer "
            "cadence.  Use 0.5 or less.\n" % args.interval)
        return 3

    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "r2_samples.jsonl.gz")
    # H-20: never append.  A file already here belongs to another run.
    if os.path.exists(path):
        sys.stderr.write(
            "REFUSING: %s already exists.  Appending would mix two runs' samples into one "
            "series and the analysis could not tell them apart.  Move it aside or use a new "
            "RUN_TAG.\n" % path)
        return 3

    # all_destination_paths lives on the control plane, and its host differs by fabric.
    # F-8 (08-18) is exactly this defaulting to the wrong port and reporting a clean pass on
    # two channels out of three, silently.  It is a required argument here for that reason.
    if args.fabric == "p4":
        paths_url = args.proxy + "/ryu_server/all_destination_paths"
    else:
        paths_url = args.ryu + "/ryu_server/all_destination_paths"

    targets = [
        ("flows",  args.ndt + "/ndt/get_detected_flow_data"),
        ("graph",  args.ndt + "/ndt/get_graph_data"),
        ("paths",  paths_url),
    ]

    meta = {
        "started": time.time(),
        "started_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "argv": sys.argv,
        "fabric": args.fabric,
        "interval": args.interval,
        "seconds": args.seconds,
        "targets": dict(targets),
        "written_not_run": "this sampler was authored without being executed; first run is its "
                           "own first test (memory: new-tools-are-the-first-thing-under-test)",
        "cadence_note": "measured app cadences 2026-08-30: energy 60s, sim event-driven, "
                        "nsr 5s, viz 1s, te 1s.  PREREG R-2 assumes 15s for all consumers.",
    }
    with open(os.path.join(args.out, "r2_meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    deadline = time.time() + args.seconds
    n = 0
    fh = gzip.open(path, "wt")
    try:
        while time.time() < deadline:
            tick = time.time()
            rec = {"t": tick, "n": n}
            for name, url in targets:
                rec[name] = probe(url)
            fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
            n += 1
            if n % FLUSH_EVERY == 0:
                fh.flush()                      # H-24
                sys.stdout.write(
                    "  sample %d  t+%.0fs  flows=%s graph=%s paths=%s\n" % (
                        n, tick - meta["started"],
                        _short(rec["flows"]), _short(rec["graph"]), _short(rec["paths"])))
                sys.stdout.flush()
            sleep = args.interval - (time.time() - tick)
            if sleep > 0:
                time.sleep(sleep)
            else:
                # Recording that we could not keep up matters: a sampler silently slipping
                # behind its nominal rate reports a slower-changing world than the real one.
                rec_slow = {"t": time.time(), "n": n, "__overrun__": round(-sleep, 3)}
                fh.write(json.dumps(rec_slow, separators=(",", ":")) + "\n")
    finally:
        fh.close()

    print("wrote %d samples to %s" % (n, path))
    print("analyse with:  ./35_r2_r3_analyse.py --samples %s" % path)
    return 0


def _short(p):
    if p is None:
        return "?"
    if p.get("err"):
        return "ERR"
    return str(p.get("http"))


if __name__ == "__main__":
    sys.exit(main())
