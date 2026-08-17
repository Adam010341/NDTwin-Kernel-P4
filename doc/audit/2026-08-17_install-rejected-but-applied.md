# `/ndt/install_flow_entry` 回 400 卻真的裝上規則（2026-08-17，live 實證）

**一句話**：一個**只缺 `priority`** 的 install body，API 回
`400 {"error":"JSON parsing error"}`，而規則**已經裝進交換機並開始轉發**。
客戶端被告知請求被拒絕，資料面卻已經改變了。

**這是本 repo 記載過的 bug 形狀的反面**：不是「做了沒做的事卻報成功」
（`[[bmv2-unknown-status-vocabulary]]`／HANDOFF 的 success-reported-for-work-not-done 族），
而是**「做了事卻報失敗」**。後者更難發現：沒有人會去查一個被拒絕的請求做了什麼。

[Co-developed with claude code -- Adam]

## 怎麼找到的

不是讀程式碼找到的。契約套件 L2 全綠（51/51）但 kernel log 有
`dispatched install failed for dpid 1 (priority 0)`——**佇列式端點只驗「誠實地說已排隊」，
沒有任何檢查看得到派送結果**，所以綠燈與失敗同時存在。追這條矛盾追出來的。

歸因過程本身有個轉折：三個 flow-write 檢查**單獨跑都不產生任何 warning**，
三個 batch 檢查也不產生。只有整套跑會出現一條。線索是 **`priority 0`**——
套件裡每個 install 都送 `priority: 1`，所以送出它的不是它們，
是 `install_flow_entry__missing_fields`（body 只有 `{"dpid": 1}`）。

## 機制（讀過程式碼，不是從現象推論）

1. `HttpSession::handleInstallFlowEntry` 把 entry 包成 batch → `processFlowBatch`。
2. `processFlowBatch` 用 `makeInstallJob` 建 job，取值是
   **`entry.value("priority", 0)`**（`HttpSession.cpp:856`）——**缺 priority 不會丟例外**，
   預設 0。建 job 的迴圈確實包在 try/catch 裡並會回 400，但這個 body 根本走不到那個 catch。
3. job **`enqueue()` 出去**，回應設成 `200 {"status":"queued"}`。
4. **之後**才輪到 `DeviceConfigurationAndPowerManager::updateOpenFlowTables`
   （`:1916`）更新本地表快取，它用的是
   **`newFlow["priority"] = e.at("priority")`（`:2004`，另一處 `:2034`）**——
   `.at()` 對缺鍵丟 `json::out_of_range.403`。
5. 例外逃到 `HttpSession::buildResponse` 的外層 handler，**把已經寫好的 200 覆蓋成
   400 `{"error":"JSON parsing error","details":"key 'priority' not found"}`**。
6. 派送執行緒不知道有例外，照常把 job 送給 proxy，proxy 照常寫進交換機。

**同一個檔案裡兩種取值慣例並存**：`:1969` 是 `e.value("priority", 0)`、
`:2004`/`:2034` 是 `e.at("priority")`。缺的守衛就是這個不一致。

## 實證（live P4 stack，10 台 bmv2）

```
switch 1 table BEFORE                     5 entries
POST /ndt/install_flow_entry
  {"dpid":1,"match":{"eth_type":2048,"ipv4_dst":"10.44.44.44"},
   "actions":[{"type":"OUTPUT","port":1}]}          ← 唯一缺的是 priority
  → HTTP 400 {"details":"[json.exception.out_of_range.403] key 'priority' not found",
              "error":"JSON parsing error"}
switch 1 table AFTER                      6 entries
  ... {'nw_dst': '10.44.44.44', 'dl_type': 2048}    ← 裝上了
```

表是從 **proxy 的 `/stats/flow/1`** 讀的，與 kernel 的回應是獨立通道。

## 邊界（都實測過，不是推論）

| 情形 | 結果 |
|---|---|
| install 缺 `priority`（dpid/match/actions 都合法） | 🔴 **400，但規則裝上了** |
| install 缺 `actions`（priority 有） | 400，且**沒有**裝上（job 進了佇列但 proxy 找不到 OUTPUT，寫入正當地失敗） |
| install 只有 `{"dpid":1}` | 400，沒有裝上（同上，空 match） |
| **delete** 缺 `priority` | ✅ 200 queued，正確刪除 |
| **modify** 缺 `priority` | ✅ 200 queued，正確套用 |

所以危險區只有一格：**install，且缺的正好只有 `priority`**。
其餘缺欄位的情形，寫入會在 proxy 那端自然失敗，結果與 400 一致。

## 可達性

kernel 自己的 `FlowRoutingManager::installAnEntry` 一律帶 priority，所以**內部路徑不會踩到**。
踩得到的是**直接打 HTTP 的外部呼叫者**：`/ndt/install_flow_entry` 的 priority 在
`doc/2026-01-02_ndt_api.md` 是必填，但沒有任何東西強制它——而 delete 的合法 body
本來就不帶 priority（kernel 的 `deleteAnEntry` 預設 -1），所以「install 也可以不帶」
是一個很自然的誤解。

## 修法選項（未動手，等裁決）

1. **`updateOpenFlowTables` 改用 `.value()` 配預設值**，與 `makeInstallJob` 對齊
   （priority 預設 0）。最小、與既有慣例一致；缺點是 400 消失後，
   一個缺 priority 的 body 會安靜地以 priority 0 成功。
2. **把驗證搬到 enqueue 之前**：在 `processFlowBatch` 建 job 時就要求 install entry
   具備 priority/match/actions，缺任一就 400 **且不入佇列**。語意最正確
   （400 = 什麼都沒發生），但會讓目前「缺 actions 也回 400」的行為從
   「寫入失敗」變成「拒絕」，那是行為變更。
3. **兩者都做**：先驗證後入列（2），並讓快取更新用 `.value()`（1）當縱深防禦。

無論選哪個，都要補一條契約檢查釘住「400 之後交換機表沒有變」——
本輪的教訓正是**沒有任何一層在看派送結果**。
