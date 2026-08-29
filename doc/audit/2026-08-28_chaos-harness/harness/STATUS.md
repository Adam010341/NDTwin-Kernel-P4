# Where the chaos harness got to — updated 2026-08-29 13:45, after its first live run

**The null round and the four positive controls have now been run live.** Full write-up, with
raw JSON for every run: [`../05_first-live-run.md`](../05_first-live-run.md).

Headline: the false-positive floor is **0** quiet and **0** under traffic — *after* **eleven**
defects were removed from the harness. On the first run it was **1**, and that violation was a
fabricated claim about NDTwin (`switch_flags` could not tell a host from a switch). Of the four
controls, **one fires**; one is mis-paired, one was never implemented, and one had never
executed a single line against the system while its own G2 check reported success.

⚠️ The count says eleven, not the nine first reported. H-10 and H-11 arrived after the write-up
was filed — one of them found by a sibling session asking a one-line question the whole run's
evidence could not answer, and one found by the mutation test written for the fix to it.

**G1 is still unmet — 1 of 7 invariants has a control demonstrated to fire — so `--full` still
refuses, by design.** Any PASS from an invariant other than INV-06 remains unbacked.

---

## `04_harness-spec.md`, clause by clause

| clause | state | note |
| :--- | :--- | :--- |
| **§0 G1** — every invariant needs a positive control, *and you must have watched it fire* | 🔴 **NOT MET, 1 of 7** | Only **INV-06 has fired**. G1-01 fixed but never run (destructive, undo unproven); G1-04 not implemented; G1-07 mis-paired with an invariant B-3 cannot turn red; INV-02/03/05 have no control. 🔑 The gate itself was rewritten: it used to verify the *control* and print "FIRED" without ever running the *invariant* |
| **§0 G2** — every injection asserts its own success | ⚠️ done, two defects found live | every `Action` carries `verify()`. But `_c01_verify` judged on latency alone and scored an **unrouted request** as a reproduction, and `_c06_verify` **repaired the fault it had just confirmed**, so the invariant saw a healthy system. Both fixed |
| **§0 G3** — claim the lab, `exclusive_cpu=yes` | ✅ done, **two** bugs fixed | reads `ndt status` (for `measuring`), not the claim file. Fail-closed when `--owner` is absent; and it now runs `ndt status` **under the identity in `--owner`** — it previously passed only because this session never exported `NDT_OWNER`, and would have refused the lab's rightful owner for following the documented protocol |
| **§1 must-fix 1** — `pgrep -cf 'simple_switch_g[r]pc'` | ✅ done | `probes.bmv2_process_count`, with why `-a` matches nothing and why `-xf` is worse |
| **§1 must-fix 2** — delete INV-08's monotonicity half | ✅ done | deleted with the reasoning kept; the underflow half survives |
| **§2** — CPU anti-oracle | ⚠️ implemented, **never calibrated** | `CpuGate`, `/proc/stat` busy fraction, +0.15 → `INCONCLUSIVE-CPU`. 🔑 Measured 2026-08-29: **one iperf3 alone moves busy fraction 0.045 → 0.33–0.39**, so the inherited 0.15 is exceeded by ordinary traffic before any chaos. Calibration deferred; start from that number, not from 0.15 |
| **§3** — narrow the three over-firing invariants | ⚠️ mostly, **a fourth found live** | INV-02 → the specific `up=true,en=false`; INV-04 → 196/√c tolerance, no verdict below 3 Mbit/s, clamp handled first; INV-05 → `path` from `get_detected_flow_data`, 5 s settle. 🔴 **INV-07 also over-fired**: its "quiet window" precondition was enforced nowhere, so it reported zombie entries on a healthy fabric whenever traffic was flowing — which is every injection round. Now checks the wire and returns SKIPPED when busy |
| **§4** — five testbed-destroying actions | ⚠️ mostly, one gap closed | kill-by-recorded-pid only; `tc netem` not `ifconfig down`; no tcpdump; every shell-out timed out. **Proxy restart is not implemented at all.** 🔴 G1-01 was destructive with **no undo**, for a sequence the kernel source documents as non-recovering (`P4PowerStrategy.cpp:100-114`); it now has one, and sits behind `--allow-poweroff` because that undo is still unproven against a switch that is actually off |
| **§5.1** — null round first, its violations are the false-positive floor | ✅ **RUN** | floor = **0** quiet, **0** under traffic, 7 of 8 invariants reaching a verdict. First run gave 1, and it was fabricated |
| **§5.2** — dry run for every destructive action, and that mode must be exercised | ✅ done and **exercised** | 2026-08-29; also all three G3 refuse branches |
| **§5.3** — verdicts on state, never on rc/HTTP status | ✅ structural | `probes.api_get` does not return the status code, so a caller cannot use it by accident |
| **§6** — coverage boundaries stated | ✅ done | in `README.md` |

## `01`'s action table: 3 of ~50 implemented

Only **H5** (malformed lock body), **H23** (empty path publish, must be refused) and a
`tc netem` link blackhole. Everything else in §8.1–§8.5 is unimplemented. The deliberate
exclusions with reasons — H13/H15/H16 live shell injection, H17 `/etc/exports`, §8.4 lifecycle,
N-1 NTP step — are in the comment block at the foot of `actions.py`. **The rest are simply not
done yet**, which is a different thing from excluded, and should not be read as covered.

## The defects this build found in itself

Eleven. Full account in [`../05_first-live-run.md`](../05_first-live-run.md); the short list,
because §5 predicted exactly this and the pattern is the useful part:

| | defect | why it survived |
| :--- | :--- | :--- |
| H-1 | `switch_flags` counted 128 hosts (all `dpid: 0`) as one extra switch | the error had **the exact shape of INV-01's finding**, and was constant, so the invariant had no resolving power at all |
| H-2 | G1 verified the *control* and printed **"FIRED"**, never running the *invariant* | "if the invariant were deleted, would this gate go red?" — no |
| H-3 | G1-01 sent GET to a POST route with `dpid` to an `ip`-keyed handler: **it never touched the system**, for the whole build | A-1's signature is "success, suspiciously fast"; an **unrouted request is also fast**, so its own G2 scored 0.0069 s as a reproduction |
| H-4 | that same control had **no undo**, for a sequence the source documents as non-recovering | destructive-ness was noted in prose, not encoded |
| H-5 | `gate_g3_claim` worked only because `NDT_OWNER` was unset | it would have **refused the lab's rightful owner** for following `ndt`'s own documented protocol |
| H-6a | my G1 rewrite took the baseline **after** the fault | caught on the first live run: a control inherited a failure it had caused |
| H-6b | `_c06_verify` **repaired** the fault it had just confirmed | the invariant then found a healthy system and was reported as blind |
| H-7 | INV-07's "quiet window" precondition was **enforced nowhere** | it fails on a healthy fabric under traffic — i.e. in **every** injection round, a false positive aligned with the treatment |
| H-8 | G1-04 was counted as "written" but its live branch always refused | a tally of 4 where 3 could fire |
| H-9 | G1-07 reproduces B-3 against INV-07, which measures a different subsystem | the control **works**; it is the pairing that is wrong, so nothing ever errored |
| H-10 | my `_c01_undo` printed `🔴 s1 NOT RECOVERED` on a healthy fabric | its success test could not tell "repaired" from "nothing needed repairing" |
| H-11 | **no artefact named the binary it measured** | `ndt status` and argv both said `bmv2-fast`, but the JSON recorded neither and my pre-state `awk` stripped the path; by the time a sibling asked, the fabric had been rebuilt and those pids were gone |

🔑 The oldest lessons recurred verbatim: **"a claim exists" ≠ "the claim is mine"** (H-5, second
time in this one gate); **an instrument must not share its finding's shape** (H-1, H-3);
**name the binary you measured** (H-11); and **a harness's cwd hides a class of defect** — the
mutation test for H-11's fix immediately caught the fix itself skipping its cross-check when run
from `harness/`.

## Next steps, in order

1. **Re-pair G1-07**, or write an invariant that B-3 can actually turn red. As it stands the
   control reproduces a real defect against an invariant about a different subsystem.
2. **Implement G1-04** on `traffic.sh`, which already drives ~1.1 Gbit/s past a link declared at
   1 Gbps — that *is* the clamp condition.
3. **Run G1-01 with `--allow-poweroff`**, but only after designing a restore tested against a
   switch that is genuinely off. The current undo has only ever met a healthy one.
4. **Build controls for INV-02, INV-03, INV-05.** Each needs a restore path that has itself been
   tested, because each mutates live state (wedged poll / ghost rule / prefix blackhole).
5. **Calibrate the CPU threshold** starting from the measured 0.33–0.39 under one iperf3, not
   from the inherited 0.15.
6. Then widen `01`'s action coverage.

## Related, already on disk

| | |
| :--- | :--- |
| `../../2026-08-28_manual-verification-coverage/GENERATING-TRAFFIC.md` | the "both branches spell pass" finding |
| `../../2026-08-28_manual-verification-coverage/COVERAGE.md` | updated, incl. the pickup note |
| `/mnt/win/ndtwin-vm/{guest,test}_sections_1_5.sh` | §1–§5 replay, syntax-checked and dry-tested, never run |
| `~/NDTwin-Website` `f17d2c5` | User Manual fix — **local, do not push** (Adam: publish only when testing is complete) |
| `../2026-08-28_QM-mirrored-block/plot_deck_903_round2.py` | still modified, uncommitted |
| `../05_first-live-run.md` | **the write-up of this run** |
| `../raw/` | every run's JSON, plus pre/post fabric state |
| `test_probes.py` | parser self-test — offline, runs against a captured payload |
| `traffic.sh` | asserted traffic generator; what G1-04 needs |

[Co-developed with claude code -- Adam]
