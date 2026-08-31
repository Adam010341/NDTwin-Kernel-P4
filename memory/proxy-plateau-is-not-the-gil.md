---
name: proxy-plateau-is-not-the-gil
description: "🔑 08-27 工單 G 實測推翻「proxy 卡在 GIL」——144.1% CPU 對 GIL 佔用率 0.461；卡住的是 `sflow_emitter.py:363` 的 `sendto`（＝回壓鏈第一環）與 grpc C 層"
metadata: 
  node_type: memory
  type: project
  originSessionId: bfb90c75-a7ee-41b9-91e0-48f870a0ed59
  modified: 2026-08-27T03:47:50.300Z
---

2026-08-27，工單 G（Adam 排序第②項）。1/8 @ 200 Mbit/s、一代 fabric、三臂、
245 次 py-spy dump（透過 `sudo -n mnexec -a <pid>`，本機 `ptrace_scope=1`）。
全文＋原始 dump：`doc/audit/2026-08-25_sampling-rounds/PREREG.md`（工單 G／增補 G-1）、
`raw_gil.tar.gz`、commit `5586ca9`。

## 結論：**H-GIL 推翻**

| 臂 | G（GIL 被持有比例） | W | proxy CPU |
|---|---|---|---|
| 閒置（開機殘 work） | 0.000 | 0.20 | 10.6% |
| **負載** | **0.461** | 1.64 | **144.1%** |
| 閒置（漂移基準） | 0.025 | 0.03 | 8.9% |

事前寫死 G ≤ 0.60 ⇒ 推翻。🔑 **proxy 燒著那個平台的 144%，而直譯器一半以上時間是空的。**

## 🔑 決定性的那一步：兩個指標打架，用邏輯拆開

W=1.64 讀起來像排隊，G=0.461 說 GIL 沒飽和。**等 GIL 的執行緒看到 GIL 空著就會拿走它**
⇒ 若排隊在 GIL 上，「GIL 空著且有人排隊」必須是 0。實測 **46/102**，
**P(GIL 被持有│有人排隊) = 0.432 對理論 1.000** ⇒ 不是在等 GIL。

⇒ **通用招式**：兩個指標矛盾時，找出「若機制 X 成立則必為零」的那一格，去數它。
比再多加一個指標有用。相關：[[arithmetic-that-fits-is-not-the-mechanism]]

## 它們實際在等什麼（頂層 frame 原文）

| 次數 | frame | 是什麼 |
|---|---|---|
| 44 | `sflow_emitter.py:363 (emit)` | **`self._sock.sendto(datagram, self.collector)`** |
| 51 | `grpc/_channel.py:932 (_next)` | `self._call.operate(...)`，cygrpc，**GIL 已放開** |
| 24 | `threading.py:304 (__enter__)` | grpc channel 的 `Condition` 鎖，**不是 GIL** |

### 🔴 撤回：我曾寫「`sendto` 停住＝送出緩衝滿＝kernel 沒抽乾＝回壓第一環」——**不成立**

`8/27 auditor` 驗收時查了機制（08-27）。**H-GIL 推翻的裁決不受影響**，但這句單獨撤回：

1. **收端是 loopback**：`sflow_emitter.py:93` `DEFAULT_COLLECTOR = ("127.0.0.1", 6343)`，
   `:288` 是沒有任何 `setsockopt`/`setblocking` 的 `SOCK_DGRAM`。
   **我沒打開這一行就下了結論。**
2. `loopback_xmit` 進場 `skb_orphan` ⇒ 送出緩衝記帳在同一次 `sendto` 內釋放，不會累積。
   收端 rcvbuf 滿的表現是**無聲丟包＋sendto 回成功**，不是阻塞。
3. **對帳舊結果反對我**：工單 E 已量到**樣本沒掉** ⇒ rcvbuf 沒滿。

🔑 **睡眠是真的、機制未指認**。把 60 次 `emit` 觀察按「有沒有人持有 GIL」切開：
**28 次睡著而 GIL 是空的**、16 次睡著而 GIL 被持有、14 次在 CPU 上、2 次自己持有
⇒ 「等著重取 GIL」最多蓋 16/44。全 60 次都落在那三條熱 receiver 上。

🔴 **這一刀所需的資料我早就有**：我算過全域 P(GIL 被持有│有人排隊)=0.432，
**卻沒有把 `sendto` 那 44 次單獨切開**，一個多小時後才被別人切。
⇒ [[arithmetic-that-fits-is-not-the-mechanism]] 又一例，而且是**證據在手上**的那種。

✅ 可講：「觀察到與回壓一致的睡眠」（三條熱 receiver 各約 14% 的 dump）
❌ 不可講：「回壓第一環被直接觀察到」「送出緩衝滿」「kernel 沒抽乾」

## 144.1% 的帳（`/proc` 的 utime+stime，完全不經過 py-spy）

- `_stream_receiver` **只有 3 條熱的**，各 20.4% ⇒ 61.3%
- `_run`（grpc `channel_spin`）3 條，各 16.8% ⇒ 50.5%
- **py-spy 看不見的原生執行緒 ~16 條**（零 Python frame），各 ~2.1% ⇒ ~33%
- ⇒ 約 85% 不在直譯器裡——🔴 **但這是 frame 推估**。`G=0.461` 守得住的**量測下界**是 `(144.3−46.1)/144.3 ≈ **68%**` ⇒ **deck 印「至少三分之二」**，85% 要用必須標推估

🔑 **為什麼只有 3 條**：`h1→h33` 單流只經過路徑上那幾台 switch，其餘七台沒樣本可送。
**樣本負載集中在路徑上，不是散在 fabric 上** ⇒ 單流量到的是 3 條 receiver 的上限，不是 10 條的。
**多流從沒量過。**

## 結構真值（推翻交接說法）

交接寫「5 Python / 21 OS」⇒ 實測 **35 Python / 51 OS**：
`MainThread` 1、**`_stream_receiver` 10**（每台 switch 一條）、`_run` 20、
`liveness-probe`/`link-watchdog`/`lldp-beacon`/`AnyIO worker` 各 1。

## 方法上可重用的三件事

1. **`py-spy dump --json` 有 `owns_gil` / `active` / `os_thread_id` 三個欄位**，
   靠 `os_thread_id` 可以把 py-spy 與 `/proc/<pid>/task/<tid>/stat` 對起來 ⇒ 兩個獨立儀器。
   單次 dump **0.01 s**，1 Hz ≈ 1% 負擔。
2. **儀器擾動要量**：dump 前 148.2 / dump 中 144.3 / dump 後 146.6 ⇒ 暫停行程**沒有**製造隊列。
3. **`active` 是關鍵的第三態**：`active=True ∧ owns_gil=False` ＝ 在 C 層跑（GIL 已放開），
   只有 `active=False ∧ owns_gil=False ∧ 非已知等待` 才可能是 GIL 排隊。

## 🔴 不得宣稱

天花板往上移多少、天花板在哪、回壓鏈成立、多流下的結構。本輪只說**它不是 GIL**。

相關：[[telemetry-cost-is-fixed-not-per-sample]]（那份是 **kernel** 側熱執行緒）、
[[sflow-truncate-merge-status]]、[[py-spy-via-mnexec-under-ptrace-scope]]、
[[controls-decide-what-you-learn]]、[[failures-that-report-success]]

---

## 🆕 08-27 工單 H：那些睡眠**等的不是送出路徑**（(a)(c)(d) 出局，(b) 未達門檻）

1/8 負載、三臂、`/proc/<tid>/wchan` ＋ `/proc/net/udp` ＋ py-spy 三向對帳。
全文＝`PREREG.md` 增補 H-1、commit `c441ddb`、原始資料 `raw_h.tar.gz`。

38 個 `emit(363)` 睡眠者、23 個接得上穩定 wchan：

| wchan | 次數 | 候選 |
|---|---|---|
| `futex_do_wait` | **15**（65.2%） | (b) GIL 重取 |
| `0`（符號化不出來） | 8 | 未指認 |
| `sock_wait_for_wmem`／`sock_alloc_send_pskb` | **0** | **(a)** |
| `shrink_*`／`try_to_free_pages` | **0** | **(c)** |

| 候選 | 結果 |
|---|---|
| (a) kernel 收端回壓 | **出局**（send-wait 0/23、drops delta 0、`rx_queue` max 960 B＝單一 datagram；**兩個獨立工作點**） |
| (b) GIL 重取（含喚醒延遲） | **唯一有正面證據，但未達事前門檻** 0.652 < 0.80 ⇒ **不宣稱成立** |
| (c) direct reclaim | **對這些執行緒出局** |
| (d) py-spy `active` 假象 | **出局**——一致率 97.4–99.9% ⇒ **工單 G 的 `active` 讀數也一併洗清** |
| (e) 其他 | **仍開著**（8 次 `0`：4 S／3 不穩／1 R） |

### 🔑 三條可重用的

1. **`/proc/<tid>/wchan` 是「它在等什麼」的最便宜答案**（讀一個檔），
   Python frame 只說直譯器停在哪，說不出 OS 在等什麼。
   **下一步更強的是 `/proc/<tid>/syscall`**——給系統呼叫編號與參數，
   **wchan 符號化不出來時它仍有值**（正好蓋那 8 個 `0`）。未跑。
2. 🔴 **判準的符號要選「會出現」的那個**：我原本用 `sk_stream_wait_memory` 當 (a) 的判準，
   審查員指出**那是 TCP 的、UDP 永遠不會停在那**⇒ 那個桶永遠 0，而我會把「沒觸發」
   讀成「(a) 出局」。**一個測不到它宣稱在測的東西的判準＝裝飾性判準。**
3. 🔴 **「沒有執行緒停在 reclaim 裡」≠「機器沒在 reclaim」**。本輪機器**確實**在
   direct reclaim（`pgscan_direct` 一分鐘內 +85,432 頁、`MemAvailable` 4/15.8 GB），
   但 23 個睡眠者沒有一個在回收路徑上。**兩句都真，合併就是錯的結論。**

### ⚠️ 環境confound（引用本輪數字必附）

`開機手冊` session 12:38 起了一台 **`ndt status` 看不見的 QEMU VM**。
H 跑 12:43–12:49 ⇒ 三臂**一致**帶著它（臂間比較成立），
但 **loadavg 7.03–20.07 對工單 G 的 ~11 ⇒ G 與 H 不可逐值比較**。
🔑 **教訓：`ndt status` 不涵蓋整台機器**；量測前值得看一眼 `loadavg` 與 `MemAvailable`。
