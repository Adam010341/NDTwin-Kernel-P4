# NDTwin-Kernel 測試工具總覽

## 這份文件回答什麼

這份文件是 NDTwin-Kernel（一個網路數位孿生系統的 C++ 核心）測試工具的總覽，對象是接手的工程師。它回答四個問題：

1. 專案裡有哪些測試工具？以什麼分類軸組織？
2. 每一類工具回答什麼問題、什麼時候跑、失敗代表什麼？
3. 為什麼需要這麼多層，而不是一個「跑全部」的腳本？
4. 每個工具取代了什麼不可靠的人工判斷？

這不是工具清單。主要分類軸是專案自己的五層測試架構（L0–L4）加上判定標準層；第二個分類軸是跨層級的閘門機制型態。文件內容只根據專案中實際存在的文件與工具檔頭撰寫；凡是材料不足以支撐的地方，文件會明說「不在材料範圍內」，而不是猜測。

## 設計主題：把「看起來還好」換成 pass/fail 閘門

這個專案的測試工具有一個反覆出現的主題：**把「看起來還好」換成明確的 pass/fail 閘門**。幾乎每個工具的存在理由都可以用這句話解釋：

- `check_logs.py` 取代「捲一遍 log 看有沒有怪東西」——它對任何未允許的 error/warning 直接判失敗。
- `warning_allowlist.txt` 讓「新出現的 warning」無法藏在既有 warning 裡——任何沒列出來的就失敗。
- `baseline_diff_allowlist.txt` 逼每個「P4 做不到這個」都必須寫成文字——任何沒被允許的差異都失敗。
- `compare_baseline.py` 用「已知良好的 OVS 行為」當 P4 的規格，取代「肉眼看 P4 輸出覺得差不多就當作可以」。
- `components.py` 用實測取代「把七個元件全部啟動再用肉眼檢查」。
- L1 把 gtest 跑兩種方式，取代「單一測試跑法全綠就當作沒問題」。
- mutation testing 要求「親眼看測試失敗過」才算出貨，取代「測試有跑、有綠燈就當作有效」。

為什麼需要這麼多層？因為不同的失敗模式出現在不同階段，而且每一層的成本不同。L0/L1 只要幾分鐘、不需要 Mininet 或執行中的 kernel，所以可以在每次改動後跑；L2/L3 需要 running stack，回答 API 契約與影響範圍；L4 需要完整 stack 和流量，回答端到端行為。層與層之間有依賴關係——workflow 文件明確指出啟動順序有依賴關係，順序錯了測不出東西。下層沒過，上層的結果沒有意義；反過來，下層過了也不代表上層會過。

把閘門分層的另一個理由：每一層的失敗有不同的調試成本。L0 失敗表示編譯期就破，L1 失敗表示單元行為錯或跨測試干擾，L2 失敗表示 API 契約破，L3 告訴你誰會受影響，L4 告訴你整個 P4 路徑是否偏離已知良好的 OVS 行為。越早的閘門越便宜，所以應該越常跑。

## 分類軸一：測試層級（L0–L4 與判定標準）

以下是專案五層測試架構的總覽：

| 層級 | 回答的問題 | 執行時機 | 失敗代表 | 主要工具 |
|---|---|---|---|---|
| L0 建置檢查 | 每個元件還能不能編譯？ | 每次改動後；無需 Mininet 或執行中 kernel | 跨 repo 建置破壞 | `l0_build_check.sh` |
| L1 單元測試 | 單元行為對不對？共享 process 下還對不對？ | quick 模式（約 2 分鐘） | 行為錯誤或跨測試干擾 | `l1_unit_tests.sh` |
| L2 API 契約 | kernel 的 `/ndt/*` API 是否遵守契約？ | 需要 running stack | API 結構、不變量、錯誤路徑被破壞 | `run_contract_test.py`、`spec.py`、`schema.py` |
| L3 元件契約子集 | 改一個 endpoint，哪些元件會壞？ | 需要 running stack | 元件呼叫未實作 endpoint，或依賴的契約被破壞 | `l3_component_check.py`、`components.py` |
| L4 端到端 + 差異比對 | P4 路徑與已知良好的 OVS 路徑行為是否一致？ | 需要完整 stack 與場景流量 | 行為差異未被允許 | `compare_baseline.py`、`baseline_diff_allowlist.txt` |
| 判定標準 | log、行程、資源有沒有異常？ | 每個需要判定的場合 | 未允許的 warning/error、不健康的行程等 | `check_logs.py`（log 部分） |

### L0：建置檢查

**回答的問題：**「每個元件還能不能編譯？」具體來說，它抓的是最常見的跨 repo 破壞：你在 kernel 改了一個 shared header，一週後才發現 Energy-Saving-App 已經編不過了。L0 把這個發現時間從一週縮短到幾分鐘（腳本執行時間為秒到分鐘級）。

**執行時機：** 每次改動後的第一道閘門。不需要 Mininet、不需要執行中的 kernel。可以只跑指定的元件（`./l0_build_check.sh kernel p4`）或全部。

**失敗代表：** 某個元件回報 FAIL，exit code 非零——有跨 repo 的建置破壞。特別值得注意的是第三種狀態 SKIP：toolchain 在這台機器上缺席。SKIP 不算失敗，但會被回報，讓你知道覆蓋範圍縮小了。這是這個專案一貫的設計：覆蓋降低必須可見，不能默默發生。

**為什麼存在：** 取代「等到真的把系統跑起來才發現編不過」。單一 repo 的建置無法發現 shared header 的跨 repo 影響，所以必須把 kernel 的兄弟元件一起編。這個腳本依賴 `components.env` 提供路徑、conda env 與 port 的單一事實來源；`KERNEL_DIR` 由 `components.env` 自己的位置推導，`WORKSPACE_ROOT` 用「找兄弟 repo」的方式發現而不是假設固定深度——這些設計都是為了讓腳本在不同 checkout 下不用改設定就能跑。檔頭也註明這些值是在這台機器上驗證過的，佈局不同時要調整。

### L1：Kernel 單元測試

**回答的問題：** 單元層級的行為是否正確？這層涵蓋 C++ 與 Python 兩半邊。C++ 這邊是 gtest：**31 個 `.cpp`、414 個測試**，全部在 `tests/` 下，編成單一執行檔 `test_routing_strategy`（2026-08-10 實跑更正，原本寫 28／368／41）。Python 這邊是 `p4_proxy/tests/` 的 **12 個**檔案、**312 個**測試（unittest 格式，不是 pytest）——P4 路徑有一半在 Python（sFlow emitter、clone session），C++ suite 碰不到它們。

**執行時機：** `./run_layers.sh quick` = L0 + L1，約 2 分鐘，不需要 Mininet。`l1_unit_tests.sh` 會先設定/建置（或 `--no-build` 假設 build 是最新的），然後把 gtest 跑兩種方式。

**L1 最關鍵的設計理由：為什麼要把 gtest 跑兩次。** 兩種執行方式單獨看都會騙人：

- `ctest` 為每個 `TEST_F` 註冊一個獨立的 ctest case，各自在自己的 process 裡用 `--gtest_filter` 執行。這種隔離意味著「只有在多個 suite 共用同一個 process 時才會發生」的問題永遠不會發生，所以 ctest 會報綠。
- 直接執行整個執行檔則把所有 suite 放在同一個 process，跨測試干擾才會現形：static 初始化、singleton、全域註冊表、某個 suite 留下來的狀態。

實測數據（在 `Logger::init` 重複初始化 bug 還存在的時候）：

| 執行方式 | exit | ran | passed | skipped |
|---|---|---|---|---|
| `--gtest_filter=P4RoutingStrategyTest.Install...` | 0 | 1 | 1 | 0 |
| 整個執行檔 | 1 | 12 | 10 | 2 |
| ctest | 100% passed | 12 | 0 failed | — |

注意第一行：在 ctest 底下那些測試是真的跑了、也真的通過。ctest 不是在吞掉失敗，而是它從來沒有製造出會失敗的條件。所以兩種方式都要跑：ctest 的隔離保證每個測試的獨立正確性，直接執行讓跨測試干擾現形。

腳本另外斷言「實際 RUN 的測試數」等於「探索到的測試數」：被 SKIP 的測試不是通過的測試。Python 端的 skip 比照辦理，但有一个額外的陷阱：unittest 把 skip 掉的測試算進 "Ran N tests"（gtest 不會），所以「整個檔案全部 skip」會印出 `Ran 55 tests / OK` 而被誤判為通過。Python 測試若因為 interpreter 真的缺 P4Runtime protobufs 而 skip，那是環境限制而不是測試壞掉，但仍舊會被回報為未通過。

**失敗代表：** 單元行為錯誤、跨測試干擾、或測試被 skip。找出是哪一種，是 L1 之後除錯的起點。

**為什麼存在：** 取代「單一測試跑法全綠就當作沒問題」。L1 也是上面所有層的立足點：API 契約測試假設單元行為正確，端到端比對假設元件行為正確。測試資產方面還有 `tests/python/`（2 個 Python 檔：kernel 端 + 測試工具本身的測試）、`tests/shell/`（1 個 shell 測試）、以及 `tests/fixtures/` 的 31 個 `.bin`——從真實運作的 OVS + Ryu + Mininet 抓下來的 sFlow 封包，作為 golden fixtures。

### L2：Kernel API 契約測試

**回答的問題：** kernel 的 `/ndt/*` HTTP API 是否遵守契約？工作區的每個工具和 app 都只透過這個 API 跟 kernel 講話，所以在這裡驗證，等於驗證它們共同的地基。workflow 文件把 L2 標為「最重要，你現在缺的」一層；`tools/contract_test/` 下的工具就是這層的實作。

**檢查什麼：** 每個 endpoint 三種檢查：

1. **structure**：回應是合法 JSON、欄位正確、型別正確。
2. **invariants**：數值跟 topology 檔一致、彼此一致（例如 10 個 switch、全部 up、路徑非空）。
3. **error path**：壞輸入得到合理的 4xx，而不是 500、也不是假 200。

**工具如何配合：**

- `spec.py`（710 行）定義每個 kernel 註冊的 `/ndt/*` endpoint 的契約。shapes 取自 `doc/ndt_api.md`，並與 `src/ndt_core/http/HttpSession.cpp` 的 dispatch table 交叉檢查。endpoint 名稱與 method 以 kernel 實際註冊為準，所以有幾個是 `ndt_api.md` 沒寫到的。method 很重要：kernel 是 (method, target) 一起 match，GET 打到 POST-only endpoint 會落到 404，看起來像 endpoint 不存在。
- `schema.py` 是刻意零依賴的宣告式 schema validator（不用 jsonschema/pydantic），讓契約測試在任何有 python3 的地方都能跑，包括光禿禿的 demo VM。它的存在理由是**精確的失敗訊息**：`nodes[3].is_up: expected bool, got str ('true')` 比「get_graph_data failed」有用得多——後者比肉眼盯 GUI 好不了多少。
- `run_contract_test.py` 是驅動者，對每個 endpoint 跑 structure/invariant/error path 檢查。它是 read-only 檢查，對 running system 安全。用法帶 `--topology` 指定 topology 檔（例如 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`）。
- `selftest_fixtures.py` 用 `doc/ndt_api.md` 的實際 response 範例當 fixture，**證明 schema 接受 kernel 文件上寫的東西**，不需要跑 kernel。如果 schema 拒絕文件範例，是 schema 錯；在 live system 上除錯之前，先在這裡發現便宜得多。invariant 的 case 還額外檢查每個 invariant 在壞資料上真的會 fire——確保檢查不是空轉、不是 vacuous pass。

**執行時機：** 需要 running stack。`./run_layers.sh api p4` = L2 + L3 + log check。

**失敗代表：** API 的結構、不變量或錯誤路徑被破壞。workflow 文件在 L2 章節有「順手抓到的現有破口」一節，表示建置這一層時確實抓到了既有的 API 問題。

**為什麼存在：** 取代「把 GUI 打開、點一點、看有沒有壞」。因為所有元件都站在同一個 API 上，契約測試是最省錢的槓桿點。同時它讓「改 kernel API」變成有明確後果的動作：改壞了，L2 會先紅。

### L3：元件契約子集

**回答的問題：** L2 問「kernel 的 API 對不對」，L3 問「**哪些元件會壞**」。改完一個 endpoint 之後，不用把七個元件全部啟動再用肉眼檢查，就能知道爆炸半徑。

**工具如何配合：**

- `components.py` 記錄每個工作區元件實際依賴哪些 `/ndt/*` endpoint。它是**實測不是猜的**：把每個元件的 source 拿來 grep `/ndt/` URL 得出來的。`KERNEL_ENDPOINTS` 是 kernel 真正的 dispatch table，從 `HttpSession.cpp` 的 if/else-if chain 逐行抄錄。method 的細節再次重要：kernel 是 (method, target) 一起 match，GET 打到 POST-only 會 404，看起來像 endpoint 不存在。
- `l3_component_check.py` 對每個元件做兩種檢查：
  1. **existence**：它呼叫的每個 endpoint 必須存在。404 代表元件在呼叫 kernel 沒實作的東西。Energy-Saving-App 對 `/ndt/disable_switch` 的呼叫就是這樣被抓到的——不過這個例子後來被更正過，值得完整寫下來，因為它示範了 L3 這種靜態掃描的能力邊界。`components.py` 記錄「app POST 這個 endpoint」是**對的**：`src/app/http.cpp:269` 真的有那段程式碼，而 kernel 真的沒有實作它，L3 也確實印出 MISSING。但那個函式有 **0 個呼叫點**——它是死碼。實際的節能路徑走 `/ndt/set_switches_power_state`（2 個呼叫點，實測回 200）。所以「節能功能從來沒關掉過任何交換機」這個推論是錯的。

  這件事的教訓不是 L3 沒用，而是它回答的問題比看起來窄：**它掃的是「原始碼裡出現過哪些 endpoint」，不是「執行時真的會打哪些 endpoint」。** 前者是後者的超集。要區分兩者需要呼叫圖分析或執行期觀測，不在這一層的能力範圍內。把這個限制寫清楚，比讓下一個人再推論一次同樣的錯誤便宜。
  2. **contract**：對 `spec.py` 有涵蓋的 endpoint，跑 L2 的 structure/invariant 檢查，把失敗歸因到依賴它的元件。

**執行時機：** 需要 running stack；`run_layers.sh api p4` 包含。

**失敗代表：** 有元件在呼叫 kernel 沒實作的 endpoint，或某個 endpoint 的契約破壞會波及哪些元件。它把「改 API 的影響」從模糊的擔憂變成明確的清單。

**為什麼存在：** 取代「全部啟動、肉眼檢查」。「當 kernel 改一個 endpoint 時，可以精確說出哪些元件會壞，而不是把七個都 launch 起來盯著看」——這是 `components.py` 自己寫明的存在理由。

### L4：端到端場景 + OVS/P4 差異比對

**回答的問題：** 整個系統跑起來之後，P4 路徑的行為是否與已知良好的 OVS 路徑一致？這層分兩部分：4-A 固定場景腳本，4-B OVS/P4 差異比對。workflow 文件稱 4-B 是「P4 開發最有效的技巧」。

**4-B 的核心設計（`compare_baseline.py`）：** OVS 路徑是 known-good，所以**用它的行為當 P4 的規格**，而不是替 P4 發明一份規格。naive JSON diffing 在這裡行不通：兩個 topology 真的不同（128 hosts vs 4），rates/counters/timestamps 每秒都在變。所以只比較兩件「無論 data plane 為何都應該相同」的事：

1. **shape**：遞迴的「field path -> type」集合。抓 missing field、type 改變、以及（關鍵）某一邊是空的但另一邊有內容的 list——這正是 P4 stubs 呈現差異的方式。
2. **facts**：per-endpoint 的行為布林。所有 switch 是否 up？flow paths 是否有值？rates 是否非零？tables 是否非空？這些問題的答案必須一致，即使數字不一致。

**`baseline_diff_allowlist.txt`：** 目的是「逼每個『P4 做不到這個』都寫下來」。`compare_baseline.py` 對任何不在清單上的差異都判失敗。每個 P4 落差都必須附理由，不能默默劣化。當 `doc/p4_bmv2_support_plan.md` 的某個 phase 完成，對應條目就應該刪掉；工具會回報未使用的條目，所以不會累積。

**執行時機：** 需要完整 stack。`./run_layers.sh baseline ovs` 抓 OVS reference；`./run_layers.sh compare` 比對最近一次 P4 capture 與 OVS baseline；`./run_layers.sh full p4` 跑 P4 run 可用的全部層級。stack 的帶起由 `stack.sh` 負責（見「執行編排」一節），場景需要的 readers、traffic、apps 由場景腳本各自啟動。

**失敗代表：** P4 與 OVS 的行為差異（shape 或 facts）沒有被允許。這表示 P4 實作在某個地方偏離了已知良好的行為。

**為什麼存在：** 取代「肉眼看 P4 輸出覺得差不多」。數字永遠不會一樣，但 shape 與 facts 應該一樣；把這個「應該一樣」變成自動化閘門，P4 開發才有穩定的回饋。

### 判定標準層：取代「看有沒有 error」

workflow 文件的判定標準章節處理三件事：log 判定、行程健康度、以及為什麼要量記憶體和 thread。`run_layers.sh` 的 `--traffic` 會加上 telemetry checks。材料中可詳細說明的是 log 判定：

**`check_logs.py`** 直接取代「捲 log 看有沒有怪東西」：

- 任何 error/critical 行失敗，除非明確 allowlist。
- 任何 warning 行失敗，除非 allowlist——所以**新的 warning 無法藏在已經接受的 warning 裡**。
- FORBID pattern 在任何 level 都失敗，針對「severity 比它被記錄的 level 還糟」的訊息。
- allowlist 條目如果從來沒 match 到，會被回報——allowlist 不會腐化。
- `--suggest-allowlist` 可以在既有 log 上 bootstrap。

allowlist 格式是三個欄位，以「 | 」（空白-直條-空白）分隔：`LEVEL | python regex | 為什麼可以接受`。不用裸直條，是為了讓 regex 本身可以包含直條。

**失敗代表：** kernel log 裡出現未允許的 warning/error。這就是「有東西在叫」的明確閘門。

**為什麼存在：** `warning_allowlist.txt` 的檔頭解釋了核心問題：沒有 allowlist 時，「檢查 log 有沒有 warning」只要有超過一小撮 warning 就退化——真正新的 warning 會淹沒在已經決定要與之共存的 warning 裡。allowlist 反轉預設：**任何沒列出來的東西都是失敗**，回歸無法躲在雜訊裡。

（行程健康度、記憶體與 thread 的具體判定工具與標準，在材料中只有 workflow 文件的章節標題與 `--traffic` 的線索；此處不做臆測。）

### 各層如何被編排：run_layers.sh

`run_layers.sh` 是頂層驅動，依你在做的事選對層級組合：

| 指令 | 執行內容 | 需要什麼 |
|---|---|---|
| `quick` | L0 + L1 | 無 Mininet，約 2 分鐘 |
| `api p4` | L2 + L3 + log check | running stack |
| `api p4 --traffic` | 同上 + telemetry checks | running stack + traffic |
| `baseline ovs` | 抓 OVS reference 給 L4 | OVS stack |
| `compare` | 比對最近一次 P4 capture 與 OVS baseline | 兩份 capture |
| `full p4` | P4 run 可用的全部層級 | 完整 P4 stack |

每層印出自己的判定（verdict）；最後的 summary 是該讀的東西。**任何一層失敗，exit code 非零，所以可以 gate CI。**

為什麼需要這個編排？因為不同工作階段需要不同層級：快速驗證不需要 Mininet；API 檢查需要 running stack；L4 需要先有 baseline。單一指令讓「該跑什麼」變成決定好的事，而不是每次重新判斷。`tools/test_workflow/README.md` 是這些流程腳本的中文說明，可與本文件搭配閱讀。

## 分類軸二：閘門的機制型態（跨層級的共同模式）

如果只看層級，會忽略這個專案真正反覆出現的設計模式。這些模式跨越層級，是理解整套工具如何互相配合的關鍵。

### allowlist 型閘門：新問題不能藏在舊問題裡

`warning_allowlist.txt` 和 `baseline_diff_allowlist.txt` 共享同一套哲學：**不在清單上的東西就是失敗**。兩者的動機相同：「檢查 log 有沒有 warning」這種事，只要 warning 一多就退化；「P4 有一些差異」只要累積起來就會變成常態。allowlist 反轉預設值，讓新的 warning 和新的 P4 差異都必須被明確承認。

兩者還有三個共同的防腐化機制：

- 格式相同：三個欄位，`LEVEL/endpoint | python regex | 為什麼可以接受`，分隔符是「 | 」。
- 未使用的條目會被回報，所以 allowlist 不會因為「以前寫的條目現在沒用了」而默默累積。
- 條目有生命週期：`baseline_diff_allowlist.txt` 的條目在 `doc/p4_bmv2_support_plan.md` 的 phase 完成後**應該被刪掉**——工具回報未使用條目，讓刪除變成例行公事。

這個機制型態回答的問題是：**如何讓「接受既有問題」和「抓新問題」不衝突**。沒有 allowlist，接受既有問題的方式是「容忍所有 warning」；有了 allowlist，接受既有問題的方式是「逐條寫下理由」。

### 以「已知良好」當規格，而不是發明規格

- `compare_baseline.py`：OVS 路徑 known-good，用它的行為當 P4 的規格。
- `components.py`：元件依賴是實測掃出來的，不是猜的；`KERNEL_ENDPOINTS` 從真實 dispatch table 逐行抄錄。
- `spec.py`：shapes 取自 `doc/ndt_api.md`，並與 `HttpSession.cpp` 交叉檢查；endpoint 以實際註冊為準，所以文件漏寫的也會被涵蓋。

這個模式回答的問題是：**規格從哪裡來**。當文件與程式碼衝突時，以實測或實際註冊為準。它取代的是「相信一份可能過期的文件」或「替 P4 發明一份可能不符合現實的規格」。

### 測試的自我驗證：確保閘門本身有意義

- `selftest_fixtures.py`：證明 schema 接受文件範例；而且 invariant 檢查在壞資料上真的會 fire，不是 vacuous pass。
- L1 的「跑兩次」：兩種執行模式互相補位，避免任何單一模式造成的假綠。
- SKIP 當失敗：被跳過的測試不算通過（Python unittest 還會把 skip 算進 "Ran N tests"，需要特別處理）。
- mutation testing（下一節）：最強的一種自我驗證。

這個模式回答的問題是：**怎麼知道測試本身有意義**。沒有自我驗證，綠燈只是「有跑」的證據，不是「行為正確」的證據。

### 執行編排：讓閘門可重複、可信任

- `components.env`：路徑、conda env、port 的單一事實來源，l0/l1/stack 腳本都 source 它；可以在環境變數覆蓋（例如 `NDT_URL=http://192.168.1.5:8000 ./l0_build_check.sh`）。`KERNEL_DIR` 從檔案自身位置推導，`WORKSPACE_ROOT` 用尋找方式發現——不同 checkout 不需要改設定。
- `stack.sh`：元件有嚴格依賴順序，太早啟動下一個會產生「看起來像 bug 的失敗」。step 3→4 尤其必須等：很多「看起來壞了」其實是「topology 還沒 converge」。腳本涵蓋 1–3 步（control plane、data plane、kernel）加 convergence，因為這幾步必須腳本化才能再現；readers、traffic、apps（steps 4–6）由每個測試場景自己啟動。提供 `up ovs`、`up p4`、`wait`、`status`、`down`、`logs` 等操作。Mininet 需要 root，`up` 會在 sudo 下重新執行 topology；其他步驟以呼叫者身份執行。
- `run_layers.sh`：把常見情況濃縮成單一指令，每層獨立 verdict、最後 summary、exit code gate CI。

這個模式回答的問題是：**怎麼讓測試結果可信**。如果啟動順序錯了、路徑設錯了、topology 還沒 converge，任何測試結果都沒有意義。編排工具把這些變數消掉，讓「跑測試」變成一個決定好的、可重複的程序。

## 以 mutation testing 驗收測試本身

這個專案把 mutation testing 當成測試的驗收閘門，規則是：**一個測試沒有「親眼看它失敗過」就不算交付**。

做法是：對生產程式碼做一個具名的修改（mutation），重新編譯、執行，確認**指名的那個測試**真的失敗，然後還原。每個測試都要附上「把哪一行改成什麼，這個測試就會失敗」的紀錄，包含實際觀察到的失敗輸出。如果找不到任何 mutation 能讓某個測試失敗，那個測試就要被刪掉——因為它證明不了任何事。

實測成效：這個做法在這個 repo 上已經抓出 11 個「會通過但證明不了任何事」的測試。證據文件在 `doc/audit/mutation-evidence-*.md`（2 份）。

兩個已知的陷阱：

1. 確認 mutation 有落在檔案裡還不夠，它必須落在**測試真正會走到的那條路上**。
2. 一個 mutation 如果一次弄壞 30 個測試，對其中任何單一個測試都是很弱的證據——要盡量找窄的 mutation。

為什麼存在：前面所有閘門都在檢查產品；mutation testing 是**檢查閘門本身的閘門**。它把「測試有效」從信念變成可驗證的事實，也直接呼應整個專案的主題：不能通過「親眼看到它失敗」這個考驗的測試，就是另一種「看起來還好」。

## 測試資產規模

| 資產 | 規模/形式 | 用途 |
|---|---|---|
| gtest 測試 | **31 個 `.cpp`、414 個測試**，編成 `test_routing_strategy` 單一執行檔（2026-08-10 更正） | L1 |
| `p4_proxy/tests/` | **12 個** Python 檔、**312 個**測試（unittest 格式，非 pytest） | L1 的 P4 Python 半邊 |
| `tests/python/` | 2 個 Python 檔、**101 個**測試（kernel 端 + 測試工具本身）。⚠️ **沒有**被 ctest 註冊 | L1 / 工具自我測試 |
| `tests/shell/` | 1 個 shell 測試 | 腳本層 |
| `tests/fixtures/` | 31 個 `.bin`（真實 OVS + Ryu + Mininet 抓取的 sFlow 封包 golden fixtures） | 真實流量對照 |
| `doc/audit/` | 2 份 `mutation-evidence-*.md` | mutation 驗收證據 |

## 什麼還沒有被涵蓋

workflow 文件本身有「這些工具『沒有』涵蓋什麼」專節（`doc/testing_workflow.md`），其內容不在本文件材料內。以下僅根據材料中可明確辨識的缺口列出。

材料中明確提到的工具涵蓋範圍限制：

1. **L4 不比數值**：`compare_baseline.py` 只比較 shape 和 facts，不比 rates/counters/timestamps 的數值——因為這些數值每秒都在變。因此「數值是否正確」不在 L4 的涵蓋範圍內。
2. **L3 的 contract 檢查有範圍限制**：`l3_component_check.py` 的 contract 檢查只對 `spec.py` 有涵蓋的 endpoint 有效；沒有 spec 的 endpoint 只能做 existence 檢查。
3. **log 檢查目前只有 kernel 的**：`check_logs.py` 檢查的是 NDTwin kernel log；材料中沒有其他元件 log 的同等檢查工具。
4. **環境依賴造成的覆蓋缺口**：L0 在 toolchain 缺席時回報 SKIP（覆蓋降低但不算失敗）；p4_proxy 的 Python 測試在 interpreter 缺 P4Runtime protobufs 時被 skip——這是環境限制，不是測試壞掉，但在那些機器上，P4 路徑的 Python 半邊沒有被驗證。
5. **`stack.sh` 只保證 1–3 步**：control plane、data plane、kernel 加上 convergence 是腳本化的；readers、traffic、apps（steps 4–6）由每個測試場景各自啟動，所以這幾層的啟動再現性不在 `stack.sh` 的保證範圍內。

材料本身不足以判斷的範圍：

6. workflow 文件「這些工具『沒有』涵蓋什麼」專節的實際內容不在本文件材料內。
7. 判定標準中的行程健康度、記憶體與 thread 測量，材料中只有章節標題與 `--traffic` 會加入 telemetry checks 的線索；具體判定工具與標準需要另外查閱 `doc/testing_workflow.md`。
