# Residue of `/home/adam/P4_Source_Code` — evidence rescued before the tree is deleted

[Co-developed with claude code -- Adam]

> ## 🔴 THIS IS NOT SOURCE CODE. NOTHING HERE BUILDS ANYTHING.
>
> Every file in this directory is a **flat, non-executable copy** of something that existed in
> `/home/adam/P4_Source_Code`, a 3.5 GB p4 toolchain build tree that is scheduled for deletion.
> The names use `__` where the original had `/`, and every copied file carries a `.txt` suffix and
> mode 0644, **on purpose**: you cannot `cd` into this, you cannot run it, and you must not treat
> it as a checkout. It is a filing cabinet, not a workspace.
>
> If you came here looking for a p4 toolchain to build against: this is the wrong directory.
> Re-clone the upstream repos at the commits listed in §1.

**Status: 現役 (current-facing).** Created 2026-08-31, against repo `c10ac7c`.
The tree it describes was **still on disk, unmodified, when this was written** — deletion had not
been authorised. If you are reading this after the deletion, §5 is the part that matters.

## 🔴 Read this before trusting "recoverable from upstream"

Three of the four modified files here are reproducible by re-applying a `p4-guide` patch (§2.2).
That conclusion is weaker than it sounds, and the weakness is measurable:

> **This tree is `upstream + patch + fuzz`, not `upstream + patch`.**

Two of the four patches left a `.orig` beside their target. GNU `patch` writes `.orig` only under
`--backup-if-mismatch`, i.e. **only when the patch did not apply exactly** — it landed with offset
or fuzz. `p4runtime-shell` says so twice over: its patch declares `index 07c5c31..8a9dad9` while
the real before/after blobs are `6a29def..6172f6b`, so the patch was authored against a different
`setup.cfg` than the one it hit.

**A patch that applied with fuzz is not guaranteed to land in the same place next time**, on a
different base, a different `patch` version, or a different fuzz factor. So "reproducible from
upstream" means *a* correct-looking result can be regenerated, **not** that it will be
byte-identical to what this machine built against. The verbatim copies in this directory are the
only artifacts that settle it, and `MANIFEST.sha256` is how you check. Details in §2.3.

Companion record on the `audit-raw` branch: `p4-source-tree-residue-2026-08-31/` holds the bulk
material (the 27 MB install inventory and the other build records). See §6.

---

## 1. What the tree was, and where each piece came from

`/home/adam/P4_Source_Code` is the working directory of a single run of
`p4-guide/bin/install-p4dev-v8.sh` on **2026-07-13**, on this machine
(`adam-Yoga-7-2-in-1-16IML9`). It produced everything under `/usr/local/bin` that this project
calls "the stock p4 toolchain": `simple_switch_grpc`, `simple_switch`, `psa_switch`,
`p4c-bm2-ss`, the `*_CLI` wrappers, and the PI / thrift / grpc libraries they link.

Seven git checkouts, all clean of history rewrites, all pinned:

| directory | upstream | commit | on GitHub 2026-08-31? |
|---|---|---|---|
| `behavioral-model` | `p4lang/behavioral-model` | `f0b7d201570d088a056b7fe660802ca1a8bcb912` | ✅ API 200 |
| `p4c` | `p4lang/p4c` | `5b948b037a76ec9aa9cbccfc78aa636a62c78ce7` | ✅ API 200 |
| `p4-guide` | `jafingerhut/p4-guide` | `812e597adfdd0b8f15259f6342524cab8c44103d` | ✅ API 200 |
| `PI` | `p4lang/PI` | `4bd2eef617972acb471651c276fce561905a96df` | ✅ branch tip |
| `ptf` | `p4lang/ptf` | `fe62f401dcc38ec983f9a2df6b2e890983c357fb` | ✅ API 200 |
| `mininet` | `mininet/mininet` | `6eb8973c0bfd13c25c244a3871130c5e36b5fbd7` | ✅ branch tip |
| `p4runtime-shell` | `p4lang/p4runtime-shell` | `4b69a672b499a50255d04ca8196a8420d63dcaeb` | ✅ branch tip |

**The reachability column is an observation, not an assumption.** Checked 2026-08-31 with
`git ls-remote` and `GET /repos/<owner>/<repo>/commits/<sha>`; three answered as a current branch
tip, four answered `200` for the commit object. That is what makes deleting the *tracked* content
of this tree recoverable. It is **not** a guarantee for any future date — GitHub can lose a commit
that no branch or tag points at, and four of the seven are in exactly that position.

`behavioral-model` is the one the rest of the project cares about: `f0b7d201` is the source of
**both** `simple_switch_grpc` builds (see `doc/audit/bmv2-binary-provenance.md`) and is the commit
that PREREG-B's four arms are pinned to
(`doc/audit/2026-08-31_completeness-experiments/PREREG-B-nslab-build.md:22`). PREREG-B builds its
arms from a **fresh clone on the nslab guest**, not from this tree, so deleting the tree does not
touch that round — but it does remove the local object store that made `f0b7d201` a fact you could
check without a network.

---

## 2. What was saved here, and why each item could not be re-derived

### 2.1 🔴 The one genuine hand edit: `install-p4dev-v8.sh`

| | |
|---|---|
| files | `p4-guide__bin__install-p4dev-v8.sh.diff` (4,778 B), `…modified.txt` (45,848 B) |
| base | `p4-guide` `812e597`, path `bin/install-p4dev-v8.sh` |
| size of change | 58 insertions, 38 deletions, 4 hunks |
| committed anywhere? | **no** — never committed, never pushed, existed only in that working tree |

Four `git clone` sites (mininet, ptf, p4runtime-shell, tutorials) were each wrapped in
`if [ -d <dir> ] … else <clone+patch+install> fi`, turning a re-run of the installer from
"clone over the top and fail" into a resumable, idempotent one. The `else` branches are the
upstream code moved verbatim under one more level of indentation; the added lines are the guards
and their `echo "Found directory … Assuming desired version … is already installed."` messages.

This is the item that would have been lost outright. It is *the* record of how this machine's
toolchain was actually installed, as opposed to how upstream says to install it.

### 2.2 The three "local modifications" that are **not** local work

The ticket that commissioned this rescue listed the `behavioral-model`, `mininet` and
`p4runtime-shell` working-tree modifications as things to preserve. They are worth preserving, but
their status is different from §2.1 and the difference matters if anyone ever wants to reproduce
the tree: **they are installer output, not hand edits.** `install-p4dev-v8.sh` applies them:

| tracked file modified | applied by | patch |
|---|---|---|
| `behavioral-model/install_deps.sh` | `install-p4dev-v8.sh:876` | `p4-guide/bin/patches/behavioral-model-adjust-ubuntu-packges.patch` |
| `behavioral-model/ci/install-thrift.sh` | `install-p4dev-v8.sh:877` | `p4-guide/bin/patches/behavioral-model-support-venv-2026-apr.patch` |
| `mininet/util/install.sh` | `install-p4dev-v8.sh:1031` | `p4-guide/bin/patches/mininet-patch-for-2024-sep-enable-venv.patch` |
| `p4runtime-shell/setup.cfg` | `install-p4dev-v8.sh:1150` | `p4-guide/bin/patches/p4runtime-shell-2023-changes.patch` |

For `mininet/util/install.sh` this is provable rather than plausible: the generated diff and the
patch file carry **the same git blob hashes on both sides** (`index bf4492d..998cc22`), so the
on-disk file is byte-for-byte "upstream + that patch".

All four patches are **tracked, unmodified** files inside `p4-guide` at `812e597`, so the
modifications are reproducible from upstream. They are kept here anyway, because reproducing them
requires re-running a patch and the copies make the comparison a `sha256sum`.

### 2.3 The two `.orig` files are a finding, not clutter

`behavioral-model__ci__install-thrift.sh.orig.txt` and `p4runtime-shell__setup.cfg.orig.txt` are
GNU `patch` backups. GNU `patch` defaults to `--backup-if-mismatch`: it writes `.orig`
**only when the patch did not apply exactly** (offset or fuzz). Two of the four patches above have
an `.orig` beside them and two do not.

So the installed tree is not "upstream + patch" for those two files — it is "upstream + patch
applied with fuzz", and the `.orig` is the only surviving record of what the pre-patch file looked
like at the version the fuzz was resolved against. `p4runtime-shell` corroborates this
independently: its patch declares `index 07c5c31..8a9dad9` while the real before/after blobs are
`6a29def..6172f6b` — the patch was written against an older `setup.cfg` than the one it landed on.

### 2.4 🔴 `config.log` — the `-O0` provenance that `git status` never showed

| | |
|---|---|
| file | `behavioral-model__config.log.txt` (62,676 B) |
| original | `/home/adam/P4_Source_Code/behavioral-model/config.log`, written 2026-07-13 17:02 |
| tracked? | **no — `.gitignore`d as an autotools artifact**, so it appears in no `git status` output |

Line 7 is the entire reason this file matters:

```
  $ ./configure --with-pi --with-thrift --with-python_prefix=/home/adam/p4dev-python-venv 'CXXFLAGS=-O0 -g'
```

Two current-facing documents cite it **by path and line number**:

- `doc/audit/bmv2-binary-provenance.md` — "Stock's flags: read directly from the original tree's
  `config.log:7`, which records the invocation verbatim". That row is how the project knows the
  stock binary is `-O0` with logging macros and the elogger **on** (neither `--disable-` flag is
  present), which is the denominator of the fast-vs-stock ratio.
- `doc/2026-08-15_bmv2-performance-report.md:179` — 本機證據 `…/behavioral-model/config.log:7`.

`config.log:2` (`created by bm configure 1.15.3-f0b7d201`) is the second half of that document's
source-SHA argument.

**A survey that only asks `git status` cannot find this file.** It was not on the rescue ticket;
it was found by listing ignored entries. If it had gone with the tree, the 12×/8.0× claim would
have kept its numerator (`tools/test_workflow/build_bmv2_fast.sh` is committed) and lost its
denominator's provenance, and `bmv2-binary-provenance.md` would have grown a dangling citation
that still *reads* as verified.

`config.status` (81,573 B) is the same class and is on `audit-raw` (§6) rather than here — it is a
generated 80 KB shell script, and every human-readable fact in it is also in `config.log`.

### 2.5 🔴 `log.txt` is not the log of the build that produced the toolchain

`install-run__log.txt` (51,972 B), from `/home/adam/P4_Source_Code/log.txt`. Cited by
`doc/audit/2026-08-15_bmv2-source-analysis.md:42` as `log.txt:1107`, where
`simple_switch_grpc --version` prints `1.15.3-f0b7d201`. Kept on this branch, not only on
`audit-raw`, because it is a line-numbered citation target in a current document.

**It records a re-run that built nothing.** Six observations, each checkable against the files
saved here and on `audit-raw`:

| # | observation |
|---|---|
| 1 | the `/usr/local` subset of all eight `install-details` snapshots is **byte-identical** — 610 lines, `sha256 05a44ce03d3a…` for every one |
| 2 | snapshot **1**, named `before-protobuf`, already lists `/usr/local/bin/simple_switch_grpc`, `p4c-bm2-ss`, `simple_switch`, `psa_switch`, `libbmall.so` |
| 3 | `/usr/local/bin/simple_switch_grpc` mtime = **17:19:59** |
| 4 | the hand-edited `install-p4dev-v8.sh` mtime = **17:44:27** — 25 min *after* that binary landed |
| 5 | snapshot 1 written **17:51:24**, `log.txt` closed **17:52:30**: the whole recorded run is ~8 minutes |
| 6 | its own timing summary: `p4lang/PI install : 1 sec`, `p4lang/p4c install : 7 sec`, `mininet : 0 sec`, `p4lang/ptf : 0 sec` — a p4c build is hours |

Read together: this is the installer being re-run **after** the §2.1 hand edit, with every
`if [ -d <dir> ]` guard firing, every clone skipped and nothing written to `/usr/local`. The eight
snapshots differ only under `$PYTHON_VENV` and `~/.local`, where `pip` was still working. **The
run that actually compiled and installed the toolchain left no log in that tree.**

What this does and does not cost:

- `log.txt:1107` still supports what `2026-08-15_bmv2-source-analysis.md:42` cites it for. Line
  1107 sits inside the installer's closing `which` / `--version` sweep, which interrogates the
  **already-installed** binary; `1.15.3-f0b7d201` is a fact about the file on disk no matter which
  run printed it. The citation holds; the phrase "install log" around it does not.
- `doc/audit/bmv2-binary-provenance.md` is untouched by this — it identifies the stock binary by
  sha256 and BuildID, not by install log.
- It raises `config.log`'s value rather than lowering it. `config.log` (mtime **17:02**) predates
  the re-run by 49 minutes and is **the only surviving artifact of the run that produced the stock
  `simple_switch_grpc`**.

### 2.6 `config.h.in` — untracked, and it contradicts a comment we rely on

`behavioral-model__targets__simple_switch_grpc__config.h.in.txt` (3,811 B, untracked, **mtime
2026-08-15 14:58**).

`tools/test_workflow/build_bmv2_fast.sh` states in a comment that it deliberately does **not**
touch the original tree — "A clone reproduces HEAD exactly … and leaves the original tree
byte-for-byte untouched. Verified live 2026-08-15". But 100 files in that tree have mtimes of
2026-08-15 14:58, all of them autotools output (`configure`, `aclocal.m4`, every `Makefile.in`,
`ltmain.sh`, the `autom4te.cache/`s) plus this untracked `config.h.in`. That is an `autogen.sh`
run **in the original tree**, minutes before the fast build.

This does not invalidate the fast binary: `git clone --local` copies committed state, and every
file touched is `.gitignore`d, so the clone was unaffected and the *source* claim stands. What is
wrong is the comment's scope — "byte-for-byte untouched" is false for the ignored half of the
tree. Left as an observation; the comment is not corrected here because the tree is going away
and the sentence becomes moot. Recorded so a future reader of that comment does not treat it as
having been verified in the sense it claims.

---

## 3. What was checked and deliberately **not** saved

The point of this section is that "unique" was a conclusion, not an assumption. Population
searched: every `.orig`/`.rej`/`.bak`/`.patch`/`.diff` in the tree; every git working-tree
modification and untracked file in all seven checkouts; every `.gitignore`d entry in all seven
(173 + 362 + 4 + 0 + 2 + 6 + 3); every file with an mtime after the 2026-07-13 install.

| not saved | why it is safe |
|---|---|
| all tracked, unmodified upstream content in the seven checkouts | recoverable at the commits in §1, verified reachable 2026-08-31 |
| ~50 `.patch`/`.diff` files under `p4-guide/bin/patches/`, `p4c/`, `mininet/util/` | all **tracked upstream files**, none modified |
| `behavioral-model/mininet/stress_test_ipv4.py` | `./configure` output from tracked `stress_test_ipv4.py.in`; ignored via `mininet/.gitignore:5` |
| `sswitch_CLI.py`, `runtime_CLI.py`, `bm_runtime/`, `sswitch_runtime/`, `bmpy_utils.py` | **byte-identical copies already installed** in `/home/adam/p4dev-python-venv/lib/python3.13/site-packages/` — `cmp` clean. See §5.2 |
| the 100 files with post-install mtimes | all `__pycache__/*.pyc` or 2026-08-15 autotools regeneration; **zero** hand-edited files outside the four in §2.2 |
| `p4c/build/` (2.9 GB), `PI/*/.libs`, every `.o`/`.so`/`Makefile` | compiler output; the installed artifacts in `/usr/local` are the artifacts of record |
| all three git stashes… | there are none: `git stash list` is empty in all seven checkouts |

---

## 4. Regenerating the four diffs (while the tree still exists)

```
S=/home/adam/P4_Source_Code
git -C $S/p4-guide        diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ -U3 -- bin/install-p4dev-v8.sh
git -C $S/behavioral-model diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ -U3 -- ci/install-thrift.sh install_deps.sh
git -C $S/mininet          diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ -U3 -- util/install.sh
git -C $S/p4runtime-shell  diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ -U3 -- setup.cfg
```

`MANIFEST.sha256` holds the sha256 of each `.diff` and of each verbatim copy's **original on
disk**. Verify a saved copy by content, never by exit code:

```
git cat-file blob HEAD:doc/audit/2026-08-31_p4-source-tree-residue/<name> | sha256sum
```

---

## 5. If the tree is already gone: what breaks and what does not

### 5.1 Runtime: nothing breaks

Checked before this directory was written: `/usr/local/bin/simple_switch_grpc`,
`/usr/local/bin/p4c-bm2-ss` and `/usr/local/bmv2-fast/bin/simple_switch_grpc` carry no `RUNPATH`
or `RPATH` into the tree, and no `.so` any of them loads comes from it. The fast build's
`RUNPATH` is `/usr/local/bmv2-fast/lib`, which is self-contained. Nothing under `/usr/local/bin`
or the venv contains the string `P4_Source_Code`.

### 5.2 One repo document is wrong about this, independently of the deletion

`doc/2026-07-29_environment_gotchas.md:62-63` and `p4_proxy/requirements.txt:39` both say
`sswitch_CLI` / `runtime_CLI` **live only in the `P4_Source_Code` source tree**, and give a
`PYTHONPATH=$BM/targets/simple_switch:$BM/tools` recipe built on that. That is false: both modules,
plus `bm_runtime/`, `sswitch_runtime/` and `bmpy_utils.py`, are installed and byte-identical
(`cmp` clean, 2026-08-31) in

```
/home/adam/p4dev-python-venv/lib/python3.13/site-packages/
```

The conclusion those documents draw — that `/usr/local/bin/simple_switch_CLI` is broken — is
still true, but for a different reason. Run today it fails at
`bmpy_utils.py:16: from thrift import Thrift` → `ModuleNotFoundError: No module named 'thrift'`.
The wrapper hard-codes the **3.13** site-packages path while `p4dev-python-venv`'s own
interpreter is **3.12**, so the modules it needs and the interpreter that runs it never meet.

⚠️ **Correction to the first version of this section, 2026-08-31.** It said "neither
`/usr/bin/python3` nor `/home/adam/p4dev-python-venv/bin/python` can import `thrift`". True, but
it was the wrong population: I checked two interpreters and not the one the recipe in
`p4_proxy/requirements.txt` actually names. **`p4_proxy/venv/bin/python` is 3.13 and has a working
`thrift`.** So a working combination does exist, and the repoint is a tested substitution rather
than a deferral:

```
SP=/home/adam/p4dev-python-venv/lib/python3.13/site-packages
PYTHONPATH="$SP" p4_proxy/venv/bin/python "$SP/sswitch_CLI.py" --thrift-port <9090+dpid>
```

Run 2026-08-31: `sswitch_CLI`, `runtime_CLI`, `bmpy_utils`, `bm_runtime` and `sswitch_runtime` all
import under that combination, resolving out of `$SP` — **executed, not reasoned about.** The
three documents have been repointed to it (§5.5); each edit records the `$BM/…` path it replaced.

### 5.3 The one script that hard-codes the path

`tools/test_workflow/build_bmv2_fast.sh` builds the fast bmv2 from `$SRC`, and `$SRC` was this
tree. It now refuses to start when the tree is missing, and prints a pointer to this directory
rather than cloning a replacement — a fresh clone would land on a *different* commit and rebuild
"the same" binary from different source. See the guard at the top of that script.

To rebuild the fast binary after the deletion:

```
git clone https://github.com/p4lang/behavioral-model /some/path/behavioral-model
git -C /some/path/behavioral-model checkout f0b7d201570d088a056b7fe660802ca1a8bcb912
SRC=/some/path/behavioral-model bash tools/test_workflow/build_bmv2_fast.sh
```

⚠️ The result is **functionally equivalent, not byte-identical** — `-march=native` bakes in this
machine's ISA and the original build tree `/tmp/bmv2-fast-src` is already gone. That was already
true before the deletion; see the closing note of `doc/audit/bmv2-binary-provenance.md`.

### 5.5 The sweep: every reference to the tree, and what was done with it

Done 2026-08-31, immediately before recommending deletion. A citation that outlives its target
does not fail loudly — it keeps reading as verified. This is the audit of that.

**Search forms used** (the reason to list them: a zero-hit result is only as good as the forms
tried, and a path can be written four ways or split by a line wrap):

| # | form | where | hits |
|---|---|---|---|
| 1 | `p4_source_code`, case-insensitive — catches `/home/adam/…`, `~/…`, `$HOME/…`, and bare `P4_Source_Code/behavioral-model` alike | all tracked files, working branch | 40 |
| 2 | same | `audit-raw` | 3 (all in this rescue's own files, all "`<-` original path" provenance lines) |
| 3 | line-wrap splits: `P4_$`, `P4_Source$`, `P4_Source_$`, `Source_Code`, `^_Code`, `^Code/`, `^Source_Code` | working branch | **0** |
| 4 | separator variants: `P4 Source Code`, `P4-Source-Code`, `P4Source`, `p4source`, `P4_SourceCode` | working branch | 1, a false positive — `p4_proxy/p4_src/SPEC.md:1` "P4 Source Code Specification", unrelated |
| 5 | **citations into the tree that never name the directory**: `config.log`, `log.txt:<n>`, `config.status`, `CMakeCache`, `build-behavioral-model`, `install-details`, `install-p4dev` | working branch | 60+, triaged below |
| 6 | every other local branch | 18 branches | `main` and 7 agent worktrees: 0. Ten branches: 14 each — the pre-rescue set, which they inherit fixed on merge. Not edited: they belong to other sessions |
| 7 | untracked / ignored files in the worktree | working tree | 1 — `doc/audit/2026-08-29_europ4-poster-review/role-bmv2-maintainer.md:15-16`, not committed by anyone; **flagged, not edited** |

**Disposition.** Repointed in place, each edit naming the path it replaced:

| file | citation | now points at |
|---|---|---|
| `doc/2026-08-15_bmv2-performance-report.md:179` | `…/behavioral-model/config.log:7` | `behavioral-model__config.log.txt`, line 7 unchanged |
| `doc/audit/2026-08-15_bmv2-source-analysis.md:8` | header note covering all six of its citations | this directory + `audit-raw` |
| `doc/audit/bmv2-binary-provenance.md:29,55` | `rev-parse` on the tree, `config.log:7`/`:4` | §1 here + the saved copy |
| `doc/2026-08-14_cross-component-integration-matrix.md:209` | bare "config.log 實錘" | the saved copy |
| `doc/2026-07-29_environment_gotchas.md:62-63` | `$BM` module locations | the venv, per §5.2 |
| `doc/2026-07-29_HANDOFF.md:940` | `$BM` recipe | the venv, per §5.2 |
| `p4_proxy/requirements.txt:33-39` | `$BM` recipe | the venv, per §5.2 |

**Deliberately not repointed**, with the reason:

| left alone | why |
|---|---|
| `tools/test_workflow/build_bmv2_fast.sh:37,40,73` | it *must* name the default path — it is the guard that fires when the path is gone (§5.3) |
| `doc/2026-08-15_bmv2-performance-build-public-manual-draft.md:28,60`, `doc/2026-08-16_delivery-package/bmv2-manual-entry.md:11,43` | these tell a **public reader** to inspect **their own** tree's `config.log`. Different tree |
| `doc/audit/2026-08-28_manual-verification-coverage/**` (`$HOME/behavioral-model/config.log`) | the clean-room VM's tree, not this one |
| `doc/audit/2026-08-31_p4-demo-vm/guest_prepare_demo.sh:86` (`$HOME/install-details`) | the demo guest's tree, not this one |
| `doc/audit/2026-08-09_memory-safety-ci-plan.md`, `2026-08-31_sampling-ceiling-after-merge/build_1khz_binary.sh` (`CMakeCache.txt`) | NDTwin's own `build-asan/`, nothing to do with p4c |
| `doc/audit/2026-08-27_p4guide-v10-tty/**` | a different installer run in a different VM |
| `doc/audit/2026-08_session-handoff-log.md:200,675` | dated handoff log. `doc/audit/README.md`: *historical records are not corrected, they are dated* — listed here instead |
| ten other local branches | other sessions' work; they pick this up on merge |

**One thing the sweep found that is not about the deletion.** Transcribing the citations into a
table caught an off-by-two: `bmv2-binary-provenance.md` had cited `config.log:2` for
`created by bm configure 1.15.3-f0b7d201` since 2026-08-21. The string is on **line 4**. The claim
was right and the pointer was wrong, and nothing would ever have disagreed — the neighbouring
`config.log:7` in the same bullet is correct, so the two never contradicted each other. Corrected
in place. Copying a citation out by hand is the cheapest instrument for this; nothing else in the
repo checks a line number.

**Line numbers re-resolved against the saved copies** (all four verified by reading the line, not
by assuming byte-identity implies it):

| citation | saved copy line | content |
|---|---|---|
| `config.log:7` | 7 | `$ ./configure … 'CXXFLAGS=-O0 -g'` |
| `config.log:4` | 4 | `It was created by bm configure 1.15.3-f0b7d201, which was` |
| `log.txt:1107` | 1107 | `1.15.3-f0b7d201` |
| `config.status:423` (on `audit-raw`) | 423 | `ac_cs_config='--with-pi --with-thrift … '\''CXXFLAGS=-O0 -g'\'''` |

### 5.4 Citations that go dangling and are answered here instead

| citation | now answered by |
|---|---|
| `doc/audit/bmv2-binary-provenance.md` → `config.log:7`, `config.log:2` | `behavioral-model__config.log.txt` |
| `doc/2026-08-15_bmv2-performance-report.md:179` → `config.log:7` | same |
| `doc/audit/2026-08-15_bmv2-source-analysis.md:42` → `log.txt:1107` | `install-run__log.txt` |
| `doc/audit/2026-08-15_bmv2-source-analysis.md:71` → `p4-guide/bin/build-behavioral-model.sh:84` | not copied — tracked upstream at `812e597` |
| `doc/audit/bmv2-binary-provenance.md:28` "still the HEAD of `/home/adam/P4_Source_Code/behavioral-model`" | §1 of this file |
| `doc/2026-07-29_environment_gotchas.md:62-63`, `p4_proxy/requirements.txt:35-39` | §5.2 — the claim is wrong on its own terms |

---

## 6. The bulk half, on `audit-raw`

`install-details/` (8 files, 27 MB) and the remaining machine-local build records are on the
`audit-raw` branch under `p4-source-tree-residue-2026-08-31/`, per the `raw 進 audit-raw` rule.
That branch shares no history with `main` and is not pushed.

```
git show audit-raw:p4-source-tree-residue-2026-08-31/README.md
git show audit-raw:p4-source-tree-residue-2026-08-31/install-details/usr-local-9-after-miscellaneous-install.txt | head
```

What is over there: the eight `usr-local-N-*.txt` snapshots (`find /usr/lib /usr/local ~/.local
$PYTHON_VENV | sort`, one per install stage — stage 2 was never written), a second copy of
`log.txt`, and the build records not kept here — `behavioral-model/config.status`,
`PI/config.log`, `PI/config.status`, `PI/proto/config.log`, `PI/proto/config.status`,
`p4c/build/CMakeCache.txt` (which is where `p4c-bm2-ss` is recorded as
`CMAKE_BUILD_TYPE=Release`, `-O3 -DNDEBUG`).

⚠️ **Do not use the snapshots to attribute a `/usr/local` file to an install stage.** Their
`/usr/local` half is a constant — identical in all eight, "before" included — for the reason set
out in §2.5. What they *are* good for is the venv: they are a stage-by-stage record of what `pip`
put in `$PYTHON_VENV` and `~/.local`, and that half does move between snapshots.

---

## 7. Deletion has not been authorised

Adam has not given the order. Nothing in `/home/adam/P4_Source_Code` was moved, modified or
removed while this directory was written; every file here is a copy. §3 is the population that
must be read before anyone answers "yes, it can go".
