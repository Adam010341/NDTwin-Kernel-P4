# `claude-memory` — snapshot of this project's Claude memory directory

[Co-developed with claude code -- Adam]

An orphan branch. It shares no history with `trunk` or `main`, the same arrangement
`audit-raw` uses. Nothing here is source code; it is the memory directory that Claude
sessions read at the start of every session and write to as they learn things.

| | |
|---|---|
| Source | `/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory/` |
| Snapshot taken | 2026-08-31 (auditor session, at Adam's instruction) |
| Contents | 144 `.md` files, 2.0 MB, verified byte-identical to the source at snapshot time |
| Push targets | `p4` → `Adam010341/NDTwin-Kernel-P4` and `ndtwin-lab/NDTwin-Kernel-P4` |

## 🔴 This branch must not be published

Both push targets were **PRIVATE** when this was written, verified with
`gh repo view <repo> --json visibility` rather than assumed. Keep it that way.
The reason is not general caution — it is four specific things in the files:

| what | files |
|---|---|
| **Unsubmitted double-blind work**: venues, submission plan, `abstract.tex`, Turnitin runs | **17** |
| Third parties' private assessments, quoted (a supervisor's verdict on the work; a colleague's instruction about lab access) | **15** |
| Lab and host infrastructure: addresses, ssh arrangements, `nslab` details | 29 |
| Adam's real name and institutional accounts | 4 |

The first row is the one that decides it. **Both submissions are double-blind and neither
has been sent.** Publishing files that name the venues, the plan, and the author would
break anonymity directly — no inference required.

This is not hypothetical on this project. On 2026-08-31 a `.ova` destined for a shared
drive carried an entire working-tree `.git` containing 77 objects of the same submission
(`abstract.tex`, `refs.bib`, `figs/`). The objects had never been checked out, so `ls`,
`find`, `grep -r` and `git status` all reported the tree clean; only
`git rev-list --objects --all` could see them. **Four checks agreeing that something is
clean is not evidence that it is.**

If publishing is ever considered, it is a separate decision needing a per-file pass over
at least the 17, not a `grep` and a glance. Read
`memory/packaging-a-filesystem-ships-the-invisible.md` first — it is the write-up of the
incident above.

## What this is and is not

**A snapshot, not a sync.** The live directory keeps changing; several sessions write to
it concurrently, sometimes within the same hour. This branch is what it looked like at
one moment. Refreshing it means taking another snapshot deliberately — nothing updates
it on its own, and a stale snapshot presents itself exactly like a current one.

**Not authoritative over the repo.** Where a memory file and the repo disagree about this
codebase, the repo wins; memory records what was true when it was written. Several files
say so about themselves. `memory/MEMORY.md` is the index each session loads — start there.

## Reproducing the snapshot

```
git worktree add --detach <tmp> HEAD
cd <tmp> && git checkout --orphan claude-memory && git rm -rq --cached .
mkdir -p memory && cp /home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory/*.md memory/
git add README.md memory/ && git commit
```

`git add` names its paths on purpose. The worktree still holds the untracked checkout the
orphan branch was cut from, so `git add -A` there would sweep the whole repo into this
branch — the directory-pathspec hazard `CLAUDE.md` warns about, one level up.
