# F-17 修法影響調查 —— 只查不改，交事實不交結論

**建立 2026-08-29，`8/29 mainDev`。** Adam 08-29 裁定：**先查修法影響再裁「修不修」。**
**本輪未修改任何產品碼**（`TopologyAndFlowMonitor.cpp` 與 Energy-Saving-App 都只讀不動）。

> 🔴 **本文件刻意不下「該修／不該修」的結論。** 那是 Adam 的裁決。
> 下面每一節結尾標的是**這項事實把裁決往哪個方向推**，不是建議。

**被查的東西**：`GET /ndt/get_average_link_usage`，實作在
[src/ndt_core/collection/TopologyAndFlowMonitor.cpp:2755](../../../src/ndt_core/collection/TopologyAndFlowMonitor.cpp)
（`getAvgLinkUsage`），缺陷編號 F-17（`doc/KNOWN-ISSUES.md` §C）。

---

## 1. 今天有誰在讀這個值

**結論：零個活的消費端。** 唯一寫過 client 的是 Energy-Saving-App，而**那個 client 沒有人呼叫**。

`/ndt/` 是跨 repo 契約，這個 repo 的測試不會因為消費端壞掉而變紅，所以**逐一掃了七個兄弟 repo**
（路徑真實來源＝`tools/test_workflow/components.env` 的 `*_DIR`）：

| repo | 有沒有引用這個端點 | 我怎麼確定的 |
|---|---|---|
| **Energy-Saving-App** | ⚠️ **有 client，零呼叫端** | `src/app/http.cpp:393` 定義 `get_average_link_usage()`（打 `/ndt/get_average_link_usage`，`:395`）、`include/app/http.hpp:34` 宣告；`grep` 全 repo 扣掉定義／宣告／它自己的 log 行後**無任何呼叫**。決策點 `energy_saving_app.cpp:926` 讀的是 `group_avg_link_utilization`（`include/common/types.hpp:215`），從 graph 算 |
| Simulation-Platform-Manager | ❌ 無 | `get_average_link_usage`／`avg_link_usage` 皆 0 命中；`/ndt/` 只出現 4 次且**全是字面字串**（`app.hpp:18`、`sim_server.hpp:10` 等） |
| Network-Traffic-Visualizer | ❌ 無 | 同上 0 命中；`/ndt/` 11 次、全字面（README 端點清單） |
| **Traffic-Engineering-App** | ❌ 無 | 🔑 **這個 repo 會拼接**（`Traffic-engineering-App.py:32` `ndt_url = ".../ndt/"`），所以**逐一列出它拼了什麼**：`get_graph_data`、`get_detected_flow_data`、`acquire_lock`、`release_lock`、`install_flow_entry`、`install_flow_entries_modify_flow_entries_and_delete_flow_entries`（`:51/:61/:71/:85/:345/:573`）。**沒有這一個** |
| Network-State-Recorder | ❌ 無 | 0 命中。`/ndt/` 有 11,863 次但集中在 `development_guide` 與錄下來的資料；**原始碼只有兩個端點**（`network_state_recorder.py:21,23`＝flow 與 graph） |
| Web-GUI | ❌ 無 | 0 命中；`/ndt/` 12 次，形如 `` `${NDT_API_BASE_URL}/ndt/get_graph_data` ``——**base URL 是變數但端點名是字面**，所以 grep 抓得到 |
| Network-Traffic-Generator | ❌ 無 | 0 命中；`/ndt/` 2 次、端點名字面（`Utilis/distance_seperate.py:52-53`） |

⚠️ **這個表的邊界**：查的是**磁碟上這七個 repo 的當前工作區**。
**沒有涵蓋**：repo 外的呼叫者（手動 `curl`、GUI 使用者、別台機器上的部署）、
未 clone 的分支、以及任何在執行期才決定端點名的呼叫（**七個 repo 都沒有這種寫法，已逐一確認**）。

🔑 **「零呼叫端」不等於「可以隨便改」** —— 見 [[no-in-repo-callers-is-not-dead-code]]。
Energy-App **已經把 client 寫好放在那裡**，任何人接一行就會用到它。

**→ 這項事實把裁決推向**：修這個端點**今天不會改變任何應用的行為**，所以它既不緊急、風險也低。

---

## 2. `LOW_WATER_MARK` 今天的值

**0.40**，讀自 **`/home/adam/Energy-Saving-App/include/app/settings.hpp:7`**
（`#define LOW_WATER_MARK 0.40`）。同檔 `:6` 是 `#define HIGH_WATER_MARK 0.6`。

- **與 round 4 引用的值一致**，沒有漂移。**這次是現查的，不是抄 round 4 的。**
- 使用點：`src/app/energy_saving_app.cpp:926` `if(*avgLinkUtilization <= LOW_WATER_MARK)`、
  `:928` `else if(*avgLinkUtilization >= HIGH_WATER_MARK)`。
- ⚠️ **那個 repo 有本機、刻意不推的 commit（`9facb78`）。本輪只讀，未 push、未動工作區。**

---

## 3. 改分母之後行為會怎麼變

現行語意＝**忙碌邊的平均**；候選修法＝**可用邊的平均**（分母含閒置邊）。

### 3.1 在 round 4 那個工作點，修了**不會改變決策**

| | 值 | vs `LOW_WATER_MARK` 0.40 | 決策 |
|---|---|---|---|
| 現行（只算忙碌邊） | **0.11** | ≤ 0.40 | 關機 |
| 修法後（算可用邊） | **0.027** | ≤ 0.40 | 關機 |

⇒ **4.0× 的高估在這個工作點上完全不影響決策，因為兩個值都遠在門檻之下。**

### 3.2 決策會不同的區間，以及它會往哪一邊倒

膨脹倍率 `f ≈ 可用邊數 / 忙碌邊數`。**決策只在真值落在 `(0.40/f, 0.40]` 時不同**，
而在那個區間裡 **現行＝不關機、修法後＝關機**：

| 忙碌比例 | f | 決策不同的真值區間 |
|---|---|---|
| 2/32 | 16.0 | (0.025, 0.40] |
| 4/32 | 8.0 | (0.050, 0.40] |
| 8/32（round 4） | 4.0 | **(0.100, 0.40]** |
| 16/32 | 2.0 | (0.200, 0.40] |
| 32/32 | 1.0 | 空（無差異） |

🔴 **所以修法的方向是「更容易關機」，不是「更安全」。**
高估消失 ⇒ 值下降 ⇒ 更容易跌破 low-water mark。
**修掉偏樂觀的那一半，會把偏悲觀的那一半放大。**

### 3.3 修分母**不會**修掉「閒置回 0.0」那一半

| | 沒有忙碌邊時 |
|---|---|
| 現行 | `:2796` `if (!noneZeroEdgeNum) return 0;` → **0.0** |
| 修法後 | `sum(0) / N(可用邊)` → **0.0** |

⇒ **輸出一模一樣。** 「閒置歸零」不是分母造成的，是「零流量的真實平均就是零」。
要讓「真的閒置」與「量不到」可區分，**得改回傳型別或加旗標，那是 API 契約變更**
（`/ndt/` 跨七個 repo）。

### 3.4 同一個 `return 0` 有兩條路走得到

`:2781` 的 `if` 同時要求「`linkBandwidthUsage != 0`」**與**「兩端都不是 HOST」，
兩個條件累加**同一個** `noneZeroEdgeNum` ⇒ **「host 邊被排除」與「沒有忙碌的交換機間邊」
產生同一個 0.0，端點分不出來。** 三份操作手冊原本只講前者、且說「不是壞掉」，
已於 `4126cc4` 各補一句後果（**但明確寫明危險的不是這個端點，是網路狀態本身**）。

**→ 這一節把裁決推向**：修法**不是純粹的改善**。它修掉一個真實的高估，
但同時放大另一個方向的失效，而且**構不到最常被引用的那個症狀（閒置回 0.0）**。

---

## 4. 舊裁定的理由今天還剩哪些

🔴 **`doc/KNOWN-ISSUES.md` §D 上，F-17 這列的書面理由從頭到尾只有一條：「失效方向保守
（少關機，不會誤關）」。而那條已被 round 4 推翻。**

| 理由 | 狀態 |
|---|---|
| 「失效方向保守（少關機，不會誤關）」 | 🔴 **已被 round 4 實測推翻**：有負載時高估 4.0×（偏少關）、閒置時歸零（偏關光）⇒ **雙向** |
| ~~「報告前產品碼凍結」~~ | ⚠️ **這不是 F-17 的理由** —— 它寫在 **A-1/A-2/A-3 那一列**。我先前把它當成 F-17 的理由是**推測**，已在 §D 更正 |

**所以 F-17 的「不修」沒有第二條書面理由可以撐。**
（若 08-18 當時有未寫下的考量，那不在紀錄裡，我查不到。）

📌 **順帶**：即使「報告前凍結」曾經適用，**報告已於 `2b5c7ee` 定稿** ⇒ 那條理由已到期。

---

## 5. 一件本輪順帶查到、不在派工範圍的事

**同一個錯誤前提（「Energy-App 讀這個端點」）在產品碼裡還有兩個引用點，本輪未動：**

| 位置 | 內容 |
|---|---|
| `include/ndt_core/http/HttpSession.hpp:592` | 「This figure is what Energy-Saving-App reads」——🔴 **而且拿它當一次標頭修改的理由** |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:2767` | 同一句話的註解版 |

這是 [[existence-is-not-wiring]] 的實例（**理由比結論活得久，還會被下游引用**）。
**08-28 就已經查證並記在記憶裡了**，但沒有寫回 `KNOWN-ISSUES.md`，
所以 08-29 又被獨立重查了一次。

---

## 5b. 方法紀錄：怎麼量一個背景行程的 CPU（`8/29 auditor` 要求記下來）

本輪要判斷 commit hook 觸發的 `agy` 複審有沒有污染 lab，**`ps` 的 `%CPU` 不能用**
——那是**生命期平均**，不是瞬時值。實際做法：

```bash
read u1 s1 <<< $(awk '{print $14, $15}' /proc/<pid>/stat)   # utime, stime (ticks)
sleep 3
read u2 s2 <<< $(awk '{print $14, $15}' /proc/<pid>/stat)
# ((u2+s2)-(u1+s1)) / 3.0  => % of one core
```

**兩個一起做才算數**：
1. **取兩次差**（上面），得到瞬時佔用；
2. **確認有沒有子行程**（`ps -eo pid,ppid,... | awk '$2==<pid>'`）——
   父行程輕不代表整棵樹輕。本輪確認 `agy` **無子行程**（模型算力在遠端）。

本輪讀數：`ps` 生命期平均 1.3%、**瞬時 0.7% of one core**、無子行程、全程約 6 分鐘。
⚠️ **這不推翻記憶裡「agy 實測 207%」那條** —— 那條本來就註明「非單一常數」。
兩者不矛盾：**要判斷污染就當場量，不要引用常數。**

## 6. 我讀過 vs 只知道檔名

**實際打開讀過、可以負責描述**：`TopologyAndFlowMonitor.cpp:2755-2800`（`getAvgLinkUsage` 全函式）、
`HttpSession.hpp:577-603`、`Energy-Saving-App/{include/app/settings.hpp, include/app/http.hpp,
src/app/http.cpp:393-418, src/app/energy_saving_app.cpp:911-930}`、
`Traffic-engineering-App.py` 的全部 `ndt_url` 使用點、`network_state_recorder.py:21-23`、
`tools/test_workflow/components.env` 的 `*_DIR` 段、三份 runbook 的相關段落。

**只 grep 過、沒有通讀**：Simulation-Platform-Manager／Network-Traffic-Visualizer／Web-GUI／
Network-Traffic-Generator 四個 repo（只確認端點名的命中與拼接方式，**沒有讀它們的邏輯**）。

**[Co-developed with claude code -- Adam]**
