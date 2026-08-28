# Which existing conclusions rest on measurements where the receiver may have been the bottleneck?

Assigned by `8/27 auditor` on 2026-08-28 after the jitter round found that
[`05_layer_attribution.md`](../2026-08-28_jitter-working-point/05_layer_attribution.md)'s packet
loss was happening in the receiving process's UDP socket, not anywhere in the network. Read-only:
nothing was rerun, no fabric was touched, every number below is quoted from data already on disk.

**[Co-developed with claude code -- Adam]**

## The criterion as assigned does not answer the question

The assigned test was "did that round read `RcvbufErrors`?", with anything else marked
*receiver not excluded*. Applied literally it gives one hit, `05_layer_attribution.md`, and marks
every other round unexcluded. That answer is wrong in both directions.

**False positives.** Two rounds excluded the receiver by *upstream* counters, which is stronger
evidence than a receiver-side error count, not weaker. A packet that never left the first switch
cannot have been dropped by the receiver, and no reading of `RcvbufErrors` is needed to say so.

**False negatives.** `RcvbufErrors` is a system-wide UDP counter. Each round has its own
receiver, and for most of them it is not iperf3: the 08-25 round's receiver is the kernel's sFlow
socket on :6343, and that round checked `/proc/net/udp` for exactly that socket — the right
instrument, and not `RcvbufErrors`. A round could also read `RcvbufErrors` diligently and learn
nothing, because the socket that mattered was somebody else's.

**The question the criterion is a proxy for:** *is the round's headline quantity read downstream
of a socket that could fill?* Interface counters, `tc -s qdisc` and switch-internal counters sit
upstream of every socket and are immune. Anything the receiving application reports — iperf3's
delivered rate and loss, the twin's sample count — is downstream and is not.

That reframing is what the table uses.

## Result

| round | headline quantity | read where | receiver |
|---|---|---|---|
| **08-15 bmv2 stock vs fast** (12–18×) | delivered rate, loss | iperf3 server side **but** loss localised at s1 | **excluded** — see below |
| **08-19 p4-sflow-accuracy** | sFlow sample rate vs spec | `tcpdump` on the wire at `lo:6343` | **excluded** — counted before the socket |
| **08-20 sampling-rate-and-cpu** | bmv2 CPU vs clone rate | `/proc/net/dev`, 200.0 Mbit/s at every rate | **excluded** — interface counters, and 200 Mbit is far below any receiver limit |
| **08-25 large-scale, telemetry −34%** | twin's reported edge usage | `/proc/net/udp:6343` drops 0 across 291 samples, `rx_queue` max 960 B | **excluded** — the right socket, checked |
| **08-25 N-1, OVS 53.142 Gbit/s** | per-link rate | **interface counters, explicitly not iperf3** (`n1.out:14`) | **excluded** — iperf3's own 220.96 Gbit/s was rejected as the less conservative reading |
| **08-22 loaded-fp-study** | false-positive count under load | event counts, not a rate | **not applicable** |
| **08-27 capacity-clamp** | twin usage clamped at declared capacity | source, four write sites | **not applicable** — a code fact |
| **08-28 QM mirrored block** (Q, M) | loop period, detection→path latency | kernel's own instrument, API polls | **not applicable** — no receiver in the path of the quantity |
| **08-28 jitter** | loss, CV | iperf3 receiver | **the finding itself** |

**No conclusion in this list is receiver-limited.** That is a stronger result than expected and it
is not because the rounds went looking for this failure mode — it is because most of them
measured at interface or switch counters for unrelated reasons, and those happen to sit upstream
of the socket.

## The 08-15 case the auditor singled out

> 📌 若收端是共同瓶頸，12–18× 是下界不是高估。

The reasoning is sound: a ceiling C common to both arms caps the faster arm first, so the observed
ratio understates the true one. The premise is false here, on two independent lines already in
[`doc/2026-08-15_bmv2-performance-report.md`](../../2026-08-15_bmv2-performance-report.md).

**1. Ninety-nine percent of the loss happened before the packets left the first switch.**
At 100 Mbit, h1 sent 89,296, `s1-eth3` received 89,296 with zero interface loss, and `s1-eth1`
transmitted 33,456; downstream s5 and s2 lost nothing of what survived. At 700 Mbit, s1 received
624,963 and forwarded 437,301, with ~0.2% per hop after that. Packets that were never transmitted
by s1 cannot have been dropped by a socket three hops later.

**2. The round measured its own receiver, at 1000× the rate in question.** The loopback control
h1→h1 ran at **42.4 Gbit/s** on the stock build and **63.5 Gbit/s** on fast, annotated in the
report as "host is never the bottleneck". The fast arm's ceiling is 460–530 Mbit/s. C is roughly
eighty times the quantity it would have had to cap.

⚠️ **Two limits on that exclusion, stated rather than smoothed.** The localisation was measured at
100 Mbit and 700 Mbit — the saturated regime of each arm, so it covers both headline numbers, but
not every rung of the ladder. And loopback does not traverse a veth pair, so 42.4 Gbit/s bounds
what the iperf3 *process* can drain from a socket — which is the mechanism the jitter round
identified — but not what the veth receive path can deliver. Both caveats leave a large margin.

⇒ **12–18× stands as measured. It is not a lower bound, because there was no common ceiling.**

## What this sweep did not do

- **Did not rerun anything.** Every figure is quoted from committed data or from a file on disk.
- **Did not open the 08-25 large-scale round's raw** beyond the `/proc/net/udp` lines quoted here.
- **Did not check pre-08-15 rounds.** The candidate list came from a grep for iperf/throughput
  prose across `doc/`, which returned 74 files; those are runbooks, plans and model reviews rather
  than measurement rounds with a rate conclusion. Rounds before 08-15 were not examined and are
  neither cleared nor flagged.
- **Did not verify that the 08-19 `tcpdump` count and the 08-25 `/proc/net/udp` reading were taken
  during the windows they are cited for.** Both are quoted at face value from their own reports.

## The reusable part

**Ask where the number is read, not whether a particular counter was recorded.** A round that
never heard of `RcvbufErrors` can be immune by construction, and a round that records it can still
be measuring the wrong socket. The two-line version, for a future round's PREREG:

> If the headline quantity is reported by the receiving application, name the socket and read its
> drop counter. If it is read from an interface, qdisc or switch counter, say so and the question
> is closed.
