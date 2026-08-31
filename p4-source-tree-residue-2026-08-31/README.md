# `p4-source-tree-residue-2026-08-31/` — the bulk half

[Co-developed with claude code -- Adam]

Raw material rescued from `/home/adam/P4_Source_Code` (3.5 GB), a p4 toolchain build tree
scheduled for deletion. **This is not source code and none of it builds anything.**

The analysed half — the diffs, the hand edit, `behavioral-model/config.log`, and the reasoning
about what was and was not unique to that tree — is on the working branch:

    doc/audit/2026-08-31_p4-source-tree-residue/README.md

Read that first. This directory is the bulk it points at.

Nothing in `/home/adam/P4_Source_Code` was moved, modified or deleted to produce this. Deletion
had not been authorised when it was written.

## Contents

| path | bytes | what it is |
|---|---|---|
| `install-details/usr-local-{1,3,4,5,6,7,8,9}-*.txt` | 27 MB | nine-stage `find` snapshots, minus stage 2 — see below |
| `log.txt` | 51,972 | stdout of the installer run, `set -x` throughout |
| `build-records/behavioral-model__config.log` | 62,676 | 🔴 the `-O0` configure invocation. Duplicated on the working branch on purpose |
| `build-records/behavioral-model__config.status` | 81,573 | its generated companion |
| `build-records/PI__config.log`, `PI__config.status` | 60,822 / 72,400 | same, for PI |
| `build-records/PI__proto__config.log`, `PI__proto__config.status` | 46,130 / 72,592 | same, for `PI/proto` |
| `build-records/p4c__build__CMakeCache.txt` | 66,765 | `p4c-bm2-ss` was built `CMAKE_BUILD_TYPE=Release`, `-O3 -DNDEBUG` |

`MANIFEST.sha256` carries the sha256 of every original as it sat on disk.

## 🔴 What these files are NOT: they are not the log of the build that produced the toolchain

The obvious reading of `install-details/usr-local-5-after-behavioral-model.txt` is "the state of
the system after behavioral-model was installed", and of `log.txt` that it is the install log. For
the `/usr/local` half **both readings are wrong**, and this is the reason to read this section
before quoting either file.

Each snapshot is `find /usr/lib /usr/local $HOME/.local $PYTHON_VENV | sort`
(`p4-guide/bin/install-p4dev-v8.sh`, `debug_dump_many_install_files`, fires at `DEBUG_INSTALL>=2`).
Six observations, each checkable against the files here:

1. The `/usr/local` subset — 610 lines — is **byte-identical in all eight snapshots**
   (`grep '^/usr/local' … | sha256sum` → `05a44ce03d3a…` for every one).
2. Snapshot **1**, named `before-protobuf`, already lists `/usr/local/bin/simple_switch_grpc`,
   `p4c-bm2-ss`, `simple_switch`, `psa_switch` and `libbmall.so`.
3. `/usr/local/bin/simple_switch_grpc` has mtime **2026-07-13 17:19:59**.
4. `p4-guide/bin/install-p4dev-v8.sh` — the hand-edited one — has mtime **17:44:27**, i.e. the
   edit is 25 minutes *after* the binary was installed.
5. Snapshot 1 was written **17:51:24** and `log.txt` closed **17:52:30**: the whole recorded run
   is about eight minutes.
6. Its own timing summary says nothing was built: `p4lang/PI clone : 0 sec`,
   `p4lang/PI install : 1 sec`, `p4lang/p4c clone : 0 sec`, `p4lang/p4c install : 7 sec`,
   `mininet : 0 sec`, `p4lang/ptf : 0 sec`. A p4c build is hours.

Together: **`log.txt` and `install-details/` record a re-run of the installer, after the hand edit,
in which every `if [ -d <dir> ]` guard fired, every clone was skipped, and nothing at all was
written to `/usr/local`.** The eight snapshots differ only in `$PYTHON_VENV` and `~/.local`, where
`pip` was still doing work. The run that actually compiled and installed the toolchain — the one
that ended at 17:19:59 — left **no log in this tree**. It never had one.

So the snapshots are a good record of **what pip put in the venv, stage by stage**, and a
*constant* — a single before-and-after-identical listing — for `/usr/local`. Do not use them to
attribute a `/usr/local` file to an install stage; they cannot do it, for any file.

### What survives this, and what it costs

- `log.txt:1107` is still good for what
  `doc/audit/2026-08-15_bmv2-source-analysis.md:42` cites it for. Line 1107 is inside the
  installer's closing `which` / `--version` verification, which interrogates the
  **already-installed** binary; it reports `1.15.3-f0b7d201`, and that is a fact about the binary
  on disk regardless of which run printed it. The citation holds; the word "install log" around it
  does not.
- `behavioral-model/config.log` (mtime **17:02**) is from the *real* build. It predates the
  re-run by 49 minutes and it is the **only surviving artifact of the run that produced the stock
  `simple_switch_grpc`**. That is why it also sits on the working branch, where the documents that
  cite `config.log:7` can reach it without a branch switch.
- Nothing here changes `doc/audit/bmv2-binary-provenance.md`. That document identifies the stock
  binary by sha256 and BuildID, not by install log, and its `config.log:7` citation is the one
  artifact that came through.

## Reading a file without checking the branch out

    git show audit-raw:p4-source-tree-residue-2026-08-31/build-records/behavioral-model__config.log | sed -n '7p'
    git cat-file blob audit-raw:p4-source-tree-residue-2026-08-31/log.txt | sha256sum

Do not `git worktree add` this branch just to read one file — see this branch's top-level
`README.md` for why (virtiofsd holds deleted files open; expanding it costs disk that `rm` does
not return).
