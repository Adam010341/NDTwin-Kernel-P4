> 出處:2026-08-15 效能調查的 source-analysis subagent(唯讀,未動 tree 與 /usr/local)。
> 主 session 抽查驗證:config.log 的 -O0 invocation 引文屬實;官方 docs/performance.md 與
> 社群數字(~917 Mbps @ -O3+disable-logging/elogger)獨立佐證其結論。重建腳本已抽出為
> tools/test_workflow/build_bmv2_fast.sh;策展版結論在 doc/2026-08-15_bmv2-performance-report.md。

# Why `simple_switch_grpc` tops out near ~170 Mbps on this machine

Source tree: `/home/adam/P4_Source_Code/behavioral-model/`
Analysis date: 2026-08-15. Read-only; nothing in the tree or in `/usr/local` was modified.

---

## 0. Headline

The installed binary was compiled **`-O0`** (no optimization) with **all debug logging
macros and the nanomsg event logger left enabled**. Those two facts are recorded verbatim
in the tree's own build artifacts. On top of that, bmv2's hot path contains
**eagerly-evaluated `std::ostringstream` formatting on every table lookup, every table hit
and every parser state transition** — work that is performed even though the default log
sink is a null sink and nothing is ever printed.

`-O0` is the dominant multiplier because every P4 field value is a GMP-backed `Bignum`
(`include/bm/bm_sim/data.h:27,51`) accessed through ~180 tiny header-defined accessors that
are all supposed to be inlined away.

An `-O3 --disable-logging-macros --disable-elogger` rebuild is the single highest-leverage
change. Upstream p4-guide already ships that exact recipe as a commented-out line, with a
caveat (section 4.4).

---

## 1. How the installed binary was actually built

### 1.1 Provenance — the installed binary *is* from this tree

| Evidence | Value |
|---|---|
| `which simple_switch_grpc` | `/usr/local/bin/simple_switch_grpc` |
| Installed binary mtime | `Jul 13 17:19` |
| Last object built in tree (`targets/simple_switch_grpc/.deps/switch_runner.Plo`) | `2026-07-13 17:19:38` |
| Tree version (`config.h` `PACKAGE_VERSION`) | `1.15.3-f0b7d201` |
| `simple_switch_grpc --version` as recorded in `/home/adam/P4_Source_Code/log.txt:1107` | `1.15.3-f0b7d201` |

The version string embeds the git short SHA and matches the tree's `HEAD` exactly. All
bmv2 libraries in `/usr/local/lib` (`libbmall.*`, `libbm_grpc_dataplane.*`, `libbmpi.*`,
`libsimpleswitch_thrift.*`) also carry `Jul 13 17:19`. Provenance is confirmed.

The binary is `stripped` (`file` output) because the p4-guide installer uses
`sudo make install-strip` (`p4-guide/bin/install-p4dev-v8.sh:893`). Stripping removes the
`-g` debug info but **does not** change the `-O0` code generation.

`libbmall` does **not** appear in `ldd` output — the bm_sim core is statically linked into
the binary. The `/usr/local/lib` shared deps are PI, Thrift, and the grpc dataplane
services.

### 1.2 The exact configure invocation

`config.log:7` (first lines of the file, verbatim):

```
  $ ./configure --with-pi --with-thrift --with-python_prefix=/home/adam/p4dev-python-venv 'CXXFLAGS=-O0 -g'
```

Corroborated by `config.status:423`:

```
ac_cs_config='--with-pi --with-thrift --with-python_prefix=/home/adam/p4dev-python-venv '\''CXXFLAGS=-O0 -g'\'''
```

The `-O0` originates from p4-guide, not from a local decision —
`/home/adam/P4_Source_Code/p4-guide/bin/build-behavioral-model.sh:84`:

```sh
# With debug enabled in binaries:
./configure --with-pi --with-thrift ${configure_python_prefix} 'CXXFLAGS=-O0 -g'
```

### 1.3 Effective compiler flags

`-O0` propagated to **every** C++ compilation unit. Verified per-directory:

| Makefile | line | value |
|---|---|---|
| `Makefile` (top) | 239 | `CXXFLAGS = -O0 -g` |
| `src/bm_sim/Makefile` | 270 | `CXXFLAGS = -O0 -g` |
| `targets/simple_switch/Makefile` | 367 | `CXXFLAGS = -O0 -g` |
| `targets/simple_switch_grpc/Makefile` | 324 | `CXXFLAGS = -O0 -g` |

Also relevant:

- `CXX = g++ -std=c++17`, `AM_CXXFLAGS = -Wall -Wextra -pthread` (no `-march`, no LTO, no `-DNDEBUG`).
- `CFLAGS = -g -O2` — **only `CXXFLAGS` was overridden.** The C code (the BMI/pcap port
  layer, `src/BMI/*.c`) is therefore built `-O2`. All the expensive C++ (parser, match
  tables, PHV, deparser, pipeline) is the `-O0` part.
- Compiler: `GCC (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0` (`readelf -p .comment`).
- `assert()` is **live** — `-DNDEBUG` is absent, so the `assert` calls in the packet path
  (e.g. `src/BMI/bmi_port.c:123,152`) execute.

### 1.4 Feature switches — enabled vs disabled

`configure.ac` gates these; the generated `include/bm/config.h` (the `BM_`-prefixed header
that the code actually tests) is the ground truth:

| Feature | configure flag | Define in `include/bm/config.h` | State |
|---|---|---|---|
| Debug logging macros | `--disable-logging-macros` (**not passed**) | `BM_LOG_DEBUG_ON` | **ENABLED** |
| Trace logging macros | same flag | `BM_LOG_TRACE_ON` | **ENABLED** |
| Nanomsg event logger | `--disable-elogger` (**not passed**) | `BM_ELOG_ON` | **ENABLED** |
| Nanomsg transport | `--without-nanomsg` (**not passed**) | `BM_NANOMSG_ON` | **ENABLED** |
| pcap support | auto-detected | `BM_HAVE_LIBPCAP 1` | **ENABLED** |
| Remote debugger | `--enable-debugger` (**not passed**) | `BM_DEBUG_ON` | **DISABLED** (good) |
| Thrift runtime | `--with-thrift` (passed) | `BM_THRIFT_ON` | ENABLED |
| P4_16 stacks | default-on (`configure.ac:123`) | `WP4_16_STACKS` | ENABLED |

Why the two logging defines matter — `include/bm/bm_sim/logger.h:111-125`:

```cpp
#ifdef BM_LOG_DEBUG_ON
#define BMLOG_DEBUG(...) bm::Logger::get()->debug(__VA_ARGS__);
#else
#define BMLOG_DEBUG(...)
#endif
```

With `BM_LOG_DEBUG_ON` set, the macro expands to a real call, so **its arguments are
evaluated at the call site** before spdlog's level check ever runs. Compiling the macro out
is the only way to avoid that cost. Same structure for `BMELOG`
(`include/bm/bm_sim/event_logger.h:122-126`).

The debugger being off is genuinely free: `DEBUGGER_NOTIFY_CTR` /
`DEBUGGER_NOTIFY_UPDATE_V` expand to nothing (`include/bm/bm_sim/debugger.h:153-159`).

---

## 2. Per-packet cost centers

Ordered roughly by expected contribution. Every item is a per-packet or per-packet-per-object cost.

### 2.1 `-O0`: every field access is an un-inlined call into GMP

`include/bm/bm_sim/data.h:48-51`:

```
//! Note that Data includes a Bignum (for arbitrary arithmetic). Therefore,
class Data {
```

Each P4 field value is a `bignum::Bignum`. Header-defined accessor counts in the hot data
structures — all of these are written to be inlined and none of them are at `-O0`:
`data.h` ~55, `packet.h` ~40, `phv.h` ~32, `bytecontainer.h` ~29, `fields.h` ~23.
At `-O0` GCC emits a real call+frame for each. This multiplies the cost of every other item
below and is why `-O0` → `-O3` is the largest single lever here.

### 2.2 Eager string building on the hottest paths (needs `BM_LOG_*` compiled out)

**(a) Every match-table lookup** — `src/bm_sim/match_units.cpp:783`:

```cpp
  // BMLOG_DEBUG_PKT(pkt, "Looking up key {}", key_to_string(key));
  BMLOG_DEBUG_PKT(pkt, "Looking up key:\n{}", key_to_string_with_names(key));
```

Note upstream left the *cheap* variant commented out on line 782 and shipped the expensive
one. `key_to_string_with_names` (`match_units.cpp:754-773`) constructs a
`std::ostringstream`, calls `key_to_fields()` (which builds a vector of `ByteContainer`s),
then loops applying `std::setw`/`std::left` and `dump_hexstring` per key field, and finally
returns `ret.str()` by value. This runs for **every table, for every packet**, and the
result is handed to a null sink and discarded.

**(b) Every table hit** — `src/bm_sim/match_tables.cpp:116`:

```cpp
    // TODO(antonin): change to trace?
    BMLOG_DEBUG_PKT(*pkt, "{}", dump_entry_string_(handle));
```

`dump_entry_string_` (`match_tables.cpp:344-350`) serialises the entire matched entry
through another `std::ostringstream`. Worse, `match_tables.cpp:109` notes
`// we're holding the lock for this...` — this serialisation happens while the table's read
locks (`lock_read()`, `lock_impl_read()`, acquired at `match_tables.cpp:90-91`) are held.

**(c) Every parser state transition** — `src/bm_sim/parser.cpp:1066`:

```cpp
  BMLOG_DEBUG_PKT(*pkt, "Parser state '{}': key is {}",
                  get_name(), key.to_hex());
```

`key.to_hex()` allocates a fresh `std::string` per state, and a parser walks many states per
packet.

**(d) Checksum verify** — `src/bm_sim/checksums.cpp:152-154` evaluates
`convertU64ToHexStr()` twice per checksum per packet.

The default sink is a **null sink** — `src/bm_sim/logger.cpp:67-68` creates
`spdlog::sinks::null_sink_mt` when neither `--log-console` nor `--log-file` is given. That
suppresses the I/O but **not** the argument evaluation above. This is the key insight: not
passing `--log-console` does *not* buy you the logging cost back.

### 2.3 Event logger (`BM_ELOG_ON`) — per event, even with no subscriber

`BMELOG(...)` fires at `packet_in` (`simple_switch.cpp:239`), `packet_out`
(`simple_switch.cpp:383`), parser start/done/extract, deparser start/done/emit, pipeline
start/done, and per table hit/miss (`match_tables.cpp:111,118`). Each handler builds a
packed message struct and makes a **virtual** `transport_instance->send(...)` call —
e.g. `src/bm_sim/event_logger.cpp:218-230`. Without `--nanolog` the transport is
`TransportDummy` (`src/bm_sim/transport.cpp:90-92`), so there is no I/O, but the struct fill
and the virtual dispatch still happen per event per packet, and at `-O0` none of it is
elided.

### 2.4 Packet receive path — one packet per `select()` wakeup, one thread for all ports

`src/BMI/bmi_port.c:101-172`. A **single** `run_select` thread services every port:

- `select()` per iteration with a 100 ms timeout and an `fds`/`max_fd` copy taken under
  `pthread_rwlock_rdlock` (lines 117-122).
- The drain loop (lines 150-169) calls `bmi_interface_recv` **exactly once** per
  ready port per `select()` iteration (line 156). Even if a port has a backlog, only one
  packet is dequeued before the next `select()` syscall. RX is therefore bounded by the
  `select()` round-trip rate, not by packet arrival rate — and it degrades as port count
  rises because the ready-port scan is linear.
- A global `pthread_rwlock` is held across the whole drain loop (lines 139-171), plus a
  per-packet `pthread_mutex` for stats (lines 161-164).

Underneath, `bmi_interface_recv` uses libpcap one packet at a time via `pcap_next_ex`
(`src/BMI/bmi_interface.c:132`), not raw `AF_PACKET` with a ring buffer.
`pcap_set_immediate_mode(..., 1)` is active (`bmi_interface.c:63`, guarded by
`WITH_PCAP_FIX`, which **is** defined — `src/BMI/Makefile:95`,
`am__append_1 = -DWITH_PCAP_FIX`). Immediate mode minimises latency but deliberately
defeats kernel-side batching, so there is one syscall's worth of overhead per packet.

Note this C layer is the `-O2` part; it is a structural (syscall/threading) cost, not a
codegen cost.

### 2.5 Thread architecture and queue hand-offs

`targets/simple_switch/simple_switch.cpp:271-275`:

```cpp
  threads_.push_back(std::thread(&SimpleSwitch::ingress_thread, this));
  for (size_t i = 0; i < nb_egress_threads; i++) {
    threads_.push_back(std::thread(&SimpleSwitch::egress_thread, this, i));
  }
  threads_.push_back(std::thread(&SimpleSwitch::transmit_thread, this));
```

- **1 ingress thread.** All parsing + ingress match-action for every port is serialised
  through this one thread. This is the primary throughput ceiling once RX is fed.
- **4 egress threads** — `nb_egress_threads` is a `static constexpr size_t` at
  `targets/simple_switch/simple_switch.h:140`. **Compile-time constant; there is no runtime
  flag to raise it.**
- **1 transmit thread**, plus the BMI `run_select` RX thread. Seven threads total on a
  14-core machine — core count is not the constraint.

Every packet crosses three mutex+condvar hand-offs: `input_buffer` →
`egress_buffers` → `output_buffer`. The `InputBuffer` (`simple_switch.cpp:116-190`) uses one
`std::mutex` plus three condition variables, and `push_front`/`pop_back` each take the lock
and signal a condvar per packet (lines 171-179, 145-161).

Queue capacities, all from the constructor at `simple_switch.cpp:199-205`:

| Queue | capacity | source |
|---|---|---|
| `input_buffer` normal (lo) | 1024 packets | `simple_switch.cpp:200` |
| `input_buffer` resubmit/recirc (hi) | 1024 packets | `simple_switch.cpp:200` |
| `egress_buffers` per queue | **64 packets** | `simple_switch.cpp:203` |
| `output_buffer` | 128 packets | `simple_switch.cpp:205` |
| priority queues per port | 1 (`default_nb_queues_per_port`) | `simple_switch.h:69` |

The 64-deep egress buffer is the shallowest link and the one worth raising first (§3.2).
Normal-packet enqueue is blocking, so a full queue back-pressures the interface
(`simple_switch.cpp:114-115`).

**No default rate limit.** `egress_buffers` is a `QueueingLogicPriRL`
(`simple_switch.h:194-195`), whose `queue_rate_pps` defaults to `0`
(`include/bm/bm_sim/queueing.h:815`), and `rate_to_ticks(0)` returns `ticks(0)`
(`queueing.h:694-699`). So the ~170 Mbps is **not** a configured throttle — it is CPU cost.
The dequeue path does still call `clock::now()` per packet via `get_next_tp`
(`queueing.h:764-767`).

### 2.6 PHV acquisition — global mutex per packet

`src/bm_sim/phv_source.cpp:26-51`. PHVs are pooled rather than reallocated, but both
`get()` (line 36) and `release()` (line 48) take a single `std::mutex` guarding the whole
pool. That is two lock/unlock pairs per packet, contended between the ingress thread and
the four egress threads.

### 2.7 String-keyed PHV lookups per packet

`include/bm/bm_sim/phv.h:75` — `using FieldNamesMap = std::unordered_map<std::string, FieldRef>;`
and `get_field(const std::string&)` is `fields_map.at(field_name)` (line 133). Each call
hashes a string.

`SimpleSwitch::receive_` alone does this ~5 times per packet
(`simple_switch.cpp:249,253,254,257,258`), and `ingress_thread` /`egress_thread` add more
(`simple_switch.cpp:505,510,519,531` and `671,674,676,681,683`). Also
`phv->reset_metadata()` (`simple_switch.cpp:244`) walks **all** headers per packet
(`src/bm_sim/phv.cpp:51-56`).

### 2.8 Parser / deparser genericity

`Parser::parse` is a data-driven interpreter: it walks `ParseState` objects, and each state
runs a vector of `parser_op` virtual functors (`src/bm_sim/parser.cpp:1050`) then builds a
match key and linearly scans `parser_switch` cases (`parser.cpp:1069-1072`). Nothing is
specialised per P4 program. Deparsing mirrors this — `Deparser::deparse`
(`src/bm_sim/deparser.cpp:57-77`) calls `update_checksums(pkt)` (line 66), then `prepend`s a
buffer (line 67) and runs a vector of virtual `deparser_op`s (lines 73-74) under
`RegisterSync::RegisterLocks` (lines 70-71). Every step is an indirect call at `-O0`.

### 2.9 Clone / mirroring (1-in-256 clone-to-CPU) — real but **not** your bottleneck

`targets/simple_switch/simple_switch.cpp:552-566`. The cloned packet is **re-parsed from
scratch**, with upstream's rationale in the comment at lines 556-558:

```
        // We need to parse again.
        // The alternative would be to pay the (huge) price of PHV copy for
        // every ingress packet.
```

So each clone costs roughly one extra full parse plus a buffer copy
(`clone_no_phv_ptr()`, line 552) and another `enqueue` (line 577). At a 1/256 sampling
rate that is well under 1% amortised overhead. **Do not chase this** — it is a rounding
error next to §2.1 and §2.2. The egress clone path (`simple_switch.cpp:707`) is analogous.

### 2.10 Learning and ageing — background, not per-packet

Ageing runs a dedicated sweep thread on a 1000 ms default interval
(`include/bm/bm_sim/ageing.h:38,97`); learning uses a separate transmit thread with a
1000 ms default timeout (`src/bm_sim/learning.cpp:286`, `include/bm/bm_sim/learning.h:48`).
Per-packet cost is incurred only when a P4 program actually calls `learn`
(`simple_switch.cpp:584-586`, gated on `learn_id > 0`). Neither is a factor here.

---

## 3. Runtime knobs

### 3.1 Command-line options that affect performance

From `src/bm_sim/options_parse.cpp:84-156` (bmv2 core, shared by both targets):

| Option | Default | Performance note |
|---|---|---|
| `--log-console` | off | Switches the null sink to stdout. Adds real I/O on top of the already-paid formatting. **Leave off.** |
| `--log-file <f>` | off | As above, to a file. |
| `--log-flush` | off | With `--log-file`, flushes after **every** message. Catastrophic if logging is on. |
| `--log-level,-L` | help text says `trace`; sink is null unless a `--log-*` is given | Lowers I/O volume but **does not** avoid the §2.2 argument evaluation. |
| `--pcap [dir]` | **off** (`default_value("")`, `implicit_value(".")`) | Enables per-interface pcap dumping. `src/BMI/bmi_interface.c:120-122,140-142` calls `pcap_dump` **plus `pcap_dump_flush` on every single packet**, both RX and TX. Never enable this in a throughput test. |
| `--nanolog <sock>` | off (dummy transport) | Replaces `TransportDummy` with a real nanomsg PUB socket, turning every `BMELOG` into an actual send. **Leave off.** |
| `--dump-packet-data <n>` | `0` (nothing logged) | Logs n bytes of every packet at `info` level. Leave at 0. |
| `--notifications-addr` | `ipc:///tmp/bmv2-<id>-notifications.ipc` | Only carries learn/age notifications. |
| `--debugger` / `--debugger-addr` | n/a | **Not even compiled in** — the options are inside `#ifdef BM_DEBUG_ON` (`options_parse.cpp:132-138`) and `BM_DEBUG_ON` is unset. |
| `--max-port-count` | `default_max_port_count` | Larger values grow the BMI port array that `run_select` scans linearly. |

`simple_switch_grpc` adds `--grpc-server-addr`, `--cpu-port`, `--dp-grpc-server-addr`
(`targets/simple_switch_grpc/main.cpp:36,54,70`); none are throughput knobs. Note that
`--dp-grpc-server-addr` switches the dataplane to gRPC-based packet I/O instead of veth,
which is a different (not obviously faster) path.

**There is no CLI flag for worker-thread count or for the input/egress queue depths.**

### 3.2 Runtime knobs available through `simple_switch_CLI` (Thrift)

`targets/simple_switch/sswitch_CLI.py`:

- `set_queue_depth <port> <depth>` (line 45) → `set_egress_queue_depth`
  (`simple_switch.cpp:332`). Raises the per-port egress buffer above the default 64.
- `set_queue_rate <port> <pps>` (line 61) → `set_egress_queue_rate`
  (`simple_switch.cpp:351`). Default is unlimited (§2.5) — only useful to *impose* a limit,
  and worth checking that nothing in your harness sets it.

Raising queue depth helps burst absorption and reduces back-pressure stalls; it does not
raise steady-state throughput, which is CPU-bound.

### 3.3 What to check on the running switch first

Confirm the live process is not making things worse than the build already does:

```sh
pgrep -ax simple_switch_grpc   # look for --log-console, --log-file, --pcap, --nanolog
```

Any of those four present would mean measurable headroom is available with no rebuild.

---

## 4. Build-time recipe: a maximum-performance build at a separate prefix

### 4.1 Read this before running it

Upstream's own warning, `p4-guide/bin/build-behavioral-model.sh:89-92`:

```sh
# With more aggressive C++ compiler optimization enabled, but I believe
# that with all of these options, the resulting simple_switch binary
# cannot be used to achieve passing results on all p4c tests.
#./configure 'CXXFLAGS=-g -O3' 'CFLAGS=-g -O3' --disable-logging-macros --disable-elogger
```

Two consequences worth planning around:

1. `--disable-elogger` removes the nanomsg event stream. Some p4c/PTF test tooling
   subscribes to it, and `configure.ac:80` notes it "is required for some tests". If any of
   your validation depends on the event stream, build with elogger but still drop the
   logging macros — you keep most of the win (§2.2 is the expensive half).
2. `--disable-logging-macros` compiles out `BMLOG_DEBUG`/`BMLOG_TRACE` entirely, so
   `--log-console` and `--log-file` will emit almost nothing on the fast binary. Keep the
   existing `/usr/local` build for any debugging that needs packet-level logs. That is
   exactly why this installs to a separate prefix.

### 4.2 The script

Builds out-of-tree into a scratch directory and installs to `/usr/local/bmv2-fast`. The
existing `/usr/local` installation is never written to.

```sh
#!/usr/bin/env bash
set -euo pipefail

SRC=/home/adam/P4_Source_Code/behavioral-model
PREFIX=/usr/local/bmv2-fast
BUILD=/tmp/bmv2-fast-build
VENV=/home/adam/p4dev-python-venv

# Out-of-tree build: leaves $SRC/Makefile, config.log and config.h untouched,
# so the existing -O0 build config stays reproducible.
rm -rf "$BUILD" && mkdir -p "$BUILD"
cd "$SRC" && ./autogen.sh
cd "$BUILD"

PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
"$SRC"/configure \
  --prefix="$PREFIX" \
  --with-pi \
  --with-thrift \
  --with-python_prefix="$VENV" \
  --disable-logging-macros \
  --disable-elogger \
  'CXXFLAGS=-O3 -g -DNDEBUG -march=native -fno-semantic-interposition' \
  'CFLAGS=-O3 -g -DNDEBUG -march=native'

# Expect the recap to print:
#   Logging macros enabled ........ : no
#   Event logger enabled .......... : no
#   Debugger enabled .............. : no

make -j"$(nproc)"
sudo make install          # NOT install-strip: keep symbols for perf/py-spy
```

Flag rationale, each tied to a finding above:

- `-O3` — restores inlining of the `Bignum`/`Field`/`PHV`/`ByteContainer` accessors (§2.1).
- `--disable-logging-macros` — compiles out the `ostringstream` work at
  `match_units.cpp:783`, `match_tables.cpp:116`, `parser.cpp:1066` (§2.2). Highest-value
  flag after `-O3`.
- `--disable-elogger` — compiles out `BMELOG` struct-fill + virtual send (§2.3).
- `-DNDEBUG` — removes the live `assert()`s in the packet path (§1.3).
- `-march=native` — safe here because the binary will only run on this machine.
- `-fno-semantic-interposition` — lets the shared libraries inline internal calls.
- No `--enable-debugger` — it is already off and must stay off.
- Deliberately **not** stripping, so profiling still works (`py-spy`/`perf` on this codebase
  is how several past findings were made).

### 4.3 Running the fast binary without disturbing the existing install

This tree builds `libbm_grpc_dataplane`, `libruntimestubs` and `libsimpleswitch_thrift` as
shared objects, and copies of them already exist in `/usr/local/lib` from the `-O0` build.
The new binary must be made to load the **new** ones, or you will silently benchmark a mix:

```sh
export LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib:${LD_LIBRARY_PATH:-}
/usr/local/bmv2-fast/bin/simple_switch_grpc --version   # expect 1.15.3-f0b7d201

# Verify the right libraries resolved — every bmv2/services lib should point at
# /usr/local/bmv2-fast/lib, not /usr/local/lib:
ldd /usr/local/bmv2-fast/bin/simple_switch_grpc | grep -E 'bm_grpc|runtimestubs|simpleswitch'
```

`libbmall` is statically linked, so the bm_sim core needs no runtime path help — but the
three libraries above do. Do **not** run `ldconfig` after this install; that would put the
fast libs on the global search path and change the behaviour of the existing
`/usr/local/bin/simple_switch_grpc`.

To point NDTwin at the fast binary, override the switch path in the topology/helper rather
than changing `PATH` globally, so the two installs stay independently selectable.

### 4.4 Expected outcome and how to verify honestly

I am deliberately not predicting a speedup multiple — the memory note
`arithmetic-that-fits-is-not-the-mechanism` applies. Measure it:

1. Record the current baseline with the existing binary on a fixed workload.
2. Rebuild per §4.2, re-run the identical workload with `LD_LIBRARY_PATH` set.
3. If the gain is smaller than expected, profile rather than guess — attach `py-spy`/`perf`
   through `mnexec` (per the `py-spy-via-mnexec-under-ptrace-scope` note) and confirm
   whether time has moved out of `key_to_string_with_names` / `dump_entry_string_` and into
   the `run_select` RX loop (§2.4). If it has, the next ceiling is structural
   (single RX thread, one packet per `select()`, single ingress thread) and **no configure
   flag will move it** — that would require a source change.
4. Re-run the P4 functional tests against the fast binary before trusting any result from
   it, given the upstream caveat in §4.1.

Note also that `bmv2-scale-ceiling-and-sflow-sample-math` in memory already records the
>64-switch fidelity ceiling; a faster per-switch binary changes the per-switch number but
not the sampling-error floor.

---

## 5. Source version

- Repo: `/home/adam/P4_Source_Code/behavioral-model` (git checkout).
- `HEAD`: `f0b7d201570d088a056b7fe660802ca1a8bcb912`
- Date: `2026-07-08 14:42:22 -0400`
- Subject: `Bump actions/checkout from 6 to 7 (#1420)` (author `dependabot[bot]`)
- `git describe`: `1.15.3-14-gf0b7d20` → 14 commits past the `1.15.3` tag.
- Package version string: `1.15.3-f0b7d201` (`config.h`), matching the installed binary.

Working tree is clean with respect to compiled sources — the only modifications are
`ci/install-thrift.sh` and `install_deps.sh`, plus untracked `ci/install-thrift.sh.orig` and
`targets/simple_switch_grpc/config.h.in`. **No `src/` or `targets/` file is modified**, so
the built code corresponds exactly to upstream `f0b7d201`.

Machine: 14 cores, 15 GB RAM, kernel 6.17.0-35-generic.
