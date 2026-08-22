# The host-discovery gate does not gate: it is a fixed sleep with a poll loop attached

[Co-developed with claude code -- Adam]

P0-1 was "apply `scratch/pending/host-discovery-gate.patch` and verify". The patch applies, the
fabric it produces is healthy, and the acceptance numbers pass. **The mechanism it claims is
still false**, and that matters more than the passing numbers, because the claim is written into
the source as a measured fact and would have been quoted onward.

Raw: `acceptance.txt`, `discriminator.txt`, `raw/`. Drivers alongside.

## What the patch claims

> Wait for the event rather than for a duration. `NDTWIN_RYU_SETTLE_S` is now a deadline, not a
> wait; a healthy 128-host fabric exits it early.

The regression it addresses is real and was pinned by intervention the previous night
(`e5e4980`): Ryu learns a host's IPv4 only from packet-in, the all-pairs rules end every punt,
static ARP closes the ARP path, so the learning window is exactly `[switch connect, all-pairs
install]`. Install too early and the twin shows 256 host edges down on a network that forwards
perfectly. Shortening the sleep 60 -> 10 did exactly that.

## What it actually does

Two boots, everything held, only the deadline changed:

| deadline | gate's reading, whole window | boot wall | final Ryu | final kernel graph |
|---|---|---|---|---|
| 90 s | `0/128` at every 10 s mark | 101 s | 128/128 with ipv4 | 288 edges, 0 down |
| 180 s | `0/128` at every 10 s mark | 191 s | 128/128 with ipv4 | 288 edges, 0 down |

**The gate has never once observed the event it waits for**, and boot time is `base + deadline`.

The early-exit path -- the entire point of the change -- has never been taken on a 128-host boot.

## The gate is not blind, and that is what makes this conclusive

The obvious first suspicion was that `_hosts_with_ipv4` reads the wrong thing: it calls
`get_all_host(self)` while every other topology-API call in `intelligent_router.py` passes
`self.topology_api_app`. A broken read would report a plausible 0 forever.

`gate_discriminator.sh` put a second reader on the same table for the same boot -- an external
poller on Ryu's own `/v1.0/topology/hosts` every 2 s -- and the two agree exactly:

```
t+2s     0 hosts known
t+6s     0 with ipv4, 36 hosts known     <- MACs seen, no IPv4-bearing packet-in
...      unchanged for the whole window
t+97s    128 with ipv4, 128 known        <- all at once, one sample
```

Both readers are right. There is nothing to see while the gate waits. (Code reading agrees:
`get_host` routes by `req.dst`, fixed to `'switches'` by the event class, so the `app` argument
does not select the table. The prediction was checked against the experiment, and here they
matched -- for the *read*. The prediction about the burst did not survive, see below.)

## The finding that reverses the story

At deadline 90 the burst looked like it landed at a fixed t+96s, one second after the deadline
expired -- a near-miss, arguing for a longer deadline. **That reading is wrong, and the 180 s run
is what kills it**: a burst at a fixed t+96s would have been seen by a 180 s gate, which would
have exited early at 96 s. It did not. It waited the full 180 s and the hosts appeared after.

The learning time tracks the deadline. Whatever produces the addresses happens *after the gate
releases*, not at a fixed point in fabric bring-up.

Raising the deadline therefore buys nothing but boot time, and the first fix attempted here
(90 -> 180 on "the burst lands at 96 s, give it margin") was reasoning from a single point that
the second point refuted. It is recorded because the near-miss story fit the first run perfectly.

## The ping burst is not the teacher

The patch, the runbook, and my own first write-up all said the same thing: the wait exists to
protect the startup ping burst, which is how Ryu learns host addresses. `burst_timing.sh` dates
that burst directly, by counting `testbed_topo.py`'s own "Pinging from hN" lines out of the topo
session every 4 s (`ndtwin-lab topo-out` is a tmux `capture-pane`, and the session is created
fresh by `ovs-topo-start` and killed by `ndt down`, so the buffer cannot be a previous run's):

| t (boot) | pings printed | Ryu hosts with ipv4 | wait released |
|---|---|---|---|
| +32 s | **128** | 0 | no |
| +32…+93 s | 128 | 0 | no |
| **+97 s** | 128 | **128** | **YES** |

All 128 pings are done within 32 s. Ryu learns **nothing** from them for the next 65 seconds.
Every address appears in the single sample where the wait releases.

So the wait is not protecting the burst -- the burst is long over by the time the wait ends.
Whatever produces the addresses is triggered by the release itself. **That mechanism is still
not identified**, and it is now a sharper question than before rather than a vaguer one: what
happens at release is the all-pairs walk, and a walk that installs forwarding rules is the one
thing that should make packets *stop* reaching the controller.

Note what this retires: the "burst lands late, give the deadline margin" story, and also the
inverse story I had written into the runbook an hour earlier ("that ping round is the twin's
only chance to learn"). Both were wrong in the same way -- built on when the burst was *assumed*
to happen, never on a measurement of it.

What survives from `e5e4980` is the punt half: IPv4 is learned only from packet-in, and static
ARP closes the ARP path. That was established by intervention and is not in question. What does
not survive is the identification of the boot-time burst as the packet that does the teaching.

### The consequence worth acting on -- and the prediction it got wrong

The reasoning at this point was: the only time-dependence left is whether release lands after
the fabric finishes building. `settle=10` releases at ~t+18, before the burst completes at
~t+32, and leaves 0/128 forever; `settle=90` releases at ~t+97 and works. So the rule should be
"release after ~t+32", a settle of 25--40 should work, and boot should come back to ~45 s.

**The boot-time half of that was right and the mechanism half was wrong.** `settle_bisect.sh`
found the cliff between 10 and 15 -- so 15 and 20 work, both of which release *before* the burst
finishes. "Release after the burst" is therefore not the rule either. The correct default fell
out of the curve anyway (below), but it was not found by understanding the mechanism, and the
mechanism is no better understood than it was two paragraphs ago.

**A failed attempt at this is also recorded**, because it failed in an instructive way.
`gate_coupling.sh` was written to probe mid-window: does s1 have a table-miss entry, do the
Mininet hosts exist, does a hand-issued ping teach Ryu? It reported "gate is open", probed, and
found no hosts and unreadable endpoints -- which looks exactly like a result. It was not one.
`ndt up` had refused at preflight ("a Mininet is already running") and never booted; the gate
line the script keyed on was the **previous** run's, still in `ryu.log` because rotation happens
when a new Ryu starts and no new Ryu had started. The script asserted that a gate was open; it
never asserted that *this run's boot* had happened. A freshness check with no freshness in it.
The script is kept with the flaw described rather than silently repaired, and re-running it
requires fixing that assertion first.

## A second failure mode, downstream of the one the patch addresses

The n=3 acceptance at the 90 s default, each read **immediately** after `ndt up` returned:

| run | boot | Ryu's host table | kernel graph |
|---|---|---|---|
| 1 | 100 s | 128/128 with ipv4 | 288 edges, **256 down** |
| 2 | 101 s | 128/128 with ipv4 | 288 edges, 0 down |
| 3 | 100 s | 128/128 with ipv4 | 288 edges, 0 down |
| 4-host | 6 s | 4/4 with ipv4 | 40 edges, 0 down |

Run 1 is a different shape from the original regression: **Ryu knew every address and the twin
still showed 256 edges down.** The disagreement is between Ryu and the kernel's copy, not
between Ryu and the fabric.

The kernel re-polls -- `TopologyAndFlowMonitor.cpp:2032-2034`, every 5 s for its first 90 s, then
every 30 s -- and it is started at `ndt`'s [4/4], *after* the settle wait releases. So its first
poll can land in the second or two before Ryu learns, `updateHosts` skips every host whose
`ipv4` list is empty, and a read taken at that instant sees 256 down on a fabric that is fine.

`graph_settle.sh` re-ran the boot and sampled both sides every 5 s for two minutes: `128/128`
and `288,0` at t+0 and at every sample after. **It does not reproduce run 1.**

The healing path does exist, and this is not inference from timing: `updateHosts` sets
`isUp = true` / `isEnabled = true` on the edge every time it sees a host with an IPv4
(`TopologyAndFlowMonitor.cpp:683-687`) -- unconditionally, not only on first sight. So it is
not a member of this codebase's "should replace, can only add" family; a down edge does come
back up on the next poll, and the next poll is at most 5 s away during the first 90 s.

What remains unproven is that run 1 specifically took that path, because **run 1 was never
re-sampled** -- the acceptance script looked once and moved on. So: the mechanism that would
heal it is present and on a 5 s timer, three later boots were clean at t+0 and stayed clean for
120 s, and whether that particular fabric healed is now unknowable.

The method defect is real regardless: reading the twin at t+0 races a poll loop the script knows
about. The acceptance criterion should be "reaches 288/0 within the kernel's poll cadence".

## The default: 40, off a measured curve

`settle_bisect.sh`, eleven full 128-host boots, both sides read at t+0 and again 20 s later (the
second read is there because the kernel re-polls every 5 s, and the n=3 acceptance's single t+0
read is what produced an unexplainable "256 down"):

| settle | boot | Ryu | kernel graph | verdict |
|---|---|---|---|---|
| 5 | 16 s | 0/128 | 288e / 256 down | **BLIND** |
| 10 | 20 s | 0/128 | 288e / 256 down | **BLIND** |
| 10 (repeat) | 20 s | 0/128 | 288e / 256 down | **BLIND** |
| 15 | 27 s | 128 | 288e / 0 down | ok |
| 20 | 31 s | 128 | 288e / 0 down | ok |
| 30 | 41 s | 128 | 288e / 0 down | ok |
| **40** | **51 s** | 128 | 288e / 0 down | ok |
| 40 (repeat) | 52 s | 128 | 288e / 0 down | ok |
| 40 (repeat) | 52 s | 128 | 288e / 0 down | ok |
| 55 | 66 s | 128 | 288e / 0 down | ok |
| 90 | 100 s | 128 | 288e / 0 down | ok |

Two things this settles that no amount of reading could:

1. **The regression is real and reproduces on demand.** settle=10 was measured broken yesterday
   by a different session; it is broken twice more today, at a commit whose only intervening
   changes were documentation. This is the control the whole task rested on, and it had not been
   run at this commit until now.
2. **It is a cliff, not a slope** -- every host is learned or none is, with the edge between 10
   and 15. There is no partial regime to tune within.

**40** sits 4x above the highest failing value and ~2.7x above the cliff's upper bound, n=3 at
52 s. That is *faster than the 73 s* the settle=60 era cost, and correct. So the deck's OVS
number improves rather than regresses -- the opposite of what this report said an hour ago,
when the default was 90 and the only evidence was a single point.

Do not tune toward 15 to save 25 s. The failure is silent and total: the fabric forwards
perfectly, every ping passes, and the twin cannot see 256 of its own 288 links, with nothing in
the boot output saying so. A slower machine or a bigger fabric moves the cliff and nothing
would announce it.

## What the source now says

Ship the 40 s default and the corrected comments; do **not** ship the "waits for the event"
claim. The machinery is kept because fail-open costs nothing and the early exit becomes correct
the moment the coupling is understood -- but the source says plainly that the early exit has
never fired on a 128-host boot.

## Still open

* **What actually teaches Ryu at release.** The burst is over by t+32 and teaches nothing; every
  address appears when the walk runs. A walk that installs forwarding rules is the last thing
  that should produce packet-ins, so this is not a small gap in the story -- it is the story.
* **Why the cliff sits at 10--15 s** rather than at the burst's completion (~32 s). If the rule
  were "release after the burst", 15 and 20 would have failed. They did not. So "release after
  the burst" is *also* not the rule, and the real dependency is still unnamed.
* Run 1 of the n=3 acceptance: 256 down at t+0, never re-sampled, now unknowable.
