# Round 3 — the one who does not believe the numbers

Read `COMMON-BRIEF.md` first; it binds. This file is your mission.

## Who you are

You are here to find the load at which this system stops telling the truth about itself. Not to
break it — to make it report something false while looking healthy. That is the more dangerous
failure, because it ends up in a paper.

## Leads to verify (each is a hypothesis with a file:line, not a fact)

The full analysis is in
`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/bug-brainstorm/boundary-auditor.md`.
Read it. Its author never ran anything, and the tree has moved since. Verify before believing.

1. **Per-flow rate may have no time denominator** (`FlowLinkUsageCollector.cpp:1934/1952`), while
   the link path divides properly. If so the error is optimistic and grows with the collector's
   loop period, which itself grows with flow count. A fix may land tonight — check `git log`
   first, then measure the published number against a ground truth you generate yourself
   (a known iperf3 rate).
2. **`get_power_report` may be a pure function of dpid in MININET mode**
   (`DeviceConfigurationAndPowerManager.cpp:544-564`, called at `:1335`/`:1779`), with no
   `source` field to say so. F-1 turned cpu/memory/temperature into a -1 sentinel; power was not
   included. If true, any "we saved N% power" result is counting vertices marked down.
3. **A-8's ACCOUNTED-FOR branch may compare a bit with itself** in MININET
   (`queryMininet:305` returns `getVertexIsUp ? ON : OFF`, and the invariant reads the same
   `isUp`). Tonight three bmv2 switches disappeared with no OOM and the check printed
   "powered off — the Energy-Saving-App doing its job" with RC=0. **Test the discrimination
   directly**: kill a switch process without powering it off, and see whether the check can tell
   that from a commanded power-off. If it cannot, that is a confirmed defect with tonight's logs
   as corroboration.
4. **Three different windows answer "how many flows"** — a 2 s edge set
   (`TopologyAndFlowMonitor.cpp:3496`), a 3 s API default (`kFlowActiveWindowMs`), and a 15 s
   flow table. The 3 s window times **sample arrival**, so under 1/256 sampling a genuinely
   active flow below roughly 1-3 Mbit/s can vanish from the default response. Construct exactly
   that flow and see which of the three answers it appears in.
5. **sFlow samples appear to be dropped round-robin rather than queued**
   (`FlowLinkUsageCollector.cpp:858-868`), so one slow worker discards a fixed fraction of all
   traffic, and the four drop counters (`FlowLinkUsageCollector.hpp:581-588`) are readable from
   **no** `/ndt/` endpoint — only from a log line that nobody reading the API will see. Confirm
   the counters move, and confirm there is no API path to them.

## The design rule for this round

🔴 **Do not vary flow count and per-flow rate on the same gradient.** At least four mechanisms
here (the 3 s window, sample dropping, the collector's loop period, and genuine saturation)
produce the *same symptom*. If both variables move together you cannot say which one you found.
Hold one fixed, sweep the other, then swap.

Every cell of the sweep needs:
- **a quiet cell** taken immediately before it — same command, no load;
- **a forced-red and a forced-green direction**: prove your assertion can fail (feed it a known
  wrong number) and can pass (feed it a known right one). An assertion never seen red measures
  nothing;
- **a machine-noise record**: what else was running. This laptop is shared with other agents
  tonight, and a build or someone else's iperf3 manufactures most of this round's signal on its
  own. A CPU-gate record without a `suspect` field is **UNKNOWN, not quiet**.
- **ground truth you generated**: compare the system's reported rate against the rate you asked
  iperf3 for and what iperf3 itself reports. "The number looks plausible" is not a measurement.

## Traps

- Link-usage quantisation below ~3 Mbit/s is a documented resolution limit, not a "reads as 0"
  bug — the project already retracted that overclaim once. Do not re-file it.
- `ndt status --check` returns rc=1 on a healthy OVS fabric ("N links are down" is the expected
  fingerprint of Ryu never learning host IPv4 over static ARP). Do not file it as the bug of the
  night.
- A number that is stable across samples is not thereby correct — several of the leads above are
  *constants*. Check whether it varies when the underlying reality varies; that is the test that
  distinguishes a measurement from a decoration.
- Saturating the laptop is not a finding about the system. Keep ~2 GB RAM free and record
  `free -g` alongside every heavy step.

## Deliverable

`doc/audit/2026-09-03_night-rounds/round3-measurement/` — numbered logs, `FINDINGS.md` updated
after every step, `SUMMARY.md`. For every number you report: the command, the log path, the
quiet cell beside it, and the commit hash plus binary sha256 it was measured on. For each of the
five leads: CONFIRMED / REFUTED / NOT-SETTLED, with the evidence either way — a refuted lead is
worth as much as a confirmed one and takes a door off the list.
