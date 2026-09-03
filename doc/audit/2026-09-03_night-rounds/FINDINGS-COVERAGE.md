# 夜巡 68 條 findings 的覆蓋率總帳

**日期**：2026-09-03（下午）
**產出者**：claude code subagent（唯讀分析；除本檔外沒有動任何檔案、分支或實驗室）
**trunk**：`ed23a3b3`（`Night rounds: untangle the two branches that shared one pointer, and re-verify`）
**對象**：`doc/audit/2026-09-03_night-rounds/FINDINGS-ALL.md` 的 68 條 CONFIRMED 缺陷

[Co-developed with claude code -- Adam]

---

## 這張表怎麼讀

**狀態五值**

| 值 | 意思 |
|---|---|
| ✅ **IN TRUNK** | 修法已經是 `ed23a3b3` 的祖先。證據＝commit sha ＋那顆 commit 動的檔案。 |
| 🔧 **ON BRANCH** | 修法在某支未併分支上。證據＝`分支 @ sha` ＋動到的檔案 ＋閘門狀態。 |
| ⭕ **UNASSIGNED** | 沒有任何分支或 trunk commit 碰它。證據＝我查過哪裡、查了什麼、沒有找到。 |
| ➖ **NOT A DEFECT** | FINDINGS-ALL 自己歸為非缺陷，或明說刻意不修。 |
| ❓ **UNKNOWN** | 我查了但判不出來。證據欄寫卡在哪。 |

**兩條書寫規則，先講清楚免得誤讀**

1. 🔴 **狀態描述的是「這一條的標題主張」。** 一條 finding 若在同一格裡附帶了一個尚未修的
   同型後續（例如 #20 的 `lib_e.sh:565`），標題那半照實標 ✅／🔧，**後續寫進「誰該接手」並掛 ⭕**。
   但若**標題本身**就有一半沒修（#17 的兩個實例、#18 的兩條路徑），整條標 ⭕，
   證據欄再說明哪半已經落地。**方向永遠是「寧可看起來還沒修，不要看起來已經修好」。**
2. **部分覆蓋一律在證據欄標「（部分）」**，並寫明沒被覆蓋的是哪一半。

**統計**

| 狀態 | 條數 | 編號 |
|---|---:|---|
| ✅ IN TRUNK / 已修 | **44** | 4–7, 10–17, 19–20, 22–24, 26, 28–30, 32, 41–42, 45, 47–48, 50, 53, 56, 58–60, 63–65, 71–74, 78, 35–36, 46 |
| 🛠 派工中 | **4** | 8, 69–70, 77 |
| ⭕ UNASSIGNED | **32** | 1–3, 9, 18, 21, 25, 27, 31, 33–34, 37–40, 43, 49, 51–52, 54–55, 61–62, 66–68, 75–76, 79–82 |
| ➖ NOT A DEFECT | **1** | 44 |
| ❓ UNKNOWN | **1** | 57 |
| **合計** | **82** | （09-03 20:xx 由各列狀態欄重算；派工中＝3 支：logger #69/70（驗收中）、ndtcheck #8、ovstopo #77；⭕ 含 #77「等 Adam 裁」，#79–82 是 poll 交付時挖出的） |

**未併分支的實況（`git for-each-ref` ＋ 逐支 `git rev-list --count`）**

`refs/heads/` 底下 30 支 `fix/*` 裡，**只有 13 支真的沒併**；另外 17 支（`fix/F-8-…`、
`fix/a-2-…`、`fix/a-4d-…`、`fix/a-4f-…`、`fix/a-7-…`、`fix/a-9-…`、`fix/a4c-…`、`fix/b-2b-…`、
`fix/b3-…`、`fix/bx-…`、`fix/f-1-…`、`fix/f-6-…`、`fix/f13-…`、`fix/f15-…`、
`fix/flow-rate-divide-by-zero`、`fix/mutate-rate-denominator-…`、`fix/optimistic-topology-…`）
的 tip **就是 trunk 的祖先**（`merge-base == tip`，ahead=0），是已併的殘留指標，不是待審分支。
非 `fix/*` 的分支裡只有四支 ahead>0：`docs/known-issues-batch1`(+1)、`t8-t10-fixes`(+10)、
`audit/desk-check-remaining-manual-pages`(+22)、`t7b-release-renew`(+27)。
🔴 **`t8-t10-fixes` 的內容已經在 trunk 上了**（`39ee5484` 的同名修法以 `eae75da5` 落在 trunk），
它是一支過期的重複分支，不要當成待審修法。

---

## 主表（68 列）

### 嚴重（1–7）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 1 | `/ndt/delete_group_entry` 在 OVS 上是無聲 no-op，id 永久洩漏 | ⭕ UNASSIGNED | 逐支讀了 13 支未併 `fix/*` ＋ `t8-t10-fixes` ＋ `docs/known-issues-batch1` 的完整 diff：`GroupEntry`／`group_entry`／`MeterEntry` 在**全部改動行裡 0 次命中**。`HttpSession.cpp:1001 handleDeleteGroupEntry`（宣告 `HttpSession.hpp:397`、路由 `HttpSession.cpp:211`）在每一支上都與 trunk 相同；碰 `HttpSession.cpp` 的只有 telemetry（加 `get_sflow_stats`）與 topology-round（加 `topology_round` key），兩者都不在 group/meter 區塊 | kernel OVS group/meter 路徑；要 ovs4 才能重現 |
| 2 | B-1 幽靈規則過濾器沒覆蓋 OVS 寫入路徑 | ⭕ UNASSIGNED | `phantom`／`first_sighting` 在所有未併分支的改動行 **0 次命中**。過濾器本體 `include/ndt_core/routing_management/PendingEntryFilter.hpp`、`DispatchOutcomeLog.hpp`、`DeviceConfigurationAndPowerManager.cpp:2095` 都不在任何分支的變更檔清單裡 | 08-31 判「已修」的那支的作者；要兩個平面對照 |
| 3 | 失敗的 `ndt up ovs4` 不回滾，留下沒有大腦的網路 | ⭕ UNASSIGNED | `tools/test_workflow/stack.sh` 只被 `fix/b5-kernel-shutdown` 動到，內容是 `supervise.sh`／exit-status 紀錄／`cmd_down` 對 fatal 碼回非零——**沒有任何 rollback／trap 加在 bring-up 路徑上**（該 diff 裡 `trap` 全在測試腳本，`rollback` 0 命中）。`stack.sh:774 [3/3] kernel` ／ `:782 wait_for_port 8000` 的先後順序未變 | 🔧 `fix/ports-that-block-restart` 的 preflight 只**警告**佔用不回滾，兩件事不要混 |
| 4 | `ovs4` 完全沒配 sFlow ⇒ 流速率與鏈路使用率結構性為零 | ✅ IN TRUNK（09-03 第二批，`fix/ovs4-has-sflow`） | `tools/test_workflow/ovs_4host_topo.py` 只被 `fix/ports-that-block-restart` 動到，且**只加了 7 行 docstring 段落講 `:6653/:6633`**（diff 全文已讀），**零行 sFlow**。`enable_sflow` 在該檔仍 0 次；參考實作在 `testbed_topo.py:105`（定義）與 `:202`（呼叫） | **見下方「最該先派的五條」第 1 條** |
| 5 | kernel 關機時 abort（`stop()` 只 join 兩條 thread） | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/b5-kernel-shutdown @ e9f1326e`，修法 commit `4203d857`，動 `include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp` ＋ `src/.../DeviceConfigurationAndPowerManager.cpp`。閘門：**作者宣稱** `tests/shell/mutate_b5_power_manager_shutdown.sh` 3 變異／0 存活，**raw log 有 commit**（`doc/audit/2026-09-02_live-round/raw/b5-fix/mutation_gate.log`）；**無 control 變異**；**auditor 未重跑** | ⚠️ SIGTERM handler 刻意沒註冊 ⇒ `ndt down` 走的仍是硬殺，「乾淨關機」在正式路徑上還是沒跑過（見 #27） |
| 6 | `ndt apps stop` 只殺 bash wrapper，viz 的 JVM 活著而三個通道都說沒在跑 | ✅ IN TRUNK（09-03 `94abfb3f`，併 `fix/apps-stop-kills-the-group @ 850a6ea8`；auditor 重跑 71/0、閘門 13/0、鄰居 20/0；**真 app 未跑**，殘留見 WORK-ITEMS W-2） | 🔴 **分支名會騙人。** `fix/g6-ndt-apps-liveness @ e83ef1d1` 只替 energy／sim 補了 signature：分支上的 `tools/test_workflow/ndt:1636` 仍是 `viz) echo "network_traffic_visualizer.sh"`，而存活的兩個 JVM 的 argv **不含這個字串**（round3 `14_viz_process_chain.log` 已量到）。`e83ef1d1` 本身只加 `NEXT.md`，不是修法 | viz 的 argv 已到手 ⇒ 可以動手；比對字串是目錄名 `Network-Traffic-Visualizer` |
| 7 | `ndt` 有兩個 `sudo -n` 不在手冊教的 sudoers 規則裡 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 🆕 12:5x **`fix/ndt-sudo-surface @ 20d834aa`**（base `ed23a3b3`），新增 `tools/test_workflow/sudo_surface.sh`（一張被讀取的宣告式表，形狀照 `ports.sh`）＋ `ndt` 的 `ovs_bridge_count`／`dataplane_ok` 改成**問不到就 rc 2 且不作答**＋ `up_p4` 的守衛在「不知道」時**停下來**。閘門：**auditor 自己重跑** `tests/shell/mutate_ndt_sudo_surface.sh` → baseline 33 checks 0 failed、**14 mutations, 0 survived**、baseline byte-identical（`sudo_surface.sh` 與 `ndt` 兩個）。**兩面成立**：M1–M10 把缺陷放回去，**N1–N4 是「什麼都拒絕」的四種寫法**（通得過全部十條 M，只有 control 抓得到）| 🔴 **與 `fix/ports-that-block-restart` 在 `tools/test_workflow/ndt` 衝突**（auditor 實測）；vs `g6`／`g9` 乾淨。🔴 **從未在真的需要密碼的機器上實跑**——所有「被拒」由 PATH 上的假 `sudo` 產生 ⇒ 仍是 desk check |

### 中等（8–31）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 8 | `ndt status --check` 在健康 ovs4 上報假紅，且在 OVS 上零鑑別力 | 🛠 派工中（20:4x，`fix/ndt-status-check-baseline`，base trunk，N12 裁 (a)） | trunk `ndt:1367-1375`：`want` 取自 `$topo`，比 `"$g_hosts $g_edges"`，紅時 push `the kernel graph does not match the topology file`。`host_count_override` 在 trunk 的 `ndt` 出現 7 次，在 `fix/ports`／`fix/g6`／`t8-t10` 三支上**也是 7 次** ⇒ 沒人動 | 🔑 **規格現成**：trunk `eae75da5`（`verify_p4` 改讀 `fabric_host_count()`）是同一形狀的解法。⚠️ `t8-t10-fixes` 的 `39ee5484` 修的是 `verify_p4`，**不是**這個檢查 |
| 9 | OVS 收下 action 為 `OUTPUT:999` 的流（s1 上不存在的 port） | ⭕ UNASSIGNED | `OUTPUT:999` 在所有分支 diff 0 命中；OVS 側的 flow 安裝驗證路徑不在任何分支的變更檔清單裡 | 需要 ovs4 |
| 10 | 每條流的速率沒有分母，誤差＝迴圈週期，大象流門檻一定錯 | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/flow-rate-denominator @ 6088c0b5`，動 `include/common_types/SFlowType.hpp`（新純函式 `updateFlowRatesForInterval`）、`include/ndt_core/collection/FlowLinkUsageCollector.hpp`、`src/.../FlowLinkUsageCollector.cpp`、`tests/test_RateDenominator.cpp`、`tests/shell/mutate_flow_rate_denominator.sh`。閘門：**作者宣稱** 5 變異／0 存活（F1 逐字還原出貨運算式，F4 是唯一斷言接線的那格）；**無 control 變異**、**分支上無 raw log**、**auditor 未重跑** | 🔴 合併前置條件是作者自己下的：T1／T2／T3 三筆既有結論要先對帳 |
| 11 | `check_logs.py` 崩潰樣式表缺 12 類致命訊息（含 SIGKILL／oomd） | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/b5-kernel-shutdown @ e9f1326e`，commit `d050bb35`，動 `tools/contract_test/check_logs.py` ＋ `tests/shell/test_check_logs_crash_patterns.sh`。閘門：**先看過紅且 raw 有 commit**——`raw/b5-fix/test_crash_patterns_vs_HEAD.red.txt`（對 HEAD 32 checks／12 failed，本分支 0 failed）；auditor 未重跑 | 併入後對既有 audit log 重跑會出現新的紅，要有人吃 |
| 12 | `stop_one` 的 `local name=… pidfile=…` 讀到呼叫端的變數 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 同上分支，commit `621cca07`，動 `tools/test_workflow/stack.sh` ＋ `tests/shell/test_stop_one_targets_its_argument.sh`。閘門：紅跑 raw 有 commit（`raw/b5-fix/test_stop_one_vs_HEAD.red.txt`，末行 `Ran 5 checks, 4 failed`）；auditor 未重跑 | — |
| 13 | `l1_unit_tests.sh` 把五個全綠的 shell 套件記成失敗 | ✅ IN TRUNK | `49801adb`，動 `tools/test_workflow/l1_unit_tests.sh` ＋ `tests/shell/test_l1_shell_scoring.sh` ＋ `tests/shell/mutate_l1_shell_scoring.sh` | — |
| 14 | chaos `_c07` 的控制組零鑑別力，一條已發表的宣稱建立在它上面 | ✅ IN TRUNK | `1411f163`，動 `doc/audit/2026-08-28_chaos-harness/harness/{actions,probes}.py`、`05_first-live-run.md`、`tests/python/test_chaos_c07_control.py`、`tests/shell/mutate_chaos_c07_control.sh` | — |
| 15 | `l3_component_check.py --check-drift` 不認得 `utils::pathIs(...)` ⇒ 誤報兩條路由被刪 | ✅ IN TRUNK | `70665602`，動 `tools/contract_test/components.py` ＋ `tests/python/test_l3_dispatch_drift.py` ＋ `tests/shell/mutate_l3_dispatch_drift.sh` | — |
| 16 | `run_layers.sh` 不管哪座 fabric 起著都用 4 主機模型 | ✅ IN TRUNK | `09e72e7b`，動 `tools/test_workflow/run_layers.sh` ＋ `tests/shell/{test,mutate}_run_layers_topology_from_fabric.sh` | — |
| 17 | 同型第三、第四例：`_h23_verify` 讀未註冊路由；`invariants.py:84` 對只收 POST 的路由發 GET | ✅ IN TRUNK（09-03 `65d4a32f`，併 `fix/chaos-invariants-method @ 8694f70f`；第四例＋掃出的第五例 `_c01_undo`；auditor 丟棄式樹重跑閘門 **11/0**、合併樹 27/27） | **（部分）第三例已修**：`efd2fe10`（trunk 祖先）把 `harness/actions.py:456 _h23_verify` 改成 `api_get_checked` ＋ `NotAnswered` 拒絕（我讀了 trunk 上的函式本體）。**第四例未修**：trunk `harness/invariants.py` 的 `inv01_powercycle_latency()` 仍用 `probes.api_get_timed(f"/ndt/set_switches_power_state?…")` 對只收 POST 的路由發 GET，任何分支都沒動這個檔 | chaos harness 的主人；FINDINGS 說「已另開工單」，但**工單編號沒有寫在任何我讀到的文件裡**；🆕 殘留：INV-01 延遲檢查 runner 沒接 → #75、proxy 面無守衛、`actions.py:507` 該讀哪條路由未定 |
| 18 | 兩個速率欄位量的不是同一件事，分歧隨負載成長（一個高估、一個漏看） | ⭕ UNASSIGNED | **（部分）高估那半＝ #10**，在 `fix/flow-rate-denominator @ 6088c0b5` 上。**漏看那半未修**：`AutoRefreshQueue`／`refresh()`／`m_interval` 在該分支只出現在**文件行**（`FLOW-RATE-DENOMINATOR.md` 72/73/170），`include/common_types/SFlowType.hpp:193-266` 的滑動視窗邏輯**沒有任何分支改過** ⇒ 兩次讀數之間的空隙仍在，兩欄仍不可比 | 同 #10 的人接續；這半要改的是取樣視窗與迴圈週期的關係，不是分母 |
| 19 | `check_gate_anchors.py` 有四個閘門根本沒在檢查（含 A-9 的全部證據） | ✅ IN TRUNK | `16419664`，動 `tests/shell/check_gate_anchors.py`（+654/−40）＋ `tests/python/test_check_gate_anchors.py` ＋ `tests/shell/mutate_check_gate_anchors.sh` | — |
| 20 | `lib_e.sh:435` 的 iperf3 守衛會自我毀滅後回報「乾淨」 | ✅ IN TRUNK | `f830dd03`，動 `doc/audit/…/lib_e.sh` ＋ `tests/shell/{test,mutate}_iperf3_guard.sh` | ⭕ **同型待修**：`lib_e.sh:565` 對 `ndtwin_kernel` 有同樣的 argv 形狀，`f830dd03` 沒有碰它，也沒有任何分支碰它 |
| 21 | `up_p4` 在沒清乾淨的 orphan 上建 fabric，且丟棄 cleanup 的 rc | ⭕ UNASSIGNED | **刻意不修**（FINDINGS 自述）。實測分支上仍未修：`fix/ports-that-block-restart` 的 `ndt` diff 在同一段只加了一行 `ndt_port_residue p4 \| sed …`，底下仍是 `sudo -n "$LAB" cleanup >/dev/null 2>&1`，**rc 照樣丟掉**；`ndt:1083`（`cmd_down`）同樣未讀 rc | 要與 G-9 一起裁（G-9 讓 cleanup 會失敗之後這個洞才看得見） |
| 22 | 殘留報告漏掉 bmv2 的 `:3005x`——唯一會擋住下一次啟動的那個 port | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/ports-that-block-restart @ 2fe70075`，新增 `tools/test_workflow/ports.sh`（9 列 `spec\|proto\|plane\|owner\|consequence`，含 `30051-30060` 與 `9091-9100`），並**確實接線**：`tools/test_workflow/ndt` 的 `cmd_clean`、`deep_sweep`、`preflight` 三處都改成讀 `ndt_port_rows`／`ndt_port_residue`（逐 hunk 讀過）。閘門：**auditor 在解糾纏後的新 sha 上重跑**——baseline `Ran 18 checks, 0 failed`，**9 mutations, 0 survived**，事後 `ports.sh` 與 `ndt` byte-identical | ⚠️ `ndt status` 仍自帶三個字面 port（`ndt:1400-1402`），同一形狀沒收進表 |
| 23 | 同型第二例：`:6653`／`:6633` 在整個 `ndt` 裡一次都沒出現 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 同上分支同一張表（`ports.sh` 的 `6653` 與 `6633` 兩列，consequence 欄寫明 RemoteController 的 6653→6633→fallback 會讓「沒有 controller」與「不是你的 controller」長得一樣）；閘門同 #22 | — |
| 24 | 同型第三例：`:9000`（sim app）在 `ndt` 與 `stack.sh` 各 0 次 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 同上分支（`ports.sh` 的 `9000\|tcp\|apps\|Simulation-Platform-Manager` 列）；閘門同 #22 | — |
| 25 | 🔑「這個檢查有鑑別力」的證據可能只在被檢查的那一組上成立 | ⭕ UNASSIGNED | 方法論 finding，沒有對應的一段碼。**已被部分回應**：`fix/ports-that-block-restart` 的閘門刻意把鑑別力建立在原本三個 port 之外（M4 只有在 UDP port 上觀察得到）。**未回應**：G-9 的 `sweep_matches` 仍只被人為發明的命令列測過，作者列為合併必要條件的 L2（起一座真 bmv2、先印 argv 再 cleanup）**沒有任何分支或紀錄顯示做過** | L2 需要實驗室；今天派不出去 |
| 26 | `grep -c 'simple_switch_grpc'` 在 0 座 bmv2 的機器上回 3（全是自我比中） | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/g9-cleanup-no-pkill-f @ 81519ad8`，修法 commit `82df654f`，動 `tools/test_workflow/ndtwin-lab`（`pgrep -c -f` → `sweep_count`，ps 當索引／`/proc/<pid>/cmdline` 當權威）。閘門：**作者宣稱** `mutate_g9_cleanup_no_pkill_f.sh` 6／0 ＋ `mutate_g9_faults_topo_pid.sh` 4／0，**兩把都有 control-comment-only 存活**；**分支上無 raw log**、**auditor 未重跑** | 🔴 與 `fix/g7-ndtwin-lab-config` 對同一行意見相反（G-7 原樣留 `pgrep -c -f`）⇒ 先 G-9 再 rebase G-7 |
| 27 | 關機的 openflow worker 只在輪與輪之間檢查 `m_running`（忙碌時 81 秒） | ⭕ UNASSIGNED | `fix/b5-kernel-shutdown` 的 diff 裡 `m_running` **只出現在散文**（B5-REPORT.md 三處），程式碼一行未改。B-5 的報告自己寫了修法順序（**先把輪詢變成有界的，再註冊 handler**），而**有界化那一步不在任何分支上** | 這是 SIGTERM handler 的前置條件；沒有它，註冊 handler 等於把「立刻死」換成「等 10 秒再被 SIGKILL」 |
| 28 | 今晚新寫的兩個變異閘門，anchor 檢查器一個都讀不到 | ✅ IN TRUNK | `053387b1`（動 `mutate_e_restore_asserts_compiled_artifact.sh`、`mutate_preflight_instrument_self_failures.sh`）＋ `fbe4dd8f`（再修 preflight 那支的 `report()` 被當成 applier 解析） | — |
| 29 | `lib_e.sh` 的還原檢查在輪次真正移動的那個軸上零鑑別力 | ✅ IN TRUNK | `e72ebdfa`，動 `doc/audit/…/lib_e.sh` ＋ `tests/shell/{test,mutate}_e_restore_asserts_compiled_artifact.sh` | — |
| 30 | `00_preflight.sh` 分不出「別人的 claim」與「不知道這是誰的 claim」 | ✅ IN TRUNK | `c916bd4c`，動 `doc/audit/2026-08-30_live-full-stack-round/harness/00_preflight.sh` ＋ `harness/lib.sh` ＋ `tests/shell/{test,mutate}_preflight_instrument_self_failures.sh` | — |
| 31 | `TESTBED` 那條路有除以時間，但把間隔截斷成整數秒 | ⭕ UNASSIGNED | **刻意延後**。`fix/flow-rate-denominator` 的文件第 171／230 行登記為「🟠 有分母但被截斷，另案」「本輪未處理」，該分支的 `FlowLinkUsageCollector.cpp` diff 沒有動 `updateLinkInfo` 的 TESTBED 分支 | 可及性低（TESTBED 是停用硬體），但已登記免得下次又靠 grep 漏掉 |

### Round 2 — 開關機／路徑重算（32–40）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 32 | 🔴 根因：啟動競態讓 bmv2 的 liveness 路徑從不執行 | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/d15-dataplane-kind-race @ 75c2b526`，動 `include/ndt_core/collection/TopologyAndFlowMonitor.hpp`、`include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp`、對應兩個 `.cpp`、`tests/CMakeLists.txt`、新增 `tests/test_DataPlaneKindOrdering.cpp`。閘門：**auditor 親自編譯並執行**——編譯乾淨（98 目標、0 個 `FAILED:`），**閘門 3／4**。紅的 `TheStartupSequenceMainUsesYieldsABmv2Verdict` 是**測試自己名不副實**（只呼叫 `startMonitor()`，沒呼叫 `m_manager->start()`），不是修法紅 | 🔴 **這支的閘門在自己的分支上關不起來**：要照 main 的順序跑就得呼叫 `m_manager->start()`，而 B-5 的漏 join 還在 ⇒ **B-5 必須先落地** |
| 33 | `/ndt/get_switches_power_state` 回報的是下過的指令不是量測 | ⭕ UNASSIGNED | `set_switches_power_state`／`get_switches_power_state`／`PowerState`／`powerState` 在**所有未併分支的改動行 0 次命中**；D15 的文件把它列成「UNRUN／預測形狀改變但仍讀同一個 `isUp` bit」，**沒有修** | 電源 API 的主人；`isUp` 承載兩個意思是共同根因（見 #46） |
| 34 | A-8 的三態檢查在 MININET 下不可能失敗，且硬把原因歸給 Energy-Saving-App | ⭕ UNASSIGNED | `unexplained_down` 在 trunk 只出現在 audit 文件裡，不在任何分支的改動行 | — |
| 35 | 電源 API 兩個方向都用 `isUp` 提前 return Success | ✅ IN TRUNK | `85c1a159`（merge of `fix/poll-does-not-resurrect`，修法 `7e8d91e0`）：`adminPoweredOff` 旗標＋`updateSwitches` 不抬、三條電源路徑 commanded writer、#35 早退刪除；閘門 10/0＋3 widenings；gtest 951/951；raw `audit-raw @ 19e3ab88`；MERGE-LOG 27 | — |
| 36 | 命令的關機會遺失，9 次中 2 次 | ✅ IN TRUNK | `85c1a159`（merge of `fix/poll-does-not-resurrect`，修法 `7e8d91e0`）：`adminPoweredOff` 旗標＋`updateSwitches` 不抬、三條電源路徑 commanded writer、#35 早退刪除；閘門 10/0＋3 widenings；gtest 951/951；raw `audit-raw @ 19e3ab88`；MERGE-LOG 27 | 與 #46 同一根 |
| 37 | 被拒的模擬 case 讓 Energy app 永久卡死並霸佔 `routing_lock` | ⭕ UNASSIGNED | 已被 Lead E **降級**為單一 app 的 liveness bug（`routing_lock` 後面什麼都沒擋）。修法對象 `energy_saving_app.cpp` **不在本 repo**（`~/Energy-Saving-App`），本 repo 無分支涉及 | Energy-Saving-App 的主人；⚠️ MEMORY 記著那個 repo 的 power bug「已修但不要 push」 |
| 38 | 連線被拒被報成「30 秒逾時」（實測 6–9 ms） | ⭕ UNASSIGNED | 訊息產生點不在任何分支的變更檔清單裡 | — |
| 39 | `get_power_report` 是 dpid 的純函數，且沒有 `source` 欄 | ⭕ UNASSIGNED | `get_power_report` 在所有分支 diff 0 命中；round 6 已確認值是 `splitmix64(dpid)`、屬已知 #39／#33 而非 cache bug | 「省了 N% 電」的任何宣稱都掛在這條上 |
| 40 | 兩條路全關時 twin 說 no path，交換機自己的表仍指向已關機的 s6 | ⭕ UNASSIGNED | 分身與資料平面的對帳路徑不在任何分支的變更檔清單裡 | — |

### 安裝手冊 run-04（41–44）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 41 | 🔴 `ndt down` 的乾淨驗證看不到 sFlow 的 `:6343`，五條斷言全綠 | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/ports-that-block-restart @ 2fe70075`。三件都查了：(a) `ports.sh` 有 `6343\|udp\|both\|…` 這一列；(b) `ndt_port_open` 對 `udp` 走 `ss -lunH`（舊 `port_open` 只講 TCP，所以就算列了也看不到）；(c) `cmd_down` 在 `ndt:1141` 呼叫 `cmd_clean`，而 `cmd_clean` 的 `for p in 8000 8080 8081` 已換成 `ndt_port_residue all`，`prc == 2`（查不到）也算 not-clean。閘門同 #22（auditor 重跑 18 checks／9 變異 0 存活） | ⚠️ `fix/g9` 的 `81519ad8`「Add :6343 to the blocking-port table」**只動 `NEXT.md`**，不是修法 |
| 42 | `testbed_topo.py` 的 128 對 ping self-test 全 100% loss，結尾 banner 照樣印三個 OK | ✅ IN TRUNK（09-03 `94abfb3f`，併 `fix/testbed-banner-reads-its-ping @ cb6c47a0`；auditor 重跑 45/45、25/0；**只修本 repo 那份**，`ndt up ovs` 跑的 NTG 副本見 #77／N13） | `testbed_topo.py`（repo 根目錄）**不在任何未併分支的變更檔清單裡**。trunk 上 `:228-239` 用 threading 跑 ping、`:246` 無條件 `print("Host internet: OK \| sFlow reachability: OK \| Switch identification: OK")`——**banner 與 ping 結果之間沒有任何資料流** | **見下方第 3 條**；banner 那半完全離線可修 |
| 43 | 🔴 NSR 的 stop script 用 `pgrep -f` 連坐殺掉 tester 自己的 shell | ⭕ UNASSIGNED | 修法對象**不在本 repo**：`git ls-tree -r trunk \| grep network_state_recorder` 只回 audit log 與 tester 腳本，沒有產品側的 stop script | Network-State-Recorder 的主人；本 repo 的 `fix/g9-cleanup-no-pkill-f` 在做同族的事，可當範本 |
| 44 | Web GUI 的 pnpm 未釘版本，如預測重現 | ➖ NOT A DEFECT | FINDINGS-ALL 自述「run-01 就有、**刻意沒修**」，用途是預註冊預測的命中證據。`web_gui_deploy.sh` 也不在本 repo（只有 tester 的 `bugs_webgui_pnpm.sh` 重現腳本） | 什麼時候要真的釘版本，是裁決不是缺陷 |

### Round 3 — 反覆重啟／併發（45–50）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 45 | 🔴 啟動競態由 topology 檔的 parse 時間決定，出貨檔 0/44 勝 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 與 #32 同一支：`fix/d15-dataplane-kind-race @ 75c2b526`（`start()` 改成在生出任何執行緒之前、在呼叫者的執行緒上完成靜態拓樸載入）。閘門同 #32（auditor 編過、3／4）。fixture 刻意用 310 B 級拓樸——**那正是壞版本會贏的尺寸**，所以不能靠運氣過 | 同 #32：B-5 先落地 |
| 46 | 🔴 輪詢覆蓋關機指令且復活是永久的（`isUp=true`，沒有 else 分支） | ✅ IN TRUNK | `85c1a159`（merge of `fix/poll-does-not-resurrect`，修法 `7e8d91e0`）：`adminPoweredOff` 旗標＋`updateSwitches` 不抬、三條電源路徑 commanded writer、#35 早退刪除；閘門 10/0＋3 widenings；gtest 951/951；raw `audit-raw @ 19e3ab88`；MERGE-LOG 27 | **見下方第 2 條** |
| 47 | 🔴 kernel 的 listening socket 被自己 `popen` 出來的 sh／curl 繼承（2.01–2.22 s，48/48） | ✅ IN TRUNK（09-03 `94abfb3f`，併 `fix/cloexec-listening-sockets @ 401cb6f2`；auditor 在整合樹重跑閘門 **12/0＋3 widening**、940/940；raw `audit-raw @ 94333bb2`；前提：窗口＝最長命子行程，proxy 卡住才重現） | `FD_CLOEXEC`／`O_CLOEXEC`／`closefrom` 在所有未併分支的改動行 **0 次新增**。唯一碰 `utils::execCommand` 的是 `fix/topology-round-reads-status`，而它只在 curl 命令尾巴加 `--write-out`（`TopologyAndFlowMonitor.cpp:488` 附近），**沒有動 fd 繼承** | 錯誤訊息「另一個 NDTwin kernel 幾乎確定還在跑」會把人推向錯誤診斷，值得早修 |
| 48 | `ndt apps stop viz` 回 ok 而兩個 JVM（531 MB）仍活著；`apps orphans` 也說沒有 | ✅ IN TRUNK（09-03 `94abfb3f`，併 `fix/apps-stop-kills-the-group @ 850a6ea8`；auditor 重跑 71/0、閘門 13/0、鄰居 20/0；**真 app 未跑**，殘留見 WORK-ITEMS W-2） | 與 #6 同一缺陷、第二次量到。證據同 #6（分支上 `app_sig viz` 未變） | 同 #6 |
| 49 | `ndt down` 自己的 verify 誤報（說 5 still running，20 秒後 `ps` 數到 0） | ⭕ UNASSIGNED | trunk `ndt:1103/1106` 的 `bmv2_count`／`mn_count` 斷言在 `fix/ports-that-block-restart` 上**未改**——該分支只把底下的 `for p in 8000 8080 8081` 換成表。verify 與 sweep 之間仍沒有同步 | 與 #21／#26 同一族，適合一起做 |
| 50 | `ndt:1687` 的 `2>/dev/null` 放在 `<` 之後，所以它擋不住它唯一要擋的訊息 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 🆕 **`fix/redirection-order @ 7fdd8971`**（base `feb9baef`）。**同形共 20 處**（lexer 掃描＋粗 regex 交叉檢查＋3084 次注入量偽陰性率），修 15 處、5 處判定為 `< /dev/null` 不會失敗故不改。閘門 **16 mutations, 0 survived**（agent 自陳，auditor 未重跑） | 🔴 **合併預警，auditor 實測**：`fix/g6-ndt-apps-liveness` 與它**乾淨合併，卻把缺陷帶回來**——g6 的 `ndt:2011` 新增 `err "   pid $pid: $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \| cut -c1-90)"`，`<` 仍在 `2>` 之前，而 trunk 沒有這一行 ⇒ git 看不出衝突，閘門也抓不到（錨點逐處指名）。**g6 落地後要補這一行** |

### Round 4 — 高流量與量測失真（51–57）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 51 | 🔴 高負載下分身低報 2.76 倍，而所有健康訊號都說正常 | ⭕ UNASSIGNED | **（部分）「看不見」那半在 `fix/telemetry-health-visible @ b7aad224` 上**（每一列 flow 與 `get_average_link_usage` 都會帶 `telemetry_health.status`／`loss_fraction`）。**低報本身沒有任何分支處理**：`classifyIngestHealth` 只分類，不改速率；取樣→速率路徑沒有針對 socket 掉包做補償或標記 void | 先併 telemetry 讓它可見，再決定低報要修還是要標 void |
| 52 | 🔴 完全送達的 flow 會從 API 預設窗口消失，界線的單位是 pps 不是 bit/s（~22 pps） | ⭕ UNASSIGNED | API 的窗口／liveness 判定不在任何分支的變更檔清單裡；`?liveness=all` 那條路徑也沒被動過 | 至少要先把文件與宣稱的口徑從 Mbit/s 改成 pps |
| 53 | 🔴 sFlow 樣本會掉，而四個丟棄計數器沒有任何 API 讀得到 | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/telemetry-health-visible @ b7aad224`，動 `include/ndt_core/collection/FlowLinkUsageCollector.hpp`（新 `IngestHealth`／`classifyIngestHealth`／`ingestHealthJson`）、`src/.../FlowLinkUsageCollector.cpp`、`include/ndt_core/http/HttpSession.hpp`、`src/ndt_core/http/HttpSession.cpp`（新 `handleGetSflowStats`，`utils::pathIs(target, "/ndt/get_sflow_stats")`）、`tests/CMakeLists.txt`、新增 `tests/test_TelemetryHealth.cpp`。閘門：🔴 **作者交付時 0 閘門且編不過**；**auditor 補了兩行 namespace 限定（`b7aad224`）之後編得過，閘門 17／18**。紅的 `AppDropsAloneMoveTheVerdict` 是**真的邊界缺陷**（`FlowLinkUsageCollector.hpp:373,375` 的 `0.01`／`0.10` 配 `.cpp:1780` 的嚴格大於，剛好 0.10 落進 `lossy`） | 分支主人要裁 `>` vs `>=`；**目前沒有任何綠測試在約束那個邊界** |
| 54 | 同一個 match 裝 20 次報 `succeeded +20`，交換機只多 1 列；刪不存在的規則 15 次全 succeeded | ⭕ UNASSIGNED | `fix/p4-priority-not-silently-dropped` 只改**帶 priority 的 `delete_strict`／`modify`**（回 501），`add` 路徑與 `succeeded` 的累加語意**沒有動**（該分支 diff 裡 `succeeded` 只出現在說明 501 改記 `failed+1` 的兩行） | 「succeeded 是什麼的計數」需要先裁一個定義 |
| 55 | collector 綁 `INADDR_ANY:6343`，來源位址從頭到尾沒被讀過（`srcAddrs` 只寫不讀） | ⭕ UNASSIGNED | `srcAddrs`／`INADDR_ANY` 在所有未併分支的改動行 **0 次命中**。trunk 側 `src/ndt_core/collection/FlowLinkUsageCollector.cpp` 雖被 flow-rate 與 telemetry 兩支動到，但兩支的 hunk 都不在收包歸屬那段 | 🔴 任何能送 UDP 到本機的東西都能改寫遙測，而沒有 endpoint 會顯示 |
| 56 | `rx` 在穩態下沒有任何通道 ⇒「沒有 WARN」與「什麼都沒收到」分不出來 | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/telemetry-health-visible @ b7aad224`：`classifyIngestHealth()` 在 `offered_in_window == 0` 時回 `status = "no_samples"`，並把 `samples_in_window` 掛進每一列 flow 與 `get_average_link_usage`；分支自己的 `FIX-TELEMETRY-HEALTH.md` 第 3 點明列這一條。閘門同 #53（17／18） | — |
| 57 | API 送出的 IP 是位元組反序的，文件沒講 | ❓ UNKNOWN | **卡在前提對不上，兩個方向都有證據。** (a) trunk 的 `doc/2026-01-02_ndt_api.md:255-261`（自 `9e3874c2`，08-13 起）**已經寫了** `src_ip`/`dst_ip` 是 network byte order 並舉 `16777226` 為例；(b) round 4 自己的 `round4-traffic-measurement/SUMMARY.md:184` 把它記為 **"Observation (not filed as a defect)"**；(c) 但那段文件的算術本身可疑——它說 `16777226` 的位元組是 `0A 00 00 01`，而 `16777226 = 0x0100000A`，位元組是 `01 00 00 0A`。**我判不出來**：不知道 round 4 讀的是哪個 endpoint 的哪個欄位（是否落在那段說明的涵蓋範圍內），也不敢在沒有實跑的情況下斷言文件的例子錯了 | 需要一次唯讀的 API 取樣（讀既有 raw 即可，不必起 fabric）＋一個人裁「文件的例子對不對」 |

### Round 5 — 拓樸檔與重現性（58–63）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 58 | 🔴 8 次 bring-up 產生 4 種不同的全網路由表，而 `get_path_switch_count` 逐位元相同 | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/deterministic-path-tiebreak @ 966734be`，動 `p4_proxy/proxy_agent/{ryu_topology,topology_manager}.py` ＋ `p4_proxy/tests/{test_path_determinism,test_link_watchdog}.py` ＋ `tests/shell/mutate_path_determinism.sh`。閘門：**auditor 重跑**——baseline 10 tests 綠，**5 mutations, 0 survived**，rc=0，每個變異紅的是腳本**指名的那一支**測試，事後 baseline byte-identical | ⚠️ `get_path_switch_count`（研究者用來問「路徑變了沒」的端點）這支完全沒碰 ⇒ 修好之後**仍然看不見**。爆炸半徑已盤點，結論留給 Adam 裁 |
| 59 | 🔴 產生器能產出自家 kernel 載不動的檔，而失敗發生在 port 看起來健康之後 | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/topology-load-fails-before-listen @ 896f6674`，動 `tools/make_topology.py`、`tests/python/test_make_topology.py`、`src/main.cpp`、`include/…/TopologyAndFlowMonitor.hpp`、`src/…/TopologyAndFlowMonitor.cpp`（`loadStaticTopology()` 同步、失敗 `EXIT_FAILURE`、空圖也拒絕）。閘門：**auditor 重跑了 Python 那半**——29 tests OK（腳本與 `unittest` 收集都一樣）、`--hosts 300` → rc=1 且訊息成立、對照組 `--hosts 8` → rc=0 仍完整產出。🔴 **C++ 那半從未編譯、從未執行，排序的閘門沒有寫**（需要 binary） | 🔴 **與 D15 同檔同區**（實測 `merge-tree`：`TopologyAndFlowMonitor.hpp` 與 `.cpp` 都衝突）⇒ **先併 D15 再 rebase 這支**。另外「拓樸檔不見就拒絕啟動」是行為變更，作者自己標了要 Adam 裁 |
| 60 | P4 平面上 `priority` 被收下、寫進 log、然後丟掉（777 改到既有規則、999 也刪得掉） | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/p4-priority-not-silently-dropped @ 4c5a92da`，動 `p4_proxy/proxy_agent/api_routes.py` ＋ `p4_proxy/tests/test_flowentry_endpoints.py` ＋ `tests/shell/mutate_p4_priority_refusal.sh`。閘門：**auditor 在解糾纏後的新 sha 上重跑**——**7 mutations, 0 survived**, rc=0，四個「必須不觸發」的仍不觸發，`api_routes.py` byte-identical；**red-before-fix 的 raw log 有 commit**（`doc/audit/2026-09-03_night-rounds/priority-refusal/red-before-fix.log`，六支紅） | ⚠️ **`add` 路徑刻意維持揭露不拒絕**（沿用 T-15 Option 0 的既有裁決）；未實機驗證 501 穿過 kernel 的路徑 |
| 61 | dpid 對不到交換機的 host edge 被靜默丟棄（40 條進 39 條），只有一行 WARN | ⭕ UNASSIGNED | `fix/topology-load-fails-before-listen` **不涵蓋這一條**：我讀了該分支的 `loadStaticTopology()` 全文（`:236-287`），它只在 (a) parse／IP 例外、(b) `num_vertices == 0` 兩種情況拒絕啟動；dpid 解不出來的邊仍走既有的 `continue`（該檔 20 處 `continue` 未變）。round 5 的 T4 與現成重現檔 `round5-topology-repro/03_mutant_m1_host_edge_ghost_dpid.log` 都還沒有對應修法 | 規格與重現檔都現成，適合接在 #59 後面 |
| 62 | `src_interface` 0 與 999999 完全不做範圍檢查，原樣公布並流進 flow path | ⭕ UNASSIGNED | `src_interface` 在所有未併分支的改動行只命中 **1 次**，且是 `fix/deterministic-path-tiebreak` 的**測試檔**在讀 `edge["src_interface"]`，不是驗證 | 重現檔現成（`06_mutant_m4a_port_zero.log`、`07_mutant_m4b_port_six_digits.log`） |
| 63 | `--logfile` 文件寫得像吃路徑，實際是 boolean；指定的檔 0 bytes、stderr 無話 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 🆕 **`fix/logfile-takes-a-path @ 12291b17`**（base `feb9baef`），動 `src/utils/Logger.cpp`、`include/utils/Logger.hpp`、`src/main.cpp`＋新增 `tests/test_LoggerCliArgs.cpp`（19 cases）。閘門：**auditor 自己重跑**（走 `tools/build_guard/guarded_build.sh`）→ **9 mutations, 0 survived；3 widenings, 0 wrongly caught**；三個檔還原後 byte-identical、測試 binary sha 前後同為 `921e7e4fb44e3d3d` | ⚠️ **重跑是在 agent 自己的 worktree 裡做的**（乾淨 worktree 沒有已設定的 `build/`，冷編要 20 分鐘）——五個相關檔已逐一比對與分支 byte-identical，所以驗的是分支的內容，繼承的只有 build 目錄。🔴 **同族仍缺一塊**：不認得的旗標（`--logfle /tmp/x.log`）仍然靜默忽略 |

### Round 6 — 歷史 bug 形狀的未檢驗實例（64–68）

| # | 一句話 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 64 | 🔴 拓樸輪次的「完整性」檢查只測 body 非空，從不看 HTTP status | ✅ IN TRUNK（09-03 整合 `b466407b`） | `fix/topology-round-reads-status @ e970d716`（9 個檔）。逐 hunk 讀過：`buildTopologyFetchCommand` 加 `--write-out '\n@@ndt-topology-http-status@@%{http_code}'`（因為 `utils::execCommand` 是 popen，狀態碼**不是被忽略是根本拿不到**）；新 `EndpointOutcome{Ok,NoResponse,ReportedFailure,Unparseable,WrongShape}` ＋ `classifyEndpointReply()`；`classifyPollRound` 改吃 outcome 不吃 bool；`get_graph_data` 多一個 top-level `topology_round`。閘門：**作者** 19／19 綠、先看過紅、6 變異 0 存活；🟠 作者自己更正——**那 6 個變異是在共用工作樹上用手動連結的 binary 跑的**，乾淨 worktree 裡重跑的是 97/97 建置 ＋ 19/19 閘門 ＋ 878/878 全套件；🟠 **auditor 沒有重跑這一支** | 值得補一次乾淨 worktree 的變異重跑，那是這支唯一沒有乾淨證據的一格 |
| 65 | 三種「讀不到交換機」有三種行為，只有兩種被標記 | ✅ IN TRUNK（09-03 整合 `b466407b`） | 同上分支。實際 hunk：`StaleTableCarryForward.hpp` 新增 `kUnreadWrongShape = "wrong_shape"`；`DeviceConfigurationAndPowerManager.cpp` 的 `classifyFlowStatsReply()` 新增 `sawNonList` 掃描 → `FlowStatsVerdict::NotUnderstood`，命中時保留前一張表並推 `{dpid, kUnreadWrongShape}`；`{"3": []}`（誠實回報沒有規則）刻意不落進這一格。測試 `TwoHundredCarryingTheWrongShapeIsNotAnAnswer` 等在 `tests/test_TopologyPollRound.cpp` | 同 #64 |
| 66 | 交換機死掉後 flow table 照舊供應 10–12 秒且無 stale 標記 | ⭕ UNASSIGNED | `fix/topology-round-reads-status` 改的是**回應內容讀不懂時**的分類，不是**交換機死掉到第一次失敗輪詢之間**的那個窗口——該分支對 `m_flowStatsTimeouts`／`recordFailure()` 的觸發時機一行未改 | 與 #46（liveness 不會寫 false）是同一個時序家族 |
| 67 | power cycle 會弄丟操作者裝的規則且不還原，而 `get_flow_dispatch_status` 仍記為 succeeded | ⭕ UNASSIGNED | `get_flow_dispatch_status` 的記帳路徑在所有未併分支的改動行 0 次命中（`fix/p4-priority-…` 只在說明文字裡提到它） | 與 #54 同一個「succeeded 是什麼」的問題 |
| 68 | 兩個 elephant flag 是唯寫的（1 宣告、6 賦值、全樹 0 讀取，也不在端點的 15 個 key 裡） | ⭕ UNASSIGNED | `fix/flow-rate-denominator` 動了 `isElephantFlowPeriodically` 的**賦值**（改成用除過的速率判定，`SFlowType.hpp` 的 `updateFlowRatesForInterval`），但**沒有新增任何讀取點，也沒有把它放進任何 endpoint 的輸出**——旗標仍然唯寫 | 要嘛公開要嘛刪掉，這是一個裁決不是一段碼 |

---

## 1. `⭕ UNASSIGNED` 裡最該先派的五條

排序準則：**嚴重度 × 修起來要不要實驗室 × 有沒有現成規格**。實驗室今天 12:20 之後歸 Adam，
所以「離線能不能做完」是硬條件。

| 順位 | # | 為什麼是這一條 | 離線程度 |
|---|---|---|---|
| 1 | **#4** ovs4 沒有 sFlow | 嚴重度最高的可派項：`ovs4` 上**每一個流速率與鏈路使用率都結構性為零**，而「沒問到」與「網路很閒」在輸出上無法分辨——夜巡多條 OVS finding 的數字都活在這個陰影下。**規格是同一個 repo 裡的可運行實作**：`testbed_topo.py:105` 的 `enable_sflow()` ＋ `:202` 的呼叫點，照抄進 `ovs_4host_topo.py` 即可 | 🟡 **寫碼＋腳本層閘門完全離線**；只有「跑一次 ovs4 看數字不再是 0」需要實驗室 |
| 2 | **#46** 輪詢覆蓋關機指令（`isUp=true` 沒有 else） | 🔴 它是 #33／#35／#36 的共同寫入端，也是 D15 作者親自標明「**untouched here and not to be claimed**」的第二個獨立缺陷。機制、相位、時間點全部釘死了（失敗全在 t_off+2.31 s），**行號精確到 `TopologyAndFlowMonitor.cpp:762-777`** | 🟡 **else 分支 ＋ 單元閘門完全離線**（不需要 fabric 就能測「輪詢結果為 down 時會不會寫 false」）；相位回歸需要實驗室 |
| 3 | **#42** `testbed_topo.py` 的 banner 在 100% loss 上印三個 OK | 一個**出貨腳本**對使用者做了三項健康宣告，而它與自己的量測之間沒有任何資料流（`:228-239` 跑 ping、`:246` 無條件印）。這是「儀器說謊」家族裡最便宜的一條 | 🟢 **banner 那半完全離線可做完**（讓 `ping_test` 回傳結果、banner 依結果印）；「為什麼 self-test 100% loss 而手動 ping 0%」的根因才需要實驗室——**兩件事要分開派** |
| 4 | **#63** `--logfile` 是 boolean 不吃路徑 | 表面積最小、最自足的一條：單一檔案 `src/utils/Logger.cpp:29-33`，加上 `src/main.cpp:79` 的 usage 字串。而它的價值大於它的大小——**每一輪「我有收 log」的宣稱都掛在這個旗標上** | 🟢 **完全離線做完**（碼＋測試＋mutation gate 都不需要 fabric；建置照 MEMORY 的 `-j2` ＋ `systemd-run --user` 規矩） |
| 5 | **#50** `ndt:1687` 的 `2>/dev/null` 放錯邊 | 最便宜的一條，而且**驗收條件 FINDINGS 已經替你寫好了**：「用不存在的 pid 呼叫，斷言 stderr 為空」。三個同族站點（`:1687`／`:1999`／`:2034`），純 shell | 🟢 **完全離線做完**（`tests/shell/` 底下一支測試 ＋ 一把 mutation gate 就夠） |

🟢 **完全離線能做完的是 #63、#50，加上 #42 的 banner 那半**——那是現在唯一能派出去、
今天之內拿得到「碼＋閘門＋看過紅」完整交付的三件。
🟡 #4 與 #46 是**寫得完、驗不完**：碼與閘門今天做得完，最後那一格 live 確認要排到實驗室還回來。

**沒進前五、但排第六到第八的**（給下一輪用）：

- **#47**（socket 被 popen 的孤兒繼承 2 秒，錯誤訊息把人推向錯誤診斷）——嚴重且機制清楚，
  但 48/48 的重現要實驗室，而 `FD_CLOEXEC` 要加在哪幾個 socket 上得先讀一遍收包路徑。
- **#8**（`ndt status --check` 假紅＋零鑑別力）——規格現成（trunk `eae75da5` 的 `fabric_host_count` 形狀），
  但要先裁「`--check` 該拿哪份拓樸檔當基準」，那是裁決不是碼。
- **#1**（OVS group delete 無聲 no-op、id 永久洩漏）——嚴重度其實排得很前面，
  但它**只能在 ovs4 上重現**，今天連閘門的形狀都定不下來。

---

## 2. 一支分支涵蓋多條，以及誰跟誰會撞

### 2.1 一支涵蓋多條的

| 分支 | 涵蓋的 finding | 一句話 |
|---|---|---|
| `fix/ports-that-block-restart @ 2fe70075` | **#22, #23, #24, #41** | 四條同型 finding 被同一張表（`ports.sh`，9 列）一次解掉，而且是**接線**不是宣告——`cmd_clean`／`deep_sweep`／`preflight` 三個呼叫端都改讀表 |
| `fix/b5-kernel-shutdown @ e9f1326e` | **#5, #11, #12** | 一支分支三個缺陷：C++ 的漏 join、`check_logs.py` 的樣式表、`stack.sh` 的 `local` 求值序 |
| `fix/telemetry-health-visible @ b7aad224` | **#53, #56**（＋ #51 的「看不見」那半） | 一個 `telemetry_health` 物件掛在三個回應上 |
| `fix/d15-dataplane-kind-race @ 75c2b526` | **#32, #45** | 同一個啟動競態的根因與它的定量版本 |
| `fix/topology-round-reads-status @ e970d716` | **#64, #65** | 拓樸路徑與 flow-table 路徑共用同一套 outcome 詞彙（`wrong_shape` 同時加進兩邊） |
| `fix/flow-rate-denominator @ 6088c0b5` | **#10**（＋ #18 的高估那半） | — |


### 🆕 09-03 下午新增的兩條（#69／#70，修 #63 的過程中發現）

| # | 缺陷 | 狀態 | 證據 | 誰該接手 |
|---|---|---|---|---|
| 69 | 🔴 `--loglevel <打錯的值>` 把 log 整個關掉，rc 0、無訊息，而攔它的錯誤路徑不可能執行 | 🛠 派工中（18:3x，`fix/logger-cli-refuses-unknown`，base `431d98a5`，C++，建置排在 lock 後） | **auditor 親自讀碼查證**：`from_str` 在 `libs/spdlog/common.h:294` 與 `common-inl.h:38` **兩處都宣告 `SPDLOG_NOEXCEPT`** ⇒ `Logger.cpp:16` 的 `catch (const spdlog::spdlog_ex&)` 永遠到不了；`common-inl.h` 的結尾是 `return level::off;` ⇒ 不是「用預設等級」是**完全不記錄**。⚠️ **`origin/main` 逐字相同**，讀者也中 | `fix/logfile-takes-a-path` 已經**順手**加了 `AMistypedLevelIsRefusedRatherThanSilentlyDisablingLogging` 這條測試並在閘門 M8 驗過 ⇒ **併那支就一起修掉**。但它沒有被登記成一條 finding，所以列在這裡免得被當成「附帶效果」而沒有人對帳 |
| 70 | `Logger` 的 `--help` 在 kernel 裡不可達（`cli::parse` 先 `return 0`），而 `main.cpp` 的 usage 正指向那段印不出來的字；兩個 parser 對不認得的旗標都靜默忽略 | 🛠 派工中（同上，同一支） | 同上分支的旗標完整表；auditor 在 `origin/main` 上確認同一形狀 | 🔴 **靜默忽略未知旗標這半沒有人在修**，要讓兩個 parser 知道對方的旗標集合，是另一個改動 |
| 71 | 🔴 rule journal 在 production 從來沒被寫過，而 `test_journal_wiring.py` 14 個測試全綠（注入依賴，證明的是「給它 journal 它會寫」） | ✅ IN TRUNK（09-03 `486d89fb`，併 `fix/rule-journal-is-wired @ 1f3fd41f`；auditor 丟棄式樹重跑閘門 **14/0**、合併樹 25 個 proxy 模組全綠；三個裁決在 QUESTIONS N11） | auditor 查證：`main.py:26` 不傳 journal、`_note_in_journal` 第一行 `if … self._journal is None: return`；production 零 import | 修法＝`main.py` 建構真 `RuleJournal` 並注入＋一支**不注入**的接線測試（直接跑 `main` 的建構路徑），否則 A-4c 的 replay 永遠拿到空 journal |
| 72 | demo image 的 netplan 綁死 QEMU 的 MAC，換 hypervisor 沒網路 | ✅ 已修（image） | `開機手冊` session，`doc/audit/2026-09-03_virtualbox-demo-vm/REPORT.md`，紅綠都量；`ndtwin-vm.sh` 仍釘著該 MAC（工具側待修）；08-31「Untested on real VMware — closed」被降級（依據是 ovftool 轉檔，碰不到 netplan） | 工具側：`ndtwin-vm.sh` 的 MAC；VMware 真開機一次 |
| 73 | `KERNEL_ENDPOINTS` 手抄表漏 `GET /ndt/get_sflow_stats`，`test_l3_dispatch_drift` 在 trunk 紅 | ✅ IN TRUNK（09-03 `431d98a5`，併 `fix/inventories-follow-the-merges @ 8d492733`；auditor 在 trunk 看過紅、合併樹 28＋25 個 python 模組全綠） | auditor：沿 trunk first-parent 逐 commit 跑，`ea139d1c`（telemetry-health 併入）起紅 | 合併驗證缺口，見 MERGE-LOG「第七個教訓」 |
| 74 | `SHELL_SITES` 清單對不上被 `classifyEndpointReply(...)` 包起來的 `execCommand` 站點，`test_shell_command_construction` 兩個 case 紅 | ✅ IN TRUNK（同上；provenance 由 agent 重新推導：`m_ryuUrl` 唯一寫入點 `setTopologyApiUrls`，來源是兩個 build-time `AppConfig` 常數，無 HTTP handler 可達 ⇒ 清單漂移，不是注入路徑） | auditor：`d00fa57c`（topology-round 併入）起紅；我讀過 `url` 來源不變（`AppConfig` IP:port＋字面路徑） | agent 要再讀一次 provenance；若 request 可達 ⇒ 升級為真缺陷、不准只改清單 |
| 75 | `inv01_powercycle_latency()` 修好了（#17）但 `harness/chaos.py` 沒接，零呼叫點 | ⭕ UNASSIGNED | #17 agent 查證（FIX-CHAOS-INVARIANTS §未做到） | existence ≠ wiring；接之前要先定 INV-01 兩個檢查（agreement 已接、latency 沒接）的關係 |
| 76 | proxy 卡住時，bind 失敗的 kernel 印完 `Exiting` 後 8 秒還在（shutdown 卡在 poll thread 的 curl） | ⭕ UNASSIGNED | #47 agent 順帶觀察，未追 | 與 B-5 關機路徑同族；重啟腳本若拿「印了 Exiting」當退出訊號會踩到 |
| 77 | `ndt up ovs` 跑的是 NTG repo 那份 `testbed_topo.py`（同樣的常數橫幅），本 repo 的 #42 修法改不到那條路 | 🛠 派工中（20:4x，`fix/ndt-up-ovs-runs-repo-topo`，base trunk，N13 裁 (b)） | #42 agent 讀 caller 發現（`ndtwin-lab:571-580`） | 跨 repo；建議改 `ndtwin-lab` 跑本 repo 那份 |
| 78 | `check_gate_anchors.py` 對 repo 根目錄檔案用 `"/" in v` 判檔名，回報自信的錯答案 `MISSING:23` | ✅ IN TRUNK | `1ec39977`（merge of `fix/gate-anchors-root-files`，修法 `aed8f299`）：`tests/shell/check_gate_anchors.py` +1 述詞 `is_repo_path`／7 呼叫點、`tests/python/test_check_gate_anchors.py` +14 case（對 trunk 工具 9 FAIL＋3 ERROR）、`tests/shell/mutate_gate_anchors_root_files.sh` 13/0；全 repo 掃描 40/53→41/54、既有格一格沒動；raw `audit-raw @ 1cfbbc73`；MERGE-LOG 26 | #42 agent 撞到、閘門內以 `./` 繞過（繞道留著，兩種寫法都 `ok(23)`）；已知極限：名為 `foo.d` 的目錄會被放行、未修 |
| 79 | `ndt` claim／pids 是 per-checkout，多 worktree 下互相隱形 | ⭕ UNASSIGNED | auditor 讀 `tools/test_workflow/ndt`：`CLAIM=` 第 256 行、`.test_run/pids` 第 243 行，都由 `$REPO` 組出；沒有任何分支碰它 | 修法方向：claim／pid 目錄改到與 checkout 無關的位置（`/tmp/ndtwin-lab/` 或 `$XDG_RUNTIME_DIR`），要 Adam 點頭再派——它改的是交接協定 |
| 80 | liveness worker 用快取 `probe_ok` 把 `is_up` 寫回 true 8–13 s | ⭕ UNASSIGNED | poll agent 兩臂 18/18（raw 在 `audit-raw`）；沒有分支 | 與 Q12 綁在一起裁；候選修法：distrust window 改證據界定 |
| 81 | `handleInformSwitchEntered` 無條件 `setVertexUp` | ⭕ UNASSIGNED | `HttpSession.cpp:1449`（agent 讀碼）；沒有分支 | 小；可併入 #80 的工單 |
| 82 | OVS `powerOff` 的 `!isUp` 早退（#35 同型） | ⭕ UNASSIGNED | `OVSPowerStrategy::powerOff`（agent 讀碼）；沒有分支 | 先補 `br-exists` 量測；OVS 平面補一輪 live |

### 2.2 兩支動到同一段碼（合併衝突預警）

下面每一列都是我用 `git merge-tree --write-tree --messages <a> <b>` **實測**的，不是讀檔案清單推論的。

| A | B | 實測衝突 | 已經被記載了嗎 |
|---|---|---|---|
| `fix/d15-dataplane-kind-race` | `fix/topology-load-fails-before-listen` | `include/ndt_core/collection/TopologyAndFlowMonitor.hpp`、`src/.../TopologyAndFlowMonitor.cpp` | ✅ 已記（FIX-BRANCHES §5：先併 D15 再 rebase topoload） |
| `fix/g9-cleanup-no-pkill-f` | `fix/g7-ndtwin-lab-config` | `tools/test_workflow/ndtwin-lab` ＋ `NEXT.md`／`RATIONALE.md`（add/add） | ✅ 已記（BRANCHES-FOR-REVIEW） |
| **`fix/telemetry-health-visible`** | **`fix/flow-rate-denominator`** | **`include/ndt_core/collection/FlowLinkUsageCollector.hpp`** | 🔴 **沒有任何審查文件提過。** 兩支都在同一個 header 加東西（telemetry 加 `IngestHealth`／`classifyIngestHealth`；flow-rate 改速率函式的簽名與常數）。兩支都要進 trunk ⇒ 其中一支必須 rebase |
| `fix/d15-dataplane-kind-race` | `fix/b5-kernel-shutdown` | **只有 `tests/CMakeLists.txt`** | 🟠 **與既有記載不符（往好的方向）。** `6ad6811b` 預告的是 `DeviceConfigurationAndPowerManager.cpp` 的文字衝突；實測那個 `.cpp` **併得起來**，真正衝突的是兩支各自新增的測試檔在 `tests/CMakeLists.txt` 的同一段 |
| `fix/b5-kernel-shutdown` | `fix/telemetry-health-visible` | `tests/CMakeLists.txt` | 🟠 未記載。同上，是新測試檔的登記行相撞 |

🆕 **12:5x — 那個 telemetry × flow-rate 衝突，auditor 拆開看過了，它比看起來輕。**
`FlowLinkUsageCollector.hpp` 只有**一個**衝突區塊（`302`–`396`），而且兩邊放的是**互不相干的新增**：
telemetry 那半是 `struct IngestHealth` ＋ `classifyIngestHealth`，flow-rate 那半是
`lastFlowRateDivisorSeconds()`。**兩邊都插在 class 的同一個位置，所以 git 判不出來——但語意上沒有重疊。**
解法是**兩塊都留**，不需要取捨；`.cpp` 兩邊自動合得起來（實測）。⇒ **先併誰都可以，第二支 rebase 時
手動保留兩塊即可。** 之所以值得寫下來，是因為「`CONFLICT (content)` 在同一個 header」在審查表上長得像
「兩支在搶同一段邏輯」，而它不是。

🆕 **12:5x 新增一對（auditor 實測）**：`fix/ndt-sudo-surface` × `fix/ports-that-block-restart`
在 `tools/test_workflow/ndt` **衝突**——兩支都在改同一支腳本的相鄰區域（一個加 sudo 表、一個加 port 表）。
vs `fix/g6-ndt-apps-liveness` 與 `fix/g9-cleanup-no-pkill-f` 則都乾淨。

**沒有衝突、可以放心的兩對**（也實測過，列出來免得別人重做）：
`fix/topology-load-fails-before-listen` × `fix/l9-make-topology-stdout-json`（兩支都動
`tools/make_topology.py`，**不衝突**）；`fix/ports-that-block-restart` × `fix/g9`／`fix/g7`
（三支都動 `tools/test_workflow/ndtwin-lab`，ports 只加 6 行註解，**不衝突**）。

**合併順序的一句話結論**：`B-5` → `D15` → `topoload`，這條鏈是硬的（D15 的閘門在自己分支上
關不起來，要 B-5 的第三個 join；topoload 與 D15 同檔同區）。`tests/CMakeLists.txt` 是四支
C++ 分支的共同碰撞點（B-5／D15／telemetry／topology-round），每一次併都要看那個檔。

---

## 3. 這張表本身的限制

**我用的方法（三步，全部唯讀）**

1. 用 `git for-each-ref` ＋ 逐支 `git rev-list --count <merge-base>..<branch>` 把 30 支 `fix/*`
   縮到**真正未併的 13 支**，再加 4 支非 `fix/*` 的（ahead>0）。
2. 對這 17 支各跑一次 `git diff <merge-base>..<branch>`，把 **doc/ 與 `*.md` 以外**的改動行
   （9,196 行）抽成一份語料，得到一張**「哪支分支動了哪個原始碼檔」的完全清單**。
3. 對每一條 finding 取它的識別符（函式名／常數名／port 號／檔案:行號），先在那份語料裡搜，
   命中就**打開那個 commit 的 diff 逐 hunk 讀**（#22/#41 的 `cmd_clean` 接線、#64/#65 的
   `classifyEndpointReply`／`NotUnderstood`、#6 的 `app_sig viz`、#21 的 `cleanup` rc 都是這樣判的）；
   零命中就再回 trunk 確認那段碼還在原處、且那個檔不在任何分支的變更檔清單裡。

**這個方法會漏掉的四類**

1. 🔴 **改了名字的修法。** 我搜的是 finding 裡出現的識別符。一支分支若把
   `handleDeleteGroupEntry` 重寫成別的名字、或把整段搬到新檔，我的零命中會把它讀成
   「沒人修」。**緩解**：第 2 步的變更檔清單是完整的，所以我至少知道「那個檔有沒有被動過」——
   但**檔案沒被動過**才是我真正的強證據，**識別符零命中**只是弱證據。上表凡是靠後者的，
   我都同時寫出了檔案層級的判斷。
2. 🔴 **未提交的工作樹修改。** 共用工作樹裡現在就躺著至少三份未提交的修改
   （`fix/deterministic-path-tiebreak` 的三個 p4_proxy 執行檔、D15 的較早一版、
   `stack.sh` 的 177 行 supervise/report_exit），FIX-BRANCHES-FOR-REVIEW 已記。
   **我只讀 commit，所以任何只存在於工作樹的修法在這張表上一律是 ⭕。**
   `fix/telemetry-health-visible` 就是這樣差點消失的（作者死掉、東西全在工作樹）。
3. **repo 外的修法。** #37（Energy-Saving-App）、#43（NSR）、#44（Web GUI）的對象不在本 repo，
   我對它們的「沒人修」只在本 repo 範圍內成立，那是**四個 repo 裡的一個**。
4. **語意等價但不是同一條 finding 的修法。** 例如 `t8-t10-fixes` 的 `39ee5484` 修的是
   `verify_p4` 的「model matches fabric」，跟 #8 的 `ndt status --check` 長得**很像**但不是同一段碼；
   我把它判成 #8 未修。若有人認為那兩個檢查該一起改，我的分類會讀起來偏保守。

**另外三件要一起讀的**

- **✅ IN TRUNK 只證明碼進了 trunk，不證明缺陷消失。** 九條 IN TRUNK 全是工具／閘門層的修法，
  每一條都有變異閘且都在 trunk 上，但**沒有一條在 live fabric 上重驗過**。
- **🔧 ON BRANCH 的閘門品質差四個等級**，證據欄逐條寫了，這裡總結：
  ① auditor 重跑過的四支（tie-break、ports、p4-priority、topoload 的 Python 半）；
  ② auditor 親自編譯過的兩支（D15 3/4、telemetry 17/18，**兩支的結果都推翻了作者的預測**）；
  ③ 作者宣稱＋raw log 有 commit 的一支（B-5）；
  ④ 只有作者宣稱、分支上沒有可對帳輸出的五支（flow-rate、G-6、G-7、G-9、L-9）。
  **④ 那一組的「N mutations, 0 survived」我無法從分支本身驗證**，上表照抄了它們的宣稱並標明來源。
- 🔴 **這批修法沒有一支在 live fabric 上驗過**（AUDITOR-VERIFICATION.md 自己這樣寫）。
  所以整張表回答的是「**誰在修**」，不是「**修好了沒**」。這兩個問題今天都還沒有人能回答第二個。

[Co-developed with claude code -- Adam]

### 🛠 16:xx 第二批派工（Adam：「實驗室現在應可以用，你就繼續把剩下的 bug 修一修」）

四支 opus agent，全部從 `integrate/2026-09-03-auditor-merge @ 5c64d432` 長，檔案互不重疊（`ndt` 那兩支各動不同區塊，已要求互測 merge-tree）：

| 分支 | findings | 需要實驗室 | 閘門要求 |
|---|---|---|---|
| `fix/poll-does-not-resurrect` | #46（＋#36、#35 同根） | 是（p4 4，round3 phase-A 配方） | gtest＋兩面變異閘；**不改 API 欄位形狀**（Q12 未裁） |
| `fix/cloexec-listening-sockets` | #47 | 是（port 釋放時長、窗口內重啟） | fd flag 的 gtest＋spawn 子行程看不到 fd＋變異閘；完整的 popen/system 呼叫點表 |
| `fix/apps-stop-kills-the-group` | #6／#48（W-2）＋log 上限 | 否（假 app） | shell 測試＋兩面變異閘；副本要帶兩張表 |
| `fix/ovs4-has-sflow` | #4 | 是（ovs4，對照 ovs 128） | Python 測試＋變異閘＋`verify_ovs` 的紅 |

實驗室以 `ndt claim` 排隊（各自 `NDT_OWNER`），平面明寫，不動別人的 fabric；建置走 `guarded_build.sh`（全機一把鎖）。

### ✅ 09-03 17:xx：18 支修法全部進 trunk（`b466407b`）

上表 17 列從「在分支上」改為「已在 trunk」。過程與每一支的驗證在 `MERGE-LOG.md`。
仍標「在分支上」但分支不在這 18 支裡的列：#🔧 ON BRANCH, #12, #23, #24, #65。

### 🛠 17:xx 第三批派工（離線、Python、不與前一批撞檔）

| 分支 | findings | 需要實驗室 | 閘門要求 |
|---|---|---|---|
| `fix/rule-journal-is-wired` | #71 | 否 | 一支**不注入**的接線測試（走 `main.py` 真建構路徑，修前必須紅）＋兩面變異閘；replay 預設不自動開 |
| `fix/chaos-invariants-method` | #17（第四例） | 否 | 照第三例 `efd2fe10` 的形狀；harness 所有 HTTP 呼叫對照 `components.py` 的完整表 |

前一批仍在跑：`fix/poll-does-not-resurrect`（#46/36/35）、`fix/cloexec-listening-sockets`（#47，現持 lab claim）、`fix/apps-stop-kills-the-group`（#6/48）。

