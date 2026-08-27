# 明天接手：剩下什麼、線索在哪

**2026-08-27 深夜，`8/27 mainDev` 停工前寫。** 用量要留給半夜的長跑 session。
**一行一項，附檔案路徑與行號，接手的人不必重找。**

---

## ✅ 已完成並 commit（**不要重做**）

| 項目 | commit | 結論 |
|---|---|---|
| **② 對帳 2026-08-13** | `6b6ba52` | 🔴 **確認不同源**。W 有 15 秒硬上界，觀察值 291 秒＝19 倍 |
| **① 讀 Energy-Saving-App** | `d38d209` | 🔴 **逐流消費，嚴重度分支相依**（baseline 有幻影負載、本分支沒有） |
| M-quater（6-2 退場、換指標） | `f6cc9b1` | 已放行，**臂未跑** |
| W 預註冊＋倍率公式 | `59d58fb`、`6b6ba52` | |
| KNOWN-ISSUES B 類 | `80f0fbd`、`b9f920e` | |
| pre-flight readout（投影片的 13× 有檔案了） | `8c9e841` | |

---

## 🔴 剩下**一件**：③ 查 API 文件有沒有揭露「含已結束的流」

**目標檔**：`doc/2026-01-02_ndt_api.md` **§4**（`get_detected_flow_data` 的規格）

**要回答的**：文件有沒有說這個端點會回傳**已經結束**的流？

- **有寫** ⇒ W 降級成「文件被忽略」，不是缺陷 ⇒ W 的措辭要改
- **沒寫** ⇒ 端點沒有表達自己的語意 ⇒ 維持 W 現在的措辭（**缺陷在沒表達，不在保留本身**）

**⚠️ 兩種結果都會改 W 的措辭，所以不可跳過。**

**現成線索**：
- 契約測試已經替這個端點定了型別：`tools/contract_test/selftest_fixtures.py:75`
  `"get_detected_flow_data": (spec.List(spec.FLOW_RECORD), FLOW_DATA_SAMPLE)`
  ⇒ **看 `spec.FLOW_RECORD` 有沒有任何欄位能表達「這條已經死了」**。目前已知的欄位裡沒有。

---

## 📌 追 ①／② 時撿到、但**還沒有人追**的三條

| # | 線索 | 位置 |
|---|---|---|
| **N-1** 🔴 | **系統時鐘倒退 ⇒ 流永遠不被清除**。`if (now <= info.endTime) { continue; }`，而 `now` 來自 `getCurrentTimeMillisSystemClock()`（**系統時鐘，不是 steady**）。NTP 校正／VM suspend-resume／手動改時間都會觸發，**產生沒有上界的殭屍紀錄**——正是 291 秒那個形狀。**未驗證，具名可測**：把時鐘往回撥，看那條流會不會永遠留著 | `src/ndt_core/collection/FlowLinkUsageCollector.cpp:2242` |
| **N-2** | 模擬器**讀哪一個速率欄位**未確認。baseline 上只有 `_in_the_proceeding_1sec_timeslot` 會保留陳舊值，`_in_the_last_sec` 兩邊都讀 0。**無原始碼** ⇒ 只能用行為推 | `~/Energy-Saving-App/energy_saving_simulator`（ELF） |
| **N-3** | 模擬器可能把**流的數量**當指標（`strings` 有 `flows are EMPTY!`）。**若是，13× 在兩個分支上都會咬人，與速率無關** | 同上 |

**N-1 我建議獨立成工單**：它與 15 秒尾巴是**兩個不同的缺陷**，只是症狀重疊。

---

## 🔑 今晚為 chaos 差異臂預先寫下的預測（**在它跑之前**）

> **baseline 的 `get_detected_top_k_flow_data` 在流量停止後 5–10 秒仍會回報非零、
> 逐位元相同的速率；本分支會回報 0。**

- 依據：`FLUC:1896-1910` 的註解記著 baseline 實測「iperf3 結束後 5 秒與 10 秒仍回報
  逐位相同的 20.3 Mbps / 10496 pps」
- guard `31b357a` **不是 `origin/main` 的祖先**（`git merge-base --is-ancestor` 驗過）
- 🔴 **若 baseline 沒有重現 ⇒ `d38d209` 裡整段對 baseline 的歸因要撤回**

---

## Q／M 兩張工單的狀態（臂全部未跑）

- **Q**：碼＋測試＋五個突變＋負控制全 commit（`f5e3556`／`01c583c`／`fb517a1`）。
  驗收在真實 180 s 臂上跑過：`GATE: 7/7 live, worst 0.0000%`。**臂要照審查員的鏡像設計重跑**（`base Q M M Q base`）
- **M**：6-2 已退場，改用「流建立 → 第一次拿到 path 的延遲」。**不要用 6-2 跑臂**
- **三顆 binary** 在 `.test_run/binaries/`，sha 與用途見 `.test_run/lab.handoff`

---

## 🔑 通則（審查員要求寫進 handoff，一併記在這裡）

> **發現要隨時落盤，不要等一輪結束才寫。**
> **用量中斷、session 掛掉、context 壓縮——三種都會讓「還沒寫下來的」蒸發，而且都不給警告。**

這與今晚自己抓到的「**交接動作不能早於證據保存**」是同一條，
差別只在**這次的交接是被動的，而被動的交接不會等你**。

[Co-developed with claude code -- Adam]
