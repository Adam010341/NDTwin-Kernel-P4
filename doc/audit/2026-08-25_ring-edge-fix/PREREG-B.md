# 預註冊 B：把拓撲重建搬離事件迴圈

寫於 B 實作**之前**。作者 `8/25 mainDev`，審查員 `8/24 auditer`。
Adam 直接確認「現在做 B」（2026-08-25）。承接 `PREREG.md`（A 輪）與 `DESIGN-B.md`。

## 0. B 要建立的不變量（這才是 B 的主張，不是 wedge 率）

> **IntelligentRyu 的事件迴圈上不執行任何無界操作，也不執行任何同步 topology request-reply。**

A 的主張是「卡住會恢復」；**B 的主張是「卡不住」**。兩者互補（見 DESIGN-B §0），B 不取代 A——
A 的時限留著，因為搬到 worker 上的呼叫仍可能卡，而**卡住的 worker ＝ 無聲停更**，比 wedge 更難發現。

## 1. 🔑 B 的驗收不需要靶活著

這是 B 相對 A 最重要的性質，也是它值得現在做的理由：

> **結構性斷言**：任何一次 USR2 dump 中，`_event_loop` 那條 greenlet 的 frame
> **永不得**出現 `get_switch` / `get_link` / `get_all_host` / `send_request`。

這條在**冷機器上也能驗**。A 的驗收依賴召喚環（Phase 0 花了 21 分鐘只為了確認靶還活著），
B 不依賴。⇒ **主證據是結構性斷言，wedge 率是輔證。**

## 2. log 文法第三次改寫——先寫下對照表

A 輪的判讀規則（`classify_boot.py`）建立在「handler 內完成鏈」上。B 之後**同樣的字串由 worker 印出**，
計數的**意義**改變：

| 字串 | A 之前／之後 | B 之後 |
|---|---|---|
| `Topology update triggered` | 每個 `EventSwitchEnter` 一次 | **每次重建一次**（已合併，會比事件數少） |
| `Complete get_switch` / `get_link` | 同上 | 同上 |
| `Switch entered:` | handler 內、每事件 | **worker 內、每個排隊的 dpid** |
| `topology read did not answer` | handler | worker |

⇒ **新增一行**把「事件數」與「重建數」分開，否則兩者再也無法區分：
`switch-enter queued for topology rebuild (dpid=%s)` —— 每個事件一次，**在 handler 內**。

**判讀輸入因此改變**：`trig/gsw/glk/ent` 在 B 之後**降為診斷欄位、不再是判定輸入**。
判定只用兩樣：**§1 的結構性斷言** ＋ **保真度對**。

## 3. 判讀規則（跑之前定死）

先驗條件（照 `PREREG.md` 5-bis R2 的順序紀律）：
0. **注入斷言**：worker 的 heartbeat 行必須在場。不在場 ＝ B 沒生效，**該列不算證據**，不得讀成任何結論。

然後：
- **PASS**：結構性斷言成立（全部 dump 零命中）**且** 保真度對 3/3（`edges_down==0 && hosts_ipv4==128`）。
- **PARTIAL**：結構性斷言成立、但保真度未達 ⇒ 環消了、開機另有問題（**新問題，不得記為 B 失敗**）。
- **FAIL**：結構性斷言被違反（事件迴圈仍出現 request-reply frame）⇒ 搬移不完整，frame 直接指名漏網處。
- **SILENT-STALL**（B 專屬的新失效模式）：保真度未達 **且** worker heartbeat 停止推進 ⇒
  worker 自己卡死。**這是 B 引入的風險，必須能被偵測到才算交付。**

## 4. 交付門檻（缺一不可）

1. **coalescing 的核心性質要有斷言**：「最後一個事件之後至少完整重建一次」。
   ⇒ 寫測試，且**先看它失敗**（[[mutation-gate-for-tests]]）。
2. **worker heartbeat 進 USR2 dump**：上次成功重建距今幾秒、worker 目前狀態。
   沒有它，SILENT-STALL 偵測不到，而那是 B 換來的新失效模式。
3. **判讀器 B 版先在歷史 corpus 自測**，照 `24a958c` 的流程（那次自測抓到九格誤判）。
4. **重量當下靶率**（`PREREG.md` §1）：Phase 0 的 2/3 是好幾小時前的數字，靶在腐化。
   ⚠️ 但注意：**B 的主證據不依賴靶**，靶率低不是停跑條件，只影響輔證的強度。

## 5. 已知會改變的語意（逐條要驗）

1. 重建次數變少（合併）。需確認沒有東西依賴「每事件一次」。
2. `_static_topology_spawned` 這個臨時守衛**可能可以拿掉**（單 worker 天然序列化）——
   拿掉前要確認沒有別的路徑進 `load_static_topology`。
3. **notify 也搬走**（DESIGN-B §5 改判：有界佔用也是佔用）⇒ 通知延後最多一輪重建。
   實測支撐：開機期所有 notify 都是 ECONNREFUSED，且 **twin 是靠 kernel 輪詢學拓撲的**，延後的代價很可能是零——但**這是預測，要量**。
4. `self.switches` 的過時窗口變長（合併所致）。今天已有此性質，但窗口變長。

## 6. 本輪不宣稱

- 不宣稱 B 解決「佔用源」問題的全部——**佔用源普查仍未做**。B 消除的是**這一個 handler** 的停車與佔用。
- 不宣稱 A 可以移除。A 的時限是 B 的安全網（§0）。
- 不宣稱任何開機秒數（8/27 deck 規則不變）。
