---
name: rejected-requests-can-still-act
description: "A 4xx does not prove nothing happened. NDTwin's install_flow_entry answers 400 and applies the rule anyway — check the far side of every rejection, because nobody audits what a rejected request did"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 46476ec8-b8b8-4584-8a0a-abf1c43432e6
  modified: 2026-08-30T14:10:42.781Z
---

**2026-08-17, live P4 fabric.** `POST /ndt/install_flow_entry` with a body missing only
`priority` answered `400 {"error":"JSON parsing error"}` — and the rule was **installed on
the switch** (table 5 → 6 entries, read back through the proxy, an independent channel).

Mechanism: `makeInstallJob` takes priority with `.value("priority", 0)` so it never throws,
the job is **enqueued and dispatched**, and only afterwards does
`updateOpenFlowTables` (`DeviceConfigurationAndPowerManager.cpp:2004`) do
`e.at("priority")`, throw, and let the outer handler overwrite the already-written 200
with a 400. Two accessor conventions in one file, three lines apart from each other's
sibling at `:1969`.

**Why:** this repo's documented shape is *success reported for work not done*
([[bmv2-unknown-status-vocabulary]], [[replace-vs-add-bug-shape]]). This is the inverse and
it is harder to catch, because **nobody goes looking at what a rejected request did.** The
contract suite was 51/51 green while it happened; the only witness was one kernel log line,
and the queue endpoints assert only that they honestly say "queued" — no layer looks at the
dispatch outcome.

**How to apply:**
- When testing an error path, do not stop at the status code. Read the far side — the
  switch table, the file, the row — and assert it did **not** change. An ERRORPATH check
  that only asserts `400` cannot see this whole class.
- Suspect any handler that builds work with `.value(field, default)` and later re-reads the
  same body with `.at(field)`. The default hides the missing field from validation and the
  `.at` surfaces it after the side effect.
- A green suite sitting next to an error in the log is a finding, not noise. That
  contradiction is what led here. Related: [[live-runs-find-what-tests-cannot]].

Report: `doc/audit/2026-08-17_install-rejected-but-applied.md` (boundaries measured:
delete and modify are clean, install missing other fields fails honestly — the dangerous
case is exactly one). **Unfixed, three options recorded, awaiting Adam.**

---

**2026-08-18 補一個更糟的變體，在 OVS 上。** 上面那條說「唯一的目擊者是一行 kernel log」。
**在 OVS 上連那個目擊者都沒有。**

送一條交換機會拒絕的規則（OpenFlow 1.3 要求 `ipv4_dst` 帶 `eth_type` 前提，我故意不帶）：

```
POST /ndt/install_flow_entry  → 200 {"accepted":1,"status":"queued"}
   t=0..7s   kernel 的 get_switch_openflow_table_entries 顯示 131 條（含這條）
   全程      ovs-ofctl dump-flows s1 = 130 條、Ryu /stats/flow/1 = 130 條
   t=9s      kernel 也回到 130
   kernel log 16,324 行、**0 個 error**；Ryu log 也沒有
```

幽靈的 actions 是 `[{"port":2,"type":"OUTPUT"}]`——**130 條字串裡混一個物件**。
那是它在回傳請求而非回報表格的指紋。

> 🔴 **08-30 更正（T-4 FINDING-03，實測）**：原文寫「**跟我 POST 的 body 一字不差**」，
> **那句是錯的，不要拿去用**。實測比對：`dpid` 被丟掉、key 序也不同 ⇒ **不是 byte-identical**。
> 成立的是**結構同一性**，而且判別力最強的不是 `actions` 的型別，是 **`match` 的字彙**：
> 幽靈用 `eth_type`/`ipv4_dst`（**呼叫端 POST 的用字**），其餘 41 筆用 `dl_type`/`nw_dst`
> （**交換機的用字**）；另外幽靈只有 4 個欄位而別人有 13 個，**`byte_count`／`packet_count`／
> `duration_*`／`cookie`／兩個 timeout 一個都沒有**——真的存在於表裡的列會帶統計。
> ⇒ **拿 byte-diff 去驗會得到「沒命中」並誤判幽靈消失**。要驗就驗上面三項結構特徵。
> 🔑 同族：[[cited-line-numbers-are-not-evidence]]——**當時那句話是憑印象寫的，不是比對出來的**。

**同一條規則在 P4 上會被抓到**：`[error] [Controller.cpp:55] dispatched install failed
for dpid 1 (priority 901) ... {"status":"error","message":"Failed to add route"}`。

機制（讀碼確認）：`Controller.cpp:55` 靠「200 回應的 body 裡有沒有 error」判失敗。
P4 proxy 做同步 P4Runtime 寫入會放；**Ryu 的 `/stats/flowentry/add` 是 fire-and-forget，
在交換機裁決之前就回 200**，所以那個檢查在 OVS 上永遠沒東西可找。

`doc/2026-07-28_test_coverage_gaps.md` §8 待辦 4 **三週前就預測了這件事**並稱它
「最有價值也最容易做」，沒人做。

**發作頻率實測（重要，別當成常態）**：30 分鐘真實負載、177 取樣、期間 37 次寫入
與 5 次電源變動 → **0 次自然發作**。取樣週期 10s 對約 8s 的現象，單次捕捉率約 80%。
所以是「低發作率」不是「零」。**Adam 裁定報告前不修。**

詳見 `doc/audit/2026-08-18_live-full-stack-round/`、[[live-round-2026-08-18-two-passes]]。

---

## 🆕 08-30 第三個載體：**不是 HTTP，是我自己的 shell 指令**

前兩例都是 NDTwin 的端點。這一次的「請求」是**我打的一行 bash**，而它同樣**報了錯卻做了事**。

我用巢狀 heredoc 去 patch 一支腳本，內層的 `PY` 結束標記把外層吃掉了：

```
SyntaxError: unterminated triple-quoted string literal
/bin/bash: eval: line 67: unexpected EOF while looking for matching `''
```

**兩個錯誤、非零退出、看起來像什麼都沒發生。** 實際上 shell 把 heredoc **剩下的內容當成指令執行了**，
其中包含 `( cd p4_proxy && … venv/bin/python proxy_agent/main.py … ) &`
⇒ **主機上多了一個跑了 15 分鐘、佔著 `:8081`、沒有人記帳的 proxy**。
它是在整機輪開跑前的例行 `ndt status` 才被看到的（`:8081 proxy open`、3968 destination paths）。

🔑 **兩個新的點：**
1. **「指令失敗了」不代表「指令沒有副作用」** —— 這條原本只寫給 API，現在對 shell 也成立，
   而 shell 的失敗**更容易被當成什麼都沒發生**（因為它同時印了語法錯誤）。
2. ⚠️ **我第一時間把它歸因給 `test_port_guard.py`（我剛寫的測試），那是錯的。**
   實測那個測試清理乾淨（跑完 `:8081` 零 listener）。真相是從 **PPID** 追出來的——
   父行程的完整命令列就是那條壞掉的 heredoc。
   ⇒ **歸因要看行程譜系，不要看「誰最近碰過這個主題」**
   （與 [[two-writers-one-worktree]] 的「歸屬要看檔案譜系不是 commit」同形）。

**How to apply:** 長跑或會起服務的指令，語法錯誤之後**不要假設它沒跑**——
用記下的 pid 或 `ss -lptn` 確認沒有殘留，尤其在別人要用同一台機器量測之前。

## 🏁 08-30 有流量輪：那個「幽靈」的另一半終於量到了

正本 `doc/audit/2026-08-30_live-traffic-round/`（`68c3209`；raw 在 audit-raw `d1f044e`）。
兩條都是 P4/BMv2、kernel `1208d22`、128 hosts 實測。

**① 🔴 更正（22:10，嚴重度翻轉）：那個窗是「看不見」不是「還沒裝」。**
規則 **~20 ms 就到交換機**（southbound 三次都是 t+0.01~0.02 s），而 kernel 的
**表視圖快取**要 1.31/2.22/10.04 s 才公布它。10.70 s 是
`DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker`（:1890 覆寫、:1900 睡 10 秒）
＝**我那支儀器上游的刷新週期**，不是 dispatch 的性質（`FlowDispatcher::workerLoop_`
是 `cv_.wait`→`sender_`，路徑上沒有時鐘）。幻影＝`HttpSession` 在
`// TODO: Immediately update the table` 把原始請求**同步**寫進同一份快取；
`HttpSession.cpp:622` 服務的就是這份快取。
🔑 `instrument-must-not-mimic-its-own-finding` **又一層**——我量到的週期屬於讀取器。
   給得起的線索我沒用：**幻影瞬間出現、真列按時鐘出現**＝兩條寫入路徑進同一個 store，
   不是佇列在排空。**T-11-A 的設計吃「看不見 vs 沒裝」這個差別。**
🔑 原始碼 `:2001` 早就寫了「visible for ~7s」——那是同一個 [0,10.7] 相位分布的**單次抽樣**，
   跟 T-4 的「2 秒」同型錯誤。我這輪犯了兩次、也抓到兩次。
**保住的**：窗真實存在、上界 ~10.7 s、相位分布、「四條同瞬可見」（同一次 `std::move` 覆寫）。

**① 原始（已更正，保留供對照）＝ 10.70 s 的 cycle（sd 0.05，n=4）。**
決定性觀察：8 條規則間隔 3 秒送出，被 program 的時刻只有 **3 個**（4 條、3 條、1 條），
每一群內部 spread **0 ms**。per-rule 排程做不出這個。
⇒ 窗＝POST 到下一次 tick 的距離：**上界 10.7 s、平均 5.35 s、分布是相位**。
⇒ 負載**不會**讓它變長（contended 與 idle 完全重疊）。
⇒ T-4 FINDING-03 的「t=2 s 已消失」資料全對、讀法要換：那是一次相位抽樣，不是上界。
🔑 我先看到 disappearance 比 POST 規律 10 倍（σ 0.22 vs 2.3）就想喊週期——**那只是 fit**。
   真正定案的是讓兩個假說對「還沒做過的觀察」給出相反預測（不同時間送、會不會一起落地）。

**② `install_flow_entry` 把每一條規則都以 `priority 0` 寫下去**，不管你要求什麼（17/17）。
窗內 kernel 的 table view 回**你要求的** priority，窗後回 0 ⇒ **同一條規則兩種答案**，
早讀晚讀不一樣。priority 正是「specific 蓋過 general」的唯一機制。
POST 的回應本身很誠實：`{"accepted":1,"status":"queued","detail":"…outcomes are reported in
the kernel log, not in this response"}` ⇒ 這不是「謊報安裝成功」，是 queued 真的就是 queued。

🔴 **②差點被我寫成相反的、更聳動的版本**：「安裝的規則永遠不會被 program」。
我的儀器拿 `priority` 當 key，而系統會改寫它 ⇒ 計數結構性釘死在 0、每一輪都「一致」。
救回來的不是測試，是**去問另一邊**：entry 數從 1280 漂到 1285，那五個就是我裝的規則。
⇒ 規則的身分要用**呼叫端自己選、且會存活的欄位**（destination），不要用系統會重寫的欄位。
