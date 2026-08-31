# NDTwin — 已知未修缺陷

**缺陷清單的普查基準日：2026-08-19**　　涵蓋到 kernel `04b8933`＋分支 `fix/flow-rate-divide-by-zero`

**2026-08-29 增補（只動了兩處，其餘條目仍是 08-19 的普查結果、未重驗）**：
① **§F 新增 `F-bmv2`** —— 08-28/29 四張工單（②封包大小／①＋①b build 比值／③流數）收案後的
實測天花板，並退役 §F 舊的無出處數字；
② **§D 的 F-17 標記為「前提已被推翻、待重裁」**（更正全文在 §C 表下）。

**2026-08-30 對帳（基準 `1208d22`）**：一次**只修衰減、不重排**的普查對帳。
每一條的碼都重新 grep 過，狀態行標了日期與 commit。改動集中在四處：
① **B-2 拆成兩半** —— 隱式代入 `routing_lock` 那一族已修（`4ee086f`＋`87d272f`），
**過期續約與無 owner 兩條原始問題都沒修**，所以拆而不關；
② **B-3 的回覆形狀已變**（`aabe605`，08-20 就修了、清單漏標十天），但**寫入零筆照舊**，
且**兩個分支都回 200 `success`**，看狀態碼的呼叫端仍然分不出來；
③ **§C／§D 的 `F-4` 加了消歧註** —— 08-18 那個目錄裡有**兩套各自編號的 F-n**，
本週 R-5 說「F-4 已修」指的**不是**這裡這一條；
④ **§G 新增 T-4 輪的儀器缺陷區塊**（FINDING-01…05）。
🔴 **本輪沒有跑任何東西**（量測窗開著），所有判斷都是讀碼；標「實測」的一律是引用他人已跑的結果。

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

- **狀態**：~~報告前不改碼，用操作繞過（2026-08-19 裁定）~~ ⇒ 2026-08-30 Adam 改裁「修」⇒
  **修法已落（`98e890a`，2026-08-31 併入）並過變異閘**（A-1 五顆全殺、對照顆 13 輪全綠、46/46）。
  **live 配方 2026-08-31 已跑**（`2026-08-31_live-recipes/`）：arm1 窗內 power-on **PASS**
  （2.160 s、count 9→10、kernel.log 有真實 `switch s1 -> on` 行——不是 0.01 s 假成功）、
  arm2 sleep-20 對照 **PASS**（3.046 s；第一輪誤判是取樣太早的儀器假象，隔離重跑正名）；
  ⚠️ arm3（I1/I5 重複 power-on）**INCONCLUSIVE**——量測當下交換機是關的，而不變式是關於
  開著的交換機，觀測不具鑑別力；連同 ping 子句排入 F-5 新輪重跑。**arm3 綠前不改 RESOLVED。**
  （原配方三缺陷已更正入 §5：port 8081→8000、`switch_ip`→`ip`、pgrep 15 字元截斷儀器。）
  落地前 15 秒繞法仍有效於未帶此修的 build。
  **本條在該檔 §4 的變異測試跑綠之前不得改標 RESOLVED**（A-3 就是修好後被掛 OPEN 八天的反例）
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

- **狀態**：**kernel 側修法已落（`687de6c`）、過變異閘（2026-08-31：A-2 五顆全殺、46/46），
  且 §5.3 live 已於 2026-08-31 15:21–15:25 跑過並通過**——
  三個 curl 加 `--connect-timeout 2 --max-time 5`（兩旗標對兩種實測故障：131 秒 IPv6 黑洞
  與 Ryu wedge）、`-s`→`-sS`、每輪一行邊沿觸發 WARN＋恢復 INFO。
  - **live 量到的**（binary `build/bin/ndtwin_kernel` sha256 `e3bad23c…f1b94`／md5
    `5f2e701e…a858`，`strings` 驗出兩條修法字串各 1 次，**無 RUNPATH**⇒走預設載入路徑；
    fabric＝`ndt up ovs4`）：`iptables -I INPUT -p tcp --dport 8080 -j DROP` 期間
    **四個 poll pass 只發一行 WARN**，elapsed **6.024s**（有界，不是 733 秒），
    kernel 執行緒數不變、行程續活；拆掉規則後**恰好一行**
    `topology poll answered again after 4 silent pass(es), in 0.628s`。
    「四個 pass」有兩個互相獨立的證人：`/proc` 掃 curl 子行程（t≈4/40/76/112s）
    與恢復行自己的計數器——**少了前者，「只發一行」與「執行緒死在第一輪」分不開**。
    `-sS` 也驗到了：`curl: (28) Failed to connect to localhost port 8080 after 2001 ms`
    進了 log。raw＝`doc/audit/2026-08-31_live-recipes/raw/{drive_a2_wedge.sh,a2_wedge.log,
    a2_kernel.log}`。
  - 🔴 **明列未覆蓋範圍（三項，不要讀成「A-2 已修」）**：
    1. **`--max-time 5` 那一支未經 live**。iptables DROP 丟的是 SYN ⇒ 永遠走
       `--connect-timeout`；要打到 `--max-time` 需要「accept 之後不回」的 controller，
       授權的那條規則做不出來。目前**只有單元變異閘 M10**。
       ⇒ 補法**不需要 sudo**：停掉 Ryu，用十行 python listener 佔住 `:8080`、accept 後不寫。
       配方＝`doc/audit/2026-08-31_live-recipes/rider_a2-max-time.md`，**掛在下一個 fabric 窗**。
    2. 🔴 **Ryu 那端完全沒動**：`intelligent_router.py:304` 的 `get_link()` 仍會永久阻塞
       （兄弟 `get_switch`（`:284-288`）有 20 秒有界重試，它沒有）。
       **kernel 側的修法只讓症狀有界並發聲，並沒有移除成因**——真實世界那一次
       是 Ryu wedge 觸發的，修法之後同樣的 wedge 仍會發生，只是 twin 現在會說出來。
    3. **「部分套用」未處理**：一輪裡 switches 有回答而 links 沒有，仍然會把拿到的那半套上去
       （`updateSwitches`／`updateHosts`／`updateLinks` 各自對空 body 早退）。
       這是修法前就有的行為，`687de6c` 刻意沒改；見 §6 開放問題 3。
  ⇒ **本條不是 RESOLVED，也不是「kernel 側已修」四個字就能結案**：
  live 成立的只有「三個 curl 會結束」與「結束不了會說出來」這兩件事。配方＝
  `doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md` §5.3（該節的
  「elapsed ~15s」判準已於本輪更正為 ~6s——**原判準會讓一個正常運作的修法被判 FAIL**，
  屬 **A-8** 那一族；判準要跟著故障注入手法走，換注入就要重推期望值）。
  〔修前存證（2026-08-30 ledger 讀碼重驗於 `1208d22`）：`include/utils/Utils.hpp:543-568`
  裸 `popen()` 無 timeout、三個 curl（`TopologyAndFlowMonitor.cpp:472/485/498`）無
  `--max-time`；且已收窄＝那三個是 kernel 僅存的無界 curl，其餘南向全有界
  （`HttpRoutingStrategyBase.cpp:82`、`FlowLinkUsageCollector.cpp:2496`、
  `DeviceConfigurationAndPowerManager.cpp:820/835/848`、`P4PowerStrategy.cpp:82`）〕
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
兩者是不同的函式。🔑 **2026-08-29 確認這個區分不只是形式上的**：F-17 那個端點
**在 ESA 裡零呼叫端**，所以它根本碰不到這條決策路徑（見 §C 的 F-17 二次更正）。
**A-4b 從來不依賴 F-17，而它才是真的關機風險。**

#### 🔴 A-4b 的機制已從實作確認（2026-08-29，讀碼，未實跑）

`group_avg_link_utilization`（`Energy-Saving-App/src/common/types.cpp:396`）：

| 行 | 做什麼 | 為什麼要命 |
|---|---|---|
| `:410` | `if (g[*ei].isUp == true && g[*ei].isEnabled == true)` | **分母收「所有 up+enabled 的邊」，完全不篩忙碌** ——**與 kernel 的 `getAvgLinkUsage` 正好相反** |
| `:412-413` | `utilizationSum += …; edgeCount++;` | 沒流量的邊貢獻 0 到分子、貢獻 1 到分母 |
| `:423-425` | `if (edgeCount == 0) return std::nullopt;` | **只有「一條 up+enabled 的邊都沒有」才回 `nullopt`** |
| `:427` | `return utilizationSum / (edgeCount * 100.0);` | 邊活著但沒流量 ⇒ **回 `0.0`，不是 `nullopt`** |

⇒ `0.0 <= LOW_WATER_MARK`（**0.40**，`Energy-Saving-App/include/app/settings.hpp:7`）⇒ **關機**，
而利用率永遠碰不到 `HIGH_WATER_MARK`（**0.6**，同檔 `:6`）⇒ **不會再開回來**。

📎 **哪些既有程序會製造這個條件**：三份操作手冊都提醒「同一台交換機底下的 host 互打，
`get_average_link_usage` 永遠是 0.0」——**那個網路狀態（交換機間邊都活著但沒有流量）
正好就是本條的觸發條件**。⚠️ **但那三份手冊都不啟動 Energy-Saving-App**
（2026-08-29 實查：兩份零次提及、OVS 那份唯一一次在講別的端點），
所以**對照著那些手冊操作不會發作**；會發作的是**把同樣的網路狀態帶到 ESA 有在跑的環境**。
手冊：`doc/2026-07-30_full_test_runbook.md` §1d（完整版）、
`doc/2026-07-29_p4_status_and_test_guide.md`、`doc/2026-08-10_ovs_manual_test_runbook.md`。

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
  delete 又把它撤掉——原本的路由沒有回來。proxy 自己的註解
  講了「每個 prefix 一筆」這個前提，**但漏了這個後果**
- 📌 **行號更正（2026-08-30，`1208d22`）**：原文引的 `api_routes.py:190-204`
  **現在指向不相干的碼**（`_flowentry_body` 的 JSON 解碼守衛）。
  那段前提註解已移到 **`api_routes.py:253-255`**；delete 路徑在
  `topology_manager.py:813-821`（刪完 `pop` 掉紀錄就結束，**沒有任何還原邏輯**），
  而 `topology_manager.py:683-685` 的 docstring 現在明寫了
  「OVS 是 priority 100 疊在 10 上、這裡是取代該目的地唯一的一筆」——**前提寫得更清楚了，後果仍然沒寫**。
  ⇒ **機制與結論不變，只有引用位置要換。**
- **🔑 為什麼排在 A 節**：**一個會自己清理的 app 就會觸發它。** TE app 遷移完流量後刪掉
  自己的規則是完全正常的行為
- **證據**：實測雙平面對照，`scratch/round6/FINDINGS-round6.md`

### A-4e 🔴 `modify_flow_entry` 忽略 `priority`，會改到別人的規則而且傷害存活

- **狀態**：🟢 **RESOLVED（2026-08-31）**——修法 `c46c51e`＋變異閘（四顆全殺、46/46）＋
  **live 雙驗**：§3.3 阻斷檢查對活 Ryu 回 **200**（路由存在，07-29 指南清單過時）；§5.2 讀回
  真表＝prio-100 規則 `OUTPUT:1→3` 而 prio-10 規則**原封**（`duration_sec` 連續 8.0→16.0，
  被重寫會歸零——正是「同一筆、counters 沒動」那把尺）。
- **平面**：兩者共用同一份 C++（🔄 08-30 更正：`P4RoutingStrategy` 沒有 override `modifyAnEntry`，
  分岔在 proxy 端只服務 `modify`——修法因此帶 `strictModifyPath()` override 保 P4 不變 404）
  ⚠️ **08-30 讀碼更正：「P4 走不同路徑」只在 proxy 那一端成立。**
  `P4RoutingStrategy` **沒有** override `modifyAnEntry`，所以 **C++ 這一段兩個平面共用同一份碼**；
  分岔點在 proxy——它自己會從 body 讀 `priority`（`topology_manager.py` `modify_flow`），
  而且**只服務 `/stats/flowentry/modify`、沒有 `modify_strict` 路由**。
  ⇒ 無條件改送 strict 會讓**每一次 P4 modify 變成 404**，而因為 flow 路徑是非同步的，
  呼叫端仍會拿到 200 `queued`，**看不見**
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

### A-5 ~~每次 kernel 重啟都會截斷前一輪的 log~~ —— **已修（2026-08-30 更正）**

- **狀態**：🟢 **RESOLVED（2026-08-31，全鏈收齊）**——主機制 `b2e5b04`；深度 2 增強 `8e7e3b0`
  ＋變異閘（M-6 殺且四條 depth-1 舊檢查全綠、M-7 恰 6 紅）＋**三世代 live PASS**：兩次重啟後
  `.prev2` 首行與跑到一半即時擷取的 era-1 首行 `cmp` **逐位元組相同**、種入的 era-0 誘餌被
  逐出＝深度確實封頂 3、無 `.prev3`。
  ⚠️ **本條在 `b2e5b04` 之後仍被留成 OPEN，2026-08-30 才發現**——
  派工單據此指示去修 `src/utils/Logger.cpp`，那裡**本來就是 append**
  （`basic_file_sink_mt("netdt.log", /*truncate=*/false)`），**假設整個是錯的**
- **平面**：兩者
- **真正的機制（原文沒寫對）**：截斷不在 kernel 裡，在 **launcher 的 `>` 重導**——
  `stack.sh` 的 `start_bg`。`doc/2026-08-14_cross-component-integration-matrix.md:170` 早就寫對了。
  kernel 的 log 走 stdout，`--logfile`／`netdt.log` **stack.sh 從來沒傳過**，是死路徑
- **已修**：`b2e5b04` 把 `>` 前面加上 `mv -f "$log" "$log.prev"`，
  三個 log（`kernel.log`／`p4_proxy.log`／`ryu.log`）都走同一個 `start_bg`，全部涵蓋；
  測試 `tests/shell/test_start_bg_log_rotation.sh`
- **🔴 殘留（2026-08-30 補修）**：一代不夠。A-2 的繞法就是「重啟 kernel」，
  症狀復發你會再重啟一次——**第二次重啟把「有證據的那一代」換成「什麼都沒有的那一代」**，
  正好是本條講的示範情境。已改成 **深度 2**（`.prev` → `.prev2`），磁碟仍有界
- **🔑 繞法（仍然適用於超過兩代）**：連續重啟三次以上，還是要把 log 複製到別處
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`（舊輪次掃描，機制寫錯）；
  修法與複驗 `doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md`

### A-6 ~~P4 proxy 每次啟動都宣告「這輪毀了」~~ —— **已修（2026-08-30 更正）**

- **狀態**：🏁 **已修，本條原文已過期**。
  ⚠️ 與 A-5 同型：`11789e0` 修掉之後**本條仍被留成 OPEN**，2026-08-30 才發現
- **平面**：P4
- **原本會發生什麼**：proxy 在**每次**啟動時印出「the graph will stay partly disabled … for the
  rest」之類的訊息。那是假的——`inform_switch_entered` 會重試而且會成功。
  台下看到這行會以為系統壞了
- **已修**：`11789e0`（`p4_proxy/proxy_agent/main.py:259-279`）。三件事一起做了：
  1. 訊息**變成有條件的**——`if not not_entered` 走「全部認可」那支
  2. 剩下那支改寫成啟動當下**真正知道的事**：
     「normal when the kernel starts after the proxy … retrying the push in the background」，
     並指名 kernel 的 topology poll 自己就會 enable（`TopologyAndFlowMonitor.cpp:566`）
  3. 補上一個**有界的背景重試**，讓訊息講的「會自己好」真的成立
  原始碼註解自己記著這條的來歷：**2026-08-15 的 overnight audit 相信了那句話，誤診了一個健康的 era**
- **⚠️ 本條的另一半沒修、也不在本輪範圍**：`cleanupAppFolder` 仍會噴
  **17 條敘述後果為假的警告** ＋ **9 個裸的 sudo 密碼提示打到 stderr**（未複驗，沿用原記載）
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`；
  複驗 `doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md`

### A-7 排隊寫入的失敗對所有 API 都不可見

- **狀態**：🟢 **RESOLVED（2026-08-31）**——`DispatchOutcomeLog`＋`GET /ndt/get_flow_dispatch_status`
  （`2016d4c`／`636f9ab`），變異閘 M11 為首全數通過，**live P5 六項全中**（壞 port ⇒ `failed`+1、
  `recent_failures` 帶 dpid/priority/match；合法規則對照 ⇒ `succeeded`+1 其餘不動）、M15 淘汰算術閉合。
  ⚠️ 兩個語意邊界（實測）：`dispatched` 只數**經兩個 dispatch API** 的請求（開機編程對它隱形）；
  「southbound 說 ok」≠「表與請求一致」（FINDING-07：priority 落地恆 0）。
  〔歷史：曾裁延到報告後、列簡報 Page 35 誠實未解清單〕
- **平面**：兩者
- **失效方向**：（修前）樂觀 ＋ 靜默
- **會發生什麼（修前）**：契約測試套件**全綠**，而同時 `kernel.log` 寫著 `dispatched install failed`。
  沒有任何 API 表面暴露那個失敗——**log 且只對失敗寫**（08-31 對帳：失敗行 261 vs `failed=261`
  一致；成功行 0 vs `succeeded=1`）
- **與 B-1 的關係**：B-1 是「拒絕沒被記錄」，這條是「失敗被記錄了但沒有 API 讀得到」——
  同一個斷鏈的兩端
- ⚠️ **2026-08-30 讀碼重驗：多了一個計數器，但斷鏈沒有接上（狀態不變）。**
  `aabe605` 為 `FlowDispatcher` 在 `stop()` 之後被丟掉的 job 加了計數與一次性警告
  （`include/ndt_core/routing_management/FlowDispatcher.hpp:116` 的 `droppedAfterStop()`、
  `:135` 的 `droppedAfterStop_`）。**但 `droppedAfterStop()` 在 `src/ndt_core/http/` 底下零個呼叫端**
  ——證據存在於行程記憶體裡，**仍然沒有任何 API 表面讀得到它**。
  ⇒ 本條的宣稱逐字照舊成立；這是 [[existence-is-not-wiring]] 的形狀，
  **「加了計數器」不等於「暴露了失敗」**。
  ⚠️ 另註：`aabe605` 補的是 **stop() 之後丟棄**那一種，本條原本引的
  `dispatched install failed` 是**另一種**失敗，兩者不要混為一談。
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`

### A-8 三個測試工具在系統正確運作時變紅

- **狀態**：OPEN。**2026-08-30 實跑重驗仍然成立**（T-4 輪 R-5，kernel `89c1754`）：
  契約套件對著一座 Energy-App **正確**降級過的網路，報了 8 行 `switch(es) not up` ＋ 1 行 `BROKEN`，
  而那 20 條 down 的邊每一條都連著一台已關機的交換機——**孿生的帳是對的，抱怨的是套件**。
  正本 `doc/audit/2026-08-30_live-full-stack-round/R5-result-both-arms.md`（該檔的 **F-2** 列）。
  ⚠️ **那份檔案裡的 `F-2` 就是本條**；不要跟 §C 表的 `F-2`（不存在）或 subagent 那套編號混用，見 §C 表下的消歧註
- **平面**：兩者
- **失效方向**：悲觀
- **會發生什麼**：Energy-Saving-App **正確地**關掉一台交換機時，L2 契約測試、L3 契約測試、
  log allowlist 三個工具同時turn紅
- **為什麼重要**：一個在系統正確時變紅的測試套件，會訓練它的讀者**忽略紅色**
- **證據**：實測，`doc/audit/2026-08-18_live-full-stack-round/` F-2 / N-9

### A-9 🔴 Energy-App 拿了 `routing_lock` 就永遠不放（TR-5 三臂 0 台被關的原因）

- **狀態**：OPEN（2026-08-30 TR-5 發現＝FINDING-08；三臂重現：P4、OVS、乾淨重跑臂一致）
- **平面**：兩者（缺陷在 Energy-Saving-App 的呼叫序）
- **機制**：兩個 `release_lock` 呼叫都在「需要 Simulation-Platform-Manager 的模擬往返」後面；
  該往返不可達時 app 對 423 以 1 Hz 空轉滿 **300 秒 TTL**——比 241 秒的 energy watch 還長，
  於是 watch 只數到重試；**鎖活過 `energy-stop`**。
- **會發生什麼**：示範時 Energy-App 第一輪就把自己廢掉，0 台交換機被關；之後任何要
  `routing_lock` 的操作都吃 423 直到 TTL 到期。
- **繞法**：`POST /ndt/release_lock {"type":"routing_lock"}` 手動清鎖。
- **真修**：動 Energy-Saving-App repo（等 Adam 裁）；週四 demo 用繞法。
- **證據**：`doc/audit/2026-08-30_live-traffic-round/`（TR-5 三臂：0 台被關、acquire_lock
  183/188/183；`776c91e`／`ec515ce`）

---

## B. 需要特定操作才會踩到

### B-1 被交換機拒絕的規則，twin 當成存在的來服務（幽靈規則）

- **狀態**：OPEN（2026-08-18 裁定報告前不修）。
  **2026-08-30 實跑重驗：兩個平面都仍然發作，而且機制第一次被指認出來**
  （T-4 輪 R-5／FINDING-03，文件 commit `2bfb958`，kernel `89c1754`）。
  **機制**：kernel 的**流表視圖**把一個**已排隊但尚未編程**的請求當成流表列服務出去，
  剝掉了真實流表列會帶的每一個統計欄位。
  指紋有鑑別力且兩平面一致：該筆只有 4 個欄位（其餘 41 筆有 13 個）、
  `actions` 是**物件**（`{"port":999,"type":"OUTPUT"}`）而不是字串（`"OUTPUT:3"`）、
  match 用的是**請求自己的詞彙**（`eth_type`/`ipv4_dst`）而不是 OpenFlow 的（`dl_type`/`nw_dst`）。
  ⇒ **回音在 kernel 的表格視圖，不在任一資料面的寫入路徑。**
  🔑 **API 本身是誠實的**：它回 `{"status":"queued","accepted":1,...}` 並且真的只是排隊了；
  **過度宣稱的是表格視圖**。
  ⚠️ **不要用它解釋本條原本記的 7.2–8.2 秒**：FINDING-03 量到的窗口在 t=2（P4）／t=3（OVS）就沒了，
  該檔**明文不宣稱**這和 08-18 量到的 ~8 秒是同一個現象（「同一個指紋，與舊時長的關係未知」）。
  ⚠️ **08-18 說「P4 上這個窗口不存在」是錯的**，原因是取樣格的**第一格就在 t=2**、已經在事件之後；
  **這不是資料錯，是格子沒對準**。
  📌 修法已開工單 **T-11**（`doc/2026-08-30_manual-verification-report.md:96`，狀態＝已開、修法待裁）；
  **T-11 這個編號不在 FINDING-03 檔內**，引用時要引工單表那一行
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
- 🟢 **kernel 視圖那一半已修（T-11-A `91e7743`，2026-08-31 live 力紅力綠雙向驗證）**：
  表列只報南向已確認的列（token provenance），pre-T-11 binary 幻影 t=0.005s 現／T-11 binary
  25 秒全程不現。**兩個明界**：①已確認列在下一次 poll 前（實測 **7.4 秒**）仍帶請求 priority
  與呼叫端字彙——FINDING-07 地盤，不在本修範圍；②**只 token 了 install**——被拒的
  modify/delete 仍反向污染快取（少報、≤10.7s poll 自癒），已登記鏡像票（週四後）。

### B-2 鎖在兩種平常情況下不提供互斥

- **狀態**：**OPEN，兩條原始問題一條都沒修**（2026-08-30 讀碼重驗，`1208d22`）。
  🔴 **本條在 08-30 被拆過一次**：這一週動到鎖端點的兩顆 commit
  （`4ee086f`＋`87d272f`）修的是**第三族**問題——「請求沒指名鎖，卻被代入 `routing_lock`」，
  那一族已收在 **B-2d**。**它們沒有碰下面這兩條。**
  ⚠️ **所以看到「acquire_lock 三個缺陷已修」不要順手把本條關掉**，兩件事只是共用同一個端點。
- **平面**：兩者（純 kernel）
- **失效方向**：靜默（兩邊都回 200）
- **兩個獨立問題**：
  1. **續約一個已過期的鎖回 200**（契約寫 412）。`LockManager::renew` 只檢查 map entry
     存在且 `isLocked` 為真，**從不比較 `now < expiryTime`**；而 `isLocked` 只有 `unlock()`
     或 `acquireLock()` 會清掉，**過期不會清**。
     實測的有鑑別力變體：一個**什麼都沒持有**的 client 把**別人的**鎖從 3 秒延長到 120 秒，
     並把第三方鎖在門外。
     ✅ **2026-08-30 逐行重驗仍然成立**：`include/ndt_core/lock_management/LockManager.hpp:256-271`
     的 `renew()` 判斷式逐字是
     `if (m_locks.find(type) == m_locks.end() || !m_locks[type].isLocked)`——**沒有任何時間比較**。
     🔑 **對照組就在同一個檔案裡**：`acquireLock()`（`:210`）寫的是
     `if (state.isLocked && now < state.expiryTime)`，**它比了**。
     ⇒ **這不是「整個類別都沒有到期概念」，是 renew 這一支漏掉**，所以修法很窄。
  2. **任何人可以釋放任何人的鎖**。`LockState` **沒有 owner 欄位**，`unlock()` 為呼叫者清鎖。
     真正的持有者只會從下一次失敗的 renew 得知自己被踢出臨界區。
     ✅ **2026-08-30 逐行重驗仍然成立**：`LockManager.hpp:18-21` 的 `LockState`
     只有 `isLocked` 與 `expiryTime` **兩個欄位**，仍然沒有 owner／token；
     `unlock()`（`:236-251`）只認鎖的**名字**，不認**誰**在呼叫。
     ⚠️ `unlock()` 這一週確實改過（`1145372` 讓它回 bool、釋放沒人持有的鎖改回 412），
     **但那是「有沒有被持有」，不是「被誰持有」**——**擁有權的洞原封不動**。
- **實際影響**：Energy-App 與 TE-App 都取同一把 `routing_lock`，各自 6 次/分鐘。
  任何超過 TTL 的持有都開啟「兩個 app 都以為自己擁有網路」的窗口
- **⚠️ 更大的脈絡**：這條擋住了整個併發控制的路——見 memory
  `ndtwin-cannot-do-either-concurrency-control`
- **證據**：實測，`scratch/phase2/FINDINGS.md` E3/E4；round-2 的 F-11 是同一族

### B-2d 三個鎖端點會把「沒指名鎖」的請求代入 `routing_lock` —— 從 B-2 拆出

- **狀態**：🟢 **RESOLVED（2026-08-30，`4ee086f`＋`87d272f`）。** 2026-08-30 讀碼確認。
  **本條是 08-30 對帳時從 B-2 拆出來的**：它與 B-2 共用端點但**是不同的缺陷**，
  而且**只有它被修了**——把它跟 B-2 綁在同一條裡，會讓 B-2 看起來像是修好了。
- **平面**：兩者（純 kernel）
- **失效方向**（當時）：靜默 ＋ **主動誤導**（回覆裡指名一把呼叫端從沒提過的鎖）
- **曾經發生什麼**：`/ndt/acquire_lock`、`/ndt/renew_lock`、`/ndt/release_lock` 三個端點各自
  在行內解析、**先把預設值指派好**，再用 `catch (...)` 吞掉解析錯誤往下走。於是
  **①body 不是 JSON、②JSON 裡沒有 `type`、③`type` 指名一把不存在的鎖**，
  三種完全不同的情況**全部落到 `routing_lock`**——那正是序列化真實交換機寫入的那把鎖。
  🔑 **最傷的不是亂碼那一種**：一個持有 `power_lock` 的 app 不帶 body 送 renew，
  **延長的是別人的 routing 租約**，自己被回 200 `"renewed"`，
  而它自己的租約**一秒沒有被延到**。release 同理，**兩把鎖同時錯、任何地方都沒有錯誤訊息**。
- **修法**：抽出**單一**解析接縫 `LockManager::parseRequest`
  （`include/ndt_core/lock_management/LockManager.hpp:102-147`）＋
  單一訊息表 `describeError`（`:162-184`），三個端點共用
  （`src/ndt_core/http/HttpSession.cpp:1924`／`:1978`／`:2038`）。
  **什麼都不再預設**：`type` 沒指名就是 400、**而且不碰任何鎖**；
  `ttl` 仍然有預設，理由寫在碼裡——**它是時長不是標的，弄錯不會讓請求作用到別的東西上**。
  狀態碼也分開了：**request 錯 = 400**（acquire 舊碼回 423、renew/release 回 412），
  **狀態錯才是 423／412**——「你該重試」與「你的請求是錯的」不再共用一個碼。
- 🔑 **修法自己做了呼叫端普查才拿掉 fallback**：三個 release 呼叫端
  （`Energy-Saving-App/src/app/http.cpp:461`、`Traffic-engineering-App.py:85`、
  chaos harness `probes.py:206`）與契約測試**全都明送 `type`**
  ⇒ **那個「文件說 body 可選」的預設，沒有任何使用者**。
- ⚠️ **本條 RESOLVED 不擴及 B-2 的兩條**（過期續約、無 owner）——見 B-2 的狀態行
- **證據**：讀碼（2026-08-30，基準 `1208d22`），**本輪未實跑**；
  修法 commit 訊息記載 08-29 曾以狀態判準實跑驗過 acquire 那一支
  （`"{this is not json` 回 `{"status":"locked","type":"routing_lock"}`、第二個 client 隨即取不到鎖）

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

⚠️ **「14」這個數字重數不出來（2026-08-30，`1208d22`）—— 結論不動，但引用前要知道。**
本輪逐一追執行器重數，得到 **11 個**走 `utils::execCommand` 的 curl 構造點：
`TopologyAndFlowMonitor.cpp:472/485/498`、`HttpRoutingStrategyBase.cpp:82`、
`SimulationRequestManager.cpp:124` 與 `:150`、`FlowLinkUsageCollector.cpp:2496`、
`DeviceConfigurationAndPowerManager.cpp:222/820/835/848`。
第 12 個（`P4PowerStrategy.cpp:82`）走的是 `executeSystemCommand`（`std::system`）**不是** `execCommand`
——**同樣經過 `/bin/sh -c`，所以暴露面相同，但不屬於這個計數**。
**原文那個 14 是用什麼母體數的，本輪查不出來**（一個可能是 `HttpRoutingStrategyBase.cpp:82`
被展開成它服務的 10 個 `post()` 動詞，那樣會得到 20，也不是 14；**這是推測不是結論**）。
🔑 **這不影響本條的任何判斷**：漏洞成立與否取決於**構造存在**，不取決於它有幾份；
**「不要在單一呼叫點加跳脫」的修法規則照舊**，只是那句話涵蓋的是 11（＋1）個地方而不是 14 個。

⚠️ **`validateRequestBody()` 只檢查形狀，不是修補**——`SimulationRequestManager.cpp:115-121` 的註解
明文這樣寫，這裡重述是因為「有驗證函式」很容易被讀成「有防護」。

🔑 **為什麼它被低估了一整個級別，這比漏洞本身更值得記：**
本條的「實務觸發」寫的是「**目前只送數字與 IP，所以不會自然發作**」——
**那是一句關於「意外」的話，卻被拿來給整條定級。**
**「不會自然發作」不等於「不會發作」**：自然發作的機率由正常使用決定，
**故意發作的機率由有沒有人想這麼做決定**，兩者無關。
⇒ **凡是分析「這個壞掉的輸入會怎樣」的條目，都要再問一遍「有人故意送這個輸入會怎樣」。**

**修法不變、優先級改變**：仍然是「一次做完、所有呼叫點、改用 argv 執行器」（見上面兩處註解，
它們都明說不要零星修補）。**不要在單一呼叫點加跳脫**——那會讓其餘的看起來已經被處理過
（原文寫「13 個」，依上面的重數應為 10 個＋走 `std::system` 的那 1 個）。

📌 **本增補由 DeepSeek 在設計 chaos harness 的行動面時獨立指出**，審查員逐項複驗：
四個環節全部親自看過原始碼確認。**它找到的不是新缺陷，是一個既有條目沒有寫完的那一半。**
- **證據**：實測雙平面對照，`scratch/round4/FINDINGS-round4.md` 實驗 2 ＋ 實驗 5

### B-2c P4 proxy 對 CIDR 形式的 `ipv4_dst` 回 500（未處理的 `OSError`）

- **狀態**：🟢 **RESOLVED（2026-08-31）**——修法＋變異閘（M-1〜M-5 全殺、49/49＋8/8）＋
  **live 四驗全 PASS**：CIDR ⇒ 400、body 引呼叫端原字串 `"10.0.0.5/32"`（剝去完整出現後
  **零個裸替換值**）、含「No rule was installed」；accept-path 對照 200；B-2c-b（數值欄位仍
  500）照註冊仍開、只記錄未修。round 4 發現；2026-08-30 讀碼重驗（`1208d22`）
- **平面**：P4
- **失效方向**：吵（500），但錯誤沒有說明原因
- **機制**：`route_flow` 寫死 `/32`，然後把呼叫者給的值直接丟進 `inet_aton`——
  值本身若已是 CIDR 形式（`10.0.0.5/32`）就丟出未捕捉的 `OSError`
- 📌 **現行位置（本輪補上，原文沒有給行號）**：寫死 `/32` 在
  `p4_proxy/proxy_agent/topology_manager.py:767`，值從 `:717` 的
  `match_dict.get("nw_dst") or match_dict.get("ipv4_dst")` 原樣傳進來；
  `inet_aton` 在 `p4_proxy/proxy_agent/p4_client.py:819`，**且落在 `try:` 之外**
  （該 `try` 從 `:836` 才開始、只捕 `grpc.RpcError`）。delete 路徑同形（`p4_client.py:899`）。
  上游沒有任何一層會轉譯它：`api_routes.py:229-235` 只捕 `UnsupportedMatchError`、
  `_flowentry_body`（`:186-198`）只捕 `ValueError`，而
  `unsupported_match_fields` 驗的是**欄位名不是值**
- **把 kernel 排除在外也能重現**（直接打 proxy）
- **🔑 2026-08-30 增補：本條的觸發面比原文寫的寬，而且 repo 內就有生產者。**
  原文讀起來像「要有人手動送一個怪值」。實際上：
  - `unsupported_match_fields` 驗的是**欄位名**，不是**值** ⇒ `nw_dst` 是合法欄位，直接放行
  - **三個動詞都中**：`route_flow`／`unroute_flow`／`modify_flow`，
    分別落在 `p4_client.py:819`／`:899`／`:948` 的同一個 `inet_aton`
  - **來源側也中**：5-tuple 路徑的 `_encode_5tuple_value`（`p4_client.py:687`）
    對 `nw_src`／`ipv4_src` 走同一個 `inet_aton` ⇒ 只修目的端會**看起來修好了**
  - **🔴 repo 內就有生產者**：`IntentTranslator.cpp:359-362` 把驗證代理的 `ipv4_dst`
    原樣複製成 `nw_dst`，而 `validation_agent_prompt.txt:113` **明文告訴模型 CIDR 是允許的答案**
    ⇒ 這不是只有手打 curl 才碰得到
- **修法**：在 `topology_manager.py` 加 `check_match_values()`，三個動詞各呼叫一次，
  丟 `MalformedMatchValueError(UnsupportedMatchError)` ⇒ 走 `api_routes` **既有**的 catch 變 400。
  **用 `socket.inet_aton` 自己當判準**（不自己寫更嚴的 parser），所以不會新拒絕今天會動的輸入
- **⚠️ 未涵蓋（同族，另計）**：flow_5tuple 的**數值欄位**
  （`in_port`／`ip_proto`／`tp_src`／`tp_dst` 等）走的是 `int(value).to_bytes(width)`，
  非數字字串仍 `ValueError`、超出範圍仍 `OverflowError`，**兩者都還是 500**。
  本輪刻意不一起修（改動面會擴到編碼寬度表，量測窗內無法驗），**登記待裁**
- **⚠️ 跨 repo 契約**：500→400 對北向是**可見的變更**。`HttpSession.cpp:735-758` 把 4xx/5xx
  原樣穿透，所以 `/ndt/install_flow_entry` 在 P4 模式下的回應會從 500 變 400。
  in-repo 確認無人期待 500（`tools/contract_test/spec.py` 唯二的 `expect_status=[200,500]`
  是 `/ndt/historical_logging`，與此無關；南向 `HttpRoutingStrategyBase.cpp:103` 對 400/500 行為完全相同）。
  **七個 cross-repo caller 未檢查**，清單見證據檔
- **證據**：實測，`scratch/round4/FINDINGS-round4.md` 實驗 2 附帶發現；
  修法與預註冊 `doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md`

### B-3 historical logging 回 200「已啟用」，但一列都不會寫

- **狀態**：**OPEN，但回覆已經會講實話了——本條的措辭在 08-20 就過期，清單漏標十天。**
  🟢 **揭露部分 RESOLVED（2026-08-20，`aabe605`）**，2026-08-30 讀碼確認並更正本條目
  （T-4 輪 R-1 實跑觀察到現行形狀）。
  🔴 **沒有 RESOLVED 的是本體**：MININET 下**仍然一列都不會寫**，
  修的是「回覆不再謊稱有在錄」，不是「開始錄」。
  🔑 **可判斷的欄位是 `recording`，不是 `status`**（兩分支都回 200 "success"）——
  契約自 2026-08-31 起強制斷言它（`spec.py` required `recording: Bool`，對活 kernel 51/51 驗過）；
  網站 API 頁與 `doc/2026-01-02_ndt_api.md` §39 同步載明三種 shape。
- **平面**：兩者
- **失效方向**：靜默 → **現在是「誠實但仍不可由狀態碼分辨」**（見下）
- **會發生什麼（現行，`1208d22`）**：`POST /ndt/historical_logging?state=enable` 回
  **200**，body 是
  `{"status":"success","recording":false,"message":"Historical data logging is enabled, but this deployment does not record: the recorder is only started outside MININET mode, so no rows will be written."}`
  （`src/ndt_core/http/HttpSession.cpp:1801-1810`，判準是
  `include/ndt_core/data_management/HistoricalDataManager.hpp:107` 的
  `canRecord() { return m_mode != utils::DeploymentMode::MININET; }`）。
  **零筆寫入這件事沒有變**，變的是它現在會說出來。
- 🔴 **新的殘留缺陷，比舊的窄但沒有消失**：**兩個分支都回 200 且都是 `"status":"success"`**
  （`HttpSession.cpp:1804` 與 `:1813`），**只有 `recording` 與 `message` 兩個欄位不同**。
  ⇒ **看狀態碼的呼叫端、或看 `status` 欄位的呼叫端，仍然分不出
  「已經在錄」與「這個部署根本錄不了」**——而**後者是本專案每一次實跑都會走到的那一支**。
  ⚠️ **而且這個端點在 Developer Manual 上沒有任何條目**（41 條 route 裡 12 條無文件之一）
  ⇒ **呼叫端兩邊都拿不到訊號：wire 上分不出來，手冊裡查不到**。
  正本 `doc/audit/2026-08-30_live-full-stack-round/FINDINGS-T6-developer-manual-api-page.md`
  （補文件已開工單 **T-13**）
- **曾經發生什麼（修法前）**：回 200 "Historical data logging has been enabled."，然後**零筆寫入**，
  kernel log 裡**從來沒有** `HistoricalDataManager started.`
- **機制（本體，未修）**：`HistoricalDataManager::start()` 在 MININET 模式直接 return，
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
  📌 **這半句已經不成立了**：`HttpSession.cpp:1794-1800` 現在把整件事寫在 handler 的註解裡，
  並且說明**為什麼仍然回 200**——「旗標真的設了，需要被講出來的是後果」。
  **早退本身沒改**，改的是有沒有人把它寫下來。
- **實測排除了替代解釋**：不是「輸出目錄不可寫」——**根本沒有嘗試寫入**
- **證據**：修法前實測，`scratch/phase2/FINDINGS.md` E5；
  現行形狀＝2026-08-30 讀碼（`1208d22`）＋ T-4 輪 R-1 的實跑觀察。
  ⚠️ **R-1 這一輪自己判定為 UNTESTABLE**（`PRE-ROUND-R1-determination.md`：
  七個 repo 掃過，**沒有任何消費端呼叫這個端點**，所以「沒有人壞掉」不能當成「修法安全」的證據）

### B-4 模擬案例：任一欄位含單引號 → 回 202 但請求從沒送出

- **狀態**：OPEN（程式碼註解已自承）。**2026-08-30 讀碼重驗仍然成立**（`1208d22`）：
  內插逐字在 `SimulationRequestManager.cpp:124-125`，
  **同一個檔案裡還有第二處同形的**（`:150-151`），
  而 `:118-122` 的註解仍然寫著「不要在這裡零星加消毒」
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
- **2026-08-30 讀碼重驗（`1208d22`）：整條照舊，沒有一項被修掉。**
  `FLOW_IDLE_TIMEOUT 15000` 仍在 `include/ndt_core/collection/FlowLinkUsageCollector.hpp:35`；
  `getFlowInfoJson` 仍然無條件走訪整張表（迴圈 `:2296-2326`，**沒有任何 predicate**）；
  `getTopKFlowInfoJson` 仍是 `min(k, size)` 不過濾（`:2347`）；預設 `k = 50` 仍在
  `HttpSession.cpp:589`。
  🔴 **最重要的一項也照舊：回傳的紀錄裡仍然沒有任何存活性欄位**
  （`:2298-2323` 建出來的欄位是 src/dst ip、port、protocol、四個速率、
  `first_sampled_time`、`latest_sampled_time`、`path`）——
  `latest_sampled_time` 是**唯一**的間接線索，而它是**格式化過的字串不是旗標**。
  📌 行號小幅漂移：原文的 `:2291-2327` 現在是 **`:2290-2329`**（函式體）。

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

> ### 🔴 引用 `F-n` 之前先確認是哪一套編號（2026-08-30 消歧）
>
> **`doc/audit/2026-08-18_live-full-stack-round/` 這個目錄裡有兩套各自從 F-1 編起的發現，
> 而且它們在 F-1…F-6 全面撞號。** 本表用的是**其中一套**：
>
> | 檔案 | 誰寫的 | 本文件哪裡用它 |
> |---|---|---|
> | `subagent-round2-FINDINGS.md`（18 條） | subagent | **本表（§C）全部**、§D 的 `F-4` |
> | `live-findings-2026-08-18-ovs.md`（F-1…F-7） | 審查員自己 | **A-8**（該檔的 `F-2`）、**B-1**／§D 的 `F-5`（該檔的 `F-5`） |
>
> **撞號實例，看一眼就知道為什麼要寫這一段**：
>
> | 編號 | subagent 那套（＝本表） | 審查員那套 |
> |---|---|---|
> | `F-1` | cpu/mem 回傳位元組相同 | punt 規則被誤診成缺失的拓撲鏈路 |
> | `F-2` | 單向鏈路故障誤報反向 | 契約套件與 Energy-App 不能共存（＝**A-8**） |
> | `F-3` | `ecmp_groups` 是靜態檔案虛構 | 契約 schema 與文件的 `-1` 哨兵牴觸 |
> | `F-4` | **死鏈路被復活成 `is_up=true`（＝本表這一列）** | **`04b8933` 留下的過期註解** |
> | `F-5` | 無控制器的交換機仍報 `is_up: true` | **幽靈規則（＝B-1）** |
>
> 🔴 **2026-08-30 這一週的 R-5 重驗跑的是「審查員那套」**，它的結論是
> **`F-3` FIXED、`F-4` FIXED、`F-2` STILL PRESENT、`F-5` STILL PRESENT**。
> ⇒ **那兩個 FIXED 與本表這一列的 `F-4` 無關**，也不對應本文件的任何條目
> （兩者都是 `tools/contract_test/spec.py` 的契約測試問題，**從來沒有被收進本清單**）。
> **本表的 `F-4` 本輪沒有被重驗，維持 OPEN。**
> ⚠️ **這正是最容易把一條還開著的缺陷誤標成已修的路徑**：兩套編號、同一個目錄、同一週的報告。

| # | 缺陷 | 平面 | 方向 |
|---|---|---|---|
| **F-4** | 死掉的交換機間鏈路**每次 poll 都被復活成 `is_up=true`**——`updateHosts` 只憑 IP 相符就把邊標 up，而交換機自己的管理 IP 被 Ryu 當成 host 學到 | OVS | 樂觀 |
| **F-17** | `get_average_link_usage` **只平均忙碌的鏈路**（分子分母都只算非零邊）。**round 4 量化：8/32 條邊忙碌時，只算忙碌邊的平均 0.11 vs 真實 0.027，正好 4.0×**。🔴 **08-29 更正：原文寫的「這是 Energy-App 關機決策的輸入」與「標頭文件寫的是另一個公式」兩句都是錯的**——見表下 | 兩者 | 樂觀（有負載時高估 4.0×）；**失效方向的完整敘述見表下** |
| **F-14** | **host 永遠不會被標成 down**——沒有任何程式路徑可以做到。發現之後 `is_up` 是常數 `true` | 兩者 | 樂觀 |
| **F-16** | 交換機死掉時**只有交換機間的邊被標 down**，它面向 host 的邊維持 up，所以被孤立的 host 看起來還連著 | 兩者 | 樂觀 |
| **F-8** | `left_link_bandwidth_bps` 在第一次取樣前**寫死 1 Gbit/s**，所以每條 10 Gbit/s 核心鏈路只宣告十分之一的餘裕。🔑 **與「容量夾制」同根**：`link_bandwidth` 這個**模型宣告值**滲進量測欄位的**第二種方式**——F-8 拿它當**初始值**，夾制拿它當**上限**（見 `doc/audit/2026-08-27_capacity-clamp/FINDING.md`）。**兩條並列不合併**：F-8 是暫態、會被真資料取代；夾制是持久、且只在超載時觸發 | 兩者 | 樂觀 |
| **F-1** | `get_cpu_utilization` 與 `get_memory_utilization` **回傳位元組完全相同的內容**——同一個 `10 + hash(ip) % 50` 運算式；三個裝置健康指標都是交換機 IP 的常數函數 | 兩者 | 合成 |
| **F-13** | 對**不存在的** group / meter 做 modify/delete 回 200 "modified"/"deleted" 且什麼都沒改。6 個端點零契約覆蓋。⚠️ **08-30 更正機制、結論不變**：那個 200 現在是**從 Ryu 轉述**的，不是 kernel 自己捏的——kernel 已改成傳遞真實結果（`HttpSession.cpp:804-805` 的 `respondToOpResult`，`7856efc`），但**整條路徑上沒有任何存在性檢查**，請求原樣轉給 Ryu（`HttpRoutingStrategyBase.cpp:219-220`），而 Ryu 對不存在的 group 回 200 空 body，`post()` 只在非 2xx 或 body 內含 `{"status":"error"}` 時才判失敗（`:104`／`:118-125`）。⇒ **使用者看到的行為一模一樣**；`7856efc` 早於 08-18 的量測，所以當時量到的就是現在這個機制。<br>🔄 **08-30 sweep 補精度**：六端點**路由有登記**（`tools/contract_test/components.py:36-41` 全在、mapped POST），缺的是**回應形狀斷言**（components.py 以外 grep `group_entry` 零命中）——「零契約覆蓋」精確講是「**登記而無形狀斷言**」（`recording` 是同型第二例、已修；此六端點仍待） | OVS | 靜默 |
| **F-6** | 讀取流表失敗的交換機**被從 `get_switch_openflow_table_entries` 刪除**，而四處程式碼註解承諾「保留前一份表格」 | 兩者 | 靜默 |
| **F-9** | 鏈路使用量量化到取樣粒度（1/256 × frame length × 8），所以低於約 3 Mbit/s 的鏈路**讀成一個量子的整數倍**（⚠️ 原文寫「讀成 0 或一個量子」，**「讀成 0」那半未被觀察到**，見下） | OVS | 解析度限制 |
| **F-15** | bmv2 gRPC port 配在 kernel 的 ephemeral range 內，所以交換機**隨機開不起來**，而錯誤訊息指向錯的原因。⚠️ **08-30 重驗：分兩半，只有一半還在**。配置缺陷照舊（`p4_proxy/mininet/p4_testbed_topo.py:365` 的 `grpc_port=50050+i` ⇒ 50051–50060，落在預設 `32768-60999` 內）；但**「訊息指向錯的原因」已部分緩解**——`failure_reason()`（`:308-338`）現在會讀 bmv2 自己的 log，並在 `:331-332` 回報「gRPC port {} 已被占用，多半是前一輪殘留的 `simple_switch_grpc`」。**log 還在的時候診斷是對的** | P4 | 環境 |

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
> 🏁 **對 §D 裁定的影響：已重裁完畢（Adam，2026-08-29）。**
> 原理由（失效方向保守）被 round 4 推翻、而 round 4 推出的「0.0 → 觸發關機」也被本次更正推翻
> ⇒ **那條裁定原本唯一的書面依據已經沒了**。重裁的結果是**結論不變（不修）、理由整組換掉**，
> 換成「零個活的消費端／修分母會讓失效方向翻面／修分母構不到閒置回 0.0」三條。
> **細節見 §D 的 F-17 那格與 `doc/audit/2026-08-29_f17-fix-impact/FINDINGS.md`。**

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
| **F-5（幽靈規則）**<br>（＝審查員那套編號，本文件的 **B-1**） | 2026-08-18 不修。🔴 **2026-08-30：裁定的證據基礎鬆動，待重裁** | 原理由：30 分鐘真實負載下 **0 次自然發作**（177 取樣、期間 37 次寫入、5 次電源變動、15 輪 TE 遷移）。量測靈敏度約 80%/次，所以是「發作率低」不是「零」。<br>🔴 **2026-08-30 的問題：那 177 個取樣是 10 秒一格**（`measure_f5_frequency.sh` 的 `INTERVAL="${1:-10}"`，`f5_frequency.log` 檔頭逐字寫著 `interval=10s duration=30min`），**而同一週 FINDING-03 量到的窗口在 t=2（P4）／t=3（OVS）就消失了**。<br>⇒ **「靈敏度約 80%/次」是照 ~8 秒的窗口算的；若窗口其實是 2–3 秒，10 秒格的靈敏度遠低於此，「0 次」就幾乎不構成證據。**<br>⚠️ **但不要把話講死**：FINDING-03 **明文不宣稱**它量到的短窗與 08-18 的 ~8 秒是同一個現象（「同一個指紋，與舊時長的關係未知」），而且它是在**沒有流量**的網路上量的。<br>⇒ **兩種可能都還開著**：①窗口本來就短、08-18 的 8 秒另有原因；②有流量時窗口會變長。**本輪不裁，交 Adam**；要裁之前該補的是**同一格點下、有流量的重量**，不是再多取樣。<br>📌 機制已指認（FINDING-03）＋工單 **T-11** 已開，見 B-1。<br>🏁 **08-31 補：要求的「同格點、有流量重量」已跑**（TR-3）＝**窗是時鐘不是負載**（表視圖快取 10 s 刷新；FINDING-06 更正 `51b3e84`＝blindness not delay——規則多半立即編程、最長 ~10.7 s 不可見）；且 **T-11-A（`91e7743`）已把幻影整個移出視圖**（08-31 live 力紅力綠雙向驗證）。**重裁材料齊備，裁決仍留 Adam**（F-5 是否解鎖併發控制前置） |
| **F-4**<br>（＝subagent 那套編號，＝§C 表那一列） | 2026-08-18 不修 | 機制讀碼確認，但報告裡「permanent and built in」那句被實跑推翻——我那輪 0 次，subagent 那輪 18 次（在它切斷 s10 controller 之後）。**觸發條件比原報告說的窄**。<br>⚠️ **2026-08-30：本輪 R-5 報的「F-4 FIXED」不是這一條**（那是審查員那套的 F-4＝過期註解）——見 §C 表上的消歧註。**本條未重驗，裁定不變** |
| **F-17** | **不修**。原裁定 **2026-08-18**；**2026-08-29 由 Adam 重裁，結論不變、理由整組換掉**（舊理由已死，見下） | **今天生效的三條理由**（全部出自 `doc/audit/2026-08-29_f17-fix-impact/FINDINGS.md` 的實查）：<br>**①「零個活的消費端」** —— 七個兄弟 repo（`tools/test_workflow/components.env` 的 `*_DIR`）逐一掃過，只有 ESA 寫過 client（`src/app/http.cpp:393`）而**沒有人呼叫它**；`Traffic-Engineering-App` 會拼接 base URL，另做了一次逐端點檢查。<br>**② 修分母會讓失效方向翻面，不是消失** —— 膨脹倍率 `f ≈ 可用邊/忙碌邊`，**決策只在真值落 `(0.40/f, 0.40]` 時改變，而在那個區間裡是「現行不關機 → 修法後關機」**。8/32 忙碌 ⇒ 區間 `(0.10, 0.40]`。在 round 4 自己的工作點（0.11 vs 0.027）**兩邊都關機，修了毫無差別**。<br>**③ 修分母構不到最常被引用的那個症狀** —— 閒置時現行走 `return 0`、修法後走 `sum(0)/N`，**輸出相同**。要讓「真的閒置」與「量不到」可區分得改回傳型別 ＝ **`/ndt/` 跨 repo 契約變更**。<br>⚠️ **這不表示 F-17 不重要，兩件事要分開**：**端點讀值的缺陷照舊成立**（有負載高估 **4.0×**、閒置歸零，機制仍是「分子分母都只算非零邊」）——那是 **twin 可信度**問題，只是**它今天不驅動任何決策**。<br>⚠️ **零呼叫端不是可以改回傳的許可**：ESA 的 client 已經寫好，接一行就會用到。<br>🗄️ **舊理由存查**：08-18 原裁定的**唯一**書面理由是「失效方向保守（少關機，不會誤關）」，已被 round 4 推翻（讀值是雙向失效）；而 round 4 由此推出的「0.0 → Energy-App 關機」也不成立（接線不存在，見 §C 表下）。**這條裁定換過理由，結論才留下來。** |

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
- 🆕 **「守衛擺在傷害已經造成之後的那條路徑上」**（2026-08-30 新增，缺陷 **P-1**，已修 `a7ab17d`）——
  第二個 proxy 實例對著一個**已被占用**的 port 啟動時，uvicorn 會**先跑完 ASGI lifespan 再 bind**
  ⇒ startup 已經開了 gRPC channel、推了 pipeline config、裝了轉發規則，
  **然後才拿到 `[Errno 98] address already in use`**。
  實測：**10 次 `Setting Forwarding Pipeline Config...`、LLDP discovery 起來、link watchdog 種好**，
  全部發生在錯誤之前——**兩個 agent 同時寫同一座 bmv2 fabric**。
  **修法不是加檢查，是把 bind 提前**：`claim_listen_socket()`
  （`p4_proxy/proxy_agent/main.py:361-398`）在 `Server.run` 之前搶下 socket，
  失敗就 `sys.exit(1)`，並且**把 socket 交給 uvicorn 而不是關掉重綁**——關掉重綁會把這個競態再開一次。
  🔑 **要問的問題**：**這個守衛跑的時候，它要防的事情已經發生了嗎？**
  「bind 失敗處理器」聽起來是對的地方，但在這個框架裡它**結構性地太晚**。
  ⚠️ **本條沒有對應的舊條目**——這個缺陷從來沒有進過本清單，08-30 對帳時才補記形狀。

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

- 🔴 **任何活過自己 pidfile 的 app，在每一個 `ndt` 介面上同時是隱形且殺不掉的**（2026-08-31
  live 實證）：前一 session 的 TE-App 崩潰迴圈灌了 **100 MB log**（`UnboundLocalError`），
  而 `ndt status`＝`apps none running`、`ndt apps`＝`te -`、**`ndt apps stop te` 回
  rc 0「te not running」**——`app_stop` 只看 `.test_run/pids/app_te.pid`，pidfile 沒了就全盲。
  📦 **那份 100 MB log 已依 Adam 裁定刪除**（08-31，釋出 96.2 MiB）；刪除前的有界證據包
  ＝`doc/audit/2026-08-31_live-recipes/app_te_log_evidence.txt`（14 KB，含原檔 sha256
  `9df3e225…`、逐時直方圖、方法在同目錄 `analyse_app_te_log.py`）。**引用這條的數字請引證據包，
  不要再引已刪除的 log。** 證據包同時更正／收窄了三件事：
  ① 🔴 **「20h32m」不是這份 log 給的**——檔案本身跨 **20h38m39s**、崩潰迴圈跨 **20h07m02s**，
  兩個都不是 20h32m，而 20h32m 這個數字在 repo 裡沒有任何 raw 支撐（形狀像是發現當下的
  `ps` etime 讀數，但沒人記下來，證據包**不替它湊**）。
  ② 🔴 **迴圈不是從頭就有**——前面有 **31m37s 完全乾淨**，第一個例外在 `15:39:10.273`，
  觸發點是 `:8000` 第一次 connection refused。
  ③ 🔑 **這次事件裡它其實沒裝成任何流表規則**——全檔 123,420 條 ERROR **全部**是
  `localhost:8000 connection refused`，整段 20h07m 它一次都沒接到活的 kernel。
  下一行那句「孤兒會裝流表規則」是**風險**（乾淨的那 31 分鐘它確實在跟 kernel 講話），
  不是這次的已發生事實。
  「崩潰迴圈」與「100 MB」則被證據包**確認**：61,710 個**同一種** `UnboundLocalError`、
  穩定 3600 次／小時，全程只有三段約 135 秒的停頓。
  📏 **「這份 log 能不能刪」的判準（08-31 兩次刪除各學到一半，寫成規則）**：
  分界**不是**「它有沒有支撐宣稱」——同一天刪的兩份**都有**。分界是**證據的保存狀態**：
  | 問 | `app_te.log` | `app_viz.log` |
  |---|---|---|
  | 有沒有支撐已發表宣稱 | 有（§G 三個詞） | 有（FINDING-02＋maven 共變數） |
  | 關鍵事實抽出來了嗎 | ❌ 只有 184 byte 的**身分**節錄，**節奏從沒被抽過** | ✅ 當輪就刻意抽成 `covariate_maven_build.txt` |
  | 有沒有等價副本 | ❌ 全世界一份 | ✅ **逐 byte 相同**的副本＋`artifact-baseline.txt` 記著 sha |
  | ⇒ 刪之前要做什麼 | **現做有界證據包** | 不用（但**副本當時不在任何 object store**⇒補進 `audit-raw f9f30c0`） |
  🔴 **查「有沒有被引用」時 grep 範圍要涵蓋 `raw/` 的 `.txt`／`.jsonl` 與 `harness/` 的 `.sh`**——
  只查 `--include="*.md" doc/` 會得到「零引用」的錯誤結論（08-31 我就是這樣答錯 `app_viz.log` 的）。
  這種孤兒會裝流表規則，kernel 一起來就污染量測。正解＝`/proc` 驗身分後按 PID 停。
  🔄 **08-31 修法已落，狀態＝過了單元變異閘、live 未驗（不是 RESOLVED）**：
  `ndt` 加了三態 `app_probe`（`running`／`not-running`／**`pidfile-lost-but-alive`**）、
  `app_scan_pids`（`ps` 只當候選索引、`/proc` 才是判準）、`app_kill_pid`（前後都用
  `pid_is_app` 不用 `kill -0`），並接到 `apps stop`／`apps status`／`status`／`down`
  四個入口；新子命令 **`ndt apps orphans`**（找到孤兒 exit 1）＝量測開跑前的檢查。
  測試 `tests/shell/test_ndt_app_orphans.sh`（52 checks），**七個變異全部看過紅**
  （含「掃描根本不執行」那一支，用來擋「因為沒東西所以通過」）。
  🟢 **live 已補（2026-08-31 15:25–15:30，`ndt up ovs4`）**：養了一隻真的 TE-App
  （mode 2，20 秒內 log 長 5→53 行＝確實在工作），拿走 pidfile 後——
  **修法前的 `c10ac7c` 版本原樣重現壞行為**（`te not running`／rc 0／行程還活著），
  而現行版四個介面全部正確（`apps orphans` rc 1、`apps status` ＝ `ORPHAN`、
  `status --check` 列 `untracked te(...)`、`apps stop te` 印三態訊息並真的停掉）；
  額外一輪 `ndt down` 也把孤兒收掉了（`stopping it by pid`＋`REAPED BY DOWN`）。
  raw＝audit-raw `243e7e7`（`w2_` 前綴）；配方與實測紀錄
  ＝`doc/audit/2026-08-31_live-recipes/rider_app-orphan-stop.md`。
  🔴 **那份配方自己有三個缺陷，已就地更正**，其中一個與 A-1 的 R3 同型：
  控制組原本放 `/tmp`，而 `ndt` 用 `$HERE/../..` 推 `REPO` ⇒ 在 `/tmp` 解成 `/`，
  舊碼於是印出預期的 `te not running` **是因為路徑錯、不是因為缺陷在**——
  **舊碼就算是好的也照樣「通過」**。已改放 `.test_run/ctl/`（gitignore 內、且剛好第二層），
  並新增「先證明控制組看得見那隻 app」的前置步驟。

- 🔴 **`ndt apps stop` 的優雅停止路徑，對 TE-App 在生產上從來沒有作用過**
  （2026-08-31，讀碼＋live 兩面確認）。`app_kill_pid` 先送 SIGTERM、給 5 秒窗
  （10×0.5s，每次用 `pid_is_app` 驗身分）、逾時才 `SIGKILL`。
  但 **`Traffic-engineering-App.py` 一個 signal handler 都沒裝**——
  `signal` 只出現在 `:29` 的 import，全檔零使用 ⇒ SIGTERM 走 **Python 預設處置＝立即結束**。
  **這不是測試缺口，是一個關於生產行為的事實**：那支 app 沒有任何清理機會，
  它正在裝的流表規則會停在半途，而 `apps stop` 回報的 `ok` 只證明行程沒了。
  🔑 順帶推翻配方寫的「多執行緒所以可能不會馬上死」：mode 2 根本不起 listener 執行緒
  （實測 `Threads: 1`），而且**執行緒數與這件事無關**——沒有 handler，幾條執行緒都一樣立刻死。
  ⇒ 要驗 TERM 窗／KILL 回退那段碼，需要一支**自己 trap 住 TERM 不理**的五行 fixture；
  **不要為了測試去改 TE-App 的生產碼**。
  🔑 修的過程順手抓到兩個同源缺陷：① 舊 `app_stop` 對 pidfile 裡的 pid **不驗身分就 `kill`**
  ⇒ pid 被回收就打到路人（本機 `.test_run/pids/app_viz.pid` 從 08-30 起就指著死 pid）；
  ② `ndt down` 的 app 迴圈也用 `app_running` 當閘 ⇒ **最需要停的那隻正好被跳過**。
  🪞 第一版 `app_scan_pids` 用「flatten 後 substring」比對，**當場自我匹配**：
  `bash -c '<提到 app 名字的腳本>'` 整段腳本是一個 argv 元素，掃描器自己的每個 fork 都命中
  （`$$`／`$PPID` 擋不住，fork 有新 pid）。改成**逐 argv 元素比對**（等於 sig 或以 `/sig` 結尾）。
  順帶：TE 的崩因是 `get_graph_data_api_call` 在 except 後 `return graph_data`（未賦值）——
  **Traffic-Engineering-App repo 的缺陷**，excerpt 在 `2026-08-31_live-recipes/te-crashloop-excerpt.txt`。
- 🔴 **「把掃描寫進 script 檔就不會自我匹配」這句話不完整——真正決定的是「在哪一道命令裡執行」**
  （2026-08-31 實測，同一輪內連續踩兩次）。`/proc` 掃描器如果把搜尋字串放在**自己的 cmdline**
  上就會數到自己。已知的解法是「寫進 script 檔」，但那只保護**掃描器自己**：
  - 用 heredoc **在同一道命令裡**產生並執行那支腳本 ⇒ **父 shell 的 cmdline 仍然帶著整段
    heredoc 內容**（含 pattern），掃描照樣多數一個。實測讀數 1，真值 0。
  - 把同一支腳本改成**單獨一道命令**執行（`bash /path/scan.sh`，那一行沒有別的東西）
    ⇒ 讀數 0。**腳本沒改一個字，只換了誰是父行程。**
  🔑 判準不是「命令有沒有寫進檔案」，而是**「從我的行程往上，有沒有任何一個祖先的 cmdline
  含有 pattern」**。⇒ 產生腳本與執行腳本要拆成兩道命令；pattern 一律放腳本內的變數。
  🔑 這也是為什麼「兩個讀數不一致」要先當**儀器發現**：08-31 早上那一輪也是同一個偏移
  （inline 讀 1、真值 0），當時歸因成「inline vs 檔案」，**歸因只對了一半**。

- 🔴 **`git commit -- <path>` 保護的是「不同檔案」，兩個寫者改同一個檔時它一點保護都沒有**
  （2026-08-31 實測；「兩個寫者一個 worktree」的新一式）。共用 worktree 的既定紀律是
  `git commit -m "..." -- <paths>`，那擋得住「把別人的檔一起 commit 進來」，
  但 `-- <path>` 是**按路徑切，不是按 hunk 切**：它送出的是那個檔案**當下工作區的全部內容**。
  於是同一個 `doc/KNOWN-ISSUES.md` 上兩個 session 併行編輯時，實際發生的是——
  **我的 A-2 改動被對方的 commit `e5eae74` 捲走，對方的 virtiofsd 段被我的 `6fd8a4d` 捲走**。
  🔑 **沒有掉資料，但歸屬交叉了，而且完全無聲**：兩邊的 `git commit` 都回 rc 0，
  兩邊的內容事後查都在檔案裡，只有 `git log -S` 問得出來是誰的 commit 帶進來的。
  ⇒ 三條慣例（不設鎖——鎖會腐爛，而且四個寫者沒人會去讀它）：
  ① **傷害來自 dirty 窗口的長度，不是並行本身** ⇒ 改完 `KNOWN-ISSUES.md` 立刻 commit，
  不要讓它跨一個長操作（例如一整個 fabric 窗）留在 dirty；
  ② commit 之後**驗自己的改動在自己的 commit 裡**：`git show <sha> -- doc/KNOWN-ISSUES.md`；
  ③ 引用「某條是誰寫的」時用 `git log -S '<字串>' -- <path>`，**不要用 `%an`**（零資訊）。
  🔴 **同一天第二次，而且是在寫下上面那三條之後發生的：①「立刻 commit」是必要條件，
  不是充分條件。** 08-31 15:46–15:48 我把上面這幾條寫進本檔，兩分鐘內就下 commit，
  **仍然整批被別的 session 的 `3920180` 捲走**——我的 `git commit` 回 rc 1
  「no changes added to commit」，因為工作區已經沒有差異了。
  🔑 **窗口是「第一次 Edit 到 commit」之間的整段時間，不是「我有沒有拖延」**：
  四個寫者時，兩分鐘也輸得掉。⇒ 真正把窗關掉的做法是**編輯與 commit 放進同一道命令**
  （腳本改檔案、緊接著 `git commit -- <path>`），把窗壓到次秒級。
  這條記錄本身就是那樣寫進去的。

- 🔴 **raw 歸檔的守衛是單向的：它擋錯的目的地，沒有任何東西檢查對的目的地發生過**
  （2026-08-31 普查）。
  🔑 **缺口是沉默不是假話——這 15 輪沒有一輪宣稱過自己歸檔了，而且沒有任何地方記錄過
  某輪是否「決定不歸檔」，連意圖都查不到。**
  底下的清單會過期，這個結構不會：**我們的守衛只會對「做錯的事」出聲，不會對「沒做的事」出聲。**
  `tools/githooks/pre-commit` 只做一件事——工作分支上出現 raw 就擋（`:32` 是
  `[[ "$branch" == "audit-raw" ]] && exit 0`）。🔑 **它只在你 commit 的那一刻才有機會說話，
  而「缺席」不觸發任何事件**⇒ 這是「**保護的失效時機與它要防的事件重合**」
  （見 [[failures-that-report-success]]）的又一個實例：**忘記歸檔的那一輪，正好就是
  永遠不會讓 hook 執行到的那一輪。** 要補的不是更嚴的 hook，是一個**在輪次收官時
  主動去問「這輪的 raw 在哪」的檢查**——沒有事件可以掛，就得自己排一個。
  所以 `doc/2026-08-29_bmv2-performance-study.md:219` 那句「raw 一律進 `audit-raw` 分支
  （**pre-commit hook 強制**）」**高估了守衛**：hook 保證的是「raw 不會出現在工作分支」，
  **不是**「raw 已經進了 audit-raw」。
  📊 **普查結果（08-31）：兩個明講過的宣稱都是真的。**
  - ✅ `12_auditor-rulings.md:38`「raw 18 檔＋TE excerpt＋drive_ovs.log 落 audit-raw `d62ff34`」
    ——**逐項對上**：`2026-08-31_live-recipes/raw/` 在 audit-raw 上正好 **18 檔**，
    加 `te-crashloop-excerpt.txt` 共 19，`drive_ovs_a4e_a2.sh` 在列。
    （🪞 我一度把這句讀成在講 08-30 那輪而報成「對不上」——**是我讀錯章節，那句話沒有錯**。
    `audit-raw f9f30c0` 的 commit message 帶著這個誤讀，未推送但不重寫；以本行為準。）
  - ✅ `2026-08-29_europ4-poster-review/smoke/SMOKE-RESULT.md:5`「raw 歸檔＝audit-raw `e19595d`」
    ——commit 存在、是 audit-raw 祖先、該筆加入 **36 檔**，與磁碟相符。
  - 🔴 **但有 15 輪的 raw 不在任何 object store，合計 533.2 MiB**（讀數時 audit-raw 尖端
    ＝`243e7e7`；**這是點取樣不是租約**，輪次還在跑，要用就當場重跑下面那段）。
    其中 **8 輪一個檔都沒有**，扣掉當天還在跑的兩輪（`2026-08-31_f5-fine-grid-round`、
    `2026-08-31_sampling-ceiling-after-merge`）是 **6 輪歷史全缺**：
    `2026-08-25_sampling-rounds`（**1458 檔**）、`2026-08-27_p4guide-v10-tty`、
    `2026-08-27_telemetry-blindness`、`2026-08-28_baseline-architecture-drift`、
    `2026-08-28_bmv2-literature-review`、`2026-08-28_wire-consumer-compat`。
    檔數最大＝`2026-08-28_QM-mirrored-block` 1942 檔；位元組最大＝
    `2026-08-25_large-scale-concurrent` 1187 檔／452.5 MiB
    （`Q_T64/`、`P_Qp/`、`P_Q/`… 是**每臂的證據目錄**，不是 scratch）。
    💰 **成本不是 533 MiB**：文字壓縮率極高，實測 zlib 後約 **32.8 MiB（6.1%）**，
    而其中 **26.2 MiB 全在 `large-scale-concurrent` 一輪**——
    **其餘 14 輪加起來只有約 6.6 MiB**。權衡要用這兩個數字，不要用 533。
    ⚠️ **這 15 輪沒有一輪宣稱過自己歸檔了**，所以這是「紀律沒被執行」不是「宣稱不實」；
    而且**沒有任何地方記錄過某輪是否「決定不歸檔」**——連意圖都查不到，這才是最難補的部分。
  🔬 **重跑這份普查（唯讀，可直接貼）**：
  ```bash
  for r in doc/audit/*/; do
    d=0; g=0
    # 🔴 一輪可以有**好幾個** raw* 目錄，必須全部加總。第一版寫成
    # `find ... -name 'raw*' | head -1`，於是 `2026-08-25_sampling-rounds` 只數到 raw_n、
    # 漏掉 raw_h 與 raw_gil（420 → 實際 1458），`QM-mirrored-block` 196 → 1942。
    # `.gitignore:60` 的 pathspec 之所以是 `raw*` 而不是 `raw/`，就是因為有一輪寫進 raw_n/。
    while read -r rd; do
      # 🔴 必須排除 .gitignore：每個 raw/ 都有一個「工作分支上追蹤、audit-raw 上沒有」的
      # keeper（.gitignore:61 的 `!doc/audit/*/raw*/.gitignore`）。不排除的話 20 個健康的
      # 輪次會各報「少 1 檔」——一個由儀器自己製造出來的缺陷。
      d=$((d + $(find "$rd" -type f ! -name '.gitignore' | wc -l)))
      g=$((g + $(git ls-tree -r --name-only audit-raw -- "$rd" 2>/dev/null | wc -l)))
    done < <(find "$r" -type d -name 'raw*' 2>/dev/null)
    [ "$d" = "$g" ] || printf '%-46s disk=%-6s audit-raw=%-6s\n' "$(basename "$r")" "$d" "$g"
  done
  ```
- 🔴 **`rm` 一個大檔不會還你空間——VM 的 `virtiofsd` 把它按住了**（2026-08-31 實測）：刪掉
  `app_viz.log` 之後 `du` 少了 17.4 MiB 而 **`df` 一個 byte 都沒回來**。原因＝這個 repo 被
  virtio-fs 掛進 qemu VM，`virtiofsd` 對 guest 碰過的每個檔案留著 fd，**檔名沒了、blocks 還在**。
  當下全機 **606.2 MiB 的已刪除檔案仍佔著 `/`，其中 511.9 MiB 是 `virtiofsd` 按住的**
  （`build/bin/test_routing_strategy` 162.3 MiB、`build/bin/ndtwin_kernel` 68.9 MiB、
  `build/lib/*.a` 約 230 MiB——**全都是早就 `rm` 過的舊 build 產物**）。
  🔑 **這是「VM 對 `ndt status` 隱形」的第二面：它對磁碟簿記也隱形**——`du` 與 `df` 會給你
  兩個相反的答案，而兩個都不是錯的。**空間見底時先查 `/proc/*/fd` 找 deleted 檔，不要再刪東西**
  （再刪也不會回來）。回收方式＝關掉／重開那個 VM，**不是 `kill virtiofsd`**（那是別人的 VM）。
  **量法（唯讀、可直接貼，08-31 實跑過；與獨立寫的 python 版逐數字對過帳）**：

  ```bash
  ROOTDEV=$(stat -c %d /)
  for d in /proc/[0-9]*; do
    c=$(cat "$d/comm" 2>/dev/null) || continue
    for f in "$d"/fd/*; do
      t=$(readlink "$f" 2>/dev/null) || continue
      case "$t" in *' (deleted)') ;; *) continue ;; esac
      # 這一行是關鍵：不濾掉 memfd/socket/pipe 會算出 40 GB，
      # 而那是共享記憶體不是磁碟——67 倍的假警報。
      case "$t" in /memfd:*|/dev/*|anon_inode:*|socket:*|pipe:*) continue ;; esac
      read -r dev sz < <(stat -Lc '%d %s' "$f" 2>/dev/null) || continue
      [ "$dev" = "$ROOTDEV" ] || continue     # 只算 / 上的，別把別的 fs 算進來
      printf '%s\t%s\t%s\n' "$sz" "$c" "${t% (deleted)}"
    done
  done 2>/dev/null | sort -rn > /tmp/delfd.tsv
  awk -F'\t' '{t+=$1; p[$2]+=$1} END {printf "TOTAL %.1f MiB in %d fds\n", t/1048576, NR;
    for (k in p) printf "  %-16s %8.1f MiB\n", k, p[k]/1048576}' /tmp/delfd.tsv | sort -k2 -rn | head -6
  head -5 /tmp/delfd.tsv | awk -F'\t' '{printf "  %8.1f MiB  %-12s %s\n", $1/1048576, $2, $3}'
  ```

  08-31 的輸出＝`TOTAL 606.2 MiB in 450 fds`／`virtiofsd 511.9 MiB`。
  🔑 **不要用 `pgrep -f`／`pkill -f` 找或殺這些持有者**，也不要 kill `virtiofsd`——
  **回收的唯一正解是關掉那個 VM，而那台 VM 是別人的。**
  🔑 **操作推論（比機制本身更常用到）：在這台機器上，「先展開再刪掉」是一個會單向消耗磁碟的
  動作。** 任何「解壓／checkout／複製出來看一眼再刪」的流程，刪的那一步可能不會還你空間，
  於是淨效果只有消耗。08-31 因此**沒有**用 `git worktree add /tmp/rawwt audit-raw`
  （會攤開 514 MiB／6330 個 blob）補檔，改用 plumbing 直接寫 object store——
  `read-tree` → `add -f` → `write-tree` → `commit-tree` → `update-ref`（帶舊值做 compare-and-swap），
  **不動工作區、不動 HEAD、不攤任何檔案到磁碟**，共用 worktree 上還有別的 session 在工作。
- 🔴 **`ndtwin-lab cleanup` 可能殺掉呼叫它的 shell**（內部跑 `mn -c`）。單獨一行跑。
  🔄 08-30 收窄（sweep 實讀 `/usr/lib/python3/dist-packages/mininet/clean.py:29/:37/:66`）：
  機制＝`pkill -9 -f`，**argv 對上 pattern 才殺**——`sudo mn -c` 的 shell 不匹配
  `"sudo mnexec"`；命令列帶 topo 腳本名的 driver 會匹配 killprocs。「一定殺」比碼支持的強。
- 🔴 **`cleanup` 不會停掉 topo 的 tmux session**。殘留的 session 讓拓撲拒絕啟動，
  而 `topo-out` 還在印**上一輪**的 pane ——驅動腳本會把屍體讀成活的。
  **正確順序：`stack.sh down` → `topo-stop` → `cleanup`。
  `sudo ndtwin-lab status` 才是誠實的存活檢查。**
  ⚠️ **`sudo` 這兩個字是 08-30 補上的，不是可選的**（`0b6db9e`）：
  `tools/test_workflow/ndtwin-lab:86` 現在對**每一個動詞（含 `status`）**擋非 root 呼叫。
  🔑 **這一改反而讓上面那句話變成真的**——在它之前，非 root 的 `status` 會走
  `:218` 的 `$TMUX list-sessions 2>/dev/null || echo "no lab sessions"`，
  **把 tmux 開不了 socket 的錯誤吞掉、印出一個很有自信的「no lab sessions」**。
  ⇒ **那正是本節在講的失效形狀，而它就長在本節推薦的那個指令上。**
- 🔴 **`pkill -f` 會匹配你自己 shell 的命令列**並殺掉它。用 `pkill -x` 或 PID。
- 🔴 **`until ! pgrep -f 'foo'` 永遠不會結束**——`pgrep -f` 匹配迴圈自己。加 bracket：`'fo[o]'`。
- 🔴 **裸 `sudo -n kill` 無授權，而且失敗是靜默的** → 無聲 no-op 實驗看起來像結果。
  走 `sudo -n mnexec -a 1 kill`，並且**永遠斷言注入成功**後才下結論。
- **`read -p` 的提示在 stdin 是 FIFO 時不會送出**，等提示的驅動腳本必定逾時；
  逾時後 stack.sh 會繼續前進、**在空 fabric 上啟動 proxy**。
- **`ifconfig down` 在 bmv2 上會關掉整台交換機**，不是一條鏈路。用 `tc netem`。
- **bmv2 行程會活過 `mn -c`** 變成孤兒佔住 gRPC port。

### G-2. 整機 harness 與 `ndt` 的五個儀器缺陷（T-4 輪，2026-08-30）

**正本 `doc/audit/2026-08-30_live-full-stack-round/`，每條一個 `FINDING-0n_*.md`。**
🔑 **五條裡有四條是儀器自己的缺陷，只有一條是系統的**——
**新工具第一次實跑，找到的幾乎都是工具自己的問題**，這一輪逐字重演了那個規律。

| # | 缺陷 | 現況 |
|---|---|---|
| **01** | 🔴 **`ndt` 的「model matches fabric」比的是模型和模型，從來不讀 fabric** —— `$hosts` 來自 kernel graph、`$want_hosts` 來自餵給 kernel 的拓撲 JSON，**兩邊同源**。實測它在一座 **128 host** 的 fabric 上印出 `ok model matches fabric: 4 hosts` | 🟢 **已修**（`eae75da`，工單 T-8）。現在第三個量來自 fabric：`fabric_host_count()` 從 `ps` 數 host namespace（`tools/test_workflow/ndt:747-758`）。🔑 **「讀不到」判紅不判綠**——`fabric_host_count` 回 0 代表**讀數失敗**，而舊碼等於對每個值都走那一支 |
| **02** | R-3 收斂表四個數字有三個量的是 **harness 自己的時間**；`port_holder` 看不到 root 擁有的 listener | 已開工單 **T-9／T-10** |
| **03** | **唯一一條關於系統的**：kernel 把**排隊未編程**的請求當流表列服務出去，**兩個 fabric 都是**；08-18 之所以沒看到，是因為它的取樣格**第一格就在 t=2** | 見 **B-1**；工單 **T-11**（修法待裁） |
| **04** | **兩條還原路徑都不還原**；`--rebuild` 把 fabric 拆掉就停住 | 已開工單 **T-10**；危險路徑已加勿執行註解 |
| **05** | 一個註冊為 240 秒的窗口實際跑了 **474 秒**；一面**永遠亮著**的 banner | 已開工單 **T-10** |

🔴 **引用這一輪任何數字之前先讀兩件事**：
① **那一輪的網路沒有流量**（R-2 的 1800 個取樣裡 `flows` 全部是 `[]`），
**這一個條件同時弱化了三個結果**——R-2 不可能失敗、F-1 沒有發作、F-5 的窗口沒有競爭對手。
**下一輪最該補的是流量，不是更多取樣也不是更細的格子。**
② **那一輪的量測窗內有十次 `agy` 執行，全部是審查員自己起的**
（`CONTAMINATION-agy-runs-i-started-myself.md`）。

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

### 2026-08-30 對帳這一輪自己的邊界

- **做了什麼**：§A–§G 逐條把碼重新 grep 一次，對照本週落地的修法。
  **21 條動過**（8 條改狀態或拆分、13 條加日期註記或更正引用），**0 條刪除**。
- 🔴 **這一輪一行都沒有跑。** 量測窗開著，所有判斷都是**讀碼**。
  凡是標「實測」的，一律是引用**別人已經跑完**的結果（T-4 輪 R-5／R-1），不是本輪產生的。
  ⇒ **需要實跑才能定的問題，本輪一律留在 OPEN 並標 ⚠️**，沒有一條靠推論結案。
- ⚠️ **沒有覆蓋到的**：§A 的 A-5／A-6（log 截斷、proxy 啟動訊息）**本輪沒有重驗**；
  §G 除了 `ndtwin-lab` 那兩條之外，其餘都是**外部工具**的行為，讀本 repo 的碼驗不了。
- 🔴 **一個引用陷阱已在 §C 表上補了消歧註，但它的成因沒有被修掉**：
  `doc/audit/2026-08-18_live-full-stack-round/` 裡**兩套 F-n 編號同時存在且撞號**。
  **真正的修法是把其中一套重新編號**，那超出本輪範圍（會動到所有引用點）。
  在那之前，**每一次引用 `F-n` 都要指名是哪一個檔案**。
- ⚠️ **commit sha 對不上的情況會再發生**：本週幾顆修法 commit 在本文件寫下的 sha
  （`4ee086f`／`87d272f`／`a7ab17d`）與交接訊息裡流傳的 sha
  （`dff87f9`／`db02d45`／`e29424e`）**內容相同但 sha 不同**（rebase 造成，`git patch-id` 逐一對過）。
  **本文件一律寫「在 `1208d22` 這條歷史上真的存在」的那顆**；
  引用時若 `git show` 不到，先試 `git log --oneline -S <關鍵字> -- <檔案>` 再說它不存在。

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

### `measure.sh` 內含專案硬規矩禁用的 `pkill -f`，而四輪結果錨在這支儀器上 ⇒ **改它與不改它都有代價**

- **狀態**：**登記的陷阱，不是修票**。2026-08-31 auditor 裁「本輪不改」，理由見下。
- **位置**：`doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh:45-46`（前置清場）與 `:96`（收尾）：
  `sudo -n mnexec -a "$H33" pkill -f iperf3`。
- 🔴 **它真的會打到別人**：該檔自己的註解寫明 mininet host 共用 root PID namespace
  ——「Hosts share the root PID namespace, **which is why a plain pkill reaches them at all**」
  ⇒ `pkill -f iperf3` 的作用域是整台機器，不是那個 namespace。
  另一個 session 的 iperf3 會被它殺掉，而且**被殺的那一方看到的是自己的量測莫名中斷**。
- 🔴 **CLAUDE.md 的規矩是絕對的**：「永不 `pkill -f`／`pgrep -f` 殺程序」，
  [[destructive-shell-traps]] 記著已經第七次自傷。**專案禁用的動詞，就寫在一支被多輪依賴的儀器裡。**
- **兩難本身才是要登記的東西**：
  - **改它** ⇒ 與 08-20／08-25 D 輪的存檔格**不再是逐位元組同一支儀器**。
    E 輪 §6 的「同 fabric、同 binary 才逐格比」建立在同儀器上；改了就只能比方向。
  - **不改它** ⇒ 總有一天它會殺到別人的 iperf3，而且失敗的形狀是**別人的資料無聲少一段**。
- **目前的緩解（E 輪 08-31 落地，不改 `measure.sh`）**：呼叫端在交棒之前先確認
  **沒有任何不是本輪起的 iperf3**，有就中止該格；列舉用 `ps -eo pid=,comm=` 精確比對 `comm`，
  **不用 `pgrep -f`**（`-f` 的樣式比對永遠會匹配到搜尋命令自己）。
  見 `doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh:foreign_iperf3_guard`。
  ⚠️ **這只保護「呼叫端有檢查」的那些輪**。任何直接跑 `measure.sh` 的人不受保護。
- **要修的話的形狀**：把清場改成「讀 `/proc`、按 PID、只殺本輪記錄下來的那些」，
  並同時給 `measure.sh` 一個版本標記，讓「改版前／改版後」的格永遠分得開
  ——否則修完之後，新舊格會長得一樣而不可比。

### 哨兵值會製造**空洞的通過**：兩個「讀不到」彼此相等 ⇒ 首尾對帳成功

- **狀態**：**通則，已在 2026-08-31 的兩支新量測腳本上實際發生並修好**。登記在此是因為它
  不屬於任何一輪——它是一種寫法的性質。
- **形狀**：一個函式在失敗時回傳哨兵字串（`NO-KERNEL-PROCESS`、`UNREADABLE`、`N/A`、`""`），
  呼叫端拿它做**相等比較**（首尾括號、前後對帳、A/B 比值）。
  🔴 **兩個哨兵值彼此相等** ⇒ 一個**從頭到尾都讀不到**的量測，比較會「成功」。
  失效方向是最壞的那個：**完全沒有資料** 與 **資料完全一致** 產生同一個結論。
- **實例（08-31，E 與 F-5 的 binary 身分括號）**：
  ```bash
  running_kernel_sha() { ... || echo "UNREADABLE"; }
  sha_open=$(running_kernel_sha);  # ... 量測 ...
  sha_close=$(running_kernel_sha)
  [[ "$sha_open" == "$sha_close" ]] || abort   # ← 兩邊都 UNREADABLE 時通過
  ```
  🔑 **寫這段的人，在同一份檔案裡寫了「讀不到 ≠ 通過」的警語。** 知道規則不等於套用規則。
- **修法（兩層，缺一不可）**：
  1. **形狀檢查**：比較之前先斷言值長得像一個答案（`[[ "$v" =~ ^[0-9a-f]{64}$ ]]`）。
     形狀不對 ⇒ **中止**，不是通過、也不是警告。
  2. 🔴 **判準看輸出，不看 exit code**：讓檢查印出
     `verdict=MATCH|MISMATCH|UNREADABLE`，呼叫端 grep `verdict=MATCH`。
     **`exit 0` 表示「跑完了」，不表示「答案是對的」**——而「檢查根本沒跑到」也會 exit 0。
- **怎麼找出既有的實例**：找「回傳哨兵字串的函式」與「拿它的回傳值做 `==` / `!=`」的組合。
  同族還有：`grep -c` 回 0（沒命中）與真的是 0 個不可分辨；
  空陣列的平均；以及任何「兩邊都缺席 ⇒ 差為零 ⇒ 判定通過」的比值。
- **關聯**：[[failures-that-report-success]]（第 N 個機制）、
  [[injections-must-assert-their-own-success]]、
  [[verify-the-purpose-not-the-mechanism]]（每個閘門要 force-red **也要** force-green）。
