# doc/ — 這裡有什麼，哪些還算數

**每個檔名開頭是它的建立日期**（不是最後更新日——後者每編輯一次就要改名並修所有引用）。
所以**檔名的日期不代表內容有多舊**：`2026-01-02_ndt_api.md` 是 2026-01-02 建立的，但它
每週都在更新，是現役規格。要知道一份文件現在算不算數，看下面的**地位**欄，不要看檔名。

**沒有 expired/ 資料夾，這是刻意的。** 這裡的歷史文件多半是**寫的時候正確**的紀錄，用
「與現況相符」去判它們是錯的判準。
而搬檔案的代價是實的：上一次大規模改名（`9e3874c`，105 個改名、532 處引用）當場改壞了
repo 外的一組連結。所以這份索引取代分區——標記地位，不動路徑。

四種地位：

- **現役** — 現在就該讀、內容維護中。
- **參照** — 正確但不是入口；要深入某個主題時才打開。
- **歷史** — 寫的時候正確，之後沒有跟著現況更新。**引用前必須對源碼重新查證。**
- **草稿／已結案** — 產出物，等著被送出去或已經有了結局。

[Co-developed with claude code -- Adam]

---

## 先讀這三份

| 檔案 | 為什麼是它 |
|---|---|
| [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md) | **「我現在該跑什麼」的唯一入口**；**§2 是完整的開機手冊**（清空／起 bmv2 與 OVS／切拓樸／改參數／Mininet 與 NTG／開 app／收尾／故障排除）。其餘七份測試文件的地位也列在它裡面 |
| [2026-01-02_ndt_api.md](2026-01-02_ndt_api.md) | `/ndt/*` 的 41 個端點，與 dispatcher 逐條相符。7 個兄弟元件與 kernel 之間唯一的介面 |

---

## 規格與設計

| 檔案 | 地位 | 內容 |
|---|---|---|
| [2026-01-02_ndt_api.md](2026-01-02_ndt_api.md) | **現役** | API 規格，41 端點（§1–§41）。其中 30 個有機器檢查（`tools/contract_test/`）。⚠️ **裡面的「這個在分支上、不在 `trunk`」但書會過期**：分支併進 trunk 時沒有人回來撤它。09-12 實測 §2b／§2c 的「trunk 回 404 / branch-only」在 `d7aa176e` 已假（端點 09-10 併入，實際回 200）——那兩處已改；**同檔還有 8 處同形狀的但書指向已經在 trunk 上的分支（`w8`／`w8b`／`w11`），尚未逐條重查**。引用任何一條之前，先對你手上的 kernel 打一次 |
| [2026-07-27_p4_bmv2_support_plan.md](2026-07-27_p4_bmv2_support_plan.md) | **現役** | P4/bmv2 支援的 Phase 0–8 規格與進度 |
| [2026-08-11_phase7_power_mechanism_design.md](2026-08-11_phase7_power_mechanism_design.md) | **現役** | Phase 7 電源機制的三個設計決定與 live 驗收結果。機制已完成 |
| [2026-07-29_environment_gotchas.md](2026-07-29_environment_gotchas.md) | **現役** | 這台機器的環境陷阱（sudo、pgrep 數錯、殘留清理）。踩到怪事先翻它 |

## 測試

七份都在 [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md) §6 有逐份說明，這裡只列地位：

| 檔案 | 地位 |
|---|---|
| [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md) | **現役（入口）** |
| [2026-08-10_p4_manual_test_runbook.md](2026-08-10_p4_manual_test_runbook.md) | **現役**（手動 runbook） |
| [2026-08-10_ovs_manual_test_runbook.md](2026-08-10_ovs_manual_test_runbook.md) | **現役**（手動 runbook） |
| [2026-08-07_testing_tools_overview.md](2026-08-07_testing_tools_overview.md) | 參照（每個工具的完整說明） |
| [2026-07-27_testing_workflow.md](2026-07-27_testing_workflow.md) | 參照（L0–L5 分層的定義與理由） |
| [2026-07-28_test_coverage_gaps.md](2026-07-28_test_coverage_gaps.md) | 參照（涵蓋範圍與已知缺口，2026-07-28 的清單） |
| [2026-07-30_full_test_runbook.md](2026-07-30_full_test_runbook.md) | 歷史（早於 wrapper／`local_ci.sh`／`run_layers.sh`，不要照抄指令） |
| [2026-07-29_p4_status_and_test_guide.md](2026-07-29_p4_status_and_test_guide.md) | 歷史（「目前進度」是 2026-07-30 的） |

**量測輪的起草程序**（不在上面七份之列，是給預註冊用的）：

| 檔案 | 地位 | 一句話 |
|---|---|---|
| [2026-08-31_vm-image-shipping-checklist.md](2026-08-31_vm-image-shipping-checklist.md) | **現役** | **任何要離開這台機器的 VM 映像／tarball 的出貨前清單**（三項：`.git` 歷史帶陽性對照／`fstrim`／成品大小 vs 檔案系統用量對帳）。🔴 **它是清單不是規則**——同一套匯出程序 08-31 在兩個產物上各出一次事、症狀完全不同（一顆帶著雙盲投稿的 `.git` 出去、一顆 57% 是沒 discard 的區塊）⇒ **根因是沒有出貨前檢查，不是少了某一步** |

## 調查與報告

| 檔案 | 地位 | 一句話 |
|---|---|---|
| [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | **現役** | 已知未修缺陷的常設清單。排序軸是「示範或正常操作會不會踩到」，不是嚴重度；每條標失效方向（樂觀／悲觀／靜默）。普查基準日 2026-08-19，08-29 增補 §F-bmv2 與 F-17 更正。🔴 **引用任何舊條目前必須重查現況**——它自己載明衰減不均勻 |
| [2026-08-28_bmv2-throughput-literature-vs-ours.md](2026-08-28_bmv2-throughput-literature-vs-ours.md) | 參照 | 四篇 bmv2 效能論文與本機實測的對照。⚠️ 它自陳**不是文獻回顧**（兩次關鍵字搜尋、沒做系統性檢索）⇒ 只能說「這四篇沒寫 X」，不能說「文獻裡沒人寫 X」。 |
| [2026-08-13_p4runtime-mastership-spec-check.md](2026-08-13_p4runtime-mastership-spec-check.md) | 已結案 | 結論是**上游沒有 bug**、肇因在我方 election id 重用。它是更正稿，別引用它的舊版標題 |

## 草稿與交付

| 檔案 | 地位 | 下一步是誰 |
|---|---|---|
| [2026-08-16_delivery-package/](2026-08-16_delivery-package/) | **待轉交** | 安裝手冊的維護者：bmv2 效能 build 的手冊條目（`bmv2-manual-entry.md`，目錄裡只有這一份） |

## 廠商參考（baseline 時期）

| 檔案 | 地位 |
|---|---|
| [2026-01-02_OpenflowFlowEntryExamplesMininet.md](2026-01-02_OpenflowFlowEntryExamplesMininet.md) | 歷史（OVS flow entry 語法範例；除本索引外 repo 內零引用，檔頭已有警語） |
| [2026-01-02_OpenflowFlowEntryOperationExamples.md](2026-01-02_OpenflowFlowEntryOperationExamples.md) | 歷史（HPE 交換器操作範例，同上） |
| [2026-01-02_OpenflowCapacity.json](2026-01-02_OpenflowCapacity.json) | 參照（OVS/HPE 的容量數字） |

## 資料夾

| 資料夾 | 地位 | 內容 |
|---|---|---|
| [audit/](audit/) | 測試基礎設施（暫放） | 測試與 lab 工具仍在使用的腳本、fixture 與資料檔，之後會搬到 `tools/` 與 `tests/`。見 [README.md](audit/README.md) |
| [audit/2026-08-28_chaos-harness/harness/](audit/2026-08-28_chaos-harness/harness/)、[audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py](audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py) | **現役工具（住在紀錄裡）** | 🔴 **這兩份不是紀錄，是活的工具**，只是寫在某一輪的目錄裡就沒搬出來過。harness 的 suite 與變異閘在 `tests/python/test_chaos_*.py`（5 支）與 `tests/shell/mutate_chaos_*.sh`（5 支）；`cpu_gate.py` 被 `tests/python/test_cpu_gate_lifetime.py` **按這條路徑 import**（它自己的 docstring：複製一份過去等於測一份複本）、被 `tests/shell/mutate_cpu_gate_lifetime.sh` 直接變異。⇒ 它們是 `tests/shell/check_process_by_name.py` `AUDIT_EXCEPTIONS` 的**兩筆登記例外**（見下） |
| [2026-08-16_delivery-package/](2026-08-16_delivery-package/) | 待轉交 | 見上 |
| [debug-log/](debug-log/) | 現役（空目錄） | 給執行期 log 落腳用，靠 `.gitkeep` 保留 |
| [../tools/remote-lab/](../tools/remote-lab/) | **現役** | 遠端 lab 機器的**佔用協調**（`rlab`＝機器層、`ndtwin-vm.sh`＝VM 層）與 VM 生命週期，含變異閘 **100/100**（G10a 是結構測試：**母體從 dispatch 導出**，斷言每個動詞都被歸類且改動性動詞都有守衛——32/32 全綠時 `stop`／`ssh` 根本沒有守衛，而**接手的 G10 迴圈的是手寫清單，加新動詞照樣全綠**，見 `tools/remote-lab/test_vm_coordination.sh` 的 G10a 與 [README](../tools/remote-lab/README.md) 的「56 → 66（G10a）」節）。**規定與佔用帳的正本不在那裡，也不在本 repo**——工具說「怎麼做」，規定說「可不可以做、要登記什麼」。🔴 **動手前先讀規定：R1 要求開跑前登記、不准事後補登** |

### `audit/` 底下的 lint 規則：預設不掃，活工具走登記（2026-09-12）

`tests/shell/check_process_by_name.py`（「不准用名字找／殺行程」那支）**預設不掃 `audit/**`**：
那底下原本是某一天量到什麼的紀錄，**為了讓 lint 過而改紀錄＝篡改證據**；紀錄移出之後，留下的是測試與 lab 工具還在用的腳本與 fixture。

例外不是 glob 裡的硬字串，是 `AUDIT_EXCEPTIONS` 這張**登記表**（路徑＋為什麼算活的＋登記日期），
而且**兩個方向都查**——登記了卻一個檔都對不到，就是它搬走或被刪了，紅。
每次跑都會印 `N registered audit exceptions scanned`。
**入表的判準只有一條：活樹（`tests/`／`tools/`／`p4_proxy/`／`src/`）有東西會「執行或變異」它。
引用它、連結它、在報告裡提到它，都不算。**

2026-09-12 盤點過一次：`audit/` 底下 130 支 `.py`，其中 13 支提到行程名工具（`pgrep`／`pkill`／
`killall`／`pidof`）——**5 支是活工具**（harness 4 支＋`cpu_gate.py`，都已登記）、**6 支是一次性
腳本**（提到它們多半是在說明自己為什麼**不**那樣做）、**2 支 repo 內零引用**：
一支某輪的逐臂 CPU 分析腳本，
以及一份 `cpu_gate.py` 的副本
（與正本**位元相同**，且沒有人按全路徑引用它）。
兩支死檔後來隨紀錄一起移出 repo。現在 `audit/` 底下剩 28 支 `.py`，其中 6 支提到行程名工具：上面 5 支已登記的活工具，加上未登記的 `2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py`。活的工具之後會搬到 `tools/` 與 `tests/`（見 [audit/README.md](audit/README.md)）。
