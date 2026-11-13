# ndtwin: a Python client for the NDTwin kernel

[Co-developed with claude code -- Adam]

`ndtwin` wraps the kernel's HTTP API (port 8000, `doc/2026-01-02_ndt_api.md`) for an app written in
Python. It uses only the standard library, needs Python 3.10 or newer, and is synchronous. It calls
the kernel's `/ndt/...` routes and nothing else: an app does not talk to the P4 proxy on port 8081.

Install it into a virtual environment (Ubuntu 24.04's system Python is externally managed, so
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
    topo = k.topology()                             # switches, hosts, links
    changed = []
    for dpid in topo.switches:                      # every switch with a link to s4 ...
        ports = topo.neighbours(dpid)               # {port: neighbouring switch}
        if 4 not in ports.values():
            continue
        spare = [p for p, n in ports.items() if n != 4]
        table = k.p4.read_table(dpid, "MyIngress.ipv4_lpm")
        changed += [e.with_params(port=spare[0]) for e in table.entries
                    if ports.get(e.params["port"]) == 4]   # ... sends its routes via s4 elsewhere
    k.p4.modify_all(changed, verify=True)           # writes, then reads each table back
    lease.renew(60)                                 # before a step that must still hold the lock
    k.power_off(4)                                  # by dpid; raises PowerError unless it reads "off"
    # ... later, when the traffic is back:
    k.power_on(4)                                   # raises PowerError unless it reads "on"
```

This is for the tutorials' `basic` exercise (pod topology: h1, h2 on s1; h3, h4 on s2; s3 and s4
each joined to s1 and s2), where s4 has no host and s3 already routes every host, so moving the
routes of s1 and s2 that leave towards s4 onto their other spine keeps every host reachable. It
keeps each entry's next-hop MAC address, which `basic` does not check, and checks no route: on
another fabric, use a route check such as the one of `examples/p4_energy_saving/` (below).

## What it offers

| call | route |
|---|---|
| `k.topology()` | `GET /ndt/get_graph_data` (§3): `switches`, `hosts`, `attached_hosts`, `links`, `edge_switches`; see "The topology" |
| `k.average_link_usage()` | `GET /ndt/get_average_link_usage` (§24), a 0..1 fraction (a `float`) with `.telemetry_health` |
| `k.power_report()` | `GET /ndt/get_power_report` (§6), `{dpid: mW}` |
| `k.power_state(dpid)`, `k.power_off(dpid)`, `k.power_on(dpid)` | `GET`/`POST /ndt/(get\|set)_switches_power_state` (§7, §8): see "What powering a P4 switch needs" and "Powering a switch back on" |
| `k.lock(name, ttl)`, `lease.renew(ttl)` | `POST /ndt/acquire_lock`, `/ndt/renew_lock`, `/ndt/release_lock` (§27, §28, §29) |
| `k.p4.read_table(dpid, table)` | `GET /ndt/p4/table_entry` (§43) |
| `k.p4.write(entry, op, table_size=None)`, `k.p4.modify(entry)`, `k.p4.modify_all(entries)` | `POST /ndt/p4/table_entry` (§43); `table_size`: see "A full table" |
| `k.p4.settle(entry, op, budget_s=60.0, wait_s=None)` | `POST`, then one `GET /ndt/p4/table_entry`: see "Settling a write whose outcome is unknown" |
| `k.p4.counter(name, dpid, index=0)` | `GET /ndt/p4/counter/{name}` (§43, §3) |
| `k.p4.direct_counter(name, dpid)` | `GET /ndt/p4/direct_counter/{name}` |
| `k.p4.register(name, dpid, index=None, start=None, count=None)` | `GET /ndt/p4/register/{name}` (bmv2 only) |

The power API takes a switch's management address, not its dpid. The SDK maps the dpid to the
address from the topology (the kernel serialises the address as a little-endian integer, which the
SDK decodes). A table entry is a `dict` in the exact JSON shape of the API, with `.match`,
`.params`, `.priority` and `with_params(**changes)`; values the API gives go back unchanged.

`verify=True` reads each table back after the writes, as strictly as `read_table`: a table with
entries the API cannot show raises `WriteNotVerified`, and the check compares values in the form
the GET returns them. A MAC address in upper case, or a number where the API gives a `"0x..."`
string, lands on the switch and still fails the check; send values back in the GET's form.

The counter and register reads return the proxy's reply as plain objects; they are sent again on
the same rule as any read. Not covered: path finding over the topology (an app that reroutes
brings its own, as `examples/p4_energy_saving/energy_saving_sdk.py` does), and reading a table's
declared size (the kernel does not serve it for every table: pass it, see "A full table").

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
`src_port`, `dst`, `dst_port`, `up`, `utilization_percent`, `usage_bps`, `bandwidth_bps` and
`telemetry_status`.

## What powering a P4 switch needs

On a P4 (bmv2) fabric, `k.power_off(dpid)` and `k.power_on(dpid)` work only on a machine where the
root helper `/usr/local/sbin/ndtwin-p4-power` is installed and the account that runs the kernel
(under `ndt up`, the one that ran it) may run it through `sudo` without a password. Nothing installs
either: the install command and the grant line are under "P4 power control" in section 3.2 of this
repository's user guide (`doc/2026-11-05_user-guide.md`). Without them the kernel answers `500`
and the call raises `PowerError`, with `nothing_written` `None`. In that case the switch is not
touched, but the same `500` also comes back when the helper signalled the switch and it had not
stopped 10 s later, so the SDK cannot tell the two apart: read the state back. On an OVS fabric the
kernel uses `ovs-vsctl` and `ifconfig` instead (the same section).

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
`modify_all` also has `written`: the entries answered before the write that failed.

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
| `PowerError` | the power command failed, or the state read afterwards is not the one commanded | `None`: the kernel's 500 is the same whether the switch was touched or not (a bmv2 switch may have been signalled and still be stopping) | no |
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

## Tests

```bash
python3 tests/python/test_ndtwin_sdk.py -v
```

They run the SDK from `sdk/python` against an in-process fake kernel; nothing has to be installed.
How the SDK reads the replies the P4 proxy's own handler builds is checked with the proxy's
tests, under an interpreter that has the proxy's packages:

```bash
cd p4_proxy && PYTHONPATH=. venv/bin/python tests/test_ndtwin_sdk_proxy_replies.py -v
```

Under an interpreter without those packages it skips both of its tests and exits 0
(`OK (skipped=2)`).
