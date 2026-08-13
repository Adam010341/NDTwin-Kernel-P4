# doc/audit — what is in here, and what deliberately is not

[Co-developed with claude code -- Adam]

Audit, review and test-evidence material for this codebase. Most of it was produced by review
agents; the prompts that produced it are kept alongside the reports, because a finding whose method
is unrecorded cannot be re-run.

## Layout

| Directory | What it holds |
|---|---|
| `codebase-review/` | Whole-codebase reviews: architecture, the four thematic audits (`AUDIT_A..D`) and their adjudications, plus the two prompts that generated them. `components/` holds the per-component reviews. |
| `structure-decomposition/` | Component-by-component structural analysis of the kernel, done before the P4 work started. |
| `overnight-review-2026-08-12/` | The 2026-08-12/13 overnight round: live runbooks (P4 and OVS), static review agents B1–B4, the upstream `8b61cdc` analysis, and the W2 live re-verification. `INDEX.md` first. |
| `advanced-testing-research-2026-08-13/` | Research on testing approaches; two of its recommendations shipped (the P4 coverage gate and the libFuzzer harness). |
| `commit-review-2026-08-08/`, `scoped/` | Earlier rounds, by area and by severity tier. |
| `mutation-evidence-*.md` | Mutation runs. Every `observed failure` is copied from stdout, never predicted. |
| Loose `*.md`, `ryu-wedge-trace-*.tsv` | Single-topic runbooks, findings and raw traces. |

## Deliberately kept outside the repo

These live in `~/Documents/NDTwin documentation/` and were left there on purpose (Adam's decision,
2026-08-13) — moving them in would have created a second source of truth or committed material that
is not about this codebase:

| Kept out | Why |
|---|---|
| `Commit review/NN_Commit_<hash>_Review.md` (80 files) and `Commit review/old/` | Per-commit walkthroughs written so Adam could see what each commit did. Reading material, not findings. |
| `TESTING-INVENTORY.md` | Report material. Its own header names `doc/testing_tools_overview.md` as authoritative, so importing it would create two competing descriptions of the same test suite. |
| `HANDOFF_next-session_*.md` | Session scaffolding — meant to be pasted into a new session, and stale within a day. Not the same thing as `doc/HANDOFF.md`, which tracks unfiled decisions and open work. |
| `S-slide-review.md` | Reviews `~/Desktop/NDTwin-slide-template.md`, which is not in the repo. |
| `DRAFT-message-to-patty.md` | A draft of a message to a person. |
| `PROMPT_EnergySavingApp_9facb78.md` | Reviews a different repository. |
| The three PDFs | Third-party reference material. |

`overnight-review-2026-08-12/INDEX.md` still names `S-slide-review.md` and
`DRAFT-message-to-patty.md` in its tables; a note at the top of that file says where they went.
