# Energy saving on a P4 fabric, through the kernel's API

[Co-developed with claude code -- Adam]

A small app that turns off one switch when the network is quiet, and turns it back on when the
traffic returns. It uses only the NDTwin
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
over both spines. The pings may keep running while the app runs: they are far below its limits on
link usage.

An edge leaves `silent` when the switch it leads to samples a packet, and reads `silent` again once
that switch has sampled none for 5 s (the kernel's window). A switch samples each packet it
receives with a chance of 1 in 256, so under light steady traffic an edge goes back and forth
between `silent` and `live` or `idle` instead of settling. The pings below bring s3 about 30 packets
a second and s4 about 10, so s3 is sampled about every 8 s on average and s4 about every 25 s, both
longer than the window: much of the time their edges read `silent`, and the app keeps them on and
says so. Do not wait for every edge to read `live` or `idle` at once: run step 2 again (each run
reads the links afresh, and one that names no switch writes nothing) until it names one, or send
the pings faster (a smaller `-i`, with `-c` raised to match so they still last a minute). In
`GET /ndt/get_graph_data`, each switch-to-switch edge's `agent_last_sample_age_seconds` is how many
seconds ago the switch it leads to last sampled a packet (`-1` for never).

These pings are typed at Mininet's `mininet>` prompt, which NTG as it ships does not give: select
it with `ndt ntg cli` **before** the bring-up below (the user guide's section 4.7,
`doc/2026-11-05_user-guide.md`; a fabric that is already up keeps its mode until `ndt down`).

1. Finish the tutorials' `basic` exercise (its `solution/basic.p4` is a finished one), build it
   and bring it up:

   ```bash
   ndt ntg cli
   make -C ~/tutorials/exercises/basic build
   ndt up p4 --app ~/tutorials/exercises/basic
   ```

   Then start the pings, a minute of them at five a second, in the background, each into its own
   file. `sudo ndtwin-lab topo-cmd` types a line at the `mininet>` prompt and needs only the user
   guide's sudo grants (section 4.7 says what it does; as root you can attach to the pane and type
   the same lines):

   ```bash
   sudo ndtwin-lab topo-cmd 'h1 ping -c 300 -i 0.2 h3 > /tmp/h1-h3.txt 2>&1 &'
   sudo ndtwin-lab topo-cmd 'h1 ping -c 300 -i 0.2 h4 > /tmp/h1-h4.txt 2>&1 &'
   sudo ndtwin-lab topo-cmd 'h3 ping -c 300 -i 0.2 h1 > /tmp/h3-h1.txt 2>&1 &'
   sudo ndtwin-lab topo-cmd 'h4 ping -c 300 -i 0.2 h1 > /tmp/h4-h1.txt 2>&1 &'
   ```

   When they have ended, `tail -n 2 /tmp/h1-h3.txt /tmp/h1-h4.txt /tmp/h3-h1.txt /tmp/h4-h1.txt`
   shows each one's loss. Without a `mininet>` prompt, the user guide's section 3.2 runs the same
   pings with `mnexec`.

2. See what it would do, then do it:

   ```bash
   python3 examples/p4_energy_saving/energy_saving.py --dry-run
   python3 examples/p4_energy_saving/energy_saving.py
   ```

   The SDK version needs the SDK installed first, into a virtual environment (Python 3.10 or
   newer, no other package), then takes the same options:

   ```bash
   python3 -m venv .venv && . .venv/bin/activate
   pip install -e sdk/python
   python3 examples/p4_energy_saving/energy_saving_sdk.py --dry-run
   python3 examples/p4_energy_saving/energy_saving_sdk.py
   ```

   `pip install -e sdk/python` downloads `setuptools` for the build. On a machine without network
   access, install it as the second recipe of `sdk/python/README.md` says
   (`python3 -m venv --system-site-packages .venv`, then
   `pip install --no-index --no-build-isolation -e sdk/python`), or skip the install with
   `export PYTHONPATH="$PWD/sdk/python"` as that README describes.

On `basic`'s pod topology (h1 and h2 on s1, h3 and h4 on s2, s3 and s4 each joined to s1 and s2)
it picks s4 when s4's links read `live` or `idle` (s4 draws more power), and s3 when only s3's
do; for s4 it moves s1's route to h4 and s2's route to h2 onto s3, reads both tables
back, and powers s4 off. On 2026-10-31 an earlier version of both apps did that on a bmv2 1.15.5 fabric of
that exercise, with pings through every switch, without losing a ping; the tests show the same
against a fake kernel built from a recorded reply of that topology.

Powering a bmv2 switch off or on needs the root helper `/usr/local/sbin/ndtwin-p4-power` and a
sudo grant for it (`doc/2026-01-02_ndt_api.md` §8). This repository's user guide gives the one
install command and the grant line, under "P4 power control" in section 3.2
(`doc/2026-11-05_user-guide.md`); nothing installs them for you. Without them the power-off
answers `500` and the app says the power-off may have taken effect, since the same `500` also
comes back when the helper signalled the switch and it had not stopped 10 s later; the routes it
moved still work, because the other spine carries them. To see which it was, read the line above
the kernel's `command failed` line in `.test_run/logs/kernel.log`: `sudo: ...: command not found`
means the helper is not installed, `sudo: a password is required` means the grant is missing, and
a line starting `ndtwin-p4-power:` is the helper's own reason.

## Options

| option | default | meaning |
|---|---|---|
| `--kernel` | `http://localhost:8000` | the kernel |
| `--table`, `--match-field` | `MyIngress.ipv4_lpm`, `hdr.ipv4.dstAddr` | your forwarding table and its destination field |
| `--port-param`, `--mac-param` | `port`, `dstAddr` | the action parameters that hold the egress port and the next hop's MAC (`''` if none) |
| `--max-avg-usage` | `0.4` | do nothing above this average link usage (a 0..1 fraction, §24) |
| `--max-link-util` | `40` | never turn off a switch with a link above this utilisation (percent, §3) |
| `--every` | `0` | repeat every N seconds; 0 runs once. Less than 15 s is refused (see "Closed-loop apps" in the API document) |
| `--wake-factor` | `2` | wake a switch turned off above this times `--max-avg-usage` (above 1) |
| `--wake-after` | `3` | passes in a row above the wake level before a wake |
| `--stay-on` | `300` | seconds after a power-on is sent or tried during which the app turns nothing off |
| `--dry-run` | | read and plan, write nothing |

Exit status: 0 done or nothing to do, 1 an error or a step that did not take, 3 another app holds
`routing_lock`.

## Waking the switch when the traffic returns

Run with `--every N` and the app remembers, in memory, the switches it turned off, in order, and
the routes it moved. If the app stops, nothing remembers them: a switch it turned off stays off
until someone powers it on. After `--wake-after` passes in a row (3 by default) with the average
link usage above `--wake-factor` (2 by default) times `--max-avg-usage`, a pass does not look for
another switch to turn off; it takes the switch it turned off last and

1. renews the lock, powers that switch on (§8) and reads its state back; a `500`, or a state
   that is not `on`, stops the pass;
2. reads the switch's forwarding table: a power-on starts the switch's bmv2 again and pushes its
   pipeline afresh, which empties its tables, and on a fabric brought up with `--app` the
   package's entries go back on (see "Powering a switch back on" in `sdk/python/README.md` for
   what else does and does not). It checks that the table is not empty, then reads the tables of
   the switches that are on and follows every pair of hosts through them as they will be with
   the routes moved back (`route_walk.py`, over the links as they were when the switch was turned
   off). An empty table, or a packet that would be dropped or loop, leaves the routes where they
   are and the switch on, still listed as one to wake;
3. renews the lock again and writes back the entries it had rewritten, as they were, and reads
   the tables back.

A failure before the writes leaves the routes around the switch, which keep working; a failed write
can leave some of them back on it, and a later wake of that switch writes them all again. The reason
line names the step that stopped. A switch whose wake fails goes to the back of the line, so the
next wake tries the one turned off before it; the links each switch remembers learn the ports of
every switch woken since, and a route may then come back onto a different switch than the one it
started on (every route is still checked first). A switch that is no longer in the topology is
forgotten, and its routes stay where they were moved. With two switches asleep, a wake takes the one
turned off last, and the next wake, after another `--wake-after` busy passes, the other: the switch
still off has no table to read, so a route that would need it reads as broken and the wake stops
there. For `--stay-on` seconds (300 by default) after a power-on is sent or tried, the app turns
nothing off, so a power-on that fails, and may still have taken effect, holds too.

Why these three: the kernel's average counts only the links that carry a reading (KNOWN-ISSUES
F-17), so it moves with the switches that are on, and it is noisy. On a bmv2 fabric one steady 52
Mbit/s flow read, at 2 s intervals, from 0.0290 to 0.0749 with one switch off (2.6 times from lowest
to highest) and from 0.0165 to 0.0681 with every switch on (4.1 times; 2026-11-11 UTC); in another
run of the same flow, with one switch off, from 0.0243 to 0.0707 (2.9 times). A wake level only
twice the limit is therefore not enough on its own to keep a switch from being turned off and on by
turns, when the limit sits inside such a range; and one reading 2 s after a power-on fell to 0.0021,
a quiet network's. Several passes in a row above the wake level filter single high readings, and
`--stay-on` bounds what is left: **no power-off comes less than `--stay-on` seconds after a power-on
is sent or tried, whatever the readings**, so the app turns switches off and on by turns at most
once per `--stay-on` seconds, across the whole fabric, and it cannot tell noise from a real change.
Pick the limit and the factor from your own fabric's readings: each pass prints the average it read,
and while a switch is asleep the reason line says what a wake needs.

With `--max-avg-usage 0.015` (wake level 0.03) on that fabric, the app turned a spine off on a quiet
network; once the flow started, the busy passes went 0, 1, 0, 1, 2, 3 and the sixth pass woke the
spine (the power-on took 1.24 s), checked the routes and moved two back; the 16 passes under load
after it turned nothing off, and four ping streams lost no packet (2026-11-11 UTC). A single hot
link is not a trigger: the switch it would wake may not relieve that link, and a later pass would
find that switch quiet and turn it off again (seen on that fabric, 16 s after a wake on a hot link).
A one-shot run (`--every 0`) knows of no switch it turned off, so it never powers one on. With
`--dry-run` it says what it would do.

The tests run against a fake kernel:
`tests/python/test_p4_energy_saving_example.py` for `energy_saving.py` and
`tests/python/test_p4_energy_saving_sdk_example.py` for `energy_saving_sdk.py`; the SDK's own tests
are `tests/python/test_ndtwin_sdk.py`.
