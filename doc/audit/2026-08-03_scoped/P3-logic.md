# P3 — new logic that can silently do nothing

Scope: `be3c242..576dd2a` only. Worktree `/tmp/audit-576dd2a`.

[Co-developed with claude code -- Adam]

---

### `KeyedFailureLog`'s hold-off resets on any single quiet pass, so an intermittent failure is reported never

- **File:line** — `include/utils/KeyedFailureLog.hpp:119-133` (the pruning loop), used with a 15 s
  hold-off at `src/ndt_core/collection/FlowLinkUsageCollector.cpp:2270`. `f5281a8`
- **Severity** — **high**. This class exists to make a specific class of fault visible, and its
  failure mode is silence. The warning it replaced — `edge not found by dpid/port 4:3` — was the
  answer to the P4 host-port bug; under the new rules that answer is only printed if the flow
  carrying it is present in **every one of ~15,000 consecutive passes**.
- **Confidence** — verified for the suppression itself; the live path is argued below from the
  callers.
- **How I checked** — `endPass()` erases any open key absent from the current pass, whether or not
  it was ever reported (`KeyedFailureLog.hpp:119-133`), so `firstSeen` is re-set from scratch the
  next time it appears. Persistence is therefore measured over *uninterrupted* presence, not
  cumulative presence. Compiled the real header standalone (`scratchpad/probe_keyedlog.cpp`,
  `g++ -std=c++17 -I/tmp/audit-576dd2a/include`) and drove it with the loop's real cadence — 1 kHz
  passes, 15 s hold-off, 10 minutes of simulated time:

  ```
  A: failure present in 99% of 600000 passes over 10 minutes -> reported 0 time(s)
  B: 10 s bursts of a permanently-broken flow, 10 minutes    -> reported 0 time(s)
  C: continuously present for 60 s                           -> reported 1 time(s)
  ```

  Case A is the important one: a fault that is true 99 % of the time, for ten minutes, produces
  **no output at all**.

  Reachability in `calFlowPathByQueried`: every key is recorded only while a flow that provokes it
  is in the snapshot taken at the top of the pass (`FlowLinkUsageCollector.cpp:2277-2283`), and
  `purgeIdleFlows` erases flows after `FLOW_IDLE_TIMEOUT` (15,000 ms — the same 15 s, by
  coincidence) and `handlePacket` re-creates them on the next sample. So key presence is not
  monotonic: it tracks traffic. Any pass in which the flow table is momentarily empty — between
  bursts, at the start of a test run, after a purge — clears every unreported key. The same applies
  within a single flow's walk, which `break`s at the first failure, so a flow that fails at
  different hops on different passes accumulates nothing under either key.
- **Failure scenario** — the P4 host-port bug (`doc/2026-07-29_HANDOFF.md` §1d) rediscovered today with the
  runbook's own traffic recipe. `h1 ping -c 30000 -i 0.01 -q h4` runs for 27 s; a 20 s iperf burst
  runs for 20 s. Both are longer than 15 s of wall clock but neither guarantees 15,000 *consecutive*
  passes with the flow present, and a burst under 15 s guarantees the opposite. The run finishes
  with a clean log and the misconfigured port unmentioned. Before `f5281a8` the same run printed the
  answer 27,000 times; the fix for "too loud to read" has landed on "silent".
- **Suggested fix** — make persistence cumulative rather than consecutive: keep an entry in `m_open`
  for a grace period after it stops being recorded (say 2 × `reportAfter`) instead of erasing it
  immediately, and only emit the recovery line when that grace period expires. That preserves the
  startup hold-off it was built for (a genuinely transient miss clears and stays cleared) while a
  flapping fault accumulates. Whatever the mechanism, the property to test is the one the current
  tests do not cover: *a failure present in most but not all passes must eventually be reported.*

---

### `endPass()`'s "called twice" warning describes the wrong consequence

- **File:line** — `include/utils/KeyedFailureLog.hpp:90-91`, `f5281a8`
- **Severity** — medium as a comment (the brief asks for wrong comments); low as behaviour, since
  the sole caller invokes it once per pass and correctly.
- **Confidence** — verified
- **How I checked** — the comment says: *"Calling it twice would report the same recovery twice and
  then treat every still-failing key as new."* The first clause is wrong. A recovered key is
  `erase`d in the same call that reports it, so it cannot be reported again. What a second call
  actually does is report **every still-open, already-reported key as recovered** — for failures
  that have not recovered at all — and then erase them. Probe case D:

  ```
  D: first endPass  -> new=1 recovered=0 open=1
  D: second endPass (nothing recovered in reality) -> new=0 recovered=1 open=0
  ```

  So the hazard is a false "cleared after N pass(es)" INFO line for a fault that is still live, plus
  a reset hold-off — strictly worse than the comment implies, because a duplicate line is noise
  while a false recovery is a wrong statement about the network.
- **Failure scenario** — a future caller adds an early `continue` or a second drain point and calls
  `endPass()` twice in one pass. The log reads "path-walk failure 'dpid-port:4:3' cleared after 900
  pass(es)" while it is still failing, and `check_logs.py` sees an INFO, not a WARNING.
- **Suggested fix** — correct the comment to say what happens, and consider making it structural:
  have `endPass()` take the pass as a parameter, or assert that at least one `record()` or an
  explicit `beginPass()` happened. A comment is the weakest possible guard for something this easy
  to get wrong.

---

### `utils::describeCommandStatus` blames `ovs-vsctl` and `sudo` for every command's exit 1 and 127

- **File:line** — `include/utils/Utils.hpp:330-341`, `65aaa38`
- **Severity** — medium. It is a diagnostic that sends an operator to the wrong place, in a
  codebase whose documented lessons are mostly about diagnostics.
- **Confidence** — verified
- **How I checked** — the decoder was correct where it came from (`DeviceConfigurationAndPowerManager`,
  which only runs `ovs-vsctl`). Moving it into `utils::` also wired it into
  `utils::execCommand` (`Utils.hpp:377`), which is the generic shell-out used for everything:

  ```
  $ grep -rn "execCommand(" --include=*.cpp src | grep -v Utils.hpp
  .../SimulationRequestManager.cpp:127        curl to the simulator server
  .../HttpRoutingStrategyBase.cpp:70          curl to Ryu / the P4 proxy
  .../TopologyAndFlowMonitor.cpp:385,398,411  curl to the control plane
  .../DeviceConfigurationAndPowerManager.cpp  snmpget / snmpwalk, 13 sites
  .../FlowLinkUsageCollector.cpp:2013         curl all_destination_paths
  ```

  Any of those exiting 127 now prints "command not found -- is ovs-vsctl installed?", and any
  exiting 1 prints "ovs-vsctl refused; a sudo password prompt does this on a process with no
  controlling terminal". `snmpget` exits 1 on a timeout or an unknown OID, and exits 127 when
  net-snmp is not installed — which is the TESTBED path, where nobody is running `ovs-vsctl` at all.
- **Failure scenario** — TESTBED mode, net-snmp not installed. Every power reading logs "is
  ovs-vsctl installed?" and the operator spends the afternoon on Open vSwitch. `doc/2026-07-29_HANDOFF.md`
  §1j's lesson 4 is that a misleading log costs more than a missing one.
- **Suggested fix** — take the command (or a short tool name) as a second parameter and interpolate
  it: `describeCommandStatus(rc, "ovs-vsctl")`. Keep the sudo hint only when the caller says the
  command was run under sudo — the OVS strategy and the liveness probe can both pass it; nothing
  else should.

---

### `handleGetNickname` logs a bad `?dpid=` under the name of a different endpoint

- **File:line** — `src/ndt_core/http/HttpSession.cpp:1387`, `832d75c`
- **Severity** — low as behaviour (the 400 is correct), medium as a diagnostic
- **Confidence** — verified
- **How I checked** — the parse guard was copy-pasted from `handleInformSwitchEntered` into
  `handleGetNickname` without editing either the comment or the message. The block sits inside
  `handleGetNickname` at an indentation level that gives it away:

  ```cpp
  // src/ndt_core/http/HttpSession.cpp, inside handleGetNickname
              // [Co-developed with claude code -- Adam]
      // std::stoull threw on `?dpid=abc` ... -- the L2 failure
      // inform_switch_entered__bad_dpid. ...
      const auto dpidOpt = utils::tryParseUint64(dpidStr);
      if (!dpidOpt)
      {
          SPDLOG_LOGGER_WARN(Logger::instance(),
                             "inform_switch_entered: dpid '{}' is not an unsigned integer",
                             dpidStr);
  ```

  Both the comment ("this is the L2 failure inform\_switch\_entered\_\_bad\_dpid") and the WARN text
  name an endpoint this code is not in. The comment is wrong, which is the one comment category the
  brief keeps in scope.
- **Failure scenario** — a caller mistypes `GET /ndt/get_nickname?dpid=s1`. The log says
  `inform_switch_entered: dpid 's1' is not an unsigned integer`, so whoever reads it goes looking at
  the Ryu-facing switch-entry path, or greps `intelligent_router.py` for a bad notification, and
  finds nothing wrong there. Two identical messages from two endpoints also make the log unusable
  for telling them apart.
- **Suggested fix** — change the message to `get_nickname:` and delete the copied comment (the
  reason is already recorded once, at the real site). While there: the surrounding `try`/`catch`
  block is now dead — `tryParseUint64` does not throw and `findSwitchByDpid` is not documented to —
  so `Invalid DPID format` is unreachable.

---

## Checked and found sound

- **`powerOff`'s refusal cannot strand a switch.** When `executeListPorts` returns `nullopt`,
  `powerOff` returns 500 and leaves the vertex up (`OVSPowerStrategy.cpp:137-143`). I traced what
  happens next: the bridge is untouched, so the twin and the network still agree; a transient sudo
  failure clears on retry; and if the bridge is genuinely gone, `pingWorker`'s three-state
  `ovsLivenessFor` marks the vertex down independently of this path. So "refuse" does not become
  "stuck up forever" — but it does depend on the liveness probe running, which is worth knowing.
  The one remaining hole is the one the tests already record and do not endorse: `powerOn` with no
  saved ports builds an empty bridge and reports success
  (`PowerOnWithNoSavedPortsStillReportsSuccessButBuildsAnEmptyBridge`). I looked for others in this
  file and did not find any — every command now goes through `executeSystemCommand`, and
  `m_lastCommandFailed` gates both `setVertexUp` and `setVertexDown`.
- **`describeCommandStatus`'s `errno` read is valid at all three call sites.** The brief asked
  specifically. `errno` is only consulted on `status == -1`, and at each site nothing runs between
  the `pclose`/`std::system` and the call: `Utils.hpp:374-378` (comparison only),
  `OVSPowerStrategy.cpp:18-22` and `:53-60` (the value is an argument to the SPDLOG macro, whose
  only other work is `should_log` and a `shared_ptr` copy). The `status == -1` check also correctly
  precedes `WIFSIGNALED`/`WIFEXITED`, which are not meaningful on -1.
- **The new `<sys/wait.h>` and `<cstring>` in `Utils.hpp` break nothing.** Full clean build of every
  target with `-Werror`, no warnings, 207 tests green. `Utils.hpp` is included nearly everywhere, so
  this was worth confirming rather than assuming.
- **`tryIpStringToUint32` does not widen what the endpoints accept.** It uses `inet_aton`, and so
  does the pre-existing throwing `ipStringToUint32` (`Utils.hpp:124`) — so the short forms
  (`"10.1"` → 10.0.0.1, `"1"` → 0.0.0.1) were already accepted before this diff, and
  `TheShortFormsInetAtonAcceptsAreDocumentedNotAssumed` records rather than introduces them.
  `tryParseUint64` is genuinely stricter than `stoull` in every way its tests claim.
- **`HONOURED_MATCH_FIELDS` is complete for what actually calls it.** I read both real callers
  rather than reasoning about them. `Traffic-Engineering-App.py:337` and `:501` send
  `{"eth_type": 2048, "ipv4_dst": ...}`; `Energy-Saving-App/src/app/http.cpp:153` sends
  `{"eth_type", 2048}, {"ipv4_dst", ...}`. Both are inside the honoured set with the right eth\_type,
  so nothing that works today starts getting a 400. (The `# TODO: Change to match 5-tuple in HPE` at
  `Traffic-Engineering-App.py:332` is the case that *will* be refused, which is the intent.)
- **The 400 does reach the caller, at the proxy layer.** `api_routes.py` catches
  `UnsupportedMatchError` on all three endpoints and raises `HTTPException(400, detail={...fields})`
  rather than letting it become a 500; the kernel's `HttpRoutingStrategyBase` already treats
  non-2xx as failure. What is missing is a *test* of that, not the behaviour — see P1.
- **`Classifier::knowsSwitch` is monotonic.** I checked whether it could flip false→true→false and
  so make the `no-table:` / `no-rule:` keys alternate: `updateFromQueriedTables`
  (`Classifier.cpp:1276`) only ever adds or updates, never erases, so once a switch is known it
  stays known. The `lookup()`/`knowsSwitch()` pair does take the lock twice, but the second call
  only picks the wording of a log line.
