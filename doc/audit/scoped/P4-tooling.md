# P4 — the test tooling

Scope: `be3c242..576dd2a` only. Worktree `/tmp/audit-576dd2a`.

[Co-developed with claude code -- Adam]

The brief's standard for this group is that a false PASS here is worse than a bug in the kernel.
Two of the four findings below are false PASSes; one is a false FAIL that will get the guard
disabled, which amounts to the same thing.

---

### `wait_for_port`'s "is the port ours?" check is unreachable, and the stray-process case it exists for still passes

- **File:line** — `tools/test_workflow/stack.sh:324-357`, `a059bb5`
- **Severity** — **high**. This is the guard against the failure `doc/HANDOFF.md` §1j calls out as
  having bitten three times, including one whole P4 session that silently measured a leftover OVS
  kernel (288 edges, 128 hosts). The guard does not do what its comment says.
- **Confidence** — verified for the control flow; probable for the exact live timing (I did not
  start a real kernel against a held port)
- **How I checked** — the two checks in the loop are textually identical and run in the same
  iteration with only `port_open` between them:

  ```bash
  for _ in $(seq 1 $((timeout * 2))); do
      if [[ -n "$component" ]] && ! is_running "$component"; then
          echo " died"; ...; return 1
      fi
      if port_open "$port"; then
          if [[ -n "$component" ]] && ! is_running "$component"; then   # <- same condition
              echo " not ours"; ...; return 1
          fi
          echo " up"; return 0
      fi
      printf '.'; sleep 0.5
  done
  ```

  If the inner condition were true, the outer one would already have returned. So the inner branch
  can only fire if the process dies in the microseconds between them — not "another process holds
  the port", which is what the comment claims it detects. I reproduced the flow verbatim with
  `is_running`/`port_open` stubbed (`scratchpad/wfp_demo.sh`), modelling a stray holding the port
  from the start:

  ```
  ### our kernel still alive on the first two polls (start_bg has just returned):
    waiting for kernel API on :8000  up
    -> exit=0        # stack.sh proceeds and measures the stray process

  ### our kernel already gone before the first poll:
    waiting for kernel API on :8000  died          -> exit=1

  ### alive on poll 1, dead by poll 2 -- the only window the inner check covers:
    waiting for kernel API on :8000  not ours      -> exit=1
  ```

  Which of those three you get is decided entirely by whether the component has *already* exited
  when the first `is_running` runs. It normally has not: `start_bg` is
  `setsid "$@" >"$log" 2>&1 &` followed immediately by `echo $! > pidfile`
  (`stack.sh:258-267`), and `wait_for_port` is called on the next line with no sleep — so the
  first poll happens within a millisecond or two of the fork, long before the kernel has finished
  dynamic linking, let alone reached `bind()`. `port_open` (bash `/dev/tcp`) then succeeds against
  the stray, and the function reports **up**.

  Note also that the pid recorded is the `setsid bash -c "cd … && ./bin/ndtwin_kernel …"` wrapper,
  not the kernel itself, which widens the window further.
- **Failure scenario** — exactly the one in the comment. A kernel is left running on `:8000`
  (started by hand, or by a `down` that could not kill a root-owned process). `stack.sh up p4`
  starts a new kernel, which dies of `bind: Address already in use`. `wait_for_port 8000 "kernel
  API" 40 kernel` polls once, sees the wrapper alive and the port open, prints `up`, and the entire
  run — graph, telemetry, any captured baseline — is about the wrong process in the wrong mode.
- **Suggested fix** — check ownership rather than liveness. After `port_open` succeeds, confirm the
  listener is the component's own pid (or a descendant of it):
  `ss -ltnpH "sport = :$port" | grep -q "pid=$(cat "$PID_DIR/$component.pid")"`, falling back to
  `pgrep -P` for the wrapper case. Failing that, at minimum record whether the port was **already
  open before `start_bg` ran** and refuse if it was — that alone catches every stray case without
  needing `ss`, and it can be done in `cmd_up` before starting anything.

---

### `_is_routable_unicast` lets `inv_flow_paths_non_empty` pass while checking nothing

- **File:line** — `tools/contract_test/spec.py:220-241` and `:252-254`, `f5281a8`
- **Severity** — medium. The invariant is described in its own docstring as "the second highest-value
  P4 invariant"; it can now report success having examined zero flows, with no output saying so.
- **Confidence** — verified (by reading; the degenerate case is arithmetic on the filter)
- **How I checked** — the change is

  ```python
  bad = [f"{f['src_ip']}->{f['dst_ip']}" for f in data
         if not f["path"] and _is_routable_unicast(f["dst_ip"])]
  if bad: ...
  ```

  If every flow in the sample is multicast, broadcast or link-local, `bad` is empty and the
  invariant passes — indistinguishably from "every flow had a path". Nothing counts how many flows
  survived the filter. The docstring says the exclusion was added because a real run failed on
  `192.168.123.16 -> 224.0.0.251` (Avahi mDNS), i.e. samples dominated by non-unicast traffic are
  a thing that happens on this machine. A short, quiet capture window — which is precisely when the
  check matters least and is most likely to be trusted anyway — can consist of nothing but mDNS
  and ARP-adjacent chatter.

  The exclusion logic itself is right where it matters: `first_octet = ip_u32 & 0xFF` is correct for
  `in_addr::s_addr` on a little-endian host, 224–239 is 224/4, and the link-local test reads the
  second octet correctly. The one loose end is that the `first_octet == 255` branch is commented
  "broadcast" but only excludes 255.0.0.0/8 — a directed broadcast such as `10.0.0.255` has first
  octet 10 and is still required to have a path. That is over-strict rather than over-permissive,
  so it fails loudly if it ever fires; not worth changing on its own.
- **Failure scenario** — `run_layers.sh` L2 on a P4 run whose sampling window caught only mDNS.
  `inv_flow_paths_non_empty` reports PASS. The next reader concludes paths resolve in P4 mode.
- **Suggested fix** — count the flows that passed the filter and fail (or at minimum print a loud
  note) when it is zero: `checked = [f for f in data if _is_routable_unicast(f["dst_ip"])]`, then
  `if not checked: return ["no routable-unicast flows in the sample; this invariant checked nothing"]`.
  The existing "0 hits" reporting for allowlist rules (`compare_baseline.py:378`) is the same idea
  applied to the other file — this check deserves it too.

---

### `kernel_owns_log` cannot see a root-started kernel, so the log layer hard-fails on the documented startup method

- **File:line** — `tools/test_workflow/run_layers.sh:117-131` and its use at `:145-153`, `f5281a8`
- **Severity** — medium. A false FAIL, but on the path the user manual teaches, which means the
  guard will be read as broken and worked around.
- **Confidence** — verified
- **How I checked** — the check is
  `readlink -f /proc/"$pid"/fd/* 2>/dev/null | grep -qxF "$target"`. `/proc/PID/fd` is mode 0500
  owned by the process's uid:

  ```
  $ ls -ld /proc/1/fd
  dr-x------ 2 root root 295 Jul 31 20:20 /proc/1/fd
  $ ls /proc/1/fd
  ls: cannot open directory '/proc/1/fd': Permission denied
  ```

  So for a kernel started as root the glob matches nothing, `readlink` finds nothing, the loop falls
  through, `kernel_owns_log` returns 1, and `run_logcheck` prints "*is not being written by any
  running kernel*" plus "*this layer would report on a stale file, so it is checking nothing*" and
  `return 1`s. `doc/HANDOFF.md` §5 records that the manual teaches `sudo -E bin/ndtwin_kernel` and
  that the kernel is often root-owned — the same section that warns a normal-user `pkill` cannot
  kill it.
- **Failure scenario** — operator follows the manual, starts the kernel with `sudo -E`, runs
  `./run_layers.sh`. Every layer passes except the log check, which fails with a message asserting
  the log is stale when it is being written live. The natural response is to stop trusting the
  check — which is how the previous generation of allowlist noise got where it did.
- **Suggested fix** — treat "cannot inspect" as a third state rather than as "not ours", exactly as
  `ovsLivenessFor` does for the OVS probe. If `pgrep -x ndtwin_kernel` finds a pid but
  `/proc/$pid/fd` is unreadable, say so and fall back to a weaker signal (log mtime within the last
  N seconds) rather than failing. `sudo -n readlink` is the other option but adds a sudo dependency
  to a read-only check.

---

### Two surviving allowlist patterns are much broader than their new justifications

- **File:line** — `tools/contract_test/baseline_diff_allowlist.txt:88-89`, `22e1176` / `dac192b`
- **Severity** — medium
- **Confidence** — verified for the matching semantics; probable for the specific regression they
  would hide (I have no live P4 baseline here to produce one)
- **How I checked** — twelve entries were correctly pruned in this diff. The two that remain had
  their *reasons* rewritten while their *patterns* were left alone:

  ```
  get_switch_openflow_table_entries | field missing in P4: \[\]\.flows | P4 entries match on dst IP
      only (ipv4_lpm), so OVS-only match fields like dl_dst and in_port are genuinely absent
  get_switch_openflow_table_entries | type differs at \[\]\.flows | numeric field widths differ
      between P4Runtime reads and Ryu stats for the same logical rule
  ```

  Matching is `self.regex.search(detail)` — unanchored (`compare_baseline.py:206-208`). So the first
  pattern suppresses **any** field missing anywhere under `[].flows`, not just match fields:
  `actions`, `priority`, `packet_count`, `table_id`. The second suppresses **any** type difference
  under `[].flows`, not just numeric widths — `actions` becoming a string instead of a list would be
  covered. The justifications name a narrow subset; the patterns do not encode it.

  This is the shape the brief flags: an entry too broad hides a real regression. The file already
  demonstrates the cost — `f5281a8` removed one entry after the suppressed warning turned out to
  fire 75,853 times.
- **Failure scenario** — Phase 3 wires `route_flow` to the ternary `flow_5tuple` table and the
  proxy stops reporting `actions` on read-back. Every entry loses its `actions` field, L4 says PASS,
  and the difference is invisible until someone reads a flow table by hand.
- **Suggested fix** — anchor them to what the reason actually claims:
  `field missing in P4: \[\]\.flows\[\]\.(dl_dst|dl_src|in_port|nw_src|tp_src|tp_dst)` and, for the
  type entry, name the fields whose widths differ. If the real detail strings do not support that
  shape, split the entry per field. `compare_baseline.py` already reports rules with zero hits
  (`:378`), so over-narrow entries announce themselves cheaply — the asymmetry favours being too
  specific.

---

### `stack.sh down` fails on any listener on 8000/8080/8081, and asserts it is not ours without checking

- **File:line** — `tools/test_workflow/stack.sh:576-596`, `a059bb5`
- **Severity** — low
- **Confidence** — verified
- **How I checked** — after `stop_one`, the new block calls `port_open` on all three ports and, for
  each that answers, prints `:$port is still listening after shutdown -- not something this script
  started` and `return 1`. `port_open` only proves *something* is listening; the "not something this
  script started" part is asserted. On a developer machine `:8000` and `:8080` are two of the most
  commonly occupied ports going (`python -m http.server`, any dev server, a local proxy).
- **Failure scenario** — an unrelated `:8080` listener makes `stack.sh down` exit non-zero on every
  invocation, and any wrapper that checks its status starts treating teardown as broken. The
  intent — refuse to report success while a port is held — is right; the message overstates what was
  established.
- **Suggested fix** — soften the wording to "still listening; if it is not yours, the next `up` will
  measure it", and keep the non-zero exit. Or check ownership with the same `ss -ltnp` the message
  already tells the operator to run.

---

## Checked and found sound

- **The convergence gate fix is correct.** `expected_counts` for P4 now yields `hosts * (hosts - 1)`
  ordered pairs and `observed_counts` reads `d["all_destination_paths"]` out of the envelope rather
  than `len()`-ing the envelope's two keys. On the 10-switch/4-host topology that is 12 expected,
  matching the four hosts' ordered pairs; the old code compared 14 (switches + hosts) against a
  constant 2, which could never be satisfied. The comment at `:160-166` explicitly corrects its own
  earlier false claim, which is the right way to leave that.
- **`mark_log`'s repeated-run guard is honest about its limits.** It detects a previous contract
  run's probes by the `there_is_no_such_endpoint` signature and only *warns* — it does not fail the
  run or silently adjust the mark. Given that the deliberate-error probes are what pollute the log,
  warning and naming the fix (`stack.sh down && up`) is the right weight.
- **The `warning_allowlist.txt` change removes rather than adds suppression.** The `switch not found
  dpid N` entry is gone, `Classifier::lookup` no longer logs at all, and the replacement
  `KeyedFailureLog` lines are deliberately *not* allowlisted, so a genuinely absent control plane
  fails the log check. That is the correct direction. Its value now depends entirely on the P3-1
  finding — the lines only appear if the failure survives 15 s of uninterrupted passes.
- **`compare_baseline.py` reports stale allowlist rules** (`stale = [r for r in rules if r.hits == 0]`,
  `:378`), so an entry that becomes unnecessary is surfaced. That is why over-narrow entries are
  cheap and over-broad ones are not.
- **`l1_unit_tests.sh` runs both `ctest` and each binary directly**, and treats SKIPPED tests and
  "no tests ran" as failures. The layering is right — which is exactly why the three ctest
  segfaults in P1 matter: the tooling will catch them, and the handoff says they are not there.
