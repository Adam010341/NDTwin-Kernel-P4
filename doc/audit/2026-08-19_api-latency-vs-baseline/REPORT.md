# Did the kernel's read path get slower? Baseline `28b8b13` vs `b6b75fa`

**2026-08-19.** The read path is where our changes are heaviest — `FlowLinkUsageCollector.cpp`
+442/−168, `TopologyAndFlowMonitor.cpp` +454/−96, `HttpSession.cpp` +329/−234 — and nobody had
measured whether it cost anything. This round measures it.

**In one line:** on a matched build type and a matched topology, **the current kernel is not
slower than the baseline on any of the three read endpoints.**

[Co-developed with claude code -- Adam]

---

## 1. Method

Both kernels served the **same live fabric**: Ryu and the OVS 128-host Mininet topology were
started once and left running; only the kernel binary was swapped underneath them. So the graph
being serialised is identical, not merely similar.

- 200 calls per endpoint after 10 unmeasured warm-up calls, p50/p90/p99 reported.
- **The measurement script asserts the topology before timing** (`nodes / switches / edges`).
  The baseline kernel has no `--topology` flag and is configured by answering prompts on stdin,
  which is precisely how one silently measures the wrong graph. Both runs assert
  **138 nodes / 10 switches / 288 edges**.
- **The serving binary was verified from `/proc/<pid>/exe`**, not assumed — see §3.
- Baseline is `28b8b13` in a detached worktree. Its `-Werror` was removed to build under the
  current GCC (it fails on `warn_unused_result` for ignored `system()` returns); that changes
  no code generation.

## 2. Result

| endpoint | baseline `28b8b13` | current `b6b75fa` |
|---|---|---|
| `/ndt/get_graph_data` | p50 **13.02 ms** (p99 20.38) | p50 **11.99 ms** (p99 18.99) |
| `/ndt/get_switches_power_state` | p50 **1.21 ms** (p99 2.36) | p50 **0.79 ms** (p99 1.97) |
| `/ndt/get_cpu_utilization` | p50 **0.33 ms** (p99 0.52) | p50 **0.32 ms** (p99 0.48) |

**No endpoint regressed.** The defensible claim is *"not slower"* — not *"faster"*: the
per-call ranges overlap (baseline min 10.88 ms vs current max 21.34 ms on `get_graph_data`), and
a 1 ms difference in p50 at n=200 does not support a directional claim.

## 3. Two confounds that had to be removed first, and both changed the answer

**Build type was the entire first result.** The main tree is configured `CMAKE_BUILD_TYPE=Debug`;
the first baseline worktree was built `Release`. Comparing them gave *"current is 5.5× slower"* —
an artefact of `-O3 -DNDEBUG` against `-g`, nothing to do with our code. Rebuilding the baseline
as `Debug` reversed the direction of the result.

**The binary under test was not the one intended.** After rebuilding, the Debug kernel was
started while the Release kernel was still alive; it aborted on
`bind: Address already in use` for the sFlow collector's UDP 6343 and the old process kept
serving :8000. The numbers that came back looked plausible — 2.33 ms, near the Release figure —
and would have been recorded as "baseline Debug" had the crash not been noticed in the same
output. **A latency measurement must identify the process it measured**; `/proc/<pid>/exe` on
the listener is now part of the procedure.

## 4. Limitations

- **Debug builds both sides.** That matches what is actually running on this machine, but the
  absolute numbers are not what an optimised deployment would show. The comparison is valid;
  the magnitudes are not a performance claim.
- **Read path only, idle fabric, n=200.** Nothing here measures the write path, or behaviour
  under concurrent load from the 7 consuming applications.
- **`get_graph_data` at 57 ms is a different measurement.** That figure comes from the sFlow
  accuracy round, taken while a flow was running and the graph was being polled at 4 Hz. Idle,
  the same endpoint on the same topology is ~12 ms. Neither number is wrong; they are not
  interchangeable, and the condition has to travel with the number.
- **Single machine, single run of each.** No repetition across reboots.

## 5. Reproducing

```bash
git worktree add <dir> 28b8b13 --detach
cd <dir> && sed -i 's/    -Werror -pthread/    -pthread/' CMakeLists.txt
cmake -B build-debug -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build build-debug -j14
# with Ryu + the 128-host topology already up, and no other kernel holding :8000 / :6343
cd build-debug && printf '1\n2\n' | ./bin/ndtwin_kernel &
# confirm which binary is actually listening before timing anything
ss -lptn 'sport = :8000'
python3 api_latency.py 200
```
