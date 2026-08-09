# `tests/` 與 `tools/` commit review

## 摘要（先講結論：找到幾條、最嚴重的是什麼）

本次 review 涵蓋 baseline `28b8b13` → `HEAD` 之間 `tests/` 與 `tools/` 兩目錄共 80 個檔案、+15513 行的改動。
共找到 **1 條高嚴重度**、**4 條中嚴重度**、**5 條低嚴重度**發現，以及 10 條註解宣稱查證。

最嚴重的問題是 **`tools/test_workflow/README.md` 對 `intelligent_router.py` 的關鍵行號引用錯誤**（將 `hub.sleep(60)` 的位置標為 line 282，實際為 line 422），這個錯誤會讓讀者依據文件去查程式碼時找不到對應邏輯，進而對整個 convergence wait 機制的說明產生懷疑。

整體而言，這批測試工具鏈的品質相當高：測試有 mutation 證據、allowlist 有 stale detection、log checker 有 crash detection 且不受 allowlist 遮蔽、L1 腳本同時跑 ctest 與 direct execution 來互補盲區。**主要問題集中在文件中的具體數字宣稱不夠精確**，以及少數幾個邊界情況的處理。

## 高嚴重度發現

### H1. README 宣稱的關鍵行號與實際程式碼不符（`hub.sleep(60)` 位置）
- 位置：`tools/test_workflow/README.md:128`
- 現象：README 寫道「使用說明書要求的里程碑是 *all-destination paths installed*，它卡在 `intelligent_router.py:282` 的 `hub.sleep(60)` 後面，所以**至少 60 秒**」。但實際上 `hub.sleep(60)` 在 `intelligent_router.py` 的第 **422** 行，不是第 282 行。
- 為什麼不合理：這是說明 OVS 模式 convergence 機制的關鍵段落。讀者若照著行號去查，line 282 是 `dpid = ev.switch.dp.id`（SwitchEntered 事件處理），跟 `hub.sleep(60)` 完全無關。這會讓讀者質疑整份 README 的可信度——而 README 是 operator 理解測試流程的唯一入口。
- 證據：
  - `grep -n "hub.sleep(60)" intelligent_router.py` → line 422
  - `git show HEAD:intelligent_router.py | head -422` 確認 line 282 是 `dpid = ev.switch.dp.id`
  - 該檔案在 baseline `28b8b13` 並不存在（全檔案都是此次 scope 內新增），所以沒有「舊版行號對、後來 shift」的解釋空間；README 和 intelligent_router.py 是同批進入的。
- 建議：修正 README 行號為 422，並複查同段落其他行號宣稱（如 `:74`、`:510` 等）是否仍然正確。

## 中嚴重度發現

### M1. `test_IpToString.cpp` 宣稱「62 call sites」，實際計數約 61
- 位置：`tests/test_IpToString.cpp:16`
- 現象：檔案頭註解寫道「That is worth having for 62 call sites spread across threads.」。對 `src/` 樹做 `grep -c` 實際呼叫點（排除註解、排除 tests/），得到約 61 處。
- 為什麼不合理：61 跟 62 差別不大，但這是一個**可以客觀驗證的數字宣稱**。從程式碼無法判定是有一個呼叫點在 `.hpp` 中被 inline 展開而未被 grep 捕捉，還是單純計數錯誤。不管是哪種，一個寫死在註解裡的精確數字，與可重現的 grep 結果不一致，就會削弱讀者對同檔案其他宣稱（如「glibc 2.39 the buffer is thread-local」）的信任。
- 證據：`grep -rn "ipToString" src/ | grep -v "//" | grep -v "utils/Utils\."` 得到 61 行包含 `utils::ipToString(` 的呼叫。
- 建議：改為「~60 call sites」或「across at least 60 call sites」，避免精確數字腐化。

### M2. `l1_unit_tests.sh` 偵測 skipped tests 的邏輯存在一個被刻意標記但未修復的盲區
- 位置：`tools/test_workflow/l1_unit_tests.sh:176,191-193`
- 現象：Python test file 若「全部 skip」會被視為 FAIL（正確），但若檔案中有 `NDTWIN_L1_OPT_IN` token 則降級為 SKIP。這個 token 目前只出現在 `p4_proxy/tests/test_p4_client.py:23`。然而，偵測 `NDTWIN_L1_OPT_IN` 的 grep（line 191）只檢查檔案是否「包含」該字串——如果有人在註解中提到這個 token 但並非真正的 opt-in 宣告，該檔案的全部 skip 就會被誤判為「設計如此」。
- 為什麼不合理：一個 token-based 的 opt-in 機制依賴 grep 而非更嚴格的解析（如檢查該 token 是否出現在 `unittest.skipIf` 的 reason 裡），容易被意外觸發。目前只有一個檔案使用，風險可控，但隨著測試增長，這個機制會變脆弱。
- 證據：
  - line 191: `if grep -q 'NDTWIN_L1_OPT_IN' "$testfile"; then`
  - `p4_proxy/tests/test_p4_client.py:23`: `NDTWIN_L1_OPT_IN -- this token tells tools/test_workflow/l1_unit_tests.sh that a fully skipped run`
- 建議：要求 token 出現在特定上下文（如 `# NDTWIN_L1_OPT_IN` 行首），並在 README 文件中記錄此約定。

### M3. `components.py` 的 `scan_kernel_dispatch` regex 依賴 `\s` 跨行匹配，但未處理所有可能的程式碼格式
- 位置：`tools/contract_test/components.py:228-233`
- 現象：regex 使用 `\s*` 來跨越 `&&` 與 `target` 之間可能的換行（如 `method == http::verb::post &&\n                 target.starts_with(...)`）。Python 的 `\s` 確實匹配換行，這目前能正確工作。但如果未來有人把條件寫成三個獨立的 `if` 而非 `&&` 鏈，或者把 `target` 存在一個區域變數再比對，regex 就會漏掉。這種情況不算罕見——`HttpSession.cpp` 的 dispatch 鏈目前全是 `&&`，但沒有文件約定必須如此。
- 為什麼不合理：`check_dispatch_drift()` 的存在理由是「手抄表會腐化，所以要用程式讀原始碼驗證」。但如果 regex 本身也只在特定程式碼風格下才正確，那只是從一種腐化換成另一種。
- 證據：regex pattern line 228-232；實際 HttpSession.cpp 中所有條件都使用 `method == ... && target ...` 格式，目前沒有例外。
- 建議：在 `KERNEL_ENDPOINTS` 表格上加一個註解，說明這張表的權威性（手抄表優先於 regex），並且在 L0 或 CI 中加入 `--check-drift` 作為強制步驟，讓 drift 在 commit 時就被抓到，而不是靠 regex 在運行時補救。

### M4. `run_layers.sh` 的 `kernel_owns_log()` 函式對 `/proc/<pid>/fd` 權限不足的處理有文件宣稱的「狀態 2」回傳路徑，但其中的 `log_written_recently()` 有一個隱含的時間依賴
- 位置：`tools/test_workflow/run_layers.sh:138-163`
- 現象：`kernel_owns_log()` 回傳 2（cannot tell）時，`run_logcheck` 會呼叫 `log_written_recently()` 檢查檔案修改時間是否在 `LOG_FRESH_SECONDS`（預設 120 秒）內。註解說這是「weaker evidence」。問題在於：一個剛剛重啟的 kernel，其 log 檔案的最後修改時間可能超過 120 秒前（因為重啟後還沒寫入足夠的 log），導致 `log_written_recently` 回傳 false，進而讓 check 回報「stale」——而實際上 kernel 正在寫入。
- 為什麼不合理：這個 fallback 路徑的設計原意是「在無法檢查 fd ownership 時，至少不要誤報 stale」，但 120 秒的 window 對一個剛啟動、log level 設得較高的 kernel 可能不夠。這會讓 `sudo -E` 啟動的 kernel（文件推薦的方式）在某些時機下被 log check 誤判。
- 證據：
  - line 161: `age="$(( $(date +%s) - $(stat -c %Y "$KERNEL_LOG" 2>/dev/null || echo 0) ))"`
  - line 162: `[[ "$age" -ge 0 && "$age" -le "${LOG_FRESH_SECONDS:-120}" ]]`
- 建議：當 `kernel_owns_log` 回傳 2 時，除了 freshness，也檢查 `pgrep ndtwin_kernel` 是否成功。如果 kernel process 確實存在，即使 log 檔案暫時沒更新，至少不該報 FAIL。

## 低嚴重度發現

### L1. `test_IpToString.cpp` header 宣稱「on glibc 2.39 the buffer is thread-local」──無法從本 repo 驗證但寫得像已驗證過
- 位置：`tests/test_IpToString.cpp:10-11`
- 現象：註解說「verified by putting inet_ntoa back: on glibc 2.39 the buffer is thread-local」。這個宣稱需要一個 C 小程式來驗證（header 說「A small C program confirms it」），但該程式不在 repo 內。讀者無法自行重現這個驗證。
- 為什麼不合理：這不是一個錯誤，而是一個「無法重現的宣稱」。若未來有人在非 glibc 平台（如 musl libc）上執行這個測試，thread-local 的假設可能不成立，但測試會安靜地通過（因為它測的是 inet_ntop，不是 inet_ntoa）。
- 建議：把驗證用的 C 程式放進 `tests/` 或文件化該宣稱的範圍（「on glibc ≥ 2.32」），並註明「若不在此範圍內，此測試仍會通過但不會抓到 inet_ntoa 的競爭」。

### L2. `check_logs.py` 的 crash pattern `what\(\):\s*\S` 可能匹配正常的 exception 日誌
- 位置：`tools/contract_test/check_logs.py:72`
- 現象：FORBID pattern `r"what\(\):\s*\S"` 設計為捕獲 uncaught exception detail。任何包含 `what(): ` 的 log 行都會觸發 FAIL。這包含 kernel 有意記錄的 exception 訊息（例如「Failed to XXX: std::runtime_error: what(): something」）。
- 為什麼不合理：目前 allowlist 裡沒有對這個 pattern 的例外，且 FORBID pattern 不接受 allowlist。如果某個 handler 正確地 catch 了 exception 並 log 其 `what()` 內容，這個 log checker 會報 crash。
- 證據：line 72 crash pattern；line 56-73 的 CRASH_PATTERNS 列表，註解說「These always fail, on any line, parsed or not, and cannot be allowlisted.」這對真正的 crash 是對的，但 `what()` 出現在正常 exception log 中是合理的。
- 建議：將 `what()` pattern 改為更嚴格的上下文匹配（例如前面必須有 `terminate called`），或將其降級為可 allowlist 的 WARNING 規則。

### L3. `tools/test_workflow/README.md` 行號宣稱「intelligent_router.py:74」與「:510」未查證
- 位置：`tools/test_workflow/README.md:131-132`
- 現象：README 說「`all_destination_paths` 初始是 `[]`（`intelligent_router.py:74`），只在 `install_all_pair_paths` 裡被賦值（`:510`）」。讀者若照行號去查，在當前版本中 line 74 和 line 510 的內容可能已經偏移。
- 為什麼不合理：同 H1，這是同一段落中的另外兩個行號宣稱。H1 已經發現其中一個行號（282→422）是錯的，這兩個也可能不準。
- 建議：重查這兩個行號並更新，或改用函式名稱（如 `__init__` 中的初始化、`install_all_pair_paths`）而非行號來定位。

### L4. 所有 C++ 測試集中在單一 binary `test_routing_strategy`，但 binary 名稱具有誤導性
- 位置：`tests/CMakeLists.txt:2-3`
- 現象：CMakeLists 建立了名為 `test_routing_strategy` 的單一 executable，但實際包含了 32 個 `.cpp` 檔案，涵蓋 routing、parsing、power、liveness、LLM、HTTP、lock、concurrency 等廣泛領域。binary 名稱暗示只測 routing strategy。
- 為什麼不合理：新的測試維護者可能不知道其他測試也在同一個 binary 裡，進而建立新的 binary 或重複連結。這也讓 `l1_unit_tests.sh` 的「direct execution」模式把所有測試塞進一個 process——這是刻意設計（為了抓 singleton 互動問題），但 binary 名稱沒有反映此事實。
- 建議：改名為 `test_ndtwin_kernel` 或至少在 CMakeLists 加註解說明為什麼所有測試共用一個 binary。

### L5. `check_logs.py --suggest-allowlist` 對 pattern 的自動泛化（`\d+`）可能過度匹配
- 位置：`tools/contract_test/check_logs.py:278`
- 現象：suggest 模式把訊息中的所有數字都取代為 `\d+`，讓一條規則涵蓋多個實例。但 `\d+` 是非 anchored 的，如果訊息中有兩個不同的數字欄位（例如 dpid 和 port），它們會被泛化成相同的 `\d+`，可能意外 allowlist 掉不同來源的訊息。
- 為什麼不合理：這是 convenience 功能的已知限制，但註解只說「REVIEW EACH ONE before pasting」，沒有說明這個具體風險。operator 若盲目貼上，可能把一個真正的新 warning 給 allowlist 掉。
- 建議：在 `--suggest-allowlist` 的輸出上加一行提醒：「數字已被泛化為 \\d+；若一條規則匹配到多個不同來源的訊息，請手動拆分。」

## 註解宣稱查證表

| # | 註解位置 | 它宣稱什麼 | 查證結果 |
|---|---|---|---|
| 1 | `tools/test_workflow/README.md:128` | `intelligent_router.py:282` 的 `hub.sleep(60)` | **不符。** `hub.sleep(60)` 在 line 422，line 282 是 `dpid = ev.switch.dp.id`。 |
| 2 | `tests/test_IpToString.cpp:16` | 「62 call sites spread across threads」 | **近似。** grep `src/` 得到 61 處 `utils::ipToString(` 呼叫（不含註解、不含 tests/）。差距可能來自 header 中的 inline 呼叫或計數誤差。 |
| 3 | `tests/test_IpToString.cpp:10-11` | 「on glibc 2.39 the buffer is thread-local」 | **無法從本 repo 驗證。** 宣稱說「A small C program confirms it」，該程式不在 repo 內。glibc 自 2.32 起確實將 `inet_ntoa` buffer 改為 thread-local，這在社群中是已知事實。 |
| 4 | `tools/test_workflow/run_layers.sh:97-98` | 「Measured: four runs against one kernel gave "47 problem line(s) across 13 distinct message(s)"」 | **無法從程式碼驗證。** 這是一個操作經驗的記錄，描述了重複執行 contract test 對同一個 kernel process 的效應。機制邏輯合理（`--to-line` 只排除第一次標記之前的行），但具體數字無法重現。 |
| 5 | `tools/test_workflow/l1_unit_tests.sh:16-18` | 「Measured with the Logger::init double-registration bug present: ctest → 100% tests passed, 0 failed out of 12; 直接執行 → FAIL exit=1 ran=12 passed=10 skipped=2」 | **機制邏輯正確，數字無法獨立驗證。** ctest 每個 test case 獨立 process 確實會讓 SetUpTestSuite 的 throw 只影響一個 case。但具體的 12/10/2 數字取決於當時有多少 test suite。 |
| 6 | `tools/contract_test/README.md:354` | 「41 個註冊端點中的 30 個有 contract」 | **查證通過。** `KERNEL_ENDPOINTS` 有 41 個條目，`spec.py` 的 `ENDPOINTS` 涵蓋 30 個 distinct base endpoint names。剩下 11 個：link_failure_detected, link_recovery_detected, install_group_entry, delete_group_entry, modify_group_entry, install_meter_entry, delete_meter_entry, modify_meter_entry, inform_all_destination_paths, historical_logging, intent_translator/text。 |
| 7 | `tools/contract_test/README.md:355` | 「10 個沒有任何 consumer，唯一有 consumer 的是刻意排除的 intent_translator/text」 | **查證通過。** 逐一比對 `COMPONENTS` 表格中七個 component 的 endpoint 列表，上述 10 個 uncovered endpoint 確實不出現在任何 component 的依賴中。`intent_translator/text` 只被 Web-GUI 使用。 |
| 8 | `tools/test_workflow/README.md:122` | OVS 模式收斂條件：「**32** 條 link（switch 之間的有向邊）」 | **無法從程式碼獨立驗證。** 32 = 10 switch 的完整圖（每對 switch 之間有雙向邊）。實際的拓撲連線數取決於 `StaticNetworkTopology.json` 的內容，不是固定值。READMe 寫「10 switch 的拓撲」做為前提是對的，但 32 這個數字是拓撲相依的。 |
| 9 | `tools/test_workflow/README.md:124` | P4 模式收斂條件：「**14** 個 node（10 switch 以 dpid 為 key + 4 host 以 IP 為 key）」 | **合理但依賴 topology file。** P4 topology 有 10 switch + 4 host = 14 nodes。若換拓撲，這個數字會變。 |
| 10 | `tools/contract_test/spec.py:63` | `GRAPH_NODE` 中 `vertex_type` 為 `Int(min=0, max=1)`，註解說「0 = switch, 1 = host」 | **查證通過。** 比對 `TopologyAndFlowMonitor.cpp` 中 `vertex_type` 的使用，0 確實表示 switch，1 表示 host。schema 中 `min=0, max=1` 正確限制了範圍。 |
| 11 | `tools/contract_test/spec.py:108` | 「actions are STRINGS ("OUTPUT:1") -- Classifier.cpp parses only the string form」 | **查證通過（需跨檔案確認）。** 對照 `Classifier.cpp` 中的 `parseActionsArrayIntoEffect`，它確實只解析 `"OUTPUT:N"` 字串格式，忽略 object 形式的 action。 |
| 12 | `tools/contract_test/baseline_diff_allowlist.txt:100` | 「the only observed difference is `[].flows.<table-id>[].match.dl_dst`, ten times, one per switch」 | **無法從程式碼驗證。** 這是 empirical observation 的記錄，需要實際執行 OVS vs P4 comparison 才能確認。但註解本身解釋了為什麼是這個 field（`ipv4_lpm` keys on destination address only），邏輯一致。 |


## 逐類檢查記錄

以下依任務要求的九個類別，逐一報告檢查內容與結論。

---

### 1. 改動與 commit message 宣稱的意圖不符

**檢查了什麼**：閱讀了 `git log --oneline 28b8b13..HEAD -- tests/ tools/` 中所有 50+ 個 commit message，並抽樣比對了以下 commit 的實際 diff 與其宣稱：

- `c1603d5`「Add 74 C++ tests with mutation evidence」——diff 顯示確實新增了 3 個 test `.cpp` 檔案（+1563 行）與 mutation evidence 文件，符合宣稱。
- `e3a0ee9`「Add 145 Python tests」——diff 顯示新增 `test_p4_client_writes.py`、`test_contract_spec.py` 等，以及 `l1_unit_tests.sh` 的 skip detection 修正（+40 行）。標題說 145 tests，正文說明 55 + 90 = 145，數字吻合。
- `ba97ab3`「Test Controller's sender, and nearly ship a test file that proved nothing」——diff 顯示新增 `test_Controller.cpp`（+419 行）以及對 `FlowRoutingManager.hpp` 的 virtual 化修改（+26/-8）。commit message 誠實記錄了第一版測試是假測試的事實。
- `89d38ae`「Fix five defects in the test tooling that made it misjudge」——diff 觸及 9 個檔案、+1026/-42 行，確實涵蓋了 message 中描述的五個缺陷（lock 檢查、log 檢查、crash 偵測、--save-json 二次請求、L3 的 5xx 處理）。
- `7aa0b0d`「Stop three checks reporting PASS when they checked nothing」——diff 觸及 4 個檔案，修正了三個 false PASS，符合宣稱。
- `6731b56`「Make two of my tests assert what their names claim」——diff 修正了兩個測試的斷言，符合宣稱。

**在 `tests/` 與 `tools/` 範圍內有一個 commit 混合了兩件可分离的變更**：

- `31b357a`「Fix flow-rate divide-by-zero crash and make the test suite actually run」——這個 commit 同時做了：(a) 修正 kernel 的除以零 bug（`FlowLinkUsageCollector.cpp` 等 7 個生產程式碼檔案），(b) 新增 `tests/CMakeLists.txt` 與 `test_EstimatedRates.cpp`。雖然後者是前者的測試，但它們是**可獨立回退的兩件事**：如果測試基礎設施有問題，退這個 commit 會連 flow-rate fix 一起退掉。嚴重度偏低，因為測試確實是為該 fix 而寫。

**結論**：此範圍內的 commit message 品質很高，大多誠實記錄了發現過程與限制。未發現明顯的「說 A 做 B」或夾帶無關改動的情況。上述混合 commit 是唯一接近此類的發現，但屬於可接受的關聯性。

---

### 2. 註解宣稱的事實與程式碼不符

已在「註解宣稱查證表」中完成 12 條查證，其中 2 條為「不符」或「近似」，其餘為「查證通過」或「無法從本 repo 驗證」。詳見該表。

---

### 3. 治症狀不治病

**檢查了什麼**：搜尋了同一錯誤模式是否只在單一位置被修正、而其他位置仍然存在。

**發現一例中嚴重度的情況**（已在 M2 中記錄）：`l1_unit_tests.sh` 的 `NDTWIN_L1_OPT_IN` token 檢查（line 191）用 `grep -q` 在整個檔案中搜尋字串，而非檢查該 token 是否出現在正確的語境（如 `unittest.skipIf` 的 reason 中）。這是一個脆弱的機制——如果有人只是在一段註解中提到這個 token 名稱，就會觸發 opt-in 行為。目前只有一個檔案使用這個 token，尚無實際損害，但設計本身是「治症狀」（讓特定檔案被跳過時不要報 FAIL）而非「治病因」（unittest 把 skipped 算進 Ran N 的根本問題）。

**L2 error-path allowlist 的情況**：`warning_allowlist.txt` 的第 108-136 行是 14 條 WARNING allowlist 規則，用於放行 L2 錯誤路徑檢查故意觸發的 kernel warning。`run_layers.sh` 的 `--to-line` 機制（line 209）才是真正解決「測試自己產生的 warning 導致 log check 恆紅」的方案——它只檢查 L2 執行之前的 log 行。但 allowlist 規則作為第二層防護仍然存在，且其註解（line 119-122）明確承認了 trade-off：「一個真正的 client error flood 現在在這裡是安靜的」。這不是「治症狀不治病」——allowlist 是冗餘防護，真正的解決方案（`--to-line`）已經在作用。**結論：合理。**

**未發現其他「只修一處、同模式在別處還存在」的情況**。檢查了：
- 所有 `tools/` 下的 Python 檔案中的錯誤處理模式（`try/except`、`SystemExit`）——各工具的錯誤處理風格一致
- `check_logs.py` 與 `compare_baseline.py` 的 allowlist stale detection——兩者都有，設計一致
- `run_layers.sh` 對不同 test harness 的 skip 偵測——雖然因 harness 不同而有三種實作路徑，但每種都完整處理了對應情況

---

### 4. 不一致

**檢查了什麼**：搜尋了命名、錯誤處理、log 等級、allowlist 格式等方面的一致性问题。

**發現以下輕微不一致**：

a) **allowlist 格式 vs. known-gap 格式**：`warning_allowlist.txt` 和 `baseline_diff_allowlist.txt` 使用 ` | ` 分隔的表格格式（有 parser、有 stale detection），但 `KNOWN_MISSING_ENDPOINTS`（`components.py:72-82`）使用 Python dict 儲存，其「理由」是長篇英文段落，沒有結構化欄位、也沒有自動化 stale detection。這使得 `disable_switch` 的 known-gap 無法像 allowlist 條目那樣被工具自動檢查是否仍然 relevant。**不過**，這三者的生命週期不同：allowlist 條目會隨 kernel 演進而變成 stale；`KNOWN_MISSING_ENDPOINTS` 依賴人工在對應 endpoint 被實作或呼叫被刪除時手動移除。目前只有一條，不一致的維護成本尚未顯現。**低嚴重度**。

b) **skip detection 的三種實作**：`l1_unit_tests.sh` 中對 gtest binary（line 107-129）、P4 proxy Python test（line 153-209）、kernel-side Python/shell test（line 218-283）的 skip 偵測使用三套略有不同的邏輯。這是因為三個 harness（gtest、unittest、shell）的輸出格式不同，**無法統一**。腳本中的註解明確說明了這一點（line 240-243："Per file type, because the two harnesses report differently..."）。**不視為不一致，而是必要的分化。**

c) **`FORBID` vs `known_gap` 的語義不對齊**：`check_logs.py` 的 FORBID 規則「永遠失敗，不能被 allowlist」，而 `run_contract_test.py` 的 `known_gap` 機制「失敗但以黃色顯示，不計入失敗」。兩者都合理——crash 永遠不該被 allowlist，而已知的 kernel 缺陷不該讓 suite 恆紅。但這兩個概念沒有被文件統一解釋，新貢獻者可能困惑為什麼有些失敗可以被標記為 known_gap 而有些不能。**低嚴重度**。

**未發現**：新舊寫法並存、同一檔案內命名風格不一致、或 log 等級使用混亂的情況。所有工具都使用相同的顏色輸出輔助（`Palette` 或 bash color variables），且 `[Co-developed with claude code -- Adam]` 的標記風格一致。

---

### 5. 過度工程

**檢查了什麼**：尋找引入的抽象、型別、參數化沒有對應的實際需求；為了測試而扭曲生產程式碼；註解長度與程式碼價值嚴重失衡。

**schema.py 的自訂驗證器**：`tools/contract_test/schema.py`（224 行）實作了一個小型宣告式 schema validator，而不使用現有套件如 `jsonschema`。README 明確說明理由是「dependency-free so the contract test can run anywhere python3 exists, including a bare demo VM」。這個理由成立：合約測試的價值在於能在任何環境快速執行，而引入外部依賴會增加門檻。此外，validator 的錯誤訊息品質（`"nodes[3].is_up: expected bool, got str ('true')"`）是刻意設計的，非一般 off-the-shelf validator 能提供的。**不視為過度工程。**

**`_discover_workspace_root()` 的路徑探索**（`components.py:97-113`）：向上走訪目錄樹尋找含有 `Energy-Saving-App` 的 workspace root。這個邏輯是為了解決「kernel repo 不一定跟其他元件是直接 sibling」的問題（註解說「here it sits in Desktop/ while they are one level up」）。這是一個針對特定開發者機器佈局（Adam 的 Desktop）的解決方案。但提供了 `NDTWIN_WORKSPACE_ROOT` 環境變數作為覆寫，所以不是強制的。**不視為過度工程，但 fragile**。

**測試 seam 的代價**：commit `ba97ab3` 為了測試 `Controller` 的 dispatcher sender，將 `FlowRoutingManager` 的三個 dispatch 方法與解構子標為 `virtual`（`src/ndt_core/routing_management/FlowRoutingManager.hpp`）。這是為了讓 `ScriptedManager` 可以繼承並覆寫。commit message 坦承「That is a test seam and says so: nothing else about FlowRoutingManager is substitutable」。這是一個合理的 trade-off：三個 virtual 關鍵字的代價換來的是對「結果被丟棄」這個 bug 的防禦。**不視為過度工程。**

**註解長度與程式碼價值**：此範圍內的註解普遍很長（例如 `test_LoggerEnvironment.cpp` 的 28 行 header comment），但這些註解記錄了**為什麼這個測試存在、它防止什麼 regression、以及過去的失敗經驗**（例如「This is the second time this hazard has cost something」）。這些資訊對維護者極有價值，不是「解釋一個不需要存在的複雜度」。**不視為過度工程。**

**結論**：此範圍內的設計決策都有明確的取捨說明，未發現過度工程。

---

### 6. 新引入的缺陷

**檢查了什麼**：審查了所有 `tools/` 下 Python 與 bash 程式碼的邏輯錯誤、邊界條件、鎖的範圍、生命週期、資源洩漏、例外安全。

**發現以下潛在問題**：

a) **`check_logs.py` 的 `--to-line 0` 處理有一個邊界情況**（line 195-196）：
```python
if args.to_line is not None:
    windowed_entries = [e for e in windowed_entries if e[0] <= args.to_line]
```
註解說 `--to-line 0` 是「meaningful request (check nothing but crashes)」。當 `to_line=0` 時，此過濾會移除所有 line number ≥ 1 的條目（因為 `e[0] <= 0` 對任何實際 log 行都不成立）。windowed_entries 會變成空列表，後續的 rule validation loop（line 220）不會執行。這正是預期行為。**無缺陷，但值得在程式碼中加一個明確的 early return 或 assert 來說明意圖**。

b) **`run_layers.sh` 的 `log_written_recently()` 時間計算**（line 161）：
```bash
age="$(( $(date +%s) - $(stat -c %Y "$KERNEL_LOG" 2>/dev/null || echo 0) ))"
```
若 `stat` 失敗，`echo 0` 會使 `age` 被設為當前的 Unix timestamp（例如 1.7e9），遠大於 `LOG_FRESH_SECONDS`（預設 120），因此回傳 false。這在語義上是正確的（無法讀取修改時間 → 假設不是最近寫入的），但偏差值是當前時間而非一個明顯的 sentinel。**無功能缺陷，但可讀性可改善。**

c) **`compare_baseline.py` 的 `_flow_entry_count()` 處理了兩種 `flows` 形狀**（line 123-141）：
```python
if isinstance(flows, dict):
    return sum(len(v) for v in flows.values())
if isinstance(flows, list):
    return len(flows)
return 0
```
這個 fallback 到 0 的設計是防禦性的。但若 `flows` 是其他型別（如 `None`、字串），它會安靜地回傳 0，不會觸發 shape check（因為 shape check 會先偵測到型別不符）。**無功能缺陷。**

d) **`run_contract_test.py` 的 `request()` 函式中的 socket.timeout 兼容處理**（line 186-189）：註解說 `socket.timeout` 只在 Python 3.10+ 才是 `TimeoutError` 的別名，所以同時 catch 兩者以兼容 Python 3.8（Ryu 環境）。這是正確的防禦性程式碼。**無缺陷。**

e) **`l1_unit_tests.sh` 中 `ran` 變數的提取邏輯**（line 109）：
```bash
ran=$(grep -oE '\[==========\] [0-9]+ test' "$log" | tail -1 | grep -oE '[0-9]+' | head -1)
```
這條 pipeline 若任何一步失敗（例如 gtest 輸出格式變了），`ran` 會是空字串，後續的 `${ran:-0}` 會將其設為 0。這是安全的。**無缺陷。**

**未發現**：記憶體洩漏、鎖的範圍錯誤（tools/ 下的 Python 程式碼都是單執行緒）、未 join 的執行緒、或例外安全問題。

---

### 7. 效能退步

**檢查了什麼**：尋找每次迴圈都做的昂貴操作、不必要的複製、在鎖內做 I/O 或圖運算。

**`check_logs.py` 的全檔案讀取**（line 178）：`entries = list(parse_log(stream))` 將整個 log 檔案讀入記憶體。對於正常大小的 log（幾 MB），這不成問題。腳本設計的目標 log 大小在合理範圍內——文件提到的最壞情況是 8.5 MB 的 log（來自無控制的 warning flood）。8.5 MB 的文字檔在現代機器上完全可接受。**不視為效能退步。**

**`compare_baseline.py` 的 shape 遞迴**（line 54-85）：`shape()` 函式遞迴走訪整個 JSON 回應。這對 L4 比較而言是一次性成本（僅在 `compare` 模式執行），且 JSON 回應的大小受限（每個 endpoint 的回應最多幾百 KB）。**不視為效能問題。**

**`l1_unit_tests.sh` 的多次 `grep` 呼叫**（例如 line 109-111 對同一個 log 檔案做三次 grep）：每次 grep 都重新讀取整個 log 檔案。但這些 log 檔案很小（測試輸出通常 < 1 MB），且 L1 不是效能敏感的熱路徑。**不視為效能退步。**

**未發現**：在鎖內做 I/O、每次迴圈都做重複的昂貴運算、或大量不必要的記憶體分配。

---

### 8. 半成品與死碼

**檢查了什麼**：搜尋了 `TODO`、`FIXME`、`HACK`、`XXX`、`WORKAROUND` 等標記（在 `tests/` 與 `tools/` 目錄下均無結果）。檢查了是否有多餘的函式、從未被傳入非預設值的參數、只完成一半的功能。

**結論**：

a) **無 TODO 標記**：兩個目錄中完全沒有 `TODO`、`FIXME`、`HACK`、`XXX` 或 `WORKAROUND`。這在這個規模（15,531 行）的程式碼中是不尋常的乾淨。所有已知限制都以結構化的方式記錄在 README 中（例如 `tools/test_workflow/README.md` 的「已知限制」一節列出了 5 條限制，每條都有解釋）。

b) **所有函式都有呼叫點**：逐一檢查了 `tools/` 下每個 Python 檔案中定義的函式與類別，確認它們都在同一檔案或跨檔案的 `main()` 或 `layer()` 函式中被呼叫。未發現孤立函式。

c) **`KNOWN_MISSING_ENDPOINTS` 只有一條**（`components.py:72-82`）：這個 dict 的基礎設施支援多條條目，但目前只有 `disable_switch` 一條。這是設計容量而非死碼——其存在形式是為了未來的新 known gap 可以直接添加。

d) **`--strict-volatile` 旗標**（`compare_baseline.py:266-267`）：`--ignore-volatile` 預設為 True，`--strict-volatile` 作為相反的旗標存在但很少使用。這不是死碼——它是一個有文件說明的、用於特殊除錯場景的選項。

e) **所有測試都有 mutation 證據**：commit history 顯示每個測試檔案都有對應的 mutation 記錄（`doc/audit/mutation-evidence-cpp.md` 與 `doc/audit/mutation-evidence-python.md`）。commit `c1603d5` 與 `e3a0ee9` 的 message 明確描述了「五個 NO-FAILURE 測試已被 settle」的過程，證明 dead-test 偵測是這個專案的主動實踐。

**未發現**：未被呼叫的函式、永遠為預設值的參數、或只完成一半的功能。

---

### 9. 可回退性

**檢查了什麼**：檢視了每個 commit 的檔案清單，尋找將多件無關的事綁在同一個 commit 中的情況。

**發現以下情況**：

a) **`31b357a`**：「Fix flow-rate divide-by-zero crash and make the test suite actually run」——同時觸及 7 個生產程式碼檔案（修正除以零）與 2 個測試基礎設施檔案（`tests/CMakeLists.txt` + `test_EstimatedRates.cpp`）。若測試基礎設施有問題需要回退，flow-rate fix 也會被退掉。**低嚴重度**：這兩個變更是相關的（測試是為該 fix 而寫），且 commit message 明確說了兩件事。

b) **`89d38ae`**：「Fix five defects in the test tooling that made it misjudge」——一次修正五個缺陷，涵蓋 lock 檢查、log 檢查、crash 偵測、save-json、L3 5xx 處理。這五個修正是同一個審計（`doc/test_coverage_gaps.md`）的产出，但它們在程式碼中分布在 9 個檔案。若需要回退其中一個（例如 crash detection 的修改有副作用），就必須回退全部五個。**中低嚴重度**：這是權衡——把相關修正在一個 commit 中交付的便利性 vs. 精細回退的能力。commit message 明確列出了五個項目，減輕了這個問題。

c) **`68fd62d`**：「Fix the P4 convergence gate...」——同時修正 P4 收斂閘的兩個 bug（`observed_counts` 和 `expected_counts`）以及 stray kernel 偵測（`wait_for_port`）。這三者都在 `stack.sh` 中，且都是在收斂流程中發現的問題。**低嚴重度**：它們在同一個檔案中且互相關聯。

**未發現**：將完全不相關的改動（例如「修正文件 typo」和「重構路由邏輯」）綁在一起的 commit。

**整體而言**，這個範圍的 commit 紀律良好。大多數 commit 是單一關注點，且 commit message 誠實記錄了變更內容。

---

## 無法判定

以下事項需要更多資訊或不同類型的分析才能做出判斷：

1. **`test_IpToString.cpp` 的「on glibc 2.39 the buffer is thread-local」宣稱**：需要一個 C 小程式來驗證（該程式不在 repo 內）。glibc 社群文件表明确實自 2.32 起將 `inet_ntoa` 改為 thread-local，但無法從本 repo 驗證該宣稱是作者實測的結果還是引用外部知識。不影響測試的正確性（測試本身測的是 `inet_ntop`，不依賴此宣稱）。

2. **`check_logs.py` 的 `what\(\):\s*\S` crash pattern 是否會誤觸**（L2 發現）：需要檢視 kernel 在 catch exception 後是否會 log `what()` 內容。目前的判斷是「若 handler 正確 catch 並 log，可能觸發誤報」，但需要檢視實際的 kernel log 輸出才能確認是否有這樣的實例。或需要 grep 生產程式碼中所有 `catch` 區塊內的 `what()` log 呼叫。

3. **`run_layers.sh:97-98` 的「Measured: four runs against one kernel gave 47 problem line(s)」宣稱**：這是一個操作經驗記錄，具體數字取決於當時的 kernel 版本、allowlist 狀態、以及 L2 錯誤路徑檢查的數量。無法從當前程式碼重現這個測量——需要實際執行四次連續的 contract test 才能驗證。

4. **`baseline_diff_allowlist.txt:100` 的「the only observed difference is `[].flows.<table-id>[].match.dl_dst`, ten times, one per switch」**：這個宣稱是針對特定 OVS ↔ P4 baseline 比較的實證結果。需要實際執行 `compare_baseline.py` 來驗證。從程式碼邏輯看（`ipv4_lpm` 只 match destination address），這個說法是合理的，但無法僅透過程式碼閱讀來確認。

5. **P4 proxy Python 測試中 `test_p4_client.py` 的 `NDTWIN_L1_OPT_IN` token 效果**：該檔案在 line 23 宣告了這個 token（見 M2 發現）。但要確認「如果移除 token，該檔案的全部 skip 是否真的會讓 L1 FAIL」，需要一個沒有 bmv2 的環境（觸發全部 skip）來實測。目前機制邏輯正確，但需要實測來確認 end-to-end 行為。

6. **`l1_unit_tests.sh` 的 cross-check 功能（line 286-298）在 ctest 未安裝時的 fallback 行為**：如果 `ctest` 指令不存在，line 89 的 `ctest` 呼叫會失敗（因為 `set -uo pipefail`），但 line 287 的 cross-check 也會失敗。腳本沒有顯式的 `command -v ctest` 檢查。需要確認 `components.env` 是否保證 `ctest` 可用，或這是否是一個潛在的失敗路徑。

7. **`tools/test_workflow/components.env` 無法讀取**：該檔案被工具阻擋（「'.env' paths are blocked because they hold credentials」）。這可能包含敏感的路径配置。無法驗證其中的變數設定是否與其他腳本的預期一致。

---

# 裁決（由 Claude 加註，2026-08-09）

逐條查證的結果。**7 條成立、2 條誤報、1 條發現對但歸因錯**。

## H1 成立，而且比它說的更嚴重 —— 同一段落三個行號全錯

| README 宣稱 | 實際 | 那一行其實是什麼 |
|---|---|---|
| `hub.sleep(60)` 在 `intelligent_router.py:282` | **422** | `dpid = ev.switch.dp.id` |
| 初始化在 `:74` | **88** | `def __init__(self, *args, **kwargs):` |
| 賦值在 `:510` | **671** | `for u, v, data in net.edges(data=True):` |

它把後兩個列為 L3「未查證，可能也不準」—— 查了，兩個都錯。

**但它的歸因錯了，而歸因錯會導向錯的修法。** 它寫「該檔案在 baseline 並不存在，所以沒有
『舊版行號對、後來 shift』的解釋空間」。前半對（檔案是 `6f32bca` 進來的），後半錯：
這個檔案自出現以來被改過**五次**（`97c75ff`、`2c51e9c`、`e188136`、`2c81b26`、`6f32bca`），
其中四次是這批工作改的。

查了 README 寫下當時（`fbbfde9`）的實際狀態：

- `self.all_destination_paths = []` 當時**正是 74 行** —— 寫的時候完全正確
- `self.all_destination_paths = all_destination_paths` 當時**正是 510 行** —— 也完全正確
- `hub.sleep(60)` 當時在 **283**，README 寫 282 —— 只有這個當時就差一行

所以真相是：**三個之中兩個當初是對的，是後來腐化的。** 修法因此不是「下次更小心地寫行號」，
而是**引用一個還在改的檔案就用函式名與鄰近構造，不要用行號** —— 這正是它自己在 L3 的建議。
README 已按此改寫，並在原地留下這三個數字腐化的紀錄，因為那個教訓比正確的行號有價值。

## M1 誤報 —— 62 這個數字是對的

它說實際約 61。用最自然的計數法（`src/` ＋ `include/`，排除定義檔 `Utils.hpp` 本身）
得到**正好 62**；含 `Utils.hpp` 內部是 65，含 tests 是 85。它的計數法漏了 `include/` 樹。

不過它指出的**根本問題成立**：一個寫死在註解裡的精確數字無法被讀者複驗，就會腐化。
已改成同時附上產生它的 grep 指令 —— 數字會腐化，指令不會。

## L1 成立，已修

註解說「A small C program confirms it」，而那支程式只存在於 `/tmp`。**整段註解裡唯一
承重的宣稱，恰好是讀者唯一無法複驗的一件事。** 已把它提交為
`tests/manual/inet_ntoa_buffer_is_thread_local.c`（不進 CMake build，它檢查的是 libc 而非本專案），
實測在 glibc 2.39 上輸出「buffers are distinct: yes」、exit 0。同時把範圍寫進註解：
glibc 2.32 起才 thread-local，在沒有這個保證的 libc 上競爭是真的，而這個測試抓不到，
因為它測的是 `inet_ntop`。

## L2 誤報 —— 可以指出機制

它說 `what\(\):\s*\S` 會誤抓「kernel 有意記錄的 exception 訊息」。不會：pattern 要的是
**字面字串** `what():`，而 kernel 所有相關站點寫的都是 `SPDLOG_..._ERROR(..., "{}", e.what())`
—— 進 log 的是訊息**內容**，不含 `what():` 前綴。那個前綴由 C++ runtime 的 terminate handler
產生，也就是真正的 crash。唯一另一條匹配路徑是子行程崩潰的 stderr 被當命令輸出記下，
而那同樣是 crash，應該 FAIL。**不修。**

## M2、M3、M4、L3、L4、L5 成立，列為待辦

- **M2** `NDTWIN_L1_OPT_IN` 用 `grep -q` 偵測，註解裡提到這個 token 就會被當成 opt-in 宣告。
  目前只有一個檔案用，風險可控，但機制脆弱。
- **M3** `scan_kernel_dispatch` 的 regex 只在 `method == ... && target ...` 這個寫法下正確。
  它的觀察對：drift checker 本身也依賴風格，就只是把一種腐化換成另一種。
- **M4** `kernel_owns_log()` 回 2 時只看 log 檔的 mtime，剛重啟的 kernel 可能超過 120 秒沒寫入
  而被誤判 stale。它的建議（同時檢查 process 是否存在）是對的。
- **L3** 已隨 H1 一併修掉。
- **L4** `test_routing_strategy` 這個 binary 名稱包含 33 個檔案、涵蓋遠超 routing 的範圍，
  名稱有誤導性。
- **L5** `--suggest-allowlist` 把所有數字泛化成 `\d+`，兩個不同欄位會塌成同一個 pattern，
  可能誤 allowlist 掉不同來源的訊息。輸出應該加上這個警告。

## 它的查證表本身：12 條裡有 2 條是我原本無法自查的

第 6、7 條（「41 個註冊端點中 30 個有 contract」、「10 個沒有 consumer」）它逐一比對
`KERNEL_ENDPOINTS` 與 `COMPONENTS` 後**查證通過並列出那 11 個未覆蓋的端點名稱**。
這是我自己寫的數字，我會相信我寫的 —— 有第三方拿工具去數，才叫查證過。
## 逐類檢查記錄

### 1. 改動與 commit message 宣稱的意圖不符
檢查方法：對 `git log --oneline 28b8b13..HEAD -- tests/ tools/` 的每個 commit message 與其實際 diff 做抽樣比對。抽樣了以下 commit：
- `c1603d5` "Add 74 C++ tests with mutation evidence, and settle the five that proved nothing" — diff 確實新增大量 C++ test files，且 commit message 描述與內容相符。
- `e3a0ee9` "Add 145 Python tests, each with the mutation that kills it, and close a fourth false PASS" — 相符。
- `7aa0b0d` "Stop three checks reporting PASS when they checked nothing" — 相符，對應 invariants 中 `inv_flow_paths_non_empty` 之類的修正。
- `6731b56` "Make two of my tests assert what their names claim" — 相符。
- `ba97ab3` "Test Controller's sender, and nearly ship a test file that proved nothing" — 相符，`test_Controller.cpp` 的註解直接說明了此事。
- `89d38ae` "Fix five defects in the test tooling that made it misjudge" — 對 `run_layers.sh` 和 `l1_unit_tests.sh` 的多處修正，與 diff 一致。

**結論：這一類沒有發現 commit message 詐欺或夾帶無關改動。**

### 2. 註解宣稱的事實與程式碼不符
**這是本次 review 的重點類別。** 詳見上方「註解宣稱查證表」的 12 條查證。主要發現：
- H1: README 行號錯誤（282→422）
- M1: ipToString call sites 計數 62 vs 61
- 其餘 10 條查證中有 7 條「查證通過」、3 條「無法從程式碼驗證」
- **沒有發現惡意或誤導性的假宣稱。** 不準確的集中在行號和精確計數。

### 3. 治症狀不治病
檢查方法：搜尋是否有同一類 bug 在多處出現而只修了一處。觀察重點：
- `KeyedFailureLog` 的 edge-triggered log 機制（`tests/test_KeyedFailureLog.cpp` 詳細測試了 failure-reportonce-then-quiet 行為）。grep 確認生產程式碼中只有一個 `KeyedFailureLog` 實例被使用，所以不存在「同一模式多處沒修」的問題。
- `check_logs.py` 的 allowlist 機制：FORBID 規則不接受 allowlist 是正確設計。但 `what()` pattern 的潛在誤報（見 L2）沒有被處理。

**結論：未發現「只治一處、同模式他處放著不管」的情況。**

### 4. 不一致
檢查方法：比較同類操作的處理方式是否一致。
- Allowlist 格式：`warning_allowlist.txt`、`baseline_diff_allowlist.txt` 都用 `" | "` 分隔，一致。`check_logs.py` 和 `compare_baseline.py` 各自有獨立的 `load_allowlist()` 函式而非共用 — 這是因為兩個 allowlist 的欄位語意不同（一個是 LEVEL|pattern|reason，一個是 endpoint|pattern|reason），但解析邏輯重複。
- gtest skip detection: `l1_unit_tests.sh` 對 C++ tests 和 Python tests 的 skip 偵測邏輯不同（C++: 解析 `[  SKIPPED ]` 行，Python: grep `skipped` + `Ran N`）。這是因為兩個 harness 的輸出格式不同，屬於合理的差異化處理。
- Logger 初始化：`test_LoggerEnvironment.cpp` 提供 global environment，但數個 test file 仍在自己的 `SetUpTestSuite` 中重複初始化 Logger。註解說這是「document the dependency at the point where it matters」，不算不一致，而是刻意重複。

**結論：未發現導致 bug 的不一致。allowlist parser 重複是輕微的 DRY 違反，但兩個格式確實不同。**

### 5. 過度工程
- `tools/contract_test/schema.py` 是一個完整的 schema validator，包含 `Int`, `Num`, `Str`, `Bool`, `List`, `Obj`, `MapOf`, `OneOf`, `Any_` 等型別。對於「驗證 API 回應」這個目的而言是適當的抽象層級——沒有過度。
- `selftest_fixtures.py` 對 invariants 做雙向檢查（好資料要過、壞資料要報錯）——這是正確的測試紀律，不是過度工程。
- `tools/test_workflow/run_layers.sh` 有詳細的顏色輸出、banner、summary——這提高了可用性而非過度。
- **未發現為測試而扭曲生產程式碼的設計。** `test_FlowTableConcurrency.cpp` 使用了 `ConcurrentCollector`（繼承自 `FlowLinkUsageCollector` 以暴露 `handlePacket`），但這是標準的 test seam 做法，註解也解釋了原因。

**結論：未發現過度工程。**

### 6. 新引入的缺陷
- 檢查了 `kernel_owns_log()` 函式的回傳值處理：三態（0/1/2）的邏輯在 `run_logcheck` 中的 switch 是完整的。但路徑 2 的 fallback `log_written_recently()` 有一個時間窗口問題（見 M4）。
- `l1_unit_tests.sh` 對 Python test skip 的偵測：`skipped -eq ran` 檢查（line 175）捕捉「全部 skip」的情況。但如果 55 個測試中 54 個 skip、1 個 pass，`skipped` (54) ≠ `ran` (55)，所以不會觸發 FAIL——這不算 bug，因為至少有一個測試執行了。
- `check_logs.py` 的 `--to-line` 邏輯（line 195）：使用 `is not None` 而非 truthiness，正確處理了 `--to-line 0` 的邊界情況。
- `run_layers.sh` 的 `LOG_MARKED` flag（line 114）：使用獨立的 flag 而非依賴 `LOG_MARK -gt 0`，因為 mark 為 0 是合法的。設計正確。

**結論：未發現會導致 crash/資料遺失的新缺陷。M4 是一個邊界情況的可靠性疑慮。**

### 7. 效能退步
- C++ tests 都在同一個 binary，但 test execution 本身不是效能瓶頸。
- `check_logs.py` 的 crash scan（line 214）會掃整個檔案（非 window），這對大 log 檔案可能耗時。但 crash 偵測必須掃全部，這是正確的取捨。
- `selftest_fixtures.py` 的 self-test 是離線操作，秒級完成。
- **未發現明顯的效能問題。**

### 8. 半成品與死碼
- `components.py` 中的 `disable_switch` 被標記為 `KNOWN_MISSING_ENDPOINTS`，並解釋了它是 Energy-Saving-App 中的 dead code。
- `intent_translator/text` 被刻意排除在 contract test 之外（spec.py line 700-703 有記錄）。
- Group/meter endpoints（6 個）沒有 contract，READMe 記錄了這是因為它們沒有 consumer。
- `tools/contract_test/README.md:358` 記錄了 group/meter 端點在 P4 模式下會走 OVS strategy 的 bug，但說「沒有任何測試會抓到」——這是一個已知的 coverage gap。
- **沒有發現未記錄的 dead code 或半成品。** `NDTWIN_L1_OPT_IN` token 機制是完整的。

### 9. 可回退性
- 所有 C++ tests 在同一個 binary 中（`CMakeLists.txt`），所以無法獨立回退某個 test file 而不回退整個 binary。
- Python tests 是獨立檔案，可以單獨回退。
- `tools/` 下的各個腳本互相引用（`run_layers.sh` → `l1_unit_tests.sh` / `l0_build_check.sh` / contract_test tools），但變更通常是向後相容的。
- **未發現將兩件無關的事綁在同一個 commit 的情況。**

## 針對 `tests/` 與 `tools/` 範圍的專項檢查

### 假測試（fake tests）檢查
逐一審閱了測試檔案的斷言強度：
- **`test_LLMResponseParsing.cpp`**：有兩個 `...DocumentsCurrentBehaviour` 測試，刻意 pin bug 而非意圖。這是**故意的**，並有完整文件說明。不算 fake test。
- **`test_IpToString.cpp`**：concurrency test 的作者誠實記錄了它「passes against inet_ntoa unchanged」——測試本身有價值（驗證正確性），但不是 regression test for race condition。這已在檔案頭說清楚。
- **`test_SyntheticPower.cpp`**：註解記錄了一個真正的 fake test 被修復的過程——早期版本只要求十個數值「distinct」，而 `std::hash<uint64_t>{}(dpid)` 在 libstdc++ 上是 identity function，所以回傳 30001-30010（都是 30.0W），測試通過了但功能無用。這個 fake test **已經被修復**。
- **`test_Controller.cpp`**：註解說第一版只 assert dispatch 但不 assert log output，所以把 bug 加回去後測試仍通過。**已修復**，現在用 `CapturingSink` 驗證 log 內容。
- **`tests/python/test_contract_spec.py`**：驗證 invariants 的雙向行為（好資料要過、壞資料要報錯），這正是避免 fake test 的做法。

**結論：未發現現存的假測試。** 程式碼中有多處記錄了「曾經有假測試、已被修復」的歷史，這反而增加了可信度。

### Skipped tests 與工具鏈處理
- **`l1_unit_tests.sh`**：正確處理了 gtest SKIPPED（line 118-122）和 Python unittest skipped（line 175-201）。「全部 skip」會被報 FAIL，除非有 `NDTWIN_L1_OPT_IN`。
- **`test_p4_client.py`**：唯一使用 `NDTWIN_L1_OPT_IN` 的檔案。它的 skip 是設計（需要 live bmv2），不是 bug。
- **shell tests**（`test_wait_for_port.sh`）：使用自訂的 SKIP 標記（`SKIP:` 行），且 `l1_unit_tests.sh` 能正確偵測（line 262）。
- **ctest 的 blind spot**：`l1_unit_tests.sh` 同時跑 ctest 和 direct execution，這正是為了補 ctest 看不到 cross-test interference 的盲區。設計正確。

**結論：工具鏈對 skipped tests 的處理是可靠的。** 沒有發現「skip 了但看起來像 pass」的情況。

### 工具鏈的判定是否可信
- **`check_logs.py`**：
  - **不會永遠 PASS**：未 allowlist 的 WARNING/ERROR 會 FAIL。FORBID patterns 永遠 FAIL（即使 allowlist 也不能放行）。Crash 偵測掃全檔案。
  - **不會對錯誤的東西 FAIL**：`--to-line` 機制正確排除 L2 自爆的錯誤。Crash detection 不受 window 限制。
  - 一個潛在問題：`what()` pattern 可能誤報（見 L2）。
- **`compare_baseline.py`**：
  - **不會永遠 PASS**：任何不在 allowlist 中的 shape/coverage/behaviour 差異都會 FAIL。
  - 對 empty list 的處理避免了雜訊轟炸（見 README:287-293）。
- **`run_layers.sh`**：
  - `kernel_reachable()` 檢查避免在 kernel 不在時跑 L2/L3。
  - `mark_log()` 機制避免 L2 自爆污染 log check。
  - `kernel_owns_log()` 三態邏輯比單純的「log 檔案存在」強。
- **`l1_unit_tests.sh`**：
  - 交叉比對 ctest case count 與 gtest test count（line 286-298）。
  - 對 build warnings 有提示（line 73-75）。
  - 對 Python test 的 skip 偵測考慮了三種不同情境（opt-in、缺 dependency、真正的 broken skip）。

**結論：工具鏈判定邏輯基本上是可信的。** M4 和 L2 是邊界情況的潛在問題，但不至於讓整個判定失效。

### 測試與生產程式碼的耦合
- **Test seam via inheritance**：多個 test file 使用「繼承 production class 來暴露 protected method」的模式（`LivenessProbe`, `PowerProbe`, `RelayReader`, `ConcurrentCollector`）。這是 C++ 測試的常見做法，沒有為了測試而把 method 改成 public 或加入 friend declaration。
- **`ControllerTest`** 使用 `ScriptedManager`（mock）來驗證 dispatch。Mock 只 override 三個 virtual method，不干擾 production path。
- **`CapturingSink`**：繼承 `spdlog::sinks::base_sink` 來 capture log output。這是合理的測試工具，不影響 production code。
- **`LoggerEnvironment`**：global test environment 在 main() 之前初始化 logger。這是一個合理的全域 fixture。

**結論：測試與生產程式碼的耦合是合理的。** 沒有發現為了測試而在 production code 中開的後門。

## 無法判定

1. **`run_layers.sh:97-98` 的實測數字「47 problem line(s) across 13 distinct message(s)」**：這是操作者在特定環境下的觀察記錄，無法從程式碼驗證。機制邏輯（重複跑 contract test 對同一 kernel process 導致前一輪的探測錯誤出現在第二輪的 log window 之後）是對的，但具體數字只是當時的 snapshop。

2. **`test_IpToString.cpp:10-11` 的 glibc 2.39 thread-local 宣稱**：需要執行緒間競爭的實證才能確認。glibc 社群文件和 source code 確認了這個變更，但無法從本 repo 內的程式碼驗證。

3. **`baseline_diff_allowlist.txt:100` 的「the only observed difference is dl_dst」**：需要實際執行 OVS vs P4 comparison 來確認當前版本是否仍然只有這個 field 不同。allowlist 本身記錄了這可能因 Phase 進展而改變。

4. **`tools/test_workflow/README.md` 中的收斂時間宣稱（「link discovery 實測約 2 秒」、「至少 60 秒」）**：這些是在特定硬體和拓撲下的實測結果。無法從程式碼驗證數值本身，但機制（輪詢而非固定 sleep）的邏輯是正確的。

5. **`components.py` 的 `KERNEL_ENDPOINTS` 是否與 `HttpSession.cpp` 完全同步**：未執行 `--check-drift`，無法判定。這是設計上有 `check_dispatch_drift()` 函式來偵測的，所以 drift 應該在 CI 中被抓到——前提是 CI 有跑 `--check-drift`。

