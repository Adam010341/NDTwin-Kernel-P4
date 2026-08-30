# Live-traffic round (full-stack #3) — index

2026-08-30, 20:23–21:56 CST. Three arms, kernel `1208d22`
(sha256 `66f437a56dd09a91311b7acf18b59ae07ff86e0e1e7f3bcfccd7724c69be0e42`).

**Start here: [RESULTS.md](RESULTS.md).**

[Co-developed with claude code -- Adam]

| file | what it holds |
|---|---|
| [PREREG.md](PREREG.md) | the pre-registration (`5cbd672`), written before any data. **Not edited by this round.** |
| [RESULTS.md](RESULTS.md) | provenance, traffic actually applied, TR-1…TR-6 verdicts, the harness defects found |
| [FINDING-06](FINDING-06_dispatch-is-a-10.7s-cycle-not-a-queue.md) | 🔴 **corrected 22:10** — the kernel's table view is **blind for up to 10.70 s**; the rule is on the switch in ~20 ms. Answers TR-3. |
| [FINDING-07](FINDING-07_install-flow-entry-drops-the-priority.md) | 🔴 **corrected 23:00** — the API accepts a `priority` the **LPM** table it routes to has no column for. **No packet is misforwarded**; it is an API-contract defect, not a forwarding one. |
| [FINDING-08](FINDING-08_energy-app-locks-itself-out.md) | TR-5: the Energy-App locks itself out on cycle 1 and spins at 1 Hz; the watch reports 4 decision cycles when there was **one** |
| [TR1-timing-4host.md](TR1-timing-4host.md) | R-2's timing half, answered on the fabric size where it is measurable |
| [COVARIATES-and-preflight-override.md](COVARIATES-and-preflight-override.md) | the one precondition that was not met, its measured size, and why the round ran anyway |

## Verdicts at a glance

| | verdict |
|---|---|
| TR-1 gate — is `flows` non-empty under traffic? | **HELD**, both fabrics (P4 8–12, OVS 8–13; `[]` when idle) |
| TR-1 timing — R-2 observable? | **No consumer-visible difference**, and the registered *reason* is wrong |
| TR-2 — F-1 punt path | **unreachable**: bypassed by proactive routing. Instrument-blindness refuted. Not "passed". |
| TR-3 — does the window grow under contention? | **No.** 10.70 s clock (sd 0.05, n=4) — **of the view cache**, not of dispatch. |
| TR-4 — `contract_test` live | **39/39 PASS** (+52-check self-test). Discharges T-7b §0.0. |
| TR-5 — energy observation base | **COLLECTED, three arms** (P4, OVS, + a clean P4 re-run after the first was contaminated). 0 switches off on each; mechanism identified. FINDING-05's asymmetry does **not** reproduce. |
| TR-6 — the manual's 128-host example | **PASS**, and its "refuses to start on mismatch" claim forced red in both directions |

## What the next round should pick up

1. ~~TR-5's clean re-run is one authorisation away.~~ **DONE 23:08** — both arms, 0 switches off,
   FINDING-08. **What it opened:** the 15:30-vs-tonight difference is still confounded (kernel
   `89c1754`→`1208d22` *and* agy removed). The decisive arm is one watch against the T-4 baseline
   worktree; cheap, not run.
2. ~~Name the 10.70 s timer in the source.~~ **DONE 22:10** —
   `DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker:1900`, a fixed 10 s sleep plus
   the poll. The severity flipped with it: see FINDING-06's correction banner. What remains is
   **T-11-A**, whose design depends on "invisible" vs "not installed".
3. ~~Find which layer drops the priority.~~ **ANSWERED 23:00** — nothing drops it; `ipv4_lpm` has
   no priority column and destination-only matches all compile there. What is left is a **design
   call**: should the endpoint reject a `priority` it will ignore, echo it back with a note, or
   keep accepting it silently? FINDING-07.
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
