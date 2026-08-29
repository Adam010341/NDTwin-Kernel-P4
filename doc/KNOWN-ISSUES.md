# NDTwin — 已知未修缺陷

**缺陷清單的普查基準日：2026-08-19**　　涵蓋到 kernel `04b8933`＋分支 `fix/flow-rate-divide-by-zero`

**2026-08-29 增補（只動了兩處，其餘條目仍是 08-19 的普查結果、未重驗）**：
① **§F 新增 `F-bmv2`** —— 08-28/29 四張工單（②封包大小／①＋①b build 比值／③流數）收案後的
實測天花板，並退役 §F 舊的無出處數字；
② **§D 的 F-17 標記為「前提已被推翻、待重裁」**（更正全文在 §C 表下）。

🔴 **引用本文件任何舊條目前務必重查現況** —— 實測衰減**不均勻**（見文末〈完整性邊界〉：
agy Tier 1 六條全修、Tier 2 十三條還在十一條）。**清單上寫著的不等於今天還在。**

📌 **已登記的待辦：把整份文件依四張工單重排。**
Adam 2026-08-29 裁定**延後**，理由是當時三個 session 在同一個 worktree 上寫，
大範圍重排的合併風險不成比例。**觸發條件＝poster 定稿。**
本輪交付的是有界版（新增 §F-bmv2 ＋ 退役 §F 舊數字 ＋ F-17 的兩次更正），
**排序軸仍是原本的「示範或正常操作會不會踩到」，沒有改。**

這份文件的排序軸是**「示範或正常操作會不會踩到」**，不是嚴重度。一個會靜默給出錯誤數字
的缺陷可能永遠不會在台上發作，而一個只是外觀問題的缺陷可能第一分鐘就出現。

每一條都標了**失效方向**，這比嚴重度標籤有用：

- **樂觀** = 壞掉時說健康（twin 最危險的方向，因為抓故障就是它存在的理由）
- **悲觀** = 健康時說壞掉
- **靜默** = 兩邊都沒有記錄

證據檔在 `doc/audit/<日期>_<主題>/`。標「實測」的是跑出來的，標「讀碼」的是推論。

---

## A. 正常操作就會發作 —— 示範前務必知道

### A-1 🔴 關機後馬上開機 = 回報成功但什麼都沒做

- **狀態**：OPEN。**報告前不改碼，用操作繞過**（2026-08-19 裁定）
- **平面**：P4
- **失效方向**：樂觀 ＋ 靜默
- **會發生什麼**：`POST /ndt/set_switches_power_state?action=on` 回 **200 `{"Success"}`、0.01 秒**，
  bmv2 行程數不動、沒有 readopt、交換機**永久維持死亡**。同時 `power=ON`、`is_up=True`、
  8/8 邊 up、**100% 封包遺失**。
- **機制**：`powerOff` 標 vertex down → 約 1 秒後 1 Hz liveness worker 在死掉的交換機上把它
  **翻回 up**（`p4LivenessFor` 對 2 秒內的舊 `probe_ok` 回 Up，之後在 LLDP beacon 未超過
  `kLldpFreshSeconds = 12` 前回 Unknown）→ `P4PowerStrategy::powerOn:45-50` 第一行：
  ```cpp
  if (topoMonitor->getVertexIsUp(node))
  {
      // Already up: nothing to do, and reporting success is accurate.
      return OpResult::success();
  }
  ```
  那句「reporting success is accurate」在 vertex 說謊時不成立。檔案自己的註解預測過這會發生在
  **重試**上；實際上**第一次呼叫**就會。
- **窗口**：關機後約 **10 秒**
- **🔑 繞法（零成本）**：**關機後等 15 秒再開機**，或先確認 `get_graph_data` 的
  `is_up=false` 再送 `action=on`
- **為什麼排第一**：人手動示範「關掉再打開」就是幾秒內完成，**正好落在窗口裡**，
  而電源管理是 Phase 7 的招牌功能
- **證據**：實測，`scratch/phase2/FINDINGS.md` E2。用有鑑別力的第二次呼叫證明——
  graph 沉澱到 `is_up=false` 後送**完全相同**的 POST，花 1.27 秒、行程 9→10、轉發全復原

### A-2 🔴 topology poll 可以永久阻塞，而且沒有任何東西會發現

- **狀態**：OPEN
- **平面**：OVS（機制在 kernel，P4 走不同路徑）
- **失效方向**：悲觀 ＋ 靜默（**零 log**）
- **會發生什麼**：twin 顯示**全部 40 條 link down、10 台交換機 `enabled=false`**，
  而 fabric 一路正常轉發（0% 遺失）。**不重啟永遠不會恢復。**
- **機制**：`pollControlPlaneTopology` 經 `utils::execCommand`
  （`include/utils/Utils.hpp:543-568`）呼叫 curl——**裸 `popen()` 沒有 timeout，
  curl 也沒有 `--max-time`**。一個沒反應的 controller 就能讓那條執行緒死到行程結束：
  沒有重試、沒有 watchdog、**一行 log 都沒有**。
  實測抓到一個 curl 子行程**活了 733 秒**，跟 kernel 同一秒啟動，是它嘗試的第一次 poll。
  兄弟路徑 `fetchOpenFlowTablesInternal` 有 0.5 秒的可疑門檻並會警告；這條什麼都沒有。
- **Ryu 那端**：`intelligent_router.py:304` 的 `get_link()` 永久阻塞。
  兄弟 `get_switch`（`:284-288`）有 20 秒有界重試，**`get_link` 沒有**。
  三個 `/v1.0/topology/*` 全回 HTTP 000，而**同一個行程**的
  `/ryu_server/all_destination_paths` 在 0.2 ms 內回答——**「Ryu 還活著」不能當證據**。
- **指紋**：`up=true, enabled=false` 在實務上就是「liveness 跑了、poll 沒跑」的指紋。
  ⚠️ **但機制敘述要精確**：`isEnabled` 有**三個**寫入者，不是一個——
  ① topology poll（`TopologyAndFlowMonitor.cpp:566/648/688/728/863` 設 true）
  ② `inform_switch_entered` 經 `setVertexEnable()`（`HttpSession.cpp:1173`）
  ③ 1 Hz liveness worker 在 ping 不通時 `setVertexDisable()`
  （`DeviceConfigurationAndPowerManager.cpp:694-695`）
  所以這個指紋成立需要**兩個條件同時滿足**：poll 卡住**而且** `inform_switch_entered` 也沒送到。
  觀察到的那次兩者都成立（Ryu wedge 了所以它也沒推），結論沒錯但推導不完整。
  最初的「poll 是唯一寫入者」是 `grep 'isEnabled = '` 漏掉 setter 造成的
  （見 memory `grep-endpoints-misses-concatenation`）。
- **🔑 繞法（一行檢查，建議寫進 runbook）**：
  ```bash
  curl -s -o /dev/null --max-time 3 -w '%{http_code}\n' http://localhost:8080/v1.0/topology/switches
  ```
  回 `000` 就是卡住了，**而且 kernel 必須在 Ryu 之後重啟**
- **證據**：實測，`scratch/phase2/FINDINGS.md` PRIORITY 節。Adam 自己在 Visualizer 看到
  `enable: no, status: up` 而觸發的調查

### A-3 流量停止後 top-k 還在報舊速率約 15 秒

- **狀態**：🟢 **RESOLVED（2026-08-20，`aabe605`）。2026-08-28 讀碼確認並更正本條目。**
  這個條目在修好之後仍被標成 OPEN 過 8 天，期間還被編輯過，**沒有人回頭改狀態**。
- **平面**：兩者
- **失效方向**（當時）：樂觀（顯示不存在的負載）
- **曾經發生什麼**：iperf3 結束後 5 秒、10 秒，top-k 還在送**位元完全相同**的
  20.3 Mbps / 10496 pps，同一個物件裡的 `_in_the_last_sec` 卻是 `0`
- **機制**：`31b357a6`（2026-07-27）的除零守衛改成 `continue` 而**沒有清除**，
  於是 `estimated_*_in_the_proceeding_1sec_timeslot` 沿用舊值；
  `getTopKFlowInfoJson` 正好用那個欄位排序（現行 `FlowLinkUsageCollector.cpp:2339-2344`）。
- **修法**：`aabe605` 把清除加回來（現行 `:1911-1913`），並在原地留下為什麼的說明：
  ```cpp
  if (!rates.hasActiveHops)
  {
      // ... the divide-by-zero is already prevented by `hasActiveHops` itself, and
      // writing 0 divides by nothing. What to report *after* the guard was a separate
      // choice, and carrying the old value forward was the wrong one.
      info.estimatedFlowSendingRatePeriodically = 0;
      info.estimatedPacketSendingRatePeriodically = 0;
      info.isElephantFlowPeriodically = false;
      continue;
  }
  ```
- 🔴 **分支歸屬更正（2026-08-28）。** 本條目原本被引用來支持
  「**baseline 保留陳舊速率、本分支歸零**」——**那是反的**。
  `origin/main` 的對應處一直都清除，逐字為：
  ```cpp
  if (hopsCounter == 0)
  {
      // No active hop in this interval, so explicitly clear periodic rates.
      info.estimatedFlowSendingRatePeriodically = 0;
      info.estimatedPacketSendingRatePeriodically = 0;
      continue;
  }
  ```
  （`git show origin/main:src/ndt_core/collection/FlowLinkUsageCollector.cpp` 的 1453-1459 行）
  且兩邊的判準等價：`computeEstimatedRates` 在 `hopsCounter <= 0` 時回
  `hasActiveHops == false`（`include/common_types/SFlowType.hpp:446-449`）。
  ⇒ **保留是本分支自己引入、又自己修掉的，從來不是 baseline 的性質。**
  受影響的下游見 `doc/audit/2026-08-27_flow-table-idle-tail/NEXT.md` 的更正段。
- ⚠️ **仍然開著的殘留屬於 B-x，不屬於這裡**：修好之後死流的速率是 **0**，
  但那條流**還是會被列出來 15 秒**。「報舊速率」已修，「還在名單上」沒修。
- 📌 本條目原先引的行號 `:1773-1778`／`:2167-2172` 實際指向 rate-loop 的除錯日誌與
  immediate 路徑的 elephant 旗標，**都不是它描述的東西**。行號會腐爛，引用前要重查。
- **證據**：當時實測 `scratch/phase2/FINDINGS.md` E9；本次更正為讀碼，未重跑

### A-4 OVS 4-host cell 完全沒有遙測

- **狀態**：OPEN（**環境／拓撲問題，不是 kernel 缺陷**）
- **平面**：OVS，**只有 4-host cell**
- **失效方向**：靜默（0 與「閒置」無法區分）
- **會發生什麼**：實測 50.00 Mbps 負載下，`get_detected_flow_data` 回 `[]`、
  所有邊 `link_bandwidth_usage_bps = 0`、`get_average_link_usage` 回 `0.0`
  且 `"status":"success"`。同一顆 kernel 在 P4 上報 2 條流、55.8 Mbps。
- **機制**：`tools/test_workflow/ovs_4host_topo.py`（178 行，全讀過）**沒有任何 sFlow 設定**。
  兩個平面的遙測都只從 UDP 6343 的 sFlow datagram 來。
- **⚠️ 128-host 拓撲有設定**（`testbed_topo.py` 的 `enable_sflow`），實測正常——
  見 `doc/audit/2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md`
- **🔑 繞法**：**示範遙測一律用 128-host 拓撲**
- **證據**：實測，`scratch/phase2/FINDINGS.md` E7A/E7B

#### A-4b ⚠️ 推論：Energy-Saving-App 在這座 cell 上會把交換機關光且不會恢復

**這是讀碼推論，尚未實測**——E10 被環境擋住（`/mnt/nfs/app` 不是掛載點、app binary 沒建），
所以沒有人真的跑過。但如果要在 4-host cell 上示範節能，這條必須先驗證。

決策路徑（`Energy-Saving-App/src/app/energy_saving_app.cpp:911-928`）：

```cpp
std::optional<double> avgLinkUtilization = group_avg_link_utilization(g, group);
if(!avgLinkUtilization.has_value()){ continue; }        // 群組裡沒有 up+enabled 的邊 → 不動
if(*avgLinkUtilization <= LOW_WATER_MARK){              // 0.40
    easy_disable_switch(g, json2sim, group);
}else if(*avgLinkUtilization >= HIGH_WATER_MARK){       // 0.60
    easy_enable_switch(g, json2sim, group);
}
```

`nullopt` 的條件是**邊的狀態**，不是流量為零。4-host cell 上邊是 up+enabled 的（40/40），
所以函式回傳 **0.0** 而不是 nullopt → `0.0 <= 0.40` 成立 → **關機觸發**。
而利用率永遠碰不到 0.60（完全沒有遙測），所以**永遠不會再開回來**。

**預期行為是單調關機直到沒得關，不是「不動作」。**

⚠️ **不要把這條跟 F-17 混為一談**：F-17 是 kernel 端 `get_average_link_usage`
只平均忙碌鏈路；這條走的是 app 自己的 `group_avg_link_utilization`，從 graph 資料算，
兩者是不同的函式。

📌 那個 `!has_value()` 分支的註解記著一個**已修**的除零：邊數為 0 時算出 `inf`，
而 `inf >= HIGH_WATER_MARK` 會把整組**開回來**。同一個地方已經踩過一次。

### A-4c 🔴 P4 proxy 重啟會靜默摧毀 bring-up 以來安裝的每一條規則

- **狀態**：OPEN。**round 4 新發現**
- **平面**：P4
- **失效方向**：樂觀 ＋ **零警告**
- **會發生什麼**：重啟 P4 proxy（**bmv2 沒有重啟**）之後，bring-up 以來安裝的**每一條規則都消失**，
  而 twin 回報**完整健康恢復**：40/40 邊、10/10 up、**一行警告都沒有**
- **為什麼排在 A 節**：不需要注入任何故障。**重啟 proxy 是正常運維動作**——除錯、改設定、
  升級都會做。而且 twin 事後看起來完全正常，所以沒有人會知道規則不見了
- **驗證方式**：用 P4Runtime 直接讀真實交換機表比對，不是看 kernel 快取
- **證據**：實測，`scratch/round4/FINDINGS-round4.md` 實驗 4「Bug D」

### A-4d 🔴 P4 上「裝一條規則然後刪掉」會把目的地打成黑洞

- **狀態**：OPEN。**round 6 新發現**
- **平面**：P4（**OVS 上同樣兩個呼叫是安全的**）
- **失效方向**：災難性但**吵**（ping 100% loss，看得出來）
- **會發生什麼**：`install_flow_entry` 然後 `delete_flow_entry` 同一條 → **目的地完全不通**。
  實測 tx 計數器：裝上後 100% 流量移到新埠，刪掉後 **0 MB、ping 100% 遺失**
- **機制**：`ipv4_lpm` **每個 prefix 只有一筆**，所以 install **覆寫**了控制面的路由，
  delete 又把它撤掉——原本的路由沒有回來。proxy 自己的註解（`api_routes.py:190-204`）
  講了「每個 prefix 一筆」這個前提，**但漏了這個後果**
- **🔑 為什麼排在 A 節**：**一個會自己清理的 app 就會觸發它。** TE app 遷移完流量後刪掉
  自己的規則是完全正常的行為
- **證據**：實測雙平面對照，`scratch/round6/FINDINGS-round6.md`

### A-4e 🔴 `modify_flow_entry` 忽略 `priority`，會改到別人的規則而且傷害存活

- **狀態**：OPEN。**round 6 新發現**
- **平面**：OVS（P4 的 modify 走不同路徑）
- **失效方向**：靜默 ＋ **不可逆**
- **會發生什麼**：改自己的 priority-100 規則，結果**改到 router 的 priority-10 規則**
  （確認是同一條——`duration`/`n_packets` 沒變），搬走 32 MB 流量，
  **而且刪掉自己的規則之後傷害還在**
- **機制**（同一個檔案、相隔 40 行，一個做對一個做錯）：
  ```cpp
  // HttpRoutingStrategyBase.cpp:158-164  —— 正確
  if (priority == -1) return post("/stats/flowentry/delete", ...);          // 非 strict
  body["priority"] = priority;
  return post("/stats/flowentry/delete_strict", ...);                        // strict

  // HttpRoutingStrategyBase.cpp:195-201  —— 錯
  body["priority"] = priority;                    // 設了…
  return post("/stats/flowentry/modify", ...);    // …但送非 strict，Ryu 不用它比對
  ```
- **`modify_flow_entry` 是唯一從沒被任何測試輪呼叫過的寫入動詞**，所以四輪都沒發現
- **證據**：實測 ＋ 原始碼比對（我獨立 grep 驗證過這個不對稱），`scratch/round6/`

### A-4f 🔴 電源循環會失去 bridge 的 sFlow 紀錄 → 該鏈路遙測永久歸零

- **狀態**：OPEN。**round 6 確認（A/B 實測，n=2）**
- **平面**：OVS
- **失效方向**：靜默（**0 bps 與「閒置」無法區分**）
- **會發生什麼**：電源循環後，**s3→s8 鏈路在實際承載 103 Mbps 時讀值恰好 0 bps**；
  手動補回 sFlow 紀錄後讀到 106–148 Mbps
- ⚠️ **機制比預測的窄**：**去樣本化的那台交換機是「進來的邊」變暗，不是出去的邊**
- **🔑 與 A-4b 疊加**（**08-29 更正歸屬：原文寫的是「與 F-17 疊加」，機制掛錯了**）：
  這條鏈路讀 0 bps 會進到 graph，而 Energy-App 的關機決策讀的是它**自己**從 graph 算的
  `group_avg_link_utilization`（A-4b 的路徑），**不是** F-17 的 `get_average_link_usage` 端點
  （那個端點的 client 在 app 裡零呼叫點——見 §C 表下的二次更正）。
  ⇒ **結論不變、機制換人**：**電源循環過的交換機會讓自己更容易再被關掉**，
  但要走 A-4b 的路徑講，不要引用 F-17
- **與 §F 的 qdisc 遺失是同一族**：`powerOff` 存了 port 清單，但既沒存 qdisc 也沒存 sFlow 紀錄
- **證據**：實測，`scratch/round6/FINDINGS-round6.md` X1

### A-5 每次 kernel 重啟都會截斷前一輪的 log —— 包括示範自己的證據

- **狀態**：OPEN
- **平面**：兩者
- **失效方向**：靜默（證據消失，沒有人被通知）
- **會發生什麼**：出事後想回頭看 log，**上一輪的已經沒了**。示範中途重啟 kernel（A-2 的繞法
  正好要求這麼做）就會抹掉導致問題的那段紀錄
- **🔑 繞法**：**每輪結束立刻把 `kernel.log` / `p4_proxy.log` / `ryu.log` 複製到別處**，
  在下一次 stack 循環之前
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`（舊輪次掃描）

### A-6 P4 proxy 每次啟動都宣告「這輪毀了」，而它是錯的

- **狀態**：OPEN
- **平面**：P4
- **失效方向**：悲觀 ＋ 噪音
- **會發生什麼**：proxy 在**每次**啟動時印出「the graph will stay partly disabled … for the
  rest」之類的訊息。實測那是假的——`inform_switch_entered` 會重試而且會成功。
  台下看到這行會以為系統壞了
- **相關**：`cleanupAppFolder` 另外會噴 **17 條敘述後果為假的警告**，
  外加 **9 個裸的 sudo 密碼提示打到 stderr**
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`

### A-7 排隊寫入的失敗對所有 API 都不可見

- **狀態**：OPEN。**已裁定延到報告後，且已在簡報 Page 35 的誠實未解項目清單上**
- **平面**：兩者
- **失效方向**：樂觀 ＋ 靜默
- **會發生什麼**：契約測試套件**全綠**，而同時 `kernel.log` 寫著 `dispatched install failed`。
  沒有任何 API 表面暴露那個失敗
- **與 B-1 的關係**：B-1 是「拒絕沒被記錄」，這條是「失敗被記錄了但沒有 API 讀得到」——
  同一個斷鏈的兩端
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`

### A-8 三個測試工具在系統正確運作時變紅

- **狀態**：OPEN
- **平面**：兩者
- **失效方向**：悲觀
- **會發生什麼**：Energy-Saving-App **正確地**關掉一台交換機時，L2 契約測試、L3 契約測試、
  log allowlist 三個工具同時turn紅
- **為什麼重要**：一個在系統正確時變紅的測試套件，會訓練它的讀者**忽略紅色**
- **證據**：實測，`doc/audit/2026-08-18_live-full-stack-round/` F-2 / N-9

---

## B. 需要特定操作才會踩到

### B-1 被交換機拒絕的規則，twin 當成存在的來服務（幽靈規則）

- **狀態**：OPEN（2026-08-18 裁定報告前不修）
- **平面**：**兩者**，但誠實程度不同
- **失效方向**：樂觀 ＋ **OVS 上完全靜默**
- **四個格子**（實測，2026-08-19）：

  | | 不帶 `ip_proto` 的 `tcp_dst` | 帶 `ip_proto` |
  |---|---|---|
  | **OVS** | kernel 200、Ryu 200、**兩邊 log 零錯誤行**、規則從沒到達交換機 | 立刻裝上 |
  | **P4** | proxy 400 指名欄位、kernel `[warning]`+`[error]`、proxy `Refusing rule`，POST 後 8 ms | **一樣 400**（`ipv4_lpm` 也不收） |

- **幽靈窗口**：兩個平面都有。P4 上實測 **7.2–8.2 秒**（1 秒解析度），到下次 poll 為止
- **🔑 kernel 回應文字「per-entry outcomes are reported in the kernel log」
  在 P4 上為真、在 OVS 上為假**
- **根因（OVS）**：`Controller.cpp:55` 靠「在 200 body 裡找錯誤」偵測失敗；
  P4 proxy 會放一個進去，Ryu 的 fire-and-forget `/stats/flowentry/add` 做不到
- **⚠️ 這在三週前就被預測過**：`doc/2026-07-28_test_coverage_gaps.md` §8 待辦 4 猜對了原因
  （"curl fire-and-forget"），08-13 的 fault catalogue C-1 引用它並稱之為
  「最有價值也最容易做」
- **副作用**：服務出去的表格**混用兩套 match key 詞彙**——poll 來的是 `dl_type`/`nw_dst`，
  樂觀 append 來的是 `eth_type`/`ipv4_dst`
- **證據**：實測，`doc/audit/2026-08-18_live-full-stack-round/` F-5/F-5b（OVS）
  ＋ `scratch/phase2/FINDINGS.md` E6（四格對照）

### B-2 鎖在兩種平常情況下不提供互斥

- **狀態**：OPEN
- **平面**：兩者（純 kernel）
- **失效方向**：靜默（兩邊都回 200）
- **兩個獨立問題**：
  1. **續約一個已過期的鎖回 200**（契約寫 412）。`LockManager::renew` 只檢查 map entry
     存在且 `isLocked` 為真，**從不比較 `now < expiryTime`**；而 `isLocked` 只有 `unlock()`
     或 `acquireLock()` 會清掉，**過期不會清**。
     實測的有鑑別力變體：一個**什麼都沒持有**的 client 把**別人的**鎖從 3 秒延長到 120 秒，
     並把第三方鎖在門外。
  2. **任何人可以釋放任何人的鎖**。`LockState` **沒有 owner 欄位**，`unlock()` 為呼叫者清鎖。
     真正的持有者只會從下一次失敗的 renew 得知自己被踢出臨界區。
- **實際影響**：Energy-App 與 TE-App 都取同一把 `routing_lock`，各自 6 次/分鐘。
  任何超過 TTL 的持有都開啟「兩個 app 都以為自己擁有網路」的窗口
- **⚠️ 更大的脈絡**：這條擋住了整個併發控制的路——見 memory
  `ndtwin-cannot-do-either-concurrency-control`
- **證據**：實測，`scratch/phase2/FINDINGS.md` E3/E4；round-2 的 F-11 是同一族

### B-2b 🔴 一個單引號讓 kernel 指控一個健康的元件 —— 而且訊息與真實故障無法區分

- **狀態**：OPEN。**round 4 新發現**，是 B-4（模擬案例引號）的第三個實例
- **平面**：兩者
- **失效方向**：靜默 ＋ **主動誤導診斷**
- **會發生什麼**：`HttpRoutingStrategyBase::post` 把 `body.dump()` 內插進 shell 的單引號裡沒有
  跳脫（原始碼註解自承）。match 裡有一個 `'` → **`/bin/sh` 語法錯誤 → curl 從沒執行** →
  `splitBodyAndStatus` 拿到 status 0 → kernel 回報：

  ```
  no response from <component> at <url> within 5s
  ```

  **它指控一個它根本沒有連過的健康元件。**
- **🔑 這條真正的傷害不是它會壞，是它會把除錯的人送去錯的地方。**
  round 4 同時測了「控制器真的掛掉」的情況（實驗 5），得到**一模一樣的訊息**——
  所以出事時 log 無法區分「我的請求壞了」和「對方掛了」
- **實務觸發**：TE app 目前只送數字與 IP，所以不會自然發作。但輸入檔路徑、device name、
  intent 文字這些欄位都可能含引號

#### 🔴🔴 2026-08-28 增補：**上面整條只分析了「意外」的引號。「故意」的引號嚴重度差一個級別**

本條原本的結論是**診斷被誤導**（可用性 ＋ 誤指健康元件）。那是一個**不小心**打進引號的人會遇到的事。
一個**故意**送引號的人得到的不是語法錯誤，是**命令執行**：

```
單引號讓字串「壞掉」  →  單引號讓字串「結束」，後面接的是命令
{"...": "x'; <command>; echo '"}      ← json::dump() 不跳脫 ' ⇒ 原樣進 /bin/sh
```

**完整的鏈是既有的，本條自己就寫了其中一段**（「match 裡有一個 `'`」＝北向送的 match 值會走到這裡）：

| # | 環節 | 依據 |
|---|---|---|
| 1 | 北向 API 監聽 **`0.0.0.0`，不是 localhost** | `ControllerAndOtherEventHandler.cpp:90`：`tcp::endpoint{tcp::v4(), NDT_PORT}` |
| 2 | 北向送的 match 值會流進南向 body | **本條自己的例子** |
| 3 | `body.dump()` 內插進單引號，`json::dump()` 不跳脫 `'` | `HttpRoutingStrategyBase.cpp:76-84`（原始碼註解自承） |
| 4 | `utils::execCommand` 用**裸 `popen()`** ⇒ 經過 `/bin/sh -c` | 本檔 §A 已記載 |

⇒ **能連到 port 8000 的人，可以用 kernel 的身分執行命令。** 共 **14 個南向 curl 呼叫點**共用這個構造；
`SimulationRequestManager.cpp:118-125` 是第二個已確認的入口，其註解同樣自承。

⚠️ **`validateRequestBody()` 只檢查形狀，不是修補**——`SimulationRequestManager.cpp:115-121` 的註解
明文這樣寫，這裡重述是因為「有驗證函式」很容易被讀成「有防護」。

🔑 **為什麼它被低估了一整個級別，這比漏洞本身更值得記：**
本條的「實務觸發」寫的是「**目前只送數字與 IP，所以不會自然發作**」——
**那是一句關於「意外」的話，卻被拿來給整條定級。**
**「不會自然發作」不等於「不會發作」**：自然發作的機率由正常使用決定，
**故意發作的機率由有沒有人想這麼做決定**，兩者無關。
⇒ **凡是分析「這個壞掉的輸入會怎樣」的條目，都要再問一遍「有人故意送這個輸入會怎樣」。**

**修法不變、優先級改變**：仍然是「一次做完、所有呼叫點、改用 argv 執行器」（見上面兩處註解，
它們都明說不要零星修補）。**不要在單一呼叫點加跳脫**——那會讓其餘 13 個看起來已經被處理過。

📌 **本增補由 DeepSeek 在設計 chaos harness 的行動面時獨立指出**，審查員逐項複驗：
四個環節全部親自看過原始碼確認。**它找到的不是新缺陷，是一個既有條目沒有寫完的那一半。**
- **證據**：實測雙平面對照，`scratch/round4/FINDINGS-round4.md` 實驗 2 ＋ 實驗 5

### B-2c P4 proxy 對 CIDR 形式的 `ipv4_dst` 回 500（未處理的 `OSError`）

- **狀態**：OPEN。**round 4 新發現**
- **平面**：P4
- **失效方向**：吵（500），但錯誤沒有說明原因
- **機制**：`route_flow` 寫死 `/32`，然後把呼叫者給的值直接丟進 `inet_aton`——
  值本身若已是 CIDR 形式（`10.0.0.5/32`）就丟出未捕捉的 `OSError`
- **把 kernel 排除在外也能重現**（直接打 proxy）
- **證據**：實測，`scratch/round4/FINDINGS-round4.md` 實驗 2 附帶發現

### B-3 historical logging 回 200「已啟用」，但一列都不會寫

- **狀態**：OPEN
- **平面**：兩者
- **失效方向**：靜默
- **會發生什麼**：`POST /ndt/historical_logging?state=enable` 回
  200 "Historical data logging has been enabled."，然後**零筆寫入**，
  kernel log 裡**從來沒有** `HistoricalDataManager started.`
- **機制**：`HistoricalDataManager::start()` 在 MININET 模式直接 return，
  而 `writeSnapshot` 只從 `run()` 呼叫——那條執行緒從沒啟動。REST 端點只翻旗標。
  `stack.sh` 永遠用 `--mode mininet` 啟動 kernel。
  ```cpp
  if (m_running.exchange(true) or m_mode == utils::DeploymentMode::MININET)
  {
      // Already running
      return;
  ```
  ⚠️ 註解只描述了條件的**前半**。「MININET 模式下這個元件根本不啟動」這件事
  在原始碼裡沒有任何一個字說明，讀的人會以為早退只是因為重複呼叫。
- **實測排除了替代解釋**：不是「輸出目錄不可寫」——**根本沒有嘗試寫入**
- **證據**：實測，`scratch/phase2/FINDINGS.md` E5

### B-4 模擬案例：任一欄位含單引號 → 回 202 但請求從沒送出

- **狀態**：OPEN（程式碼註解已自承）
- **平面**：兩者
- **失效方向**：靜默
- **會發生什麼**：`received_a_simulation_case` 的欄位含 `'` → API 回
  **`202 {"status":""}`**，請求**從沒離開 kernel**，log 裡是 `sh: 1: Syntax error`
- **機制**：`handleReceivedSimulationCase` 只驗形狀，然後
  `SimulationRequestManager.cpp:115-133` 把原始 body **字串內插**進
  `curl ... -d '<body>'` 的 shell 指令，並把指令印出的東西當成 202 的 status 回傳。
  輸入檔路徑本來就可能含引號——那正是那個欄位的用途。
- **證據**：實測，`scratch/phase2/FINDINGS.md` E12

---

## B-x. `/ndt/get_detected_flow_data` 包含已經結束的流（churn 下約 92%）

**2026-08-27 實測。** 完整記錄：[`doc/audit/2026-08-27_flow-table-idle-tail/PREREG.md`](audit/2026-08-27_flow-table-idle-tail/PREREG.md)（工單 W）。

`FLOW_IDLE_TIMEOUT = 15000 ms`：一條流停止送封包之後，**仍留在流表 15 秒**。
在 churn 工作點（1.6 條新流/秒）實測：

| 當下真的在送封包 | 端點列出 | 比值 |
|---:|---:|---:|
| 4.7 | 63.0 | **13.3×** |

⇒ **端點回報的「流」約 92% 已經結束**，而**回傳的紀錄沒有任何欄位表達這件事**。

🔴 **有 repo 外的消費者**：`~/Energy-Saving-App/src/app/energy_saving_app.cpp:741`
把它整包餵進 `json2sim["flowDataList"]`。**是否據以做關機決策：未讀，未宣稱。**

**繞法**：需要「當下併發流數」的呼叫端，不能直接數這個端點的長度。
**倍率 ≈ `1 + 15 × 新流速率 / 平均併發`**，長流下趨近 1，**短流／高 churn 下最壞**。

⚠️ **保留 15 秒可能是刻意的**（避免短流一閃即逝）。**缺陷在於端點沒有把它表達出來，不在保留本身。**

**2026-08-28：規格揭露查核已完成**（[`03_spec-disclosure-check.md`](audit/2026-08-27_flow-table-idle-tail/03_spec-disclosure-check.md)）。
判定規則事前寫在 `NEXT.md:25-30`，結果落在「**沒寫**」那一支 ⇒ 上面的措辭維持不變。查核同時定出兩件事：

- 🔴 **文件不只是沒說，是說了相反的話。** §4 稱這個端點回傳 “all **active** flows”
  （`doc/2026-01-02_ndt_api.md:358`）。所以這不是「規格沉默、實作自由發揮」，
  是**規格做了宣稱而實作牴觸它**——可被引用來反駁 twin 讀數的等級。
- 🔴 **同一個母體涵蓋兩個端點。** `get_detected_top_k_flow_data` 的
  `getTopKFlowInfoJson` 直接呼叫 `getFlowInfoJson()`（`FlowLinkUsageCollector.cpp:2336`），
  而後者走訪整張 `m_flowInfoTable` **無存活性過濾**（`:2291-2327`）；文件 2395 行用了字面相同的
  “Top-K **active** flows”。**與既有的 top-k 殘影條目是不同的缺陷**：那條是速率**數值**沿用舊值，
  這條是**母體**——速率全部正確歸零，那 92% 仍然會被列出來。
- ✅ **修法契約相容**：`Obj` 的 `strict` 預設 False（`tools/contract_test/schema.py:129-138`），
  新增一個存活性欄位不會讓契約測試變紅，不必先改契約。

### B-x 的排序後果——**一個被提出的加乘效應，實測不成立**

有人提出：top-k 用 `estimated_packet_rate_in_the_proceeding_1sec_timeslot` 排序
（`FlowLinkUsageCollector.cpp:2339-2344`，兩個分支都一樣），
而死流會在該欄位保留舊速率 ⇒ **死流會贏過活流搶進前 K 名**。

🔴 **這個加乘在兩個分支上都不成立，因為前提已經不對了。**

| | 死流的 `_in_the_proceeding_1sec_timeslot` |
|---|---|
| `origin/main` | **0**（一直都清除，`FLUC:1453-1459`） |
| 本分支（現行） | **0**（`aabe605` 修回清除，`:1911-1913`） |
| 本分支（`31b357a6`…`aabe605` 之間） | 保留舊值 ⇐ **A-3 的那個窗口，已關閉** |

⇒ 死流在兩個分支上都排到**最底**，不會擠掉活流。

⚠️ **但母體問題仍然成立，而且它自己就夠難看**：`getTopKFlowInfoJson` 取
`min(k, size)` 且**不過濾**（`:2347`）。預設 `k = 50`（`HttpSession.cpp:589`），
churn 工作點只有 **4.7** 條流真的在送封包
⇒ **回傳的 50 筆裡約 45 筆是速率 0 的死流**。清單不是被死流「灌到前面」，是**被屍體填滿**。

🔑 這條的教訓是**兩個缺陷可以看起來相乘而實際不相乘**：
A-3（數值）與 B-x（母體）確實會在 top-k 相遇，但 A-3 已經修掉，所以相遇的只剩一邊。
**在把兩個缺陷相乘之前，先確認兩個都還活著。**


## C. 靜默的正確性問題（不影響示範，影響可信度）

這些是 2026-08-18 那輪 subagent 找到的 18 條中仍然開著的部分。**都需要注入故障或特定條件**，
所以不會在示範中自己發作，但它們決定了「twin 說的話能不能信」。

| # | 缺陷 | 平面 | 方向 |
|---|---|---|---|
| **F-4** | 死掉的交換機間鏈路**每次 poll 都被復活成 `is_up=true`**——`updateHosts` 只憑 IP 相符就把邊標 up，而交換機自己的管理 IP 被 Ryu 當成 host 學到 | OVS | 樂觀 |
| **F-17** | `get_average_link_usage` **只平均忙碌的鏈路**（分子分母都只算非零邊）。**round 4 量化：8/32 條邊忙碌時，只算忙碌邊的平均 0.11 vs 真實 0.027，正好 4.0×**。🔴 **08-29 更正：原文寫的「這是 Energy-App 關機決策的輸入」與「標頭文件寫的是另一個公式」兩句都是錯的**——見表下 | 兩者 | 樂觀（有負載時高估 4.0×）；**失效方向的完整敘述見表下** |
| **F-14** | **host 永遠不會被標成 down**——沒有任何程式路徑可以做到。發現之後 `is_up` 是常數 `true` | 兩者 | 樂觀 |
| **F-16** | 交換機死掉時**只有交換機間的邊被標 down**，它面向 host 的邊維持 up，所以被孤立的 host 看起來還連著 | 兩者 | 樂觀 |
| **F-8** | `left_link_bandwidth_bps` 在第一次取樣前**寫死 1 Gbit/s**，所以每條 10 Gbit/s 核心鏈路只宣告十分之一的餘裕。🔑 **與「容量夾制」同根**：`link_bandwidth` 這個**模型宣告值**滲進量測欄位的**第二種方式**——F-8 拿它當**初始值**，夾制拿它當**上限**（見 `doc/audit/2026-08-27_capacity-clamp/FINDING.md`）。**兩條並列不合併**：F-8 是暫態、會被真資料取代；夾制是持久、且只在超載時觸發 | 兩者 | 樂觀 |
| **F-1** | `get_cpu_utilization` 與 `get_memory_utilization` **回傳位元組完全相同的內容**——同一個 `10 + hash(ip) % 50` 運算式；三個裝置健康指標都是交換機 IP 的常數函數 | 兩者 | 合成 |
| **F-13** | 對**不存在的** group / meter 做 modify/delete 回 200 "modified"/"deleted" 且什麼都沒改。6 個端點零契約覆蓋 | OVS | 靜默 |
| **F-6** | 讀取流表失敗的交換機**被從 `get_switch_openflow_table_entries` 刪除**，而四處程式碼註解承諾「保留前一份表格」 | 兩者 | 靜默 |
| **F-9** | 鏈路使用量量化到取樣粒度（1/256 × frame length × 8），所以低於約 3 Mbit/s 的鏈路**讀成一個量子的整數倍**（⚠️ 原文寫「讀成 0 或一個量子」，**「讀成 0」那半未被觀察到**，見下） | OVS | 解析度限制 |
| **F-15** | bmv2 gRPC port 配在 kernel 的 ephemeral range 內，所以交換機**隨機開不起來**，而錯誤訊息指向錯的原因 | P4 | 環境 |

> ### 🔴 F-17 的兩次更正，方向相反 —— 兩次都要讀完再引用
>
> **第一次（round 4 實測，仍然成立的部分）**：先前記載的失效方向「保守（少關機，不會誤關）」
> **是錯的**。round 4 量到**「保守」這個性質在閒置時消失**：沒有忙碌邊時這個端點回 **0.0**。
> 所以它**有負載時高估 4.0×、閒置時歸零**——**端點的讀值本身是雙向失效的**，這一半照舊成立。
>
> **第二次（2026-08-29 更正，把第一次的結論收窄）**：round 4 接著推論
> 「0.0 落在 Energy-App 的 `LOW_WATER_MARK = 0.40` 之下 → 觸發關機」。
> 🔴 **那條因果鏈需要一條不存在的接線。**
>
> | 查了什麼 | 結果 |
> |---|---|
> | `Energy-Saving-App` 有沒有這個端點的 client | ✅ **有**：`src/app/http.cpp:393` 定義 `get_average_link_usage()`，打 `/ndt/get_average_link_usage`；`include/app/http.hpp:34` 宣告 |
> | 那個 client 有沒有**被呼叫** | 🔴 **零個呼叫點**（全 repo grep，扣掉定義與宣告後為空） |
> | 關機決策實際讀什麼 | `energy_saving_app.cpp:926` 的 `avgLinkUtilization` 來自 **`group_avg_link_utilization(g, group)`**（`include/common/types.hpp:215`），**從 Graph 自己算**，不經過這個端點 |
>
> ⇒ **F-17 不是 Energy-App 關機決策的輸入。** 這正是 [[existence-is-not-wiring]] 的形狀：
> **端點的 client 存在、被宣告、被文件記載，但沒有人呼叫它。**
>
> **所以下面這些要分開**：
> - 🔴 **不再成立**：「F-17 會害 Energy-App 關光交換機」。它碰不到那條決策路徑。
> - ✅ **照舊成立**：端點讀值有負載時高估 4.0×、閒置時歸零（**這是 twin 可信度的缺陷**）。
> - ✅ **照舊成立，而且它才是真的關機風險**：**A-4b** —— app **自己的**
>   `group_avg_link_utilization` 在邊 up+enabled 但沒有量到流量時回 0.0 → `0.0 <= 0.40` → 關機。
>   **那條推論完全不依賴 F-17**，`:168` 從一開始就寫著兩者是不同的函式。
> - ⚠️ **零呼叫點不等於可以安全地改**：`/ndt/` 是跨 repo 契約、七個姊妹應用在用，
>   而這個端點的 client 已經寫好放在那裡（見 [[no-in-repo-callers-is-not-dead-code]]）。
>
> 📌 **同一個錯誤前提還有第五個引用點，在產品碼裡**：`include/ndt_core/http/HttpSession.hpp:592`
> 寫著「This figure is what Energy-Saving-App reads」，**而且是拿它當一次標頭修改的理由**。
> **本輪沒有動產品碼**，已另行回報。
>
> 🔴 **對 §D 裁定的影響**：F-17「不修」的原理由（失效方向保守）仍然被 round 4 推翻，
> 所以**仍然需要重裁**；但**重裁的籌碼變小了**——「它會觸發關機」這個最重的理由已經沒了。
> **前提塌了不代表結論塌了**，裁決權在 Adam，本文件不代為裁定。

**F-1 在示範上的風險最高、工程嚴重度最低。** 台下有人點兩台交換機看到同一個數字，
或問一句「CPU 哪來的」，那是零防守的。**要嘛不上台，要嘛明講「Mininet 模式下未實作」。**

證據：`doc/audit/2026-08-18_live-full-stack-round/subagent-round2-FINDINGS.md`（904 行）

### 🔴 F-9 的範圍更正（2026-08-27）

原文說低於約 3 Mbit/s 的鏈路「**讀成 0** 或一個量子」。**「讀成 0」那半沒有被觀察到。**

| 來源 | 觀察 |
|---|---|
| `8/27 auditor` | **62 條 host 邊全部低於 3 Mbit/s，而無一讀 0** |
| 本次獨立複驗（OVS、`raw_n/N1d_moderate/rows.json`） | **55 條有負載的邊（veth > 1 MB），讀 0 的有 0 條**；最小的非零 twin 讀值 = 291,442 B ≈ **2.33 Mbit/視窗**，正落在 3 Mbit 以下那個區間 |

⇒ **量化本身是真的**（存在一個地板、讀值是量子的整數倍），
但**「低於門檻就掉到 0」不是這個缺陷的行為**。

🔑 **為什麼這個更正重要而不是雞蛋裡挑骨頭**：
「讀成 0」意味著**一條有流量的鏈路會在分身上看起來是閒置的**——那是**可見性的缺口**；
「讀成一個量子」只是**精度不足**。**兩者對維運的意義完全不同**，
而原文的措辭會讓讀的人準備防守一個不存在的失效模式。

⚠️ **未宣稱**：這兩份觀察都在**有流量**的邊上取得。
**完全沒有流量的邊讀什麼，本次沒有量**，所以不排除「真正閒置 ⇒ 0」——
那本來就是正確行為，與本條無關。

---

## D. 已明確裁定不修（含理由）

| 缺陷 | 裁定 | 理由 |
|---|---|---|
| **A-1 / A-2 / A-3** | 報告前不改碼，改用操作繞過 | 產品碼在報告前凍結（Adam 裁定）。A-1 的修法要碰 `powerOn` 的冪等語意，那個早退是**故意**的；報告前改錯比 bug 本身更糟 |
| **5-tuple 下發** | 報告後再修 | **不是缺陷，是排序**。P4 pipeline **有** `flow_5tuple` ternary 表且已接進 pipeline 排在 LPM 之前；proxy 的 `route_flow` 沒接；**而 TE app 自己也只送 `ipv4_dst`**（`# TODO: Change to match 5-tuple in HPE`）。三層一致，沒有消費端今天需要它。目前的 400 是**修法**——它取代了「接受 5-tuple 但實際裝成整個目的地的規則、priority 讀回 0」的靜默降級。詳見 memory `single-flow-precision-gap` |
| **F-5（幽靈規則）** | 2026-08-18 不修 | 30 分鐘真實負載下 **0 次自然發作**（177 取樣、期間 37 次寫入、5 次電源變動、15 輪 TE 遷移）。量測靈敏度約 80%/次，所以是「發作率低」不是「零」 |
| **F-4** | 2026-08-18 不修 | 機制讀碼確認，但報告裡「permanent and built in」那句被實跑推翻——我那輪 0 次，subagent 那輪 18 次（在它切斷 s10 controller 之後）。**觸發條件比原報告說的窄** |
| **F-17** | 2026-08-18 不修 —— 🔴 **裁定所依據的前提已被推翻，需要重裁**（2026-08-29 標記） | ⚠️ 原理由逐字是「失效方向**保守**（少關機，不會誤關）」，**round 4 實測推翻了它**（更正全文見 §C 表下）：沒有忙碌邊時**端點回 0.0**，所以**讀值的失效方向是雙向的**，不是單向保守。<br>**沒有被推翻的部分**：機制仍是「分子分母都只算非零邊」；有負載時仍高估 **4.0×**（8/32 邊忙碌時 0.11 vs 0.027），**那一半確實偏向少關機**。<br>⚠️ **08-29 二次更正**：round 4 由此推出的「0.0 → Energy-App 關機」**不成立**——那條接線不存在（app 的 client 零呼叫點，決策讀自己的 `group_avg_link_utilization`）。**重裁仍然需要，但最重的那個理由沒了。**<br>🔴 **「不修」這個結論本身尚未重裁** —— 前提被否證不等於結論被否證（修法成本、報告前凍結產品碼等其他理由未經檢驗）。**待 Adam 重裁** |

---

## D-2. 報告後待辦（不是缺陷，是待評估的調整）

### 縮短 LLDP beacon 間隔以加快故障偵測

- **狀態**：待評估。**報告後做，而且要做成實驗不是直接改**
- **提出**：Adam 2026-08-19

**現況的常數**（`p4_proxy/proxy_agent/topology_manager.py:137,155,158`）：

```python
LLDP_BEACON_INTERVAL_S   = 5
LINK_BEACON_TIMEOUT_S    = 3 * LLDP_BEACON_INTERVAL_S   # = 15，衍生
LINK_WATCHDOG_INTERVAL_S = LLDP_BEACON_INTERVAL_S       # = 5，衍生
```

timeout 與 watchdog 間隔**都是衍生的**，所以改一個常數三個一起動——這是便宜的部分。

**⚠️「收斂」是兩個數字，只有一個會改善**：

| | 現況 | 縮短 LLDP 後 |
|---|---|---|
| 偵測「這條鏈路死了」 | 實測 10.7–14 s | **會變短** |
| 修正「反向其實還活著」 | **0–30 s** | **不變**——由 `kOnceConverged = 30s` 的 poll 相位決定 |

`handleLinkFailure` 對單向故障也把**雙向**標 down，而只有 topology poll 會修正
（round 4 E8 確立）。所以在意「GUI 多久反應」→ 改 LLDP 有效；在意「拓撲圖多久才正確」
→ 要動 `kOnceConverged`。

**主要風險是誤判鏈路死亡**，而 `topology_manager.py:147-150` 的註解自己論證過為什麼那比慢更糟：
一次 interval 的容忍度會讓「掃描剛好落在 beacon 之前」就報故障，而
**會抖動的鏈路報告比慢的更糟**——每一次都讓 kernel 拆掉那條邊、從 BFS 移除、重算全域路徑。
這台機器讓風險是真的：bmv2 是 `-O0` debug build，模擬器**共用系統時鐘與 CPU**（見 §F）。

**隱藏成本**：`kLldpFreshSeconds = 12.0` 是 **C++ 常數**
（`DeviceConfigurationAndPowerManager.hpp:259`）。beacon 從 5 降到 2.5，那個窗口就從容忍
2.4 個 beacon 變成 4.8 個——**交換機存活判斷相對變得更不敏感**。維持同樣容忍比例要改 C++ 重編。

🔑 **先解決一個疑點再調參**：註解寫「偵測需要 15 到 20 秒」，**round 4 實測 10.7–14 秒**，
比文件快 5 秒。這代表我們對偵測時序的模型還沒對上——調完會不知道是什麼在動。

**建議的實驗設計**（改一行 Python，跑既有的鏈路故障實驗）：
掃 beacon = 5 / 3 / 2 / 1 秒，每個值量**偵測時間**與**誤判次數**。
**誤判率才是決定值不值得的數字**，不是偵測時間——因為偵測時間必然會降，
而誤判的代價是全域路徑重算。至少要跑到能區分「零誤判」和「低誤判」的樣本數。

---

## E. 已修，但形狀容易復發

不是待辦，是**審查時要問的問題**。完整討論在 memory 的形狀家族。

- **「該取代卻只能新增」**（7 個實例）—— 每個 ingest 都要問：**舊資料什麼時候消失？**
  → memory `replace-vs-add-bug-shape`
- **「被拒絕的請求仍然做了事」**（3 面）——
  ① 回 400 但真的裝上（`install_flow_entry` 缺 priority，**已修**）
  ② 回 200 queued 但被拒絕（B-1，開著）
  ③ 回 200 Success 但完全沒動作（A-1，開著）
  → memory `rejected-requests-can-still-act`
- **`/stats/flow` wedge**（三道門全部關上）—— 核心教訓：**失敗比逾時快**，
  所以任何基於延遲的守衛對「快速失敗」結構性失明
  → memory `ryu-flow-stats-wedge`

---

## E-2. 潛伏：一個旗標之遙的靜默故障

### 🔴 `getTopKFlowInfoJson` 對同一個 `std::shared_mutex` 遞迴取 shared lock

- **狀態**：**潛伏**。依 C++ 標準是**未定義行為**，但在目前的執行環境下**不會卡死**，
  所以**不宣稱它是活的缺陷**。列在這裡是因為變成缺陷的條件是具名且可驗的。
- **碼**：`FlowLinkUsageCollector.cpp:2335` 取 `shared_lock(m_flowInfoTableMutex)`，
  下一行 `:2336` 呼叫的 `getFlowInfoJson()` **對同一個 mutex 再取一次**（`:2293`）。
  `m_flowInfoTableMutex` 是 `std::shared_mutex`（`FlowLinkUsageCollector.hpp:387`），
  同一個 mutex 上有 **5 個 writer** 取 `unique_lock`（`:1486 :1822 :2109 :2272 :2924`）。
- **為什麼現在不咬人**：glibc 的 `pthread_rwlock` 預設是 `PTHREAD_RWLOCK_PREFER_READER_NP`，
  reader 不會為等待中的 writer 讓路，所以同執行緒遞迴 rdlock 會成功。
- 🔴 **會變成缺陷的條件（具名、可測）**：
  1. rwlock 種類改成 writer 優先（`PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP`），或
  2. libstdc++ 換成 condvar 版的 `shared_mutex` 實作（未定義 `_GLIBCXX_USE_PTHREAD_RWLOCK_T` 時）
  ⇒ 兩者之一成立時，**writer 卡在兩次 shared 取得之間就會自我死鎖**。
- 🔑 **一旦卡死就是整顆 API 卡死，不是一個端點**：北向 API 一次只服務一個請求
  （見 memory `northbound-api-serialises`），所以一條卡住的處理執行緒會佔住整個伺服器。
- **修法**：把 `getFlowInfoJson` 的鎖抽出來（拆成一個不取鎖的內部版本，
  由兩個呼叫端各自取一次），不要靠底層 rwlock 的偏好設定。
- 📌 **順帶**：`getTopKFlowInfoJson` 在持有 shared lock 的情況下對整個 JSON 陣列做
  `std::sort`（`:2339-2352`），臨界區長度與流表大小成 O(n log n)。這與死鎖無關，
  但它讓上面那個窗口變寬。
- **證據**：讀碼（2026-08-28）。**未實測**，也沒有已知的觸發紀錄。


### sFlow batching 的老化清掃只在有樣本進來時跑 ⇒ **整個 fabric 同時安靜下來，尾巴留在記憶體裡**

- **狀態**：**潛伏**。旗標是 `NDTWIN_SFLOW_BATCH`，**生產預設 1 ＝ batching 關閉 ⇒ 目前不咬人**。
  truncate／merge 若採用（工單 D/E/F 在評估）就會咬。
- **機制**：`sflow_emitter.py` 的老化 sweep 掛在 `emit()` 裡
  ——**只有樣本進來時才會檢查別的 dpid 有沒有過期**。若整個 fabric 同時安靜，
  沒有任何 `emit()` 被呼叫 ⇒ **每台交換機最後一批部分樣本留在記憶體裡直到 `close()`**。
- 🔴 **緩解措施存在，而且它自己寫下了需求，但沒有呼叫者**：`flush()` 的 docstring 明寫
  *"a caller running the emitter for long periods should call it on a timer as well"*，
  而 `main.py` **只在 `close()` 呼叫它，沒有任何 timer**。
  ⇒ [[existence-is-not-wiring]] 的變體：**不是「有呼叫點沒定義」，是「有定義零呼叫者」，
  而且需求是這段碼自己寫下的。**
- **本輪不修**（修它是行為改變，要有量測支撐），**改為用測試釘住現況**：
  `tests/python/test_sflow_emitter_batching.py::QuietFabricTailIsPinnedNotFixed`
  斷言「整個 fabric 安靜時尾巴仍在 `_pending` 裡」⇒ **未來要修，必須來這裡把斷言改掉，
  不能不知不覺地修掉。**
- **影響量級**：每台交換機最多 `batch_size - 1` 個樣本。batch=8 時＝10 台 × 7 ＝ 70 個樣本
  停在最後一次安靜之後，直到下一次流量或關機。
- **要修的話的形狀**：`main.py` 起一個 timer 週期呼叫 `flush()`，週期 ≤ `batch_max_delay_s`。


### OVS 電源開機把交換機指向 `6633`，目前能通是**巧合**

- **狀態**：**不是缺陷**（實測驗證），但是**潛伏風險**
- **兩個獨立模型（DeepSeek、Muse Spark）都把這條列為 CRITICAL，實測是它們錯了。**
  `OVSPowerStrategy.cpp:112` 執行 `set-controller <sw> tcp:127.0.0.1:6633`，而拓撲檔設
  `CONTROLLER_PORT = 6653`。實測電源循環後：`target: tcp:127.0.0.1:6633` **且
  `is_connected: true`**，撐過兩分鐘；鄰居維持 6653；datapath-id 存活。
  鑑別對照（指向死埠 16633）得到 `is_connected: false, state=BACKOFF`，證明欄位有鑑別力。
- **為什麼能通** —— Ryu 自己的原始碼（`ryu/controller/controller.py:127-135`）：
  ```python
  if not CONF.ofp_tcp_listen_port and not CONF.ofp_ssl_listen_port:
      self.ofp_tcp_listen_port = ofproto_common.OFP_TCP_PORT      # 6653
      # For the backward compatibility, we spawn a server loop
      # listening on the old OpenFlow listen port 6633.
      hub.spawn(self.server_loop, ofproto_common.OFP_TCP_PORT_OLD, ...)   # 6633
  else:
      self.ofp_tcp_listen_port = CONF.ofp_tcp_listen_port          # 只綁這一個
  ```
- 🔴 **`else` 那條分支就是風險**：只要有人在 `ryu-manager` 加上 `--ofp-tcp-listen-port`，
  6633 就不再綁定，而 `powerOn` **不檢查 `is_connected`** 就回 Success →
  每一台電源循環過的交換機被靜默孤立
- **這個事實 repo 裡一個字都沒有**，只寫在 Ryu 的原始碼裡。任何只讀本專案的人都推不出來——
  **這正是讀原始碼的模型會高估缺陷的原因**
- **證據**：實測 ＋ Ryu 原始碼，`scratch/round4/FINDINGS-round4.md` 實驗 1

### OVS `powerOn` 的 `&&` 短路（precondition 目前構不到）

`run("add-br <sw> && set bridge <sw> other-config:datapath-id=...")` —— `add-br` 對已存在的
bridge 會 exit 1，於是 **datapath-id 永遠不會被設**。round 4 實際製造了 ovsdb 競用
（24 個並行 worker，powerOn 從 0.16s 拉長到 3.5s），**零次 ovs-vsctl 失敗**，s7 完全復原。
所以判 REFUTED as tested，但**短路本身是真的且已被示範**——記為潛伏，precondition 不可達。

---

## F. 環境與測試床限制（不是缺陷，但會被誤判成缺陷）

- **Mininet 靜靜忽略 `bw>1000`**（`link.py:238`），所以 128-host 拓撲宣告 10 Gbps 的
  **16 條核心鏈路從未被整形**。實測 htb 144/160，缺的 16 個逐字就是那 16 條。
- **10 Gbps 在這個拓撲裡是算術上構不到的**——每台接取交換機只有 2 條 1 Gbps 上行，
  所以單條核心鏈路上限約 2 Gbps。**換多快的機器都一樣。**
- **電源循環會掉整形，但只有 4 個介面**（144 → 140），而且**對端不受影響**＝效果是**單向的**。
  `OVSPowerStrategy::powerOff` 存了 port 清單但沒存 qdisc。
  ⚠️ **這條更正過**：最初報告成「20 個介面、雙向」，那是把「從未整形的 16 個」
  誤算進去的巧合。
- **bmv2 天花板 —— 2026-08-28/29 四張工單已量過，見下面的 §F-bmv2。**
  **量測型實驗必須記錄用的是哪顆 binary**，否則「速率估計錯了」的結論可能只是丟包的假象。
  🔴 **並且必須記錄 frame size** —— 工單 ② 證明不記錄就是 16× 的歧義。
  舊的無出處數字已退役，理由見 §F-bmv2 最後一段。
- **sFlow 取樣誤差有理論地板**：95% 信賴下 ≈ `196 × √(1/c)`，c = 樣本數。
  **±5% @ 1 秒窗在 bmv2 上不可能**，不是生成器的問題。
  已實測驗證跨 430× 窗長與 10× 負載範圍，見
  `doc/audit/2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md`

### F-bmv2. bmv2 轉發天花板 —— 四張工單的實測結果（2026-08-28／29 收案）

**正本是三個 audit 目錄的 `FINDINGS*.md`，下表是索引不是取代。**
每張工單的 `FINDINGS` 都有一節「What this licenses」明列**不准**由它推出什麼；
引用前讀那一節。

| 工單 | 問題 | 結果 | 正本 |
|---|---|---|---|
| **②** 封包大小 | 天花板是 pps 還是 bps？ | ✅ **pps**。兩個註冊比值都落在 H1 | `doc/audit/2026-08-28_packet-size-sweep/FINDINGS.md` |
| **①** build 比值 | 12× 是 build 的功勞還是路徑的？ | 🔴 **裁不了** —— 梯子在 fast 之前先用完，R ≥ 8.0 是全部量到的 | `doc/audit/2026-08-28_single-switch-build-ratio/FINDINGS.md` |
| **①b** 重跑 | 同上，梯頂改由停止規則決定 | ✅ **R = 8.0 ⇒ H2**，四臂全部因 loss 而停 | 同目錄 `FINDINGS-1b.md` |
| **③** 流數 | 容量隨流數怎麼變？ | ✅ **每流最高乾淨速率兩臂各自單調下降**；🔴 註冊的放棄判準觸發 | `doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md` |

**② —— 天花板是 pps，不是 bps。**
六臂鏡像 `64 256 1024 | 1024 256 64`，單流 h1→h65（s1→s3），**fast build**，128-host P4，kernel `a40e04ce`。
**是 frame size 不是 payload**（iperf3 `-l` 22 / 214 / 982，frame = payload + 42）：

| frame | 乾淨 kpps | 同一批資料換成 Mbit/s |
|---|---|---|
| 64 B | 16.0 | **8.2** |
| 256 B | 20.0 | **41.0** |
| 1024 B | 16.0 | **131.1** |

⇒ **pps 只變 1.25×，bit rate 變 16.0×。** 最強的支持不是這三格本身，而是
**六臂全部在同一階（110 kpps）截斷**，而截斷規則只看 loss、**對 frame size 全盲**。
🔴 **所以「bmv2 大約跑得到 N Mbps」這種句子不是不精確，是 16 倍的歧義。**
⚠️ 解析度只有 **±1 階**；② **不授權**任何關於其他 build／流數／fabric 的敘述。

**①／①b —— 12× 有一部分不是 build 的功勞。**
單跳 h1→h2 on s1、1400 B payload（＝1442 B frame）、**控制平面保持活著**、每臂一個 fabric 世代：

| build | 最高乾淨 | 梯子停在 | 為什麼停 |
|---|---|---|---|
| stock（`EventLogger` 24 個，sha `327fa7d1`） | **45 Mbit/s** | 160 M | 飽和規則 |
| fast（`EventLogger` 0 個，sha `3ff54b5c`） | **360 Mbit/s** | 810 M | 飽和規則 |

**R = 360 / 45 = 8.0 ⇒ H2**：**報告的 12× 有一部分來自三跳路徑與其上的控制平面，不是編譯旗標。**
主張要收窄成「**沿三跳生產路徑 12×**」，而論文必須講明是哪一個。

🔴 **但 H2 不是無條件成立**：一階量到的是「loss ≤ 0.5% 的最高階」，真正的零損點落在該階與下一階之間
⇒ stock ∈ [45, 70)、fast ∈ [360, 540) ⇒ **R ∈ (5.14, 12.0)，而 H1/H2 的邊界 9 就在區間內**。
🔑 **複製救不了這件事** —— 十臂零散布只證明「階」是穩的，
對「真值在階內哪裡」零資訊，因為不確定性是**量化**不是雜訊。
膝蓋形狀內插收窄到 **≈7.8**（**更深進 H2**，也就是離比較好講的 H1 更遠），
但那是**佐證不是量測**，而且**沒有為此再跑更細的梯子**（因為答案不順眼就重量，正是本專案反對的做法）。
⇒ **決策規則缺一支「區間跨過邊界 ⇒ 報不可分辨」，任何未來的比值輪都要先註冊那一支。**

🔴 **差額（8.0 vs 12）是路徑還是控制平面 —— 這是 ① `AMENDMENT-1 §8.2` 開跑前就註冊的另一輪，
本輪與本文件都不得推論。**

📌 換成 pps 是**算術換算不是量測**：45 / 360 Mbit/s @ 1442 B frame ＝ **3.90 / 31.21 kpps**，
**繼承上面同一個量化區間**。⚠️ **不要拿它跟 ② 的 kpps 對帳** —— 跳數、frame size、build 覆蓋範圍都不同，
而 ② 明文不授權跨 build 的敘述。

**③ —— 容量是流數的函數，而且不要用比值講。**
同一路徑類別上的每流最高乾淨速率（≤ 0.5% loss）：

| n（流數） | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| **arm a**（M/flow） | 160 | 110 | 30 | 5 | 2 |
| **arm b**（M/flow） | 240 | 110 | 45 | 8 | 1 |

⇒ **兩臂各自獨立單調下降**，而這個宣稱**不需要任何比值**。
🔴 **「16 流塌陷 3.3×」已撤回且不重算** —— 分子是坐在**平台**上的無損門檻、分母是坐在**膝蓋**上的飽和點，
**兩邊不是同一種量，換任何數字進去病都還在**。新口徑不要用「塌陷」這個詞。
🔴 **註冊的放棄判準觸發**（n=2 兩臂皆 220，註冊區間 95–150），兩個註冊模型判死 —— **殺死一個模型是結果**。
③ **不授權**任何 n=1 與 n=16 之間的比值。

**⇒ 之後任何 bmv2 量測型實驗的最低紀錄要求**：
① 哪一顆 binary（**用 `nm -DC <路徑> | grep -c EventLogger`：0 = fast、24 = stock**，
不要用 mtime 也不要用 PATH 上那顆）、② **frame size 還是 payload**、③ 跳數與路徑類別、
④ 流數、⑤ 控制平面是死是活。**缺任何一項，數字就不能跨輪比較。**

#### 已退役的舊 bmv2 天花板敘述（保留供追溯，**不要再引用**）

原文（§F，2026-08-19 前）：

> stock（`-O0`＋全 logging）約 **40 Mbps / 3.6k pps**；
> `-O3`（`/usr/local/bmv2-fast`）約 **47 kpps / 726 Mbps TCP**。

**為什麼退役 —— 三個理由，其中第三個是自我否證的：**

1. **repo 內查無出處** —— 全 repo `grep` 這四個數字，只命中本檔自己。沒有 audit 目錄、
   沒有原始資料、沒有指名 binary。
2. **它用 Mbps 陳述容量而不講 frame size** —— 正是工單 ② 指認的 **16× 歧義**。
3. 🔴 **fast 那一對自己不自洽**：726 Mbit/s ÷ 47 kpps = **15,447 bit ＝ 1,931 B/frame**，
   **高於標準 MTU frame（1,514 B）**，所以這兩個數字不可能來自標準 MTU 下的**同一次**量測。
   （對照組：stock 那一對隱含 **1,389 B/frame**，落在合理範圍 ⇒ 問題出在 fast 那一對，
   不是出在我的算法。）

⚠️ **沒有被推翻的是方向**：fast build 確實比 stock 快很多，這一點四張工單全部支持。
被退役的是**那四個數值本身、以及由它們算出的任何比值**
（舊數字給的是 Mbps 18.15× / pps 13.06×，兩者互不相等，也都不是實測的 8.0×）。

---

## G. 操作陷阱（會製造假的測試結果）

- 🔴 **`ndtwin-lab cleanup` 會殺掉呼叫它的 shell**（內部跑 `mn -c`）。單獨一行跑。
- 🔴 **`cleanup` 不會停掉 topo 的 tmux session**。殘留的 session 讓拓撲拒絕啟動，
  而 `topo-out` 還在印**上一輪**的 pane ——驅動腳本會把屍體讀成活的。
  **正確順序：`stack.sh down` → `topo-stop` → `cleanup`。
  `ndtwin-lab status` 才是誠實的存活檢查。**
- 🔴 **`pkill -f` 會匹配你自己 shell 的命令列**並殺掉它。用 `pkill -x` 或 PID。
- 🔴 **`until ! pgrep -f 'foo'` 永遠不會結束**——`pgrep -f` 匹配迴圈自己。加 bracket：`'fo[o]'`。
- 🔴 **裸 `sudo -n kill` 無授權，而且失敗是靜默的** → 無聲 no-op 實驗看起來像結果。
  走 `sudo -n mnexec -a 1 kill`，並且**永遠斷言注入成功**後才下結論。
- **`read -p` 的提示在 stdin 是 FIFO 時不會送出**，等提示的驅動腳本必定逾時；
  逾時後 stack.sh 會繼續前進、**在空 fabric 上啟動 proxy**。
- **`ifconfig down` 在 bmv2 上會關掉整台交換機**，不是一條鏈路。用 `tc netem`。
- **bmv2 行程會活過 `mn -c`** 變成孤兒佔住 gRPC port。

---

## 證據索引

| 輪次 | 位置 | 內容 |
|---|---|---|
| 2026-08-19 phase-2 | `scratch/phase2/FINDINGS.md`（1717 行） | 12 個實驗、10 CONFIRMED / 6 REFUTED；計畫在 `PLAN.md`（DeepSeek 盲寫） |
| 2026-08-18 live | `doc/audit/2026-08-18_live-full-stack-round/` | 我 8 條 ＋ subagent 18 條（重疊僅 1 條）＋ sFlow 準確度報告與原始資料 |
| 較早輪次彙整 | `scratch/phase2/DEFECT-INVENTORY.md`（~870 行） | 九輪（07-30 → 08-18）掃描，**92 條已驗證**：64 OPEN、6 明確不修、22 可能已修（列為有爭議而非丟棄） |
| 較早輪次原始 | `doc/audit/`（約 40 個日期目錄） | 見 `doc/audit/README.md` |

## 這份文件的完整性邊界（誠實聲明）

- **舊發現約三分之二仍然為真**（pre-08-12：33 條裡 21 條；含 08-12 那輪則 51 條裡 31 條）。
  衰減**不均勻**，而且模式很銳利：**agy Tier 1 的 6 條全部已修，Tier 2 的 13 條裡 11 條還在（85%）**。
  **嚴重度驅動了修復，其他什麼都沒有。** → 引用任何舊的 Tier 1 清單前務必重查；Tier 2 可近乎照搬。
- 🔴 **328 份 agy review 裡有 213 份從未被分類**（98 HIGH + 113 MEDIUM），
  而且那份分類文件自承它的抽取腳本不可靠。**這是庫存缺口，不是缺陷**，
  但它界定了這份文件能誠實宣稱的完整度上限。
- **一條需要重新裁決而不只是更新狀態**：agy 0211（readopt 部分失敗被 200 吞掉）在 08-17 的
  triage 裡被標為可能與「completion handle」的結論矛盾，並明確指示不要繼承任一答案。
  目前列為 OPEN 且有爭議。
- ⚠️ **一條被掃描列為缺陷、但實際上不是**：「per-link 利用率在定速流量下擺盪 ±40%」
  **是取樣理論的地板，不是缺陷**——`196 × √(1/c)`，已跨 430× 窗長與 10× 負載實測驗證。
  見 `doc/audit/2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md`。
  GUI 上看得到擺盪是真的，但那是**儀器的解析度**，修不掉。

## ✅ 已驗證為正確的核心行為（2026-08-19 round 6）

**「透過 kernel API 裝上的流規則會真的改變轉發嗎？」——四輪從沒驗證過，現在驗了：會，兩個平面都會。**

用 `/proc/net/dev` 的 tx-byte 差（獨立於孿生與交換機表）、規則強迫走**另一個**埠、
三個狀態（裝前／裝後／刪後）、定速流所以整批流量必須移動：

| 平面 | 裝前 | 裝後 | 刪後 |
|---|---|---|---|
| OVS 128-host | 100% 走 s1-eth2 | **100% 走 s1-eth1** | 回到 s1-eth2 ✅ |
| P4 bmv2 | 100% 走 s1-eth2 | **100% 走 s1-eth1** | 🔴 黑洞（見 A-4d） |

**位元對位元的同一個量**，不是比例。資料面切換次秒級，孿生的 `path` 約 3–5 秒跟上。

⚠️ **量路徑變化不要用 `get_path_switch_count`**——OVS 三個狀態它都回 5。
有鑑別力的欄位是 `get_detected_flow_data` 的 `path`。

## 三條對本文件既有敘述的更正（round 6）

1. **128-host 拓撲是 32 條交換機間鏈路 / 288 條邊**，不是 40。（40 是 4-host cell。）
2. **電源循環的 qdisc 遺失在 4-host cell 是 2 個介面**，128-host 是 4 個——
   差別是另兩個面向 10 G 核心鏈路，**Mininet 從來沒整形過它們**（見 §F）。
3. 🔑 **`up=false, en=true` 是關機交換機的正常穩態**，所以
   **「兩個旗標不一致」本身不能當故障訊號**。這收窄了 A-2 指紋的適用範圍——
   A-2 的指紋是特定的 `up=true, en=false`，不是「任何不一致」。

**REFUTED 的紀錄同樣有價值**，別重測：E1（OVS 電源循環後流表**會**重裝）、
E-H3（8 種畸形 dpid 全部正確拒絕、graph diff 空）、`get_openflow_capacity`、
`get_static_topology_json`、批次端點的混合 dpid 誠實度、
E8（雙平面的鏈路故障/恢復都正常，過度回報窗口是 0–30 秒取決於相位）、
E9（top-k 成員/排序/速率全對，`bps ÷ pps` 分毫不差）、E11（`--no-ai` 防護正常）。
