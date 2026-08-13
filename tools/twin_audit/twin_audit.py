#!/usr/bin/env python3
"""
twin_audit.py -- the twin lie detector: for every flow the twin says is alive, go and check
whether packets are actually moving, and shout when they are not.

[Co-developed with claude code -- Adam]

The case it was built for
-------------------------
2026-08-13, overnight OVS round. `get_detected_flow_data` reported a flow "flowing at
9-15 Mbps"; `get_graph_data` reported edges_up 287/288. The flow had carried zero packets
for 291 seconds. Nothing in the stack noticed, because every dashboard number descends from
the same sFlow ingest: when the ingest keeps replaying a stale record, all of them agree,
confidently, and wrongly. This tool asks a question the twin cannot answer for itself.

Scope: connectivity reconciliation only
---------------------------------------
For each flow the twin advertises as active it verifies, independently, that traffic can
move between those two hosts (tools/twin_audit/criteria.py -- ping both ways, path count
both ways, peer counter growth). It does NOT reconcile rates or link utilisation, and that
is a deliberate decision rather than an omission: at 1/256 sFlow sampling the error floor
is 196*sqrt(1/c), so a "wrong" rate and an honestly-sampled one are not separable at the
counts this testbed produces. A numeric comparison there would emit alarms nobody can
action, and an alarm nobody can action trains people to ignore the alarm that matters.

Path reconciliation -- "are the packets moving along the path the twin claims" -- is the
intended next question. Its slot is reserved in criteria.py (RESERVED_CHECKS) and refuses
loudly rather than pretending; nothing here needs to change to adopt it.

Independent by construction
---------------------------
Not part of the kernel, not part of the proxy, not on any request path. Under a three-week
schedule, demo stability is worth more than architectural tidiness -- and a separate tool
works against BOTH data planes unchanged, which an in-kernel check reading OVS internals
would not.

Usage
-----
  twin_audit.py audit                    # every flow the twin calls active
  twin_audit.py audit --pair 10.0.0.1,10.0.0.2   # just this pair, twin claim assumed true
  twin_audit.py flows                    # what the twin currently claims, and how stale
  twin_audit.py hosts                    # the IP -> host -> PID map this tool resolved

Exit codes:
  0  no contradiction found
  1  at least one flow is LYING (twin says active, the network says still) or BLIND
  2  usage / could not reach the twin at all
  3  nothing could be decided (every pair inconclusive or disputed)

Seams -- everything that touches the world is a function or an environment variable. See
criteria.py's header for the shared ones; this file adds:

  NDT_URL                 kernel northbound API      (default: http://localhost:8000)
  TWIN_AUDIT_PS           process lister used to find Mininet host PIDs (default: ps)
  TWIN_AUDIT_STALE_S      staleness printed as a warning beside a claim (default: 30)
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import shlex
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_criteria():
    """criteria.py is a sibling file, not an installed package: tools/ is not importable
    and this tool must run from a checkout with no install step."""
    path = os.path.join(_HERE, "criteria.py")
    spec = importlib.util.spec_from_file_location("twin_audit_criteria", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


criteria = _load_criteria()

VERTEX_TYPE_HOST = 1


# --- reading the twin ---------------------------------------------------------------


def fetch_flows(cfg):
    """The twin's own list of detected flows, or None if it could not be read."""
    payload = criteria.http_get_json(cfg.ndt_url + "/ndt/get_detected_flow_data",
                                     cfg.timeout_s)
    if not isinstance(payload, list):
        return None
    return payload


def fetch_graph(cfg):
    payload = criteria.http_get_json(cfg.ndt_url + "/ndt/get_graph_data", cfg.timeout_s)
    if not isinstance(payload, dict):
        return None
    return payload


RATE_FIELD = "estimated_flow_sending_rate_bps_in_the_last_sec"


def twin_claims_active(flow):
    """The claim under audit: the twin says this flow is carrying traffic right now.

    A boolean reading of the rate field, never a comparison of its value -- see the scope
    note in the module docstring for why the numeric comparison is deliberately not done.
    """
    try:
        return float(flow.get(RATE_FIELD, 0)) > 0
    except (TypeError, ValueError):
        return False


def flow_age_s(flow, now_ts):
    """Seconds since the twin last sampled this flow, or None if unparseable.

    Reported as context, never as a vote: it is the twin's own bookkeeping, so it descends
    from the same ingest as the claim. It happens to be the single most damning number in
    the 2026-08-13 case (a 291 s old sample presented as a live 9-15 Mbps flow), which is
    why it is printed even though it cannot be trusted to decide anything.
    """
    stamp = flow.get("latest_sampled_time")
    if not isinstance(stamp, str):
        return None
    try:
        parsed = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return now_ts - parsed.timestamp()


def flow_pair(flow):
    """(src, dst) as dotted quads, or None if the record has no usable addresses."""
    try:
        return (criteria.ip_int_to_str(flow["src_ip"]),
                criteria.ip_int_to_str(flow["dst_ip"]))
    except (KeyError, TypeError, ValueError, OSError):
        return None


# --- resolving Mininet host PIDs ----------------------------------------------------


def list_host_pids(cfg):
    """{host name: pid} for every Mininet node, read from the process table.

    `$NF ~ /^mininet:/` is the same signal stack.sh's count_mininet_procs uses and the same
    one mnexec targets, so this agrees with the rest of the tooling by construction.
    Returns {} when nothing is running, which is not an error here -- a P4 testbed audited
    from inside a single namespace legitimately has no host PIDs.
    """
    result = criteria.run_command(shlex.split(cfg.ps) + ["-eo", "pid,args"], cfg.timeout_s)
    if result.rc is None or result.rc != 0:
        return {}
    hosts = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        tag = fields[-1]
        if not tag.startswith("mininet:"):
            continue
        name = tag[len("mininet:"):]
        try:
            hosts[name] = int(fields[0])
        except ValueError:
            continue
    return hosts


def ip_to_host_name(graph):
    """{dotted ip: device_name} for host vertices in get_graph_data.

    A node's `ip` is an array (a host has several), and its entries are the same
    network-byte-order integers as everywhere else in this API -- confirmed against
    VertexProperties::ip (std::vector<uint32_t>) and utils::ipToString, which assigns
    straight into in_addr::s_addr. String entries are accepted too: doc/2026-01-02_ndt_api.md
    describes this field as dotted text in one paragraph and shows integers in its own
    sample, so both are handled rather than guessed at.
    """
    mapping = {}
    for node in graph.get("nodes", []):
        if not isinstance(node, dict):
            continue
        if node.get("vertex_type") != VERTEX_TYPE_HOST:
            continue
        name = node.get("device_name")
        if not name:
            continue
        for entry in node.get("ip", []) or []:
            if isinstance(entry, str):
                mapping.setdefault(entry, name)
                continue
            try:
                mapping.setdefault(criteria.ip_int_to_str(entry), name)
            except (TypeError, ValueError, OSError):
                continue
    return mapping


def build_targets(pairs, ip_names, host_pids):
    """Turn (src_ip, dst_ip) pairs into criteria Targets, attaching host PIDs where the
    mapping resolved. An unresolved PID is not fatal: the probes then run in the caller's
    namespace, which is correct for a single-namespace testbed and honest for the rest --
    criteria.py reports UNKNOWN rather than inventing a verdict."""
    targets = []
    for src_ip, dst_ip in pairs:
        src_pid = host_pids.get(ip_names.get(src_ip))
        dst_pid = host_pids.get(ip_names.get(dst_ip))
        targets.append(criteria.Target(src_ip, dst_ip, src_pid, dst_pid))
    return targets


# --- the audit ----------------------------------------------------------------------


class Finding(object):
    def __init__(self, target, claim, verdict, reconciliation, observations, ages):
        self.target = target
        self.claim = claim
        self.verdict = verdict
        self.reconciliation = reconciliation
        self.observations = observations
        self.ages = ages

    @property
    def is_contradiction(self):
        return self.reconciliation in (criteria.LYING, criteria.BLIND)

    def as_dict(self):
        return {
            "pair": self.target.label,
            "twin_claims_active": self.claim,
            "verdict": self.verdict,
            "reconciliation": self.reconciliation,
            "twin_sample_age_s": self.ages,
            "observations": [o.as_dict() for o in self.observations],
        }


def distinct_pairs(flows):
    """Host pairs to audit, deduplicated and direction-normalised.

    The criteria are symmetric (every channel asks both ways), so auditing 10.0.0.1->
    10.0.0.2 and 10.0.0.2->10.0.0.1 separately would double the ping load for one answer.
    Bidirectional traffic produces exactly that pair of records.
    """
    seen = {}
    for flow in flows:
        pair = flow_pair(flow)
        if pair is None:
            continue
        key = tuple(sorted(pair))
        seen.setdefault(key, pair)
    return [seen[key] for key in sorted(seen)]


def audit(cfg, flows, ip_names, host_pids, only_pair=None, checks=None):
    now_ts = criteria.now()
    if only_pair is not None:
        pairs = [only_pair]
        claims = {tuple(sorted(only_pair)): True}
        ages = {tuple(sorted(only_pair)): []}
    else:
        active = [f for f in flows if twin_claims_active(f)]
        pairs = distinct_pairs(active)
        claims = {}
        ages = {}
        for flow in active:
            pair = flow_pair(flow)
            if pair is None:
                continue
            key = tuple(sorted(pair))
            claims[key] = True
            ages.setdefault(key, []).append(flow_age_s(flow, now_ts))

    findings = []
    for target in build_targets(pairs, ip_names, host_pids):
        key = tuple(sorted((target.src_ip, target.dst_ip)))
        claim = claims.get(key, False)
        verdict, observations = criteria.evaluate(cfg, target, checks)
        findings.append(Finding(target, claim, verdict,
                                criteria.reconcile(claim, verdict),
                                observations, ages.get(key, [])))
    return findings


# --- output -------------------------------------------------------------------------

_BANNER = {
    criteria.LYING: "LYING    twin advertises this flow as active; the network says still",
    criteria.BLIND: "BLIND    packets are moving and the twin does not know",
    criteria.DISPUTED: "DISPUTED the three channels disagree; one of them is broken",
    criteria.INCONCLUSIVE: "INCONCLUSIVE  not enough channels reported to decide",
    criteria.AGREES: "ok       twin and network agree",
}


def format_findings(findings):
    lines = []
    for finding in findings:
        lines.append("%s  %s" % (finding.target.label,
                                 _BANNER.get(finding.reconciliation,
                                             finding.reconciliation)))
        ages = [a for a in finding.ages if a is not None]
        if ages:
            lines.append("  twin's own newest sample for this pair: %.0fs old" % min(ages))
        for obs in finding.observations:
            lines.append("    %-9s %-8s %s" % (obs.check, obs.verdict, obs.detail))
    if not findings:
        lines.append("no flows to audit")
    contradictions = [f for f in findings if f.is_contradiction]
    lines.append("")
    lines.append("%d pair(s) audited, %d contradiction(s)"
                 % (len(findings), len(contradictions)))
    return "\n".join(lines)


def exit_code_for(findings):
    if any(f.is_contradiction for f in findings):
        return 1
    if findings and all(f.reconciliation in (criteria.DISPUTED, criteria.INCONCLUSIVE)
                        for f in findings):
        return 3
    return 0


# --- CLI ----------------------------------------------------------------------------


class AuditConfig(criteria.Config):
    """criteria.Config plus the two settings only this tool needs."""

    def __init__(self, ps="ps", stale_s=30.0, **kwargs):
        super().__init__(**kwargs)
        self.ps = ps
        self.stale_s = float(stale_s)

    @classmethod
    def from_env(cls):
        base = criteria.Config.from_env()
        return cls(ps=os.environ.get("TWIN_AUDIT_PS") or "ps",
                   stale_s=os.environ.get("TWIN_AUDIT_STALE_S") or 30.0,
                   ping=base.ping, mnexec=base.mnexec, cat=base.cat,
                   ndt_url=base.ndt_url, paths_url=base.paths_url,
                   ping_count=base.ping_count, gap_s=base.gap_s,
                   min_growth=base.min_growth, timeout_s=base.timeout_s)


def _parse_pair(text):
    parts = [p.strip() for p in text.split(",")]
    if len(parts) != 2 or not all(parts):
        raise ValueError("--pair wants SRC_IP,DST_IP")
    return (parts[0], parts[1])


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="twin_audit.py",
        description="Verify that the flows the twin calls active are really moving.")
    sub = parser.add_subparsers(dest="command")

    run = sub.add_parser("audit", help="reconcile the twin's active flows with reality")
    run.add_argument("--pair", default=None,
                     help="audit only SRC_IP,DST_IP (the twin claim is assumed true)")
    run.add_argument("--checks", default=None,
                     help="comma-separated subset of: " + ",".join(criteria.CHECKS))
    run.add_argument("--json", action="store_true")

    sub.add_parser("flows", help="print what the twin currently claims")
    sub.add_parser("hosts", help="print the resolved ip -> host -> pid map")

    args = parser.parse_args(argv)
    if args.command not in ("audit", "flows", "hosts"):
        parser.print_usage(sys.stderr)
        return 2

    cfg = AuditConfig.from_env()

    if args.command == "hosts":
        graph = fetch_graph(cfg)
        if graph is None:
            sys.stderr.write("could not read get_graph_data at %s\n" % cfg.ndt_url)
            return 2
        pids = list_host_pids(cfg)
        for ip, name in sorted(ip_to_host_name(graph).items()):
            sys.stdout.write("%-16s %-6s pid=%s\n" % (ip, name, pids.get(name, "-")))
        return 0

    flows = fetch_flows(cfg)
    if flows is None:
        sys.stderr.write("could not read get_detected_flow_data at %s\n" % cfg.ndt_url)
        return 2

    if args.command == "flows":
        now_ts = criteria.now()
        for flow in flows:
            pair = flow_pair(flow)
            age = flow_age_s(flow, now_ts)
            sys.stdout.write("%-34s active=%-5s age=%s\n" % (
                "%s -> %s" % pair if pair else "<unparseable>",
                twin_claims_active(flow),
                "?" if age is None else "%.0fs" % age))
        return 0

    only_pair = None
    if args.pair:
        try:
            only_pair = _parse_pair(args.pair)
        except ValueError as exc:
            sys.stderr.write("%s\n" % exc)
            return 2

    graph = fetch_graph(cfg)
    ip_names = ip_to_host_name(graph) if graph else {}
    host_pids = list_host_pids(cfg)

    names = None
    if args.checks:
        names = [n.strip() for n in args.checks.split(",") if n.strip()]

    try:
        findings = audit(cfg, flows, ip_names, host_pids, only_pair, names)
    except (KeyError, NotImplementedError) as exc:
        sys.stderr.write("%s\n" % exc)
        return 2

    if args.json:
        sys.stdout.write(json.dumps([f.as_dict() for f in findings], indent=2) + "\n")
    else:
        sys.stdout.write(format_findings(findings) + "\n")
    return exit_code_for(findings)


if __name__ == "__main__":
    sys.exit(main())
