# Finding 08 — the Energy-Saving-App locks itself out, and the watch that measures it reports four cycles when there was one

**Status: CONFIRMED, 2026-08-30 22:24–23:08 CST.** TR-5, both arms (P4 4-host, OVS 4-host),
kernel `1208d22`. Adam authorised the power-off verb at 22:24. **System finding**, plus a
harness finding.

[Co-developed with claude code -- Adam]

---

## TR-5's registered result

| arm | watch | switches powered off | `acquire_lock` calls | sim cases |
|---|---|---|---|---|
| 5 — P4 / BMv2, 4 hosts | 242 s | **0** | 183 | 3 |
| 6 — OVS / Ryu, 4 hosts | 241 s | **0** | 188 | 3 |
| **7 — P4 re-run, clean** | 242 s | **0** | **183** | **3** |

**Arm 7 exists because arm 5 was contaminated** and the auditor was right to call it: mainDev
misread the lab state between my two arms and ran a T-11 build, a mutation re-run, 655 tests and
a commit inside arm 5's window (hard upper bound: commit `91e7743` at 22:33:17). A contaminated
run is exactly what the 15:30/15:53 pair had to be redone for, so it was redone rather than
declared: re-claimed at 22:52, load1 **0.99–1.13** throughout, **zero** in-window commits.

**It reproduces the contaminated arm on every count** — same 183 lock calls, same 3 simulation
cases, same zero. Which is what the mechanism predicts: a held lock is a *state*, not a timing
effect, so CPU contention cannot move it. The re-run was still worth doing — "the covariate
could not have mattered" is an argument, and this is a measurement.

Peak link utilisation was **0.0 %** on both — far below the app's `LOW_WATER_MARK` of 0.40, so
the decision chain predicts a shutdown. **This is not "the network was busy". There was nothing
to stop.**

🔴 **FINDING-05's P4-vs-OVS asymmetry does not reproduce.** The 15:30 P4 run powered off three
switches (s9, s7, s5); the 15:53 OVS run powered off none, and that difference is what FINDING-05
turns on. In a clean window both arms give **zero**. See "what is still confounded" below before
reading that as "the asymmetry was contamination".

## Why nothing was powered off — from the app's own log, not inferred

`25_apps_energy.sh` records that the cause "is NOT ESTABLISHED" and that reaching it needs the
app's own output. That output exists only in a root `tmux` buffer and dies with the session, so
it was captured **while the app was alive** via `ndtwin-lab energy-out`:

```
[error] [http.cpp:439 acquire_lock] acquire_lock: bad HTTP code 423 or null body:
  {"detail":"lock \"routing_lock\" is held by another client; retry after its TTL",
   "error":"Lock acquisition failed"}
```

— once per second, continuously. The chain, each link read rather than assumed:

1. **The loop retries on lock failure and does nothing else.**
   `energy_saving_app.cpp:952-956`:
   ```cpp
   if (!acquire_lock()) { std::this_thread::sleep_for(std::chrono::seconds(1)); continue; }
   bool ok = run_switch_cycle_once();
   ```
   So a refused lock means **no switch cycle runs at all** — not a cycle that decides against
   powering off.
2. **The kernel-side counts match exactly.** 183 `POST /ndt/acquire_lock` in 242 s (P4) and 188
   in 241 s (OVS) — ~0.77/s, which is the 1 s retry.
3. **The app did decide to act.** Three `POST /ndt/received_a_simulation_case` on *each* arm: the
   first cycle got the lock, evaluated, and sent its cases.
4. **It never releases.** `release_lock()` appears twice in `energy_saving_app.cpp`, and **both
   calls sit inside conditionals tied to a simulation round-trip completing** — `if
   (caseID2SwitchesDpidToPowerOff.size() == completeSimulations.size())` (~:374) and `if
   (!sentCase)` (~:632). With no Simulation-Platform-Manager running, no simulation completes,
   `sentCase` is true, and neither branch is taken.
5. **The lock is held for its full TTL — 300 s — which is longer than the 241 s watch.** Recovery
   inside a single watch is impossible by construction.
6. **The lock outlives the process.** Measured: after `ndtwin-lab energy-stop`, a fresh
   `acquire_lock` still returns **423**. Killing the app does not free it.

So the app **disables itself on its first cycle** and then spins. The power-off it computed is
gated behind a simulation round-trip that has no counterpart running.

## 🔴 The harness reports four decision cycles and there was one

`25_apps_energy.sh` prints:

> watch window: requested 240s, ACHIEVED 242s over 25 samples … **that is 4 full 60 s app
> cycles, which is the number to quote — not 240s.**

Four *wall-clock* cycles, yes. But only the **first** reached a decision; the other ~180
iterations were 1 Hz lock refusals. **PREREG §3 TR-5 requires "≥2 decision cycles per arm", and
that requirement was not met on either arm — while the script reported it as met.**

The line is a good idea implemented against the wrong quantity: it converts seconds to cycles by
dividing by the app's *configured* cadence, which assumes every cycle ran. A cycle count has to
be counted, not derived — the app's `received_a_simulation_case` calls (3 per arm, all in the
first cycle) or its own log are the observables.
🔑 Same family as this round's other two: `memory: failures-that-report-success`. The gate could
go red and could go green; it just could not tell "ran and declined" from "never ran", and it
announced the more reassuring one.

## What is still confounded — do not close FINDING-05 on this

Two things changed between the 15:30 P4 run and this one, not one:

| | 15:30 (3 switches off) | tonight (0) |
|---|---|---|
| kernel | `89c1754`, sha `eb78019d…` (the T-4 baseline worktree) | `1208d22`, sha `66f437a5…` |
| `agy` contamination | ~2 cores, present | **absent** |

The kernel difference includes `4ee086f` / `87d272f`, which touch **exactly** the lock endpoints
this finding runs through. I checked whether the fix changed the already-held path and **it did
not** — `4ee086f` is about malformed bodies answering 423 instead of 400, and its own message
notes a second client already could not acquire. So "the old lock always granted" is **not
supported**, and the attribution is open.

**The decisive test is cheap and was not run:** point `KERNEL_DIR` at
`/home/adam/Desktop/NDTwin-Kernel-t4-baseline` and repeat this watch on `89c1754`. One arm
settles whether the change is the kernel or the contamination. Registered, not done.

## Also observed, out of PREREG scope

`POST /ndt/release_lock {"type":"routing_lock"}` from an unrelated client — a bare `curl` that
never acquired it — **released the app's lock and returned 200**. PREREG §5 puts the
`acquire_lock` family out of scope and this is not written up as a verdict; it is recorded
because it is how the lab was left clean, and because anyone re-running this will need it.

## 🔴 I contaminated my own OVS arm, and caught it by timestamp

The OVS kernel log shows 3 `POST /ndt/release_lock` where P4 shows none, which looks like a real
P4/OVS difference. **All three are mine** — curl probes at 22:33:54, 22:33:54 and 22:34:48, and
the OVS watch window opened at 22:35:38. The app released nothing on either arm.
🔑 Probing the endpoint under test *during* the arm that measures it. Caught only because the
watch window has its own epochs in `energy_watch.tsv` and the log lines carry clock times.

## Provenance — checked, and it was nine seconds from being wrong

Both TR-5 arms ran the round's binary, **`1208d22` / sha256 `66f437a5…`** (72 312 168 B):

| | kernel process started | binary |
|---|---|---|
| arm 5, P4 | 22:25 | `66f437a5` |
| arm 6, OVS | **22:32:13** | `66f437a5` |

**`build/bin/ndtwin_kernel` was rebuilt at 22:32:22 by another session** — nine seconds after the
OVS arm's kernel had already `exec`'d, so that arm loaded the old image and the claim holds. It
was checked rather than assumed, because I had written "both arms, kernel `1208d22`" from the
fact that I never rebuilt anything myself, which is not the same statement.
🔑 A concurrent build does not disturb a process that has already started, but it silently
changes what the *next* one loads. `memory: benchmark-must-name-the-binary-it-measured` — the
binary is decided at exec, and a measurement window has to own the file, not just the fabric.

### 🔴 The binary on disk is no longer the one this round measured

It is now sha256 `4e7afe2d…` (72 688 888 B), including commit **`91e7743` "Serve only the flow
entries that were actually programmed"** — T-11-A. That commit touches `HttpSession.cpp` and
`DeviceConfigurationAndPowerManager.cpp`, i.e. **exactly the path FINDING-06 and FINDING-07
measure**. Their reproduce recipes are written against `66f437a5` and **may not reproduce on the
current build** — if T-11-A does what its subject line says, the phantom is gone by design.
That is the intended outcome, not a contradiction; it is recorded here so nobody reads a
non-reproduction as a refutation.

## Reproduce

```bash
NDT_OWNER=x NDT_EXCLUSIVE_CPU=1 ndt claim 60 'TR-5'
NDT_OWNER=x ndt up p4 4
bash doc/audit/2026-08-30_live-full-stack-round/harness/25_apps_energy.sh --yes-power-switches-off
# then, while a second energy instance is alive:
sudo -n /usr/local/sbin/ndtwin-lab energy-start; sleep 75
sudo -n /usr/local/sbin/ndtwin-lab energy-out | tail -30
```

Expect: 0 switches off, and `acquire_lock: bad HTTP code 423` once a second.

Artefacts: `raw/arm5-tr5-p4/`, `raw/arm6-tr5-ovs/` (`tr5_energy.log`, `energy_watch.tsv`,
`energy_app_own_output.txt`).
