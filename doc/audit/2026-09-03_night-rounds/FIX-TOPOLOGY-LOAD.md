# A topology this repo generated, that this repo's kernel could not load

2026-09-03. Branch `fix/topology-load-fails-before-listen`. Evidence:
`doc/audit/2026-09-03_night-rounds/round5-topology-repro/`, logs `01_` and `09_`.
[Co-developed with claude code -- Adam]

## The composition

`tools/make_topology.py --hosts 300` exits 0, prints nothing on stderr, and emits 45 host
addresses of the form `10.0.0.256`..`10.0.0.300` (log `01_`). Its `validate()` asked only
whether the address *strings* were unique, and `10.0.0.256` is unique.

Feed that file to the kernel (log `09_`) and:

| t (s) | what happened |
|-------|---------------|
| 0.50  | `:8000` accepting; `:6343` bound; `Server Listening on port 8000` in the log |
| 1.50  | `terminate called after throwing an instance of 'std::invalid_argument'` / `what(): Invalid IP address: 10.0.0.256`; rc=134, core dumped |

For one full second this kernel was, to every health check and every human, up.

Two lines on stderr, naming neither the file nor the node. With `--topology` pointing at one
of several candidates and 310 nodes inside, that is a diagnostic you have to guess your way
out of -- and this codebase has a documented habit of guessing wrong under exactly that
pressure (a permission denial read as a data-plane failure; an orphaned `curl` read as
"another kernel is almost certainly running").

## Cause

`TopologyAndFlowMonitor::run()` -- the body of the thread `start()` spawns -- opened with three
bare calls, the first being `loadStaticTopologyFromFile`. `main()` returned from `start()`
immediately and went on to bind the sFlow socket and the REST acceptor while the JSON was
still parsing. The thread had no `try`/`catch` anywhere in it, so the throw went straight to
the thread entry, i.e. `std::terminate` -> `abort()`.

## What changed

1. **Ordering (the one that matters).** New `TopologyAndFlowMonitor::loadStaticTopology()`
   loads synchronously, on the caller's thread, returning `false` instead of throwing.
   `src/main.cpp` calls it **immediately after the monitor is constructed** -- before the
   handler and collector objects even exist, so before anything in the process can construct
   an acceptor -- and `return EXIT_FAILURE`s on false. Same shape as the collector's existing
   bind-failure refusal, deliberately. It also fails closed on an empty graph, which is what a
   missing or empty topology file used to produce silently.
2. **The diagnostic.** `loadStaticTopologyFromFile` is now a wrapper around
   `parseStaticTopologyFile`, which records a description of the node or edge it is currently
   reading; any exception is rethrown as
   `topology file "<path>": node #256 "h256" ip=["10.0.0.256"]: Invalid IP address: 10.0.0.256`.
   The describer reads every field defensively -- it runs *while reporting* a failure one of
   those fields caused.
3. **The backstop.** `run()` is now a thin `try`/`catch(...)` around `runLoop()`. Unreachable
   if the above holds; it is what makes "a bad input costs us the poll, not the process" true
   for a shape nobody has thought of yet.
4. **The generator.** `MAX_HOSTS = 252`, derived (`10.0.0.<i>`, octet stops at 254, must divide
   over four edge switches). `build()` **refuses** above it; it does not cap -- quietly handing
   back 252 hosts under a 300-host name is the shape this project keeps getting bitten by.
   `validate()` now runs `ipaddress.IPv4Address` over every address on every node and both ends
   of every edge. `main()` turns the refusal into one stderr line and rc=1, not a traceback.

## Mutation gate

Tests seen failing first: `RefusesToEmitInvalidAddresses` was run against the unfixed
generator -- 3 of 5 red (`ValueError not raised`, `0 == 0 : rc=0 is the defect`,
`AssertionError not raised`). After the fix the whole module is green, 29 tests, including the
24 that predate this change.

**5 mutations, 1 survived.**

| # | mutation | verdict |
|---|----------|---------|
| M1 | `MAX_HOSTS = 100000` | killed (2 failures) |
| M2 | `if hosts > MAX_HOSTS:` -> `if False:` | killed (2 failures) |
| M3 | `addressable()` swallows the `AssertionError` | killed (1 failure) |
| M4 | delete the node-address loop from `validate()` | **survived** |
| M5 | the refusal returns rc=0 | killed (1 failure) |

M4 survives honestly and the test is owed. `test_validate_rejects_an_address_that_is_not_an_address`
rewrites the bad address onto the host node *and* onto its two edges, so the edge loop catches
it and the node loop is never the thing under test. A node-only case is not a one-line addition:
changing a node's `ip` without its edges trips the existing uplink/downlink pairing assert
first, which also raises `AssertionError` and also contains the address, so the test would pass
for the wrong reason. It needs a fixture whose edges are consistent with an invalid node
address. Not written.

## Not done

- **The C++ half is unbuilt and unrun.** `build-topoload/` did not exist, a cold configure plus
  build of this project at `-j2` does not fit the window, and only ~4 GB was free. Nothing in
  items 1-3 above has been compiled. The claim "this compiles" is not made.
- **The ordering gate does not exist.** Item 1's gate must assert *that no port is bound when
  the load fails* -- not merely a non-zero exit, which the process already produces. That is an
  integration test shaped like `round5-topology-repro/run_mutant.sh`: start the kernel on a
  topology with one bad address, poll `:8000`/`:6343` for the process's whole lifetime, assert
  they were never bound and rc != 0, plus a control run on a good topology asserting they *were*.
  It needs the binary. Not written, not run.
- A missing/unreadable topology file still only logs inside `loadStaticTopologyFromFile`; the
  new empty-graph check in `loadStaticTopology()` is what turns it into a refusal. That path
  has no test either.

## Overlap with in-flight work -- read before merging

**Unverified observation of someone else's uncommitted working tree**, not a claim about any
commit: at the time of writing, the shared main worktree had uncommitted modifications to
`TopologyAndFlowMonitor.{hpp,cpp}` (labelled D15) that move those same three calls --
`loadStaticTopologyFromFile`, `initializeMappingsFromGraph`, `configureTopologyApiUrls` -- out
of `run()` and into `start()`, and add `isStaticTopologyLoaded()`. That change fixes the
ordering for a different reason (a startup race with the power manager's bmv2 latch) and, as
seen, adds no `try`/`catch` -- so on its own it would move the abort earlier without turning it
into a clean exit.

This branch was deliberately shaped to compose with it: it does **not** touch `start()`, and
`loadStaticTopology()` is idempotent, so if both land the second load is a no-op. The one
textual conflict to expect is in `run()`, where both changes remove the same three lines.
