# 預註冊：開機環「環邊本身」修法實驗

寫於實驗開跑前。作者 `8/25 mainDev`，審查員 `8/24 auditer`（機制部分已 4/4 CONFIRMED）。

## 0. 被檢驗的機制（已確認，非本次待驗）

環 = `switches` event loop ⇄ IntelligentRyu event loop 的 2-cycle。
`switches` 那條邊在 5 份 dump 中逐字相同：`switches.py:818` → `_events_sem.acquire()`。
IR 那條邊 = `EventSwitchEnter` handler `get_topology_data` 底下的**無時限 request-reply**，三個站點：

| # | HEAD | 凍結版 `52267aa` | 呼叫 | 現況 |
|---|---|---|---|---|
| 1 | `:752` | `:713` | `get_switch` | **無防護** |
| 2 | `:779` | `:740` | `get_link` | **無防護** |
| 3 | `:979` | `:915` | `get_all_host` | `hub.Timeout` (`d1d973d`) |

**本次要驗的新命題**：#1/#2 是當前 wedge 的環邊；把它們接上時限會破環。

## 1. 停跑條件（Phase 0，必須先跑）

靶會腐化且非單調（同 `boot_id` 17.48h→4/4、18.43h→1/4）。**先量當下 defaults wedge 率，3 次開機。**

- **≥2/3 wedge** → 靶活著，進 Phase 2。
- **0/3** → 靶冷，**停**。修法臂跑出 0/N 什麼都不證明（＝§5-Q 那次的坑）。
- **1/3** → 補到 6 次再判。

判讀用已預註冊並在 47 份歷史 log 上 P1 47/47、P2 零違反的規則：
`Complete get_link` == `Switch entered`；`trig − Complete get_switch` ==1 ⇔ 卡 `get_switch`，==0 且 `gsw>glk` ⇔ 卡 `get_link`。

## 2. Phase 1：儀器化（純加法，隨 Phase 0 一起跑）

USR2 handler 加印各 app 的 event queue `qsize()`。
理由：「Switches 卡在塞 **IR** 的佇列」目前是**消去法推論**（frame 不印 observer 名）。加這一行，下一次 wedge 就把它變成觀察。不改控制流，因此可以在 Phase 0 就帶著。

## 3. Phase 2：修法

**A（本次要測）**：`:752`/`:779` 各包 `hub.Timeout`，並修 `:751` 那個「可被單次迭代內阻塞規避」的 20s 迴圈。
**B（不在本次）**：整個 handler body 搬離 event loop。有 `self.dynamic_net` / `self.switches` 的併發問題，另案。
**C（不在本次）**：完全不用同步 topology API，改由 IR 已觀察到的事件維護拓撲。最結構性、最大改動。

## 4. 預先寫下的判讀規則（三選一，跑之前定死）

- **BREAK**：wedge 0/N（N ≥ Phase 0 的 N）**且**保真度未退（見 §5）→ #1/#2 是環邊，修法足夠。
- **RELOCATE**：仍 wedge，但 dump 的 IR frame **不是** `get_switch`/`get_link`/`get_all_host` → 機制對、修法不完整；新 frame 直接指名下一站。
- **FALSIFY**：仍 wedge **且** dump 仍停在 `:752`/`:779` → **我的機制錯**。

## 5. 兩個「會讓修法通過錯的測試」的陷阱，先寫下防線

1. **注入必須自證**（[[injections-must-assert-their-own-success]]）：新 timeout 觸發時必須 log，harness 斷言該行存在。否則「沒 wedge」可能只是**修法沒生效**，而那會被讀成成功。
2. **保真度，不只連通性**（[[speedups-pass-the-wrong-test]]）：`:752` 逾時 ⇒ `switch_list` 為空 ⇒ handler 走 `:757` 的 "Switch list is empty after timeout" 並 **return**，該次拓撲更新被**跳過**。網路可能照常轉發而 twin 少一台交換機。
   ⇒ **BREAK 的判定必須同時檢查健康基線**（邊數／host 數／`ent`==10），不能只看「沒 wedge」。

## 5-bis. 修訂 A（2026-08-25，Phase 0 boot1 之後、**Phase 2 之前**）

> 預註冊被改寫就沒有價值，所以這節是**追加**不是重寫。上面第 4 節的原文一字未動。
> 來源：`8/24 auditer` 的 PREREG 審查 R1–R5。R1 是他判定的「開跑前必改」，我同意。

### R1【必改】第 4 節的判讀規則會被它要評估的修法弄壞

`:752` 包上逾時後，逾時→空清單→`:757` 的 abort 路徑（"Switch list is empty after timeout" 然後
`return`）**按設計就會出現**，而那條路徑**也產生 `trig − gsw = 1`**——與 P2 的 `WEDGE@get_switch`
signature 逐字相同。

⇒ **P2 是在「#1 無逾時」的 log 文法上驗出 47/47 的；修法 A 改寫那個文法。**
累積計數會把「健康地逾時、放棄、返回、迴圈繼續轉」讀成「卡死在 S1」。

歷史 56 檔的 abort 計數為 0，所以 Phase 0 的分類不受影響（**本修訂不追溯 Phase 0**）。

**Phase 2 改用三腿並列，不用累積差值**：
1. **末態存活探針**：Ryu／kernel HTTP 端點是否應答；USR2 dump 裡事件迴圈是否 parked。
2. **最後一次 invocation 的完成鏈**：最後一個 `Topology update triggered` 之後，是否走到
   `Switch entered:`（完成）／`Switch list is empty after timeout`（健康放棄）／什麼都沒有（真卡死）。
3. **abort 與 hto 計數並列呈現**，不折疊成一個數字。

這是我自己那條 [[a-fix-changes-reachability]] 的判讀版：**修法改變可達性，判讀規則也得跟著改。**

### R2【必改】FALSIFY 與「注入失效」重疊，判讀要有順序

dump 停在 `:752`/`:779` **且零筆新 timeout log** ＝ 防線 1 的**注入失敗**，不是機制被證偽。
⇒ **判讀順序寫死：先驗注入斷言（新 log 行存在＋running router 的 sha 對得上），通過了才進三分支。**

### R3 BREAK 的措辭預先限定

BREAK 只能宣稱「**#1/#2 是當前的環邊**」。**小 N 的 0/N 不得用來關掉 3(b) 的佔用源問題**（見下）。

### R4 母體歸檔
47 檔母體清單與審查員的 56 檔超集複算（`scratch/review-2026-08-25/sweep_replicate_out.txt`）
收進本輪目錄，兩表互為複算。

### R5 儀器化的第二關
`qsize_balance_selftest.py` 的 PASS 輸出存檔；Phase 1 上線後**在真的 USR2 dump 上做一次已知非空
驗證**（[[new-tools-are-the-first-thing-under-test]]：新工具的第一個受測者是它自己）。

### 併入審查員的兩個機制升級（影響 A 的預期，先寫下來）

- **(a) wedge 是兩階段的，逾時擋得住「停車」擋不住「佔用」。** `111502` dump 拍到 #3 的 spin 階段：
  每次讀被 `d1d973d` 的 Timeout 彈回，但**每次仍佔用事件迴圈約 5s**（hto 40–41 次 ≈ 整個 settle 窗），
  佇列照樣填滿；下一次進 handler 才撞上無時限站點。
  ⇒ **設陷阱（佔用、填佇列）→ 彈陷阱（撞無界站點）。**
  ⇒ **對 A 的直接後果**：包逾時可能只是把 #1/#2 也變成「佔用源」而非消除它們。A 仍值得測，
  但 **BREAK 不是唯一合理結果，RELOCATE 的先驗機率比我原本估的高。**
- **(b) 三站表是「無界停車位」的普查，不是「佔用源」的普查。** async 臂已把 walk 移出 handler
  仍 wedge ⇒ 填佇列的不只 walk。候選：`:797` 每事件同步 notify（有界 (2,5)，10 台最壞 50s）、
  `:751` 迴圈本身、事件洪峰密度。**佔用源普查尚未做**，B/C 的設計必須以它為前提。

### 兩處事實更正（我自己的）
- full-stack `2/2/2/2` 桶是 **9 份不是 8 份**（漏數 `diag3`）。審查員複算抓到。
- async spawn 在 HEAD 的 **`:851`**（`:845` 是 `if _async_topology_install:`）。凍結版是 `:794-800`。
  兩者都在 `:779` 之後，論證不變。

## 6. 本次不宣稱的事

- 不宣稱修法順序＝結案。**08-21 15:53 的 walk log（早於兩個修法）就已卡在 #1** ⇒ 站點由「佇列填滿時迴圈走到哪」決定，不由修法決定。逐站包 timeout 本質是打地鼠，A 只是可證偽的第一刀。
- 不宣稱任何開機秒數（8/27 deck 規則）。
