# Energy saving on a P4 fabric, through the kernel's API

[Co-developed with claude code -- Adam]

A small app that turns off one switch when the network is quiet. It uses only the NDTwin
kernel's HTTP API on port 8000 and the Python standard library. It is written twice, with the same
policy, options and exit codes, and the same rule for a write that may have landed (it is sent
once, and the switch stays on):

| file | what it is |
|---|---|
| `energy_saving.py` | does its own HTTP, error handling, address decoding and table read-back |
| `energy_saving_sdk.py` | the same app on the `ndtwin` Python SDK (`sdk/python`) |
| `route_walk.py` | follows each pair of hosts through the planned tables; both apps use it |

The SDK version is shorter because the SDK does the plumbing; what is left in it is the policy, a
shortest-path helper and the route check of `route_walk.py`. Compare the two files to see what the
SDK takes over.

Before it writes anything, each app follows every pair of hosts of the switches that are on and
reachable, also a host behind a link that is down for now, through the tables as they will be
after its rewrites. (A switch with hosts that is off or unreachable has no table to follow; the app
says so, and does not check its hosts' routes.) On a fabric where a route reaches the switch
through another switch, moving only the entries next to it can send packets in a loop; the app
then leaves that switch on and tries the next one. The check is conservative: a packet that only
the default entry would take (even one whose action forwards), or only an lpm entry that matches
any address, counts as dropped, so a fabric that relies on either keeps every switch on.

The check follows ports, not MAC addresses. A rewritten entry takes the next hop's MAC address
from another entry of the switch that uses the new port. When none gives one, the entry keeps the
address it had and the output says so (`dstAddr unchanged`): packets then go to the new next hop
carrying the address of the old one, the switch being turned off. That is harmless on the
tutorials' pipelines, which forward on the IPv4 address alone, but wrong on a pipeline that checks
the destination MAC address (a router-MAC table, say) or with an Ethernet switch between the P4
switches: there the packets are dropped and the route check cannot see it. Read the `--dry-run`
output first, and do not run the app on such a pipeline when a line says `dstAddr unchanged`.

The app also leaves on every switch that has a host, even behind a link that is down; those are
not printed. Every switch it rejects before choosing one is printed with the reason ("s3 stays
on: ..."), including one whose links have no telemetry (see below).

The one difference in behaviour is the retry: the SDK also sends again a request that could not
connect to the kernel and a read whose connection broke; `energy_saving.py` repeats a request
only after a 502, 503 or 504 answer, and only where repeating it cannot write twice.

## Run it

Before the app can turn anything off, **traffic has to pass through every switch**. The app reads
each link's `telemetry_status` in `GET /ndt/get_graph_data`, and keeps on any switch with a link
to another switch that reads neither `live` nor `idle`:

- `silent`: the switch's sFlow agent has sent no sample within the kernel's window. On bmv2 a
  switch that no packet has passed lately reads like this.
- `unknown`: the kernel has never had a sample from it.

Such a link reads 0 %, but that is no measurement, so the app cannot tell a quiet link from one it
knows nothing about, and it keeps the switch on by design. On a fabric nobody has sent traffic
through yet every link reads like that, and the app does nothing and says why, for example:

```text
s3 stays on: no telemetry on s1->s3 silent, s2->s3 silent, s3->s1 silent, s3->s2 silent
s4 stays on: no telemetry on s1->s4 silent, s2->s4 silent, s4->s1 silent, s4->s2 silent
no switch can be turned off; s3, s4 stayed on only because their links have no telemetry samples: send traffic through every switch, then run again
```

On the `basic` pod topology, steady pings from h1 to h3 and to h4, and from h3 and h4 to h1, go
over both spines; then wait until every switch-to-switch edge in `GET /ndt/get_graph_data` reads
`live` or `idle`. The pings may keep running while the app runs: they are far below its limits on
link usage.

1. Finish the tutorials' `basic` exercise (its `solution/basic.p4` is a finished one), build it
   and bring it up:

   ```bash
   make -C ~/tutorials/exercises/basic build
   ndt up p4 --app ~/tutorials/exercises/basic
   ```

2. See what it would do, then do it:

   ```bash
   python3 examples/p4_energy_saving/energy_saving.py --dry-run
   python3 examples/p4_energy_saving/energy_saving.py
   ```

   The SDK version needs the SDK installed first, into a virtual environment (Python 3.10 or
   newer, no other package; `sdk/python/README.md` gives the recipe for a machine without
   network access), then takes the same options:

   ```bash
   python3 -m venv .venv && . .venv/bin/activate
   pip install -e sdk/python
   python3 examples/p4_energy_saving/energy_saving_sdk.py --dry-run
   python3 examples/p4_energy_saving/energy_saving_sdk.py
   ```

On `basic`'s pod topology (h1 and h2 on s1, h3 and h4 on s2, s3 and s4 each joined to s1 and s2)
it picks s4, moves s1's route to h4 and s2's route to h2 onto s3, reads both tables back, and
powers s4 off. On 2026-10-31 an earlier version of both apps did that on a bmv2 1.15.5 fabric of
that exercise, with pings through every switch, without losing a ping; the tests show the same
against a fake kernel built from a recorded reply of that topology.

Powering a bmv2 switch off needs the root helper `ndtwin-p4-power` (`doc/2026-01-02_ndt_api.md`
§8). The User Manual does not install it: the steps are in the docstring of
`tools/p4_power_helper.py`. Without it the power-off answers `500` and the app says the power-off
may have taken effect, since the same `500` also comes back when the helper signalled the switch
and it had not stopped 10 s later; the routes it moved still work, because the other spine carries
them.

## Options

| option | default | meaning |
|---|---|---|
| `--kernel` | `http://localhost:8000` | the kernel |
| `--table`, `--match-field` | `MyIngress.ipv4_lpm`, `hdr.ipv4.dstAddr` | your forwarding table and its destination field |
| `--port-param`, `--mac-param` | `port`, `dstAddr` | the action parameters that hold the egress port and the next hop's MAC (`''` if none) |
| `--max-avg-usage` | `0.4` | do nothing above this average link usage (a 0..1 fraction, §24) |
| `--max-link-util` | `40` | never turn off a switch with a link above this utilisation (percent, §3) |
| `--every` | `0` | repeat every N seconds; 0 runs once. Less than 15 s is refused (see "Closed-loop apps" in the API document) |
| `--dry-run` | | read and plan, write nothing |

Exit status: 0 done or nothing to do, 1 an error or a step that did not take, 3 another app holds
`routing_lock`.

Neither app ever powers a switch back on. The tests run against a fake kernel:
`tests/python/test_p4_energy_saving_example.py` for `energy_saving.py` and
`tests/python/test_p4_energy_saving_sdk_example.py` for `energy_saving_sdk.py`; the SDK's own tests
are `tests/python/test_ndtwin_sdk.py`.
