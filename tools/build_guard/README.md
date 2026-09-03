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
JOBS=3 MEM_MAX=6G tools/build_guard/guarded_build.sh ninja -C build
```

`JOBS` (default 2) · `MEM_MAX` (default 5G) · `LOCK` (default `/tmp/ndtwin-build.lock`) ·
`LOCK_WAIT` (default 3600) · `TIMEOUT` · `NO_CGROUP=1` to skip guard 3.

## Three guards, each for a different failure

| | guard | what it stops |
|---|---|---|
| 1 | PATH shims for `cmake`, `ninja`, `make` | the hardcoded `-j14` in the call site you did not edit |
| 2 | `flock` | two capped builds, which still add up |
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
- `tests/shell/mutate_build_guard.sh` — 10 mutations, 0 survived. Seven are "the cap must
  happen"; **M9 and M10 are widenings** — a guard that capped *everything* would satisfy a
  one-sided gate while changing what `cmake -S . -B build` and a deliberately serial
  `make install` do.
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
