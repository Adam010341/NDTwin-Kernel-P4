# Manual scripts — not tests

[Co-developed with claude code -- Adam]

Everything here is a **hand-run diagnostic that needs a live fabric**: a running Mininet with
bmv2 switches, and for some of them a running proxy agent. None of it is part of any automated
suite, none of it asserts anything, and none of it runs in CI.

They were in the repository root until 2026-08-12, which is why several documents refer to them
as "the scripts at the repo root".

## ⚠️ Do not move these into `p4_proxy/tests/`

Three of them are named `test_*.py` and **none of them contains a single test case**. That name
is what made an earlier cleanup plan propose filing them under `p4_proxy/tests/`, which would
have broken the test suite: `tools/test_workflow/l1_unit_tests.sh` globs
`p4_proxy/tests/test_*.py`, runs each file directly and parses `Ran N tests`, and labels a file
that runs no tests as **NO TESTS RAN**. (Correction 2026-08-13: for this glob the label alone
does not increment the runner's failure count — that branch exists for another directory. What
actually fails the run is the file's own nonzero exit code, e.g. an import error, plus the
labelled noise in the summary. The conclusion stands either way: these files do not belong in
the suite's glob.)

The names are kept as they are because several audit documents cite them, and those are
historical records. This README is the correction.

## What each one does

| Script | Needs | What it does |
|---|---|---|
| `check_env.py` | nothing | Prints the interpreter path and where `grpc` and the P4Runtime protobufs resolve from. First thing to run when an import fails in one venv but not another. |
| `dump_table.py` | bmv2 on `localhost:50051` | Reads every table entry off device 1 over P4Runtime and prints the raw protobuf. `table_id = 0` means "all tables". |
| `test_modify.py` | proxy on `:8081` | Posts one `flowentry/modify` and prints the reply. The shortest check that the modify path answers at all. |
| `test_modify_error.py` | bmv2 on `localhost:50051` | Calls `modify_ipv4_route` against a switch directly, bypassing the proxy's HTTP layer, and prints whatever it raises. |
| `test_10_routes.py` | proxy on `:8081` | Pushes ten routes through `flowentry/add` and reports which succeeded. |
| `p4runtime_mastership_probe.py` | bmv2 on `localhost:5005x`, **3 scratch devices** | ⚠️ **Destructive** (pushes `VERIFY_AND_COMMIT`, which clears every table). Runs the three mastership scenarios that settled whether bmv2 accepts a pipeline push from a non-primary: it does not. A third-party client on purpose — no code shared with `p4_client.py`. See `doc/2026-08-13_p4runtime-mastership-spec-check.md`. |

`test_10_routes.py` pointed at port **8080** from the day it was written, while the agent has
always bound **8081**, so it had never once run successfully. Fixed 2026-08-12 along with the
move.

## Running them

They resolve their own paths now, so the working directory does not matter:

```bash
p4_proxy/venv/bin/python p4_proxy/reference/check_env.py
```
