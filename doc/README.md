# doc/ — 這裡有什麼，哪些還算數

**每個檔名開頭是它的建立日期**（不是最後更新日——後者每編輯一次就要改名並修所有引用）。
所以**檔名的日期不代表內容有多舊**：`2026-01-02_ndt_api.md` 是 2026-01-02 建立的，但它
每週都在更新，是現役規格。要知道一份文件現在算不算數，看下面的**地位**欄，不要看檔名。

**沒有 expired/ 資料夾，這是刻意的。** 這裡的歷史文件多半是**寫的時候正確**的紀錄，用
「與現況相符」去判它們是錯的判準（同樣的原則寫在 [audit/README.md](audit/README.md)）。
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
| [2026-07-29_HANDOFF.md](2026-07-29_HANDOFF.md) | 未結的決策與開放工作。是待辦清單，不是說明書 |
| [2026-01-02_ndt_api.md](2026-01-02_ndt_api.md) | `/ndt/*` 的 41 個端點，與 dispatcher 逐條相符。7 個兄弟元件與 kernel 之間唯一的介面 |

---

## 規格與設計

| 檔案 | 地位 | 內容 |
|---|---|---|
| [2026-01-02_ndt_api.md](2026-01-02_ndt_api.md) | **現役** | API 規格，41 端點（§1–§41）。其中 30 個有機器檢查（`tools/contract_test/`） |
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

## 調查與報告

| 檔案 | 地位 | 一句話 |
|---|---|---|
| [2026-08-14_cross-component-integration-matrix.md](2026-08-14_cross-component-integration-matrix.md) | **現役** | 8 元件串接矩陣。跨 repo 的事先讀它 |
| [2026-08-15_bmv2-performance-report.md](2026-08-15_bmv2-performance-report.md) | **現役** | bmv2 效能：debug build 的代價、A/B 飽和實測（12–18×）。**含一節撤回案（clone cap 從來不存在），引用前先看那節** |
| [2026-08-16_src-ip-endianness-review.md](2026-08-16_src-ip-endianness-review.md) | **現役** | `src_ip` 是三消費端依賴的既成契約；末節是 TE priority/idle_timeout 的更正 |
| [2026-08-13_p4runtime-mastership-spec-check.md](2026-08-13_p4runtime-mastership-spec-check.md) | 已結案 | 結論是**上游沒有 bug**、肇因在我方 election id 重用。它是更正稿，別引用它的舊版標題 |

## 草稿與交付

| 檔案 | 地位 | 下一步是誰 |
|---|---|---|
| [2026-08-16_delivery-package/](2026-08-16_delivery-package/) | **待轉交** | **Adam**：NTG 三條給 NTG 維護者、手冊條目與三條勘誤給 patty。三檔已定稿、內部前言已移除 |
| [2026-08-15_ntg-upstream-report-draft.md](2026-08-15_ntg-upstream-report-draft.md) | 草稿（原稿） | 乾淨版在投遞包裡；這份保留內部前言 |
| [2026-08-15_bmv2-performance-build-public-manual-draft.md](2026-08-15_bmv2-performance-build-public-manual-draft.md) | 草稿（原稿） | 同上 |
| [2026-08-16_p4lang-clone-stacking-issue-draft.md](2026-08-16_p4lang-clone-stacking-issue-draft.md) | **已結案：不投遞** | 沒有人。Adam 2026-08-17 裁決只歸檔；我方曝險已由 settle pair (`79e4f69`) 關閉 |

## 廠商參考（baseline 時期）

| 檔案 | 地位 |
|---|---|
| [2026-01-02_OpenflowFlowEntryExamplesMininet.md](2026-01-02_OpenflowFlowEntryExamplesMininet.md) | 歷史（OVS flow entry 語法範例；除本索引外 repo 內零引用，檔頭已有警語） |
| [2026-01-02_OpenflowFlowEntryOperationExamples.md](2026-01-02_OpenflowFlowEntryOperationExamples.md) | 歷史（HPE 交換器操作範例，同上） |
| [2026-01-02_OpenflowCapacity.json](2026-01-02_OpenflowCapacity.json) | 參照（OVS/HPE 的容量數字） |

## 資料夾

| 資料夾 | 地位 | 內容 |
|---|---|---|
| [audit/](audit/) | 歷史紀錄集合 | 審查／複驗／測試證據。**先讀它的 [README.md](audit/README.md)**——它說明了各子資料夾、為什麼產出報告的 prompt 一起收在旁邊、以及哪七類刻意留在 repo 外 |
| [2026-08-16_delivery-package/](2026-08-16_delivery-package/) | 待轉交 | 見上 |
| [debug-log/](debug-log/) | 現役（空目錄） | 給執行期 log 落腳用，靠 `.gitkeep` 保留 |

`audit/` 底下有一個看起來放錯地方的 [2026-07-30_audit-be3c242/](audit/2026-07-30_audit-be3c242/)
——它是第一輪十階段子系統審查，2026-08-17 才從 `doc/` 頂層搬進去；**在那之前它在外面不是
歸檔錯誤，是它比 `audit/` 早誕生**。理由與「引用它但不要複製它」那條規則寫在
[audit/README.md](audit/README.md)。
