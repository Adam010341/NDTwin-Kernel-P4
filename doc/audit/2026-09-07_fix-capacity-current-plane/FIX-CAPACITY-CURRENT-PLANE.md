# W17 — `get_openflow_capacity` reports the plane it is actually running

分支 `fix/w17-capacity-current-plane`（base＝trunk `1536ff17`）。裁決 D-1（09-07 grill §4D）。

[Co-developed with claude code -- Adam]

---

## 1. 症狀

`GET /ndt/get_openflow_capacity` 把 `doc/2026-01-02_OpenflowCapacity.json` 原封不動吐出來：
`OVS 1000000`／`BrocadeICX7250 3072`／`HPE5520 65535`，**bmv2 一個字都沒有**。
而這台機器上跑的就是 bmv2：09-06 §X2 在活的 10 台 fabric 上量到

- 每台上限 **1024** 筆，落在 `MyIngress.ipv4_lpm`；
- fabric 自己的 host route 佔掉每台一條 `/32`（128 台規模＝128 條）⇒ 使用者實得 **896**；
- 單筆每 50 ms 灌 15 分鐘、與一次 2000 筆，**撞到同一個 896** ⇒ 是表滿，不是節流。

型錄裡最小的那個數字（3072）是實際可用量（896）的 **3.4 倍**。照它規劃的人會在 896 撞牆，
而撞牆的形狀是 bmv2 回 `StatusCode.UNKNOWN`、details 全空，proxy 只能翻成
`{"status":"error"}` 配 **HTTP 200**——「請求成功、內容是失敗」。

## 2. 修法

### 2.1 數字要說出它從哪來

回應每一塊都帶 `source`：

| 區塊 | `source` | 意思 |
|---|---|---|
| `OVS`／`BrocadeICX7250`／`HPE5520` | `"vendor table"` | 型錄。**沒有人在這套部署上量過它。** |
| `bmv2` | `"<artifact 路徑> max_size"`＋`source_kind` | 從**正在跑的那顆 binary 載入的** pipeline 讀的 |

`source_kind` 分兩種說法，因為那是兩種不同的宣稱：

- `argv of a running bmv2 switch (pid N)` — 走 `/proc/<pid>/cmdline`，argv[0] 的 basename 以
  `simple_switch` 開頭者才算，取 argv 裡**最後一個** `.json`（bmv2 的 argv 是
  `… <pipeline>.json -- --grpc-server-addr …`，pipeline 不是最後一個參數，但是最後一個 `.json`）。
- `build artifact -- … what a switch would load, not what one has loaded` — 沒有任何交換機在跑時。

### 2.2 三個值

`max_entries`（＝artifact 的 `MyIngress.ipv4_lpm.max_size`）、`in_use`、`available ＝ max − in_use`，
逐台一組。**`in_use` 沒讀到的交換機回 `null`，不回 `0`。**「還沒被 poll 過」和「表是空的」
是兩件事，把前者答成「1024 條都還空著」正是這個端點原本在犯的錯，只是換個位置。

### 2.3 兩個刻意不做的近似

- **`in_use` 是那台交換機全部表的列數，不是 `ipv4_lpm` 一張表的。** P4 的列在
  `ryu_flow_stats.py:158` 全部被標成 `table_id: 0`，表名在轉成 Ryu 形狀時就沒了，kernel 拿不到。
  ⇒ 若有 5-tuple 規則存在，`in_use` 會**高估** `ipv4_lpm` 的占用，`available` 因此是**下界**
  （偏保守，不會超賣）。這句話寫在回應的 `note` 裡，不是藏在這份文件裡。
- **`max_entries` 只認 `MyIngress.ipv4_lpm` 這個名字。** 它是 proxy 實際寫入的那張表
  （`p4_client.py:846`／`:926`／`:975`）。artifact 裡沒有這個名字時回 `null` 加 `why`，
  **不退回任何字面值**——「讀不到就用 1024」正是要修掉的病。

## 3. 檔案

| 檔 | 做什麼 |
|---|---|
| `include/ndt_core/http/OpenflowCapacityReport.hpp` | 宣告＋「為什麼」 |
| `src/ndt_core/http/OpenflowCapacityReport.cpp` | 機制。**獨立 TU**：`HttpSession.cpp` 在這台機器上要 1.6 GB／百秒級才編得完，閘門每個 mutation 重建一次，十次就沒人會跑那個閘門了 |
| `src/ndt_core/http/HttpSession.cpp` | handler 改成收集 bmv2 dpid ＋ 表視圖，交給 `readCapacityReport` |
| `include/ndt_core/http/HttpSession.hpp` | 第五個 test peer；`m_capacitySources` 讓測試把路徑指到 fixture |
| `tests/test_OpenflowCapacityReport.cpp` | 單元層＋端點層 |
| `tests/shell/mutate_capacity_reads_running_artifact.sh` | 閘門（12 個 mutation ＋ 4 個 widening） |
| `tools/contract_test/spec.py` | 兩條 invariant：`inv_capacity_names_its_source`（每一塊都要有 `source` 或 `why`）、`inv_capacity_available_closes`（三個數字要對得起來） |
| `tools/contract_test/selftest_fixtures.py` | 新形狀的樣本 ＋ 五個 invariant 自測案例（含兩個必須為紅的） |
| `tools/contract_test/warning_allowlist.txt` | `Cannot open OpenflowCapacity.json` 那條 FORBID 的**理由**過期了（它說「回空的 200」）；regex 不動 |
| `doc/2026-01-02_ndt_api.md` §37、`doc/KNOWN-ISSUES.md` C-6 | 文件 |

## 4. 測試為什麼是這個形狀

fixture 的 artifact **從來不寫 1024**，只寫 512 和 2048，而且同一段程式要兩個都答對。
理由：1024 是這個 repo 現在的 artifact 的正確答案，所以**一份寫死 1024 的測試會對一份寫死
1024 的實作全綠**——那正是上一層的病，換個位置再犯一次。

`/proc` 走訪一律打 fixture 樹，不打這台機器真正的行程表：「找不找得到正在跑的那顆」這個問題，
答案不可以取決於跑測試的當下實驗室有沒有開機。

### 4.1 閘門第一輪抓到的兩件事（都是**測試／閘門自己**的缺陷）

第一次跑 `mutate_capacity_reads_running_artifact.sh`：**12 個 mutation、2 個活下來**。
兩個都不是「碼沒被測到」，是**儀器壞了**：

1. 🔴 **M9／M12 讓行程 abort，而不是讓測試變紅。**
   nlohmann 的 **const** `operator[]` 碰到不存在的鍵會觸發 `JSON_ASSERT`，而這個 build
   沒有 `NDEBUG` ⇒ 直接 `abort()`。M9 把 `source` 拿掉之後，`report["OVS"]["source"]`
   **殺掉整個測試二進位**，於是一行 `[  FAILED  ]` 都沒有印出來——閘門只能把它記成 SURVIVED。
   **一個會 abort 的斷言，跟一個沒有人寫的斷言，在閘門眼裡長得一模一樣。**
   ⇒ 所有可選鍵的讀取改走 `at(json, key)` helper（`tests/test_OpenflowCapacityReport.cpp`）。
2. 🔴 **閘門的 `--gtest_filter` 打的是一個不存在的 suite 名。**
   原本寫 `HttpSessionCapacityTest.*`，而端點測試的 suite 叫 `CapacityEndpointTest`。
   `gtest_filter` 對不存在的名字**不會報錯，只是什麼都不跑** ⇒ 基準線是綠的、
   **而 M12（handler 退回原本吐檔案）本來就不可能被抓到，不管碼怎麼寫**。
   ⇒ filter 與 M12 的 expected 都改成 `CapacityEndpointTest`。

🔑 **這兩件事是這個閘門今晚最有價值的產出**：它們證明的不是「碼對了」，
而是「**這組測試在被拿掉修法時真的會說話**」——而第一版並不會。

## 5. 對帳與後續

- 09-05 R4-3 的「900」：§X2 已結案（900 ＝ 896 ＋ 量測前基準 3）。本單用的是 896／1024 那一組。
- KNOWN-ISSUES 新登錄 **C-6**「bmv2 表滿回 200」——**那是 proxy 側的另一張單**，本單只登錄，不修。
  🔴 **編號有撞號風險**：09-07 同一夜另一個 agent（`fix/bug17-mixed-dataplane-refused`）也在登記
  **C-5**。我看到的是它**未提交的草稿**（共用 scratchpad），所以把自己這條讓到 C-6；
  **兩條都還在分支上，併入順序若相反要再對一次號。**
- `doc/2026-01-02_ndt_api.md` §37 已改。**`NDTwin-Website` 的手冊鏡像還是舊的**（跨 repo，本單不動）。
- **沒做但值得做**：`source` 只**指名**檔案，沒有**證明**是那一份。§X2 是用 sha256
  （`0b19d789d74fc99…`）認 artifact 的，而本專案的規矩是「benchmark 必指認 binary（sha＋識別碼）」。
  回應多帶一個 `source_sha256` 就能把「指名」升級成「可驗證」。今晚沒做的理由是成本不對稱：
  這個 TU 目前不連 OpenSSL，而 OpenSSL 3 的 `SHA256_*` 是 deprecated，在 `-Werror` 下要另外開洞。
- **`doc/audit/2026-08-28_chaos-harness/harness/probes.py:364` 的註解過期了**（它說
  `get_openflow_capacity` 檔案不見時「回 200 空 body」——現在會回 bmv2 那一塊）。
  那是別一輪的儀器，本單不動，只登記。
