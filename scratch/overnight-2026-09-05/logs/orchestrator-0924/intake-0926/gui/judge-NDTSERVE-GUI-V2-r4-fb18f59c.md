## Round-4 review: feat/ndt-serve-gui-v2-0927 @ fb18f59c (code head 73889e54), merge 3e8148ab

**VERDICT: MERGE.** The round-3 fix list is done, and every item has command-written evidence at 73889e54 and on the merge commit. Only two mechanical checks remain before trunk, both already in your plan:
- Rebuild the merge on fb18f59c and confirm its tree is dcdc2380 plus `doc/audit/2026-09-27_ndt-serve-gui/SUMMARY-v2-r3.md` and nothing else.
- Confirm trunk is still 1e350bf2; the merge-tree log recorded "trunk now 1e350bf2" at 10:16. If trunk has moved, re-run merge-tree and at least the suites, both main gates, the measuring test and gate, and anchors on the new merge.

Read-only as before.
- Path roots:
  - WT = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927`
  - L = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2`
  - D = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/gui/diff-r4-51f61eea..fb18f59c.patch`
- D touches only `SUMMARY-v2-r3.md` and four `tests/shell` scripts, matching "tests/shell only".

### Round-3 fix list

1. **Probe pin: DONE.** `test_ndt_status_measuring.sh` grew from 79 to 102 checks (D:478-698), with three new layers, each with its own control:
   - **Allowlist PATH.** `--measuring` runs with only cat, cut, date, dirname, head, readlink, sed, wc and the ps shim on PATH. An exported `command_not_found_handle` records anything else. ndt never sets PATH itself, so the allowlist does bind.
   - **Listeners.** Connection counters on 127.0.0.1:8000, :8080 and :8081 run inside `unshare -rn`. If neither the namespace nor the host fallback is possible, the check fails rather than passes.
   - **Static closure.** The functions reachable from `status_measuring_rows` must be exactly five, with no `/dev/tcp`, `/dev/udp` or absolute-path command among them.

   Evidence:
   - Red: the r3 test passes all five bypass mutants (79/0); the r4 test fails every one (L/pin-hole-r4.log:6-10).
     - L14 is caught by three layers.
     - L14b, L15 and L16b by two each.
     - L16 by the static layer alone.
   - The pin-hole run used the committed r4 test: its sha 96562034 matches the gate's file list (L/ndt-measuring-gate-r4-73889e54.log:36).
   - Green at 73889e54, porcelain 0:
     - Test 102/0 (L/ndt-measuring-test-r4-73889e54.log:105-118).
     - Gate 19/0 (gate log :21-25, :38). L14 and L16b name the network check; L14b and L16 the static check; L15 the allowlist check.
   - The merge commit repeats it: 102/0 in netns mode, and 19/0.
2. **Merge re-made and more run on it: DONE.**
   - merge-tree rc is now command output: rc=1 for the head (5 citation conflicts), rc=0 for 3e8148ab (L/mergedc-3e8148ab-merge-tree.log:6-22).
   - On the merge (merged ndt 581c236e):
     - 4 suites, 18/75/39/35, on 3.12 and 3.8.
     - Both main gates 198/0, with M61 and M63–M65 caught (main-gate-py312.log:77, :106-108, :278-280).
     - status_check gate 24/0 (:36-38).
     - honesty gate 67/0 (:79-81).
     - residue_row 27/0, lab_handoff 19/19.
     - Anchors 4/4 and 129/129.
     - Page suite from the extraction: 32 OK in 619.051 s, page under test `/tmp/mergedc-n2bb9g/tools/ndt_serve/static`, 0 leftovers (page-suite.log:16, :62-67).
   - Still not run on the merge, as the SUMMARY lists: the page gate, the rebuild gate, the round_baseline and sudo_surface gates, and G-N7.
   - None of those touches anything trunk changed: the page and page gate are unchanged since 0170df28 (page gate sha 7e71944f in killed-r4-term-page-gate.log:4).
3. **SUMMARY corrections: DONE.** The committed WT SUMMARY-v2-r3.md has every correction:
   - The header line now points at §5 (:5-8).
   - The r2 column shows 48/0 and ok(39) (:218, :220).
   - The not-run-on-merge list (:165).
   - merge-tree rc cited from command output (:139-143).
   - The up.target explanation (:113-116).
   - The 617.823 s note (:229).
   - On the identical 617.823 s: the two runs were separate invocations, each with its own timestamped header, and nothing in the gate reuses earlier output. Coincidence is the remaining explanation; the merge run's 619.051 s fits the 615–619 s spread.
4. **Optional items: DONE.**
   - The main, measuring and rebuild gates print their own sha. Each matches between the killed run and the head run: 673d5164, edcd5ddc, fe873d70.
   - The kill harness now takes INT or TERM and scans /tmp and /proc (cmdline and cwd) after the kill.
   - INT on the measuring gate: exit 130, INCOMPLETE. TERM on the main, rebuild and page gates: exit 143, INCOMPLETE. Nothing left after any of them (killed-r4-*.log).
   - The first INT run, ignored because SIGINT was ignored at launch, is kept and explained.
   - The "上次探測 on a failed probe" item is deferred, as you said.

### L16: is `/usr/bin/ovs-vsctl list-br` equivalent to `/usr/bin/sudo -n true`?

Yes, for what the gate proves.
- L16 is caught only by the static check: the pin-hole log shows only "no absolute-path command and no /dev/tcp" failing (:9), and the gate names that same check (:24).
- That check is purely textual. It flags any command-position word starting with "/" inside the five reachable functions (D:678-698).
- Both lines have the same shape, so they get the same verdict. Neither does a PATH lookup or touches a watched port, so no other layer sees either one.
- The only difference is what runs during the gate. The substitute makes an unprivileged OVS read attempt, with output discarded; the original would make a real sudo authentication attempt. That has no effect on any check, and it avoids sudo noise.
- Caveat: absolute-path commands, sudo included, are pinned only by this text rule. If the rule were ever narrowed to match names such as "sudo", L16 would stop standing in for a sudo bypass.

### New (none blocking)

- **[LOW] The page-gate kill could have proven nothing.** It came about 61 s into baseline 1. The log doesn't show whether Chrome had started yet or the suite was still waiting for the build-guard lock. Fix: have `kill-midrun-r4.sh` count, just before the kill, the processes whose cmdline or cwd names the gate's temp dir.
- **[LOW] The listener can miss a late connection.** `net-run.sh` kills the listener 0.2 s after the command ends, without accepting what is still queued. On a loaded machine a connection made at the very end could go uncounted. The other layers and the 8 states make this unlikely to matter. Fix: accept everything still queued before exiting.
- **[LOW] Not yet seen in CI.** The new test is in CI's L1 lane (`tests/shell/test_*.sh`), but it has not run there, and its host-port fallback is untested (disclosed).
  - `unshare -rn` may be blocked on CI runners, in which case the test falls back to host ports.
  - The allowlist was derived on this laptop.
  - Either problem shows up as a red run, never a false pass. Watch the first CI run after the merge.
- **[INFO] Remaining blind spot.** An absolute-path command held in a variable or run through `eval`, with no network use, escapes all four layers. Low risk; noted for completeness.
- **[INFO] INT is lost when a gate is launched with SIGINT already ignored.** That happens when a gate runs in the background of a non-interactive script; bash cannot trap such a signal, and the worker documented it. TERM works.

### Before pushing (your plan, restated)

1. Rebuild the merge on fb18f59c and confirm its tree is dcdc2380 plus SUMMARY-v2-r3.md only.
2. Confirm trunk is still 1e350bf2. If it moved, re-run merge-tree and the merged suites, both main gates, the measuring test and gate, and anchors.
3. Optional follow-ups: the before-kill snapshot, the listener drain, and the deferred "上次探測" label in the next GUI delivery.
