# Live-traffic round (full-stack #3) — index

2026-08-30, 20:23–21:56 CST. Three arms, kernel `1208d22`
(sha256 `66f437a56dd09a91311b7acf18b59ae07ff86e0e1e7f3bcfccd7724c69be0e42`).

**Start here: [RESULTS.md](RESULTS.md).**

[Co-developed with claude code -- Adam]

| file | what it holds |
|---|---|
| [PREREG.md](PREREG.md) | the pre-registration (`5cbd672`), written before any data. **Not edited by this round.** |
| [RESULTS.md](RESULTS.md) | provenance, traffic actually applied, TR-1…TR-6 verdicts, the harness defects found |
| [FINDING-06](FINDING-06_dispatch-is-a-10.7s-cycle-not-a-queue.md) | the install "exposure window" is a **10.70 s dispatch cycle**, not queue pressure. Answers TR-3. |
| [FINDING-07](FINDING-07_install-flow-entry-drops-the-priority.md) | `install_flow_entry` programs **every** rule at **priority 0** |
| [TR1-timing-4host.md](TR1-timing-4host.md) | R-2's timing half, answered on the fabric size where it is measurable |
| [COVARIATES-and-preflight-override.md](COVARIATES-and-preflight-override.md) | the one precondition that was not met, its measured size, and why the round ran anyway |

## Verdicts at a glance

| | verdict |
|---|---|
| TR-1 gate — is `flows` non-empty under traffic? | **HELD**, both fabrics (P4 8–12, OVS 8–13; `[]` when idle) |
| TR-1 timing — R-2 observable? | **No consumer-visible difference**, and the registered *reason* is wrong |
| TR-2 — F-1 punt path | **unreachable**: bypassed by proactive routing. Instrument-blindness refuted. Not "passed". |
| TR-3 — does the window grow under contention? | **No.** It is a 10.70 s clock (sd 0.05, n=4). |
| TR-4 — `contract_test` live | **39/39 PASS** (+52-check self-test). Discharges T-7b §0.0. |
| TR-5 — energy observation base | **NOT COLLECTED** — refused by the permission layer. A gap, not a pass. |
| TR-6 — the manual's 128-host example | **PASS**, and its "refuses to start on mismatch" claim forced red in both directions |

## What the next round should pick up

1. **TR-5's clean re-run is one authorisation away.** Conditions were finally right (no `agy`, zero
   in-window commits) and both prior runs were contaminated. See RESULTS.md → TR-5.
2. **Name the 10.70 s timer in the source.** FINDING-06 is measured behaviour; the constant has
   not been located.
3. **Find which layer drops the priority** (kernel southbound encoder / proxy `/stats/flowentry/add`
   / BMv2 table write). A source read, not a live run. FINDING-07.
4. **Three sub-second change intervals in the 4-host R-2 data are unexplained** and are the only
   part of that distribution inconsistent with its conclusion. TR1-timing-4host.md.
5. **`00_preflight.sh`'s qemu gate should read `-name` from `/proc/<pid>/cmdline`**, not attribute
   every qemu to the installation-manual VM.

## Raw

Raw artefacts are **gitignored on working branches by design** (`.gitignore:60`, enforced by
`tools/githooks/pre-commit`) and belong on the `audit-raw` orphan branch:
`raw/arm1-p4-128/` (56 MB, incl. `r2_samples.jsonl.gz` with full response bodies for 833 samples),
`raw/arm2-ovs/`, `raw/arm3-p4-4/` (incl. a second `r2_samples.jsonl.gz`, 1200 samples, 0 overruns),
`raw/build_arm1.log`.
