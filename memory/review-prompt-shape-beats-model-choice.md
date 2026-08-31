---
name: review-prompt-shape-beats-model-choice
description: "Asked whether to swap the post-commit reviewer from Gemini to DeepSeek, the corpus said the prompt was the problem: 332 nitpicks vs 74 serious findings, 313 'nothing to report', 83 praises"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-09T11:15:28.185Z
---

Adam asked whether to switch the `post-commit` AI review from Gemini (free, on his existing subscription) to DeepSeek (paid, cheap). Measured the 156 reviews already on disk instead of guessing:

- **332** "nitpick" labels against **74** critical/high
- **313** "nothing to report" statements across 91 of 156 files
- **83** instances of praise (excellent / perfectly / remarkably / commendable)
- 8 of 156 empty or truncated (~5% failure rate)

The old prompt asked for a finding **or** an explicit "nothing to report" in each of eight categories, and told it not to skip categories silently. **That instruction manufactured the filler.** So the observed quality gap between reviewers tracked the prompt, not the model — and swapping both at once would have tested neither.

**Decision: keep Gemini on the hook, rewrite the prompt.** Free, per-commit, and in the one range triaged by hand (reviews 0107–0127) three findings were real, all holes in a fix made the same day — which is what per-commit review is good at. Paid review goes where it measurably outperformed: whole-subsystem sweeps, the cross-repo compatibility question, spec-derived tests. All of those need a bespoke prompt a hook cannot provide.

**Do not run both per commit.** Adjudication is the bottleneck — six subsystem reviews were produced in one session and only two got adjudicated. Doubling reports without doubling adjudication is negative value.

The rewrite (tracked at `tools/git-hooks/`, since `.git/hooks` is not version-controlled and 156 reviews' worth of machinery lived only on one machine): ban praise, collapse clean categories to one line, cap nitpicks at three and only when nothing substantive was found, require `file:line`, define HIGH/MEDIUM/NITPICK, and open with a greppable `VERDICT:` line. Plus a checklist of the six failure shapes this codebase has produced more than once — a targeted list has earned its keep here where a generic one did not.

**It worked immediately.** First output was a review of its own commit: `VERDICT: 3 HIGH, 0 MEDIUM, 0 NITPICK`, 1431 bytes against the old format's 5770, every finding with a line number, and it reached for the supplied vocabulary ("a comment that states something false"). All three were real and all three were in the hook. One was over-graded — 157 reviews show zero duplicated sequence numbers, so a race that has never fired is MEDIUM — and saying so matters, having asked it to calibrate.

**The hook could not tell a failed run from a review** (found 2026-08-09, when Adam asked why one
review was empty). `agy` prints its own errors to **stdout** and **exits 0** — verified directly: an
invalid `--model`/`--effort` pair prints `Error: invalid model selection ...` and exits 0. So
`agy … && [ -s "$2" ]` was true for a failed run and announced "review ready" over a 36-byte file
reading `Error: timeout waiting for response`. Four of 166 reviews on disk are like that. The fix is
the `VERDICT:` line, which discriminates the real corpus exactly: all nine post-rewrite successes
open with it, only the failure lacks it. Plus one retry — both observed failures were transient, and
a run that hangs on a 36-line doc commit will hang just as well with a longer timeout.

**Measured before touching the prompt, because "the reviews got shorter" has two causes with
opposite treatments.** 20 reviews before the rewrite: 4118 bytes each, 24 nitpicks, **zero** HIGH.
10 after: 978 bytes each, 1 nitpick, **14** HIGH. The short ones are the documentation commits. But
Adam's challenge was still right on its own terms: the prompt had a **ceiling on filler and no floor
on effort**, and it knew the recurring defect shapes without knowing the system. Both now fixed —
it gets the architecture, where the plan and audit trail live, that `/ndt/` is a contract with seven
applications in other repos (so a response-shape change is HIGH even with a green suite), and it must
close by listing what it read. Also that HEAD may have moved by the time a background review runs.

**Also worth remembering: static review and sanitizers do not substitute for each other.** The `heap-use-after-free` in `c1603d5` was reviewed as *"Concurrency / thread-safety: Nothing to report"* with the containing test praised as "written perfectly"; TSan found it in one run. Related: [[sanitizer-and-ci-setup-gotchas]], [[mutation-gate-for-tests]].
