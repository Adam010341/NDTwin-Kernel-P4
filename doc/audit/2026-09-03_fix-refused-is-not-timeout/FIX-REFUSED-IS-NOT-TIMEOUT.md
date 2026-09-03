# FIX：連線被拒不是逾時（FINDINGS #38）

分支 `fix/refused-is-not-timeout`，base `trunk` = `92a79392`。
[Co-developed with claude code -- Adam]

---

## 1. 這句話是誰印的

FINDINGS-ALL 第 38 列 → round2 `D12` → `round2-power-paths/05_sim502_claims_30s_timeout.log`。
**是 kernel 的 C++，不是 python client，也不是 WebGUI。**

- 印出的人：`src/ndt_core/application_management/SimulationRequestManager.cpp`
  的 `requestSimulation()`，舊版第 202-210 行。
- 傳到外面的路：`HttpSession::handleReceivedSimulationCase`（`src/ndt_core/http/HttpSession.cpp:1512`
  起，502 那一段在 `:1554-1570`）把 `Dispatch::failureReason` 原字串放進 502 的 `details` 欄。
  round2 抓到的就是這個欄位。
- 觸發者：Energy-Saving-App 打 `POST /ndt/received_a_simulation_case`，
  simulator server（`:9000`）沒開。

**為什麼會講錯。** curl 的 `-w %{http_code}` 在「完全沒有 HTTP 回應」的時候一律印 `000`，
所以 `curl.httpStatus == 0` 是**「被拒 ∪ 被 reset ∪ DNS 查不到 ∪ 真的逾時」的聯集**，
而那個分支把訊息寫死成逾時。真正能分開它們的是 **curl 自己的 exit code**——它一直都在
`utils::CommandOutcome::status` 裡，`execArgv` 早就帶回來了，**沒有人讀**。

我在本機量了這件事（`raw/f38_curl_cases_measured.log`，三種情境各 5 次，全部走 loopback）：

| 情境（本機 socket） | curl exit | 符號 | 實測耗時 | `%{http_code}` |
|---|---|---|---|---|
| 關掉的 port（被拒） | **7** | `CURLE_COULDNT_CONNECT` | 0.006–0.007s | `000` |
| listen 但不 accept（掛住） | **28** | `CURLE_OPERATION_TIMEDOUT` | 2.008–2.009s（= deadline） | `000` |
| 收了連線再拆掉（reset） | **56** | `CURLE_RECV_ERROR` | 0.151–0.152s | `000` |

**三種的 `http_code` 一模一樣，exit code 三種都不同。** 這就是修法的全部根據。

---

## 2. before / after 逐字

**before**（`SimulationRequestManager.cpp`，修改前）：

```cpp
if (curl.httpStatus == 0)
{
    dispatch.failureReason = "no response from the simulator server at " + SIM_SERVER_URL +
                             " within " + std::to_string(REQUEST_TIMEOUT_SECONDS) + "s";
```

round2 實際收到的 502 body（`05_` 五次全同，總耗時 0.005956–0.009033s）：

```json
{"details":"no response from the simulator server at http://127.0.0.1:9000/submit within 30s",
 "error":"Simulation case was not accepted","status":"error"}
```

**after**：改成讀 curl 的 exit code 分類，並且**自己量時間**。同一個 502，現在會是
（下面是紅→綠那兩次 gtest 實際印出來的字串，port 是 kernel 挑的 ephemeral port）：

| 情境 | 修改前（`raw/f38_gtest_RED.log`） | 修改後（`raw/f38_gtest_GREEN.log`） |
|---|---|---|
| 被拒 | `no response from the simulator server at http://127.0.0.1:54851/submit within 2s` | `connection refused after 0.012s: nothing accepted a connection at http://127.0.0.1:39993/submit (curl exit 7)` |
| 掛住 | `no response from the simulator server at http://127.0.0.1:48215/submit within 2s` | `timed out after 2.015s: no reply from http://127.0.0.1:59147/submit within the 2s deadline (curl exit 28)` |
| reset | `no response from the simulator server at http://127.0.0.1:59477/submit within 2s` | `connection reset after 0.156s by http://127.0.0.1:50859/submit (curl exit 56)` |

（兩欄都是**跑出來抄下來的**，不是照著程式碼寫的；port 每次不同是因為測試用 ephemeral port。
 修改後那一欄由測試自己印——`failureReasonFor()` 每次都印 `502 details would read: …`，
 通過也印：一份講訊息的測試如果從不顯示訊息，讀的人就只剩斷言、看不到到底講了什麼。）

（上表 `2s` 是測試把 deadline 調短的值；production 仍是 30s，沒有改。
 修改前那一欄三句話**在去掉 URL 之後完全一樣**——這正是 D12 的核心。）

新的分類函式 `describeCurlNoReply()`（file-local，`SimulationRequestManager.cpp` 匿名 namespace）
只認 curl 手冊上這個 kernel 真的碰得到的碼：6 / 7 / 28 / 35 / 52 / 55 / 56，
**其餘一律落到 `utils::describeCommandStatus` 印 exit code，不猜**——猜成因就是這條 finding 本身。

**exit code 沒有改。** 被拒仍然回 502（`sent=true, answered=false`），這是對的：
請求確實離開了這台機器、只是沒有人收；`sent=false` 那條路（curl 根本沒跑起來）仍然是 500。
兩者的分界是 B-2b 訂的，跟 #38 無關，我沒有動它。

### 一個為了讓它可測而做的改動

`REQUEST_TIMEOUT_SECONDS` 從「編譯期常數」變成 constructor 的**第三個參數，預設值就是它**
（`SimulationRequestManager(appManager, url, requestTimeoutSeconds = REQUEST_TIMEOUT_SECONDS)`）。
production 唯一的建構點 `src/main.cpp:416` 傳兩個參數，行為**逐位元不變**。

會做這個改動的理由是：deadline 寫死 30 的時候，「真的逾時」那條分支要測就得等 30 秒，
所以**它從來沒有被測過**——而沒被測過的分支，正是一句訊息可以一直描述一場沒發生過的等待的地方。
現在掛住那個 case 花 2 秒。

---

## 3. 紅 → 綠

新測試 `tests/test_RefusedIsNotTimeout.cpp`，5 個 case，**只用本機 socket**：
關掉的 port（被拒）對 listen 但不 accept 的 socket（掛住），外加一個收了連線再拆掉的（reset）。
沒有 mock：分類是活在 curl 的 exit code 裡的，假的 curl 得自己編一個 exit code 出來，
那等於先假設答案。

**RED**（`raw/f38_gtest_RED.log`，binary sha256 `9aee6220…`）：**5 個全紅**。
最有價值的是它的 stderr——`execArgv` 自己會印失敗的 exit code：

```
Command failed (exit code 7):  curl ... http://127.0.0.1:54851/submit    ← 被拒
Command failed (exit code 28): curl ... http://127.0.0.1:48215/submit    ← 掛住
Command failed (exit code 56): curl ... http://127.0.0.1:59477/submit    ← reset
```

**同一次執行裡，區分三者的資訊就印在旁邊，而三句訊息一字不差。**

```
[  FAILED  ] RefusedIsNotTimeoutTest.ARefusalIsNotDescribedAsATimeout
[  FAILED  ] RefusedIsNotTimeoutTest.AHangIsStillDescribedAsATimeout
[  FAILED  ] RefusedIsNotTimeoutTest.TheTwoFailuresDoNotProduceTheSameSentence
[  FAILED  ] RefusedIsNotTimeoutTest.TheRefusalCarriesTheDurationThatWasActuallyMeasured
[  FAILED  ] RefusedIsNotTimeoutTest.ADroppedConnectionIsNeitherOfTheTwo
```

**GREEN**（`raw/f38_gtest_GREEN.log`）：**5 個全綠**（`5 tests from 1 test suite ran. [  PASSED  ] 5 tests.`），binary sha256 `f9bf5557…`。stderr 的 `Command failed (exit code 7/28/56)` 三行還在——curl 的分類沒有變，變的是我們有沒有把它講出來。

測試**不釘句子、只釘分類**：被拒不可以出現任何逾時說法、真逾時必須說 timed out、
兩者不可以再收斂成同一句、訊息裡的秒數必須是這個 process 量到的（< 1s）、
reset 不可以被講成被拒。改字可以，重新混在一起不行——這一點由閘門的 W2/W3 證明。

---

## 4. 變異閘門

`tests/shell/mutate_refused_is_not_timeout.sh`（照 `mutate_poll_does_not_resurrect.sh` 的 C++ 形狀寫：
自己守 baseline、`cp -p` + EXIT trap 還原、結束時比對 sha256 與 test binary sha、
不編譯的 mutant 算存活、不用 `pkill`／`pgrep`）。

**`7 mutations, 0 survived` / `3 widenings, 0 wrongly caught`**（`raw/f38_gate.log`）。
還原後 `all 1 file(s) byte-identical to the pre-run snapshot`、`suite green again after restore`、
`test binary sha unchanged: f9bf55574c43473e`。

🔴 **第一次跑不是這個數字，這裡要講清楚。** 第一次是 `7 mutations, 1 survived`（rc=1），
存活的是 M1——它把舊訊息放回去，於是 `elapsedSeconds` 變成沒人用的變數，
而這棵樹是 `-Wall -Wextra -Werror`，**mutant 編不過**。閘門把「編不過」記成**存活**是對的：
測試根本沒跑，證明不了任何事。M1 補上 `(void)elapsedSeconds;` 之後重跑才是上面那個數字。
第一次那份 log 被重跑覆蓋掉了，但它的結尾留在 `raw/f38_run_all.log` 裡。

方向一（把缺陷放回去）：M1 原字串、M2 再次丟掉 curl exit code、M3 被拒走進逾時分支、
M6 reset 被講成被拒、M7 秒數換回 deadline。
方向二（放寬過頭）：**M4 把逾時字眼整個刪掉**（只看方向一會全綠，卻比原缺陷更糟——
唯一真的等滿 deadline 的請求從此不說了）、M5 反過來什麼都叫「被拒」。
控制組：W1 註解、**W2 把「被拒」那句改寫**、**W3 把「逾時」那句改寫**——兩句都必須存活，
否則下一個想改進措辭的人得先去改測試。

錨點：`tests/shell/check_gate_anchors.py` 對這支閘門回 **`ok(7)`**（7 個錨點全部解析得到、
每個各出現 1 次）。這是 FINDINGS #28 的教訓——**新出廠的儀器預設是沒被檢查過的**，
所以照它讀得懂的寫法寫。（同一次掃描裡 trunk 上另有數支舊閘門回 `no anchors extracted`／
`could not resolve`，那是既有狀態，不是本分支造成的，我也沒有動它們。）

---

## 5. 測試套件

| 套件 | 結果 |
|---|---|
| `test_routing_strategy`（gtest 全部） | **970 tests / 125 test suites 全綠**（113.4s） |
| `ctest` | **970/970 passed, 0 failed**（133.7s） |
| `tests/python`（29 模組，逐模組） | 29/29 綠（見下面那條但書） |
| `p4_proxy/tests`（25 模組，逐模組） | 25/25 綠，604 cases、3 skip |

**`tests/python` 的但書，因為它不是一句「全綠」可以誠實蓋掉的。** 一共有 29 個模組，
但**沒有單一直譯器能把 29 個都跑起來**：

- `l1_unit_tests.sh` 會挑到的 `~/miniconda3/envs/ryu-env/bin/python`（**3.8.20**，有 networkx＋ryu）
  跑出 **25 綠 / 4 紅**。那 4 個紅全是 Python 版本問題，跟本分支無關：
  `test_l3_dispatch_drift`（`str.removeprefix`，3.9+）、`test_ovs4_sflow`（`ast.unparse`，3.9+）、
  `test_chaos_c07_control` 與 `test_chaos_invariants_method`（它們 import 的
  `doc/audit/2026-08-28_chaos-harness/harness/actions.py:143` 用了多行 f-string，3.12+ 才能 parse）。
- 系統的 `python3`（**3.13.13**）把那 4 個全跑綠，但沒有 networkx／ryu，所以
  `test_find_host_by_ip`／`test_topology_read_timeouts`／`test_topology_worker_coalescing`／
  `test_walk_instrumentation` 變成**整支 skip**——那不是綠，是沒跑。
- `test_sflow_stats_endpoint` 依指示用 `p4_proxy/venv/bin/python`，5 cases 綠。

**每一個模組都在「它跑得起來的那個直譯器」下面是綠的，而且沒有一個模組是兩邊都紅的。**
這是 trunk 既有的狀態（本分支一個 python 檔都沒動），我沒有去修它，也不打算把它報成
「29/29 全綠」而不附這段。

原始 tally 在 `raw/f38_tests_python_*.tsv`、`raw/f38_p4_proxy_tests.tsv`。
**本分支沒有動任何一個 python 檔**（`git diff --name-only trunk` 只有三個 C++／CMake 檔）。

---

## 6. `git merge-tree --write-tree trunk fix/refused-is-not-timeout`

```
$ git merge-tree --write-tree trunk fix/refused-is-not-timeout   # branch = bd37683e, trunk = dae65b85
ed0b8d38e3f1e14262b442eadd649ad2e6426b66
rc=0
```

**rc 0、只吐一個 tree oid、沒有 conflict 區段 ⇒ 跟 `trunk` 乾淨合得起來。**

上面記的是 **code commit `bd37683e`** 的結果。加上本文件之後在分支頂端再打一次**也是 rc 0**，
只是 tree oid 不同（tree 裡多了這個檔）——**那個 oid 我不寫進來**：寫進來這個動作本身
就會改掉這個檔、改掉 tree、改掉 oid。要驗的人自己打一次；rc 才是這一節的宣稱。

### 一個會嚇到人的數字，先解釋掉

`git diff --stat trunk..fix/refused-is-not-timeout` 會印 **183 個檔案、-43829 行**。
**那不是我的 diff。** 我開分支時 `trunk` 是 `92a79392`，之後 trunk 自己往前走了 **35 個 commit**；
`trunk..branch` 是「從現在的 trunk 走到我的分支」，所以把 trunk 這 35 個 commit 的內容
全部算成刪除。merge-base 仍然是 `92a79392`（沒有 rebase、沒有 merge）。

**我實際帶的東西是 `git diff --stat 92a79392..fix/refused-is-not-timeout`：6 個檔、+1212 −25。**

```
 doc/audit/2026-09-03_fix-refused-is-not-timeout/FIX-REFUSED-IS-NOT-TIMEOUT.md | 238 +
 include/ndt_core/application_management/SimulationRequestManager.hpp          |  46 +-
 src/ndt_core/application_management/SimulationRequestManager.cpp              | 120 +-
 tests/CMakeLists.txt                                                          |   4 +
 tests/shell/mutate_refused_is_not_timeout.sh                                  | 493 +
 tests/test_RefusedIsNotTimeout.cpp                                            | 336 +
```

沒有 build 產物、沒有 log、沒有投稿包、沒有別人的檔案。

要注意 merge-tree **只回答「跟 trunk 合不合得起來」**，不回答跟今晚其他分支合起來會怎樣：
`HttpRoutingStrategyBase.cpp` 我沒動（見第 7 節第 1 點），所以那邊如果有人同時在修同一句措辭，
衝突會出現在他們跟我之間，不會出現在這一條裡。

---

## 7. 我**沒有**做的事

1. **`HttpRoutingStrategyBase.cpp` 沒改。** 同一句 `within Ns` 的措辭還在兩個地方：
   `:164`（`post()`）與 `:264`（`get()`），`REQUEST_TIMEOUT_SECONDS = 5`。
   它們是同一個形狀（`httpStatus == 0` 當成逾時，exit code 丟掉），但
   #38 的證據只指向 simulator 這條路，而我今晚沒有替那兩條寫 socket 測試。
   **不能說它們修好了。**
2. **`describeCurlNoReply` 沒有放進 `utils::`。** 放進 `Utils.hpp` 會讓「改一行分類邏輯」
   變成全樹重編（大部分 TU 都 include 它），閘門每個 mutation 都要付那個代價。
   等上面第 1 點要修的時候再往上提，那時它有兩個以上的呼叫端，也有測試撐著。
3. **`onSimulationResult` 那個 log 沒有測試。** 它在 detached thread 上、200 已經送出去了，
   沒有呼叫端可以觀察。我把它改成同一個分類函式（同一個 commit），但那是**讀碼**，
   不是跑出來的證據；被測到的是分類函式本身，走的是 `requestSimulation` 那條路。
4. **DNS（curl exit 6）沒有測。** 要測就得打 name server，不是本機 socket，
   所以閘門也**沒有**變異 `case 6`——沒有測試護著的分支我不假裝它被護著。
5. **沒有跑 lab、沒有 claim、沒有碰實體 testbed。** 全程只有 loopback socket。
6. **沒有 push。** 分支留在本地。
7. **沒有動 `doc/KNOWN-ISSUES.md`、FINDINGS-ALL 或任何別人的 worktree。**

---

## 附：檔案清單

| 檔案 | 動作 |
|---|---|
| `src/ndt_core/application_management/SimulationRequestManager.cpp` | 分類函式＋量測＋兩個呼叫端 |
| `include/ndt_core/application_management/SimulationRequestManager.hpp` | deadline 變成可注入的參數（預設不變） |
| `tests/test_RefusedIsNotTimeout.cpp` | 新增，5 個 case |
| `tests/CMakeLists.txt` | 掛進 `test_routing_strategy` |
| `tests/shell/mutate_refused_is_not_timeout.sh` | 新增閘門 |
| 本文件 | 新增 |

raw（logs、before/after、時間量測）在 `audit-raw` 分支的
`doc/audit/2026-09-03_fix-refused-is-not-timeout/raw/`，commit message 開頭
`FIX-REFUSED-IS-NOT-TIMEOUT raw:`。**這個目錄底下只留這一份 .md。**
