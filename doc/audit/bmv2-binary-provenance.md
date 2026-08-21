# Which bmv2 produced a number — the binary identity record

[Co-developed with claude code -- Adam]

**Current-facing document.** When either binary is rebuilt or replaced, correct this file in
place; do not append a second table. Recorded 2026-08-21 against repo `d9f580b`.

Two `simple_switch_grpc` installations coexist on this machine and **both answer `--version`
with the same string**. Every throughput, CPU and jitter figure in this project depends on
which one was running, and the difference between them is roughly an order of magnitude. This
file is the identifier that `--version` cannot provide.

## The two builds

| | stock | fast |
|---|---|---|
| path | `/usr/local/bin/simple_switch_grpc` | `/usr/local/bmv2-fast/bin/simple_switch_grpc` |
| **`--version`** | `1.15.3-f0b7d201` | `1.15.3-f0b7d201` ← **identical, do not use as an ID** |
| sha256 | `327fa7d17221739747a15c6ced580b452b5c8981f29ba6a6998c1361d73cdef4` | `3ff54b5c1901c9d3ffd80ac05dc3dc7d0e696e3df73174c1616fb87ac9aedb4a` |
| GNU BuildID | `38844c64e64540a2185b9336b6e5dea207fd527c` | `1748b7ebaef9fd0181eba223e36220d9001709c3` |
| size (bytes) | 9,576,568 | 92,147,960 |
| mtime | 2026-07-13 17:19:59 +0800 | 2026-08-15 15:11:36 +0800 |
| symbols | stripped | not stripped (`with debug_info`) |
| optimisation | `-O0 -g` | `-O3 -g -DNDEBUG -march=native -fno-semantic-interposition` |
| logging macros / elogger | **on** (autoconf default) | **off** (`--disable-logging-macros --disable-elogger`) |
| libraries | `/usr/local/lib` | `/usr/local/bmv2-fast/lib` (27 `.so*`) |

Both were built from **behavioral-model `f0b7d201`**, which is still the HEAD of
`/home/adam/P4_Source_Code/behavioral-model`.

### How each row was established (observation, not inference)

- sha256, BuildID, size, mtime, stripped-ness: `sha256sum`, `file`, `stat` on 2026-08-21.
- Stock's flags: read directly from the original tree's `config.log:7`, which records the
  invocation verbatim —
  `./configure --with-pi --with-thrift --with-python_prefix=/home/adam/p4dev-python-venv 'CXXFLAGS=-O0 -g'`.
  It carries neither `--disable-logging-macros` nor `--disable-elogger`, so both are on.
- Fast's flags: `tools/test_workflow/build_bmv2_fast.sh`, the recipe that produced it.
- Source SHA: `config.log:2` opens with `created by bm configure 1.15.3-f0b7d201`, and both
  binaries embed the same string. `git -C /home/adam/P4_Source_Code/behavioral-model rev-parse`
  → `f0b7d201`.

## The source SHA was recoverable after all

`doc/audit/2026-08-19_p4-sflow-accuracy/METHOD_jitter-and-load.md:205-217` concluded that the
`-O3` cell is unpinnable — "no version file, no build record and no behavioral-model source SHA
stored anywhere beside it" — and that the fix could only help future builds.

The first two clauses are still true; **the third is not**. The source SHA is embedded in the
binary's own `--version` output, and the tree it names is still on disk at that commit. So
every past `-O3` result *is* attributable, retroactively, to `f0b7d201`:

- `git clone --local` copies committed state only, so the fast build took **clean `f0b7d201`**,
  not the working tree (which today carries local edits to `ci/install-thrift.sh`,
  `install_deps.sh` and an untracked `targets/simple_switch_grpc/config.h.in` — build infra,
  not pipeline source).
- The binary cited by `METHOD_jitter-and-load.md:211` — **92,147,960 bytes, built 2026-08-15
  15:11** — matches the file on disk today, byte count and timestamp both. The artifact that
  produced `p4_fast_200M.jsonl.gz` has not been replaced.

What genuinely remains unpinnable is the *configure recap* (the `no/no/no` flag confirmation)
and the exact toolchain, neither of which was captured at build time.

## How a run selects its binary

`p4_proxy/mininet/bmv2_binary_override` → `resolve_bmv2_launcher()`
(`p4_proxy/mininet/p4_testbed_topo.py:63`), imported by `ntg_bmv2_topo.py:52`. **Both
topologies share the one seam**, so there is no second selection path to keep in sync.

Current content: one directive line naming the fast binary. Tracked, committed at `cc249c8`,
clean in the worktree as of `d9f580b`.

Failure semantics, as written:

| override file state | result |
|---|---|
| absent | `DEFAULT_BMV2_BINARY` — bare name, PATH lookup → **stock, silently** |
| present, all lines commented | same as absent → **stock, silently** |
| present, relative path | raises `ValueError` |
| present, names no executable | raises `ValueError` |
| present, valid | that binary; `LD_LIBRARY_PATH` derived as `dirname/../lib` when it exists |

The `../lib` derivation is automatic precisely so a fast binary cannot be run against stock
libraries — the performance report's trap #3. `tools/p4_power_helper.py:301` re-implements the
same rule for power-on; the two derivations must move together.

🔴 **The one silent path is the top two rows.** Delete or comment out the override and the next
run benchmarks the `-O0` build while every filename, note and slide still says fast. Nothing
errors. The number that comes back is plausible — roughly 10× low, which reads as "the fabric
was busy" rather than as a wrong binary.

## Proving which binary a run actually used

Prefer evidence written into the run's own data over memory of what was configured:

1. **Live switch argv carries the absolute path.** Every `simple_switch_grpc` process is
   launched with its full path, so `ps`/`/proc/<pid>/cmdline` names the build. Confirmed
   2026-08-21 against the 10 running switches.
2. **The switch manifest records `argv` per switch** (`write_manifest`,
   `p4_testbed_topo.py:354-394`, field `argv` at :371), including the `LD_LIBRARY_PATH` prefix.
   This survives the run and is the after-the-fact record.
3. **`ndt up` and `ndt status` print `running binary: <path>`** (`tools/test_workflow/ndt:468`,
   `:894`) — deliberately read from the *running* process, not from the override file, because a
   fabric started before an override edit is the difference between 40 and 500 Mbit/s.

⚠️ All three record the **path**, none records content. A rebuild in place at the same path
would leave every historical `argv` pointing at a binary that no longer exists. That is what the
sha256 above is for: it is the only thing here that would notice.

## Open

- `build_bmv2_fast.sh` still writes no manifest into `/usr/local/bmv2-fast/` — confirmed empty
  of any build record on 2026-08-21 (only `bin/`, `include/`, `lib/`). The fix proposed in
  `METHOD_jitter-and-load.md:215` (source SHA + configure flags + date) is unimplemented.
- Neither `ndt check` nor `ndt up` compares the running binary against an expected identity;
  they print the path and move on.
- The fast build is **not byte-reproducible**: its build tree `/tmp/bmv2-fast-src` is gone, and
  `-march=native` bakes in this machine's ISA. It can be rebuilt functionally equivalent from
  `f0b7d201`, not identically. **Treat the installed binary as the artifact of record.**
