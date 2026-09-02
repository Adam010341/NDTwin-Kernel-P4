# Round 2 — powering things off, and what the paths do about it

Read `COMMON-BRIEF.md` first; it binds. This file is your mission.

## Why this round exists

The system's owner named this area unprompted: *"powering on/off and path recomputation also
break often."* It is where two subsystems meet — the Energy-Saving-App decides a switch should
go away, and the control plane has to notice and re-route around it — and the seam between them
is where the failures live. It is also the area with the most existing evidence to build on, so
you start from a long way in.

## What is already known (do not re-derive; verify only where marked)

- Tonight three bmv2 switches (s5, s7, s9) disappeared mid-round with no OOM. The cause was the
  Energy-Saving-App powering them off — attributed from the app's own actions
  (`doc/audit/2026-09-02_live-round/raw/C30_bmv2_loss.log`, `C31`, `C32`).
- A-8's three-state check then printed *"accounted for: 3 switch(es) … a powered-down switch is
  the Energy-Saving-App doing its job"* with RC=0 (`raw/C34_a8_three_state.log`).
  🔴 **The open question is whether it could have said anything else.** In MININET,
  `queryMininet:305` returns `getVertexIsUp ? ON : OFF`, and the invariant it is checked against
  reads the same `isUp` bit — if so, the check compares a bit with itself and cannot distinguish
  *we powered it off* from *it died*. **Test the discrimination directly**: kill a switch process
  by its exact pid (never `pkill -f`) without commanding a power-off, and see whether anything in
  the system can tell that apart from a commanded power-off. If it cannot, that is a confirmed
  defect and tonight's logs corroborate it.
- Recovery is not proactive: `down_reason` lags `is_up` by roughly 40 s
  (`raw/C43_f14_recovery.log`). Measure it again and see what the lag depends on.
- `get_power_report` may be a pure function of dpid in MININET
  (`DeviceConfigurationAndPowerManager.cpp:544-564`, called `:1335`/`:1779`), with no `source`
  field saying so. F-1 turned cpu/memory/temperature into a -1 sentinel; power was not included.
  If true, "we saved N% power" counts vertices marked down. **Verify before believing.**
- `tools/p4_power_helper.py` has never been run to actually power a switch — only its refusal
  path (CHECKPOINT T-15).

## Hunt list

1. **Power off a switch that is carrying traffic.** Does a path get recomputed? How long until
   traffic actually moves — measured from the packets, not from an API's opinion? Is there a
   black-hole window, and how long? Distinguish three outcomes: re-routed, dropped, or *silently
   still pointing at the dead switch*.
2. **Power it back on.** Does the path come back, and does anything actively mark it up, or does
   it only recover when something else happens to poll? Time both directions; asymmetry between
   down-detection and up-detection is the expected shape here.
3. **Power off the only remaining path.** Two switches down so that no route exists. What does
   the system report — no route, a stale route, or a route through a switch that is off? The
   third is the finding.
4. **Power-cycle repeatedly**, faster each time, while traffic runs. Where does state stop
   converging? Does the table end up describing a topology that never existed at any instant?
5. **Power off during a route install**, and install a route to a switch that is powering down.
   The window between "decided to power off" and "actually off" is exactly where a rejected
   request can still have an effect — check the switch's own table afterwards, not the API's
   answer.
6. **`p4_power_helper.py` for real.** First run of an unrun tool: check it did the thing, not
   just that it exited 0.
7. **Recompute under churn**: change routes while a power event is in flight, and see whether
   the recomputation and the manual change fight — last writer wins, lost update, or a merge that
   makes sense to neither.

## Controls — without these your findings are worth nothing

- **The discrimination control (the most important one here)**: for every claim of the form "the
  system detected X", show it reports something *different* when X did not happen. A check that
  says "accounted for" whatever you do has no discriminating power, and this round exists partly
  because we suspect exactly that.
- **The quiet cell** before and after every sequence.
- **Ground truth from the switch, not the API**: read the flow table with the switch's own tool.
  A path that the API believes exists and the switch does not is the finding, and you can only
  see it by asking both.
- **In MININET, "power" is a graph flag, not electricity.** Any energy number you see is a model
  output. Say so in every sentence where you report one; do not let a reader think a wattage was
  measured.

## Traps

- Killing a switch process and commanding a power-off may look identical in the logs — that is
  the hypothesis, so do not accept identical output as proof that the system handled both
  correctly.
- A path that "recovered" may just be a cached answer that was never invalidated. Force a fresh
  computation and compare.
- The Energy-Saving-App acts on its own schedule. If a switch goes away and you did not do it,
  find out who did before building a finding on it — that already happened once tonight.
- Recovery lag is not a bug by itself; a recovery that *never* happens without an external poke
  is. Distinguish them by waiting long enough, and say how long you waited.

## Deliverable

`doc/audit/2026-09-03_night-rounds/round2-power-paths/` — numbered logs, `FINDINGS.md` updated
after **every** step, `SUMMARY.md`. For each of the five known leads above: CONFIRMED / REFUTED /
NOT-SETTLED with the evidence. For each confirmed defect: the smallest recipe, how many times out
of how many, and the control that rules out the machine.
