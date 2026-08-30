# 07 — Fix evidence: the red, and then the green

Companion to `06_ticket_acquire-lock.md`. Fixes landed in `e29424e` (P-1) and `dff87f9`
(`acquire_lock`); until now the red→green evidence existed only inside those two commit
messages, which is not somewhere a reviewer can check it.

🔑 **Everything below was re-run on 2026-08-30 to produce this file, not transcribed from the
original session.** The house rule is that a cheap failure gets reproduced rather than quoted,
and both of these are cheap: one is a subprocess test, the other is a header change and a
7-target rebuild. Re-running also proved the mutation is still reachable — a red that can only
be quoted is a red nobody can check.

---

## P-1 — the proxy touched switches before it found out it could not have the port

### The mutation

`p4_proxy/proxy_agent/main.py`'s entrypoint reverted to the pre-fix form:

```python
if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8081)
```

### RED — `tests/test_port_guard.py`, port 8081 occupied

```
Ran 3 tests in 58.087s
FAILED (failures=1)

FAIL: test_startup_event_never_runs_when_the_port_is_taken
AssertionError: '[Proxy Agent] Starting up...' unexpectedly found in ...
```

The captured stdout is the finding, not the assertion. In order, before the bind is even
attempted:

```
[Proxy Agent] Starting up...
[1] Setting Forwarding Pipeline Config...
[2] Setting Forwarding Pipeline Config...
 ... through ...
[10] Setting Forwarding Pipeline Config...
[Proxy Agent] 10 of 10 switches have no pipeline ([1..10])
[Proxy Agent] Kernel acknowledged all 0 usable switches
[Proxy Agent] Started LLDP Discovery...
[TopologyManager] link watchdog seeded with 32 declared links
[Proxy Agent] Started LLDP link watchdog...
[Proxy Agent] Started liveness polling...
[Proxy Agent] Shutting down...
INFO:     Application startup complete.
ERROR:    [Errno 98] error while attempting to bind on address ('0.0.0.0', 8081): address already in use
```

**Ten pipeline pushes and LLDP discovery, all above the line that says the port was never
available.** uvicorn awaits `lifespan.startup()` at `server.py:103-104` and binds afterwards;
identical in all three uvicorns installed here (0.49.0 / 0.51.0 / 0.52.1), so not a version
quirk. A guard in the bind-failure path cannot help — the writes have already happened.

The other two tests in the file **passed under the mutation**, and that is deliberate: the
pre-fix code already exited non-zero and already named the port. Those were never the broken
properties, and a test that only checked them would have gone green on a defect.

### GREEN — after restoring the fix

```
Ran 3 tests in 17.803s
OK
```

### The acceptance that actually matters — switch state, not exit codes

From `raw/t7/p1-switchstate-2.log`. sha256 over `table_dump` of all ten switches:

| | digest |
| :--- | :--- |
| D1 baseline | `daf18fe0…` |
| D2 after a quiet interval, nothing launched | `daf18fe0…` ← fabric genuinely still |
| **D3 second proxy, WITH the fix** | **`daf18fe0…`** — unchanged |
| **D4 second proxy, WITHOUT the fix** | **`dc336e41…`** — 10 pipeline pushes |

D2 is what makes D3 mean anything, and D4 is what makes D3 mean anything: without the positive
control, "unchanged" is equally consistent with a measurement that cannot see change.

⚠️ The first attempt at D4 **proved nothing and said so**: it ran the pre-fix copy from
`/tmp/prefix` and died on `could not read topology /tmp/setting/...`, because the agent resolves
its paths relative to cwd — the dependency the User Manual documents. A control that never
reaches a switch cannot show that reaching one is detectable. It was re-run with the entrypoint
swapped in place.

---

## `acquire_lock` — three questions, one behaviour

### The mutation

`LockManager::parseRequest` replaced with the pre-fix logic from `HttpSession.cpp:1917-1931`:
defaults assigned first, `json::parse` in a `try`, and a `catch (...)` that keeps them.

### RED — `LockRequestParsing`, rebuilt and run

```
[  FAILED  ] LockRequestParsing.MalformedBodyIsRefusedRatherThanDefaulted
  Value of: r.ok        Actual: true    Expected: false
  Value of: r.type.empty()  Actual: false   Expected: true
  a malformed body resolved to lock type 'routing_lock'; it must name nothing,
  or garbage acquires the routing lock

[  FAILED  ] LockRequestParsing.MissingTypeIsRefusedRatherThanSubstituted
  no type was requested but 'routing_lock' came back; a caller that believes it
  holds a private lock would be holding the one routing actually uses

[  FAILED  ] LockRequestParsing.InvalidTypeIsDistinguishedFromMissingType
  Value of: r.ok        Actual: true    Expected: false

[       OK ] LockRequestParsing.AllThreeRealLocksAreAccepted
[       OK ] LockRequestParsing.ExplicitTtlIsHonoured
[       OK ] LockRequestParsing.TheShapeBothSiblingAppsSendStillWorks

[  PASSED  ] 3 tests.
[  FAILED  ] 3 tests
```

**3 red / 3 green is the shape to check, not "it failed".** The three that stayed green are the
accept path — including the exact body both sibling apps send. A suite that only refused things
would have passed the first three on its own and told us nothing.

### GREEN — after restoring the fix

```
[==========] 623 tests from 86 test suites ran. (2583 ms total)
[  PASSED  ] 623 tests.
```

### Live, on the built binary

Both directions, judged on state where state is what matters:

| request | status | after |
| :--- | :--- | :--- |
| `{this is not json` | **400** | `routing_lock` **still free** |
| `{"ttl": 30}` (no type) | **400** | still free |
| `{"type":"alpha"}` | **400**, quotes `alpha` — what the caller sent | still free |
| `{"ttl":300,"type":"routing_lock"}` (both sibling apps' shape) | **200** | acquired |
| same again, second client | **423** — busy, not 400 | still held by the first |
| `{"type":"power_lock"}` while routing held | **200** | locks are independent |

The 400/423 split is the third defect: the old code answered every one of these with
`"System busy or invalid lock type: routing_lock"` — one sentence for two unrelated conditions,
quoting a lock the caller never named. 423 means retry; 400 means do not.

---

## Restoration check

Both files are byte-identical to HEAD after the mutations (`git diff --quiet` clean, zero
`MUTANT` markers left). Full suites green: **C++ 623**, **p4_proxy 497** (1 skipped).

[Co-developed with claude code -- Adam]
