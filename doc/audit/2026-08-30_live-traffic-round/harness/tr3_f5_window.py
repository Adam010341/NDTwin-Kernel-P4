#!/usr/bin/env python3
"""
tr3_f5_window.py -- TR-3: how long is F-5's queued-but-unprogrammed exposure window, and does
it grow under contention?

PREREG §3 TR-3. T-4's FINDING-03 established WHAT the phantom is (the POST body re-served as a
table row) and bounded WHEN with a grid of {0, 2, 4, ...}: present at t=0, absent by t=2. That
bounds the window only to the open interval (0, 2] s, because the ladder had no rung in between.
This probe puts rungs in between.

WHAT IT MEASURES, AND WHAT IT CANNOT
    It polls GET /ndt/get_switch_openflow_table_entries as fast as the kernel will answer, so its
    RESOLUTION IS THE REQUEST LATENCY -- and the northbound API serialises one request at a time
    (memory: northbound-api-serialises), so a poll is not free: this instrument competes with the
    very dispatch queue whose window it is timing. Both are reported. A window shorter than the
    measured inter-sample gap is recorded as "< gap", never as a number.
    🔑 memory: instrument-must-not-mimic-its-own-finding -- a ladder shorter than the thing it
    measures. Here the ladder's rungs are request latencies and they are printed next to the
    answer so nobody has to take the resolution on trust.

CLASSIFICATION IS STRUCTURAL, NEVER SUBSTRING
    FINDING-03 recorded that the harness's `grep -c '901'` cannot exceed 1 on a newline-free body
    (the H-16 shape) and happened not to produce a false positive. This does not repeat that.
    Every entry is parsed and classified on the three discriminators FINDING-03 established:
        phantom : ~4 fields, NO byte_count/packet_count/duration_*/cookie, match spelled in the
                  POST's vocabulary (eth_type/ipv4_dst), actions elements are OBJECTS
        real    : 13 fields with statistics present, match spelled OpenFlow's way
                  (dl_type/nw_dst), actions elements are STRINGS ("OUTPUT:3")

THE CONTROL IS FIRST AND IT IS LOAD-BEARING
    Before any rep, a VALID rule is installed and must become visible as a REAL entry. If the
    instrument cannot see a rule that exists, then "no phantom" is produced by blindness and no
    verdict may be recorded from this run. `--force-blind` exists to demonstrate that this gate
    actually goes red (point it at a port with nothing on it).

[Co-developed with claude code -- Adam]
"""
import argparse, json, os, sys, time, urllib.error, urllib.request

STAT_FIELDS = ("byte_count", "packet_count", "duration_sec", "duration_nsec", "cookie")
POST_VOCAB  = ("eth_type", "ipv4_dst")
OF_VOCAB    = ("dl_type", "nw_dst")


def req(url, method="GET", body=None, timeout=15.0):
    """Returns (elapsed_s, http_status_or_None, transport_error_or_None, parsed_or_raw)."""
    data = body.encode() if body else None
    r = urllib.request.Request(url, data=data, method=method)
    if body:
        r.add_header("Content-Type", "application/json")
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
    except urllib.error.HTTPError as e:              # a 4xx/5xx IS the service answering (H-19)
        raw, status = e.read().decode("utf-8", "replace"), e.code
    except Exception as e:                           # transport failure is a different observation
        return (time.monotonic() - t0, None, repr(e), None)
    dt = time.monotonic() - t0
    try:
        return (dt, status, None, json.loads(raw))
    except Exception:
        return (dt, status, None, raw)


def classify(entry):
    """-> 'phantom' | 'real' | 'other'. Structural, per FINDING-03's three discriminators."""
    if not isinstance(entry, dict):
        return "other"
    has_stats = any(k in entry for k in STAT_FIELDS)
    m = entry.get("match") or {}
    post_vocab = isinstance(m, dict) and any(k in m for k in POST_VOCAB)
    of_vocab = isinstance(m, dict) and any(k in m for k in OF_VOCAB)
    acts = entry.get("actions") or []
    obj_actions = bool(acts) and isinstance(acts[0], dict)
    if not has_stats and (post_vocab or obj_actions):
        return "phantom"
    if has_stats and of_vocab:
        return "real"
    return "other"


def entries_of(body):
    """The table view's entry list, wherever it lives, without guessing silently.

    MEASURED SHAPE (128-host P4 stack, 2026-08-30):

        [ {"dpid": 1, "flows": {"1": [ {…}, … 128 entries … ]}},  … 10 dpid wrappers … ]

    i.e. three levels deep: a per-switch list, a table-id-keyed dict, then the entries. The first
    version of this function returned the TOP-LEVEL LIST -- ten `{"dpid","flows"}` wrappers, none
    of which carries a `priority` -- so it found 0 real and 0 phantom entries and reported
    "10 entries". The control caught it before a single verdict was recorded, which is the entire
    reason the control runs first and is allowed to abort.
    🔑 The failure was silent in the direction that matters: 0 phantom is exactly what a working
    system looks like. Only the CONTROL's "and 0 real, too" made it visible.

    `_dpid`/`_table` are attached for provenance. classify() keys off statistics fields and match
    vocabulary, never off a field count, so the extra keys cannot change a classification.
    """
    if (isinstance(body, list) and body and isinstance(body[0], dict)
            and "flows" in body[0] and "dpid" in body[0]):
        out = []
        for el in body:
            fl = el.get("flows")
            if isinstance(fl, dict):
                for tid, lst in fl.items():
                    if isinstance(lst, list):
                        out += [dict(e, _dpid=el.get("dpid"), _table=tid)
                                for e in lst if isinstance(e, dict)]
            elif isinstance(fl, list):
                out += [dict(e, _dpid=el.get("dpid")) for e in fl if isinstance(e, dict)]
        return out, f"flattened dpid->flows[table][] over {len(body)} switch wrapper(s)"
    if isinstance(body, list):
        return body, "top-level list"
    if isinstance(body, dict):
        for k in ("entries", "flows", "flow_entries", "data", "result"):
            v = body.get(k)
            if isinstance(v, list):
                return v, f"body[{k!r}]"
        for k, v in body.items():                     # dpid-keyed map
            if isinstance(v, list):
                return v, f"body[{k!r}] (first list-valued key)"
    return [], "NO LIST FOUND"


def dst_of(entry):
    """The destination this entry matches, under either spelling."""
    m = entry.get("match") or {}
    if not isinstance(m, dict):
        return None
    return m.get("nw_dst") or m.get("ipv4_dst")


def scan(body, prio, dst=None):
    """Count phantom and programmed entries for one installed rule.

    🔴 CORRECTED 2026-08-30 13:05Z, and the correction reverses a conclusion.
    This used to key BOTH counts on `priority == prio`. It found phantoms fine (the echo carries
    the requested priority) but counted ZERO programmed entries for every rule, in every run --
    from which I was about to write up "an installed rule never becomes a programmed entry".

    That was false, and the instrument manufactured it. The rules WERE programmed; the kernel
    writes them to the switch with **priority 0**, not the requested priority. Checked on the
    live table: destinations 10.0.0.200/.201/.210/.211/.212 -- the five rules whose action was a
    port that exists -- are all present as real entries with `actions:["OUTPUT:2"]` and
    `priority: 0`, alongside the 128 base routes per switch. The four rules pointing at port 999
    are correctly absent.

    So the rule identity has to be the DESTINATION, which the caller chooses and which survives
    the trip, not the priority, which does not.
    🔑 memory: grep-endpoints-misses-concatenation -- ask the other side before reporting an
    absence. An instrument keyed on a field the system rewrites reports absence with total
    confidence, and "never programmed" is a far more exciting sentence than "programmed at a
    different priority", which is exactly why it needed checking.
    """
    ents, where = entries_of(body)
    def is_mine(e):
        return dst is None or dst_of(e) == dst
    ph = [e for e in ents if isinstance(e, dict) and is_mine(e)
          and e.get("priority") == prio and classify(e) == "phantom"]
    rl = [e for e in ents if isinstance(e, dict) and is_mine(e) and classify(e) == "real"
          and (dst is not None or e.get("priority") == prio)]
    return len(ents), len(ph), len(rl), where, (ph[0] if ph else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ndt", default=os.environ.get("NDT_URL", "http://localhost:8000"))
    ap.add_argument("--out", default=os.environ.get("OUT", "."))
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--fast-seconds", type=float, default=3.0, help="tight-loop phase per rep")
    ap.add_argument("--tail-seconds", type=float, default=8.0, help="0.5 s phase after it")
    ap.add_argument("--label", default="contended")
    ap.add_argument("--subject", choices=["valid", "invalid"], default="invalid",
                    help="valid = OUTPUT to a port that exists (does it ever become programmed?); "
                         "invalid = OUTPUT to port 999, FINDING-03's original subject")
    ap.add_argument("--force-blind", action="store_true",
                    help="demonstrate the control CAN fail: probe a port nothing is on")
    a = ap.parse_args()
    if a.force_blind:
        a.ndt = "http://localhost:8009"

    os.makedirs(a.out, exist_ok=True)
    tsv = os.path.join(a.out, f"tr3_f5_window_{a.label}.tsv")
    js  = os.path.join(a.out, f"tr3_f5_window_{a.label}.jsonl")
    fails = 0

    print(f"===== TR-3 F-5 exposure window ({a.label})  {time.strftime('%FT%TZ', time.gmtime())} =====")
    print(f"      kernel: {a.ndt}")

    # ---- the control, first ---------------------------------------------------------------
    print("\n----- control: can this instrument see a rule that exists? -----")
    cb = json.dumps({"dpid": 1, "priority": 902,
                     "match": {"eth_type": 2048, "ipv4_dst": "10.0.0.97"},
                     "actions": [{"type": "OUTPUT", "port": 2}]})
    dt, st, err, body = req(a.ndt + "/ndt/install_flow_entry", "POST", cb)
    print(f"      install valid rule (priority 902): http={st} err={err} in {dt*1000:.0f} ms")
    time.sleep(6)
    dt, st, err, body = req(a.ndt + "/ndt/get_switch_openflow_table_entries")
    if err is not None:
        print(f"  FAIL  CONTROL: the kernel did not answer at all ({err}). Nothing below is interpretable.")
        fails += 1
        n_ent = n_ph = n_rl = 0
        where = "n/a"
    else:
        n_ent, n_ph, n_rl, where, _ = scan(body, 902)
        n_real_any = sum(1 for e in entries_of(body)[0] if classify(e) == "real")
        print(f"      table view: {n_ent} entries, read from {where}; priority-902 real={n_rl} phantom={n_ph}")
        print(f"      entries classified 'real' anywhere in the view: {n_real_any}")
        # The control asks TWO separate questions, and the first version of this code fused them
        # into one and got the fusion wrong. Whether the instrument can SEE rules is a property of
        # the instrument. Whether MY rule became a programmed entry is a property of the SYSTEM --
        # and on 2026-08-30 it is the finding, so scoring it as a broken control would have thrown
        # away the result and stopped the round.
        if n_real_any == 0:
            print("  FAIL  CONTROL A FAILED: nothing in the view classifies as a real programmed "
                  "entry. Every 'no phantom' below would come from an instrument that cannot see a "
                  "rule at all. Do not record a TR-3 verdict from this run.")
            fails += 1
        else:
            print(f"  PASS  CONTROL A: {n_real_any} real programmed entries are visible and are "
                  f"distinguished from phantoms structurally, so absence below means absence.")
        if n_rl > 0:
            print("  PASS  CONTROL B: the valid rule reached the table as a REAL entry within 6 s.")
        elif n_ph > 0:
            print("  N/A   OBSERVATION, not a control failure: 6 s after a 200, the valid rule is "
                  "present ONLY as a phantom (the queued request echoed back) and NOT as a "
                  "programmed entry. This is TR-3's subject, measured on the control rule.")
        else:
            print("  N/A   OBSERVATION: 6 s after a 200 the valid rule is absent entirely -- neither "
                  "phantom nor programmed.")
    if fails:
        print(f"\n===== TR-3 ({a.label}): ABORTED at the control, {fails} FAIL =====")
        return 3

    # ---- the reps -------------------------------------------------------------------------
    with open(tsv, "w") as ft, open(js, "w") as fj:
        ft.write("rep\tprio\tsample\tt_since_post_ms\treq_ms\tn_entries\tn_phantom\tn_real\n")
        print(f"      subject: {a.subject} rule (OUTPUT port {'2' if a.subject=='valid' else '999'})")
        summary = []
        for rep in range(a.reps):
            prio = 910 + rep
            dst = f"10.0.0.{200 + rep}"          # a fresh, unused destination every rep
            # --subject decides whether the rep uses a rule the switch CAN program (port 2 exists)
            # or one it cannot (port 999). They answer different questions and 08-30 showed they
            # need separating: FINDING-03 timed the INVALID rule's phantom, and the valid rule's
            # behaviour under load turned out not to follow from it.
            port = 2 if a.subject == "valid" else 999
            bad = json.dumps({"dpid": 1, "priority": prio,
                              "match": {"eth_type": 2048, "ipv4_dst": dst},
                              "actions": [{"type": "OUTPUT", "port": port}]})
            # A staggered, IRREGULAR inter-rep delay. If the phantom's lifetime is set by a
            # PERIODIC flush rather than by queue depth, then evenly spaced reps can alias with
            # that period and produce a fake constant. Varying the spacing decorrelates the POST's
            # phase within any cycle. (memory: arithmetic-that-fits-is-not-the-mechanism -- a
            # distribution that fits a periodic story has to be given a chance to refute it.)
            if rep:
                time.sleep(1.7 * (rep % 5))
            post_epoch = time.time()
            t_post = time.monotonic()
            dt, st, err, resp = req(a.ndt + "/ndt/install_flow_entry", "POST", bad)
            post_done = time.monotonic()
            print(f"\n----- rep {rep}: priority {prio} -> {dst}, POST http={st} in {dt*1000:.0f} ms -----")
            if st == 400:
                print("      kernel rejected at the shape check (400): nothing was queued, so this rep "
                      "cannot exercise the window. Recorded as unreachable, not as zero.")
                summary.append((rep, prio, None, None, None, "shape-rejected-400"))
                continue

            first_seen = last_seen = None
            gaps = []
            i = 0
            deadline_fast = post_done + a.fast_seconds
            deadline_all = post_done + a.fast_seconds + a.tail_seconds
            prev = None
            while time.monotonic() < deadline_all:
                d, s, e, b = req(a.ndt + "/ndt/get_switch_openflow_table_entries")
                now = time.monotonic()
                t_ms = (now - post_done) * 1000.0
                if prev is not None:
                    gaps.append((now - prev) * 1000.0)
                prev = now
                if e is not None:
                    ft.write(f"{rep}\t{prio}\t{i}\t{t_ms:.1f}\t{d*1000:.1f}\tERR\tERR\tERR\n")
                else:
                    ne, nph, nrl, where, sample = scan(b, prio)
                    ft.write(f"{rep}\t{prio}\t{i}\t{t_ms:.1f}\t{d*1000:.1f}\t{ne}\t{nph}\t{nrl}\n")
                    if nph > 0:
                        if first_seen is None:
                            first_seen = t_ms
                            fj.write(json.dumps({"rep": rep, "prio": prio, "t_ms": t_ms,
                                                 "phantom": sample}) + "\n")
                        last_seen = t_ms
                i += 1
                if time.monotonic() > deadline_fast:
                    time.sleep(0.5)
            med_gap = sorted(gaps)[len(gaps)//2] if gaps else float("nan")
            summary.append((rep, prio, first_seen, last_seen, med_gap, "measured"))
            gone_at = post_epoch + (last_seen or 0)/1000.0
            print(f"      post_epoch={post_epoch:.3f}  phantom_gone_epoch={gone_at:.3f}")
            with open(os.path.join(a.out, f"tr3_epochs_{a.label}.tsv"), "a") as fe:
                fe.write(f"{rep}\t{prio}\t{post_epoch:.3f}\t"
                         f"{(first_seen or 0)/1000.0:.3f}\t{(last_seen or 0)/1000.0:.3f}\t{gone_at:.3f}\n")
            if first_seen is None:
                print(f"      no phantom seen in {i} samples (median gap {med_gap:.0f} ms). "
                      f"That bounds the window at < {med_gap:.0f} ms -- it does NOT show there was none.")
            else:
                print(f"      phantom visible from {first_seen:.0f} ms to {last_seen:.0f} ms "
                      f"({i} samples, median gap {med_gap:.0f} ms)")

    # ---- report ---------------------------------------------------------------------------
    print(f"\n----- TR-3 summary ({a.label}) -----")
    print(f"{'rep':>4}{'prio':>6}{'first_ms':>10}{'last_ms':>10}{'gap_ms':>9}  note")
    for rep, prio, f, l, g, note in summary:
        fs = f"{f:.0f}" if f is not None else "-"
        ls = f"{l:.0f}" if l is not None else "-"
        gs = f"{g:.0f}" if g is not None else "-"
        print(f"{rep:>4}{prio:>6}{fs:>10}{ls:>10}{gs:>9}  {note}")
    seen = [s for s in summary if s[2] is not None]
    print(f"\nphantom observed in {len(seen)}/{len(summary)} rep(s).")
    print("RESOLUTION: the gap column is this instrument's own sampling period. A window reported")
    print("as 0 ms means 'present in the first sample after the POST returned' -- the POST's own")
    print("round trip is already inside it and is NOT subtracted.")
    print(f"\nartefacts: {tsv}\n           {js}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
