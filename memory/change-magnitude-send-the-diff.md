---
name: change-magnitude-send-the-diff
description: "I judged the shared-kernel changes 'not big, easy to revert'; a review of the actual 7237-line diff said large/high and was right. I had assessed only the fixes I remembered from one session"
metadata:
  node_type: feedback
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-08T13:13:02.443Z
---

Adam asked whether the changes to shared kernel code (used by both the OVS and P4 paths) were a big deal and how painful a revert would be. **My answer was wrong in a way worth remembering.**

I said "not a big change, revert is easy", reasoning from a list of ten fixes. A review of the **actual diff** (7237 lines, 33 files, since baseline `28b8b13`) concluded **magnitude large, revert pain high** — and it was right. Four substantial items were absent from my list entirely, all verified present: `OpResult` plus the whole failure-reporting chain, the sFlow `BoundedWords`/`TruncatedDatagram` bounds checking, `m_ifIndexMapMutex` changing from `std::mutex` to `std::shared_mutex`, and `pingWorker` nearly rewritten (+766 lines in that file).

**Why:** I assessed the fixes I remembered from the current session rather than the diff since the baseline. The scope I evaluated was much smaller than the scope I was asked about, so the judgement was internally consistent and externally false.

Worse, I first asked DeepSeek the same question by feeding it my hand-written summary. It agreed with me — which was not independent confirmation but **an echo of my own error**, because I had withheld the only thing that determines magnitude.

**How to apply:** to judge the size, risk or revertability of a change, **send the diff, not a summary of it** — `git diff <baseline>..HEAD -- <paths>` into the reviewer's context. For that kind of judgement use `deepseek-v4-pro -e max`, not the flash default; the wrapper now handles 300 KB+ prompts (see [[deepseek-large-prompt-fix]]). And when asked "is this big?", first establish *what set* is being asked about — mine differed from Adam's by several major subsystems. The full review is kept at `doc/audit/2026-08-08_change-magnitude-review.md` with its three "verify these first" priorities: concurrency under simultaneous sFlow load and topology flapping; HTTP status-code compatibility for existing clients; and end-to-end numeric correctness plus a >1 hour memory and thread-count watch. Related: [[existence-is-not-wiring]] — same family of error, reasoning from a proxy for the artefact instead of the artefact.
