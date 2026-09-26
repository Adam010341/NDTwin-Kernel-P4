# live 07 on trunk b2eeb71d -- 2026-09-27 04:20:55–04:24:07 +0800 (orchestrator, 9/25 session)

- binary/code: trunk `b2eeb71df30fe9cdd0086f281062517ba3e86815` (git sha of the checkout the run used; the
  driver refuses any other HEAD); `07_roles_basic.sh` sha256 `7010f3825e06c078…`, `_common.sh` `36c3689b41bd000a…`,
  root helper `/usr/local/sbin/ndtwin-lab` sha256 `6a558fe452955de3…` (= trunk's `tools/test_workflow/ndtwin-lab`).
- driver `live07.frozen.sh` (read-only copy), owner `orch-0927`; `L1_POLL_S` / `SELFTEST_*` unset (judge R-N2 on 4f661e31).
- workers paused for the whole run (worker ack "paused, nothing running", 0 pids; orchestrator checked: no
  `ndtwin-build-*` scope, no worker test process, no `mininet:h*` process before the start).
- raw: `doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/2026-09-26T202055Z_07_roles_basic/`; log `07.log`.

## Result: PASS 07_roles_basic (rc 0) -- RAN, not read

| check | result |
|---|---|
| L6 roles | 4/4 `{binding_source: package, five_tuple: false, ipv4_route: ndtwin, link_discovery: heartbeat, reroute: true}`; skipped `[link_watchdog, lldp_discovery]` |
| L1 on switch_state (roles) | 8/8 declared, heartbeat, down false, heard -- on the 3rd poll (20:21:07Z, :09Z `declared`; :11Z OK) |
| L1 graph | 8/8 is_enabled/is_up |
| L3 | 12/12 pairs 0% loss |
| L2 | install -> dispatched_ok 1 -> read back OUTPUT:3 -> deleted |
| L4 | both directions down after the cut, still down after 40 s, back up after recovery, no netem left |
| L6 unbound | 4/4 `{null, false, unbound, heartbeat, false}`; skipped `[install_initial_routes, link_watchdog, lldp_discovery]` |
| L1 on switch_state (unbound) | 8/8 heard -- on the 3rd poll (20:23:57Z, :59Z `declared`; 20:24:01Z OK) |
| L5 | 501 unsupported_on_p4 / unbound (incl. the author's /32); recent_failures says why; 16 author rows identical; 10.0.1.1 still -> port 1 |

knob `host_count_override` 4 before and after.

## Reconciled against the previous live 07 (2026-09-24T160256Z, trunk 572d9462, before segment W)

- **Updated (recorded, not asserted):** traffic during the L4 cut went from 8/12 lossy pairs (every h1/h2 <-> h3/h4
  pair) to 3/12 (h1->h3, h1->h4, h2->h3 -- the first three cross pairs pingall tries; the later five crossed at 0%).
  INFERRED: the proxy's heartbeat detected the cut and rerouted part-way through the ~30 s pingall; 07 does not
  time-stamp pairs, so this is consistent with, not a measurement of, detection-then-reroute (08 H1 asserts that).
- **Same:** L3 12/12, recovery 12/12, L2, L5 (16 rows identical, /32 untouched).
- **New since 09-24 (not comparable):** L6's `link_discovery: heartbeat` / `reroute` keys and L1 on switch_state
  (segment W; the 07 links check since 3f8c2abf, the startup-grace rule since b2eeb71d).
- **Confirms the poll was needed:** both packages read `declared` for the first ~4 s after `ndt up`; a single
  read (the pre-3f8c2abf shape) would have judged BAD on a healthy run.

[Co-developed with claude code -- Adam]
