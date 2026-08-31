---
name: sflow-truncate-merge-status
description: 教授關切的「封包 truncate＋merge」真相：🔑 08-25 工單 D 已跑完並通過驗收＝P4 extern truncate 真的生效（位元組 5.6×）但牆完全沒動、λ 平台反而 2550→2100 ⇒ per-byte 否證、成本是 per-sample；🔑 08-26 工單 E：merge 已接線並過閘門（datagram ↓6.86×）但**在 1/8 無法判定**（噪聲 7.5 > 效果 4.4）；🔑🔑 **08-26 03:16 工單 F 在 1/16 重測＝成功分離：proxy CPU −13.4%、kernel −16.4%，三對三零重疊**（`d39eca1`）⇒ **merge 確實省成本，但「天花板上移多少」仍不得宣稱**；switch 側 knob 08-20＝無聲全滅
metadata: 
  node_type: memory
  type: project
  originSessionId: eafec5bf-e5ef-4c82-8845-f24921cbe297
  modified: 2026-08-27T03:19:12.680Z
---

（2026-08-25 查清：mainDev 讀碼＋審查逐行複驗＋審查補上 08-20 量測史）**沒有「提案→取消」的
紀錄——truncate 有三條路狀態各異、merge 是有意識的單發**。程式碼都在
`p4_proxy/proxy_agent/sflow_emitter.py`（07-28/29 落地 `c3a1317`/`9a46b4b`/`02245e0`）。

## truncate 的三條路
1. **emitter（應用層）＝做了、一直開著**：`:88 DEFAULT_MAX_HEADER_BYTES=128`、`:174
   frame[:max_header_bytes]`，無旗標無覆寫。只省 collector 頻寬；bmv2 CPU 與 gRPC 的成本在
   它之前已付。
2. 🔴 **switch 側 runtime knob＝08-20 實測過、是災難**（mainDev 的信漏了這條——它只 grep 了
   .p4 的 extern）：clone session `packet_length_bytes=128` ⇒ **全部邊讀 0、無聲、無錯誤**
   （session 顯示已裝、endpoint 都答、rate 全 0；CPU 特徵＝樣本根本沒送抵 CPU port）。
   `doc/audit/2026-08-20_sampling-rate-and-cpu/REPORT.md` §「not an optimisation, it is an
   outage」；`p4_client.py:347`「emitter truncates instead」自此從偏好變**量測過的必要條件**。
3. ✅ **P4 `truncate()` extern＝08-25 工單 D 已試（見文末）**，結論是「有效但沒用」。以下是
   開跑前的狀態，保留以供對照：全部 .p4 零呼叫（雙方各 grep 一次）；與 knob 是
   不同機制、在 pipeline 內截，行為未知；本版 bmv2 可用性未驗（tutorials 可當對照＝
   [[p4lang-tutorials-as-local-control]]）。

## merge＝[[existence-is-not-wiring]] 又一例（有意識的，不是忘記）
`build_datagram(samples: list)`（`:220`）原生支援 N 個；`p4_proxy/tests/test_sflow_emitter.py`
`MultiSampleTest`（~:271）三-sample 測試在跑（審查親驗）；docstring `:227` 明寫「OVS 會合批省
syscall、kernel 兩種都吃」；唯一 production 呼叫者 `emit()`（def `:302`）傳 `[sample]`。
接上≈emit() 一行＋小緩衝（mainDev 估）。

## 開銷的既有實測（答教授用）
1/64 取樣的成本：**kernel 57＋proxy 20 個百分點（單核）**，bmv2 跨 1/256→1/64 平坦
（149-158%，率間內部對照、不依賴控制組）；⚠️「sFlow 不是 bmv2 比 OVS 慢的原因」headline 的
no-clone 控制組**已撤回**（[[ab-control-deleted-nothing]]——引用要並陳冷啟零點）。機器 14 核、
10 bmv2 idle 合計 2.2% 單核。

## Adam 指令（08-25）＋未決
就算不重要也要**做一個成功版本→跑實驗→再向教授解釋為何不採用**。✅ 三題已裁（08-25 表單，
皆取建議項）：(1) 標的＝就是這兩個；(2) 範圍＝**P4 extern 實驗（先 tutorials 驗可用性）＋
merge 接線**；(3) 排程＝環修法告一段落後開工→**🔁 08-25 二次裁決改為「修法 B 做完後」**（Adam 選「B 現在做完」）、P2 工單順位不變、8/27 deck 有結果就放、
沒有 9/03 口頭補。deck 素材頁已入 `v5-draft-2026-08-25.md` §C。

**Why:** 教授點名；9/03 素材；「量測過的否決」勝過「論證出的否決」——truncate 的 knob 路
其實已經有一份完整的量測否決在手。
**How to apply:** extern 實驗開工前先在 tutorials bmv2 驗可用性＋期望「掉樣本 vs 短樣本」
兩種結果都寫進預註冊；merge 對照記得 [[bmv2-scale-ceiling-and-sflow-sample-math]] 的取樣數學；
switch-knob 史料引用 REPORT 原文行號。

## 🔑 08-25 夜：truncate/merge 從「解釋為什麼不做」升級成**解開天花板的鑰匙**
取樣率階梯的牆**已由既有 raw 指認**（`r0NN_poll_cpu.jsonl.gz` 的 `proc` 欄，無新量測）：
| cell | bmv2×10 | **proxy** | kernel | lost% |
|---|---|---|---|---|
| 1/32 | 160.0 | **40.8** | 79.3 | 0.03 |
| 1/16 | 170.3 | **70.4** | 101.9 | 0.03 |
| 1/8 | 207.6 | **143.1** | 149.0 | **5.1** |
| 1/4 | 155.7 | **147.7** | 156.2 | **45.3** |
| 1/1 | 104.1 | **141.0** | 157.5 | **85.2** |
**proxy 在 ~145% 平掉、掉包同時開始；bmv2 爬到 208 後往下掉＝被餓死不是瓶頸**；
全機最忙僅 4.4/14 核。⇒ **修 bmv2 是修錯地方**；該修的是 proxy 接收路徑，
而 truncate（clone 128 B 而非 1442 B，~11× 減量）與 merge（省 syscall）正是兩把刀
——🔴 **其中 truncate 那把已於當晚被自己的實驗折斷，見下節。**
⚠️ 我曾對 Adam 說「牆不在孿生這一側」＝**錯**（牆在 proxy＝遙測管線）；
kernel 的 46% 浪費仍不是這面牆的原因（在 proxy 下游），修它是省 CPU 不是解鎖能力。


---

## 🔑 08-26 凌晨：工單 E（merge）——**能用，但牆的問題無法判定**

Adam 把報告提前，E 當晚跑完。接線＝`main.py:80`
`SFlowEmitter(batch_size=int(os.environ.get("NDTWIN_SFLOW_BATCH","1")))`（**這個檔就是 reader**，
刻意堵 [[committed-setter-uncommitted-reader]] 那個坑）。實作本體是 mainDev 未提交的
`sflow_emitter.py` +87 行（`batch_size`/`_flush_one`/`flush()`），他自陳**測試從未跑過**。

### 閘門（1/256，兩臂只差 `NDTWIN_SFLOW_BATCH`）＝三項全過
| | batch=1 | batch=8 |
|---|---|---|
| **udp datagram/s** | 209.8 | **30.6（↓6.86×）** |
| λ（單邊） | 70.81 | 70.27（**不變**） |
| ratio | 1.016 | 1.008 |
| distinct | 34 | **14** |
⇒ merge 真的在 merge、樣本沒掉（E-P4 滿足 ⇒ 不是實作 bug）。降幅 6.86 而非 8 與
`batch_max_delay_s=0.2` 的 age-timer 沖出未滿批次一致。
**順帶量到「`batch_size=1` 等價於舊行為」**（brief 明令不許當前提）。

### 主量測（1/8，**同一代 fabric**，只重啟 proxy）＝**無法判定**
```
臂1 batch=1 t=0      lost 22.01  gt 160.8  ratio 0.9288  proxy CPU 154.4%
臂2 batch=8 t=+5min  lost 17.64  gt 169.3  ratio 0.9545  proxy CPU 142.0%   bmv2 219.5→219.7 不動
臂3 batch=1 t=+10min lost 29.49  gt 132.0  ratio 0.8833
```
四項同向＋bmv2 不動，看起來就是送側成本下降。**但臂 3（同參數、同世代、隔 10 分鐘）
與臂 1 差 7.5 點 > 條件間 4.4 點 ⇒ 效果落在自己的噪聲裡。E-P1 未獲支持、也未被推翻。**
🔴 臂 3 的 29.49 **落在預註冊三個分支之外**（≈22／≈17.6／中間），照實記、不硬塞。

### 🔴 兩個會上台的假數字，已擋下
1. **臂 2 的 `λ=1.258e+06`、`quantum=128` 是估計器壞了**——`quantum` 是相異 twin 讀值的
   **gcd**，批次化打散取值集合 ⇒ gcd 塌到 128 ⇒ λ 爆掉。**臂 2 的 λ/floor/spread 全部作廢。**
   （它之所以被抓到是因為 126 萬樣本/秒荒謬到不可能；沒有那個結構性上限，這種故障會安靜產出「合理」數字。）
2. 這一代 fabric 工作點**異常差且在惡化**（22%→29.5%，vs 工單 D 同組態 8.1%）⇒ 效果在健康的一代上未必重現，**這句必須進投影片**。

### 下一輪的正確設計（審查員寫下，今晚未跑）
**配對區塊**：`b1,b8` 背靠背成一對、重複 5 對、分析**對內差值**（對內只隔 2.5 分鐘，漂移進不來）。
前提：(1) 開在健康的一代（先驗工作點要對得上 D 的 8.1%，對不上就重建）；(2) 對內順序隨機。約 25 分鐘。
🔴 **不要用「加 n 的交錯設計」**：以 n=2 估的條件內 SD＝5.3 點，要分離 4.4 點需**每條件 n≈12**（一小時），
而漂移還會累積。

**產物**：`doc/audit/2026-08-25_sampling-rounds/`（`gate_e.sh`、`run_e8.sh`、`BRIEF-E-merge.md`），
raw 在 `2026-08-20_.../raw/` 前綴 `e8b1/e8b8/e8b1r/e256b1/e256b8`。

## 🆕 08-26：truncate 對**位元組記帳**的真實效應只有 0.5–2%（與「牆」無關的另一問）

上面各節談的是 truncate 對**成本／牆**的影響。另一個問題是它會不會**讓 twin 的位元組對帳失真**——
`8/25 mainDev` 的大規模輪同 fabric 兩臂實測：

| | host→sw | sw→host | sw→sw |
|---|---|---|---|
| `p4_T16`（truncate **128**） | 1.019 | 1.037 | 1.015 |
| `p4_T16nt`（truncate **關**） | 1.039 | 1.044 | 1.029 |

⇒ **差 0.5–2%**，與機制一致：**sFlow 樣本帶原始 frame 長度，收集端讀的是它、不是擷取長度。**
若收集端讀擷取長度，128/1500 會是 **12 倍**的效應，不是 2% ⇒ **這也順便證明了收集端讀的是原始長度。**

🔴 **這一格曾被誤用**：`p4_T16` / `p4_T16nt` 一度被讀成「低報 0.92」並歸因給 truncate，
那是把 `analyze.py` 的 `per-edge min` 欄當成 `ratio` 欄（見 [[verify-against-known-good-output]] 第五式）。
**truncate 從來不是那個「低報」的原因，因為那個低報不存在。**
⚠️ 但「被警告兩次、自己寫進報告當前提，然後 `ndt up` 重建 fabric 時忘了 sed」那條教訓照留。

---

## 🔑🔑 08-26 03:16 工單 F：**merge 確實省成本**——換工作點就分離出來了（`d39eca1`）

**審查員親自跑的**（Adam 在他睡前明確授權，因為兩個實驗 session 都收工了）。
腳本 `doc/audit/2026-08-25_sampling-rounds/wall_f.sh`，raw 前綴 `f16b1a/f16b8a/f16b1b/f16b8b/f16b1c/f16b8c`。

**1/16 交替跑六次，只換 `NDTWIN_SFLOW_BATCH`：**

| | batch=1（n=3） | batch=8（n=3） | 效果 | 條件內全距 | 重疊 |
|---|---|---|---|---|---|
| **proxy CPU** | 72.4 | **62.7** | **−9.7 點（−13.4%）** | 2.8 | **無** |
| **kernel CPU** | 103.6 | **86.7** | **−17.0 點（−16.4%）** | 1.8 | **無** |
| bmv2 CPU | 175.3 | 170.3 | −5.0 | **6.9**（>效果） | 不可宣稱 |
| datagram/s | 3346 | **447** | 7.46× | — | — |
| λ | 1112–1120 | 1111–1120 | **不變** | — | — |
| 掉包 | 0.036–0.044% | 0.014–0.035% | 都貼地板 | — | — |

⇒ **λ 不變 ⇒ 這是「同樣工作量下的成本」，不是「少做事所以比較省」。**
⇒ **kernel 省得比 proxy 多**（merge 也減少接收端要收與解析的 datagram 數）。

### 🔑 為什麼 E 失敗而 F 成功：**換的是工作點，不是方法**

| 工作點 | 同設定重跑的變異 | 能不能測 |
|---|---|---|
| 1/8（懸崖邊） | **7.5 點** | ❌ 效果 4.4 點被吃掉 |
| 1/256（太閒） | **0.3 點**（跨兩次完整重建！） | ❌ 樣本太少、沒東西可省 |
| **1/16** | **2.8 點** | ✅ λ=1112、掉包 0.03%、proxy 70%（平台 145%） |

**儀器從來不吵，是工作點在吵。** 1/256 那兩臂中間夾了完整 teardown＋重建卻只差 0.3 點
⇒ **重建變異在穩定區可以忽略**，這也是 F 敢沿用「每臂重建」而不手刻 proxy 重啟的理由
（手刻重啟正是 E 唯一出錯的地方）。

🔴 **這條推翻了 E 收尾時寫下的「配對區塊、每條件 n≈12」建議**：
那個估計用的是**懸崖邊**的 SD＝5.3 點。在 1/16，**n=3 就夠了**。
⇒ **要分離效果，先換工作點，不要先加 n。**

### 🔴 明確不宣稱
**天花板上移多少。** F 量的是「同一個工作點上每單位取樣工作的成本」。
**這條 CPU-vs-取樣率的線不得外推**去算飽和點——08-20 已證明外推到零會比實測零點高 45 點
（[[ab-control-deleted-nothing]]）。**「省 13–16% 成本」可講；「能開到多高」不可講。**

### ⚠️ 跑的時候踩到的坑（已修進 `wall_f.sh`）
第一次 02:57 abort：**舊 proxy 佔著 `:8081`，而 `stack.sh down` 故意不殺它自己沒啟動的 process**
（原話「the next 'up' would find the port open and **measure the wrong process**」）。
**那個守衛是對的**，清 port 是 harness 的責任。修法＝從 `ss` 讀 holder pid、**按 pid kill**；
🔴 **不可用 `pkill -f`**——腳本自己的命令列就含那些字串（見 [[destructive-shell-traps]]）。

### 🆕 順帶：proxy 的執行緒結構（讀出來的，**GIL 競爭未直接觀察**）
`py-spy dump`（透過 `sudo -n mnexec` 繞過 `ptrace_scope=1`）：**5 條 Python 執行緒、21 條 OS 執行緒**，
而那 5 條是 uvicorn 主迴圈／lldp-beacon／link-watchdog／liveness-probe／AnyIO worker
——**沒有任何一條是每交換機的樣本處理執行緒** ⇒ **樣本 callback 是從 gRPC 的 C 層執行緒進入 Python 的。**
旁證：proxy CPU 跨 1/8→1/1（142.1→146.9→146.6→140.1）**取樣率 ×8 完全不動**，而機器 14 核只用 4.4。
🔴 **但 dump 是在閒置的 proxy 上做的（1/256、無流量）⇒ 沒有直接觀察到 GIL 競爭，不得寫成已證實。**
要直接看到需在 1/8 有負載時 dump（約 20–30 分鐘）。
🔑 分片的接縫已存在：`build_p4_clients(dpids=DEFAULT_SWITCH_DPIDS)` 本來就吃子集參數；
但兩個完整 proxy **不能共存**（都綁 `:8081`、都跑自己的 LLDP beacon 會污染拓撲發現）。

---

## 🆕 08-27 更新：這份裡「GIL 競爭未直接觀察」那句已經過期

工單 G 在 1/8 有負載下量了 245 次 py-spy dump：**GIL 佔用率 0.461 對 proxy CPU 144.1%
⇒ H-GIL 推翻**，卡住 receiver 的是 `sflow_emitter.py:363` 的 `sendto`（送給 kernel 的 UDP，
緩衝滿）與 grpc C 層，**不是 GIL**。約 **85% 的 proxy 成本在直譯器之外**。
完整內容與方法在 → [[proxy-plateau-is-not-the-gil]]。

⇒ **本檔對 merge 的結論不受影響**（F 量的是成本，成立），但**不要再用「可能卡在 GIL」
當作 merge 有效的解釋**——已知它不是。

## 🏁 2026-08-27 工單 R：**batching 的孤兒狀態解除，四輪的參照系進版控了**

**先前的隱患**：D／E／F／G 四輪全部在 `sflow_emitter.py` 的**未提交**工作樹版本上量的
（sha256 `5bdf97eb…`、+84/−3、作者 `8/25 mainDev`）。⇒ 任何人 `git stash`／`git checkout`
掉它，**四輪永久不可重現**。而它**零個 Python 測試**。

✅ **已 commit（`a3bb761`）**：實作一個位元組沒改、attribution 給 `8/25 mainDev`，
**HEAD 版的 sha256 就是 `5bdf97eb…`** ⇒ 四輪量的正是版控裡這份位元組。

**補的 8 個測試**（`tests/python/test_sflow_emitter_batching.py`），兩條承重：
1. **`batch_size=1` 與 batching 前逐位元組相同** —— 碼裡的註解用大寫寫著
   "DEFAULT 1 IS EXACTLY THE OLD BEHAVIOUR, byte for byte"，**那是宣稱，先前沒有測試**；
   D/E/F/G 的基線臂全靠它。
2. **兩台交換機不得共用一個 datagram** —— sFlow 協定要求，錯了會把位元組歸給錯的交換機，
   **而且是無聲的**。用「與獨立建構的 per-dpid datagram 逐位元組相等」驗，不解析 wire format
   （解析會變成在測 parser）。

🆕 **live 獨立佐證（08-27，P4 實機）**：`GET /sflow/stats` 在 8 秒流量後讀到
**`datagrams_sent` 3828 ＝ `samples_sent` 3828`** ⇒ 「一個樣本一個 datagram」在 `batch_size=1`
下**實機成立**，與上面第 1 條的單元測試互相獨立。

🔴 **記進 `doc/KNOWN-ISSUES.md` §E-2 的潛伏缺陷（未修，用測試釘住現況）**：
老化清掃只在**有樣本進來時**才跑 ⇒ **整個 fabric 同時安靜下來，每台交換機最後一批
部分樣本留在記憶體裡直到 `close()`**。而 `flush()` 的 docstring 自己寫著
*"a caller running the emitter for long periods should call it on a timer as well"*，
**`main.py` 沒有任何 timer 呼叫它** ⇒ **緩解措施存在、需求是它自己寫下的、零呼叫者**。
**batch=1 時不咬人；truncate／merge 若採用就會咬。**
測試 `QuietFabricTailIsPinnedNotFixed` 斷言尾巴**仍在** `_pending` 裡
⇒ **未來要修必須來改這個斷言，不能不知不覺修掉。**

🆕 **新的送出面觀測點**：`GET /sflow/stats`（`59e7298`）暴露
`datagrams_sent`／`samples_sent`／`send_errors`／`batch_size` ＋時戳，
端點在 `api_routes.py`、注入在 `main.py`（`inject_emitter`）。**`sflow_emitter.py` 完全未動。**
