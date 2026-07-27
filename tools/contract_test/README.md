# L2 契約測試與 log 檢查

實作 [doc/testing_workflow.md](../../doc/testing_workflow.md) 的 **L2 層**：把「打開元件看看有沒有 error」變成機器判斷的 pass/fail。

不需要安裝任何套件，只要 `python3`。

---

## 為什麼需要這個

Workspace 裡 7 個 tool/app 跟 kernel 之間**唯一**的介面就是 `/ndt/*` HTTP API。所以 kernel 的 API 只要形狀變了，所有元件會同時壞掉，但每個壞的樣子都不一樣，很難從單一元件的畫面看出來。

在一個地方把契約驗過，等於一次驗證了所有元件的地基。

---

## 兩支工具

| 工具 | 檢查什麼 |
|---|---|
| `run_contract_test.py` | kernel 的 API 回應：結構、語意不變量、錯誤路徑 |
| `check_logs.py` | kernel 的 log：未預期的 warning/error |

---

## 快速開始

```bash
cd tools/contract_test

# 1. 先確認測試腳本本身是對的（不需要 kernel 在跑）
./run_contract_test.py --self-test

# 2. kernel 跑起來之後，做唯讀檢查（不會改到網路狀態）
./run_contract_test.py --topology ../../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json

# 3. 開始產生流量後，加上 telemetry 相關檢查
./run_contract_test.py --topology <拓撲檔> --with-traffic

# 4. 檢查 log
./check_logs.py /path/to/kernel.log
```

兩支都是**成功才回傳 exit code 0**，可以直接接進 CI。

---

## run_contract_test.py

### 三種檢查

**1. 結構** — 回應是合法 JSON、欄位存在、型別正確。失敗訊息會指到確切位置：

```
nodes[3].is_up: expected bool, got str ('true')
```

**2. 語意不變量** — 這是把「看一眼」變成「可判定」的關鍵。期望值**從拓撲檔推導**，不是寫死的，所以換拓撲會自動適應（OVS 10 switch/128 host、P4 10 switch/4 host 都能用同一套）：

```
switch(es) not enabled (not connected to a controller): s3(dpid=3)
  -- in P4 mode this usually means the proxy never called /ndt/inform_switch_entered

3 flow(s) with an empty path: 10.0.0.1->10.0.0.4
  -- the Classifier has no flow-table data (check /stats/flow/<dpid>)
```

**3. 錯誤路徑** — 餵壞的輸入，要回合理的 4xx，不能回 500 也不能假裝成功。這類檢查會抓到：未知 dpid 被安靜轉給 Ryu、非數字 dpid 造成 500、lock 沒有正確回 423/412。

### 重要參數

| 參數 | 說明 |
|---|---|
| `--topology <檔案>` | **必填**。kernel 啟動時用的拓撲檔，不變量的期望值由它推導 |
| `--with-traffic` | 額外要求「有 flow、path 非空、速率非零」。沒有流量時不要加，否則會誤報 |
| `--allow-mutations` | 才會執行會改動網路的端點（裝規則、改電源、改名稱）。**預設不執行** |
| `--url` | kernel 位址，預設 `http://localhost:8000`（或環境變數 `NDT_API_URL`） |
| `--save-json <目錄>` | 把每個回應存檔。這就是 L4 做 OVS/P4 差異比對的 baseline |
| `--only <名稱>` | 只跑指定檢查，除錯時用。可重複 |
| `--self-test` | 用 `doc/ndt_api.md` 的範例驗證 schema 本身，不需要 kernel |

### 為什麼預設不跑 mutation

`--allow-mutations` 會真的下流量規則、改電源狀態。對正在跑的系統來說這是破壞性的，所以必須明確開啟。唯讀檢查可以隨時對生產環境跑。

（例外：lock 相關檢查會執行，但它用自己專屬的 lock type `ndt_contract_test_lock`，不會干擾正在跑的 app。）

### --self-test 是什麼

它拿 `doc/ndt_api.md` 裡的實際回應範例去驗證 schema。**如果 schema 連文件裡的範例都不接受，那是 schema 寫錯了** — 在這裡發現比對著真系統 debug 便宜太多。

它同時檢查每個不變量的**兩個方向**：好資料要安靜、壞資料要噴錯。這樣才知道檢查不是「永遠都過」的假綠燈。

目前 47 個 self-test 檢查。

---

## check_logs.py

### 核心概念

沒有 allowlist 的話，「檢查 log 有沒有 warning」在 warning 超過幾個之後就失效了 — 真正新出現的問題會被你已經決定接受的那些淹沒。

有了 allowlist，**沒列在裡面的就是失敗**，所以 regression 藏不住。

### 判定規則

| 情況 | 結果 |
|---|---|
| `error` / `critical` 等級 | **失敗**，除非明確列在 allowlist |
| `warning` 等級 | **失敗**，除非列在 allowlist |
| 符合 `FORBID` 樣式 | **失敗，不管什麼等級**（包含 info/debug） |
| allowlist 有列但這次沒對到 | 提示（方便清理過期項目） |

### FORBID 為什麼存在

有些訊息的嚴重性跟它被記錄的等級不符。例如 `Unsupported SFlow Version` 是用 `WARN` 記的，但它代表**所有 telemetry 都被丟掉了** — 整個數位孿生的資料全部是空的。

FORBID 讓這種訊息不管記在哪個等級都會讓測試失敗。

而且 FORBID 的違規**不會**被 `--suggest-allowlist` 建議加進白名單 — 那種訊息要修，不是要放行。

### allowlist 格式

`warning_allowlist.txt`，三欄用 `|` 分隔：

```
LEVEL | python regex | 為什麼可以接受
```

比對的是**訊息本文**（時間戳、等級、檔名行號、函式名都會先被剝掉，ANSI 色碼也會清掉），所以不用自己處理前綴。

### 導入到現有的 log

現有的 log 大概本來就有一堆 warning。用這個產生起始清單：

```bash
./check_logs.py kernel.log --suggest-allowlist
```

它會輸出可以直接貼的 allowlist 行（數字會自動泛化成 `\d+`，一條規則涵蓋多個實例）。

**但不要無腦貼上。** 這個機制的價值在於逼你逐條決定「這個 warning 到底可不可以接受」，而不是把所有 warning 消音。每一條都要填上理由。

### 清理機制

工具會報告「列在 allowlist 但這次沒對到」的項目，避免清單長期累積垃圾。

FORBID 規則不會被列為未使用 — FORBID 沒對到代表系統健康，那正是我們要的。

---

## 建議節奏

| 時機 | 執行 |
|---|---|
| 改完程式碼 | `--self-test`（秒級，不需要 kernel） |
| 每個 phase 結束 | 唯讀檢查 + `check_logs.py` |
| 產生流量後 | 加 `--with-traffic` |
| 要驗證寫入路徑 | 加 `--allow-mutations` |
| 準備 demo 前 | OVS 和 P4 各跑一次，用 `--save-json` 存下來比對 |

---

## 檔案

| 檔案 | 用途 |
|---|---|
| `run_contract_test.py` | 主程式（CLI、HTTP、報表） |
| `spec.py` | 40 個端點的定義與不變量 |
| `schema.py` | 極簡 schema 驗證器（零依賴） |
| `selftest_fixtures.py` | `doc/ndt_api.md` 的範例，供 self-test 使用 |
| `check_logs.py` | log 檢查器 |
| `warning_allowlist.txt` | 可接受的 warning 清單 |

### 要新增一個端點檢查

編輯 `spec.py` 的 `ENDPOINTS`，加一筆 dict：`name`、`method`、`path`、`category`（`READ`／`MUTATE`／`ERRORPATH`）、`schema`，需要的話再加 `invariants`。

如果新增了 schema，順手在 `selftest_fixtures.py` 加一筆範例，這樣 self-test 才守得住它。

---

## 已知限制

- 端點清單是照 `HttpSession.cpp` 的註冊表手工維護的。kernel 新增端點時要一起更新這裡（`unknown_endpoint` 檢查只驗證未知路徑會回 404，不會偵測到「有實作但沒測」）。
- `--with-traffic` 的不變量假設流量正在跑。用在流量剛停的系統上會誤報。
- 對 `intent_translator`、`app_register`、`received_a_simulation_case`、`simulation_completed`、`historical_logging`、`modify_device_name`、group／meter 相關端點目前沒有檢查 — 它們需要外部相依（LLM token、模擬平台）或會造成不易還原的副作用。
