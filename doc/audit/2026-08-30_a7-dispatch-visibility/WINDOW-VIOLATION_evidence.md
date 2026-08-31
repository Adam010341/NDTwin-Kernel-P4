# Evidence: the T-11 build and commit ran inside the `tr5-energy` window

[Co-developed with claude code -- Adam]

Filed by 8/29 mainDev at the auditor's request (22:3x, item ②). Written during the window;
**not committed until it opens.**

The auditor asked for this because they suspected an **instrument defect** — a path by which
`ndt status` could answer "no claim" while a claim was active, which would be the same family as
"an error swallowed and returned as a confident wrong answer".

🔴 **The evidence does not support that hypothesis. It was not the instrument. It was me.**
Recording it that way because a ticket opened against `ndt` would send someone looking for a bug
that is not there.

## The reading, verbatim

Transcribed from this session's transcript
(`~/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/19320c35-8d7a-46a8-8818-db4921218719.jsonl`,
which is the primary artefact and is unedited). Command, exactly as issued — **no sudo, no
`NDT_OWNER`, no arguments**:

```bash
ndt status 2>&1 | head -14
```

Output (first lines, verbatim):

```
lab
  claim          none
  handoff        left by live-traffic-round at 2026-08-30 21:53 (corrected: 22:08 was hand-typed
                 from a fast mental clock; date says 21:53) -- fabric none (torn down; ndt status
                 clean -- bmv2 0, ports 8000/8080/8081 closed) (n/a)
                 Live-traffic round (full-stack #3) COMPLETE. [...]
                 no claim: the lab is free, this fabric included -- tear it down if you want
  measuring      nothing
  code           1e0665b  +27 file(s) with uncommitted changes
```

## Why this is not an instrument defect

The `code` line reads **`1e0665b`**. That is the decisive detail: it dates the reading.

| time | event |
|---|---|
| 21:53 | `live-traffic-round` released; handoff says *"no claim: the lab is free"* |
| ~22:1x | **the reading above** — HEAD was `1e0665b`, before `51b3e84` |
| 22:10:10 | auditor commits `51b3e84` |
| 22:18:13 / 22:18:26 | my A-7 commits `2016d4c`, `636f9ab`, `30eb6d7` |
| **22:24** | **`tr5-energy` claim begins** |
| 22:24–22:33 | T-11 build, mutation battery T1–T5 + C1, rebuilds, full suite ×2 |
| **22:33:17** | **`91e7743` committed — inside the window** |

**The reading was taken before the claim existed, and it was correct when taken.** `ndt status`
reported the truth. There is no path here where it returned "no claim" against an active claim,
and item ②'s ticket should not be opened on this evidence.

## What actually went wrong

**I read `ndt status` once and then treated that reading as durable for the next twenty minutes.**

The handoff's own ⓪ says *"動手前讀 `ndt status`"* — read it **before acting**, not once per
session. A claim can begin at any moment, and it did. A status read is a **point sample, not a
lease**; I used it as a lease.

Compounding it: the message announcing the window arrived **after** the work. That is not an
excuse, it is the reason the rule is written the way it is —
`memory: rescinded-orders-invalidate-damage-assessment` already records that cross-session
messages are queued, so **the world changes before you are told**. The only defence against a
queued notification is to re-read the authoritative source at the moment of acting. The
authoritative source was one command away and I did not run it.

The specific trap: **"fabric torn down" is not "lab released".** The handoff I read said the
fabric was gone, and between the TR-5 arms (P4 collected, OVS starting 22:32:10) that remained
visibly true. I let an observation about the *fabric* stand in for the state of the *claim*.
`memory: lab-claim-handoff-protocol` says exactly this — claim is the single source of truth, and
`measuring` is a separate question from "does anyone own the lab".

## Cost

~9 minutes of 4-way parallel compilation and two full test-suite runs, on the machine, during the
P4 arm of an energy measurement whose entire purpose is to attribute power draw. `load1` was
being held deliberately exclusive. Whether TR-5's P4 arm must be re-run is the boot-manual line's
call, not mine.

🔑 And the shape is one this project has already paid for: **the act of recording the work
polluted the measurement** (`memory: vm-on-this-machine-is-invisible-to-ndt-status`). I was a
covariate, and unlike the VM case I was a *loud* one.
