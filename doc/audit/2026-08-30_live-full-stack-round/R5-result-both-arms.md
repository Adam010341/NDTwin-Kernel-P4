# R-5 — the 08-18 findings re-checked, both arms

PREREG §3 R-5 registers three outcomes per finding — **still present / fixed / no longer
reachable** — the third *"on purpose so a finding that merely became untestable is not scored
as fixed"*. `50_r5_ovs.sh` adds a fourth state the write-up must honour:

> **NOT RE-CHECKED** — no row was produced. Distinct from `unreachable`, and not to be folded
> into it.

Kernel `89c1754` throughout. P4 arm 15:25–15:36, OVS arm 15:52.

---

## Verdicts

| | P4 arm | OVS arm | **settled verdict** |
|---|---|---|---|
| **F-1** punt-rule diagnosed as a missing link | unreachable | unreachable | **NO LONGER REACHABLE — but for a reason worth reading** |
| **F-2** contract suite vs a correctly degraded network | **STILL PRESENT** | *(see below)* | **STILL PRESENT** |
| **F-3** schema vs the documented `-1` sentinel | **FIXED** | unreachable | **FIXED** |
| **F-4** stale comment from `04b8933` | **FIXED** | not re-checked (source-only, fabric-independent) | **FIXED** |
| **F-5** phantom rule | **STILL PRESENT** | **STILL PRESENT** | **STILL PRESENT, mechanism identified — `FINDING-03`** |
| **F-5b** the P4/OVS differential | present (P4 half) | present (OVS half) | **STILL PRESENT — differential now complete** |

## F-5b — the only finding that needed both arms, and it got them

F-5b is a *difference*, so one arm is half a finding. Both halves, same kernel, same endpoint,
same request shape, same `200`:

| | dispatch-failure lines in `kernel.log` |
|---|---|
| **P4** | **1**, first seen at +2 s |
| **OVS** | **0**, over 454 lines |

**Unchanged from 08-18.** Mechanism unchanged too: `Controller.cpp:55` detects failure by
finding an error *inside* a 200 body; the P4 proxy writes synchronously and puts the error
there, while Ryu's `/stats/flowentry/add` returns 200 before the switch has ruled and the
rejection arrives later as an `OFPErrorMsg` nothing listens for.

🔑 The caller-side statement of the same fact, which the OVS arm produced and 08-18 did not:
the kernel's own 200 says *"per-entry outcomes are reported in the kernel log, not in this
response"*, and **on OVS that log is empty**. The API tells the caller where to look and, on
this fabric, there is nothing there.

## F-1 — "unreachable" twice, and the two reasons are not the same

* **P4:** structural. There is no `OFPP_CONTROLLER` equivalent, so a reserved out-port cannot
  occur. The finding cannot fire on this fabric at all.
* **OVS:** contingent. *"The punt rules exist (2 on s1) and the code is unguarded, but no flow
  resolved to a reserved port during this run."* The defect is intact and simply did not fire.

The OVS row comes with the recipe to reach it: **send traffic with no specific forwarding rule
on some switch along its path**, so it falls to the prio-0 table-miss. That was not done,
because —

## 🔴 The single condition that limited this round: the network was quiet

`flows` was `[]` in **all 1800** R-2 samples. Three separate results are weakened by the same
fact, and they should be read together rather than as three independent shortfalls:

| result | how the quiet network limits it |
|---|---|
| **R-2** "no consumer-visible difference" | with no traffic the path set is static (one distinct value, 12 paths, 900 s), so 1 kHz and 1 Hz are **indistinguishable by construction** — see `R2-result.md` |
| **F-1** unreachable on OVS | nothing fell to the table-miss, so no punt occurred |
| **F-5** duration | the echo was gone by t=3 (OVS) / t=2 (P4) with nothing else in flight; whether traffic lengthens the window is untested |

⇒ **The most valuable single change to the next round is traffic.** Not more samples, not a
finer grid — a fabric that is doing something. `memory: assert-invariants-not-repro-rates` —
*when A/B cannot tell the arms apart, change the working point before increasing n.*

## What each verdict rests on, so none is over-read

* **F-3 FIXED** rests on `spec.py:502/507` reading `Num(min=-1, max=100)` **and** 9 keys
  carrying `-1` on a live degraded fabric — schema and wire, not one or the other. The script
  also notes that `get_temperature`'s `OneOf(Num(), Str())` **was never the F-3 site**, which is
  worth keeping: F-4 and F-3 concern different schema lines and are easy to conflate.
* **F-4 FIXED** was determined **before the round, from source, with no fabric**
  (`R5-rerun-checklist.md`), and the P4 arm confirmed it live. It is fabric-independent, so its
  absence from the OVS arm is "not re-checked", not a gap.
* **F-2 STILL PRESENT** rests on the contract suite reporting 8 `switch(es) not up` lines and 1
  `BROKEN` line against a network the Energy-App had **correctly** degraded — corroborated
  independently: every one of the 20 down edges was incident to a powered-off switch, so the
  twin's accounting was right and the suite's complaint was wrong. That is the original 08-18
  claim, unchanged.
* **F-5 / F-5b** are `FINDING-03` and the table above.

## Environment

Both arms ran the same pinned kernel; the running process was tied to the built binary by
dev+inode, not by path or mtime (`BASELINE-PROVENANCE.md`). The P4 arm's fabric was rebuilt by
hand after `90_restore.sh` failed both of its routes (`FINDING-04`).

[Co-developed with claude code -- Adam]
