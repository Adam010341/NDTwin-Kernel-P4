# 測試流程腳本

實作 [doc/testing_workflow.md](../../doc/testing_workflow.md) 的 L0、L1 兩層，以及啟動編排與頂層驅動。
L2 / L3 / L4 的 Python 工具在 [../contract_test/](../contract_test/)。

---

## 一句話

```bash
./run_layers.sh selftest     # 完全離線，秒級。改完程式碼先跑這個
./run_layers.sh quick        # L0 建置 + L1 單元測試，約 2 分鐘
./run_layers.sh api p4       # L2 + L3 + log 檢查（需要 stack 在跑）
```

全部都是**成功才 exit 0**，可以直接接 CI。

---

## 檔案

| 檔案 | 層 | 用途 |
|---|---|---|
| `components.env` | — | 路徑、conda env、port、拓撲檔的單一資料來源 |
| `l0_build_check.sh` | L0 | 所有元件是否還建置得起來 |
| `l1_unit_tests.sh` | L1 | kernel 單元測試（**兩種方式**都跑）＋ P4 proxy 的 Python 測試 |
| `stack.sh` | — | 按正確順序啟動／關閉，並等待拓撲收斂 |
| `run_layers.sh` | 全部 | 頂層驅動，把各層組合起來 |

---

## L0：建置檢查

```bash
./l0_build_check.sh              # 全部 10 個目標
./l0_build_check.sh kernel p4    # 只跑指定目標
./l0_build_check.sh --list
```

涵蓋：kernel（CMake）、P4 pipeline（`p4c-bm2-ss`）、Energy-Saving-App、Simulation-Platform-Manager、Visualizer（Maven）、Web-GUI、三個 Python 元件、契約測試工具本身。

三種結果：
- **PASS** — 建置乾淨
- **FAIL** — 建置錯誤，會直接印出 log 最後 25 行（錯誤幾乎都在那裡）
- **SKIP** — 這台機器沒有該工具鏈。**不算失敗**，但會列出來讓你知道涵蓋範圍縮小了

kernel 開了 `-Werror`，所以任何新 warning 在這一層就已經是失敗。

**Web-GUI 的處理**：這台機器沒有 node/pnpm，官方路徑是 Docker。預設只驗證 compose 檔（快），要完整建 image 就設 `L0_WEBGUI_DOCKER_BUILD=1`。

**Python 元件用 `ast.parse` 而不是 `py_compile`**：後者會把 bytecode 寫在原始碼旁邊，而這些目錄裡有 sudo 跑 Mininet 留下的 root-owned `__pycache__`，會讓檢查因為跟程式碼無關的原因失敗。兩者涵蓋範圍相同（都只抓 SyntaxError），但 parse 不寫檔。

---

## L1：kernel 單元測試

```bash
./l1_unit_tests.sh              # 建置後執行
./l1_unit_tests.sh --no-build   # 假設 build 是最新的
```

**為什麼要用兩種方式跑**，這是這支腳本存在的唯一理由：

`ctest` 透過 `gtest_discover_tests` 把每個 `TEST_F` 放在**獨立 process**執行。所以 `SetUpTestSuite` 失敗只會影響那一個 process，其他照樣通過 —— `ctest` 會顯示全綠。

這不是理論。我實測把 `Logger::init` 的 idempotency 修正拿掉後：

```
ctest            → 100% tests passed, 0 tests failed out of 12   ← 謊言
直接執行         → FAIL (exit 1, ran=12 passed=10 skipped=2)      ← 真相
                   C++ exception "logger with name 'netdt' already exists"
                   thrown in SetUpTestSuite()
```

所以這支腳本會：
1. 跑 `ctest`
2. **另外**直接執行每個測試 binary
3. 檢查「實際執行數」是否等於「發現的測試數」—— **SKIPPED 的測試不算通過**
4. 交叉比對 ctest 註冊的案例數與 gtest 的測試數（不一致代表有測試沒被註冊）

---

## stack.sh：啟動編排

元件有嚴格的依賴順序，順序錯了會測出假的失敗：

```
1. 控制層    Ryu (OVS 模式)  或  P4 proxy agent (P4 模式)
2. 資料層    Mininet 拓撲
3. Kernel    ndtwin_kernel          ← 這裡到下一步必須等收斂
4. 唯讀工具  Visualizer / NSR / Web-GUI
5. 產流量    NTG
6. 應用程式  Energy-Saving / Traffic-Engineering   ← 會改動網路，最後才開
```

```bash
./stack.sh up p4      # 控制層 → 提示你手動開 Mininet → kernel
./stack.sh wait       # 阻塞直到收斂
./stack.sh status
./stack.sh down
./stack.sh logs
```

### `wait` 是最重要的部分

它輪詢 `get_graph_data`，直到**拓撲檔裡的每一台 switch 都同時 up 且 enabled**。期望值從拓撲檔推導，不是寫死的。

```
waiting for topology convergence (expect 10 switches up+enabled, timeout 90s)
  switches=10 up=4 enabled=0 edges=0
  switches=10 up=10 enabled=10 edges=40
converged after 12s
```

很多「看起來壞掉」其實只是還沒收斂。有了這個就不會再誤判。

逾時的時候它會給出方向：

```
did not converge within 90s (last: 10 4 0 0)
in P4 mode this is expected until Phase 6: nothing calls
/ndt/inform_switch_entered, so is_enabled stays false.
```

### Mininet 是手動的

Mininet 需要 root，而且會停在自己的 CLI，沒辦法乾淨地背景化。所以 `up` 會停下來請你在另一個終端機執行，等你按 Enter 再繼續。這是刻意的 —— 硬要自動化只會換成更難除錯的問題。

關閉時 Mininet 也要自己清：`sudo mn -c`。

### kernel 的 stdin 提問

`main.cpp` 目前還是用互動式 `std::cin` 問模式／拓撲／AI，所以 `stack.sh` 用 `printf '1\n2\n2\n'` 餵答案。這很脆弱 —— 計畫 Phase 1 會改成 CLI 參數（`--mode`／`--topology`／`--no-ai`），到時候這段可以簡化。

---

## run_layers.sh：頂層驅動

| 模式 | 跑什麼 | 需要 Mininet？ |
|---|---|---|
| `selftest` | schema self-test、依賴地圖 | ❌ |
| `quick` | L0 + L1 | ❌ |
| `api {ovs\|p4}` | L2 + L3 + log 檢查 | ✅ |
| `baseline {ovs\|p4}` | 擷取回應供 L4 比對 | ✅ |
| `compare` | L4 差異比對 | ❌（用已擷取的檔案） |
| `full {ovs\|p4}` | 全部，跑不了的自動跳過 | 視情況 |

選項：`--traffic`（額外要求 flow／path／速率）、`--mutations`（含寫入端點）。

### 典型 P4 開發流程

```bash
./stack.sh up p4 && ./stack.sh wait
./run_layers.sh api p4 --traffic
./stack.sh down
```

### 建立 L4 baseline（在健康的 OVS 環境做一次）

```bash
./stack.sh up ovs && ./stack.sh wait
./run_layers.sh baseline ovs --traffic
./stack.sh down
```

之後每次 P4 有進展：

```bash
./stack.sh up p4 && ./stack.sh wait
./run_layers.sh baseline p4 --traffic
./run_layers.sh compare
```

`compare` 會把 P4 跟 OVS 的差異分成三類：允許的 P4 限制（寫在 allowlist）、數值容忍範圍內、**其他就是 bug**。

---

## 產出位置

所有 log、pidfile、baseline 都在 `$RUN_DIR`（預設 `/tmp/ndtwin_test_run`），不會污染 repo。

```
/tmp/ndtwin_test_run/
├── logs/       建置 log、各元件執行 log、ctest 輸出
├── pids/       stack.sh 的 pidfile
├── baseline/   ovs/ 與 p4/ 的 API 回應擷取
└── mode        目前 stack 的模式與拓撲
```

要換位置：`RUN_DIR=/somewhere ./run_layers.sh quick`

---

## 覆寫設定

`components.env` 裡每個變數都可以從環境覆寫：

```bash
NDT_URL=http://192.168.1.5:8000 ./run_layers.sh api p4
TOPO_P4=/path/to/my_topo.json ./stack.sh up p4
```

---

## 已知限制

- **Mininet 手動**：見上面說明。
- **kernel 靠 stdin 餵參數**：Phase 1 加了 CLI 參數之後要更新 `stack.sh`。
- **L0 的 Python 檢查只驗語法**：這些腳本的執行期依賴太重（Mininet、nornir、活的 kernel），沒辦法在這一層 import。
- **步驟 4-6 沒有腳本化**：Visualizer 需要顯示器、Web-GUI 是 Docker、NTG 要在 Mininet 裡跑，各測試情境需求不同，所以留給人工或個別情境腳本。
- **`components.env` 的路徑是這台機器的實際配置**，換機器要調整。
