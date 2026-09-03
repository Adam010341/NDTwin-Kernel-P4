# 裁決：A-7 交過來的兩條 kernel 側事項

auditor，2026-09-03。請求方＝`開機手冊` session（Adam 09-03 裁「手冊的它改，kernel 的發給 auditor」）。
[Co-developed with claude code -- Adam]

---

## 1. `install/modify/delete_flow_entry` 的成功路徑契約

### 🔴 先更正前提：那個字串在 trunk 上已經不是那樣了

請求裡引的是

> `per-entry outcomes are reported in the kernel log, not in this response`

trunk (`d568a8a4`) 的 `HttpSession.cpp` 實際是

> `… are reported in the kernel log and, since they are not in this response, are readable
> afterwards from GET /ndt/get_flow_dispatch_status`

`636f9abb`（**2026-08-30**，"Add GET /ndt/get_flow_dispatch_status, and stop telling callers the
log is the only record"）就是改它的那個 commit。而該端點回的**不只是計數器**：

```
counters            dispatched / succeeded / failed / dropped_after_stop
recent_failures[]   at_unix_ms · seq · op · dpid · requested_priority · match
                    · controller_status · message      ← 逐筆，帶 match 與控制器回覆
recent_failures_capacity / recent_failures_evicted      ← 自己揭露會被擠掉
counters_cover      includes_boot_time_programming=false, includes_intent_translator=false
dispatcher_running
```

### 而「前提過期的方式」才是真正該記的一條

```
$ git merge-base --is-ancestor 636f9abb main        → no
$ git merge-base --is-ancestor 636f9abb origin/main → no
$ git cat-file -t 936f8c6                           → fatal: Not a valid object name
```

⇒ **修法只在 trunk。手冊叫人 clone 的公開端沒有它。**
⇒ run-03 那六次重現是**對出貨快照的正確觀測**，不是對 trunk 的。
⇒ 🔴 **A-7 #1 不可以記成「kernel 未修」**，要記成「已修於 `636f9abb`，公開端未帶」。
兩者對「下一個 campaign 會不會再撞到」的預測相反。

（`936f8c6` 在本 repo 裡不是一個 object，我無法查證它的內容。凡是關於那顆快照的斷言，
出自我這裡的一律標「未查證」。）

### 裁決

**接下這條，但範圍改小。** trunk 上真正還缺的是三件，不是「只能讀 log」：

| # | 缺口 | 後果 |
|---|---|---|
| a | **沒有關聯把手**：install 的回應不帶 `seq`／batch id，而 `recent_failures` 有 `seq` | 兩個 app 同時寫的時候，呼叫端**分不出哪幾筆失敗是自己的** |
| b | **成功只有總數**：`succeeded` 是計數器 | 「我那 12 筆進去了沒」＝前後相減，而相減會被別的寫者污染 |
| c | `recent_failures` 有界會擠掉舊的 | 慢的呼叫端會**遺失自己的**失敗紀錄（端點有誠實公布 `recent_failures_evicted`） |

**現在只做 (a)**：讓 install 的回應帶上它佔用的 `seq` 區間。理由——
- 純附加，不動 `status`／`accepted`；repo 內兩個消費者都**丟棄** response body（08-30 已盤點）。
- (b) 的自然做法是 completion handle，碼裡自己的註解就說那是**架構決定不是措辭問題**；
  現在有七支未合併的分支在等，量測窗口裡不動架構。

### 🔴 但 A-4e 那一半，回應契約修不了

`modify_flow_entry` 是「一筆 entry 改掉 N 條既有規則」。OpenFlow 的 `OFPFC_MODIFY`
**不回報影響筆數** ⇒ kernel 不做**回讀**就無從得知 N，再完美的 per-entry 通道也報不出來。

這與今晚第一輪的 finding #1 是**同一族**：
`/ndt/delete_group_entry` 回 `200 {"outcome":"deleted"}` 而 group 還在交換機上
（`round1-ovs/21_*.log`，已登記為 `KNOWN-ISSUES` A-10）。

⇒ **合成一條工作項，不要兩條**：**寫入 → 回讀 → 斷言差異**，而不是「API 說成功」。
閘門要能同時紅在 delete_group_entry 與 modify_flow_entry 上。

---

## 2. `fix/ndt-sudo-surface`

**接受，而且排在下一個。** 補三點：

1. **不需要實驗室** ⇒ 不會撞到 Adam 的 12:20 之後的使用。驗收條件（沒權限問必須回 **2** 不准回 1）
   用 PATH shim 把 `sudo` 換成回 1 的假貨就能測，不必動真的 sudoers。
2. **與今早的 `fix/ports-that-block-restart` 同型，建議一起做**：那支留下的未竟事項之一是
   `ndt_port_open` 回 **2**（機器上沒有 `ss`）被當成 not-clean，而**那條路徑本機走不到**。
   兩者都是「**分不出『答案是否』與『我問不到』**」——同一個修法形狀，同一把閘門形狀。
3. 下一個 campaign 的 VM 拿掉全域免密碼 sudo ⇒ 它會自己跳出來。**這正是它該先修的理由**：
   它今天看不見是因為儀器遮住它（`test-environment-masks-the-defect`），
   而遮蔽物正要被移除。

---

## 3. 一個給新 campaign 的預警（不是要你做，是免得判準被誤讀）

公開快照凍結、且**不設更新觸發條件**（Adam 09-03 裁）＝ 每一輪 tester 都會再撞到
**已經在 trunk 修好**的東西。判準若寫「零干預」，這類命中會被計成失敗，
而它們**不是 agent 裝不起來，是它裝的那份沒有修法**。

⇒ 建議判準分兩欄：**「在被測 ref 上是缺陷」與「在 trunk 上已修」**。
否則新 campaign 量到的會是快照與 trunk 的距離，而不是手冊的品質。
