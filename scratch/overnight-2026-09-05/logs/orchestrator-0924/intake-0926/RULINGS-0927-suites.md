# Orchestrator rulings, 2026-09-27 ~06:5x +0800 -- the probe suites and the suites red under the gate environment

Worker report: `hunt-0911/fix/SUITES-UNDER-GATE-ENV-SUMMARY.md` (branch `fix/suites-under-gate-env-0927`, head d271f5b8 at
the time). Evidence: `logs/gates-0910/probe_report_a{,2}.sgenv-3db3b9a8.log`, `diag_b.sgenv-3db3b9a8.log`.
These are test-maintenance rulings (no product behaviour, no public claim, no lab policy): the orchestrator's to make
under Adam's standing "繼續工作／有問題一次問完". Each is listed here so Adam can overturn it.

| item | ruling | why |
|---|---|---|
| (a) six probe suites | built-in PATH `sudo` stub in all six, answering like today's R pass (record + refuse, rc 1), closing check fails on any call outside the suite's allow-list; stub unprivileged `tc qdisc show` (lab_handoff) and `ovs-vsctl` (sample_rate) too | the suites must be deterministic whatever the machine's lab state: with a live OVS lab, `test_ndt_sample_rate_reads_both_bounds` goes red (4 checks) with nothing broken. A fabricated "no lab" rc-0 answer was rejected: it would move the suites onto a path neither CI nor any gate has run |
| (a) live-answer variant | out of scope; recorded as an open idea | new test scope, not a fix |
| (b) test_build_guard | fixed by unsetting the guard's variables at the top (d271f5b8) | environment, not a defect; red first shown |
| (b1) test_start_bg_log_rotation | update the suite to O-4's five stamped generations (74c811df, 09-06); do NOT revisit O-4 | O-4 was a deliberate design change; the suite was left behind (red in every environment since 09-06) |
| (b2) test_gate_exit_code_not_tee | minimal synthetic t008_poll twin-trace fixture beside the suite; do NOT commit/un-ignore the raw under `doc/audit/2026-08-20_sampling-rate-and-cpu/raw/`; correct the false "in version control" header | the suite depends on a file only the main checkout has (gitignored `*`); a SKIP-when-absent would leave CI never running it |
| (b3) test_l1_shell_scoring group C | first decide which side is wrong: if the L1 runtime scorer misreads any of the 12 suites' real last line -> report (a real L1 reporting defect, not fixed in this round); if only the static last-echo heuristic is wrong -> replace it with one that does not depend on echo position, discrimination shown by a mutant | changing 12 suites' output to satisfy a heuristic would be fitting the data to the instrument |
| r3 judge NOTEs R3-N1..N5, N7 | queued after the above | none blocks; R3-N4 (l6_plain's 30 s default unexercised; live phase B uses it) is the substantive one |

[Co-developed with claude code -- Adam]
