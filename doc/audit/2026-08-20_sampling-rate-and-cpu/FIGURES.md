# Figures — sampling rate and CPU (2026-08-20)

**Status:** IN PROGRESS (stub created before any work; running log below)

Task: produce three presentation figures from today's measurement data into
`/home/adam/Desktop/NDTwin slide material 827/figures/`, with a reproducible
script at `doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py`.

House style copied from `doc/audit/2026-08-19_p4-sflow-accuracy/plot_figures.py`
(not modified).

## Running log

- [x] Read 08-19 plot_figures.py for house style
- [x] Read REPORT.md, compare.py, measure.sh, cpu_probe.py, cpu_report.py
- [x] Compute stats independently (discard first 6 s of every trace)
- [ ] Figure 1 page_sampling-tradeoff.png
- [ ] Figure 2 page_where-the-cpu-goes.png
- [ ] Figure 3 page_iperf-competes.png
- [ ] Visually inspect every PNG

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

