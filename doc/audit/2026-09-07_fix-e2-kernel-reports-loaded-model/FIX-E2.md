# FIX E-2 — kernel 回報它載入的模型（路徑＋sha256＋時間），`run_layers.sh` 改成問它

[Co-developed with claude code -- Adam]

分支 `fix/e2-kernel-reports-loaded-model`（base＝trunk `1a284f75`，未併、未推）。
裁決正本：`scratch/overnight-2026-09-05/DECISIONS.md`「grill §4E」**E-2**——
「開單：kernel 回報載入的模型路徑（或 sha）」，腳本改成問 kernel。
來源：`scratch/overnight-2026-09-05/fix/R2-PY-SUMMARY.md` §7 第 3 條。
KNOWN-ISSUES 條目：**G-15**。

---

## 1. 缺陷：一個**綠得理直氣壯**的儀器

`tools/test_workflow/run_layers.sh` 的 `topo_for_mode()` 由 **(資料平面, 活著的 host 數)**
在 `setting/` 裡找模型。它從來沒問過 kernel 開的是哪一個檔。

三件事湊起來才是缺陷：

1. 選檔靠推導（host 數）；
2. `setting/` 裡**不只一份**模型的基數與 dpid 完全相同；
3. 契約檢查 `inv_graph_matches_topology` 比的是「圖 vs **它被交到手上的**那份檔」。

⇒ 拿 A 建起來的 fabric 對 B 的模型驗，**每一條 per-node 身分檢查都通過**——
因為兩份檔的數字本來就一樣。這不是漏報也不是誤報：**整套檢查在對一個不存在的網路做比對，
而每一條都說 OK。**

**跑過**（2026-09-07，本 worktree，逐檔 parse `setting/StaticNetworkTopology*.json`）：
**兩對**模型完全同形——同 10 個 switch、同 host 數、同 edge 數、dpid 都是 1..10：

| 對 | switch | host | edge | dpid |
|---|---|---|---|---|
| `StaticNetworkTopologyP4_10Switches_4Hosts.json` ／ `StaticNetworkTopologyOVS_10Switches_4Hosts.json` | 10 | 4 | 40 | 1..10 |
| `StaticNetworkTopologyP4_10Switches_128Hosts.json` ／ `StaticNetworkTopologyMininet_10Switches.json` | 10 | 128 | 288 | 1..10 |

⚠️ **推導唯一的防線是檔名的「家族」前綴**（`topo_for_hosts` 用 `StaticNetworkTopologyP4_*`
與 `StaticNetworkTopologyOVS_*`／`Mininet_*` 分流）——**那是一個命名慣例，不是關於跑著的系統的事實**。
而且它管不到最重要的那一種情形：**kernel 可以用 `--topology` 開任何一個檔**，包括不在
`setting/` 底下、名字完全不照慣例的。**推導永遠構不到那種檔；只有 kernel 知道。**

🔑 **儀器不知道自己在測什麼，而且它沒有任何管道可以知道。** kernel 是唯一知道答案的人，
而它從來沒說過。

**與 L-1 的分工。** L-1 把「模型跟著 `components.env` 的預設」改成「模型跟著跑著的 fabric」，
讓推導**更準**——但推導仍然是推導。**這一張單修的是「不要推導，去問」。**

**R2-PY §7-3 說「契約測試關不掉這道門」是對的**，而它之所以對，是因為當時 kernel 不肯說。
kernel 一開口，那道門就關得掉了（§4 的 `inv_kernel_serves_the_model_under_test`）。

---

## 2. 修法

### 2.1 kernel：三個頂層新欄位

`GET /ndt/get_graph_data` **純新增**（`Obj` 非嚴格，加欄位不破壞任何既有消費者）：

| 欄位 | 型別 | 內容 |
|---|---|---|
| `topology_file` | string | 載入的檔，**正規化成絕對路徑** |
| `topology_sha256` | string | **載入那一刻檔案 bytes 的 sha256**，64 位小寫十六進位 |
| `topology_loaded_at` | integer | epoch 秒 |

實作（檔:行以本分支 tip 為準）：

- `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` `parseStaticTopologyFile()`：
  原本是 `std::ifstream file(path); … file >> j;`。改成**一次讀成字串、hash 那串、再 parse 那串**：

  ```cpp
  const std::string bytes((std::istreambuf_iterator<char>(file)),
                          std::istreambuf_iterator<char>());
  noteLoadedTopology(path, bytes);
  json j = json::parse(bytes);
  ```

  🔑 **同一批 bytes 既變成圖也被 hash。** 另開一次檔去 hash 會是**第二次讀**一個可能在兩次之間
  被改掉的檔——那正是這個 record 要讓人看見的競態。`std::ios::binary`，因為 `sha256sum`
  hash 的是磁碟上的東西。

  ⚠️ **順帶收緊了一點，寫出來以免被當成意外**：`file >> j` 只讀**一個** JSON 值就停，
  後面剩下的東西它不管；`json::parse(bytes)` 要求**整個檔就是一個 JSON 值**。
  ⇒ 一個「合法 JSON ＋後面接了垃圾」的拓樸檔，以前會載入，現在會被拒絕（走既有的
  CRITICAL＋不開 port 那條路）。**沒有任何 shipped 檔或測試 fixture 是那個形狀**
  （13 個 `setting/StaticNetworkTopology*.json` 都是純 dump），
  而「檔尾有垃圾」本來就該拒絕，所以留著這個收緊。

- `noteLoadedTopology()`：`weakly_canonical` 絕對化路徑、算 digest、記 epoch 秒，
  上 `m_loadedTopologyMutex`（載入的那條 thread 寫、HTTP thread 讀）。
- `sha256Hex()`：OpenSSL 一次性 `SHA256()` ＋自己的小寫十六進位。
  **hex 是契約而不是實作細節**——消費者是拿 `sha256sum … | cut -d' ' -f1` 來比的 shell。
- `loadedTopologyJson()`：沒 record 就回**空物件**（三個 key 一起不見）。
- `src/ndt_core/http/HttpSession.cpp` `handleGetGraphData()`：
  `result.update(m_topologyAndFlowMonitor->loadedTopologyJson());`——**平舖不包一層**，
  因為唯一的消費者是在旁邊拿 shell 讀它、跟它正在比對的圖並排看。

🔴 **在載入時算一次，不在每次請求重讀檔。** 重讀會報告「磁碟**現在**是什麼」，
而那正是消費者要拿來比對的量；kernel 的工作是說**它在服務什麼**。

🔴 **記錄的時機在 parse 與 validate 之前。** 誠實的敘述是「這就是我讀到的 bytes」。
壞檔會讓 `loadStaticTopology()` 走 CRITICAL 並讓 `main.cpp` 拒絕開 port，
所以沒有任何消費者看得到一次沒完成的載入所留下的 record。

### 2.2 baseline 的語意（每個新欄位都要交代的那一條）

`28b8b13` 與所有 E-2 之前的 kernel **三個欄位一個都不送**。

> **缺欄位＝「kernel 沒說」。不是「沒有東西要檢查」，不是「沒問題」，也不是「可以改去猜」。**

落地成三個地方的行為：

- `run_layers.sh`：退回原本的推導，**並印一行說它在 `guessing`**；
- 契約套件：回 `TOOL-PRECONDITION-FAILED`（**既不是綠也不是紅**——舊 kernel 沒壞，
  是這一輪沒辦法確認）；
- **沒載入任何拓樸的 kernel 也一個欄位都不送**，跟 baseline 同一個形狀、同一個意思。

兩個方向都被對照格擋著：把「沒說」變成拒絕跑是 **M6**，把「沒載入」變成有答案是 **M8**。

### 2.3 `run_layers.sh`：先問，問不到才推導

固定三層，`NDT_TOPO` 仍蓋過一切（既有逃生門，不動）：

```
NDT_TOPO  >  kernel 說的（且 sha 對得上）  >  由活 host 數推導（並印 guessing）
```

- `kernel_graph_json()` — 單獨一個函式，**就是給測試換掉用的接縫**（`fabric_host_count()`
  同一個形狀）。
- `kernel_loaded_model()` — body 走 **stdin** 而不是參數或環境變數：
  128-host 的圖輕鬆超過單一 exec 參數的上限（`MAX_ARG_STRLEN`，128 KiB），
  **而那正是模型選錯最要命的規模**。測試第 9 格拿一個 374 KB 的 body 打過這條路。
- `kernel_model_is_confirmed()` — 「我可以用 kernel 說的那個檔嗎」，兩個拒絕理由各一句話。
- 兩種 **rc 3**（拒絕，不是失敗），都印該怎麼辦：
  - sha 不合 ⇒ `... has been edited since the kernel loaded it` ＋**列出兩個 digest**
    （「兩者不同」不是診斷）；
  - 本機讀不到那個檔 ⇒ `... cannot read that file`。**不悄悄退回推導**：
    退回去就是拿一個 kernel 沒在服務的檔去驗，這正是 L-1 的失效再演一次。
- kernel 給了路徑但**沒給 sha** ⇒ **仍然用那個路徑**（那是 kernel 指名的檔，比猜好），
  但印黃字說這一輪無法判斷檔有沒有被改過。

### 2.4 契約：spec.py 的第五邊

- `GRAPH_DATA` 加三個 **optional** 欄位（pin 型別）。
  optional 而非 required，理由與底下 liveness 三兄弟一樣：**required 會把契約測試變成版本檢查**，
  健康的舊 kernel 會被判紅。
- 新 invariant `inv_kernel_serves_the_model_under_test`，**排在 get_graph_data 的第一個**：
  它後面每一條都是拿圖去比「這一輪被交到手上的那份檔」，
  **kernel 若在服務別的檔，後面每一條都名不副實**。三種回答：

  | 情況 | 回答 |
  |---|---|
  | kernel 說的檔＝這一輪指到的檔，且 digest 與磁碟一致 | 什麼都不報 |
  | kernel 沒說（E-2 之前） | `TOOL-PRECONDITION-FAILED` |
  | kernel 說的是**別的檔**，或同一個檔但 digest 不同 | **紅** |

  兩邊都走 `os.path.realpath`：runner 常常拿相對路徑、kernel 一律絕對，
  比字串會把「同一個檔的兩種寫法」報成「兩個檔」。

---

## 3. 測試與變異

| 檔 | 格數 | 管什麼 |
|---|---|---|
| `tests/test_TopologyLoadedModelReported.cpp` | 7 | kernel 那半：record 的三個欄位、hash 的是 bytes 不是路徑、載入後不跟著檔跑、沒載入就不說、三個 key 上到 wire、baseline 形狀 |
| `tests/shell/test_run_layers_asks_kernel.sh` | 10 | 消費者那半：用 kernel 說的檔、sha 不合 rc 3、沒欄位退回推導＋印 guessing、讀不到檔 rc 3、`NDT_TOPO` 仍最大、null 不當成檔名、大 body |
| `tests/python/test_contract_spec.py` | +8 | 三欄 optional、型別、invariant 的三種回答、相對/絕對同檔不算不符、digest 形狀 |

🔴 **儀器不能自己生出答案。** gtest 裡期望的 digest 是**測試自己讀檔、自己算**的
（跟受測碼不共用一行），而**那個 hasher 自己先對 FIPS 180-4 的 `"abc"` 向量**——
如果測試的 hasher 壞了，它會先說出來，而不是拿一個未知量去比對。

閘門 `tests/shell/mutate_kernel_reports_loaded_model.sh`，**8 個變異**：

| # | 變異 | 面 | 該紅的 |
|---|---|---|---|
| M1 | kernel 只回路徑、不回 digest | C++ | `TopologyLoadedModel.ThePathTheHashAndTheTimeAreRecordedAtLoad` |
| M2 | digest 算的是**路徑字串**不是檔案 bytes | C++ | `TopologyLoadedModel.TheHashIsOfTheFileBytesNotOfItsPath` |
| M3 | 每次請求**重讀檔**重算 digest | C++ | `TopologyLoadedModel.TheRecordDoesNotFollowTheFileAfterTheLoad` |
| M4 | `run_layers` 忽略 kernel、照舊推導 | sh | `the model the kernel says it loaded is the model used` |
| M5 | digest 不合照樣繼續 | sh | `a topology whose sha256 no longer matches is refused (rc 3)` |
| M6 | **加寬**：kernel 沒說就拒絕跑 | sh | `a pre-E-2 kernel falls back to the derivation and says it is guessing` |
| M7 | handler 從不把 record 併進回應 | C++ | `TopologyLoadedModelWire.TheThreeKeysAreServedByGetGraphData` |
| M8 | **加寬**：什麼都沒載入也送出三個 key | C++ | `TopologyLoadedModelWire.AKernelWithNoTopologyServesTheBaselineShape` |

🔴 **M2 是 kernel 那半最重要的一個。** hash 路徑會生出一個**存在、看起來合理、64 位十六進位、
而且終生不變**的欄位：它把「這個檔被改過嗎」永遠回答成「沒有」。
**一個不會變的 digest 比沒有 digest 更糟**，因為它占住了真答案該在的位置。

🔴 **M6／M8 是兩個加寬對照格。** 讓新測試變綠最便宜的兩條路就是「舊 kernel 一律拒絕跑」
與「沒載入也回三個欄位」，兩條都會毀掉這次改動唯一要買的那個分辨力。

閘門守自己的 baseline：C++ 那半 snapshot＋EXIT trap 還原＋最後逐檔 `cmp` 驗 byte-identical；
`run_layers.sh` **從頭到尾不寫**（變異進 temp dir 的副本，用 `RUN_LAYERS_UNDER_TEST` 指過去），
因為**別的 session 可能正在執行那支腳本**。anchor 一律在**真的檔**上數。

⚠️ **既有閘門的相容**：`mutate_run_layers_topology_from_fabric.sh` 的 M2 anchor 是
`'        return 3'`（八個空格＋`return 3`，極通用的字面）。本次新增的兩個拒絕路徑刻意**不是**
那個形狀（走 `kernel_model_is_confirmed … || return 3`，四個空格），
所以那個 anchor 在改後**仍然只命中一次**，既有閘門不需要改。
`check_gate_anchors.py HEAD` 改前 73/73 ok、改後 74/74 ok。

`tests/shell/test_run_layers_topology_from_fabric.sh` 加了一行
`kernel_graph_json() { return 1; }`：那套測試管的是**推導**，
不可以因為機器上剛好有 kernel 在 :8000 聽而改去量那個 kernel。

---

## 4. 沒做的

- **live 未驗。** 本分支的證據全部來自單元／整合測試與閘門。
  「arm 這顆二進位、`curl … | jq .topology_file,.topology_sha256` 對 `sha256sum`、
  再對活 fabric 跑一次 `run_layers.sh`」是 orchestrator 的事，**尚未進行**。
- **沒有加 `/ndt/status` 之類的新端點。** 選 `get_graph_data` 的理由見 SUMMARY §6。
- **kernel 不監看檔案。** 它報告載入當時的事實；「現在磁碟上是什麼」是呼叫端算的，
  而那是刻意的分工——kernel 若自己去比，它報的就不再是「我在服務什麼」。
