# L2 contract tests and log checks

The **L2 layer** of the test layering (L0-L4; see the top of
[../test_workflow/run_layers.sh](../test_workflow/run_layers.sh)). It turns "open the component and
see whether anything looks wrong" into a machine-decided pass/fail.

Nothing needs to be installed: the tools need `python3` only.

---

## Why this exists

The only interface between the kernel and the tools and apps around it is the `/ndt/*` HTTP API.
When the shape of an API answer changes, every component breaks at once, each in its own way, and
that is hard to see from any one component's screen. Checking the contract in one place checks the
foundation of all of them.

---

## The four tools

| Tool | Layer | What it checks |
|---|---|---|
| `run_contract_test.py` | L2 | The kernel's API answers: structure, semantic invariants, error paths |
| `l3_component_check.py` | L3 | Whether every endpoint a component depends on exists and honours its contract |
| `compare_baseline.py` | L4 | The difference between a P4 run and an OVS baseline |
| `check_logs.py` | - | The kernel log: unexpected warnings and errors, crashes |

Stack start-up orchestration and L0/L1 live in [../test_workflow/](../test_workflow/).

---

## Quick start

```bash
cd tools/contract_test

# 1. Check that the test tooling itself is right (no kernel needed)
./run_contract_test.py --self-test

# 2. With a kernel running: read-only checks (they change nothing in the network)
./run_contract_test.py --topology ../../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json

# 3. Once traffic is flowing, add the telemetry checks
./run_contract_test.py --topology <topology file> --with-traffic

# 4. Check a kernel log
./check_logs.py /path/to/kernel.log
```

Both tools exit 0 only on success, so they can be wired into CI.

### Exit code 3: the tool reached no verdict

`run_contract_test.py`, `l3_component_check.py` and `check_logs.py` can exit with **3
(`TOOL-PRECONDITION-FAILED`)**: something the tool needs to know before it can decide could not be
established, so it makes **no claim** about the system. That is different from exit 1 ("the system
is broken").

The reason for the split is power management. When the Energy-Saving-App correctly turns a
switch off, that switch is `is_up=false`, and a checker that reported it as a failure would be red
when the system is right. So:

- Before deciding, L2 and L3 read `/ndt/get_switches_power_state` once. For each switch that is
  `is_up=false` there are three possible answers. The power state says ON: still a **failure**
  (wiring faults are still detected). It says OFF: listed as `accounted for`, not a failure. It
  cannot be read: **exit 3**, no guess.
- `check_logs.py` takes `--powered-off 5,7,9` to declare which switches were switched off.
  `--powered-off none` means "I assert that nothing is off", which is **not** the same as leaving
  the flag out.
- `run_layers.sh` forwards the declaration through the environment:
  `NDT_POWERED_OFF=5,7,9 ./run_layers.sh api ovs` (or `NDT_POWERED_OFF=none`).

`run_layers.sh` treats any non-zero code as a failed layer, so exit 3 still counts as a failure
there (it fails closed); the difference is that the report says that no verdict was reached
instead of naming a fault that does not exist.

---

## run_contract_test.py

### Three kinds of check

**1. Structure.** The answer is valid JSON, the fields exist and have the right types. A failure
points at the exact location:

```
nodes[3].is_up: expected bool, got str ('true')
```

**2. Semantic invariants.** This is what makes "have a look" decidable. Expected values are
**derived from the topology file**, not hard-coded, so the same checks work for the OVS 10-switch
topology and the P4 10-switch/4-host topology:

```
switch(es) not enabled (not connected to a controller): s3(dpid=3)
  -- in P4 mode this usually means the proxy never called /ndt/inform_switch_entered

3 flow(s) with an empty path: 10.0.0.1->10.0.0.4
  -- the Classifier has no flow-table data (check /stats/flow/<dpid>)
```

**3. Error paths.** Feed bad input and require a sensible 4xx: not a 500, and not a pretend
success. These checks catch, for example, an unknown dpid silently forwarded to Ryu, a non-numeric
dpid causing a 500, or a lock that does not answer 423/412 where it should.

### Main options

| Option | Meaning |
|---|---|
| `--topology <file>` | **Required.** The topology file the kernel was started with; the invariants' expected values are derived from it |
| `--with-traffic` | Also require flows, non-empty paths and non-zero rates. Do not use it when no traffic is running; it would report false failures |
| `--allow-mutations` | Run the endpoints that change the network (install rules, change power state, rename). **Off by default** |
| `--url` | Kernel address; default `http://localhost:8000` (or the `NDT_API_URL` environment variable) |
| `--save-json <dir>` | Save every answer to a file. This is how an L4 baseline for the OVS/P4 comparison is captured |
| `--only <name>` | Run only the named check; repeatable. For debugging |
| `--self-test` | Validate the schemas against the examples in `doc/2026-01-02_ndt_api.md`; needs no kernel |

Other options: `--timeout`, `--topk`, `--probe-ip` (see `--help`).

### The lock checks use `graph_lock`

`LockManager::stringToLockType` recognises `routing_lock`, `graph_lock` and `power_lock`; any
other string is `Unknown`, and acquire and renew refuse it. A made-up lock type would therefore
make every lock check fail without ever exercising the mutual exclusion. `graph_lock` is a type
the kernel really knows, and the applications in the workspace do not use it, so the checks run
the real exclusion logic without disturbing a running app.

The checks run a whole life cycle:

```
acquire -> a second acquire must answer 423 -> renew -> release -> acquire again must succeed -> clean up
```

"Acquire again must succeed" is what catches a release that reported success but did not let go.

### `known_gap`: documented kernel defects

A check whose failure is a real, known kernel defect can be marked `known_gap` (with a reason) in
`spec.py`. It then behaves like this:

- It fails: shown as a yellow `GAP` and **not counted as a failure** (otherwise the suite would be
  permanently red and nobody would read it). A gap does not excuse a missing answer or a 5xx.
- It starts to pass: shown as `FIXED`, with a reminder to remove the marker.

At the moment no check in `spec.py` carries a `known_gap`; the mechanism is there for the next one.

### Why mutations are off by default

`--allow-mutations` really installs flow rules and changes power state. That is destructive on a
running system, so it has to be asked for. Read-only checks can be run against a live system at
any time. (The lock checks always run; see above.)

### What `--self-test` does

It validates the schemas against `selftest_fixtures.py`, which holds example answers copied from
`doc/2026-01-02_ndt_api.md` (the self-test itself does not read the document). If a schema does
not accept the document's own examples, the schema is wrong, and noticing that here is much
cheaper than debugging it against a live system.

It also checks every invariant **in both directions**: good data must be quiet and bad data must
raise an error. That is how you know a check is not an always-green light.

---

## check_logs.py

### Core idea

Without an allowlist, "check the log for warnings" stops working once there are more than a few
warnings: a genuinely new problem is drowned by the ones you decided to accept. With an allowlist,
**anything not listed fails**, so a regression cannot hide.

### Verdict rules

| Case | Result |
|---|---|
| `error` / `critical` level | **Fails**, unless listed in the allowlist |
| `warning` level | **Fails**, unless listed in the allowlist |
| Matches a `FORBID` pattern | **Fails at any level** (including info and debug) |
| Matches a `WHEN-POWERED-OFF` pattern, and that dpid was declared with `--powered-off` | **EXPECTED**, not a failure |
| Matches a `WHEN-POWERED-OFF` pattern, but that dpid was not declared | **Fails** (normal level rules apply) |
| Matches a `WHEN-POWERED-OFF` pattern and **nothing was declared at all** | **Exit 3**, no verdict reached |
| Listed in the allowlist but not matched in this run | Reported (so stale entries can be cleaned up; `FORBID` and `WHEN-POWERED-OFF` entries are not reported) |

`WHEN-POWERED-OFF` is a **scoped permission**, not a fourth way to write a warning entry. A line
like `... reported a read failure for switch 5 ...` is the kernel's correct, conservative handling
when switch 5 has been switched off; when switch 5 has not been switched off it is a real defect (a
wedged Ryu reporting zero rules on every switch). Writing it as a plain `WARNING` would turn this
tool into something that hides that defect. So the pattern must capture the switch with
`(?P<dpid>\d+)`, and `check_logs.py` refuses to load a `WHEN-POWERED-OFF` rule without that group.

### Crash detection (not affected by the allowlist)

Crash messages are printed by the runtime, not by spdlog, so they do not match the log format and
would be dropped by `--ignore-unparsed`, which would put the most important signal in a blind
spot. Every line is therefore scanned first, whether or not it parses, for things such as:

```
terminate called after throwing / what():        <- std::terminate
Segmentation fault / core dumped / SIGSEGV       <- memory error
Floating point exception / SIGFPE                <- integer division by zero
Assertion ... failed / std::bad_alloc            <- assertion, allocation failure
AddressSanitizer / double free / pure virtual    <- other fatal errors
```

(The full list is `CRASH_PATTERNS` in `check_logs.py`.) These **always fail and cannot be
allowlisted**.

### Error-path checks pollute the log: use `--to-line`

The L2 error-path checks make the kernel write ERROR and WARN lines **on purpose** (malformed JSON,
unknown dpid, non-numeric dpid, nonexistent endpoints). Checking the whole log would make this
layer permanently red for a reason the test itself caused, and that trains readers to ignore it.

`run_layers.sh` solves this by recording the log's line count **before** running L2 and checking
only the part before that point:

```bash
./check_logs.py kernel.log --to-line 120   # look only at the first 120 lines
./check_logs.py kernel.log --from-line 50  # skip the first 50 lines (e.g. leftovers from a previous run)
```

Crash detection ignores the window and always scans everything.

### Why FORBID exists

Some messages are logged at a level lower than their real severity. For example
`Unsupported SFlow Version` is logged at `WARN`, but it means **all telemetry is being dropped**
and the twin's data is empty. `FORBID` makes such a message fail the check at whatever level it is
logged. FORBID violations are **not** offered by `--suggest-allowlist`: they are to be fixed, not
waved through.

### Allowlist format

`warning_allowlist.txt`, three fields separated by a pipe **with spaces around it** (`" | "`):

```
LEVEL | python regex | why it is acceptable
```

It is not a bare `|`, so regex alternation still works: write `(int|float)` with no spaces around
the pipe. `LEVEL` is `WARNING`, `ERROR`, `FORBID` or `WHEN-POWERED-OFF`.

The regex is matched against the **message text** only (timestamp, level, file name and line, and
function name are stripped first, and ANSI colour codes are removed), so you do not need to deal
with the prefix.

### Adopting it on an existing log

An existing log probably has plenty of warnings already. Generate a starting list:

```bash
./check_logs.py kernel.log --suggest-allowlist
```

It prints allowlist lines you can paste (numbers are generalised to `\d+`, so one rule covers many
instances). **Do not paste blindly.** The value of the mechanism is that it forces a decision on
each warning, "is this one really acceptable?", instead of silencing them all. Every entry needs a
reason.

### Cleaning up

The tool reports entries that are in the allowlist but did not match this time, so the list does
not collect junk over the years. FORBID rules are never listed as unused: a FORBID that does not
match means the system is healthy, which is what we want.

---

## l3_component_check.py

L2 asks "is the kernel's API right?". L3 asks "**which components will break?**". After changing
an endpoint you can see the blast radius without starting every tool.

```bash
./l3_component_check.py --map                          # offline: the dependency map
./l3_component_check.py --blast-radius get_graph_data  # offline: which components are affected
./l3_component_check.py --topology <topology file>     # the full check
./l3_component_check.py --topology <topology file> --component Web-GUI
```

### Two kinds of check

**1. Existence.** Every endpoint a component calls must exist. A 404 means the component is
calling something the kernel does not implement.

The probe **must use the right HTTP method**: the kernel matches on `(method, target)` together,
so a GET to a POST-only endpoint falls through to 404 and looks like a missing endpoint.

**2. Contract.** For the endpoints that `spec.py` covers, the L2 checks are run and failures are
attributed to the components that depend on that endpoint.

A 5xx does not count as "the endpoint exists": a route that throws on a minimal request still
gives its consumers a 5xx, so it is reported as a problem.

### `--check-drift`: keep the hand-copied table honest

`KERNEL_ENDPOINTS` in `components.py` is **transcribed by hand** from the if/else chain in
`HttpSession.cpp`. If someone adds an endpoint and forgets the table, L3 would report the new
endpoint as "not in the dispatch table".

```bash
./l3_component_check.py --check-drift
```

This reads `HttpSession.cpp` and compares. It catches all three kinds of drift: an endpoint left
out, a wrong method (which would make the probe use the wrong method and misreport a 404), and an
entry for an endpoint that has been removed. `--map` also prints a warning first when the table is
stale.

### Known gaps versus new gaps

Same principle as the other allowlists: known gaps are registered in `KNOWN_MISSING_ENDPOINTS` in
`components.py`, each with a reason, so a **new** missing endpoint fails instead of being lost among
the tolerated ones.

- Known gap: yellow `KNOWN GAPS` / `DEGRADED`, exit 0.
- Unregistered gap: red `UNACKNOWLEDGED`, exit 1.

### Why the map is useful

`--blast-radius get_graph_data` lists every component that reads it; a break there is a break
almost everywhere. That endpoint and the detected-flow data both depend on sFlow telemetry, which
is the most fragile part in P4 mode, so test effort should concentrate there.

---

## compare_baseline.py

The cheapest way to develop the P4 path: **the OVS path is known to work**, so use its behaviour as
the specification instead of guessing what P4 "should look like".

```bash
# Capture once on a healthy OVS stack
./run_contract_test.py --topology <ovs topology> --with-traffic --save-json baseline/ovs

# Capture the same way for P4, then compare
./run_contract_test.py --topology <p4 topology> --with-traffic --save-json result/p4
./compare_baseline.py baseline/ovs result/p4
```

### Why not a plain JSON diff

The two sides have different topologies (128 hosts versus 4), and rates, counters and timestamps
change every second. So only two things are compared, the ones that should be the same on any data
plane:

**1. Shape.** A recursive set of "field path -> type". It catches a field disappearing, a type
changing and, most importantly, **one side having data where the other is empty**, which is how P4
stubs usually show up. List indices are collapsed to `[]`, so 4 hosts and 128 hosts have the same
signature.

**2. Behavioural facts.** A boolean per endpoint: are all switches up? Is the flow path filled in?
Is the rate non-zero? Is the table non-empty? These answers must agree even when the values
differ.

### Empty lists

When P4 returns `[]`, an early version reported every field of every OVS element as "missing":
twenty lines of noise for one real difference. It now collapses to a single conclusion:

```
[empty] list is empty in P4 but populated in OVS: <root list>
```

### Allowlist

`baseline_diff_allowlist.txt`, same format as the log allowlist (`endpoint | regex | reason`).

A difference falls in exactly one of three classes:
1. **An allowed P4 limitation**: write it in the allowlist and say what removes it.
2. **Within numeric tolerance**: handled by the tool (fields such as `_bps`, `_rate` and `_count`
   are compared by type only).
3. **Anything else is a bug.**

There is no fourth class, so every "P4 cannot do this" is written down instead of silently broken.

The end of the file lists, as comments, examples that must **not** be added to the allowlist (for
example `all_switches_enabled`): that is exactly the kind of defect the comparison exists to catch,
and allowing it would defeat the purpose.

The tool also reports entries that were registered but not used this time; that usually means the
limitation has been fixed and the line should be deleted.

---

## Suggested rhythm

| When | Run |
|---|---|
| After changing code | `--self-test` (seconds, no kernel) |
| At the end of each development phase | The read-only checks plus `check_logs.py` |
| Once traffic is flowing | Add `--with-traffic` |
| To verify the write paths | Add `--allow-mutations` |
| Before a demo | Run OVS and P4 once each, saving with `--save-json`, and compare |

---

## Files

| File | Purpose |
|---|---|
| `run_contract_test.py` | L2 main program (CLI, HTTP, report) |
| `spec.py` | Endpoint definitions and semantic invariants |
| `schema.py` | Minimal schema validator (no dependencies) |
| `selftest_fixtures.py` | Examples from `doc/2026-01-02_ndt_api.md`, for `--self-test` |
| `components.py` | Per-component endpoint dependencies, the kernel dispatch table, known gaps |
| `l3_component_check.py` | L3 component contract check |
| `compare_baseline.py` | L4 OVS/P4 comparison |
| `baseline_diff_allowlist.txt` | Acceptable OVS/P4 differences |
| `check_logs.py` | Log checker |
| `warning_allowlist.txt` | Acceptable warnings |

### Field separator in the allowlists

All three allowlist files separate fields with a pipe **with spaces around it** (`" | "`), not a
bare `|`. That keeps regex alternation usable: `(int|float)` (no spaces around the pipe) is not
mistaken for a field separator.

### Adding an endpoint check

Edit `ENDPOINTS` in `spec.py` and add a dict with `name`, `method`, `path`, `category` (`READ`,
`MUTATE` or `ERRORPATH`), `schema` and, if needed, `invariants`.

If you add a schema, add an example for it to `selftest_fixtures.py` so that `--self-test` guards
it.

---

## Known limits

- **Coverage.** Not every registered endpoint has a contract: the group and meter endpoints
  (`install_`/`modify_`/`delete_` `group_entry` and `meter_entry`), `get_sflow_stats` and
  `inform_all_destination_paths` have none, and none of them has a consumer among the components.
  Do not copy a number from this file; recompute it:

  ```bash
  python3 -c "
  import sys; sys.path.insert(0,'.')
  import spec, components
  covered = {e['path'].removeprefix('/ndt/') for e in spec.ENDPOINTS}
  kernel = set(components.KERNEL_ENDPOINTS)
  print('registered:', len(kernel), 'covered:', len(covered & kernel))
  for e in sorted(kernel - covered):
      print('  UNCOVERED', e, components.blast_radius(e) or '-')"
  ```
- **The `--with-traffic` invariants assume traffic is running.** On a system where traffic has just
  stopped they report false failures.
- **The success path of `intent_translator/text` deliberately has no contract.** It needs an OpenAI
  token, costs money per call, and the answer is model-dependent, so a contract would be unstable
  and expensive. The error path has one (no token needed), and the Web-GUI's dependence on the
  success path is covered only by the L3 existence check.
- **The simulation endpoints are checked on their error paths only.** The success path of
  `received_a_simulation_case` and `simulation_completed` needs the Simulation-Platform-Manager
  running, which would make the checks unstable; their input validation (malformed JSON must not
  give a 500) can be checked and is.
- **The group and meter endpoints have no contract.** `FlowRoutingManager` dispatches them by the
  `dpid` in the payload (`dispatchByPayloadDpid`), so the P4 strategy can refuse them explicitly,
  but L2 does not exercise that routing.
- **Invariants have a limit on strictness.** `inv_graph_matches_topology` compares the three
  counts, the dpid set and per-node identity (switches by `brand_name` and address set against
  dpid; hosts by address set against `mac`; `device_name` is only reported as accounted for, since
  a rename is persisted by design). It does **not** verify that the edges are wired correctly (the
  right count with wrong endpoints passes), and it cannot see fields `get_graph_data` does not
  return. A topology file that is itself wrong, faithfully served by the kernel, is also
  invisible to it: the graph agrees with the file. `inv_flow_paths_non_empty` checks only that a
  path is non-empty, not that it is connected or consistent with the edges. `inv_topk_bounded`
  checks that there are at most k entries, not that they are really the k largest.
- **The HTTP protocol layer is not checked**: CORS / `OPTIONS` (which the Web-GUI depends on),
  keep-alive, request body size limits, boundary values of the `k` parameter.
- **Concurrency is not checked.** The kernel serves requests on `hardware_concurrency()` threads
  that share one `io_context`. L2 and L3 send their requests one at a time, so neither contention
  nor a slow handler (SNMP, SSH, a synchronous curl to Ryu) tying up a thread is ever exercised.
- **The sFlow UDP input is not exercised.** The kernel has two external input surfaces (`/ndt/*`
  over HTTP and sFlow over UDP on :6343); only the first is covered here.
- **Process health (RSS, thread count, exit code) has no tool.** `check_logs.py` catches crash
  messages, but memory leaks and thread leaks are not detected.

[Co-developed with claude code -- Adam]
