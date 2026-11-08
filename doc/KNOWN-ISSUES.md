# Known issues

This file lists the defects that are open in this repository's `main` branch. Each entry says what a
user sees, when it happens, why (with the place in the code), and what to do about it.

Defects that have been fixed are not listed here; their codes are kept in `doc/FIXED-ISSUES.md`. An
entry is cited by its code, for example `B-9`. Codes are stable and are never reused.

Some entries end with a failure direction, which says how the symptom misleads:

- **optimistic**: a reading or a verdict says healthy when something is broken;
- **pessimistic**: it says broken, absent or idle when it is not;
- **silent**: nothing in the reply, the logs or the status output shows that anything went wrong.

Code locations (`path:line`) are given for `main` at commit `ada902504`; lines move as the code
changes, so search for the quoted names if a line has drifted. An entry whose title starts with "if"
applies only when that condition holds; the others occur in ordinary use. Things that look like
defects but are limits of the environment or of the measurement are at the end, under "Limitations".

---

## Running a lab with `ndt`

### G-33 `ndt check` reports DOUBLE-COUNTING and exits 4 when a link has just failed

**What you see.** While traffic flows and a link is cut (for example with `tc netem loss 100%` on an
interface), `ndt check` prints `DOUBLE-COUNTING -- twin is <r>x ground truth` and exits with 4, although
nothing is counted twice: the twin is only lagging behind the measured traffic, which dropped.

**When.** `ndt check` with traffic flowing, within a few seconds after a link fault or any sudden
fall in the real rate.

**Why.** The verdict is chosen by the ratio alone: above 1.5 it prints DOUBLE-COUNTING and the command
exits 4 (`tools/test_workflow/ndt:8263-8265`, `:8425`). The verdict word no longer names a mechanism,
and the lines under it list both possible causes (stacked duplicates, or a lagging twin) side by
side from the per-sub-window ratios (`tools/test_workflow/ndt:8186-8241`); but a lag still produces
the same word and the same exit code as a real stack of duplicates.

**What to do.** Read the cause lines under the verdict, not the exit code alone: they say whether every
sub-window was over the band over a steady ground truth (the shape of stacked duplicates) or only some
of them while the ground truth moved (the shape of a lag), and name both causes when the window cannot
say. Repeat the check once traffic has been steady for a few seconds. With no traffic `ndt check`
compares nothing and exits 0; that 0 does not mean the fabric is healthy (`ndt help` says so).

Failure direction: pessimistic (a fault is read as duplication).

### G-36 `ndt status --check` after a completed `ndt down` always exits 3 ("could not check")

**What you see.** On an idle machine, after an `ndt down` that left none of the fabric behind,
`ndt status --check` prints `check: COULD NOT CHECK -- no 'ndt up' target recorded in this checkout`
and exits 3.

**When.** After every `ndt down` whose own `verify clean` finds none of the fabric itself (no bmv2
switch, no Mininet host or switch process, no topo session): that `ndt down` clears the recorded
`ndt up` target, `.test_run/up.target` (`tools/test_workflow/ndt:6245-6246`, `clear_up_target` at
`:623`). If the fabric is still there the record is kept and `--check` does not answer 3: `ndt down`
keeps it when `verify clean` still finds bmv2 switches, Mininet hosts or switches, the topo session, or a
topo session it could not read (for example because the lab helper's sudo grant is missing), and when its
own `verify clean` was refused because another `ndt down` is running (`:6409`). It then prints what it
found and "kept the 'ndt up' target record", and `ndt status --check` goes on comparing the running lab
with that record. Anything else `verify clean` reports (a stranger on a port, the app knob) does not keep
it (`:6232-6247`). A kept record goes with the next `ndt down` that finds none of the fabric, or with the
next `ndt up` that builds a fabric (one that refuses leaves it as it is); once the fabric is gone you can
remove it yourself with `rm .test_run/up.target` (`:634-647`; user guide, section 4.9).

**Why.** `--check` compares the running lab with the recorded `up` target; with no target there is
nothing to compare (`tools/test_workflow/ndt:8084-8091`). It does not fall back to checking that
nothing should be running. This is documented behaviour (`doc/2026-11-05_user-guide.md`, section 4.5,
exit-code table); whether `--check` should do more after `down` is undecided.

**What to do.** If `ndt down` printed "kept the 'ndt up' target record", the fabric it names may not be
gone (or, if its own check was refused, was not measured): fix what it says (for a missing sudo grant, the
line it prints) and run `ndt down` again. To confirm that a lab is down, use `ndt clean` (it asserts that no lab process, topo session or
listening lab port is left). On a lab that is already down it exits 3, "there was nothing to judge", and both 0 and 3
mean down (`tools/test_workflow/ndt:12338-12344`; user guide, section 4.10). To compare a state before and after,
compare the full `ndt status --check` output (rc 3 and the same list of problems), not the exit code against 0; plain
`ndt status` always exits 0 (`doc/2026-11-05_user-guide.md`, section 4.5).

### G-39 After a failed P4 bring-up, the pane that `ndt up p4` points to is already gone

**What you see.** When the bmv2 topology bridge exits early, `ndt up p4` stops waiting after about
6 seconds and prints the last lines of `.test_run/logs/topo.log`, then rolls back. It also prints
`look at the pane: sudo -n <helper> topo-out 40`, but that pane no longer exists, so the command
answers that there is no topo session. A bring-up done by hand with the helper (not through `ndt`)
loses the abort message the same way.

**When.** The bridge process dies before the fabric is up (a missing module, a bad package).

**Why.** The helper starts the bridge in a detached tmux session (`tools/test_workflow/ndtwin-lab:585`)
without `remain-on-exit`, and tmux removes the session when the bridge exits. `ndt` notices the missing
session at two checks in a row and prints the `look at the pane` line, and then the log tail
(`tools/test_workflow/ndt:4297-4331`).

**What to do.** Read `.test_run/logs/topo.log` (the bridge writes its output there as well); `ndt up p4`
prints its tail. For a hand-run bring-up, read that file directly.

### G-59 `ndt status` can show a missing sudo grant as granted

**What you see.** On a machine where `sudo` refuses a command without printing a line that starts with
`sudo:`, the sudo-grant row of `ndt status` says the grant is present, and `ndt status --check` can be
green although the grant is missing.

**When.** Only for these refusals: a refusal that prints nothing at all (a wrapper or shim); a refusal
that follows only a listed harmless warning (such as `unable to resolve host`); a refusal worded without
the `sudo:` prefix. The last case could be the Rust `sudo-rs`; its actual wording has not been checked.

**Why.** The probe treats a non-zero exit with no `sudo:` line as "the program ran and failed on its own",
which means the grant is live (`tools/test_workflow/sudo_surface.sh:237-253`). A refusal of that shape
is indistinguishable from stderr alone. The behaviour is pinned as a known limit in
`tests/shell/test_ndt_sudo_surface.sh:389-427`.

**What to do.** If `ndt` later fails with a sudo error although `ndt status` showed the grant, test the
grant by hand (the user guide's section 3.2 lists each rule and the command it covers). Steps that tear
things down decide on the command's exit status, not on this row, so no wrong teardown follows.

Failure direction: optimistic (limited to the status wording).

### G-62 The residue report can say "no flow entry arrived during that window" while the app's own rules are still on the switches

**What you see.** After `ndt apps stop`, or in `ndt apps orphans` and `ndt status --check`, the report
says no flow entry arrived during the app's time window (exit code 0), while rules the app installed
during its first second, or shortly before it stopped, are still present on the switches.

**When.** Rules installed in the first second after the app started; rules installed just before the
recorded end of the window (up to the age of the kernel's cached flow table, about 10 seconds, and
longer while the cache is carried forward after failed polls).

**Why.** Two edges of the window are fixed in whole seconds from the clock of a different moment. The
start is the app's elapsed time in whole seconds (`ps etimes`) turned into an absolute time
(`tools/test_workflow/ndt:10329-10336`), which can be up to a second late; it is stored when the app
is stopped (`:10030`, `app_window_record` at `:8632`). A rule's age is `now - duration_sec`, and the
table that supplies `duration_sec` is the kernel's cached copy, polled about every 10 seconds
(`:10822-10834`), so the age can be later than the real install time by the age of the cache.
Rules outside the window are by design not reported.

**What to do.** Do not read "no flow entry arrived" as proof that the app left nothing behind. Read the
switch tables from the controller's REST API (not from the kernel's cached copy) for the rules the app
is known to install. Waiting before you run the report does not help: a rule's install time is computed
from the cached table as it was last polled, and the window's end is fixed when the app is stopped
(`tools/test_workflow/ndt:8637`, `:10032`), so no amount of waiting closes the gap. This applies to OVS
only; on P4 the report prints `NOT CHECKED` (see "On P4, `ndt` cannot tell when a rule was installed"
under Limitations). None yet that makes the window exact.

Failure direction: optimistic.

---

## The northbound API

### B-2 Locks do not give mutual exclusion in one ordinary case

B-2 had two cases, cited in the source as B-2① (renewing an expired lock) and B-2② (a lock with no
owner). Case ① is fixed; this entry is case ②.

**What you see.** A client that holds no lock can release or renew another client's lock. The real
holder only learns it when its next renewal fails. Two applications that both use `routing_lock` can
each believe they own the network.

**When.** `POST /ndt/release_lock` and `/ndt/renew_lock` without a `lease` number in the JSON body; a
lease sent as a query parameter or as a string counts as none. (Case ①, renewing an already expired
lock, is refused with 412; that part is fixed.)

**Why.** A lock records only that it is held and when it expires; it has no owner
(`include/ndt_core/lock_management/LockManager.hpp:19-33`). A lease id exists and a caller that passes it
back as `lease` is refused when the lock has moved on (`:526`, `:552`, `:687`, `:713`), but a call with
no `lease` is acted on by name alone and only counted (`:564-570`, `:725-731`). The switch that would make
the lease mandatory, `setRequireLeaseId`, is off by default and nothing calls it (`:73`, `:215`;
`src/ndt_core/http/HttpSession.cpp:4016`, `:4127`).

**What to do.** Pass the `lease` value returned by `acquire_lock` to every `renew_lock` and
`release_lock`, as a number in the JSON body: a query parameter or a string is silently ignored, as if
it were absent (`include/ndt_core/lock_management/LockManager.hpp:352-354`). That protects you from
acting on a lease that has since changed hands. It does not stop another client that omits `lease`; none
yet for that.

Failure direction: silent (both clients get 200).

### B-3 Historical logging answers "enabled" but writes no rows on a `ndt up` lab

**What you see.** `POST /ndt/historical_logging?state=enable` answers 200 with
`"status":"not_applicable"`, `"recording":false`, and a message saying that no rows will be written.
No historical link data is recorded.

**When.** Whenever the kernel runs in MININET mode, which is how `ndt up` always starts it
(`tools/test_workflow/stack.sh:1301`). Outside MININET mode, the same reply is given when the recorder
thread is not running or when every write to the output directory fails.

**Why.** The recorder is not started in MININET mode, and says so in the kernel log
(`src/ndt_core/data_management/HistoricalDataManager.cpp:63-72`). The endpoint reports this honestly
(`src/ndt_core/http/HttpSession.cpp:3481-3508`). The reply is 200, so only the `recording` and `status`
fields tell the case apart from a working recorder.

**What to do.** Read `recording` (and `reason`), not the status code. Use a deployment mode that records
if you need history; there is no way to record in a `ndt up` lab.

### B-17 (TESTBED mode, if a switch reports interface speed 0) A link's utilisation becomes `null` and its bandwidth 0

**What you see.** If a switch's sFlow counter samples carry an interface speed of 0, the standard
"unknown speed" value, the link's utilisation in `get_graph_data` is `null` and its bandwidth is
overwritten with 0.

**When.** Only in TESTBED mode (real switches), and only for a switch that sends interface speed 0.
In MININET mode, which is how `ndt up` always starts the kernel, counter samples are discarded before the
division (`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1349-1354`), so no `ndt up` lab can hit it.
This was found by reading the code and has not been reproduced.

**Why.** The counter-sample handler divides by the reported speed and stores it as the link bandwidth
without a zero check (`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3245-3258`; the sample is
passed through unchecked at `src/ndt_core/collection/FlowLinkUsageCollector.cpp:1364-1411`). A topology
file that declares a zero bandwidth is refused at load, but a switch can still report one
(`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:277-279`).

**What to do.** None yet. If a link shows `null` utilisation and `link_bandwidth_bps` 0 while traffic
flows, check the interface speed that the switch reports.

Failure direction: silent.

### B-21 A fully delivered low-rate flow drops out of the default flow view

(The reverse case of the fixed defect cited as "B-x", in which ended flows were listed as active; see
`doc/FIXED-ISSUES.md`. Most citations of "B-x" in the source mean that fixed case.)

**What you see.** A flow that sends fewer than about 90 packets per second is sometimes missing from
`/ndt/get_detected_flow_data` (default view) and from `get_num_of_flows_passing_a_switch`, although every
packet is delivered. Below about 22 packets per second it is missing more often than present.

**When.** Low packet rates with 1-in-256 sampling. The limit is a packet rate, not a bit rate: with the
same bandwidth and smaller frames the flow is seen again. Measured with one flow, 1,400-byte frames,
3 hops, 30 one-second polls per cell: the default view listed it 30 of 30 times at 179 pps, 26 of 30 at
89 pps and 16 of 30 at 22 pps. `?liveness=all` was still 30 of 30 at 22 pps and began to miss
only around 5 pps. `get_num_of_flows_passing_a_switch` was the narrowest: 21 of 30 at 179 pps, 6 of 30 at
22 pps.

**Why.** A flow is "active" only if a sample for it arrived in the last 3 seconds
(`include/ndt_core/collection/FlowLinkUsageCollector.hpp:90`), and the per-edge flow sets used by the
count are emptied after 2 seconds (`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:5899-5920`). At
1-in-256 sampling a slow flow produces too few samples. The behaviour is documented
(`doc/2026-01-02_ndt_api.md`, section 4).

**What to do.** Do not treat absence from the default view as a stopped flow. Use `?liveness=all` plus
`last_seen_ms`; size polling to the packet rate. None yet for the count endpoint.

Failure direction: pessimistic (and optimistic for a caller that shuts down paths it thinks are idle).

### C-8 `last_sample_age_seconds` is -1.0 for a link that has never been sampled

**What you see.** In `get_graph_data`, an edge's `last_sample_age_seconds` is -1.0 when no sample has
ever arrived for it, in a field that is otherwise an age in seconds. `agent_last_sample_age_seconds`
has the same convention.

**When.** Any edge that has not been sampled since the kernel started, for example before telemetry
starts or on an edge nobody samples.

**Why.** Deliberate sentinel: `-1.0` means "never", not "a long time ago"
(`src/ndt_core/collection/FlowLinkUsageCollector.cpp:2047-2051`, serialised as is at
`src/ndt_core/http/HttpSession.cpp:1565-1567`). The contract does not bound the value from below.

**What to do.** Treat a negative value as "never sampled" before doing arithmetic on it. Do not use
`telemetry_status` instead: it is decided per switch, so an edge that was never sampled on a switch that
is sampling other ports reads `idle` with -1.0, and `unknown` means only that the whole switch has never
reported (`src/ndt_core/collection/FlowLinkUsageCollector.cpp:2051`, `:2054-2060`, `:2069-2076`).

### C-9 A link whose telemetry went silent reports usage 0, the same as an idle link

**What you see.** When sFlow reports stop arriving for a link, `get_graph_data` still shows
`link_bandwidth_usage_bps` and `link_bandwidth_utilization_percent` as 0, exactly as for a link with
no traffic. `telemetry_status` is `silent` then, but `silent` is not a fault test: it means that no
sample has arrived from that switch on any port within the window, and a switch that is idle on every
port looks the same. Agents report only for the flows they sample, and MININET mode discards counter
samples (`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1638-1640`, `:1349-1354`); the code
documents the false positive as deliberate (`include/ndt_core/collection/FlowLinkUsageCollector.hpp:283-286`).

**When.** After traffic stops and the sampling agent goes quiet (the window is 5 seconds,
`include/ndt_core/collection/FlowLinkUsageCollector.hpp:304`), for as long as the edge stays in the
graph.

**Why.** The usage fields are always numeric (`src/ndt_core/http/HttpSession.cpp:1581-1582`); the
silence is carried only by `telemetry_status` (`:1563-1564`;
`src/ndt_core/collection/FlowLinkUsageCollector.cpp:2053-2073`).

**What to do.** Read `silent` as "cannot tell": it covers a broken telemetry path and a switch with
nothing to report alike. A consumer that acts on low usage (a power-saving decision, a top-k list, a
threshold) can act only when `telemetry_status` is `live` or `idle` for the link; that protects it from a
fault, but it also means it can never act on a switch that carries no traffic at all. A power-saving
consumer therefore cannot power off a completely idle switch from this signal, and needs another source
to tell an idle switch from a broken one.

Failure direction: optimistic.

### F-17 `get_average_link_usage` averages only the busy links

**What you see.** `/ndt/get_average_link_usage` is the mean over only those switch-to-switch links that
carry traffic. With 8 busy links of 32 the reading is about 4 times the real average over all links; on
an idle network it is 0.0, which is also the true average there, but the same 0.0 is returned when no
link has a reading at all.

**When.** Always; the average has no idle links in it by construction.

**Why.** Links with `linkBandwidthUsage` 0, links that are not usable, and edges to hosts are skipped,
and 0 is returned when no link is left (`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:5621-5675`).
The handler is `src/ndt_core/http/HttpSession.cpp:3521-3535`. The endpoint is part of the
cross-repository `/ndt/` contract, so its meaning is not changed. The P4 energy-saving example uses it
as a gate and stops its pass when the value is above its limit
(`examples/p4_energy_saving/energy_saving.py:323-327`), so an overstated value makes it skip passes.

**What to do.** Compute the average yourself from `get_graph_data` (`link_bandwidth_usage_bps` over
`link_bandwidth_bps` per edge), counting the links you want in the denominator.

Failure direction: misleading both ways: too high when only some links are busy, and 0.0 cannot tell
an idle network from one with no readings.

### G-16 Powering off a switch whose `power_path` is `none` is accepted, and the power report never shows a measured saving

**What you see.** `POST /ndt/set_switches_power_state?ip=<switch>&action=off` for a switch exempted from
power control (its `power_path` is `none`) answers 200 `{"<ip>":"Success"}` and the graph shows it as
off. `GET /ndt/get_power_report` for that switch never shows a measured saving. Before the
off it reads the synthetic per-switch figure in MININET mode (every `ndt up` lab) and -1 ("unavailable")
in TESTBED mode; after the off it reads 0 in both modes, because a switch that is marked down reads 0
(`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:1941-1950`, `:1982-1985`).

**When.** A switch that the topology file admits through an explicit `switch_kind` (`ovs`,
`bmv2`/`p4` or `hardware`) although its `brand_name` is one this build has no power or telemetry path
for (`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:716-733`).

**Why.** Commands are routed by switch kind only: bmv2 goes to the P4 strategy, OVS and hardware to the
OVS strategy; the exemption mark is never read on that path
(`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:70-100`). It is deliberate:
a documented state value is not answered with 4xx. In TESTBED mode the command goes through the
smart-plug table instead, and a switch missing from that table is refused with 404
(`:2044-2077`; `src/ndt_core/http/HttpSession.cpp:2020-2027`). It is documented in
`doc/2026-01-02_ndt_api.md` ("The exemption affects reads, not commands").

**What to do.** To tell whether a switch is exempt, read its node in `/ndt/get_graph_data`:
`power_path` is `"none"` for an exempt switch. Do not infer it from the reply of
`set_switches_power_state`, which is 200 either way. Estimate the saved power from the topology rather
than from `get_power_report`.

Failure direction: optimistic.

---

## Apps run by `ndt`

### A-4b The Energy-Saving-App powers redundant switches off on an idle network and on again only when one switch's value reaches 0.60

**What you see.** In a lab that has no traffic (or very little), `ndt apps energy` powers the redundant
switches of each group off and does not power them on again until the value computed at one of the group's
remaining up switches reaches 0.60 (60 %; see When). An idle network never reaches it, so the switches
stay off.

**When.** Any network whose switch links are up and enabled but carry no traffic. The decision value is
computed for each up switch of a group, from the sum carried over from the group's earlier switches plus
that switch's own up and enabled links (see Why). A link with no traffic contributes 0, so with no traffic
every value is 0.0, which is below the low-water mark of 0.40; the high-water mark is 0.60
(`include/app/settings.hpp.example:6-7` in the Energy-Saving-App).

**Why.** The defect is in the Energy-Saving-App, not in this repository; `ndt apps energy` runs it from
the checkout named by `ENERGY_APP_DIR` (`tools/test_workflow/components.env:28`). It was read, not run,
at commit `e5b3ec1c` of that repository (its public `main`). In `run_switch_cycle_once`, for each node
of a group, the loop adds the utilisation of that node's up and enabled edges to a running sum kept for
the whole group (declared at `src/app/energy_saving_app.cpp:904`, added to at `:913`), divides the sum by
that node's edge count times 100 (`:917`), and powers the whole group off when the result is at or below
`LOW_WATER_MARK` and on when it is at or above `HIGH_WATER_MARK` (`:921-923`). So the decision is made once
per node, on a sum that is carried over from the previous node and divided again each time. On an idle
network every term is 0, so every result is 0.0 and the group is powered off. For a node with no up and
enabled edge the divisor is 0: if the carried sum is 0 the result is NaN (every comparison is false, so
no action, and the sum stays NaN for the group's later nodes in that cycle); only a positive sum gives
infinity, which powers the group on. This is the app's
decision rule, so whether it is a defect depends on what you expect an idle network to do; it is listed
because a lab that is started without traffic, or whose traffic is light, behaves this way every time.

**What to do.** Start the traffic before the app; that helps only while the value computed at every up
switch of the group stays above 0.40, because any one switch at or below it powers the whole group off.
Or change `LOW_WATER_MARK` and `HIGH_WATER_MARK` in the app's `settings.hpp`. Related and also in the app:
it takes `routing_lock` every cycle
(`src/app/energy_saving_app.cpp:948`), and the only two `release_lock()` calls are in the
simulation-result handler (`:374`) and in `easy_disable_switch` when nothing was simulated (`:632`);
`easy_enable_switch` (`:637`) and the cycle's other exits do not release it, so the lock is held until
its lease runs out. This is the application half of the lock livelock cited as A-9 (kernel half fixed; see
`doc/FIXED-ISSUES.md`). After `ndt apps stop energy`, `POST /ndt/release_lock {"type":"routing_lock"}`
clears it by hand. That works only because of B-2 (a release by name needs no lease); do not do it while
the app runs, because it hands the lock to another client while the app still believes it holds it.

---

## OVS

### B-9 Powering an OVS switch off and on cuts every host behind it, and every check says healthy

**What you see.** After `POST /ndt/set_switches_power_state` with `action=off` and then `action=on` for
an OVS switch, both calls answer 200 `Success`. The switch's ports now carry different OpenFlow port
numbers (for example `s3-eth10` becomes port 2), while the installed flows still use the old numbers.
Every host behind that switch loses connectivity (100 % loss) until the whole lab is rebuilt. The
flow count is unchanged, and `get_graph_data`, path queries and `ndt status --check` still report
healthy.

**When.** OVS only; bmv2 (P4) fabrics are not affected, because their ports are created with an
explicit port-to-interface mapping (`p4_proxy/mininet/p4_testbed_topo.py:323`). A power off followed by
on of an OVS switch whose port names sort in a different order from their port numbers, which happens
from 10 ports upward (as on the 128-host leaves); a switch with ports `sN-eth1` to `sN-eth9` gets the same
numbers back. In particular from energy-saving apps.

**Why.** On power off the kernel reads the bridge's ports with `ovs-vsctl list-ports`, which lists them
in name order (`s3-eth10` before `s3-eth2`), saves that list and deletes the bridge
(`src/ndt_core/power_management/OVSPowerStrategy.cpp:51-80`, `:707-712`). On power on it adds the ports
back in that order with no `ofport_request`, so OVS numbers them 1, 2, 3 in that order
(`:474-479`; no `ofport` appears anywhere in the file). The flows the router installs take their output
port numbers from the topology file's `src_interface` (`intelligent_router.py:1426`, `:1429`, `:1634`,
`:1658`), which assumes `sN-ethM` is port M, and never reads the switch's current port numbers.

**What to do.** Do not power-cycle OVS switches while the lab carries traffic. If you must, rebuild the
lab after the `on` (`ndt down`, then `ndt up ovs`), or verify reachability of every host behind the
switch with a ping matrix; the built-in checks cannot show it.

Failure direction: optimistic and silent.

### C-4b After a delete, the OVS flow-table view keeps the rule for about 10 seconds

**What you see.** On OVS, for about 10 seconds after `delete_flow_entry` answers 200,
`get_switch_openflow_table_entries` still lists the deleted rule, with nothing saying the data is old.
(Measured on OVS in two of two runs of the delete direction; in the logged run the controller itself
had dropped the rule after 0.5 s and the kernel's view dropped it after 10.1 s, 9.6 s later. P4 was not
measured.) The install direction is related: a new rule is held back from the view until a poll sees it,
and the kernel logs that (also two of two).

**When.** Right after a successful delete on OVS; a caller that deletes, reads back at once and then
deletes again gets 200 each time.

**Why.** The endpoint serves the kernel's cached table, refreshed by a periodic poll of the controller.
The delete edits the cache by matching a key built from the request
(`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:3189-3201`); the key reads the
Ethernet type from `eth_type` only (`:3102`), while rows polled from the controller can carry `dl_type`,
so the row probably survives until the next poll replaces the cache. That mechanism comes from reading the
code and has not been confirmed on a running lab.

**What to do.** Do not use this endpoint as an immediate read-back after a write; wait for a poll
period (15 seconds is safe), or read the controller's own flow table, or confirm a path change through
`get_detected_top_k_flow_data`. The timing is described in `doc/2026-01-02_ndt_api.md`, "Closed-loop
apps: how long until a change is visible".

Failure direction: optimistic and silent.

---

## P4 and bmv2

### A-4c Rules installed through the flow API are lost when the P4 proxy restarts or a switch is re-adopted

**What you see.** After the P4 proxy restarts, or after `POST /p4/readopt/{dpid}`, the flow rules that
an application installed on that switch through `/ndt/install_flow_entry` (the Ryu-compatible
`/stats/flowentry/*` path) since bring-up are gone from the switch and are not put back. The kernel
logs an ERROR naming the switch and the number of rules ("NOT replayed"), and `get_graph_data` carries
a `ryu_rules_lost` record on that switch's node (an `id`, `cause`, `count`, the rules, up to 100, and
`replayed: false`).

**When.** Proxy restart or readopt, which includes the P4 power-on of a switch (it restarts bmv2 and then
calls readopt, `src/ndt_core/power_management/P4PowerStrategy.cpp:155-157`). A fresh bmv2 holds no cookie and
reports nothing, so in those cases the record says 0 (`p4_proxy/proxy_agent/main.py:2339-2341`,
`p4_proxy/proxy_agent/topology_manager.py:1471-1472`): the 0 is right only when the kernel and the apps were
restarted together with bmv2. After a P4 power cycle, or when bmv2 restarted by itself while the kernel and
the apps kept running, the rules the apps installed are gone and the record still says 0. Rules written
with `POST /p4/table_entry` are kept in a
journal and replayed. The record keeps only the latest entry per switch, so a second restart before
the kernel has read the first hides it; the count may be short when the journal could not be written
or read, and is unknown (null) when the push itself failed.

**Why.** The proxy pushes the pipeline to each switch at startup and readopt, which empties its tables
(`p4_proxy/proxy_agent/main.py:2336-2345`, `p4_proxy/proxy_agent/topology_manager.py:1453-1494`,
`:2071`). Rules of the Ryu-compatible path are reported, never replayed, because the journal holds
requests and not the reasons for them. The kernel reads the record on its regular poll of the proxy and logs it at
ERROR (`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:797-805`;
`src/ndt_core/power_management/P4RulesLost.cpp:99-103`); `get_graph_data` serves it on the switch node
(`src/ndt_core/http/HttpSession.cpp:1511-1517`).

**What to do.** After a proxy restart or readopt, read `ryu_rules_lost` in `get_graph_data` and have
the application that installed those rules resend them. A record of 0 is not proof that nothing was
lost: also resend after any P4 power-on of the switch and after any restart of bmv2, because "resend when
the record says so" misses those two cases. Do not restart the proxy while apps are running if you can
avoid it.

Failure direction: silent before the record existed; now loud, but the rules are still gone.

### B-18 (if tables were written with `simple_switch_CLI`) The proxy cannot read that switch's tables

**What you see.** If anyone writes a fabric switch's tables with bmv2's `simple_switch_CLI`
(`table_add ...`), the proxy's table reads for that switch fail with `Table state out-of-sync with
target`. The rules still forward.

**When.** Only after CLI writes on a switch that is also managed over P4Runtime; reading a table that
the CLI wrote fails, as does reading all tables at once. Tables written over P4Runtime still read. Seen
on both the stock and the performance bmv2 build.

**Why.** A limitation between bmv2's P4Runtime server and its Thrift CLI, not in NDTwin code
(`p4_proxy/proxy_agent/bm_thrift.py:26`). The mechanism is not confirmed.

**What to do.** Do not run an app's own CLI scripts on a fabric switch. Convert them:
`tools/p4_exercise/convert.py --thrift-commands` turns the CLI commands into P4Runtime entries that the
proxy writes (`tools/p4_exercise/convert.py:1129`). See the user guide's section on protecting bmv2's
Thrift port for the access side.

Failure direction: pessimistic.

### B-19 (if an indirect table was written with `simple_switch_CLI`) `GET /p4/table_entry` answers 503 for the whole table

**What you see.** After adding an entry with `simple_switch_CLI` to a table that uses an action profile
or an action selector, `GET /p4/table_entry` for that table answers `503 table not read`
(`grpc_status` `INTERNAL`, "This is NOT an empty table"). The entry is on the switch, but the whole
table is unreadable. Deleting the entry with the CLI makes the table readable again.

**When.** Only for action profile and action selector tables with a CLI-written entry. Measured on bmv2
1.15.5. Not measured: CLI entries mixed with P4Runtime entries in the same table, CLI modify, the same
call through the kernel's `/ndt/p4/table_entry`.

**Why.** bmv2 fails the read; the cause was not investigated
(`p4_proxy/proxy_agent/api_routes.py:1602-1604` shows where the 503 is made). It may be the same
limitation as B-18; that has not been checked.

**What to do.** Write members, groups and entries of such tables only from a P4Runtime controller, and
bring the fabric up with the `external` control plane for it, where the proxy only reads
(`doc/2026-10-31_p4-app-guide.md`, section 6). Do not take mastership of a fabric switch away from the
proxy on a fabric the proxy drives: the proxy's own writes to that switch then fail
(`p4_proxy/proxy_agent/p4_client.py:290-334`, `:537-554`). `POST /p4/table_entry` cannot write entries whose action
is a profile member or group, and `convert.py --thrift-commands` translates only `table_add` and
`table_set_default`, so there is no NDTwin path for these tables yet.

Failure direction: pessimistic.

### B-20 (if an idle timeout was set with `simple_switch_CLI`) It reads back as 0, and writing the entry back clears it

**What you see.** An idle timeout set with `table_set_timeout` in `simple_switch_CLI` reads back from
`GET /p4/table_entry` as `idle_timeout_ns: 0`. Posting that entry back unchanged as a modify answers 200
and removes the timeout.

**When.** A table declared with `support_timeout`, an entry whose timeout was set from the CLI, then a
read-modify-write over the API. Measured on bmv2 1.15.5. A timeout written through
`POST /p4/table_entry` with `idle_timeout_ns` is read back correctly and survives a modify that carries
the same value; a modify without it clears it, which is bmv2's behaviour
(`p4_proxy/proxy_agent/api_routes.py:1514-1516`).

**Why.** bmv2 does not report the CLI-set timeout over P4Runtime; why was not investigated.

**What to do.** Set timeouts through `POST /p4/table_entry` with `idle_timeout_ns`, not through the CLI.

Failure direction: silent.

---

## Limitations

These are not defects. They are limits of the measurement or of the environment that are easy to
mistake for defects.

### F-9 Link usage is read in whole sampling steps

Link usage comes from 1-in-256 packet sampling, and each sampled packet is credited with
its length times the sampling rate (256 by default; it can be changed, see the user guide's section 4.6)
(`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1585`, `:1602`, `:1613`, `:1622`, `:1634`). A link with
little traffic (roughly under 3 Mbit/s with 1,400-byte frames) therefore shows a reading that is a whole
multiple of one sample's worth rather than a smooth value. A link that carries traffic was not seen
reading 0 for this reason.

### F-bmv2 The software switch forwards at a limited packet rate

bmv2 forwards in software, and its ceiling is set by packets per second, not by bits per second: the
same fabric delivers very different Mbit/s for 64-byte and for 1,400-byte frames, so a statement of the
form "bmv2 does N Mbps" is ambiguous unless it names the frame size. The clean rate per flow falls as
the number of flows grows, it depends strongly on which bmv2 build is used (a debug build with logging
macros is far slower than a performance build), and on the path length and whether the control plane is
running. No number is given here, because a number is only meaningful with its binary, frame size,
path and flow count; the build instructions and a measured comparison of the two builds are in
`doc/2026-11-05_user-guide.md`, "Building bmv2 for realistic throughput". Report any bmv2 measurement
with the binary, the frame size, the number of hops and flows, and whether the control plane was alive.

### OVS power cycle and traffic shaping

On the OVS fabric, links built with a bandwidth have an htb queueing discipline on the interface.
Powering a switch off and on (see B-9) deletes and recreates the bridge; the power code restores the port
membership and the sFlow records only, and does not touch queueing disciplines
(`src/ndt_core/power_management/OVSPowerStrategy.cpp` contains no `tc` or `htb` handling). In one
measurement on the 128-host fabric, 4 interfaces lost their htb (144 shaped interfaces became 140), and
the interfaces at the other ends of those links were not affected; which interfaces of the cycled switch
had been shaped was not recorded. The shaping stays gone until the links are rebuilt with `ndt down` and
`ndt up`. The user guide describes the same effect for other causes (a
`tc ... root netem` replacing the htb) in section 4.9, "Taking it down: `ndt down` and `ndt clean`"
(`doc/2026-11-05_user-guide.md`, the paragraph on links shaped with a bandwidth), and shows how to
check the queueing tree before and after with `tools/test_workflow/qdisc_snapshot.sh`.

### On P4, `ndt` cannot tell when a rule was installed

The P4 proxy now stamps every rule it installs, so the flow statistics it serves carry a real age for
those rules. `ndt` still treats the whole P4 plane as having no time axis
(`tools/test_workflow/ndt:10560-10562`). On a P4 fabric, `ndt apps stop`, `ndt apps orphans` and
`ndt status --check` therefore cannot date any rule to an app's time window, and their `rules-in-window`
row prints `NOT CHECKED`, which is not "clean". To find the rules an app left behind on P4, read the
switch tables themselves. The user guide describes this in section 4.5 (`doc/2026-11-05_user-guide.md`,
the paragraph on the `rules-in-window` row). It is the unfixed remainder of G-13, which `doc/FIXED-ISSUES.md` lists as partly fixed. ndt's P4 limit
is documented, so it is kept here as a limitation and not as an open defect.
