# PREREG — ① single-switch isolated working point: is 12–18× a property of the build or the path?

**Registered 2026-08-28 evening by `8/28 mainDev`, before any data. Assigned by `8/28 auditor` as P1-①.**
**[Co-developed with claude code -- Adam]**

---

## 1. The claim under test, and why the existing evidence cannot settle it

`doc/2026-08-15_bmv2-performance-report.md` reports bmv2-fast beating stock by 12–18×. Every one of
those numbers was measured on a **three-hop production stack** (`h1→h2`, `s1→s5→s2`, full pipeline,
proxy pushing routes, kernel polling, sFlow clone active).

⇒ The measurement cannot distinguish **"this build is 12–18× faster"** from **"this build is 12–18×
faster along a three-hop path with a live control plane on it"**. The claim we want to make in the
paper is the first one. Only the second one has been measured.

## 2. 🔴 "12–18×" is a range across *different metrics*, not a confidence interval

This has to be fixed before anything is compared, because it silently decides what a "matching"
result means. From that report's own table:

| quantity | stock | bmv2-fast | ratio |
|---|---|---|---|
| UDP zero-loss point (1400 B) | 25 Mbps | 300 Mbps | **12×** |
| UDP delivered ceiling | ~40–42 Mbps | ~460–530 Mbps | ~12–13× |
| 64 B small-packet delivered | 3,619 pps | 50,786 pps | **14×** |
| TCP single-flow goodput | 24.2 Mbps | 431.0 Mbps | **17.8×** |
| TCP 8 parallel flows | 24.2 Mbps | 435.7 Mbps | **18×** |
| idle RTT (3 hops) | 9.1 ms | 2.8 ms | 3.3× |

**The spread from 12 to 18 is the spread between UDP capacity and TCP goodput, not measurement
noise.** Quoting "12–18×" as though it were one quantity with an uncertainty is wrong, and
comparing an isolated result against the whole range would let almost any number "agree".

⇒ **Registered: this round measures the UDP zero-loss point and compares against 12× only.** It is
the same quantity ③'s ladder measures, so the two rounds are commensurable. The other rows are out
of scope and must not be used for reconciliation.

## 3. Design

- **One bmv2 switch, one hop.** Two hosts attached to the same switch, so the path traverses a
  single `simple_switch_grpc` process. The specific host pair is read from the topology JSON at
  run time and **recorded in the arm meta** — not assumed from host numbering.
- **Arms = the two builds.** `/usr/local/bmv2-fast/` vs stock. Everything else pinned: same
  topology, same ladder, same step length, same host pair, same loss threshold, same clean rule
  (AMENDMENT-2 11.1 from ③: any nonzero reading goes to three reps on the median; the reported top
  rung is re-confirmed at three).
- **Replication unit is the arm**, two arms per build minimum, interleaved `fast stock fast stock`
  and then mirrored, so drift cannot align with a build.
- **Ladder**: the ×1.5 ladder from ③, extended down to cover stock's expected ~25 Mbps region:
  `1 2 3 5 8 12 20 30 45 70 110 160 240 360`.

### Build identification is by symbol signature, never PATH

PATH does not answer which binary the fabric is running; that error is already on record. Build is
established by `pgrep -af 'simple_switch_g[r]pc'` (**no `-x`** — `-x` compares the whole command
line and reports any process with arguments as absent) plus the binary's own symbols.

🔴 **Negative control, required before the arms count.** `3367d0e9` answers *no* to both Q and M.
Running the signature check against it must return **no match**. Without a binary that should
answer no, "the signature matched" and "my grep is broken" are the same observation. This control
runs first and its result is recorded before any capacity arm.

## 4. Registered predictions — intervals, and a meaning for every outcome

Let **R** = (bmv2-fast UDP zero-loss point) ÷ (stock UDP zero-loss point), one hop, this round.

| outcome | interval | what it means — **registered now, not after seeing R** |
|---|---|---|
| **H1 — build property** | **R ∈ [9, 20]** | The 12× survives isolation. The paper may say "the build is ~12× faster", full stop. |
| 🔴 **H2 — partly the path** | **R < 9** | **A result, not a failed measurement.** Part of the reported ratio came from the three-hop path and the live control plane on it, not from the compiler flags. The main claim narrows to "12× along a three-hop production path", and the paper must say which. |
| 🔴 **H3 — the path was capping the fast build** | **R > 20** | Also a result. On three hops something other than bmv2 was limiting bmv2-fast, so 12× is a **lower bound** and the isolated figure is the honest one. |

The H1 interval is wide because it inherits the ladder's ±20% rung resolution on both sides of a
ratio: two rungs of resolution on a quotient is roughly ±45%, and 12 × 1.45 ≈ 17, 12 ÷ 1.45 ≈ 8.3.
**A derived quantity's tolerance must be at least as wide as the noise it inherits**, and a ratio
inherits it twice.

⇒ H2 and H3 are therefore not "H1 failed" — they are the two ways the sentence in the paper would
have to change, written down before the number exists.

## 5. Cost that must be paid deliberately

Switching builds means restarting the fabric. That **destroys the current binary identification**
and the warm 128-host fabric ③ is using. ⇒ **This round runs only after ③'s arms are complete**,
and re-establishes build identity from symbols at every arm rather than inheriting it.

## 6. Readouts

Both, every arm, same as ③ §5: iperf3 `sum_sent`/`sum_received`, and interface counters read as
**ingress-port RX against egress-port TX on the same switch** — 08-15 measured loss occurring
*inside* bmv2's input buffer, invisible to a per-interface drop counter (s1-eth3 RX 89,296 with
zero interface loss while s1-eth1 TX carried 33,456). On one hop this pairing is unambiguous, which
is a secondary reason the isolated topology is worth the teardown.

## 7. Load

The gate is ③'s AMENDMENT-2 11.2: in-window busy fraction from `/proc/stat` deltas, arm rerun if it
exceeds the median arm's by more than 0.15 absolute. `load1` recorded as a pre-screen only.
**No commits inside a measurement window.**
