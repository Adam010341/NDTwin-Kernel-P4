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
| `2026-08-08_commit-review/`, `scoped/` | Earlier rounds, by area and by severity tier. |
| `mutation-evidence-*.md` | Mutation runs. Every `observed failure` is copied from stdout, never predicted. |
| Loose `*.md`, `ryu-wedge-trace-*.tsv` | Single-topic runbooks, findings and raw traces. |

## Why `2026-07-30_audit-be3c242/` is still here

`doc/2026-07-30_audit-be3c242/` is the **first** ten-stage subsystem review (2026-07-31, against commit
`be3c242`). It is kept, not superseded-and-deleted, because it is the only record of what the
codebase looked like before the P4 work — but it must be read with one rule, which every prompt of
the second round restated:

> Reference it, never copy from it. It was written against an old commit, and at least five fix
> commits have since changed the code it describes. Any claim taken from it has to be re-verified
> against the source as it is now.

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
