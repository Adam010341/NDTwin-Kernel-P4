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

## What is NOT established

**Why learning follows the release.** Three candidates, none discriminated:

1. This handler stalling its own app's event queue. It blocks inside an `EventSwitchEnter`
   handler and Ryu dispatches one app's events serially, so anything else `IntelligentRyu`
   would have done -- including installing table-miss entries for switches whose features event
   is still queued -- waits too.
2. Switches without a table-miss entry dropping the burst rather than punting it, so no packet
   reaches the controller until the walk installs rules.
3. The burst simply being serialised behind fabric bring-up for an unrelated reason.

Against (1) specifically: the external poller kept answering throughout, and it is served by a
*different* app, so at minimum the `Switches` app was not stalled.

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
and `288,0` at t+0 and at every sample after. **It does not reproduce run 1.** So the
read-too-early explanation is consistent with the poll cadence and with three later boots, but
it is *not confirmed* -- run 1 was never re-sampled, because the acceptance script looked once
and moved on. Whether that fabric would have healed five seconds later is now unknowable.

The method defect is real regardless: reading the twin at t+0 races a poll loop the script knows
about. The acceptance criterion should be "reaches 288/0 within the kernel's poll cadence".

## The default

**90.** The claim behind it is narrower than n=3 makes it sound: four boots, four fabrics that
Ryu reported as fully learned, three of which also had a clean kernel graph at t+0 and one that
did not and was not looked at again.

- **10** -- the committed default before this change -- is known broken: 0/128 learned, 256 host
  edges down, on a fabric that forwards perfectly.
- **60** was healthy historically and was *not* adopted on that basis. That result predates
  `4810e8f`, which made the walk ~9x faster and therefore moved it earlier relative to
  everything else; the old measurement does not transfer and has not been repeated.

Cost: OVS 128-host boot goes from the ~73 s quoted for the settle=60 era to **101 s**. That is
the price of the twin seeing its own hosts, and it is a real regression against the number the
8/27 deck was going to quote.

## Recommendation

Ship the 90 s default and the corrected comments; do **not** ship the "waits for the event"
claim. The machinery is kept because fail-open costs nothing and the early exit becomes correct
the moment the coupling is broken -- but the source now says plainly that the early exit has
never fired.

The mechanism is worth one more round: if the coupling is (1) or (2), the fix likely restores
both correctness *and* the ~73 s boot, which is the only path back to the deck's original
number.
