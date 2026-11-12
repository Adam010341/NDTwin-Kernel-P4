#!/usr/bin/env python3
"""The energy-saving app of energy_saving.py, written with the ndtwin Python SDK.

[Co-developed with claude code -- Adam]

Same policy, command-line options and exit codes as energy_saving.py, and the same rule for a
write that may have landed (it is sent once). The one difference in behaviour: the SDK also sends
again a request that could not connect and a read whose connection broke; energy_saving.py repeats
only a request answered 502, 503 or 504 where that is safe. The SDK (sdk/python,
`pip install -e sdk/python`) does the HTTP, the error handling, the address decoding, the table
read-back and the lock; what is left here is the policy, a shortest-path helper and the route
check of route_walk.py (shared with energy_saving.py). It talks to the kernel only (port 8000).

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
     one behind a link that is down, through the planned tables (route_walk.py), and drop the
     switch when a packet would loop, be dropped or still pass it, or when a route cannot be
     planned; then try the next one. Each switch left on is logged with the reason;
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
Only a run with --every remembers, in memory, what it turned off, so only that run wakes it.

Run:  python3 examples/p4_energy_saving/energy_saving_sdk.py [--dry-run] [--every 30]
"""
import argparse
import json
import sys
import time
from collections import deque

import ndtwin
import route_walk


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


def unmeasured(topo):
    """{dpid: ["s1->s3 silent", ...]}: the switches with a link to another switch whose telemetry
    is neither "live" nor "idle" (§3), and those links. "silent": the switch's sFlow agent sent no
    sample within the window; "unknown": none ever. A 0 % there is an absence of samples, not a
    quiet link."""
    found = {}
    for link in topo.links:
        if link.up and link.src and link.dst and link.telemetry_status not in ("live", "idle"):
            for dpid in (link.src, link.dst):
                found.setdefault(dpid, []).append(f"s{link.src}->s{link.dst} {link.telemetry_status}")
    return found


def candidates(topo, links, power, max_util, log=print):
    """(the switches that may be turned off, the one drawing the most power first; the switches
    kept on only because a link of theirs has no telemetry). A switch with a host is not listed;
    every other switch that is kept on is logged with the reason."""
    host_switches = {h.switch for h in topo.hosts.values()}
    blind = unmeasured(topo)
    found, kept_blind = [], []
    for sw in topo.switches.values():
        if not sw.usable or sw.dpid in topo.edge_switches:
            continue
        if sw.dpid in blind:
            log(f"s{sw.dpid} stays on: no telemetry on {', '.join(blind[sw.dpid])}")
            kept_blind.append(sw.dpid)
        elif topo.busiest(sw.dpid) > max_util:
            log(f"s{sw.dpid} stays on: a link at {topo.busiest(sw.dpid):.0f} % (--max-link-util "
                f"{max_util:g})")
        elif host_switches and not host_switches <= ports_toward(links, min(host_switches), sw.dpid).keys():
            log(f"s{sw.dpid} stays on: without it some hosts could not reach each other")
        else:
            found.append(sw.dpid)
    return sorted(found, key=lambda dpid: -power.get(dpid, 0)), kept_blind


def plan(k, a, topo, links, victim):
    """([(entry as read, entry to write)], {dpid: the table's entries after those writes}) that
    move every route off `victim`, or a string that says why that cannot be done: a table's
    default entry sends packets to it (the default is not rewritten), or a destination has no
    single way around it. The next hop's MAC address comes from another entry of the switch that
    uses the new port; when there is none, the entry keeps the one it had (see `rewrite_line`)."""
    changes, tables = [], {}
    for sw in topo.switches.values():
        if not sw.usable or sw.dpid == victim:
            continue
        table = k.p4.read_table(sw.dpid, a.table)  # NDTwinError if it is not fully shown
        entries = table.entries
        if table.default and topo.neighbour(sw.dpid, table.default.params.get(a.port_param)) == victim:
            return f"s{sw.dpid}'s default entry sends packets to it"
        mac_via = {e.params.get(a.port_param): e.params.get(a.mac_param) for e in entries}
        tables[sw.dpid] = []
        for entry in entries:
            if topo.neighbour(sw.dpid, entry.params.get(a.port_param)) != victim:
                tables[sw.dpid].append(entry)
                continue
            dst = entry.match.get(a.match_field)
            new_ports = {ports_toward(links, h.switch, victim).get(sw.dpid) for h in topo.hosts_in(dst)}
            if len(new_ports) != 1 or None in new_ports:
                return f"s{sw.dpid}: no single way around it for {dst}"
            new = {a.port_param: new_ports.pop()}
            if a.mac_param and mac_via.get(new[a.port_param]) is not None:
                new[a.mac_param] = mac_via[new[a.port_param]]
            changes.append((entry, entry.with_params(**new)))
            tables[sw.dpid].append(changes[-1][1])
    return changes, tables


def rewrite_line(a, old, new):
    """The log line of one rewrite. It says so when the entry's MAC address did not change: no
    entry of the switch that uses the new port gives another one, so the packets may carry the
    address of the next hop they had (towards the switch being turned off), and the route check,
    which follows ports only, does not see it."""
    line = f"  s{old.dpid} {old.match}: {old.params} -> {new.params}"
    if a.mac_param and a.mac_param in old.params and (
            new.params.get(a.mac_param) == old.params[a.mac_param]):
        line += (f" ({a.mac_param} unchanged: no entry of s{old.dpid} that uses port "
                 f"{new.params.get(a.port_param)} gives another)")
    return line


def run_once(k, a, log=print, memory=None):
    """One pass. Returns {"switch", "rewrites", "powered_off", "powered_on", "reason"}.

    `memory` carries what one pass leaves the next: "asleep" {dpid: ([(entry as it was, entry
    as rewritten)], {dpid: {port: neighbour}} as the links were)} of the switches this app turned
    off, in that order; "busy", the passes in a row above the wake level; "woken" {dpid: when it
    was powered on}. When the lock's release fails after the pass, the reason is logged before
    the error is raised, so what the pass did is not lost."""
    result = {"switch": None, "rewrites": [], "powered_off": False, "powered_on": False,
              "reason": ""}
    memory = {} if memory is None else memory
    for name, empty in (("asleep", {}), ("busy", 0), ("woken", {})):
        memory.setdefault(name, empty)
    try:
        with k.lock("routing_lock", ttl=a.lock_ttl) as lease:
            one_pass(k, a, lease, result, log, memory)
    except ndtwin.NDTwinError:
        if result["reason"]:
            log(result["reason"])
        raise
    return result


def key(entry):
    return entry.dpid, json.dumps(entry.match, sort_keys=True), entry.priority


def restored(k, a, moves, on):
    """{dpid: the table as it will be once `moves` are undone}, for the switches `on`; a switch
    that is off has no table, so a route through it reads as broken."""
    back = {key(old): old for old, _new in moves}
    return {dpid: [back.get(key(e), e) for e in k.p4.read_table(dpid, a.table).entries]
            for dpid in on}


def to_the_back(memory, dpid):
    """After a failed wake: the next wake tries the switch turned off before this one."""
    memory["asleep"] = {dpid: memory["asleep"].pop(dpid), **memory["asleep"]}


def wake(k, a, lease, result, memory, topo):
    """Power on the switch this app turned off last, check its table is not empty and every route
    holds with its routes moved back, then move them back.
    [Co-developed with claude code -- Adam]"""
    asleep = memory["asleep"]
    dpid, (moves, links) = next(reversed(asleep.items()))  # undo in the reverse order
    result["switch"] = dpid
    if a.dry_run:
        result["reason"] = f"dry run: would power s{dpid} on and move {len(moves)} routes back"
        return
    memory["busy"] = 0
    if dpid not in topo.switches:
        del asleep[dpid]
        result["reason"] = f"s{dpid} is no longer in the topology: forgotten, its routes stay moved"
        return
    step = "power-on"
    try:
        lease.renew(a.lock_ttl)
        memory["woken"][dpid] = time.monotonic()  # before sending: one that errs may have landed
        k.power_on(dpid)  # PowerError unless the state reads "on"
        result["powered_on"], step = True, "check"
        # The pipeline is pushed again on power-on, and the package's entries go back on.
        held = k.p4.read_table(dpid, a.table).entries
        on = ({sw.dpid for sw in topo.switches.values() if sw.usable} | {dpid}) & set(links)
        hosts = {h.ip: (h.switch, h.port) for h in topo.attached_hosts.values() if h.switch in on}
        broken = held and route_walk.first_broken_route(
            restored(k, a, moves, on), links, hosts, None, a.match_field, a.port_param)
        if not held or broken:
            result["reason"] = (f"s{dpid} is on, but {broken or f'its {a.table} is empty'}"
                                f": routes stay moved")
            return to_the_back(memory, dpid)
        lease.renew(a.lock_ttl)
        step = "routes moved back (some may be)"
        k.p4.modify_all([old for old, _new in moves], verify=True)
    except ndtwin.NDTwinError as err:
        result["reason"] = f"waking s{dpid} stopped at the {step}: {err}"
        return to_the_back(memory, dpid)
    del asleep[dpid]
    for _moved, saved in asleep.values():  # links saved while this switch was off now know it
        for d, ports in links.items():
            saved.setdefault(d, {}).update(ports)
    result["rewrites"] = [old for old, _new in moves]
    result["reason"] = (f"s{dpid} powered on with {len(held)} entries in {a.table}; "
                        f"{len(moves)} routes moved back onto it")


def one_pass(k, a, lease, result, log, memory):
    """The pass inside the lock; fills `result`."""
    topo, avg, power = k.topology(), k.average_link_usage(), k.power_report()
    log(f"average link usage {avg:.4f}")
    # The wake level sits above the power-off limit, and must be passed several times in a row:
    # the average is noisy and moves with the switches that are on (it counts only links with a
    # reading), so one reading against one limit would turn a switch off and on by turns.
    wake_level, asleep = a.wake_factor * a.max_avg_usage, memory["asleep"]
    memory["busy"] = memory["busy"] + 1 if avg > wake_level else 0
    if asleep and memory["busy"] >= a.wake_after:
        return wake(k, a, lease, result, memory, topo)
    if avg > a.max_avg_usage:
        result["reason"] = f"average link usage {avg:.4f} is above {a.max_avg_usage:g}" + (
            f"; a wake needs above {wake_level:.4f} on {a.wake_after} passes in a row "
            f"({memory['busy']} so far)" if asleep else "")
        return
    # Right after a power-on the average can read as low as on a quiet network.
    recent = [d for d, at in memory["woken"].items() if time.monotonic() - at < a.stay_on]
    if recent:
        latest = max(recent, key=memory["woken"].get)
        result["reason"] = (f"a power-on of s{latest} was sent or tried less than "
                            f"{a.stay_on:g} s ago (--stay-on): nothing is turned off")
        return
    links = {sw.dpid: topo.neighbours(sw.dpid) for sw in topo.switches.values() if sw.usable}
    # Every host of a usable switch, also behind a link that is down: its route must hold when
    # the link comes back. A switch that is off or unreachable has no table to follow.
    hosts = {h.ip: (h.switch, h.port) for h in topo.attached_hosts.values()
             if topo.switches[h.switch].usable}
    for dpid in sorted({h.switch for h in topo.attached_hosts.values()} - set(links)):
        log(f"s{dpid} has hosts and is off or unreachable: their routes are not checked")
    victim = changes = None
    found, blind = candidates(topo, links, power, a.max_link_util, log)
    for dpid in found:
        planned = plan(k, a, topo, links, dpid)
        if isinstance(planned, str):
            log(f"s{dpid} stays on: {planned}")
            continue
        broken = route_walk.first_broken_route(planned[1], links, hosts, dpid, a.match_field,
                                               a.port_param)
        if broken:
            log(f"s{dpid} stays on: after the rewrites {broken}")
            continue
        victim, changes = dpid, planned[0]
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
    result["rewrites"] = [new for _, new in changes]
    for old, new in changes:
        log(rewrite_line(a, old, new))
    if a.dry_run:
        result["reason"] = "dry run"
        return
    try:
        lease.renew(a.lock_ttl)  # the reads may have taken a good part of the first ttl
    except ndtwin.NDTwinError as err:
        result["reason"] = (f"routing_lock could not be renewed, s{victim} left on, nothing "
                            f"written: {err}")
        return
    try:
        k.p4.modify_all(result["rewrites"], verify=True)
    except ndtwin.WriteNotVerified as err:
        # modify_all raises it only after every write was answered.
        result["reason"] = (f"every write was answered, the read-back does not confirm them "
                            f"(they may have landed), s{victim} left on: {err}")
        return
    except ndtwin.NDTwinError as err:
        # Any error of a write: also a KernelUnreachable after the retries and a reply that is not
        # JSON, which `ndtwin.WriteError` does not hold. modify_all sets `written` on each of them.
        # Every route still works while the switch stays on, rewritten or not.
        # [Co-developed with claude code -- Adam]
        landed = "may have landed" if err.may_have_landed else "not on the switch"
        before = "".join(f"; s{e.dpid} {e.match} was written before it" for e in err.written)
        result["reason"] = f"write failed ({landed}){before}, s{victim} left on: {err}"
        return
    time.sleep(a.settle)
    ip = topo.switches[victim].mgmt_ip
    try:
        lease.renew(a.lock_ttl)  # the pass may have outlived the first ttl
    except ndtwin.NDTwinError as err:
        result["reason"] = (f"routing_lock could not be renewed, s{victim} left on, routes "
                            f"already moved: {err}")
        return
    try:
        state = k.power_off(victim)
    except ndtwin.NDTwinError as err:
        took = "may have taken effect" if err.may_have_landed else "did not take effect"
        result["reason"] = f"power-off of s{victim} ({ip}) {took}, routes already moved: {err}"
        return
    result["powered_off"] = True
    # A switch woken in vain and turned off again keeps the routes it had first.
    moved, _ = asleep.setdefault(victim, ([], links))
    known = {key(old) for old, _new in moved}
    moved += [c for c in changes if key(c[0]) not in known]
    result["reason"] = f"s{victim} ({ip}) power state {state}"


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
    a = p.parse_args(argv)
    if a.every != 0 and a.every < 15:
        p.error("--every is 0 (one pass) or 15 seconds or more")
    if a.wake_factor <= 1 or a.wake_after < 1 or a.stay_on < 0:
        p.error("--wake-factor is above 1, --wake-after 1 or more, --stay-on 0 or more")
    return a


def main(argv=None, kernel=None, log=print):
    a = parse_args(argv)
    kernel = kernel or ndtwin.Kernel(a.kernel)
    memory = {}
    while True:
        try:
            result = run_once(kernel, a, log, memory)
        except ndtwin.LockBusy as err:
            log(f"routing_lock is held by another app, free in about {err.retry_after_s} s")
            return 3
        except (ndtwin.NDTwinError, RuntimeError, ValueError) as err:
            log(f"error: {err}")  # ValueError: a match value that is not an IPv4 address or prefix
            return 1
        log(result["reason"])
        if a.every <= 0:
            return 0 if (result["powered_off"] or result["powered_on"] or not result["switch"]
                         or a.dry_run) else 1
        time.sleep(a.every)


if __name__ == "__main__":
    sys.exit(main())
