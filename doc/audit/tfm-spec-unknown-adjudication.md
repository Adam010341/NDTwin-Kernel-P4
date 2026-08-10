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

代價是啟用有最多 1 秒延遲（poll 間隔，:1798），而且會自我修正。用一個「可能路由到黑洞」的窗口換
1 秒，不值得。

`enableSwitchAndEdges` 因此**不是**沒被呼叫的死碼，它的呼叫點語意是對的：Intent Translator 的
`ENABLE_SWITCH`（IntentTranslator.cpp:227）—— 那是**管理員意圖**，管理員說「啟用 s3」本來就涵蓋
它的鏈路。discovery 管活著沒活著，管理意圖管准不准用，兩者本來就該由不同的函式管。

---

## SU-3 `isUp` 與 `isEnabled` 的語意 → **它猜對了，而且這條問題問出了一個真缺陷**

### 語意本身

它猜 `isEnabled` = 管理啟用、`isUp` = 實際運作。程式碼自己就這樣講，不必推論 ——
LLMAgent.cpp:216-217 把兩者塞進 LLM prompt 時的字面用詞是：

```cpp
"(administratively " + (vprop.isEnabled ? "up" : "down") +
", powered " + (vprop.isUp ? "on" : "off") + "), "
```

消費端一律取**交集**：BFS 走訪（:2204、:2208 `if (!g[x].isUp || !g[x].isEnabled) continue;`）、
`/ndt/` 的鏈路狀態（:2511）、路徑列舉（:2577）、鏈路使用率（:1902）。所以任一為 false 就等於不可用。

它問的「`isEnabled=true` 但 `isUp=false` 是什麼狀態」答案是：**行政上允許、實際上不通**，而且對
路由的效果與兩者皆 false 相同。

順帶確認了我做 link watchdog 時依賴的一件事：`handleLinkFailure` → `setEdgeDown` 只清 `isUp`
（:1446），而 BFS 檢查的是交集，所以**失效回報真的會讓那條邊退出選路**。回報有效，只是活不過 1 秒
—— 那是 `down_link_endpoints` 修掉的部分。

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

> **LLM intent「DisableSwitch s3」在 1 秒內被 topology poll 撤销。**

證據鏈，每一環都可重跑：

1. `"DisableSwitch"` → `DISABLE_SWITCH`（LLMResponseTypes.hpp:234-236），是解析得出的、非死碼。
2. `DISABLE_SWITCH` → `disableSwitchAndEdges(dpid)`（IntentTranslator.cpp:209-216）。
3. `disableSwitchAndEdges` 只把頂點與相鄰邊的 `isEnabled` 設 false，不動 `isUp`。
4. `updateSwitches` 對 poll 回報裡的每台 switch 無條件 `isEnabled = true`；`updateLinks` 對每條
   link 同樣。
5. poll 間隔 1 秒（TopologyAndFlowMonitor.cpp:1798）。
6. `grep -n "adminDisabled\|administrativelyDisabled\|isAdmin" include/common_types/GraphTypes.hpp`
   → **0 筆**。沒有任何欄位能記住「管理員關過這台」，所以 poll 沒有東西可以尊重。

只要那台 switch 還連著控制器，`DisableSwitch` 就是個 no-op —— 而且不會有任何一行 log 說它被撤销。
這是**「應該取代卻只能新增」的第 6 例**，形狀與我剛修掉的 link 失效完全相同：一邊只會設 true，另一邊
只會設 false，兩邊都沒有「誰說了算」的概念。

差別在受害者是誰：link 那一例是我自己 ship 的，這一例是 OVS 路徑上**既有**的使用者功能，與 P4 無關。

### 為什麼不在這次一起修

修法是設計決策，不是補一行：要嘛在 `VertexProperties`／`EdgeProperties` 加一個管理意圖欄位，讓
discovery 只准動 `isUp`、不准碰 `isEnabled`；要嘛明確宣告「管理停用不持久，靠外部系統重放」。前者
會改到 `/ndt/get_graph_data` 的語意與 `from_json`／`to_json`，是 7 個下游 app 的契約。留給 Adam
決定，已進 todo。

### 順手記下的第二個小不對稱

`pingWorker` 失敗時設 `setVertexDown` ＋ `setVertexDisable`（兩個都清），成功時只設
`setVertexUp`（DeviceConfigurationAndPowerManager.cpp:697-706）—— 不設 `setVertexEnable`。所以
ping 恢復後那台 switch 是 `isUp=true, isEnabled=false`，交集判定下**仍然不可用**，要等 topology
poll 把 `isEnabled` 補回來。目前被 poll 掩蓋，所以看不出來；一旦上面的修法讓 poll 不再碰
`isEnabled`，這個不對稱就會變成「ping 恢復後永遠回不來」。兩件事必須一起改。
