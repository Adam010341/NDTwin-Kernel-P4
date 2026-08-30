# §6.7 "Build BMv2 for realistic throughput" — run verbatim in the clean-room VM

2026-08-30 19:25–19:40. Guest: Ubuntu 24.04, 4 vCPU, 6 GB. Harness `vm/guest_section6_7.sh`
(`9d2c721`, `c325abd`), committed before it ran. Raw: `~/s6.7-results/` in the guest.

**7 PASS · 1 FAIL · 6 N/A — and the one FAIL is mine, withdrawn below.**

This was the last unrun executable section of the Installation Manual.

---

## The block works, verbatim

`BUILD PASS, rc=0, 15 min on 4 cores.` The clone, `autogen.sh`, the long `./configure` line,
`make -j$(nproc)` and `sudo make install` all ran exactly as printed. Nothing needed adjusting.

**The manual states no duration.** 15 minutes on a 4-core VM is worth adding: a reader deciding
whether to take an optional step needs to know the order of magnitude, and "optional" invites
skipping something that is actually cheap.

## What the manual promised and delivered

| | |
|---|---|
| **PRE-1** | The manual says to look for `CXXFLAGS=-O0 -g` in the existing tree's `config.log` as evidence the stock build is a debug build. **It is there.** The page's own stated evidence checks out. |
| **POST-1** | `/usr/local/bmv2-fast/bin/simple_switch_grpc` produced, 92 085 928 B (vs the debug binary's 9 601 144 B). |
| **POST-2** | The debug install is **byte-identical** to before the build (`d5edeb552dda0b3e`). The separate-prefix promise — *"so the debug install stays available"* — holds, verified against a hash taken **before** the build rather than against itself. |
| **FINAL** | The last instruction (write the absolute path into `p4_proxy/mininet/bmv2_binary_override`) has a valid target and works. |

## 🔑 Note 2 — the danger is real, the remedy is misattributed

The manual:

> **Never run `ldconfig` after installing**, and always launch the fast binary with
> `LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib`. Both builds ship libraries with identical sonames;
> without this the fast binary silently loads the debug libraries and you benchmark a mixture.

**Every precondition for that hazard is present on this guest**, verified:

* identical sonames — `libbmpi.so.0`, `libbm_grpc_dataplane.so.0` exist under both prefixes;
* the **debug** libraries are in the loader cache — `ldconfig -p` lists four entries, all
  `/usr/local/lib/...`, put there by `install-p4dev`;
* the **fast** libraries are **not** in the cache — the manual's "do not run `ldconfig`" was
  followed.

And yet, measured both ways:

| | bmv2 libraries resolving outside `/usr/local/bmv2-fast` |
|---|---|
| with `LD_LIBRARY_PATH` | **0** |
| **without** `LD_LIBRARY_PATH` | **0** |

The reason:

```
$ readelf -d …/bmv2-fast/bin/simple_switch_grpc
 0x…1d (RUNPATH)  Library runpath: [/usr/local/bmv2-fast/lib]
```

**`DT_RUNPATH` is searched before the loader cache**, so the binary finds its own libraries
whether or not the operator sets anything.

⇒ **The protection is a property of the build, not a discipline of the operator**, and the
manual attributes it to the operator. Two consequences, opposite in direction:

* A reader who forgets `LD_LIBRARY_PATH` is told they are benchmarking a mixture. **They are
  not**, and may discard good numbers.
* If a future build loses the `RUNPATH` — a `--disable-rpath`, a distro packaging change — the
  manual's advice silently becomes load-bearing again, and nothing would announce that.

**Suggested wording**: keep both instructions, and say *why* they are belt-and-braces — the
binary carries a `RUNPATH` to its own prefix, `LD_LIBRARY_PATH` overrides everything ahead of
it, and not running `ldconfig` keeps the fast libraries out of the cache. Then the advice
survives a build that drops the rpath.

⚠️ The manual's stated verification method — *"Verify through `/proc/<pid>/maps`"* — **cannot be
followed at this point in the manual.** `/proc/<pid>/maps` needs a running switch, a switch needs
a fabric, and §6.7 has none. A reader cannot check the trap where the manual raises it. `ldd`
answers the same question with no process; the maps route is deferred to note 3's re-test.

## 🔴 Note 4 — my FAIL is withdrawn: I tested a different claim

The harness reported:

> `NOTE-4 FAIL — fast binary still links nanomsg`

**That verdict is wrong and is retracted.** The manual's claim is:

> `--disable-elogger` removes the nanomsg **event stream** that some PTF tooling subscribes to.

That is a claim about a **stream being offered at runtime**. I measured **linkage**, which is a
different thing, and the follow-up measurement shows neither instrument discriminates:

| | fast build | debug build |
|---|---|---|
| links `libnanomsg.so.5.0.0` | yes | **yes** |
| exported `elogger` symbols (`nm -D --defined-only`) | 0 | **0** |

Both builds look identical under both tests, so **neither can tell them apart**, and a FAIL
from a non-discriminating instrument is not a finding about the software.

🔑 `memory: claim-verb-decides-the-evidence`. The claim's verb is *removes the event stream*;
I tested *links the library*. Testing it properly means starting a switch and checking whether
the nanomsg event socket is offered — which, again, needs a fabric.

**Correct status: note 4 is UNTESTED**, and registered for the fabric re-test alongside note 3.

## Note 1 — untested, on purpose

> Build from a fresh clone … an in-tree configuration makes autoconf refuse an out-of-tree
> configure, and `make distclean` would destroy the `config.log`.

Reproducing this means running `configure` inside `~/behavioral-model` — the tree whose
`config.log` PRE-1 reads, and which took over an hour to produce. The advice is conservative and
free to follow; verifying it costs the baseline. **Recorded as untested, not as verified.**

## Note 3 — the one that matters most, and it is not done

> Re-run your functional tests against the fast binary before trusting any number from it.
> Upstream warns that this flag set cannot pass the complete p4c test suite.

Not run. It needs a fabric in the guest, which §6.7 does not build. **This is the note a reader
is most likely to skip and least able to afford skipping**, and this run does not discharge it.

Registered next step, with everything it needs already in place: the override now points at the
fast binary, so `ndt up p4 4` in the guest exercises exactly the path in question, and the same
run discharges note 2's `/proc/<pid>/maps` check and note 4's event-stream check.

## Scoreboard

| id | verdict |
|---|---|
| PRE-1 · PRE-2 · PRE-4 · BUILD · POST-1 · POST-2 · FINAL | **PASS** |
| NOTE-2 (mechanism) | measured — **manual over-attributes the remedy**, wording fix proposed |
| NOTE-4 | **retracted** — untested, instrument did not discriminate |
| NOTE-1 | untested, reason recorded |
| NOTE-3 | **not run** — needs a fabric |
| BUILD-TIME | 15 min, absent from the manual |

[Co-developed with claude code -- Adam]
