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
🔴 **SUPERSEDED by AMENDMENT-1 §8.3.** **No commits inside a measurement window.**

---

## 8. AMENDMENT-1 — four corrections, all before any arm

**Registered 2026-08-29 09:50 +0800 by `8/28 mainDev`, §8.1/§8.2/§8.3 directed by `8/28 auditor`,
§8.4 found while executing. Appended; nothing above is edited.**

**Approval conditions:** ✅ zero packets this round (`raw/` does not exist; the only traffic sent
is the 4 s topology probe in §8.1, which is a control, not an arm, and its result is recorded);
✅ reasons cite only pre-existing data (③'s AMENDMENT-3, ②'s FINDINGS §4, and the two binaries'
symbol tables); ✅ tightening only (adds two controls, removes one confound, narrows one claim).

### 8.1 🔴 The topology is NOT replaced. One hop comes from the host pair.

§5 says switching builds "destroys the warm 128-host fabric", which was read as *the round needs a
different, smaller topology*. **§3 does not say that** — it says "two hosts attached to the same
switch … the specific host pair is read from the topology JSON at run time".

⇒ **Keep the 128-host P4 topology. `ndt down` → swap the bmv2 binary → `ndt up`. Nothing else
changes.**

🔑 **This is not just cheaper, it is the correct control**: the topology is then *byte-identical*
between the two build arms. Swapping to a small topology would vary the build and the topology at
the same time, in a round whose entire purpose is to isolate the build.

**Host pair, established by measurement rather than by the JSON or by host numbering:** the
topology JSON gives every host `dpid: 0`, so host→switch attachment is not derivable from its
edges at all. A 4 s / 20 Mbit probe h1→h2 moved **exactly two switch interfaces** —
`s1-eth3` RX +7157 and `s1-eth4` TX +7157, delivered 20.0 Mbit/s at 0.0000% loss — and **no
interface on any other switch moved at all**.

⇒ **h1 → h2 (10.0.0.2) traverses one `simple_switch_grpc`.** Recorded in every arm meta. The probe
is repeated after the binary swap, because the topology is rebuilt by `ndt up` and "it was one hop
before" is not evidence about the fabric that actually runs the arms.

### 8.2 🔴 The control plane stays live, and this round isolates ONE variable

§1 binds two confounds into one phrase: "three-hop path **with a live control plane on it**".
Those are two variables, and going to one hop removes only the first.

⇒ **Registered: the control plane runs normally for every arm** — proxy installing routes, kernel
polling, sFlow clone enabled. Three reasons: (a) changing two things at once makes a shrunken R
unattributable; (b) the paper's claim is about the build *as deployed*, and a no-control-plane
ratio describes a configuration nobody runs; (c) **sFlow clone is per-packet work inside bmv2**, so
it is part of what "this build costs", not an external contaminant.

**Follow-up branch, registered now so H2 cannot become "we don't know what to write":**

> **If R lands in H2 (< 9)**, the next question is *path or control plane*, and that is **another
> round**. This round may not attribute the shortfall to either. **If R lands in H1 or H3**, the
> control-plane confound does not matter at this working point and the question closes.

### 8.3 The load gate is ②'s, not ③'s — and its positive control is re-run

③'s gate was shown to have no discriminating power (③ AMENDMENT-3). ② replaced it with the foreign
residual and **demonstrated it can fire** before trusting its silence. ① uses ②'s version verbatim:

> **external = total busy − Σ(utime+stime of the switch processes) − Σ(utime+stime of iperf3)**,
> sampled at 1 Hz from `/proc/<pid>/stat` with a **per-PID accumulator** (a snapshot sum over
> currently-alive iperf3 reads ~0, because each rep's processes exit before the next sample —
> that bug is on record in ②'s FINDINGS §4). Rerun any arm whose mean `external` exceeds the
> median arm's by more than 0.15 absolute.

🔴 **The positive control is re-run for this round, not inherited.** Swapping the binary changes
the subject under measurement; a control that fired against bmv2-fast is not evidence about a
fabric running stock. It runs once per build.

### 8.4 🔴 The registered negative control cannot test what this round identifies

§3 requires a negative control and names **`3367d0e9`**. That is an **`ndtwin_kernel`** binary, and
the symbol it answers *no* to is `kFlowPathRecomputeInterval` — a **kernel** symbol from the Q/M
ticket. **This round identifies a *bmv2 build*.** A kernel binary cannot be a negative control for
"is this switch fast or stock"; it would return no match for a reason that has nothing to do with
the question.

**The registered control was still run and is recorded** (it is a valid control for the *kernel*
identification that every arm meta also carries):

| kernel binary | `kFlowPathRecomputeInterval` hits | |
|---|---|---|
| `a40e04ce` (running) | **5** | positive |
| `ab2d7ed1` | 0 | |
| **`3367d0e9`** | **0** | ✅ **negative control passes** |

**The bmv2 build signature, with a control in both directions:**

| symbol (dynamic table) | `/usr/local/bmv2-fast/` (`3ff54b5c`) | `/usr/local/bin/` (`327fa7d1`) |
|---|---|---|
| **`EventLogger`** | **0** | **24** |

`EventLogger` maps directly onto the named build flag `--disable-elogger`, so the signature is tied
to the thing that differs rather than to an incidental artifact.

🔑 **Each binary is the other's negative control**, which is stronger than the one-directional
check §3 asked for: "is fast" = zero hits must *pass* on fast and *fail* on stock, and "is stock" =
nonzero hits must do the reverse. Both directions are asserted at every arm.

⚠️ **Two differences that must NOT be used as the signature**, recorded so nobody later mistakes
them for evidence: fast is 92,147,960 B with a full symbol table, stock is 9,576,568 B and
**stripped** (`nm -C` reports "no symbols"; only `nm -DC` works on it). That is packaging
provenance — locally built versus distribution binary — **not** optimisation flags, and reading it
as build evidence would be the mtime error in another costume.

### 8.5 ⚠️ The strongest form of binary provenance is not available to this uid

`/proc/<pid>/exe` is the kernel's own answer to "what is this process running" and cannot be spoofed
by argv. **It is unreadable here**: the switches run as root, and this uid has passwordless sudo
only for `mnexec`/`tc`/power/`ovs-vsctl`, not `readlink`.

⇒ **The binary is resolved from the process's `argv`** — what the launcher actually exec'd — and
cross-checked against `p4_proxy/mininet/bmv2_binary_override` as an independent second source.
**The two must agree or the arm aborts rather than picking one.** The `sha256` of the file at that
path is recorded per arm.

**What this is weaker than, stated plainly:** argv is the launcher's claim. If the *file* at that
path were replaced between launch and the symbol check, the check would read the new file while the
running process kept the old one. Nothing in this round replaces binaries mid-run, and the `sha256`
is recorded so a later reader can compare — but this is one notch below kernel-verified provenance
and must not be written up as if it were not.

**[Co-developed with claude code -- Adam]**
