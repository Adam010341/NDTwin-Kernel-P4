# Figures — sampling rate and CPU (2026-08-20)

**Status:** DONE — five figures render from committed data.

Task: produce presentation figures from today's measurement data into
`/home/adam/Desktop/NDTwin slide material 827/figures/`, with a reproducible
script at `doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py`.

House style copied from `doc/audit/2026-08-19_p4-sflow-accuracy/plot_figures.py`
(not modified).

## Running log

- [x] Read 08-19 plot_figures.py for house style
- [x] Read REPORT.md, compare.py, measure.sh, cpu_probe.py, cpu_report.py
- [x] Compute stats independently (discard first 6 s of every trace)
- [x] Figure 1 page_sampling-tradeoff.png
- [x] Figure 2 page_where-the-cpu-goes.png
- [x] Figure 3 page_iperf-competes.png
- [x] Figure 4 page_api-concurrency-envelope.png
- [x] Figure 5 page_matrix-decomposition.png
- [x] Visually inspect every PNG

## Computed vs REPORT.md

### Telemetry (trim = 6 s) — EXACT MATCH on every cell of REPORT §1

| rate | quantum Mbit/s | λ/1s | Fano | sd/mean | 1/√λ | twin/truth |
|---|---|---|---|---|---|---|
| 1/256 | 2.9532 | 69.6 | 0.88 | 11.2% | 12.0% | 1.001 |
| 1/128 | 1.4766 | 139.1 | 0.88 | 7.9% | 8.5% | 1.000 |
| 1/64 | 0.7383 | 278.0 | 1.05 | 6.1% | 6.0% | 0.999 |

Quantum is exactly `N × 1442 B × 8` at all three rates (1442 = 1400 payload + 42 header).
Busiest edge `s5-eth2` in all three; ground truth 205.4 Mbit/s on the wire vs 200.0 Mbit/s
application bits. Ratios vs 1/256: quantum 2.00×/4.00× finer, λ 2.00×/3.99×, dispersion
1.41×/1.83× tighter (√ predicts 1.41×/2.00×). `trunc128` and `noclone`: twin sum is
**literally 0** across all 32 edges × 1176 post-trim rows, while the path really carried
205 Mbit/s.

### CPU — see disagreement 1 below

## Disagreements / findings

**1. REPORT.md applies the 6 s trim in §2 but NOT in §1 or §4.** Reproduced exactly, both ways:

| condition | trim | bmv2 | kernel | proxy | matches |
|---|---|---|---|---|---|
| 1/256 | none | 150.4 | 57.3 | 12.3 | **REPORT §1** |
| 1/256 | 6 s | 151.4 | 57.7 | 12.2 | — |
| 1/128 | none | 156.9 | 61.9 | 17.8 | **REPORT §1** |
| 1/128 | 6 s | 158.1 | 62.1 | 17.9 | — |
| 1/64 | none | 148.4 | 67.4 | 23.7 | **REPORT §1** |
| 1/64 | 6 s | 149.4 | 67.5 | 23.9 | **REPORT §2** |
| trunc128 | 6 s | 152.3 | 10.3 | 4.0 | **REPORT §2** |
| noclone | 6 s | 153.3 | 10.2 | 3.9 | **REPORT §2** |

So the same rate64 run is printed twice in REPORT.md with two different bmv2 numbers
(148.4 in §1, 149.4 in §2). §4's per-switch figures (51.8 / 52.1 / 44.8) are likewise
untrimmed; trimmed they are 52.1 / 52.5 / 45.1. Magnitude ≤ 1.2 points of one core — no
conclusion changes — but §1's table violates the report's own stated rule. **Figures use
the trimmed values throughout.**

**2. "iperf3 burns ~114% of a core" is a sum over three matched processes, not one.**
In rate256: one process at 100.6%, one at 13.1%, one at 0.0%. The 0.0% one is a wrapper
(`sudo`/`mnexec`, whose cmdline contains "iperf3", and `cpu_probe.TARGETS` tests "iperf"
before "mininet"). Role assignment from appearance time, which matches `measure.sh`
exactly: the 13.1% process is present at t=0 (the server is started *before* the pollers),
the other two appear at t=2.0 s (`sleep 2` then the client). So the **sender is 100.6%**
and the receiver 13.1%. The single largest process on the box is therefore the traffic
generator's sending side, at ~2× the busiest switch.

**3. One hop of the flow's path is outside the twin's monitored edge set.** tx counters
show the flow on `s1-eth1` (205.6), `s2-eth3` (205.3) and `s5-eth2` (205.4) Mbit/s.
`s2-eth3` is not one of the twin's 32 monitored edges (`s1..s4` contribute eth1–eth2,
`s5..s10` eth1–eth4). Not a figure; recorded because it bounds what "every link" can mean.
It does confirm the §4 claim independently: the three switches with CPU (bmv2-1/2/5) are
exactly the three switches carrying the flow.


**4. Compressing the traces broke `analyse_matrix.py` silently-ish, and it had been left broken.**
`ae9f12a` taught this directory's readers about `.gz`, but one site was missed: the cell-presence
test in `main()` was a bare `os.path.exists` on the *uncompressed* name, while the loader beside
it went through the gz-aware `_open()`. After the traces were committed `.gz`, every cell looked
absent and the script printed `no cells found -- has matrix.sh produced anything yet?` on a
complete 14-cell matrix. It does not raise and it does not print a wrong number, so the only
symptom is a script that appears to have nothing to analyse. Fixed by giving `_open()` a matching
`_exists()`; this is the third reader in two days broken by the same compression change, and all
three had the same shape — two code paths reading one piece of evidence.

**5. The matrix's intended intercept is not an intercept, and the real zero was never fitted.**
`mnone` was run under `NDTWIN_CLONE_DISABLE=1` to be the zero-sampling cell. The flag never took:
its twin trace holds 480,540,662,784 counter-units over 2,352 non-zero readings and it measures
**553.5 samples/s**, against 556.1 at 1/64 — it is a replicate of the 1/64 cell wearing a zero's
label, and its CPU agrees (67.7/60.0 vs 67.9/60.1). `plot_figures.py` had already caught this for
figure 2 and swapped in the cold-fabric `mzero` re-run; `analyse_matrix.py` had not, and was still
printing it as the `none` row *and* fitting through it. Both readers now agree, and the fit
excludes it (slope moves 1.1 µs/sample, so no conclusion turned on it).

Fitting the five genuine cells and then comparing against `mzero_nopoll` is what the round had
never done: **fit intercept 48.5%, measured zero 2.8%** — 45.6 points apart, 65× the 0.7-point
noise floor. The line is excellent inside 34.7–556.1 samples/s (largest residual 0.4) and wrong
outside it, so `206 µs/sample` is a marginal cost over that range and **not** a divisor for a
capacity. See the REPORT.md correction block for the withdrawn ceiling.

**6. `mzero_nopoll`'s iperf3 client.json is a stub of nulls, and the run is still good.**
`measure.sh`'s jq slimming path filters `.end.sum` and `.start.test_start` out of iperf3's JSON.
When iperf3 emits an error object instead of a result, both selectors yield `null` and the path
writes a *well-formed* 76-byte file of nulls, discarding the error text — so a reader that checks
the file parses sees nothing wrong, and `is_complete()` rejects the cell as half-written. The run
itself is intact: the `/proc/net/dev` counters in the twin trace, which are independent of both
iperf3 and the kernel, put 205.9 Mbit/s on s1-eth1, s2-eth3 and s5-eth2 over the full 293.8 s —
the same three hops at the same rate as every other cell. Offered load for that cell is therefore
taken from the counters.

**Fixed**, because the n=3 top-up Adam ordered re-runs this exact cell. The branch moved out of
`measure.sh` into `slim_client_json.sh` — measure.sh and `tests/shell/test_slim_client_json.sh`
now drive one code path, rather than the test re-implementing what it tests, which is the same
mistake as items 4 and 5. A result slims and exits 0; an error object, a truncated file, or an
explicit `"sum": null` is kept verbatim and exits 3 with the error text on stderr.

The mechanism is pinned rather than merely plausible: piping an iperf3 error object through the
*old* filter reproduces the committed `mzero_nopoll_client.json` **byte for byte**, and the test
asserts that it still does — if that ever stops matching, the story behind the fix is wrong.
Mutation gate: reverting to always-slim fails 6 of 12 checks, dropping `jq -e` fails 4.

**7. The poll-off arm cannot verify its own zero, so the inheritance is checked.**
`netdev_only.py` records tx counters and no twin readings at all, so `mzero_nopoll` has no
telemetry of its own to confirm as zero — it inherits that from `mzero_poll`, the poll-on arm of
the same cold-fabric run, exactly as the matrix's poll-off cells inherit their sample rate. The
check: the two arms must differ by the polling cost and nothing else. They differ by **7.7
points**, against a matrix poll column spanning 6.3–8.0. `analyse_matrix.py` now prints this
rather than assuming it.

**8. The timeline the review session asked for, taken from the traces rather than from mtimes.**
The other session's `doc/audit/2026-08-20_lab-bringup-inventory/INVENTORY.md` §7.3 records their
`ndt check` pushing 606 Mbit/s through the fabric at ~16:08 and "spoiling one of their cells".
The epoch stamps *inside* the traces settle it, and they clear all of it:

| window | cells |
|---|---|
| 13:21–14:05 | single-factor sweep (`rate256`…`restore_check`) |
| **14:53:06 – 15:56:55** | **all 12 matrix cells**, back to back, 300 s each |
| 16:01:59 | their `ndt down` kills the kernel; 16:03:31 it is restarted |
| ~16:08 | their `ndt check` traffic |
| **16:45:07 – 16:55:11** | **the `mzero` pair** |

No surviving cell overlaps 16:05–16:12. The matrix finished four minutes before the first
collision, and the zero pair was re-run 37 minutes after the last one on a cold fabric with its
control verified before measuring. The spoiled cell was evidently a first attempt at the zero
point that was discarded and re-run — which is what `mzero` is. **Nothing in the fit is
contaminated**, and the timeline question blocking the raw-data commit is closed.

> ⚠️ **Correction.** An earlier draft of this item said mtimes could not settle the question
> "because gzipping rewrote every file at ~17:00". That is wrong, and the 開機手冊 session
> caught it: **gzip preserves the source file's mtime by default.** Checked across all 20
> `*_twin.jsonl.gz`, every one has an mtime equal to its own last `t` to within a second — so
> mtime is a perfectly good independent cross-check, and that is in fact how the other session
> verified this table.
>
> What misled me is that the two file types in `raw/` behave differently. The `.gz` traces kept
> their original mtimes; the **`client.json` files were rewritten in place at 16:53–16:55 by
> the retroactive jq slimming**, so *their* mtimes sit one to two hours after the runs they
> describe (`m1024_poll_client.json`: mtime 16:53:11, trace end 14:58:06). I saw that on the
> client files and generalised it to the directory.
>
> Using the in-trace `t` remains the right choice — it is what the data says about itself
> rather than what the filesystem says about the file — but the reason matters: believing
> mtime was destroyed would have thrown away a working cross-check for no reason.
>
> One detail worth keeping: `mzero_nopoll_client.json` has mtime 16:55:13, two seconds after
> its own trace ends. It was therefore written **live, as the null stub**, not produced later
> by the retroactive slimming — independent confirmation that the iperf3 failure happened
> during the run, which is what item 6 claims.
