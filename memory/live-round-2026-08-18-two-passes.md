---
name: live-round-2026-08-18-two-passes
description: 2026-08-18 四輪 live（OVS/P4 × NTG 開關）＋ 一輪 subagent；26 個發現幾乎不重疊，全部落檔在 doc/audit/2026-08-18_live-full-stack-round/
metadata: 
  node_type: memory
  type: project
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-29T05:32:53.395Z
---

**全部內容在 `doc/audit/2026-08-18_live-full-stack-round/`**（這裡只放指標與不會重新推導出來的判斷）。
檔案：`SUMMARY.md`、`live-findings-2026-08-18-ovs.md`（含 F-7 的更正節）、
`live-findings-2026-08-18-p4.md`、`subagent-round2-FINDINGS.md`（904 行）、
`f5_frequency.log`、兩支量測腳本。

## 兩輪獨立掃描，發現幾乎不重疊

我自己四輪（kernel `04b8933`，七工具中六個，Web-GUI 因無 Node 略過）找到 8 條；
一個全新、只給操作機制、不給任何發現的 Claude subagent 找到 18 條 + 10 個 clean。
**重疊只有一條**（契約 schema 對 `-1` 哨兵失敗）。

**這是 [[ovs-pretest-state-2026-08-11]] 那句「自動化輪次共享盲點」的實測校正**：
它們不是共享盲點，是**各有各的盲點**。所以「跑過兩輪 = 找完了」不成立。

## 報告前的裁定（Adam 2026-08-18）

**產品碼一行不動。** 只改了兩個測試檔：`spec.py` 的 `Num(min=0)` → `min=-1`（文件與 GUI
都以 `-1` 為不可用哨兵，schema 是三者中唯一錯的），與 `faults.sh` 的
`FAULTS_SETTLE_S` 5 → 75。

未修且已裁定不修（理由各不相同，寫在 SUMMARY）：
- **F-5 幽靈規則**：被交換機拒絕的規則回 `200 queued`、被顯示成已裝約 8 秒、然後消失。
  **30 分鐘真實負載下 0 次自然發作**（177 取樣、期間 37 次寫入、5 次電源變動、15 輪 TE 遷移）。
  量測靈敏度約 80%/次，所以結論是「發作率低」不是「零」。
- **F-4（subagent）**：死鏈路每 30 秒被復活。機制我讀碼確認，但**它報告裡「permanent and
  built in」那句被我的實跑推翻——我那輪 0 次，它那輪 18 次（在它切斷 s10 controller 之後）**。
  觸發條件比它說的窄。
- **F-17（subagent）**：`getAvgLinkUsage` 分子分母都只算非零邊 → fabric 越空數字不會降。
  ~~標頭文件寫的是 `mean across all qualifying edges`，與程式不符。餵給 Energy-App 的關機決策。~~
  🔴 **兩句都已推翻，見下面的二次更正。**
  🔴 **2026-08-19 更正：我原本寫「失效方向保守（少關機，不會誤關）」，那是錯的。**
  round 4 量化了兩件事：①有負載時高估 **4.0×**（8/32 條邊忙碌 → 只算忙碌邊 0.11 vs 真實 0.027）
  ②**「保守」這個性質在閒置時消失——沒有忙碌邊時回 `0.0`**。
  所以**端點讀值**有負載時偏少關、閒置時歸零，兩個方向都有，不是單向保守。**這一半仍然成立。**
  **教訓**：「失效方向」不能只看一個負載點就下判斷——把負載掃過去，端點行為可能換方向。

  🔴 **2026-08-29 二次更正，方向與上一次相反 —— 引用前一定要讀到這裡。**
  round 4 接著推出的「0.0 → `LOW_WATER_MARK = 0.40` → **觸發關機**」**不成立，那條接線不存在**：
  ESA 有 `get_average_link_usage()` 的 client（`src/app/http.cpp:393`／`include/app/http.hpp:34`）
  但**零呼叫端**；關機決策（`energy_saving_app.cpp:926`）讀的是 app **自己**從 graph 算的
  `group_avg_link_utilization`（`include/common/types.hpp:215`）。
  ⇒ **F-17 碰不到那條決策路徑。** 也因此它**不是** A-4b 的支持——
  **A-4b 從一開始就走 app 自己的函式，本來就不依賴 F-17**（`KNOWN-ISSUES.md` 的 A-4b 註記
  一直是這樣寫的，是這條記憶把兩者接在一起）。
  ⚠️ **零呼叫端 ≠ 可以安全地改**：`/ndt/` 是跨 repo 契約（見 [[no-in-repo-callers-is-not-dead-code]]）。
  📌 **08-28 就已經查證過同一件事**（[[existence-is-not-wiring]] §08-28、[[baseline-drift-audit-2026-08-28]]），
  而這條記憶與 `KNOWN-ISSUES.md` 都沒跟著更新 ⇒ **記憶之間也要對帳，不是只跟 repo 對帳。**
  正本＝`doc/KNOWN-ISSUES.md` §C 的 F-17 更正區塊（commit `f351aea`）。

## 我今天被推翻四次，全部由 Adam 或證據推翻

1. 「20 個介面掉整形」→ 實際 4 個（見 [[ovs-testbed-bandwidth-reality]]）
2. 「10 Gbps 宣告是虛構的」→ 不是，它描述被模擬的真實網路
3. 「TE 對核心是瞎的、核心是裝飾」→ **TE 正常運作，實測 15 輪遷移**（Adam 憑記憶擋下）
4. 「TE 的空 ECMP 候選可能是缺陷」→ 139 次裡 67 次有候選，空的是下行鏈路＝正確行為

第 5 次是自己抓的：把 subagent 18 條歸成「一個形狀」，實際只涵蓋 10 條，
而且 F-2 的失效方向與其餘相反（悲觀而非樂觀）。

相關：[[live-runs-find-what-tests-cannot]]、[[arithmetic-that-fits-is-not-the-mechanism]]、
[[subagent-operating-constraints]]、[[ovs-testbed-bandwidth-reality]]。

## 🔴 08-30 T-4 推翻一條：P4「no phantom, ever」＝取樣格假陰性（FINDING-03）

08-18 的格點是 t=2,4,8,16,30；T-4 加了 **t=0**：幻影**只在 t=0 存在、t=2 就消失**
⇒ 08-18 不是觀察到「不存在」，是**第一格已經在事件之後**（梯子比現象短）。
機制已指認：**kernel 把「已排隊但未編程」的請求當成流表列服務出去**。指紋＝該列只有 4 欄
（無 byte_count/packet_count/duration_*/cookie）、actions 是物件、match 用**呼叫端 POST 的字彙**
（eth_type/ipv4_dst）而真列用 dl_type/nw_dst。正本＝T-4 round 的 FINDING-03（`569f976`）。

## 🔴 08-30 TR-2：F-1 的 punt path 是「被繞過」不是「沒觀察到」——而且預註冊的前提本身錯了

OVS/Ryu 128-host、兩段流量共 21 條全新 pair，`kernel.log` 的 `edge not found` **全程 0**。
兩個分支都測過，不是二選一猜的：
- **(a) 被繞過＝成立**：Ryu 在起機時就把路徑**主動裝好**（`ndt up` log：`paths=installed`；
  Ryu REST 讀回每台 switch **128 條 destination route**、全 fabric 1280 條，**都在任何流量之前**）
  ⇒ **新 pair 不可能 miss 一張它已經在裡面的表**。
- **(b) 儀器瞎掉＝否證**：punt 規則看得見**而且在計數**——每台 2 條
  （`{dl_dst:01:80:c2:00:00:0e, dl_type:35020}`＝LLDP 671 封包；`priority=0, match={}`＝真正的
  table-miss 規則 648 封包／63,663 B／594 s）。而且**流量期間 kernel 確實有偵測到流**（8–13 條）
  ⇒ 會發出那行訊息的 path walk 有東西可走。

🔑 **PREREG §2 寫「churn 會給 F-1 它的 table-miss 事件」——這個前提對主動式控制器不成立。**
table-miss 需要**反應式**轉發；再多 churn 也造不出來。這是對預註冊設計的更正，不是關於 F-1 的結果。
⇒ F-1 仍記 `unreachable` **不是 `fixed`**（它的機制要一條 output port 是 `OFPP_CONTROLLER`
的流進到 collector 的 path walk，這點沒驗到）。
🔑 下次寫「用 X 製造 Y 事件」的預註冊之前，先確認系統是**用哪種方式**產生 Y 的。
