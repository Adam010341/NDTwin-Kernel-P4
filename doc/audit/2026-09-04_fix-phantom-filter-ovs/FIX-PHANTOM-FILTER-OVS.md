# FIX：B-1 的幽靈規則過濾器補上 OVS 寫入路徑（KNOWN-ISSUES C-4）

- **分支**：`fix/phantom-filter-covers-ovs`（base：`trunk` @ `7de4ef2f`）
- **對應**：夜巡第一輪 FINDINGS-ALL 第 2 列；`doc/KNOWN-ISSUES.md` §C-4；§B-1 的 2026-09-02 覆核第 1 條
- **證據**：`doc/audit/2026-09-03_night-rounds/round1-ovs/22_x5_b1_phantom_window_ovs.log`

[Co-developed with claude code -- Adam]

---

## 一、缺陷是什麼

09-03 在 `ovs4` 上實測：`POST /ndt/install_flow_entry` 之後，
`get_switch_openflow_table_entries` 在 **t=0.257 s** 就送出一列——形狀是**呼叫端自己的
`ipv4_dst` 詞彙、沒有計數器、帶著請求的 priority**——並持續約 1.0 s；真正輪詢回來的列
**t=13.4 s** 才到。同一份配方在 P4 上是 `first_sighting=never`。

那份 log 自己附的**陽性對照**決定了修法的形狀：**合法的 port-2 規則有同樣的幽靈**
（t=0.255 s）。所以被送出去的那一列是**快取列本身**，它答錯的問題不是「這條規則合不合法」，
而是「**有沒有任何東西在交換機上看見過它**」。探測解析度 0.25 s 對上約 1.0 s 的窗，
「探測太慢」被排除。

---

## 二、為什麼 T-11 的過濾器擋不住它

過濾器擋的判準是 `DispatchOutcomeLog::isProgrammed(token)`，而 token 是
`DispatchOutcomeLog::record()` 在 **`OpResult::ok` 為真時**蓋上的。
`ok` 由 `HttpRoutingStrategyBase::post()` 決定，它的最後一道閘的註解**逐字寫著整個缺陷**：

```
// Some proxies answer 200 with {"status":"error"} in the body. Ryu does not, but the P4
// proxy agent does, so a 2xx alone is not proof of success.
```

- **P4**：proxy 先把表寫進去才回答，逐筆失敗會放 `{"status":"error"}` 進 200 的 body
  ⇒ 它的成功**是一次裁決**。
- **OVS**：Ryu 的 `/stats/flowentry/add` 組完 `OFPFlowMod` 就回 200，而 **OpenFlow 的
  FLOW_MOD 本來就沒有 ack**（除非另外送 barrier）⇒ 那個 200 在任何交換機裁決之前就發出了。

**同一段碼、同一個狀態碼，在兩個平面上是兩件不同的事**，而過濾器把兩者都當成觀測。

🔑 **這一條的形狀值得單獨記住**：修法沒有錯，接線沒有錯，過濾器與 token 都是共用的。
**沒有被共用的是「確認訊號本身是不是真的」。** 一個修法在它被驗證的那個平面成立，
不表示在另一個平面成立——而原本的驗證（08-31 只在 P4 上跑）在結構上不可能發現這件事。

---

## 三、修法

契約：**被下發但尚未被觀測到的列，永遠不會被當成「已觀測」的列服務出去。**
「已觀測」是**控制平面回答的性質**，不是時間的性質——所以這裡沒有延後寫快取，
也沒有把輪詢調密。

改動共七處，主線是一個 bool 從「誰有資格宣稱」流到「誰有資格蓋章」：

| # | 檔案 | 改了什麼 |
|---|---|---|
| 1 | `include/ndt_core/routing_management/OpResult.hpp` | 新增 `confirmsProgramming`（預設 **false**）與 `withProgrammingConfirmed()`。`ok` 回答「對方收下了嗎」，這個欄位回答「這個回答算不算交換機已經裝好的證據」 |
| 2 | `include/ndt_core/routing_management/IRoutingStrategy.hpp` | 新增純虛擬 `successConfirmsProgramming()`。**純虛擬是刻意的**：未來多一個平面時，它必須自己回答，而不是繼承一個猜測 |
| 3 | `OpenFlowRoutingStrategy.hpp` | `false`——Ryu 的 200 不是裁決 |
| 4 | `P4RoutingStrategy.hpp` | `true`——proxy 的 200 是裁決 |
| 5 | `HttpRoutingStrategyBase.cpp::post()` | 成功回傳時把平面的宣稱掛上去，**唯一一行**把兩個平面的差別帶下去 |
| 6 | `DispatchOutcomeLog::record()` | 只有 `result.confirmsProgramming` 才 `noteProgrammed_`。**計數器一個都沒動**：被扣住不等於失敗 |
| 7 | `Controller.cpp` sender ＋ `DeviceConfigurationAndPowerManager::getOpenFlowTables()` | 兩條 log：下發端說**為什麼**、讀取端說**正在扣住幾列** |

### 為什麼預設是 false

一個「沒有說任何關於編程的事」的回答不可以被讀成「確認了」。
保守方向的代價是**一列真的規則被扣到下一次輪詢**（可恢復）；
樂觀方向的代價是**幽靈**（正是這張票存在的理由）。
這與 `PendingEntryFilter` 自己的預設（predicate 為空時扣住每一列）同向。

### 兩條 log

- **下發端**（`Controller.cpp`，**每批一行、不是每筆一行**——一批是 2000 筆）：
  說明這批裡有幾筆被接受但那個接受不構成證據，以及它們會被扣到輪詢看見為止。
- **讀取端**（`getOpenFlowTables()`，**邊緣觸發**）：說明視圖正在扣住幾列、原因是
  「dispatched but not observed」。
  這同時補上 §B-1 覆核第 3 條：`stripUnprogrammedEntries` 的回傳值
  （docstring 明寫「so a caller can log or assert on it」）**過去被丟掉**，
  所以「視圖正在扣住東西」從外面完全看不出來。

---

## 四、刻意沒有改的

1. **P4 的行為一個位元都沒動。** 這是 OVS-only 的修法，而測試裡有兩顆專門守它的對照
   （`AConfirmedP4InstallIsStillServedImmediately`、`AProxySuccessStillConfirmsTheEntry`）。
   閘門的變異 2 就是「讓 P4 也不確認」——那看起來很安全（永遠不會有幽靈），
   實際上是把一個沒有缺陷的平面上的真列扣掉一整個輪詢週期。
2. **沒有送 OpenFlow barrier。** 那才是 OVS 上真正的「觀測」，但 Ryu 的 REST 沒有 barrier 路由，
   要做得改 southbound 協定與跨 repo 的 proxy——而且**它是另一個問題的修法**：
   本修法要的是「不要把不是觀測的東西當成觀測」，不是「去弄一個觀測出來」。**留給 Adam 裁。**
3. **快取裡被拒的列仍然留著**（§B-1 覆核第 2 條）。`updateOpenFlowTables` 的 `modifyOne`／
   `deleteOne` 仍然直接走原始陣列、不看 token，所以那 ~10.7 秒內進來的 modify／delete
   仍可能命中一條從未被編程的列。**本修法只動視圖與確認訊號，沒有動狀態。** 嚴重度仍未量。
4. **`ndt` 與 OVS 那條「接受了 OUTPUT:999」的真規則**（夜巡第 9 列）沒有碰。
   那是資料面接受了一條指向不存在的 port 的規則，與本條是不同的危害，證據檔裡也是分開記的。
5. **A-7 的 `/ndt/get_flow_dispatch_status` 沒有加欄位。** 加一個 key 對嚴格的 client 是契約破壞
   （`OpResult` 自己的註解就這麼寫），而且沒有消費端今天需要它。
   閘門的變異 7 守住反向：**扣住不可以被記成失敗**，否則一座健康的 OVS fabric 會被報成
   滿是被拒規則的 fabric——把一種假警報換成另一種。

---

## 五、紅→綠

測試檔 `tests/test_PhantomFilterCoversOvs.cpp`（12 顆）。

🔑 **裡面沒有一顆斷言碰到新欄位的名字**。每一顆斷言的都是**後果**——確認索引怎麼回答、
端點讀的那份快取裝了什麼、kernel.log 說了什麼——沒有一顆斷言機制。
這不是風格問題：**這是它能夠對著未修的 trunk 編譯並看到紅色的唯一寫法**。
照新拼字寫的測試只會編不過，而編不過不是紅色，是沒有證據。
附帶好處是修法日後換一種寫法時，判它的測試不必跟著重寫。

四顆是**對照**、不是被修的東西：P4 確認過的列仍立即服務、P4 被拒的列仍被扣住、
輪詢回來的列兩個平面都不扣、A-7 的計數器意義不變。
沒有這四顆，「讓 OVS 遵守契約」可以靠「什麼都扣住」達成——那是穿著修法外衣的中斷。

（gtest 逐字紅／綠與數量：見本輪 raw。）

### 另一層：不需要整包連結的紅→綠

`raw/00_header_level_red_green.log`。同一份 source，只用 include 路徑切換 trunk 的標頭與修過的標頭：

| | trunk | 修法後 |
|---|---|---|
| Ryu 接受的那筆 `isProgrammed` | **1**（錯） | **0** |
| P4 編程確認的那筆 | 1 | 1 |
| P4 被拒的那筆 | 0 | 0 |
| 未帶 token（輪詢來的） | 1 | 1 |
| 過濾器扣住幾列 | **0** | **1** |
| 服務出去幾列 | **3**（含幽靈） | 2 |

trunk 那一欄服務出去的第一列就是 FINDING-03 的指紋：`ipv4_dst` 詞彙、沒有計數器。

## 六、變異閘

`tests/shell/mutate_phantom_filter_covers_ovs.sh`：11 個致命變異（每個指名唯一該紅的那顆）
＋ 4 個保行為的放寬（必須維持綠）。過濾器含既有的 B-1 兩套
（`PendingEntryFilterTest`／`ProgrammedTokenTest`）——**這次要證的有一半是 P4 沒有動**。

（逐項結果：見本輪 raw。）

## 七、Live

（見本輪 raw。）

## 八、附記：兩件順手發現、沒有一起修的事

1. **既有測試把這個缺陷釘成了預期行為。** `tests/test_PendingEntryFilter.cpp` 有一顆綠的
   `OnlyASouthboundSuccessConfirmsAToken`，用 `OpResult::success()` 斷言 token 被蓋上。
   那句話在 P4 上為真、在 OVS 上為假，所以這套測試**把 B-1 的 OVS 那一半釘住了**，
   而 08-31 的驗收只在 P4 上跑、結構上看不到。已改名為
   `OnlyAnAdjudicatingSouthboundSuccessConfirmsAToken` 並補上第三筆（接受但未裁決）。
   **與 B-2 的 `RenewingAnExpiredLockPutsItBackInForce` 同型，這是第二例。**
2. **`ndt` 的預檢查的不是它接著啟動的那一個。** `ndt:830` 檢查
   `$REPO/build/bin/ndtwin_kernel`（主 checkout），而 `stack.sh:908` 啟動的是
   `$KERNEL_DIR/build/bin/ndtwin_kernel`，`KERNEL_DIR` 可由環境覆寫（`components.env:16` 用 `:=`）。
   兩者預設相同、被覆寫時不同 ⇒ **預檢查會對一個不會被執行的檔案回綠。**
   本輪的 live arm 正是靠這個覆寫跑自己的 binary 的。**沒有修**（不在本工單範圍），
   但值得單獨開一條。
