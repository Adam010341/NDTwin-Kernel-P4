# Provenance note — I edited the experiment's subject while the run was in flight

[Co-developed with claude code -- Adam]

## What happened

Adam ruled "fix R-1 now" while `host_curve.sh` was still running. I applied R-1 to
`intelligent_router.py` — **which is the very file each boot of this run loads into Ryu** — without
first checking whether the run had finished. It had not: 3 of 8 boots were recorded and a fourth
was in flight.

The run's header pins the router it believes it is measuring:

```
# router:  sha256=d19020b1a1dcf932  matches HEAD
```

With R-1 applied the file was `a5c8bcad6cc55f3b`. Reverted immediately; the file is back to
`d19020b1a1dcf932` and clean against HEAD. The R-1 patch is held in the session scratchpad and
will be re-applied **after** this run completes.

## Provenance of each boot

| boots | router | certainty |
|---|---|---|
| `loaded_p1`, `quiet_p1`, `loaded_p2` | `d19020b1` | **certain** — completed before the file was touched |
| `quiet_p2` (4th, in flight during the edit) | almost certainly `d19020b1` | **inferred, not proven** — see below |
| `loaded_p3` onward | `d19020b1` | **certain** — file restored before they start |

The 4th boot's Ryu had been running **204 s** when checked, while the modified file existed for
roughly the window t-180 s to t-60 s. Ryu reads `intelligent_router.py` once at import, so a
process that started at t-204 s loaded the original. That reasoning is sound but rests on my
recollection of when I ran the edit, not on a recorded timestamp. **Treat `quiet_p2` as
provenance-uncertain**: if it produces an anomalous result, do not build on it without a repeat.

## Why this is recorded rather than quietly fixed

R-1 adds a conditional warning log and changes no control flow, so the temptation is to say it
could not have affected the outcome and move on. That reasoning is exactly the failure mode this
project keeps logging: *deciding a change is harmless instead of keeping the record honest*. An
experiment whose subject changed mid-run, with the artefact still asserting a single sha, is not
something a reviewer can check — and this run's whole purpose is to be checkable.

## The rule this should have followed

**Do not modify the subject of a running experiment, however harmless the change looks.** The
harness already asserts the router sha in its header; that assertion runs *once, at start*, and
cannot see a mid-run change. A future harness should re-assert the sha per boot and mark any
iteration whose subject moved.
