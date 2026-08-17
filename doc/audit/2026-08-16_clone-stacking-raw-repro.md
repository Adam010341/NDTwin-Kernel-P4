# Clone-session stacking: raw-client reproduction, and the delete that heals it — 2026-08-16

**Why this document exists.** The reconciliation round
(`doc/audit/2026-08-16_concurrent-flow-reconciliation.md` §5b) convicted
"proxy restart × warm fabric = telemetry ×N" with our own proxy as the actor. Before
anything goes upstream, the C8 lesson applies
([[third-party-repro-catches-false-upstream-report]]): reproduce with a client that shares
nothing with the suspect. `p4_proxy/reference/clone_stack_probe.py` is that client — raw
grpc + stock p4.v1 protobufs, same discipline as the mastership probe. Observation channel
(thrift `mirroring_get` / `mc_dump`) is independent of the actor (gRPC).

## Phases (one scratch device, fresh fabric; each phase re-arbitrates (0,1))

| Phase | Action | Status answered | PRE nodes after |
|---|---|---|---|
| boot | nothing pushed | — | session not found |
| **a** gen-1 | push pipeline + INSERT session 250 | OK / OK | **1** |
| **b** control | duplicate INSERT, **no push** | **UNKNOWN ('')** | 1 — no stacking |
| **c** gen-2 | push + INSERT | OK / **OK** (no duplicate!) | **2** |
| **d** gen-3 | push + DELETE + INSERT | DELETE **UNKNOWN ('')**, INSERT OK | **3** |
| **e** diagnostic | DELETE, **no push** (session registered) | **OK** | **0 — whole group destroyed, orphans included** |

Everything the round claimed, our proxy excluded, plus two corrections:

1. **The trigger is the pipeline commit, not the restart.** Control (b): with bookkeeping
   intact a duplicate INSERT is properly refused and nothing stacks. After a
   `SetForwardingPipelineConfig(VERIFY_AND_COMMIT)` the server's clone bookkeeping is
   empty, the PRE multicast group (mgid 0x8000+session) survives, and the next INSERT
   *appends* a replica to it.
2. **Correction:** §5b said the post-commit DELETE is answered NOT_FOUND. The raw capture
   says **UNKNOWN with empty details** — the round's NOT_FOUND was an inference (the
   proxy's best-effort `except: pass` never logged a code). Fourth instance of bmv2's
   UNKNOWN-for-everything vocabulary ([[bmv2-unknown-status-vocabulary]]). The effective
   claim — that DELETE cannot reach the orphan — stands unchanged.
3. **Phase e overturns "no clone-session API call can clean it up":** a DELETE issued
   while the bookkeeping *holds* the session destroys the entire backing group, stacked
   replicas and all. The orphans are unreachable only from the emptied-bookkeeping state.

## The fix this bought (`79e4f69`)

`write_clone_session` now **settles** after every successful registration: DELETE +
INSERT once more. At that point the bookkeeping always holds the session, so the DELETE
is phase e's — it collapses whatever the group accumulated across any number of pipeline
re-commits, and the INSERT rebuilds exactly one replica. Sequence on the wire:
`DELETE, INSERT[, MODIFY], DELETE, INSERT`. A settle failure is a real failure (a True
there could hand back a session that multiplies every sample).
Tests 20 → 23, sequence pins updated, mutation gate M1-M4 all killed (settle removed /
failure swallowed / order inverted / rebuild dropped).

**Live heal validation** (same day): probe stacked s1 to **2** replicas (phases a+c),
then a plain `stack.sh up p4` against that warm fabric — the settled proxy's own
pipeline push re-orphaned the group, registration appended, settle collapsed:
**s1 = 1 node** afterwards (s5, s9 = 1; sessions installed 10/10; `settle failed` count
0). Fabric torn down to 0/0 after.

**Operational rule downgrade:** "a proxy restart must be a fabric restart" drops from
load-bearing to defense in depth. The veth reconciliation harness remains the detector
for this whole shape.

## What is upstream-grade — and why it was not submitted

Reproduced without our code: a pipeline config commit on `simple_switch_grpc` leaves the
PRE clone group of a previously-programmed session alive while forgetting the session —
the next same-id INSERT appends to the orphan (silent replication ×N), duplicate
detection is lost, and a post-commit DELETE cannot reach it. Expected behaviors that
would each close the hole: clear PRE clone state on commit, or keep session bookkeeping
across commits, or refuse the dangling-group INSERT. Whether the defect sits in bmv2's
PI integration or PI's clone manager is for upstream to place; the probe reproduces it
in five phases on a stock build.

🚫 **Submission ruling (Adam, 2026-08-17): not filed — archived only.** This supersedes
the 08-16 ruling ("file it separately with p4lang"). Nothing was posted: no matching
issue exists on p4lang, verified 08-17 with `gh search issues --author Adam010341`. The
prepared issue text stays at `doc/2026-08-16_p4lang-clone-stacking-issue-draft.md`,
carrying the same ruling banner, ready if that changes. Our own exposure is closed by the
settle pair (`79e4f69`) below, so the archive is a record, not an open loop.

[Co-developed with claude code -- Adam]
