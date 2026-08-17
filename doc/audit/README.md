# doc/audit — what is in here, and what deliberately is not

[Co-developed with claude code -- Adam]

Audit, review and test-evidence material for this codebase. Most of it was produced by review
agents; the prompts that produced it are kept alongside the reports, because a finding whose method
is unrecorded cannot be re-run.

## Layout

| Directory | What it holds |
|---|---|
| `2026-07-29_codebase-review/` | Whole-codebase reviews: architecture, the four thematic audits (`AUDIT_A..D`) and their adjudications, plus the two prompts that generated them. `components/` holds the per-component reviews. |
| `2026-07-17_structure-decomposition/` | Component-by-component structural analysis of the kernel, done before the P4 work started. |
| `2026-08-12_overnight-review/` | The 2026-08-12/13 overnight round: live runbooks (P4 and OVS), static review agents B1–B4, the upstream `8b61cdc` analysis, and the W2 live re-verification. `INDEX.md` first. |
| `2026-08-13_advanced-testing-research/` | Research on testing approaches; two of its recommendations shipped (the P4 coverage gate and the libFuzzer harness). |
| `2026-07-30_audit-be3c242/` | The first ten-stage subsystem review, against commit `be3c242`. Read the rule below before quoting it. |
| `2026-08-17_p4-vs-ovs-matched-topology/` | 23 live failover measurements holding the topology constant across P4 and OVS. Retires the "P4 12.5 s vs OVS 291 s" comparison: the 291 s was mostly a since-fixed kernel defect, and the real data-plane gap is **2.0 s, 13 %** (13.7 vs 15.7 s, n=10 each, p=0.0098). Raw ping logs and the measurement script are kept with the report. |
| `2026-08-08_commit-review/`, `scoped/` | Earlier rounds, by area and by severity tier. |
| `mutation-evidence-*.md` | Mutation runs. Every `observed failure` is copied from stdout, never predicted. |
| Loose `*.md`, `ryu-wedge-trace-*.tsv` | Single-topic runbooks, findings and raw traces. |

## Every measured number carries the commit it was measured at

**Rule: when a measured figure goes into a document, write the commit beside it.**
`50.1 s (9467ea0)`, `585 tests / 79 suites (13e53df)`. One token, written once.

A measurement is only true of the code that produced it, and the code moves. Without the commit
a reader cannot tell a current fact from a historical one, so stale figures keep getting quoted
as if they were properties of the system. Both of 2026-08-17's instances were found by accident,
not by anything that looks for them:

| figure | valid for | then quoted for |
|---|---|---|
| OVS blackholes **291 s** with zero self-heal | measured overnight 08-12/13; `034da18` fixed it at **09:48 on 08-13** | **4 days**, across 11 files, as a property of OVS. Re-measured 08-17: 50.1 s, and it self-heals |
| C++ baseline **579 tests / 78 suites** | written 08-17 ~14:00 | hours — `1b1f941` and `13e53df` overtook it the same afternoon, under a line reading "a mismatch means someone changed the code" |

Both were written accurately and neither was wrong when written. Nothing changed them because
nothing connected the fix to the sentence it invalidated. The commit tag does not prevent the
rot; it makes the rot **visible to the next reader**, which is the part that failed here.

Two corollaries this repo already follows, now stated:

- **Historical records are not corrected, they are dated.** A finding written against an old
  commit stays as it is — see the `be3c242` rule below. It is *current-facing* documents (the
  testing manual's baseline, the fault catalogue's expectations, this index) that must be
  corrected, because a reader acts on those.
- **Retire in place, do not delete.** When a figure is superseded, leave the old sentence with a
  RETIRED marker and the new measurement beside it. `faults.txt`'s L-2 entry is the worked
  example: the reasoning behind the wrong expectation is still worth reading.

## Why `2026-07-30_audit-be3c242/` is kept, and why it used to sit outside

`doc/audit/2026-07-30_audit-be3c242/` is the **first** ten-stage subsystem review (2026-07-31, against commit
`be3c242`). It is kept, not superseded-and-deleted, because it is the only record of what the
codebase looked like before the P4 work — but it must be read with one rule, which every prompt of
the second round restated:

> Reference it, never copy from it. It was written against an old commit, and at least five fix
> commits have since changed the code it describes. Any claim taken from it has to be re-verified
> against the source as it is now.

Until 2026-08-17 it lived at `doc/2026-07-30_audit-be3c242/`, one level up, which looked like a
filing mistake and was asked about as one. It was not: `1f9e4b4` created it on 2026-07-30, and
`doc/audit/` did not exist until `ef30fde` brought 54 files back from `~/Documents` on 08-13. It
predates the convention rather than breaking it, and the date-prefix rename (`9e3874c`) moved
nothing. Moved in here now, because a reader's first question about a layout is the layout's
problem. The directory name keeps its
`audit-` stutter on purpose: unchanged, it stays the same greppable identifier it is in the commit
history and in the several hundred post-commit reviews under `.git/agy-reviews/`.

A **second** ten-stage plan was written on 2026-08-03 (`doc/audit/00-workflow-plan.md`, 1641 lines)
intending to redo that review against the current tree, with outputs named
`doc/audit/NN-<phase-name>-summary.md`. **It was never executed** — no such file was ever created,
and the review effort went into differently-shaped work instead (the mutation evidence, the scoped
review of `be3c242..576dd2a`, the thematic `2026-07-29_codebase-review/` audits, and the overnight round).
The plan was deleted 2026-08-13 as dead weight; recover it from git history if the ten-stage
approach is ever wanted again. Its embedded "environment facts" had rotted badly by then — it
asserted the repo had no CI (`tools/test_workflow/local_ci.sh` now exists) and quoted a gtest count
of 156 (now 554), which is itself a good illustration of why a plan document ages worse than a
findings document.

## Deliberately kept outside the repo

These live in `~/Documents/NDTwin documentation/` and were left there on purpose (Adam's decision,
2026-08-13) — moving them in would have created a second source of truth or committed material that
is not about this codebase:

| Kept out | Why |
|---|---|
| `Commit review/NN_Commit_<hash>_Review.md` (80 files) and `Commit review/old/` | Per-commit walkthroughs written so Adam could see what each commit did. Reading material, not findings. |
| `TESTING-INVENTORY.md` | Report material. Its own header names `doc/2026-08-07_testing_tools_overview.md` as authoritative, so importing it would create two competing descriptions of the same test suite. |
| `HANDOFF_next-session_*.md` | Session scaffolding — meant to be pasted into a new session, and stale within a day. Not the same thing as `doc/2026-07-29_HANDOFF.md`, which tracks unfiled decisions and open work. |
| `S-slide-review.md` | Reviews `~/Desktop/NDTwin-slide-template.md`, which is not in the repo. |
| `DRAFT-message-to-patty.md` | A draft of a message to a person. |
| `PROMPT_EnergySavingApp_9facb78.md` | Reviews a different repository. |
| The three PDFs | Third-party reference material. |

`2026-08-12_overnight-review/INDEX.md` still names `S-slide-review.md` and
`DRAFT-message-to-patty.md` in its tables; a note at the top of that file says where they went.
