# p4lang/behavioral-model issue 稿:clone session 疊加(2026-08-16)

> 🚫 **裁決:不投遞,只歸檔(Adam 2026-08-17 表單)。** 取代 08-16 那次的「單獨投 p4lang」。
> **這份稿子沒有貼出去,也不要貼**——p4lang 上不存在對應的 issue(08-17 以
> `gh search issues --author Adam010341` 查證過)。本檔從此是內部紀錄:缺陷的完整
> 陳述留在這裡,是因為它自成一頁、對外可讀,將來若改變主意可以直接用。
>
> **內部前言**:原定投 https://github.com/p4lang/behavioral-model/issues(它同時牽動
> PI 的簿記與 bmv2 的 PRE,先投 behavioral-model,維護者若判在 PI 會自己轉)。
> 佐證出處:`doc/audit/2026-08-16_clone-stacking-raw-repro.md`(五相原始輸出)、
> probe=`p4_proxy/reference/clone_stack_probe.py`。
> ⚠️ **我方不受此缺陷影響**:settle pair(`79e4f69`)已讓 `write_clone_session` 在任何
> 路徑都收斂到單 replica,並經 live heal 驗證。歸檔不代表問題還開著。
> 正文如下,英文。

---

**Title: Pipeline config swap orphans PRE clone-session state: re-INSERT then appends a
duplicate replica (telemetry silently multiplied)**

### Summary

After a `SetForwardingPipelineConfig` (VERIFY_AND_COMMIT) on a running
`simple_switch_grpc`, the P4Runtime server's clone-session bookkeeping is reset, but the
PRE multicast group backing a previously-inserted clone session survives. A subsequent
`INSERT` of the same session id then succeeds (duplicate detection is gone with the
bookkeeping) and **appends a second replica to the surviving group**. Every cloned
packet is now duplicated; each further config-swap-plus-INSERT cycle adds one more
replica. For a controller that programs its clone session on (re)connect — the natural
pattern — a controller restart silently multiplies all clone-based telemetry.

### Environment

bmv2 1.15.3 (f0b7d20), built from source; P4Runtime over gRPC
(`simple_switch_grpc`); any P4 program using `clone_preserving_field_list` (ours clones
to a CPU port for sFlow-style sampling; session id 250, one replica to port 255).

### Reproduction (raw P4Runtime client, five steps)

Observed via the thrift CLI between steps: `mirroring_get 250` and `mc_dump`
(session 250 maps to mgid 0x8000+250 = 33018).

| Step | Action | Status returned | PRE state after |
|---|---|---|---|
| 1 | arbitrate, push pipeline, INSERT clone session 250 (1 replica, port 255) | OK / OK | 1 node |
| 2 | duplicate INSERT, **no push** (control) | UNKNOWN (empty details) | 1 node — correctly refused |
| 3 | push pipeline again, INSERT | OK / **OK** | **2 nodes** |
| 4 | push again, DELETE, INSERT | DELETE **UNKNOWN** (empty details), INSERT OK | **3 nodes** |
| 5 | DELETE with the session registered (no push in between) | OK | session and group fully removed |

Step 2 isolates the trigger: client churn alone does not stack — the config commit does.
Step 4 shows the defensive `DELETE`-before-`INSERT` a controller might attempt cannot
reach the orphaned group (the emptied bookkeeping answers UNKNOWN and the target is
never touched). Step 5 shows the group is only reachable again after the session is
re-registered — at which point a DELETE removes the whole group, accumulated replicas
included (this is the workaround below).

### Expected

Any one of these would close the hole:

- the config swap clears the PRE clone/multicast state along with the session
  bookkeeping, or
- the session bookkeeping survives the swap (so the duplicate INSERT keeps being
  refused), or
- an INSERT that finds a dangling group for its session id refuses (or resets the
  group) instead of appending to it.

### Impact and workaround

Impact: silent, uniform multiplication of all cloned traffic after a controller restart
against a warm switch — we measured every sampled rate doubling fabric-wide, and it is
invisible unless telemetry is reconciled against an independent channel.

Controller-side workaround that works today: after successfully registering the clone
session, immediately DELETE and re-INSERT it once ("settle"). The DELETE now lands on a
registered session, destroys the whole backing group (orphans included), and the
re-INSERT rebuilds it with exactly one replica.

A standalone ~200-line Python repro (raw grpc + stock p4.v1 protobufs, no framework)
driving the five steps is available on request / attached.

*Found while reconciling digital-twin telemetry against veth counters in NDTwin's P4
testbed; happy to provide the full lab notes.*
