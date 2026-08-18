# 三模型提問輪：讓不認識實作的人來問，然後照原始輸出回答

**2026-08-18。**三個模型各自扮演「必須決定要不要相信這個孿生」的操作者，**盲寫**問題清單，
每題必須事先登記「什麼答案會讓你擔心」；我逐題對活的 P4／4 台 stack 執行並貼原始輸出。

**一句話**：**兩個真缺陷**（佇列式寫入的失敗對 API 完全不可見；任何人可以解任何人的鎖），
一個**被推翻的推論**（stale probe 不會讓死掉的交換機永遠報 Up），
其餘是**一致性通過**——而我自己在讀結果時錯了三次，三次都被「重讀機制」救回來。

[Co-developed with claude code -- Adam]

---

## §1 方法，以及它防的是什麼

| 角色 | 誰 | 看得到什麼 |
|---|---|---|
| 提問者 A | **DeepSeek v4 pro**（`-e max`，無工具）| API 文件 ＋ 拓撲 JSON，內嵌在 prompt 裡 |
| 提問者 B | **Gemini 3.7 flash**（effort high＝上限）| 同上，透過 `add_dir` |
| 提問者 C | **Muse Spark 1.2 contributor** | 同上，內嵌 |
| 執行者／被測的盲點 | 我 | 全部 |

**刻意不給**：`src/`、`tests/`、`doc/audit/`、測試說明書。理由是**實作知識正是製造盲點的東西**——
讀過它的提問者會繼承我的假設，變成一個比較慢的我。用工具的目錄根強制，不是在 prompt 裡拜託。

**規則：每題必須事先寫下 `FINE IF` 和 `WORRYING IF`。**沒有預先登記擔心答案的問題就是撈魚，
而且這條規則讓我**不能事後說「這是預期的」**——他們已經先定義了預期。

### ⚠️ 這個設計有一個我沒防到的漏洞

**主題分類是我做的。**三個模型盲寫，但「哪幾題算同一題」是我事後判斷的——
**我防了裁判那一步（規定自己貼原始輸出），沒防合併那一步。**

Adam 當場問「主題是誰定的」，重算之後：**我原本宣稱「四個主題三個模型收斂」，
真正措辭近乎相同的只有一個**（下方 A）。而且我犯了具體的計票錯誤：
Muse 的 Q2 被我同時算進兩欄。**往後逐題貼原文並列，不用我的標籤計票。**

---

## §2 兩個真缺陷

### 2a. 🔴 佇列式寫入的失敗，對 API 完全不可見 —— 三個模型近乎逐字問了同一題

| | 問題 |
|---|---|
| **[D]** Q4 | queued 之後，規則到底有沒有出現在交換機表裡 |
| **[G]** Q1 | 之後被控制器拒絕時，有沒有**任何 API 看得到**的錯誤或狀態變化 |
| **[M]** Q3 | 「200 queued」是不是在說謊 |

Gemini 的 WORRYING IF：*API 回 200 queued、規則從沒出現在交換機上、**而且沒有任何 API client
偵測得到**這個改變被默默丟掉了——然後就去執行依賴它的動作，像是關掉交換機。*

**三個條件全部成立：**

```
POST /ndt/install_flow_entry
  {"dpid":1,"priority":500,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.99"},
   "actions":[{"type":"OUTPUT","port":999}]}
→ HTTP 200 {"accepted":1,"status":"queued"}

GET /ndt/get_switch_openflow_table_entries
→ NOT PRESENT: no rule matching 10.0.0.99 or priority 500 on dpid 1

kernel.log
→ [error] dispatched install failed for dpid 1 (priority 500): HTTP 200 --
          P4 proxy agent reported an error in a 200 response:
          {"status":"error","message":"Failed to add route"}
```

**已列入「已知未完成」**（`2026-08-18_pre-report-claim-verification.md` §5）。這一輪把它從
「我注意到的缺口」升級成**三個沒看過我任何文件的模型事先預測、然後被實測證實**。

Gemini 的收尾更直白——如果只能看一眼，它要看的是「**kernel 內部派送 log 與交換機真實表格並排**」。

### 2b. 🔴 任何呼叫者可以解任何呼叫者的鎖 —— [G-Q2]＋[M-Q5]

```
A: POST /ndt/acquire_lock {"type":"routing_lock","ttl":120}  → 200 {"status":"locked"}
B: POST /ndt/release_lock {"type":"routing_lock"}            → 200 {"status":"released"}
B: POST /ndt/acquire_lock {"type":"routing_lock","ttl":120}  → 200 {"status":"locked"}
```

**B 釋放了它從未持有的鎖，然後拿走了它。**沒有 owner token，`release_lock` 只看鎖存不存在
（不存在回 412），不看誰持有。七個元件共用這組鎖，其中一個的清理流程可以在另一個操作到一半時
無聲地把它的 routing lock 抽掉。

⚠️ 順帶（文件自己記載的）：`acquire_lock` 的 **423 同時代表「系統忙」和「無效的鎖型別」**，
不區分——我第一次用錯型別（`routing` 而非 `routing_lock`）就吃到這個歧義。

---

## §3 一個被實測推翻的推論（本輪最有價值的否定結果）

**[M-Q1]＋[G-Q3]：P4 的 stale probe 會不會讓凍住的交換機永遠報 Up？**

兩個模型都**正確讀出了文件寫的政策**——「`probe_ok == true` 就算 Up，不看 `probe_age_s`」——
然後推論 poller 卡住會把它釘在 Up。

SIGSTOP 一台 bmv2（注入有斷言：`/proc State: T (stopped)` 全程）：

```
t+3s    probe_ok=True   age=3.186s   'answered GetForwardingPipelineConfig'  → is_up True
t+10s   probe_ok=False  DEADLINE_EXCEEDED                                    → is_up False, edges 32/40
t+20s   probe_ok=False  DEADLINE_EXCEEDED                                    → 同上
t+35s   同上 ／ t+50s   同上
```

**`probe_ok` 不可能變成「舊的 true」**：探測本身帶 deadline，凍住的交換機給 `DEADLINE_EXCEEDED`
→ `probe_ok=False`。**他們擔心的狀態到達不了。**

**最鋒利的細節**：`stream_alive` 在整個凍結期間**一直是 `True``。會騙人的訊號確實存在——
而判定**正確地沒有用它**。

👉 **不完整的是文件，不是碼**：API 文件描述了政策卻沒提探測有 deadline，
於是任何只讀文件的人都會推出同一個錯誤結論。

---

## §4 一致性通過的

| 主題 | 誰問的 | 結果 |
|---|---|---|
| **斷鏈通知會不會傳播、兩個方向都下？** | [D-Q2][G-Q4][M-Q2] | ✅ **兩個方向都下**（`1:1->5:1` 與 `5:1->1:1` 同時 `is_up=False`，`edges_up 38/40`），recovery 後回復 |
| **關機後三個 liveness 視圖同不同意？** | [D-Q3][G-Q3][M-Q1] | ✅ 2 秒內三個同時翻：graph `is_up=False`、`power_state=OFF`、proxy `probe_ok=False` |
| **交換機聚合值 vs 各邊加總** | [D-Q7,Q8][G-Q8] | ✅ **byte 精確**，dpid 1/5/9 三台皆然（422137856 / 428744704 / 437886976，與各自入邊總和完全相等；`num_of_flows` 也吻合）|
| **flow 每一跳是不是活著的邊** | [D-Q5][M-Q4] | ✅ 8/8 hop 全部對得上活邊 |
| **流量停掉後 flow 會不會過期** | [D-Q10][G-Q6] | ✅ 0 flows、0 條非零邊使用率。⚠️ **但我量得太晚**，沒抓到轉換時刻，所以「多久消失」沒有數字 |
| **`get_average_link_usage` 的分母** | [D-Q9][G-Q5] | ✅ 非缺陷。`0.358402048 × 100 = 35.840205` ＝**只算非零邊**的平均，**文件 §24 兩件事都寫了**（分母與 0–1 單位）。而它們擔心的能源 App **從來沒呼叫過這個端點**（零呼叫點）|
| **批次部分丟棄看不看得出來** | [M-Q6][G-Q10] | 🟡 見下 |

### §4a. 批次部分丟棄：API 做對了，消費端沒讀

```
POST .../install_flow_entries_modify_flow_entries_and_delete_flow_entries
  （一台真交換機 ＋ 一台虛構的 dpid 424242）
→ HTTP 200
  {"accepted":1,"rejected":1,"rejected_dpids":[424242],
   "detail":"some entries were dropped because their dpid is not a switch in the loaded topology..."}
```

**只看狀態碼會漏掉**（Muse 預測正確），但 body 講得非常清楚，而且 API 文件明寫
「a client that reads only the status code will see 200 and miss the partial acceptance
entirely. Check for the keys.」

**真正的殘留在消費端**：`processFlowBatch` 的註解記載，兩個會寫 flow 的應用
（Energy-Saving-App `:225`/`:241`、TE-App `:572`）**都完全丟棄回應**。
所以對實際的使用者而言，部分丟棄**確實是不可見的**——不是因為 API 沒說，是因為沒人在聽。

### §4b. 關機後的合成遙測：三個姊妹端點三種說法（已知 P2，仍未修）

| 端點 | 它怎麼表達「這台 down 了」|
|---|---|
| `get_cpu_utilization` | **整個 key 消失** |
| `get_memory_utilization` | **整個 key 消失** |
| `get_temperature` | **key 留著，值的型別從 `int` 變字串** `"The switch is down."` |

08-12 那輪已記為 P2，仍未修。Gemini 的 FINE IF 三種都接受，
所以按登記算 FINE——但**姊妹端點彼此不一致**沒有人問到。

---

## §5 我在讀結果時錯了三次

**這一節是本文件最該被讀的部分。**三次都不是系統的問題，是我的。

**① 斷鏈：第一次量到「40/40 沒變」，結論「通知被忽略」。**
錯。鏈路實際上是好的（我只是「通知」了故障），拓撲輪詢在我讀之前就正確地把它改回來了。
**立刻重讀**（不 sleep）得到 `is_up=False`、`edges_up 38/40`——完全相反。
救我的是不接受一個「算式吻合但沒讀機制」的結論。

**② flow 路徑：第一次算出 8/8 hop「不是邊」。**
**全滅的形狀通常是我讀錯 schema，不是系統壞了。**path 裡的 `interface` 是該節點**自己的出口**，
不是入口——真實邊 `3:2 -> 8:1`，而 path 寫 `{3, if 2}` 然後 `{8, if 3}`（8 自己的出口）。
改成不比對目的介面之後：**8/8 全對**。

**③ power off/on 的第一次實測無效。**
manifest 的 `pid` 是 `None`（我先前手動重啟留下的），所以 OFF 是**空的 Success**、
ON 又因為 port 被占著。清乾淨（`kill` → 斷言 port free → pid 仍為 None）才是真的測試。

**還有兩次工具面的**：`kill` 之後無條件印「killed」（root 擁有的 process，我的 kill 是無聲 no-op，
正解是 `sudo -n mnexec -a 1 kill`）；mutation gate 的 `tail | head` 把 `FAILED` 那行截掉，
輸出看起來像兩個 mutant 都通過——**今天第二次踩同一形狀**（第一次是 C++ mutant 沒編過、
我拿舊 binary 當結果）。

---

## §6 順帶找到、已修的：override 之下 P4 開機是壞的

不是提問清單問出來的，是**執行 Theme C 時撞到的**：

```
POST /ndt/set_switches_power_state?ip=192.168.123.15&action=on
→ HTTP 500 {"error":"Failed to change switch power state"}
ndtwin-p4-power: manifest argv for 's5' does not start with simple_switch_grpc
                 (['LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib']); refusing to execute it
```

`bmv2_binary_override` 讓拓撲以 `LD_LIBRARY_PATH=... <binary>` 啟動，manifest 記下整串，
而 helper 驗 `basename(argv[0])`。**關機可以、開機不行**，而**能源節費 App 的整個功能就是關掉再開回來**
——在 override 之下它只能把 fabric 一台一台關掉而且回不來。

原本這是**刻意的**（`bmv2_launch_head` 的 docstring 寫著「大聲的拒絕勝過沒人注意的混函式庫交換機」）。
**兩邊都對，但漏了第三個選項**：讓 helper 自己從它已經驗過的 binary 路徑推導 lib 目錄
（`dirname(binary)/../lib`，與 `resolve_bmv2_launcher` 同一條規則）。

修於 `68cbeb3`，實測驗證到底：

```
cmdline                : /usr/local/bmv2-fast/bin/simple_switch_grpc -i 1@s5-eth1 ...
child LD_LIBRARY_PATH  : /usr/local/bmv2-fast/lib
mapped libraries       : /usr/local/bmv2-fast/lib/libbmpi.so.0.0.0  (fast，不是 stock)
```

⚠️ **我在這裡的第一個安全反對意見是錯的**，值得記下來：我說「往 root exec 注入
`LD_LIBRARY_PATH` 是教科書提權向量」，但讀完 `load_manifest` 之後——安全邊界是
**「manifest 必須 root 所有、group/other 不可寫」**，而 basename 檢查只驗檔名
（`/anywhere/simple_switch_grpc` 一樣過），**manifest 本來就在決定那個 root exec 跑哪個 binary**。
能注入 lib 路徑的人本來就能選 binary。**我套了通則沒讀這支 helper 的實際模型。**
（最後仍選「推導」而非「讀 manifest 欄位」，但理由換成**兩邊不漂移**，不是安全。）

---

## §7 還沒跑的

- **[M-Q10]** 兩種 IP 編碼（整數 network byte order vs 點分字串）會不會對不上
- **[M-Q9]** `is_enabled = isEnabled && !adminDisabled` 這個折疊不變式實際成不成立
- **[M-Q8]** P4 上 group/meter 是誠實回 501 還是假裝自己是 OVS
- **[D-Q12]** top-k 是不是真的照宣稱的欄位降冪排序
- **[D-Q1]** `get_static_topology_json` 與 `get_graph_data` 的節點／邊集合一不一致
- **[D-Q11]** `get_path_switch_count` 與實際觀察到的路徑跳數一不一致

## §8 原始材料

`scratchpad/q-deepseek-clean.md`（12 題）、`q-muse.md`（10 題）、agy 輸出（10 題）、
`q-deepseek.md`（11 題，**已汙染**——`deepseek_agent_task` 的 `repo` 參數不是沙箱，
它自己寫道「The /tmp path from the task is inaccessible from this sandbox, so I'll use the
accessible copies inside /home/adam/Desktop/NDTwin-Kernel」，然後讀了真 repo 與兩份 handoff。
**保留當第四份參考，不計入收斂**。Gemini 沒有這個問題：它引用的每個名字都在 staged 文件裡）。
