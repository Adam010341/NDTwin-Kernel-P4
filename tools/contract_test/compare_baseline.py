#!/usr/bin/env python3
"""
L4: compare a P4 run against an OVS baseline.

The technique that makes P4 development tractable: the OVS path is known-good, so use
its behaviour as the specification instead of inventing one for P4.

Naive JSON diffing does not work here -- the two topologies genuinely differ (128 hosts
vs 4), and rates/counters/timestamps change every second. So we compare two things that
*should* be identical regardless of data plane:

  1. shape    -- the recursive set of "field path -> type". Catches a missing field, a
                 field whose type changed, and (crucially) a list that is empty on one
                 side but populated on the other, which is how the P4 stubs present.

  2. facts    -- per-endpoint behavioural booleans: are all switches up? are flow paths
                 populated? are rates non-zero? are tables non-empty? These are the
                 questions whose answers must match even when the numbers do not.

Anything the two runs disagree on is either an accepted P4 limitation (put it in
baseline_diff_allowlist.txt with a reason) or a bug. There is no third category, which
is the point: every P4 shortfall ends up written down.

Usage
-----
  # capture the known-good side once
  ./run_contract_test.py --topology <ovs topo> --with-traffic --save-json baseline/ovs

  # capture P4 the same way, then compare
  ./run_contract_test.py --topology <p4 topo>  --with-traffic --save-json result/p4
  ./compare_baseline.py baseline/ovs result/p4

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from run_contract_test import Palette, supports_colour  # noqa: E402

# Values that legitimately differ run to run; compared only for type, never for value.
VOLATILE = re.compile(
    r"(_time|_bps|_percent|_count|_usage|duration_|cookie|power_consumed"
    r"|utilization|rate|left_link)", re.IGNORECASE)


def shape(data, path="", out=None) -> dict[str, str]:
    """
    Recursive field-path -> type signature. List indices collapse to [] so a 4-host and
    a 128-host topology produce the same signature.

    An empty list yields '<empty list>', which is what makes the P4 stubs visible: OVS
    reports 'list of object' where P4 reports '<empty list>'.
    """
    if out is None:
        out = {}

    if isinstance(data, dict):
        for k, v in data.items():
            shape(v, f"{path}.{k}" if path else k, out)
    elif isinstance(data, list):
        key = f"{path}[]"
        if not data:
            out[key] = "<empty list>"
        else:
            # Union of element shapes; heterogeneous lists surface as multiple entries.
            for item in data:
                shape(item, key, out)
    else:
        t = "bool" if isinstance(data, bool) else type(data).__name__
        t = {"str": "str", "int": "int", "float": "float", "NoneType": "null"}.get(t, t)
        prev = out.get(path)
        if prev and prev != t:
            # int/float mixing is normal for rates; record the widened type.
            out[path] = "number" if {prev, t} <= {"int", "float", "number"} else f"{prev}|{t}"
        else:
            out[path] = prev or t
    return out


# --- behavioural fact extractors --------------------------------------------------
# Each returns {fact_name: value}. Values must be comparable across data planes, so
# they are booleans or ratios-as-categories, never raw magnitudes.

def _cat(n: int) -> str:
    return "none" if n == 0 else "some"


def facts_graph_data(d):
    nodes = d.get("nodes", [])
    edges = d.get("edges", [])
    sw = [n for n in nodes if n.get("vertex_type") == 0]
    return {
        "has_switches": bool(sw),
        "all_switches_up": all(n.get("is_up") for n in sw) if sw else False,
        "all_switches_enabled": all(n.get("is_enabled") for n in sw) if sw else False,
        "has_edges": bool(edges),
        "all_edges_up": all(e.get("is_up") for e in edges) if edges else False,
        "any_edge_has_flow_set": any(e.get("flow_set") for e in edges),
        "any_link_usage_nonzero": any(
            (e.get("link_bandwidth_usage_bps") or 0) > 0 for e in edges),
    }


def facts_flow_data(d):
    return {
        "flows_detected": _cat(len(d)),
        "all_paths_populated": all(f.get("path") for f in d) if d else False,
        "any_rate_nonzero": any(
            (f.get("estimated_flow_sending_rate_bps_in_the_last_sec") or 0) > 0 for f in d),
        "any_packet_rate_nonzero": any(
            (f.get("estimated_packet_rate_in_the_last_sec") or 0) > 0 for f in d),
    }


def _flow_entry_count(entry):
    """
    How many flow entries one switch object reports, whichever shape `flows` has.

    [Co-developed with claude code -- Adam]
    The kernel documents `flows` as a map of table id -> entries, which is what OVS mode
    returns. The P4 proxy's stubbed /stats/flow/<dpid> returns a bare list instead, and this
    used to call .values() unconditionally: comparing an OVS baseline against a P4 one died
    with "AttributeError: 'list' object has no attribute 'values'" and reported nothing at
    all for this endpoint. A comparison tool that crashes on the difference it exists to
    find is worse than one that counts it, so both shapes are accepted here -- the shape
    mismatch itself is still reported by the [shape] checks.
    """
    flows = entry.get("flows")
    if isinstance(flows, dict):
        return sum(len(v) for v in flows.values())
    if isinstance(flows, list):
        return len(flows)
    return 0


def facts_of_tables(d):
    # [Co-developed with claude code -- Adam]
    # Only a list of switch objects is meaningful here. The earlier fix handled `flows` being a
    # list instead of a map but still assumed the top level was a list, so an error payload --
    # the kernel answers {"status":"error", ...} on several endpoints -- crashed with
    # "'str' object has no attribute 'get'" (iterating a dict yields its keys), and a null body
    # crashed on len(). A comparison tool must report the difference, not die on it.
    if not isinstance(d, list):
        return {
            "switches_reporting": _cat(0),
            "entries_present": _cat(0),
            "all_switches_have_entries": False,
        }
    entries = [_flow_entry_count(e) for e in d if isinstance(e, dict)]
    return {
        "switches_reporting": _cat(len(d)),
        "entries_present": _cat(sum(entries)),
        "all_switches_have_entries": all(n > 0 for n in entries) if entries else False,
    }


def facts_avg_link_usage(d):
    return {"avg_link_usage_nonzero": (d.get("avg_link_usage") or 0) > 0}


def facts_power_report(d):
    return {"switches_reporting": _cat(len(d)),
            "any_nonzero": any((e.get("power_consumed") or 0) > 0 for e in d)}


def facts_util_map(d):
    return {"switches_reporting": _cat(len(d) if isinstance(d, dict) else 0)}


def facts_power_state(d):
    vals = set(d.values()) if isinstance(d, dict) else set()
    return {"switches_reporting": _cat(len(d) if isinstance(d, dict) else 0),
            "values_are_on_off": vals <= {"ON", "OFF"} if vals else False}


FACT_EXTRACTORS = {
    "get_graph_data": facts_graph_data,
    "get_detected_flow_data": facts_flow_data,
    "get_detected_top_k_flow_data": facts_flow_data,
    "get_switch_openflow_table_entries": facts_of_tables,
    "get_average_link_usage": facts_avg_link_usage,
    "get_power_report": facts_power_report,
    "get_cpu_utilization": facts_util_map,
    "get_memory_utilization": facts_util_map,
    "get_switches_power_state": facts_power_state,
}


class AllowRule:
    def __init__(self, endpoint, pattern, reason, lineno):
        self.endpoint = endpoint
        self.pattern_src = pattern
        self.regex = re.compile(pattern)
        self.reason = reason
        self.lineno = lineno
        self.hits = 0

    def matches(self, endpoint, detail) -> bool:
        if self.endpoint not in ("*", endpoint):
            return False
        return bool(self.regex.search(detail))


# Field separator: a pipe surrounded by whitespace. Splitting on a bare "|" would break
# every regex that uses alternation, so inside a pattern write it without spaces --
# (int|float) is a regex, " | " is a separator.
FIELD_SEP = re.compile(r"\s+\|\s+")


def load_allowlist(path) -> list[AllowRule]:
    if not os.path.exists(path):
        return []
    rules = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in FIELD_SEP.split(line)]
            if len(parts) < 3:
                raise SystemExit(
                    f"{path}:{lineno}: expected 'endpoint | regex | reason'"
                    f" (fields separated by a pipe with spaces around it), got: {line}")
            try:
                rules.append(AllowRule(parts[0], parts[1], " | ".join(parts[2:]), lineno))
            except re.error as exc:
                raise SystemExit(f"{path}:{lineno}: invalid regex {parts[1]!r}: {exc}")
    return rules


def load_dir(path) -> dict[str, object]:
    if not os.path.isdir(path):
        raise SystemExit(f"not a directory: {path}")
    out = {}
    for fn in sorted(os.listdir(path)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(path, fn), encoding="utf-8") as fh:
            try:
                out[fn[:-5]] = json.load(fh)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{os.path.join(path, fn)}: invalid JSON: {exc}")
    if not out:
        raise SystemExit(f"no .json files in {path} -- did you run with --save-json?")
    return out


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="L4 OVS-baseline vs P4 differential")
    ap.add_argument("baseline", help="directory of known-good responses (usually OVS)")
    ap.add_argument("candidate", help="directory of responses under test (usually P4)")
    ap.add_argument("--allowlist", default=os.path.join(here, "baseline_diff_allowlist.txt"))
    ap.add_argument("--baseline-name", default="OVS")
    ap.add_argument("--candidate-name", default="P4")
    ap.add_argument("--ignore-volatile", action="store_true", default=True,
                    help="compare volatile fields by type only (default)")
    ap.add_argument("--strict-volatile", dest="ignore_volatile", action="store_false",
                    help="also compare volatile field values (rarely useful)")
    args = ap.parse_args()

    pal = Palette(supports_colour())
    base = load_dir(args.baseline)
    cand = load_dir(args.candidate)
    rules = load_allowlist(args.allowlist)

    A, B = args.baseline_name, args.candidate_name
    print(f"L4 differential: {B} against a {A} baseline")
    print(f"  {A:<9}: {args.baseline} ({len(base)} endpoint responses)")
    print(f"  {B:<9}: {args.candidate} ({len(cand)} endpoint responses)")
    print(f"  allowlist: {len(rules)} accepted difference(s)\n")

    problems = []      # (endpoint, kind, detail)
    accepted = []      # (endpoint, detail, reason)

    def note(endpoint, kind, detail):
        rule = next((r for r in rules if r.matches(endpoint, detail)), None)
        if rule:
            rule.hits += 1
            accepted.append((endpoint, detail, rule.reason))
        else:
            problems.append((endpoint, kind, detail))

    only_base = sorted(set(base) - set(cand))
    only_cand = sorted(set(cand) - set(base))
    for ep in only_base:
        note(ep, "coverage", f"present in {A} but missing from {B}")
    for ep in only_cand:
        note(ep, "coverage", f"present in {B} but missing from {A}")

    for ep in sorted(set(base) & set(cand)):
        sb, sc = shape(base[ep]), shape(cand[ep])

        empty_b = {k for k, v in sb.items() if v == "<empty list>"}
        empty_c = {k for k, v in sc.items() if v == "<empty list>"}

        def covered_by_empty(field: str, empties: set[str]) -> bool:
            """
            True when this field's absence is already explained by an empty list above it.

            An empty list on one side would otherwise produce one 'field missing' line per
            field of the other side's element type -- 20 lines of noise for a single fact.
            """
            return any(field.startswith(e) for e in empties)

        # Report each emptiness mismatch once, as its own finding. "[]" is the whole
        # response body being a list, which reads better spelled out.
        def label(key: str) -> str:
            return "<root list>" if key == "[]" else key

        for key in sorted(empty_c):
            populated_in_base = any(k.startswith(key + ".") for k in sb) or \
                                any(k.startswith(key + "[") for k in sb)
            if populated_in_base:
                note(ep, "empty",
                     f"list is empty in {B} but populated in {A}: {label(key)}")
        for key in sorted(empty_b):
            populated_in_cand = any(k.startswith(key + ".") for k in sc) or \
                                any(k.startswith(key + "[") for k in sc)
            if populated_in_cand:
                note(ep, "empty",
                     f"list is empty in {A} but populated in {B}: {label(key)}")

        for field in sorted(set(sb) - set(sc)):
            if covered_by_empty(field, empty_c):
                continue
            note(ep, "shape", f"field missing in {B}: {field} (is {sb[field]} in {A})")
        for field in sorted(set(sc) - set(sb)):
            if covered_by_empty(field, empty_b) or field in empty_c:
                continue
            note(ep, "shape", f"extra field in {B}: {field} ({sc[field]})")
        for field in sorted(set(sb) & set(sc)):
            if sb[field] == sc[field]:
                continue
            if args.ignore_volatile and VOLATILE.search(field) \
                    and {sb[field], sc[field]} <= {"int", "float", "number"}:
                continue    # int vs float on a rate is not a contract change
            note(ep, "shape",
                 f"type differs at {field}: {A}={sb[field]} {B}={sc[field]}")

        extractor = FACT_EXTRACTORS.get(ep)
        if extractor:
            try:
                fb, fc = extractor(base[ep]), extractor(cand[ep])
            except Exception as exc:
                note(ep, "facts", f"fact extraction failed: {type(exc).__name__}: {exc}")
            else:
                for k in sorted(set(fb) | set(fc)):
                    if fb.get(k) != fc.get(k):
                        note(ep, "behaviour",
                             f"{k}: {A}={fb.get(k)!r} {B}={fc.get(k)!r}")

    if accepted:
        print(f"{pal.yellow('ACCEPTED DIFFERENCES')} ({len(accepted)})")
        for ep, detail, reason in accepted:
            print(f"  {ep}: {detail}")
            print(f"      {pal.dim('accepted: ' + reason)}")
        print()

    if problems:
        print(f"{pal.red('UNEXPECTED DIFFERENCES')} ({len(problems)})")
        by_ep: dict[str, list] = {}
        for ep, kind, detail in problems:
            by_ep.setdefault(ep, []).append((kind, detail))
        for ep, items in by_ep.items():
            print(f"\n  {pal.red(ep)}")
            for kind, detail in items:
                print(f"      [{kind}] {detail}")

    stale = [r for r in rules if r.hits == 0]
    if stale:
        print(f"\n{pal.yellow('UNUSED ALLOWLIST ENTRIES')} "
              f"(the difference they permit did not occur -- possibly now fixed)")
        for r in stale:
            print(f"  {os.path.basename(args.allowlist)}:{r.lineno}  "
                  f"{r.endpoint} | {r.pattern_src}")

    print(f"\n{'=' * 70}")
    if problems:
        print(pal.red(f"FAIL: {len(problems)} unexpected difference(s) between "
                      f"{A} and {B}"))
        print(pal.dim(f"each one is either a bug, or an accepted {B} limitation that "
                      f"belongs in {os.path.basename(args.allowlist)} with a reason"))
        return 1
    print(pal.green(f"PASS: {B} matches the {A} baseline "
                    f"(plus {len(accepted)} accepted difference(s))"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
