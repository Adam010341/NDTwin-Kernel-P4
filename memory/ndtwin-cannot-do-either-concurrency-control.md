---
name: ndtwin-cannot-do-either-concurrency-control
description: 悲觀鎖被「沒有 owner、零個寫入端點檢查它」擋住，樂觀併發被「commit 失敗偵測不到」擋住——兩條路現在都走不了，而修 F-5 是唯一的解鎖前置
metadata: 
  node_type: memory
  type: project
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-18T13:45:21.855Z
---

Adam 2026-08-18 問「是不是只有 TE 跟 Energy 同時開才會遇到 F-5」，順著查出來的架構結論。

## 現況：兩條標準路線都被擋住

**悲觀鎖走不了。** `LockState` 只有 `{ bool isLocked; time_point expiryTime; }`——**沒有 owner
欄位**。而且 `m_lockManager` 在整個 `HttpSession.cpp` 只出現**三次**（acquire / renew / unlock），
**零個寫入端點檢查它**（逐一查過 `handleInstallFlowEntry`、`processFlowBatch`、
`handleModifyFlowEntry`、`handleDeleteFlowEntry`、`handleSetSwitchesPowerState`，提到鎖的次數全是 0）。
所以它是純君子協定。

好消息：兩個 app 確實配合，而且取同一把——Energy-App(`http.cpp:424`) 與
TE-App(`Traffic-engineering-App.py:71`) 都送 `{"ttl":300,"type":"routing_lock"}`。
定義了 `power_lock`／`graph_lock` 但關電源實際跑在 `routing_lock` 底下。

**樂觀併發也走不了。** 樂觀 CC **必須**在 commit 時可靠偵測衝突，而那正是 F-5
（OVS 上被拒絕的寫入完全無聲，見 [[rejected-requests-can-still-act]]）。

🔑 **所以「寫後驗證」不只是修一個 bug，它是任何真正併發控制的前置條件。**
這改變了 F-5 的優先級判斷——不是因為它常發作（實測 30 分鐘 0 次），是因為它擋住後面的路。

## 文獻（Adam 要求查的，2026-08-18）

這是有名字的已知問題：SDN 因控制集中，多應用衝突機率**比傳統網路更高**。文獻裡還有一類叫
**"hidden conflicts"**——不是規則之間衝突，是**應用行為的副作用**，正好是 TE×Energy 那種形狀。

三條路線：① 規則層衝突偵測（Brew on OpenDaylight、TCDR）② 政策組合（Frenetic/Pyretic、PGA、
NetKAT，要重寫 app）③ **狀態調和 — Statesman, SIGCOMM 2014**（Sun/Mahajan/Rexford，
`https://ratul.org/papers/sigcomm2014-statesman.pdf`）。

Statesman **刻意不以鎖為主要機制**：observed state（實際）／proposed state（app 寫的是
**提案**不是命令）／target state（checker 依狀態依賴圖合併互不衝突的提案並檢查全網不變量）。
衝突時選一個接受、拒絕其他（last-write-wins／鎖／優先級可選）；**被拒絕的 app 不用付額外成本**，
因為它們寫成冪等調和迴圈，下一輪自然重提。已部署在 10 個 Azure 資料中心、>150 萬個狀態變數。

**對 NDTwin 的意義：twin 本身就是 observed state，等於已經有 80%。** 缺的是「app 提案而非下令」
與「合併器＋不變量」。**但那是重新設計七個元件的介面，是報告素材不是本週素材。**

## 三階梯（由便宜到貴）

1. 鎖加 owner token ＋ 寫入端點強制檢查 — 但要改七個元件的契約
2. **寫後驗證（修 F-5）— 我建議先做這個**，它同時修掉幽靈、且是 1 與 3 的前置
3. Statesman 式 propose/merge ＋ 不變量 — 重新設計

相關：[[rejected-requests-can-still-act]]、[[live-round-2026-08-18-two-passes]]。

---

**2026-08-19 補:加 owner 還不夠,`renew` 另外有一個 TTL 缺口。**

`LockManager::renew`(`include/ndt_core/lock_management/LockManager.hpp:123-137`)
**只檢查 `isLocked`,不檢查有沒有過期**(`:131`),然後 `:136` 無條件把
`expiryTime` 設成 `now + ttl`。所以**一個已經過期的租約可以被無限期續下去**——
TTL 對「持有者掛掉」這個情境完全失效。對照 `acquireLock` 是有查 `now < expiryTime` 的。

`doc/KNOWN-ISSUES.md:290` 已記載並有實測:非持有者把別人**過期的** `routing_lock`
從 3s 續到 120s。

🔑 **所以悲觀鎖那條路有兩半**:加 owner(誰能放)＋ 給 `renew` 加 `now < expiry` 守衛
(過期的租約不能復活)。**只做前者,崩潰的持有者仍然永遠不會被驅逐。**
(這條是 Muse Spark 的複審提出、我開檔查證過的。)

## 🆕 08-30：F-5 機制已指認（T-4 FINDING-03，`569f976`）

kernel 對 `/ndt/` 流表查詢會把**已排隊、尚未編程**的請求當成表格列回出去（僅 t=0 可見、t=2 消失）。
指紋＝4 欄 vs 13 欄、無 counters、match 用呼叫端字彙。⇒「修 F-5」現在有明確的靶：
排隊中的請求不得出現在表列，或出現時要帶可判別的狀態欄。

## 🏁 08-30 TR-5：Energy-App 把自己鎖死（FINDING-08）

正本 `doc/audit/2026-08-30_live-traffic-round/FINDING-08_*.md`（`776c91e`；raw `3584da6`）。

**兩臂都關 0 台交換機**（P4 4-host 242 s、OVS 4-host 241 s，link util 0.0%）
⇒ **FINDING-05 的 P4/OVS 不對稱（3 台 vs 0 台）重現不出來**。

機制（取自 app 自己的輸出，不是推的）：
`acquire_lock` 每秒回 **423**「held by another client」。`energy_saving_app.cpp:952` 的迴圈
`if (!acquire_lock()) { sleep(1); continue; }` ⇒ **鎖拿不到＝一個 cycle 都沒跑**，
不是「跑了但決定不關」。持有者是它自己的第一個 instance：兩個 `release_lock()` 都在
「模擬往返完成」的條件分支裡，而沒有 Simulation-Platform-Manager 在跑就永遠不會完成。
TTL **300 s > 241 s 的觀察窗** ⇒ 單次觀察窗結構上不可能看到第二個 cycle。
🔴 **鎖活過行程**：`energy-stop` 之後再 acquire 仍然 423；清法＝
`POST /ndt/release_lock {"type":"routing_lock"}`（任何 client 都能解別人的鎖，200）。

🔴 **儀器同型錯**：harness 印「4 full 60 s app cycles, which is the number to quote」——
那是牆鐘不是決策數，只有**一個** cycle 決策過。PREREG 要求「每臂 ≥2 decision cycles」
**兩臂都沒達到，而腳本回報達到了**。cycle 數要用數的（`received_a_simulation_case` 各 3 次、
全在第一個 cycle），不能拿秒數除以設定的 cadence。

🔑 **不要據此結案 FINDING-05**：15:30 到今晚同時改了兩件事——kernel `89c1754`→`1208d22`
＋agy 移除。「舊版 acquire_lock 一律放行」已被**否證**（`4ee086f` 改的是 malformed body
回 400 不回 423）。決定性的一臂＝拿 `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel-t4-baseline`
再跑一次 energy watch，便宜、未跑。
