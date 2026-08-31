---
name: arithmetic-that-fits-is-not-the-mechanism
description: A formula that matches the measurements is not the mechanism -- now with a fifth instance where a PRE-REGISTERED INTERVAL (not a direction) caught it: predicted T in 1.16-1.20 s, measured 1.042, so a real defect explaining 4 of 18 points did not get written up as the answer -- and being wrong forced the comparison that exposed the whole batch as irreproducible
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 354194c4-0718-4137-b4b9-524e1ee1af6d
  modified: 2026-08-28T02:12:31.071Z
---

On 2026-08-11 I made the same mistake three times, and it survived into committed documentation twice.

1. **§5i of the OVS runbook.** I computed `sampling rate × packet size × 8 = 3.01 Mbps` per sFlow sample, saw it bracket the measured 1.03–4.66 spread at 1 Mbit/s, and wrote "the estimate is a multiple of 3.01 Mbps divided by the sampling window length". The code divides by `hopsCounter` — how many switches saw a sample — and the window is never a denominator (`SFlowType.hpp:339-350`). I never opened the division.
2. **§5k.** I explained why 4×50M did not starve LLDP where 1×100M reportedly did, as "the per-flow packet rate differs by 2×". But `s10→s8` carried two of those flows *in the same direction* — 100 Mbit/s at the same packet rate. The stated reason could not be true.
3. **§5j, first version.** deepseek-agent inferred "this endpoint excludes ICMP"; the pattern fit 10/10 switches. I re-derived it independently and also got 10/10. Both wrong — reading `edge.flow_set` directly showed the same ICMP flow present on one hop and absent on the next, which is per-edge sampling, not protocol filtering.

**Why:** a formula that reproduces the numbers feels like proof, and the arithmetic being *mine* makes it feel verified rather than assumed. But matching output is weak evidence: several different mechanisms produce the same numbers over a narrow range, and the range I sampled was always narrow. Case 3 is the sharpest — two independent derivations agreeing raised my confidence when it should not have, because both were reasoning from the same aggregate view.

**How to apply:** before writing down *why* a number behaves as it does, open the line that computes it. Not the function that reports it, not the caller — the actual expression, and specifically its **denominator and its filters**, which is where all three of these went wrong. If I cannot point to the line, the claim is written as an observation ("readings ranged 1.03–4.66") and never as a mechanism ("because it divides by X"). A predicted mechanism belongs in the doc only when it names the file and line, so the next reader can check it in seconds instead of inheriting my guess.

The corollary Adam's project already knows: [[cited-line-numbers-are-not-evidence]] is the same failure from the reading side, [[investigation-briefs-separate-observation-from-inference]] is the reporting-side discipline, and [[reproducible-is-not-mechanism]] is the version where someone *else's* reproducible finding is still wrong about why.

**第四次，2026-08-18，而且是在這條記憶已經存在之後。** 量到 OVS 上有 **20 個介面沒有 htb
整形**，同時 twin 報 **20 條邊 down**，兩個 20 對上了，我就寫下「電源循環把兩端的整形都毀了」
並產出一份帶「內部對照組」的發現文件。

**那個 20=20 是巧合。** 真相是 16 個從來沒有被整形過（Mininet 忽略 `bw>1000`，
見 [[ovs-testbed-bandwidth-reality]]），電源循環只掉了 4 個。我宣稱的「內部對照」
（s6 的 eth3/eth4 掉了、eth1/eth2 沒掉）**什麼都沒證明——s6 根本沒被關過機**。

這次的變形值得記：**我不是沒去讀碼，我讀了 `OVSPowerStrategy.cpp` 而且它確實沒有還原
qdisc**——機制的一半是真的。錯在我沒去讀**另一邊**：那 20 個介面本來的整形狀態。
一個成立的機制加上一個沒查證的分母，仍然是錯的結論。

**新增的做法**：宣稱「X 造成 N 個東西改變」之前，先量 **X 發生之前的 N**。
今天的解法就是這個——在一個全新、從未被電源循環過的拓撲上重量，得到 144/160，
差額正好 4，預測與新樣本吻合。

**第四例（2026-08-20 深夜，觀察版）**：兩個 session 剛各自修完同形的過濾器錯誤（recorder／比對器都只留 inter-switch 邊），對殘餘觀察「host-facing 邊上有 206 Mbit/s」**合編**了「模型分類或接線有錯」的新機制——聽起來合理、與兩邊資料都吻合。答案是一行 JSON（`dst_ip=10.0.0.33`）加兩個 ping：那是 h33 自己的接取鏈路，流量是目的端最後一跳。**觀察吻合也不是機制；先問「這條邊接到誰」再蓋理論。**

**第六例（2026-08-24）——這次是「時鐘自己動了」，而且我差點回報兩個假發現。**
`boot_rate.txt` 有一行 `boot 8: CONVERGED wall=7626s`，而腳本明明包著 `timeout 600 ndt up ovs`。
7626 > 600 完美吻合「deadline 被繞過」，我當場寫下三個結論並**已經口頭報給 Adam**：
deadline 被繞過 12.7×、基線該從 6/10 改判 7/10、boot 8 是「環會自癒」的反證。**三個全錯。**

真相是 `journalctl` 兩行：`PM: suspend entry 13:04:58` / `suspend exit 15:11:07`——筆電睡了 7569 秒，
而 `rate_boot8_up.out` 的 mtime 是**resume 後 3 秒**。boot 8 實際只跑了約 50 秒（和其他成功的 58 秒一致）。
之所以印「converged」而不是逾時警告，是因為 `await_convergence` 的**成功判斷排在 deadline 判斷之前**，
resume 後第一輪就看到數字齊了、直接從成功分支返回，從頭到尾沒看過時鐘。

兩個新做法：
1. **我這次做對的一件事**：我為「curl 卡住所以繞過 deadline」這個假說去讀了原始碼，發現三個 curl
   全都帶 `--max-time 3`，**假說當場被自己否證**，沒有寫進報告。讀碼要讀到能否證自己為止。
2. **牆鐘減法的新盲點**：`$(date +%s) - start` 會把 suspend 一起算進去。任何無人看顧的計時實驗，
   引用秒數前先 `journalctl -k | grep "PM: suspend entry"` 對一次時間窗；跨過 suspend 的那次要標
   CONTAMINATED 排除，不能靜靜平均進去。長實驗直接包 `systemd-inhibit --what=idle:sleep`。

**這一族的新形狀：數字超出上限時，先問「是上限失效，還是時鐘動了」。**
機制不一定在程式裡——這次它在作業系統的電源管理裡。

---

## 🆕 08-25 第四例：**寫進註解的數字，28 倍是錯的，而且沒有人量過**

`intelligent_router.py` 的開機環註解寫：
> 「this app also observes EventOFPPacketIn, so every punted LLDP lands in the same queue at
> ~2.5/s: **128 slots fill in ~50 s**」

實測（`doc/audit/2026-08-25_ring-edge-fix/phase5_arrival_rate.txt`，n=2 每臂）：
**packet_in ≈ 70/s、t_fill ≈ 1.8 s** ⇒ **差 28 倍**。

**更重要的是第二層**：`NDTWIN_RYU_LLDP_GUARD` 從 0.01 改成 0.05（LLDP 送出慢 5×），
總到達率只從 70.5/s 掉到 57.8/s ＝ **1.22×，不是 5×**。
⇒ **進佇列的 packet-in 大部分根本不是 LLDP**（table-miss 規則把所有東西送上控制器，
開機時的 host ping burst 才是大宗）。

⇒ **那段註解錯的不只是數字，是它假設的機制。** 算式（2.5/s × 128 ≈ 50s）內部自洽、
看起來很合理、被後續每一輪引用，但**分子選錯了物種**。

**規則**：註解裡出現「≈ N/s」「約 N 秒」這種量，先問**誰量的、量在哪個檔**。
量不到出處就當它未經驗證，不要拿它推導下一步。
相關：[[cited-line-numbers-are-not-evidence]]、[[check-against-prior-experiments]]


## 第五例(2026-08-25):**可否證的區間救了我兩次,而「方向對」會騙人**

這次我事前把預測寫成**區間**而不是方向:
> 若「bps 分母寫死成 1」是那個 +18% 高報的成因,則迴圈週期 `T` ∈ **1.16–1.20 s**。

**實測 1.042 s。**

### 救我的第一次:不讓「方向對」冒充「機制對」

實測確實 > 1 秒(空載 1000.1 ms → 16 流 1042 ms,儀器精度 0.1 ms,42 ms 不是雜訊),
**所以那個缺陷是真的**。若預註冊只寫「預期 `T` > 1 秒」,我會寫成「機制確認」收工——
把一個**只解釋 18 個百分點裡的 4 個**的成因當成答案,**而且它看起來完全合理**。

🔑 **區間逼我事前承諾「1.04 算什麼」。答案是:算部分成因,不算解釋。**

### 救我的第二次:逼出同一輪內的比較,而那個比較炸掉了整批數字

因為 1.042 ≠ 1.18,我必須做「同一輪內 ratio vs 該輪自己的 `T`」的比較(跨輪會被不同 `T` 污染)。
做下去才發現:**同條件同平面,15:53 量到 1.18、23:38 量到 0.92,差 1.28 倍且方向相反**
⇒ **整批高報數字不可重現**([[large-scale-concurrent-never-measured]] §0-警告)。

**如果我當初猜中(比如量到 1.18),我不會做那個比較,那批不可重現的數字會原封不動進報告。**
⇒ 預測錯 + 事前寫死判讀規則,比預測對更有價值。

### 判準

寫預測時問自己:**「如果實測落在區間外但方向正確,我會怎麼寫?」**
若答案是「還是會說機制確認」,那個預測沒有可否證性,等於沒寫。
配套是**結構性上下限**(本輪是迴圈自己的 `sleep_for(1s)`),讓錯的答案自曝——
見 [[assert-invariants-not-repro-rates]]、[[new-tools-are-the-first-thing-under-test]]。

## 🆕 08-27：**混淆因子的「方向檢查」——零成本排除一個解釋**（sFlow 萃取，auditor 提出實例）

工單 N 的吞吐量在兩格之間差 **+15.5%**（53.142 → 61.377 Gbit/s），而兩格的環境不同
（後一格有一台 4 vCPU 的 QEMU VM 在場）。自然的處置是「confounded、歸因未定」。

🔑 **但混淆因子指向錯的方向**：後一格**多了一個競爭者**，吞吐卻**更高**。
CPU 競爭應該讓吞吐**下降**。⇒ **「VM 造成的」這個解釋被方向排除了**，不需要任何新量測。

⇒ 可重用形式（sFlow 的措辭，比原始實例通用）：
> **混淆因子存在 ≠ 它能解釋觀察到的效應。先問它的方向對不對——
> 方向不符就能在不量測的情況下零成本排除它。**

**How to apply:** 發現混淆因子時，先問三句再決定要不要重跑：
1. 它的**方向**與觀察到的效應一致嗎？不一致 ⇒ 它不是解釋（但格子仍不可逐值比較）。
2. 它的**量級**夠嗎？（今天另一例：VM 1.63 核 vs 待測效果 0.46 核 ⇒ 夠大，要處理。）
3. 它在兩臂之間**變不變**？不變 ⇒ 配對設計可吸收；變 ⇒ 才是真的混淆。

⚠️ 方向不符**不能**把兩格升級成「可逐值比較」——它只排除**一個**解釋。
差異仍是未解釋的，只是候選少一個。**兩件事要分開寫。**

## 🔴 2026-08-28 反面：**方向不符是免費的排除，方向相符不是免費的採用**

上面那條寫的是「方向不符 ⇒ 零成本排除」。**這個早上撞到它的鏡像面，而鏡像面沒有對稱。**

`8/27 mainDev` 的 Q base 列 miss 了註冊區間（實測全在上方）。手邊剛好有一個現成解釋：
`measure_loop_period.py` 的檔頭**自己警告**長週期會讓估計**偏低**——**方向剛好對得上**。
⇒ 採用它，miss 就結案了，而且看起來像做過功課。

**他沒有採用，去拿 in-loop 儀器對帳，結果外部估計實際上偏高 11.5 ms ⇒ 那個解釋被否掉。**
真正的原因是：**註冊的 ±0.02（＝±20 ms 週期）比他自己量到的臂間離散度 57 ms 還窄。
區間訂錯，不是多出機制。**

🔑 **可操作的那一句：**
> **一個方向剛好對的解釋，是最貴的那一種，因為它讓人停止查證。**
> 方向相符只把它**留在候選名單上**，不能結案；要結案得用**獨立的資料**驗它的量級與符號。

⇒ 與上面併起來是一組不對稱的判準：
**方向不符 ⇒ 可以零成本刪掉。方向相符 ⇒ 什麼都還沒得到。**

## 🔑 同一天的第二條：**衍生量的容差，至少要和它繼承的噪聲一樣寬**

`mainDev` 的措辭，三個實例，**其中一個是我出的**：

| # | 註冊了什麼 | 繼承的噪聲 | 結果 |
|---|---|---|---|
| 1 | Q base 的 ratio ±0.02（＝週期 ±20 ms） | 臂間離散度 **57 ms** | miss，而原因是容差窄 |
| 2 | M 的臂層級平均 0.4–0.6 s（**絕對值**） | 兩臂共有的偵測地板 **0.146 s** | miss；扣掉地板＝0.530，在區間內 |
| 3 | 🔴 **我出的漂移門檻 90 ms** | 拿**安靜臂**（27.2／41.6）校準，用在 **churn 臂** | 實測 **57.0**，過關但校準母體本來就不對 |

⚠️ **#2 與 #1／#3 不完全同型**：#1/#3 是**寬度**訂太窄，#2 是**量選錯了**（訂在絕對值而非差值）。
**兩者都會以「miss」的形式現身，而修法不同** ⇒ miss 之後第一問是「**訂錯寬度還是訂錯量**」。

🔴 **而「區間訂錯了」是 miss 之後最方便的解釋**，所以它受上面那條約束：
**必須先用獨立資料排除「機制真的不一樣」，才准採用它。** #1 就是這樣做的。

相關：[[ratio-sides-must-share-a-population]]（#3 正是「母體叫不叫得起它的名字」）、
[[controls-decide-what-you-learn]]、[[instrument-must-not-mimic-its-own-finding]]（#2 的地板）

## 🆕 08-31：**資訊在被否證的那一半**——預測要開跑前寫下，否則「合理」會吃掉它

盤點一顆 14:41 的 VM 快照裡有沒有私有 repo。**開跑前登記了預測**：
reviewer 的 `b-round/` 是 14:5x 之後才建的 ⇒ 快照裡應該少那幾個。

| 預測 | 結果 |
|---|---|
| `b-round/`（5 個 repo）不在 | ✅ 對（24 − 19 ＝ 5，正好那五個） |
| `c4/` 也不在 | 🔴 **錯，它在** |

追那個錯的一半 ⇒ `c4/p4benchmark` 的 `git reflog` 說 clone 於 **14:23:43**，
而佔用帳上寫的是「~14:5x」——**帳錯了半小時**，已更正。

🔑 **若我沒有先寫下預測，`19` 這個數字只會被讀成「比 24 少，合理」** ——
**方向相符，然後就停在那裡**（＝本檔開頭那條）。那半小時的誤差會留在帳上，
而它是別人排時序時要用的東西。

⇒ **可轉移的兩句**：
1. **一個被否證的預測，比一個被證實的預測給了更多東西。** 證實只讓你回到原地，
   否證會指著一個你原本不知道自己不知道的東西。
2. **「合理」是最貴的形容詞**：它是「我沒有預期值」的偽裝。**有預期值的時候，
   你講的是「差 5，正好是那五個」；沒有的時候，你只講得出「比較少，合理」。**

⚠️ 反面也要記：預測**要便宜**才寫得下去。這次那句話只有一行，寫在派工單旁邊，
**成本接近零而回報是一個被更正的帳**。不要把「登記預測」搞成一份文件。

## 🔴 08-31：**一個推出來的估計，是「某個真實區間」的長度——只是不是被問的那一段**

同一個問題（「在 nslab 上重建一顆 kernel 要多久」）一天內被報錯兩次，**方向相反**：

| 報的值 | 怎麼來的 | 錯在哪 |
|---|---|---|
| **2 分鐘** | 只算「送檔」那一步 | **假設 VM 還在**——而正在討論的 `destroy` 恰好拿掉那個前提 |
| **30 分鐘** | 把整段佔用窗（23 分）當 build 時間 | 那 23 分**含兩次 build 失敗與診斷** |
| ✅ **18 分鐘** | **讀 build log**（三次 build ＝ 4:25） | — |

🔑 **兩次都不是從 log 導出來的，而那份 log 從頭到尾就在磁碟上。**

⇒ **這比「猜錯」難發現得多**：兩個錯值**都是某個真實區間的長度**，
所以它們**都通得過「這數字像不像話」的檢查**。
**同族＝[[ratio-sides-must-share-a-population]]**：那裡問「這兩邊是同一個母體嗎」，
這裡問「**這個長度，是哪一段的長度？**」

### 🔴 我的那一份：**轉述一個數字＝為它背書**

兩次都經過我：①拿它的「2 分鐘」下了決定性建議（去 destroy）②**把「30 分鐘」轉給第三方當排程依據**。
兩次都沒問那個數字怎麼來的。

> **轉述任何要被拿去排程／下決定的數字前，問一句「這是量的還是算的？量的是哪一段？」**
> 那一句的成本是一行字；**接收方拿它去排一個窗的成本，是那個窗。**

🔑 **而正確答案往往就在旁邊**：這次是磁碟上的 build log；同一天早上是「**最好的樣本
就是那個真正在跑的傳輸本身**」（我用 8 MB 合成樣本量頻寬，而 2.5 GB 的真傳輸正在跑）。
⇒ **兩次都是在有現成量測的情況下，用了一個推出來的數字。**
**判準：動手估之前先問「有沒有一份已經在跑／已經落盤的東西，直接回答了這件事？」**
