#!/bin/bash
# RECOVERED sampler that produced raw/host_witness_a_rerun.log (150 samples,
# 23:57:39-00:10:10) and raw/host_witness_bcd.log (200 samples, 00:14:12-00:30:54)
# on the nslab HOST during the B-round re-runs of 2026-08-31/09-01.
#
# [Co-developed with claude code -- Adam]
#
# ---------------------------------------------------------------------------
# PROVENANCE OF THIS FILE  -- read before citing it
# ---------------------------------------------------------------------------
# There never was a script file. Both windows were sampled by an inline
# `ssh nslab '... setsid bash -c "..."'` one-liner, so nothing was left on
# nslab (`ls ~/reviewer-B-witness/` shows the two .log files and no .sh) and
# nothing entered version control. `PROVENANCE-host-witness-logs.md` records
# it as unreproducible; that was correct at the time it was written.
#
# The body below is recovered verbatim from this session's transcript
# (`034fd7dd-....jsonl`), from the `tool_use` input of the two Bash calls that
# launched the samplers -- i.e. from the literal text that was executed, not
# from a description of it. Recovered 2026-09-01 after the "遠端機器測試" line
# flagged the gap. It is a reconstruction of a command, not a rediscovered
# artefact, and is committed under that label.
#
# ---------------------------------------------------------------------------
# WHAT IT SEES, AND WHAT IT DOES NOT  -- this is the load-bearing part
# ---------------------------------------------------------------------------
# It counts VMs BY PROCESS NAME (`ps -eo comm | grep -c '^qemu-system'`).
#
# 1. NOT the argv problem. `comm` is set by the kernel from the executable's
#    name at execve; a process cannot reach it through argv. So the
#    argv-shaped fixtures the "遠端機器測試" line warned about do NOT fool
#    this sampler. Measured here 2026-09-01, both spoofs live at once:
#      bash -c 'sleep 4; :' qemu-system-x86_64       -> comm=bash
#      bash -c 'exec -a qemu-system-x86_64 sleep 4'  -> comm=sleep
#      ps -eo comm | grep -c '^qemu-system'  => 1   (the real VM, only)
#      ps -eo args | grep -c '[q]emu-system' => 6   (both fixtures + noise)
#    An earlier revision of this header said the opposite. That was me
#    copying their warning in without testing it; the correction is theirs.
#    `comm` is still not tamper-proof -- prctl(PR_SET_NAME), a write to
#    /proc/self/comm, or a renamed binary each change it, and it truncates at
#    15 bytes -- so /proc/<pid>/exe (their tools/remote-lab/host_witness.sh,
#    beb45fc) is the better field and replaces this from here on.
# 2. THE LOAD-BEARING ONE. Non-VM foreign load is invisible to the qemu
#    column: a build, a compile, or another user's shell job never appears
#    there at all. Its only channel is `load=`, which is load1 -- a lagging
#    composite, not a threshold. So "the window is continuously accounted
#    for" is exact for VMs and an overstatement for foreign load in general.
#    This bears on what a conclusion can carry, not merely on a miscount.
#    Corrected in FINDINGS.md 7.7a.
# 3. Direction of the residual: unrecorded non-VM load slows the arm it hits.
#    It is not one-sided across arms -- it would push a baseline arm and a
#    fast arm the same way -- so it does not have a known sign on R.
#
# The logs' content was never in doubt: pid 52578 is this round's own guest
# on nslab (started 20:19:30, -smp 16 -m 16384,
# /home/nslab/ndtwin-vm-reviewer-B/), which FINDINGS.md 7.7 already stated.
# ---------------------------------------------------------------------------

set -u

N="${1:?usage: host_witness_sampler_RECOVERED.sh <samples> <outfile>}"
OUT="${2:?usage: host_witness_sampler_RECOVERED.sh <samples> <outfile>}"

# Body as executed. The original ran inside ssh '...' -> setsid bash -c "..."
# with two layers of escaping; the escaping is dropped here and nothing else is.
for i in $(seq 1 "$N"); do
  printf "%s load=%s qemu=%s pids=%s\n" \
    "$(date +%T)" \
    "$(awk '{print $1}' /proc/loadavg)" \
    "$(ps -eo comm | grep -c '^qemu-system')" \
    "$(ps -eo pid,comm | awk '/qemu-system/{printf "%s ", $1}')"
  sleep 5
done > "$OUT" 2>&1
