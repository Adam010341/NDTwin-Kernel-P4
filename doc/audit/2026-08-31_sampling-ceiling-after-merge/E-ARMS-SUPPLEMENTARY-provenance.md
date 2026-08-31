# SUPPLEMENTARY provenance — E round, the two recompute-interval arms (H-20)

**Pointed to from** `ndtwin_kernel.recompute-1hz.provenance` and
`ndtwin_kernel.recompute-1khz.provenance` (trailer comment in each).
Built 2026-08-31 on **nslab**, registered as **H-20** in
`doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md` §2.2.

> ## 🔑 This file exists in TWO places, deliberately
>
> | copy | why |
> |---|---|
> | `doc/audit/2026-08-31_sampling-ceiling-after-merge/E-ARMS-SUPPLEMENTARY-provenance.md` | **the durable one — version-controlled** |
> | `.test_run/binaries/e-round/SUPPLEMENTARY-provenance.md` | the near copy, beside the binaries it describes |
>
> **`.test_run/` is a run directory whose purpose is to be cleared**, and it is gitignored
> (`.gitignore:21`). Provenance must not live only in a directory designed to be emptied.
> **This duplication is intentional and is declared here** — an undeclared second copy is a
> fork waiting to happen; a declared one is a backup. If they ever disagree, **the
> version-controlled copy wins.**

[Co-developed with claude code -- Adam]

## Why this file exists, and what is NOT in it

`build_1khz_binary.sh` is named in **PREREG-E §4**, and PREREG-E is **v1.0-stamped**. Adding
fields to it would be an amendment to a stamped registration, and the E-round files had a
concurrent writer at the time. The auditor ruled: **do not touch the script; carry the extra
facts in a supplementary file, and make sure something points at it.**

> When a registered artefact and an unregistered supplement can both carry the same
> information, choose the supplement — but an unreferenced supplement is worthless.

So: the two `.provenance` files are exactly what the script wrote. Everything below is
**additional**, and nothing below contradicts them.

## 1. The arms

| | 1 Hz arm | 1 kHz arm |
|---|---|---|
| file | `ndtwin_kernel.recompute-1hz` | `ndtwin_kernel.recompute-1khz` |
| sha256 | `fcb0d9d40d5814a80b37127d01a04068f92aa45a54e74372bebec75ec343b956` | `4dc9193de97a2cfed2307fb3ef50fa9d8ee7b62879bfb277e92ed3626b74bba6` |
| size | 72 877 744 | 72 883 184 |
| source line | `std::chrono::seconds(1)` | `std::chrono::microseconds(1000)` |
| **gtest `FlowPathRecomputeInterval`** | **PASS** (required: pass) | **FAIL rc=8** (required: fail) |

**The identity assay is the gtest, both directions, not `nm`.** Both arms are the same tree
differing in one constant's *value*, so the symbol is present in both:
`nm -C … | grep -c kFlowPathRecomputeInterval` returns **5 on both** — measured, not assumed.
A check that can only come out one colour is not a check; `2f57ba5` shipped
`FlowPathRecomputeInterval.IsOneSecondNotOneMillisecond` for exactly this, and the script
requires PASS on one arm and FAIL on the other.

**Negative control:** the two staged files are **not** byte-identical (verified on both machines).
Had the revert never reached the compiler, both arms would have been the 1 Hz arm under two names.

`revert-2f57ba5.patch` (sha256 `f7dfc6e956a82c4d60e516eac41f020f9b53dc300b5056812c2654422124ddbc`)
is the one-line diff that separates them, kept because "a one-line revert" is a description, not
an identity.

## 2. 🔴 `commit=` in the main files is NOT the upstream commit — read this before citing it

The build ran on nslab, where a shared unix account is in use. Shipping a real clone would have
shipped the whole tracked tree (**846 `doc/` objects**, `p4_proxy/`, `setting/`, `.claude/`,
measured with `git rev-list --objects`) because **a commit sha is a commit to the entire tree**;
sparse-checkout controls the working tree, not the object store. H-15/H-18 had just established
"private-repo objects on nslab = 0", so only the build-graph paths were sent and the repo was
reconstructed in the guest.

| field | value |
|---|---|
| `upstream_commit` | `4d831b5859b67815f183267014d1396f474bd92d` |
| `subset_commit` (what `commit=` shows) | `c0884f154fcb0b10f772159202a15ee3e12cd63f` |
| export-time upstream worktree clean? | **yes** (for the exported paths) |

**Identity is carried by content, not by the container.** Every path was hashed on the laptop
from `4d831b5…` and recomputed in the guest; all six match:

| path | tree/blob hash (identical both sides) |
|---|---|
| `CMakeLists.txt` | `fc7f6cfe57314f88a6ff9275381280dce3ceddab` |
| `include/` | `215c26c9ffed161fa8b18a66d1e8446fecb9ef49` |
| `src/` | `14a04c5dd147abc81c85185a190be050c5d6c196` |
| `tests/` | `3f5416432236b84f9d09b94a6a75f2b55ffb3780` |
| `cmake/` | `78b1d1e29f2f8e13defbe717fd1c52529514d20a` (blob: `sanitizer-flags.cmake`) |
| `libs/` | `c568c894b580ca0c07e8c819c7e6761a41082df8` |

🔑 These hashes are **better provenance than `commit=`, not a weaker substitute**: on 2026-08-31
the repo tip moved every few minutes (two `rev-parse HEAD` calls minutes apart returned different
shas), all from doc commits that cannot change a binary. **A field that changes while the build
does not is not provenance.**

## 3. 🔴 `dirty_worktree=4` does not mean the source was modified

The four entries are all **untracked build output**: `.test_run/`, `build/`, `doc/` (created by
`round.env`'s `mkdir -p`), and `setting/AppConfig.hpp` (generated by cmake from the tracked
`.example`). **No tracked source file was modified.** After the run the script restored the
header and it was confirmed back at `constexpr auto kFlowPathRecomputeInterval =
std::chrono::seconds(1);` (line 51).

## 4. The fifth input: googletest is fetched, so the six hashes above do not cover everything

`CMakeLists.txt:126-129` fetches googletest with `FetchContent`. Checked rather than assumed:

- **Pinned**: the URL names a commit archive — `…/archive/03597a01ee50ed33e9dfd640b249b4be3799d395.zip`.
  Not a branch, not a moving tag.
- ⚠️ **No `URL_HASH`** — the ref is pinned but the bytes are not verified by the build system.
  So the content actually used is recorded here instead:
  **downloaded archive sha256 = `edd885a1ab32b6999515a880f669efadb80b3f880215f315985fa3f6eca7c4d3`**
- **Both arms share one fetch**: a single build tree (`build/_deps/`) served both arms, so the
  gtest that judged the 1 Hz arm is byte-identical to the one that judged the 1 kHz arm. This
  matters because the gtest result *is* the arm-identity assay.

## 5. Build conditions

| | |
|---|---|
| host | nslab (28 cores, 31 GiB, shared account) |
| guest VM | `~/ndtwin-vm-maindev`, ssh 127.0.0.1:2245, qemu pid 35068 |
| **work point** | **12 vCPU / 8192 MiB, set explicitly**; `ndtwin-vm.sh` recorded the source as `env（顯式指定）` in `$VM_DIR/CONFIG` (R7 — a silent 12/8192 downgrade is what that rule exists for) |
| guest OS | Ubuntu 24.04.4 LTS, kernel 6.8.0-138-generic |
| compiler | `c++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0` |
| `MemAvailable` at build time | **7.3 GiB** (read at the moment of use, not copied from any note) |
| `nproc` in guest | 12 |
| **actual `-j`** | **3** |
| how `-j` was capped | **`taskset -c 0-2`** — the script hard-codes `-j "$(nproc)"`, and `nproc` honours the affinity mask. **The script was not edited.** |
| why capped | `min(cores, RAM÷2 GB)` = `min(12, 7.3÷2)` = 3. At `-j12` this script does **not** silently degrade — it OOMs and the compile dies. |
| `CMAKE_BUILD_TYPE` | **Debug** |

**Why Debug** (asked before anyone has to): the E round compares its cells against the D round's
`t008`/`t004` cells, and PREREG-E §6 wants that comparison per cell. The D-round cells were
produced by the repo's standard `build/` tree, which is configured `Debug`. Building these arms
Release would make them faster *and* incomparable — the arms are compared to **each other** and
to prior cells, never quoted as an absolute capacity. Changing the optimisation level would
change the working point, which R9 forbids mid-claim.

## 6. What was actually shipped to the shared account (R4)

| # | R4 asks | answer |
|---|---|---|
| 1 | what | `CMakeLists.txt`, `include/`, `src/`, `tests/`, `cmake/`, `setting/AppConfig.hpp.example`, `libs/` — **~3.5 MB**. **No `.git`, no `doc/`, no `p4_proxy/`, no submission package.** |
| 2 | permissions | `$VM_DIR` `chmod 700` (created 775), every transferred file `600` via `umask 077` |
| 3 | delete by | **2026-09-01, before end of day** |
| 4 | who confirms | this line's owner, by `ls -l` showing absence — **state, not the exit code of `rm`** |

**Transfer integrity** — each archive's sha256 was recomputed *inside the guest* and compared:

| archive | sha256 (identical both sides) |
|---|---|
| `e-src.tar.gz` | `4cc5f4b65f8c911ad0611a0f3288e903e6ead764d0febd50a1dd0a6575257516` |
| `e-extra.tar.gz` | `70aa34415953838d4b0869d0c0b78c0391c8a654c024fe025f873ace5654213d` |
| `e-libs.tar.gz` | `66412b6808d3e27436cff85c4974bd3d6d72656fdc3c963d9cd0f4a390e7065c` |
| `escripts.tar.gz` | `dc674527b24aec12c887d20ab735061d4d284db2793e01449298c7b40f682e9c` |

🔴 **The shipped set grew from four paths to seven, and it grew because builds failed.** The
first list came from grepping `add_subdirectory`; the build then found `include(cmake/…)`
missing, and after that `include_directories(… libs)` missing (vendored `spdlog`/`nlohmann`).
Both were cheap, loud failures that named exactly what was absent. Recorded because
"I read the CMakeLists" and "it builds" are two different claims, and only the second was
evidence.

## 7. Scripts used, by exact bytes

Shipped to `~/escripts/` in the guest, from the round directory at the time of shipping:

| file | sha256 (prefix) | note |
|---|---|---|
| `build_1khz_binary.sh` | `33dcd2d77d54126a…` | **unmodified** |
| `lib_e.sh` | `269e6cf56da7485a…` | unmodified; recorded because this file had a concurrent writer that day |
| `round.env` | `611537e48715f591…` → **`703d0bc0dadd7a53a24fd47a94cfcb6f24c574148ceba43c8fd104f4ea36bcb5`** | the **guest copy only** had one line changed: `KERNEL_DIR` → `/home/ndt/kernel`. The repo's copy was not touched. |

`DRY_RUN=1` was executed first and completed the whole control flow; only then was the real run
started.

## 8. Library resolution was measured on the machine that will run these binaries

Both arms have **zero `RUNPATH`/`RPATH` entries** — so which `.so` loads is decided by the
machine executing them, not by anything inside the file, and not by the environment. The E-round
measurement runs on **Adam's laptop** (`lib_e.sh` copies the staged arm over
`build/bin/ndtwin_kernel`, whose path `stack.sh:766` hard-codes), so `ldd` was taken **there**:

- **`not found` count: 0 for both arms.**
- `libboost_url.so.1.83.0` resolves to `/lib/x86_64-linux-gnu/` — the guest and the laptop are
  both Ubuntu 24.04.4 with boost 1.83 and glibc 2.39, so the sonames agree. **Verified, not assumed**:
  the risk that a cross-machine build produces an unloadable binary was real until this check ran.
- The `ldd` block inside each `.provenance` was taken **in the guest** by the script. It agrees
  with the laptop's, but the laptop's is the one that governs.

## 9. Reconciliation with prior results

- `.test_run/binaries/ndtwin_kernel.ab2d7ed1` is also a 1 kHz binary and is **not** used: its own
  provenance records `commit=UNKNOWN` / `dirty_worktree=UNKNOWN`, so its delta from the 1 Hz
  binary beside it is "everything that changed between two unrecorded trees", not one line.
  These two arms replace it for Q2.
- Neither arm has been run. **Nothing here is a measurement** — this file is about identity only.

## 10. 🔴 The binaries live in a directory designed to be cleared — here is how to rebuild them

`.test_run/` is gitignored (`.gitignore:21`) and exists to be emptied. The two 72 MB arms are the
most expensive product of this round and they are **not** archived into audit-raw (145 MB is not
worth archiving for something reproducible). **That trade is only honest if "reproducible" is
written down rather than assumed** — so:

**The build VM has been destroyed** (2026-08-31 17:54, R4b: the clearing unit is the disk image,
not the file — see `NSLAB-USAGE-RULES.md` §3 R4b). Rebuild therefore costs:

| | |
|---|---|
| ship the source subset again | ~2 min |
| a fresh VM (base image download + apt + boot) | ~8 min |
| three builds at `-j3` | ~23 min |
| **total** | **~30 min**, plus one VM's worth of RAM on a shared host |

**The recipe is self-sufficient from three things, all version-controlled:**

1. `upstream_commit = 4d831b5859b67815f183267014d1396f474bd92d`, restricted to the **seven** paths
   in §6 — not the four the first attempt used (§6 records why it grew).
2. `build_1khz_binary.sh` (unmodified) + `lib_e.sh` + `round.env` with `KERNEL_DIR` repointed —
   §7 records the sha256 of each as shipped.
3. The googletest input in §4 — **a fresh VM will re-download it, and there is no `URL_HASH`**,
   so compare the downloaded archive against `edd885a1ab32b699…` before trusting a rebuilt arm.

`revert-2f57ba5.patch` is kept beside this file **and** in the audit directory. Note it is a
*record*, not an input: `build_1khz_binary.sh` regenerates it from the two source lines it
hard-codes, so a lost patch file does not block a rebuild — it only loses the evidence of what
separated the arms.

**Verify a rebuilt pair against these arms** (this is the check that makes "reproducible" a
claim rather than a hope):

```bash
sha256sum .test_run/binaries/e-round/ndtwin_kernel.recompute-1hz \
          .test_run/binaries/e-round/ndtwin_kernel.recompute-1khz
# 1hz  must be fcb0d9d40d5814a80b37127d01a04068f92aa45a54e74372bebec75ec343b956
# 1khz must be 4dc9193de97a2cfed2307fb3ef50fa9d8ee7b62879bfb277e92ed3626b74bba6
```

⚠️ **A rebuild is not guaranteed to be byte-identical** (build paths, timestamps and the fetched
gtest can all move it). If the sha256 differs, that is **not** automatically a defect — but it
does mean the rebuilt arms are a *new pair*, and the gtest two-directional proof in §1 must be
re-run and re-recorded for them rather than inherited from here.

## 11. Sequencing note, recorded because it was not the intended order

The auditor's instruction was **confirm the rebuild recipe is self-sufficient, then destroy**.
The destroy happened first (17:54), on the remote line's recommendation, and the instruction
arrived afterwards — cross-session messages queue. Verified retroactively:

| condition | at destroy time |
|---|---|
| seven-path scope recorded verbatim | ✅ was already in §6 |
| gtest archive sha256 recorded | ✅ was already in §4 |
| `revert-2f57ba5.patch` in version control | 🔴 **was not** — it existed only under gitignored `.test_run/` |

The third was fixed after the fact by committing it to the audit directory. **The consequence
was bounded** — the patch is derivable (see §10), so no rebuild input was actually lost — but
**the order was still wrong, and "it turned out not to matter" is not the same as "it was safe".**
