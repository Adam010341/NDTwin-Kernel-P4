#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Section 2.6 (completed after Section 4.1, as instructed)   15:51   friction: 0
what I did: manual explicitly says "Do Step 4.1 first, then come back" for this step, so I
did it out of numeric order, right after cloning. `intelligent_router.py` and `testbed_topo.py`
both exist at the repo root as promised (no paste-your-own-controller step needed -- the
manual's own note explains this used to be a paste-in step and was removed as a source of
drift, which checks out: the file is 114953 bytes / a few thousand lines, not something you'd
paste by hand). Verified the three "configure" claims by reading the file rather than editing
it: `static_topology_file_path` is a `Path(os.environ.get("NDTWIN_RYU_TOPO_FILE", ...)))` at
line 36 as described; `is_mininet` is set at line 56 and unconditionally reassigned `True`
again at line 602 (manual said "about 545 lines further down" from its own line 56 -- actual
gap is 546, so the manual's own approximate figure is accurate); `switch_num` follows exactly
the 3-tier fallback (env var -> topology file's declared count -> hardcoded 10) the manual
describes, at lines 92-101. Chose the non-destructive option for `static_topology_file_path`:
export `NDTWIN_RYU_TOPO_FILE` in the shell that starts Ryu, rather than editing the source.
verdict: 0 smooth -- this is a "trust but verify" step and everything I checked matched.

## Section 4: Download & Compile NDTwin Kernel   started 15:51   ended 15:57   friction: 2
what I did: Step 4.1 -- per the manual's own guidance ("If you are not sure, clone the P4
one"), cloned `NDTwin-Kernel-P4-public` (not the plain `NDTwin-Kernel`) into
`~/Desktop/NDTwin-Kernel`, so the optional P4 section stays available without re-cloning. Got
commit `936f8c6` (2026-09-01), which matches the commit the Web GUI user-manual page names as
"the kernel snapshot the Installation Manual names" -- a small but real cross-check that the
docs and the repo agree on what "current" means. `mkdir -p ~/Desktop` was necessary (this
machine has no ~/Desktop by default, confirming the Server-shaped read from Section 1). Step
4.2: `cmake -GNinja ..` then `ninja clean` then `ninja -j 2` (this VM has 4 vCPUs, so
nproc/2=2) -- built cleanly: `CMAKE_EXIT=0`, `NINJA_EXIT=0`, zero lines matching "warning:" in
the full build log even though the project compiles with `-Wall -Wextra -Wpedantic -Werror`
(so a warning would have been a hard failure, and there were none), `build/bin/ndtwin_kernel`
(11.8 MB) exists and `--help` prints a flag summary that matches what the User Manual's
"why the flags" boxes describe (`--mode`, `--topology`, `--ai`/`--no-ai`). Whole build took
about 6 minutes wall clock, far under what I budgeted for a C++23 project this size.
surprised by: not the build itself (clean, fast) -- the friction here was mine, not the
project's: I started this in the background and then genuinely stopped acting on the belief
that a detached VM-side process would page me automatically when it finished. See the
"Tooling note" entry above; it cost about 6 minutes of wall time where nothing progressed
after the build had, in fact, already finished (build done 15:57, caught ~15:57 per the
external check, so the real cost was small this time, but the *pattern* -- assuming
notification instead of re-checking -- is what's being flagged for next time, e.g. the much
longer Section 6 P4 build).
verdict: 2 needed a workaround: none from the manual's side (it built clean on the first
try) -- the friction was entirely in how I was watching a background build, corrected now to
active re-checks.

## Section 5: Prepare Network Topology Script   started 15:58   ended 15:58   friction: 0
what I did: `testbed_topo.py` ships in the repo root (10575 bytes, executable bit already
set) -- nothing to create, matching the manual. Have not yet run it (that happens under the
User Manual's Terminal 2, later); this section is only the pre-flight existence check per the
Installation Manual's own scope. Reached the "Installation Complete" banner for the
Open-vSwitch path at this point.
verdict: 0 smooth.
EOF
echo APPENDED
