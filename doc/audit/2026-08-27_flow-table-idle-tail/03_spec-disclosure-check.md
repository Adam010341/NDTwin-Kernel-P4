# ③ API 文件有沒有揭露「端點會回傳已經結束的流」？

**2026-08-28 執行。** 對應 [`NEXT.md`](NEXT.md) 的第 ③ 項，工單 W。
判定規則在動手之前就寫死了（`NEXT.md:25-30`），這裡照它走。

**方法：讀檔。沒有跑任何東西。** 讀過的檔案逐一列在下面，行號是這次實際讀到的。

---

## 裁決：**沒寫** ⇒ 維持 W 現在的措辭

> **沒寫 ⇒ 端點沒有表達自己的語意 ⇒ 維持 W 現在的措辭（缺陷在沒表達，不在保留本身）**

W（`doc/KNOWN-ISSUES.md` B-x）現在的關鍵句是
「**回傳的紀錄沒有任何欄位表達這件事**」與
「**保留 15 秒可能是刻意的；缺陷在於端點沒有把它表達出來，不在保留本身**」——
**兩句都成立，不必改。**

---

## 證據

### 1. `doc/2026-01-02_ndt_api.md` §4 全文讀過（356–493 行）

規格對這個端點的語意只有一句，在 **358 行**：

> Returns detailed information about all **active** flows observed by the network system (sFLow) …

§4 其餘部分是：ICMP 的 `src_port`/`dst_port` 註記、`src_ip`/`dst_ip` 的位元組序警告、
一份 JSON 範例、三個錯誤碼。**沒有一個字提到 idle timeout、保留、過期、或流的生命週期。**

全檔搜過 `idle|timeout|expire|stale|ended|no longer|removed|retain|TTL`（24 命中），
**沒有一條落在 §4**。24 條全部屬於其他端點：`is_up` 的陳舊規則（193–202）、
OpenFlow 表項自己的 `idle_timeout`/`hard_timeout` 欄位（522–523）、
鎖的 TTL（2216–2322）、manifest 陳舊（759）、`DEC_NW_TTL` 這個動作名稱（2937）。

### 2. `spec.FLOW_RECORD` 全文讀過（`tools/contract_test/spec.py:92-105`）

12 個必要欄位，**沒有 optional**：

```
src_ip  dst_ip  src_port  dst_port  protocol_id
estimated_flow_sending_rate_bps_in_the_last_sec
estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot
estimated_packet_rate_in_the_last_sec
estimated_packet_rate_in_the_proceeding_1sec_timeslot
first_sampled_time  latest_sampled_time  path
```

**沒有任何欄位能表達「這條已經死了」。** `NEXT.md:35` 寫的是「目前已知的欄位裡沒有」，
現在是讀過完整定義之後的結論，不再是「已知的」。

`latest_sampled_time` 是唯一沾得上邊的，但它是一個**時間字串**：
呼叫端要拿它判斷存活，必須先知道 `FLOW_IDLE_TIMEOUT = 15000 ms` 這個常數——
**而那正是文件沒說的東西**。它把判斷推給呼叫端，卻沒給判斷所需的參數。

---

## 三件超出這個二分法、但會影響 W 措辭強度的事

### (a) 🔴 文件不只是「沒說」，而是**說了相反的話**

規格寫的是 **“all active flows”**。實測 92% 已經結束。
所以這不是「規格沉默、實作自由發揮」，是**規格做了一個宣稱，而實作牴觸它**。

⇒ **建議 W 補一句**（措辭不變，強度補足）：

> 規格 §4 稱這個端點回傳 “all **active** flows”（`doc/2026-01-02_ndt_api.md:358`）。
> 缺陷不只是「端點沒有表達保留行為」，而是**文件明說 active、實際包含已結束的流**。

這一句讓 W 從「文件缺一段說明」升級成「文件與行為不一致」，而後者是**可以被引用來反駁 twin 讀數**的等級。

### (b) 🔴 同一個缺陷涵蓋**兩個端點**，W 目前只點名一個

`get_detected_top_k_flow_data` 是同一個母體，**已用原始碼確認、非推論**：

- `HttpSession.cpp:163` → `handleGetDetectedTopKFlowData`
- `HttpSession.cpp:608` → `m_flowLinkUsageCollector->getTopKFlowInfoJson(k)`
- `FlowLinkUsageCollector.cpp:2336` → `getTopKFlowInfoJson` **直接呼叫 `getFlowInfoJson()`**
- `FlowLinkUsageCollector.cpp:2291-2327` → `getFlowInfoJson` 走訪整張 `m_flowInfoTable`，
  **沒有任何存活性過濾**，逐項 push 進結果

而文件 **2395 行**對 top-k 用了字面相同的宣稱：“the Top-K **active** flows”。

⚠️ **不要跟既有的 top-k 工單混為一談**：那一條講的是
`_in_the_proceeding_1sec_timeslot` 沿用舊值（`FLUC:1773-1778`）造成殘影，是**數值**問題。
這裡是**母體**問題——就算速率欄位全部正確歸零，那 92% 的紀錄仍然會被列出來。
**兩者可以各自獨立修好而另一個仍在。**

### (c) ✅ 修法不會破壞契約（這條是好消息）

我原本以為契約測試會擋掉「新增一個存活性欄位」。**查了，不會。**
`tools/contract_test/schema.py:129-138`：`Obj` 的 `strict` **預設 False**，
docstring 明寫「a kernel that *adds* a field is not breaking its consumers」。

⇒ 加一個 `is_active` / `idle_ms` 之類的欄位是**契約相容**的，
不需要先改契約測試。W 的補救成本比看起來低。

---

## 📌 順手撿到、**不列為本次發現**的一條（需要自己的工單與自己的驗證）

`FlowLinkUsageCollector.cpp:2335` 取了 `shared_lock(m_flowInfoTableMutex)`，
**然後在 2336 行呼叫的 `getFlowInfoJson()` 對同一個 mutex 再取一次 `shared_lock`**（`:2293`）。
`m_flowInfoTableMutex` 是 `std::shared_mutex`（`FlowLinkUsageCollector.hpp:387`），
而同一個 mutex 上有 **5 個 writer** 取 `unique_lock`（`:1486 :1822 :2109 :2272 :2924`）。

- **已驗證（讀碼）**：巢狀的 shared 取得、鎖的型別、5 個 writer 的存在。
  依 C++ 標準，對 `std::shared_mutex` 遞迴取 shared 是**未定義行為**。
- **未驗證（推論，不要當結論）**：它會不會真的卡死，**取決於底層 rwlock 的偏好設定**。
  glibc 預設是 `PTHREAD_RWLOCK_PREFER_READER_NP`（reader 優先），
  在那個設定下遞迴 rdlock **不會**卡死。所以**我不宣稱這是一個活的缺陷**。
- **會變成缺陷的條件**：rwlock 種類改成 writer 優先、
  或 libstdc++ 換成 condvar 版的 `shared_mutex` 實作。
  再加上「北向 API 一次只服務一個請求」——**一旦卡住就是整顆 API 卡住**。

**建議獨立成工單，與 W 分開。** 這裡只記錄，不併入 W。

---

[Co-developed with claude code -- Adam]
