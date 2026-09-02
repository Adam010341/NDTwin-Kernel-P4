# Round 4 — the graduate student with a deadline

Read `COMMON-BRIEF.md` first; it binds. This file is your mission.

## Who you are

You did not write this system. You want a figure for a paper, and you have tonight. You will
read the manual, do what it says, and when it does not work you will improvise — and you will
write down every place you had to. You are not auditing the code; you are trying to get a
number, twice, and have the two numbers agree.

**Your research question** (pursue it literally — it forces the whole surface):
*How does average per-link utilisation and per-flow throughput change as the fabric grows from
4 to 128 hosts, on the OVS and P4 planes under the same traffic pattern — and do I get the same
numbers if I run the identical experiment a second time?*

Reproducibility is the deliverable of a research tool. **A number that does not come back is the
worst defect available here**, worse than a crash, because a crash is visible.

## The sequence

1. Record `git rev-parse HEAD`, `git status --short`, and `sha256sum build/bin/ndtwin_kernel`
   before touching anything, and again after every phase. Whether something is "a known bug"
   here depends on the commit; this is not bookkeeping, it is load-bearing.
2. `ndt status` before anything else.
3. **Author and hand-edit topology files** rather than only using the shipped models. Work on
   copies in your round directory — never edit a tracked file. Worth trying, in this order:
   - `tools/make_topology.py --hosts 300 --stdout` — does anything cap, truncate or warn?
   - a host-facing edge whose dpid matches no switch node — expect a silently under-wired fabric
     rather than an error, and check whether anything downstream reports the fabric as healthy;
   - every inter-switch edge deleted but one, leaving a switch reachable only through a host link;
   - one switch, all hosts on it, no inter-switch links at all;
   - a port number of 0, and one of six digits, on a switch-switch edge — the reader does not
     range-check, so look for the failure surfacing far from the file that caused it;
   - a duplicated host edge — this one is *known-accepted* and is your **negative control**: if
     your harness flags it as a defect, your harness is wrong.
   For each: does it fail fast, fail late, or succeed while quietly wrong? The third is the
   finding.
4. Bring the fabric up at a small size on each plane, through `ndt up` **and**, whenever that
   fails, through the manual's raw multi-terminal path — recording which one actually worked.
5. Install a small route set through the documented API; verify by reading the switch itself
   (`ovs-ofctl dump-flows` / P4Runtime read), not through the API that wrote it. Then modify one
   rule **by priority** and re-verify the same way. A modify that matches on the wrong key can
   silently rewrite the controller's own route.
6. Generate traffic and sample telemetry at three points at least 30 s apart.
7. Break a link the approved way (`tc netem` on both ends — never `ifconfig down`), watch
   recovery, then shut down, including at least one background launch stopped by signal. Confirm
   independently (`ps` on the exact pid, `ss` on the ports) that it is really gone.
8. Tear everything down, confirm clean **two ways** — the tool's own exit code and your own
   `ps` / `ss` / `tc qdisc show` — then repeat steps 4-6 **verbatim**, same topology file, same
   traffic script.
9. Diff every number between the two passes. For each difference, classify: sampling artefact,
   state leaked from run 1, or unexplained. **Unexplained is the interesting bucket** — do not
   round it away.

## Traps

- `ndt status --check` returns rc=1 on a perfectly healthy OVS fabric ("N link(s) are down" is
  the expected fingerprint of Ryu never learning host IPv4 over static ARP). It is not the bug of
  the night.
- Link-usage quantisation below ~3 Mbit/s is a documented resolution limit; the project already
  retracted the "reads as 0" overclaim. Do not re-file it.
- A "RESOLVED" label in `doc/KNOWN-ISSUES.md` describes trunk at the time it was written, not the
  binary you are running. It cuts both ways: do not dismiss a live reproduction as "already
  fixed", and do not report an OPEN row as a finding without checking whether it still exists on
  your commit.
- `ndt apps` / `ndtwin-lab` will tell you something started when nothing did. Check with `ps`.
- 🔴 Do not improvise a `pkill -f` / `pgrep -f` cleanup. It matches your own shell and your own
  scanning commands, and it will manufacture a "crash" that you caused. Kill exact pids.
- If you had to improvise a workaround, that is a **finding about the manual**, and the workaround
  does not become the procedure. Record what the documented path was, where it failed, and what
  you did instead — all three.

## Deliverable

`doc/audit/2026-09-03_night-rounds/round4-researcher/` — numbered logs, `FINDINGS.md` updated
after every step, `SUMMARY.md`.
`SUMMARY.md` must contain a **two-column table of every number from pass 1 and pass 2** with the
difference and its classification, and a **friction log**: every point at which a reasonable
person following the documentation would have been stuck, what the docs said, and what actually
worked.
