---
name: energy-saving-app-power-bug-fix
description: "Fixed 3 power-decision bugs in Energy-Saving-App (separate repo) on 2026-08-11; committed but deliberately NOT pushed, pending Adam's professor's decision"
metadata: 
  node_type: memory
  type: project
  originSessionId: 354194c4-0718-4137-b4b9-524e1ee1af6d
  modified: 2026-08-27T13:57:40.193Z
---

On 2026-08-11 I fixed three defects in `/home/adam/Energy-Saving-App` (a *different* repo from NDTwin-Kernel, remote `origin` → `github.com/ndtwin-lab/Energy-Saving-App`). Branch `fix/power-decision-per-group`, commit `9facb78`.

**Do not push it.** Adam's instruction: this work is outside his assigned scope, so he will mention it in his report and ask his professor whether it should go upstream. Committed and recorded only.

All three bugs were in the power-decision loop in `run_switch_cycle_once()` (`src/app/energy_saving_app.cpp`, pre-image around :903-926): an accumulator declared per-group but divided inside the per-node loop; an unguarded division by an edge count that can be zero (a switch up+enabled with all links down → inf, and `inf >= HIGH_WATER_MARK` powers the group back **on**); and the enable/disable call sitting inside the node loop, so one group could be both enabled and disabled in a single pass, order-dependently.

Fix extracted the arithmetic to `group_avg_link_utilization()` in `src/common/types.cpp` returning `std::optional<double>` — this was also the only way to make it testable, since the decision code shares a translation unit with `main()` and calls Boost.Beast directly.

**Two facts worth carrying forward:**

1. **The idle/power decision does not live in NDTwin-Kernel.** The kernel only exposes the mechanism (`/ndt/set_switches_power_state` → `OVSPowerStrategy` / `P4PowerStrategy`). Energy-Saving-App owns the policy, and it is dataplane-agnostic. So Phase 7's scope is the *mechanism* for bmv2, not the decision logic — and these bugs, being in the shared policy layer, will act on the P4 path too once Phase 7 lands (it has since landed — see
[[p4-orphan-switches-and-manifest-lifetime]] for what is still open, and
`doc/2026-07-27_p4_bmv2_support_plan.md` for the phase plan).

2. **Energy-Saving-App had zero tests before this.** No test dir, no framework, no CI, no sanitizers, `-Wall` only. `tests/test_group_avg_link_utilization.cpp` (Catch2 v3, `/usr/lib/libCatch2Main.a`) plus a `tests` Makefile target is the first. Contrast with NDTwin-Kernel's 426 C++ / 332 Python / CI. Assume no safety net when touching the sibling apps.

Review prompt for a second opinion: `/home/adam/Documents/NDTwin documentation/Commit review/PROMPT_EnergySavingApp_9facb78.md`.

Verified per [[mutation-gate-for-tests]]: substituting the original buggy algorithm behind the new signature turns 7 of 10 cases red, reporting `inf`, `-nan` and `0.205 vs 0.4` — the three defects by name. The subagent that wrote the tests also killed 19/19 of its own synthetic mutants, but that is the weaker evidence; the real-bug substitution is the one that counts.
