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

**量測輪的起草程序**（不在上面七份之列，是給預註冊用的）：

| 檔案 | 地位 | 一句話 |
|---|---|---|
| [2026-08-31_prereg-inheritance-checklist.md](2026-08-31_prereg-inheritance-checklist.md) | **現役** | 起草新一輪預註冊前的必經步驟。**不繼承可以，靜默地不繼承不行**——母體是上一輪**實際執行過的腳本**（不是它的註冊），且「腳本裡有」與「註冊裡有」要分兩欄記 |
| [2026-08-31_vm-image-shipping-checklist.md](2026-08-31_vm-image-shipping-checklist.md) | **現役** | **任何要離開這台機器的 VM 映像／tarball 的出貨前清單**（三項：`.git` 歷史帶陽性對照／`fstrim`／成品大小 vs 檔案系統用量對帳）。🔴 **它是清單不是規則**——同一套匯出程序 08-31 在兩個產物上各出一次事、症狀完全不同（一顆帶著雙盲投稿的 `.git` 出去、一顆 57% 是沒 discard 的區塊）⇒ **根因是沒有出貨前檢查，不是少了某一步** |
| [2026-08-31_round-closing-checklist.md](2026-08-31_round-closing-checklist.md) | **現役** | **收輪時**讀（上面那份是開輪前讀）。第一項是「本輪 raw 已落 `audit-raw` ＋ sha」——因為 pre-commit hook 只擋 raw 落到工作分支，**沒有任何東西檢查它進了 audit-raw**，而 08-31 普查發現 15 輪、533.2 MiB 從沒進去過且無人宣稱相反。**沒有事件可以掛，就得自己排一個**，這份就是那個事件 |

## 調查與報告

| 檔案 | 地位 | 一句話 |
|---|---|---|
| [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | **現役** | 已知未修缺陷的常設清單（966 行）。排序軸是「示範或正常操作會不會踩到」，不是嚴重度；每條標失效方向（樂觀／悲觀／靜默）。普查基準日 2026-08-19，08-29 增補 §F-bmv2 與 F-17 更正。🔴 **引用任何舊條目前必須重查現況**——它自己載明衰減不均勻 |
| [2026-08-30_manual-verification-report.md](2026-08-30_manual-verification-report.md) | **現役** | 官網手冊驗證線的彙整（給教授簡報用）：安裝→能跑→UM/DM，兩級證據分開標，正本索引在文末。數字以各 FINDINGS 為準 |
| [2026-08-14_cross-component-integration-matrix.md](2026-08-14_cross-component-integration-matrix.md) | **現役** | 8 元件串接矩陣。跨 repo 的事先讀它 |
| [2026-08-15_bmv2-performance-report.md](2026-08-15_bmv2-performance-report.md) | **現役** | bmv2 效能：debug build 的代價、A/B 飽和實測（12–18×）。**含一節撤回案（clone cap 從來不存在），引用前先看那節** |
| [2026-08-28_bmv2-throughput-literature-vs-ours.md](2026-08-28_bmv2-throughput-literature-vs-ours.md) | 參照 | 四篇 bmv2 效能論文與本機實測的對照。⚠️ 它自陳**不是文獻回顧**（兩次關鍵字搜尋、沒做系統性檢索）⇒ 只能說「這四篇沒寫 X」，不能說「文獻裡沒人寫 X」。較完整的對照在 [audit/2026-08-28_bmv2-literature-review/RELATED-WORK.md](audit/2026-08-28_bmv2-literature-review/RELATED-WORK.md) |
| [2026-08-16_src-ip-endianness-review.md](2026-08-16_src-ip-endianness-review.md) | **現役** | `src_ip` 是三消費端依賴的既成契約；末節是 TE priority/idle_timeout 的更正 |
| [2026-08-13_p4runtime-mastership-spec-check.md](2026-08-13_p4runtime-mastership-spec-check.md) | 已結案 | 結論是**上游沒有 bug**、肇因在我方 election id 重用。它是更正稿，別引用它的舊版標題 |

## 草稿與交付

| 檔案 | 地位 | 下一步是誰 |
|---|---|---|
| [2026-08-29_bmv2-performance-study.md](2026-08-29_bmv2-performance-study.md) | **草稿（現役維護中）** | **全定稿**：§4 由四工單收案填滿——①＝H2 主張收窄（三跳 12×／單跳 8.0×，`e82ac6f`）、②＝H1「16× 歧義」（`c3bfe50`）、③＝兩臂單調（`387d3ea`）；唯 OVS 同梯對照待裁；下一步＝Adam 的 full paper 底稿 |
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
| [audit/2026-08-31_p4-source-tree-residue/](audit/2026-08-31_p4-source-tree-residue/) | **現役** | 🔴 **不是原始碼、不能 build。** `/home/adam/P4_Source_Code`（3.5 GB，p4 工具鏈 build tree）待刪，這裡是刪之前撈出來的殘留證據：唯一那份沒 commit 過的 `install-p4dev-v8.sh` 手改（58+/38-）、四份 diff，以及 `git status` 看不到的 `behavioral-model/config.log`——它的第 7 行就是 [audit/bmv2-binary-provenance.md](audit/bmv2-binary-provenance.md) 與 [2026-08-15_bmv2-performance-report.md](2026-08-15_bmv2-performance-report.md) 逐行引用的 `-O0` configure 命令。§3 列出「還有什麼只在那棵樹裡」的母體，§5 列出樹沒了之後會斷的東西。⚠️ **`log.txt` 與 `install-details/` 不是那顆 binary 的 build log**（§2.5）。27 MB 的 raw 在 `audit-raw:p4-source-tree-residue-2026-08-31/` |
| [2026-08-16_delivery-package/](2026-08-16_delivery-package/) | 待轉交 | 見上 |
| [debug-log/](debug-log/) | 現役（空目錄） | 給執行期 log 落腳用，靠 `.gitkeep` 保留 |
| [../tools/remote-lab/](../tools/remote-lab/) | **現役** | 遠端 lab 機器的**佔用協調**（`rlab`＝機器層、`ndtwin-vm.sh`＝VM 層）與 VM 生命週期，含變異閘 **73/73**（G10a 是結構測試：**母體從 dispatch 導出**，斷言每個動詞都被歸類且改動性動詞都有守衛——32/32 全綠時 `stop`／`ssh` 根本沒有守衛，而**接手的 G10 迴圈的是手寫清單，加新動詞照樣全綠**，見 [FINDING-a-fix-needs-its-own-mutation](audit/2026-08-31_completeness-experiments/FINDING-a-fix-needs-its-own-mutation.md)）。**規定與佔用帳的正本不在那裡**，在 [audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md](audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md)——工具說「怎麼做」，規定說「可不可以做、要登記什麼」。🔴 **動手前先讀規定：R1 要求開跑前登記、不准事後補登** |

`audit/` 底下有一個看起來放錯地方的 [2026-07-30_audit-be3c242/](audit/2026-07-30_audit-be3c242/)
——它是第一輪十階段子系統審查，2026-08-17 才從 `doc/` 頂層搬進去；**在那之前它在外面不是
歸檔錯誤，是它比 `audit/` 早誕生**。理由與「引用它但不要複製它」那條規則寫在
[audit/README.md](audit/README.md)。
