# 設計 B：把阻塞工作搬離 IntelligentRyu 的事件迴圈

Adam 08-25 裁決：「A 先測，同時設計 B」。本檔是設計，**不是實作**，也還沒測過。

## 0. 先修正一個框架：A 和 B 不是二選一

我原本把 A/B/C 寫成三個互斥選項。讀完碼之後這是錯的：

- **A（包 `hub.Timeout`）** 讓卡住的呼叫**會恢復**，但呼叫仍在事件迴圈上 ⇒ 環仍可在逾時觸發前的窗口內形成，而且下一個無界呼叫出現時又要再包一次。
- **B（搬離事件迴圈）** 讓卡住的呼叫**不能形成環**，但一個卡住的 worker 會**無聲地永遠不更新拓撲**——比 wedge 更難發現。

⇒ **B 需要 A 才安全，A 需要 B 才結構性。正確的終局是兩個都要。**
A 仍然先做，因為它是可證偽的第一刀（見 PREREG.md 的三選一判讀）。

## 1. 範圍是封閉的（本次讀碼的新結果）

掃過 IR 全部 7 個 `@set_ev_cls` handler：

| handler | 事件迴圈上的阻塞 |
|---|---|
| `switch_features_handler` | 無 |
| **`get_topology_data`** | **🔴 L791 `get_switch`、L818 `get_link`＝唯二無界 request-reply** |
| `_state_change_handler` (L912-964) | 只有 `requests.get(timeout=(2,5))`，有界 |
| `_packet_in_handler` | 無 |
| `on_link_delete` | 只有 `requests.post(timeout=(2,5))`，有界 |
| `on_link_add` | 只有 `requests.post(timeout=(2,5))`，有界 |
| `flow_stats_reply_handler` | 無 |

⇒ **不存在第三個未發現的環邊。** B 只需要搬 `get_topology_data` 一個 handler，就能建立不變量：
> **IntelligentRyu 的事件迴圈上不執行任何無界操作。**

（註：`hub.sleep` 是讓出不是阻塞，不算。我第一版的掃描把它算進去了，是錯的。）

## 2. 結構

**不要用 per-event `hub.spawn`。** 開機時 10 個 `EventSwitchEnter` 會生出 10 個並行 body，同時搶
`self.dynamic_net` / `self.switches`，並同時各跑一個 20s 的 `get_switch` 迴圈。

改用**單一合併 worker（coalescing worker）**：

- handler 只留兩件事，兩件都有界：
  1. 該 dpid 的 `inform_switch_entered` 通知（**必須留在 handler**：它是 per-event 的，worker 沒有 `ev`）
  2. 設 dirty 旗標、喚醒 worker、`return`
- worker（init 時 spawn 一個）迴圈：等 dirty → 清 dirty → 跑重算 body（`get_switch`／`get_link`／更新圖／門檻檢查／`load_static_topology`）→ 若期間又 dirty 就再跑一輪

語意從「每個 enter 跑一次重算」變成「**最後一個 enter 之後至少完整跑一次**」——那才是真正的需求，
而且順帶消掉開機時 10 次重複的全量重算。

## 3. 會被改變的語意，逐條列出（B 實作時必須逐條驗）

1. **重算次數變少。** 需確認沒有東西依賴「每 enter 一次」。`install_all_pair_paths` 由
   `install_initial_openflow_entries_completed` 守著，看起來安全，但**要實測**。
2. **`self.switches` 有短暫過時窗口**——不過今天就已經有了（handler 也是逐事件更新），不算退步。
3. **`_static_topology_spawned` 這個臨時守衛可以拿掉**：單一 worker 天然序列化。拿掉前要確認
   沒有別的路徑進 `load_static_topology`。
4. **worker 卡住 = 拓撲無聲不更新。** 所以第 0 節：B 必須連同 A 的逾時一起上，而且 worker 應該
   有 liveness log（「上次成功重算距今 Ns」），否則就是把 wedge 換成一個更安靜的故障模式。

## 4. B 的驗收判讀（先寫下來）

跟 PREREG.md 同樣的三選一，**外加一條 B 專屬的結構性斷言**：

> 任何一次 USR2 dump 中，`_event_loop` 那個 greenlet 的 frame **永遠不得**出現
> `get_switch` / `get_link` / `get_all_host`。

這條比 wedge 率強，因為它**不需要靶活著就能驗**——冷機器上也能證明不變量成立，
正好繞開「靶會腐化」這個一直擋住我們的問題。⇒ **B 的驗收不依賴召喚環，A 的依賴。**

## 5. 尚未決定

- ~~handler 裡那個有界通知，10 台交換機最壞會讓事件迴圈停 10×5s。有界所以不成環，但要不要
  也搬走？搬走會改變通知順序，**未決**。~~
  🔴 **2026-08-25 改判為「必須搬」**，理由是審查員的佔用/停車二分（見 §6）：**有界不等於不填佇列。**
  10×5s 的佔用足以填滿 128 格，而填滿佇列正是環的另一半。搬走時通知順序的改變要另外處理
  （每個 dpid 一則、可亂序，但不可遺漏）。

## 6. 🔴 前提修正：三站表是「停車位」普查，不是「佔用源」普查

審查員 08-25 的機制升級，直接改變 B 的正確性論證，寫在這裡免得下一個人照 §1 的表就動手。

**wedge 是兩階段的**：`111502` dump 拍到 #3 的 spin 階段——每次讀被 `d1d973d` 的 Timeout 彈回，
但**每次仍佔用事件迴圈約 5s**（hto 40–41 次 ≈ 整個 settle 窗），佇列照樣填滿；**下一次**進 handler
才撞上無時限站點停車。⇒ **設陷阱（佔用、填佇列）→ 彈陷阱（撞無界站點）。**

⇒ **逾時擋得住「停車」，擋不住「佔用」。**
⇒ async 臂已把 walk 移出 handler **仍然 wedge**，證明填佇列的不只 walk。

**所以 §1 那張「唯二無界 request-reply」的表仍然正確，但它回答的是「停在哪」，不是「誰把佇列填滿」。**
佔用源普查**尚未做**，候選：`:797` 每事件同步 notify、`:751` 迴圈本身、事件洪峰密度。

**這對 B 反而是好消息**：B 把整個 body 搬離事件迴圈，同時消掉該 handler 的**停車與佔用兩者**，
不需要先做完佔用源普查也能成立——**前提是通知也一起搬**（見 §5 的改判）。
A 就沒有這個性質：它只處理停車。
- C（完全不用同步 topology API，改由已觀察事件維護拓撲）仍是更徹底的解，但 B 若成立，
  C 的收益只剩效率，不再是正確性。⇒ **C 降級為非必要**。
