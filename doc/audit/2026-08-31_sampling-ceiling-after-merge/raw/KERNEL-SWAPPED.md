# `build/bin/ndtwin_kernel` is not stable while the E round is running

**Written 2026-08-31 20:5x by `8/31 mainDev`, during the E round's measurement window.**
[Co-developed with claude code -- Adam]

## 🔴 Read this if you found a kernel binary here you did not expect

The E round (`doc/audit/2026-08-31_sampling-ceiling-after-merge/`) **swaps
`build/bin/ndtwin_kernel` in and out on purpose**, once per cell. Two staged arms differ only
in `kFlowPathRecomputeInterval`, and `lib_e.sh:swap_kernel` copies one of them over
`build/bin/ndtwin_kernel` before each cell. So during the window that path holds a
**measurement arm**, not production, and that is expected rather than broken.

| what | sha256 | size |
|---|---|---|
| **production** | `e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94` | 72 878 120 |
| arm, recompute **1 Hz** | `fcb0d9d40d5814a80b37127d01a04068f92aa45a54e74372bebec75ec343b956` | 72 877 744 |
| arm, recompute **1 kHz** | `4dc9193de97a2cfed2307fb3ef50fa9d8ee7b62879bfb277e92ed3626b74bba6` | 72 883 184 |

## Do not trust the snapshot below — take your own

At the moment this file was written, `build/bin/ndtwin_kernel` was **production**
(`e3bad23c…`), because a force-red test had just run `abort` → `restore_production`. That is a
**point sample of a value that changes every cell**, so it is worthless to you. Read it
yourself:

```bash
sha256sum /home/adam/Desktop/NDTwin-Kernel/build/bin/ndtwin_kernel
```

and compare against the table above.

## Where production lives, and why there are two copies

1. `NDTwin-Kernel/.test_run/binaries/e-round/ndtwin_kernel.production-backup`
   — written by `lib_e.sh:swap_kernel`, and **`.test_run/` is gitignored and designed to be
   cleared**.
2. `/home/adam/ndtwin-artifacts/production-kernel/ndtwin_kernel.production-2026-08-31`
   — copied out on 2026-08-31 20:40 precisely because (1) was the only copy and sits in a
   disposable directory. See the `README.md` beside it.

Both verified byte-identical by a single `sha256sum` invocation over both paths (not two
separate runs, which would agree with each other even if the reader were broken).

🔴 **This binary has no rebuild recipe.** No commit, no build configuration, no build log is
recorded for it anywhere. It is an artefact, not something reproducible. Treat losing it as
permanent.

⚠️ `strings` finds `961c151d2e87f2686a955a9be24d316f1362bf21` inside it. **That is not a commit
in this repository** (`git cat-file -t` → `bad object`). It looks exactly like provenance and is
not. Recorded here so nobody re-walks that dead end and concludes they found the answer.

## To put production back

```bash
cp -f /home/adam/ndtwin-artifacts/production-kernel/ndtwin_kernel.production-2026-08-31 \
      /home/adam/Desktop/NDTwin-Kernel/build/bin/ndtwin_kernel
```

The round's own path is `restore_production` in `lib_e.sh`, which also tears the fabric down and
recompiles P4 at 1/256 — that is the full production config, not just the binary. `abort()`
calls it, so any gate or cell that fails loudly restores by itself.

## What this file deliberately is not

It is **not** a `LAB-NOT-RESTORED` marker, and it is deliberately not named like one.
`lib_e.sh:193` refuses to start when it finds `doc/audit/*/raw/LAB-NOT-RESTORED`, and that glob
covers this round's own `raw/` — writing that marker here mid-round would make this round's own
preflight refuse, locking the running round out of itself. That marker's own comment says it is
written *"when it exits"*: it is a message to the **next** occupant, not a flag for a hazard
that is live right now. This file is the record; the marker is the interlock, and they are
different jobs.
