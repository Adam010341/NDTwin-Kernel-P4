# Finding 05 — the Energy-App declined to act on OVS, and three of the phase's own messages did not match what happened

**Status: CONFIRMED, 2026-08-30 15:53–16:02, OVS arm.** One observation about the app, three
about `25_apps_energy.sh`'s reporting. Kept together because the three messages are what would
have made the observation unreadable.

---

## The observation: same app, same quiet network, opposite decision on the two fabrics

| | P4 arm (15:30) | OVS arm (15:53) |
|---|---|---|
| switches powered off | **3** (s9, then s7, then s5) | **0** |
| first shutdown | within ~1 min | never |
| watch duration | 250 s | **474 s** (≈8 app cycles) |
| verdict | `INJECTION ASSERTED` | `N/A … F-2/F-3 NO LONGER REACHABLE` |

Both fabrics, same kernel (`89c1754`), same app, comparably idle.

**The registered decision chain predicts a shutdown on OVS and it did not happen.** PREREG §2
traces the chain to `link_bandwidth_utilization_percent`, read straight off the wire by
`GraphTypes.hpp:92`, averaged over up+enabled edges by `types.cpp:411,427`, and compared against
`LOW_WATER_MARK = 0.40` at `energy_saving_app.cpp:911,926`. Measured on the OVS fabric during
the watch:

```
edges=40  with the field=40   min=0.0  median=0.0  max=0.0
```

**Zero on every edge**, far below the 0.40 mark, for eight consecutive app cycles.

Corroborated independently — `ndt status` during and after: `10 up, 10 enabled, 0
admin-disabled, 40 links, 0 down`, and `apps energy` while it ran, so the app was up.

🔴 **The cause is NOT established.** Candidates not distinguished: the app's grouping may reject
these switches for a topology reason; the power loop is gated by `acquire_lock`
(`energy_saving_app.cpp:952`) and lock behaviour was not observed; the OVS path may differ
elsewhere. I could not read the app's own output — `ndtwin-lab energy-out` reports
`no energy session` while `ndt status` reports `apps energy`, the same instrument disagreement
this round already logged for `sim` and did not resolve. **One run per fabric is one run per
fabric**; this is an observation to open a ticket on, not a mechanism.

## The three messages

**1. The N/A offers a cause the measurement rules out.**

> *"on a network carrying traffic, declining to power down is correct … If you need them
> reachable, stop all traffic generation and re-run this phase."*

There was no traffic to stop. Utilisation was 0.0 on all 40 edges, and `flows` was empty
throughout the round. The suggested remedy is a no-op here, and the offered explanation is the
opposite of the measured condition.

🔑 The verdict itself is **right** — `unreachable`, not `fixed`, exactly the third branch
`R5-rerun-checklist.md` pre-registered for this case *("Energy-App powers nothing down this
round ⇒ the collision cannot occur")*. It is the **explanation attached to a correct verdict**
that is wrong, and that is the more dangerous kind: a reader takes the verdict on trust and
inherits the reason with it (`memory: investigation-briefs-separate-observation-from-inference`).

**2. "in 240s" was actually 474 s.**

`25_apps_energy.sh:157-165`:

```bash
WATCH_S=240
for i in $(seq 0 $(( WATCH_S / 10 ))); do
    … graph_counts …          # costs ~10 s on OVS, ~0 s on P4
    sleep 10
done
```

The query time is not counted. Measured: **25 samples spanning 474 s, mean interval 19.8 s**
against the 10 s the comment assumes. The comment states the intent exactly —

> *"240 s is four cycles: enough that 'nothing happened' is a statement about the app rather
> than about our patience"*

— and the implementation counts iterations, so the window is whatever the fabric's response
time makes it. Here it stretched (harmless: more chances to act, and the report understates its
own patience). On a faster path the same construct **shortens** it silently, and then
"nothing happened" is about our patience after all.

⇒ **Third instance in this harness of an iteration count standing in for a time.** The other two
are `FINDING-02`'s Defect A (`T_APP = T0 + i` for viz, te and sim). It is a house style, not a
slip.

**3. "THE FABRIC IS NOW DEGRADED" is printed unconditionally.**

```
🔴 THE FABRIC IS NOW DEGRADED. Run ./90_restore.sh before any further measurement.
```

printed immediately after the same script established `switches powered off by the app: 0`.
`ndt status` after the phase: `10 up, 0 admin-disabled, 40 links, 0 down`. **Nothing was
degraded.**

Harmless in isolation; not harmless in combination, because the restore it directs you to is
the one `FINDING-04` shows tears the fabric down and stops. **Following this instruction on an
undegraded OVS fabric would have destroyed a healthy fabric to fix nothing.**

## Repairs (not applied — instrument, mid-round)

* Gate the degraded banner on the count the script already computed.
* Drive the watch loop from a deadline (`end=$(( $(date +%s) + WATCH_S ))`) rather than an
  iteration count, and report the span it actually achieved.
* Make the N/A explanation conditional on the measured utilisation instead of asserting the
  traffic hypothesis.

## 🔴 Added after the round — the comparison was not controlled, and I am the reason

Both watches ran under `agy` jobs that my own commits launched (~2 cores each, invisible to
`ndt status`; full table in `CONTAMINATION-agy-runs-i-started-myself.md`):

| | agy overlap | outcome |
|---|---|---|
| P4 watch (250 s) | **two** concurrent runs, ≈174 s of it | 3 switches off |
| OVS watch (474 s) | **three** across its opening minutes | 0 switches off |

CPU contention is therefore **a live alternative explanation** for the difference, and it was
heavier on the arm that did nothing.

It does not explain the difference away — the P4 arm powered three switches off *while* two
`agy` runs were going, so the app is not simply starved by load. But **this is no longer a
controlled comparison**, and the confound is one I created without knowing it.

⇒ The observation stands as *a thing that happened*; it does **not** stand as *P4 and OVS
differ*. The ticket below keeps its question and loses its cleanliness. Its re-run must have
**zero commits in the window** — now the standing rule regardless.

## Ticket this earns

**"Why does the Energy-App power switches down on P4 and not on OVS, given identical
zero utilisation?"** — with the caveat that both arms are n=1 and the app's own log was not
readable. Reaching it needs the `ndtwin-lab` / `ndt` session-visibility disagreement resolved
first, because that is what blocks reading the app's reasoning.

[Co-developed with claude code -- Adam]
