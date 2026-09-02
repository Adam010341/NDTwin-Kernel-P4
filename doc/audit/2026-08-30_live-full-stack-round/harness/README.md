# T-4 full-stack round — harness

**WRITTEN, NOT RUN.** Every script here was authored by a session with no permission to claim
the lab, start a fabric, or sudo. **No script below has been executed against a running system,
and none has produced a single observation about NDTwin.** The first execution is the harness's
own first test, and on this project's record that is when most of its defects will appear
(`memory: new-tools-are-the-first-thing-under-test` — the chaos harness's first live run found
thirteen defects, all in the harness).

### Exactly what *was* verified before commit

Stated precisely, because "written, not run" is easy to use as cover for "not checked at all".

| Checked | How | Result |
|---|---|---|
| shell syntax, all 6 `.sh` | `bash -n` | clean |
| python syntax, both `.py` | `python3 -m py_compile` | clean |
| `pattern_selftest` passes | sourced `lib.sh`, ran it (pure string matching — no lab, no sudo, no network) | 11 patterns, all matched their sample and rejected their near-miss |
| `pattern_selftest` **goes red** | injected the real H-23 defect into a scratch copy (`Discovered link` → `link discovered`) | aborted, exit 3, flagged **both** directions |
| malformed-registry guard | deleted one field from a scratch copy | aborted: "54 entries is not a multiple of 5" |
| `verdict5` rejects a fourth value | passed `"probably fine"` | aborted, exit 3 |

**The self-test earned its place on its first run: it caught a defect in itself.** The registry
originally packed five fields into one `|`-separated string, and `cut -d'|'` tore every regex
that used alternation — `(install|modify|delete)`, `\[(error|critical)\]` — in half. Four of
eleven patterns were silently mangled into invalid regexes. Uncaught, the harness would have
reported *0 matches* for the kernel's dispatch-failure line, and that would have been written up
as **"the kernel no longer logs rejected rules"** — a system-shaped finding manufactured entirely
by a delimiter, in the same family as the four false findings of 08-30. The registry is now a
flat array read five at a time, with no delimiter to collide with.

Everything else in this README — every expected output, every "force it red" recipe below —
is **predicted, not observed**. Treat the first run's disagreements as findings about the
harness until shown otherwise.

Registered by `doc/audit/2026-08-30_live-full-stack-round/PREREG.md`. Read §3 before running:
R-1…R-5 are the only things under test, §2's hypothesis is already dead and must not be
credited to this round, and §4's preconditions are the executor's job.

[Co-developed with claude code -- Adam]

---

## 🔴 Four things the author found that contradict the PREREG or the manual

These were found while writing, from source, before any run. They are recorded rather than
silently fixed: amending a pre-registration is the auditor's call, and "I moved the premise
because it was inconvenient" is the worst reason to move one.

| # | The PREREG / manual says | Source says |
|---|---|---|
| 1 | R-1's endpoint is `/ndt/set_historical_logging_state` | That is the **C++ handler name**. The only route is `POST /ndt/historical_logging` (`HttpSession.cpp:284`). A probe written from the PREREG's string 404s **for the wrong reason** — the H-19 shape. Both spellings are probed separately in `10_…`. |
| 2 | R-2: "consumers poll on a 15 s cadence" | **No app uses 15 s.** energy 60 s (`settings.hpp:8`), sim never (event-driven), nsr 5 s (`recorder_setting.yaml:5`), viz 1 s (`NetworkTopologyApp.java:424`), te 1 s (`Traffic-engineering-App.py:41`). Three of five poll *faster* than R-2's 1 Hz recompute, so the registered "no observable difference" rests on a premise that does not hold. `35_…` prints the registered cadence and the measured ones side by side and decides neither. |
| 3 | R-3: "convergence … 08-18 reference: 69 s (OVS) / 2 s (P4)" | Those two numbers are the **stack** coming up, from the 08-18 documents' own headers, measured before any app was started. They are not five-apps-serving times. `20_…` records `T_stack` and `T_app[i]` as two quantities and never compares one to the other. |
| 4 | R-1 has a registered null branch | It is **the branch that fires**. A read of all seven sibling repos found zero callers, by enumerating every `/ndt/` path each repo constructs rather than by grepping the name. `10_…` re-runs that enumeration live so the conclusion is dated by the run. |

One more, not a contradiction but a blocker: **`te` cannot start headless.**
`Traffic-engineering-App.py:617` calls `ask_mode()`, which calls `input()` at `:599` and `:605`
with no `EOFError` guard (only `enter_listener()` at `:591` catches it). `ndt apps te` inherits
stdin, so from a script it dies before its first poll. `20_…` runs the documented command first
— because "the sanctioned command does not work headless" is itself a finding and can only be
observed by running the sanctioned command — and then restarts it under a pty.

---

## Run order

Phases 1–5 are non-destructive. Phase 6 powers switches off. Do not reorder.

| # | Command | Needs | Roughly |
|---|---|---|---|
| 0 | `./00_preflight.sh` | lab claimed, nothing else running | seconds |
| 1 | executor: `date +%s > $OUT/t0_ndt_up_epoch` then `ndt up p4 4` | — | ~2 min |
| 2 | `./20_apps_lifecycle.sh p4` | stack up | ~5 min |
| 3 | `./10_r1_endpoint_callers.sh` | kernel up (for the probe half) | ~1 min |
| 4 | `./30_r2_r3_sample.py --fabric p4 --seconds 900 --interval 0.5` then `./35_r2_r3_analyse.py --samples $OUT/r2_samples.jsonl.gz` | stack + apps up | 15 min + seconds |
| 5 | `./40_r5_p4.sh` | stack up | ~5 min |
| 6 | `./25_apps_energy.sh --yes-power-switches-off` | **everything above finished** | ~7 min |
| 6b | `./40_r5_p4.sh --f2f3-only` | **fabric still degraded** | ~2 min |
| 7 | `./90_restore.sh --rebuild 'p4 4'` (P4 — see below) or `./90_restore.sh power-on` (OVS) | — | ~2 min |
| 8 | OVS arm: `ndt down && ndt up ovs4`, then repeat 1–7 with `50_r5_ovs.sh` in place of `40_…` | — | ~30 min |

`OUT` defaults to `../raw/<UTC timestamp>/`. Set `RUN_TAG` to label a re-run. Every script
refuses to append to another run's artefacts.

**Step 7's routes were swapped on 2026-08-30 (FINDING-04).** This table used to offer `power-on`
as *the* P4 route; the 08-30 run ended at 7 up of 10 with 20 links down, and that was attributed
to BMv2 power-on from the kernel being a stub.
🔴 **The stub attribution is dead as of 2026-09-02** (`doc/audit/2026-09-02_live-round/raw/C42`):
three `action=on` POSTs returned `Success`, bmv2 processes went 7 → 10 within 15 s, the three
gRPC ports had listeners again, and all ten switches read `ON`. **What is still unmeasured is
forwarding after power-on** — the kernel's own reply said the routes were pending on the link
watchdog — so `--rebuild` remains the route with no open question on it, but it is no longer the
*only* route that can restore a P4 fabric. `power-on` remains the cheap route on **OVS**, with F-7a's
caveat — it re-adds the ports without re-applying shaping, so four 1 Gbps interfaces come back
unshaped and the twin reports them identically to shaped ones.
Route 2 itself was **unable to succeed** until 08-30: `ndt_down` returned its count on the same
channel it narrated on, so the success gate could never be taken and the script tore the fabric
down and stopped. Fixed; both directions demonstrated in `../09_t8-t10-evidence.md` §2.5.

**Phase 6b is easy to skip and it is where two of the six R-5 findings live.** F-2 and F-3 are
only reachable while the fabric is degraded. Skipping it does not make them pass; it makes them
`no longer reachable`, which is a different sentence in the write-up.

---

## Expected output, per step

Read the **shape** of the output, not just the exit status. Every script prints
`PASS` / `FAIL` / `N/A` lines and ends with a count.

- **00_preflight** — a `PASS` for each of: claim is yours, `exclusive cpu … holding`,
  `measuring nothing`, no qemu, `/tmp/ndtwin_p4_switches.json` absent, ports 8000/8080/8081/9000
  free, all five apps present on disk. Writes `binary-provenance.txt` and
  `artifact-baseline.txt`. Expect **one `N/A`** for viz if headless, and **one `N/A`** for te's
  known EOF crash. A `FAIL` here means do not proceed — every later script reads
  `artifact-baseline.txt`.
- **20_apps_lifecycle** — `r3_convergence.tsv` with a row per app. sim should appear on :9000 in
  seconds; nsr should write into `recorded_info/` within ~5 s; te should print `Select TE mode`
  under the pty. Expect the documented-start step to **FAIL by design** with an EOFError note.
- **10_r1** — a positive-control PASS (`get_graph_data` found in ≥5 files), then `N/A  R-1
  UNTESTABLE`, then three kernel probes: 404 for the PREREG spelling, 200 with
  `"recording":false` for the real route, 400 for `state=banana`.
- **30/35** — section 1 (sampler health) **before** any result. If overruns exceed 5 % the timing
  numbers are unusable, not merely noisy. Section 2 names the JSON key it treated as the path
  field — check that key by hand against a raw body the first time.
- **40 / 50** — a `r5_verdicts.tsv` with one row per finding, each `present` / `fixed` /
  `unreachable`. On P4 expect F-1 and F-5 to land on `unreachable` for structural reasons; that
  is the correct answer, not a gap.
- **25_apps_energy** — `energy_watch.tsv` sampled every 10 s for 4 min. Either
  `INJECTION ASSERTED: … powered N switch(es) off`, or `N/A` saying F-2/F-3 are now unreachable.
  **Powering nothing off is not a failure.**
- **90_restore** — counts back to the pre-energy reference, and on OVS an explicit `FAIL`
  reminding you that power-on cannot restore shaping (F-7a).

---

## How to force each gate red

**Look at red before you believe green.** Every gate below has a one-line way to make it fail;
run at least the starred ones before the round, because a gate nobody has seen fail is a gate
nobody has tested. This is the discipline that was missing when the 08-30 pingall assertion
turned out to be structurally incapable of going red (H-21).

| Gate | Force it red by |
|---|---|
| ★ **pattern self-test** (`lib.sh`, runs at the start of every script) | Edit any regex in `PATTERNS` so it cannot match its own sample — e.g. change `Discovered link` to `link discovered`, which *is* the H-23 defect. Every script must abort. **(Verified before commit — see the table above.)** |
| ★ **R-1 positive control** (`10_…`) | Set `CONTROL_FRAG='get_moon_phase'`. The script must `die`, not report "no callers". This is the gate that stops an H-18 false negative from becoming a finding. |
| ★ **F-5 / F-5b controls** (`40_…`, `50_…`) | Change the control rule's priority to one already in use, or point `NDT_URL` at a dead port. The control must FAIL and the script must tell you not to record a verdict. |
| ★ **H-20 staleness** (`00_…`, `require_absent_or_fresh`) | `sudo touch /tmp/ndtwin_p4_switches.json` before preflight. Preflight must FAIL naming the owner; `40_…` must `die` if the file is byte-identical to the baseline. |
| ★ **H-22 pid identity** (`spawn_exec`) | Give it a command that execs into something else, or edit the cmdline check to compare against a name that is not there. It must `die` rather than record a pid it cannot verify. |
| **claim gate** (`00_…`) | `ndt release` before running. Must FAIL on the claim line. |
| **exclusive-cpu gate** (`00_…`) | Claim without `exclusive_cpu=yes`, or start a busy loop so `load1 > 1.5 × ncpu`. |
| **measuring gate** (`00_…`) | Start any process `ndt status` counts as in-flight. Must FAIL, and must distinguish `measuring` from `orphaned`. |
| **port-free gates** (`00_…`) | `python3 -m http.server 8000`. Must FAIL naming the holding pid. |
| **manifest-vs-procs** (`40_…`) | Edit the manifest to list a different count. |
| **sim convergence** (`20_…`) | Block :9000 first. Must FAIL after 60 s, not hang. |
| **nsr convergence** (`20_…`) | Point `NSR_DIR` at an empty directory. Must FAIL on "no record in 60 s". |
| **te documented start** (`20_…`) | This one is **already red by design**. If it ever passes, re-read `ask_mode()` before believing it. |
| **sampler resolution** (`30_…`) | `--interval 1.0`. Must refuse to start: a ladder shorter than what it measures. |
| **sampler overrun** (`35_…`) | Run the sampler under load. Section 1 must declare the timing unusable rather than printing intervals anyway. |
| **paths channel** (`35_…`) | Run with `--fabric ovs` against a P4 stack. Must print the F-8 banner and mark paths-derived lines untestable — **not** print a clean summary. |
| **energy injection assertion** (`25_…`) | Run it on a fabric carrying traffic so nothing is powered off. Must print `N/A … F-2 and F-3 are NO LONGER REACHABLE`, never a pass. |
| **energy stop verification** (`25_…`) | Kill `ndtwin-lab`'s stop verb. Must FAIL rather than say "energy stopped". |
| **restore verification** (`90_…`) | Power one switch off by hand after the restore. Must FAIL on counts, not on the HTTP 200s. |
| **verdict5** (`lib.sh`) | Pass any fourth value. Must `die`. There is no "probably fine". |

The question to ask of any gate not in this table: **if the thing it checks were completely
broken, would this line go red?** If you cannot answer from the code, the gate is decorative.

---

## H-17 … H-24 — where each is answered

Every script's header carries its own correspondence. Summary:

| | Defect | Answered by |
|---|---|---|
| H-17 | `kill -0` returns EPERM for root-owned processes, indistinguishable from dead | `lib.sh alive()` reads `/proc/<pid>`. `kill -0` appears nowhere. |
| H-18 | grepping the manual's word instead of the software's emitted text | `lib.sh` PATTERN REGISTRY: every regex declared with the line it must match (cited to the emitting source) and a near-miss it must not. `pattern_selftest` runs before any measurement. Plus the R-1 positive control. |
| H-19 | a 404 is the service answering | `http_probe` returns curl-rc and HTTP status separately and writes them to separate files. No caller may collapse them. |
| H-20 | root-owned artefacts from a previous run read as this run's | `00_preflight` signs every candidate; `require_absent_or_fresh` aborts if a file is byte-identical to the baseline. It never falls through to "assume it is ours". |
| H-21 | `… \| tail -1 \|\| bad` can never fail | `set -o pipefail` in `lib.sh`; `gate()` takes a pre-computed value. No gate in this harness is the tail of a pipeline. |
| H-22 | `$!` after `( … ) &` names the subshell | `spawn_exec` execs through every layer, then **proves** the pid by matching `/proc/<pid>/cmdline` and dies if it does not. `pkill -f` / `pgrep -f` appear nowhere. |
| H-23 | a backwards grep (`link (add\|up\|discover)` vs `Discovered link`) | Same registry; that exact line is its own registry entry with the real text as must-match. |
| H-24 | block-buffered stdout read as a complete log | `PYTHONUNBUFFERED=1` exported by `lib.sh`; the sampler flushes every 20 records; `wait_for_line` polls instead of reading once. |

**Two things the harness cannot fix, stated rather than hidden:**

1. **The patterns are reconstructed, not copied.** Each must-match sample was rebuilt from the
   format string in the cited source, because this session had no live log to copy from. That
   is one step better than copying from a manual and one step worse than copying from output.
   **After the first run, replace each sample with a real line from the real log.** The `viz`
   pattern in `20_…` is worse still — viz has never been run in this project's audits, so its
   grep is un-calibrated and marked as such inline.
2. **The session running the harness is a covariate.** ~0.3 of a core when idle, and the act of
   recording the experiment has been measured at 207 % of a core. `00_preflight` records it and
   does not pretend to subtract it.

---

## Things this harness deliberately does not do

- **It does not test `/ndt/acquire_lock`.** PREREG §5 puts its three defects out of scope. The
  Energy-App's power loop is gated by it (`energy_saving_app.cpp:952`), so phase 6 exercises it
  incidentally. Do not write anything up about it from these runs.
- **It reports no timing or throughput numbers as performance.** PREREG §5. The seconds in
  `r3_convergence.tsv` are convergence evidence, not benchmarks.
- **It does not re-check F-6, F-6b, F-7, F-8.** R-5's registered range is F-1…F-5b. Noted so
  their absence is not read as an oversight. For the record, two look already addressed in
  source and would need their own round to confirm: `faults.sh:104` now reads
  `FAULTS_SETTLE_S:-75` (F-6/F-6b was 5), and `criteria.py:200` still defaults `PATHS_URL` to
  Ryu's `:8080` (F-8 unchanged).
- **It does not claim the lab, and it does not amend the PREREG.** Both belong to people.
