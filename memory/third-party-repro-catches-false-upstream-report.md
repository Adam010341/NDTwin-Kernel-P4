---
name: third-party-repro-catches-false-upstream-report
description: "The third-party reproduction step exists to rule your own tooling in or out — run it before reporting upstream, because it can invert the finding entirely (bmv2 mastership, 2026-08-13)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7d45c16b-81a8-47c1-b671-54d6b29c02cc
  modified: 2026-08-13T14:52:25.337Z
---

2026-08-13. We spent most of a day building the case that bmv2 violates the P4Runtime spec by
accepting `SetForwardingPipelineConfig` from a non-primary client. Live observation (s10 tables
wiped 4→0), spec clauses pinned verbatim across two versions, a "killer corroboration" that
`Write` implements the same check while the pipeline push does not. One step remained before
filing upstream: **reproduce it with a client that shares no code with ours**, to rule out our
own `p4_client.py`. That step ruled our client *in*. There was no bmv2 bug.

What the third-party client actually showed, three scenarios on live bmv2:
1. A genuine non-primary (lower election id, confirmed `"Is backup"`, stream open) → the push is
   refused with `PERMISSION_DENIED`. **bmv2 does implement the check we said it skipped.**
2. A *duplicate* election id → push accepted **and so is the Write**. The asymmetry we called the
   killer corroboration does not exist.
3. Scenario 2, then close the incumbent's stream between the two RPCs → same client, same election
   id, same RPC kind flips `OK` → `PERMISSION_DENIED`. That was our log all along.

Root cause was ours: every client bid the same hardcoded `election_id (0,1)`, so readopt's "fresh"
client presented the incumbent's exact `(device_id, role, election_id)`. P4Runtime identifies the
sender of a unary RPC by the 3-tuple *in the message*, not by the connection — so bmv2 killed the
duplicate **stream** (which is what set `mastership_confirmed=False`) while correctly honouring
the push.

**Why:** the finding was strong in every way that feels like rigour — reproducible, spec-cited,
with a corroborating asymmetry — and every one of those strengths was compatible with the wrong
mechanism. The decisive detail was already in our own evidence: the log said
`Election id already exists`, which means *duplicate*. The write-up paraphrased it as
"election id 較低" (lower), and from then on the inference was the premise nobody re-examined.
An observation restated in your own words becomes an inference, and inferences inherit confidence
they did not earn.

**How to apply:** when a finding is heading somewhere expensive and hard to walk back — an upstream
bug report, a vendor escalation, a claim in a paper or a slide — identify the step whose *only*
job is to falsify your own involvement, and run it **before** committing to the claim, not as a
formality afterwards. Here that step was "use a client we did not write". Design it to self-verify
its own preconditions first (the probe refuses to conclude anything unless it has confirmed
A=primary and B=backup), so a false negative cannot masquerade as the bug. And when transcribing
evidence into a write-up, quote the literal string the system emitted; if the exact wording is
worth paraphrasing, it is worth keeping.

Same family: [[arithmetic-that-fits-is-not-the-mechanism]] and [[reproducible-is-not-mechanism]]
are this failure without the external blast radius; [[investigation-briefs-separate-observation-from-inference]]
is the discipline that would have kept "被拒" and "較低" apart;
[[new-tools-are-the-first-thing-under-test]] is why the probe self-verifies.
Artifact: `p4_proxy/reference/p4runtime_mastership_probe.py`, write-up
`doc/2026-08-13_p4runtime-mastership-spec-check.md`.
