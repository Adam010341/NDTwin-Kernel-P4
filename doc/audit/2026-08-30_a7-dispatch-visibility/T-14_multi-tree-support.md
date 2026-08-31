# T-14 — multi-tree support: the override forks by privilege layer

[Co-developed with claude code -- Adam]

Written by 8/29 mainDev, `tr5-energy` window (pure reads and writing only). Design ticket, **no
implementation**.

## The premise, stated correctly

`KERNEL_DIR` is **not** simply "supported" or "rejected". It forks:

| layer | behaviour | why |
|---|---|---|
| **user** (`components.env:16`, `ndt`, `stack.sh`) | override **accepted** — `: "${KERNEL_DIR:=…}"` | by design; a different checkout works without editing anything |
| **root** (`tools/test_workflow/ndtwin-lab:51`, installed root-owned at `/usr/local/sbin/ndtwin-lab`, NOPASSWD sudo) | **hardcoded, deliberately not overridable** | the wrapper executes `$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py` **as root** |

Both are correct, and they are correct for different reasons. **That is the ticket.**

The root half's rationale, from the file's own header (`:26-49`), is worth quoting because it
forecloses the obvious "fix":

> Letting the environment choose KERNEL_DIR would let anything running as adam point root at an
> arbitrary adam-writable .py … sudo's env_reset would drop the variable in the normal path
> anyway, so the "override" would be silently ineffective where it is safe and a privilege
> escalation where it worked. **Both halves are bad.**

## The cost is already measured, not hypothetical

`FINDING-01`, 2026-08-30, recorded in the same header: a round pinned the kernel to a worktree and
exported `KERNEL_DIR`, so `ndt`, `stack.sh` and `components.env` all honoured it — **and
`ndtwin-lab`, being outside the reach of that variable, ran the main tree's `ntg_bmv2_topo.py`
with its `host_count_override` of 128, while `ndt up p4 4` wrote 4 into the worktree's copy.**

**Fabric 128, model 4, every structural check green.** No message anywhere said the two halves
disagreed.

🔑 This is the exact shape the ticket has to design against, and it is worse than a plain
mismatch: the honoured override is what *creates* the split. A tool that ignored `KERNEL_DIR`
entirely would have been consistently wrong and obvious; honouring it in five places and not the
sixth produced a stack that was half one tree and half another **while passing its own checks**.
The current mitigation is a comment: *"A WORKTREE CANNOT BE TESTED THROUGH THIS SCRIPT."*

## Design space (the header already drafts it; expanded here)

**(a) Pass the tree as a positional argument to `topo-start`, and refuse any path that is not
root-owned or not on a fixed allowlist.**
* Keeps the privilege boundary meaningful: the caller names the tree, but root decides whether it
  is allowed, and the answer does not come from the environment.
* An allowlist is a file only root can edit, so adding a worktree is a deliberate privileged act —
  which is the right cost for "let root execute code from this directory".
* ⚠️ Root-ownership as the test has a trap: a root-owned *directory* containing an adam-writable
  `.py` still gives root arbitrary code. The check must be on the **executed file**, not the tree
  root. Worth stating because "root-owned" reads as sufficient and is not.

**(b) Install one copy of the wrapper per tree.**
* Simple and needs no new validation, but multiplies a root-owned, NOPASSWD-invoked file. Every
  copy is an independent thing to keep patched, and a stale copy is a root-executed stale
  topology. Prefer (a) unless the number of trees is small and fixed.

**(c) Refuse loudly instead of proceeding (the cheap floor, and it composes with either).**
* `ndtwin-lab` cannot see `KERNEL_DIR`, but it *can* see whether the tree it is hardcoded to is the
  one the caller is in — compare its own `KERNEL_DIR` against `git rev-parse --show-toplevel` of
  the invoking cwd, and refuse when they differ.
* Buys nothing for the multi-tree use case and **would have turned FINDING-01 from a silent
  128-vs-4 split into a refusal at the first command.** Cheapest thing on this list; independent
  of which of (a)/(b) is chosen.

## Recommendation

**(c) now, (a) next.** (c) is small, needs no privilege-model change, and closes the failure mode
that has actually been paid for. (a) is the real multi-tree answer and should not be rushed,
because its whole value is the allowlist being trustworthy.

**(b) only if (a) proves awkward** — more root-owned copies is a worse steady state than one
wrapper with a checked argument.

## Not established

* **No caller inventory.** Which scripts and which humans invoke `ndtwin-lab` directly, and
  whether any of them would break on a new positional argument, has not been checked. (a) is a
  CLI change to a root-invoked tool, so that inventory is a prerequisite, not a detail.
* **Whether worktree testing is still wanted.** The 08-30 agent-worktree round was invalidated for
  an unrelated reason (765 commits behind), and the standing guidance narrowed worktree use to
  outward-facing PRs. If nobody needs to run a fabric from a worktree, (c) alone may close this
  ticket and (a) is unnecessary work.
* **The sudoers rule was not read.** Everything above assumes the NOPASSWD entry targets this
  script specifically; if it is broader, the privilege analysis changes.

## Method note — how this ticket was nearly written backwards

The first draft of this file concluded the premise was false: `components.env:16` uses `:=` and
accepts an override, `ndt` contains no `KERNEL_DIR` at all, and `ls -d ~/ndtwin-lab` found nothing.
Three readings were offered and the ticket was filed **blocked, asking the other side**, rather
than as "the rejection does not exist".

That was the right call and it was still an incomplete search. `ndtwin-lab` is a **file** in
`tools/test_workflow/`, not a directory, and it is installed to `/usr/local/sbin/`. The searches
that would have found it — `git ls-files | grep ndtwin-lab`, `ls /usr/local/sbin` — are the ones
`memory: grep-endpoints-misses-concatenation` names: *before reporting an absence, ask the other
side*. I applied that rule to the **conclusion** and not to the **search**, which is exactly the
half-application the memory warns about: "搜過的範圍" ≠ "存在的範圍".

🔑 The saving move was structural, not clever: **filing a blocked ticket instead of a confident
negative**. The premise turned out to be true, and a ticket saying "this does not exist" would
have been a confident wrong answer with a root-owned privilege boundary as its subject.
