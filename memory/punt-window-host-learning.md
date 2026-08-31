---
name: punt-window-host-learning
description: "OVS host-IPv4 學習窗＝settle 窗（已修，預設 40）。🟢 **08-25 下午：開機環結案**——機制已觀察（switches ⇄ IntelligentRyu 兩個事件迴圈的 2-cycle，由 EventSwitchEnter handler 下的無時限 request-reply 閉合）；修法 A（時限）與 B（搬離事件迴圈）皆已實測，B 已上線且不變量可在冷機驗證；🔴 **碼註解裡的「LLDP ~2.5/s、128 格 50s 填滿」實測差 28 倍**（真值 ~70/s、1.8s），且 guard 只改變到達率 1.22× 不是 5× ⇒ 到達率從來不是限制因素、guard 不是成因。全文 doc/audit/2026-08-25_ring-edge-fix/REPORT.md"
metadata: 
  node_type: memory
  type: project
  originSessionId: 80663333-dc9c-42bd-9c05-499d63b60be1
  modified: 2026-08-27T14:01:40.043Z
---

**Ryu 只從 packet-in 學 host IPv4，而 all-pairs 規則從模型 proactive 裝好之後 IPv4 永不
punt、static ARP 又封死 ARP 路 ⇒ 學習窗＝[switch 連上, all-pairs install]＝settle 窗。**
窗關了之後，等再久、灌再多流量都教不會（2026-08-22 介入實驗，`e5e4980`，
`doc/audit/2026-08-22_punt-window-discriminator/`）：

- 控制臂：規則完好，h1→10.0.0.33 ping 3/3 送達，**0/128** 學到
- 實驗臂：REST 刪掉 s1 的 `ipv4_dst=10.0.0.33` 規則（斷言 1→0），同樣的 ping 變 punt
  （priority-0 OUTPUT:CONTROLLER 事先確認存在），**恰好 10.0.0.1**（packet-in 的 src）出現
- 35 秒後 kernel 圖恰好 h1 的兩條有向邊翻 up ⇒ `updateHosts→findEdgeByHostIp` 下游健康，
  **256-down 迴歸完全在 kernel 上游**

宏觀兩臂（皆 08-21 同日同機）：settle=10 → 0/128 持續 ≥4 分鐘；settle=60（L4 baseline
抓取）→ 128/128 全有 IP。08-07 的「128/128」量在 settle=60 時代——[[ndtwin-static-arp-blocks-host-discovery]]
的「empty ipv4 是 transient」只在窗內成立，窗外是**永久**的。[[speedups-pass-the-wrong-test]]
的 settle 迴歸機制就是這個。

## 🔴 08-22 下午更正：一半成立，一半被自己的實測推翻

patch 已 apply 並量過（`33f1de9`、`doc/audit/2026-08-22_settle-gate-acceptance/`）。結果：

**① gate 根本沒有在 gate。** 它宣稱「等 host 學到、健康 fabric 提早離開」——**11 次開機裡
早退路徑一次都沒走過**。deadline 90 → 整整 90 秒讀到 0/128；deadline 180 → 整整 180 秒讀到
0/128，開機時間 = base + deadline。它不是瞎（外部 poller 打 `/v1.0/topology/hosts` 每 2 秒，
跟它讀到的完全一致）——**是真的沒東西可看**。

**② 「開機那輪 ping burst 教會 Ryu」是錯的。** 直接數 `testbed_topo.py` 自己印的 128 行
"Pinging from hN"（`ndtwin-lab topo-out`＝tmux capture-pane，每次開機新 session 所以不會髒）：
**burst 在 t+32 秒內全跑完，Ryu 接下來 65 秒一台都沒學到**，128 台的 IPv4 是在 settle 放開的
那**一個取樣點**一次全出現。所以「punt 會教」✅（介入實驗證明的，仍然成立），
「開機 burst 就是那些 punt」❌。**真正在放開那刻教會 Ryu 的是什麼，還沒查出來**——那刻發生的
是 all-pairs walk 裝規則，而裝轉發規則正是最不該產生 packet-in 的動作。

**③ 真正的答案是量出來的曲線，不是機制。** 11 次完整開機，t+0 與 t+20 各讀一次
（`settle_bisect.txt`）：

| settle | 5 | 10 | 10 | 15 | 20 | 30 | 40 ×3 | 55 | 90 |
|---|---|---|---|---|---|---|---|---|---|
| 結果 | 🔴 | 🔴 | 🔴 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 開機 | 16s | 20s | 20s | 27s | 31s | 41s | **52s** | 66s | 100s |

🔑 **是懸崖不是斜坡**（128 台全學到或一台都沒有），分界在 **10 與 15 之間**。
**預設已改 40（n=3，52 秒）——比 settle=60 時代的 73 秒還快而且是對的**，所以 8/27 的 OVS
數字是進步不是退步。**不要往 15 調**：失敗無聲且全面（轉發全正常、ping 全通、開機輸出零警告，
只有 `get_graph_data` 的 down 數會說話）。

⚠️ 我自己踩的坑：先看 deadline=90 的單點，推論「burst 落在 t+96、差一秒、加大 margin」→ 改成
180。第二個點就推翻了它。**單點加故事＝猜**。

🔴🔴 **08-24 已量完，這條現在是本專案最重要的未解缺陷：defaults 開機 10 次 6 次不收斂**
（review session，`doc/audit/2026-08-24_full-stack-run/boot_rate.txt`，commit 79cd66a）。
**結果**二值分明沒有中間態（收斂或不收斂）。成功一律 58 s；⚠️ 失敗的 413–415 s **是 `ndt`
放棄等 converged 標記的常數，不是缺陷的簽名**——那個緊分佈量的是量測殼、不是故障，而且失敗態
在 ndt 放棄後仍持續（boot1 的 kernel 在 Ryu 起後 +7 分鐘還在拿 158-byte 空 paths）＝穩定態，
不是「400 s 後翻轉」。（boot 8 的 7626 s 是筆電 suspend、收斂算數但計時作廢。）裁決規則（數字出來前就定好的）因此觸發 → **8/27 deck 那頁不放任何秒數**，
52 s 與 24.1 s 都作廢，改放「收斂缺陷 open」。

🔬 **機制已定位，而且不是「switch 沒連上」**：六個失敗 boot 的 `EventOFPStateChange` 都是
10/10、t+300 waiter 也看到 10 online 並照裝路由 —— 空的是 `/v1.0/topology/links`（整場 109
bytes 空）⇒ **LLDP link discovery 全程零產出**，all-pairs walk 對一張沒有邊的圖正確地跑完。
🔑 **兩種失敗的辨識法（散文裡長得很像）**：

| 失敗 | kernel 圖 | 壞的是什麼 |
|---|---|---|
| settle 迴歸（已修） | 288 邊、**256** down | host IPv4 沒學到；switch-switch 邊正常 |
| 本缺陷（未解） | 288 邊、**288** down | 一條邊都沒發現 |

⚠️ **本週所有 OVS 數字都量在這個雙峰母體的成功半邊**（沒人知道它是雙峰）——settle 懸崖、
burst 時序、0/128 vs 128/128 在「有收斂的 boot 上」仍然成立，但引用開機秒數前要先問這個。
LLDP backoff 已雙重除罪：defaults 6/10 失敗＋sweep 修補在 `if _lldp_backoff:` 分支內。
settle-gate REPORT 的候選(1)（handler 堵住自己 app 的事件佇列）**確認真的發生**
（失敗 boot `entered` 只跑 2/10、健康 10/10）**但不是禍首**（links 屬於沒被堵的 Switches app）。

🔴 **08-24 驗收層補記（review session）**：(1) 上表的 52s **只量到成功的開機**——之後兩天
plain defaults 已知結果 5 boots 失敗 3（`2026-08-24_path-switch-count-404/REPORT.md`，
簽名=0 link events、不轉發；與 settle 值無關的上游缺陷，open）；引用 52s 要帶這個 caveat。
(2) bisect 表的磁碟證據不完整：`settle_bisect.sh` 每次呼叫清空輸出＋同臂重跑同名覆寫 raw，
11 列裡 5 列無獨立檔案（更正單 C-1a）。(3) 上面 How-to-apply ①「窗內主動 ping」以 burst
被推翻後不再有依據——修 256-down 的可靠路只剩「kernel 不依賴 ipv4」那條。

✅ **08-24 深夜結案：開機不收斂＝semaphore 死鎖環，frame 級抓到**（full-stack round，
`doc/audit/2026-08-24_full-stack-run/`，commit `71ba08b`）。實測 defaults ×10 失敗 **6/10**、
二值（58s 或永不、放 15 分鐘不自癒）。USR2 greenlet dump（mainDev 的 `7f7de4a` 儀器）：
**12 個 greenlet 卡在 `_send_event→_events_sem.acquire()`**（Ryu 的 app buffer＝queue＋
semaphore 對、128 格）——10 個 datapath serve loop 發 packet-in、link_loop、以及 **Switches
event loop 在 `lldp_packet_in_handler` 宣告第一條 `EventLinkAdd` 時卡死＝discovery 成功但
宣告不出去**；另半環＝IntelligentRyu 的 event loop 在 gate 的 `get_all_host→reply_q.get()`
**無 timeout** 等回覆。settle **值**除罪（環只需 handler 內有阻塞 request＋buffer 滿）。
兩條環邊已各自砍斷：`d1d973d`（gate poll 包 hub.Timeout，「能被繞過的 deadline 不是
deadline」）＋`72fbae6`（async install flag，預設關）；修復輪 live 驗證（flag ×10 對照
6/10 基線）由 mainDev 接。⚠️ 我差點用錯的 grep（找 `in put`、實為 sem acquire）把對的
假說判死——自動判決行保留原樣＋報告更正。曾寫過的「~12 分鐘自癒」預測已被否證。

## 🔴🔴 08-24 晚間：**wedge 召不出來了。同一個 commit 今晚 10/10 全過。**

修復輪跑完了，結論不是「修好了」而是**「今天沒得驗」**。四臂各 n=10（全在 `systemd-inhibit`
下、每次 boot 對 `journalctl` 查 suspend）：

| 臂 | router | 失敗 | 秒數 |
|---|---|---|---|
| 基線 12:23（review session） | `79cd66a` sha `d192329b` | **6/10** | 414 wedged／58 ok |
| t_only（今日預設） | HEAD sha `d19020b1` | 0/10 | 52–53 |
| async（+flag） | HEAD＋flag | 0/10 | **26**，banner 10/10 斷言 |
| **對照組** | **`79cd66a` 還原** | **0/10** | 52–53 |

**⇒ 兩個修法都沒被驗證，`d1d973d` 的功勞不成立。** 我拿到 t_only 0/10 時差點回報「timeout
修好了」，擋下來的是兩件事：**① `d1d973d` 動作時會 log warning，四臂零筆**，而且每次秒數都跟
基線的**成功例**一樣，沒有一次像被救回來；② 對照組坐實「今天不觸發」。

**唯一站得住的結果：async flag 把開機時間砍半（26s vs 52s）**——同日、同機、單變數、n=10、
banner 每次斷言。**這是速度結果，與 wedge 無關**；要翻預設只能拿速度當理由。

**被我殺掉的假說（方向是反的，值得記）**：6 個失敗 log **全部**是 12 筆 switch-enter／10
unique，6/6 一致，而環正好起於那個 handler ⇒ 看起來 duplicate `EventSwitchEnter` 是觸發點。
但抓一個**同基線碼、成功**的 boot 來比：**20 筆／10 unique**（每台兩筆）。**成功的更多。**
失敗那 12 是**被截斷**的計數（app 卡住就不再通知）＝症狀不是成因。
**只有失敗組的 log 會把人帶到相反結論**——見 [[ratio-sides-must-share-a-population]]。

**和解後的正解（與 review session 兩輪對打得出，比雙方原版都準）**：
`Failed to notify NDT (switch enter)` **同一個字串、兩個 handler 發**，所以 flat `grep -c`
看起來同質其實不是：

| handler | marker | notify site | 失敗 | 成功 |
|---|---|---|---|---|
| `EventSwitchEnter`→`get_topology_data` | `Switch entered:` `:754` | **`:763`** | **2** | 10 |
| `EventOFPStateChange`→`_state_change_handler` | `connected (…)` `:827` | **`:857`** | 10 | 10 |
| | | 合計 | **12** | **20** |

逐 dpid：失敗那次**只有 dpid 1、2** 進到 enter handler，**十台全部**進到 state-change。
⇒ **截斷只落在 `:763`（enter handler）＝環阻塞的那個 handler，低層 state-change 全程照流。**
獨立佐證 §5-P 的簽名（`EventOFPStateChange` 10/10 而 links 空）與 frame dump 的 `entered=2/10`。

⚠️ **兩個 session 各錯一半，差點互相背書進報告**：我寫的「retry 迴圈第二輪」是錯的（**根本沒有
retry**，是兩個 handler 各通知一次）；他們的 2/10 數字對但**行號歸屬左右顛倒**（把截斷掛在
`:857`）。decorator＋marker 相鄰性才判得出來——見 [[cited-line-numbers-are-not-evidence]]。
`:831` 有一行註解掉的舊 `Switch entered:`，不計數。

**下一輪該做的不是調參，是刻意召喚**：失敗集中在 run 開頭（`FFFFSFSSFS`，連四敗，i.i.d. 60%
下 p≈0.13），而 12:23 那輪緊接在一整天 5-tuple／404 之後。**髒機器 vs 冷機器各跑一輪**。
召不出來之前沒有靶。⚠️ 未排除的干擾項：今天三臂都在 `systemd-inhibit` 下、基線那輪沒有。
⚠️ greenlet dump 路徑**仍未在真實 wedge 上跑過**（零失敗＝零 dump）。

## 🔴🔴 08-24 深夜召喚輪：**環召不出來，但 `settle=40` 被載重 8/8 打爆（而且永久）**

`doc/audit/2026-08-24_boot-ring-summon/`（`de49f21`＋`2c17dbd`）。「髒 vs 冷」先被我自己推翻
（teardown 實測乾淨、30 次循環召不出），真正分離兩個母體的是 **boot session**：wedge 全在
session −1（~67h uptime），機器 **08-24 16:46–17:01 重開過**，session 0 至今 **50 次開機零個環**
（含還原基線 commit 的 10 次）。67 小時造不出來 ⇒ 改打 frame dump 釘死的近因（walk 變慢→
128 格 buffer 填滿）＝ **CPU contention**，14 workers／14 cores、loaded/quiet **逐 boot 交錯** 8 對。

| 臂 | class | n | wall |
|---|---|---|---|
| loaded | `SETTLE-HOSTS`：`0/128`、288e/**256**d | **8/8** | 77–93s |
| quiet | `HEALTHY(-XX)`：`128/128`、288e/**0**d | **8/8** | 52–53s |
| 任一 | **`RING-WEDGE`** | **0/16** | — |

**三面一致「不是環」**：256≠288 down、`entered=10/10` 沒截斷、USR2 dump **零個**
`_events_sem.acquire`。（`7f7de4a` 首次在真實失敗上跑，給的是**否定**結果。）

🔑 **永久不是慢**：persistence probe 每 15s 取樣 20 分鐘、**t+609s 完全拿掉負載**——
**80/80 樣本都是 `0/128, 256d`，零恢復。拿掉成因不解除結果。**

🔴 **兩條新 open finding**：
1. ~~**`settle=40` 在 CPU 競爭下不成立**~~ 🔴🔴 **08-25 撤回：歸因是錯的。**
   `intelligent_router.py:975-989` 有每 10 秒的 host learning 進度追蹤，就在 16 份歸檔 log 裡、
   我一直沒讀。**16/16（loaded 和 quiet 都是）在 40s deadline 時都是 `0/128`，逐字相同**，
   包含八次最後 128/128 健康收場的 quiet。⇒ **settle gate 不是判別因子，它在每一次開機都逾時。**
   差異**完全在 gate 放棄、paths 裝完之後**：quiet 在那之後學到 128 台，loaded 學不到。
   **現象全部成立**（loaded 永久 0/128、12h 封存讀值），錯的是**掛在 settle 上**；
   而且「調高 settle 會改善」現在很可疑——**gate 已經在健康開機上逾時了**。
   正確措辭：**缺陷在 gate 之後那段 post-install host learning，不在 settle 值。**
   （原本要跑的 settle sweep 因此取消＝在調一個證據說沒接上的旋鈕。）
2. **`ndt` 這時候回報 `up. ready`**：`[4/4] verify` 數的是**邊的數量**（"128 hosts, 288 edges"），
   不看 up/down 也不看 host learning ⇒ **一個讓 twin 全盲的開機被回報成功**。
   **驗證面的缺陷，與預設值的缺陷要分開修。**

⚠️ **機制刻意留空**——🔴 **08-25 更正（`dd2ea62`，審查 S-1 促發、mainDev 自我推翻）**：
原版「loaded 學得更多 197 vs 93」**是錯的**——197/93 是 **log 行數**（該表每次 all-pair
install dump 一次、loaded 裝兩次），**distinct MAC 兩臂都是 128/128**；「3–4 vs 2 installs」
也是行數（start＋done 各一行），**完成數＝2 vs 1**（auditer 的 `install_all_pair_paths done`
才是對的量法）。存活且新量到的：**載重下 install 跑兩次、每次 walk 慢 ~5×**（1.207/1.190s
vs 0.239s），done: 行兩臂同為 hosts=128 pairs=16256 ⇒ 模型驅動 install 不受影響，壞的仍
**專屬 IPv4 association**（≠MAC→port）。取數指令已入 REPORT。**機制仍 open、仍不得引用
故事。**（normalized-diff 差點反向＋行數當 distinct＝同 session 第五、六次錯機制，都靠
「用數的」擋下。）

⚠️ **quiet 臂不純淨**：交錯讓每次 quiet 緊接在一次**失敗的** loaded 之後；2/8 出現 verify
transient（`0 up, 0 enabled` 但 128/128、288e/0d、轉發正常），而稍早 **30 次連續開機零次**
＝順序效應殘留。純淨基線用那 30 次。**交錯是拿順序效應換時間漂移，不可兼得。**
⚠️ ambient：`load1` 是滯後平均，workers=0 期間橫跨 1.43–17.11（前一次 loaded 的衰減），
**不能**刻畫 quiet 臂；硬保證是「每次 quiet 前斷言 worker=0」。

**環的處置：收櫃、證據留著。** 三個假說已死（`d1d973d` 修好／P4 殘留／CPU contention），
缺陷是真的但**沒有靶**，兩個修法都驗不了。長 uptime 只是 **n=1 的相關**，不是機制。
🔴 **08-25：這裡原本寫「下一格給 settle」，已作廢**——settle 歸因被撤回（見上），
**settle sweep 取消**。下一格＝**穿透整個開機期連續輪詢 `/v1.0/topology/hosts`**、
畫出 host learning 曲線、loaded vs quiet 交錯：gate 那個 10 秒取樣在 40s 就停了，
看不到 quiet 究竟何時、如何學到 128 台，**而那正是唯一有差別的區段**。

🔄 **08-24 深夜（auditer）：「髒 vs 冷」已被 mainDev 自己推翻並重設計。** 依據
（`boot_summon.sh` 檔頭）：6/10 的 wedge 全落在 **boot session −1**（08-21 21:14 →
08-24 16:46，~67h uptime），機器在 16:46–17:01 間**重開過**，之後同晚 30 boots（含基線
commit 還原臂）teardown 全乾淨仍召不出 ⇒ 變因是**長 uptime**、不是 P4/telemetry 殘留。
67h 製造不出來，可測的是 frame dump 釘死的近因（walk 變慢→128 格 buffer 填滿）⇒ 新設計
＝**CPU contention**：14 busy-loop worker、loaded/quiet **逐 boot 交錯** 8 對（防機況
漂移偽裝成處理效應——12:23 vs 18:00 就是踩了這個）、強制 plain defaults（帶 NDTWIN env
即拒跑）、每 boot 歸檔 ryu.log（N-1 的教訓）、cap 前先 USR2。位置
`doc/audit/2026-08-24_boot-ring-summon/`；**截至 20:56 已設計未開跑（raw/ 空）**。
Adam 三裁決（guard／async 都是「裁可、召喚輪後落」）見 [[review-round-2026-08-21]]。

⏱️ **Run 實況（mid-run 快照；已被上方「08-24 深夜召喚輪」節取代，數字以該節與 REPORT.md 為準；auditer 驗收見 [[review-round-2026-08-21]] ⑧）**：20:56 首發**死鎖、零 boot**（mainDev 自報：
`$(load_start)` 命令替換等背景 busy-loop 關 stdout——[[new-tools-are-the-first-thing-under-test]]
重演；機制待我對 script diff 驗）；21:2x PAIRS=1 smoke（`raw/smoke_*`，勿與正式 16 筆混算）；
**21:28 起正式 8 對 16 boots、L/Q 逐 boot 交錯＝全程零負載窗**。早期（≥3 boots）：loaded 臂
FAILED 87s＝**SETTLE-HOSTS 形狀**（hosts 0/128、288e/**256**d、entered **10/10 無截斷**、
dump 零 `_events_sem.acquire`）——**三判別全指「不是環」**；quiet_p1 52s 全健康。
🔴 **新 open：settle=40 在 CPU 競爭下不穩**（載重把開機拖到 87s、40s 窗在學到任何 host 前
到期→twin 對 128 台全盲）——正打在 §5-P「懸崖每格 n=1、選值依據弱」的自白上；guard 落地前
先問 settle 這格。⚠️ async 的 26s/52s **全量在閒置機器**，commit 措辭不得延伸到載重、也不得
宣稱它緩解 settle（未量）。ambient 誠實帳：quiet 臂實測 load1≈4（chrome 139%），報告寫
「實測 ambient」非「idle」。若 8 對全 SETTLE-HOSTS ⇒「順便在真靶驗 async」從工單劃掉。

**順帶推翻 review session 的 boot 8**：`CONVERGED wall=7626s` 是**筆電休眠**（`PM: suspend
entry 13:04:58`→`exit 15:11:07`＝7569s，raw mtime 在 resume 後 3 秒），不是 deadline 被繞過。
它是真的約 50s 收斂 ⇒ **6/10 仍是 6/10**（我一度算成 7/10，撤回），**也不是自癒的證據**。
機制見 [[arithmetic-that-fits-is-not-the-mechanism]] 第六例。

**Why:** bringup README §1b 曾判定「三者不可能都對」；其實是一個機制的三個設定值。

**How to apply:** ① 修 256-down 要嘛把等待改成「窗內主動 ping＋等學到再裝規則」（C3 的
方向，可行），要嘛讓 kernel 不依賴 Ryu 學到的 ipv4（`findVertexByMac` 不需要 IP）。
② out-of-band 刪規則永不被補裝（無 link event ⇒ 無 reinstall），是
[[rejected-requests-can-still-act]] 的路由表版。③ 任何「等 Ryu 學到 host」的邏輯放在
install 之後＝等到天荒地老。


## 🔴🔴 08-25 修法驗證輪：**兩個修法都對真靶測過了，兩個都不夠**

`doc/audit/2026-08-25_ring-fix-verify/`（`6f678fa`）。靶回來了才做得成
（曲線輪 uptime 17.48h、quiet 4/4 wedge）。4 對 8 次交錯、quiet-only、router 凍結 `d19020b1`
且跑前跑後外部驗 sha。

| 修法 | 切哪條邊 | 怎麼驗的 | 結果 |
|---|---|---|---|
| `d1d973d` | 邊 4（gate `get_all_host()` 無逾時） | 逾時**每次 wedge 觸發 ~41 次**（41/40/40/40） | **上場了，不足夠** |
| `72fbae6` | 邊 1（walk 在 enter handler 內阻塞） | **banner=1 ×2，仍 wedge ×2** | **上場了，不足夠** |

⇒ **§5-P 的「理論上切任一條邊環就無法閉合」被實測推翻。**

🔑 **這輪能有結論靠的是不對稱邏輯，值得記做方法**：比數污染了（基線 4/4 → 本輪 defaults 1/4，
靶中途衰退）⇒ **乾淨的 boot 一律不可歸因**。但**反例不受基礎率影響**——若 `72fbae6` 能破環，
banner=1 時就不可能 wedge，而它 wedge 了兩次。**「有效」測不出來、「無效」已證實。**
⚠️ 2/4 vs 1/4 **不可**讀成「async 更糟」（n=4，無統計意義）。

🔴 **uptime 單調性也死了**：**同一個 boot_id**，17.48h → 4/4 wedge、18.43h → 1/4 wedge。
一小時掉一半。「越久越 wedge」和「reboot 清掉它」都裝不下。倖存的只有 **reboot 邊界的相關**
（session −1 @67h 6/10；session 0 前 50 次零環）＋**session 內非單調、機制未知**。
**下一輪要先量當下 defaults 率再談歸因。**

🔬 **新線索（假說，未讀碼，不可引用）**：三份 dump 的 `reply_q.get()` 全落在
**`ryu/base/app_manager.py:279`**＝**無逾時 request-reply，在 Ryu 自己的 library**。形狀同
`d1d973d` 綁掉的那個但在上游、改不到。可能是**沒被算進去的第五條邊**，也解釋為何端點回
**HTTP 000** 而不是空 body。

⚠️ 審查 session 曾回報「timeout warning 零筆 ⇒ d1d973d 沒上場」＝**false negative**：他們 grep
變數名 `HOST_QUERY_TIMEOUT`，而它被內插成 `5.0`，那字串永不出現。已撤回。
**「上場了但不足夠」≠「沒被驗到」。**

**async 翻預設的措辭上限不變**：只能引「閒置 26s vs 52s ×10」，**不得宣稱破環**——現在不只沒
證據，是**有兩個反例在案**。


## 🔴 08-25 收官更正：**combo 其實已經測過了，而且我的措辭不精確**

寫「每日探針」腳本的第一步是確認 combo 會設成什麼組態，結果發現它**已經跑完了**：
`d1d973d` 的逾時**自該 commit 起就是預設開啟**，router 又凍結在含它的 `d19020b1`
⇒ **fix-verify 的 async 臂從來就不是「`72fbae6` 單獨」，一直是兩個一起。** 逐檔證據：

| boot | timeout warning | async banner | 結果 |
|---|---|---|---|
| `async_p3` | **40** | **1** | RING-WEDGE |
| `async_p4` | **40** | **1** | RING-WEDGE |

| 組態 | 結果 |
|---|---|
| timeout 單獨 | **不足夠** |
| **timeout ＋ async（combo）** | **不足夠** |
| async 單獨 | **未測且測不了**（要先 revert `d1d973d`） |

⇒ **已知修法組合用盡，combo 輪與探針取消**（`8ab0132`）。下一格是**機制工作**：
`ryu/base/app_manager.py:279` 的無逾時 `reply_q.get()`，**先讀碼**。

⚠️ 我先前寫「`72fbae6` 上場了、不足夠」**不精確**——被驗的一直是 combo。結論方向不變，
但「**哪個組態被測了**」必須說對。

**三個預設已落**（08-25）：guard `0.05→0.01`（`d807798`，只引 FP×6 全零＋3.9×）、
async `0→1`（`1b25cda`，**只引閒置 26s vs 52s，不得宣稱破環**）、R-1 notify 站點
（`f84f738`，main 上的繼承缺陷）。🔴 **async 翻預設改變了「plain defaults」的定義**，
且弄壞了 `ring_fix_verify.sh` 的 defaults 臂斷言（已加註、未改寫）。

## 🟢 08-25 PM：三站點機制（mainDev 讀碼＋sweep；審查 56-log 複算全符）——「修法用盡」措辭作廢

`get_topology_data` 下**三個**無時限 request-reply（HEAD／凍結 `52267aa`）：#1 `get_switch`
`:752`/`:713`、#2 `get_link` `:779`/`:740`、#3 `get_all_host` `:979`/`:915`（唯一被 `d1d973d`
包住）；`72fbae6` 的 spawn 在 `:851`＝#1/#2 **之後**，卡在 #1 永遠到不了。⇒ 兩修法合計只蓋
#3；**上節「已知修法組合用盡」僅指這兩個已實作修法的組合——#1/#2 從未被修，修法空間重開**。

**遷移實證**（56-log 全量表 `scratch/review-2026-08-25/sweep_replicate_out.txt`；P1=glk==ent
56/56）：wedge∧hto=0（修前）全停 #3（full-stack 2/2/2/2 ×9）；wedge∧hto=40+（修後）全停
#1/#2（walk、curve quiet×4、async_p3、defaults_p1＝#1；prev_spy1、async_p4＝#2）。零例外＝
「綁掉一站、卡點搬家」的打地鼠直接觀察。abort 線（`:757`）歷史 0 次，但**修 #1 之後它變可達
——P2 計數規則會把恢復讀成卡死，ring-edge-fix 輪判讀必須翻新（已告知 mainDev）**。

**一次 wedge 兩階段**（curve `wedge_111502` dump 全鏈 `:802→:1061→:969→:916→app_manager:279`）：
拍到時在 #3 spin——每次讀被 Timeout 彈回（hto 40×5s≈整個 settle 窗）＝**逾時擋住停車、擋不住
佔用**，佇列照樣填滿；末態計數才停 #1。設陷阱與彈陷阱是兩個時刻、同一次 wedge。

🔴 **佔用普查未完**：async 臂 walk 已離 handler 仍 wedge（async_p3/p4）⇒ 填佇列的不只 walk；
候選＝`:797` 每事件同步 notify（≤7s）、`:751` 20s 重試迴圈。三站表是「無界停車位」普查、非
「佔用源」普查。下一步＝`doc/audit/2026-08-25_ring-edge-fix/PREREG.md`（Phase 0 先量當天靶率、
qsize 儀器（自檢我複跑 PASS）、修法 A、BREAK/RELOCATE/FALSIFY 預註冊；審查意見已回）。
`.test_run` 現場 log＝async_p4／defaults_p4 本尊（prefix md5 驗證），無未歸檔開機。

**08-25 PM Phase 0 驗收（詳 review-round ⑰）**：靶率 **2/3** @20.09h、同 boot_id b8b44406 ⇒
單開機四點 4/4→1/4→2/4→2/3＝非單調決定版。e27283a 佇列普查首戰：**兩佇列同時飽和被直接
觀察**（IR 128/128 −12＋switches 128/128 −43/−18；被擋數＝acquire frames 整除吻合）。身分：
IR 側 12＝10 OF 連線 greenlet＋switches 兩迴圈；switches 側 43＝REST 卡 **send 步**（22 gsw
＋21 glk）⇒「switches 卡在塞 IR」升為兩觀察事實的推導、且 REST 也在把 switches 佇列塞滿。
修法 A 的 Timeout 要包整個呼叫（`:277` send＋`:279` reply，庫源碼已驗）。boot3 健康臂
host learning 128/128 正常。

**08-25 PM2 修法 A 首驗（詳 review-round ⑱）**：`cce9c5d` 把 #1/#2 包進真 deadline（helper
`_bounded_topo_read` 回 None 不丟例外；get_switch 迴圈改真預算；get_link 逾時中止本輪）。
同 boot_id 對照：**Phase 0 靶 2/3 → fix 臂 0/3、保真 3/3**；fixa1＝關鍵格：阻塞真的發生
（28 逾時全 (get_switch)、7 次中止**全走 :852 空清單出口**、link 出口 :897 **從未實跑**、
hto=24）而後**自癒**，twin 最終完整；**失明窗 ≈148s**（輪詢斷流後爆發補收）。🔑 機制再修正：
**twin 學拓撲靠 kernel 輪詢 REST（`GET /v1.0/topology/switches`），不靠推播**（六 boot 推播
全 ECONNREFUSED＝N-2 舊資料一致）⇒ 環的殺傷＝**餓死輪詢**（wedge 4 次後永默 vs 健康 23、
fixa1 26）。暫判 **BREAK**（N=3、≈3.7% 單尾；**無阻塞中 dump**＝最大缺口，建議 grab_dump
改首逾時觸發）；只宣稱「#1/#2 是當前環邊」；**佔用源普查仍未做**；🟢 **B 已實作＋驗證通過（`bfb0569`/`c986ca0`；不變量 159 stack 0 違規、保真 3/3、正控制 6/6）＝環章結案**；truncate/merge 開工中。


---

## 🟢 2026-08-25 下午：環結案（`8/25 mainDev`，審查員 `8/24 auditer` 全程對抗性驗證）

**全文在 repo：`doc/audit/2026-08-25_ring-edge-fix/REPORT.md`＋`PREREG.md`／`PREREG-B.md`。**
這裡只記「難以重新推導」的部分。

### 機制（已觀察，不再是推論）

環 ＝ **`switches` 與 `IntelligentRyu` 兩個事件迴圈的 2-cycle**，由 `EventSwitchEnter` handler
`get_topology_data` 底下的**無時限 request-reply**（`app_manager.py:279` 的 `reply_q.get()`）閉合。
三條互相獨立的腿同一答案：frames ＋ **佇列普查** ＋ log 計數器。

🔑 **佇列普查是本輪新增的儀器**（SIGUSR2 印每個 app 的 `qsize/maxsize` 與 semaphore `balance`，
**balance 負值＝有幾個 emitter 被擋住**）。它推翻了先前只推論出的一半：
**兩個佇列同時飽和**（IR 128/128 balance −12、`switches` 128/128 balance −43/−18，其餘四個 app 0/128）。
四類參與者全數指認：10 條 OF 連線＋switches 兩條迴圈塞 IR；REST handler（22+21=43）塞 switches。

**環的可見後果＝餓死 kernel 的拓撲輪詢**（wedge 開機只服務 4 次 `GET /v1.0/topology/switches`、
恢復的 26 次）⇒ 無修法＝**永久失明**；修法 A＝**失明 148 秒後完整恢復**。

### 「已知修法用盡」是反的

`get_topology_data` 下有**三個**無時限 request-reply：`get_switch`／`get_link`／`get_all_host`。
`d1d973d` 只修了第三個；`72fbae6` 的 spawn 在 `:851`＝**在 #1/#2 之後，構不到它們**。

### 🔴 兩個「文件裡的數字沒人量過」的實例（本節最值得帶走的）

1. **`intelligent_router.py` 環註解寫「LLDP 以 ~2.5/s 進佇列 ⇒ 128 格約 50 s 填滿」——實測
   `packet_in` ≈ **70/s**、**t_fill ≈ 1.8 s**，差 28 倍。** 那個數字是推導出來寫進註解，然後被
   後續每一輪引用。（08-25 Phase 5，`doc/audit/2026-08-25_ring-edge-fix/phase5_arrival_rate.txt`）
2. **guard `0.05→0.01` 只讓到達率差 1.22×，不是 5×**（57.8/s vs 70.5/s，n=2 每臂）。
   ⇒ **進 IR 佇列的 packet-in 大部分不是 LLDP**（table-miss 把所有東西送上控制器）。
   **這推翻的是那段註解假設的機制本身，不只是它的數字。**

⇒ **Adam 的 Q1「我們的加速有沒有把故障率推高」的答案**：兩個 guard 值的 t_fill 都是約 2 秒，
而阻塞時長是**數十秒**（settle 窗 40s、walk、通知鏈）⇒ **到達率從來不是限制因素。**
⚠️ **措辭上限**：這是「對量到的到達率做算術」，**不是量到的故障率**，
**不得寫成「guard 與環無關」**——後 B 的零壓力對 pre-B 的因果沒有否證力。

### 佔用源普查：第一份實證

Phase 4（guard 0.01 vs 0.05 交錯，B 之下，各 3 boot）：**兩臂 peak 佇列深度皆 0–1/128**。
⇒ **光靠到達率填不滿佇列，「被卡住的迴圈」（佔用）是必要條件。**

### 仍未做

**補 N**（A/B 皆 0/3，P(0/3|真實率 2/3)≈3.7%，是暗示不是結論）；
**完整的佔用源普查**（誰在正常情況下佔住迴圈）。
`get_link` 的時限 live 仍未觸發過，但**已由 `tests/python/test_topology_read_timeouts.py` 強迫執行**，
並推翻我原本的悲觀預測：**中止是「延後批次」不是「丟掉批次」**。
