# 待辦工作項目

Adam 交辦、但還沒有 session 在做的事。**這個 build 沒有 `TaskCreate`／`TaskUpdate`**（工具集裡不存在），
所以待辦放在這裡，不放在某個 session 的腦裡——那樣 Adam 看不到，session 一結束也就沒了。

一件事開工之後，把它從這裡移到它自己的分支／文件，並在這裡留一行指過去。

[Co-developed with claude code -- Adam]

---

## W-1 — 在 NDTwin 上跑 p4lang/tutorials 的 exercise 1–5

**來源**：教授交辦，Adam 2026-09-03 轉達，並指定「你自己決定什麼時候做」。

**材料已經在機器上**：`~/tutorials`（p4lang/tutorials，13 個 exercise）。不需要重新 clone。

### ✅ Adam 15:xx 已釐清（原本的兩個問題都答了）

- **「1–5」＝五個主題群，共 13 個 exercise**，沒有期限。
- **目的不是跑 tutorial**：教授知道那只是量 p4lang 的東西。要測的是 **NDTwin 能不能在不同的 `.p4` 檔下正常橋接它們的 p4info**。
- 分析（auditor 15:xx）：我們的 `ndtwin_switch.p4` 的 `ipv4_lpm` 就是 p4lang `basic.p4` 那張表加 `send_to_cpu`，proxy 寫死查
  `MyIngress.ipv4_lpm`。⇒ **8 個 exercise**（basic／ecn／qos／mri／firewall／link_monitor／basic_tunnel／p4runtime）路由橋得過去、
  但**沒有 CPU port／`send_to_cpu`／clone session** ⇒ LLDP 與 sFlow 全滅——要測的是 NDTwin 會說「看不到」還是回報一個健康的空網路；
  **5 個**（flowcache／calc／load_balance／multicast／source_routing）連 `ipv4_lpm` 都沒有 ⇒ 第一個量測：proxy 在 p4info 找不到表時做什麼。
  建議順序 `source_routing`（沒有表，最快炸）→ `basic`（基線）→ `flowcache`（與 idle-timeout 已知缺陷重疊）→ `p4runtime`（參照 controller）→ 其餘。

### （原問題留底）「1–5」是哪五個

`~/tutorials/README.md` **不是平面編號**，它分成四個主題群。照 README 由上而下取前五個是：

| # | exercise | 主題群 |
|---|---|---|
| 1 | `basic`（Basic Forwarding） | 1. Introduction and Language Basics |
| 2 | `basic_tunnel`（Basic Tunneling） | 1. 同上 |
| 3 | `p4runtime` | 2. P4Runtime and the Control Plane |
| 4 | `flowcache` | 2. 同上 |
| 5 | `ecn` | 3. Monitoring and Debugging |

⚠️ 教授說的「1–5」也可能是指**第 1 群到第 5 個主題**、或課程投影片自己的編號。
**開工前先跟 Adam 確認一次**，這是唯一會讓整件事白做的分歧。

### 🔴 開工前一定要知道的四件事（不要重新踩一次）

正本：記憶 `p4lang-tutorials-as-local-control.md`（2026-08-13 實際用過）。

1. **exercise 目錄裡的 `.p4` 是編不過的填空骨架。** 完整版在各自的 `solution/`。
   要「跑起來」用的是 `solution/`，要「當練習做」才用骨架。
2. **教學拓撲（2–4 台）與我們的 topology JSON 不相容。** 這是整件事最大的一個決定，見下。
3. **它的 `utils/p4runtime_lib/` 對 bmv2 會卡死**：`MasterArbitrationUpdate()` 等回應，
   而 bmv2 對重複 election id 是直接殺 stream ⇒ 永遠等不到。要繞過它的 stream 封裝手寫低階 gRPC。
4. **它需要 `p4.tmp`，我們的 venv 沒有**——用 `/home/adam/p4dev-python-venv/bin/python`。

### 要 Adam 裁的：「在 NDTwin 上跑」是哪一層

這句話有兩個差很多的讀法，成本與產出都不同：

- **(a) 只跑 bmv2 管線本身**：用 tutorial 自己的 `make run`／Mininet，我們只提供機器與 bmv2 build。
  便宜、幾乎一定跑得起來，但**沒有用到 NDTwin 的任何東西**——證明的是工具鏈能用，不是孿生體能用。
- **(b) 讓 NDTwin kernel 管理它們**：要把每個 exercise 的拓撲翻成我們的 topology JSON、
  接上 p4_proxy、讓 kernel 認得那些 pipeline。**這才是有意義的那個**，但每個 exercise 的
  pipeline 不同（不同 table、不同 action），我們的 proxy 目前只認 `ndtwin_switch.json` 的表結構。
  ⇒ 這是一件**每個 exercise 都要單獨接線**的工作，不是跑五次同一個腳本。

**我的建議**：先做 (a) 把五個都跑通並存下 raw（成本低、而且是 (b) 的對照組——
沒有 (a) 的話 (b) 失敗時分不出是我們的問題還是 exercise 的問題），
然後只挑 **`basic`** 做 (b)，把「接一個外來 pipeline 進 NDTwin 要做哪些事」寫成一份可重複的清單。
五個都做 (b) 之前先讓 Adam 看那份清單的成本。

### 需要實驗室

(a) 與 (b) 都要起 Mininet／bmv2 ⇒ **不能在 Adam 需要實驗室的時段做**。開跑前 claim。

---

## W-2 — finding #6／#48：`ndt apps stop` 停不掉 viz（✅ 修法已進 trunk `94abfb3f`；真 app 未驗）

2026-09-03 13:1x Adam 本人現場撞到：`ndt apps stop` 之後 visualizer 仍在跑。
**`fix/g6-ndt-apps-liveness` 不修這個**（已查證，見 `AUDITOR-VERIFICATION.md`）——
它改善的是「回報有沒有在跑」，而 `app_spawn` 仍是 `( cd "$dir" && exec nohup "$@" ) &`，
**沒有 `setsid`、沒有自己的 process group**，`app_stop` 仍只對單一 pid 送 TERM。

修法形狀：`app_spawn` 加 `setsid`（或 `systemd-run --user`），停止時殺**整個 process group**，
並且停止之後用**獨立管道**確認（`/proc/<pid>/fd` 反查誰開著它的 log，比 pidfile 可靠）。

🔴 **連帶**：`.test_run/logs/app_viz.log` 在 09-03 長到 **364 MB**（每一幀一行 DEBUG），
根目錄一度到 98%。09-02 同一個機制長到 875 MB 塞爆磁碟。**log 要有上限**，這是同一張工單的一部分。

### ✅ 19:1x：已進 trunk `94abfb3f`（`fix/apps-stop-kills-the-group @ 850a6ea8`）——下面五條殘留仍然成立

- **做了**：`app_spawn` 走 `exec setsid nohup`，啟動後讀 `/proc` 驗 pgid==sid==pid 並寫 `.pgid`；`app_stop` 先 `kill -TERM -<pgid>` 整個 group、再補個別 pid、再補「log 的可寫 fd 持有者」找到的殘存；
  「停掉了」要過 `app_verify_stopped`（group／log fd／port 三管道皆空），看不到的管道明說「不是沒有，是沒看到」（rc 2）；
  `apps orphans` 用同一組管道（09-02 那個狀態從 rc 0 變 rc 1）；log 改 `>>`、兩代輪替、`status` 印大小＋256 MB 轉黃、新增 `ndt apps trim`。
- **證據**：測試 71 checks（修法前 45 紅）、閘門 13/0（8 缺陷向＋5 放寬向控制組，含「對自己的 group 送訊號」）；auditor 丟棄式樹重跑：71/0、鄰居 52/44/29 全綠、兩支閘門在跑。
- **🔴 沒做／要接的**（可另開工單）：
  1. `energy`／`sim` 走 `ndtwin-lab` 的 tmux，**沒有自己的 group**（要改 root 端 `ndtwin-lab`），這次只加了停止後的獨立驗證（含 sim 的 `:9000`）。
  2. **沒在真 app 上跑過**（viz 要顯示器）；最便宜的真機驗證是 `ndt apps start sim` → `stop`，順便驗 `:9000` 管道——要一段有實驗室的時間。
  3. log **沒有硬上限**（只有輪替＋警告＋手動 `trim`）；理由寫在 FIX-APPS-STOP §6.1（中介行程會弄壞 fd 管道）。
  4. `ndt down` 仍把 `app_stop` 的輸出丟到 `/dev/null` ⇒ 殘存者名單不進 teardown log。
  5. `apps orphans` 新增 rc 2，呼叫端（`||` 閘門）沒有盤點。

---

## W-3 — finding #3：失敗的 `ndt up` 不回滾（沒有人在修）

`ndt up ovs4` 失敗後 Ryu（:8080/:6633/:6653）、tmux topo session、15 個行程／36 條 veth 全留著，
而沒有 kernel。`:8000` 被佔用的檢查在 `stack.sh` 的 [3/3]，**在 fabric 建好之後**。
證據：`round1-ovs/02_ndt_up_failure_leaves_fabric_running.log`（對照組 `03_`）。
同事線把它列為 BUG-3，未查證。需要實驗室才驗得完。

## W-N11 量測：一條規則裝進 bmv2 要多久（對帳 rule journal 的 6.37 ms fsync）

Adam 裁（09-03 21:1x）：journal 現況不動，先量。要量的是 REST `/stats/flowentry/add` 一筆從進 proxy 到 gRPC table write 回來的 per-rule latency（bmv2、`ndt up p4 4`），與 `RuleJournal.record` 的 6.37 ms（`RED_before`＝stub fsync 0.027 ms）並列；若 gRPC write 本身 ≥ 6 ms，fsync 的 150 rules/s 上界不是瓶頸、N11 ①結案；若遠小於，再回 N11 裁批次 fsync。要 lab（P4），排在 #77／#8 兩支之後；raw 進 audit-raw；報告寫進 `doc/audit/2026-09-03_fix-rule-journal/` 的補記或新 dir。狀態：⭕ 未派（09-03 21:1x）。

## W-Q12 `is_up` 拆成 `admin_state`＋`reachable`（✅ 已併 trunk `147c5ad1`，MERGE-LOG 38）

Adam 裁（09-03 21:1x）：(a)。派 `fix/is-up-split-admin-state-reachable`。狀態：🛠 派工中（09-03 21:1x）。

## W-27b — finding #27 的下半：`FlowLinkUsageCollector::stop()` 接上同一個 `StopSignal`（Adam 09-04 裁：今晚測完派；⭕ 未派）

`fix/kernel-stop-is-bounded` 併入後，行程層級的關機是 **4.70 s**，其中 **4.607 s** 在 collector 的 `stop()`（`refreshDestinationPathsPeriodically` 的 `--max-time 10` curl 與 `testCalAvgFlowSendingRatesRandomly`／`purgeIdleFlows`／`calAvgFlowSendingRatesPeriodically`／`calFlowPathByQueried` 四條沒切片的 1–2 s sleep）。照抄同一個原語（`WorkerScope`＋`waitFor`＋`execCommandCancellable`）即可；做完才能對外承諾 3 s。stop agent 建議現在就派（N20 Q1 建議 (b)）。前提：`FlowLinkUsageCollector.cpp` 今晚有別的分支在動的話先等它們併完。

Adam 裁（09-04 14:0x，N20 Q1）：(b) 今晚測完派；兩支併完對外承諾 3 秒，在那之前文件寫「行程 5 秒」。

## W-GATE-LOCK — C++ 變異閘門整輪持鎖，餓死其他 agent（⭕ 未派，工具層）

09-04 凌晨實測：一支 C++ 閘門在 `guarded_build.sh` 的**單次持鎖**內對每個 mutant 重編（-j1、動到 `GraphTypes.hpp` 的每個 mutant 重編大半棵樹），連續持鎖 1 h 33 m；同時 7 個 waiter，delgroup 的 configure 排 76 分鐘沒拿到、noip 也停下等。`LOCK_WAIT` 預設 3600 s 讓排隊者直接放棄（已改 verify 腳本預設 10800）。**改法候選**：閘門對每個 mutant 各自取放鎖（`build()` 包一層 guard，而不是整支腳本包一層）；或 guard 加公平佇列（ticket）。代價：每次取放鎖多幾秒；好處：多 agent 之夜不再餓死。要 Adam 點頭再動 `tools/build_guard/`（它是 09-02 為了保護 app 加的）。

## W-LOGS-TO-AUDIT-RAW — trunk 上 09-03 起的 1,049 個 log／證據檔搬去 `audit-raw`（Adam 09-04 裁 (b)；⭕ 今晚測完做）

`doc/audit/2026-09-02_manual-usertest/**/logs`、`**/tester-files/logs`、A-12 的 `evidence/`（`8baf9074`、`69bd66c1`、`f6158e8a`、`47c6cb1a`、`1cf1556f`、`64602876` 等，共 12.9 MB／約 330 個 .log/.txt/.err＋夜巡 round 1–6 約 150 個）→ `audit-raw` 同路徑（temp-index 法，逐檔 sha256 對帳），trunk 上 `git rm`（**列到檔案，不用目錄 pathspec**）。不改寫歷史（p4／lab 已有）。**做完才解凍 push。**

## W-GROUP-INSTALL-MODIFY — install／modify group/meter 與 #1 同型（FINDINGS #87；Adam 09-04 裁：測完開工單）

同一套「先讀回再宣稱」接到 `install_group_entry`／`modify_group_entry`（meter 同）；會動既有回應契約 ⇒ API 文件 `doc/2026-01-02_ndt_api.md` §33 一併改（該節現在叫使用者去看一直是空的 kernel log）。

## W-OF-BARRIER — 幽靈 flow 修法之後的 OpenFlow barrier（N22 Q5；Adam 09-04 裁：先不做）

#2 修完，OVS 上剛 `install_flow_entry` 的列要等下一次輪詢（3–13 s）才進 `get_*`。**今晚整機測試量到的延遲＝這張工單的 BEFORE。** 候選做法：install 後送 barrier 再讀回；動到 Ryu 的呼叫方式與南向驗證路徑，需要一輪 live A/B。

## W-GATE-ANCHORS-HEREDOC — 三支閘門 anchor checker 讀不到（N14 Q4；⭕ 未派，工具層）

`mutate_ndt_up_target.sh`、`mutate_g7_ndtwin_lab_config.sh`、`mutate_g9_cleanup_no_pkill_f.sh` 回 NO-ANCHORS（heredoc 寫法；#19 的修法沒涵蓋這個形狀，ndtcheck agent 也撞到）。改閘門寫法或教 `tests/shell/check_gate_anchors.py` 讀 heredoc，二擇一；判決不得變。

## W-RC3-AGGREGATE — `ndt status --check` 的 rc 3 與新閘門接進彙總跑批（N15 Q4＋N17 Q4；⭕ 未派）

目前沒有任何呼叫端讀 rc 3（三態只有人眼看得到）；`mutate_ndt_up_down_robust.sh` 也沒進 `local_ci.sh`／`l1_unit_tests.sh` 之類的彙總。一張工單一起做。

## W-TOPO-THREE-DOORS — 拓樸輸入驗證的其他三扇門（N18 Q3；⭕ 未派，isup 已併可派）

`GraphTypes.hpp` 的 `from_json`（不是檔案載入路徑）、`ecmp_groups[].port_id`、node 迴圈裡三個「加了一部分 vertex 才 throw」的半套用。連同 FINDINGS #89（檢查器知道、kernel 不知道）。

## W-EXECARGV-EXPECTED-NONZERO — `utils::execArgv` 對預期中的非零 status 仍印 `Command failed (exit code 2)`（N19 Q3；⭕ 未派，小）

每次對已不在的 bridge 關機都會先印這行誤導、再印正確的 INFO。**今晚 kernel log 會看到，不是新缺陷。** `Utils.hpp` 共用，等今晚分支都併完再改。

## W-INV01-LATENCY-LIVE — 把 INV-01-latency 真的量一次（N16 Q5；⭕ 未派，需要 P4 窗口）

claim → `ndt up p4 4` → 關 s1 → `--power-ip 192.168.123.11 --null`；那會是這個檢查存在以來第一次量到真的 power-on。跟 W-N11 同一個 P4 窗口做。

## W-DOCS-NDT-NTG-AND-MANUAL-TOPO — 兩處文件（N14 Q2＋Q5；⭕ 未派，純文字）

① `ndt ntg cli|prompt` 的說明改成「只對手動路徑有效」（`ndt up ovs` 現在落進本 repo 那份的 `CLI(net)`）；② 手冊的手動路徑改成叫人跑本 repo 的 `testbed_topo.py`（#84：NTG 那份靠一個沒 commit 的編輯），不動 NTG。

## W-OVS-MAY-EXIST — `add-br`／`add-port` 改 `--may-exist` 讓 bring-up 真正冪等（N19 Q2；Adam 裁：測完再議）

動到既有成功路徑（今晚會走），所以今晚之後。

## W-ADMIN-POWEREDOFF-CLEAR — `ndt up` 開場清掉所有 `adminPoweredOff`（N19 Q4；⭕ 未派）

OVS 的 bridge 名在 `ndt down` 後會重用；對「不存在的 bridge」關機現在回成功並記命令，同名 bridge 稍後被別人重建時那道命令仍掛在同一 vertex（要 power-on 才撤）。跟 #8 的 `up.target` 一起想。

## W-APPS-LIVE — 四個外部 app 對著跑起來的 kernel 用一次（⭕ 未派；今晚整機測試若開 app 就是第一次）

09-02 手動測試只到安裝／建置／headless smoke（run-04 `JOURNAL.md:506` 明寫 GUI 功能頁不在範圍）；auditor 09-04 14:0x 的 grep 是第一次查 consumer（六個本地 repo：沒人讀 `get_switches_power_state`，五個讀 `is_up`）。→ FINDINGS #90。
