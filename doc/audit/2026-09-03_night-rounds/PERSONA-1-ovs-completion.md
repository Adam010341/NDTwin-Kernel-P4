# Round 1 — the OVS plane, closed out

Read `COMMON-BRIEF.md` first; it binds. This file is your mission.

## Who you are

Not a persona: you are the auditor's own hands. Tonight's later rounds hunt for unknown
defects; your job is the opposite and it comes first, because it is the cheap one — a list of
named, specified work items whose answers are currently missing. Every item below has been
sitting at UNVERIFIED because the round that could have answered it ran out of clock on the
P4 plane. One `ovs4` window answers most of them.

## Your source of truth

`doc/audit/2026-09-02_live-round/CHECKPOINT.md`. Read section (a) REMAINING (T-1..T-23),
section (b) REMAINING (X-1..X-12), and section (e) — (e) has the claim command, the bring-up
sequence, the log convention, and the work order. Follow it. It was written by the agent that
did the P4 half; where it and this file disagree, this file wins, but say so in your report.

## Work order

1. **T-1 .. T-6** — bring up `ovs4` and run the OVS arms of the contract/component/log tools
   and the R-5 harness. `50_r5_ovs.sh` (T-6) is the important one: it is the only path to
   **R-5 F-1** and **R-5 F-5**, and it closes the **F-5b differential** — the P4 arm alone is
   half a finding, and half a finding is not a finding.
2. **X-5, X-8, X-9, X-10, X-6, X-7** — the fix arms that need OVS or were simply never
   attempted. X-6 and X-7 (a single quote in a request body / a simulation case) can run on
   either plane and take minutes; do them early so they are not the thing you run out of time on.
3. **T-9 then X-1, X-3** — Ryu up: prove from `ryu-manager`'s **argv** that the vendored
   `tools/ryu_apps/rest_topology_bounded.py` is the app actually loaded, not the packaged one.
   Then the half-answered topology round (`topology-round-partial`).
4. **T-10 .. T-23** — the tools with no run evidence. Note T-20 before T-22: `25_apps_energy.sh`
   writes the file without which `90_restore.sh` aborts.
5. **T-7 / X-2 LAST.** The `--max-time` rider stops Ryu and holds `:8080` with a listener that
   accepts and never answers. It destroys the control plane; nothing after it is trustworthy.
   Run it at the end of the window, then tear down.

## What must be true of your evidence

- **T-9 is an argv question, not a behaviour question.** "The bounded app seems to be working"
  is not evidence that our copy is loaded. Read the process's argv.
- **X-2 is a timing assertion**: ~15 s (3 × 5 s), not ~6 s. Record the actual elapsed time. The
  08-31 injection dropped SYNs and therefore only exercised `--connect-timeout`; a listener that
  *accepts* and then stalls is a different code path. If you cannot make it stall, say so —
  do not accept a `--connect-timeout` result as if it were the `--max-time` arm.
- **X-10 inverts on OVS**: groups and meters are real there, so the six endpoints should NOT
  answer 501. A 501 on OVS is a finding, not a pass.
- **X-5**: the phantom-rule window structurally cannot exist on P4 (the proxy writes
  synchronously inside its 200). On OVS it can. Re-run the 08-31 force-red recipe; if it does
  not go red, the interesting question is whether the window closed or whether your probe is
  too slow to see it — answer that question rather than reporting a pass.
- **X-9**: you need a captured HTTP response that actually contains `stale_since` /
  `stale_polls` / `last_error`. The kernel log line firing is not the endpoint half. A grep over
  all of the P4 round's evidence found those fields nowhere in any response body.

## Traps specific to this round

- Several of these items were marked UNVERIFIED **because nobody ran them**, not because they
  failed. Do not let the word prime you toward finding failure; run the thing and read what it
  says.
- `ndt status` point-samples every column, including `measuring`. It is not a lease and not a
  health check.
- Anything you conclude from the OVS plane about a fix does **not** transfer to the P4 plane,
  and vice versa. The CHECKPOINT is careful about this; stay careful.
- A tool that exits 0 having done nothing is this codebase's signature failure. For every tool
  you run for the first time, check that it actually did the thing — a changed file, a changed
  table, a log line — not just its exit code.

## Deliverable

`doc/audit/2026-09-03_night-rounds/round1-ovs/` with your numbered logs, `FINDINGS.md` (updated
after **every** step — you will be interrupted) and `SUMMARY.md`. In `SUMMARY.md`, give the
auditor an updated T-list and X-list: for each id, the new verdict and the evidence path, and
for anything still unanswered, one line saying what specifically blocked it.
