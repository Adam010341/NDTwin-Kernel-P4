# ndtwin: a Python client for the NDTwin kernel

[Co-developed with claude code -- Adam]

`ndtwin` wraps the kernel's HTTP API (port 8000, `doc/2026-01-02_ndt_api.md`) for an app written in
Python. It uses only the standard library, needs Python 3.10 or newer, and is synchronous. It calls
the kernel's `/ndt/...` routes and nothing else: an app does not talk to the P4 proxy on port 8081.

To run an app against it, nothing needs installing: from the checkout, `ndt python` runs `python3`
with this directory first on Python's path, so the app imports the SDK of the kernel this checkout
built, and takes the same arguments `python3` does:

```bash
tools/test_workflow/ndt python my_app.py
```

Its exit code is the app's. It refuses a `python3` older than 3.10 and runs nothing (exit 5).
`python3 -I` or `-E` would ignore the path, so do not pass them.

For an editor or a debugger that needs to import the SDK too, install it into a virtual
environment (Ubuntu 24.04's system Python is externally managed, so
`pip install` refuses to run outside one), from the root of the repository; it needs `setuptools`
64 or newer, which `pip` fetches for the build:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -e sdk/python
```

On a machine without network access, build with the `setuptools` that is already installed
instead of fetching one: let the virtual environment see the system's packages, and turn off
`pip`'s isolated build environment:

```bash
python3 -m venv --system-site-packages .venv
. .venv/bin/activate
pip install --no-index --no-build-isolation -e sdk/python
```

This needs `setuptools` 64 or newer in the virtual environment or in the system Python. Up to
Python 3.11 the virtual environment gets its own `setuptools`, the one the Python installation
carries; from 3.12 on it gets `pip` alone and uses the system's, such as Ubuntu's
`python3-setuptools`. Inside the activated environment, this prints the version:
`python3 -c 'import setuptools; print(setuptools.__version__)'`.

The SDK is plain Python with no dependencies, so where that `setuptools` is older than 64, or
missing, or the build fails, skip installing it and point Python at it instead, from the root of
the repository:

```bash
export PYTHONPATH="$PWD/sdk/python"
```

```python
import ndtwin

k = ndtwin.Kernel("http://localhost:8000")          # timeout=20.0, retries=2, retry_wait=1.0
with k.lock("routing_lock", ttl=60) as lease:       # LockBusy if another app holds it
    changed = k.move_routes_off(4, "MyIngress.ipv4_lpm")   # NoDetour, and nothing written, if it cannot
    for e in changed:
        print(f"s{e.dpid}", e.match, "now leaves on port", e.params["port"])
    lease.renew(60)                                 # before a step that must still hold the lock
    print("s4:", k.power_off(4))                    # by dpid; raises PowerError unless it reads "off"
    # ... later, when the traffic is back:
    k.power_on(4)                                   # raises PowerError unless it reads "on"
```

This is for the tutorials' `basic` exercise (pod topology: h1, h2 on s1; h3, h4 on s2; s3 and s4
each joined to s1 and s2). `move_routes_off` finds every entry of the table that leaves towards
s4, moves it to a port whose neighbour still reaches its destination without s4, checks that
every host still reaches every other host through the tables as they will be, writes the entries
and reads the tables back: here, s1's route to h4 and s2's route to h2 go over s3. See "Moving
the routes off a switch" for the rules and the names it assumes.

## Moving the routes off a switch

Every app that turns a switch off, or steers traffic away from one, first sends the routes that
leave towards that switch out of another port. Two calls do it for one forwarding table:

| call | what it does |
|---|---|
| `k.plan_routes_off(dpid, table, *, port_param="port", mac_param=None, match_field="hdr.ipv4.dstAddr", topo=None)` | reads the topology (unless you pass `topo`) and the table of every switch that is on and reachable, and returns the entries to send as modifies, a `RoutePlan`; writes nothing (this is the dry run) |
| `k.move_routes_off(dpid, table, *, port_param="port", mac_param=None, match_field="hdr.ipv4.dstAddr", topo=None, verify=True)` | the same, then `k.p4.modify_all(plan, verify=verify)`; returns the entries as read back |

The names after `*` are keyword-only. A `RoutePlan` is a list of the new entries; its `old` holds
each of them as it was read, in the same order, so `k.p4.modify_all(plan.old)` moves the routes
back. The caller holds the lock, from before the plan to after the write: the plan is only as
good as the tables it read.

The kernel does not say which action parameter is the egress port, so the call assumes the names
of the tutorials' `basic` exercise and of NDTwin's own pipeline: `port_param` is the action
parameter that holds the egress port and `match_field` the match field that holds the destination
address (the names the energy example's `--port-param`, `--mac-param` and `--match-field` take).
Name yours when they differ. `mac_param` names the parameter that holds the next hop's MAC
address: given, the moved entry takes the address that the switch's other entries leaving on the
new port carry, and an entry whose action has parameters but not that one is refused (a misspelt
name is an error, not ignored); left out, the entry keeps the address it had, which is harmless on
a pipeline that forwards on the IPv4 address alone (like `basic`) and wrong on one that checks the
destination MAC address.

How it decides:

- An entry leaves towards the switch when its `port_param` leads there over a link that is up.
- Its new port is one whose neighbour reaches the switches of every host its destination holds
  without passing the switch being avoided and without coming back through this one: of those,
  the fewest hops in all, then the lowest port. The neighbour is not simply "any other one": on a
  fabric where a neighbour reaches the destination only back through this switch, that would loop.
- Then it follows the packets from every switch with a host (also one behind a link that is down)
  to every host that is not on the avoided switch, through the tables as they will be. Moving only
  the entries next to the switch can loop on some fabrics, when a switch further back still sends
  packets towards it; the plan is refused then.

It refuses rather than guesses, raising `ndtwin.NoDetour` (an `NDTwinError`, `nothing_written`
True, nothing sent) whose message names the switch and the entry (`err.entry`), or the way the
packets would take (`err.switches`, the switches in order; `err.path` keeps its meaning on every
`NDTwinError`, the HTTP route, and is `None` here), when:

| case | why |
|---|---|
| the switch is off or unreachable | `topo.links` still lists its links, but `topo.neighbours()` leaves out those of a switch that is not usable, and the call reads neighbours of switches that are on; so it cannot tell which entries lead to a switch that has already failed |
| a destination holds a host on the switch itself | no route reaches that host without the switch |
| a destination holds a host on the entry's own switch | the entry would send packets away from a host that hangs off this very switch |
| no other port reaches the destination | there is no way around |
| after the moves some host does not reach another (a loop, a drop) | the message says when no moved entry is on that way: the route is broken already |
| after the moves a packet needs a default entry whose action has parameters (a port, or a next-hop id the check cannot read), or an entry that matches every address (an lpm `0/0` entry reads back without the match field), to be forwarded | the check does not follow those; the message says "not followed" and does not say broken: the packets may well be delivered |
| a default entry sends packets to the switch | default entries are not moved |
| an entry's action has parameters but not `port_param` (or not `mac_param`, when that is named); an entry has a priority; an entry's match has a key besides `match_field` (an ingress port, a VRF, an exact metadata key); a destination is not an IPv4 address or prefix, matches every address, or holds no host the topology knows | it cannot tell where those packets go, or which entry the switch applies |
| with `mac_param`, no other entry leaving on the new port gives an address, or two disagree | it would have to invent one |

A table the API cannot show in full (entries it cannot render) is not a `NoDetour`: the read
raises its own `NDTwinError` (`nothing_written` True) as `k.p4.read_table` does, and the plan stops
there.

It works on one table: a pipeline that forwards through several tables is not followed. It reads
switches that are on and reachable only; a switch that is off has no table to read. An unknown
`dpid` raises `NotFound`.

If a write of `move_routes_off` fails (a refused entry, a read-back that does not show an entry,
Ctrl-C between two writes), the exception is raised as it is, with the plan on it as `err.plan`.
After a refused write `err.written` lists the entries that landed; after a failed read-back every
entry was sent. To move the routes back, send the old entries: `k.p4.modify_all(err.plan.old)`
(an entry that never changed is sent as it was, which changes nothing).

Writes to a table that NDTwin owns are refused with `409`, and `plan_routes_off` still works
there: it only reads, so an app can show the plan or hand it to the owner. Which tables belong to
NDTwin depends on the fabric:

- On NDTwin's own pipeline (`ndt up p4` without `--app`) every table does. The topology says so
  (`capabilities` `ipv4_route` is `"ndtwin"` and `binding_source` is `"baseline"`), so
  `move_routes_off` makes the plan, then refuses before the first write, for a switch the plan
  would write, with a `NoDetour` that names the switch and says its tables belong to NDTwin. A
  switch the plan does not write does not count, and an unknown or powered-off `dpid` gets its
  own `NotFound` or off-or-unreachable refusal first.
- A package started with `--table-owner ndtwin` shows `ipv4_route` `"ndtwin"` in the capabilities
  too (with `binding_source` `"package"`), but only its route-role table belongs to NDTwin: the
  first write to that table gets `409` and `move_routes_off` raises `Refused`, nothing written.
  The package's other tables are writable.
- A table a package leaves to an external control plane is not told by the topology either: the
  first write finds out.

So catch both `NoDetour` and `Refused` when an app may meet either, or test `nothing_written`.

## What it offers

| call | route |
|---|---|
| `k.topology()` | `GET /ndt/get_graph_data` (§3): `switches`, `hosts`, `attached_hosts`, `links`, `edge_switches`; see "The topology" |
| `k.average_link_usage()` | `GET /ndt/get_average_link_usage` (§24), a 0..1 fraction (a `float`) with `.telemetry_health` |
| `k.power_report()` | `GET /ndt/get_power_report` (§6), `{dpid: mW}` |
| `k.power_state(dpid)`, `k.power_off(dpid)`, `k.power_on(dpid)` | `GET`/`POST /ndt/(get\|set)_switches_power_state` (§7, §8): see "What powering a P4 switch needs" and "Powering a switch back on" |
| `k.plan_routes_off(dpid, table)`, `k.move_routes_off(dpid, table)` | `GET /ndt/get_graph_data`, `GET /ndt/p4/table_entry` of each switch, and for `move_routes_off` `POST /ndt/p4/table_entry`: see "Moving the routes off a switch" |
| `k.lock(name, ttl)`, `lease.renew(ttl)` | `POST /ndt/acquire_lock`, `/ndt/renew_lock`, `/ndt/release_lock` (§27, §28, §29) |
| `k.p4.read_table(dpid, table)` | `GET /ndt/p4/table_entry` (§43) |
| `k.p4.write(entry, op, table_size=None)`, `k.p4.modify(entry)`, `k.p4.modify_all(entries)` | `POST /ndt/p4/table_entry` (§43); `table_size`: see "A full table" |
| `k.p4.settle(entry, op, budget_s=60.0, wait_s=None)` | `POST`, then one `GET /ndt/p4/table_entry`: see "Settling a write whose outcome is unknown" |
| `k.p4.counter(name, dpid, index=0)` | `GET /ndt/p4/counter/{name}` (§43, §3) |
| `k.p4.direct_counter(name, dpid)` | `GET /ndt/p4/direct_counter/{name}` |
| `k.p4.register(name, dpid, index=None, start=None, count=None)` | `GET /ndt/p4/register/{name}` (bmv2 only) |
| `k.of.write(entry, op="install", *, wait_s=10.0, all_rules=False)` | `POST /ndt/install_flow_entry`, `/ndt/modify_flow_entry` or `/ndt/delete_flow_entry` (§9, §10, §11), then `GET /ndt/get_flow_dispatch_status?request_id=` (§42) until the kernel's record of the write is complete: see "OVS flow entries" |
| `k.of.dispatch_status(request_id)` | `GET /ndt/get_flow_dispatch_status?request_id=` (§42), the record as the kernel gives it |
| `with k.link_down(link) as cut:` | `GET /ndt/get_graph_data`, then `POST /ndt/inject_link_failure` (§2b) on entry and `POST /ndt/inject_link_recovery` (§2c) when the block ends, also when it raises: see "Cutting a link" |
| `k.restore_link(link)` | `GET /ndt/get_graph_data`, then `POST /ndt/inject_link_recovery` (§2c), for a cut no block ended: see "Cutting a link" |

The power API takes a switch's management address, not its dpid. The SDK maps the dpid to the
address from the topology (the kernel serialises the address as a little-endian integer, which the
SDK decodes). A table entry is a `dict` in the exact JSON shape of the API, with `.dpid`,
`.match`, `.params`, `.priority` and `with_params(**changes)`; values the API gives go back
unchanged.

`verify=True` reads each table back after the writes, as strictly as `read_table`: a table with
entries the API cannot show raises `WriteNotVerified`, and the check compares values in the form
the GET returns them. A MAC address in upper case, or a number where the API gives a `"0x..."`
string, lands on the switch and still fails the check; send values back in the GET's form.

The counter and register reads return the proxy's reply as plain objects; they are sent again on
the same rule as any read. Not covered: path finding beyond moving routes off one switch
(`examples/p4_energy_saving/energy_saving_sdk.py` does the same job with its own planner, under a
different policy: it keeps the old MAC address and says so where `move_routes_off` with
`mac_param` refuses, and it refuses a prefix whose hosts need different ports where
`move_routes_off` picks the one port that reaches them all), and reading a table's declared size
(the kernel does not serve it for every table: pass it, see "A full table").

A complete app on this SDK, which turns a switch off when the network is quiet and on again when
the traffic returns, with a route check, is described in
[examples/p4_energy_saving/README.md](../../examples/p4_energy_saving/README.md).

## The topology

`k.topology()` returns a `Topology` (`ndtwin/topology.py`). Its fields: `switches`
(`{dpid: Switch}`), `hosts` (`{ip: Host}`, the hosts behind a usable switch through a link that is
up), `attached_hosts` (every host with a link to a switch, up or not), `links` (a list of `Link`,
one per direction; a host end has dpid 0) and `edge_switches` (the set of dpids with a link to a
host, up or down). "Usable" means on and reachable. To map ports to switches:

| method | returns |
|---|---|
| `topo.neighbours(dpid)` | `{port: neighbouring switch dpid}`, over links that are up between usable switches |
| `topo.neighbour(dpid, port)` | the switch on the other side of `dpid`'s `port`, or `None` (a host, a link that is down) |
| `topo.busiest(dpid)` | the highest utilisation (percent, 0..100) of a link that touches `dpid` and is up between usable ends; `0.0` if none |
| `topo.hosts_in(match_value)` | the `Host`s of `hosts` a destination match holds: `[value, prefix_len]` (lpm) or the value (exact) |
| `Switch.usable` (a property) | `True` when the switch's `admin_state` is `"on"` and it is reachable |

A `Switch` also has `dpid`, `name`, `mgmt_ip`, `admin_state`, `reachable` and `brand`; a `Host` has
`name`, `ip`, `mac`, `switch` and `port` (the switch's port towards it); a `Link` has `src`,
`src_port`, `dst`, `dst_port`, `up`, `utilization_percent`, `usage_bps`, `bandwidth_bps`,
`telemetry_status` and `down_reason` (`"declared"` while the twin holds the link down because it
was told to, `"switch-unreachable"`, `"none"`; `None` from a kernel that does not send it).

## What powering a P4 switch needs

On a P4 (bmv2) fabric, `k.power_off(dpid)` and `k.power_on(dpid)` work only on a machine where the
root helper `/usr/local/sbin/ndtwin-p4-power` is installed and the account that runs the kernel
(under `ndt up`, the one that ran it) may run it through `sudo` without a password. Nothing installs
either: the install command and the grant line are under "P4 power control" in section 3.2 of this
repository's user guide (`doc/2026-11-05_user-guide.md`). Without them the kernel answers `500`
and the call raises `PowerError`, with `nothing_written` `None`. In that case the switch is not
touched, but the same `500` also comes back when the helper signalled the switch and it had not
stopped 10 s later, so the SDK cannot tell the two apart: read the state back, and read the line
above the kernel's `command failed` line in its log (section 3.2 says what each one means). On an
OVS fabric the kernel uses `ovs-vsctl` and `ifconfig` instead (the same section).

## Powering a switch back on

`k.power_on(dpid)` is the twin of `k.power_off(dpid)`: it sends `action=on`, reads the state back,
and returns it (`admin_state` "on"), or raises the same errors. A switch the twin knows to be on
already, and has not been told to power off, is left alone and reported on.

On a P4 (bmv2) switch the kernel answers only after it has started the switch's bmv2 again and
the P4 proxy has re-adopted it, so the switch runs its pipeline when `power_on` returns. The
pipeline is pushed afresh, which empties every table; then:

| what was in the switch's tables | after `power_on` |
|---|---|
| an app package's own entries (`ndt up p4 --app`) | put back before `power_on` returns |
| what your app wrote with `k.p4.write`, `modify`, `modify_all` on such a fabric | put back from the P4 proxy's table-entry journal (on by default), before `power_on` returns |
| NDTwin's routes, on NDTwin's own pipeline (`ndt up p4` without `--app`) | put back by the re-adoption while the P4 proxy still has paths through the switch, before `power_on` returns; otherwise by NDTwin's link watchdog once the switch's links are seen again, after `power_on` has returned (on a fabric where no link watchdog runs, nothing puts them back). Do not write them yourself |
| what your app wrote with `k.p4.write` and the like | on NDTwin's own pipeline there is nothing to put back: the proxy refuses those writes (`409` "owned by NDTwin", a `Refused`), and an app's routes there go through `/ndt/install_flow_entry` (next row) |
| rules installed with `/ndt/install_flow_entry` | gone; the switch's node in `get_graph_data` carries a `ryu_rules_lost` record of them (KNOWN-ISSUES A-4c) |

All rows were seen on bmv2 1.15.5 on 2026-11-11 UTC. The first two, with the tutorials' `basic`
exercise: four power-ons answered in 1.24 to 1.27 s on the kernel's side, with the package's
entries back and, each of the three times it was checked, an entry written through `k.p4.write`
before the power-off. The last three, on NDTwin's own pipeline (`ndt up p4 4`): two power-ons
answered in 1.25 s. After 12 s off all four of the switch's routes were back when `power_on`
returned, but the switch's links were declared down 0.4 s later and back 5.0 s after that, and
in between NDTwin rerouted around the switch; after 90 s off none of its routes were there at the
return, and all four were back about 2 s later. A rule installed with `/ndt/install_flow_entry`
was gone both times, with `ryu_rules_lost` counting and listing it.

So after a power-on, read the switch's tables (`k.p4.read_table`) and send again what your app
wrote and does not find; NDTwin's own routes are not yours to send, and may arrive a few seconds
after `power_on` returns. A `PowerError` from `power_on` can also mean that bmv2 runs again but
its re-adoption did not finish, so it may not forward; sending the power-on again does not retry
the re-adoption (the kernel log names the step and the recovery). The kernel gives the
re-adoption up to 30 s, more than the client's default `timeout` of 20 s, so a slow one raises
`OutcomeUnknown` and the switch may still come up. `examples/p4_energy_saving/energy_saving_sdk.py`
wakes the switch it turned off when the traffic comes back, checks that its table is not empty and
that every route holds with its routes moved back, and moves them back.

## A full table

bmv2 refuses an insert into a full table with `p4rt_error` `UNKNOWN` "Error when adding match
entry to target", not P4Runtime's `RESOURCE_EXHAUSTED`. The text names no cause, so the code alone
does not say the table is full. `k.p4.write(entry, "insert", table_size=N)`, with N the `size`
your P4 program declares for the table (a positive integer), checks: after an `UNKNOWN` it reads
the table once and raises `ndtwin.TableFull` (a `SwitchRefused`, with `entries` and `size`) when
the table holds N entries or more, counting the entries the API cannot show and leaving out the
default entry. Without `table_size`, or when the table holds fewer, or the read fails, it raises
`SwitchRefused` and says why in `note`. An insert answered `RESOURCE_EXHAUSTED` raises `TableFull`
without the read, `table_size` or not (P4Runtime's meaning; not observed on bmv2). The read
happens after the refusal, so another writer may have changed the table in between.

On bmv2 a table holds as many entries as it declares, and its default entry does not count:
on bmv2 1.15.5 (2026-11-05, and again 2026-11-11 UTC) an exact-match table declared `size = 16`
that held one entry of the app package took 15 more, 16 in all, and refused the 17th. There
`table_size=16` gave `TableFull` with `entries` 16, no `table_size` gave `SwitchRefused` with its
`note`, and `table_size=1024` a note that the table was not full. A duplicate of an entry that is
there still gets `ALREADY_EXISTS`, full or not.

## Errors, and whether a write may have landed

Every exception is an `NDTwinError` with `method`, `path`, `status`, `origin` (`"kernel"`, `"proxy"`
or `None`), `body`, `lab_claim` (the reply's `X-NDTwin-Lab-Claim`, parsed) and `nothing_written`:
`True` when nothing was changed on any switch (no request went out, or the reply says so), `None`
when that is unknown. `may_have_landed` is `nothing_written is not True`. An error of
`modify_all` also has `written`: the entries answered before the write that failed; one of
`move_routes_off` also has `plan`, the `RoutePlan` it was writing.

| exception | when | `nothing_written` | sent again by the SDK |
|---|---|---|---|
| `KernelUnreachable` | no connection to the kernel | `True` | yes |
| `Busy` | the proxy answered 503, or the kernel's 502/504 says the request was not sent | `True` | yes |
| `Refused` (`NotFound`, `LockBusy`) | a 4xx | `True` | no |
| `SwitchRefused` | the proxy's 502 that carries the switch's own reason (`p4rt_error`): the switch refused the entry | `True` | no |
| `TableFull` (a `SwitchRefused`) | an insert refused while the table is full, as far as the evidence shows: see "A full table" | `True` | no |
| `OutcomeUnknown` | a write: the kernel's 502/504 with `request_sent` true, a 500 on `/ndt/p4`, a proxy 502 without `p4rt_error` (its own deadline, an unavailable switch: `grpc_status` says which), any other proxy 5xx except 501 and 503, a connection that broke after the request went out | `None` | never |
| `Unsettled` (an `OutcomeUnknown`) | `k.p4.settle` could not tell: its budget ran out, or the re-sent write was refused in a way that does not say; `last` is that error, `attempts` the writes it sent | `None` | no |
| `WriteNotVerified` | a write was answered and the table read back does not show it, shows entries the API cannot render, or could not be read | `None` | no |
| `NoDetour` | `plan_routes_off` or `move_routes_off` will not move the routes, or `move_routes_off` finds a switch it would write on NDTwin's own pipeline (the tables belong to NDTwin; a package's `--table-owner ndtwin` table arrives as `Refused` instead, so catch both or test `nothing_written`): see "Moving the routes off a switch" | `True` | no |
| `PowerError` | the power command failed, or the state read afterwards is not the one commanded | `None`: the kernel's 500 is the same whether the switch was touched or not (a bmv2 switch may have been signalled and still be stopping) | no |
| `LinkNotRestored` | the recovery of a cut link failed, was refused, has an outcome the SDK cannot know, or did not clear a netem: the link may still be cut; `still_cut`, `tc` and `remedy` say where and how to restore it: see "Cutting a link" | `None` from `link_down`; from `restore_link`, `True` when the recovery changed nothing, else `None` | no |
| `NDTwinError` | any other case: a proxy 502 on a read, a kernel 504 on a read that was sent, a 501, a reply that is not JSON, a broken connection on a read | `True` for a read, `None` for a write | reads only |

A read is sent again after a broken connection, a kernel 502, a kernel 504 that says the request
was not sent, or a proxy 503, since it cannot write. It is not sent again after the proxy's 502,
which is a final answer, nor after a kernel 504 that says the request was sent: the first read may
still be holding one of the proxy's read slots. After `OutcomeUnknown` the write may still land
later (§43), and a table read straight away does not settle it; `k.p4.settle` does (below).

Catch `ndtwin.NDTwinError` around a write and read `err.may_have_landed`: that covers every case
above, `KernelUnreachable` included. `ndtwin.WriteError` is the tuple of the classes a write
reports once something answered or the request went out (not `KernelUnreachable`, and not a bare
`NDTwinError`); use it to tell them from the rest, not to be sure that nothing escapes.

A lease that ran out cannot be renewed (`Refused`, status 412) and the lock is then no longer held;
releasing it afterwards answers 412 too. The SDK demo renews it right before its writes and right
before the power-off, and does neither when that fails. After Ctrl-C the `with` block releases the
lock with one try, without the retries.

## Settling a write whose outcome is unknown

After a write raised `OutcomeUnknown` (the kernel's 504 with `request_sent: true`, the proxy's 502
without `p4rt_error`, ...), the write may still land later, at a time nobody can bound (§43). The
SDK never sends such a write again by itself. An app that must know asks for it:

```python
try:
    k.p4.write(entry, "insert")
except ndtwin.OutcomeUnknown:
    settled = k.p4.settle(entry, "insert", budget_s=60)   # raises ndtwin.Unsettled if still unknown
    print(settled.original_landed, settled.entry)
```

`settle` does what an app would do by hand:

1. wait `wait_s` seconds (the client's `retry_wait` by default), then send the identical write
   again (same entry, same `op`);
2. read the switch's answer in `p4rt_error.code`: after an insert, `ALREADY_EXISTS` means the
   entry is there, which an earlier copy did; after a delete, `NOT_FOUND` means the entry is gone,
   which an earlier copy did unless the entry never existed or another writer deleted it; a `200`
   means the write sent again was applied, so no earlier copy had landed by then; a modify is
   simply applied again, and so is an insert of a default entry, which the proxy sends as a
   modify;
3. read the table once, with no retry, and check that the entry is there as sent (or gone, after a
   delete).

While the answer says nothing about the switch (`Busy`, `KernelUnreachable`, `OutcomeUnknown`
again) it goes back to step 1. It sends at least one write, and starts no further one once
`budget_s` seconds have passed since it was called, the time spent waiting for answers included.
So it takes at most `max(budget_s, wait_s)` seconds plus one write and the one read. The client's
`timeout` applies to each socket operation (connecting, sending, each wait for data), not to a
whole request, so a request can take longer than `timeout`. Negative, infinite or NaN values of
`budget_s` and `wait_s` are refused, as `Kernel` refuses such a `retry_wait`.

It returns a `Settled`: `entry` as read back (None after a delete), `attempts`, and
`original_landed`: True (after an insert, the entry is there, which an earlier copy did; after a
delete, the entry is gone, which an earlier copy did unless the entry never existed or another
writer deleted it), False (the re-send was applied), or None when that cannot be told: for a
modify and a default entry, and when one of `settle`'s own re-sends got `OutcomeUnknown`, since
the switch's answer may then be about that one.

It raises:

- `Unsettled` (an `OutcomeUnknown`, carrying the error in `last` and its `status`, `origin` and
  `body`) when the budget runs out, and when the re-sent write is refused in a way that says
  nothing about the earlier copies: a 4xx from the kernel or the proxy, a reply that is not JSON,
  or a switch's code other than the ones below;
- `SwitchRefused` as is when the switch answers `INVALID_ARGUMENT`, `OUT_OF_RANGE` or
  `UNIMPLEMENTED`: in P4Runtime these codes say the write itself is invalid, so no copy of it can
  have landed. That follows the codes' meaning; it has not been observed on bmv2;
- `WriteNotVerified` when the table read does not confirm the outcome (an `ALREADY_EXISTS` from an
  entry with another action, written by someone else, ends here), or cannot. It then carries
  `attempts` and `original_landed` as `settle` had decided it, except where the read contradicts
  that decision: after `ALREADY_EXISTS` the read does not show the entry as sent (another action or
  parameters, or no entry), or after a delete's `NOT_FOUND` it still shows the entry; then
  `original_landed` is None. The decision is kept when the read failed (also when it found
  entries the API cannot show), when a delete's match could not be compared with the table, and
  after a re-sent write that was applied (`False`).

A modify of an entry that is not there is expected to be answered `NOT_FOUND` every time (that
follows P4Runtime; it has not been observed on bmv2), so it ends at once in `Unsettled`: an earlier
copy may have landed before another writer deleted the entry. Only a switch's refusal carries
`p4rt_error`, so tell that case from a budget that ran out (`last` is then a `Busy`,
`KernelUnreachable` or `OutcomeUnknown`) like this:

```python
except ndtwin.Unsettled as err:
    gone = isinstance(err.last, ndtwin.SwitchRefused) and err.last.p4rt_error["code"] == "NOT_FOUND"
```

**`Unsettled` means unknown: the write may have landed.** It may be on the switch already, or
land later. On bmv2 1.15.5 (2026-11-05), with the proxy's threads held busy, `settle` raised
`Unsettled` 64 s into the test (four re-sends, each answered `504` after 15 s), and a queued
copy of the insert landed at 89.5 s, 25 s after `Unsettled`. So read the entry back, and again
later, before you act on either answer. The snippet compares match and priority as they are, so
pass the entry in the form `read_table` gives it:

```python
def on_switch(k, entry):
    """The entry as the switch holds it (same match and priority), or None."""
    table = k.p4.read_table(entry["dpid"], entry["table"])
    return next((e for e in table.entries if e.match == entry["match"]
                 and e.priority == entry.get("priority")), None)

try:
    k.p4.settle(entry, "insert", budget_s=60)
except ndtwin.Unsettled:
    if on_switch(k, entry) is None:
        ...  # not there yet: it may still land; read again later, before writing that entry
```

Pass the entry in the form `read_table` gives it, as for `modify`. A delete is confirmed against
the table in one form: IPv4 addresses, MAC addresses and `"0x..."` values are compared as numbers,
a one-element list (an exact or optional match may be sent so) as its element, and a priority of 0
as none. A match with any other text in it (a decimal string, an address with spaces around it) is
not compared at all: the delete is then not confirmed (`WriteNotVerified`).

**When `settle` returns, the write can still land again.** An earlier copy of it, the first write
or one of `settle`'s own re-sends that got `OutcomeUnknown`, can still be waiting in the P4 proxy
and land later: §43 describes that wait, and it has no bound. On its own such a copy changes
nothing, since it is the same write; but it can undo a different write to the same entry (same
table, match and priority) sent after it. Nothing on the kernel's API tells an app when no earlier
copy can still land, so after a different write to that entry, read the entry back again later.

On bmv2 1.15.5 (2026-10-31) the switch's `ALREADY_EXISTS` (an insert sent twice) and `NOT_FOUND`
(a delete of a missing entry) came back in `p4rt_error` through the kernel, and a write sent
again at once while the proxy's threads were all busy was answered `504` again.

## OVS flow entries

`k.of.write(entry, op)` writes one flow entry through the kernel's flow routes (`op` is
`"install"`, the default, `"modify"` or `"delete"`) and then waits, up to `wait_s` seconds (10 by
default), for the kernel's record of what its dispatcher did with it. The entry is a `dict` in the
kernel's request shape (`ndtwin.FlowEntry` gives it `.dpid`, `.priority`, `.match`, `.actions`
and `.idle_timeout`):

```python
entry = {"dpid": 1, "priority": 100,
         "match": {"eth_type": 2048, "ipv4_dst": "10.0.0.2"},
         "actions": [{"type": "OUTPUT", "port": 3}]}
try:
    done = k.of.write(entry, "install")
    print("request", done.request_id, "taken by the controller; on the switch:", done.on_switch)
except ndtwin.Refused as err:              # NotFound too: nothing was written
    print("refused:", err, err.remedy)
except ndtwin.OutcomeUnknown as err:       # it may have landed, or may still land
    print("not known:", err, err.request_id)
```

**A normal return on OVS means the controller took the request, not that the switch has the
rule.** The kernel answers the POST with `200` `queued` once the entry passed its own checks and
is on its dispatcher's queue; it may not have reached the controller (Ryu) yet. `write` then
reads `GET /ndt/get_flow_dispatch_status?request_id=` until it says every job of the request was
dispatched, and raises for a refusal it finds there. `wait_s` bounds that polling, not a single
read of the record, which can take the client's `timeout` (20 s by default) and its retries.
Ryu answers before any switch has acted on the entry, and OpenFlow does not acknowledge a flow
mod, so a rule the switch itself turns down (a port it does not have, a full table) is reported by
nothing on the kernel's API. `on_switch` is `None`
on OVS for that reason, always.

It returns a `FlowWrite`:

| field | what |
|---|---|
| `request_id`, `accepted` | from the kernel's `200` body |
| `on_switch` | `True` when the record says the switch accepted every job (a bmv2 switch, below; after a delete, the delete was applied); `None` otherwise, on OVS always |
| `failures` | the record's failure list, `[]`; `None` when the call did not wait |
| `body` | the kernel's `200` body |
| `lab_claim` | that body's `lab_claim` key; these routes send no `X-NDTwin-Lab-Claim` header |

`wait_s=0` returns as soon as the kernel queued the entry, without reading the record
(`on_switch` and `failures` `None`); `k.of.dispatch_status(done.request_id)` reads it later. The
kernel keeps a bounded number of records and forgets them when it restarts.

What it raises, besides `ValueError` for an entry refused before sending (below). Every exception
of the wait carries `request_id`, `failures` (the records as the kernel gives them) and `remedy`
(the first one a record carries, or `None`). The POST is sent once: never again after a reply, or
after a connection that broke once the request went out.

| exception | when | `nothing_written` |
|---|---|---|
| `Refused` | the kernel refused the entry (`400` `malformed flow entry`, `Bad entry`); the kernel refused, before queueing, a delete with a priority on a bmv2 switch for a destination-only match (`501`, its reason in `err.body["refused_on_p4_reason"]`); Ryu refused it (`400`, `501`); the P4 proxy refused it (a `4xx`, or `501` with a `remedy`) | `True` |
| `NotFound` (a `Refused`) | the kernel does not know the dpid (`404`); Ryu answered `404`, which usually means the switch is not connected to Ryu (off, or disconnected), and in Ryu 4.34 also comes from a command, a port or a URL it does not know; the P4 proxy does not know the switch | `True` |
| `OutcomeUnknown` | the P4 proxy reported the write as failed (its `502`; the kernel's record keeps nothing that says whether the switch itself refused it, and the proxy answers the same for its own gRPC errors); the kernel answered `500`, or `400` `JSON parsing error` (its router answers that for an error anywhere in the handler, also after the entry was queued); the connection broke after the POST went out; Ryu did not answer within the kernel's 5 s, or answered a `5xx`; the record was not complete within `wait_s`; the kernel's dispatcher stopped; the kernel has no record of the request (`unknown request_id`), or no longer keeps some of its failures | `None` |
| `NDTwinError` | the kernel could not run `curl` to reach the controller (a `500` with no `refused_by` in the record) | `True` |
| `KernelUnreachable` | no connection to the kernel; sent again like any request | `True` |

Refused with `ValueError` before anything is sent, because the kernel or the controller would take
the entry and then not do what it says:

| entry | why |
|---|---|
| a key other than `dpid`, `priority`, `match`, `actions` and `idle_timeout` (`cookie`, `hard_timeout`, `table_id`, ...) | the kernel forwards only those to the controller. A kernel with the fix for `doc/FIXED-ISSUES.md` C-10 refuses `cookie`, `cookie_mask`, `table_id`, `hard_timeout`, `flags`, `buffer_id`, `out_port` and `out_group` with a 400 unless the value is the controller's default; older kernels drop them without a word |
| `idle_timeout` on a modify or a delete, `actions` on a delete | the kernel does not forward them on those ops (a kernel with the fix for C-10 refuses `idle_timeout` there with a 400 unless it is 0) |
| `match` that is not a `dict`, or has a key Ryu does not know (`ip_dst` for `ipv4_dst`) | Ryu drops an unknown match key with a log line only, so the rule would match more than asked |
| `eth_type`, `ip_proto` or a TCP, UDP or SCTP port that is not an integer (`"0x0800"`), in any of their spellings (`dl_type`, `nw_proto`, `tp_src`, ...) | Ryu takes it, but on a modify or a delete the kernel reads `eth_type`, `ip_proto` and, for TCP and UDP, the ports as integers when it updates its table view after it queued the entry, and then answers an error for an entry it already queued. It does not read the other spellings or the SCTP ports; the SDK holds them to the same form so that a field is checked alike whatever name it is written with |
| `tp_src` or `tp_dst` without `ip_proto` (or `nw_proto`) 6 or 17 | Ryu cannot tell TCP from UDP and fails |
| `actions` that is not a list of `dict`s whose `type` Ryu knows (`[]` is a drop rule) | Ryu drops an unknown action type with a log line only: a forwarding rule would become a drop |
| a delete without a `match`, or with an empty one, unless `all_rules=True` | without a `priority` it removes every rule in the switch's table 0, the kernel's own included: the LLDP rule to the controller, the table-miss rule and NDTwin's routes; with a `priority`, the match-all rule at that priority (at 0, the table-miss rule) |

What the controller does with what is sent:

- The kernel sends no `table_id`, so Ryu acts on table 0 (a kernel with the fix for C-10 refuses
  a `table_id` other than 0).
- A delete without `priority` is non-strict: it removes every rule whose match includes the one
  sent, at any priority, so more specific rules too, NDTwin's own route of that destination
  included. With a `priority` it removes only the rule with exactly that match and priority. A
  modify always names a
  priority (none means 0) and changes only the rule with that match and priority; under
  OpenFlow 1.3 it changes nothing when there is no such rule, and nothing says so.
- NDTwin's router installs its routes as `{"eth_type": 2048, "ipv4_dst": <host>}` at priority 10,
  and installs them again when the links change (`intelligent_router.py`). Under OpenFlow 1.3 an
  install with the same match and priority replaces the rule that is there, so the router's next
  install can replace yours too; write at another priority to keep a rule of your own.
- The kernel does not check the lock (`k.lock`) on these routes: it is for apps that agree to take
  it.

The kernel's table view, `GET /ndt/get_switch_openflow_table_entries`, is not a read-back. It
holds the kernel's last poll of each switch, about every 10 s, and the kernel edits it itself when
it queues a modify or a delete: such a write can show there at once, before the switch has it and
even when the controller then refuses it (when the request names the ethertype as `dl_type`, or
not at all). An install shows only after a poll. On OVS an install showed there 3.25 to 3.66 s
after the POST, and a deleted rule was still listed 9.61 s after the switch dropped it
(doc/2026-01-02_ndt_api.md §5).

The same call reaches a bmv2 switch, through the P4 proxy. On NDTwin's own pipeline (`ndt up p4`
without `--app`) the proxy programs the switch before it answers, so a normal return has
`on_switch` `True`; after a delete, `True` means the delete was applied. There a match on the
destination alone goes to a table with one entry per destination and no priority: the priority is
not programmed, and an install replaces that destination's entry instead of adding one above it.
The proxy ignores `idle_timeout`, and `on_switch` is `True` all the same. A write the proxy reports
as failed (its `502`) is an `OutcomeUnknown`: the proxy answers it for the switch's refusal and for
its own gRPC errors alike, and the kernel's record does not tell them apart. On a package's pipeline
(`ndt up p4 --app`) the proxy writes only a destination route, and only into a route table the
package gives to NDTwin (`roles.ipv4_route` with owner `ndtwin`); it refuses anything else with
`501`, which `write` raises as `Refused` with the proxy's `remedy`: write that table with
`POST /p4/table_entry`, which is `k.p4.write`.

Not offered yet: reading the table view, writing several entries in one request, a read-back that
confirms an entry on an OVS switch, `cookie`, `hard_timeout` and `table_id`, and group and meter
entries.

## Cutting a link

`k.link_down(link)` cuts a link between two switches for the length of a `with` block, through
the kernel, and puts it back when the block ends, whether the block finishes, raises or is
interrupted with Ctrl-C. `link` is a `Link` of `k.topology().links` (either direction) or the two
ends, `((dpid, port), (dpid, port))`.

```python
link = next(l for l in k.topology().links if (l.src, l.dst) == (1, 2))
try:
    with k.link_down(link) as cut:
        print("on the wire:", cut.on_wire, cut.interfaces or cut.why)
        # ... what the app does while the link is down
    print("restored:", cut.restored.removed)
except ndtwin.LinkNotRestored as err:      # the link may still be cut
    print("not restored:", err.still_cut, err.remedy)
```

Entering sends `POST /ndt/inject_link_failure` (§2b) once. The kernel declares both directions of
the link down in the twin and, on a Mininet deployment, attaches `netem loss 100%` to the
interfaces at both ends (`s<N>-eth<M>`), or to neither. Leaving sends
`POST /ndt/inject_link_recovery` (§2c) once: it withdraws the declaration and removes the netem
this kernel process attached. Neither POST is sent again after a reply, or after a connection
that broke once the request went out: a repeated injection answers that nothing was attached
while the first one's netem still cuts the wire, and the kernel keeps no owner of an injection,
so a repeated recovery that lands after another app injected the same link withdraws that
app's injection.

`cut` (a `LinkCut`) says what is known about the wire:

| field | what |
|---|---|
| `on_wire` | `True`: the netem this injection attached is on every end. `False`: this injection attached no netem: the deployment is not Mininet (`tc` is `"skipped (not MININET)"`), or the kernel refused the cut (a netem already on an interface, a qdisc tree it could not read, an interface it cannot name). `None`: on some ends only (below). The block runs on `True` and `False` |
| `interfaces` | the interfaces that carry the netem this injection attached |
| `why` | when `on_wire` is not `True`: the kernel's reason, quoted, where the kernel gave one; the SDK's own sentence when the kernel skipped tc (not a Mininet deployment) |
| `tc`, `status`, `body`, `lab_claim` | the reply's per-interface detail, status line, body and `lab_claim` key |
| `restored` | after the block: the recovery's `LinkRestore` (`removed`, `still_cut`, `tc`, `status`, `body`, `lab_claim`) |
| `restore_error` | after the block: the `LinkNotRestored` the recovery raised, or `None` |

`on_wire` `False` does not mean that packets cross the link. A netem that was already on an
interface (an injection that outlived a kernel restart, another app's, a fault tool's) is why the
kernel refused the cut, and it may drop every packet: `cut.why` names it at entry, and
`cut.restored.still_cut` lists it after the block, since this kernel does not remove a netem it
did not attach. When the kernel could not read a qdisc tree, nothing is known about that interface.

The kernel cuts both ends or neither, and takes an end off again when the other cannot be cut.
When it could not take it off (its `tc` detail says `rolled_back` with `ok` false), the netem
stays on one end only, which is a different fault (it stops the link in one direction): the
block does not run, the SDK sends the recovery at once and raises an `NDTwinError` whose
`restore` is that recovery's `LinkRestore` (`nothing_written` `None`: something was written and
undone), or `LinkNotRestored` when that recovery did not clear it.

Refused before anything is sent: `ValueError` for anything that is not a link, then `Refused`
(`nothing_written` `True`) for a host-facing link (dpid 0), and then, after one read of the
topology, `NotFound` for a link the topology does not hold as given (ports included) and
`Refused` for a link whose two switches have another link between them (the kernel finds a link
by its two switches only, so it could act on the other one) and for a link already declared down
(`down_reason` `"declared"`), which the recovery at the end of the block would withdraw. The
kernel's graph says `"declared"` both for an injection (another block's, or one left behind) and
for a failure the control plane reported, and does not tell them apart: `k.restore_link`
withdraws an injection you know was left behind, while a reported failure ends when the control
plane reports the link back.

The topology read and the POST are two requests. An injection by another app, or a failure the
control plane reports, that lands between them is not refused: the kernel declares the link again
and, when another injection's netem is already there, attaches none (`on_wire` `False`); the
recovery at the end of this block then withdraws that declaration too. A netem that this same
kernel process attached for another app's injection of the link is this kernel's to remove, so
that recovery removes it too. Then:

| exception | when | `nothing_written` |
|---|---|---|
| `Refused`, `NotFound` | the kernel refused the injection (`400` a payload it cannot read or a dpid 0, `404` no such link): nothing changed, the block does not run | `True` |
| `NDTwinError` | the kernel's `500` `reverse edge missing from the topology; nothing was injected` | `True` |
| `OutcomeUnknown` | any other `5xx`, a `400` `JSON parsing error` (the kernel's router answers it for an error thrown after the change too), a `2xx` the SDK cannot read, a connection that broke after the POST went out: the link may be cut; `remedy` is the `k.restore_link(...)` call | `None` |
| `KernelUnreachable` | no connection to the kernel for the injection (sent again like any request): nothing changed | `True` |
| `LinkNotRestored` | the recovery at the end of the block was refused (also its `409`), failed, could not connect, has an outcome the SDK cannot know, or answered `200` without clearing an interface this injection attached (a qdisc tree it could not read, a delete that failed, a netem somebody replaced) | `None`: the link may still be cut; the recovery's own error is `__cause__` (`None` after a `200`) |

A `LinkNotRestored` carries `ends`, `still_cut` (the interfaces that may still carry a netem;
`None` when the SDK cannot tell which, and `None` inside it for an end the kernel cannot name),
`tc` (the recovery's per-interface detail), `restore` (the `LinkRestore` of a readable `200`) and
`remedy`: the `k.restore_link(...)` call when sending the recovery again can clear it, and, for a
netem this kernel process did not attach, how to remove it by hand instead, since a recovery would
be refused again: after a `409` that text is the SDK's (the `409` names the interfaces, not the
command), and for a netem left standing it is the kernel's own sentence, which names the exact
`tc` command. An end the kernel gave no interface name is called "an end the kernel did not name".
When the block itself raised, its exception
goes on unchanged and the `LinkNotRestored` is set on it as `link_not_restored` (and added as a
note on Python 3.11 and later, which a traceback prints), and on `cut.restore_error`. A
netem on an interface this injection did not attach (it was there before the block) is reported
in `cut.restored.still_cut` and not raised.

Ctrl-C (or any exception) that arrives while the injection, or the recovery after a cut on some
ends only, is being sent is not covered: the `with` block has not started, so nothing sends a
recovery, and the link may be cut. Ctrl-C while the recovery at the end of the block is being sent
is not covered either: the interrupt goes on, no `LinkNotRestored` is raised, and whether the
recovery landed is not known. Run `k.restore_link(link)` in both cases.

`k.restore_link(link)` sends the recovery on its own and returns a `LinkRestore`. It refuses
before sending what `link_down` refuses (a host-facing link, then a link the topology does not
hold as given or whose switches have another link between them), except a link declared down,
which is what it is for. It raises `LinkNotRestored` for every interface it does not clear, for a
`409` (nothing is declared on the link and a netem this kernel process did not attach is on it;
`still_cut` names it) and for any other failure of the recovery; `nothing_written` is `True`
there only when the recovery changed nothing. The topology read before it raises, with nothing
sent, `KernelUnreachable` when the kernel is down and `NDTwinError` for a graph the SDK cannot
read.

**What a killed app or a restarted kernel leaves behind.** A process that is killed (`SIGKILL`,
a power cut) runs no recovery: the link stays declared down in the twin and cut on the wire.
Both outlive the app, and the netem also outlives the kernel. To find and clear what an app left:

```python
for link in k.topology().links:
    if link.down_reason == "declared" and 0 < link.src < link.dst:
        try:
            done = k.restore_link(link)
            print(f"s{link.src}-s{link.dst} restored:", done.removed)
        except ndtwin.LinkNotRestored as err:   # go on with the other links
            print(f"s{link.src}-s{link.dst} not restored:", err.still_cut, err.remedy)
        except ndtwin.Refused as err:           # refused before sending: nothing changed
            print(f"s{link.src}-s{link.dst} skipped:", err)
```

It withdraws the declaration of every link it restores: also the injection of an app that is
still running, and a failure the control plane reported. It skips, with nothing sent, a link
whose two switches have another link between them (`Refused`: the kernel finds a link by its two
switches only, so the recovery could act on the other one): the SDK restores no such link, and
the loop goes on with the others. Run it when no other app is cutting links.
A kernel that restarts forgets its declarations (the link then reads `"none"`) and no longer owns
the netem it attached: `k.restore_link` then answers `LinkNotRestored` (the kernel's `409`, with
the interfaces in `still_cut`), and the netem has to be removed by hand on the kernel's machine:
`sudo tc qdisc del dev <interface> root`, or `parent <id>` where `tc qdisc show dev <interface>`
shows the netem under a parent. At startup the kernel logs one line naming the interfaces that
already carry a netem (`netem is already attached`).

**What the cut needs on the kernel's machine.** The kernel runs `sudo -n tc qdisc show`, `add`
and `del` on `s<N>-eth<M>` interfaces, so the account that runs it needs those as NOPASSWD sudo
rules: the user guide's section 3.2 gives them as its optional `link-fault API only` line
(`doc/2026-11-05_user-guide.md`). Without them the kernel cannot read the qdisc tree and attaches
nothing: `cut.on_wire` is `False` and `cut.why` says so.

**P4 and OVS fabrics.** The routes do not depend on the data plane: the kernel decides only by
its deployment mode, and a Mininet fabric, OVS (`ndt up`) or bmv2 (`ndt up p4`), names its
interfaces `<bridge>-eth<port>` from its topology file. A cut was measured on the OVS fabric
(§2b: LLDP stops crossing the link and the controller reports it down). On bmv2 it has not been
measured: whether bmv2 stops forwarding on the cut interfaces as OVS does, and what the P4 proxy
then reports, only a run on that fabric shows. Outside Mininet nothing is cut (`on_wire` `False`).
The kernel does not check the lock (`k.lock`) on these routes.

## Tests

```bash
python3 tests/python/test_ndtwin_sdk.py -v
```

They run the SDK from `sdk/python` against an in-process fake kernel; nothing has to be installed.
`k.of` has its own file, `python3 tests/python/test_ndtwin_sdk_of.py -v`, and so do
`k.link_down` and `k.restore_link`, `python3 tests/python/test_ndtwin_sdk_link.py -v`.
How the SDK reads the replies the P4 proxy's own handler builds is checked with the proxy's
tests, under an interpreter that has the proxy's packages:

```bash
cd p4_proxy && PYTHONPATH=. venv/bin/python tests/test_ndtwin_sdk_proxy_replies.py -v
```

Under an interpreter without those packages it skips both of its tests and exits 0
(`OK (skipped=2)`).
