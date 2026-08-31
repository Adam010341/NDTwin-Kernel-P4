---
name: phase2-round-2026-08-19
description: DeepSeek 盲寫計畫 + Claude 執行的兩階段輪次；12 個實驗跑完 11 個半，10 CONFIRMED / 6 REFUTED，全文在 scratch/phase2/FINDINGS.md
metadata: 
  node_type: memory
  type: project
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-19T04:20:55.238Z
---

**全文在 `scratch/phase2/`**：`PLAN.md`（DeepSeek 寫，698 行、12 個實驗）、
`FINDINGS.md`（兩個執行者接力，1717 行）。這裡只放不會重新推導出來的判斷。

## 這輪的設計（Adam 2026-08-18 裁定）

兩階段：① DeepSeek v4 pro **盲寫**測試計畫（讀 repo，但今天的發現被移出 repo）
② Claude subagent 當苦力執行。**藏的只有當天未 commit 的那輪**——已 commit 的
`doc/audit/` 是專案知識，任何 reviewer 都會看到，藏它只會讓 DeepSeek 重新規劃已定案的東西。

盲寫確實有效：**E1/E3/E5/E11/E12 是前兩輪完全沒碰過的地面**，只有 E4（鎖沒有 owner）
與 round-2 的 F-11 重複。

## 結果總覽

**10 CONFIRMED / 6 REFUTED**，其中最重要的三條：

1. **E2 → 獨立記憶 [[power-on-reports-success-without-acting]]**（示範時最可能發作）
2. **E6 反轉了計畫的預設**：計畫預期「OVS 乾淨、P4 有缺陷」。實測相反——
   缺 `ip_proto` 的 `tcp_dst` 規則在 **OVS 上 kernel 200、Ryu 200、兩邊 log 零錯誤行、
   規則從沒到達交換機、還以幽靈之姿留在 `get_switch_openflow_table_entries`**；
   **P4 兩種變體都誠實回 400**。幽靈兩個平面都有，P4 上實測 7.2–8.2 秒。
   （OF 1.3 match 前提條件：`tcp_dst` 需要 `ip_proto`，補上就立刻裝上。）
3. **E9 判 REFUTED 但撞到本分支自己造成的缺陷**：top-k 的
   `_in_the_proceeding_1sec_timeslot` 在沒流量時**沿用舊值**，而 `_in_the_last_sec` **歸零**，
   top-k 偏偏用沿用的那個排序 → 流量停止後 5 秒、10 秒還在送**位元相同**的 20.3 Mbps。
   `git blame` 追到 `31b357a6`＝**分支 `fix/flow-rate-divide-by-zero` 的主題**。
   除零的修法引入了這個不對稱。

**REFUTED 的價值一樣高**：DeepSeek 最懷疑的 E1（OVS 電源循環後流表沒重裝）**是錯的**——
t=+10s 流表完整、5/5 ping 通、`twin_audit` 零矛盾。E8、E11 也正常。

## 兩個執行者都更正了自己差點發表的錯

- E8：2 秒取樣說「從不過度回報」、0.25 秒說「整段都過度回報」，**兩個都不是答案**——
  `handleLinkFailure` 一律標雙向 down，只有 **30 秒**的 topology poll 修正，
  所以窗口是 **0–30 秒取決於相位**。OVS 那輪的 13 秒是一次抽樣，不是 OVS 的性質。
- E6 的探針 bug 差點產出「被接受的規則不會進快取」這個假發現。

## 潛伏、未觸發（讀碼）

`getTopKFlowInfoJson` 持有 `m_flowInfoTableMutex` 的 `shared_lock` 後又呼叫
`getFlowInfoJson`，後者再拿一次 → writer-preferring rwlock 下是 UB／會死鎖。本輪沒卡住。

## 未跑

E10（Energy app）被環境擋住：`/mnt/nfs/app` 不是掛載點、app binary 沒建。

相關：[[live-round-2026-08-18-two-passes]]、[[rejected-requests-can-still-act]]、
[[single-flow-precision-gap]]、[[ryu-flow-stats-wedge]]、[[subagent-operating-constraints]]。
