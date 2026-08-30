# T-4 — live full-stack round #2, 2026-08-30 — index

Kernel under test: **`89c1754`**, built in a detached worktree, identified backwards on four
axes. PREREG registered `faffdbe`; `89c1754`'s source is byte-identical to it across `src/`,
`include/`, `p4_proxy/` and `tests/`. **Quote the measured commit, not the registered one.**

Read in this order.

---

## Before anything else

| file | what it settles |
|---|---|
| [`PREREG.md`](PREREG.md) | what was registered, and `AMENDMENT-1` (three premises corrected **before** data) |
| [`BASELINE-PROVENANCE.md`](BASELINE-PROVENANCE.md) | why a worktree was necessary, and how the binary is identified **from itself** — the load-bearing axis is the absence of the T-7 fix inside it |
| [`CONTAMINATION-agy-runs-i-started-myself.md`](CONTAMINATION-agy-runs-i-started-myself.md) | 🔴 **ten `agy` runs inside the measurement window, all mine.** Read before quoting any number from this round |

## Results

| file | verdict |
|---|---|
| [`PRE-ROUND-R1-determination.md`](PRE-ROUND-R1-determination.md) | **R-1 UNTESTABLE** — the registered null branch, determined before the round and confirmed live |
| [`R2-result.md`](R2-result.md) | **R-2 confirmed, and nearly unfalsifiable** — a quiet network makes 1 kHz and 1 Hz indistinguishable |
| [`R5-rerun-checklist.md`](R5-rerun-checklist.md) | the three branches per finding, written before the round; F-4 determined there from source |
| [`R5-result-both-arms.md`](R5-result-both-arms.md) | **R-5, all six, both arms.** F-5b's differential is complete |
| [`FINDINGS-T6-developer-manual-api-page.md`](FINDINGS-T6-developer-manual-api-page.md) | **T-6** — 29/29 documented endpoints correct; 12 of 41 routes undocumented |

## Findings

| | class | one line |
|---|---|---|
| [`FINDING-01`](FINDING-01_model-matches-fabric-cannot-fail.md) | `ndt` | "model matches fabric" compares the model to the model — it never reads the fabric → **T-8** |
| [`FINDING-02`](FINDING-02_r3-convergence-table-measures-the-harness.md) | harness | three of R-3's four numbers are the harness timing itself; `port_holder` cannot see a root-owned listener → **T-9, T-10** |
| [`FINDING-03`](FINDING-03_p4-phantom-is-the-request-echoed-back.md) | **system** | the kernel serves a queued-but-unprogrammed request as a table row, **on both fabrics** — and 08-18 missed it because its first sample was at t=2 |
| [`FINDING-04`](FINDING-04_neither-restore-route-restores.md) | harness | neither restore route restores; `--rebuild` tears the fabric down and stops → **T-10** |
| [`FINDING-05`](FINDING-05_energy-declined-on-ovs-and-three-messages-that-did-not-match.md) | app + harness | Energy-App acted on P4 and not on OVS — **confounded, see the contamination record** |

**FINDING-03 is the only one about the system.** Four of five are about the instruments, which is
what the harness README predicted of its own first run.

## Raw

`raw/20260830-t4-p4/` (P4 arm) and `raw/20260830-t4-ovs/` (OVS arm). Notable:
`binary-provenance.txt`, `artifact-baseline.txt` (H-20 signatures), `r5_verdicts.tsv`
(append-only — **later rows supersede earlier ones**), `mismatch-evidence/` (FINDING-01),
`covariate_maven_build.txt`, `t6_probes/`.

---

## The one sentence to carry forward

**The round ran on a network with no traffic, and that single condition weakened three separate
results** — R-2 could not have failed, F-1 never fired, and F-5's window had nothing to compete
with. The most valuable change to the next round is **traffic**, not more samples and not a
finer grid.

## Standing rules this round produced

1. **No `git commit` anywhere in this repo during a measurement window.** `post-commit` launched
   `agy --effort high` (~2 cores, invisible to `ndt status`), and `--amend` fires it twice.
   *(The hook was disabled by Adam on 2026-08-30, after this round.)*
2. **`90_restore.sh` cannot restore.** Bring a degraded fabric back with `ndt down` then
   `ndt up <what>` by hand until T-10 lands.
3. `p4_proxy/mininet/host_count_override` is **tracked**, and `ndt up` rewrites it. Check it
   before committing anything under `p4_proxy/`.

[Co-developed with claude code -- Adam]
