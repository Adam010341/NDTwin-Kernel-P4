# Full-stack round, phase 1: the boot-convergence defect measured, localised, and given a testable mechanism

[Co-developed with claude code -- Adam]

Run 2026-08-24 at `79cd66a`+, review session (`review-0824`). Raw: `boot_rate.txt`,
`fail_probe.txt`, `wedge_spy.txt`, `raw/`. Drivers alongside. Diagnosis narrative:
`phase1_diagnosis_notes.md`.

## The rate (OBSERVED)

Ten OVS boots, plain defaults, no environment overrides, teardown between each:

**6 of 10 failed to converge.** Successes: boots 5, 7, 8, 10. Failures: 1, 2, 3, 4, 6, 9.

Every success converged in **58 s** (boot 8's wall reads 7626 s because the machine suspended
mid-run; its convergence is counted, its timing is discarded). Every failure sat unconverged
until `ndt`'s own give-up constant (~400 s wait + verify ≈ 414 s wall — **that figure measures
ndt, not the defect**; the failed state persists past it, see below). There is no intermediate
outcome. The 8/27 decision rule fires on this: near-3/5 arm → **the deck page carries no boot
number**.

Failure signature, identical all six times: `XX kernel: 10 switches, 0 up, 0 enabled`,
graph matches the model file, `h1 cannot reach 10.0.0.2`, kernel graph 288 edges / 288 down.

## The localisation ladder (OBSERVED, each rung from raw on disk)

1. **Not a switch-connect failure.** All six failing `ryu.log`s show
   `connected (EventOFPStateChange)` for all 10 dpids, and the t+300 waiter reports
   `10 of 10 switches online` before installing. Mid-wait `5 of 10` snapshots are transient
   (healthy boots show the same, e.g. `3 of 10` in `bisect_40_ryu.log`).
2. **Not an install failure.** The install message and `Loaded static topology` print on
   schedule — but `/ryu_server/all_destination_paths` stays 158 bytes (empty) for the whole
   boot, against 1,110,641 bytes healthy. The walk ran over a graph with no edges.
3. **Not an LLDP send/wire/punt failure.** Live probe of a caught failing fabric
   (`fail_probe.txt` attempt 3): the LLDP punt rule
   (`priority=65535, dl_type=0x88cc -> CONTROLLER`) is present on all 10 switches with
   counters **63–127 packets at t+~155 s and still rising 20 s later** (+6..+12). Healthy
   baseline: 38 pkts/150 s. LLDP is sent, arrives, and is punted to the controller
   continuously, on every switch, throughout the failure. `is_connected: true` 10/10.
4. **The Switches app stops consuming.** In all seven archived failing logs (six rate boots +
   the probe), `/v1.0/topology/switches` and `/links` complete **exactly 4 times each, the
   last ~6 s after Ryu start** — the moment of the connect burst — and never again (healthy:
   28, spread across the boot). Those endpoints are served by an event request-reply into the
   Switches app's queue. Endpoints that do not touch that queue (`all_destination_paths`
   served from IntelligentRyu's dict, `/stats/flow/*` from ofctl_rest) keep answering for the
   entire boot. The failure state **persists**: boot 1's log shows the kernel still receiving
   158-byte empty paths 7 minutes after Ryu start.

So: every switch connected, LLDP flowing and punted, and **the one component that turns
punted LLDP into links — the Switches app's event loop — permanently stops draining its queue
at connect time**, roughly one boot in two.

## The mechanism hypothesis (INFERRED — labelled as such; do not quote as established)

Two code facts (verified):

* `intelligent_router.py:1252` — IntelligentRyu observes `EventOFPPacketIn`, so **every punted
  LLDP is also queued to IntelligentRyu**. Its `EventOFPSwitchFeatures` (:545, table-miss
  install) and `EventSwitchEnter` (:592, the settle gate + switch waiter) share the same queue.
* `ryu/base/app_manager.py:160` — each app's queue is `hub.Queue(128)`, **bounded**; a `put`
  into a full queue blocks the emitter.

The cycle this enables: the enter handler blocks its own queue for
40 s (gate) + up-to-300 s (switch waiter); LLDP packet-ins flow into the blocked queue at
~2.5/s; **128 slots fill in ~50 s**; the next emitter to `send_event` into it blocks — and one
of those emitters is the **Switches app's own event-loop greenlet** (emitting
`EventSwitchEnter`/host events), which then stops consuming its own queue, which is where LLDP
processing and the topology REST replies live. The gate's `get_all_host()` polls are
request-replies into that same dead queue, closing the cycle.

What this hypothesis explains that nothing else has: (a) the bimodality — fast connects keep
the waiter at ~0 s and the handler exits before the queue fills; one slow straggler engages
the waiter and the fill wins the race; (b) why the 08-22 morning bisect went 11/11 healthy on
this same code — connects were fast that morning (52 s walls), and the failing boots' logs all
show the slow-connect `5 of 10` snapshot; (c) why *everything* topology-shaped dies at once at
t+6 s while wsgi, paths and stats survive; (d) why the failure is stable rather than
transient.

A prediction it made, since tested and **refuted along with the drain story**: the enter
chain never drains (the loop is parked *inside* one poll, see the frame verdict below), so
the "~12-minute self-heal via late `EventLinkAdd`" could not happen. Measured: a wedged boot
left untouched for **15 minutes never healed** (`wedge_usr2.txt`, `SELF-HEAL: no`) — no
timeout exists anywhere in the ring, and the OVS-side inactivity probe did not break it
either on that horizon. The failure is permanent, not slow.

**Decisive test in flight**: `wedge_spy.sh` catches one more failing boot and py-spy-dumps the
Ryu process in the wedged state. The hypothesis dies if the dumps show the Switches greenlet
somewhere other than a blocking queue put. Verdict: *pending — see below.*

## py-spy verdict (OBSERVED, `raw/spy3_dump{1,2}.txt`)

Two dumps of the wedged Ryu (pid 1828060), 10 s apart, are byte-identical: **one thread,
parked in the eventlet hub's epoll** (`do_poll/wait/run`). No greenlet was runnable at either
instant.

What this rules out: any busy-spin or hot-loop wedge — the process is asleep. What it adds:
LLDP packet-ins were arriving continuously at that moment (punt counters rising), yet the hub
idles — meaning **no greenlet is subscribed to those readable sockets**, which is what a
datapath receive greenlet blocked in a queue `put` (rather than parked on its socket) looks
like from the outside; unread sockets also explain how the switch-side counters keep rising
(the rule counts matches at the switch regardless of whether the controller drains the
connection) while `is_connected` stays true.

What it cannot do: name the parked frames — py-spy sees thread stacks, and parked greenlets
live on the heap. Frame-level confirmation needed an in-process greenlet dump; mainDev built
one (`7f7de4a`, SIGUSR2), and round 3 used it.

## Frame-level verdict (OBSERVED, `raw/usr2_attempt4_d{1,2}.txt`, wedged pid 1956414)

**The cycle is CONFIRMED — with one correction to the hypothesis.** The automated verdict
line in `wedge_usr2.txt` reads `greenlets blocked in queue put: 0` and is **misleading as
written**: Ryu's app buffer is a queue *plus a counting semaphore* (`app_manager.py:302
_send_event → self._events_sem.acquire()`), and a full buffer parks the emitter in
`semaphore.acquire`, not `queue.put`. My grep named the wrong primitive; the mechanism it was
testing for is exactly what the dump shows.

Twelve greenlets parked in `_events_sem.acquire()` — every one an emitter into
IntelligentRyu's full 128-slot buffer:

* **10 × datapath serve loops** (`self.ofp_brick.send_event_to_observers`) — one per switch
  connection, blocked dispatching packet-ins. This is why the OF sockets go unread, LLDP punt
  counters keep climbing switch-side, and `is_connected` stays true.
* **1 × `switches.py:975 link_loop`** emitting `EventLinkDelete`.
* **1 × the Switches app's own event loop** (`_event_loop` → `switches.py:818
  lldp_packet_in_handler` → emitting **`EventLinkAdd`**). **Link discovery did not fail — it
  succeeded, and wedged announcing its first link.** With its event loop parked here, the
  Switches app can never answer topology requests again, which is the t+6s REST silence.

And the other half of the ring: **IntelligentRyu's event loop** is inside the enter handler —
`get_topology_data → load_static_topology → _await_host_discovery → _hosts_with_ipv4 →
send_request → reply_q.get()` (`intelligent_router.py:795/1027/935/888`) — waiting, with no
timeout, for a reply from the Switches app that is parked on its semaphore. Neither side has
a timeout; the wait is circular and permanent. The gate's 40 s deadline never fires because
the deadline is checked between polls and the wedged boot never returns from *inside* one
poll.

Both outcomes of the boot race are now named: if the first `EventLinkAdd` (and the gate's
request-reply) beat the buffer filling, the boot converges in 58 s; if the buffer fills
first — 10 datapaths' packet-ins share 128 slots — every emitter parks and the ring closes.

## Phase 2: OVS end-to-end smoke (OBSERVED, `phase2_ovs_smoke.txt`)

On a converged boot (attempt 1, luck of the 40%):

* **404 regression series**: `get_path_switch_count` 10/10 × HTTP 200 at 12 s spacing,
  including the first query after boot. Consistent with P1-3's "intermittent by position" —
  the transient did not fire this boot; it remains established by P1-3's own series.
* **Northbound gate (Round-6 shape)**: baseline h1→h2 ok → install a priority-300 divert at
  s1 to h1's own port (deterministic dead end) → **ping breaks** (forwarding really changed)
  → delete → **ping restored** (no install-then-delete black hole). All four steps HTTP 200.
* **Failover drill at defaults**: netem 100% loss on s1-eth2 → link-down visible in Ryu's
  links after **52 s** (idle-defaults expectation ~45–50 s plus 1 s polling and REST
  propagation) → heal → links 32/32 again **5 s** after `tc del` → kernel graph 288/0.

## Phase 3: P4 smoke on the promoted default (OBSERVED, `phase3_p4_smoke.txt`)

* First `ndt up p4` through d12641f's refuse-not-fallback default: **boots**, and the live
  switch binary read from `/proc` is `/usr/local/bmv2-fast/bin/simple_switch_grpc` — ndt's
  own provenance check and this run's independent read agree.
* Twin health: 40 edges / 0 down (4-host P4).
* **Five-tuple regression**: `five_tuple_live.sh` rerun on this fresh fabric, exit 0 —
  install/override/counters/delete all repeat. (Its outputs write into the P2-5 evidence dir;
  rerun artifacts were copied to `raw/p3_ft_*` here and the committed originals restored via
  `git checkout` — the C-1 lesson, new variant: *a run-me script's output dir is its own
  evidence dir*, so a regression rerun overwrites the original run unless you archive+restore.)
* **sFlow liveness: inconclusive, honestly.** `get_detected_flow_data` read 0 bytes twice,
  but the probe used `curl -sf | wc -c`, which conflates "endpoint error" with "no data" —
  the same silent-extractor family this week keeps finding, here in this round's own script.
  A 4-host idle fabric also offers ~no traffic to sample. Needs a code-capturing recheck
  under load next P4 boot; not counted as a pass.

## Consequences (stand regardless of the mechanism verdict)

* Every OVS number this week — 52 s boot, the settle cliff, the after-fix 16.4 s — is
  **conditional on convergence**; mainDev has annotated the reports accordingly (`2642c98`,
  `a9ac3b3`).
* The defect predates nothing visible in the boot path's code history for the failing window;
  the discriminating variable between the immune morning and the failing afternoon looks
  environmental (connect latency), which the hypothesis turns from hand-waving into a
  measurable: **time-to-10-connects vs queue-fill time**.
* The settle gate's polling (request-reply into Switches from inside a blocked handler) and
  the 128-slot bound were each individually reasonable; the cycle is their composition. Any
  fix that keeps blocking work inside `EventSwitchEnter` keeps the cycle.
* **The settle *value* is exonerated** (mainDev asked for this measured by a non-author): the
  ring needs a blocking request-reply inside the enter handler and a full observer buffer —
  neither depends on how long the deadline is. 10→40 did not create this; the gate's
  *structure* did, in composition with 10 datapaths sharing 128 slots.
* `72fbae6`'s flag (`NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=1`, default off) moves the blocking
  work off the event loop — that severs the "IntelligentRyu's loop is stopped" edge, so the
  ring cannot close. Structurally the right edge to cut; live proof belongs to the fix round.
* The 404-transient (P1-3) and this defect are now clearly separate: the transient happens on
  *converged* boots (empty path map racing the first query), the ring on wedged ones.
