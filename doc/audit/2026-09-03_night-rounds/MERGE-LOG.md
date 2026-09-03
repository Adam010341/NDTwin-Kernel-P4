# 合併日誌 — 2026-09-03 下午

Adam 14:xx：「不會（看 18 份 diff），怎麼合併你自己決定。」這份是每一支的裁決與證據。
**只合併進 trunk；不推。** push 的阻擋（P4-public 的用途與內容）另案。

[Co-developed with claude code -- Adam]

## 套用的規則

併：有變異閘，且（auditor 重跑過 或 agent 的 raw log 進了 repo），且合併乾淨或衝突已理解並解開。
等：C++ 半邊沒編過（靠這次整合第一次編）、或依賴一支還沒併的。
每一支 `--no-ff`，一支一個 merge commit，可以整支 revert。

## 順序與裁決

| # | 分支 | 裁決 | 理由 / 衝突 / 事後動作 |
|---|---|---|---|
| 1 | `docs/known-issues-batch1` | ✅ 併 | 純文件；Adam 說不看 diff ⇒ 依規則進。乾淨 |
| 2 | `fix/deterministic-path-tiebreak` | ✅ 併 | 5 變異 0 存活（auditor 重跑）。乾淨 |
| 3 | `fix/p4-priority-not-silently-dropped` | ✅ 併 | 7 變異 0 存活（auditor 重跑，含 cherry-pick 後）。501 取代假成功是正確性不是行為裁量。乾淨 |
| 4 | `fix/l9-make-topology-stdout-json` | ✅ 併 | 見 `BRANCHES-FOR-REVIEW.md`。乾淨 |
| 5 | `fix/g7-ndtwin-lab-config` | ✅ 併 | 59 checks＋閘門；乾淨（先於 g9 進，所以衝突落在 g9 那一步） |
| 6 | `fix/g9-cleanup-no-pkill-f` | ✅ 併，**解了 3 檔衝突** | `ndtwin-lab` 兩塊：第一塊兩份同義註解取 G-9；第二塊是相鄰（sweep 函式 vs `lab_conf_gate`），兩者都留，順序 sweep→sourced-return→gate→case。`NEXT.md`／`RATIONALE.md` 兩份文件撞名，全留。**合併後重跑**：G-7 59/59、G-9 29/29、兩閘門全捕 |
| 7 | `fix/g6-ndt-apps-liveness` | ✅ 併 | 只撞 `NEXT.md`／`RATIONALE.md`（日誌檔，全留）。**它帶回 #50 的形狀一處**（`app_wait_stopped`），下一步補 |
| 8 | `fix/redirection-order` | ✅ 併 ＋ 補 g6 那行 | 合併後那行改回 `2>/dev/null <`，閘門加 M2b 專門守它。26 checks、17/0 |
| 9 | `fix/ports-that-block-restart` | ✅ 併 | 9/9（auditor 重跑三次）。乾淨 |
| 10 | `fix/ndt-sudo-surface` | ✅ 併，**解 `ndt` 衝突** | 與 ports 相鄰（兩張表各自 `source`），兩邊都留。33 checks、14/14 |
| 11 | `fix/ndt-up-defaults-to-ovs` | ✅ 併 | Adam 裁的行為變更。23 checks、8/8 |
| — | **合併修復** | 🔑 **五個「各自為真、合起來為假」的 harness 假設，沒有一條是碼的缺陷** | (1) redirection 錨點 `cut -c1-90` 因 g6 多一站點而不唯一 → 每站點自己的錨＋M2b；(2) sudo 抽取器把 g6 註解裡的 `sudo -n ndtwin-lab` 當新命令 → 字面拼法對到 `lab` 列；(3) ports／sudo／(5) up-target 三個閘門只複製「ndt＋自己的表」，合併後 ndt 要 `source` 兩張 → 各補對方的表，up-target 的測試把前置條件具名（之前是 sourced `exit 2` 被 `>/dev/null` 吞掉、整套靜默死亡）；(4) redirection 靜態守衛**用行號**讀 `ndt:894`，合併後那行到 954，守衛讀到註解照樣綠、M14 存活 → 內容錨定＋逐站點檢查＋斷言數量。修完：7 套 shell 套件全綠（18／33／23／26／59／29／52），閘門 17/0、9/0、14/0、8/0 |

## Phase 2 — C++（一次冷編在 B5＋D15 之後，一次增量在全部之後）

順序由三對彼此衝突決定：D15 要 B5 的第三個 join；telemetry×flow-rate 在同一個 header 相鄰；
topo-load×D15 在 `TopologyAndFlowMonitor::start()` **語意重疊**（兩支各解了同一個排序問題的一半）。

| # | 分支 | 裁決 | 理由 / 衝突 / 事後動作 |
|---|---|---|---|
| 12 | `fix/b5-kernel-shutdown` | ✅ 併 | 7 commits，raw log 進 repo（SIGINT 7/7 exit 0）。乾淨。合併後 `stop()` 有 3 個 join（查證） |
| 13 | `fix/d15-dataplane-kind-race` | ✅ 併，**解 `tests/CMakeLists.txt`** | 與 B5 純 add/add（各加自己的測試檔），兩邊留。🔴 **它的測試紅在 fixture**：`startMonitor()` 只 `m_monitor->start()`，而 main.cpp 是 409 monitor → 432 manager；補 `m_manager->start()`＋TearDown 反序 `stop()`（B5 已進所以 join 得完）。建置後驗 4/4 |
| — | D15 fixture 補完 | ✅ | `startMonitor()` 照 main.cpp 409→432 起 monitor 再起 manager，TearDown 反序 stop。**冷編後 B5 3/3 ＋ D15 4/4 = 7/7** |
| 14 | `fix/flow-rate-denominator` | ✅ 併 | 乾淨。`SFlowType.hpp`／`FlowLinkUsageCollector.{hpp,cpp}`／`test_RateDenominator.cpp`＋建置型閘門 |
| 15 | `fix/telemetry-health-visible` | ✅ 併，**解 2 檔** | `FlowLinkUsageCollector.hpp` 與 flow-rate **相鄰**（`IngestHealth` vs `lastFlowRateDivisorSeconds()` 插同一點）兩邊留；`tests/CMakeLists.txt` 純 add/add。**裁決：severe 邊界 `>` → `>=`**（紅的測試要「剛好 10% 算 severe」，邊界歸較重的那一帶；lossy 那條沒有測試約束、不動） |
| 16 | `fix/logfile-takes-a-path` | ✅ 併 | 乾淨 |
| 17 | `fix/topology-round-reads-status` | ✅ 併 | 乾淨 |
| 18 | `fix/topology-load-fails-before-listen` | ✅ 併，**解 2 檔，唯一一個語意重疊** | 兩支各解了同一個排序問題的一半：D15 把載入搬進 `start()`（同步、發布 `isStaticTopologyLoaded()`），topo-load 做了會回報失敗的 `loadStaticTopology()`（main 在綁 port 前呼叫、失敗就 `EXIT_FAILURE`）但 `start()` 沒載入。**合法**：hpp 兩個 API 都留；cpp 留 `loadStaticTopology()` 定義、丟掉它在 `run()` 的後備呼叫（D15 的註解成立：那條 thread 只 poll）；`start()` 改成 `(void)loadStaticTopology()` 再設 D15 的兩個旗標。這支的 C++ 半邊**第一次被編譯**就是這次整合建置。Python 半邊合併後重跑：29/29、`--hosts 300` rc 1、`--hosts 8 --stdout` 是 JSON、l9 的 5/5 |
| — | **合併修復二（`5f8a745a`）** | 🔑 **第六個教訓：「兩邊都留」只在衝突塊起於語法邊界時才對** | 兩個 header 的衝突塊都從 `/** … */` **內部**開始（`/**` 是 `<<<<<<<` 上方的共用上下文），兩側各帶完整的註解本文＋`*/`＋宣告；兩邊都留之後，第二側的註解本文落在第一側的程式碼之後、**沒有 `/**`** ⇒ `FlowLinkUsageCollector.hpp:313` 起 stray `@`／stray `` ` ``／「🔴 不是合法識別字」、`IngestHealth` 不再是型別；`TopologyAndFlowMonitor.hpp:97` 起 topo-load 的註解本文在註解外、`loadStaticTopology()` 在 `start()` 的呼叫點「未宣告」。各補一個 `/**`，只編兩個失敗的 TU 驗證後 commit |
| — | 🔴 **上一則「877/877 全綠」不成立，收回** | 那輪跑的是**五支合併前的舊 binary** | `build3` 其實 `guarded_build: exit 1`（4/88 就停在上述錯誤），我讀到的「rc 0」是自己命令列最後一個 `grep -c` 的 rc——**pipeline 尾端吃掉 rc，今天第四次**。證據：執行檔 mtime 15:33 早於 build3 結束 15:36、`ninja -n` 還有 86 步、乾淨那輪 log 裡 `TelemetryHealth`／`LoggerCliArgs` 的 RUN 數是 **0**。判定一律讀 `guarded_build: exit N` 那一行 |
| — | **合併樹最終驗證（修好 `/**` 之後、真的新 binary）** | ✅ | `ninja -n` = 0、exe mtime 晚於最後一次原始碼改動；**924/924 gtest（＝924 個 TEST 巨集，一個不少）、ctest 924/924**；五個新測試檔的 case 數與來源分支逐檔相同；topo-load 的 Python 半邊 29/29＋`--hosts 300` rc 1＋`--hosts 8 --stdout` 是 JSON、l9 5/5；建置型閘門在合併樹重跑：**logfile 9/0＋3 widening 0 誤捕、flow-rate 5/0、rate_denominator 5/0**；還原後 `ninja -n` = 0 |
| — | **`stack.sh` 的漏網之魚** | ✅ 接進 | FIX-PORT-TABLE 記的那份「沒進 commit」的改動（讀 port 表）從共用工作樹抬成 patch 接進（`5c64d432`），ports／redirection／sudo 三套仍綠 |
| — | **trunk fast-forward** | 見下 | 共用工作樹有 16 個 tracked 髒檔（早上我派的 agent 留下的草稿）；逐檔比對整合分支：15 個是**子集**（無獨有行）、1 個（`stack.sh`）是真工作、已接進。還原那 15 個（備份在 scratchpad `ff-discarded-drafts/`）後 ff |
| — | **trunk fast-forward 完成** | ✅ | 期間 trunk 兩度被同事的 A-9／A-10 純文件 commit 推進，兩次都先併進整合分支（零交集、零 C++）再 ff。擋路的兩類：(1) 16 個 tracked 髒檔——12 個對整合分支零獨有行，**4 個有「獨有行」但是舊草稿**（`FlowLinkUsageCollector.cpp` +119＝telemetry 舊版含 `>`、`TopologyAndFlowMonitor.cpp` +27＝D15 doc 註解舊寫法、`DeviceConfigurationAndPowerManager.cpp` +1 註解、`tests/CMakeLists.txt` +3＝telemetry 那三行的舊位置）；(2) 16 個**未追蹤**檔＝agent 在共用樹裡的工作副本，13 個與整合版 byte-identical、3 個是更早的草稿（`test_DataPlaneKindOrdering.cpp` 修 fixture 前、`test_TelemetryHealth.cpp` 補 `sflow::` 前、`FIX-TOPOLOGY-COMPLETENESS.md` 舊版）。**全部備份（含各自對整合分支的 diff）於 `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/ff-discarded-drafts-1642`** 後還原／移除。auditor 裁決，依 Adam「怎麼合併你自己決定」 |

## 第二批（16:xx 派、從 `5c64d432` 長）

| # | 分支 | 裁決 | 理由 / 衝突 / 事後動作 |
|---|---|---|---|
| 19 | `fix/ovs4-has-sflow`（#4） | ✅ 併 | 4 commits。**auditor 乾淨樹重跑**：閘門 24/0、`test_ovs4_sflow.py` 21 OK、`test_ovs4_sflow_verify.sh` 48/0；raw 15 檔在 `audit-raw @ dc0a84d2`；主樹暫換過的 `ovs_4host_topo.py` 已按 sha 還原（`0b3f9796`）。live：ovs4 sflow 0→10 列、負載下 `avg_link_usage` 0.0→0.504（五次）、停後 8 s 回 0、對照組 128 台 0.196–0.274 與 `testbed_topo.py` 舊註記一致。對 trunk 乾淨；合併樹上動 `ndt` 的六套 shell 套件＋python 全綠。**未做**：`verify_sflow` 只掛 `up_ovs` 沒掛 `status --check`；`avg_link_usage` 的數值語意未對帳 |
| 20 | `fix/rule-journal-is-wired`（#71） | ✅ 併 → trunk `486d89fb` | 2 commits（`5fc5a13c` 修法＋`1f3fd41f` 文件）。**auditor 丟棄式樹重跑**：閘門 14/0（8 缺陷向＋6 放寬向控制組）、baseline byte-identical、`gate: exit 0`；合併樹 `p4_proxy/tests` 25 模組逐一全綠、`.run/` 未被建立。對 trunk `merge-tree` rc=0。🔴 三件交 Adam 裁（QUESTIONS N11）：每筆被接受的規則寫入多一次 `fsync`＝6.37 ms（≈150 rules/s 上界，REST 路徑、單鎖）；replay 仍無呼叫點；`quarantine()` 無呼叫點 ⇒ journal 跨 proxy 世代累積 |
| 21 | `fix/chaos-invariants-method`（#17） | ✅ 併 → trunk `65d4a32f` | 2 commits（`84997c45`＋`8694f70f`）。**auditor 丟棄式樹重跑**：閘門 11/0（M1–M8＋N1–N3 控制組）、baseline byte-identical、`gate: exit 0`；合併樹 `test_chaos_invariants_method` 27/27＋c07 20/20。第五例 `_c01_undo` 順手修了（M8 釘住）。`harness/test_probes.py` 不是 unittest（吃 fixture 路徑參數），沒算進去。對 trunk rc=0。**殘留**：`inv01_powercycle_latency()` 修好了但 runner 沒接（→ #75）；proxy 那面無守衛；`actions.py:507` 該讀哪條路由仍無答案 |
| — | 🔴 **驗證缺口（第七個教訓）** | 列 1–19 的合併驗證只跑 C++ 924＋shell 套件＋各分支自己的 python，**從沒跑整個 `tests/python/`（27 模組）與整個 `p4_proxy/tests`（25 模組）** | 在 `65d4a32f` 補跑：**2 個模組紅**。沿 trunk first-parent 逐 commit 跑：`test_l3_dispatch_drift` 自列 15（`ea139d1c`，telemetry-health）起紅——`KERNEL_ENDPOINTS` 手抄表漏 `GET /ndt/get_sflow_stats`（#73）；`test_shell_command_construction` 自列 17（`d00fa57c`，topology-round）起紅——`SHELL_SITES` 清單對不上被 `classifyEndpointReply(...)` 包起來的那行（#74；我讀過 `url` 來源不變＝`AppConfig` IP:port＋字面路徑，待 agent 再讀一次）。**兩個都是 inventory 測試在做它們的工作，而沒人跑它們。** 派 `fix/inventories-follow-the-merges`（base `65d4a32f`）。從這列起每次合併驗證固定加跑這 52 個模組 |
| — | 🔴 **17:50:25 閃退** | `systemd-oomd` 殺了 Claude 桌面 app（user slice 壓力 70% > 50% 逾 20 s）；四支 agent 是 app 的子行程、一起死；**當時唯一重負載＝cloexec 的 C++ 變異閘，跑在 guard（MemoryMax 5G）的 scope 裡** | cap 只擋 build 自己、擋不住它把 slice 擠到壓力線，oomd 殺 reclaim 最多的子 cgroup＝app。處置：17:53 停掉還在燒的孤兒 scope `ndtwin-build-3268060`；guard 加 `MemoryHigh=3G`、`MemoryMax` 降 4G（`d13890d5`，scope 內自測 `memory.high=3221225472`）；四支 agent 的 worktree 全部完好（poll 1 commit＋6 個 staged C++；cloexec 0 commit＋12 髒檔；apps-stop 1 commit＋doc；inventories 剛開工），17:5x 逐一以 on-disk 狀態接回、改用 trunk 那份 guard。lab 乾淨（claim none、0 switch、port 全關） |
| 22 | `fix/inventories-follow-the-merges`（#73/#74） | ✅ 併 → trunk `431d98a5` | 2 commits（`4d04ccf7`＋`8d492733`）。agent 在回報那一步 stall（600 s），但分支已完成、樹乾淨。**紅是我在 trunk 上親眼看的**（drift 1 FAIL、shell-site 2 FAIL），綠在分支上重跑；合併樹 `tests/python` 28＋`p4_proxy/tests` 25 模組 **0 紅**。#74 的 provenance 是 agent 重新推導的（`m_ryuUrl` 唯一寫入點、兩個 build-time `AppConfig` 常數、`--write-out` 只內插 constexpr 字面值），**不是照新行文字改 key**。`spec.py` 的 `get_sflow_stats` 列刻意沒加：handler 有 200／503 兩個分支，live 走哪個沒有 lab 判不出來（交接資料在 FIX-INVENTORIES §題目一）。ff 前 trunk 又吸了同事一個純文件 commit（run-06 tester prompt），先 ff 進整合分支再併 |

