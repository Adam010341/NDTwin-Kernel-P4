# 跨輪稽核：D 輪**執行過**的儀器條款，有幾條在 E／F-5 被掉了

[Co-developed with claude code -- Adam]

**為什麼有這份**：E 的預註冊沒點名 bmv2，而 D 輪的 `ladder_ext.sh:82` **本來就記它的 sha256**。
auditor 的判斷是：**一次遺漏是疏忽，系統性的退步表示我們的預註冊是重寫而不是繼承**——
那樣每一輪都會掉一些東西，而掉的東西不會有人發現，**因為新輪自己讀起來很完整**。
本份用 D 輪**實際執行過**的腳本（有 `.out`／`.log` 的那些）逐項點名，對 E 與 F-5 的**註冊**清查。

**方法**：母體＝`doc/audit/2026-08-25_sampling-rounds/` 中有輸出檔的 13 支腳本
（`cal_c` `ctl_c` `gate_d` `gate_e` `gil_g` `h_probe` `ladder_ext` `n_cell` `n_diag` `run_c`
`run_e8` `wall_f`）＋它們呼叫的 `2026-08-20_.../measure.sh`。
**「註冊」＝寫在該輪 PREREG.md 裡**，不是「腳本剛好有做」——這個區分是本份的重點，見 §3。

⚠️ **本份自己踩過一次 grep 陷阱**：初版用關鍵字掃 PREREG 得出「E 有註冊 production restore、
fabric completeness」，逐行複查後發現分別命中的是「**還原** patch」（TBD-1 的用詞）與我自己
今天才加的 bmv2「**十台**必須同一顆」。**三個 YES 是假陽性。** 下表是逐行複查後的結果。
（[[grep-endpoints-misses-concatenation]]：沒有鑑別力的命中不是發現。）

---

## 1. 清查表

`註冊`＝寫在 PREREG；`腳本`＝我這輪交付的腳本有做。

| # | D 輪執行過的條款 | D 輪出處 | E 註冊 | E 腳本 | F-5 註冊 | F-5 腳本 |
|---|---|---|---|---|---|---|
| 1 | kernel sha256 | `ladder_ext:81` 等六支 | ✅ | ✅ | ✅ | ✅ |
| 2 | **bmv2 binary sha256** | `ladder_ext:82`／`gil_g:136`／`run_e8:34` | ✅ **僅今日 v0.3** | ✅ | ❌ | ❌ |
| 3 | **boot_id ＋ uptime** | `ladder_ext:83` | ❌ | ❌ | ❌ | ❌ |
| 4 | 分析工具 `--selftest` **被呼叫** | `gate_e:53`／`wall_f:127`／`gil_g:124`／`h_probe:109` | ✅ §2.3 | ✅ | ✅ **僅今日 v0.4** | ✅ |
| 5 | **fabric 完整性斷言（`bmv2: 10`）** | 全部 12 支 | ❌ | ✅ | ❌ | 🟡 只驗 API 答話 |
| 6 | **注入落地斷言（sed 真的改到了）** | 全部 `compile_at` | ❌ | ✅ | n/a | n/a |
| 7 | **對「編譯產物」而非只對 source 斷言** | `gate_d:77`／`gil_g:64`／`h_probe:57`／`run_c:50`／`wall_f:74` | ❌ | ✅ | ✅ 今日 v0.4 | ⬜ 待落 |
| 8 | **跨腳本組態污染防護** | `run_c:47`（註解記著 `gate_d` 把 truncate 留在 16384） | ❌ | 🟡 只驗 128 | ❌ | ❌ |
| 9 | reader 的已知非空前置檢查 | `gate_d:89` | ✅ §2.1 | ✅ | ✅ 今日 v0.4 | ✅ |
| 10 | **:8081 按 PID 釋放、絕不 `pkill -f`** | `wall_f:free_8081`／`gil_g`／`h_probe` | ❌ | ✅ | ❌ | n/a |
| 11 | 🔴 **收工還原生產組態＋還原失敗要大聲** | `gate_d:103`／`ladder_ext:121`／`wall_f:142`／`run_c:68`／`h_probe:142`／`ctl_c:71`（**六支全有**） | ❌ | ✅ | ❌ | ❌ |
| 12 | 每格存 `kernel.log`（與 cpu trace 同一次開機） | `ladder_ext:100` | ❌ | ✅ | ❌ | ❌ |
| 13 | host pid 用**精確**比對（`$NF`，非子字串） | `measure.sh:host_pid` | ❌ | 繼承 | ❌ | ❌ |
| 14 | **重啟前後的不變量檢查** | `run_e8:67`（edge count 變了就喊「telemetry multiplication trap」） | ❌ | ❌ | ❌ | ❌ |
| 15 | 每臂記錄 p4 常數實況 | `wall_f:119` | 🟡 只有 truncate | ✅ | ❌ | ❌ |

### 計分

| | 註冊 | 其中今天才補的 | **今天之前** |
|---|---|---|---|
| **E** | 4.5 / 15 | 1（bmv2） | **3.5 / 15** |
| **F-5** | 3 / 15 | 3（v0.4 三條） | **0 / 15**（除第 1 條 kernel sha256 ⇒ 實為 1/15） |

---

## 2. 三條最該立刻補的（都不在任何一張裡）

### 🔴 第 11 條：**收工還原生產組態**，兩張都沒註冊，而 D 輪六支腳本全都有

- D 輪的寫法不只是還原，是**還原失敗要大聲**：
  `ladder_ext:122` — `"BUT production restore failed -- check before releasing lab"`。
- **為什麼這條在這兩輪比 D 輪更危險**：E **改 P4 source 又換 kernel binary**；
  F-5 **在兩臂之間換 kernel binary**。而 `LOCAL-FABRIC-QUEUE` 的 #1 與 #1= 就是這兩輪本身
  ⇒ **前一輪還原失敗，被污染的正是後一輪**，而後一輪讀不出來（它只會看到一個
  「數字有點怪」的 fabric）。
- 🔑 D 輪自己留下了這件事真的發生過的記錄：`run_c.sh:46-47` 的註解
  「earlier arm of `gate_d.sh` set it to 16384 and only its own restore put it back」
  ——所以 `run_c` 才加了一條**獨立**的 `truncate == 128` 斷言（第 8 條）。
  **那是制度記憶，兩張新預註冊都沒有繼承。**
- 建議條款（兩張同文）：
  > 收工必須還原生產組態（P4 常數、kernel binary、`NDTWIN_SFLOW_BATCH` 未設），
  > **並斷言還原成功**；還原失敗必須在 release 之前顯著回報，且**不得 release**。

### 🔴 第 14 條：**重啟前後的不變量**，兩張都沒有，而兩輪都在重啟

`run_e8:67` 在 proxy 重啟前後比對 edge count，變了就喊「telemetry multiplication trap may have
fired」——那是 [[proxy-restart-warm-fabric-multiplies-telemetry]] 的現場守衛。
E 每格重啟、F-5 每次換裝重啟，**沒有任何一張要求重啟前後對帳任何不變量**。

### 🟡 第 3 條：**boot_id**，最便宜的一條

一行，卻是唯一能事後回答「這兩格是不是同一次開機」的東西——而 tid 偏移、
`/proc` 計數器基準都綁在開機上。D 輪記了，兩張新的都沒有。

---

## 3. 這份稽核真正的結論：**「腳本有做」不能替代「有註冊」**

看第 1 節的兩組欄位：**E 腳本欄有 10 個 ✅，E 註冊欄只有 4.5 個。** 差額不是多餘的工，
差額是**下一個人拿不到的東西**：

- 腳本會被改寫、被複製、被另一支取代。D 輪的 `gate_d.sh` **只呼叫了預註冊寫的三項中的兩項**，
  那是 grep 出來的——而它之所以能被 grep 出來，正因為那三項**寫在預註冊裡**。
  沒寫進去的條款，沒有任何東西可以拿來對照。
- 這一輪就有現成的例子：F-5 的偵測器 control 早就在 TR-3 harness 裡，
  但**未註冊的 control 可以被下一版腳本刪掉而不留痕跡**（今日 v0.4 第 (9) 條才補上）。

⇒ **建議把「繼承」變成程序而不是善意**：新一輪的預註冊起草時，
**拿上一輪實際執行的腳本逐項點名**，明寫「繼承 / 不繼承 + 為什麼不」。
不繼承是可以的——**靜默地不繼承不行**，因為新輪自己讀起來一樣完整。

---

## 4. 一條需要精確、不要照搬的（避免製造假警告）

reviewer 線在 PREREG-B 發現的是**裸名 → PATH 查找**。**這一條不能整包搬到 E**：

- E 的 kernel 由 `tools/test_workflow/stack.sh:766` 以
  `bash -c "cd '$KERNEL_DIR/build' && ./bin/ndtwin_kernel ..."` 啟動
  ⇒ **相對路徑，不經 PATH** ⇒ **裸名變體在 kernel 身上不會發生。**
- bmv2 那一側**曾經**是裸名（`p4_testbed_topo.py` 的註解逐字記著它解析到 stock `-O0` build，
  「silently benchmarked a binary roughly 10x slower while every filename, note and slide still
  said fast」），但**自 2026-08-22 起缺 directive 是 REFUSAL 不是 fallback** ⇒ 該支已封。
- ⇒ E 真正殘留的失效路徑只有三條：`cp` 沒落地／前一格行程活過 `stack.sh down`／
  swap 與 exec 之間有人重編。三條都只有**比對跑著那顆**才抓得到，
  這正是 v0.3 補的條款與 `gates_e.sh` G8 在做的事。
- 🔑 把別人的失效模式原封搬過來會製造**假警告**，而假警告會稀釋真警告。
