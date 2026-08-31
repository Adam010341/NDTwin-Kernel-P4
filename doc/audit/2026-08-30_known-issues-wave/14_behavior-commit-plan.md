# COMMIT-PLAN — bundle 2 (A-1, A-4e, A-2)

Branch `fix-demo-behavior`, based on `1208d22`. **Nothing is committed.** A measurement window
(lab claim `live-traffic-round`, until ~01:24) was live throughout: no `git commit`, no compiling,
no test runs. Everything below is written and read, never executed.

Evidence and the full reasoning: `doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md`.

---

## Do this first, before any commit

1. **Confirm the window is actually over.** Re-read the claim — `ndt status`'s `measuring` column,
   not `pgrep`. The `post-commit` hook `nohup`s an `agy` review agent (~207% CPU, up to 15
   minutes, invisible to `ndt status`'s own bookkeeping), so **committing is itself load** and the
   note that forbade compiling forbade it for the same reason.
2. **Run the §3.3 blocking check** in the evidence file: does the installed Ryu serve
   `/stats/flowentry/modify_strict`? A 404 means **commit 1 and 3 only, hold commit 2**.
   `doc/2026-07-29_p4_status_and_test_guide.md:329` lists the routes without it, so this is a real
   possibility and not a formality.
3. **Build and run the mutation gate** (§4). Thirteen mutations, each with a named test that must
   go red, plus one control that must stay green. Un-run, the fixes are not delivered.

---

## Proposed commits — three, one per defect, in this order

Ordered so the riskiest is in the middle and can be dropped without disturbing the others.

### Commit 1 — A-1
```
src/ndt_core/power_management/P4PowerStrategy.cpp
include/ndt_core/power_management/P4PowerStrategy.hpp
tests/test_P4PowerStrategy.cpp
```
Subject: `powerOn: the graph is not a witness about a switch we just killed`

### Commit 2 — A-4e (**gated on the modify_strict check**)
```
src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
include/ndt_core/routing_management/HttpRoutingStrategyBase.hpp
include/ndt_core/routing_management/P4RoutingStrategy.hpp
tests/test_RoutingStrategies.cpp
doc/2026-01-02_ndt_api.md
```
Subject: `modify_flow_entry: a priority names an entry, so send it strict`

### Commit 3 — A-2
```
src/ndt_core/collection/TopologyAndFlowMonitor.cpp
include/ndt_core/collection/TopologyAndFlowMonitor.hpp
tests/test_RequestDeadlines.cpp
```
Subject: `topology poll: bound the three curls, and say so when they do not answer`

### Commit 4 — docs
```
doc/KNOWN-ISSUES.md
doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md
COMMIT-PLAN.md   (delete instead, if the plan has been executed)
```
Subject: `KNOWN-ISSUES: bundle 2 in flight, and two corrections found by reading`

`doc/KNOWN-ISSUES.md` carries a correction to A-4e's "平面" line (P4 shares the C++ path; only the
proxy differs) and the A-1 supersession note. Those are true independently of whether the fixes
land, so this commit is safe even if commit 2 is held.

---

## Use `git commit -- <paths>`, not `git add`

`git add <paths>` does not protect the index — `commit` sends the whole index, and that has
actually swallowed unrelated files in this repo before. Stage nothing; name the paths on the
commit itself.

Do **not** disable the hooks by pointing `core.hooksPath` at an empty directory: that silently
turns off the audit-raw guard too. If the `agy` hook must be suppressed, remove only
`post-commit`.

---

## Files changed (10) — none committed, none compiled

| File | Defect | What |
|---|---|---|
| `include/ndt_core/power_management/P4PowerStrategy.hpp` | A-1 | clock seam, 15s window constant, per-switch power-off record |
| `src/ndt_core/power_management/P4PowerStrategy.cpp` | A-1 | two-question guard; record on power-off; clear on helper-on |
| `tests/test_P4PowerStrategy.cpp` | A-1 | fake clock + 5 tests |
| `include/ndt_core/routing_management/HttpRoutingStrategyBase.hpp` | A-4e | `virtual strictModifyPath()` |
| `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp` | A-4e | strict route when a priority is supplied |
| `include/ndt_core/routing_management/P4RoutingStrategy.hpp` | A-4e | override — the proxy has no `modify_strict` |
| `tests/test_RoutingStrategies.cpp` | A-4e | 4 tests at the `executeCommand` seam |
| `include/ndt_core/collection/TopologyAndFlowMonitor.hpp` | A-2 | command builder, two timeout constants, failure run |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` | A-2 | bounded curl + one edge-triggered WARN + recovery INFO |
| `tests/test_RequestDeadlines.cpp` | A-2 | 5 wire-format tests |
| `doc/2026-01-02_ndt_api.md` | A-4e | §11 documents the strict/non-strict split and that `priority` defaults to 0 |
| `doc/KNOWN-ISSUES.md` | all | in-flight status + two corrections |

No `CMakeLists.txt` change: every touched test file is already in `test_routing_strategy`, which
already links `NdtCore_CollectionLib`.

---

## Do not do

- Do not mark A-1/A-2/A-4e **RESOLVED** in `doc/KNOWN-ISSUES.md` until §4 has gone green and §5
  has been run. A-3 in that same file is the counter-example: fixed, left marked OPEN for eight
  days, edited during them, and nobody went back.
- Do not `pkill -f` / `pgrep -f` anything during §5.
- Do not run the live checks and the mutation gate in the same claim window as anyone else's
  measurement — this session is itself a measurement covariate (~1 core).
