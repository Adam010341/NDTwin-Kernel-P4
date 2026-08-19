# Live full-stack round, 2026-08-18 — my own four rounds

Matrix actually run: **OVS × {NTG on, NTG off}** and **P4 × {NTG on, NTG off}**, all seven
reachable tools running (Web-GUI excluded — needs Node, not installed).

Kernel `04b8933`. Brought up and torn down entirely unattended via `ndtwin-lab`.

[Co-developed with claude code -- Adam]

---

## Findings, ranked

| # | finding | fabric | severity |
|---|---|---|---|
| **F-5 / F-5b** | A rejected flow rule returns `200 queued`, is shown as installed for ~8 s, then vanishes — **and on OVS nothing is logged at all**. P4 logs it correctly. | OVS (P4 clean) | **high** |
| **F-7** | A power off/on cycle **permanently strips TCLink htb shaping** from both ends of every affected link, while the twin keeps advertising the configured bandwidth | OVS | **high** |
| **F-2 / N-9** | Three separate test tools (L2 contract, L3 contract, log allowlist) turn red whenever the Energy-Saving-App correctly powers a switch down | both | medium |
| **F-6 / F-6b** | `faults.sh` default settle is 5 s against documented recoveries of 13.7 / 15.7 / 50.1 s — **fails on every topology on this machine** | both | medium |
| **F-8** | `twin_audit` silently runs at 2-of-3 quorum on P4 and reports the degraded run identically to a clean one | P4 | medium |
| **F-1** | A punt-to-controller rule (`OFPP_CONTROLLER` = 4294967293) is diagnosed as a missing topology link, sending the reader to the wrong file | OVS | low |
| **F-3 / F-4** | Contract schema says `Num(min=0,max=100)`; the doc, the GUI and the kernel all say `-1` means unavailable. Plus a stale comment `04b8933` left behind. | both | low |

**The single sharpest one is F-5b**, because it is a *differential*: same kernel, same
endpoint, same `200 queued` response, and the failure is caught on P4 and structurally
invisible on OVS. `Controller.cpp:55` detects failure by finding an error inside a 200 body;
the P4 proxy puts one there, Ryu's fire-and-forget `/stats/flowentry/add` cannot.

**This was predicted three weeks ago and never acted on.** `doc/2026-07-28_test_coverage_gaps.md`
§8 待辦 4, quoted in the 08-13 fault catalogue's C-1 row, says the kernel should report failure
rather than 200 and guesses the cause correctly ("curl fire-and-forget"). The catalogue calls
it 「最有價值也最容易做」.

---

## What was healthy

- Kernel log: **0 errors** across 16k lines on OVS; 1 error on P4 and it was my own test rule.
- `twin_audit`: 15 pairs / 0 contradictions on OVS under load **on a degraded network**;
  4 pairs / 0 contradictions on P4.
- Power off **and on** verified three times across both fabrics — the previously-broken
  power-on path is solid (10/10 bmv2, 138/138 and 14/14 nodes restored).
- `link_failure_detected` fired 20× correctly when switches went down.
- The `-1` telemetry sentinel from `04b8933` behaves **identically on both fabrics**.
- The replace-vs-add guard visibly working: `keeping the previous table rather than treating
  it as a switch with no rules`.
- L-3 gray failure (30 % loss) passes on OVS; valid flow install/delete round-trips cleanly
  on both fabrics.

---

## The pattern worth putting in the report

**Four of the seven findings are tests that call a healthy system broken** (F-2 ×3 tools,
F-6 ×2 fabrics, F-8's silent degradation, F-1's misdirecting message). Only F-5 and F-7 are
product defects.

That is a real result about the *test suite*, not the product: a suite that goes red when the
system behaves correctly trains its reader to discount red. Two of these (F-6, F-8) even have
the correct answer written down inside the very file that gets it wrong.

---

## Two self-corrections during the round

1. I read "twin claims 10/10 while three switches are missing from OVS" and nearly filed it.
   The 10/10 reading predated the Energy app's power-off by two minutes. Timestamps, not
   states.
2. Same trap on P4: "kernel omits dpids 5,7,9 but only s9 is off." A simultaneous four-way
   snapshot showed bmv2 procs, twin, kernel tables and proxy probes all agreeing — the app
   had powered off two more between my queries.

Both are the same mistake, twenty minutes apart, and the fix both times was to capture one
snapshot instead of two readings.
