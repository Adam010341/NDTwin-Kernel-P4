#!/usr/bin/env python3
"""Low-level measurement. Everything else in this harness rests on these being right.

TWO RULES THIS MODULE ENFORCES, because §5.3 of the spec says the harness is the first thing
under test and this codebase has twelve documented "fails while reporting success" mechanisms:

  1. **No function here returns an HTTP status code as evidence of anything.** `api_get`
     returns the parsed body or None. A caller cannot accidentally treat 200 as proof,
     because the status is not in the return value at all. (`02`'s INV-06 says
     "Do NOT check HTTP codes"; `04` §5.3 generalises it to everything.)
  2. **Every shell-out carries a timeout.** `popen(curl)` has been measured wedging for
     131 s against an IPv6 blackhole. "Known to fail" is not the same as "fails cheaply".

[Co-developed with claude code -- Adam]
"""
from __future__ import annotations

import json
import math
import os
import re
import subprocess
import time
from typing import Any

KERNEL = "http://localhost:8000"
PROXY = "http://localhost:8081"
CURL_MAX_TIME = 3.0

# sFlow sampling: the 95% error band in PERCENT for a sample count c, validated across a
# 430x window range and 10x load range. This is an instrument resolution floor, not a defect
# budget -- AO-03. Any tolerance narrower than this manufactures violations.
SFLOW_ERR_COEFF = 196.0
# Below this the sFlow estimate quantises to a single quantum (F-9), so a comparison against
# wire truth has no resolving power. Not "probably fine" -- literally undecidable.
LOW_RATE_FLOOR_BPS = 3_000_000
# include/common_types/GraphTypes.hpp:23 -- enum class VertexType { SWITCH, HOST }. Named
# rather than inlined because `n["vertex_type"] != 0` reads like a magic number and the whole
# 11-vs-10 false positive below came from nobody looking at this field at all.
VERTEX_TYPE_SWITCH = 0
VERTEX_TYPE_HOST = 1


class Timeout(Exception):
    pass


class SchemaDrift(Exception):
    """The graph payload did not carry the field a check depends on.

    Raised rather than defaulted. The whole reason this exception exists is that the first
    live null round found `switch_flags` silently treating hosts as switches; a helper that
    quietly copes with a missing discriminator turns a parse problem into a verdict, and a
    verdict-shaped parse problem is indistinguishable from a finding.
    """


def run(argv: list[str], timeout: float = 5.0,
        env: dict[str, str] | None = None) -> tuple[int, str, str]:
    """Run argv with a hard timeout. Never uses a shell, so nothing can be interpolated."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, **env} if env else None)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        raise Timeout(f"{argv[0]} exceeded {timeout}s")


# --------------------------------------------------------------------------------------------
# HTTP -- body only, never status
# --------------------------------------------------------------------------------------------
def api_get(path: str, base: str = KERNEL) -> Any | None:
    """GET and return the PARSED BODY, or None if it did not parse.

    Deliberately discards the status code. A 200 carrying an error string and a 200 carrying
    real data are the same to this function, which is the point: the caller is forced to judge
    on content. H20 is the concrete case -- `get_openflow_capacity` can answer 200 with an
    empty body when its file is missing, because the status was pre-set before the read.
    """
    try:
        rc, out, _ = run(["curl", "-s", "--max-time", str(CURL_MAX_TIME), f"{base}{path}"])
    except Timeout:
        return None
    if rc != 0 or not out.strip():
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def api_get_timed(path: str, base: str = KERNEL) -> tuple[Any | None, float]:
    """As api_get, plus wall-clock. Latency is evidence here: A-1's signature is a ~0.01 s
    power-on against an honest ~1.27 s, and the fast one is the LIE."""
    t0 = time.monotonic()
    body = api_get(path, base)
    return body, time.monotonic() - t0


def api_post_timed(path: str, payload: dict, base: str = KERNEL) -> tuple[Any | None, float]:
    """As api_post, plus wall-clock.

    ⚠️ Latency is only ever CORROBORATING evidence. `_c01_verify` once judged the A-1 defect on
    timing alone and a request that matched no route at all came back in 0.0069 s and was scored
    as a reproduction. Fast means "this returned quickly", not "this returned quickly having
    skipped the work" -- the second reading needs a state check beside it.
    """
    t0 = time.monotonic()
    body = api_post(path, payload, base)
    return body, time.monotonic() - t0


def api_post(path: str, payload: dict, base: str = KERNEL) -> Any | None:
    """POST via --data-binary @- so the body never touches a shell command line.

    Not merely tidy: B-2b is a live shell-injection through exactly this kind of
    interpolation, and `api-keys-leak-via-argv` is the same shape for secrets. The harness
    must not reproduce the defect it is testing for.
    """
    try:
        p = subprocess.run(
            ["curl", "-s", "--max-time", str(CURL_MAX_TIME), "-X", "POST",
             "-H", "Content-Type: application/json", "--data-binary", "@-", f"{base}{path}"],
            input=json.dumps(payload), capture_output=True, text=True, timeout=CURL_MAX_TIME + 2,
        )
    except subprocess.TimeoutExpired:
        return None
    if p.returncode != 0 or not p.stdout.strip():
        return None
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return None


# --------------------------------------------------------------------------------------------
# Independent ground truth -- none of this is written by the kernel
# --------------------------------------------------------------------------------------------
def bmv2_process_count() -> int:
    """Count live BMv2 switches.

    🔴 THE MUST-FIX FROM `03`. The oracle originally specified `pgrep -a simple_switch_grpc`.
    `-a` only changes output format; without `-f`, pgrep matches against `comm`, which the
    kernel truncates to 15 characters. "simple_switch_grpc" is 18. So that command matches
    ZERO processes with eleven switches running -- and it is the independent path of INV-01,
    the most important invariant, so it would have produced a 100% false-positive rate that
    looks exactly like "the system is broken".

    The bracket in 'simple_switch_g[r]pc' stops the pattern matching this harness's own
    command line. Do NOT "improve" this to `pgrep -xf`: -x with -f demands the WHOLE command
    line be equal, which is false for any process with arguments.

    `pgrep -c` prints 0 AND exits 1 when there are no matches, so `|| echo 0` in a shell
    version silently turns a real check into a constant. Handled here by reading rc explicitly.
    """
    rc, out, _ = run(["pgrep", "-cf", "simple_switch_g[r]pc"])
    if rc not in (0, 1):
        raise RuntimeError(f"pgrep failed unexpectedly rc={rc}")
    return int(out.strip() or 0)


def bmv2_provenance() -> dict:
    """Which bmv2 binary is actually running, named so a later reader can check it.

    🔴 Added 2026-08-29 after a sibling session asked "is this fabric on stock or fast?" and
    **not one artefact from the first live run could answer**. `ndt status` had said fast and
    the argv had said fast, but the committed JSON recorded neither, and the pre-state capture
    ran the argv through an `awk` that stripped the path. By the time the question arrived the
    fabric had been rebuilt and those processes were gone -- so the evidence existed only in a
    session transcript, which is exactly what `evidence-must-outlive-the-handoff` forbids.

    Provenance is one level below the strongest form, and says so: `/proc/<pid>/exe` is not
    readable as this uid, so this falls back to argv[0] cross-checked against the override file,
    with a sha256 of the resolved path. Same compromise ticket ① settled on, for the same
    reason. argv can be spoofed by whoever spawned the process; the sha256 pins the file that
    path currently names, which is not the same as pinning what the running process mapped.
    """
    out: dict = {"method": "argv[0] + sha256 of that path (NOT /proc/pid/exe -- unreadable "
                           "as this uid); the sha pins the file the path names now, not the "
                           "image the live process mapped"}
    try:
        rc, txt, _ = run(["pgrep", "-af", "simple_switch_g[r]pc"])
        if rc not in (0, 1):
            out["error"] = f"pgrep rc={rc}"
            return out
    except Timeout as e:
        out["error"] = str(e)
        return out

    paths: dict[str, int] = {}
    for line in txt.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            paths[parts[1]] = paths.get(parts[1], 0) + 1
    out["running"] = paths
    # More than one distinct binary across the fabric is a mixed-build fabric: every number
    # measured on it belongs to two populations at once. Loud, not a footnote.
    if len(paths) > 1:
        out["MIXED_BUILD"] = ("🔴 more than one bmv2 binary is running; any aggregate measured "
                              "here spans two builds and is not attributable to either")

    out["sha256"] = {}
    for p in paths:
        try:
            rc, h, _ = run(["sha256sum", p], timeout=30)
            out["sha256"][p] = h.split()[0] if rc == 0 and h.split() else f"rc={rc}"
        except Timeout:
            out["sha256"][p] = "timed out"

    # 🔴 Resolved from THIS FILE's location, walking up, not from the cwd. Caught by the
    # provenance mutation test on the day it was written: run from `harness/` the open() failed,
    # so `override_file_declares` said "unreadable" and the mismatch comparison below was
    # skipped entirely -- the check quietly became no check, and only for the people who ran it
    # the normal way. `harness-cd-hides-working-directory-defects`, same afternoon it was
    # written into the fix for something else.
    rel = "p4_proxy/mininet/bmv2_binary_override"
    here = os.path.dirname(os.path.abspath(__file__))
    override = None
    for _ in range(8):
        cand = os.path.join(here, rel)
        if os.path.exists(cand):
            override = cand
            break
        parent = os.path.dirname(here)
        if parent == here:
            break
        here = parent

    if override is None:
        # Not silently absent: an unfound file must not read the same as a matching one.
        out["OVERRIDE_UNREADABLE"] = (f"could not locate {rel} by walking up from this file; "
                                      f"the declared-vs-running cross-check DID NOT RUN")
        return out
    try:
        with open(override) as f:
            declared = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
    except OSError as e:
        out["OVERRIDE_UNREADABLE"] = f"{override}: {e}; the cross-check DID NOT RUN"
        return out

    out["override_file"] = override
    out["override_file_declares"] = declared[-1] if declared else None
    if declared and paths and declared[-1] not in paths:
        out["OVERRIDE_MISMATCH"] = (f"the override file declares {declared[-1]!r} but the "
                                    f"running processes are {list(paths)!r}")
    return out


def iface_bytes() -> dict[str, tuple[int, int]]:
    """{iface: (rx_bytes, tx_bytes)} from /proc/net/dev -- wire truth the kernel never writes."""
    out: dict[str, tuple[int, int]] = {}
    with open("/proc/net/dev") as f:
        for line in f.readlines()[2:]:
            name, _, rest = line.partition(":")
            fields = rest.split()
            if len(fields) >= 9:
                out[name.strip()] = (int(fields[0]), int(fields[8]))
    return out


def _stat_snapshot() -> tuple[int, int]:
    with open("/proc/stat") as f:
        vals = [int(x) for x in f.readline().split()[1:]]
    # idle + iowait counted as idle, the conventional split. Documented because the choice
    # matters: counting iowait as BUSY would make disk-heavy chaos actions look CPU-heavy and
    # void rounds that were fine.
    return sum(vals), vals[3] + vals[4]


def cpu_busy_fraction(window_s: float = 1.0) -> float:
    """Busy fraction over a window, from /proc/stat.

    🔑 NOT load1. `04` §2 is explicit: on 14 cores load1 is a lagging composite that also
    counts uninterruptible sleep, so as a threshold it can give the opposite answer. This is
    an instantaneous, bounded, per-window figure -- which is what the CPU anti-oracle needs.
    """
    t0, i0 = _stat_snapshot()
    time.sleep(window_s)
    t1, i1 = _stat_snapshot()
    dt = t1 - t0
    return 0.0 if dt <= 0 else 1.0 - (i1 - i0) / dt


def sflow_tolerance_pct(sample_count: int) -> float:
    """95% band in percent for a given sFlow sample count: 196/sqrt(c).

    A derived quantity's tolerance must be as wide as the noise it inherits. Comparing twin
    against wire at ±5% regardless of c is how a correct system gets reported as broken.
    """
    return float("inf") if sample_count <= 0 else SFLOW_ERR_COEFF / math.sqrt(sample_count)


# --------------------------------------------------------------------------------------------
# Convenience readers over the kernel API (content only)
# --------------------------------------------------------------------------------------------
def graph_data() -> Any | None:
    return api_get("/ndt/get_graph_data")


def flow_data() -> list[dict]:
    d = api_get("/ndt/get_detected_flow_data")
    return d if isinstance(d, list) else []


def switch_flags(graph: Any) -> dict[Any, dict]:
    """{dpid: {is_up, is_enabled, ...}} for SWITCHES ONLY, from a graph snapshot.

    🔴 THIS FUNCTION IS THE FIRST DEFECT THE NULL ROUND FOUND (2026-08-29). Keep the story,
    because the shape is reusable and it is the shape this project keeps hitting.

    It used to key every node by `dpid` with no type filter. On the 128-host P4 fabric **every
    host carries `dpid: 0`** -- so all 128 hosts collapsed into a single dict entry, last
    writer winning (`h128`, `is_up=true`), and that survivor was then counted as a switch.
    `up_in_graph` came out 11 against 10 live BMv2 processes, and INV-01 reported:

        "graph claims 11 switches up, only 10 BMv2 processes exist -- the twin is certifying
         dead switches (A-1 shape)"

    which is a fluent, plausible, entirely fabricated finding about the system under test.

    Three separate rules were broken at once, and each one alone would have been enough:

      1. **The instrument produced its own finding's shape.** INV-01 hunts for "graph claims
         more switches up than exist". An off-by-one inflation of the numerator manufactures
         exactly that, on a perfectly healthy fabric.
      2. **It was CONSTANT, so the invariant had zero resolving power.** +1 fires whether or
         not a switch is really dead, in the null round and in every injection round alike.
         An invariant that answers FAIL regardless of the input is not a weak check, it is
         not a check.
      3. **The silent drop looked like coverage.** 127 of 128 hosts vanished into a dict
         collision while the evidence field printed a confident `"total": 11`.

    So: filter on `vertex_type`, which `include/common_types/GraphTypes.hpp:23` defines as
    `enum class VertexType { SWITCH, HOST }` and `HttpSession.cpp:1219` states outright --
    "Must be 0 (switch) or 1 (host)".

    And raise instead of coping. `.get("vertex_type", 0)` would have re-created the original
    bug the first time the field was renamed, silently and in the optimistic direction. A
    caller that cannot classify nodes must report SKIPPED, never a verdict.
    """
    if not isinstance(graph, dict):
        raise SchemaDrift("graph payload is not an object")
    nodes = graph.get("nodes") or graph.get("vertices") or []
    if not isinstance(nodes, list):
        raise SchemaDrift("graph has neither a 'nodes' nor a 'vertices' list")

    out: dict[Any, dict] = {}
    untyped = 0
    for n in nodes:
        if not isinstance(n, dict):
            continue
        if "vertex_type" not in n:
            untyped += 1
            continue
        if n["vertex_type"] != VERTEX_TYPE_SWITCH:
            continue
        key = n.get("dpid", n.get("id", n.get("name")))
        if key is None:
            raise SchemaDrift(f"a switch node carries no dpid/id/name: {sorted(n)[:6]}")
        # Two switches on one dpid is the collision that started all this. Silently keeping the
        # last one is how 128 hosts became 1. If it ever happens to switches, say so loudly.
        if key in out:
            raise SchemaDrift(
                f"two switch nodes share dpid {key!r} "
                f"({out[key].get('device_name')!r} and {n.get('device_name')!r}); refusing to "
                f"drop one silently")
        out[key] = n

    if untyped:
        raise SchemaDrift(
            f"{untyped} of {len(nodes)} graph nodes carry no 'vertex_type', so switches cannot "
            f"be told from hosts. Classifying them by guess is what produced the 11-vs-10 false "
            f"positive on 2026-08-29")
    if not out:
        raise SchemaDrift(f"no vertex_type==0 nodes among {len(nodes)} graph nodes")
    return out


def decode_ip(n: int) -> str:
    """The API emits IPs as raw uint32 (FlowLinkUsageCollector.cpp:2300 writes flowKey.srcIP
    with no ipToString, unlike its neighbours at :2726). Measured 2026-08-29: 16777226 is
    10.0.0.1. Without this, any string comparison against a dotted quad silently never matches
    -- which is exactly how a 450 s run reported zero hits while the endpoint was correct."""
    return ".".join(str((n >> (8 * i)) & 0xFF) for i in range(4))


def flow_pair(rec: dict) -> tuple[str, str]:
    return decode_ip(rec.get("src_ip", 0)), decode_ip(rec.get("dst_ip", 0))
