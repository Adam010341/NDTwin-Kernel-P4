# Test workflow scripts

The L0 and L1 layers of the test layering (L0-L4, plus L5 fault injection in `faults.sh`; see the top
of [run_layers.sh](run_layers.sh)),
plus stack start-up orchestration and the top-level driver. The L2, L3 and L4 Python tools are in
[../contract_test/](../contract_test/).

---

## In one line each

```bash
./run_layers.sh selftest     # completely offline, seconds. Run this after changing code
./run_layers.sh quick        # L0 build + L1 unit tests, about 2 minutes
./run_layers.sh api p4       # L2 + L3 + log check (needs a running stack)
```

Everything exits 0 only on success, so it can be wired into CI.

---

## Files

| File | Layer | Purpose |
|---|---|---|
| `components.env` | - | Single source of truth for paths, conda environments, ports and topology files |
| `l0_build_check.sh` | L0 | Does every component still build? |
| `l1_unit_tests.sh` | L1 | Kernel unit tests (run **two ways**), the P4 proxy's Python tests (`p4_proxy/tests`) and `tools/p4_exercise/tests`. A p4_exercise test that skips because a local P4 tutorial tool is missing (`$NDTWIN_TUTORIALS_DIR`, `$NDTWIN_P4C`, `$NDTWIN_P4DEV_VENV`) is reported PROVED LESS rather than failed |
| `stack.sh` | - | Start and stop the stack in the right order and wait for the topology to converge |
| `run_layers.sh` | all | Top-level driver that combines the layers |
| `live_cells/` | - | Regression cells: one re-runnable cell for each defect that failed on a live lab and was then fixed (see below) |
| `ndt` | - | One-line bring-up and tear-down of the lab (`ndt up`, `ndt down`, `ndt status`, ...); see `ndt help` and `doc/2026-11-05_user-guide.md` |
| `ndtwin-lab` | - | The root-side lab operations `ndt` relies on (topology start/stop, NTG CLI, app binaries), run through one `sudo` rule. Install instructions are in its header |
| `sudo_surface.sh` | - | The root privileges `ndt` needs, declared once as a table (`ndt status` prints which are available) |
| `ports.sh` | - | The ports that block a bring-up, with owner and consequence for each |
| `faults.sh`, `faults.txt` | L5 | Inject one named fault, prove what it did, and put everything back |
| `qdisc_snapshot.sh` | - | Before/after snapshots of every interface's qdisc tree (`save <file>`, `diff <file>`; exit 1 on drift) |
| `orphans_verdict.sh` | - | Reads the report `ndt apps orphans` prints, not just its exit code |
| `supervise.sh` | - | Runs a command and records how it ended (the kernel is started through it) |
| `local_ci.sh` | - | Runs the jobs of `.github/workflows/ci.yml` locally |

---

## L0: build check

```bash
./l0_build_check.sh              # all targets
./l0_build_check.sh kernel p4    # only the named targets
./l0_build_check.sh --list
```

The targets are `kernel`, `p4`, `energy`, `sim`, `visualizer`, `webgui`, `python` and `contract`:
the kernel (CMake), the P4 pipeline (`p4c-bm2-ss`), Energy-Saving-App, Simulation-Platform-Manager,
Network-Traffic-Visualizer (Maven), Web-GUI, the Python components, and the contract test tooling
itself (`--self-test`).

Three results:
- **PASS**: the build is clean.
- **FAIL**: a build error; the last 25 lines of the log are printed (the error is almost always there).
- **SKIP**: the toolchain is not installed on this machine. This is **not** a failure, but it is
  listed so you know the coverage shrank.

The kernel is built with `-Werror`, so any new warning is already a failure at this layer.

**Web-GUI**: if `pnpm` is present it installs and builds; otherwise, with a usable Docker daemon,
it validates the compose file (fast). Set `L0_WEBGUI_DOCKER_BUILD=1` for a full image build.

**The Python components use `ast.parse`, not `py_compile`.** `py_compile` writes bytecode next to
the source, and these directories can contain root-owned `__pycache__` left by `sudo` Mininet
runs, which would fail the check for reasons that have nothing to do with the code. Both only
catch a `SyntaxError`; `ast.parse` writes nothing.

---

## L1: kernel unit tests

```bash
./l1_unit_tests.sh              # build, then run
./l1_unit_tests.sh --no-build   # assume the build is current
```

**Why the tests run two ways** is the only reason this script exists:

`ctest` uses `gtest_discover_tests` and runs every `TEST_F` in its **own process**. A failure in
`SetUpTestSuite` therefore only affects that one process, the others pass, and `ctest` shows all
green. Measured with the `Logger::init` idempotency fix removed:

```
ctest            -> 100% tests passed, 0 tests failed out of 12     <- misleading
direct execution -> FAIL (exit 1, ran=12 passed=10 skipped=2)       <- the truth
                    C++ exception "logger with name 'netdt' already exists"
                    thrown in SetUpTestSuite()
```

So the script:
1. runs `ctest`;
2. **also** runs each test binary directly;
3. checks that the number of tests that actually ran equals the number discovered; **a SKIPPED
   test does not count as a pass**;
4. cross-checks the number of cases `ctest` registered against gtest's test count (a mismatch
   means some test is not registered).

It also runs the P4 proxy's Python tests, since half of the P4 path is Python (the sFlow emitter
and the clone session) and the C++ suite cannot reach it. A skipped Python test is reported, not
counted as a pass, unless the run can see for itself that a prerequisite is missing: an
interpreter with the P4Runtime protobufs, or the compiled P4 artefacts that `l0_build_check.sh`
writes to `$P4_BUILD_DIR`.

---

## stack.sh: start-up orchestration

The components have a strict dependency order, and starting them in the wrong order produces
failures that are not real. **The first two steps are reversed between the two modes**, because
the southbound connections point in opposite directions:

```
OVS mode                                P4 mode
1. control plane  Ryu                   1. data plane     bmv2 Mininet
2. data plane     Mininet               2. control plane  P4 proxy agent
   (switches connect to Ryu)               (the proxy connects to bmv2 over gRPC)
3. kernel         ndtwin_kernel  <- must wait for convergence before this (both modes)
4. read-only tools  Visualizer / NSR / Web-GUI
5. traffic          NTG
6. applications     Energy-Saving / Traffic-Engineering   <- they change the network, so last
```

Ryu is the server and the switches connect to it, so Ryu starts first. In P4 mode bmv2
(`simple_switch_grpc`, listening on `127.0.0.1:30051-30060`) is the server and the proxy is the
gRPC **client**, so Mininet starts first. `stack.sh up` follows the right order for the mode.

```bash
./stack.sh up ovs     # Ryu -> asks you to start Mininet -> waits for convergence -> kernel
./stack.sh up p4      # asks you to start bmv2 Mininet -> proxy -> waits for convergence -> kernel
./stack.sh wait       # block until the kernel reports a converged topology
./stack.sh status
./stack.sh down
./stack.sh logs
```

The kernel is started last, with `--mode mininet --topology <topology file> --no-ai` (both data
planes run under `mode=mininet`; the topology file decides OVS versus bmv2), and only after
discovery has finished. The reason is that `TopologyAndFlowMonitor::run()` pulls
`/v1.0/topology/*` and the destination paths **once** at start-up and then stops, with no retry:
whatever the control plane does not know at that moment, the kernel never learns. The symptom of
starting it too early is `up=0 enabled=0`, which does not heal by itself.

**The wait polls the control plane; it does not sleep for a fixed time.** What matters is whether
discovery has finished, and the expected values are computed from the topology file:

| Mode | What is polled | Converged when |
|---|---|---|
| OVS | Ryu `/v1.0/topology/switches` and `/links` | The number of switches in the topology file, and the number of switch-to-switch directed links (host links are not reported by Ryu) |
| OVS | Ryu `/ryu_server/all_destination_paths` | **Non-empty** (the exact count depends on how many hosts Ryu learned) |
| P4 | Proxy `/ryu_server/all_destination_paths` | `hosts * (hosts - 1)` destination paths (12 for the 4-host topology); not waited for if the proxy reports that it sends no LLDP on this fabric |

In OVS mode **both** conditions have to hold, and they become true at very different times: link
discovery (LLDP between switches) takes a couple of seconds, while "all destination paths
installed" is the milestone the user manual names and it comes only after the Ryu app has
finished its settle wait before installing paths (`NDTWIN_RYU_SETTLE_S` in `intelligent_router.py`).
Checking only the link count would release the kernel far too early.

`all_destination_paths` starts as `[]` and is assigned at the end of `install_all_pair_paths()`
in `intelligent_router.py`, so "non-empty" is the direct signal for that milestone and no log
grepping is needed.

`CONVERGE_WAIT` (default **150**, whole seconds) is an **upper bound**, not a fixed wait. On
timeout the script **warns but still starts the kernel**, because being able to look at the broken
state is more useful than giving up. If the control plane never answered at all, it waits the
whole timeout before continuing, since going ahead immediately would reintroduce the race the wait
exists to prevent.

In OVS mode Ryu is started with `--observe-links`, `intelligent_router.py`, the repository's own
bounded topology app (`tools/ryu_apps/rest_topology_bounded.py`) and `ryu.app.ofctl_rest`.
`--observe-links` only loads `ryu.topology.switches` (the events); the `/v1.0/topology/*` REST
routes come from the bounded app, and the stock `ryu.app.rest_topology` must **not** be loaded
alongside it, because both register the same routes. Without those routes the kernel's
`updateSwitches()` would parse a 404 HTML page as JSON, fail, give up quietly, and leave the whole
graph down and disabled.

### `wait` is the most important part

It polls `get_graph_data` until **every switch in the topology file is both up and enabled**. The
expected number is derived from the topology file.

```
waiting for topology convergence (expect 10 switches up+enabled, timeout 90s)
  switches=10 up=4 enabled=0 edges=0
  switches=10 up=10 enabled=10 edges=40
converged after 12s
```

A lot of "looks broken" is just "not converged yet", and this removes that misreading.

### Mininet is started by hand

Mininet needs root and drops into its own CLI, so it cannot be backgrounded cleanly. `up` therefore
stops, prints the command to run in another terminal, and waits for Enter. This is deliberate:
automating it would only trade it for something harder to debug. Clean up afterwards with
`sudo mn -c`. (`ndt up` / `ndt down` do this for you through `ndtwin-lab`.)

---

## run_layers.sh: the top-level driver

| Mode | Runs | Needs Mininet? |
|---|---|---|
| `selftest` | Schema self-test, dependency map | no |
| `quick` | L0 + L1 | no |
| `api {ovs\|p4}` | L2 + L3 + log check | yes |
| `baseline {ovs\|p4}` | Capture responses for L4 | yes |
| `compare` | L4 difference check | no (uses the captured files) |
| `full {ovs\|p4}` | Everything; what cannot run is skipped | depends |

Options: `--traffic` (also require flows, paths and rates) and `--mutations` (include the write
endpoints). `NDT_POWERED_OFF=5,7,9` (or `none`) declares which switches were powered off, and is
passed to the log check (see [../contract_test/](../contract_test/README.md)).

### A typical P4 development loop

```bash
./stack.sh up p4 && ./stack.sh wait
./run_layers.sh api p4 --traffic
./stack.sh down
```

### Building the L4 baseline (once, on a healthy OVS stack)

```bash
./stack.sh up ovs && ./stack.sh wait
./run_layers.sh baseline ovs --traffic
./stack.sh down
```

After that, whenever the P4 side makes progress:

```bash
./stack.sh up p4 && ./stack.sh wait
./run_layers.sh baseline p4 --traffic
./run_layers.sh compare
```

`compare` sorts the differences between P4 and OVS into three classes: allowed P4 limitations
(written in the allowlist), differences within numeric tolerance, and **everything else, which is
a bug**.

---

## live_cells: regression cells

`l1_unit_tests.sh` and `tests/shell/` ask "is this code right?". `live_cells/` asks a different
question: **a defect that failed on a real lab and was then fixed: is it still fixed today?**

A **cell** is a reproducible sequence of actions plus an expected verdict. The rule for entry is
"it failed live and was fixed, so it comes in and never leaves", so the directory only grows, and
the number a run reports is how many cells are red.

Every cell has two subcommands, and that split is the whole design:

| | |
|---|---|
| `observe <rawdir>` | Drives the lab (or the tool) and only writes raw data; it reaches no verdict |
| `judge <rawdir>` | A **pure function** of that directory: no lab, no network, no clock, no git |

Because `judge` is pure it can be pointed at an older log, so "this cell really can go red" can be
shown without rebuilding the old binary. `tests/fixtures/live_cells/<cell>/old/` holds that red.

```bash
live_cells/run_cells.sh --list                    # which cells, with their tags and requirements
live_cells/run_cells.sh --requires none           # the cells that need no lab at all
NDT_ROOT=/path/to/NDTwin-Kernel live_cells/run_cells.sh --tag ndt
```

- The last line is `CELLS: <pass>/<total> pass, <fail> FAIL, <skip> SKIP`; any FAIL gives a
  non-zero exit.
- Each cell prints `CELL: PASS|FAIL|SKIP <name> tag=... kernel=<sha16> ndt=<blob sha> at=...`. The two
  identifiers are written by `observe` into `ids.txt` and **travel with the raw data**, so an old
  fixture identifies the old binary, not today's.
- Between cells `run_cells.sh` restores the lab itself: `orphans_verdict.sh` (**before** the
  down), `ndt down`, `ndt clean`, `orphans_verdict.sh` again. If the restore fails it stops, so
  one cell's leftovers are not charged to the next.
- `NDT_ROOT` selects the checkout whose `ndt` is driven. The cells are the instrument; the tree
  under test is the one `NDT_ROOT` points at. The root-side operations (`ndtwin-lab`) do not follow
  `NDT_ROOT`: they act on the kernel tree named in the root-owned `/etc/ndtwin-lab.conf` (or its
  built-in default when that file is absent), and `sudo ndtwin-lab config` prints which tree is in
  effect.
- Raw data goes to `$NDT_ROOT/.test_run/live_cells/<date>/<cell>/`.

The list of cells, where each came from, the commit that fixed it, and **what the cells do not
cover** are in `live_cells/CELLS.md`. The mutation gate is `tests/shell/mutate_live_cells.sh`
(two mutants, delete and widen, for each key assertion in `judge`).

---

## Where output goes

All logs, pidfiles and baselines live under `$RUN_DIR` (default `<repo>/.test_run`, which is
gitignored). It is deliberately not under `/tmp`: a predictable path in a world-writable directory
would let another local user pre-create the pidfiles that `stack.sh` later reads and kills.

```
.test_run/
|-- logs/       build logs, component logs, ctest output
|-- pids/       stack.sh pidfiles
|-- baseline/   captured API responses for ovs/ and p4/
`-- mode        the current stack's mode and topology
```

To change the location: `RUN_DIR=/somewhere ./run_layers.sh quick`

---

## Overriding the configuration

Every variable in `components.env` can be overridden from the environment:

```bash
NDT_URL=http://192.168.1.5:8000 ./run_layers.sh api p4
TOPO_P4=/path/to/my_topo.json ./stack.sh up p4
```

`KERNEL_DIR` is derived from the location of `components.env`, and the sibling repositories
(Energy-Saving-App and so on) are looked up from there; conda environments are expected under
`$CONDA_ROOT` (default `~/miniconda3`). Adjust these for a different layout.

---

## The sudo surface

The root privileges `ndt` needs are declared in `sudo_surface.sh`; `ndt status` prints, one by
one, whether each is available. Section 3.2 of `doc/2026-11-05_user-guide.md` teaches how to
grant them. On a machine set up from the website's manuals, two of them are **not** taught
there and have to be added by hand: `mnexec` and `ovs-vsctl`.

### `mnexec` makes any narrower `tc` rule moot

`mnexec -a <pid> <any command>` runs an arbitrary command **as root** inside that process's
namespaces. So whatever narrow `tc` rules the sudoers file carries (for example only the
`netem` forms of `tc qdisc add|del|show`), every `tc` form they exclude can be run through
`mnexec` unchanged. A `tc` allowlist is a convenience ("no password for the common actions"),
not a boundary, and a `NOPASSWD` `mnexec` rule makes the account root for practical purposes
inside the lab. Either narrow the `mnexec` rule to specific commands or treat that account as
root; do not keep both and describe the `tc` list as protection. (`ndt` itself does not use
`mnexec` to get around anything; its two `mnexec` call sites are declared in `sudo_surface.sh`.)

### `ovs-vsctl`: a grant the website's manuals do not teach, whose refusal looks like a reading

The probe is `ovs-vsctl list-br` (target `/usr/bin/ovs-vsctl`). Without the grant, a refused
`sudo -n ovs-vsctl list-br` used to be turned into **0 bridges**, which is also the correct
answer for a machine with no OVS at all. The same number then meant two different things, so the
guard of `ndt up p4` ("do not build on top of a live OVS fabric", `guard_no_live_ovs`) did not
fire and an existing fabric could be torn down without a word.

Now `ovs_bridge_count()` answers rc 2 ("cannot tell") for a refusal and `guard_no_live_ovs` treats
"cannot tell" as a reason to stop, so a missing grant **blocks** a bring-up instead of silently
removing someone else's fabric. The grant itself still has to be added. Generate the rule with
`ndt_sudo_rule ovs-vsctl` rather than copying a path, because the target column is whatever
`command -v` resolves on that machine:

```
<your account> ALL=(root) NOPASSWD: /usr/bin/ovs-vsctl
```

`ndt status` prints, for each grant, whether it works or was refused; a refusal is printed as a
refusal, never as a number.

`tests/shell/test_readme_mentions_mnexec.sh` requires this README to carry a paragraph for every
`taught_by=NOWHERE` row of `sudo_surface.sh`, so deleting this section turns that test red.
[Co-developed with claude code -- Adam]

---

## Known limits

- **Mininet is started by hand** (see above).
- **Steps 4-6 are not scripted**: the Visualizer needs a display, the Web-GUI runs in Docker and
  NTG runs inside Mininet; test scenarios need different things, so these are left to a person or
  to per-scenario scripts.
- **The Python checks in L0 verify syntax only**: these scripts have heavy runtime dependencies
  (Mininet, nornir, a live kernel) that cannot be imported at this layer.
- **`ndt down` and `stack.sh down` send SIGTERM, and the kernel installs a handler only for
  SIGINT** (`std::signal(SIGINT, handleSigint)` in `src/main.cpp`). SIGTERM's default action
  terminates the process directly, so a healthy kernel stopped by `ndt down` exits with code
  **143**; `stack.sh` treats 143 as normal (`fatal_exit_status` does not list it). The
  consequence is that the orderly shutdown sequence in `main.cpp` ("Shutdown requested" and "All
  subsystems stopped") does not run on the `ndt down` path; only a manual `kill -INT` (or Ctrl-C)
  reaches it. To see the shutdown sequence itself, stop the kernel with `kill -INT <kernel pid>`.
