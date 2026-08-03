# NDTwin-Kernel 程式碼審查工作流程規劃

本文件是**規劃**，不是審查結果。它把整個 repo 切成 10 個各自獨立的審查階段，每個階段附一份可以直接複製貼上、獨立成立的 prompt。

使用方式：開一個全新的 agent session，把該階段的 prompt 整段貼進去執行。每個 prompt 都完整重述了所有背景與檢查清單，**不依賴任何其他階段的內容**，順序也可以任意調換。

---

## 探索結果：這個 repo 實際上長什麼樣

排除建置產物（`build/`、`build-asan/`、`Testing/`、`.test_run/`）、Python 虛擬環境（`p4_proxy/venv/`）、`__pycache__/`、以及 vendored 第三方函式庫（`libs/spdlog`、`libs/nlohmann`）之後，原始碼約 **35,500 行**：

| 區塊 | 檔案數 | 行數 | 備註 |
|---|---:|---:|---|
| C++ 核心 `src/` + `include/` | 69 | 20,801 | 10 個 CMake static lib target + `main.cpp` |
| C++ 單元測試 `tests/` | 14 `.cpp` + 32 fixture | 3,786 | 全部編進**單一** binary `test_routing_strategy`，共 156 個 gtest case |
| P4 proxy 服務 `p4_proxy/proxy_agent/` | 7 `.py` | 1,787 | Flask/HTTP + P4Runtime gRPC + sFlow emitter |
| P4 proxy 測試 `p4_proxy/tests/` | 9 `.py` | 2,022 | 135 個 test function（含大量條件 skip）+ 2 支非測試的產生器腳本 |
| P4 程式與 mininet `p4_proxy/p4_src/`、`p4_proxy/mininet/` | 2 原始檔 + 產物 | 781 | `ndtwin_switch.p4` 482 行 |
| 測試工具 `tools/` | 15 | 4,606 | `test_workflow/` L0–L1 + 編排；`contract_test/` L2–L4 |
| 根目錄控制面/資料面腳本 | 6 `.py` | 1,009 | `intelligent_router.py` 728 行是 Ryu app |
| 設定 `setting/` | 10 | — | `AppConfig.hpp.example` + 8 個拓撲 JSON |

### 每個階段都必須知道的環境事實

這些是探索過程中查證出來的，會直接影響審查判斷，因此在**每一份 prompt 裡都重述了一次**：

1. **這個 repo 沒有任何自動 CI。** 沒有 `.github/`，沒有 workflow 檔。`tools/test_workflow/run_layers.sh` 是一支**人工**執行的驅動腳本。所以任何「這個有在 CI 裡跑」的說法都是待查證的主張，不是既定事實。
2. **`tests/CMakeLists.txt` 只連結 5 個 lib**：`NdtCore_RoutingManagementLib`、`NdtCore_CollectionLib`、`NdtCore_PowerManagementLib`、`EventSystemLib`、`UtilsLib`。也就是說 `NdtCore_HttpLib`、`NdtCore_IntentTranslatorLib`、`NdtCore_ApplicationLib`、`NdtCore_DataManagementLib`、`NdtCore_EventHandlingLib` **完全沒有任何單元測試 target**——不是覆蓋率低，是 0。
3. **`src/event_system/EventBus.cpp` 是一個 0 行的空檔案**，但它被 `add_library(EventSystemLib STATIC ...)` 編進去。
4. **AI 署名標記**：AI 協助寫的程式碼會標 `[Co-developed with claude code -- Adam]`。這是幻覺搜尋的高價值起點，但**不是**唯一範圍——沒有標記的程式碼同樣可能是 AI 寫的。
5. **`doc/audit-be3c242/` 是先前一輪的 10 階段審查結果。** 可以參考，但**不可以照抄**：它是對舊 commit 做的，之後至少 5 個修復 commit 已經改動了它描述的程式碼。任何引用都必須對現在的原始碼重新查證。
6. **文件本身會過期。** 例如 `doc/test_coverage_gaps.md` 寫「95 個 gtest」，實際數是 156；`tools/contract_test/README.md` 說契約涵蓋 41 個端點中的 30 個。這些數字都要重數，不能引用。
7. **建置開了 `-Werror`**（`CMakeLists.txt`），C++23。

### 已知的真實 bug 前科（作為邊界條件測試的線索）

這些不是假設，是這個 repo 真的發生過、而且從綠燈的測試底下溜過去的：sFlow parser 的截斷封包、flow-rate 的 divide-by-zero(`hopsCounter == 0` → SIGFPE)、`poll()` 逾時 0ms 造成的閒置 100% CPU、OVS liveness 回報整個 fabric 全死、clone session 誤判 bmv2 回傳碼、P4 拓撲 host port 造成單向 path 解析。相關階段的 prompt 裡都點了名。

---

## 階段總覽

| # | 階段 | 範圍 | 約略行數 | 現有測試 |
|---:|---|---|---:|---|
| 01 | Routing & Power 策略核心 | `src|include/ndt_core/routing_management/`、`power_management/`、`include/utils/SSHHelper.hpp` | 3,670 | 5 個測試檔，67 case |
| 02 | sFlow 遙測擷取 | `collection/FlowLinkUsageCollector.*`、`common_types/SFlowType.hpp` | 3,352 | 4 個測試檔，52 case + 32 fixture |
| 03 | 拓撲監控與 Classifier | `collection/TopologyAndFlowMonitor.*`、`collection/Classifier.*` | 4,397 | 部分被 3 個測試檔碰到 |
| 04 | HTTP 北向 API 與行程生命週期 | `http/`、`application_management/`、`data_management/`、`event_handling/`、`lock_management/`、`RequestParser.hpp`、`main.cpp` | 4,059 | **零** |
| 05 | Intent Translator / LLM | `intent_translator/` | 3,840 | **零** |
| 06 | 共用基礎建設與設定 | `event_system/`、`utils/`、`common_types/`、`setting/`、CMake | 2,300 | 3 個測試檔，24 case |
| 07 | P4 Proxy Python 服務 | `p4_proxy/proxy_agent/` | 1,787 | 6 個測試檔（2 個模組無測試） |
| 08 | P4 程式與控制/資料面腳本 | `p4_proxy/p4_src/`、`p4_proxy/mininet/`、根目錄 `.py` | 1,800 | **零**（P4 程式本身） |
| 09 | 單元測試套件本身 | `tests/`、`p4_proxy/tests/` | 5,808 | — |
| 10 | L0–L4 測試工具鏈 | `tools/test_workflow/`、`tools/contract_test/` | 4,606 | 只有 `--self-test` |

**所有階段一律忽略**：`build/`、`build-asan/`、`Testing/`、`.test_run/`、`p4_proxy/venv/`、任何 `__pycache__/`、`libs/`（vendored spdlog 與 nlohmann，第三方原始碼不審查——但**要**檢查我們對它們 API 的假設是否正確）。

---

## Phase 01: Routing & Power 策略核心

- **簡短名稱**：`01-routing-and-power`
- **範圍**：`src/ndt_core/routing_management/`、`include/ndt_core/routing_management/`、`src/ndt_core/power_management/`、`include/ndt_core/power_management/`、`include/utils/SSHHelper.hpp`
- **為什麼這樣切**：兩者共用同一組 strategy pattern（`IRoutingStrategy` / `IPowerStrategy` 的 OVS vs P4 雙實作），而且都是「對外部裝置下指令」的寫入路徑——SSH、SNMP、HTTP 到 Ryu。`SSHHelper.hpp` 雖然放在 utils，但唯一的消費者是 power management，所以放在這裡一起看。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/01-routing-and-power-summary.md 之外，不要修改、建立或刪除任何檔案。不要執行會改變狀態的指令（不要 build、不要跑測試去修東西、不要 git commit）。你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

src/ndt_core/routing_management/
  Controller.cpp (76 行)、FlowDispatcher.cpp (109)、FlowRoutingManager.cpp (231)、
  HttpRoutingStrategyBase.cpp (240)、P4RoutingStrategy.cpp (29)、CMakeLists.txt
include/ndt_core/routing_management/
  Controller.hpp (51)、FlowDispatcher.hpp (108)、FlowJob.hpp (43)、FlowRoutingManager.hpp (179)、
  HttpRoutingStrategyBase.hpp (85)、IRoutingStrategy.hpp (59)、OpenFlowRoutingStrategy.hpp (24)、
  OpResult.hpp (68)、P4RoutingStrategy.hpp (41)
src/ndt_core/power_management/
  DeviceConfigurationAndPowerManager.cpp (1642)、OVSPowerStrategy.cpp (124)、
  P4PowerStrategy.cpp (66)、CMakeLists.txt
include/ndt_core/power_management/
  DeviceConfigurationAndPowerManager.hpp (402)、IPowerStrategy.hpp (54)、
  OVSPowerStrategy.hpp (25)、P4PowerStrategy.hpp (19)
include/utils/SSHHelper.hpp (104)

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：tests/ 底下的測試檔、tests/CMakeLists.txt、
tools/test_workflow/、tools/contract_test/、setting/AppConfig.hpp.example。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、
libs/（vendored 的 spdlog 與 nlohmann——第三方原始碼不審查，但**要**檢查我們對它們 API 的假設對不對）。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本。所以任何「這段有在 CI 裡跑到」的說法都是待查證的主張。
2. tests/CMakeLists.txt 把全部 14 個測試檔編成單一 binary test_routing_strategy，共 156 個 gtest
   case，並且只連結 5 個 lib：RoutingManagement、Collection、PowerManagement、EventSystem、Utils。
3. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
   那是高價值的搜尋起點，但不是唯一範圍——沒標記的程式碼同樣可能是 AI 寫的。
4. doc/audit-be3c242/ 有一份先前的審查。可以參考，但不可以照抄：它是對舊 commit 做的，之後多個修復
   commit 已改動它描述的程式碼。任何引用都要對現在的原始碼重新查證。
5. 建置開了 -Werror，C++23。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- OpResult 錯誤傳遞鏈：最近一個 commit（8c25dbc）宣稱「把 OpResult 串起來、提前拒絕未知 dpid、
  記錄非同步結果」。去確認這條鏈是否真的完整，還是中間有某一段把錯誤降級成 log 就結束。
- FlowDispatcher 在 commit d5f5bfa 之前完全沒有測試，那次修了三個生命週期缺陷。現在
  tests/test_FlowDispatcher.cpp 只有 6 個 case——去確認那三個缺陷的迴歸測試是否真的存在，以及
  執行緒生命週期（啟動、停止、佇列滿、解構時仍有 in-flight job）是否被涵蓋。
- 有一份文件（tools/contract_test/README.md）宣稱 FlowRoutingManager 的 group/meter 方法
  「無條件使用 m_ovsStrategy，完全不看 dpid」，導致 P4 模式下的規則被送到 Ryu。去讀原始碼確認這
  件事現在是否還成立，以及有沒有任何測試會抓到它。
- DeviceConfigurationAndPowerManager.cpp 有 1642 行，是本階段最大的檔案，負責 SSH/SNMP 對實體
  交換機下指令。這是 hard-coded 憑證與 sudo 指令組裝的高風險區。
- 歷史前科：OVS liveness 曾經回報整個 fabric 全死（commit 6b3dc0c）；synthetic power 數字曾經
  算錯（0e84234）。去確認 tests/test_OvsLiveness.cpp 與 tests/test_SyntheticPower.cpp 是否真的
  釘住了這兩個迴歸，還是只測了 happy path。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——不管是在這個 repo 裡，還是在它真正依賴的
  套件（spdlog、nlohmann::json、Boost.Beast/Asio/URL、libssh、OpenSSL）裡都查不到的東西。
  請實際去 libs/ 或系統標頭確認簽章，不要憑印象。
- 註解或 docstring 描述的行為，跟程式碼實際做的事情不一樣。
- 整段邏輯講得很篤定，但其實建立在對某個 library 真實語意的錯誤假設上——順序性、執行緒安全性、
  回傳碼的意義、例外保證。
- 看起來像真的、但其實哪裡都沒定義過的常數或 enum 值。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式（尤其是 OVS 路徑複製成 P4 路徑時）。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的（呼叫完不 crash 就算過）；
  以及 mock 到最後根本沒碰到真正程式碼路徑的。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入、零值／負值、格式錯誤或截斷的資料、並發存取、
  資源耗盡。這個專案有真實前科——sFlow parser 的截斷封包、以及 flow-rate 的 divide-by-zero
  （hopsCounter == 0 造成 SIGFPE）——這類 bug 一再從這裡溜過去。
- 找出被停用／skip／標成 xfail 卻沒有留下原因紀錄的測試。
- 找出「就算把實作整段刪掉，斷言依然會通過」的假測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼，還是只是寫好放在那邊而已。注意上面提過：這個 repo
  沒有任何自動 CI，所以「有跑」最多只能是「人工執行 run_layers.sh 時會跑到」。

每個缺口都要**指名道姓**對應到具體哪個沒被測到的函式或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

- 寫死的憑證、token、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。
- 寫死的身份驗證繞過或除錯用後門：某個 magic user、flag 或日期，一觸發就跳過真正的檢查。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令（本階段的 SSH/SNMP 路徑要特別看）。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外（catch(...) 之後什麼都不做，或只 log 一行就結束）。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- 明明底層失敗了、卻回報「成功」的路徑：一個 void 函式從來不會把底層 SSH／HTTP 呼叫的失敗
  表現出來；一個回傳 bool 的函式永遠回 true。
- 把真正的失敗「合理化掉」的機制——例如一個 known-gap 白名單，結果連不相關的新失敗也一起被吞掉。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看。

## 產出

把發現寫到 doc/audit/01-routing-and-power-summary.md，結構如下：

1. 一段摘要：這個子系統最值得擔心的三件事。
2. 檔案清單：範圍內每個檔案的行數與一句話職責。
3. **測試完整度分析（本文件最長的一節）**：
   - 一張逐函式的覆蓋表：函式 | 檔案:行號 | 有無測試 | 測試檔:行號 | 這個測試真的斷言了什麼 |
     缺什麼。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體分支。
   - 假測試與無原因的 skip。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形。
4. AI 幻覺發現。
5. Hard-coded 危險內容發現。
6. 被吞掉的錯誤發現。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境（什麼輸入或
狀態會造成什麼錯誤結果）。查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 02: sFlow 遙測擷取

- **簡短名稱**：`02-sflow-collector`
- **範圍**：`src/ndt_core/collection/FlowLinkUsageCollector.cpp`、`include/ndt_core/collection/FlowLinkUsageCollector.hpp`、`include/common_types/SFlowType.hpp`
- **為什麼這樣切**：`FlowLinkUsageCollector.cpp` 是全 repo 最大的實作檔（2,458 行），而且是 kernel 兩個外部輸入面之一（:6343 UDP sFlow，另一個是 HTTP）。它與 `SFlowType.hpp` 的封包結構定義是同一件事，拆開審查會看不出解析錯誤。這也是歷史 bug 密度最高的區域。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/02-sflow-collector-summary.md 之外，不要修改、建立
或刪除任何檔案。不要執行會改變狀態的指令（不要 build、不要跑測試去修東西、不要 git commit）。
你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

src/ndt_core/collection/FlowLinkUsageCollector.cpp (2458 行)
include/ndt_core/collection/FlowLinkUsageCollector.hpp (361 行)
include/common_types/SFlowType.hpp (533 行)

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
tests/test_SFlowParsing.cpp (455 行, 21 case)、tests/test_SFlowEmitterRoundtrip.cpp (480, 17)、
tests/test_EstimatedRates.cpp (108, 8)、tests/test_GoldenFixture.cpp (327, 6)、
tests/fixtures/ 底下 32 個 .bin、tests/CMakeLists.txt、
p4_proxy/proxy_agent/sflow_emitter.py（產生封包的另一端，跨語言契約）、
tools/test_workflow/、tools/contract_test/。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、
libs/（vendored 的 spdlog 與 nlohmann——第三方原始碼不審查，但**要**檢查我們對它們 API 的假設對不對）。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本。所以任何「這段有在 CI 裡跑到」的說法都是待查證的主張。
2. tests/CMakeLists.txt 把全部 14 個測試檔編成單一 binary test_routing_strategy，共 156 個 gtest
   case。有一份文件（doc/test_coverage_gaps.md）宣稱是 95 個——文件已過期，數字要自己重數。
3. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
   那是高價值的搜尋起點，但不是唯一範圍。
4. doc/audit-be3c242/ 有一份先前的審查。可以參考，但不可以照抄：它是對舊 commit 做的，之後多個
   修復 commit 已改動它描述的程式碼。任何引用都要對現在的原始碼重新查證。
5. 建置開了 -Werror，C++23。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- 這是 kernel 的兩個外部輸入面之一（UDP :6343），也就是**唯一一個接收未經驗證的網路 bytes** 的
  地方。所有解析路徑都必須假設輸入是敵意的：截斷、長度欄位說謊、巢狀 sample 數量灌爆、
  offset 溢位、非預期的 enterprise/format 組合。
- 歷史前科一：sFlow parser 的截斷封包 bug。tests/test_SFlowParsing.cpp 據說用 ASan 驗證過
  （檔案裡提到 build-asan/），去確認每一條長度檢查是否都有對應的負面測試。
- 歷史前科二：flow-rate 的 divide-by-zero，hopsCounter == 0 造成 SIGFPE。去找出現在還有哪些
  除法或取模運算的分母沒有被證明非零。
- 歷史前科三：閒置時 100% CPU，原因是 poll() 用了 0ms 逾時。去確認 socket 迴圈現在的逾時值、
  以及有沒有任何測試或工具會抓到「忙碌等待」這種只在執行時才看得到的問題。
- 「Unsupported SFlow Version」這則訊息是用 WARN 記的，但它的真實含義是**所有 telemetry 全部被
  丟掉**、整個數位孿生的資料是空的。這是檢查重點 4 的教科書案例：log 等級與嚴重性不符。去找出
  同一類的其他訊息。
- 有一個設計決定是「link usage 排除 host edges」（commit 6996062）。去確認這個排除是刻意的、
  有註解說明的，還是某處靜靜地把資料丟掉。
- 跨語言契約：p4_proxy/proxy_agent/sflow_emitter.py 產生封包，這個 C++ collector 解析它。
  兩邊對欄位順序、位元組序、padding 的理解必須一致。去確認 round-trip 測試是否真的釘住了這件事，
  還是兩邊都用同一組錯誤假設所以自洽。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——不管是在這個 repo 裡，還是在它真正依賴的
  套件（spdlog、nlohmann::json、Boost、POSIX socket API）裡都查不到的東西。請實際確認簽章。
- 註解或 docstring 描述的行為，跟程式碼實際做的事情不一樣。本階段特別注意：註解宣稱某個欄位
  「依 sFlow v5 規格是 XX bytes」時，要去對 sFlow v5 的真實結構確認，不要相信註解。
- 整段邏輯講得很篤定，但其實建立在對某個 library 真實語意的錯誤假設上——順序性、執行緒安全性、
  回傳碼的意義、例外保證。
- 看起來像真的、但其實哪裡都沒定義過的常數或 enum 值（sFlow 的 format/enterprise 代碼是重災區）。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的（呼叫完不 crash 就算過）；
  以及 mock 到最後根本沒碰到真正程式碼路徑的。本階段要特別檢查那 32 個 .bin fixture：每一個
  是否真的有斷言被比對，還是只是被載入然後確認「沒 crash」。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入、零值／負值、格式錯誤或截斷的資料、並發存取、
  資源耗盡。這個專案有真實前科——sFlow parser 的截斷封包、以及 flow-rate 的 divide-by-zero
  （hopsCounter == 0 造成 SIGFPE）——這類 bug 一再從這裡溜過去。
- 找出被停用／skip／標成 xfail 卻沒有留下原因紀錄的測試。
- 找出「就算把實作整段刪掉，斷言依然會通過」的假測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼。特別注意：contract test 走的是 HTTP 介面，
  而這個子系統的輸入是 UDP，所以要明確判斷 UDP 輸入面到底有沒有任何工具在測。

每個缺口都要**指名道姓**對應到具體哪個沒被測到的函式或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

- 寫死的憑證、token、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。
- 寫死的身份驗證繞過或除錯用後門：某個 magic user、flag 或日期，一觸發就跳過真正的檢查。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外（catch(...) 之後什麼都不做，或只 log 一行就結束）。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。特別注意解析迴圈裡「這個 sample
  壞掉就 continue 下一個」的模式：那會讓資料默默變少而沒有任何人知道。
- 明明底層失敗了、卻回報「成功」的路徑。
- 把真正的失敗「合理化掉」的機制。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看
  （上面提過的 Unsupported SFlow Version 就是這一類）。

## 產出

把發現寫到 doc/audit/02-sflow-collector-summary.md，結構如下：

1. 一段摘要：這個子系統最值得擔心的三件事。
2. 檔案清單：範圍內每個檔案的行數與一句話職責。
3. **測試完整度分析（本文件最長的一節）**：
   - 一張逐函式的覆蓋表：函式 | 檔案:行號 | 有無測試 | 測試檔:行號 | 這個測試真的斷言了什麼 |
     缺什麼。
   - 一張 fixture 表：32 個 .bin 各自被哪個測試用到、斷言了什麼、有沒有孤兒 fixture。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體分支（特別是所有長度檢查與所有除法）。
   - 假測試與無原因的 skip。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形，含 UDP 輸入面的明確結論。
4. AI 幻覺發現。
5. Hard-coded 危險內容發現。
6. 被吞掉的錯誤發現。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境（什麼輸入或
狀態會造成什麼錯誤結果）。查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 03: 拓撲監控與 Classifier

- **簡短名稱**：`03-topology-and-classifier`
- **範圍**：`src/ndt_core/collection/TopologyAndFlowMonitor.cpp`、`include/ndt_core/collection/TopologyAndFlowMonitor.hpp`、`src/ndt_core/collection/Classifier.cpp`、`include/ndt_core/collection/Classifier.hpp`
- **為什麼這樣切**：這是 collection 模組剩下的兩個檔案，它們是同一條資料流的上下游（monitor 從控制器拉 topology 與 flow stats → Classifier 分類成 detected flows），而且共用同一批 mutex 與圖狀態。與 Phase 02 拆開是因為 collection 整個模組有 7,200 行，單一階段太大。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/03-topology-and-classifier-summary.md 之外，不要
修改、建立或刪除任何檔案。不要執行會改變狀態的指令（不要 build、不要跑測試去修東西、不要
git commit）。你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

src/ndt_core/collection/TopologyAndFlowMonitor.cpp (2522 行)
include/ndt_core/collection/TopologyAndFlowMonitor.hpp (318 行)
src/ndt_core/collection/Classifier.cpp (1359 行)
include/ndt_core/collection/Classifier.hpp (198 行)

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
tests/test_SwitchKindDispatch.cpp (567 行, 27 case)、tests/test_ClassifierDropRule.cpp (218, 7)、
tests/test_P4FlowStatsToClassifier.cpp (175, 6)、tests/test_GoldenFixture.cpp (327, 6)、
tests/CMakeLists.txt、include/common_types/GraphTypes.hpp、
tools/test_workflow/、tools/contract_test/、setting/ 底下的拓撲 JSON。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、
libs/（vendored 的 spdlog 與 nlohmann——第三方原始碼不審查，但**要**檢查我們對它們 API 的假設對不對）。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本。所以任何「這段有在 CI 裡跑到」的說法都是待查證的主張。
2. tests/CMakeLists.txt 把全部 14 個測試檔編成單一 binary test_routing_strategy，共 156 個 gtest case。
3. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
   那是高價值的搜尋起點，但不是唯一範圍。
4. doc/audit-be3c242/ 有一份先前的審查。可以參考，但不可以照抄：它是對舊 commit 做的，之後多個
   修復 commit 已改動它描述的程式碼。任何引用都要對現在的原始碼重新查證。
5. 建置開了 -Werror，C++23。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- 有一份文件（tools/test_workflow/README.md）宣稱 TopologyAndFlowMonitor::run() 只在啟動時
  「拉一次」/v1.0/topology/* 與 destination paths 就結束，沒有重試迴圈——那一刻控制層還不知道
  的東西，kernel 這輩子都不會知道。去讀原始碼確認這是否成立，以及這個設計如何被測試（或沒被測試）。
- 同一份文件宣稱：當 Ryu 缺少 rest_topology 時那三個網址會回 404，而 updateSwitches() 會把
  404 的 HTML 當 JSON 去 parse、丟出例外後「靜靜地」放棄，於是整張圖永遠是 down 且 disabled。
  這正是檢查重點 4 的核心案例——去查證它，並找出同一模式的其他實例。
- commit be3c242 修的是「edge 端點要對傳入的 graph 解析，而不是 member graph」。commit f5281a8
  修的是「path-walk 失敗要記在它的 edge 上，而不是每秒印一千次」。去確認這兩者現在的狀態，
  以及有沒有迴歸測試。
- commit 0596dd1 修的是「m_allPathMap 與 m_switchCountMap 宣告了 mutex 卻從來沒用」。去確認
  這個類別裡**每一個**共用狀態現在是否都被正確保護，尤其是被 collector 執行緒與 HTTP 執行緒
  同時碰到的那些。
- 已知環境限制：static ARP 會擋住 host discovery，導致 254/256 條 host edge 是 down。這是
  環境問題不是程式 bug，但要確認程式碼有沒有把它跟真正的失敗混在一起。
- Classifier 的輸出直接餵給北向 API 的 get_detected_flow_data（5 個外部元件依賴它）。
  空 path、空 flow table、drop rule（沒有 output port 的規則）都是已知的邊界情況。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——不管是在這個 repo 裡，還是在它真正依賴的
  套件（spdlog、nlohmann::json、Boost）裡都查不到的東西。請實際確認簽章。
- 註解或 docstring 描述的行為，跟程式碼實際做的事情不一樣。本階段特別注意：註解描述 Ryu REST
  端點的回應格式（/v1.0/topology/switches、/links、/ryu_server/all_destination_paths、
  /stats/flow/<dpid>）時，要對照 intelligent_router.py 與 p4_proxy 的實際回應確認。
- 整段邏輯講得很篤定，但其實建立在對某個 library 真實語意的錯誤假設上——順序性、執行緒安全性、
  回傳碼的意義、例外保證。
- 看起來像真的、但其實哪裡都沒定義過的常數或 enum 值。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式（OVS 路徑複製成 P4 路徑是重災區）。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
  本階段這一點特別關鍵：test_SwitchKindDispatch.cpp 名義上測的是 FlowRoutingManager 的分派，
  它會順帶建構 TopologyAndFlowMonitor——要分清楚哪些 case 真的在斷言 monitor 的行為。
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的；以及 mock 到最後根本沒碰到
  真正程式碼路徑的。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入、零值／負值、格式錯誤或截斷的資料（HTTP 回應是
  404 HTML 而不是 JSON 就是這一類）、並發存取、資源耗盡。這個專案有真實前科——sFlow parser
  的截斷封包、以及 flow-rate 的 divide-by-zero（hopsCounter == 0 造成 SIGFPE）——這類 bug
  一再從這裡溜過去。
- 找出被停用／skip／標成 xfail 卻沒有留下原因紀錄的測試。
- 找出「就算把實作整段刪掉，斷言依然會通過」的假測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼。contract_test 有一個 inv_graph_matches_topology
  不變量——去讀 tools/contract_test/spec.py 確認它到底驗了什麼、放過了什麼。

每個缺口都要**指名道姓**對應到具體哪個沒被測到的函式或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

- 寫死的憑證、token、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。本階段注意寫死的控制器 URL、
  dpid、port 號、拓撲檔路徑。
- 寫死的身份驗證繞過或除錯用後門：某個 magic user、flag 或日期，一觸發就跳過真正的檢查。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外。本階段的頭號嫌疑是 JSON parse 失敗被 catch 之後整個更新迴圈
  靜靜放棄，圖永遠停在初始狀態。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- 明明底層失敗了、卻回報「成功」的路徑：一個 void 的 update 函式從來不會把 HTTP 呼叫的失敗
  表現出來。
- 把真正的失敗「合理化掉」的機制——例如把「這台 switch 本來就不該有 path」跟「path 計算壞了」
  混為一談。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看。

## 產出

把發現寫到 doc/audit/03-topology-and-classifier-summary.md，結構如下：

1. 一段摘要：這個子系統最值得擔心的三件事。
2. 檔案清單：範圍內每個檔案的行數與一句話職責。
3. **測試完整度分析（本文件最長的一節）**：
   - 一張逐函式的覆蓋表：函式 | 檔案:行號 | 有無測試 | 測試檔:行號 | 這個測試真的斷言了什麼 |
     缺什麼。
   - 「順帶碰到 vs 真的在測」的明確區分，尤其是 test_SwitchKindDispatch.cpp。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體分支。
   - 並發存取的測試現況：哪些共用狀態被兩條以上執行緒碰到、哪些有測試。
   - 假測試與無原因的 skip。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形。
4. AI 幻覺發現。
5. Hard-coded 危險內容發現。
6. 被吞掉的錯誤發現。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境。
查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 04: HTTP 北向 API 與行程生命週期

- **簡短名稱**：`04-http-northbound`
- **範圍**：`src/ndt_core/http/`、`include/ndt_core/http/`、`src/ndt_core/application_management/`、`include/ndt_core/application_management/`、`src/ndt_core/data_management/`、`include/ndt_core/data_management/`、`src/ndt_core/event_handling/`、`include/ndt_core/event_handling/`、`include/ndt_core/lock_management/LockManager.hpp`、`include/event_system/RequestParser.hpp`、`src/main.cpp`
- **為什麼這樣切**：`HttpSession.cpp` 是 41 個端點的 dispatch chain，而 application/data/event_handling 三個小模組全部只透過它對外，`LockManager` 與 `RequestParser` 也只在這條路徑上被用到，`main.cpp` 決定了它們的建構順序與執行緒模型。**這整組沒有任何單元測試 target**——`tests/CMakeLists.txt` 根本沒連結這些 lib——所以它是全 repo 測試風險最高的一塊。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/04-http-northbound-summary.md 之外，不要修改、建立
或刪除任何檔案。不要執行會改變狀態的指令（不要 build、不要跑測試去修東西、不要 git commit）。
你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

src/ndt_core/http/HttpSession.cpp (1847 行)、include/ndt_core/http/HttpSession.hpp (692)
src/ndt_core/application_management/ApplicationManager.cpp (238)、SimulationRequestManager.cpp (54)
include/ndt_core/application_management/ApplicationManager.hpp (64)、SimulationRequestManager.hpp (58)
src/ndt_core/data_management/HistoricalDataManager.cpp (142)
include/ndt_core/data_management/HistoricalDataManager.hpp (44)
src/ndt_core/event_handling/ControllerAndOtherEventHandler.cpp (254)
include/ndt_core/event_handling/ControllerAndOtherEventHandler.hpp (135)
include/ndt_core/lock_management/LockManager.hpp (120)
include/event_system/RequestParser.hpp (86)
src/main.cpp (411)
以及上述目錄的 CMakeLists.txt

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
tests/ 全部、tests/CMakeLists.txt、tools/contract_test/（尤其是 spec.py、components.py、
l3_component_check.py）、doc/ndt_api.md、setting/AppConfig.hpp.example。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、
libs/（vendored 的 spdlog 與 nlohmann——第三方原始碼不審查，但**要**檢查我們對它們 API 的假設對不對）。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本。所以任何「這段有在 CI 裡跑到」的說法都是待查證的主張。
2. **本階段範圍內的程式碼完全沒有任何單元測試 target。** tests/CMakeLists.txt 只連結
   NdtCore_RoutingManagementLib、NdtCore_CollectionLib、NdtCore_PowerManagementLib、
   EventSystemLib、UtilsLib。NdtCore_HttpLib、NdtCore_ApplicationLib、NdtCore_DataManagementLib、
   NdtCore_EventHandlingLib 從來沒有被連進測試 binary。這不是覆蓋率低，是 0。請自己確認這件事，
   然後把「那唯一還在測它的東西是什麼」查清楚（提示：tools/contract_test 走的是活的 HTTP）。
3. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
4. doc/audit-be3c242/ 有一份先前的審查。可以參考，但不可以照抄：它是對舊 commit 做的，之後多個
   修復 commit 已改動它描述的程式碼。任何引用都要對現在的原始碼重新查證。
5. 建置開了 -Werror，C++23。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- HttpSession.cpp 是一條巨大的 (method, target) if/else dispatch chain，據稱有 41 個註冊端點。
  自己數一次。然後對照 tools/contract_test/components.py 的 KERNEL_ENDPOINTS（那是**人工轉錄**
  的表）——去確認漂移：漏列、方法寫錯、多列了已移除的端點。
- 已登記的缺陷：handleReleaseLock 據稱不管鎖有沒有被持有、型別有沒有效，一律回 200。
  這在 contract test 裡被標成 known_gap（release_lock_not_held）而**不計入失敗**。去確認程式碼
  現狀，並把這個 known_gap 機制本身當成檢查重點 4 的案例來看。
- LockManager::stringToLockType 據稱只認得 routing_lock / graph_lock / power_lock，其他一律回
  Unknown，而 acquireLock/renew 對 Unknown 直接回 false。去確認未知型別的失敗是否有被回報給
  呼叫端，還是靜靜地變成「取鎖失敗」。
- main.cpp 的 HTTP server 據稱是單執行緒（net::io_context ioc{1}）。如果成立，任何慢的 handler
  （SNMP、SSH、對 Ryu 的同步 curl）會阻塞所有其他請求。去確認執行緒模型，並確認有沒有任何測試
  或工具碰得到這個情境（提示：L2/L3 是序列發請求的）。
- main.cpp 最近加了 CLI 參數解析（--mode/--topology/--no-ai），fallback 才是互動式 std::cin，
  而且只在 stdin 是 TTY 時才提示。去確認非 TTY 且參數缺失的路徑真的會失敗而不是卡住。
- 歷史前科：Energy-Saving-App 一直 POST /ndt/disable_switch，kernel 從來沒註冊過，一直拿 404，
  而 app 把錯誤吃掉了。去找出還有沒有同類的「消費者在打、kernel 沒實作」或反過來的情況
  （tools/contract_test/components.py 的 KNOWN_MISSING_ENDPOINTS 是起點）。
- 據稱有 6 個 group/meter 端點沒有任何 contract，而且在 P4 模式下會無條件走 OVS strategy。
- 據稱 CORS / OPTIONS（Web-GUI 直接依賴）、keep-alive、request body 大小上限、k 參數邊界值
  都沒有被驗證過。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——不管是在這個 repo 裡，還是在它真正依賴的
  套件（Boost.Beast、Boost.Asio、Boost.URL、nlohmann::json、spdlog）裡都查不到的東西。
  Boost.Beast 的 API 是幻覺高發區，請實際確認簽章與正確的用法。
- 註解或 docstring 描述的行為，跟程式碼實際做的事情不一樣。本階段特別注意：註解宣稱某個端點
  「會回 412／423／400」時，去讀那條路徑實際回什麼狀態碼。
- 整段邏輯講得很篤定，但其實建立在對某個 library 真實語意的錯誤假設上——特別是 Boost.Asio 的
  執行緒安全性、handler 是否可重入、shared_ptr 生命週期在非同步回呼中的保證。
- 看起來像真的、但其實哪裡都沒定義過的常數、設定鍵值（AppConfig 的成員）或 enum 值。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式——41 個 handler 高度相似，複製貼上改錯
  （驗錯欄位、回錯物件、用了上一個 handler 的變數）在這裡最容易發生。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
  本階段的答案很可能大量是「完全沒有」——那就要把「完全沒有」寫得非常具體：每一個端點
  handler、每一個 manager 方法，逐一列出來。
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的；以及 mock 到最後根本沒碰到
  真正程式碼路徑的。tools/contract_test 打的是活的 HTTP，所以它「有碰到」真的程式碼——但要
  確認它斷言的是行為還是只是「有回應而且是合法 JSON」。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入（空 body、空 JSON、空陣列）、零值／負值
  （dpid=0、k=0、k=-1、超大的 k）、格式錯誤或截斷的資料（非 JSON、截斷的 JSON、非數字 dpid）、
  並發存取（兩個 client 同時搶同一把鎖、同時打同一個 mutation 端點）、資源耗盡（超大 body、
  大量並發連線）。這個專案有真實前科——sFlow parser 的截斷封包、以及 flow-rate 的
  divide-by-zero（hopsCounter == 0 造成 SIGFPE）——這類 bug 一再從這裡溜過去。
- 找出被停用／skip／標成 xfail 卻沒有留下原因紀錄的測試，以及 contract test 裡標成 known_gap
  的項目：每一條的理由是否還成立？
- 找出「就算把實作整段刪掉，斷言依然會通過」的假測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼。逐端點做出「有 contract / 沒有 contract」的完整清單，
  不要引用 README 的數字，自己數。

每個缺口都要**指名道姓**對應到具體哪個沒被測到的函式、端點或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

- 寫死的憑證、token、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。
- 寫死的身份驗證繞過或除錯用後門：某個 magic user、flag、header 或日期，一觸發就跳過真正的
  檢查。本階段是整個 repo 唯一的對外介面，這一項在這裡最重要——去找有沒有任何端點會依某個
  特殊輸入跳過鎖檢查、跳過權限檢查、或直接回成功。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令（注意從 HTTP 輸入流向 shell/SSH 的路徑，
  那同時是注入風險）。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- **明明底層失敗了、卻回報「成功」的路徑**——本階段的核心：HTTP 200 但內容其實是失敗訊息；
  一個 void handler 從來不會把底層 SSH/subprocess/HTTP 呼叫的失敗表現出來；release lock
  一律回 200。逐端點檢查「這個 handler 有沒有可能在底層失敗時仍然回 2xx」。
- 把真正的失敗「合理化掉」的機制——known_gap 白名單、KNOWN_MISSING_ENDPOINTS 清單，要確認它們
  的粒度夠不夠細，會不會連不相關的新失敗也一起吞掉。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看。

## 產出

把發現寫到 doc/audit/04-http-northbound-summary.md，結構如下：

1. 一段摘要：這個子系統最值得擔心的三件事。
2. 端點清單：從 HttpSession.cpp 實際數出來的 (method, target) 全表，每一筆標註：有無 contract、
   有無單元測試、消費者是誰。
3. **測試完整度分析（本文件最長的一節）**：
   - 逐 handler / 逐函式的覆蓋表：函式 | 檔案:行號 | 有無測試 | 由什麼測到 | 真的斷言了什麼 | 缺什麼。
   - 「這一整組沒有單元測試 target」這件事的完整說明與影響評估。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體端點與分支。
   - 並發與資源耗盡路徑的現況。
   - known_gap 與 KNOWN_MISSING_ENDPOINTS 每一條的重新評估。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形。
4. AI 幻覺發現。
5. Hard-coded 危險內容發現（含後門與注入面）。
6. 被吞掉的錯誤發現（含所有「失敗但回 2xx」的路徑）。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境（什麼請求會
造成什麼錯誤結果）。查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 05: Intent Translator 與 LLM 整合

- **簡短名稱**：`05-intent-translator`
- **範圍**：`src/ndt_core/intent_translator/`、`include/ndt_core/intent_translator/`
- **為什麼這樣切**：這是唯一會呼叫外部付費 API 並把模型輸出轉成網路設定變更的子系統，攻擊面與失敗模式跟其他模組完全不同（prompt injection、模型輸出解析、API key）。它被 contract test **刻意排除**（理由是需要 OpenAI token、每次呼叫要花錢），而且沒有任何單元測試——所以它是全 repo 驗證最薄弱的一塊。`LLMResponseTypes.hpp` 有 2,458 行，本身就是幻覺高發區。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/05-intent-translator-summary.md 之外，不要修改、
建立或刪除任何檔案。不要執行會改變狀態的指令（不要 build、不要跑測試、不要呼叫任何外部 API、
不要 git commit）。你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

src/ndt_core/intent_translator/IntentTranslator.cpp (967 行)
src/ndt_core/intent_translator/LLMAgent.cpp (326 行)
src/ndt_core/intent_translator/answer_agent_prompt.txt
src/ndt_core/intent_translator/validation_agent_prompt.txt
src/ndt_core/intent_translator/CMakeLists.txt
include/ndt_core/intent_translator/IntentTranslator.hpp (43)
include/ndt_core/intent_translator/LLMAgent.hpp (46)
include/ndt_core/intent_translator/LLMResponseTypes.hpp (2458)

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
tests/ 全部、tests/CMakeLists.txt、tools/contract_test/spec.py 與 components.py、
setting/AppConfig.hpp.example、src/ndt_core/http/HttpSession.cpp（呼叫端）、
src/main.cpp（--no-ai 旗標與建構）。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、
libs/（vendored 的 spdlog 與 nlohmann——第三方原始碼不審查，但**要**檢查我們對它們 API 的假設對不對）。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本。
2. **本階段範圍內的程式碼完全沒有任何單元測試 target。** tests/CMakeLists.txt 從來沒有連結
   NdtCore_IntentTranslatorLib。請自己確認。
3. contract test **刻意**不涵蓋 /ndt/intent_translator/text，理由寫在
   tools/contract_test/README.md：需要 OpenAI token、每次呼叫要花錢、回應由模型決定。
   Web-GUI 對它的依賴只靠 L3 的存在性檢查（也就是「這個端點沒有回 404」）。
   這是一個明確的決定，不是疏漏——但它的後果（這條路徑上的所有邏輯都沒有任何自動驗證）
   是你要評估的東西。
4. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
5. doc/audit-be3c242/ 有一份先前的審查。可以參考但不可照抄，要對現在的原始碼重新查證。
6. 建置開了 -Werror，C++23。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- LLMResponseTypes.hpp 有 2458 行，是全 repo 第二大的檔案，而且是純標頭。它定義模型回應的結構。
  這種「AI 生成一大批看起來很合理的型別」的檔案是幻覺重災區：去確認每一個型別、每一個欄位是否
  真的被用到、是否真的對應到某個真實 API 的回應格式，還是憑空想像出來的。
- LLMAgent.cpp 對外部 API 發 HTTP 請求。去確認：API key 從哪裡來（AppConfig？環境變數？寫死？）、
  逾時設定、重試邏輯、以及 4xx/5xx/網路失敗各自怎麼處理。
- 兩個 .txt prompt 檔會被讀進來組成請求。去確認：檔案路徑怎麼解析（相對於 cwd 還是 binary？
  找不到檔案時會怎樣？）、使用者輸入怎麼被嵌進 prompt（prompt injection 面）、以及模型的輸出
  在被轉成網路設定之前經過了什麼驗證。
- 「validation agent」這個名字暗示有一層驗證。去確認它驗的是什麼、驗不過時會發生什麼、
  以及那個驗證本身能不能被模型輸出繞過。
- 這條路徑的終點是**真的會改動網路**。去把「從 HTTP 請求 → 模型 → 實際下規則」這條完整鏈路
  畫出來，標出每一個沒有驗證的環節。
- main.cpp 有 --no-ai 旗標。去確認關掉 AI 時這條路徑是乾淨地停用，還是留下半初始化的狀態。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的，而本階段又是「AI 寫的、關於呼叫 AI 的程式碼」，幻覺密度預期最高。
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——不管是在這個 repo 裡，還是在它真正依賴的
  套件裡都查不到的東西。特別要查：AppConfig 的成員是否真的存在於 setting/AppConfig.hpp.example；
  被引用的環境變數是否真的有人設定。
- **對外部 LLM API 的請求／回應格式是否正確**：端點路徑、必填欄位、模型名稱、參數名稱、回應的
  JSON 結構。一個「聽起來很對」但實際不存在的欄位或模型 ID 就是典型幻覺。把你能查證的都查證，
  查不了的明確標成「無法離線查證」。
- 註解或 docstring 描述的行為，跟程式碼實際做的事情不一樣。
- 整段邏輯講得很篤定，但其實建立在對某個 library 或 API 真實語意的錯誤假設上。
- 看起來像真的、但其實哪裡都沒定義過的常數或 enum 值——LLMResponseTypes.hpp 是主要獵場。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
  本階段的答案很可能是「完全沒有」——那就要把它寫得非常具體，逐函式列出，並且分辨哪些函式
  **本來就可以在不呼叫外部 API 的情況下被測**（prompt 組裝、回應解析、驗證邏輯、錯誤映射），
  哪些真的需要外部服務。前者沒有測試是缺口，後者是設計取捨。
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的；以及 mock 到最後根本沒碰到
  真正程式碼路徑的。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入、零值／負值、格式錯誤或截斷的資料（模型回了非 JSON、
  回了截斷的 JSON、回了結構正確但語意荒謬的內容）、並發存取、資源耗盡（超長輸入、token 上限）。
  這個專案有真實前科——sFlow parser 的截斷封包、以及 flow-rate 的 divide-by-zero
  （hopsCounter == 0 造成 SIGFPE）——這類 bug 一再從這裡溜過去。
- 找出被停用／skip／標成 xfail 卻沒有留下原因紀錄的測試。
- 找出「就算把實作整段刪掉，斷言依然會通過」的假測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼。L3 的存在性檢查算不算「測到」？請明確論證。
- 額外要求：提出一份「不需要外部 API 就能寫的測試」清單，具體到函式與輸入。

每個缺口都要**指名道姓**對應到具體哪個沒被測到的函式或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

本階段是這一項的最高風險區。
- 寫死的憑證、token、API key、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑
  （例如寫死指向 /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。
  除了原始碼，也要看 answer_agent_prompt.txt 與 validation_agent_prompt.txt 這兩個 prompt 檔
  裡有沒有被嵌進去的機密、內部 IP、或個人資訊。
- 寫死的身份驗證繞過或除錯用後門：某個 magic user、flag、關鍵字或日期，一觸發就跳過真正的檢查
  ——例如某個特殊輸入會讓 validation agent 被跳過。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令，以及任何從模型輸出流向 shell/SSH 的路徑。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外——特別是「模型回應解析失敗就回一個空物件」這種模式。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- 明明底層失敗了、卻回報「成功」的路徑：API 呼叫失敗（401、429、逾時）之後仍然回一個看起來
  正常的結果；驗證失敗但仍然把設定送出去。
- 把真正的失敗「合理化掉」的機制。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看。
- 額外注意：把 API key 或完整 prompt（可能含機密）寫進 log 也是一種問題，方向相反但同樣要報。

## 產出

把發現寫到 doc/audit/05-intent-translator-summary.md，結構如下：

1. 一段摘要：這個子系統最值得擔心的三件事。
2. 資料流圖（文字版）：HTTP 請求 → prompt 組裝 → 外部 API → 回應解析 → 驗證 → 實際網路變更，
   每一步標出有無驗證、有無測試。
3. **測試完整度分析（本文件最長的一節）**：
   - 逐函式覆蓋表：函式 | 檔案:行號 | 有無測試 | 需不需要外部 API 才能測 | 缺什麼。
   - 「可以離線測但沒測」的函式清單（這是最有行動價值的部分）。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體分支。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形，含對「刻意排除」這個決定的評估。
4. AI 幻覺發現（LLMResponseTypes.hpp 單獨一小節）。
5. Hard-coded 危險內容發現（含 prompt .txt 檔的內容審查）。
6. 被吞掉的錯誤發現。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境。
查證不出來的就標成「未確認」或「無法離線查證」，不要用推測填充。
```

---

## Phase 06: 共用基礎建設與設定

- **簡短名稱**：`06-foundations`
- **範圍**：`src/event_system/`、`include/event_system/`（不含 `RequestParser.hpp`，那在 Phase 04）、`src/utils/`、`include/utils/`（不含 `SSHHelper.hpp`，那在 Phase 01）、`include/common_types/GraphTypes.hpp`、`include/common_types/AppTypes.hpp`、`setting/`、根目錄 `CMakeLists.txt` 與各模組 `CMakeLists.txt`
- **為什麼這樣切**：這些是被所有其他模組依賴的地基——EventBus、Logger、Utils、KeyedFailureLog、圖型別、設定與建置。一個地基層的錯誤假設會同時汙染上面每一層，所以值得單獨、集中地看一次。`setting/` 放這裡是因為 `AppConfig.hpp.example` 與 8 個拓撲 JSON 是 hard-coded 憑證／IP 最可能藏身的地方。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/06-foundations-summary.md 之外，不要修改、建立或
刪除任何檔案。不要執行會改變狀態的指令（不要 build、不要跑測試去修東西、不要 git commit）。
你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

src/event_system/EventBus.cpp、src/event_system/CMakeLists.txt
include/event_system/EventBus.hpp (83 行)、EventPayloads.hpp (22)、PayloadTypes.hpp (20)
src/utils/Logger.cpp (92)、src/utils/CMakeLists.txt
include/utils/Logger.hpp (90)、Utils.hpp (464)、KeyedFailureLog.hpp (160)
include/common_types/GraphTypes.hpp (342)、AppTypes.hpp (15)
setting/AppConfig.hpp.example、setting/ 底下 8 個拓撲 JSON、setting/node_positions_p4.json
根目錄 CMakeLists.txt (約 140 行)、以及 src/ 底下各模組的 CMakeLists.txt
.clang-format、.gitignore、check_env.py (8 行)

明確排除（屬於其他階段）：include/event_system/RequestParser.hpp、include/utils/SSHHelper.hpp、
include/common_types/SFlowType.hpp。

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
tests/test_EventBus.cpp (227 行, 8 case)、tests/test_KeyedFailureLog.cpp (236, 12)、
tests/test_IpToString.cpp (135, 4)、tests/CMakeLists.txt、
所有 include 這些標頭的原始檔（用 grep 找出真正的消費者）。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、
libs/（vendored 的 spdlog 與 nlohmann——第三方原始碼不審查，但**要**檢查我們對它們 API 的假設對不對）。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本。所以任何「這段有在 CI 裡跑到」的說法都是待查證的主張。
2. tests/CMakeLists.txt 把全部 14 個測試檔編成單一 binary test_routing_strategy，共 156 個 gtest case。
3. **src/event_system/EventBus.cpp 是一個 0 行的空檔案**，但它被 add_library(EventSystemLib STATIC ...)
   編進去。去確認這是刻意的（header-only 實作）還是有東西不見了，以及建置系統對此有沒有任何警告。
4. setting/AppConfig.hpp 被 .gitignore 排除，但 setting/AppConfig.hpp.example 有進版控。
   CMakeLists.txt 會在前者不存在時自動從後者複製一份。
5. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
6. doc/audit-be3c242/ 有一份先前的審查。可以參考但不可照抄，要對現在的原始碼重新查證。
7. 建置開了 -Werror，C++23。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- **EventBus::emit() 據稱在呼叫 handler 期間持有 shared_lock。** 如果成立，任何 handler 只要
  嘗試 registerHandler 或 emit 就會死鎖。目前據說沒有被觸發是因為還沒有人在 handler 裡做那些事。
  去查證這件事，並找出所有「現在剛好沒事、但下一個使用者就會踩到」的類似陷阱。
- Logger::init 的 idempotency：tools/test_workflow/l1_unit_tests.sh 的存在理由就是它——據稱
  拿掉 idempotency 修正之後，ctest 會全綠但直接執行 binary 會因為
  "logger with name 'netdt' already exists" 而失敗。去確認現在的實作、以及有沒有測試釘住它。
- commit 95c7690 把 ipToString 改成用 inet_ntop，commit message 說「這是可攜性問題，不是被回報
  的那個資料競爭」。去確認 Utils.hpp 裡**其他**函式有沒有真正的執行緒安全問題（用了 static
  緩衝區、非 reentrant 的 libc 函式如 strtok/asctime/localtime 之類）。
- KeyedFailureLog 是一個「抑制重複錯誤訊息」的機制。這種東西本質上就是檢查重點 4 的風險：
  去確認它抑制的粒度，會不會把不同的失敗當成同一個而吞掉。
- setting/ 的 8 個拓撲 JSON 含有真實的交換機管理位址。AppConfig.hpp.example 是設定範本。
  這兩處是本階段檢查重點 3 的主場。
- CMakeLists.txt 有 -Werror。去確認有沒有任何地方用 pragma 或編譯選項局部關掉警告。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——不管是在這個 repo 裡，還是在它真正依賴的
  套件（spdlog、nlohmann::json、Boost、標準函式庫）裡都查不到的東西。libs/spdlog 就在本機，
  請實際打開確認簽章，不要憑印象。
- 註解或 docstring 描述的行為，跟程式碼實際做的事情不一樣。
- 整段邏輯講得很篤定，但其實建立在對某個 library 真實語意的錯誤假設上——**本階段特別重要的是
  執行緒安全性與順序性**：spdlog 的哪些操作是執行緒安全的？shared_mutex 的升級語意？
  std::atomic 的記憶體序？這些是地基層最容易寫錯又最難發現的地方。
- 看起來像真的、但其實哪裡都沒定義過的常數或 enum 值。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式。
- 額外：AppConfig.hpp.example 裡宣告的鍵值，跟程式碼實際讀取的鍵值是否一一對應？
  有沒有程式碼讀了一個範本裡沒有的成員（那會在別人照範本建檔後建置失敗）？

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
  本階段特別注意：Utils.hpp 有 464 行、GraphTypes.hpp 有 342 行，而對應的測試只有
  test_IpToString.cpp 的 4 個 case——去逐函式列出其餘全部沒被測到的東西。
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的；以及 mock 到最後根本沒碰到
  真正程式碼路徑的。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入、零值／負值、格式錯誤或截斷的資料、**並發存取**
  （本階段是重點：EventBus 的多執行緒 emit/register、Logger 的多執行緒初始化、
  KeyedFailureLog 的並發存取）、資源耗盡。這個專案有真實前科——sFlow parser 的截斷封包、
  以及 flow-rate 的 divide-by-zero（hopsCounter == 0 造成 SIGFPE）——這類 bug 一再從這裡溜過去。
- 找出被停用／skip／標成 xfail 卻沒有留下原因紀錄的測試。
- 找出「就算把實作整段刪掉，斷言依然會通過」的假測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼。
- 額外要求：設定檔本身有沒有被驗證？8 個拓撲 JSON 有沒有任何 schema 檢查、有沒有測試會載入
  它們？（commit 2da6954 據稱處理過「沒有管理位址的 switch 在載入時就要被拒絕」，去確認。）

每個缺口都要**指名道姓**對應到具體哪個沒被測到的函式或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

本階段的 setting/ 是這一項的主場。
- 寫死的憑證、token、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。逐一檢查
  setting/AppConfig.hpp.example 與 8 個拓撲 JSON：裡面有沒有真實的管理位址、社群字串
  （SNMP community）、使用者名稱、密碼、或任何進了版控就不該存在的東西。
- 寫死的身份驗證繞過或除錯用後門：某個 magic user、flag 或日期，一觸發就跳過真正的檢查。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag——本階段特別注意 Logger 的等級設定與
  SPDLOG_ACTIVE_LEVEL 的編譯期裁切：有沒有可能某個等級的訊息在 release 建置下整個消失。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- 明明底層失敗了、卻回報「成功」的路徑。
- **把真正的失敗「合理化掉」的機制**——KeyedFailureLog 就是為此存在的，所以要特別嚴格地檢查
  它的抑制粒度：兩個不同原因的失敗會不會共用同一個 key 而讓第二個永遠不被印出來。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看。
- 額外：EventBus 的 handler 拋例外時會發生什麼？是傳播出去、被吞掉、還是讓其餘 handler
  收不到事件？

## 產出

把發現寫到 doc/audit/06-foundations-summary.md，結構如下：

1. 一段摘要：這個地基層最值得擔心的三件事。
2. 檔案清單：範圍內每個檔案的行數、一句話職責、以及有多少個上層模組依賴它（用 grep 數）。
3. **測試完整度分析（本文件最長的一節）**：
   - 逐函式覆蓋表：函式 | 檔案:行號 | 有無測試 | 測試檔:行號 | 真的斷言了什麼 | 缺什麼。
   - 並發相關路徑的專節：哪些狀態被多執行緒碰到、哪些有測試。
   - 設定檔（AppConfig 範本 + 8 個拓撲 JSON）的驗證現況。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體分支。
   - 假測試與無原因的 skip。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形。
4. AI 幻覺發現（含對 library 執行緒安全性假設的查證結果）。
5. Hard-coded 危險內容發現（setting/ 逐檔案結論）。
6. 被吞掉的錯誤發現。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境。
查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 07: P4 Proxy Python 服務

- **簡短名稱**：`07-p4-proxy-agent`
- **範圍**：`p4_proxy/proxy_agent/`、`p4_proxy/requirements.txt`
- **為什麼這樣切**：這是一個獨立的 Python 行程，用 P4Runtime gRPC 對 bmv2 說話、用 HTTP 對 kernel 說話、並且自己合成 sFlow 封包。它與 C++ kernel 是不同語言、不同執行期、不同失敗模式，必須單獨審查。注意：`api_routes.py` 與 `main.py` **完全沒有對應的測試檔**，`p4_client.py`(529 行) 只有一個會自我 skip 的整合測試。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/07-p4-proxy-agent-summary.md 之外，不要修改、建立
或刪除任何檔案。不要執行會改變狀態的指令（不要跑測試、不要啟動服務、不要 pip install、
不要 git commit）。你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

p4_proxy/proxy_agent/main.py (130 行)
p4_proxy/proxy_agent/api_routes.py (154)
p4_proxy/proxy_agent/p4_client.py (529)
p4_proxy/proxy_agent/topology_manager.py (315)
p4_proxy/proxy_agent/sflow_emitter.py (448)
p4_proxy/proxy_agent/ryu_topology.py (215)
p4_proxy/proxy_agent/ryu_flow_stats.py (190)
p4_proxy/proxy_agent/SPEC.md
p4_proxy/requirements.txt

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
p4_proxy/tests/ 底下全部（test_sflow_emitter.py 733 行/48 case、test_clone_session.py 381/18、
test_ryu_topology.py 278/24、test_ryu_flow_stats.py 192/22、test_kernel_notifier.py 181/13、
test_unsupported_match.py 112/9、test_p4_client.py 102/1、以及兩支非測試腳本
generate_emitted_fixtures.py、push_rules.py）、
p4_proxy/p4_src/ndtwin_switch.p4 與 build/ndtwin_switch.p4info.txt（P4Runtime 的表名與欄位契約）、
tools/test_workflow/l1_unit_tests.sh、tools/contract_test/、
src/ndt_core/collection/FlowLinkUsageCollector.cpp（sFlow 封包的另一端消費者）。

**注意**：p4_proxy/proxy_agent/kernel_notifier.py (121 行) 也在本階段範圍內。

一律忽略：build/、build-asan/、Testing/、.test_run/、**p4_proxy/venv/（那是裝進去的 Python
虛擬環境，不是原始碼）**、任何 __pycache__/、p4_proxy/p4_src/build/ 底下的建置產物
（可以讀來對照，但不審查它們的程式碼品質）。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本，其中 l1_unit_tests.sh 會逐檔執行 p4_proxy/tests/test_*.py。
2. l1_unit_tests.sh 會依序嘗試多個 Python 直譯器，其中包含**寫死的絕對路徑**
   /home/adam/p4dev-python-venv/bin/python3，找不到就退回系統 python3。這造成一個後果：
   在沒有 P4Runtime protobuf 的直譯器上，大量測試會透過 @unittest.skipUnless 自我 skip，
   而整體結果**仍然是綠的**。這是你要評估的核心風險之一。
3. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
4. doc/audit-be3c242/ 有一份先前的審查（其中 07 號是 P4 proxy agent）。可以參考但不可照抄，
   要對現在的原始碼重新查證——之後有多個 commit 改動過這些檔案。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- **api_routes.py 與 main.py 沒有任何對應的測試檔。** 去確認這件事，並逐路由列出未涵蓋的行為。
- **p4_client.py 有 529 行，但 test_p4_client.py 只有 1 個 test function，而且它同時被三重
  skip 條件保護**（需要 P4Runtime protobuf、需要有 bmv2 在聽、且 proxy 不能在跑）。
  也就是說在絕大多數執行環境下，這 529 行有 0 個測試在跑。去把這件事量化並寫清楚。
- P4Runtime 的 mastership：據稱 proxy 與測試都用 election_id 1，兩者不能共存。去確認 client
  對 "Election id already exists" 這類錯誤的處理——是往外報，還是變成靜靜的無限重試。
- commit 0843a6c 修的是「clone session 的 fallback：bmv2 回的是 UNKNOWN，不是 ALREADY_EXISTS」。
  這是對 library 回傳碼的錯誤假設的典型案例。去找出**其他**對 gRPC status code 的假設，
  並確認每一個。
- kernel_notifier.py 呼叫 kernel 的 /ndt/inform_switch_entered。據稱在某個階段之前
  「沒有任何東西會呼叫它，所以 is_enabled 永遠是 false」。去確認現在的狀態與錯誤處理。
- sflow_emitter.py 產生的封包由 C++ 的 FlowLinkUsageCollector 解析。兩邊對欄位順序、位元組序、
  padding 的理解必須一致。去確認 round-trip 測試釘住的是真正的 sFlow v5 規格，還是只是
  「我自己編碼、我自己解碼」的自洽。
- topology_manager.py 據稱會拒絕 ipv4_lpm 表達不了的 match field（commit c964946）。
  去確認這個拒絕是完整的，還是仍有靜靜narrow 規則的路徑。
- ryu_topology.py 與 ryu_flow_stats.py 是在模仿 Ryu 的 REST 回應格式給 kernel 消費。
  去確認它們產生的格式跟 kernel 期待的、以及跟真正的 Ryu 產生的，三者一致。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——不管是在這個 repo 裡，還是在它真正依賴的
  套件裡都查不到的東西。本階段的依賴是 grpc、p4runtime protobuf、可能還有 Flask/HTTP 框架與
  networkx。**p4_proxy/venv/ 就在本機**，你可以（且應該）進去讀套件原始碼確認簽章與常數
  ——但不要把 venv 當成審查對象。requirements.txt 宣告的套件與實際 import 的是否一致也要查。
- **P4Runtime 的表名、action 名、參數名、欄位寬度**必須跟 p4_proxy/p4_src/ndtwin_switch.p4
  以及 build/ndtwin_switch.p4info.txt 一致。一個「聽起來很對」但 p4info 裡不存在的名稱就是
  典型幻覺，而且會在執行期才炸。逐一比對。
- 註解或 docstring 描述的行為，跟程式碼實際做的事情不一樣。
- 整段邏輯講得很篤定，但其實建立在對某個 library 真實語意的錯誤假設上——gRPC 的 status code
  意義、串流的順序保證、protobuf 欄位的預設值語意、socket 的行為。
- 看起來像真的、但其實哪裡都沒定義過的常數或 enum 值。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
  請做出一張完整的「模組 → 測試檔」對應表，並明確標出 api_routes.py 與 main.py 的狀況。
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的；以及 mock 到最後根本沒碰到
  真正程式碼路徑的。**本階段這一點特別重要**：大量測試會 mock 掉 gRPC stub，那就要判斷它到底
  驗證了 p4_client 的哪一部分邏輯、哪一部分只是驗證了 mock 自己。
- **逐一檢視每一個 @unittest.skipUnless / @unittest.skipIf**：條件是什麼、在什麼環境下會被
  skip、被 skip 掉的是哪些行為、以及**在 l1_unit_tests.sh 實際挑選的直譯器下，這些測試到底
  有沒有跑**。一個永遠 skip 的測試等於沒有測試，但它會讓整體結果看起來是綠的。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入、零值／負值、格式錯誤或截斷的資料、並發存取
  （proxy 同時服務 HTTP 請求與 gRPC 串流）、資源耗盡。這個專案有真實前科——sFlow parser 的
  截斷封包、以及 flow-rate 的 divide-by-zero（hopsCounter == 0 造成 SIGFPE）——這類 bug
  一再從這裡溜過去。
- 找出被停用／skip／標成 xfail 卻沒有留下原因紀錄的測試。
- 找出「就算把實作整段刪掉，斷言依然會通過」的假測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼。注意 L0 對 Python 元件只做 ast.parse（語法檢查），
  請明確說明那涵蓋了什麼、沒涵蓋什麼。

每個缺口都要**指名道姓**對應到具體哪個沒被測到的函式、路由或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

- 寫死的憑證、token、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。本階段特別注意寫死的
  bmv2 gRPC 位址與 port 範圍（50051–50060）、kernel 的 URL、sFlow collector 位址與 port。
- 寫死的身份驗證繞過或除錯用後門：某個 magic user、flag、query 參數或日期，一觸發就跳過
  真正的檢查。這個服務對外開 HTTP 端點，去確認有沒有任何認證，以及有沒有繞過路徑。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令（注意有沒有 subprocess 呼叫）。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外——Python 裡的 except Exception: pass 或只 print 一行。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- **明明底層失敗了、卻回報「成功」的路徑**：HTTP 200 但 body 其實是失敗訊息；一個沒有回傳值的
  函式從來不會把底層 gRPC 寫入失敗表現出來；規則安裝失敗但回報 OK。逐路由、逐 gRPC 呼叫檢查。
- 把真正的失敗「合理化掉」的機制。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看。
- 額外：背景執行緒（sflow emitter、telemetry 迴圈）裡的例外會發生什麼？Python 的執行緒例外
  預設只會印到 stderr 然後那條執行緒就死了，主程序毫無所覺——去確認有沒有這種情況。

## 產出

把發現寫到 doc/audit/07-p4-proxy-agent-summary.md，結構如下：

1. 一段摘要：這個服務最值得擔心的三件事。
2. 模組清單：每個 .py 的行數、一句話職責、對應的測試檔（沒有就明確寫「無」）。
3. **測試完整度分析（本文件最長的一節）**：
   - 逐函式覆蓋表：函式 | 檔案:行號 | 有無測試 | 測試檔:行號 | 真的斷言了什麼 | 缺什麼。
   - **skip 條件專節**：每一個 skipUnless/skipIf 的條件、影響範圍、在 l1_unit_tests.sh 實際
     選用的直譯器下的真實結果。要給出「在典型環境下，135 個 test function 實際跑了幾個」的
     具體數字或明確的判定方法。
   - api_routes.py 與 main.py 的逐路由未涵蓋清單。
   - p4_client.py 529 行的實際涵蓋現況。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體分支。
   - 假測試與 mock 過度的案例。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形。
4. AI 幻覺發現（P4Runtime 名稱與 p4info 的比對結果單獨一小節）。
5. Hard-coded 危險內容發現。
6. 被吞掉的錯誤發現（含背景執行緒）。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境。
查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 08: P4 程式與控制／資料面腳本

- **簡短名稱**：`08-p4-and-dataplane`
- **範圍**：`p4_proxy/p4_src/`、`p4_proxy/mininet/`、根目錄的 `intelligent_router.py`、`testbed_topo.py`、`dump_table.py`、`test_modify.py`、`test_modify_error.py`
- **為什麼這樣切**：P4 程式是資料面本身，而 `intelligent_router.py`(Ryu app)與兩支 mininet 拓撲腳本是它的對照組——OVS 模式的控制面與資料面。它們共同定義了「網路實際上會怎麼轉發封包」，跟 kernel 的 C++ 程式碼是完全不同的驗證問題（沒有單元測試框架、沒有型別檢查、錯誤在執行期才顯現）。放一起是因為審查它們需要同一組領域知識。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的一個子系統做深度程式碼審查。

這是一次唯讀審查。除了你的產出檔案 doc/audit/08-p4-and-dataplane-summary.md 之外，不要修改、
建立或刪除任何檔案。不要執行會改變狀態的指令（不要編譯 P4、不要啟動 mininet、不要 sudo、
不要 git commit）。你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

p4_proxy/p4_src/ndtwin_switch.p4 (482 行)
p4_proxy/p4_src/SPEC.md
p4_proxy/p4_src/build/ndtwin_switch.p4info.txt 與 ndtwin_switch.json
  （這兩個是 p4c 的產物且進了版控——**不審查它們的程式碼品質**，但要檢查它們跟 .p4 原始檔
   是否一致，以及「產物進版控」本身造成的漂移風險）
p4_proxy/mininet/p4_testbed_topo.py (299 行)
p4_proxy/mininet/s1_commands.txt
p4_proxy/mininet/SPEC.md
intelligent_router.py (728 行，Ryu app，OVS 模式的控制面)
testbed_topo.py (240 行，OVS 模式的 mininet 拓撲)
dump_table.py (18)、test_modify.py (4)、test_modify_error.py (11)
  （這三支是根目錄的零散腳本——它們是什麼、還有沒有用、有沒有危險內容，也要有結論）

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
p4_proxy/proxy_agent/p4_client.py 與 topology_manager.py（P4Runtime 的消費端）、
setting/ 底下的拓撲 JSON（kernel 對拓撲的認知）、tools/test_workflow/stack.sh 與 components.env、
tools/contract_test/。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/run_layers.sh
   是一支人工執行的驅動腳本。L0 對 P4 只做 p4c-bm2-ss 編譯檢查、對 Python 只做 ast.parse
   語法檢查，而且**這台機器沒有工具鏈時會 SKIP，且 SKIP 不算失敗**。
2. **P4 程式本身沒有任何測試。** 沒有 PTF、沒有 STF、沒有 p4testgen。唯一會執行到它的是
   人工啟動 bmv2 + mininet 之後跑 L2–L4。請自己確認這件事。
3. 這個 codebase 是 AI 輔助寫成的。AI 寫的程式碼常會標 [Co-developed with claude code -- Adam]。
4. doc/audit-be3c242/ 有一份先前的審查（08 號是 P4 mininet topo）。可以參考但不可照抄，
   要對現在的原始碼重新查證。
5. 已知環境限制：static ARP 會擋住 host discovery，導致大量 host edge 在 kernel 看來是 down。
   這是既有的環境設定造成的，不是 P4 的回歸——但要確認腳本裡的相關設定與註解是否誠實。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- commit c964946 的訊息是「拒絕 ipv4_lpm 表達不了的 match field，而不是靜靜地把規則 narrow 掉」。
  去確認 .p4 裡 ipv4_lpm 的 key 定義，並確認控制面（p4_client.py / topology_manager.py）對它的
  假設是否一致。
- commit 1767682 修的是「P4 拓撲的 host port，它讓 path 解析在單一方向上壞掉」。去確認
  p4_testbed_topo.py 現在的 port 指派、以及它跟 setting/StaticNetworkTopologyP4_10Switches_4Hosts.json
  是否一致——兩份檔案描述同一個拓撲，任何不一致都是靜默的 bug 來源。
- intelligent_router.py:282 附近據稱有一個 hub.sleep(60)，而 all_destination_paths 初始是空 list
  （約 :74）、只在 install_all_pair_paths 裡被賦值（約 :510）。去查證這些行號與邏輯，並評估
  這個設計的失敗模式（如果 install 中途失敗會怎樣？有沒有重試？有沒有人會知道？）。
- ndtwin_switch.p4 有 clone session / packet-in / packet-out 的機制（headers 裡有
  packet_in_header_t 與 packet_out_header_t）。去確認 clone session id、mirror port、
  truncate 長度這些常數，跟 proxy_agent 那邊用的值是否一致。
- s1_commands.txt 是給某一台交換機的初始命令。去確認它是不是只針對 s1、其他交換機怎麼辦、
  以及裡面有沒有寫死的位址。
- p4_src/build/ 的產物進了版控。去確認它們是不是從現在的 .p4 產生的（比對表名、action 名、
  欄位），因為 proxy_agent 是直接讀 p4info 的——原始檔改了但產物沒重編，會造成執行期才發現的
  不一致。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這個 codebase 是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——在 P4 的情境裡，這是指：
  v1model.p4 裡不存在的 extern 或 intrinsic metadata 欄位、bmv2 不支援的 primitive、
  拼錯或想像出來的 standard_metadata 成員。請對照 v1model 的真實定義確認。
  在 mininet/Ryu 的情境裡，是指 mininet 或 ryu 套件裡不存在的 API。
- 註解或 SPEC.md 描述的行為，跟程式碼實際做的事情不一樣。本階段的兩份 SPEC.md 要逐條對照
  原始碼查證——規格文件跟實作不符是這裡最可能的問題。
- 整段邏輯講得很篤定，但其實建立在對 P4/bmv2/Ryu 真實語意的錯誤假設上：table 的 match kind
  語意（lpm vs ternary vs exact 的優先權）、action 的執行順序、checksum 的重算時機、
  clone 的 metadata 保留規則、Ryu 事件的觸發順序。
- 看起來像真的、但其實哪裡都沒定義過的常數（clone session id、mirror port、EtherType、
  P4 table size）。
- 從別處複製貼上、但套用到新情境時改錯的程式碼模式——OVS 拓撲腳本複製成 P4 拓撲腳本是重災區。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

針對本階段範圍內的**每一個原始檔、每一個 control block / table / action / 函式**，逐一回答：
- 有沒有測試真的在測它？還是只是剛好被某個「其實在測別的東西」的測試順帶碰到而已？
  P4 程式很可能完全沒有測試——那就要把它寫得非常具體：逐 table、逐 action 列出「沒有任何
  自動化驗證會碰到這條路徑」，並指出哪些路徑只有在特定封包型態下才會被走到（因此連人工
  跑 L2–L4 也碰不到）。
- 分辨清楚三種測試：真的在斷言實際行為的；只是檢查「沒有當掉」的（P4 的情境是「編得過」）；
  以及 mock 到最後根本沒碰到真正程式碼路徑的。**「p4c 編得過」不等於「轉發行為正確」**，
  這個區別在本階段要講清楚。
- 挖出沒被測到的錯誤／邊界情況路徑：空輸入、零值／負值、格式錯誤或截斷的資料（parser 遇到
  截斷封包、非預期 EtherType、IP options、分片封包）、並發存取、資源耗盡（table 滿了、
  clone session 用完、queue 滿）。這個專案有真實前科——sFlow parser 的截斷封包、以及
  flow-rate 的 divide-by-zero（hopsCounter == 0 造成 SIGFPE）——這類 bug 一再從這裡溜過去。
  P4 的 parser 是同一類風險。
- 找出被停用／skip／註解掉卻沒有留下原因紀錄的程式碼或測試。
- 找出「就算把實作整段刪掉，斷言依然會通過」的假驗證。
- 確認 tools/test_workflow 的 L0–L4 分層腳本、以及 tools/contract_test 的 contract test，
  是不是真的有跑到本階段範圍內的程式碼。特別注意：L0 對 P4 的檢查在缺工具鏈時會 SKIP 而
  **不算失敗**——請評估這件事的後果。
- 額外要求：提出一份「P4 程式可以怎麼被自動測」的具體建議（PTF/STF/p4testgen 或其他），
  對應到具體的 table 與封包情境。

每個缺口都要**指名道姓**對應到具體哪個沒被測到的 table、action、parser state 或函式，
附上檔案:行號。不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

本階段的腳本大量需要 root，是這一項的高風險區。
- 寫死的憑證、token、IP、MAC、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。拓撲腳本裡的位址是必要的，
  但要區分「拓撲定義」與「不該寫死的東西」。
- 寫死的身份驗證繞過或除錯用後門：某個 magic 封包、flag 或值，一觸發就跳過真正的轉發檢查
  （P4 的情境：某個特殊 EtherType 或 IP 直接 forward 到某個 port）。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag。
- **用寫死或半寫死的字串組出來、帶有 sudo 權限的指令**——mininet 腳本一定會有 sudo 與
  subprocess/os.system。逐一檢查：指令字串裡有沒有可被外部輸入影響的部分（命令注入）、
  有沒有 rm -rf 之類的破壞性操作、有沒有 mn -c 之類會清掉使用者其他工作的動作。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

事情已經出問題了，但完全沒有被回報出來：
- 被忽略的回傳值、被吞掉的例外——特別是 subprocess 的回傳碼沒有被檢查（腳本以為指令成功了）。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- 明明底層失敗了、卻回報「成功」的路徑：拓撲建立到一半失敗但腳本繼續跑；規則安裝失敗但
  沒有任何訊息。
- 把真正的失敗「合理化掉」的機制。
- 理論上該在錯誤分支觸發的 log 敘述沒有真的觸發，或是有觸發但等級低到根本沒人在看。
- **P4 專屬**：封包被 drop 的所有路徑。P4 的 drop 是靜默的——沒有 log、沒有計數器就等於
  資料憑空消失。逐一列出 mark_to_drop 的位置，並確認每一處有沒有對應的 counter 或其他可觀測性。
  沒有 counter 的 drop 是本階段最重要的一類發現。

## 產出

把發現寫到 doc/audit/08-p4-and-dataplane-summary.md，結構如下：

1. 一段摘要：這個子系統最值得擔心的三件事。
2. 檔案清單：範圍內每個檔案的行數、一句話職責、以及「誰會執行它、什麼時候」。
3. **測試完整度分析（本文件最長的一節）**：
   - P4 程式逐 table / 逐 action / 逐 parser state 的驗證現況表。
   - 「編得過」與「行為正確」的區分，以及目前只有前者的具體證明。
   - 所有 mark_to_drop 位置與其可觀測性。
   - Python 腳本的逐函式覆蓋現況。
   - 未涵蓋的錯誤／邊界路徑，每一條都指名到具體分支或封包情境。
   - L0–L4 與 contract test 對本階段的實際涵蓋情形，含 SKIP 不算失敗的後果評估。
   - 「P4 程式可以怎麼被自動測」的具體建議。
4. AI 幻覺發現（含 SPEC.md 與實作的逐條對照、p4info 產物與 .p4 原始檔的一致性）。
5. Hard-coded 危險內容發現（含所有 sudo 指令的逐條檢查）。
6. 被吞掉的錯誤發現。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境（什麼封包或
什麼狀態會造成什麼錯誤結果）。查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 09: 單元測試套件本身

- **簡短名稱**：`09-unit-test-suites`
- **範圍**：`tests/`（C++ gtest）、`p4_proxy/tests/`（Python unittest）
- **為什麼這樣切**：前八個階段是「這段程式碼有沒有被測到」；這個階段反過來，把測試程式碼**當成程式碼來審查**。156 個 gtest case 全部編在同一個 binary、共用同一個 process；Python 那邊 135 個 test function 大量掛著條件 skip。測試套件本身的缺陷會讓前八階段的所有覆蓋率結論失真，所以它值得獨立一個階段。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的測試套件做深度審查。
注意：這一階段的審查對象是**測試程式碼本身**，不是被測的產品程式碼。

這是一次唯讀審查。除了你的產出檔案 doc/audit/09-unit-test-suites-summary.md 之外，不要修改、
建立或刪除任何檔案。不要執行會改變狀態的指令（不要 build、不要跑測試、不要 git commit）。
你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

tests/CMakeLists.txt (40 行)
tests/test_ClassifierDropRule.cpp (218 行, 7 case)
tests/test_EstimatedRates.cpp (108, 8)
tests/test_EventBus.cpp (227, 8)
tests/test_FlowDispatcher.cpp (218, 6)
tests/test_GoldenFixture.cpp (327, 6)
tests/test_IpToString.cpp (135, 4)
tests/test_KeyedFailureLog.cpp (236, 12)
tests/test_OvsLiveness.cpp (198, 15)
tests/test_P4FlowStatsToClassifier.cpp (175, 6)
tests/test_RoutingStrategies.cpp (281, 14)
tests/test_SFlowEmitterRoundtrip.cpp (480, 17)
tests/test_SFlowParsing.cpp (455, 21)
tests/test_SwitchKindDispatch.cpp (567, 27)
tests/test_SyntheticPower.cpp (121, 5)
tests/fixtures/ 底下 32 個 .bin
p4_proxy/tests/test_clone_session.py (381, 18)
p4_proxy/tests/test_kernel_notifier.py (181, 13)
p4_proxy/tests/test_p4_client.py (102, 1)
p4_proxy/tests/test_ryu_flow_stats.py (192, 22)
p4_proxy/tests/test_ryu_topology.py (278, 24)
p4_proxy/tests/test_sflow_emitter.py (733, 48)
p4_proxy/tests/test_unsupported_match.py (112, 9)
p4_proxy/tests/generate_emitted_fixtures.py (144)  ← 非測試，是 fixture 產生器
p4_proxy/tests/push_rules.py (131)                 ← 非測試，是手動工具

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：被這些測試涵蓋的產品程式碼
（src/、include/、p4_proxy/proxy_agent/）、tools/test_workflow/l1_unit_tests.sh、
tools/test_workflow/run_layers.sh、doc/test_coverage_gaps.md、doc/testing_workflow.md。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、libs/。

## 你必須先知道的環境事實

1. 這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。tools/test_workflow/l1_unit_tests.sh
   是人工執行的。
2. tests/CMakeLists.txt 把 **14 個測試檔全部編成單一 binary `test_routing_strategy`**，
   共 156 個 gtest case，共用同一個 process。它只連結 5 個 lib：RoutingManagement、Collection、
   PowerManagement、EventSystem、Utils。
3. l1_unit_tests.sh 的存在理由是一個真實發現：ctest 透過 gtest_discover_tests 把每個 case 放在
   獨立 process 執行，所以 SetUpTestSuite 失敗只會影響那一個 process，ctest 會顯示全綠。
   實測拿掉 Logger::init 的 idempotency 修正後：ctest 顯示 100% passed，直接執行 binary 則
   FAIL。所以該腳本會用兩種方式各跑一次並交叉比對。
4. l1_unit_tests.sh 會依序嘗試多個 Python 直譯器，其中包含**寫死的絕對路徑**
   /home/adam/p4dev-python-venv/bin/python3，找不到就退回系統 python3。在缺少 P4Runtime
   protobuf 的直譯器上，大量 Python 測試會透過 @unittest.skipUnless 自我 skip，
   而整體結果仍然是綠的。
5. doc/test_coverage_gaps.md 宣稱「95 個 gtest + 63 個 Python 測試 = 153」。實際的 gtest case
   數是 156，Python test function 數是 135。**文件已經過期——所有數字請自己重數。**
6. 這個 codebase 是 AI 輔助寫成的，測試也是。AI 寫的程式碼常會標
   [Co-developed with claude code -- Adam]。
7. doc/audit-be3c242/ 有一份先前的審查（09 號是 C++ unit tests）。可參考但不可照抄。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- 156 個 case 共用一個 process：去找出所有**跨測試的狀態洩漏**——全域／static 狀態、
  Logger 單例、EventBus 單例、被 SetUpTestSuite 建立而沒被拆掉的東西。然後判斷測試結果
  是否依賴執行順序（gtest 預設按檔案內順序，但 --gtest_shuffle 會打亂）。
- 32 個 .bin fixture：逐一確認每個檔案被哪個測試用到、斷言了什麼。找出孤兒 fixture
  （沒有任何測試引用）、以及只被「載入但沒有比對內容」的 fixture。
- Python 那邊每一個 @unittest.skipUnless / @unittest.skipIf 的條件（HAVE_P4RUNTIME、
  HAVE_DEPS、a_switch_is_listening()、something_is_listening(PROXY_PORT)、檔案存在檢查）：
  在 l1_unit_tests.sh 實際挑選的直譯器與典型環境下，各自會不會被 skip。給出量化結論。
- generate_emitted_fixtures.py 與 push_rules.py 不是測試，但放在 tests/ 目錄裡。
  去確認 l1_unit_tests.sh 的 glob（test_*.py）會不會誤抓它們，以及它們自己有沒有危險內容
  （push_rules.py 會真的寫入交換機）。
- 「假測試」的具體形態：斷言了一個常數等於自己、斷言了 mock 的回傳值、只斷言函式沒拋例外、
  斷言了一個總是為真的條件、或者 EXPECT 寫在一個永遠不會執行到的分支裡。逐檔案找。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

測試程式碼同樣是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」測試：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——包括被測類別上不存在的方法、
  gtest/unittest 裡不存在的巨集或 assertion。
- **測試的註解宣稱它在驗證 X，但斷言實際上驗的是 Y**。這是本階段最重要的一類幻覺：
  逐一比對每個測試的名稱／註解與它真正斷言的東西。
- 整段測試建立在對某個 library 真實語意的錯誤假設上——例如假設某個容器有序、假設 map 的
  迭代順序穩定、假設浮點數可以直接相等比較、假設 sleep 足以同步執行緒。
- 看起來像真的、但其實哪裡都沒定義過的常數或期望值（尤其是「魔術數字」形式的期望值：
  斷言等於 42 而沒有任何說明 42 從哪來）。
- 從別處複製貼上、但套用到新情境時改錯的測試——重複的 test fixture、複製後忘了改的斷言、
  兩個測試名稱不同但內容完全一樣。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

本階段的「完整度」是問：**這套測試套件本身作為一個品質關卡，強度到哪裡？**
- 逐測試檔、逐 test case 分類：真的在斷言實際行為的；只是檢查「沒有當掉」的；
  以及 mock 到最後根本沒碰到真正程式碼路徑的。給出每一類的具體數量與清單。
- **找出「就算把實作整段刪掉，斷言依然會通過」的假測試。** 對每個測試做這個思想實驗：
  如果我把被測函式的內容換成 return {} 或直接 return，這個測試還會過嗎？會過的就列出來。
  這一項要做得徹底，它是本階段最有價值的產出。
- 逐一檢視每一個被停用／skip／xfail 的測試：條件是什麼、有沒有留下原因、原因是否還成立、
  在典型環境下實際會不會跑。給出「156 個 gtest 與 135 個 Python test function 中，
  典型環境下實際執行了幾個」的量化結論。
- 挖出測試套件本身沒涵蓋的錯誤／邊界情況：空輸入、零值／負值、格式錯誤或截斷的資料、
  並發存取、資源耗盡。這個專案有真實前科——sFlow parser 的截斷封包、以及 flow-rate 的
  divide-by-zero（hopsCounter == 0 造成 SIGFPE）——去確認這兩個迴歸現在真的各有一個會失敗的
  測試釘住它，而不是只有一個「修好之後才寫、其實測不到原始 bug」的測試。
- 測試套件的結構性風險：跨測試狀態洩漏、執行順序依賴、共用 process、時間相關的不穩定測試
  （sleep、時鐘、真實網路 socket）、以及依賴外部環境（檔案系統路徑、port、外部服務）的測試。
- 確認 tools/test_workflow 的 L0–L4 分層腳本實際怎麼執行這些測試，以及有沒有任何測試檔
  從來不會被執行到（例如沒被加進 CMakeLists、或不符合 glob）。

每個缺口都要**指名道姓**對應到具體哪個測試案例或哪個沒被測到的分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

- 寫死的憑證、token、IP、port，或路徑——包括會洩漏個人／本機資訊的絕對路徑（例如寫死指向
  /home/<使用者名稱>/... 或指向這台機器上另一個 repo 的路徑）。測試裡寫死路徑會讓測試在
  別人的機器上失敗，而且常常是靜默地 skip 掉。
- 寫死的身份驗證繞過或除錯用後門。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag——包括測試裡把 log 等級調到 off、
  或用某個 flag 繞過被測程式碼的檢查（那會讓測試驗的不是真正的行為）。
- 用寫死或半寫死的字串組出來、帶有 sudo 權限的指令。特別注意 push_rules.py 會真的寫入
  交換機、test_p4_client.py 會真的建立 table entry。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

在測試程式碼裡，這一項的形態是「測試自己把失敗吃掉了」：
- try/catch 包住整個測試主體，例外被吞掉之後測試仍然通過。
- 被忽略的回傳值：setup 步驟失敗了但沒有 ASSERT，測試繼續跑在一個無效的狀態上。
- 用 EXPECT 而不是 ASSERT 導致前提失敗後仍然繼續執行，產生連鎖的誤導性失敗訊息。
- 條件式斷言：if (x) EXPECT_EQ(...) —— 當 x 為假時這個測試什麼都沒驗。
- skip 被當成 pass：Python 的 skip 與 gtest 的 GTEST_SKIP 在報表裡不是失敗，
  所以一個永遠 skip 的測試在儀表板上是綠的。
- 明明底層失敗了、卻回報「成功」的路徑：測試 harness 或 fixture 產生器裡的錯誤處理。
- 理論上該在錯誤分支觸發的訊息沒有真的觸發，或等級低到沒人在看。

## 產出

把發現寫到 doc/audit/09-unit-test-suites-summary.md，結構如下：

1. 一段摘要：這套測試最值得擔心的三件事。
2. 實測數字表（自己重數，不要引用文件）：每個測試檔的 case 數、typical 環境下實際執行數、
   skip 數與 skip 原因。
3. **測試品質分析（本文件最長的一節）**：
   - 逐測試檔的分類表：真斷言 / 只驗不 crash / mock 到沒碰到真程式碼，各自的 case 清單。
   - **「刪掉實作也會通過」的假測試完整清單**（每一條附思想實驗的理由）。
   - 每一個 skip 條件的逐條評估與量化結論。
   - 32 個 .bin fixture 的使用情形，含孤兒 fixture 與「載入但沒比對」的 fixture。
   - 跨測試狀態洩漏、執行順序依賴、共用 process 的具體風險點。
   - 不穩定測試（時間、網路、檔案系統依賴）清單。
   - 兩個歷史迴歸（sFlow 截斷封包、hopsCounter == 0 的 SIGFPE）是否真的被釘住的查證結果。
   - 有沒有測試檔從來不會被執行到。
4. AI 幻覺發現（含「註解說在測 X、實際驗的是 Y」的逐條對照）。
5. Hard-coded 危險內容發現。
6. 測試自己吞掉失敗的發現。
7. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境。
查證不出來的就標成「未確認」，不要用推測填充。
```

---

## Phase 10: L0–L4 測試工具鏈與 contract test

- **簡短名稱**：`10-test-tooling`
- **範圍**：`tools/test_workflow/`、`tools/contract_test/`
- **為什麼這樣切**：這 4,606 行是判定「整個系統是否健康」的裁判。它有三份 allowlist（`warning_allowlist.txt`、`baseline_diff_allowlist.txt`、以及 `spec.py` 的 `known_gap` 與 `components.py` 的 `KNOWN_MISSING_ENDPOINTS`）——**「把真正的失敗合理化掉的機制」正是檢查重點 4 的定義**，而這個階段的審查對象就是由這種機制構成的。裁判自己壞掉，前面九個階段的所有綠燈都不算數。

### 審查 Prompt

```text
你要對 NDTwin-Kernel 專案（位於 /home/adam/Desktop/NDTwin-Kernel）的測試工具鏈做深度審查。
注意：這一階段的審查對象是**判定系統健康與否的工具本身**，不是被它測試的產品程式碼。

這是一次唯讀審查。除了你的產出檔案 doc/audit/10-test-tooling-summary.md 之外，不要修改、建立或
刪除任何檔案。不要執行會改變狀態的指令（不要跑 run_layers.sh、不要啟動 stack、不要 sudo、
不要 git commit）。你可以讀檔、grep、以及執行唯讀的查詢指令。

## 本階段範圍（只審查這些檔案）

tools/test_workflow/components.env (96 行)
tools/test_workflow/l0_build_check.sh (219)
tools/test_workflow/l1_unit_tests.sh (206)
tools/test_workflow/run_layers.sh (316)
tools/test_workflow/stack.sh (630)
tools/test_workflow/README.md
tools/contract_test/run_contract_test.py (427)
tools/contract_test/spec.py (689)
tools/contract_test/schema.py (224)
tools/contract_test/selftest_fixtures.py (244)
tools/contract_test/components.py (276)
tools/contract_test/l3_component_check.py (298)
tools/contract_test/compare_baseline.py (399)
tools/contract_test/check_logs.py (352)
tools/contract_test/warning_allowlist.txt (105)
tools/contract_test/baseline_diff_allowlist.txt (125)
tools/contract_test/README.md

範圍外但**必須讀來做交叉查證**（不要審查它們本身）：
src/ndt_core/http/HttpSession.cpp（端點的真實來源）、doc/ndt_api.md、doc/testing_workflow.md、
doc/test_coverage_gaps.md、tests/CMakeLists.txt、p4_proxy/tests/、src/main.cpp。

一律忽略：build/、build-asan/、Testing/、.test_run/、p4_proxy/venv/、任何 __pycache__/、libs/。

## 你必須先知道的環境事實

1. **這個 repo 沒有任何自動 CI。沒有 .github/，沒有 workflow 檔。** 所有這些工具都是人工執行的。
   README 裡「可以直接接 CI」的說法是能力描述，不是既成事實。這個落差本身要被寫進報告。
2. l1_unit_tests.sh 會依序嘗試多個 Python 直譯器，其中包含**寫死的絕對路徑**
   /home/adam/p4dev-python-venv/bin/python3。components.env 的所有路徑也是「這台機器的實際
   配置」（README 自己承認）。
3. l0_build_check.sh 的三種結果是 PASS / FAIL / **SKIP，而 SKIP 不算失敗**。
4. 這些工具的核心設計是 allowlist：沒列在裡面的失敗才會被報。共有四套這樣的機制——
   warning_allowlist.txt、baseline_diff_allowlist.txt、spec.py 的 known_gap、
   components.py 的 KNOWN_MISSING_ENDPOINTS。
5. components.py 的 KERNEL_ENDPOINTS（約 41 筆）是從 HttpSession.cpp 的 if/else 鏈
   **人工轉錄**的。有一個 --check-drift 功能宣稱可以偵測漂移。
6. 這個 codebase 是 AI 輔助寫成的，這些工具也是。AI 寫的程式碼常會標
   [Co-developed with claude code -- Adam]。
7. doc/audit-be3c242/ 有一份先前的審查（10 號是 CI workflow tests）。可參考但不可照抄。

## 本階段的重點線索（不是結論，是要你去查證的方向）

- **四套 allowlist 是本階段的核心。** 逐條檢查每一條規則：
  - regex 是不是過寬，會不會意外放行不相關的新失敗？（例如一條為了放行某個特定 warning 而
    寫的 pattern，實際上會 match 到一整類訊息。）
  - 每一條的理由是否還成立？對應的缺陷修好了沒？
  - known_gap 的行為是「失敗不計入失敗、通過時提示你移除」——去確認這個邏輯真的正確實作了。
  - KNOWN_MISSING_ENDPOINTS 的行為是「已知缺口 exit 0、未登記缺口 exit 1」——去確認。
- check_logs.py 有 FORBID 機制（不管等級一律失敗）與崩潰偵測（不受 allowlist 影響）。
  去確認這兩者的實作真的繞過了 allowlist，而不是只是宣稱如此。也去確認
  --to-line / --from-line 的視窗機制不會意外把真正的錯誤排除在檢查之外。
- run_contract_test.py 的 --self-test 宣稱有 47 個檢查，而且會驗「好資料要安靜、壞資料要噴錯」
  兩個方向。去確認每一個不變量真的有雙向測試，還是有些只驗了一半（只驗一半的不變量可能是
  「永遠通過」的假綠燈）。
- compare_baseline.py 對 _bps / _rate / _count 等欄位「只比型別不比值」。去確認這個規則的
  範圍有多大——如果它涵蓋了太多欄位，L4 差異比對就形同虛設。
- l1_unit_tests.sh 的四步驗證（跑 ctest、直接跑 binary、檢查實際執行數 == 發現數、
  交叉比對 ctest 註冊數與 gtest 測試數）是這整套工具最聰明的部分。去確認這四步真的都有實作、
  而且比對邏輯正確（尤其「SKIPPED 的測試不算通過」這一條）。
- stack.sh 有 630 行，是最大的腳本，會啟動／關閉多個元件、等待收斂、管理 pidfile。
  去確認：所有 subprocess 的回傳碼有沒有被檢查、逾時的行為是什麼、以及
  「down 會不會在 port 還被佔用時就回報成功」（commit a059bb5 據稱修過這個）。
- 所有 shell 腳本的 set 選項：run_layers.sh 用的是 set -uo pipefail（**沒有 -e**）。
  去逐支腳本確認，並評估缺少 -e 造成哪些失敗會被靜靜跳過。

## 四個檢查重點

### 檢查重點 1：AI 幻覺

這些工具是 AI 輔助寫成的。找出「聽起來很合理但其實是錯的」程式碼：
- 呼叫了實際上不存在的函式、方法、設定鍵值或環境變數——包括：components.env 定義了但沒有任何
  腳本使用的變數、腳本使用了但 components.env 沒定義的變數（會靜靜變成空字串）、
  以及引用了不存在的檔案路徑或指令。
- **README 與實作不符**：這兩份 README 非常詳細，而詳細的文件最容易跟程式碼脫節。逐條把
  README 的宣稱拿去對原始碼查證——包括所有數字（47 個 self-test、41 個端點中的 30 個有 contract、
  10 個 L0 目標）。自己重數。
- 註解描述的行為，跟程式碼實際做的事情不一樣。
- 整段邏輯建立在對某個工具真實語意的錯誤假設上——curl 的 exit code、ctest 的輸出格式、
  gtest 的 XML 結構、pgrep 的比對規則（commit ab7d0bb 據稱修過「pgrep 名稱永遠不會 match」）、
  bash 的 pipefail 與 subshell 行為。
- 看起來像真的、但其實哪裡都沒定義過的常數或設定鍵值。
- 從別處複製貼上、但套用到新情境時改錯的模式。

### 檢查重點 2：測試腳本的完整度 —— 這四點裡篇幅要給最多，而且要多出一大截

本階段的「完整度」有兩層，兩層都要寫：

**第一層：這套工具測到了什麼、沒測到什麼。**
- 逐層（L0/L1/L2/L3/L4 + log 檢查）列出：它實際執行什麼、涵蓋哪些程式碼、明確不涵蓋什麼。
- 對照整個 repo 的原始碼，列出**完全沒有任何一層會碰到**的區域。已知的候選：kernel 的 UDP
  sFlow 輸入面、intent translator、並發情境、行程健康度（記憶體／執行緒洩漏）。自己查證並補完。
- 逐端點確認 contract 涵蓋率（自己數，不要引用 README 的數字），並對每一個未涵蓋端點說明
  它的消費者是誰、風險多大。

**第二層：這套工具自己有沒有被測試。**
- run_contract_test.py --self-test 涵蓋了 spec.py 與 schema.py 的多少？其他 5 支 Python 工具
  （check_logs、compare_baseline、components、l3_component_check、以及 selftest_fixtures 本身）
  有沒有任何自我測試？
- 5 支 shell 腳本（共 1,371 行）有沒有任何自動驗證？
- 分辨清楚：哪些檢查真的在斷言行為；哪些只是檢查「有回應而且是合法 JSON」；
  哪些 mock 到最後根本沒碰到真正的程式碼路徑。
- **找出「就算把被測的東西整個弄壞，這個檢查依然會通過」的假檢查。** 對每一個不變量做這個
  思想實驗。這是本階段最有價值的產出。
- 挖出沒被涵蓋的錯誤／邊界情況：空輸入、零值／負值、格式錯誤或截斷的資料、並發存取、
  資源耗盡。這個專案有真實前科——sFlow parser 的截斷封包、以及 flow-rate 的 divide-by-zero
  （hopsCounter == 0 造成 SIGFPE）——去確認這套工具現在會不會抓到同類的問題。
- 找出被停用／skip／標成 known_gap 卻沒有留下原因紀錄的檢查。
- **明確回答「這些東西有在 CI 裡跑嗎」**：答案是沒有自動 CI。請把這件事的後果寫清楚——
  哪些保護只在有人記得手動執行時才存在。

每個缺口都要**指名道姓**對應到具體哪個未涵蓋的端點、檢查或分支，附上檔案:行號。
不能只寫「覆蓋率有待加強」這種空話。

### 檢查重點 3：惡意或危險的 hard-coded 內容

本階段是這一項的高風險區——腳本會 sudo、會啟動服務、會寫入網路。
- 寫死的憑證、token、IP、port，或路徑——**包括會洩漏個人／本機資訊的絕對路徑**。已知的一例是
  l1_unit_tests.sh 裡的 /home/adam/p4dev-python-venv/bin/python3；components.env 整份都是
  這台機器的配置。請把**所有**這類實例找出來並列成一張表，標明每一條在別人的機器上會造成
  什麼後果（失敗？靜默 skip？用錯東西？）。
- 寫死的身份驗證繞過或除錯用後門：某個環境變數或 flag 一設就跳過檢查、直接讓某一層回 pass。
- 會悄悄關掉 logging、驗證或安全檢查的寫死 flag——包括「某個條件成立就整層 SKIP」的路徑。
- **用寫死或半寫死的字串組出來、帶有 sudo 權限的指令**。stack.sh 與 l0_build_check.sh 要逐條
  檢查：有沒有 rm -rf、有沒有 mn -c 之類會清掉使用者其他工作的動作、有沒有 kill 到不該 kill
  的行程（pidfile 過期後 PID 被重用是經典風險）、指令字串裡有沒有可被外部值影響的部分。

### 檢查重點 4：被隱藏、悄悄吞掉的錯誤

**這一項在本階段是主軸，因為這套工具的核心設計就是由「合理化失敗的機制」構成的。**
- 被忽略的回傳值、被吞掉的例外——shell 腳本裡沒被檢查的 exit code（缺 set -e 的後果）、
  Python 裡的 except: pass。
- 明明該往外傳播、卻只是被 catch 起來寫個 log 就結束的錯誤。
- 明明底層失敗了、卻回報「成功」的路徑：某一層印了錯誤但仍然回 exit 0；skip 被計入 pass；
  某個檢查因為前置條件不足而沒跑，卻沒有反映在最終判定上。逐層追蹤 exit code 的傳遞。
- **把真正的失敗「合理化掉」的機制**——四套 allowlist 每一條都要評估：這條規則的 regex
  會不會連不相關的新失敗也一起吞掉？known_gap 的存在會不會遮蔽同一個端點上的**其他**問題？
  compare_baseline 的「數值容忍」會不會讓真正的行為差異變成看不見？
- 理論上該在錯誤分支觸發的 log／訊息沒有真的觸發，或是有觸發但被印在一堆輸出中間、
  最終摘要沒有反映出來（README 說「summary 才是要讀的」——那 summary 有沒有可能漏報？）。

## 產出

把發現寫到 doc/audit/10-test-tooling-summary.md，結構如下：

1. 一段摘要：這套裁判最值得擔心的三件事。
2. 分層現況表：L0/L1/L2/L3/L4/log 檢查各自實際執行什麼、涵蓋什麼、明確不涵蓋什麼、
   以及「沒有自動 CI」這件事對每一層的意義。
3. **完整度分析（本文件最長的一節）**：
   - 第一層：整個 repo 中完全沒有任何一層會碰到的區域清單（指名到目錄與檔案）。
   - 逐端點的 contract 涵蓋表（自己數）。
   - 第二層：這套工具自身的測試現況（哪些有 self-test、哪些完全沒有驗證）。
   - **「就算被測的東西壞掉也會通過」的假檢查完整清單**，每一條附思想實驗理由。
   - 未涵蓋的錯誤／邊界情況。
   - 「有沒有在 CI 裡跑」的明確結論與後果。
4. **四套 allowlist 的逐條審查表**：檔案 | 規則 | 理由 | 理由是否還成立 | regex 是否過寬 |
   會不會吞掉不相關的新失敗 | 建議動作。這一節要完整，不要抽樣。
5. AI 幻覺發現（含 README 每一個宣稱與數字的查證結果）。
6. Hard-coded 危險內容發現（含所有本機絕對路徑的完整表格、所有 sudo 指令的逐條檢查）。
7. 被吞掉的錯誤發現（含 exit code 傳遞的逐層追蹤）。
8. 依嚴重度排序的行動清單。

每一條發現都要有：檔案:行號、直接引用的程式碼片段、為什麼是問題、具體的失敗情境
（什麼樣的真實 bug 會被這個機制放過去）。查證不出來的就標成「未確認」，不要用推測填充。
```

---

## 附錄：執行建議

- **順序不重要**，每個階段都獨立成立。但如果要挑優先順序，建議 `04` → `10` → `09` → `05`：Phase 04 與 05 涵蓋的程式碼完全沒有單元測試；Phase 10 決定了其他所有綠燈的可信度；Phase 09 決定了覆蓋率結論本身的可信度。
- **產出檔案**一律放 `doc/audit/`，命名為 `NN-<phase-name>-summary.md`，與本文件的階段編號對應。
- 先前那一輪的結果在 `doc/audit-be3c242/`，兩者並存不衝突。各階段的 prompt 都已寫明：可參考，但必須對現在的原始碼重新查證。
