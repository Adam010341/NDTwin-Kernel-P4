# build_guard — run a build without taking the machine down with it

On 2026-09-02 a `-j6` build on this laptop (14 cores, 15 GB) was killed by `systemd-oomd`, and
oomd took the user's own running application with it. This directory is the guard.

**Nothing in the repo is edited to use it.** 23 call sites in 15 files hardcode `-j$(nproc)`
(= `-j14` here) or `-j4`; several are mutation-gate anchors that `check_gate_anchors.py`
parses, so editing them would move the anchors and quietly stop those gates from checking
anything. A PATH shim needs no edit at any call site.

## Use

```
tools/build_guard/guarded_build.sh cmake --build build --target test_routing_strategy
tools/build_guard/guarded_build.sh ./tests/shell/mutate_bx_flow_liveness.sh
JOBS=3 MEM_HIGH=4G MEM_MAX=6G tools/build_guard/guarded_build.sh ninja -C build
```

`JOBS` (default 2) · `MEM_HIGH` (default 3G) · `MEM_MAX` (default 4G) · `LOCK` (default `/tmp/ndtwin-build.lock`) ·
`LOCK_WAIT` (default 3600) · `TIMEOUT` · `NO_CGROUP=1` to skip guard 3.

`NDTWIN_GUARD_HELD` is set *by* the guard, not for it — see [Re-entrancy](#2026-09-11--re-entrancy-nesting-the-guard-in-itself-is-no-longer-a-deadlock).

## Three guards, each for a different failure

| | guard | what it stops |
|---|---|---|
| 1 | PATH shims for `cmake`, `ninja`, `make` | the hardcoded `-j14` in the call site you did not edit |
| 2 | `flock` | two capped builds, which still add up — but **not** a build nested inside another build of its own, see [Re-entrancy](#2026-09-11--re-entrancy-nesting-the-guard-in-itself-is-no-longer-a-deadlock) |
| 3 | a cgroup with an explicit `MemoryMax` | oomd picking its own victim — **this is the one that protects the user's application**, and the only one that survives a build step that ignores `-j` entirely |

Guard 3 is the important one. A vendored script, a recursive make, or a link step that wants
8 GB by itself all walk straight past guard 1.

## Notes that cost something to learn

- **`ninja` with no `-j` is dangerous**, because its own default is `nproc + 2`. The ninja shim
  therefore adds `-j` even when the caller passed none. `make` with no `-j` is serial, so the
  make shim leaves it alone — capping it would make the build *faster* than its author asked.
- **`make` is shimmed** because `tools/test_workflow/build_bmv2_fast.sh:170` is
  `make -j$(nproc)`. A cmake-only guard would have let the single heaviest build in the tree
  straight through.
- **`SHIM_JOBS=0` falls back to 2**, because `-j0` means *no limit* to make — the exact state
  this exists to prevent. Same for any non-integer.
- **The resolver must not find itself.** If it does, the shim execs the shim: one process
  spinning forever, which every caller without a timeout of its own — that is every gate script
  in `tests/shell` — reads as "still building". Two things make that impossible: the shim's own
  directory is taken out of `PATH` (canonicalised with `pwd -P`, because bash's `pwd` is
  logical and would miss a symlinked entry), and the candidate is `readlink -f`'d before the
  comparison, because stripping a directory does not catch a *pointer* into it.

## Evidence

- `tests/shell/test_build_guard.sh` — 37 checks, no build and no compiler: a fake
  `cmake`/`ninja`/`make` on PATH prints its own argv and the test reads what the shim forwarded.
- `tests/shell/test_guarded_build_reentrant.sh` — 15 checks, no build and no compiler and no
  real cgroup scope: nesting is a guard whose payload is another guard, and "did it open a
  second scope" is read off a fake `systemd-run` that logs its argv. Every case uses a lock
  under its own `mktemp` dir, never `/tmp/ndtwin-build.lock`.
- `tests/shell/mutate_build_guard.sh` — 14 mutations, 0 survived; it runs both suites above
  against a mutated copy of this directory. Seven are "the cap must happen"; **M9, M10 and M12
  are widenings** — a guard that capped *everything* would satisfy a one-sided gate while
  changing what `cmake -S . -B build` and a deliberately serial `make install` do, and a guard
  that stopped locking at the first sign of nesting would satisfy a one-sided re-entrancy gate
  while letting a nested build on someone else's lock run beside it.
- End-to-end, on a real three-line CMake project: a caller writing `-j$(nproc)` reached ninja
  as `-j2`; a configure was forwarded untouched; `MEM_MAX=200M` produced `memory.max` =
  209715200 in the build's own cgroup.

**Four defects were found by writing the gate, not by reading the code**: bash's logical `pwd`
left a symlinked shim dir in `PATH`; the self-resolution check was unreachable by construction
until the candidate's symlink was resolved; a shim symlinked into another `bin` dir could not
find `_resolve.sh` beside it and exited 127 with a message that named the wrong cause; and the
first test harness used a minimal `PATH` that removed `dirname` and `timeout`, so every case
came back empty — an instrument failing looks exactly like the defect it is looking for.

[Co-developed with claude code -- Adam]

## 2026-09-03 17:50 — the cap alone did not protect the app

A C++ mutation gate was running under this guard (`MemoryMax=5G`) when systemd-oomd killed the
Claude desktop app: `memory pressure for user@1000.service being 70.24% > 50.00% for > 20s`.
`MemoryMax` only bounds what the build may hold; the pressure it creates on the *slice* on the way
there is what oomd measures, and oomd kills the child with the most reclaim activity -- the app,
whose pages were being squeezed out. `MemoryHigh` (now 3G by default) makes the build's cgroup
throttle and reclaim itself first, so the pressure and the pgscan are attributed to the build scope
and it becomes oomd's victim instead. `MemoryMax` comes down to 4G. Both stay overridable.

## 2026-09-11 — re-entrancy: nesting the guard in itself is no longer a deadlock

Most mutation gates in `tests/shell` call this guard themselves, once per build. Wrapping such a
gate in an outer guard — which is how you cap a gate script that hardcodes `-j$(nproc)` in a
place the shims cannot reach until they are on `PATH` — used to deadlock, because both layers
wanted the same `flock`:

- **2026-09-04**: `guarded_build.sh ./tests/shell/mutate_cpu_report_no_ip.sh` held
  `/tmp/ndtwin-build.lock` for **3 hours** and then reported a failed baseline build.
- **2026-09-10**: nine minutes on the first gate of a round, `flock -w 10800 9` sitting at the
  bottom of the scope; the same shape turns **every mutation into `INVALID (mutant does not
  compile, rc=2)`**, which is the instrument failing and reads exactly like the code passing.
  (`scratch/overnight-2026-09-05/fix/R4-CPPGATES-1-SUMMARY.md` §4.0.)

The guard now exports **`NDTWIN_GUARD_HELD`** — a `:`-separated list of the locks held above it —
after `flock` succeeds. A call whose `$LOCK` is already in that list takes **no second flock and
opens no second scope**: it applies guard 1 (the `PATH` shims, with its own `JOBS`) and runs the
command, inside the cgroup its caller already created, whose `MemoryHigh` every descendant
inherits. So the memory cap and the parallelism cap both still hold at every depth, and the
lock is still held once, by the outermost layer, for the whole nested round.

Three things this deliberately does **not** do:

- **A different `$LOCK` is still taken.** Guard 2 exists so two builds do not run at once;
  only the lock we ourselves hold is safe to skip. Nesting is not a licence to stop locking.
- **Held locks are a list, not the last one.** Keep only the most recent and lock A → lock B →
  lock A is the 09-04 deadlock again, one level deeper. A `:` in a lock path is therefore
  refused rather than silently splitting the list in two.
- **`NDTWIN_GUARD_HELD` is not an input.** Setting it by hand tells the guard it holds a lock it
  does not, which produces precisely the unserialised parallel build guard 2 exists to prevent.

**What it assumes, stated so nobody has to rediscover it:** the variable is only true while the
ancestor that exported it is alive, because that ancestor is the process holding fd 9. Normally
that is guaranteed — kill the outer guard and its descendants are in the scope it created and go
with it. The one gap is an outer guard `SIGKILL`ed with `NO_CGROUP=1` (no scope to take the
children down) whose orphaned descendant then invokes the guard again: it would inherit a claim
to a lock nobody holds and skip a `flock` that was real. Nothing in the tree does that, and the
guard does **not** detect it.

⇒ The `LOCK=/tmp/ndtwin-build-outer.lock … guarded_build.sh env -u LOCK <gate>` convention that
09-10 used to work around this is **no longer needed**: `guarded_build.sh <gate>` is enough, and
one lock is held for the round instead of two.

[Co-developed with claude code -- Adam]
