# Round 5 (night) -- editing topology files, and whether the same experiment gives the same numbers. SUMMARY.

[Co-developed with claude code -- Adam]

**Binary of record: `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`**
(`sha256sum build/bin/ndtwin_kernel` at 03:47 before anything ran, `00_binary_and_env.log`, and again at
04:42 after everything, `23_final_lab_state.log` -- it did not move under me). The **running** kernel was
verified independently: `/proc/1372001/exe` (fabric A) and `/proc/<fabric B pid>/exe` both hashed to the
same value (`11_`, `18_`). Repo HEAD **`bd187870cf590662e72de79c22d28fe6eb5db5f8`**, branch `trunk`,
unchanged from round start to round end. Nothing built, nothing committed, nothing pushed.

Plane: **P4 / bmv2, 10 switches, 4 hosts** (`ndt up p4 4`), as instructed -- round 1's D4 proved `ovs4`
configures no sFlow, so on that fabric every rate is structurally zero.

Standing facts cited, not re-derived: per-flow rates lack a time denominator (COMMON-BRIEF s11); a flow
under ~22 pps vanishes from the default window (round 4); a restart inside ~2.2 s of the kernel pid
vanishing fails on an orphaned `curl` (round 3 C2/C3) -- every stop here waited >= 3 s.

---

## A. Confirmed defects, with recipes

### The topology half -- fail fast, fail late, or succeed while quietly wrong

**T1 + T2 + T3. The repository's own topology generator produces files its own kernel cannot load, and the
kernel dies *after* it has announced itself healthy.** HIGH. `01_`, `09_`, `10_`.

`tools/make_topology.py --hosts 300 --stdout` exits **0**, prints no warning, and emits 45 hosts whose
`ip` is not an IPv4 address (`10.0.0.256` .. `10.0.0.300`). Its own `validate()` passes because it checks
that the address strings are *unique*, never that they are addresses. The boundary is exact: 252 hosts is
the last safe count, 256 emits the first bad one, `--hosts 1024` emits **769** of them. `ndt`'s
`set_host_count` enforces only "a multiple of 4 and at least 4" -- there is no upper bound anywhere.

Feed one such host to the kernel and it is a **fail-late**: `:8000` opens at **0.50 s**, the log says
`Server Listening on port 8000` and `Listening for sFlow on UDP port 6343`, and at **1.50 s** the process
aborts (rc **134**, core dumped). The whole diagnosis is two lines on **stderr** --
`terminate called after throwing an instance of 'std::invalid_argument' / what(): Invalid IP address:
10.0.0.256` -- which name neither the file nor the node; the kernel's own log's last topology line is
`Load Static Topology File` with no path. Mechanism: `ipStringVecToUint32Vec` (`Utils.hpp:304`) throws,
`loadStaticTopologyFromFile` is the first statement of `TopologyAndFlowMonitor::run()` (`:2513`), `run()`
is a thread body with **no try/catch**, so the throw reaches `std::terminate`.
*Recipe:* `tools/make_topology.py --hosts 300 --stdout > t.json`; strip the 4-line banner; start the
kernel with `--topology t.json`; watch `:8000` open and the process abort a second later.
*Control:* the identical harness on an unmutated copy (`02_`) stays alive, loads 40/40 edges and exits 143.

**T4. A host-facing edge whose dpid matches no switch node is silently dropped -- the fabric comes up
under-wired and every endpoint says it is fine.** MEDIUM-HIGH. `03_`.
39 of the file's 40 edges load; h1 keeps its downlink and loses its uplink. Every probed endpoint answers
200. The only trace is one `Skipping edge` WARN (`TopologyAndFlowMonitor.cpp:389`). Control: the baseline
run has 40/40 edges and **0** such lines.

**T5 + T5b. Port numbers are not range-checked anywhere between the file and the API's consumers.**
MEDIUM. `06_`, `07_`, `22_`.
`src_interface: 0` and `src_interface: 999999` on an inter-switch edge load with 40/40 edges and no
warning, and `/ndt/get_graph_data` republishes `"src_interface": 999999` verbatim. It is not cosmetic:
`FlowLinkUsageCollector.cpp:3017` pushes `graph[edge].dstInterface` straight into the `path` array that
`/ndt/get_detected_flow_data` publishes, so a bad number in the file becomes a bad hop in a reported path.

**F1. `--logfile` is documented as if it took a path and is in fact a boolean.** LOW-MED. `26_`.
`Logger.cpp:31` is `if (arg == "--logfile" || arg == "-f") cfg.enableFile = true;` and `:43` says "also
write logs to **netdt.log**" -- a hard-coded name in the process's cwd. A path argument is swallowed as a
stray positional; the file the caller named stays **0 bytes** and nothing is printed on stderr. Meanwhile
`main.cpp:79` advertises it inside a usage block whose other options all take values. Verified before
being written down: `build/netdt.log` is 74 942 bytes (so the flag works), the named file is 0 bytes (so
the argument does not), and `build/` is gitignored so nothing tracked was touched.

**T6.** A fabric of one switch carrying all four hosts with **zero** inter-switch edges loads clean
(5 nodes, 8 edges), as does one with 31 of 32 inter-switch edges deleted (14 nodes, 9 edges). Neither is
reported as degraded anywhere. LOW-MED. `05_`, `04_`.

**Negative control, as instructed:** a duplicated host edge (41 in the file) is accepted and silently
collapsed to 40 in the graph, no warning. **My harness did not flag it** (`08_`). The control passed.

### The reproducibility half

**P3 + P5. The boot-time routing table is not reproducible across identical bring-ups, and the twin's own
path API cannot see it.** HIGH -- this is the round's finding. `20_`, `24_`.

Ten `ndt up p4 4` / `ndt down` cycles, same command, same topology file, each from a machine verified
clean by `ps` on exact pids and `ss` on every port. Boot routes read from the **switches** through the P4
proxy's P4Runtime read (a different process from the kernel that programmed them), all ten switches:

* **4 distinct whole-fabric routing tables in 8 fully-captured cycles.** s2, s3 and s4 each showed two
  different next-hop sets; s1 showed a fifth variant in an earlier fabric. s5-s10 (transit, one next hop
  each) were identical in all 8 -- that is the control that gives the instrument its power.
* `/ndt/get_path_switch_count` returned **byte-identical answers in all 8**. It publishes a switch
  *count*, never which uplink, so the endpoint a researcher would use to check "did the path change?"
  structurally cannot distinguish these runs.

And it moves the number a paper would publish. Eight more bring-ups, each with the identical h3 -> h1
traffic (20 Mbit/s UDP, 1400 B); s3's uplinks are port 1 -> s7 and port 2 -> s8:

| cycle | s3 route to 10.0.0.1 | via | s3:1->s7:1 | s7:3->s9:3 | s3:2->s8:1 | s8:3->s9:4 |
|---|---|---|---|---|---|---|
| 1 | OUTPUT:1 | s7 | **1.771** | 0.236 | 0.0 | 0.0 |
| 2 | OUTPUT:2 | s8 | **0.0** | 0.0 | 1.476 | 0.295 |
| 3 | OUTPUT:2 | s8 | **0.0** | 0.0 | 2.657 | 0.266 |
| 4 | OUTPUT:2 | s8 | **0.0** | 0.0 | 1.181 | 0.295 |
| 5 | OUTPUT:2 | s8 | **0.0** | 0.0 | 2.362 | 0.384 |
| 6 | OUTPUT:1 | s7 | **2.952** | 0.207 | 0.0 | 0.0 |
| 7 | OUTPUT:1 | s7 | **2.951** | 0.266 | 0.0 | 0.0 |
| 8 | OUTPUT:1 | s7 | **1.476** | 0.089 | 0.0 | 0.0 |

**A 4-of-8 split.** "Utilisation of link s3-s7 under a 20 Mbit/s h3->h1 flow" is
**{0.0, 1.476, 1.771, 2.951, 2.952}** from the same command, the same file, the same machine, inside ten
minutes -- and the two edge pairs are perfectly anti-correlated, so it is a routing decision, not noise.

**P3's mechanism, attributed** (`25_`). The shipped 4-host P4 topology has **eight equal-length shortest
paths** from h3 to h1 (all 6 hops), two of which differ only in whether s3 leaves via s7 or s8. The proxy
picks one with `nx.shortest_path(search, source, target)` (`p4_proxy/proxy_agent/topology_manager.py:784`,
reached from `install_initial_routes` at `:1146,1167`) on a plain `nx.DiGraph` (`:530`) that `add_link`
(`:666-677`) fills **incrementally as links are discovered**. `nx.shortest_path` on an unweighted graph is
BFS, and BFS breaks an equal-length tie by neighbour iteration order, which for `nx.DiGraph` is
**insertion order**. `calculate_all_paths`'s own docstring (`:750-753`) states that insertion happens on
ten concurrent gRPC receive threads: *"handle_packet_in discovers a link, calls add_link, then calls
install_initial_routes -- which lands here -- while the other switches' receive threads are calling
add_link of their own."* There is no deterministic tie-break anywhere on that path: `sorted()` appears ten
times in the file and not once in `add_link` or `calculate_all_paths`.
*Demonstrated offline, deterministically:* the **same edge set** inserted in two different orders makes
`nx.shortest_path` return `[h3, 3, 7, 9, 5, 1, h1]` or `[h3, 3, 8, 9, 5, 1, h1]` -- the exact two outcomes
observed live, 4 times each in 8 bring-ups (`25_`, section C).
**So the fix is a canonical tie-break, not a synchronisation change** -- one sort, at the point the
candidate next hop is chosen.

**R1 + R2. `priority` is accepted by the kernel's flow API, echoed into its own log, and has no effect on
the P4 plane -- so a modify aimed at a rule that does not exist silently rewrites the one that does.**
HIGH. `15_`, `15b_`.

| step | request | switch after (read via P4Runtime, not the API that wrote it) |
|---|---|---|
| 1 | install `10.0.0.210` **priority 100** OUTPUT:1 | 1 row, `10.0.0.210 p=0 -> OUTPUT:1` |
| 2 | install the SAME match at **priority 500** OUTPUT:2 | still **1 row**, now `OUTPUT:2` -- replaced, not added |
| 3 | **modify at priority 777**, a value no rule was ever created with | rewritten to `OUTPUT:3` |
| 4 | **delete at priority 999** with an action nothing used | row gone; baseline restored exactly |

All four: HTTP 200, `succeeded` +1, zero warnings, and every row reads `p=0` including the boot-time
routes, so no channel could show a caller their priority was dropped. Mechanism: `grep -c priority` is
**0** in both `src/ndt_core/routing_management/P4RoutingStrategy.cpp` and `FlowDispatcher.cpp`, and **0**
lines of `p4_proxy.log` mention it -- the kernel logs the field back at itself (34 lines in `kernel.log`)
and never sends it. *Built-in positive control:* the same read-back **does** show OUTPUT:1 -> 2 -> 3
changing, so it can see a difference; and `baseline restored: True`.

**P1. The same experiment run twice does not give the same numbers, and the gap is quantified.** HIGH for
anyone publishing a figure; see P2 for why it is not a code defect. Table in section B.

---

## B. The two-column table -- every number from pass 1 beside the same number from pass 2

Three passes of a byte-identical script (`passrun.py`): **1a** and **1b** back to back on fabric A, **2**
on fabric B built after a teardown verified clean two ways. Traffic in every pass: iperf3 UDP h1 -> h2,
20 Mbit/s, 1400 B, 100 s, telemetry sampled at t+15/+50/+85 s (>= 30 s apart). Raw:
`raw/pass1a.json`, `raw/pass1b.json`, `raw/pass2.json`; full 662-line machine diff in `raw/compare_raw.txt`.

**pass 1b is the control.** It bounds what run-to-run variation looks like *without* a rebuild, so any
pass-2 difference bigger than the 1a-vs-1b gap would be attributable to the rebuild. None was.

| number | pass 1a (fabric A) | pass 1b (fabric A, control) | pass 2 (fabric B) | classification |
|---|---|---|---|---|
| wire bytes (iperf3 sender) | 249 998 000 | 249 998 000 | 249 998 000 | identical |
| wire packets | 178 570 | 178 570 | 178 570 | identical |
| wire lost / lost % | 0 / 0 | 0 / 0 | 0 / 0 | identical |
| wire bit/s | 19 999 726.4 | 19 999 752.8 | 19 999 766.0 | sampling artefact (7 sig figs agree) |
| wire jitter ms | 0.01733 | 0.02016 | 0.01026 | sampling artefact |
| graph nodes / edges / edges_up | 14 / 40 / 40 | 14 / 40 / 40 | 14 / 40 / 40 | identical |
| switches reported ON | 10 | 10 | 10 | identical |
| `get_power_report`, all 10 dpids | identical | identical | identical | identical (pure function of dpid, round 2 D14) |
| `get_static_topology_json` size | 9 067 | 9 067 | 9 067 | identical |
| measured flow path, all 3 samples | s1:1->s5:2->s2:3 | s1:1->s5:2->s2:3 | s1:1->s5:2->s2:3 | identical |
| edges with non-zero utilisation | 4 (same 4) | 4 (same 4) | 4 (same 4) | identical |
| idle `avg_link_usage` before traffic | 0.0 | 0.0 | 0.0 | identical |
| `num_of_flows` on s1, 3 samples | 1, 1, 1 | 1, 1, 1 | 1, 1, 1 | identical |
| rows in `get_detected_flow_data` | 1, 1, 1 | 1, 1, 1 | 1, 1, 1 | identical |
| `avg_link_usage` @ t+15 | 0.011 809 525 | 0.011 809 325 | 0.023 619 68 | sampling artefact |
| `avg_link_usage` @ t+50 | 0.014 759 947 | 0.013 284 647 | 0.014 762 261 | sampling artefact |
| `avg_link_usage` @ t+85 | 0.025 096 058 | 0.019 189 073 | 0.029 523 361 | sampling artefact |
| per-flow rate bit/s @ t+15 * | 20 672 512 (+3.4%) | 24 610 133 (+23.1%) | 27 563 349 (+37.8%) | sampling artefact |
| per-flow rate bit/s @ t+50 * | 21 656 917 (+8.3%) | 18 703 701 (-6.5%) | 14 766 080 (-26.2%) | sampling artefact |
| per-flow rate bit/s @ t+85 * | 26 578 944 (+32.9%) | 18 703 701 (-6.5%) | 26 578 944 (+32.9%) | sampling artefact |
| per-flow packet rate @ t+15/50/85 * | 1792 / 1877 / 2304 | 2133 / 1621 / 1621 | 2389 / 1280 / 2304 | sampling artefact |
| s1 input load bit/s @ t+15 | 20 666 669 (+3.3%) | 29 523 312 (+47.6%) | 26 572 140 (+32.9%) | sampling artefact |
| s1 input load bit/s @ t+50 | 29 519 895 (+47.6%) | 29 521 437 (+47.6%) | 14 762 261 (-26.2%) | sampling artefact |
| s1 input load bit/s @ t+85 | 29 524 774 (+47.6%) | 14 760 825 (-26.2%) | 8 857 008 (-55.7%) | sampling artefact |
| sum of edge utilisation % @ t+15/50/85 | 5.610 / 6.790 / 10.629 | 5.609 / 6.495 / 7.085 | 9.743 / 6.495 / 9.447 | sampling artefact |
| dispatch counter at pass start | 10 | 20 | 0 | **state leaked from the previous run** (within one fabric) |
| s1 boot routes for 10.0.0.3 / .4 | OUTPUT:2 / OUTPUT:2 | OUTPUT:2 / OUTPUT:2 | **OUTPUT:1 / OUTPUT:1** | **neither sampling nor leak -- see P3; unexplained when this table was written, attributed in `25_`** |
| iperf3 client source port | 37 847 | 35 696 | 57 307 | expected (OS-chosen) |

`*` carries COMMON-BRIEF s11's known no-denominator bias; cited, not re-derived.

**Ranges over the 9 cells, against a wire truth of exactly 20 000 000 bit/s with 0 % loss:**
per-flow rate **14 766 080 .. 27 563 349 (-26.2 % .. +37.8 %)**; s1 input load
**8 857 008 .. 29 524 774 (-55.7 % .. +47.6 %)**.

**Classification of the three buckets**

1. **Sampling artefact -- and it is arithmetic, not a shrug** (`21_`). Every reported packet rate is
   exactly `(k x 256) / window` with k = 5.00, 6.33, 7.00, 7.33, 8.33, 9.00, 9.33 -- k is literally the
   number of 1/256 samples that landed in a 1 s window. The offered 1785.7 pps predicts lambda = 6.98
   samples/s; the measured mean k is 7.52. (Measured sd 1.49 is *smaller* than Poisson's 2.64, so Poisson
   is an upper bound on the noise at n=9, not a fit.) Consequence: a **single** reading of
   `/ndt/get_detected_flow_data` or `get_total_input_traffic_load_passing_a_switch` at 20 Mbit/s carries
   roughly +/-38 % relative error, and nothing in the response says so.
2. **State leaked from the first run.** One item, and it is honest state, not a bug: the flow-dispatch
   counters are per-process and accumulate across passes on the same fabric (10 -> 20 on fabric A, 0 on
   the fresh fabric B). Separately, tonight's two known leaks were both re-confirmed and both handled:
   `ndt up p4 4` rewrote the tracked `p4_proxy/mininet/host_count_override` (restored twice by explicit
   single-file path), and every teardown was verified past round 3's 2.2 s orphaned-`curl` window.
3. **Unexplained -- and then explained.** The boot routing table (P3) was the only difference that was
   neither sampling nor leak. It is a coin flip, it changes which physical link carries a host pair, and
   the twin's path API is blind to it. It was recorded as unexplained and then chased down: `25_` attributes
   it to a BFS equal-length tie broken by graph insertion order, i.e. by LLDP packet-in arrival order.
   Nothing in this bucket was rounded away, and nothing was left as a shrug.

**A control that matters:** the h1 -> h2 flow used in the three passes took the identical path and lit the
identical 4 edges in all of them, so P1's spread is *not* contaminated by P3. The two findings are
separate, and each has its own evidence.

---

## C. Friction log -- where a reasonable person following the documentation would have been stuck

| # | what the docs said | what actually happened | what worked |
|---|---|---|---|
| 1 | `ndtwin_kernel --help`: "Logging options are also accepted; see `--logfile` / `--loglevel`", in a usage block whose other options are shown taking values (`--topology <path>`, `--mode <...>`) | `--logfile <path>` produced a 0-byte file at the path I named, with **no error on stderr**. It is a **boolean**: `Logger.cpp:31` is `if (arg == "--logfile" \|\| arg == "-f") cfg.enableFile = true;` and `:43` says "also write logs to **netdt.log**" -- a hard-coded name in the process's cwd. My path was swallowed as a stray positional. Verified before publishing (`26_`): `build/netdt.log` is 74 942 bytes; `build/` is gitignored, so nothing tracked was touched | capture **stdout** (the kernel logs there too), or `cd` to where you want `netdt.log` and pass the bare flag. The top-level `--help` should either show `--logfile` with no argument or reject a stray one |
| 2 | `make_topology.py` docstring: "a file dropped into `setting/` with the right name is picked up with no wiring: `ndt up ovs32` just works"; `ndt` enforces only "a multiple of 4 and at least 4" | there is **no documented way to bring a fabric up on a topology file you wrote**: `ndt up` derives its file from `host_count_override` (`ndt:479 topo_for_hosts`, `:576,579,1229`) with no override | run the kernel by hand -- `cd build && ./bin/ndtwin_kernel --mode mininet --topology <path> --no-ai`, which is what `stack.sh:897` does. **The workaround is not the procedure**: a hand-written topology can only be tested against a bare kernel, never against `ndt up`, without writing into tracked `setting/` |
| 3 | nothing states a host-count ceiling | 252 is the real ceiling; 256+ silently emits non-addresses | `--hosts <= 252`, and check the output with `ipaddress.IPv4Address` yourself |
| 4 | no doc names the HTTP method | `/ndt/get_num_of_flows_passing_a_switch` and `/ndt/get_total_input_traffic_load_passing_a_switch` are **POST with a JSON body**; a GET answers `{"error":"Not Found"}` with no hint the method was wrong | read `tools/contract_test/spec.py:929` for the shape |
| 5 | no doc names the response fields | my first instrument guessed `flow_sending_rate_bps` and recorded **`None` for every rate through a complete 100 s pass** without erroring. The real names are `estimated_flow_sending_rate_bps_in_the_last_sec` / `estimated_packet_rate_in_the_last_sec`, and IPs come back little-endian (round 4's observation, hit again) | capture the **whole row**, never a hand-picked subset; that pass is kept as `raw/pass0_shakedown.json` rather than deleted |
| 6 | -- | `sudo -n readlink /proc/<kernel pid>/exe` prompts for a password | the kernel runs as the invoking user; no sudo is needed |
| 7 | `ndt up` prints "Mininet CLI: `sudo tmux -L ndtwinlab attach -t topo`" | that command needs a password and cannot be run non-interactively | `ndt status`'s `topo session` field |
| 8 | `faults.sh` promises a three-channel quorum from `criteria.py` | on P4 it prints `paths unknown  all_destination_paths unreadable at http://localhost:8080` (Ryu's port; there is no Ryu on P4) and proceeds. The PASS rests on two channels and the tool does not say so | accepted the 2-channel verdict, and said so here |
| 9 | `ndt down` prints "verify clean" and "ports 8000/8080/8081 closed" | it checks **only** those three (round 1 D8, round 3 C4 -- re-read, still true) | checked 8000/8080/8081/9000/6653/6633/6343/30050-30060/9091-9100 and `/proc/net/udp` by hand every time |
| 10 | `ndt up p4 4` warns "host_count_override: 128 -> 4 (persistent; affects every later run)" | nothing ever restores it | `git checkout -- p4_proxy/mininet/host_count_override`, explicit single-file path, done twice (`23_`) |
| 11 | -- | my own outer shell loop was cut short mid-experiment, leaving a fabric up and two `iperf3` running while the driver was gone | sampled that cycle by hand, then re-drove the loop under `setsid` (`uplink_driver.sh`). Recorded, not deleted; cycle 1's row is labelled in `24_` |
| 12 | COMMON-BRIEF s7 warns that `sudo` forks rather than execs, so a captured pid is not the process to stop | **`setsid` has the same shape and it is not in the brief.** `setsid CMD &` gives `$!` = setsid's pid when setsid **forks**, and the child's pid when it **execs**; it forks iff the caller is already a process-group leader, so which one you get depends on the invocation context. In `run_mutant.sh` `ps -p $!` found `ndtwin_kernel`; in step 26 the same idiom found **nothing while the kernel was alive and holding `:8000` and `:6343`** | never trust `$!` across `setsid`: find the pid with `ps -eo pid=,comm=` and stop it by exact pid. That is how the stray kernel in `26_` was found and stopped, and the ports re-verified 0/0 |

---

## D. Refuted, explained, and doors closed -- worth as much

- **"The pass-to-pass spread is state leaking between runs."** REFUTED by its own control. `pass1b` --
  the same script on the same fabric minutes after `pass1a` -- has a spread as large as the between-fabric
  comparison, and the spread is fully accounted for by the 1/256 sampler (`21_`).
- **"The two passes measured different links."** REFUTED. The flow path and the set of non-zero edges were
  identical in all 9 samples (`raw/pass*.json` `flow_path`).
- **"A duplicated host edge is a defect."** NOT-A-DEFECT, and it was my negative control. My harness did
  not flag it (`08_`).
- **`faults.sh run L-3` PASSES on the P4 plane** -- before / during / after all `moving`, qdisc tree
  restored identically (44 lines). Round 1 ran this fault on OVS; I found no P4 run of it in tonight's four rounds, but I did not search earlier days (`19_`).
- **A background launch really was stopped by signal, verified through a second channel** (`19_`):
  SIGTERM to the exact `ping` pid (1386935, **not** the `sudo` launcher 1386934, which is COMMON-BRIEF
  s7's hazard); afterwards 0 rows for both pids and 0 `ping` processes machine-wide.
- **My first instrument was wrong and it is recorded, not deleted** (`raw/pass0_shakedown.json`, friction
  5): a complete 100 s pass recorded `None` for every per-flow rate because I guessed the field names.
  Caught by reading a live row, before any pass was used as evidence.

---

## E. Not done, and why

| id | why |
|---|---|
| Reproducing P3 deliberately by controlling LLDP arrival order | The mechanism is attributed (`25_`) and demonstrated offline, but no live run *forced* a chosen order. I also tried to tie a specific bring-up's uplink to that bring-up's discovery order after the fact and could not: at the shipped log level `p4_proxy.log` records neither `add_link` order nor the routes it pushes (`Pushing P4 rule` appears **0** times in 1694 lines), and changing proxy logging is out of scope for a measurement round. This is the confirming experiment for whoever writes the fix. |
| `faults.sh run L-2` (100 % unidirectional loss) on P4 | Time. L-3 already exercised the netem path end to end and the catalogue documents P4's L-2 recovery at 13.7 s over n=10, so it would characterise rather than discover. |
| Driving a hand-edited topology through `ndt up` | Structurally impossible without writing into tracked `setting/` -- see friction 2. Everything in section A's topology half was measured against a bare kernel. |
| The OVS-plane arm of any of this | `ovs4` has no sFlow (round 1 D4); the 128-host OVS fabric does but was not affordable here. T1-T6 are topology-reader findings and are plane-independent; R1/R2 are stated for **P4 only** (`ipv4_lpm` is an LPM table, which has no P4Runtime priority -- which is the reason the field cannot work there, and the reason the API should say so). |
| `viz` | Never started this round (round 3 captured the chain -- V1). |

---

## F. For a human to decide

1. **P3 is the one to look at first, and it is cheap.** Two identical bring-ups give different routes half
   the time. The cause is an equal-length BFS tie broken by graph insertion order in
   `topology_manager.calculate_all_paths` -- so the fix is a **canonical tie-break** (sort the candidate
   next hops), not a synchronisation change. Independently, `/ndt/get_path_switch_count` reports a hop
   *count* and is therefore blind to it; publishing the chosen hops would let a user detect the problem
   even before it is fixed. Until one of the two lands, no per-link utilisation figure from this platform
   is reproducible.
2. **`priority` should either work or be rejected.** On the P4 plane it is accepted, logged and dropped,
   and a modify at a priority that matches nothing rewrites the rule that exists. A 400 saying "this
   table has no priority" would be strictly better than a 200 with `succeeded`.
3. **`make_topology.py` needs one line**: refuse above 252 hosts, or emit a second octet. Today its own
   `validate()` blesses a file that aborts the kernel.
4. **A topology-load failure should not happen after the ports open.** Whatever the reason a file is
   rejected, `run()`'s load needs a try/catch that names the file and the offending node and exits before
   `:8000` and `:6343` are bound -- otherwise every health check sees a live kernel for one second.
5. **Publish the sample count beside every rate.** +/-38 % relative error at 20 Mbit/s is inherent to
   1/256 sampling and is not a bug; a response that carried `samples_in_window` would let a reader tell a
   measurement from a coin flip. This is the same shape as round 4's request 2.

---

## G. Lab state at end of round

`23_final_lab_state.log`, taken after the last of **18** bring-up/teardown cycles and verified through
channels other than any tool's own claim: **0** each of `ndtwin_kernel`, `simple_switch`, `ryu-manager`,
`java`, `iperf3`, `ping`, `mnexec` by `ps -eo comm=` (never `pkill`/`pgrep -f`); **0** mininet namespaces;
8000 / 8080 / 8081 / 9000 / **6653** / **6633** / **6343** / 30050-30060 / 9091-9100 all free, with **0**
sockets bound to 6343 in `/proc/net/udp`; **0** netem qdiscs anywhere; no switch manifest;
`ndt status` reports `topo session absent`. 7.8 GB available -- the 3 GB floor was never approached (the
minimum recorded across the round was 7.2 GB).

**Tracked files: exactly one was changed, and not by hand.** `ndt up p4 4` rewrites
`p4_proxy/mininet/host_count_override` 128 -> 4 as a designed side effect and announces it. Restored to
128 by explicit single-file path (`git checkout -- p4_proxy/mininet/host_count_override`), never a
directory pathspec; `git status` for that path is empty. Every topology mutation was made on a **copy**
under `topo/`. Everything else in `git status` belongs to other sessions.

This round's own files are all untracked, under
`doc/audit/2026-09-03_night-rounds/round5-topology-repro/`: 28 numbered logs, `raw/`, `topo/` (8 mutants),
seven harness scripts, `FINDINGS.md`, `SUMMARY.md`. **Nothing committed, nothing pushed.**
Claim `auditor` **kept**, as instructed -- 173 min left at 04:42.

**HEAD did not move under me** (`bd187870` at start and end) and **the binary did not move**
(`a8ba99c2...` on disk before and after, and the same hash from `/proc/<pid>/exe` on both fabrics).
Every number in this round is attributable to that binary at that commit.
