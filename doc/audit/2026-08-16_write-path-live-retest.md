# Write-path live retest — 2026-08-16

**Scope.** The acceptance judges' #2 gap (`doc/audit/2026-08-15_acceptance-judgments.md`):
`/stats/flowentry/{add,delete_strict,modify}` had never been driven against a live fabric —
"寫入端點全未測", risk wording "**silent no-op or dangerous actuation**". Adam approved this
as the round's first item (form, 2026-08-16); the two unit suites that existed
(`test_p4_client_writes.py` 64, `test_unsupported_match.py` 29) are mocked at the stub, so
none of them had ever met bmv2's actual status vocabulary.

**Verdict up front.** The three implemented endpoints are **honest**: what they claim
happened, happened, on the named switch only, and refusals write nothing. The judge's
instinct was still right — three real defects sat *adjacent* to the tested surface, all on
the delete/parse side, and all three are fixed in `459acbb` (mutation 7/7, live re-verified
on a second fresh fabric).

## Environment

Two fresh fabrics, both `ndtwin-lab topo-start` (NTG-bridge over the 10-switch/4-host
testbed; stock bmv2, cpu-port 255) + `stack.sh up p4` (proxy + kernel). Single clone
replica confirmed on both via thrift `mirroring_get 250` → one `(rid=1, ports=[255])`.
Fabric #1 ran the matrix against the pre-fix proxy (= `bb9aa7e`); fabric #2 ran the fix
verification (`459acbb`), honouring the operational rule that a proxy restart must be a
fabric restart ([[proxy-restart-warm-fabric-multiplies-telemetry]]). Single actor
throughout; NTG prompt never touched.

Verification channels, deliberately independent of the writer:
**T(n)** thrift `table_dump` (non-gRPC), **G(n)** P4Runtime Read (no mastership),
**D** data plane (mnexec ping + `s1-eth{1,2}` tx counters), **P**
`/ryu_server/all_destination_paths`.

## Matrix results

| Case | What | Result |
|---|---|---|
| W1.1 | add new dst (10.9.9.9→s1 p1) | ✅ 200 success; entry on s1 (T+G agree); **T2..T10 zero contamination** |
| W1.2 | add to dpid 99 | ✅ honest `{"status":"error"}`; no write anywhere |
| W2.1 | duplicate add, new port | ✅ INSERT→UNKNOWN→MODIFY fallback fired (log shape); **switch really holds the new port** — the "recalculated path takes effect" repair, first live proof |
| W3.1 | modify | ✅ port flips on the switch |
| W3.2 | modify nonexistent | ✅ 400; **modify did not create** |
| W4.1 | delete | ✅ entry gone (T+G) |
| W4.2 | delete again | ❌ **FINDING-1** (below) |
| W5 | live-traffic cycle on s1→h2 | ✅ table below |
| W6.1-4 | refusal battery (in_port, nw_src on delete, no OUTPUT, no nw_dst, match-as-list) | ✅ all refused with named fields, **zero writes**, broad delete blocked (10.0.0.2 stayed) |
| W6.5 | body not JSON | ❌ **FINDING-2** |
| W7 | writes to SIGSTOP'd s3 | ✅ add error in **5.004s** (=RPC deadline), modify 400 in 5.004s; `/p4/switch_state` polled concurrently: 45 samples, worst **2.4 ms** — the `run_in_threadpool` half of `1a7d815` live-proven; **timed-out writes did not land post-hoc** (T3 = baseline after SIGCONT; observed, not guaranteed) |
| — | non-strict delete route | ❌ **FINDING-3** (found chasing the kernel's caller, not by the matrix) |

**W5 — the load-bearing proof** (ping h1→h2 at 5/s, 8s phases; `tx_packets` deltas):

| Phase | s1-eth1 (→s5) | s1-eth2 (→s6) | ping |
|---|---|---|---|
| A baseline (port 1) | **+42** | +2 | clean |
| B after modify→port 2 | +1 | **+42** | **0 loss at transition** (hitless) |
| C after delete | +2 | +2 | 100% loss (~39 lost ≈ 8.1s×5/s exactly) |
| D after add-back | **+47** | +2 | resumes |

Twin tracked every step: after modify P advertises h1→h2 via s6; after delete the pair is
**withdrawn** (12→11 paths); after add-back restored via s5. Add-back resolved h2's real
MAC from topology (`02, 01` = baseline exactly). Leave-no-trace: final vs baseline dumps
identical on 9/10 switches; T1's one diff is the bmv2 entry *handle* (0x1→0x1000001) from
the delete/re-add — content identical, fully accounted.

## Findings (all fixed in `459acbb`; mutation M1-M7 all killed; live re-verified)

**FINDING-1 — idempotent delete was dead code against real bmv2.**
`delete_ipv4_route` counted `NOT_FOUND` as "already gone = success" (docstring intent),
but bmv2 answers **UNKNOWN with empty details** for that case — the same status as a
genuine refusal (proxy log: `Failed to delete route: StatusCode.UNKNOWN -`). Same bmv2
vocabulary family as the documented duplicate-INSERT case. Harm chain, all verified in
source: kernel parses 2xx bodies for `"status":"error"` → `OpResult::failure` → failed
flow removal logged for every repeat delete; worse, `unroute_flow` skips its bookkeeping
pop on False, so a rule already gone from the switch could never be cleared from
`_installed_routes` — the twin advertises a route that does not exist, permanently.
**Fix:** on UNKNOWN, read the table back and answer by goal state (gone = done;
still-present or unreadable = honest failure), padding bmv2's canonicalized read-back
values. Live: repeat delete now answers success through both routes; zero spurious
delete failures in the log.

**FINDING-2 — malformed bodies answered 500.**
Non-JSON body, or JSON that is not an object, escaped `request.json()`/`data.get()` as an
exception → **500 Internal Server Error** for the client's mistake. The exact defect class
`MalformedMatchError` closed one layer down, alive one layer up. **Fix:** one parse helper
for the three endpoints → 400 naming the problem, before anything touches the topology.
Live: `not json` / `[1,2]` / `"str"` all 400.

**FINDING-3 — the kernel's most natural delete had no route in P4 mode.**
`FlowRoutingManager::deleteAnEntry` defaults `priority = -1` →
`HttpRoutingStrategyBase` posts **non-strict `/stats/flowentry/delete`** — the path taken
by every priority-less delete and by the IntentTranslator's only delete call. The proxy
served only `/delete_strict` → live probe: **404**. Works in OVS mode (ofctl_rest serves
both), so this is a silent OVS/P4 parity hole on the write surface — the judge's
"silent no-op" instinct, materialized one route over. **Fix:** both routes on the one
handler (ipv4_lpm holds one entry per destination, so strict and non-strict name the same
rule — the reason delete_strict already ignored priority). The OpenFlow wildcard half of
non-strict (empty match clears the table) stays deliberately refused, and the refusal is
now pinned by a test. Live: add → `POST /delete` → 200 + entry really gone; delete of
absent through the new route → idempotent success.

## What is now proven that was not before

Response ↔ switch-state agreement on every outcome we could produce; single-switch blast
radius; fallback-MODIFY really replacing ports; refusals and malformed input writing
nothing; deadline-bounded writes against a hung switch with the event loop responsive;
twin bookkeeping (`_installed_routes` → paths) tracking add/modify/delete through the REST
door; delete idempotency in bmv2's actual vocabulary; the non-strict route end to end.

Still untested, said plainly: concurrent write storms (two writers racing on one dpid),
priority semantics beyond ignore-it, non-IPv4 matches beyond refusal, and kernel-driven
end-to-end deletes (TE/Energy live apps were out of scope this round).

## Test-suite deltas

`test_p4_client_writes.py` 64 → **70**; `test_flowentry_endpoints.py` new (**6**).
Mutation gate M1-M7 (per-mutant restore, `PYTHONDONTWRITEBYTECODE=1`, pycache purged):
M1 no-True-on-UNKNOWN ×2 red, M2 inverted presence ×3 red, M3 padding dropped ×1 red,
M4 prefix ignored ×1 red, M5 unreadable-as-success ×1 red, M6 non-object guard ×10 red,
M7 route unregistered ×1 red. Baseline green after every restore.

*Session evidence (curl transcripts, dumps, counters, ping logs) lived in the session
scratchpad; every number above is transcribed from it. Prepared during the 2026-08-16
write-path round; fixes `459acbb`, this report is the round's archive.*

[Co-developed with claude code -- Adam]
