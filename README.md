# audit-raw

Raw artifacts for the rounds under `doc/audit/` -- logs, greenlet dumps, harness stdout.

## Why they are on a branch of their own

They are append-only evidence: written once, read by the analysis scripts in each round
directory, never edited. Carrying them on a working branch put ~166k lines into every pull
request diff, which is 55% of the diff and none of the review. Nothing here is generated
by a build, so it cannot be regenerated -- deleting it was not an option.

**This branch is not merged and must not be.** It shares no history with `main`; it exists so
the artifacts have a durable home and a URL.

## Reading a file

    git show audit-raw:doc/audit/2026-08-25_ring-edge-fix/raw/g001_ar1_greenlets.txt

or check it out somewhere disposable:

    git worktree add /tmp/rawwt audit-raw

Working copies also stay on disk in the main checkout, untracked and gitignored, so the
per-round scripts keep working with no path changes.

## Naming

One prefix per experiment, never reused. Phase 5 of the ring round reused Phase 4's `p1`/`p2`
prefix and silently overwrote four boots in the working tree; only the fact that Phase 4 was
already committed saved them. `p{1,2,3}` = Phase 4, `ar{1,2}` = Phase 5.

[Co-developed with claude code -- Adam]
