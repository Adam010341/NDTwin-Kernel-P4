# Independent review of the experiments run after the 2026-08-19 report

2026-08-20. Adam asked a supervisor session to audit what `8/19 mainDev v2` had done since the
progress report, and to run an independent reviewer alongside it. This directory is the archive
of that round. [Co-developed with claude code -- Adam]

**Scope:** `cc249c8` (2026-08-19 21:06) .. `d34688d` (2026-08-20 15:31), eight commits, plus the
untracked 2x6 matrix still in flight at review time.

## What is here

| file | what it is |
|---|---|
| `REVIEW_muse-spark_experiments-since-0819.md` | Muse Spark 1.2 (contributor), read-only over the repo, 80-step tool loop. Six sections: inventory, material locations, method review, conclusion review, retractions, weakest link. Every claim labelled OBSERVED or INFERRED. |

The reviewed material itself lives in `doc/audit/2026-08-19_p4-sflow-accuracy/` (jitter
re-analysis) and `doc/audit/2026-08-20_sampling-rate-and-cpu/` (sampling rate and CPU).

## 🔴 Two things the reviewer got wrong — read before quoting it

Both were verified against the working tree by the supervisor session on 2026-08-20.

**1. "Figures are missing / unrendered" is a sandbox artefact, not a finding.** The reviewer
could only read under the repo root, and every figure in this project is written to
`~/Desktop/NDTwin Slide material/figures/` and `~/Desktop/NDTwin slide material 827/figures/`,
which are outside it. So §2's `✗ missing` on `page39_quantisation-ladder-load.png` and its
`◐ stub, not rendered` on the three `d34688d` figures are both false — all four exist.

⚠️ It was nonetheless pointing at something real: `METHOD_jitter-and-load.md:94` says the load
ladder "still prints the change-counted values and should be re-rendered before use". The figure
exists and is stale. That is a different defect from the one reported.

**2. The language check is false.** The reviewer states twice — §1 and §3 — that it grepped
Traditional Chinese terms across `doc/` and got "zero hits", concluding all evidence prose is
English. `grep -rl '實測\|推翻\|結論' doc/` matches 20 files, and the two in-scope documents
contain Chinese themselves (`AUDIT_jitter-method.md` 77 characters,
`METHOD_jitter-and-load.md` 63). The substantive cost here was low because those two files are
mostly English, but **every "evidence not found" verdict in this report should be discounted
accordingly.** This is the second recorded instance of the same blind spot.

## 🔴 What the review missed, and why it matters more than what it found

At 16:00 on 2026-08-20 — after this review was written — `mainDev v2` discovered that the
`noclone` A/B control in `7eb54d5` **never took effect**. A bare DELETE against clone-session
bookkeeping that a pipeline commit had already emptied is a no-op, and it cannot touch the
orphaned PRE multicast group that survives from the previous proxy generation. The mechanism was
already documented, from a live measurement four days earlier, in the docstring of the very
function involved (`p4_proxy/proxy_agent/p4_client.py:294-324`), which prescribes
`DELETE -> INSERT -> settle(DELETE+INSERT)`; the A/B path sent a bare DELETE and bypassed it.

The reviewer graded that experiment **PASS**, called it "the strongest inference in the suite",
and wrote a section arguing readers should attack something else first. The supervisor session
relayed that assessment. Both were wrong, and neither could have been right from documents
alone: the proxy logged `DELETED (A/B control)` ten times, zero errors, while deleting nothing.

**So the ordering of this round is the finding.** A 62 KB, well-cited, correctly-reasoned
document review picked a weakest link that survives scrutiny. Re-running one control cell on a
warm fabric destroyed a headline. See `doc/audit/README.md` on measured numbers, and the
existing record that live runs find what green suites cannot.

## Consequences for the figures

Checked by reading which conditions each figure function loads in
`doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py`:

| figure | reads | status |
|---|---|---|
| `page_sampling-tradeoff.png` | `rate256`, `rate128`, `rate64` only (`fig_tradeoff:186-187`) | ✅ unaffected — the sampling-rate sweep does not depend on the control |
| `page_iperf-competes.png` | `rate256` only (`fig_iperf:458-459`) | ✅ unaffected |
| `page_where-the-cpu-goes.png` | `rate64`, `trunc128`, **`noclone`** (`fig_where:338-341,365-366,397`) | 🔴 **invalid** — draws a bar labelled "no clone session at all" and computes on/off deltas from a control that did not fire |
| `page39_quantisation-ladder-load.png` | jitter traces | 🔴 **stale** — prints the pre-correction change-counted Fano values (`METHOD_jitter-and-load.md:94`) |

Adam ruled on 2026-08-20 that the **delivered slides are not to be changed** (the report has
already been given), but that **the figures must be corrected because they will be reused**.
