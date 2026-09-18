#!/usr/bin/env python3
"""
Analysis for the three-group telemetry round: turns raw/ into summary.json and a text table.

[Co-developed with claude code -- Adam]

Design is PREREG.md. Every verdict this file emits was registered there before any packet, and
every threshold is a named constant below so a reader can check the code against the document
rather than against a remembered number.

PURE STDLIB, DELIBERATELY. It must run under p4_proxy/venv/bin/python -- the interpreter the
project's gates use and the one that has no matplotlib. plot.py is where matplotlib lives, and
it reads THIS file's summary.json rather than the raw, so no number can reach a figure without
passing through the analysis that the tests cover.

WHAT IT REFUSES TO DO
---------------------
  * turn a `none` cell's missing sampling error into 0. The group has no twin readings; a zero
    would be a reading. It stays None and the table prints n/a.
  * report a ratio for a cell whose two arms are more than one ladder rung apart. PREREG 5.1's
    H-A0 branch -- 1b section 4 records that a ratio round without an "indistinguishable" branch
    has to invent one after the fact.
  * fit a line through a Delta whose window-to-window spread exceeds the Delta. H-C0.
  * attribute a link group's extra error to dropped samples when the emitter's drop counters
    read zero. That is ROLE-5's finding written as code: a mechanism that was not observed does
    not go into a verdict.
  * compare an arm's foreign-CPU residual to the median of ALL arms. The gate is within group,
    because `tc action sample` burns softirq charged to no pid and a global gate would fire on
    the treatment (PREREG 6.2).

Usage:
    analyse.py --raw <run directory> [--out summary.json]
"""
import argparse
import json
import math
import os
import re
import sys

# --- the registered constants (PREREG). Named, so the code can be read against the document. --
LADDER_KPPS = [1, 2, 3, 5, 8, 12, 20, 30, 45, 70, 110, 160, 240]
#: PREREG 5.1. One REALISED ladder step, not the nominal 1.5x: the 08-30 correction to 08-28's
#: FINDINGS measured the 12 -> 20 kpps step this round's cells sit on at 1.667x.
RATIO_LO, RATIO_HI = 0.60, 1.67
#: PREREG 6.2. Absolute, and against the median arm OF THE SAME GROUP.
EXTERNAL_THRESHOLD = 0.15
#: PREREG 5.2. median|X| = 0.674 sd for a zero-mean normal; the band is [0.5, 2.0] x that.
MEDIAN_OVER_SD = 0.674
SHOT_BAND_LO, SHOT_BAND_HI = 0.5, 2.0
#: PREREG 5.2 / 3.4: the metric integrates over the inter-switch edges the flow crosses, and on
#: the 4-host model h1 -> h4 crosses four of them (s1 -> agg -> core -> agg -> s4). Recomputed
#: from the window's own key set when the raw records one, so this is only the fallback.
DEFAULT_ONPATH_LINKS = 4
DEFAULT_SAMPLING_DIVISOR = 256
#: PREREG 5.3 / 8(b). 08-20's marginal cost, and the factor band registered for "consistent".
OLD_MARGINAL_US_PER_SAMPLE = 206.0
MARGINAL_BAND_LO, MARGINAL_BAND_HI = 0.5, 3.0
FIXED_SHARE_CONSISTENT = 0.5
FIXED_SHARE_PER_SAMPLE = 0.2
#: PREREG 8(a). 08-28's 1024 B cell, the number reconciliation (a) is against.
OLD_1024B_KPPS = 16.0
#: PREREG 4.3 C1/C2.
SENDER_CONTROL_FACTOR = 5.0

GROUPS = ("none", "cooperative", "link")


# --- reading the raw ---------------------------------------------------------------------------

def parse_meta(text):
    """`key=value` lines into a dict; later lines win, and a line without '=' is skipped.

    Values keep their string form. The callers that want numbers ask for them explicitly, so a
    counter that came back `absent` cannot be silently coerced to 0 anywhere.
    """
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def _first_token(value):
    """The value up to the first whitespace. arm.meta carries trailing `# why` comments on some
    lines (`external=-1  # no samples`), and a number followed by its reason must still parse as
    that number rather than silently becoming the default."""
    if not isinstance(value, str):
        return value
    return value.split(None, 1)[0] if value.split() else value


def as_float(value, default=None):
    try:
        return float(_first_token(value))
    except (TypeError, ValueError, IndexError):
        return default


def as_int(value, default=None):
    try:
        return int(_first_token(value))
    except (TypeError, ValueError, IndexError):
        return default


def read_tsv(path):
    """A tab-separated file with a header row into a list of dicts, or [] if it is not there."""
    try:
        with open(path) as fh:
            lines = [line.rstrip("\n") for line in fh if line.strip()]
    except OSError:
        return []
    if not lines:
        return []
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:]]


def load_arm(directory):
    """One ladder arm: its meta, its ladder, its rung windows and its CPU trace path."""
    meta_path = os.path.join(directory, "arm.meta")
    if not os.path.exists(meta_path):
        return None
    with open(meta_path) as fh:
        meta = parse_meta(fh.read())
    return {
        "dir": directory,
        "arm": meta.get("arm", os.path.basename(directory)),
        "group": meta.get("group"),
        "frame": as_int(meta.get("frame_bytes")),
        "clean_kpps": as_float(meta.get("highest_clean_kpps")),
        "invalid": None if meta.get("invalid", "no") == "no" else meta.get("invalid"),
        "external": as_float(meta.get("external")),
        "softirq_share": as_float(meta.get("softirq_share")),
        "shares": {name: as_float(meta.get("%s_share" % name))
                   for name in ("bmv2", "iperf3", "kernel", "proxy", "emitter")},
        "kernel_sha": meta.get("kernel_sha256_start"),
        "switch_binary_sha": meta.get("switch_binary_sha256"),
        "pipeline_sha": meta.get("pipeline_json_sha256"),
        "truncated_at": meta.get("ladder_truncated_at"),
        "d_addressed": as_int(meta.get("d_addressed_total")),
        "families": {k[len("d_family_"):]: as_int(v)
                     for k, v in meta.items() if k.startswith("d_family_")},
        "ladder": read_tsv(os.path.join(directory, "ladder.tsv")),
        "rungs": read_tsv(os.path.join(directory, "rungs.tsv")),
        "meta": meta,
    }


def load_window(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def walk_raw(raw_dir):
    """Every arm and every sampling-error window under a run directory."""
    arms, windows, controls = [], [], {}
    for root, dirs, files in os.walk(raw_dir):
        dirs.sort()
        if "arm.meta" in files:
            arm = load_arm(root)
            if arm:
                arms.append(arm)
        if "window.json" in files:
            window = load_window(os.path.join(root, "window.json"))
            if window:
                window["dir"] = root
                windows.append(window)
        if "control.meta" in files:
            with open(os.path.join(root, "control.meta")) as fh:
                meta = parse_meta(fh.read())
            controls[meta.get("control", os.path.basename(root))] = meta
    arms.sort(key=lambda a: a["dir"])
    windows.sort(key=lambda w: w["dir"])
    return arms, windows, controls


# --- (1) the pps ceiling -------------------------------------------------------------------

def rung_index(kpps, ladder=None):
    """Where a rung sits on the ladder, or None if it is not one of them."""
    ladder = LADDER_KPPS if ladder is None else ladder
    try:
        return ladder.index(int(round(float(kpps))))
    except (ValueError, TypeError):
        return None


def cell_table(arms):
    """{(group, frame): cell} -- the two arms, their mean, and whether the cell is resolved.

    A cell whose arms are more than ONE ladder rung apart is unresolved: on a x1.5-ish ladder one
    rung IS the instrument's resolution, and averaging two values two rungs apart produces a
    number that no arm measured and that no repeat would reproduce.
    """
    cells = {}
    for arm in arms:
        if arm["invalid"] or arm["group"] not in GROUPS or arm["frame"] is None:
            continue
        cells.setdefault((arm["group"], arm["frame"]), []).append(arm)
    out = {}
    for key, members in sorted(cells.items()):
        values = [a["clean_kpps"] for a in members if a["clean_kpps"] is not None]
        entry = {"group": key[0], "frame": key[1],
                 "arms": {a["arm"]: a["clean_kpps"] for a in members},
                 "n": len(values), "mean": None, "resolved": False, "rung_gap": None}
        if values:
            entry["mean"] = sum(values) / len(values)
        if len(values) >= 2:
            indices = [rung_index(v) for v in values]
            if all(i is not None for i in indices):
                entry["rung_gap"] = max(indices) - min(indices)
                entry["resolved"] = entry["rung_gap"] <= 1
            else:
                entry["resolved"] = False
        elif len(values) == 1:
            entry["resolved"] = False           # one arm is not a replicated cell
        out[key] = entry
    return out


def ratio_verdict(ratio):
    """PREREG 5.1. H-A3 is deliberately not called a finding -- it is an instrument suspicion."""
    if ratio is None:
        return "H-A0 unresolved"
    if ratio < RATIO_LO:
        return "H-A2 telemetry costs data-plane pps"
    if ratio > RATIO_HI:
        return "H-A3 ratio above one realised rung -- suspect the instrument, not the fabric"
    return "H-A1 indistinguishable at +/-1 rung"


def ceiling_comparisons(cells):
    """Each treated cell against the `none` cell at the same frame size."""
    out = []
    frames = sorted({frame for (_group, frame) in cells})
    for frame in frames:
        base = cells.get(("none", frame))
        for group in ("cooperative", "link"):
            cell = cells.get((group, frame))
            row = {"frame": frame, "group": group,
                   "cell_mean": cell["mean"] if cell else None,
                   "none_mean": base["mean"] if base else None,
                   "ratio": None, "verdict": "H-A0 unresolved",
                   "why_unresolved": None}
            if not cell or not base:
                row["why_unresolved"] = "a cell is missing"
            elif not cell["resolved"] or not base["resolved"]:
                row["why_unresolved"] = (
                    "the arms of a cell are more than one rung apart (gap %s / %s)"
                    % (cell["rung_gap"], base["rung_gap"]))
            elif not base["mean"]:
                row["why_unresolved"] = "the none cell measured no clean rung"
            else:
                row["ratio"] = cell["mean"] / base["mean"]
                row["verdict"] = ratio_verdict(row["ratio"])
            out.append(row)
    return out


# --- (2) the sampling error ------------------------------------------------------------------

def median(values):
    ordered = sorted(values)
    if not ordered:
        return None
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def shot_noise_prediction(rate_mbit, payload_bytes, duration_s,
                          links=DEFAULT_ONPATH_LINKS, divisor=DEFAULT_SAMPLING_DIVISOR):
    """The registered prediction: median|ratio-1| = 0.674/sqrt(N) (PREREG 5.2).

    N is how many samples credit the inter-switch edges the metric sums over: the flow's packet
    rate, over the window, sampled 1/divisor at each of `links` receiving ports.
    """
    if not rate_mbit or not payload_bytes or duration_s <= 0:
        return None
    pps = rate_mbit * 1e6 / (payload_bytes * 8.0)
    n = links * pps * duration_s / float(divisor)
    if n <= 0:
        return None
    return {"n_samples": n, "median_abs": MEDIAN_OVER_SD / math.sqrt(n)}


EMITTER_STAT = re.compile(r"(\w+)=(\d+)")


def emitter_drops(log_text):
    """The emitter's last statistics line as {counter: value}, or {} when there is none.

    The line is `psample_sflow_emitter: samples=N emitted=N dropped_*=N ... enobufs=N
    per_switch=... elapsed=...`. Only the LAST line is used: the counters are cumulative, and an
    earlier line is a prefix of the story, not a different one.
    """
    last = None
    for line in (log_text or "").splitlines():
        if "psample_sflow_emitter:" in line:
            last = line
    if last is None:
        return {}
    return {key: int(value) for key, value in EMITTER_STAT.findall(last)
            if key not in ("elapsed",)}


def sampling_summary(windows):
    """Per (group, rate): the median |ratio-1|, the signed bias, and the registered verdict."""
    cells = {}
    for window in windows:
        if window.get("invalid"):
            continue
        key = (window.get("group"), window.get("offered_mbit"))
        cells.setdefault(key, []).append(window)
    out = []
    for (group, rate), members in sorted(cells.items(), key=lambda kv: (kv[0][0], kv[0][1] or 0)):
        row = {"group": group, "offered_mbit": rate, "windows": len(members),
               "median_abs_error": None, "median_signed_error": None,
               "predicted": None, "verdict": None, "note": None,
               "nonzero_twin_readings": sum(m.get("nonzero_twin_readings") or 0 for m in members)}
        sample = members[0]
        row["predicted"] = shot_noise_prediction(
            rate, sample.get("payload_bytes") or 1400, sample.get("duration_s") or 8.0,
            links=len(sample.get("keys") or []) or DEFAULT_ONPATH_LINKS)
        if group == "none":
            # 🔴 n/a, never 0. PREREG 5.2: the group has no twin readings, and reporting a zero
            # would turn an absence into a measurement.
            row["note"] = ("n/a -- the none group has no twin readings; "
                           "non-zero readings observed: %d (must be 0)"
                           % row["nonzero_twin_readings"])
            out.append(row)
            continue
        abs_errors = [m["abs_error"] for m in members if m.get("abs_error") is not None]
        signed = [m["signed_error"] for m in members if m.get("signed_error") is not None]
        row["median_abs_error"] = median(abs_errors)
        row["median_signed_error"] = median(signed)
        if row["median_abs_error"] is None or not row["predicted"]:
            row["verdict"] = "no reading"
        else:
            predicted = row["predicted"]["median_abs"]
            low, high = SHOT_BAND_LO * predicted, SHOT_BAND_HI * predicted
            if low <= row["median_abs_error"] <= high:
                row["verdict"] = "H-B1 shot-noise limited"
            elif row["median_abs_error"] > high:
                same_sign = signed and (all(s > 0 for s in signed) or all(s < 0 for s in signed))
                row["verdict"] = ("H-B2 systematic bias" if same_sign
                                  else "above the shot-noise band, signs mixed")
            else:
                row["verdict"] = "below the shot-noise band"
        out.append(row)
    return out


def link_vs_cooperative(summary_rows, emitter_counters=None):
    """H-B4, and H-B3's attribution -- which may only be made when a counter actually moved."""
    by_key = {(row["group"], row["offered_mbit"]): row for row in summary_rows}
    rates = sorted({rate for (group, rate) in by_key if group == "cooperative"})
    out = []
    for rate in rates:
        link = by_key.get(("link", rate))
        coop = by_key.get(("cooperative", rate))
        row = {"offered_mbit": rate, "link": None, "cooperative": None,
               "ratio": None, "verdict": "no reading", "attribution": None}
        if link and coop:
            row["link"], row["cooperative"] = link["median_abs_error"], coop["median_abs_error"]
        if row["link"] is None or not row["cooperative"]:
            out.append(row)
            continue
        row["ratio"] = row["link"] / row["cooperative"]
        row["verdict"] = ("H-B4 the two paths are equally accurate" if 0.5 <= row["ratio"] <= 2.0
                          else "the two paths are NOT equally accurate")
        if row["ratio"] > 2.0:
            dropped = sum(value for key, value in (emitter_counters or {}).items()
                          if key.startswith("dropped_") or key == "enobufs")
            if dropped > 0:
                row["attribution"] = ("H-B3 sample loss: the emitter's counters moved (%s)"
                                      % ", ".join("%s=%d" % kv for kv in
                                                  sorted((emitter_counters or {}).items())
                                                  if kv[0].startswith("dropped_")
                                                  or kv[0] == "enobufs"))
            else:
                # 🔴 ROLE-5 written as code. The one thing that round did wrong was to put a
                # mechanism it had not observed into a verdict string.
                row["attribution"] = ("NOT attributed to sample loss: every dropped_*/enobufs "
                                      "counter read zero, so that mechanism was not observed")
        out.append(row)
    return out


# --- (3) CPU ----------------------------------------------------------------------------------

def load_cpu(path):
    """(header, rows) from a cpu_arm_probe.py trace; ([], []) when it is not readable."""
    header, rows = None, []
    try:
        fh = open(path)
    except OSError:
        return None, []
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                document = json.loads(line)
            except ValueError:
                continue
            if header is None:
                header = document
            elif "machine" in document:
                rows.append(document)
    return header, rows


def label_of(key):
    """`bmv2-3:1234` -> `bmv2`; `kernel:99` -> `kernel`. The ten switches are one class."""
    name = key.rsplit(":", 1)[0]
    return "bmv2" if name.startswith("bmv2") else name


def cpu_for_window(rows, clk_tck, t0, t1):
    """{label: percent of ONE core} over [t0, t1], plus the machine's busy and softirq shares.

    Percent of one core, not of the machine: 08-20 reported bmv2 at 151% and the machine has 14
    cores, and a percentage of the machine would have made the single-threaded forwarding loop
    -- the thing the number is about -- unreadable.
    """
    inside = [row for row in rows if t0 <= row["t"] <= t1]
    if len(inside) < 2 or clk_tck <= 0:
        return None
    first, last = inside[0], inside[-1]
    elapsed = last["t"] - first["t"]
    if elapsed <= 0:
        return None
    # 🔴 FIRST SIGHT IS NOT THE SAME FACT FOR A LONG-LIVED PROCESS AND A NEW ONE. The kernel,
    # the proxy, the emitter and the ten bmv2s were alive before the window, so their first
    # reading is a LIFETIME total and adding it would attribute hours of CPU to eight seconds.
    # An iperf3 that appears mid-window started at zero, so its first reading IS its cost so far.
    # The discriminator is whether the key was present in the window's first row. 08-28 lost a
    # whole generator's cost to the other half of this distinction.
    present_at_start = set((inside[0].get("proc") or {}).keys())
    seen, accumulated = {}, {}
    for row in inside:
        for key, value in row.get("proc", {}).items():
            name = label_of(key)
            if key not in seen:
                accumulated[name] = accumulated.get(name, 0) + (0 if key in present_at_start
                                                                else value)
            elif value < seen[key]:
                accumulated[name] = accumulated.get(name, 0) + value       # pid reused mid-window
            else:
                accumulated[name] = accumulated.get(name, 0) + (value - seen[key])
            seen[key] = value
    out = {name: 100.0 * jiffies / clk_tck / elapsed for name, jiffies in accumulated.items()}
    # The control plane's share of sampling, as one number: under `none` and `cooperative` there
    # is no emitter at all, and a panel with a missing series reads as missing data rather than
    # as "that process does not exist in this group".
    out["_proxy_plus_emitter"] = out.get("proxy", 0.0) + out.get("emitter", 0.0)
    busy_columns = ("user", "nice", "system", "irq", "softirq", "steal")
    d_busy = sum(last["machine"][c] - first["machine"][c] for c in busy_columns)
    d_total = sum(last["machine"][c] - first["machine"][c] for c in last["machine"])
    d_softirq = last["machine"]["softirq"] - first["machine"]["softirq"]
    out["_elapsed_s"] = elapsed
    out["_machine_busy_frac"] = (d_busy / d_total) if d_total else None
    out["_softirq_frac"] = (d_softirq / d_total) if d_total else None
    return out


def rung_windows(arm):
    """{kpps: (t_start, t_end)} from rungs.tsv -- the span of all the reps of that rung."""
    spans = {}
    for row in arm.get("rungs") or []:
        kpps = as_float(row.get("kpps"))
        t0, t1 = as_float(row.get("t_start")), as_float(row.get("t_end"))
        if kpps is None or t0 is None or t1 is None:
            continue
        low, high = spans.get(kpps, (t0, t1))
        spans[kpps] = (min(low, t0), max(high, t1))
    return spans


def rung_samples_per_second(arm, kpps):
    """Measured samples/s at one rung, from that rung's own get_sflow_stats pair (A1.5)."""
    spans = rung_windows(arm)
    span = spans.get(kpps)
    if not span:
        return None
    before = load_window(os.path.join(arm["dir"], "sflow_rung%d_before.json" % int(kpps)))
    after = load_window(os.path.join(arm["dir"], "sflow_rung%d_after.json" % int(kpps)))
    if not before or not after:
        return None

    def addressed(document):
        health = document.get("telemetry_health")
        source = health if isinstance(health, dict) else document
        value = source.get("addressed_total")
        if value is None and isinstance(health, dict):
            value = document.get("addressed_total")
        return value if isinstance(value, int) else None

    b, a = addressed(before), addressed(after)
    elapsed = span[1] - span[0]
    if b is None or a is None or elapsed <= 0:
        return None
    return (a - b) / elapsed


def cpu_by_rung(arm):
    """{kpps: {label: percent of one core, ...}} for one arm, sliced by its own rung windows."""
    header, rows = load_cpu(os.path.join(arm["dir"], "cpu.jsonl"))
    if not header or not rows:
        return {}
    clk_tck = header.get("clk_tck") or 100
    out = {}
    for kpps, (t0, t1) in sorted(rung_windows(arm).items()):
        measured = cpu_for_window(rows, clk_tck, t0, t1)
        if measured is None:
            continue
        measured["_samples_per_s"] = rung_samples_per_second(arm, kpps)
        out[kpps] = measured
    return out


def fit_fixed_and_marginal(points):
    """Least squares on (samples/s, delta CPU) -> (F, m_percent_per_sample). None if degenerate.

    Written out rather than pulled from a library because this file may not import anything the
    venv does not have, and because the two returned numbers are the whole of hypothesis H-C1.
    """
    usable = [(x, y) for x, y in points if x is not None and y is not None]
    if len(usable) < 2:
        return None
    n = len(usable)
    sum_x = sum(x for x, _ in usable)
    sum_y = sum(y for _, y in usable)
    sum_xx = sum(x * x for x, _ in usable)
    sum_xy = sum(x * y for x, y in usable)
    denominator = n * sum_xx - sum_x * sum_x
    if denominator == 0:
        return None
    slope = (n * sum_xy - sum_x * sum_y) / denominator
    intercept = (sum_y - slope * sum_x) / n
    return {"fixed_percent": intercept, "marginal_percent_per_sample": slope,
            "marginal_us_per_sample": slope * 1e4, "points": n,
            "max_samples_per_s": max(x for x, _ in usable)}


def cpu_comparison(arms, frame=1024, label="kernel"):
    """Delta<label>(group - none) at every rung both groups measured, plus the (F, m) fit."""
    by_group = {}
    for arm in arms:
        if arm["invalid"] or arm["frame"] != frame or arm["group"] not in GROUPS:
            continue
        by_group.setdefault(arm["group"], []).append(arm)
    per_group_rung = {}
    for group, members in by_group.items():
        collected = {}
        for arm in members:
            for kpps, measured in cpu_by_rung(arm).items():
                collected.setdefault(kpps, []).append(measured)
        per_group_rung[group] = {
            kpps: {"cpu": median([m.get(label, 0.0) for m in values]),
                   "spread": (max(m.get(label, 0.0) for m in values)
                              - min(m.get(label, 0.0) for m in values)) if len(values) > 1 else 0.0,
                   "samples_per_s": median([m.get("_samples_per_s") for m in values
                                            if m.get("_samples_per_s") is not None]),
                   # carried through for figure 3's third panel and for the softirq statement
                   # PREREG 5.3 registers for the link group
                   "_proxy_plus_emitter": median([m.get("_proxy_plus_emitter", 0.0)
                                                  for m in values]),
                   "softirq_frac": median([m.get("_softirq_frac") for m in values
                                           if m.get("_softirq_frac") is not None]),
                   "arms": len(values)}
            for kpps, values in collected.items()}
    out = {"frame": frame, "label": label, "rows": [], "fits": {}, "per_group": per_group_rung}
    base = per_group_rung.get("none", {})
    for group in ("cooperative", "link"):
        treated = per_group_rung.get(group, {})
        points, rows = [], []
        for kpps in sorted(set(treated) & set(base)):
            if treated[kpps]["cpu"] is None or base[kpps]["cpu"] is None:
                continue
            delta = treated[kpps]["cpu"] - base[kpps]["cpu"]
            spread = max(treated[kpps]["spread"], base[kpps]["spread"])
            row = {"group": group, "kpps": kpps, "delta_percent": delta, "spread": spread,
                   "samples_per_s": treated[kpps]["samples_per_s"],
                   "resolved": abs(delta) >= spread}
            rows.append(row)
            if row["resolved"]:
                points.append((row["samples_per_s"], delta))
        out["rows"].extend(rows)
        if not points:
            # 🔴 H-C0. "Below the instrument's resolution" is a reading; a fit through it is not.
            out["fits"][group] = {"verdict": "H-C0 not resolved -- the window-to-window spread "
                                             "is larger than the effect at every rung",
                                  "fit": None}
            continue
        fit = fit_fixed_and_marginal(points)
        out["fits"][group] = {"fit": fit, "verdict": cpu_verdict(fit)}
    return out


def cpu_verdict(fit):
    """PREREG 5.3: H-C1 / H-C2 / H-C3, with H-C3 registered as a RESULT, not 'inconclusive'."""
    if not fit:
        return "H-C0 not resolved"
    marginal = fit["marginal_us_per_sample"]
    top = fit["fixed_percent"] + fit["marginal_percent_per_sample"] * fit["max_samples_per_s"]
    share = (fit["fixed_percent"] / top) if top else None
    within_band = (MARGINAL_BAND_LO * OLD_MARGINAL_US_PER_SAMPLE <= marginal
                   <= MARGINAL_BAND_HI * OLD_MARGINAL_US_PER_SAMPLE)
    if (share is not None and share >= FIXED_SHARE_CONSISTENT) or within_band:
        return "H-C1 cost is dominated by a fixed component (08-20 reproduces)"
    if share is not None and share <= FIXED_SHARE_PER_SAMPLE:
        return "H-C2 cost is per sample (08-20's fixed component does not reproduce here)"
    return "H-C3 mixed -- the decomposition IS the result (PREREG 5.3)"


# --- the load gate, within group ---------------------------------------------------------------

def external_gate(arms):
    """PREREG 6.2: an arm fires when its external exceeds ITS OWN GROUP's median by > 0.15."""
    by_group = {}
    for arm in arms:
        if arm["external"] is None or arm["external"] < 0:
            continue
        by_group.setdefault(arm["group"], []).append(arm)
    rows = []
    for group, members in sorted(by_group.items()):
        reference = median([a["external"] for a in members])
        for arm in members:
            rows.append({"arm": arm["arm"], "group": group, "external": arm["external"],
                         "group_median": reference,
                         "softirq_share": arm["softirq_share"],
                         "fires": (arm["external"] - reference) > EXTERNAL_THRESHOLD})
    return rows


# --- the three reconciliations (PREREG 8) ------------------------------------------------------

def reconcile(cells, cpu, controls):
    """(a), (b) and (c), each with the registered interval and what falling outside means."""
    rows = []

    # (a) -- reported against BOTH cells, because 08-28's arms sampled cooperatively.
    for group in ("none", "cooperative"):
        cell = cells.get((group, 1024))
        mine = cell["mean"] if cell else None
        ratio = (mine / OLD_1024B_KPPS) if mine else None
        rows.append({
            "id": "a", "group": group, "mine_kpps": mine, "theirs_kpps": OLD_1024B_KPPS,
            "ratio": ratio,
            "interval": [RATIO_LO, RATIO_HI],
            "consistent": (ratio is not None and RATIO_LO <= ratio <= RATIO_HI),
            "matched": group == "cooperative",
            "note": ("condition-matched: 08-28's arms ran with production cooperative sampling on"
                     if group == "cooperative"
                     else "the ticket's named pairing; 08-28 had no zero-telemetry arm"),
            "outside_means": ("NOT a refutation -- name which of the four stated differences "
                              "(fabric size, path length, kernel binary, telemetry group) could "
                              "carry it, and say that only a matched-fabric arm would decide, "
                              "which this round does not have"),
        })

    # (b) -- the marginal slope, because it is the quantity that should transfer across fabrics.
    for group, entry in sorted((cpu.get("fits") or {}).items()):
        fit = entry.get("fit")
        marginal = fit["marginal_us_per_sample"] if fit else None
        top = (fit["fixed_percent"] + fit["marginal_percent_per_sample"] * fit["max_samples_per_s"]
               ) if fit else None
        share = (fit["fixed_percent"] / top) if fit and top else None
        rows.append({
            "id": "b", "group": group,
            "marginal_us_per_sample": marginal, "theirs_us_per_sample": OLD_MARGINAL_US_PER_SAMPLE,
            "fixed_share": share,
            "interval": [MARGINAL_BAND_LO * OLD_MARGINAL_US_PER_SAMPLE,
                         MARGINAL_BAND_HI * OLD_MARGINAL_US_PER_SAMPLE],
            "consistent": bool(
                (marginal is not None
                 and MARGINAL_BAND_LO * OLD_MARGINAL_US_PER_SAMPLE <= marginal
                 <= MARGINAL_BAND_HI * OLD_MARGINAL_US_PER_SAMPLE)
                or (share is not None and share >= FIXED_SHARE_CONSISTENT)),
            "verdict": entry.get("verdict"),
            "outside_means": ("the fixed-cost result does not reproduce on a 10-switch fabric at "
                              "8 s windows -- a result. Name the candidate among the three stated "
                              "differences (fabric size, window length, the zero point) and what "
                              "would decide it"),
        })

    # (c) -- side by side, and 🔴 nothing in this row may be divided by anything in it.
    cell = cells.get(("none", 1024))
    mine = cell["mean"] if cell else None
    rows.append({
        "id": "c",
        "table": [
            {"source": "08-15", "value": "fast 300 Mbit/s", "conditions": "3 hops, 1400 B"},
            {"source": "1b (08-28)", "value": "fast 360 Mbit/s",
             "conditions": "1 hop, 1400 B, control plane live"},
            {"source": "2 (08-28)", "value": "fast 16.0 kpps = 131.1 Mbit/s frame",
             "conditions": "3 hops, 1024 B frame, 128 hosts, cooperative sampling on"},
            {"source": "this round", "value": (None if mine is None else
                                               "%.1f kpps = %.1f Mbit/s frame"
                                               % (mine, mine * 1000 * 1024 * 8 / 1e6)),
             "conditions": "4 inter-switch hops, 1024 B frame, 4 hosts, NO telemetry"},
        ],
        "forbidden": "no cell of this table may be divided by another; this round ran no stock arm",
    })

    # the sender controls, which gate (a) and everything else at their frame size
    for control, frame in (("C1", 64), ("C2", 1024)):
        meta = controls.get(control) or {}
        ceiling = as_float(meta.get("ceiling_pps"))
        highest = max([c["mean"] for (g, f), c in cells.items()
                       if f == frame and c["mean"] is not None] or [0.0]) * 1000.0
        rows.append({
            "id": control, "frame": frame, "ceiling_pps": ceiling,
            "highest_measured_pps": highest or None,
            "required_pps": (highest * SENDER_CONTROL_FACTOR) if highest else None,
            "passes": bool(ceiling and highest and ceiling >= SENDER_CONTROL_FACTOR * highest),
            "outside_means": ("the round reports only 'generator-limited' at this frame size and "
                              "may say nothing about bmv2's pps there (PREREG 7)"),
        })
    return rows


# --- putting it together -----------------------------------------------------------------------

def analyse(raw_dir):
    arms, windows, controls = walk_raw(raw_dir)
    cells = cell_table(arms)
    emitter = {}
    for arm in arms:
        if arm["group"] != "link":
            continue
        try:
            with open(os.path.join(arm["dir"], "emitter.log")) as fh:
                for key, value in emitter_drops(fh.read()).items():
                    emitter[key] = emitter.get(key, 0) + value
        except OSError:
            pass
    sampling = sampling_summary(windows)
    cpu = cpu_comparison(arms, frame=1024, label="kernel")
    bmv2 = cpu_comparison(arms, frame=1024, label="bmv2")
    summary = {
        "raw": os.path.abspath(raw_dir),
        "arms": [{k: v for k, v in arm.items() if k not in ("ladder", "rungs", "meta")}
                 for arm in arms],
        "invalid_arms": [{"arm": a["arm"], "reason": a["invalid"]} for a in arms if a["invalid"]],
        "cells": {"%s|%s" % key: value for key, value in cells.items()},
        "ceiling": ceiling_comparisons(cells),
        "sampling_error": sampling,
        "sampling_error_cross_group": link_vs_cooperative(sampling, emitter),
        "emitter_counters": emitter,
        "cpu_kernel": cpu,
        "cpu_bmv2": bmv2,
        "external_gate": external_gate(arms),
        "controls": controls,
        "reconciliation": reconcile(cells, cpu, controls),
        "binaries": sorted({(a["kernel_sha"] or "?")[:12] for a in arms}),
        "families": {a["arm"]: a["families"] for a in arms if a["families"]},
    }
    return summary


def render(summary, stream=sys.stdout):
    """The text table. Deliberately terse: FINDINGS.md is where the prose belongs."""
    write = stream.write
    write("=== arms\n")
    for arm in summary["arms"]:
        write("  %-28s %-12s %-6s clean=%-8s external=%-8s %s\n"
              % (arm["arm"], arm["group"], arm["frame"], arm["clean_kpps"], arm["external"],
                 "INVALID: %s" % arm["invalid"] if arm["invalid"] else ""))
    write("\n=== (1) pps ceiling, against the none cell at the same frame\n")
    for row in summary["ceiling"]:
        write("  %-12s %5sB  cell=%-8s none=%-8s ratio=%-8s %s%s\n"
              % (row["group"], row["frame"], row["cell_mean"], row["none_mean"],
                 None if row["ratio"] is None else "%.3f" % row["ratio"], row["verdict"],
                 "" if not row["why_unresolved"] else "  (%s)" % row["why_unresolved"]))
    write("\n=== (2) sampling error, |twin/truth - 1|\n")
    for row in summary["sampling_error"]:
        predicted = row["predicted"]["median_abs"] if row["predicted"] else None
        write("  %-12s %6s Mbit/s  median|err|=%-8s signed=%-9s predicted=%-8s %s\n"
              % (row["group"], row["offered_mbit"],
                 "n/a" if row["median_abs_error"] is None else "%.4f" % row["median_abs_error"],
                 "n/a" if row["median_signed_error"] is None else "%+.4f" % row["median_signed_error"],
                 "n/a" if predicted is None else "%.4f" % predicted,
                 row["verdict"] or row["note"] or ""))
    for row in summary["sampling_error_cross_group"]:
        write("  link/coop at %6s Mbit/s: %-8s %s%s\n"
              % (row["offered_mbit"],
                 "n/a" if row["ratio"] is None else "%.2f" % row["ratio"], row["verdict"],
                 "" if not row["attribution"] else "\n      %s" % row["attribution"]))
    write("\n=== (3) CPU, 1024 B ladder, kernel\n")
    for row in summary["cpu_kernel"]["rows"]:
        write("  %-12s %6s kpps  delta=%-9s spread=%-9s samples/s=%-8s %s\n"
              % (row["group"], row["kpps"], "%.2f" % row["delta_percent"], "%.2f" % row["spread"],
                 "n/a" if row["samples_per_s"] is None else "%.1f" % row["samples_per_s"],
                 "resolved" if row["resolved"] else "NOT resolved (spread >= effect)"))
    for group, entry in sorted(summary["cpu_kernel"]["fits"].items()):
        fit = entry.get("fit")
        write("  %-12s %s%s\n" % (group, entry["verdict"],
                                  "" if not fit else
                                  "  (F=%.2f%% of one core, m=%.0f us/sample)"
                                  % (fit["fixed_percent"], fit["marginal_us_per_sample"])))
    write("\n=== load gate (within group, +%.2f absolute)\n" % EXTERNAL_THRESHOLD)
    for row in summary["external_gate"]:
        write("  %-28s %-12s external=%.4f  group median=%.4f  softirq=%s  %s\n"
              % (row["arm"], row["group"], row["external"], row["group_median"],
                 "n/a" if row["softirq_share"] is None else "%.4f" % row["softirq_share"],
                 "FIRES -- rerun" if row["fires"] else "ok"))
    write("\n=== reconciliation\n")
    for row in summary["reconciliation"]:
        if row["id"] == "c":
            write("  (c) side by side, NO cell divided by another:\n")
            for entry in row["table"]:
                write("      %-14s %-34s %s\n" % (entry["source"], entry["value"], entry["conditions"]))
            continue
        if row["id"] in ("C1", "C2"):
            write("  %s  generator ceiling %s pps vs %sx the highest measured (%s): %s\n"
                  % (row["id"], row["ceiling_pps"], SENDER_CONTROL_FACTOR,
                     row["required_pps"], "PASSES" if row["passes"] else "FAILS"))
            continue
        write("  (%s) %-12s %s\n" % (row["id"], row["group"],
                                     "consistent" if row["consistent"] else "OUTSIDE the interval"))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Analyse the three-group telemetry round")
    parser.add_argument("--raw", required=True, help="a run directory written by drive_e.sh")
    parser.add_argument("--out", help="where to write summary.json (default: <raw>/summary.json)")
    args = parser.parse_args(argv)
    if not os.path.isdir(args.raw):
        print("analyse.py: %s is not a directory" % args.raw, file=sys.stderr)
        return 2
    summary = analyse(args.raw)
    out = args.out or os.path.join(args.raw, "summary.json")
    with open(out, "w") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True, default=str)
        fh.write("\n")
    render(summary)
    print("\nsummary -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
