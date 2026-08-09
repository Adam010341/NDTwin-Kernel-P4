# Git hooks

`.git/hooks/` is not version-controlled, so the hook that lives there exists only on the machine it
was installed on. This directory holds the tracked copy.

[Co-developed with claude code -- Adam]

## Install

```sh
cp tools/git-hooks/post-commit .git/hooks/post-commit
chmod +x .git/hooks/post-commit
```

## `post-commit` — advisory AI review of each commit

Runs an AI review of the commit that was just made and writes it to
`.git/agy-reviews/NNNN-<sha>.md`. Backgrounded, so `git commit` returns immediately and is never
blocked; it cannot fail a commit. Requires the `agy` CLI (Antigravity) on PATH.

**It is advisory, not a gate.** Nothing enforces that anyone reads it. CI is the gate.

### What it is for, and what it is not

156 reviews exist in this repository's history. Measured on the one range that was triaged by hand
(reviews 0107–0127), three findings were real, and all three were holes in a fix made the same day --
which is the shape this is good at: a second pair of eyes on a change while its author still
remembers the reasoning.

It is not good at what tooling now covers. A `heap-use-after-free` introduced in commit `c1603d5`
(a temporary `unique_ptr` whose `.get()` was kept past the end of the full-expression) was reviewed
and reported as *"Concurrency / thread-safety: Nothing to report"*, with the surrounding test praised
as "written perfectly". TSan found it later in one run. So: static review for semantics, sanitizers
for memory and threading, and do not expect either to do the other's job.

### Why the prompt looks the way it does

The original prompt asked for a finding *or* an explicit "nothing to report" in each of eight
categories. Across the corpus that produced **313** "nothing to report" statements, **83** instances
of praise, and **332** nitpicks against **74** findings labelled critical or high -- roughly four and
a half nitpicks per serious finding. The instruction manufactured the filler.

The current prompt therefore bans praise, collapses clean categories to a single line, caps nitpicks
at three and only when nothing substantive was found, requires `file:line` on every finding, defines
three severity levels, and opens with a greppable `VERDICT:` line. It also lists the six failure
shapes this codebase has produced more than once, because a targeted checklist has been worth more
here than a generic one.

That rewrite was chosen over switching models. The observed quality gap between reviewers on this
project tracked the prompt more closely than the model, and changing both at once would have tested
neither.
