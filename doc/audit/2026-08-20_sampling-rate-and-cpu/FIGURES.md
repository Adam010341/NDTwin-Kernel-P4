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

**9. The zero point is n=3 and holds to 0.03 points.** Adam ruled the `mzero` pair should be
repeated (overriding the previous session's "no n=3" judgement, which had been written into
the state file as settled when it was one session's opinion). Three cold-fabric runs, each
with the control verified *before* measuring: kernel poll-off **2.84 / 2.92 / 2.92** (mean
2.89, sd 0.03, range 0.07 — ten times tighter than the 0.7-point noise floor it argues
against). Poll-on repeats as tightly (10.57/10.43/10.25), putting the polling cost at 7.53
points, inside the matrix's own 6.3–8.0 column. Both readers and the decomposition figure now
quote the n=3 mean. All four iperf3 runs produced real result blocks — the c9f3c57 slimming
fix was not needed, which is the good outcome.

**10. Same-fabric A/B against the 28b8b13 fork point: the reading dispersion is inherited.**
The professor's question — is the twin's sFlow jitter original or ours? — answered on one OVS
128-host fabric, one traffic run per arm, one analysis (`analyse_jitter_ab.py`), only the
kernel binary swapped. Verdict: **both kernels sit on the sampling floor.**

| arm | sd/mean (two carrying edges) | floor 100/√λ | ratio |
|---|---|---|---|
| HEAD (`ovsjit_head`) | 12.7% / 12.5% | 11.9% / 12.0% | **1.06 / 1.05** |
| 28b8b13 (`ovsjit_base`) | 11.8% / 12.2% | 12.0% | **0.98 / 1.02** |

Mean ratio-to-floor 1.05 vs 1.00 — a 0.05 difference, deep inside noise. Neither kernel adds
avoidable noise and neither smooths (a ratio well below 1 would have meant variance hidden
behind lag). Corroborates the static evidence: the counter-report rate block, including its
1-second averaging window, is byte-identical across the fork; the kernel topology model
(`StaticNetworkTopologyMininet_10Switches.json`) is byte-identical too, so both arms modelled
the same 288 edges. Provenance: arm A's cpu trace holds exactly `kernel:1166963` (the pid ndt
logged), arm B's exactly `kernel:1169447` (child of the driver's logged subshell 1169444 —
see item 11). λ ≈ 70 and q = 2.9614M in both arms: same traffic, same quantum.

Baseline build note: 28b8b13 needed one `CMakeLists.txt` line (`-Werror` → `-Wno-error`;
2026-04 code under today's GCC trips `warn_unused_result` on `system()` calls and a Boost
`maybe-uninitialized`). Warning semantics only — the generated code is unchanged, so the
comparison stands. Built Release in ~3.5 min; worktree at the session scratchpad's
`baseline-28b8b13/`.

Also inherited, confirmed while the arms ran: **F-1's fabricated health metrics** (`10 +
hash(ip) % 50`) are at 28b8b13 in three sites of `DeviceConfigurationAndPowerManager.cpp`
(lines 455/853/1110), and **the fully-serialised northbound API** (`net::io_context ioc{1}`)
is at 28b8b13 `main.cpp:119`. Neither is ours. And `s2-eth3` carries the flow but produces no
twin reading under *either* kernel — the monitored-edge-set gap (item 3) is inherited too.

**11. The stray-kernel trap, personally verified.** The A/B driver started the baseline with
`( cd … && printf '1\n2\n' | ./bin/ndtwin_kernel … ) &` and recorded `$!` — which is the
**subshell's** pid, not the kernel's. The cleanup killed the subshell; the kernel survived as
an orphan holding :8000. `ndt down`'s teardown assertion caught it (`:8000 still listening --
this stack did not start it`) and correctly refused to kill what it didn't start. Orphan
killed by hand; `ndt clean` verified green afterwards. Same shape as the 開機手冊 session's
`app_stop` bug from the same afternoon: the pid you recorded is the wrapper, not the target,
and "stop" plus "verify stopped" must interrogate the same process. Their warning ("claim 只
保護 ndt 的動詞，擋不住裸指令") predicted this within the hour.

**12. Data-plane jitter at zero sampling is now n=3, and run-to-run noise dwarfs any
sampling effect.** iperf3 receiver jitter with sampling fully off: **0.0116 / 0.0701 /
0.0078 ms** across the three replicates — a 9× spread at *identical* configuration. The
entire spread across a 16× sampling-rate sweep was 0.0100–0.0223 ms (2.2×). So the earlier
conclusion ("no measurable sampling effect on data-plane jitter") survives n=3 in the
strongest possible form: the effect of sampling, if any, is far below the run-to-run noise of
the measurement itself. Loss tells the same story (0.074–0.393% at zero vs 0.29–0.76% across
the sweep).

**13. 🔴 Correction to items 10 and 3: the "monitored-edge gap" is the recorder's filter, not
the twin's.** Item 10 claimed s2-eth3 "carries the flow and produces no twin reading under
either kernel — the monitored-edge-set gap is inherited." The 開機手冊 session challenged the
attribution and is right. The decisive line is in our own poller, `2026-08-18_live-full-stack-
round/run.py:63`: the twin dict keeps an edge only `if e["src_dpid"] in SW and e["dst_dpid"]
in SW` — and the kernel graph classifies s2-eth3 as host-facing (`dst_dpid=0`), so the
recorder drops it before anything is written. "No twin reading in the trace" is therefore a
statement about the recorder, and its being identical under both kernels carries zero
information about either. Meanwhile that session measured the kernel live on P4: **s2-eth3
carrying 206 Mbit/s, twin reporting 215.6 Mbit/s** — the kernel reads the edge fine.

What survives, precisely: the A/B verdict (item 10's table) is untouched — it was computed on
the two edges that *were* recorded, identically filtered in both arms. Item 3's numbers stand,
but its framing ("not one of the twin's 32 monitored edges … bounds what 'every link' can
mean") inherits the same mis-attribution: the 32-edge set is what *these traces* recorded, not
what the twin monitors. The commit message of d50f8a1 carries the uncorrected sentence;
this item is the correction of record.

Two things worth keeping from the episode. First, the same filter shape produced the same
wrong conclusion twice in one evening, in two sessions, against two data planes — theirs in a
comparison tool, ours in the recorder — and both were caught only by reading the code that
built the evidence rather than the evidence itself. Second, a genuinely open residue: an edge
the kernel classifies as **host-facing** is carrying the inter-switch transit flow. Either the
model's edge classification or the fabric's wiring is not what the other believes — worth a
look in some future window (read `get_graph_data`'s edge for s2-eth3 against the Mininet topo
wiring). OVS-side kernel behaviour for such edges also remains unmeasured; next OVS window can
check it with one traffic run.
