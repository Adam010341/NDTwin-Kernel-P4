# t008_poll, synthetic -- the cell tests/shell/test_gate_exit_code_not_tee.sh gates

[Co-developed with claude code -- Adam]

The suite asks `ratio_gate.py` about one GREEN cell. It used the real 2026-08-20 cell `t008_poll`,
but that cell's raw lives only on the `audit-raw` orphan branch and in whichever checkout still has
it on disk (`doc/audit/2026-08-20_sampling-rate-and-cpu/raw/` is ignored by its own `.gitignore`),
so in any worktree, clone or CI checkout the gate had no data: `UNRUNNABLE (no ratio -- NO-DATA)`,
rc 2 -- and case 2, which expects rc 2, passed for that wrong reason.

These two files are MADE, not copied (the first cut's first row had the real trace's `t` and `tx`,
1787658157.534 and 3302 -- the opus judge's N3 on d2a9d641; since 09-27 `t` starts at 1700000000.0
and the counter at 0, every row shifted by the same amount, so the ratio is unchanged). Their shape
is the real trace's (`git show
audit-raw:doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_twin.jsonl`, sha256 295ab0d4…):
one JSON object per line, `t` every 0.25 s, `twin` and `tx` dicts keyed by interface, `twin` in
bit/s as whole multiples of one sample's worth, `tx` a byte counter. Only the edge the gate reads
(`s5-eth2`, `plot_ladder_rates.EDGE`) is present; 64 s of it (past `TRIM`, inside `SPAN`); readings
192/208 Mbit/s alternately against a counter growing 200 Mbit/s, so ratio = 1.000 (GREEN, over
`SATURATED_RATIO` 0.95). `t008_poll_client.json` carries only the field `cell_verdict.lost_percent`
reads, set to the real cell's 8.1097 %, so the verdict's mark is the real one's too.

The suite copies them into its own temp dir and points `plot_figures.RAW` there with
`NDT_SAMPLING_RAW_DIR`; nothing is ever written here. Its case 1b asserts the gate's ratio is this
fixture's, 1.0000 -- the real cell reads 0.9656 -- so a broken override on a checkout that still has
the real raw/ is red, not green.
