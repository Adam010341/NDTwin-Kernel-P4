# Building bmv2 for realistic throughput

*(Proposed entry for the installation manual's P4 environment section; a one-line
cross-reference from the developer manual is enough on the other side.)*

### Why the default install is slow

The `simple_switch_grpc` produced by the common p4-guide install scripts is a **debug
build**: compiled `-O0` with all logging macros and the nanomsg event logger enabled.
Check which build you have — the configure invocation is recorded verbatim in the bmv2
source tree's `config.log` (look for `CXXFLAGS=-O0 -g`).

On such a build, every table lookup and parser state formats a log message that is then
thrown away. **Runtime options cannot recover this cost**: `--log-level off` does not
help, because the macro arguments are evaluated before the log level is checked. The only
fix is compile-time (`--disable-logging-macros`).

The practical ceiling of a debug build is packets-per-second-shaped, not
bandwidth-shaped: in our measurements the same ~3.6 kpps limit applies to 64-byte and
1400-byte packets alike (≈ 40 Mbps of delivered UDP at 1400 B, ≈ 24 Mbps of TCP goodput
— adding parallel TCP streams does not help). Any percentage-based logic layered on top
(e.g. a 70 % congestion threshold against links declared at 1 Gbps) is physically
untriggerable on a debug fabric. Excess packets are dropped **inside the first on-path
switch process** (its input buffer), so interface counters on the veth pairs will not
show the loss.

### Recommended build

Upstream's own `docs/performance.md` prescribes the performance configuration. Build it
to a **separate prefix** so the debug install stays available:

```bash
./configure --prefix=/usr/local/bmv2-fast --with-pi --with-thrift \
    --disable-logging-macros --disable-elogger \
    'CXXFLAGS=-O3 -g -DNDEBUG -march=native -fno-semantic-interposition'
make -j"$(nproc)" && sudo make install    # do NOT run ldconfig afterwards
```

Practical notes, each learned the hard way:

1. **Build from a fresh clone of the source tree.** If the tree already holds an in-tree
   configuration, autoconf refuses an out-of-tree configure, and `make distclean` would
   destroy the `config.log` that documents your existing build.
2. **Never run `ldconfig` after installing**, and always launch the fast binary with
   `LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib`. Both builds ship libraries with the same
   sonames; without this, the fast binary silently loads the debug libraries and you
   benchmark a mix. Verify with `/proc/<pid>/maps` that no library resolves to the old
   prefix.
3. **Re-run your functional tests against the fast binary before trusting any number
   from it.** Upstream warns this flag set cannot pass the complete p4c test suite. (In
   NDTwin's P4 testbed, pipeline push, route install and all-pairs connectivity were
   re-verified after the switch.)
4. `--disable-elogger` removes the nanomsg event stream some PTF tooling subscribes to.
   If your workflow needs it, keep the elogger and drop only the logging macros — the
   macros are the expensive half.

### Selecting the build per run

NDTwin's P4 testbed selects the switch binary through an optional one-line override file
next to the topology (`p4_proxy/mininet/bmv2_binary_override`) containing the absolute
path of the `simple_switch_grpc` to run. When the file is absent the stock `PATH` lookup
applies; the matching `lib/` directory is derived automatically into `LD_LIBRARY_PATH`;
a present-but-broken path refuses to start rather than silently falling back. Keep the
default (debug) build for functional work and select the fast build for load tests.

### What to expect (calibration numbers)

Measured on one host (14-core laptop-class CPU), through a 3-switch path of a 10-switch
fabric, full NDTwin stack running, iperf3, 2026-08:

| Metric (same fabric, same path, same commands) | debug build | performance build |
|---|---|---|
| UDP delivered ceiling (1400 B) | ~40 Mbps | ~460–530 Mbps |
| TCP goodput (1 stream = 8 streams) | ~24 Mbps | ~431 Mbps |
| 64 B packets delivered | ~3.6 kpps | ~50.8 kpps |
| Idle RTT across 3 hops | ~9 ms | ~2.8 ms |

Published figures are consistent in magnitude but not directly transferable — build
flags and topology dominate. Chen, Hu & Jin (SIGSIM-PADS '23) report ~170 Mbps for
`simple_switch_grpc` (16-switch linear topology; build conditions unstated) and up to
~1 Gbps for non-gRPC `simple_switch`; upstream's `docs/performance.md` reports
~917 Mbps for a single switch with the recommended flags. Measure your own fabric
before relying on any of these numbers.

### References

- p4lang/behavioral-model, `docs/performance.md` (recommended flags and upstream numbers)
- p4lang/behavioral-model README (`--disable-logging-macros`)
- Gong Chen, Zheng Hu, and Dong Jin. 2023. *Enhancing Fidelity of P4-Based Network
  Emulation with a Lightweight Virtual Time System.* In Proceedings of the 2023 ACM
  SIGSIM Conference on Principles of Advanced Discrete Simulation (SIGSIM-PADS '23).
  https://doi.org/10.1145/3573900.3591120 (literature throughput figures)
