# 裁決 DeepSeek 在 TFM 測試裡列出的三個 SPEC-UNKNOWN（2026-08-10）

外包測試時我要求它：**期望行為不准從 `src/` 推導**，判不出來的就標 SPEC-UNKNOWN 交回來。它交回三
個。這份文件是裁決，每一條都附可重跑的證據。

報告本體：`doc/audit/tfm-tests-2026-08-09.md`。測試已落地為
`tests/test_TopologyAndFlowMonitor_mininet.cpp`（11 個，全綠）。

[Co-developed with claude code -- Adam]

---

## SU-1 `touchEdgeFlow` 是累積還是取代 → **累積是對的，不是缺陷**

它的判斷正確，而且它自己列的第一個確認條件就是關鍵：**移除路徑存在嗎？**

存在。`flushEdgeFlowLoop`（TopologyAndFlowMonitor.cpp:2631）每 1 秒掃全部邊，砍掉 `last_seen`
超過 2 秒的 entry；`touchEdgeFlow`（:2672）是 insert-or-refresh，`emplace` 失敗就更新時間戳。所以
flowSet 有界，舊 flow 會在最後一個 sample 之後 2 秒消失。

這條**不算**「應該取代卻只能新增」的一例。那個 bug shape 的判準是「舊資料什麼時候消失」，這裡答得
出來：2 秒後由 TTL 砍掉。它的測試 `TouchEdgeFlowAccumulatesEntriesCurrentBehavior` 命名成
「CurrentBehavior」是過度保守 —— 這就是規格行為。

---

## SU-2 `inform_switch_entered` 該不該一併啟用相鄰邊 → **不該，維持現狀**

它主張該改成呼叫 `enableSwitchAndEdges`。我判**不改**，理由是證據不對稱：

- switch 連上控制器，只證明**那台 switch** 活著。它完全不證明對面那台活著，也不證明中間那條線通。
- 邊由 topology poll 的 `updateLinks` 打開，而 poll 的內容是控制器（或 P4 proxy）**實際回報的
  link**。那是有證據的啟用。
- 若 switch-entered 就把所有相鄰邊打開，等於在沒有 link 證據的情況下宣告鏈路可用。BFS
  （TopologyAndFlowMonitor.cpp:2204-2208）就會在死鏈路上算路徑，直到下一次失效偵測。

代價是啟用會延遲一個 poll 週期。**這裡我原先寫「最多 1 秒」是錯的**：:1798 的 1 秒是 sleep 的切片，
存在的目的是讓 `stop()` 不必等完一個完整週期；真正的間隔在 :1793-1795，前 90 秒（`kConvergingFor`）
是 5 秒（`kWhileConverging`），之後永遠是 30 秒（`kOnceConverged`）。

所以這筆交易的真實形狀是：用「一台新加入的 switch 最多 30 秒還不能被選路」換掉「可能在沒有 link 證據
的鏈路上算路徑」。我仍然判不改 —— 前者會自我修正而且只影響剛加入的 switch，後者是把錯的答案交給下游
——但 30 秒不是可以忽略的數字。若日後有人回報「switch 上線後遲遲不可用」，原因就在這裡，而正確的修法
是縮短 `kOnceConverged` 或替 switch-entered 補一次立即 poll，不是回頭去改 `inform_switch_entered`
的語意。

`enableSwitchAndEdges` 因此**不是**沒被呼叫的死碼，它的呼叫點語意是對的：Intent Translator 的
`ENABLE_SWITCH`（IntentTranslator.cpp:227）—— 那是**管理員意圖**，管理員說「啟用 s3」本來就涵蓋
它的鏈路。discovery 管活著沒活著，管理意圖管准不准用，兩者本來就該由不同的函式管。

> ⚠️ **這段理由與 SU-3 的發現直接衝突，衝突尚未解決。**
> 上一句的「本來就該由不同的函式管」是**規範性**主張（應該如此），不是對現況的描述。SU-3 證明現況
> 恰好相反：discovery 會無條件覆寫 `isEnabled`，也就是 discovery 正在踩管理意圖。所以 SU-2 的結論
> （不改 `inform_switch_entered`）目前只靠上面那個**證據不對稱**的論證支撐 —— 那個論證獨立成立、
> 不依賴這句話 —— 而「職責分離」這個理由要等 §「為什麼不在這次一起修」的設計決策拍板後才會成真。
> 若 Adam 選了「明確宣告管理停用不持久」那條路，這句話就得刪掉，SU-2 的結論不受影響。

---

## SU-3 `isUp` 與 `isEnabled` 的語意 → **它猜對了，而且這條問題問出了一個真缺陷**

### 語意本身

它猜 `isEnabled` = 管理啟用、`isUp` = 實際運作。程式碼自己就這樣講，不必推論 ——
LLMAgent.cpp:216-217 把兩者塞進 LLM prompt 時的字面用詞是：

```cpp
"(administratively " + (vprop.isEnabled ? "up" : "down") +
", powered " + (vprop.isUp ? "on" : "off") + "), "
```

消費端**幾乎**一律取交集 —— 但有一個例外，而我上一版把它寫漏了，而且是用一句沒查證的話帶過的：

| 站點 | 判斷 |
|---|---|
| BFS 最短路（:2204、:2208） | `isUp && isEnabled` |
| DFS 全路徑列舉（:1902） | `isUp && isEnabled` |
| 鏈路狀態回覆（:2511） | `isUp && isEnabled` |
| top-k 鏈路（:2577） | 正反向共四個旗標全要 |
| **平均鏈路使用率 `getAvgLinkUsage`（:2418）** | **只看 `isUp`** |
| `graphLivenessSummary`（:1818、:1835） | 只看 `isUp`，但這是對的 —— 它報的就是 liveness，不是可用性 |

上一版寫成「鏈路使用率（:1902）」是兩個錯誤疊在一起：:1902 是 DFS 全路徑列舉、不是使用率，而真正的
使用率函式 :2418 恰好就是唯一不取交集的那個。

`getAvgLinkUsage` 因此名實不符：一條管理上已停用、但仍通電且還有殘留流量的鏈路，會被算進平均使用率。
嚴重度低（是指標，不影響選路），但它與下面的設計決策綁在一起 —— 若採「加管理意圖欄位」那條路、
discovery 不再覆寫 `isEnabled`，管理停用才會真的持久，這個偏差也才會真的被看見。

修正後的結論：**對選路而言**任一為 false 就等於不可用；**對指標而言**不成立。

它問的「`isEnabled=true` 但 `isUp=false` 是什麼狀態」答案是：**行政上允許、實際上不通**，而且對
路由的效果與兩者皆 false 相同。

順帶確認了我做 link watchdog 時依賴的一件事：`handleLinkFailure` → `setEdgeDown` 只清 `isUp`
（:1446），而 BFS 檢查的是交集，所以**失效回報真的會讓那條邊退出選路**。回報有效，只是活不過一個
poll 週期（5 秒／30 秒，見 SU-2 的更正）—— 那是 `down_link_endpoints` 修掉的部分。

### 而這條問題底下有一個真缺陷（新發現）

**寫入端從來不區分這兩個 flag。** 三條 discovery 路徑都是成對無條件設 true：

| 位置 | 動作 |
|---|---|
| `updateSwitches` | `isUp = true; isEnabled = true;`（凡是 poll 回報裡出現的 switch） |
| `updateHosts` | 同上，含正向與反向邊 |
| `updateLinks` | 同上（`isEnabled = true` 就在這裡） |
| `handleInformSwitchEntered` | `setVertexUp` ＋ `setVertexEnable`（HttpSession.cpp:1080-1081） |

清 false 的路徑只有三個，而且**都不是**成對的：`setEdgeDown` 只清 `isUp`；`setVertexDisable` 只清
`isEnabled`；`disableSwitchAndEdges` 只清頂點與相鄰邊的 `isEnabled`。

於是：

> **LLM intent「DisableSwitch s3」會在一個 topology poll 週期內被無聲撤销。**

證據鏈，每一環都可重跑：

1. `"DisableSwitch"` → `DISABLE_SWITCH`（LLMResponseTypes.hpp:234-236），是解析得出的、非死碼。
2. `DISABLE_SWITCH` → `disableSwitchAndEdges(dpid)`（IntentTranslator.cpp:209-216）。
3. `disableSwitchAndEdges` 只把頂點與相鄰邊的 `isEnabled` 設 false，不動 `isUp`。
4. `updateSwitches` 對 poll 回報裡的每台 switch 無條件 `isEnabled = true`；`updateLinks` 對每條
   link 同樣。
5. poll 間隔為 5 秒（程序啟動後前 90 秒）／30 秒（之後）——
   TopologyAndFlowMonitor.cpp:1793-1795。**更正**：先前這裡寫「1 秒（:1798）」是誤讀，:1798 是
   sleep 的 1 秒切片而非 poll 間隔。撤销窗口因此比原先聲稱的大一個數量級，但撤销本身照樣發生。
6. `grep -n "adminDisabled\|administrativelyDisabled\|isAdmin" include/common_types/GraphTypes.hpp`
   → **0 筆**。沒有任何欄位能記住「管理員關過這台」，所以 poll 沒有東西可以尊重。

只要那台 switch 還連著控制器，`DisableSwitch` 就是個 no-op —— 而且不會有任何一行 log 說它被撤销。
這是**「應該取代卻只能新增」的第 6 例**，形狀與我剛修掉的 link 失效完全相同：一邊只會設 true，另一邊
只會設 false，兩邊都沒有「誰說了算」的概念。

差別在受害者是誰：link 那一例是我自己 ship 的，這一例是 OVS 路徑上**既有**的使用者功能，與 P4 無關。

### 兩個修法的影響面分析（2026-08-10 量測，供 Adam 裁決）

先更正上一版寫的成本：**「7 個下游 app 的契約」被高估了，而「discovery 只准動 `isUp`」這個修法
會直接弄壞系統。** 兩點都是量出來的。

#### 量測結果

| 問題 | 量測 | 結論 |
|---|---|---|
| `from_json`／`to_json`（`GraphTypes.hpp`）有幾個活的呼叫點？ | **0 個。** 三個拓撲載入點（TFM:195-196、:266-267、DCPM:1564-1565）都把 `get<VertexProperties>()` 註解掉、改用手寫萃取 | kernel 這側**不是**契約面 |
| `is_enabled` 真正被送出去的地方？ | **只有 2 行**：`HttpSession.cpp:514`（node）與 `:528`（edge），都在 `handleGetGraphData` 裡手寫 | 序列化改動 = 2 行 |
| 幾個下游 app 讀 `is_enabled`？ | 4 個（Energy-Saving 18、Visualizer 39、Web-GUI 17、TE-App 4）。**其餘 3 個完全不讀** | 影響面是 4 不是 7 |
| **新增**一個欄位會不會弄壞它們？ | Visualizer 明確設 `FAIL_ON_UNKNOWN_PROPERTIES=false`；Energy-Saving 用 nlohmann `.at()` 逐欄取（無視多餘 key）；Web-GUI 是 TS／TE-App 是 Python，都忽略未知 key | **四個都安全** |
| 它們怎麼用 `is_enabled`？ | Energy-Saving 的模擬器 `energy_saving_simulator.cpp:295,299` 是 `if (!isUp \|\| !isEnabled) continue;` —— **和 kernel BFS 完全同一個交集**；Web-GUI `SwitchPortPanel.tsx:80,124` 拿它 gate 顯示；Visualizer 缺欄位時預設 `true` | 消費端已經把它當「可不可用」在讀 |

#### ⚠️ 原本寫的 Option 1 會讓整張圖變黑，不要做

「加管理意圖欄位，discovery 只准動 `isUp`、不准碰 `isEnabled`」——**這個做法會讓 kernel 停止運作**：

載入時 `vp.isEnabled = false`（TFM:203）、`ep.isEnabled = false`（:270），而把它們翻成 true 的
**唯一**路徑就是 discovery（`updateSwitches`／`updateLinks`／`updateHosts`）。禁止 discovery 碰它，
就再也沒有東西會啟用任何邊 —— BFS 全空、`path` 全空、四個 app 一起壞。它同時也會弄壞 `pingWorker`：
失敗時清 `isUp` ＋ `isEnabled`、成功時只設 `setVertexUp`（DCPM:697-706），目前靠 poll 把
`isEnabled` 補回來，poll 一旦不碰它，ping 恢復後就永遠回不來。

#### Option 1′（修正後的加欄位版）

`isEnabled` 的語意**維持不變**（「控制平面驅動得到這台」，由 discovery 負責），另外加一個
`adminDisabled`（預設 `false`），**discovery 永遠不碰它**，然後在消費端與送出的 `is_enabled` 折進去。

| 改動 | 站點數 |
|---|---|
| `GraphTypes.hpp`：2 個欄位 ＋ `to_json`／`from_json` 各 2（死碼，但要保持誠實） | 6 |
| `setVertexDisable`／`setVertexEnable`／`disableSwitchAndEdges`／`enableSwitchAndEdges` 改寫新欄位 | 4 |
| 消費端交集：:1902、:2204、:2208、:2511、:2577（＋ :2418 的 `getAvgLinkUsage` 要順便裁決） | 5–6 |
| `HttpSession.cpp:514`／`:528` 折進送出的 `is_enabled` | 2 |
| 測試 ＋ mutation | 新增 |

**約 17–18 個站點、3–4 個檔案，全部在 kernel 內，下游零改動。** ⚠️ 這是**站點數**不是實測 diff ——
我沒有實際寫出來，所以不要當成「小改」；本專案有前例是我照站點數估「不大」而實際 diff 判為 large。

好處：`pingWorker` 完全不用動（discovery 照樣補 `isEnabled`，那個不對稱維持現狀、不惡化）；
四個 app 不必改就會開始看見管理停用，因為它們已經在用交集判定。

#### Option 2（宣告不持久 ＋ 補 log）

`disableSwitchAndEdges` 與 `setVertexDisable` 各加一行 WARN，講明「這個狀態會在下一個 topology
poll（5–30 秒）被覆蓋，要持久必須由外部系統重放」，並寫進 `ndt_api.md`。**約 2 個站點。**

代價：`DisableSwitch` 仍然是 no-op，只是**不再無聲**。

#### 嚴重性

| 面向 | 評估 |
|---|---|
| 可觸達性 | **窄。** 唯一入口是 `POST /ndt/intent_translator/text`（Web-GUI），且 kernel 要以 `--ai` 啟動。Energy-Saving-App 那個 `/ndt/disable_switch` 是 **0 呼叫點的死碼**，節能實際走 `set_switches_power_state`，不經這條路 |
| 觸發頻率 | 低，人工驅動 |
| 錯誤形態 | **管理員下的指令被無聲撤銷**，而且四個 app 的畫面會顯示它仍然啟用 |
| 資料損毀 | 無。不會弄壞狀態，只是意圖遺失 |

**綜合：低頻 × 窄入口 × 完全無聲。** 不是緊急項目，但它是「系統對現實說了假話」那一類，
而這一類正是本專案排序原則裡排最前面的。

#### ⚠️ 實作 Option 1′ 時挖到的第三件事：BFS 檢查的是**反方向**的邊（未修）

`bfsAllPathsToDst`（TopologyAndFlowMonitor.cpp:2148）從**目的地**出發，走
`boost::out_edges(current, g)` 往外擴。所以它驗證的邊是 `current → neighbor`，而它正在規劃的流量
走的是 `neighbor → current` —— **它檢查的是封包實際行進方向的反面。**

目前不可觸達，因為兩個寫入端都是對稱的：`disableSwitchAndEdges` 會設所有相鄰邊（兩個方向），
`handleLinkFailure` 也是兩個方向一起標下來（HANDOFF §1g 的實測輸出可證）。所以「只有一個方向不通」
這個狀態在生產路徑上產生不出來。

但它是個埋著的陷阱，而且**離被踩到不遠**：P4 的 link watchdog 明確把「單向失效」當成一等公民
（`down_link_endpoints` 的註解寫「反向若自己還在收 beacon 就保留上報，那才是真正的單向失效」）。
哪一天那條路徑真的只報一個方向 down，BFS 會照樣把流量排進去。

發現方式值得記：deepseek 寫的測試只停用一個方向，於是紅了；我一度以為是自己的 `isUsable` 改動漏了
站點。實際上是測試造了一個生產到不了的狀態。測試已改成兩個方向都停（並在註解裡寫明理由，避免有人
把它「修」回單向），這一條列為**未修的獨立發現**，因為修法要決定「是否兩個方向都檢查」，那會改變
選路行為，不屬於這次的範圍。

#### 我的建議

**做 Option 1′。** 理由是量測推翻了原本讓它顯得昂貴的那個前提：下游契約其實只有 2 行送出點，
而四個消費端已經在用交集語意，所以折進去對它們是**修好**而不是破壞。Option 2 只把無聲變成有聲，
留下一個永遠不會生效的 API —— 而 `EnableSwitch`／`DisableSwitch` 這一對是 Intent Translator
對外宣告的能力。

若要縮小第一步：先只做 vertex（不做 edge），站點數砍半，`DisableSwitch` 就能持久；
`disableSwitchAndEdges` 的邊那半留到第二個 commit。

### 順手記下的第二個小不對稱

`pingWorker` 失敗時設 `setVertexDown` ＋ `setVertexDisable`（兩個都清），成功時只設
`setVertexUp`（DeviceConfigurationAndPowerManager.cpp:697-706）—— 不設 `setVertexEnable`。所以
ping 恢復後那台 switch 是 `isUp=true, isEnabled=false`，交集判定下**仍然不可用**，要等 topology
poll 把 `isEnabled` 補回來。目前被 poll 掩蓋，所以看不出來。

⚠️ **上一版寫「兩件事必須一起改」—— 那只對被否決的那個做法成立。** 在 Option 1′ 底下 discovery
照樣寫 `isEnabled`，所以這個不對稱**維持現狀、不會惡化**，可以獨立處理。它會變成「ping 恢復後永遠
回不來」的前提，是「poll 不再碰 `isEnabled`」—— 而那正是我判定不要做的那個設計。
