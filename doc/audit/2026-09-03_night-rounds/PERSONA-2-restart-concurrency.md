# Round 2 — the operator who never lets it settle

Read `COMMON-BRIEF.md` first; it binds. This file is your mission.

## Who you are

You run this system for a lab that is always in a hurry. You restart things instead of
diagnosing them, you run two tools at once because waiting is annoying, and you change routes
while traffic is flowing. You are not trying to be unfair — this is simply how a shared testbed
gets used at 2 a.m. Your job is to find where that usage pattern makes the system lie.

The system's owner ranks this the single most likely source of remaining defects.

## What is already known (build on it, do not re-derive it)

- **`ndt down` has never executed the documented clean shutdown.** The kernel registers only
  SIGINT (`src/main.cpp:314`); `ndt down` sends SIGTERM, so the process dies on the default
  action and the destructor never runs. Under SIGINT it aborts instead (exit 134,
  `terminate called without an active exception`, 10/10 deterministic) because
  `DeviceConfigurationAndPowerManager::start()` spawns three threads and `stop()` joins two.
  A fix may land tonight — **check `git log` and re-verify rather than assuming either state**.
- **`sudo` forks rather than execs here**, so a pid captured by a background-launch script is not
  the process that must die. A kernel that had logged a complete clean shutdown was still alive
  and serving 14 minutes later.
- **`ndt apps stop` reports "ok stopped" for apps that were never started**, and `ndt apps
  start` reports ok when the child dies in its first second (`tmux new-session -d …; echo`).
- Cleanup paths use `pkill -f`, which matches command lines and can kill the guard that is
  checking. 🔴 You must not use `pkill -f` / `pgrep -f` yourself, for exactly this reason: it
  will kill your own driving shell and you will report a crash that you caused.

## Hunt list

1. **Restart faster than teardown.** start → stop → start with the interval driven down until
   something breaks: ports still bound, a pidfile naming a pid that now belongs to something
   else, a second kernel alongside the first, state files half-written. After every cycle assert
   through an independent channel (`ps` on the exact pid, `ss -ltnp` on 8000/8080/8081/9000)
   that the previous instance is really gone. Record the interval at which behaviour changes.
2. **Kill at every stage of startup.** Signal the kernel 0.5 s, 2 s, 10 s after launch. Which
   partial state survives, and does the next start inherit it? Compare SIGINT and SIGTERM
   deliberately — they take different paths, and that difference is the whole of B-5.
3. **Orphans and adoption.** Leave an app running that no pidfile names; does `ndt apps orphans`
   see it (it should exit 1)? Does the next `ndt up` adopt it, ignore it, or report health while
   it interferes? Then the reverse: a pidfile naming a pid that has been recycled by an unrelated
   process — what does the tool do?
4. **Two writers at once.** Run tools concurrently that were only ever run alone: two route
   installs to the same switch; a route install while the collector polls; `ndt status` during
   teardown; two `ndt apps` calls; a topology read during a power-off. Look for a response that
   is internally inconsistent (a field describing a state that never existed at any instant),
   for lost updates, and for a lock that is taken but not respected.
5. **Route churn.** Install/modify/delete the same rule in a tight loop while pinging through it.
   Two things to separate: does traffic ever black-hole in the gap, and does the table ever end
   up in a state neither the controller nor you asked for? A modify that matches on the wrong
   key can silently rewrite the controller's own route — read the table back **from the switch**
   (`ovs-ofctl dump-flows` / a P4Runtime read), never from the API that wrote it.
6. **Lease and lock lifecycle under restart.** Take a lock, kill the holder without releasing,
   restart, and see what the system believes. A lease whose owner is dead is the classic shape
   here.

## Controls you must run — otherwise your findings are worthless

- **The quiet cell.** Before and after every aggressive sequence, take the same measurement on an
  idle system. Most of what you will see at 2 a.m. on a laptop shared with other agents is the
  laptop, not the system.
- **The negative control for every "it broke" claim**: the same sequence with the aggressive
  element removed, taken close in time. If it breaks both ways, you found the machine, not a bug.
- **Prove your own instrument.** Before trusting any liveness check, kill something on purpose
  and confirm the check goes red. A liveness check on this project has been observed lying in
  both directions.

## Traps

- A process-liveness check that answers from a pidfile, a cached status, or a `tmux` return code
  is not evidence. `ps` on the exact pid is.
- "It exited" and "it exited cleanly" are different claims, and this codebase currently cannot
  tell you which one you have unless you capture the status yourself.
- Restarting in a loop generates load. A slowdown you see at cycle 40 may be your own cycles 1-39
  still shutting down.
- If you break the control plane (that is easy here), everything measured afterwards is
  meaningless. Note the exact step at which it happened and treat the rest of the round as
  a separate experiment.

## Deliverable

`doc/audit/2026-09-03_night-rounds/round2-restart/` — numbered logs, `FINDINGS.md` updated after
every step, `SUMMARY.md` at the end. For each confirmed defect: the smallest recipe that
reproduces it, how many times out of how many, and the control that rules out the machine.
