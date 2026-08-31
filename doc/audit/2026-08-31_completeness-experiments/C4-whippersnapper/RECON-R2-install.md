# RECON-R2 — Whippersnapper (p4benchmark) install-only reconnaissance

Date: 2026-08-31. Scope per PREREG-C4-whippersnapper.md v0.2: **installation and
static enumeration only; no measurement was run.** Concretely: no
experiment.py / run_test.py / pktgen execution, no bmv2 process with a loaded
P4 program, no traffic generated. Everything below comes from reading code at
the pinned commit or from container installs.

Artifact: https://github.com/usi-systems/p4benchmark
HEAD at recon time: `e1b22c106c3458f757a362f57027670cee286c47`
(2017-05-06 13:54:19 +0200, "run packet generator without filter" — repo has
been dormant since; master == this commit).

All file/line references below are against that commit.

---

## 1. Container base decision

**Chosen: `ubuntu:16.04` (xenial).** Rationale and evidence:

- Probed 2026-08-31: stock `ubuntu:16.04` `apt-get update` **succeeds against
  archive.ubuntu.com** — xenial has NOT been moved to old-releases yet, so the
  anticipated sources-rewrite deviation was **not needed** (probe-results.log,
  PROBE 0).
- The artifact's own install script fingerprints the authors' distro as
  **trusty (14.04)**: `install_bmv2.sh:5` adds
  `deb http://cran.rstudio.com/bin/linux/ubuntu trusty/`. 16.04 was tried
  first per task instruction; **`ubuntu:14.04` probed viable as fallback**
  (stock apt works, image pulls) and is the more period-exact choice if xenial
  hits toolchain friction (bmv2 1.3.0 hardwires `-Wall -Werror -Wextra`,
  behavioral-model/configure.ac:158; xenial gcc 5.4 vs trusty gcc 4.8).
- Base image freshness note for the prereg: `ubuntu:16.04` docker tag was last
  rebuilt 2021; its apt state is period-frozen modulo xenial-updates.

## 2. What install_bmv2.sh installs, exactly (script section by section)

Script: `install_bmv2.sh` at repo root (79 lines, `set -e`, sudo-per-line).

| Lines | Step | Source | Pinned? |
|---|---|---|---|
| 5–7 | apt repo `deb http://cran.rstudio.com/bin/linux/ubuntu trusty/` + GPG key E084DAB9 from keyserver.ubuntu.com | cran.rstudio.com | repo dist pinned to trusty (mismatch on any non-trusty host) |
| 9 | `apt-get update` | Ubuntu archive | — |
| 12 | R build deps: libcurl4-gnutls-dev libxml2-dev libssl-dev libcairo-dev | Ubuntu archive | distro version |
| 15–16 | bmv2 deps: git autoconf python-pip build-essential python-dev cmake libjudy-dev libgmp-dev libpcap-dev **mktemp** libffi-dev **r-base** gawk | Ubuntu archive | distro version |
| 18–19 | `git submodule init && git submodule update` | github p4lang | **PINNED gitlinks** (see §3) |
| 22–24 | thrift build deps (boost dev/test/program-options/filesystem/thread, libevent, automake, libtool, flex, bison, pkg-config, g++, libssl-dev) | Ubuntu archive | distro version |
| 25–35 | **thrift 0.9.3** from `http://mirror.switch.ch/mirror/apache/dist/thrift/0.9.3/thrift-0.9.3.tar.gz`; `./configure --with-cpp=yes --with-c_glib=no --with-java=no --with-ruby=no --with-erlang=no --with-go=no --with-nodejs=no`; `sudo make -j2; sudo make install` | switch.ch mirror (**dead**, see §8) | version pinned by URL |
| 38–39 | nanomsg via `behavioral-model/travis/install-nanomsg.sh` → **nanomsg 1.0.0** tarball from github, cmake, install to `/usr` | github nanomsg | pinned by script (1.0.0) |
| 42 | nnpy via `behavioral-model/travis/install-nnpy.sh` → `pip install cffi` (unpinned) + nnpy git checkout `c7e718a5173447c85182dc45f99e2abcf9cd4065` | PyPI + github | nnpy pinned; **cffi floating** |
| 48–53 | bmv2: `./autogen.sh`; **`./configure`** (live line = prereg Arm S); `sudo make`. The commented-out line 51 is prereg Arm F verbatim: `#./configure --disable-logging-macros --disable-elogger CXXFLAGS=-O3` | submodule tree | pinned via gitlink |
| 55–58 | p4c-bm: `pip install -r requirements.txt` (= wheel==0.23.0, Tenjin==1.1.1, `git+https://github.com/p4lang/p4-hlir.git#egg=p4-hlir`), `-r requirements_v1_1.txt` (= p4-hlir `@p4v1.1` branch), `python setup.py install` | PyPI + github p4lang | wheel/Tenjin pinned; **p4-hlir floats on branch heads** |
| 61 | top-level `pip install -r requirements.txt` = sphinx, sphinx-autobuild, nose, nose-parameterized, thrift, scapy — **all unpinned** | PyPI | **floating** |
| 62 | `sudo ./veth_setup.sh` — creates 9 veth pairs (veth0..veth17), offloads off, ipv6 off | local | runtime config, not install |
| 64–68 | pktgen: cmake + make → builds **two binaries**: `p4benchmark` (open-loop, src/main.c) and `sendb2b` (closed-loop, src/close_loop.c) | local C | — |
| 72–77 | appends `P4BENCHMARK_ROOT` + `PYTHONPATH` to ~/.bashrc | — | — |
| 79 | `chown -R $USER /usr/local/lib/R` | — | cosmetic |

Both configure lines the prereg registers as Arm S / Arm F are present verbatim
at `install_bmv2.sh:50-52`:

```sh
# better performance for behavioral-model
#./configure --disable-logging-macros --disable-elogger CXXFLAGS=-O3
./configure
```

Both flags exist in the pinned bmv2 tree (`configure.ac:59` `--disable-logging-macros`,
`configure.ac:68-69` `--disable-elogger`), so Arm F is buildable against this
exact tree (NOT built during this recon — recon builds one path only, Arm S).

## 3. bmv2 tree: pinned, not master (feeds the prereg tree-generation TBD)

The install script does **not** clone bmv2 master. `behavioral-model` and
`p4c-bm` are **git submodules with pinned gitlinks** (`.gitmodules` + gitlink
objects in the tree; `git ls-tree HEAD`):

- `behavioral-model` → **`e182c0f1876541221fdeb27c596cc95d054b391f`**
  = **exactly tag `1.3.0`** ("changed VERSION number to 1.3.0 for release",
  2016-09-23 10:46:09 -0700). A true 2016/2017-era tree; the prereg's fear of
  "抓 master 拿到 2026 樹" does **not** materialize.
- `p4c-bm` → `a9edd780e39b5a6c834f05aac3f906e849ca5ad1`
  (2016-10-06, `git describe` = v0.1.0-136-ga9edd78).

Residual floating dependencies (the parts that are NOT period-frozen):
1. **p4-hlir** installed from `git+https://github.com/p4lang/p4-hlir.git`
   master (and `@p4v1.1` branch) — whatever those branch heads are today
   (repo archived/dormant, master resolved to `a30208c9…`, installed as
   p4-hlir-0.9.59 in probes).
2. **Unpinned pip packages** (cffi, scapy, thrift-py, sphinx, nose…) — resolved
   at install time (see §8 for what they resolve to today and how).
3. Ubuntu package versions (xenial-updates state as of the frozen image).

## 4. Benchmark features exposed (p4bench.py / p4gen)

`p4bench.py` (= console script `p4benchmark`, setup.py entry_points) generates
a P4_14 program + matching test.pcap + run_switch.sh + commands.txt +
run_test.py into `output/`. Features (`p4bench.py:14-19`) and knobs:

| Feature | Knobs (argparse, p4bench.py:24-48) |
|---|---|
| `parse-header` | --headers N, --fields M (+--checksum) |
| `parse-field` | --fields M (+--checksum) |
| `parse-complex` | --depth D, --fanout F |
| `set-field` (action complexity) | --operations N (+--checksum) |
| `add-header` / `rm-header` (packet modification) | --headers N, --fields M |
| `pipeline` (processing) | --tables N, --table-size S |
| `read-state` / `write-state` (registers) | --registers R, --nb-element E, --element-width W, --operations N |

Test packets: Ether/PTP(+custom P4Bench headers), padded to 256 B default
(`p4gen/genpcap.py:get_parser_header_pcap`, `packet_size=256`).

Sweep harnesses on top of the generator:
- `benchmark/pen_parser.py` (+ pen_pipeline / pen_memory / pen_packet_mod,
  chained by `benchmark/run_all.py`): e.g. pen_parser sweeps nb_headers
  5→40 step 5; for each, raises `offer_load` from 100000 in +100000 steps
  **until the first lost packet** (pen_parser.py:44-53) — i.e. a loss-bounded
  max-load search; every (headers, load) cell leaves a result directory.
  Same shape in the siblings: pen_pipeline sweeps nb_tables 5→40
  (pen_pipeline.py:48), pen_packet_mod sweeps nb_operations 5→40
  (pen_packet_mod.py:47), pen_memory sweeps nb_registers {1,2,4,8,16} with
  offer_load starting at 1 (pen_memory.py:53-54).
- `benchmark/run_experiment.py`: one experiment described by an
  `experiment.json` (types: mod|field|mem|pipeline|parser), closed-loop
  sendb2b at fixed count (default 100000).
- `experiment.py` (repo root): **not a bmv2 harness** — PISCES + MoonGen
  orchestration over ssh to hardcoded hosts `node97`/`node98` with hardcoded
  paths (`/home/danghu/...`, experiment.py:144-147); sweeps variable
  {1,2,4,8,16} × 5 reps at rate 10000 (experiment.py:153-162). Unrunnable
  outside their testbed; out of scope for a single-container bmv2 rerun.

## 5. OUTPUT FIELDS — what the pipeline actually emits (feeds primary-list TBD)

### 5a. `output/run_test.py` (scapy sender/sniffer template, p4gen/template/run_test.py)

Functional distribution check only — **no latency, no throughput**:
- line 176: `print "Sending", args.nb_packets, "packets ..."`
- lines 189-192:
  ```python
  print "DISTRIBUTION..."
  for p in port_map:
      c = ports.count(p)
      print "port {}: {:>3} [ {:>5}% ]".format(p, c, 100. * c / args.nb_packets)
  ```
  → per-port received count and percentage over veth0/veth2/veth4, stdout only,
  nothing written to disk. Send pattern: bursts of 10 pkts at 5 ms spacing,
  then a random 25–100 ms gap (`PacketDelay(10, 5, 25, 100)`, line 174).

### 5b. `pktgen/build/p4benchmark` (open-loop C generator, src/main.c)

Used by `benchmark/benchmark.py::run_packet_generator` (benchmark.py:104-116),
stdout→`latency.csv`, stderr→`loss.csv`:
- **Once per second** (report_stat thread), main.c:153:
  ```c
  fprintf(ctx->fp, "%-8lu %-6.3f\n", stat.nb_packets, avg_us);
  ```
  → columns: `packets_received_this_1s_window  mean_latency_microseconds`.
  (CMakeLists.txt defines no WRITE_TO_FILE, so `fp = stdout`; the `-o
  output_fn`/"stat.csv" path is dead code in the shipped build.)
- Latency definition: sender embeds `gettimeofday` timeval into the payload
  tail at send (main.c:301-302); receiver subtracts it from the pcap header
  timestamp (main.c:164-167) → **same-host RTT through the switch, µs**.
- **Final line to stderr**, main.c:180-181:
  ```c
  fprintf(stderr, "%-10d %-10lu %-10.3f\n",
      total_sent, stat.total_packets, lost);
  ```
  → `total_sent  total_received  loss_fraction`. (`benchmark.py:has_lost_packet`
  reads exactly this 3-field last line of loss.csv.)
- stderr also gets one `packet-size N` line per pcap packet (main.c:296).
- Rate control: `-t` = bytes/sec budget enforced per 100 µs window
  (main.c:285-332); `-c` = copies of each pcap packet.

### 5c. `pktgen/build/sendb2b` (closed-loop C, src/close_loop.c)

Used by `benchmark/load_gen.py::SendB2B` (stdout→`results_raw.tsv`,
stderr→`loss.dat`, load_gen.py:63-64) and by `run_experiment.py`:
- **One line per 1000 received packets**, close_loop.c:178-181:
  ```c
  if (stat.total_received > 0 && stat.total_received % SAMPLE_SIZE == 0) {
      float avg_latency = (float)stat.sample_latency / SAMPLE_SIZE / US_PER_S;
      fprintf(stdout, "%.6f\n", avg_latency);
  ```
  → window-mean RTT latency in **SECONDS** (SAMPLE_SIZE=1000, close_loop.c:18).
  Note the units trap vs 5b (µs there, s here).
- **Final line to stderr**, close_loop.c:192-193:
  ```c
  fprintf(stderr, "%-10lu %-10lu %-10.3f %f %f\n",
      stat.total_sent, stat.total_received, lost, throughput, stat.duration);
  ```
  → `sent  received  loss_fraction  throughput_pkts_per_sec  duration_sec`
  (throughput = received/duration, close_loop.c:190-191).
- Closed loop: `-n` outstanding packets (default 1); a receive triggers the
  next send (close_loop.c:183-185), so this measures serialized RTT, not
  offered-load behavior.

### 5d. `benchmark/run_experiment.py` → files on disk

- `out/results.tsv` = sendb2b window means **after trimming**: first 2 windows
  and last 1 dropped when ≥4 rows (run_experiment.py:34-36:
  `def clean_results(results): ... return results[2:-1]`) — i.e. their harness
  bakes in warmup/cooldown trimming.
- `out/load_stats.tsv` = single row `sent recv lost tput duration`
  (run_experiment.py:113).
- plus `p4c.log`, `bmv2.log` (switch stdout/err) in the run dir.

### 5e. `benchmark/parse_results.py` → derived headline stats

From results.tsv column 0 (the window means), parse_results.py:43-49:
```python
exp['avg_latency'] = np.mean(cols[0])
exp['min_latency'] = np.min(cols[0])
exp['max_latency'] = np.max(cols[0])
exp['p99_latency'] = np.percentile(cols[0], 99)
exp['p95_latency'] = np.percentile(cols[0], 95)
exp['std_latency'] = np.std(cols[0])
exp['cv_latency'] = exp['std_latency'] / exp['avg_latency']
```
merged with `sent, recv, lost, tput, duration` (line 39) and the experiment.json
params; emitted as TSV or JSON to stdout.

### 5f. PISCES/MoonGen side (out of container scope, enumerated for completeness)

`experiment.py` writes per (feature, variable∈{1,2,4,8,16}, rep<5, rate=10000):
`MoonGen.txt` (MoonGen stdout), `histogram.csv` (hardware-timestamped latency
histogram, columns latency,count — extract_histogram.R:14), `dump_flows.txt`,
`switch.txt`. `Rscript/plot_from_histogram.R` reduces to per-(variable,rate)
`mean, sd, mean_95th, mean_99th` and writes `<dir>.csv` + pdf plots.

### 5g. Gaps and latent defects found while enumerating (disclosure material)

1. **The bmv2 analysis scripts are missing from the artifact**:
   `benchmark/benchmark.py:21` references `benchmark/analyse.R` and
   benchmark/README.md says `./plot.R result/parser/data.csv` — **neither file
   exists anywhere in the repo**. The bmv2 pipeline therefore ends at raw
   latency.csv/loss.csv/results.tsv; any headline number must be defined on
   those raw files (relevant when freezing the primary list).
2. `benchmark/benchmark.py:add_rules` retry path calls
   `self.add_rules(json_path, port_number, commands, retries-1)` with
   `port_number` undefined → NameError if a rule insert ever needs a retry
   (static read; not executed).
3. `run_switch.sh` runs `sudo $SWITCH_PATH` with no arguments before the real
   invocation (prints usage; harmless quirk) and hardcodes 5 ports
   veth0..veth8; `benchmark/switch.py` kills bmv2 with `sudo pkill
   lt-simple_swi` (name-based kill of the libtool wrapper binary).
4. Units inconsistency across their own tools: µs (main.c per-second line),
   seconds (close_loop windows), ns axis labels in plot_from_histogram.R —
   the primary list must state units per metric explicitly.

## 6. Candidate primary metrics for the prereg TBD (from code, not from runs)

The bmv2-native pipeline can headline only these (everything else derives):

| # | Metric | Emitted by | Units | File |
|---|---|---|---|---|
| P1 | mean RTT latency per 1000-pkt window (trimmed series), and its mean = `avg_latency` | sendb2b + run_experiment + parse_results | s (window means) | results.tsv |
| P2 | `p99_latency` / `p95_latency` / `std` / `cv` over the same windows | parse_results.py:46-49 | s | stdout TSV |
| P3 | `sent recv lost tput duration` (loss fraction; pkt/s; s) | close_loop.c:192 | mixed | load_stats.tsv |
| P4 | per-second `(recv_count, mean_latency_µs)` open-loop series | main.c:153 | µs | latency.csv |
| P5 | open-loop final `sent recv loss_fraction` | main.c:180 | — | loss.csv |
| P6 | implicit capacity point: largest offer_load (bytes/s) with zero loss in the pen_* search | pen_parser.py:44-53 loop structure | B/s | directory structure |

Recommendation to the finalizer: P1+P3 (closed-loop avg latency + loss/tput
from `run_experiment.py`, which is the artifact's only turnkey single-config
runner) or P4+P5 if the pen_* open-loop sweep is chosen as "the pipeline".
The choice between open-loop (5b) and closed-loop (5c) IS the primary-list
decision — the two measure different things and the artifact ships both.

## 7. Deviations from install_bmv2.sh (each probed, evidence in logs)

| # | Deviation | Why (verbatim evidence) |
|---|---|---|
| D1 | Container-baseline packages added first (sudo git wget ca-certificates gnupg) | docker base lacks what their host assumed; script itself `sudo`s every line |
| D2 | p4benchmark checkout pinned to `e1b22c1` | == master at recon time; keeps recipe byte-stable |
| D3 | pip bootstrapped to 20.3.4 (last py2 pip) before the script's first pip use | stock pip 8.1.1 ignores Requires-Python; probed verbatim failures (probe2-results.log): `pip install cffi` → `error: command 'x86_64-linux-gnu-gcc' failed with exit status 1`; nnpy → `Command "python setup.py egg_info" failed with error code 1`; scapy → `OSError: Scapy no longer supports Python 2 ! Please use Scapy 2.5.0`; thrift → `ImportError: No module named errors`; sphinx/sphinx-autobuild → `IOError: ... setup.py` missing. Their requirement lines kept unmodified; 20.3.4 auto-selects py2-compatible versions |
| D4 | thrift 0.9.3 tarball from archive.apache.org instead of mirror.switch.ch | original URL dead (wget spider exit 8, probe-results.log PROBE 3); same upstream tarball, same version, configure line verbatim |
| D5 | bmv2 `sudo make` → `make -j4`; (thrift keeps their `-j2`) | parallelism only, resource-courtesy cap; no configure/flags change |
| D6 | `./veth_setup.sh` not run at image build | needs NET_ADMIN, unavailable in docker build; it is runtime env setup — run at container start with `--cap-add=NET_ADMIN` (not run during recon) |
| D7 | line 79 `chown -R $USER /usr/local/lib/R` skipped | $USER unset in build; as root a no-op; cosmetic |
| D8 | CRAN key fetched by **full fingerprint** `E298A3A825C0D65DFD57CBB651716619E084DAB9` instead of the script's 32-bit short ID `E084DAB9` | **The short ID is spoofed on the keyserver in 2026** (evil32-style collision). Build 1 verbatim: `gpg: key E084DAB9: public key "Totally Legit Signing Key <mallory@example.org>" imported`, then apt: `W: GPG error: http://cran.rstudio.com/bin/linux/ubuntu trusty/ Release: ... NO_PUBKEY 51716619E084DAB9` and `E: There were unauthenticated packages and -y was used without --allow-unauthenticated` (build1.log). The full fingerprint belongs to the key the script intended (Michael Rutter's CRAN Ubuntu key, long ID = the exact `51716619E084DAB9` apt asked for). Repo line itself kept verbatim. Security-relevant disclosure: anyone running their script today imports an attacker-chosen key |

**Not deviated** (worth stating because they were expected to break):
apt sources untouched (xenial still on archive.ubuntu.com, PROBE 0);
`mktemp` package exists in xenial (PROBE 1 — contrary to expectation);
CRAN trusty flat repo + hkp keyserver still reachable (PROBE 5/E/F) and the
CRAN **repo line** is kept verbatim (only the key fetch is fixed, D8) — apt
resolved the full 200-package r-base dependency tree from CRAN-trusty-on-xenial
in build 1, refusing only on authentication; github https reachable from
xenial git.

## 8. Install attempt log

### Build 1 (ubuntu:16.04) — FAILED at 139 s, spoofed CRAN key

Failed in the `apt-get install ... r-base ...` layer (install_bmv2.sh lines
15-16 equivalent). Root cause chain, verbatim from build1.log:

1. Key import (script line 6 equivalent) fetched a spoofed key:
   ```
   #8 3.068 gpg: key E084DAB9: public key "Totally Legit Signing Key <mallory@example.org>" imported
   ```
2. apt update then could not verify CRAN:
   ```
   #9 2.936 W: GPG error: http://cran.rstudio.com/bin/linux/ubuntu trusty/ Release: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 51716619E084DAB9
   ```
3. r-base resolution chose CRAN packages (200 packages, 125 MB — resolution
   itself succeeded) and aborted:
   ```
   #11 1.222 WARNING: The following packages cannot be authenticated!
   #11 1.225 E: There were unauthenticated packages and -y was used without --allow-unauthenticated
   ```

→ Deviation D8 (full-fingerprint key fetch). This failure is what the
script's own line 6 produces today; without our fix the artifact's install
dead-ends here on any host.

### Build 2 (ubuntu:16.04, D8 applied)

⏳ TO FILL FROM build2.log — status, per-layer wall-clock, verbatim failure
lines if any, toolchain versions from /opt/versions.txt.

## 9. Files in this directory

- `Dockerfile` — the recipe described above (deviations tagged inline).
- `RECON-R2-install.md` — this file.
- `probe-results.log`, `probe2-results.log` — deviation-evidence probes.
- `build1.log` (and later attempts) — full docker build transcripts.

[Co-developed with claude code -- Adam]
