# NSR documentation journey — run live in the clean-room VM

2026-08-30 19:43–19:45. Guest: Ubuntu 24.04.4, clean of NSR before the run. Harness
`vm/guest_nsr_journey.sh` (`d1e6949`), committed before it ran. Raw: `~/nsr-results/`.

Two passes by design: **literal** (every command as printed, from where a reader stands) then
**recovered** (defects worked around), so "the documentation is wrong" can be separated from
"the software does not work". That separation is what this run bought, and it lands on the
documentation.

---

## Pass 1 — literal. Three of four commands fail as a reader would experience them

| id | command as printed | result |
|---|---|---|
| **INST-1** | `pip install nornir loguru orjson requests` | 🔴 **`error: externally-managed-environment`** |
| INST-2 | `git clone …/Network-State-Recorder.git` | ✅ works |
| **INST-3** | `chmod +x start_network_state_recorder.sh stop_…` | 🔴 **rc=1** — the scripts are one directory below the reader |
| **UM-1** | `./start_network_state_recorder.sh` | 🔴 **rc=127** — command not found |

All three were predicted from reading and are now **measured**.

* **INST-1** — the page's Requirements section names no virtualenv and the Kernel manual
  mandates Ubuntu 24.04, where PEP 668 is the default. **The first command a reader types does
  not work.**
* **INST-3** — the page prints `git clone` then `chmod +x` with **nothing between them**. The
  clone makes a directory; the `chmod` runs above it. Same shape as M-1: a missing `cd` whose
  failure is quiet.
* **UM-1** — the User Manual page opens at `./start_network_state_recorder.sh` with no working
  directory stated anywhere on it and **no link to the install page**. `rc=127` is what a reader
  arriving from the site menu gets.

## Pass 2 — recovered. This is the half that decides whose fault it is

**REC-1 PASS — the four dependencies install cleanly into a venv.**
⇒ **INST-1 is a documentation defect, not a broken dependency set.** Without this pass those two
possibilities are indistinguishable, and the report would have had to say so.

Also confirmed working once the documented defects are worked around:

* **REC-5** — `logs/NSR_2026-08-30.log` exists, matching the page's
  `tail -f logs/NSR_$(date +%Y-%m-%d).log`.
* **REC-7** — `display_on_console: true` after the stop script, exactly as the page says it
  should be.

## 🔴 Correction — three of my seven FAILs are my harness, not the software

`REC-3` reported *"NSR did not start, or pgrep cannot see it"*. **Wrong.** NSR's own log:

```
INFO  : Recorder settings: NDTwin server: http://127.0.0.1:8000, Request interval: 5 seconds …
ERROR : Error checking NDTwin server status: HTTPConnectionPool(host='127.0.0.1', port=8000): …
ERROR : NDTwin server is not reachable, exiting...
```

**NSR started, read its configuration, checked its precondition, named the host, the port and
the reason, and exited on purpose.** That is good behaviour, and it is the behaviour the page's
"API Dependency" section implies. My harness polled `pgrep` twelve seconds later, found nothing,
and called it a failure to start.

| my verdict | what actually happened |
|---|---|
| REC-3 FAIL "did not start" | **started, diagnosed, exited deliberately** |
| REC-4 FAIL "nothing recorded" | correct, but *because* of the above, not in addition to it |
| REC-6 PASS "stop script stopped it" | 🔴 **vacuous** — nothing was running. The check is `if pgrep …; then FAIL else PASS`, so it passes when there is nothing to stop |

🔑 Two lessons, both already on this project's own list:

1. **"Empty conflated with failed"** — recurring defect #2 in this repo's review prompt. My gate
   could not tell *exited on purpose* from *failed to start*, and reported the harsher one.
2. **REC-6 is a gate that passes for the wrong reason**, the same family as FINDING-04 and as the
   `POST-2` tautology I caught before running §6.7. Third instance in one day. A liveness check
   that returns PASS when the subject is absent needs a precondition, not just a condition.

**Repair for the harness (not applied tonight):** REC-3 should read NSR's log before judging, and
REC-6 must assert something was running *before* the stop.

## Verdict on the pages

**Four document defects, all confirmed live:** the missing virtualenv instruction, the missing
`cd`, the missing working directory, and the missing link from usage page to install page.
**Nothing here is a defect in NSR itself** — every failure traced to an instruction, and where
the instructions were followed correctly the software did what the page says it does, including
refusing to run without its server and saying so clearly.

**Not covered:** everything downstream of a live kernel — actual recording, the ZIP archiving,
the `pgrep -f` self-match hazard in the stop command. Registered for the run that has a fabric.

[Co-developed with claude code -- Adam]
