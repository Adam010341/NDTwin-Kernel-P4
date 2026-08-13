# U — Upstream `8b61cdc "Add sharding"` analysis

**Agent**: U (upstream merge analysis)
**Date**: 2026-08-13
**Scope**: analysis only. No merge, no rebase, no cherry-pick, no file modification, no push.

## Provenance / where I stood

- Worktree: `/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-abf15f9d7d181e465`
- **On entry `git log --oneline -1` = `8b61cdc Add sharding`** — i.e. the worktree had been branched from `origin/main`, the *upstream* tree. This is the trap the brief warned about; I hit it too.
- Corrected with `git fetch origin && git fetch p4 && git reset --hard d2a609a`.
- **All "our side" statements below are made from `d2a609a`** ("Turn two of the overnight round's near-misses into standing guards").
- Verified: `git merge-base d2a609a 8b61cdc` = `28b8b133cd8835a58d52a8f3b4864672c3dd02f1`. `28b8b13..d2a609a` = **277** commits; `28b8b13..8b61cdc` = **1** commit.
- Upstream side read via `git show 8b61cdc:<path>`; never checked out.

---

## TL;DR

1. **The commit is badly named.** "Add sharding" is ~40% of it. The other 60% is: a new **sFlow sample type 5 parser** (132 new lines, a wire-format feature), **three background threads disabled**, the **topology-map update path commented out**, a **socket-close removed from `stop()`**, a **new exported metric**, and a **LAG port renumber** in a `setting/` JSON. Any merge discussion that treats this as "a perf change" will silently absorb four behavioural changes.
2. **The sharding itself is textbook lock striping** — 1024 shards, each `{shared_mutex, unordered_map}`, indexed by `FlowKeyHash(key) & 1023`. It is *correct in the narrow sense* (equal keys always land in the same shard) and it is **for throughput, not for correctness**.
3. **Her sharding rewrite incidentally fixes two real baseline defects** (an unlocked `find()` race in `handlePacket`, and a recursive `shared_lock` in `getTopKFlowInfoJson`). We fixed at least one of those independently. **This is the crux: the same defects were fixed twice, differently.**
4. **It also fixes a genuine metric bug** hidden inside a reindentation hunk: `estimatedPacketSendingRateImmediately` was being computed from **bytes**; she changed it to **packets**.
5. **She left `m_flowInfoTable` and `m_flowInfoTableMutex` in place** — the old table survives only as a `decltype` anchor, and the old mutex is entirely dead. The class doc-comment still describes the pre-sharding design. This is the repo's own ["should replace, can only add"](../..) bug shape, in her commit.
6. **The single most consequential unknown**: sample type 5 is a *custom* sFlow sample she is parsing with hardcoded byte offsets. Nothing upstream produces it. Either her P4 pipeline emits it, or the HPE lab gear does. We cannot merge that parser without knowing which — see Q1 in §5.

---

## §1 — What she actually did

`git show 8b61cdc --stat`:

```
 include/common_types/SFlowType.hpp                 |   1 +
 include/ndt_core/collection/FlowLinkUsageCollector.hpp |  39 +-
 setting/StaticNetworkTopology_ipAlias4_10_HPE_Switches_smapled_by_p4.json | 48 +-
 src/ndt_core/collection/FlowLinkUsageCollector.cpp | 666 +++++++++++++--------
 src/utils/Logger.cpp                               |   2 +-
 5 files changed, 483 insertions(+), 273 deletions(-)
```

Note the fifth file — the topology JSON — which the 2026-08-12 merge test did not surface (it merges cleanly, so it never showed up as a conflict).

The 666-line `.cpp` diff is **21 hunks**. Only ~8 of them are sharding. Below, behaviour-first.

### 1a. The sharding proper (the part the title describes)

**[Observation]** In `include/ndt_core/collection/FlowLinkUsageCollector.hpp` at `8b61cdc`, lines 163-175:

```cpp
static constexpr size_t FLOW_TABLE_SHARD_COUNT = 1024;

struct FlowTableShard
{
  mutable std::shared_mutex mutex;
  std::unordered_map<FlowKey, FlowInfo, FlowKeyHash> table;
};

std::array<FlowTableShard, FLOW_TABLE_SHARD_COUNT> m_flowInfoTableShards;

size_t getFlowShardIndex(const FlowKey& key) const;
FlowTableShard& getFlowShard(const FlowKey& key);
const FlowTableShard& getFlowShard(const FlowKey& key) const;
```

**What is sharded**: the in-memory flow table — the `FlowKey → FlowInfo` map that is the collector's central mutable state.

**Sharding key**: `FlowKeyHash{}(key) & (FLOW_TABLE_SHARD_COUNT - 1)`, guarded by a `static_assert` that the count is a power of two (`.cpp` at `8b61cdc`, lines 2242-2248). `FlowKeyHash` (in `include/common_types/SFlowType.hpp`, lines 221-233) combines **srcIP, dstIP, srcPort, dstPort, protocol** — the 5-tuple.

**[Observation]** `FlowKey` (same file, lines 24-41) also carries `icmpType` and `icmpCode`, and its `operator==` is `= default` (so it *does* compare them), but `FlowKeyHash` does **not** hash them. This asymmetry predates her commit — it is unchanged at `28b8b13`. It is legal (equal keys still hash equal, so they still land in the same shard); it only means ICMP flows differing solely in type/code collide. **Sharding does not introduce a bug here** — I checked specifically because a wrong shard index for equal keys would be catastrophic, and it is not.

**Why (purpose)**: **[Inference, high confidence]** throughput under lock contention, not correctness. The evidence: the shards exist purely to split one `shared_mutex` into 1024; there is no change to what is stored or to flow identity. Contention was real at baseline — every sampled packet took a `unique_lock` on one global mutex in `handlePacket`, on the packet-processing hot path, across `numWorkers` worker threads.

**New allocation behaviour** — constructor, `.cpp` lines 71-78:

```cpp
constexpr size_t expectedTotalFlows = 65536;
constexpr size_t perShardReserve =
    (expectedTotalFlows + FLOW_TABLE_SHARD_COUNT - 1) / FLOW_TABLE_SHARD_COUNT;

for (auto& shard : m_flowInfoTableShards)
{
    shard.table.reserve(perShardReserve);
}
```

So 1024 shards × `reserve(64)` at construction. **[Inference]** She is sizing for ~65 536 concurrent flows. That is a scale target worth confirming — it is the only number in the commit that hints at the workload she is designing for.

**No new threads, no new config item.** Shard count is a compile-time `constexpr`, not tunable.

### 1b. Old table left behind — "should replace, can only add"

**[Observation]** At `8b61cdc` the header **still declares both**:
- line 189: `std::unordered_map<FlowKey, FlowInfo, FlowKeyHash> m_flowInfoTable;`
- line 205: `mutable std::shared_mutex m_flowInfoTableMutex;`

**[Observation]** In the `.cpp` at `8b61cdc`, the only surviving reference to the old table is line 2100:

```cpp
using MapT = std::remove_reference_t<decltype(m_flowInfoTable)>;
```

i.e. it is kept **solely as a type anchor**. `m_flowInfoTableMutex` has **zero** remaining references — it is a dead member.

**[Observation]** The class doc-comment is stale. `include/ndt_core/collection/FlowLinkUsageCollector.hpp` at `8b61cdc`:
- line 45: `maintains an in-memory flow table (m_flowInfoTable) and per-interface counter snapshots`
- line 53: `- m_flowInfoTable is protected by a shared mutex (readers/writers).`

Both still describe the pre-sharding design. **[Inference]** This reads like work-in-progress that was committed at a checkpoint rather than a finished refactor — consistent with the `// TODO` markers noted below.

### 1c. Three background threads disabled (NOT sharding)

**[Observation]** `.cpp`, `start()` — hunk `@@ -301,12 +309,13 @@`:

```cpp
     m_pktRcvThread = thread(&FlowLinkUsageCollector::run, this, numWorkers, queueCapacity);
+    // TODO
     m_calAvgFlowSendingRateThreadPeriodically =
         thread(&FlowLinkUsageCollector::calAvgFlowSendingRatesPeriodically, this);
-    m_testCalAvgFlowSendingRatesRandomly =
-        thread(&FlowLinkUsageCollector::testCalAvgFlowSendingRatesRandomly, this);
+    // m_testCalAvgFlowSendingRatesRandomly =
+    //     thread(&FlowLinkUsageCollector::testCalAvgFlowSendingRatesRandomly, this);
     m_purgeThread = thread(&FlowLinkUsageCollector::purgeIdleFlows, this);
-    m_calFlowPathByQueried = thread(&FlowLinkUsageCollector::calFlowPathByQueried, this);
+    // m_calFlowPathByQueried = thread(&FlowLinkUsageCollector::calFlowPathByQueried, this);
```

Two threads no longer start: `testCalAvgFlowSendingRatesRandomly` and **`calFlowPathByQueried`**. The second one matters: it is the thread that populates `FlowInfo::flowPath`. With it disabled, `flowPath` stays empty, so **`getFlowInfoJson()`'s `"path"` array is always empty** in her build. She still *maintains* the sharded commit-path code inside `calFlowPathByQueried` (hunk `@@ -2050,14 +2225,12 @@`) — she sharded a function she then stopped running.

**[Inference]** These look like temporary bring-up toggles for a P4/bmv2 lab run, not intended semantics. But they are committed, unqualified, on `origin/main`.

### 1d. Topology-map update commented out (NOT sharding)

**[Observation]** hunk `@@ -1109,97 +1097,101 @@`, the `// 2. Update the network map` block. At `28b8b13` this ran `m_topologyAndFlowMonitor->touchEdgeFlow(...)` for ingress and egress. At `8b61cdc` the entire block is commented out behind a `// TODO`, including the `m_allPathMap.count({key.srcIP, key.dstIP})` guard.

**Behavioural effect**: edges are no longer "touched" by flow traffic, so whatever downstream logic depends on edge-flow liveness stops being fed. **[Inference]** This is very likely related to our own topology/edge work and is a **semantic decision that must not be merged silently**.

### 1e. Socket close removed from `stop()` (NOT sharding)

**[Observation]** hunk `@@ -316,11 +325,6 @@` deletes, from `stop()`:

```cpp
-    if (m_sockfd != -1)
-    {
-        ::close(m_sockfd);
-        m_sockfd = -1;
-    }
```

**[Observation]** With this removed, `stop()` proceeds straight to `m_pktRcvThread.join()`. **[Inference, needs verification]** The receive thread blocks in `recvmsg`/`poll` on `m_sockfd`; closing the socket was plausibly what unblocked it. Removing the close risks `stop()` hanging on the join, and leaks the fd. I did **not** verify the receive loop's wakeup mechanism at `8b61cdc` — **unverified**. Either way this is a shutdown-path change with no stated rationale.

### 1f. New sFlow sample type 5 parser (NOT sharding — the biggest functional addition)

**[Observation]** hunk `@@ -1214,6 +1206,138 @@` adds a 132-line `else if (sampleType == 5)` branch labelled `// Handle Custom Flow Sample (sampleType == 5)`. It parses a **fixed binary layout by hardcoded offsets** off the raw buffer:

| offset | field |
|---|---|
| +4  | `sampleLen` |
| +8 / +10 | `inputPort` / `outputPort` |
| +12 | `samplingRate` |
| +16 | `etherType` (masked `& 0xFFFF`) |
| +20 / +22 | `frameLength` / `protocol` |
| +24 / +28 | `srcIp` / `dstIp` (kept in network order, **not** `ntohl`'d) |
| +32 / +34 | `frag` / `tcpFlag` |
| +36 / +38 | `srcPort` / `dstPort` |

then advances `index += (sampleLen / 4)`.

**[Observation]** The branch contains a no-op conditional — both arms are identical:

```cpp
if (protocol != 1)
{
    key = {srcIp, dstIp, srcPort, dstPort, static_cast<uint8_t>(protocol)};
}
else
{
    key = {srcIp, dstIp, srcPort, dstPort, static_cast<uint8_t>(protocol)};
}
```

**[Inference]** This is a placeholder where ICMP (`protocol == 1`) was *meant* to populate `icmpType`/`icmpCode` — the two `FlowKey` fields that exist but are never set here. Unfinished.

**[Observation]** `stats.packetQueue.push(...)` is commented out with `// TODO` in this branch — so type-5 flows feed the *periodic* rate estimator but **not** the *immediate* one (`calAvgFlowSendingRatesImmediately` reads `packetQueue`). Type-5 flows will report `estimatedFlowSendingRateImmediately == 0`.

**[Observation]** No bounds check. The branch reads up to offset +39 without validating `sampleLen` or remaining buffer length against `len`. **[Inference]** On a malformed or truncated datagram this is an out-of-bounds read. `sampleType` is attacker-influenced in the sense that it comes off the wire.

**[Observation]** Nothing in the upstream tree *emits* sample type 5 — `git grep` for it finds only this parser. Its producer is outside this repo.

### 1g. New exported metric (NOT sharding)

**[Observation]** `include/common_types/SFlowType.hpp` adds one field to `FlowInfo` (line 211):

```cpp
uint64_t avgNonZeroHopCumulativeByteCount = 0;
```

Computed in `calAvgFlowSendingRatesPeriodically` (hunks `@@ -1292,6 +1423,13 @@` and `@@ -1301,8 +1439,22 @@`): per flow, sum `byte_count_current * currentSamplingRate` over only those hops where `byte_count_current != 0`, divide by the count of such hops; else 0. Exported as `"avg_non_zero_hop_cumulative_byte_count"` in `getFlowInfoJson()`.

**[Observation]** `git grep` across `8b61cdc` shows it is **produced and never consumed** in-tree. **[Inference]** It exists for an out-of-repo consumer (dashboard, her analysis scripts, or the Energy-Saving-App). Per the repo's own "no in-repo callers ≠ dead code" lesson, this should be asked about, not deleted.

**[Observation]** Same hunk also adds an explicit zeroing that did not exist at baseline:

```cpp
if (hopsCounter == 0)
{
    // No active hop in this interval, so explicitly clear periodic rates.
    info.estimatedFlowSendingRatePeriodically = 0;
    info.estimatedPacketSendingRatePeriodically = 0;
    continue;
}
```

At `28b8b13` the `hopsCounter == 0` branch just `continue`d, leaving the **previous interval's** rate in place — so an idle flow kept reporting its last non-zero rate forever. **This is a real staleness bug she fixed.** It is the "old data never disappears" shape the repo has hit four times.

### 1h. Metric bug fix hidden in a reindentation hunk

**[Observation]** hunk `@@ -1392,67 +1540,72 @@`, in `calAvgFlowSendingRatesImmediately`:

```cpp
-        info.estimatedPacketSendingRateImmediately = accumulatedEstimatedBytes / hopsCounter;
+            info.estimatedPacketSendingRateImmediately = accumulatedEstimatedPackets / hopsCounter;
```

The **packet** rate was being computed from **bytes**. She changed it to packets. Because the whole function was reindented one level (loop over shards), this one-token fix is buried among ~70 lines of pure whitespace churn and is very easy to lose in a conflict resolution.

### 1i. Logger timestamp precision

**[Observation]** `src/utils/Logger.cpp` line 73: pattern `[%Y-%m-%d %H:%M:%S.%e]` → `[%Y-%m-%d %H:%M:%S.%F]`. spdlog `%e` = milliseconds, `%F` = nanoseconds. **[Inference]** Consistent with profiling contended locks — you cannot see lock-hold effects at millisecond resolution. Supporting evidence that the sharding was driven by a measured performance problem.

### 1j. Topology JSON — LAG port renumber

**[Observation]** `setting/StaticNetworkTopology_ipAlias4_10_HPE_Switches_smapled_by_p4.json`, 48 changed lines, all inside `"members"` arrays of LAG objects. Port ids move: `21,22 → 25,26` (×10 each), `23,24 → 25,26` (part of the same), and one pair `→ 27,28`. Net: 6 removals each of 21/22/23/24, 10 additions each of 25/26, 2 additions each of 27/28.

**[Inference]** Physical lab re-cabling or a switch-port remap on the HPE gear. **Unrelated to sharding**; bundled in. Merges cleanly, which is exactly why it is easy to absorb without noticing that our lab's port numbering may differ.

### 1k. Misc

- `workerLoop` gains `log_thread_ids("workerLoop")`.
- A `SPDLOG_LOGGER_TRACE` of `sampleType` added at the top of the sample loop.
- Dead commented-out `SPSCQueue::push(T&&, const atomic_bool&)` overload and the `m_cv_not_full` condition-variable remnants deleted (tidy-up, no behaviour change — the CV was already unused).
- Commented-out `SO_RXQ_OVFL` getsockopt block deleted (already dead).

---

## §2 — Her intent: what she wrote vs. what I infer

### 【她寫的】— the complete written record

This is short enough to quote in full. The commit message body, `git log -1 --format=%B 8b61cdc`, is **exactly**:

```
Add sharding
```

That is the entire prose. No body, no rationale, no ticket reference.

**Code comments she added** (the only other first-person evidence):
- `// Handle Custom Flow Sample (sampleType == 5)`
- `// --- calculate average cumulative byte count across non-zero hops ---`
- `// --- AGGREGATE CUMULATIVE BYTE COUNTS ON NON-ZERO HOPS ---`
- `// --- STORE AVERAGE CUMULATIVE BYTE COUNT ACROSS NON-ZERO HOPS ---`
- `// No active hop in this interval, so explicitly clear periodic rates.`
- `"FLOW_TABLE_SHARD_COUNT must be power of two"` (static_assert message)
- Four bare `// TODO` markers: above the thread block in `start()`; above the commented-out network-map update; above the commented-out `packetQueue.push` in the type-5 branch.

**Searched and found nothing**: `git grep -il "shard" 8b61cdc` returns **only** `include/ndt_core/collection/FlowLinkUsageCollector.hpp` and `src/ndt_core/collection/FlowLinkUsageCollector.cpp`. There is **no** README, design note, or doc anywhere in the upstream tree that mentions sharding. So there is no written statement of intent beyond the word itself.

### Upstream call sites (what her change is serving)

`git grep` across `8b61cdc` for the touched API:

- `src/ndt_core/http/HttpSession.cpp:516` — `m_flowLinkUsageCollector->getFlowInfoJson().dump()`
- `src/ndt_core/http/HttpSession.cpp:575` — `getTopKFlowInfoJson(k)`
- `src/ndt_core/intent_translator/IntentTranslator.cpp:313` — `getTopKFlowInfoJson(getTopKFlowTask->k)`
- `src/ndt_core/intent_translator/IntentTranslator.cpp:416` — `getTopKFlowInfoJson(getTopKUsersTask->k)`
- `src/ndt_core/intent_translator/IntentTranslator.cpp:442` — `getFlowInfoTable()`

**[Observation]** All five are read-only consumers, and none of them changed in `8b61cdc`. The public signatures are unchanged (`getFlowInfoTable()` still returns a flat `unordered_map`, now assembled by merging shards). **So the sharding is deliberately API-transparent** — she kept the external contract identical.

**[Observation]** `avgNonZeroHopCumulativeByteCount` / `avg_non_zero_hop_cumulative_byte_count` has **no in-repo consumer**. It is written in the rate loop and emitted in JSON, and nothing upstream reads it.

### 【我的推測】— inference, clearly labelled

1. **[Inference, high confidence]** The sharding is a response to a *measured* throughput problem on the packet path. Supporting: the `%e → %F` nanosecond log-precision change in the same commit (you only need nanoseconds if you are timing lock holds); the 65 536-flow reserve target; and the fact that the one global mutex was taken with `unique_lock` on every sampled packet across all workers.

2. **[Inference, high confidence]** This commit is a **checkpoint of in-progress lab bring-up, not a finished feature.** Supporting: four bare `// TODO`s, two threads commented out rather than deleted, a dead `if/else` with identical arms, the old table and mutex left in place, and the class doc-comment not updated. Nobody writes this deliberately as a release.

3. **[Inference, high confidence]** She is bringing up a **P4/bmv2 data plane that emits a custom sFlow sample type 5**. Supporting: the target topology file is named `..._smapled_by_p4.json` and is edited in the same commit; sample type 5 is not standard sFlow; nothing in-tree emits it. The parser's fixed offsets are a contract with a P4 program we cannot see.

4. **[Inference, medium confidence]** `avgNonZeroHopCumulativeByteCount` exists for an **out-of-repo consumer** — a dashboard, an analysis script, or the Energy-Saving-App. Per this repo's own "no in-repo callers ≠ dead code" lesson, it should be asked about before being dropped. **Unverified** — I have no direct evidence of the consumer.

5. **[Inference, low confidence — explicitly uncertain]** The commented-out `touchEdgeFlow` network-map update and the disabled `calFlowPathByQueried` may have been disabled because they were *slow* (both do graph work while the packet path waits) and therefore part of the same performance push. Equally they may have been crashing or returning wrong data under P4. **I cannot distinguish these from the diff, and the difference matters a lot for merging.** This is Q2 in §5.

---

## §3 — Relationship to our side (the important part)

### 3a. What we did to this file

`git log --oneline 28b8b13..d2a609a -- src/ndt_core/collection/FlowLinkUsageCollector.cpp` returns **30** commits (the brief said 29; the extra is the merge commit `3a63ce4`). In rough theme order:

| Theme | Commits |
|---|---|
| **Concurrency correctness** | `1542f1e` lock before lookup; `0596dd1` lock `m_allPathMap`/`m_switchCountMap`; `83732d6` errno + join on throwing path; `c2cd21c` member destruction order |
| **Arithmetic correctness** | `31b357a` divide-by-zero (SIGFPE); `109690d` unsigned underflow + latched elephant flag; `c127a53` packet rate reporting bytes |
| **Parser safety** | `d704c6d` bounds-check the sFlow parser + tests |
| **Lifecycle / startup** | `a3ddd9a` bind socket in `start()`; `d79979e` idle CPU spin (`POLL_TIMEOUT_MS 0 → 100`) |
| **P4 feature work** | `6f32bca` P4 strategy pattern; `e49327a` Phase 6 destination paths; `6bc98d4` identity port mapping; `c3a1317` synthesised sFlow for bmv2 |
| **Replace-not-merge** | `eb9c860` replace destination-path maps on new snapshot; `d505b9d`/`9cd0c6b` short hop-array guards |
| **Diagnostics / hygiene** | `2979ec8`, `f5281a8`, `f103764`, `078acbe`, `2609adc`, `1859780`, `8c25dbc`, `902d1ab`, `78be6b6` |

### 3b. Same problem, or different problems? — **Both, and that is the finding**

The honest answer is not one or the other. There are three distinct categories:

#### Category A — SAME defect, fixed twice, differently (semantic adjudication required)

**A1. The unlocked `find()` race in `handlePacket`.**
- **Ours** (`1542f1e`, 2026-08-07): keep one global mutex; move `unique_lock` *above* the `find`; hold it across both branches and the TRACE diagnostic; `flowTableLock.unlock()` explicitly before the graph work. Ships `tests/test_FlowTableConcurrency.cpp` (291 lines) which fails **5 runs out of 5** against the pre-fix code.
- **Hers** (`8b61cdc`): shard the table; take the *shard's* `unique_lock` above the `find`; hold across both branches; **delete** the TRACE line entirely; use `it->second` and `emplace` instead of re-doing `operator[]`.
- **[Observation]** Both sides independently identified that the lock must precede the lookup. Her sharding **does not reintroduce** the race — she got the ordering right.
- **[Inference]** Hers is slightly better *inside the branch* (no double `operator[]` lookup, no insert-capable diagnostic). Ours is better *around* it (a test that proves it, and the graph work still runs). The ideal resolution is her body shape on our lock discipline, with our test retained.

**A2. `estimatedPacketSendingRateImmediately` computed from bytes.**
- **Ours** (`c127a53`, 2026-07-27): route both rates through `sflow::computeEstimatedRates(accumulatedEstimatedBytes * 8, accumulatedEstimatedPackets, hopsCounter)`, sharing one implementation with the periodic path; adds `tests/test_EstimatedRates.cpp`; also fixes the mislabelled debug log.
- **Hers**: one-token inline change, `accumulatedEstimatedBytes` → `accumulatedEstimatedPackets`.
- **[Observation]** Semantically identical outcome. **Ours is strictly better** (shared helper, divide-by-zero guard, test coverage).
- **Merge hazard**: her version of this line arrives inside a ~70-line pure-reindentation hunk. If the conflict is resolved by taking "theirs" for the block, we lose `computeEstimatedRates`, the `hasActiveHops` guard, and reintroduce the **SIGFPE** that `31b357a` fixed. **This is the single most dangerous hunk in the merge.**

**A3. Recursive `shared_lock` in `getTopKFlowInfoJson`.**
- **[Observation]** At `28b8b13`, `getTopKFlowInfoJson` took `shared_lock lock(m_flowInfoTableMutex)` at line 1614 and then called `getFlowInfoJson()` at line 1615, which took `shared_lock` on the *same* mutex at line 1572. Recursive shared acquisition of `std::shared_mutex` is undefined behaviour and can deadlock if a writer queues between the two.
- **Hers**: removed the outer lock (sharding forced her to, since locking moved inside `getFlowInfoJson`'s per-shard loop). Fixed as a side effect.
- **Ours**: our diff hunk `@@ -1634,8 +2125,66 @@` covers `getTopKFlowInfoJson`, but **her hunk `1611-1626` does not overlap ours** — it lands in the "clean" set. **Unverified whether we fixed this independently**; I did not trace it, and it is worth a separate check.

#### Category B — Opposite decisions on the same line (true semantic conflict)

**B1. What to do when a flow has no active hops this interval.** This is the sharpest disagreement in the whole merge.

- **Ours** (`d2a609a`, `calAvgFlowSendingRatesPeriodically`, lines 1720-1724):
```cpp
if (!rates.hasActiveHops)
{
    // No hop observed traffic this interval; leave the previous estimates
    // in place rather than dividing by zero.
    continue;
}
```
- **Hers**:
```cpp
if (hopsCounter == 0)
{
    // No active hop in this interval, so explicitly clear periodic rates.
    info.estimatedFlowSendingRatePeriodically = 0;
    info.estimatedPacketSendingRatePeriodically = 0;
    continue;
}
```

**We leave stale values. She zeroes them. Both are deliberate and commented.**

**[Observation]** Our own tree is internally inconsistent here. `calAvgFlowSendingRatesImmediately` at `d2a609a` (lines 1917-1923) **does** clear:
```cpp
if (!rates.hasActiveHops)
{
    // No activity, so clear the rates and continue
    info.estimatedFlowSendingRateImmediately = 0;
    info.estimatedPacketSendingRateImmediately = 0;
    info.isElephantFlowImmediately = false;
    continue;
}
```

**[Observation]** Our own commit `109690d` argues, about the elephant flag in the *same* function: *"the name says 'Periodically', meaning this interval"* — reasoning that supports **her** choice, not the one our periodic path currently implements.

**[Inference]** She is probably right and we are probably carrying an inherited inconsistency. A flow that stops sending should report rate 0, not its last rate forever — that is the repo's own "old data never disappears" bug shape. **But this changes what the API reports for idle flows, so it is Adam's call, not a mechanical merge.** Note it is *also* the bug that produced her new explicit-clear code, so she likely hit it in the lab.

#### Category C — Genuinely unrelated, no overlap

Her sample-type-5 parser, the LAG port renumber, the Logger precision change, the `SPSCQueue` dead-code cleanup, and `avgNonZeroHopCumulativeByteCount` address problems we never touched. Conversely, our P4 strategy work, Phase 6 destination paths, the bounds-checked parser, the idle-CPU fix, and the "replace not merge" snapshot fixes address problems she never touched.

### 3c. Hunk-by-hunk conflict classification

**Method** (so it can be re-run): `git diff 28b8b13 8b61cdc -U3` gives 21 hunks on her side; `git diff 28b8b13 d2a609a -U3` gives 42 on ours. Intersecting the **base-file** line ranges identifies which of her hunks land on lines we also changed.

**Count caveat, stated honestly**: this method yields **12** conflicting hunks, and legacy `git merge-tree 28b8b13 d2a609a 8b61cdc` independently reports **12** conflict regions in this file. The 2026-08-12 test recorded **10**. The difference is the merge algorithm (ort coalesces adjacent regions differently) and context width — not a contradiction, but do not treat "10" as exact.

| # | Her hunk (base lines) | Function | Overlaps our hunks | Verdict |
|---|---|---|---|---|
| 1 | 68-73 | ctor (shard reserve) | — | **clean** |
| 2 | 301-312 | `start()` | 291-304, 307-312 | **SEMANTIC** — she disables 2 threads; we added `openReceiveSocket()` + `m_destinationPathRefreshThread` and restructured. Direct collision on thread launches. |
| 3 | 316-326 | `stop()` | 321-326 | **SEMANTIC** — she deletes the `::close(m_sockfd)`; we added `stopAndJoinWorkers()` right there. |
| 4 | 378-398 | `SPSCQueue` | 337-426 | **mechanical** — she deletes dead commented code; we *moved the whole class* (`c2cd21c`). Textually large, semantically trivial: her deletions are of code that is already dead. |
| 5 | 404-424 | `SPSCQueue` | 337-426 | **mechanical** — same as #4. |
| 6 | 636-641 | `workerLoop` (log_thread_ids) | — | **clean** |
| 7 | 708-713 | `handlePacket` (TRACE sampleType) | 704-712 | **mechanical** — adjacent logging additions. |
| 8 | **1109-1205** | `handlePacket` flow-table update | 1109-1118, 1146-1152, 1172-1185 | **SEMANTIC, highest value** — this is A1 (both fixed the race) *plus* her commented-out `touchEdgeFlow` block. Biggest hunk (97 base lines) and needs a line-by-line merge, not a side pick. |
| 9 | 1214-1219 | sample-type-5 insertion point | — | **clean** — pure addition. But see §4: it lands next to our bounds-checking work. |
| 10 | 1238-1255 | `calAvgFlowSendingRatesPeriodically` head | 1238-1243 | **mechanical** — she adds a blank line; we added loop-scoped state (`lastSockOvfl`, `announcedHealthy`). |
| 11 | 1292-1297 | non-zero-hop aggregation | — | **clean** — pure addition, but sits *inside* the loop our `109690d` rewrote. Applies cleanly; verify it still compiles against `counterDelta`. |
| 12 | **1301-1308** | `hopsCounter == 0` | 1301-1328 | **SEMANTIC** — this is **B1**, the clear-vs-leave contradiction. Must be adjudicated. |
| 13 | 1333-1338 | TRACE of new metric | — | **clean** |
| 14 | 1367-1379 | dead `SO_RXQ_OVFL` block | 1374-1390 | **mechanical** — she deletes already-dead code; we rewrote the drop-counter logging next to it. |
| 15 | **1392-1458** | `calAvgFlowSendingRatesImmediately` | 1424-1430, 1433-1439, 1444-1458 | **SEMANTIC, most dangerous** — this is **A2**. ~70 lines of her reindentation wrapping a one-token real fix, colliding with our `computeEstimatedRates` refactor. Taking "theirs" silently reverts `c127a53` **and** `31b357a`'s SIGFPE guard. |
| 16 | 1509-1558 | `purgeIdleFlows` | — | **clean** |
| 17 | 1562-1607 | `getFlowInfoTable` / `getFlowInfoJson` | — | **clean** |
| 18 | 1611-1626 | `getTopKFlowInfoJson` | — | **clean** — but this is A3; confirm we did not fix the recursive lock differently elsewhere. |
| 19 | 1930-1945 | `calFlowPathByQueried` key snapshot | 1926-1931, 1945-1950 | **SEMANTIC** — she shards the snapshot; we changed this function for Phase 6. And she disabled the thread that runs it. |
| 20 | 2050-2063 | `calFlowPathByQueried` commit | 2061-2066 | **SEMANTIC** — same function, both sides edited the commit-under-lock block. |
| 21 | 2065-2068 | end of file (new shard helpers) | 2061-2066 | **mechanical** — her three new functions appended at EOF; we appended there too. Pure placement. |

**Summary: 9 clean, 5 mechanical, 7 semantic.** The seven semantic ones are #2, #3, #8, #12, #15, #19, #20. Of those, **#8, #12 and #15 are the ones that can silently undo our fixes.**

---

## §4 — What breaks if her change is applied to our tree

### 4a. Fixes of ours that a careless resolution would revert

| Our fix | How her commit could undo it | Severity |
|---|---|---|
| `31b357a` divide-by-zero (SIGFPE) | Hunk #15 replaces the whole `Immediately` block with her reindented version, which has no `computeEstimatedRates` / `hasActiveHops`. Taking "theirs" restores `/ hopsCounter` on a raw int. **Process death, not a wrong number.** | **Critical** |
| `c127a53` packet-rate-from-bytes | Same hunk. Her inline fix is equivalent, so the *value* survives, but the shared helper and its tests do not. | Medium |
| `109690d` unsigned underflow + latched elephant flag | Her hunks #11/#12 land inside the same loop. Her code does not use `counterDelta`; if her block is taken wholesale over ours, the `counterDelta` call sites revert to bare subtraction. Our own commit message flags that a mutation restoring bare subtraction **would not be caught by our tests**, because those call sites run on a thread started by `start()`. | **High — and untested** |
| `1542f1e` lock before lookup | Hunk #8. Her version *also* fixes it, so "take theirs" is safe on this axis. But it deletes the TRACE diagnostic and drags in the commented-out `touchEdgeFlow`. | Low on the race, high on side effects |
| `d79979e` idle CPU spin | Not in a conflicting hunk — **survives**. Confirmed: upstream still has `POLL_TIMEOUT_MS = 0` at `8b61cdc` line 508; ours is `100` at line 777. | Safe |
| `d704c6d` bounds-checked parser | Her sample-type-5 branch is a **new, unbounded** parser added *alongside* our hardened one. Not a revert — a **hole opened next to the patched one**. | **High** |
| `eb9c860` / `d505b9d` / `9cd0c6b` replace-not-merge, short hop arrays | No overlap — survive. | Safe |
| `a3ddd9a` bind socket in `start()` | Hunks #2/#3 collide with our `start()`/`stop()` restructure, but her edits are removals; our `openReceiveSocket()` is elsewhere in the hunk. | Medium (merge care) |

### 4b. Does her sharding bypass or reintroduce our fixes?

**[Observation] It does not reintroduce the `handlePacket` race** — she moved the lock above the `find` exactly as we did.

**[Observation] It does bypass one guard structurally.** Our `1542f1e` comment says the lock is *"released explicitly before the graph work below ... the graph locks must not nest under this one."* Her version does not need that discipline because she **commented the graph work out entirely**. If the graph work is ever restored on top of her sharded code, the lock-nesting hazard our comment warns about returns with no comment left to warn about it. **[Inference]** This is how a documented trap gets un-documented by a refactor.

**[Observation] Her sharding weakens one invariant we may rely on: cross-flow atomicity.** At `28b8b13` and at `d2a609a`, a single mutex means `getFlowInfoTable()` and the periodic rate loop see a **globally consistent snapshot** of all flows. With 1024 shards, `getFlowInfoTable()` locks and copies shards one at a time (`.cpp` lines 1725-1728), so the returned map can contain flow A as of time T and flow B as of time T+ε. Likewise `calAvgFlowSendingRatesPeriodically` now walks shard by shard, so the "1 second interval" is no longer simultaneous across flows.

**[Inference]** For rate estimation this is almost certainly fine (the flows are independent). But `IntentTranslator.cpp:442` consumes `getFlowInfoTable()` for top-K / user ranking, and a **torn snapshot** could rank flows measured microseconds apart. Probably benign, **unverified** — I did not read the IntentTranslator consumer closely enough to rule out an ordering assumption.

**[Observation → self-correction] `purgeIdleFlows` scan/erase gap is NOT new.** Hers computes `now` once, then per shard builds a `toRemove` list under a shared lock and erases under a unique lock, releasing between the two. I initially read this as a new lost-update window. It is not: the base at `28b8b13` also released the shared lock before taking the unique lock for the erase. **Pre-existing, not introduced.** Recording the correction rather than the first reading.

### 4c. Could our fixes break her sharding?

**[Observation]** Our `109690d` added `sflow::counterDelta` and our `c127a53`/`31b357a` added `sflow::computeEstimatedRates`, both in `include/common_types/SFlowType.hpp`. Her commit adds a field to the **same struct** in the **same header**. `merge-tree` lists that file as `changed in both`, but her single-line field addition is far from our helpers, so it merges — the 2026-08-12 test agrees (it auto-merged).

**[Observation]** Nothing in our fixes touches flow *identity* (`FlowKey`, `FlowKeyHash`), so nothing of ours can misroute a key to the wrong shard. **Her sharding is safe from our side.**

**[Inference]** The one real risk in that direction: if we later change `FlowKeyHash` to include `icmpType`/`icmpCode` — which `902d1ab` ("Warn that fixing VLAN on one side of the classifier key breaks the other") suggests is live territory — every existing key would move shards. Harmless with an empty table at startup, but **anything caching a shard reference across a hash change would break**. Nothing does today.

### 4d. New defects her commit would introduce

1. **Unbounded read in the sample-type-5 parser** — no validation of `sampleLen` or remaining buffer against `len` before reading offsets up to +39. Directly against the grain of `d704c6d`. **This should block the merge of that branch as-is.**
2. **`stop()` no longer closes the socket** — leaks the fd across a stop/start cycle. On our tree the receive thread still exits (our `POLL_TIMEOUT_MS = 100` rechecks `m_running`), so it will not hang; on hers it only worked because of the 0 ms busy-spin. **[Inference]** Her removal was probably a real double-close fix (base closed in both `stop()` and at the end of `run()`), but the correct fix is to close in exactly one place, not to delete one of two.
3. **Type-5 flows never populate `packetQueue`** (commented out), so their `estimatedFlowSendingRateImmediately` is permanently 0 while the periodic rate works. A silently half-populated API.
4. **`flowPath` always empty** while `calFlowPathByQueried` is disabled — `"path": []` for every flow.
5. **Dead `m_flowInfoTable` / `m_flowInfoTableMutex` and a stale class doc-comment** describing the pre-sharding design.

---

## §5 — Three questions for patty

### Q1. What emits sFlow sample type 5, and where is its wire format specified?

*Ask concretely: which P4 program or switch firmware produces it, and is the byte layout in your parser (inputPort at +8, samplingRate at +12, srcIp at +24 in network order, …) written down anywhere, or was it inferred from captures?*

**Why it matters:** This is the only part of the commit we **cannot merge safely without her**. It is 132 lines of fixed-offset binary parsing against a producer that does not exist in this repo, with no bounds checking, on the network-facing path. We have already hardened the standard parser (`d704c6d`); merging an unvalidated sibling reopens exactly that class of bug. And if the format was inferred from captures rather than specified, the decision changes from "review it" to "do not take it until the P4 side is pinned down." It also tells us whether her whole branch presumes a data plane we do not run.

### Q2. Were `calFlowPathByQueried`, `testCalAvgFlowSendingRatesRandomly` and the `touchEdgeFlow` network-map update disabled temporarily for a lab run, or because they were wrong or too slow?

*Ask concretely: the four `// TODO`s — are those "re-enable before merge", or "this is broken under P4"?*

**Why it matters:** This flips the merge strategy by itself. If they were temporary bring-up toggles, we simply **do not take** those hunks and the conflict shrinks a lot. If they were disabled because they misbehave under P4 or cost too much on the hot path, then she has found something in code we actively developed — `calFlowPathByQueried` is where our Phase 6 destination-path work lives (`e49327a`), and we still run that thread. We would be re-enabling something she switched off for a reason we never learned. It also decides whether `"path": []` is a bug or her intended current state.

### Q3. For a flow with no active hop in an interval, should the periodic rates be zeroed or should the previous interval's value stand?

*Ask concretely: your `hopsCounter == 0` branch now sets `estimatedFlowSendingRatePeriodically = 0`; ours leaves the previous value. Did you change that because you saw idle flows reporting stale rates in the lab?*

**Why it matters:** This is the one place where the two sides made **opposite, deliberate, commented decisions on the same line**, so no mechanical resolution is defensible — someone has to choose. It is also the question most likely to reveal a bug we still have: our `Immediately` path already zeroes, our `Periodically` path does not, and our own `109690d` reasoning ("the name says *Periodically*, meaning this interval") argues for **her** behaviour. If she says she changed it because she watched idle flows report stale rates, that is a live defect on our tree that our tests do not catch. And because both sides' rate values feed the top-K ranking the API exposes, getting it wrong is visible to every consumer.

---

## Appendix — commands to reproduce

Run from a worktree reset to `d2a609a`:

- `git merge-base d2a609a 8b61cdc` → `28b8b133cd8835a58d52a8f3b4864672c3dd02f1`
- `git log -1 --format=%B 8b61cdc` → `Add sharding` (that is all of it)
- `git show 8b61cdc --stat --name-only` → 5 files, including the topology JSON
- `git grep -il "shard" 8b61cdc` → only the `.hpp` and `.cpp`; no docs
- `git grep -n "getFlowInfoTable\|getTopKFlowInfoJson" 8b61cdc` → upstream consumers
- `git log --oneline 28b8b13..d2a609a -- src/ndt_core/collection/FlowLinkUsageCollector.cpp` → 30 commits
- `git merge-tree 28b8b13 d2a609a 8b61cdc` → read-only; 12 conflict regions in the `.cpp`

Hunk-overlap classification (§3c) came from intersecting base-file line ranges of
`git diff 28b8b13 8b61cdc -U3` (21 hunks) against `git diff 28b8b13 d2a609a -U3` (42 hunks).

**No merge, rebase, cherry-pick, push, or file modification was performed on the repository.
The worktree was reset to `d2a609a` at the start and left there. Only this report was written.**
