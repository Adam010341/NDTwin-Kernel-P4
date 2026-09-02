# Manual user-test campaign — pre-registered protocol (2026-09-02)

Adam's brief (12:4x): keep dispatching Claude subagents of different models to a fresh, clean
VM, have each install and use NDTwin following **only** the new website's Installation Manual
and User Manual, as an ordinary user would, one run at a time, and see where each one gets
stuck. Ledger: `NSLAB-USAGE-RULES.md` row **A-7** (umbrella) + one sub-row per run.

This file is written **before the first run** so the method cannot drift toward the results.

## What one run is

| | |
| :--- | :--- |
| Machine | A **new** VM from the Ubuntu 24.04 cloud image (`ndtwin-vm.sh create`), 4 vCPU / 6144 MB — the size the shipped OVF declares, i.e. what a user actually gets. Not a copy of any prepared disk: the user starts at Section 1 |
| Seed | `create`'s cloud-init pre-creates `~/Desktop` — its own comment calls this a deliberate workaround for finding M-1 (the manual assumed `~/Desktop` without creating it). Each campaign VM has its seed **rebuilt without those two lines** (`user-data.as-created` kept beside it), so whatever the manual does about `~/Desktop` today is what gets tested. `noble-base.img` is copied in beforehand so `create` reuses it instead of downloading 600 MB per run |
| Tester | One subagent, one model per run. Rotation: **sonnet → haiku → opus → fable**, then variations |
| Persona | A competent Linux user (bash, apt, git, ssh) who has never seen this project and knows nothing about its internals |
| Documentation | The website source `content/en/docs/` **copied into the guest** at `~/ndtwin-docs/`. The tester reads it top-down like a website. It may open links the manual gives (p4-guide, Miniconda) as a user would in a browser |
| Sandbox | The tester's world is that VM plus the internet. It reaches the guest via `ssh -J nslab -p <port> ndt@127.0.0.1` and touches nothing on the nslab host, no other VM, no ledger, no audit files, and never this repo's source to "figure out" a fix |
| Rules of engagement | Follow the manual literally. Ambiguity → do what a typical reader would, **and write down that it was ambiguous**. Failure → try what a normal user would (re-read, the obvious), ≤ ~15 min per obstacle, then record a blocker and (a) find a workaround reachable from the manual/links, (b) skip if later sections do not depend on it, or (c) stop |
| Record | `~/JOURNAL.md` in the guest, appended as it goes: per section start/end, what was done, verbatim command + result for anything surprising, friction **0** smooth / **1** confusing but worked / **2** needed a workaround / **3** blocked |
| Scope | Installation Manual to the end, then the User Manual: start the kernel, run the emulated network, do what the guide tells a first-time user to do |
| End state | VM **stopped, kept** (evidence; Adam can enter it). Never destroyed by the tester |

## What the orchestrator does around each run

1. Registers the sub-row **before** `create`. Reads `ndtwin-vm.sh create` once (does it re-download the 600 MB base image, or can `noble-base.img` be reused) before run 1.
2. Creates and boots the VM, copies the docs in, verifies the jump-host ssh path works, then dispatches the tester with **no knowledge of known defects** in its prompt — a hint would make it a guided walk, which is what today's three clean-room passes already were.
3. Records the **website commit** the copied docs came from. The manual may be fixed between runs; the commit per run is what keeps "changed the model" and "changed the manual" from sharing a row.
4. On completion: **re-verifies the tester's claims independently** in the guest (what exists, what answers `--version`, what the logs say) before anything is written here. A tester's "installed fine" is a claim, not a result.
5. Writes `run-NN-<model>/` with: the tester's report verbatim, the journal, the verification, and a **reconciliation** against earlier runs (same friction again / new / gone).
6. Stops the VM, releases the sub-row.

Gate: **one tester VM at a time, and none while A-6 (12 GB) is running** — the host has ~7 GB
available beside Adam's own VM, and a tester wants 6.

## Predictions, written first (R12)

- **Run 1 (sonnet) clears the Installation Manual §1–§6.** Today's corrections targeted that path. **The friction lands in the User Manual** — `ndt up` wants `NDT_OWNER`; the four apps want JDK / NFS / root; `mn -c` kills `ryu-manager` — the side that had zero verification today.
- **If run 1 stalls in the Installation Manual instead**, the day's three clean-room passes measured a path only someone who already knew the answers could walk. That conclusion would outrank any single defect.
- **haiku gets stuck where opus does not, and those places are the manual's real gaps.** A strong model reasons across a hole in the text; a weak one falls in. The weak model is the better instrument for this question.

## Reconciliation obligations

Each run's write-up must say, for every friction point, whether an earlier run (or the 09-01
clean-room passes A-2/A-4) hit the same thing. A problem that every model hits is the manual's;
a problem only one model hits is worth a second look before it is called the manual's.

[Co-developed with claude code -- Adam]
