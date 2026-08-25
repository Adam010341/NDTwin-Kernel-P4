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

## 6. 本次不宣稱的事

- 不宣稱修法順序＝結案。**08-21 15:53 的 walk log（早於兩個修法）就已卡在 #1** ⇒ 站點由「佇列填滿時迴圈走到哪」決定，不由修法決定。逐站包 timeout 本質是打地鼠，A 只是可證偽的第一刀。
- 不宣稱任何開機秒數（8/27 deck 規則）。
