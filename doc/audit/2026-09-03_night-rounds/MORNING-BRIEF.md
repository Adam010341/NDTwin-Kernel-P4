# 09-02 → 09-03 夜間：給 Adam 的交付

一頁看完；細節都指得到證據檔。**完整缺陷表在 `FINDINGS-ALL.md`，要你裁的在 `QUESTIONS-FOR-ADAM.md`。**
🆕 **68 條誰在修、誰沒人修，在 `FINDINGS-COVERAGE.md`**（12:4x 補；下面「中午補的四件」有摘要）。

## 數字

- **68 條確認缺陷**（有證據檔、有對照組、說得出重現方式；假設與待查不計）。
- **6 輪整機測試**，一輪接一輪跑（只有一座 lab），共 **178 份編號 log**，全部入庫。
- **第六輪把十個「歷史 bug 形狀的未檢驗實例」全數判定：兩條新缺陷、三條中度、六道門關掉。**
- **16 支修法進 trunk**、**8 支行為變更留在分支**等你看 diff。
- **每一支修法都有變異閘門**，而且今晚有 **6 個假綠是被閘門攔下來的**——沒有一個是讀碼看得出來的。
- **今晚一個 commit 都沒推**（一個例外，見文末）。

## 中午補的四件（12:2x–12:5x，離線，沒有碰實驗室）

1. 🏁 **兩支分支同一個指標的糾纏解開了**，兩支的變異閘在新 sha 上都重跑過。細節見下一節。
2. 🆕 **`FINDINGS-COVERAGE.md`**——68 條逐條標狀態：**✅ 已進 trunk 9 條／🔧 在分支上 18 條／⭕ 沒有人在修 39 條／➖ 非缺陷 1 條／❓ 判不出 1 條**。
   **今天真的派得出去、能拿到完整交付的只有三件**（其餘要嘛已經有人做、要嘛要實驗室）：#63 `--logfile` 是 boolean 不吃路徑、#50 `ndt:1687` 的 `2>/dev/null` 位置、#42 那個「100% loss 卻印三個 OK」的 banner 半邊。
3. 🔴 **那張表推翻了三件既有記載，三件我都自己重跑過**（`AUDITOR-VERIFICATION.md` 最後一節）：
   - **`fix/g6-ndt-apps-liveness` 沒有修 viz 孤兒（#6／#48）。** 分支上 `app_spawn` 仍沒有 `setsid`、沒有自己的 process group，stop 仍只殺單一 pid。它改善的是**存活回報**，不是**停止**。⇒ 那條嚴重缺陷目前**沒有人在修**。
   - **`fix/telemetry-health-visible` × `fix/flow-rate-denominator` 在 `FlowLinkUsageCollector.hpp` 硬衝突**，而**沒有任何審查頁提過**。兩支都要併就得先決定誰先。
   - **`fix/d15` × `fix/b5` 只衝 `tests/CMakeLists.txt`**；`6ad6811b` 預告的 `DeviceConfigurationAndPowerManager.cpp` 衝突實測不存在。
4. 🆕 **`tools/build_guard/`**——09-02 那次 `systemd-oomd` 連你的 app 一起殺掉的東西，現在有護欄了。這個 repo 有 **23 個呼叫點寫死 `-j$(nproc)`（在這台是 `-j14`）或 `-j4`**，而其中好幾個是變異閘的 anchor，改它們會讓那些閘門靜靜停止檢查 ⇒ 做成 **PATH shim，一個呼叫點都不用改**。三道：shim 壓平行度、`flock` 一次只跑一個、cgroup 給明確的 `MemoryMax`（**保護你的 app 的是第三道**）。
   閘門：37 個 check、**10 個變異 0 存活**；真的 CMake 專案端到端驗過（`-j14` 到 ninja 手上變 `-j2`、configure 沒被動、`MEM_MAX=200M` 真的變成 cgroup 的 `memory.max=209715200`）。
   用法：`tools/build_guard/guarded_build.sh <任何會編譯的指令>`。

## 修法現況（09-03 上午這批，10:00 之後）

七支修法 agent **全部落盤**：四支的閘門我自己重跑過、兩支從未編譯過的我編了並跑出結果、一支自己做完 hunk 過濾後交付。
不是採信 agent 的自陳（`AUDITOR-VERIFICATION.md`）；一頁一支的審查頁在 `FIX-BRANCHES-FOR-REVIEW.md`。

| 對應上面第幾件 | 分支 | 閘門（auditor 重跑） | 還缺什麼 |
|---|---|---|---|
| **第 1 件** 路由不確定 | `fix/deterministic-path-tiebreak` | 5 mutations, 0 survived | 沒有 live 的十次 bring-up 確認 |
| **第 2 件** 的「看不見」那一半 | `fix/telemetry-health-visible` | **auditor 編後 17/18** | agent 死亡→我救援；原本**編不過**，修好後紅在一個沒有任何綠測試在約束的帶寬邊界 |
| **第 3 件** bmv2 liveness 競態 | `fix/d15-dataplane-kind-race` | **auditor 編後 3/4** | 紅的**不是修法是測試**（漏掉 `manager->start()`）；🔴 **要先併 B-5 才關得起來**；4 列回歸仍全未跑 |
| 夜巡重複五次的殘留形狀 | `fix/ports-that-block-restart` → `2fe70075` | 9 mutations, 0 survived（**解糾纏後重跑**） | 🏁 `100644` 已改成 `100755` |
| P4 priority 靜默丟棄 | `fix/p4-priority-not-silently-dropped` → `4c5a92da` | 7 mutations, 0 survived（含四個反向，**解糾纏後重跑**） | 未經 live |
| 拓樸檔壞掉才發現 | `fix/topology-load-fails-before-listen` | 29 tests ＋兩向對照 | 🔴 **C++ 半邊未編未跑** |

🏁 **那條「兩支分支同一個指標」的糾纏已經解開**（12:2x）：ports 三顆 rebase 到 trunk（`2fe70075`）、
p4 priority 單獨 cherry-pick 到 trunk（`4c5a92da`），交集 0 顆 commit，兩支的變異閘在新 sha 上都重跑過
（9/9、7/7，baseline 都 byte-identical）。舊鏈用 tag `pin/pre-untangle-2026-09-03` 釘住。**沒有推任何東西。**
細節與新舊 sha 對照在 `FIX-BRANCHES-FOR-REVIEW.md` 前言第 1 點。

🔴 **第 2 件的低報本身沒有人在修。** `fix/telemetry-health-visible` 修的是「所有健康訊號都說正常」，
不是 2.76 倍那個數字——**成因還沒釘到單一行，現在派修法會是猜。**

🏁 **兩支從來沒被編譯過的，我編了，而兩支的結果都推翻作者的預測**（`AUDITOR-VERIFICATION.md`）：
D15 預測 4/4，實得 **3/4**——但紅的是測試不是修法（它漏掉 `main.cpp:432` 的
`manager->start()`），而且**要修好它得先併 B-5**，否則測試會在解構時 `std::terminate`。
Telemetry 那支**根本編不過**（少一個 `sflow::`），修好後 **17/18**，紅在一個
**沒有任何綠測試在約束**的帶寬邊界（剛好 10% 的丟失率）。

🔑 這兩件事只有把它編起來才會知道。**「寫好了但沒跑」與「跑過而且綠」之間，隔著兩個真缺陷。**

🔴 **這批沒有一支起過 fabric。** 實驗室整晚在跑測試輪，修法全部停在離線／單元層。
每一支的「未經 live」都是**合併條件的缺席，不是加分項的缺席**。

🔴 **一件我造成的事故**：共用工作樹的 HEAD 被其中一支 agent 用 `git checkout -b` 移走，
之後兩個 agent 的 commit 就落在那條分支上——三個作者的 commit 疊成一條。
**沒有東西遺失**，827 行的審查頁已經用 fast-forward 收回 trunk，剩下的拆法寫在
`FIX-BRANCHES-FOR-REVIEW.md` 前言第 1 點，**要動到已 checkout 的分支，等你點頭**。

## 你醒來最該先看的三件

### 1. 🔴 同一個實驗跑兩次，數字不一樣，而檢查它的端點看不見

同一個指令、同一個拓樸檔、每次都從驗證乾淨的機器起——**8 次 bring-up 產生 4 種不同的全網路由表**。
帶相同流量時 s3 走 s7／s8 **4:4 對分**，那條鏈路公布的使用率取五個不同值。
**而 `/ndt/get_path_switch_count` 這 8 次逐位元組相同**——研究者用來問「路徑變了沒」的端點只回跳數，
結構上看不到這件事。

成因已釘死並**離線重現**：`topology_manager.py:784` 的 `nx.shortest_path` 是 BFS，該對主機有 **8 條等長最短路**，
平手由 `nx.DiGraph` 的**插入順序**決定，而插入發生在十條並行 gRPC 收包執行緒上。
**修法是加確定性 tie-break（排序），不是同步問題。**

> 這是一個研究工具最壞的缺陷形態：數字不可重現，而且用來檢查的儀器看不見它。

### 2. 🔴 高負載下分身低報 2.76 倍，而所有健康訊號都說一切正常

同一條 20 Mbit/s、線上**逐位元組零丟失**的 flow（`0/98213`），twin 報 19.69 → **7.14** → 20.67 Mbit/s，
中間那格是併行灌 54 萬 datagram/s 的時候。同時：每個 endpoint 都回 200／`success` 而且**比對照組還快**、
三個窗口全程說 `active` 30/30、`avg_link_usage` **反向上升**。唯一痕跡是 33 行 WARN。
**不是 CPU 飢餓**——已知的無分母偏差會讓數字變大不是變小。

附帶量到的界線：**一條完全送達的流會從 API 預設窗口消失，而界線的單位是 pps 不是 bit/s**
（≥5 Mbit/s 全中；2 Mbit/s／179 pps 開始分歧；**250 kbit/s／22 pps 跨過 50%**；鎖死頻寬只縮封包可見度就回到 1.00）。
文件與宣稱都用 Mbit/s 表述，可移植的講法是 **~22 pps**。

### 3. 🔴 一個啟動競態，在任何出貨用的拓樸檔上是 100% 輸

`refreshDataPlaneKind()` 比 topology 載入早約 1 ms、而且**只算一次** ⇒ **bmv2 的 liveness 路徑從不執行**
（整輪 proxy log 裡 kernel 發的 `GET /p4/switch_state` 是 **0 次**）。
60 次冷啟動：310 B 贏 5/8、587 B 贏 5/8、**7.8 KB 以上 0/44**（出貨檔 0/20）。
60 次**稍後**都印 `All-bmv2 topology`，所以輸的是**時序不是拓樸**——**修法只能是排序／同步，把載入變快沒用。**

它是好幾條的根：電源狀態端點回報「下過的指令」而不是量測（兩台同樣死透的交換機，被命令關的報 OFF、
自己死掉的報 ON）；電源 API 兩個方向都靠 `isUp` 提前 return Success；一台被 kill 的交換機 **7.5 分鐘後**
twin 仍報 `is_up=True`。

## 一個貫穿整夜的形狀

同一個形狀今晚出現了 **五次**，每次都是獨立發現的：

> **殘留檢查涵蓋的是「容易指名的 port」，不是「會擋住下一次啟動的 port」。**

`cmd_clean` 與 `deep_sweep` 迭代的都是 `8000 8080 8081`。而 **bmv2 的 `:3005x`**（只出現在一行註解裡）、
**Ryu 的 `:6653`／`:6633`**（`ndt` 裡 0 次）、**sim 的 `:9000`**（`ndt`／`stack.sh` 各 0 次）、
**sFlow 的 `:6343`**（兩者皆 0 次）——沒有一個會被任何工具看到。
`:6343` 那個當場咬人了：一個 tester 沒啟動過的 kernel 佔著它、擋掉合法操作，而 **`ndt down` 的五條斷言全部回綠**。

**「哪個 port 會擋住下一次啟動」這個知識存在，但它只活在四行註解裡——註解不會被執行。**
修法已定調為做一張宣告式的表（port、屬於誰、佔住它的後果），不是各補一個 if。

## 修法狀態

**進 trunk（16 支，皆有閘門）**：測試計分器把五個全綠套件記成失敗、anchor 檢查器有四個閘門根本沒在檢查
（含 A-9 判定 RESOLVED 的**全部**證據那支）、iperf3 守衛自我毀滅後回報乾淨、chaos `_c07` 控制組零鑑別力
（含撤回一條建立在它上面的已發表宣稱）、`run_layers.sh` 用錯拓樸模型、drift 掃描不認得 `utils::pathIs`、
`lib_e.sh` 還原檢查零鑑別力、preflight 的 claim 判定、登記簿三處過期段落等。

**留在分支等你看 diff（8 支）**：`fix/g6-ndt-apps-liveness`、`fix/g9-cleanup-no-pkill-f`、
`fix/g7-ndtwin-lab-config`、`fix/b5-kernel-shutdown`、`fix/flow-rate-denominator`、
`fix/l9-make-topology-stdout-json` 等。每支附 `RATIONALE.md`（問題、修法、行為前後對照、閘門紅→綠、回退方式）。

⚠️ **`fix/b5-kernel-shutdown` 我原本歸類低風險、後來收回**：量到修好之後 SIGINT 的關機在忙碌時要 **81 秒**
（72 秒卡在新加的 join 裡，因為 openflow worker 只在輪與輪之間檢查停止旗標）。
修法前 Ctrl-C 立刻崩潰、修法後可能等 81 秒——**兩個都不好，而後者是使用者看得到的改變**，所以整支留給你。

## 沒推的東西，以及為什麼

**今晚 trunk 一個 commit 都沒推。** 論文線的 `dff0976d`（fig5b）在**它自己的 session 被權限分類器擋下**，
而它已經在 trunk 上——我一推就等於替另一個 session 執行它被拒絕的動作，所以整批停住。
**唯一推出去的是 `audit-raw`**（`lab` 與 `p4` 都到 `1b2da033`）：我推之前逐一看過，1 個 commit、30 個檔、
全部在 `doc/audit/` 底下，與那個被擋的 commit 無關。origin 全程沒碰。

**要你放行**：見 `QUESTIONS-FOR-ADAM.md` 的 N5。

## 順帶完成的

- 安裝手冊 **run-04 通關**（照你定的四條判準逐一對）——細節與「要不要把零干預加進判準」的問題在 Q14。
- 論文線 fig5b 完成（三欄改判、拆出 `second plane measured` 17/34、砍掉一欄收案準則），閘門見紅、待推。
- 兩份既有結果的絕對數值已標作廢（措辭區分**「數字錯」與「發現錯」**——08-27 那輪的結論成立，
  因為它承載的是「逐位元組相同」，而一致的倍數不改變兩次讀數是否相同）。

## 一則對我自己的更正

我在整夜的共同 brief 裡告訴每一輪：「每條流速率缺分母，**它餵給 top-k 排序與大象流分類**」。
第六輪查出**兩個 elephant flag 是唯寫的**——1 個宣告、6 個賦值、**全樹 0 個讀取**，也不在端點的 15 個 key 裡。
⇒ **門檻比較確實是錯的，但那個誤標目前沒有任何下游消費者**；我那句話只有前半成立。
已在 `FINDINGS-ALL.md` 就地更正而非刪除。

[Co-developed with claude code -- Adam]
