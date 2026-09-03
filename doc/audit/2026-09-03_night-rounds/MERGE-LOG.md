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

