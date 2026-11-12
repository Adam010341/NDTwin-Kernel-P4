#!/usr/bin/env python3
"""A small energy-saving app for a P4 fabric, written against the NDTwin kernel's HTTP API.

[Co-developed with claude code -- Adam]

It talks to the kernel only (port 8000), with the Python standard library, and expects a fabric
brought up with `ndt up p4 --app <tutorials exercise>` whose forwarding table is the package's
own (`owner=package`, the default). The defaults fit the tutorials' `basic` exercise
(`MyIngress.ipv4_lpm`, match `hdr.ipv4.dstAddr`, action parameters `port` and `dstAddr`).

One pass:
  1. take the kernel's advisory `routing_lock` (doc/2026-01-02_ndt_api.md §27, §29);
  2. read the topology (§3), the average link usage (§24) and the power report (§6);
  3. if the network is quiet, pick a switch with no host attached (even behind a link that is
     down), whose links are quiet and measured (telemetry "live" or "idle"), and without which
     every host still reaches every other host; of those, the one drawing the most power, and
     not one that a table's default entry sends packets to;
  4. on every other switch, read the forwarding table (§43) and plan to rewrite each entry whose
     egress port leads to that switch so it takes the shortest way around it, with the next
     hop's MAC address from another entry that uses that port; follow every pair of hosts, also
     one behind a link that is down, through the planned tables (route_walk.py, next to this
     file), and drop the switch when a packet would loop, be dropped or still pass it, or when a
     route cannot be planned; then try the next one. Each switch left on is logged with the
     reason;
  5. renew the lock (§28), write the entries and read the tables back (a table the API cannot
     show in full is not accepted);
  6. renew the lock again, power the switch off (§8) and read its power state (§7); a lock that
     cannot be renewed means no write, or no power-off;
  7. release the lock.

After --wake-after passes in a row with the average link usage above --wake-factor times
--max-avg-usage, a pass instead powers on the switch this run turned off last (after a failed
wake, the one before it) (§8), checks that its table is not empty and that every host still
reaches every other host once the routes are back, and moves them back. For --stay-on seconds
after it sends or tries a power-on, it turns nothing off.
Only a run with --every remembers, in memory, what it turned off, so only that run wakes it. The
policy is kept simple on purpose.

Run:  python3 examples/p4_energy_saving/energy_saving.py [--dry-run] [--every 30]
"""
import argparse
import ipaddress
import json
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque

from route_walk import first_broken_route


class KernelError(Exception):
    """A reply that was not a 2xx, or no reply at all (`status` None)."""

    def __init__(self, method, path, status, headers, body):
        self.method, self.path, self.status, self.headers, self.body = (
            method, path, status, headers, body)
        super().__init__(f"{method} {path} -> {status}: {json.dumps(body)[:400]}")

    @property
    def origin(self):
        """`kernel` or `proxy` on the /ndt/p4 routes (header X-NDTwin-Origin), else None."""
        return self.headers.get("X-NDTwin-Origin") if self.headers is not None else None

    def nothing_written(self):
        """True only when the reply says the request changed nothing on any switch."""
        if self.status is None:
            return False  # the connection broke: the request may or may not have arrived
        if self.origin == "kernel":
            if self.status in (502, 504):
                return isinstance(self.body, dict) and self.body.get("request_sent") is False
            return self.status in (404, 405, 501)
        if self.origin == "proxy":
            if self.status == 502:
                # The switch's own reason (`p4rt_error`) says it refused the entry. A 502 without
                # it (the proxy's 5 s deadline, an unavailable switch) may have landed.
                detail = self.body.get("detail") if isinstance(self.body, dict) else None
                return isinstance(detail, dict) and detail.get("p4rt_error") is not None
            return self.status in (400, 404, 409, 422, 501, 503)
        return 400 <= self.status < 500


class Kernel:
    """Plain HTTP to the kernel, JSON in and out."""

    def __init__(self, base_url, timeout=20.0, attempts=3, retry_wait=1.0):
        # 20 s: longer than the kernel's own 15 s deadline on the /ndt/p4/table_entry routes.
        self.base, self.timeout = base_url.rstrip("/"), timeout
        self.attempts, self.retry_wait = attempts, retry_wait

    def request(self, method, path, query=None, body=None):
        url = self.base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                try:
                    return json.loads(raw or b"null")
                except ValueError:  # a 2xx that is not JSON: an error, and a write may have landed
                    raise KernelError(method, path, resp.status, resp.headers,
                                      {"raw": raw.decode("utf-8", "replace")}) from None
        except urllib.error.HTTPError as err:
            raw = err.read()
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = {"raw": raw.decode("utf-8", "replace")}
            raise KernelError(method, path, err.code, err.headers, parsed) from None
        except (urllib.error.URLError, OSError) as err:
            raise KernelError(method, path, None, None, {"error": str(err)}) from None

    def call(self, method, path, query=None, body=None):
        """`request`, retried on a 502/503/504 when repeating it cannot write anything twice and may
        help: the proxy's 502 is its final answer, a write that may have landed is sent once, and
        a read the kernel timed out on after sending it is not sent again (the first one may
        still hold one of the proxy's read slots)."""
        for attempt in range(self.attempts):
            try:
                return self.request(method, path, query, body)
            except KernelError as err:
                if err.origin == "proxy":
                    again = err.status == 503
                elif err.origin == "kernel" and err.status == 504:
                    again = err.nothing_written()
                else:
                    again = method == "GET" or err.nothing_written()
                if err.status not in (502, 503, 504) or not again or attempt == self.attempts - 1:
                    raise
                time.sleep(self.retry_wait)


def ip_str(n):
    """The kernel serialises an IPv4 address as in_addr.s_addr, a little-endian read of its bytes."""
    return socket.inet_ntoa(int(n).to_bytes(4, "little"))


def read_topology(graph):
    """(switches {dpid: node}, hosts {ip: (dpid, port)}, links {dpid: {port: neighbour dpid}},
    busiest {dpid: highest utilisation % of a link touching it}, edge {dpid}, unmeasured
    {dpid: [link]}, attached {ip: (dpid, port)}), counting only what is on and up, except:
    `edge` holds every switch with a link to a host, up or down; `attached` every host with a
    link to a switch, up or down, whatever the switch's state; `unmeasured` the switches with a
    link to another switch whose telemetry is neither "live" nor "idle" ("silent": the switch's
    sFlow agent sent no sample within the window; "unknown": none ever), with those links. A 0 %
    there is an absence of samples, not a quiet link (§3)."""
    switches = {n["dpid"]: n for n in graph["nodes"]
                if n["vertex_type"] == 0 and n.get("admin_state") == "on" and n.get("reachable")}
    hosts, links, busiest, edge, unmeasured, attached = {}, {}, {}, set(), {}, {}
    for e in graph["edges"]:
        src, dst = e["src_dpid"], e["dst_dpid"]
        if bool(src) != bool(dst):
            edge.add(src or dst)  # a host hangs off it, even while that link is down
        if src and not dst:
            attached[ip_str(e["dst_ip"][0])] = (src, e["src_interface"])
        if not e.get("is_up") or (src and src not in switches) or (dst and dst not in switches):
            continue
        util = e.get("link_bandwidth_utilization_percent", 0.0)
        for dpid in (src, dst):
            if dpid:
                busiest[dpid] = max(busiest.get(dpid, 0.0), util)
        if src and dst:
            links.setdefault(src, {})[e["src_interface"]] = dst
            if e.get("telemetry_status") not in ("live", "idle"):
                for dpid in (src, dst):
                    unmeasured.setdefault(dpid, []).append(f"s{src}->s{dst} {e.get('telemetry_status')}")
        elif src:
            hosts[ip_str(e["dst_ip"][0])] = (src, e["src_interface"])
    return switches, hosts, links, busiest, edge, unmeasured, attached


def ports_toward(links, target, avoid):
    """{dpid: egress port} along a shortest path to switch `target` that never enters `avoid`."""
    port_of, queue = {target: None}, deque([target])
    while queue:
        here = queue.popleft()
        for dpid in sorted(links):
            if dpid == avoid or dpid in port_of:
                continue
            for port, nbr in sorted(links[dpid].items()):
                if nbr == here:
                    port_of[dpid] = port
                    queue.append(dpid)
                    break
    return port_of


def candidates(switches, hosts, links, busiest, edge, unmeasured, power, max_util, log=print):
    """(the switches that may be turned off, the one drawing the most power first; the switches
    kept on only because a link of theirs has no telemetry). A switch with a host is not listed;
    every other switch that is kept on is logged with the reason."""
    host_switches = {dpid for dpid, _port in hosts.values()}
    found, kept_blind = [], []
    for dpid in sorted(switches):
        if dpid in edge:
            continue
        if dpid in unmeasured:
            log(f"s{dpid} stays on: no telemetry on {', '.join(unmeasured[dpid])}")
            kept_blind.append(dpid)
        elif busiest.get(dpid, 0.0) > max_util:
            log(f"s{dpid} stays on: a link at {busiest[dpid]:.0f} % (--max-link-util {max_util:g})")
        elif host_switches and not host_switches <= ports_toward(links, min(host_switches), dpid).keys():
            log(f"s{dpid} stays on: without it some hosts could not reach each other")
        else:
            found.append(dpid)
    return sorted(found, key=lambda dpid: -power.get(dpid, 0)), kept_blind


def covers(match_value, ip):
    """Whether a destination match (`[value, prefix_len]` for lpm, the value for exact) holds `ip`."""
    if isinstance(match_value, list):
        return ipaddress.ip_address(ip) in ipaddress.ip_network(
            f"{match_value[0]}/{match_value[1]}", strict=False)
    return match_value == ip


def read_table(kernel, dpid, table):
    """(entries, default entry or None); RuntimeError if the API cannot show the table in full."""
    reply = kernel.call("GET", "/ndt/p4/table_entry", {"dpid": dpid, "table": table})
    if reply.get("unrendered"):
        raise RuntimeError(f"s{dpid} {table}: entries the API cannot show: {reply['unrendered']}")
    entries = [e for e in reply["entries"] if not e.get("default_action")]
    return entries, next((e for e in reply["entries"] if e.get("default_action")), None)


def plan_rewrites(kernel, args, switches, hosts, links, victim):
    """([(dpid, entry as read, entry to write)], {dpid: the table's entries after those writes})
    that move every route off `victim`, or a string that says why that cannot be done: a table's
    default entry sends packets to it (the default is not rewritten), or a destination has no
    single way around it. The next hop's MAC address comes from another entry of the switch that
    uses the new port; when there is none, the entry keeps the one it had (see `rewrite_line`)."""
    plans, tables = [], {}
    for dpid in sorted(switches):
        if dpid == victim:
            continue
        entries, default = read_table(kernel, dpid, args.table)
        if default and links.get(dpid, {}).get(default["action_params"].get(args.port_param)) == victim:
            return f"s{dpid}'s default entry sends packets to it"
        mac_via = {e["action_params"].get(args.port_param): e["action_params"].get(args.mac_param)
                   for e in entries}
        tables[dpid] = []
        for entry in entries:
            if links.get(dpid, {}).get(entry["action_params"].get(args.port_param)) != victim:
                tables[dpid].append(entry)
                continue
            dst = entry["match"].get(args.match_field)
            new_ports = {ports_toward(links, hosts[ip][0], victim).get(dpid)
                         for ip in hosts if dst is not None and covers(dst, ip)}
            if len(new_ports) != 1 or None in new_ports:
                return f"s{dpid}: no single way around it for {dst}"
            new = dict(entry, op="modify", action_params=dict(entry["action_params"]))
            new["action_params"][args.port_param] = port = new_ports.pop()
            if args.mac_param and mac_via.get(port) is not None:
                new["action_params"][args.mac_param] = mac_via[port]
            plans.append((dpid, entry, new))
            tables[dpid].append(new)
    return plans, tables


def apply_and_verify(kernel, args, plans, written):
    """Write every planned entry, then read each table back and compare. `written` collects the
    (dpid, entry) of each write that was answered."""
    for dpid, _old, new in plans:
        kernel.call("POST", "/ndt/p4/table_entry", body=new)
        written.append((dpid, new))
    for dpid in sorted({p[0] for p in plans}):
        on_switch, _default = read_table(kernel, dpid, args.table)
        for _, _old, new in (p for p in plans if p[0] == dpid):
            found = [e for e in on_switch
                     if e["match"] == new["match"] and e.get("priority") == new.get("priority")]
            if not found or found[0]["action_params"] != new["action_params"]:
                raise RuntimeError(f"s{dpid}: read back {found} after writing {new}")


def renew_lock(kernel, args, lock):
    kernel.call("POST", "/ndt/renew_lock", body={"type": "routing_lock", "ttl": args.lock_ttl,
                                                 "lease": lock["lease"]})


def rewrite_line(args, dpid, old, new):
    """The log line of one rewrite. It says so when the entry's MAC address did not change: no
    entry of the switch that uses the new port gives another one, so the packets may carry the
    address of the next hop they had (towards the switch being turned off), and the route check,
    which follows ports only, does not see it."""
    before, after = old["action_params"], new["action_params"]
    line = f"  s{dpid} {old['match']}: {before} -> {after}"
    if args.mac_param and args.mac_param in before and after.get(args.mac_param) == before[args.mac_param]:
        line += (f" ({args.mac_param} unchanged: no entry of s{dpid} that uses port "
                 f"{after.get(args.port_param)} gives another)")
    return line


def release_lock(kernel, lock):
    kernel.call("POST", "/ndt/release_lock", body={"type": "routing_lock", "lease": lock["lease"]})


def run_once(kernel, args, log=print, memory=None):
    """One pass. Returns {"switch", "rewrites", "powered_off", "powered_on", "reason"}.

    `memory` carries what one pass leaves the next: "asleep" {dpid: ([(dpid, entry as it was,
    entry as rewritten)], {dpid: {port: neighbour}} as the links were)} of the switches this app
    turned off, in that order; "busy", the passes in a row above the wake level; "woken" {dpid:
    when it was powered on}. The lock is released also when the pass fails, and then a failed
    release does not replace the pass's own error. When the release fails after the pass, the
    reason is logged before the release's error is raised, so what the pass did is not lost."""
    result = {"switch": None, "rewrites": [], "powered_off": False, "powered_on": False,
              "reason": ""}
    memory = {} if memory is None else memory
    for name, empty in (("asleep", {}), ("busy", 0), ("woken", {})):
        memory.setdefault(name, empty)
    lock = kernel.call("POST", "/ndt/acquire_lock", body={"type": "routing_lock", "ttl": args.lock_ttl})
    try:
        one_pass(kernel, args, lock, result, log, memory)
    except BaseException:
        try:
            release_lock(kernel, lock)
        except KernelError:
            pass  # the pass's own error is the one to report
        raise
    try:
        release_lock(kernel, lock)
    except KernelError:
        if result["reason"]:
            log(result["reason"])
        raise
    return result


def key(dpid, entry):
    return dpid, json.dumps(entry["match"], sort_keys=True), entry.get("priority")


def restored(kernel, args, plans, on):
    """{dpid: the table as it will be once `plans` are undone}, for the switches `on`; a switch
    that is off has no table, so a route through it reads as broken."""
    back = {key(d, old): old for d, old, _new in plans}
    return {dpid: [back.get(key(dpid, e), e) for e in read_table(kernel, dpid, args.table)[0]]
            for dpid in on}


def to_the_back(memory, dpid):
    """After a failed wake: the next wake tries the switch turned off before this one."""
    memory["asleep"] = {dpid: memory["asleep"].pop(dpid), **memory["asleep"]}


def wake(kernel, args, lock, result, memory, nodes, switches, attached):
    """Power on the switch this app turned off last, check its table is not empty and every route
    holds with its routes moved back, then move them back.
    [Co-developed with claude code -- Adam]"""
    asleep = memory["asleep"]
    dpid, (plans, links) = next(reversed(asleep.items()))  # undo in the reverse order
    result["switch"] = dpid
    if args.dry_run:
        result["reason"] = f"dry run: would power s{dpid} on and move {len(plans)} routes back"
        return
    memory["busy"] = 0
    if dpid not in nodes:
        del asleep[dpid]
        result["reason"] = f"s{dpid} is no longer in the topology: forgotten, its routes stay moved"
        return
    step = "power-on"
    try:
        renew_lock(kernel, args, lock)
        memory["woken"][dpid] = time.monotonic()  # before sending: one that errs may have landed
        if not nodes[dpid].get("ip"):
            raise RuntimeError(f"no switch {dpid} with a management address in the topology")
        ip = ip_str(nodes[dpid]["ip"][0])
        kernel.call("POST", "/ndt/set_switches_power_state", {"ip": ip, "action": "on"})
        state = kernel.call("GET", "/ndt/get_switches_power_state", {"ip": ip}).get(ip, {})
        result["powered_on"], step = state.get("admin_state") == "on", "check"
        # The pipeline is pushed again on power-on, and the package's entries go back on.
        held, _default = read_table(kernel, dpid, args.table)
        on = (set(switches) | {dpid}) & set(links)
        walked = {h: at for h, at in attached.items() if at[0] in on}
        broken = held and first_broken_route(restored(kernel, args, plans, on), links, walked,
                                             None, args.match_field, args.port_param)
        if not result["powered_on"] or not held or broken:
            result["reason"] = (f"s{dpid} reads {state} with {len(held)} entries"
                                f"{f', and {broken}' if broken else ''}: routes stay moved")
            return to_the_back(memory, dpid)
        renew_lock(kernel, args, lock)
        step = "routes moved back (some may be)"
        apply_and_verify(kernel, args, [(d, new, dict(old, op="modify")) for d, old, new in plans],
                         [])
    except (KernelError, RuntimeError) as err:
        result["reason"] = f"waking s{dpid} stopped at the {step}: {err}"
        return to_the_back(memory, dpid)
    del asleep[dpid]
    for _moved, saved in asleep.values():  # links saved while this switch was off now know it
        for d, ports in links.items():
            saved.setdefault(d, {}).update(ports)
    result["rewrites"] = [old for _, old, _ in plans]
    result["reason"] = (f"s{dpid} powered on with {len(held)} entries in {args.table}; "
                        f"{len(plans)} routes moved back onto it")


def one_pass(kernel, args, lock, result, log, memory):
    """The pass inside the lock; fills `result`."""
    graph = kernel.call("GET", "/ndt/get_graph_data")
    avg = kernel.call("GET", "/ndt/get_average_link_usage")["avg_link_usage"]  # 0..1
    power = {p["dpid"]: p["power_consumed"] for p in kernel.call("GET", "/ndt/get_power_report")}
    switches, hosts, links, busiest, edge, unmeasured, attached = read_topology(graph)
    log(f"average link usage {avg:.4f}")
    # The wake level sits above the power-off limit, and must be passed several times in a row:
    # the average is noisy and moves with the switches that are on (it counts only links with a
    # reading), so one reading against one limit would turn a switch off and on by turns.
    wake_level, asleep = args.wake_factor * args.max_avg_usage, memory["asleep"]
    memory["busy"] = memory["busy"] + 1 if avg > wake_level else 0
    if asleep and memory["busy"] >= args.wake_after:
        nodes = {n["dpid"]: n for n in graph["nodes"] if n["vertex_type"] == 0}
        return wake(kernel, args, lock, result, memory, nodes, switches, attached)
    if avg > args.max_avg_usage:
        result["reason"] = f"average link usage {avg:.4f} is above {args.max_avg_usage:g}" + (
            f"; a wake needs above {wake_level:.4f} on {args.wake_after} passes in a row "
            f"({memory['busy']} so far)" if asleep else "")
        return
    # Right after a power-on the average can read as low as on a quiet network.
    recent = [d for d, at in memory["woken"].items() if time.monotonic() - at < args.stay_on]
    if recent:
        latest = max(recent, key=memory["woken"].get)
        result["reason"] = (f"a power-on of s{latest} was sent or tried less than "
                            f"{args.stay_on:g} s ago (--stay-on): nothing is turned off")
        return
    # Every host of a usable switch, also behind a link that is down: its route must hold when
    # the link comes back. A switch that is off or unreachable has no table to follow.
    walked = {ip: at for ip, at in attached.items() if at[0] in switches}
    for dpid in sorted({at[0] for at in attached.values()} - set(switches)):
        log(f"s{dpid} has hosts and is off or unreachable: their routes are not checked")
    victim = plans = None
    found, blind = candidates(switches, hosts, links, busiest, edge, unmeasured, power,
                              args.max_link_util, log)
    for dpid in found:
        planned = plan_rewrites(kernel, args, switches, hosts, links, dpid)
        if isinstance(planned, str):
            log(f"s{dpid} stays on: {planned}")
            continue
        broken = first_broken_route(planned[1], links, walked, dpid, args.match_field,
                                    args.port_param)
        if broken:
            log(f"s{dpid} stays on: after the rewrites {broken}")
            continue
        victim, plans = dpid, planned[0]
        break
    if victim is None:
        result["reason"] = "no switch can be turned off"
        if blind:
            result["reason"] += (f"; {', '.join(f's{d}' for d in blind)} stayed on only because "
                                 f"their links have no telemetry samples: send traffic through "
                                 f"every switch, then run again")
        return
    result["switch"] = victim
    log(f"turning off s{victim} ({power.get(victim, 0) / 1000:.1f} W)")
    result["rewrites"] = [new for _, _, new in plans]
    for dpid, old, new in plans:
        log(rewrite_line(args, dpid, old, new))
    if args.dry_run:
        result["reason"] = "dry run"
        return
    try:
        renew_lock(kernel, args, lock)
    except KernelError as err:  # the reads may have taken a good part of the first ttl
        result["reason"] = (f"routing_lock could not be renewed, s{victim} left on, nothing "
                            f"written: {err}")
        return
    written = []
    try:
        apply_and_verify(kernel, args, plans, written)
    except (KernelError, RuntimeError) as err:
        # Every route still works while the switch stays on, rewritten or not.
        if len(written) == len(plans):  # the error is the read-back's
            result["reason"] = (f"every write was answered, the read-back does not confirm them "
                                f"(they may have landed), s{victim} left on: {err}")
            return
        landed = "may have landed" if not err.nothing_written() else "not on the switch"
        before = "".join(f"; s{dpid} {e['match']} was written before it" for dpid, e in written)
        result["reason"] = f"write failed ({landed}){before}, s{victim} left on: {err}"
        return
    time.sleep(args.settle)
    ip = ip_str(switches[victim]["ip"][0])
    try:
        renew_lock(kernel, args, lock)
    except KernelError as err:  # the pass may have outlived the first ttl
        result["reason"] = (f"routing_lock could not be renewed, s{victim} left on, routes "
                            f"already moved: {err}")
        return
    try:
        kernel.call("POST", "/ndt/set_switches_power_state", {"ip": ip, "action": "off"})
    except KernelError as err:
        # A 500 does not say whether the switch was touched: the power helper may have given
        # up waiting for a switch it had already signalled.
        took = "did not take effect" if err.nothing_written() else "may have taken effect"
        result["reason"] = f"power-off of s{victim} ({ip}) {took}, routes already moved: {err}"
        return
    state = kernel.call("GET", "/ndt/get_switches_power_state", {"ip": ip})
    result["powered_off"] = state.get(ip, {}).get("admin_state") == "off"
    if result["powered_off"]:
        # A switch woken in vain and turned off again keeps the routes it had first.
        moved, _ = memory["asleep"].setdefault(victim, ([], links))
        known = {key(d, old) for d, old, _new in moved}
        moved += [p for p in plans if key(p[0], p[1]) not in known]
    result["reason"] = f"s{victim} ({ip}) power state {state.get(ip)}"


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--kernel", default="http://localhost:8000")
    p.add_argument("--table", default="MyIngress.ipv4_lpm")
    p.add_argument("--match-field", default="hdr.ipv4.dstAddr")
    p.add_argument("--port-param", default="port")
    p.add_argument("--mac-param", default="dstAddr", help="'' if the action sets no MAC")
    p.add_argument("--max-avg-usage", type=float, default=0.4, help="fraction, 0..1 (§24)")
    p.add_argument("--max-link-util", type=float, default=40.0, help="percent, 0..100 (§3)")
    p.add_argument("--lock-ttl", type=int, default=60)
    p.add_argument("--settle", type=float, default=1.0, help="seconds between rewrite and power-off")
    p.add_argument("--every", type=float, default=0, help="repeat every N s (0: once; >= 15 s)")
    p.add_argument("--wake-factor", type=float, default=2.0,
                   help="wake above this times --max-avg-usage (> 1)")
    p.add_argument("--wake-after", type=int, default=3,
                   help="passes in a row above the wake level before a wake")
    p.add_argument("--stay-on", type=float, default=300.0,
                   help="seconds after a power-on is sent or tried in which nothing is turned off")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)
    if args.every != 0 and args.every < 15:
        p.error("--every is 0 (one pass) or 15 seconds or more")
    if args.wake_factor <= 1 or args.wake_after < 1 or args.stay_on < 0:
        p.error("--wake-factor is above 1, --wake-after 1 or more, --stay-on 0 or more")
    return args


def main(argv=None, kernel=None, log=print):
    args = parse_args(argv)
    kernel = kernel or Kernel(args.kernel)
    memory = {}
    while True:
        try:
            result = run_once(kernel, args, log, memory)
        except KernelError as err:
            if err.status == 423:
                log(f"routing_lock is held by another app: {err.body.get('detail')}")
                return 3
            log(f"error: {err}")
            return 1
        except (RuntimeError, ValueError) as err:
            log(f"error: {err}")  # ValueError: a match value that is not an IPv4 address or prefix
            return 1
        log(result["reason"])
        if args.every <= 0:
            return 0 if (result["powered_off"] or result["powered_on"] or not result["switch"]
                         or args.dry_run) else 1
        time.sleep(args.every)


if __name__ == "__main__":
    sys.exit(main())
