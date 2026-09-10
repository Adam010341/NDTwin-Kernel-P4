# Night rounds — common brief (every persona round gets this verbatim)

You are one round of an overnight hunt for real defects in NDTwin-Kernel. Rounds run one at a
time because there is exactly one lab. Your persona and mission arrive in a separate brief;
this file is the part that never changes.

## 0. What counts as success

Finding a defect that is **reproducible and attributable**. Not: a long log, a big number, or a
list of things that "look concerning". One confirmed defect with a recipe beats twenty hunches.

An honest "I tried X under conditions Y, N times, and it did not happen" is a real deliverable.
Do not manufacture a finding, and do not upgrade a suspicion into a claim to have something to
report.

## 1. Evidence discipline (this is the part people get wrong)

- **Every claim names the command that produced it and the log file that holds the output.**
  A claim with no path is deleted by the auditor without discussion.
- **"Not observed" and "does not happen" are different sentences.** Write the one you earned.
- **A test you never saw fail proves nothing.** Before believing an assertion passed for the
  right reason, break something on purpose and confirm it goes red.
- **State the binary.** Anything about performance, timing, or counters must name the kernel
  binary's sha256 and the commit it was built from. `sha256sum build/bin/ndtwin_kernel`.
- **Every measurement needs its control.** "Throughput dropped after I did X" means nothing
  without the same measurement with X absent, taken close in time on the same machine.
- **A busy machine fakes symptoms.** Before blaming the system for a latency spike, a timeout,
  or a dropped sample, check what else was running (`uptime`, and your own concurrent steps).
  Tonight several agents share this laptop.
- **Distinguish "the switch said 0" from "we failed to ask".** An empty result and a failed
  query look identical in most of this codebase's output. Prove which one you have.
- **A rejected request may still have had an effect.** After anything is refused, check the
  state it claimed not to touch. This codebase has a history of it.

## 2. Machine constraints — breaking these kills the user's desktop app

- 14 cores, 15 GB RAM, and typically **under 4 GB free**. systemd-oomd on this laptop kills the
  user's application when memory pressure rises. Today it already happened once.
- **Do not build anything** during a measurement round. If you genuinely must:
  `flock /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/lock/build.lock env PATH=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/shim:$PATH cmake --build build`
  Never a bare `ninja` or `cmake --build`.
- **Leave headroom: keep ~2 GB RAM free.** You may push traffic, concurrency and rule churn to
  the point where the *system under test* breaks; you may not push the *laptop* to the point
  where the user's session dies. Check `free -g` before and during heavy steps.
- 🔴 **Never `pkill -f` or `pgrep -f`.** They match command lines, so they hit unrelated
  processes — including the guard that is checking for them. Kill by exact pid from a pidfile.
- To break a link use `tc netem` on **both** ends. Never `ifconfig down` — it has broken a whole
  switch here before.
- Long runs go under `setsid` or `systemd-run --user --unit=<name> --collect --nice=10`.

## 3. Lab protocol

- The lab is claimed by owner `auditor`. **Every `ndt` invocation carries `NDT_OWNER=auditor`.**
- **Do not release the claim** — later rounds need it.
- `ndt status`: every column is a point sample, not a lease. `measuring nothing` means "nothing
  at this instant". Your own claim prints as `yours`, without the owner name.
- Do not touch the physical testbed, the PDU/power strip API, the switches, or physical NICs.
  Remote hosts server1-8 / cc2 / gw / gw2 are out of service.

## 4. Repo rules

- **Do not modify tracked files.** Topology experiments work on **copies** in your own round
  directory. If a defect requires editing a tracked file to demonstrate, copy it, edit the copy,
  and say so.
- **Do not commit and do not push.** The auditor commits. (This worktree is shared by several
  agents; a directory pathspec would sweep up their uncommitted work.)
- Write only under your round directory: `doc/audit/2026-09-03_night-rounds/<round-id>/`.

## 5. You will be interrupted — the disk is the deliverable

Rounds have been killed twice today by usage limits, mid-task, with everything in the agent's
head and nothing on disk. Assume it happens to you.

- One log file per step, named `NN_<what-it-proves>.log`, opening with a
  `#### <what this step proves> ####` header line.
- **After every step**, update `FINDINGS.md` (the running table) and the `NEXT:` line at its top
  saying exactly what you were about to do. Then start the next step.
- `FINDINGS.md` table: `# | claim | severity | evidence log | control | reproduced N times |
  status (CONFIRMED / SUSPECTED / REFUTED / NOT-OBSERVED)`.
- End with a `SUMMARY.md`: confirmed defects first with their recipes, then refuted hypotheses
  (worth as much — they close doors), then what you never got to.

## 6. Reporting

Report to the auditor in Chinese; logs, code, filenames and file contents stay English.
Final message: at most 15 lines. Counts, the confirmed defects one line each, and anything a
human must decide. No narrative, no praise.

## 7. Two facts learned the hard way tonight — read them before you start

- 🔴 **Do not wrap `ndt up` in `systemd-run --user --collect`.** The unit's main process exits
  as soon as bring-up returns, and systemd then SIGKILLs the kernel it just started. Use
  `setsid` for anything that must outlive the command that started it. (Found in round 0 while
  bringing up `ovs4`.)
- 🔴 **`sudo` forks rather than execs here, so a pid captured by a background-launch script is
  not the process that needs stopping.** A kernel that had logged a complete, documented clean
  shutdown was still alive and serving 14 minutes later. Whenever you stop something, verify
  through an independent channel — `ps` on the exact pid, and `ss` on the port — that it is
  actually gone. The same gap is why the kernel's exit code is currently unobservable.

## 8. Verify through a second channel, and name the commit

- **Never accept a success message as ground truth.** Processes: check `ps`/`ss`, not the
  script's claim. Routes: read them back from the switch itself, not from the API that wrote
  them. Numbers: take a second sample, from scratch.
- **Tag every result with the exact commit the running binary was built from.** In this repo
  whether something is "already fixed" depends entirely on which commit is running — the public
  clone is behind trunk, and a tester working from GitHub live-reproduced a bug that trunk had
  already fixed. `git log -1 --format=%H` plus `sha256sum build/bin/ndtwin_kernel`, recorded at
  the top of your FINDINGS.md.
- **An internal document's "RESOLVED" label is not evidence.** KNOWN-ISSUES records what was
  believed at the time it was written; several rows were wrong today.

## 9. Do not make the user's desktop pop up dialogs

- **Never use a packaged binary as a crash fixture.** `bash -c 'kill -ABRT $$'` put an Ubuntu
  "internal error" dialog on the user's screen at 23:43 and he had to come and ask what broke.
  apport only reports crashes of package-installed executables — which is why the kernel's own
  aborts have never popped a dialog. If you need a real signal, raise it in a non-packaged
  binary (the kernel itself, or a three-line program you compile in the repo); if you only need
  the exit status recorded, `exit 134` is enough.
- 🔴 Do not touch apport, `core_pattern`, or any other system setting to silence this. That is
  the user's machine configuration and it is out of scope.

## 10. Headroom, revised upward

At 23:33 the user's Chrome hit an out-of-memory condition (`failed to commit`, ENOMEM) while we
had ~2.5 GB free. Nothing was killed, but that is closer than it should ever get.

- **Keep at least 3 GB free**, and record `free -m` beside every heavy step.
- **One build at a time across all agents** — always through the shared `flock`.
- One kernel instance at a time. Before starting another, confirm the previous is gone with `ps`
  on the exact pid, not with a tool's own claim.

## 11. A known bias in every per-flow number (confirmed 2026-09-03 00:0x)

Two independent lines confirmed it tonight: **per-flow rates are not divided by elapsed time.**
`FlowLinkUsageCollector.cpp:1934` computes `counterDelta * 8 * samplingRate` and the drain loop's
period is 1 s *plus* the body's cost, so the overstatement factor equals the period and **grows
with flow count** (measured elsewhere: 1.03 at 16 flows, 1.06 at 64, 1.25 on an older fabric).
The link path divides correctly; only the flow path is affected.

It feeds **top-k ordering and elephant-flow classification**. So:
- Any per-flow rate, top-k entry, or elephant-flow verdict you record tonight carries this bias.
  Say so beside the number — do not report it as if it were clean, and do not "discover" it as a
  new finding.
- The **absolute values** are wrong for certain. Whether the **ordering** is also wrong depends on
  whether all flows share one drain batch; that is being settled separately. Until it is, treat a
  top-k *ranking* as unverified rather than as either correct or broken.
- A fix may land tonight on a branch. Check `git log` and record the commit your binary was built
  from, as always.

## 12. `ndt apps stop` exit codes changed on a branch (not yet merged)

`ndt apps stop` used to exit 0 whether or not anything was stopped. On the branch
`fix/g6-ndt-apps-liveness` it distinguishes three outcomes: **0 = stopped something, 2 = there
was nothing to stop, 1 = could not stop it**. If you are on a build that includes it, treat
**rc 2 as success**, not as failure — and never treat rc 0 on the *unfixed* build as evidence
that anything was actually stopped, because it is not.

## 13. `mn -c` still kills the shell that calls it — the `setsid` rule has NOT been relaxed

A branch tonight removed the four `pkill -f` calls from `ndtwin-lab`'s cleanup. **That is not the
same thing** as the hazard recorded in KNOWN-ISSUES §G: that one lives inside `mn -c`
itself (an internal `pkill -9 -f` at line 1488), it was deliberately left untouched, and it can
still kill the shell that invoked it. So:

- Anything that calls `mn -c`, directly or through a cleanup path, still goes under `setsid`.
- Do not read "cleanup no longer uses `pkill -f`" as "cleanup is now safe to call inline".
- Two defects that look alike, one fixed: check which one you are relying on before you relax
  anything.

## 14. The kernel you are testing aborts on Ctrl-C — that is known and owned

The binary the rounds run (`a8ba99c2`) still has B-5: SIGINT (Ctrl-C) makes it abort with exit 134
and `terminate called without an active exception`, deterministically. It is diagnosed, fixed on a
branch, and **not yours to report again**. `ndt down` sends SIGTERM, which the kernel does not
handle, so it dies instantly with 143 and never runs its shutdown code at all — also known.

What is still worth your attention: **anything that behaves differently because shutdown never
ran** — state that should have been flushed, files left half-written, a component that a later
run adopts. That is unexplored, and it is where a restart-focused round should dig.

## 15. If your round starts `viz`, capture its process chain — someone downstream needs it

The viz app is a four-layer chain and nobody has ever recorded what the surviving processes
actually look like:

```
network_traffic_visualizer.sh   (bash)        <- the pid `ndt apps` records
  └─ ./mvnw javafx:run          (maven wrapper, also a shell script)
       └─ java (maven)
            └─ java (the JavaFX app)          <- the one that burns a core
```

`ndt apps stop viz` signals only the first, and **neither surviving `java` carries the launcher's
name in its cmdline**, so every name-matching liveness check structurally cannot see them. A fix
is being designed and it is blocked on one fact nobody has: **the full argv of the surviving
JVMs.** Tonight's orphan was killed before anyone captured it, and no log in the 09-02 round has it.

So: if you start viz for any reason, before you stop it run
`for p in <each pid in the chain>; do tr '\0' ' ' < /proc/$p/cmdline; echo; done` plus
`ps -o pid=,ppid=,lstart=,comm= -p <pids>` and save it as its own numbered log. Say in FINDINGS
that you captured it. It costs you ten seconds and unblocks someone else's fix.
