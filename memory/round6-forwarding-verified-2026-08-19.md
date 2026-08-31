---
name: round6-forwarding-verified-2026-08-19
description: 覆蓋率驅動的第六輪終於驗證了產品的中心宣稱——透過 kernel API 裝規則「真的」改變轉發，兩個平面都是；但 P4 上 install-then-delete 會把目的地打成黑洞
metadata: 
  node_type: memory
  type: project
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-19T09:27:44.388Z
---

**全文 `scratch/round6/FINDINGS-round6.md`（977 行）。** 這輪是**覆蓋率驅動**而非假設驅動——
不問模型要假設，而是列舉「從沒被呼叫過的表面」。理由見 [[model-hypotheses-saturated]]。

## 🔑 產品的中心宣稱，第一次被驗證

**「透過 kernel API 裝上的流規則會不會真的改變轉發？」——四輪測試從來沒驗證過。**
先前每次都只檢查 API 回應、kernel 快取、或交換機表，**從來不是「封包真的走了新的路」**。

**答案：兩個平面都會。** 用 `/proc/net/dev` 的 tx-byte 差（獨立於孿生與交換機表）、
規則強迫走**另一個**埠、三個狀態（裝前／裝後／刪後）、定速流所以整批流量必須移動：

| 平面 | 裝前 | 裝後 | 刪後 |
|---|---|---|---|
| OVS 128-host | 100% 走 s1-eth2 | **100% 走 s1-eth1** | 回到 s1-eth2（路徑會回來） |
| P4 bmv2 | 100% 走 s1-eth2 | **100% 走 s1-eth1** | 🔴 **黑洞**，ping 100% loss |

**位元對位元的同一個量**，不是比例。資料面切換是次秒級；**孿生的 `path` 約 3–5 秒跟上**。

⚠️ **`get_path_switch_count` 看不到路徑改變**（OVS 三個狀態都回 5）——
有鑑別力的欄位是 `get_detected_flow_data` 裡的 `path`。量路徑變化別用前者。

## 五條新確認的缺陷

1. 🔴 **P4 上 install 然後 delete 會把目的地打成黑洞。** `ipv4_lpm` 每個 prefix 只有一筆，
   所以 install **覆寫**了控制面的路由，delete 又把它撤掉。
   **一個會自己清理的 app 會殺掉連線。** 同樣兩個呼叫在 OVS 上是安全的。
   proxy 自己的註解（`api_routes.py:190-204`）講了前提但漏了後果。
2. 🔴 **`modify_flow_entry` 忽略 `priority`。** `modifyAnEntry` 設了 `body["priority"]`
   卻永遠送**非 strict** 的 `/stats/flowentry/modify`；同一個檔案 40 行之外的
   `deleteAnEntry` 有 priority 時就正確地送 `delete_strict`。
   實測：改我自己的 priority-100 規則，結果**改到 router 的 priority-10 規則**
   （同一條——`duration`/`n_packets` 沒變），搬了 32 MB，
   **而且刪掉我自己的規則之後傷害還在。**（我親自 grep 驗證過這個不對稱。）
3. 🔴 **電源循環會失去 bridge 的 sFlow 紀錄**（A/B 實測，n=2）。
   s3→s8 鏈路在**實際承載 103 Mbps 時讀值恰好 0 bps**，補回紀錄後讀到 106–148 Mbps。
   ⚠️ 機制比預測的窄：**去樣本化的交換機是「進來的邊」變暗，不是出去的邊。**
4. 🟠 **重複的 GET 可以把死掉的交換機維持在「up」。** 3.3 Hz 的 `inform_switch_entered`
   迴圈讓一台沒有 bridge 的交換機在 60 個取樣裡有 47 個是 `up=True, en=True`，連續約 15 秒。
   **單次呼叫的窗口 ≤770 ms**，所以要靠重複才看得到（人手動點不出來，但重試邏輯會）。
5. 🟠 **`modify_nickname` 會改寫版控裡的拓撲檔**並重排所有 key——**7,996 行變動、語意完全相同**。
   是在收尾時讀 `git status` 發現的。證據留在 `scratch/round6/topology-as-rewritten-by-kernel.json`。

**批次端點**：`accepted` 數的是**已入佇列**不是已套用；承諾的 per-entry log
**P4 有、OVS 沒有**（新鮮 grep：0 命中）——把 B-1 延伸到批次動詞與**壞的 actions**。
幽靈窗口在批次路徑上量到 5.27–5.70 秒。

## 三條對既有文件的更正（重要）

- **這個拓撲是 32 條交換機間鏈路 / 288 條邊**，不是 40。（40 是 4-host cell 的數字。）
- **電源循環的 qdisc 遺失在這裡是 2 個介面**不是 4——另兩個面向 10 G 核心鏈路，
  **Mininet 從來沒整形過它們**（見 [[ovs-testbed-bandwidth-reality]]）。
- 🔑 **`up=false, en=true` 是關機交換機的正常穩態。**
  所以**「兩個旗標不一致」本身不能當故障訊號**。這收窄了 A-2 指紋的適用範圍。

## 它自己攔下的兩個差點發表的錯

- 電源開機後 power report「卡在 0」→ 其實是 10 秒的刷新週期
- 幽靈規則偵測器沒有 priority 過濾 → 差點把 router 自己的規則判成永久幽靈

**CLEAN／REFUTED**：E-H3（8 種畸形 dpid 全部正確拒絕、graph diff 空）、批次混合 dpid 的誠實度、
`get_openflow_capacity`、`get_static_topology_json`。
**INDETERMINATE**：E-H2——A-2 的 wedge 在約 50 分鐘、兩次 Ryu 啟動裡都沒發作。

相關：[[phase2-round-2026-08-19]]、[[replace-vs-add-bug-shape]]、
[[rejected-requests-can-still-act]]、[[model-hypotheses-saturated]]。
