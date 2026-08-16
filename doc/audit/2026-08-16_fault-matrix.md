# 故障矩陣輪(2026-08-16 傍晚)——判官補測序最後一項

> 三判官排序「並發對帳 > 寫入路徑 > 多速率 > 故障矩陣」的第四項,前三項均已於本日
> 關閉。Adam 表單核准;全自駕。**同時是 `faults.sh`(L5 注入層)的首次 live 出勤**
> ——按 [[new-tools-are-the-first-thing-under-test]] 的預期,前三個發現都是 harness
> 的,系統本體零缺陷。預測先行(scratchpad `PREDICTIONS.md`),各 case 的
> graph/paths/switch_state/ping/criteria 快照在 session scratchpad,關鍵數字載入本檔。

## 方法

fresh fabric+完整 stack。裁決三通道=`criteria.py` 法定人數(ping 雙向+paths+
counters,quorum 2 無異議)+我方 capture(graph edges_up、paths 數、6 對 ping、
switch_state 原文)。qdisc 全程快照護欄(43 行,前後必須相同)。對照組:每 case 附
未受害 pair 的 verdict。settle=30s(P4 自癒實測 12.5s+LLDP watchdog 15s 門檻,
faults.sh 預設 5s 會在癒合前裁決)。

## Phase A:faults.sh 目錄三型(首役)

| 型 | 結果 | 說明 |
|---|---|---|
| L-2 單向 loss100 | **PASS**(before/during/after 全 moving) | P4 重繞快過 settle,目錄的 mode 註記成立 |
| L-3 灰故障 30% | **PASS**(全 moving) | 偵測盲區照目錄記載成立——moving 是 FINDING 不是弱斷言 |
| N-4 SIGSTOP s5 | 首跑 FAIL(harness)→ 配置修正重跑:**全 moving,目錄 expect=still 被現實否決** | 見下 |

**N-4 的 live 答案(本輪最有價值的一筆)**:目錄原標 `expect=still` 且自註
THEORY ONLY。實測:凍結的 s5 停止發送也停止轉發鄰居的 beacon → **LLDP watchdog
15s 無 beacon 把 s5 全部 8 條有向鏈判死**(proxy log 實錄)→ 路由重繞經 s6 →
30s settle 時三通道全 moving;CONT 後路由自動收斂回 baseline(s1 的 10.0.0.2
→port1 實查)。「process-table 會說謊」仍真,但 beacon watchdog 根本不問 process
table。**目錄已改 `expect=moving`+完整註記(比照 L-2 的 mode 慣例),
test_faults.sh 的 N-4 佇列同步改,60/60 綠。**

**harness 首役的三個發現(工具的,不是系統的)**:
1. `FAULTS_KILL` 預設 `sudo -n kill` 在本機 sudoers 下要密碼 → 注入無聲降級為
   not-injected(與 header 記載的 FAULTS_TC 陷阱同類但未記載)→ header 已補:
   正解 `FAULTS_KILL="sudo -n mnexec -a 1 kill"`。
2. criteria 的 paths 通道預設打 Ryu :8080,P4 模式全程 unknown、法定人數無聲
   降為兩通道 → 這是**配置責任**(criteria.py 自己文件寫明 `PATHS_URL`,P4=:8081)
   ,faults.sh header 已補提醒。
3. 本 topo 的 veth 無 htb(attach point 全 root)——faults.sh 的活樹判讀正確處理,
   root 形式在此合法(它 header 對 shaped 介面的警告不適用本 topo)。
4. **同一個 kill 陷阱 20 分鐘後咬了本輪自己的編排器**:stage 3 的 B4/B5 用裸
   `sudo -n kill` 注入 SIGSTOP/SIGKILL,全部「a password is required」無聲未注入
   ——B4 實跑成 link-only、B5 等於沒跑,靠輸出裡的 sudo 錯誤行抓回來,B4'/B5' 於
   stage 4 以 mnexec 形式重做(見下表)。教訓:這陷阱的射程涵蓋剛寫完警告的作者;
   「injection failed 要讓 round 大聲失敗」faults.sh 有做(它標 not-injected),
   我的手動編排器沒做——手動注入也要斷言注入成功(`/proc/<pid>/status` 的 State)。

## Phase B:五個延伸型態

| Case | 故障 | 期中觀察 | 恢復 | 裁定 |
|---|---|---|---|---|
| B1 | s1↔s5 雙向 loss100 | edges 38/40、paths 12(已重繞)、6 對 ping 全通、h1h2 moving | 40/40、moving | ✅ 全中預測 |
| B2 | h1 雙上行隔離(4 qdisc) | edges 36/40、**paths 12→6**(h1 六對全撤回)、h1 ping 全 FAIL、h1h2 **still**、對照組 moving | 40/40、paths 12、moving | ✅ 完全隔離下 twin 誠實 |
| B3 | flap ×3(8s on/off) | — | 40/40、paths 12、moving、零殘留 | ✅ 無 wedge |
| B4' | s3↔s7 loss100 + SIGSTOP s6(跨區組合;`State: T` 實錘) | t+30s 快照=**重收斂中途**(9/10 switch、37/40 邊、4 個 ping 方向暫 FAIL);t+60s criteria 兩對全 moving | 40/40、paths 12、全通 | ✅ 雙故障最終自癒;**組合故障收斂 ~40-60s,比單故障(≤30s)慢**——本身是有用的量測 |
| B5' | SIGKILL s7(終端,無恢復;pgrep 確認死亡) | **9/10、32/40(s7 全部 8 條有向邊判死)、paths 12(全繞 s8)、全 ping 通、criteria 全 moving** | (不恢復,設計如此) | ✅ 終端死亡下 twin 誠實+零路徑損失,全中預測 |

附帶觀察(記錄不定論):+30s 時 kill 的 8 條邊全數已標(B5'),freeze 只標了 1 條
(B4',其餘在 +60s 前補齊)——kill 斷 TCP 讓 liveness 立即翻負、freeze 要等 beacon
逾時逐鏈到期,兩種證據通道的時間常數不同。settle 的實務含意:單故障 30s 夠、
組合故障要 60s 才到穩態。

qdisc 守衛:四個 stage 全數「43 行、與 baseline 完全相同」——faults.sh 的注入與
我的手動注入都零殘留。

## 結論

**判官補測序四項(並發對帳、寫入路徑、多速率、故障矩陣)於 2026-08-16 全部關閉。**
本輪矩陣:目錄三型(L-2/L-3/N-4)+五個延伸型態,**系統本體零缺陷**——twin 在
每種故障型態下誠實(邊/switch/paths 同步真實狀態、完全隔離時撤回廣告、終端死亡
時全繞路零損失),自癒全數發生。真正的收穫在兩處:①N-4 的 THEORY ONLY 被現實
否決並修行(凍結 switch 靠 beacon watchdog 15s 判死,process-table 的謊言不影響
它);②harness 首役四發現全數落檔修行(kill 陷阱補文件、PATHS_URL 提醒、
且同一陷阱 20 分鐘內咬了作者自己的編排器——注入後必須斷言注入成功)。

[Co-developed with claude code -- Adam]

[Co-developed with claude code -- Adam]
