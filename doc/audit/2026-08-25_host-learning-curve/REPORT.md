# Host-learning curve — the ring came back, and the dump finally caught it

[Co-developed with claude code -- Adam]

**Headline: 8 boots, zero healthy. The quiet arm wedged 4/4 — the ring, back after 24 hours of
being unsummonable — and the loaded arm failed the other way, 4/4. A live greenlet dump was
captured: 12 emitters in `_events_sem.acquire`, plus 51 REST handlers parked in an untimed
`reply_q.get()` inside Ryu's own `app_manager`.**

## What this round was for, and what it did not get

Designed to answer *when* the 128 host IPv4s appear, because the settle gate's own trace samples
every 10s and **stops at the deadline** — exactly where the arms diverge. Poll
`/v1.0/topology/hosts` every 2s from before Ryu answers until 120s after bring-up, loaded vs quiet
interleaved.

**It did not answer that question, because there were no healthy boots to draw a curve from.**
Every quiet boot wedged instead. That is a real result, but it is not the one the design targeted;
the learning-curve question is still open.

## Results — 8 boots, 4 pairs interleaved

| arm | n | outcome | wall | endpoint | hosts |
|---|---|---|---|---|---|
| **quiet** | **4/4** | **RING WEDGE** | 411–412s | dies mid-boot (`-1`) | never |
| **loaded** | **4/4** | flat zero, completes | 79–95s | answers throughout (`0`) | never |

Every quiet boot: `Switch entered:` **2** vs `connected (EventOFPStateChange)` **10** — the N-2
truncation signature, enter-handler only. Every boot in both arms: gate times out at `40s: 0/128`,
confirming again that the gate is a constant, not a variable.

### This reverses last night, on the same machine and commit

| | last night, uptime < 5 h | this morning, uptime ≈ 18 h |
|---|---|---|
| quiet | **8/8 healthy**, 52s | **4/4 wedged**, 411s |
| loaded | 8/8 flat-zero, 77–93s | 4/4 flat-zero, 79–95s |

**The loaded arm is unchanged. Only the quiet arm moved.** That is the third independent strike
against CPU contention as the ring's trigger — and note the direction is counter-intuitive: load
does not make the ring *more* likely, it appears to **substitute a different failure** that
completes in ~80s instead of hanging for 411s. Uptime remains the only covariate standing, now
with a far sharper contrast than the single reboot boundary that suggested it.

⚠️ Still a correlation. Two uptime points, one machine, no controlled manipulation.

## The dump — `7f7de4a`'s first capture of a live ring

`raw/wedge_111502_greenlets.txt`, 2537 lines, 94 greenlets. **Two distinct blocked populations:**

| n | frame | what it means |
|---|---|---|
| **12** | `send_event → _send_event → send_event_to_observers → _events_sem.acquire()` | event emitters blocked on the full 128-slot buffer — the ring's core |
| **51** | `send_request → req.reply_q.get()` @ `app_manager.py:279` | **NEW** — every request-reply caller parked forever awaiting the wedged app |

The **12** independently reproduces the review session's original count, on a different day, a
different boot session, and through a different instrument path. That is the strongest
corroboration the mechanism has.

The **51** is new and explains a symptom nothing had accounted for: `/v1.0/topology/links` returns
**HTTP 000**, not an empty body. Every WSGI worker is blocked in `reply_q.get()`, so the northbound
API surface is not merely empty — it is gone. This also sharpens
[[northbound-api-serialises]]: the serialised northbound path means one wedged app takes every
API caller with it.

🔴 **And note where it blocks.** `app_manager.py:279` is `return req.reply_q.get()` — an **untimed**
request-reply, in **Ryu's own library**, not our code. It is the identical shape to the gate call
`d1d973d` bounded on our side. We cannot fix it directly; anything that calls `send_request` into a
saturated app inherits an unbounded wait.

## The instrument was wrong three times, and it cost three wedges

`wedge_watch.sh` had to be rewritten three times, and **each version excluded the exact case it
existed to catch**:

| version | predicate | why it could never fire |
|---|---|---|
| v1 | links empty **AND** `switches` non-empty (as a liveness check) | on a wedge `switches` is empty too |
| v2 | links body `== "[]"` | during the wedge the endpoint **stops answering** — body is nothing, not `[]` |
| v3 | `HTTP != 200` **OR** body `== "[]"`, process confirmed alive | fired at 104 s: `links_http=000 body=<none>` |

`quiet_p1`, `quiet_p2` and `quiet_p3` all wedged while the instrument watched for the wrong thing.

The pattern, which belongs with the other measurement failures in `doc/audit/DEFECT-INVENTORY.md`:
**I kept encoding "what a healthy boot looks like, negated" instead of "what the failure actually
emits."** A wedged Ryu is process-alive with silent endpoints — neither healthy nor dead — and both
early predicates assumed it had to be one or the other. Same family as labelling the count
`SETTLE-HOSTS` and as reading 197-vs-93 as "more learning": **the measurement was built from a
model of the system rather than from the artefact the system produces.**

## Provenance

⚠️ `intelligent_router.py` was edited mid-run (R-1 applied, then reverted within ~2 minutes).
Boots 1–3 and 5–8 are certainly on `d19020b1`; `quiet_p2` is provenance-uncertain by inference
only. It wedged identically to the three certainly-clean quiet boots, so it does not carry the
result. Full account: `PROVENANCE-NOTE.md`.

## What to do next

1. **The ring is reproducible again, 4/4 on quiet boots.** This is the target that was missing for
   24 hours. `d1d973d` and `72fbae6` can finally be tested against it — that is the highest-value
   next run, and it is the one §5-P asked for originally.
2. **Do not tune settle.** The gate times out identically on every boot in both arms.
3. **The host-learning curve is still unmeasured.** It needs a healthy quiet boot, which this
   machine state no longer produces. Either catch one at low uptime, or accept that the question
   waits for a reboot.
