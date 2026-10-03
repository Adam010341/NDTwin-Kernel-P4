# P4 generic table writer：ternary／range／optional＋priority，與 API 寫入的 journal — 設計稿 r2

[Co-developed with claude code -- Adam]

- **範圍**：Adam 2026-10-01 選的下一刀。只有設計：不改碼、不上 lab、不 sudo。
- **基準**：分支 `design/p4-ternary-journal`，從 trunk `229ed30c` 開；以下行號都是這顆的。
  - r1＝`521a95d1`。r2 依第一輪審查（READY AFTER FIXES）改寫，對照表在 §11。
- **證據等級**（不混用）：
  - 【讀】：這次 session 親自讀過的碼或檔。
  - 【觀測】：這次 session 跑了指令、看到輸出，原始輸出在 `scratch/overnight-2026-09-05/logs/gates-0910/ternary-design/`，每份第一行都是 commit。
    - 只做了這幾種：protobuf descriptor、已安裝 binary 的 `strings`、`readelf`、grep。
    - **沒有執行任何 bmv2。**
  - 【轉述】：別份文件的說法，沒有重新驗證。
  - 【推論】：推出來的，沒有直接證據。
  - 【A0 NN】：另一個 worker 在拋棄式 `simple_switch_grpc` 上**實際執行**的量測（stock 與 bmv2-fast 兩個 binary 結果相同）。
    - 原始檔：`scratch/overnight-2026-09-05/logs/gates-0910/ternary-a0/`；`INDEX.txt` 是索引，`stock/NN-*.txt` 是逐項紀錄。
    - 我讀了 `INDEX.txt`、`stock/01`、`stock/10` 與 `ternary_a0.py` 的錯誤解碼段；其餘各項的結果引自 `INDEX.txt` 的逐項摘要。

## 0. 一段話講完

`POST /p4/table_entry` 沿用 tutorials 的 JSON 形狀，新增三種值的寫法：
- ternary `[value, mask]`；
- range `[low, high]`；
- optional 一個值；
- 外加頂層 `priority`。

**在 bmv2 會拒絕的地方，本機先回 400，什麼都不寫**（這些拒絕都已經在 bmv2 上量到過，【A0】）。交換機真的拒絕時，502 會帶上 per-update 的真正原因（E1）。

**generic writer 不寫 NDTwin 擁有的表**（Q2 建議）。這會順便修掉 trunk 今天的一個缺陷：對 baseline 的 `flow_5tuple` POST 一筆空 match 的 entry，會在 `ipv4_lpm` 前面裝上一條 catch-all，而且回 200（§1.5）。

開機 entry 和 API 走同一個 builder；pre-flight 和 writer 共用同一份形狀檢查。

**只有 API 的寫入會進 journal**，設計如下：
- 每台交換機一個檔（`.run/table_entry_journal/s<dpid>.jsonl`），配一把鎖。
- 先寫交換機，fsync 之後才回 200。
- proxy 重啟與 readopt 時，從檔案**重新讀一次**，依 entry 身分**折疊**成淨狀態，重放之後寫回 snapshot。
- replace-vs-add 的防線是「**折疊＋snapshot 取代整份檔**」。

要不要重放，看兩件事：
- 交換機上的 pipeline cookie 能不能證明「這是同一個 bmv2」（Q1 建議；可行性已量到【A0 08】）；
- p4info 與 package entries 檔的 sha 對不對得上。

舊的 kernel-routing journal 照舊：只記錄，不重放。

## 1. 今天的碼

### 1.1 writer（`p4_proxy/proxy_agent/p4_client.py`）【讀】

**能建的 match type 寫死在 `:133`**：`BUILDABLE_MATCH_TYPES = ("EXACT", "LPM")`。
- `build_table_entry` 遇到「呼叫者**有寫出來**的欄位」不在這個 tuple 裡，就丟 `TableEntryUnsupported`（`:1199-1208`），route 譯成 501。
- 🔴 **沒寫出來的欄位不檢查**，見 §1.5。

例外的分類：
- `TableEntryUnsupported` → 501（`:90-103`）；
- `TableEntryInvalid` → 400（`:106-117`）；
- `ControlPlaneReadOnly` → 409（`:46-62`）。

`encode_value`（`:136-217`）：
- 值放不下就拒絕、**不截斷**（拒絕在 `:210-216`）；
- 布林不算 1。

`table_honours_priority`（`:1132-1145`）的定義是「有任何欄位**不在** `BUILDABLE_MATCH_TYPES`」。
- ⇒ 它和那個 tuple 綁在一起（§10-1）。

priority（`:1284-1296`）：
- 非整數 → 400；
- 非 0、而且落在沒有 priority 欄的表 → 400；
- **0／缺漏落在有 priority 欄的表：不檢查**，今天就走得到（§1.5 的空 match 路徑）；
- **default entry 帶 priority：不檢查。**

`write_table_entry`（`:1318-1392`）：
- 刻意不做 MODIFY fallback（`:1327-1335`）；
- 只過 `_refuse_write`（`:1344`），**不看 route binding**；
- default 的 insert 會換成 modify（`:1353-1356`）；
- insert／modify 要有 action，**delete 可以不帶 action**（`:1356-1359`）；
- `stub.Write` 在 `:1368`，install time 在它之後記（`:1370-1377`）。

讀取側：
- `_built_entry_match`（`:1300-1316`）只認 exact／lpm；
- `read_table_entries` 認 ternary 與 range（`:1487-1494`），**丟掉 optional**。

don't-care 用「不放進 entry」表示（`:1655-1662`）。

兩個帶 MODIFY fallback 的 insert：
- `insert_5tuple_rule`：`:1800-1808`；
- `insert_ipv4_route`：`:1903-1913`；
- 理由都是 bmv2 對「已存在」也回 UNKNOWN（`:1802-1804`）。

`delete_5tuple_rule` 的 docstring 說：priority 錯了，delete「removes nothing and reports success」（`:1847-1850`）。

`RPC_TIMEOUT_S` 的註解說，寫入在負載下可能**實際已經落地**、卻回 DEADLINE_EXCEEDED（`:27-28`）。

### 1.2 route（`p4_proxy/proxy_agent/api_routes.py`）【讀】

`POST /p4/table_entry`（`:841-957`）：
- 狀態碼表在 `:866-886`。400／404／409／501 都在 `stub.Write` 之前回，測試斷言 `stub.requests == []`。
- client 在 `:902` 取一次，之後才 `await run_in_threadpool(client.write_table_entry, ...)`（`:919`）。
- 501 的 remedy 寫的是「wait for the ternary writer」（`:925-930`）。
- 每次成功都回 `journaled: False` 加上 `TABLE_ENTRY_NOT_JOURNALED`（`:837-838,954-957`）。
  - 這是 Adam 09-18 的裁決 (a)【轉述 `TICKET-P2-exercise-dataplane.md:5,68`】。
  - multicast 也用同一個常數（`:1130`）。
- `switch_state.table_entries.journaled` 是常數 false（`:765-767`；`main.py:794-807`）。

`_refuse_unhonourable_priority`（`:413-470`）只管 OpenFlow 形狀的 endpoint：
- 09-03 實測：在 `ipv4_lpm` 用 priority 777 modify、priority 999 delete，都作用在本來就在的那一筆，而且回 200（`:427-432`）。
- 09-11 實測：body 被切到 200 bytes，所以 remedy 要放在最前面（`:448-457`）。

`POST /p4/readopt/{dpid}` 是 `def`，跑在 threadpool 上，期間其他 endpoint 照常服務（`:656-692`）。

### 1.3 開機 entries 與 pre-flight【讀】

`main.apply_package_entries`（`main.py:618-665`）：
- 每一筆都呼叫 `client.write_table_entry(spec, op)`（`:657`）；
- 一筆失敗不擋其他筆，失敗的計進 `failed`。

什麼時候套用：
- startup：只在外來 pipeline、不是 broken、不是 read_only 時套用（`:2009-2020`，條件在 `:2015`）。
- readopt：push 之後重套，計數**重記、不累加**（`:1754-1760`）。
- PRE entries **每台都套**（`:2024-2048`）。

`tools/p4_exercise/preflight.py`：
- `check_entry`（`:200-288`）：不在 `_SUPPORTED_MATCH`（`:59-60`）裡的型別，一律報 FAIL「G5 not done」（`:224-235`）。
- **不檢查 priority。**
- 非 default、又沒有 match 的 entry 一律 FAIL（`:213-215`）。
- 值的檢查用 `encoded_width`（`:153-185`），和 writer 的 `encode_value` 是兩份不同的實作。

ruling 8-1 的實作（`:470-517`）：
- owner ndtwin 的表上，package 的 **match entry** 一律 FAIL；
- **default action 保留**，只記一行 note（`:514-517`）。
- `main.py:1770` 依賴這一點：「After the package's entries, so the table's default action is in place first」。

PF-T fixture：
- 檔案：`tools/p4_health/exercise/runtime/s2-runtime-pft.json:267-280`；
- 內容：`HcIngress.t_ternary`，`["10.0.1.1","255.255.255.255"]`，`priority: 10`；
- 那張表只有一個欄位 `hdr.ipv4.srcAddr`（`hc_main.p4:406-411`）。

### 1.4 rule_journal，以及它的 replay 為什麼沒有呼叫點

【讀】
- `rule_journal.py` 記錄 kernel routing，接線在 `main.py:40-111`，寫入點是 `topology_manager._note_in_journal`（`:1081-1107`）。
- 只記交換機接受的寫入（`rule_journal.py:135-136`）。
- 欄位是 OpenFlow 形狀；每筆 fsync；鎖只包住 append（`:144,167-178`）；`record` 每次都重新 open 路徑（`:171`）。
- `replay`（`:247-276`）**會自己重讀檔案，逐行套用原始紀錄**（`:260`）。⇒ 不能交給它一份折疊過的清單（§10-3）。

【觀測 `grep_replay_quarantine.log`】`.replay(` 與 `.quarantine(` 只出現在 `p4_proxy/tests/test_rule_journal.py`。

沒有呼叫點的原因。前兩點是碼裡寫的【讀】：
1. 它記的是請求，不是理由。TE 繞路過期之後，重放會裝出一條沒人要的路（`:28-31`）。所以預設關，要 opt-in（`:54-61`）。
2. 開關的位置在呼叫端（`:256-258`），而「該不該重放」本身就是一個沒人做的決定（`main.py:51-53`）。

後兩點是推論【推論】：
3. `quarantine`（`:280-296`）也沒有呼叫點。所以那份檔從沒分過代，重放會把很多次重啟以前刪掉的規則裝回來（它自己的 docstring 說的，`:285-288`）。
4. 重啟之後，`install_initial_routes` 會重鋪路由，而兩個 insert 都帶 MODIFY fallback（§1.1）。重放與重鋪之間，誰最後寫誰贏。

### 1.5 roles、owner、external，以及一個 trunk 上的現存缺陷

【讀】
- `mode` 只有 `ndtwin`／`external`（`app_package.py:93-95`）；`read_only` 就是 `mode == external`（`:298-300`）。
- owner：
  - `OWNER_NDTWIN`：NDTwin 獨占那張表；
  - `OWNER_PACKAGE`：作者擁有，NDTwin 只讀（`route_binding.py:51-57`）。
- external 的情況：
  - client 不仲裁；
  - 每個寫入方法都先過 `_refuse_write`，被擋就回 409（`p4_client.py:495-506`）；
  - startup 不 push（`main.py:1978`）。
- `route_binding` 是 class 預設值 `BASELINE`（`p4_client.py:254-260`），而那段註解記下了 roles ticket「不准改既有測試的 fixture」（`:255-257`）。
- 測試替身 `a_client` 用 `__new__` 建，從不呼叫 `bind_routes`（`tests/test_table_entry_route.py:159-175`）。⇒ 它是 baseline client。成功路徑的測試 POST 的是 `AN_LPM_ENTRY`，也就是 `MyIngress.ipv4_lpm`（`:202-205`）。

🔴 **現存缺陷（trunk `229ed30c`，只記在這個未推的分支）**：

```
{"dpid":1,"table":"MyIngress.flow_5tuple","match":{},"action_name":"MyIngress.drop","priority":1}
```

- 寫錯的程式碼路徑【讀】：
  1. `match` 是空的，所以 `:1199-1208` 的迴圈什麼也沒檢查，501 不會觸發。
  2. 表的六個欄位全是 ternary（`ndtwin_switch.p4:329-347`），所以 `table_honours_priority` 為真，priority 1 被接受（`:1284-1296`）。
  3. 最後送到 `stub.Write`（`:1368`）。
- 交換機會怎樣：
  - 省略欄位是 bmv2 接受的 don't-care 寫法【A0 04：省略 lpm 欄位 OK】【A0 05：要求「omit」】；
  - 把六個欄位全部省略的 ternary entry 沒有直接量過【推論】：它會被接受，等於在 `ipv4_lpm` 前面裝一條 catch-all drop，回 200。
- 把 priority 拿掉，同一條路會帶著 priority 0 上線。bmv2 會拒絕：per-update INVALID_ARGUMENT「Zero priority for ternary match」【A0 01、07】。
  - 這個 proxy 會把它報成 **502 `grpc_status: UNKNOWN`**（§1.8）。
- ⇒ r1 說「`flow_5tuple` 今天被 501 擋著」**是錯的**；說「priority 0 在有 priority 欄的表上今天走不到」**也是錯的**。

### 1.6 bmv2／PI／P4Runtime 要求什麼

| 事實 | 等級與來源 |
|---|---|
| `TableEntry.priority` 是 int32；MatchType 的編號：EXACT=2、LPM=3、TERNARY=4、RANGE=5、OPTIONAL=6；`Ternary{value,mask}`、`Range{low,high}`、`Optional{value}`；`ForwardingPipelineConfig.cookie` 是 uint64；有 `COOKIE_ONLY` 這個 response type | 【觀測 `descriptor.log`】venv 的 p4runtime 1.5.0 |
| `libpifeproto.so.0`（sha16 `987b243193959872`）含 PI 的拒絕字串 | 【觀測 `pi_strings.log`】 |
| 以下這些**實際會觸發**，都是 per-update INVALID_ARGUMENT，而且什麼都沒寫進去：priority 0 打 ternary 表；default entry 帶非 0 priority；INSERT 一筆 default entry；省略 EXACT 欄位；lpm /0；遮罩 0；整段 range；low > high；LPM 帶 host bit（insert 與 delete 都會拒） | 【A0 01、03、04、05、06、07、09】 |
| `value & ~mask ≠ 0` | **沒量**。那句字串存在【觀測】，會不會觸發是【推論】 |
| priority 1 到 2^31-1 全部 OK、沒有 abort；bm 內部的 priority = 2147483647 − p4rt priority；-1 被拒（UNKNOWN「Error when adding match entry」） | 【A0 07】⇒ BM_MAX 相當於 2^31-1【推論，A0 從對應關係推出來】 |
| 「數字大的贏」 | 【A0 11】同一個 match、priority 10 與 20，封包命中 20 那一筆；只在 stock 量到 |
| priority 是身分的一部分：priority 錯的 delete／modify 回 NOT_FOUND「Cannot find match entry」，entry 不動；兩筆同 match、不同 priority 都 insert 得進去 | 【A0 01、02、11】 |
| 讀回來的值會去掉前導零（全 0 變成一個 byte 00）；過長、但多出來的是前導零的值會被接受再去掉；optional 經 P4Runtime 讀回來仍是 optional，thrift 顯示成 `TERNARY 06 &&& ff`；Read 依 insertion 順序回傳 | 【A0 10】 |
| wildcard Read 不回 default entry，只有 `is_default_action=true` 的 Read 才回 | 【A0 06】 |
| 兩個 `simple_switch_grpc` 都 NEEDED `libpifeproto.so.0`；bmv2-fast 的 RUNPATH 底下沒有這個檔 | 【觀測 `readelf.log`】⇒ 兩者用的都是 `/usr/local/lib` 那一份【推論】 |
| `libbmpi.so.0` 的 `PriorityInverter` 字串；fast build 少了 assert 運算式 | 【觀測 `pi_strings.log`】。在 int32 範圍內不重要：兩個 build 對每個 priority 都沒有 abort【A0 07】 |
| cookie：push 時帶 cookie，COOKIE_ONLY 讀得回來；不帶 cookie 再 push 一次 ⇒ `has_cookie=False`；全新 bmv2（命令列給 JSON，或 `--no-p4`）在還沒 push 之前 ⇒ **FAILED_PRECONDITION**「No forwarding pipeline config set」 | 【A0 08】⇒ cookie **活不過 bmv2 重啟**，Q1 (a) 需要的就是這一點 |
| 🔴 碼裡的註解與 A0 08 不一致：`topology_manager.py:1373-1375` 說 bmv2 沒有 pipeline 也回 COOKIE_ONLY；`probe` 送的是 COOKIE_ONLY（`p4_client.py:704-717`）；push 沒設 cookie（`:732-739`） | 【讀】vs【A0 08】⇒ 依量測，剛重啟、還沒 push 的 bmv2，`probe` 會得到 `ok: False`。這一刀不處理（§10-13） |
| 「數字大的贏」 | 【轉述】P4Runtime spec（沒讀）；碼裡的說法：`p4_client.py:1759-1763`、`topology_manager.py:319` |
| tutorials 要求 TERNARY／RANGE／OPTIONAL 的表帶非 0 priority；ternary 寫 `[v,m]`、range 寫 `[lo,hi]`；不支援 optional | 【讀】`~/tutorials/utils/p4runtime_lib/simple_controller.py:150-167`、`helper.py:98-107` |

### 1.7 要轉綠的健檢格【讀】

- 來源：`doc/audit/2026-10-03_p4-health-check/expected_today.tsv`，以及該處 DESIGN §2.3 `:284-289`。
- 今天的狀態：T4／T5／T6 是 RED（501）；T7 是 NOT RUN（它依賴 T4）；T8 是 RED（恆為 false）；PF-T 是 RED（G5）。
- 判定碼：`tools/p4_health/cells/table.py`。
  - T4–T6：`:306-323`；
  - T7：`:326-334`；
  - T8：`:337-347`，讀 `switch_state` 的 `journaled is True`；
  - PF-T：`:350-363`，rc 0 判 GREEN。它唯一的 RED 路徑認的是「G5 not done」那句話（`:350-355`；`s0.py:124-133`）。
- T4–T7 的收集器還沒寫（`collect/` 底下只有 `post_table_entry`，`collect/proxy.py:51`）。
- S0 有**兩條**自檢斷言 PF-T 必須 FAIL：
  - `s0.py:275-277`；
  - `pft_verdict`（`:574-583`）。
  - 任何一條失敗，S0 的總判定就是 PROBE-BROKEN（`:598-599`）。
- bring-up C 用 owner ndtwin 綁定 `HcIngress.ipv4_lpm`（`s0.py:50-51`）。exercise 的 runtime 檔有那張表的 default（`runtime/s1-runtime.json:20-25`）。

### 1.8 失敗長什麼樣，以及這個 proxy 怎麼轉述

- 失敗的 Write 在 gRPC 頂層回的是 **UNKNOWN、message 為空**。真正的代碼與訊息在 `grpc-status-details-bin` 裡，是每個 update 一個的 `p4.v1.Error`【A0 INDEX「HOW TO READ THE STATUS」；`stock/01` 第 89-90 行】。
- `_grpc_status_name`（`api_routes.py:222-242`）只讀 `code()`；整個 `p4_proxy/proxy_agent/` 沒有任何地方讀 trailing metadata【讀；grep `grpc-status-details-bin`／`trailing_metadata` 無結果】。
  - ⇒ 今天每一個被交換機拒絕的寫入，都報成 502 `grpc_status: "UNKNOWN"`，真正的原因（NOT_FOUND、INVALID_ARGUMENT…）被丟掉了。
- 兩個 insert 的 MODIFY fallback 認的是 ALREADY_EXISTS／UNKNOWN（`p4_client.py:1800-1808,1903-1913`），所以**每一種**拒絕都會觸發重試【推論】。註解自己承認分不出來（`:1906-1910`）。
- `delete_5tuple_rule` 的 docstring 說「removes nothing and reports success」（`:1847-1850`），講的是 kernel 的 OpenFlow 5-tuple delete 路徑。和 A0 01 對不上：
  - 這個 bmv2 對 priority 錯的 delete 回 per-update NOT_FOUND（頂層 UNKNOWN）；
  - 那條路徑 catch 到 RpcError 之後回 False（`:1862-1869`）【讀】；
  - ⇒ **它回報的是失敗，不是成功**。docstring 描述的是別的 target 或舊行為【推論】。修正見 §10-14。
- 拆解 per-update error 需要的 `google.rpc.status_pb2`，proxy 的 venv 裡有【觀測：import 成功】。A0 的腳本就是這樣拆的（`ternary_a0.py:150-156`）。

## 2. 決定一：API 形狀、驗證、錯誤碼

### 2.1 形狀

body 照舊（`api_routes.py:852-857`）。值怎麼讀由 p4info 的 `match_type` 決定，**不從值的長相猜**（`p4_client.py:1160-1166`）。

| match_type | 寫法 | 上線（wire） |
|---|---|---|
| EXACT | 照舊：純值，或一元素 list | `exact.value` |
| LPM | 照舊：`[value, prefix_len]`；prefix_len 只收 1..bitwidth（V5） | `lpm` |
| TERNARY | `[value, mask]`，兩個都經 `encode_value(x, bitwidth)` | `ternary{value,mask}` |
| RANGE | `[low, high]`，編碼同上 | `range{low,high}` |
| OPTIONAL | 純值，或一元素 list | `optional.value` |
| 其他（`UNSPECIFIED`、`other`） | 照舊回 501 | — |

- ternary／range／optional／lpm 的欄位**省略**，就是 don't-care。
- **EXACT 欄位省略 → 400（V8，新增）。** 今天它會一路送上 wire，bmv2 回「Missing non-ternary field in match key」【A0 03】，proxy 報成 502 UNKNOWN（§1.8）。
- `priority` 是頂層整數，同一個鍵（`api_routes.py:915`）。
- **輸入只收一種寫法（list），不收 `{"value":..,"mask":..}`。**
  - 原因是錯誤訊息只有一套，而不是身分問題：身分本來就是用編碼後的值算的（§3.1）。
- 回應：
  - 照舊的欄位；
  - 加上 `"priority": <上線的值>`；
  - `journaled` 依 §5.6 決定；
  - `note` 只在 `journaled: false` 時出現。

### 2.2 驗證（都在 `stub.Write` 之前）

錯誤碼除了 V7 是 409，其餘都是 400 `TableEntryInvalid`。

- **V1 arity**：TERNARY／RANGE 必須剛好兩個元素。OPTIONAL 給兩個元素 → 400。
- **V2 編碼**：value／mask／low／high 都經過 `encode_value`；放不下就拒絕。
- **V3**：`value & ~mask != 0` → 400。不替作者把 value 遮掉。
- **V4**：`low > high` → 400。
- **V5 don't-care 的第二種寫法**：遮罩全 0、range `[0, 2^w-1]`、lpm `/0` → 400，訊息是「omit the field」（Q3）。
- **V6 priority**，適用於有 priority 欄的表（定義見 §10-1）：
  - insert／modify／delete 都**必須**帶 priority，而且 `1 ≤ p ≤ PRIORITY_MAX`。
  - exact／lpm 的表帶非 0 priority → 400（照舊）。
  - **default entry 帶非 0 priority → 400。**
  - `PRIORITY_MAX` = 2^31-1：等於 int32 上限，A0 量過整段範圍都 OK、沒有 abort【A0 07】。
  - 不做 `p4_priority` 的 +1 平移（`topology_manager.py:314-333`）：這個 endpoint 講的是 P4Runtime 自己的數字。
- **V7 owner**（Q2）：寫進 NDTwin 擁有的表 → 409，`error: "owned by NDTwin"`，`outcome: "owned_by_ndtwin"`。
  - `remedy` 放在前 200 bytes 內（理由同 `api_routes.py:448-457`）。
  - **V7 放在 `write_table_entry` 裡，不放在 route。** 這樣開機與重放也會再過一次，而 §5.2「重放再走一次 `write_table_entry`」才是真的。
  - 帶 ruling 8-1 的 default-action 例外（Q2 子題）。
  - ⇒ bring-up C 的 package default 照常裝上，**不會**出現 `failed > 0`。若 Q2 子題選「不留例外」，C 就會 `failed = 1`，要記進健檢預測。
- **V8**：EXACT 欄位省略 → 400。
- **V9**：LPM 的 value 在 prefix 之外有 host bit → 400。bmv2 自己就拒絕、不正規化，delete 也一樣【A0 09】，所以本機這條只是提早拒絕、把訊息講清楚。
- **V4、V5、V6、V8、V9 都只是重複 bmv2 本來就會做的拒絕**【A0 01-07、09】。在本機做的理由有兩個：
  - 回 400 而不是 502 UNKNOWN，而且 wire 上什麼都沒送；
  - pre-flight 在 fabric 起來之前就能用同一句話拒絕。
- 只有 V3 沒有量過【推論】。
- **E1：502 帶上真正的原因。** route 的 502 body 加 `p4rt_error: {"code": "<canonical name>", "message": "..."}`，由 `grpc-status-details-bin` 拆出來（§1.8）。`grpc_status` 照舊保留。
  - replay 報告與 §10-4 的 NOT_FOUND 判斷，都要靠這個欄位：只看頂層的話，每一種失敗都是 UNKNOWN。
  - 不改成 404：route 的契約說 404 一定發生在 `stub.Write` 之前（`api_routes.py:883-886`）。

錯誤碼表，取代 `api_routes.py:866-882`：

| 碼 | 意思 |
|---|---|
| 200 | 照舊 |
| 400 | 加上 V1–V6、V8、V9 |
| 404 | 照舊 |
| 409 | external（照舊）；V7（`error` 字串不同） |
| 501 | 只剩 `UNSPECIFIED`／`other` |
| 502 | 照舊 |
| 503 | `replay pending`，只發生在 readopt 期間（§5.5） |

### 2.3 共用形狀檢查（G5 的前提）

新增 `p4_proxy/proxy_agent/match_shape.py`，不依賴 gRPC。內容：
- `encode_value`，從 `p4_client.py:136-217` 搬過來，`p4_client` 再 re-export；
- V1–V6、V8、V9；
- 「這張表有沒有 priority 欄」的判斷。

`p4_client.build_table_entry` 與 `preflight.check_entry` 都呼叫它。先例是 `route_binding.resolve`，一個函式兩個呼叫端（`route_binding.py:32-36`）。

V7 不在這裡：它需要 binding，pre-flight 已經有自己的 8-1 檢查（`preflight.py:470-517`）。

## 3. 決定二：modify／delete 的身分，以及 replace-vs-add

### 3.1 身分

身分＝`(dpid, table, priority, 正規化後的 match)`。
- 建在 `rule_install_times.entry_key` 之上（`rule_install_times.py:141`）。它實際的樣子是 `(str(dpid), str(table), int(priority or 0), normalise_match(match))`：
  - 值轉成 int，而不是 bytes（`:72-87`）；
  - 遮罩 0 的 ternary 欄位已經去掉（`:90-100,127`）；
  - optional 會落進 `unknown` 分支（`:116-121`），**這一刀要補上明確的 `optional` 分支。**
- priority 原樣帶進來。它和「無 priority 欄的表用 0」等價，只因為 V6 在那種表上拒絕非 0。
- **default entry 的 key 要另外造**：`(dpid, table, "default")`。否則它和「每個欄位都省略的 entry」會撞成同一個 `(dpid, table, 0, ())`。
- 讀取側要補 optional（`p4_client.py:1487-1494`）；`_built_entry_match` 也要補三種型別（`:1300-1316`）。

有 priority 欄的表上：
- modify／delete **必須**帶 priority（V6）；priority 是身分的一部分（`p4_client.py:1842-1850`）。
- priority 帶錯：delete／modify 回 per-update NOT_FOUND，entry 不動；priority 為 0 就是 INVALID_ARGUMENT【A0 01、02】。
  - ⇒ 不會發生 09-03 那種「改到別筆」（`api_routes.py:427-432`）。
  - 也**不需要**先讀再寫。route 回 502，`p4rt_error.code = "NOT_FOUND"`（E1）。
- **正規化要用「去掉前導零」之後的形式**，因為讀回來就是那樣【A0 10】。
  - `_value_key` 已經把 bytes 轉成 int（`rule_install_times.py:72-87`），對前導零不敏感，符合這個要求。
  - optional 經 P4Runtime 讀回來仍是 optional【A0 10】，所以新加的 optional 分支，寫入側與讀取側的形狀一致。
- **modify 不能改 priority**；改 priority 就是 delete 再 insert。
- 照舊沒有 MODIFY fallback（`p4_client.py:1327-1335`），重放也沒有。

### 3.2 replace-vs-add 從哪裡進來、怎麼擋

記憶檔 `replace-vs-add-bug-shape.md` 的問題：舊的資料什麼時候消失？

1. **journal 本身**：防線是「**折疊＋snapshot 取代整份檔**」（§5.4）。
   - 「重放不追加」是一個另外要測的性質（M-J4，§6）。
   - 照 §5.4 的步驟順序，就算有人追加，也只會落在被隔離的舊 inode 上。所以要對隔離檔下斷言才殺得掉它。
2. **身分拼法**：折疊用 §3.1 的 key（編碼後的值）。
   - `"10.0.1.1"` 和 `167772417` 是同一個 key，在任一種寫法下 delete，都會移掉另一種寫法的 insert。
   - V5、V9 讓「同一個 entry 有第二種 wire 形狀」這件事不存在。
3. **世代**：每台、每次重放都把舊檔 **hard link** 成隔離名，再用 `os.replace` 換掉 live 檔（§5.4 步驟 5）。
   - 不用「先改名再寫」：那樣當掉的時候會沒有 live journal。
   - fabric 重新 bring-up，交給 Q1 的 cookie 判斷。
4. **計數**：重放的計數比照 `_record_table_entries`（`main.py:818-819`），**重記、不累加**。
5. **和 NDTwin 的寫入者重疊**：Q2 (a) 的 V7 讓兩邊寫的表不相交。
6. **package entries 檔改了**：見 §5.2 的 entries sha 防護。

## 4. 決定三：開機 entries（G5）

- `apply_package_entries` 不改（`main.py:652-657`）。builder 會建三種新型別之後，開機的 ternary entry 自然就會裝上；一筆失敗不擋其他筆，照舊。
  - V7 現在在 `write_table_entry` 裡，所以開機也會過 V7。8-1 的 default 例外讓 C 的 default 照常裝上（§2.2）。
- pre-flight 的 `check_entry` 要改：
  - 刪掉 `:224-235`；三種新型別改呼叫 `match_shape`；
  - 加上 priority 的規則；
  - `:213-215` 改成：非 default、沒有 match 的 entry，如果表上有 priority 欄就放行（那是合法的全 wildcard entry），否則照舊 FAIL；
  - 一起改 docstring `:33-34` 與 `:59` 的註解。
  - ⇒ PF-T 的 fixture 會通過。
- NDTwin 自己的 pipeline 上，package entries 照舊只記錄、不套用（`main.py:1999-2008`）。
- 開機 entry **不進 journal**：
  - 每次都從 package 檔重算（`:2016`、`:1757`）。
  - 如果也記進 journal，重放時會跟重算出來的那份撞成 ALREADY_EXISTS／UNKNOWN（`p4_client.py:1802-1804`）。
  - 而且 package 檔改了以後，舊的 journal 會把舊的 entry 寫回去。

## 5. 決定四：journal

### 5.1 記什麼

- **只記 API 寫入**：insert、modify、delete，而且只記交換機接受的（`rule_journal.py:135-136`）。
- 被拒的（400／404／409／501／502）不記。
  - 有一個例外，§10-4：delete 回 NOT_FOUND 也記。
- 開機 entry 不記。kernel routing 照舊記在舊檔，也照舊不重放（§5.7）。

### 5.2 檔案與格式

- 檔案：每台一個，`.run/table_entry_journal/s<dpid>.jsonl`。
  - 推導方式比照 `default_journal_path`（`main.py:62-82`）；env `NDTWIN_TABLE_JOURNAL_DIR` 可覆寫；`NDTWIN_TABLE_JOURNAL=off` 可關閉。
  - **為什麼每台一檔**：每台的鎖同時涵蓋 append 與 snapshot。readopt 一台的時候，另一台的寫入落在**另一個檔**，不會掉進被隔離的 inode（審查 M3 的第一個問題）。
- 不和 `rule_journal.jsonl` 合在一起：
  - 兩者的重放政策相反；
  - 形狀不同；
  - 舊檔的 19 個測試與 `mutate_rule_journal_is_wired.sh` 的錨點都不動（錨點唯一性見 §10-9）。
- 實作：`rule_journal.py` 裡的 `TableEntryJournal`。
  - 沿用的：`entries()` 容忍撕裂行的讀法、`ReplayReport` 的四值狀態。
  - **自己寫的**：`record`、`fold`、`replay`（`RuleJournal.replay` 會重讀、逐行套用，不適用，§10-3）、`write_snapshot`。
  - `write_snapshot` 的步驟：tempfile → fsync → hard link 舊檔成隔離名 → `os.replace` → fsync 目錄（§10-10）。

**第一行是 header：**

```
{"v":1,"header":true,"dpid":3,"fabric_cookie":"<u64 hex>","p4info_sha256":"<16 hex>",
 "entries_sha256":"<16 hex 或 null>","boot_id":"<BOOT_ID>"}
```

**之後每行一筆：**

```
{"v":1,"t":<s>,"op":"insert|modify|delete","key":"<§3.1 key 的 hex 摘要>",
 "spec":{"table":..,"match":..,"action_name":..,"action_params":..,"default_action":..,"priority":..},
 "outcome":"ok|not_found"}
```

- **`spec`** 是驗證過的原文。重放時再走一次 `write_table_entry`，所以 V1–V9 與 409 都會再套一次。
- **`p4info_sha256`** 用 `_p4info_fingerprint`（`main.py:511-523`）。
  - 不符時整檔記為 `stale_pipeline`，不套用。
  - 理由是「名字相同不代表同意」（`route_binding.py:10-12`）。
- **`entries_sha256`** 是這台 package entries 檔的 sha，回應審查的 MINOR。
  - 不符時：淨效果是 insert、而且原本不存在的 key 照常重放。
  - 淨效果是 modify／delete（它碰的是開機 entry 或 default）的那些記為 `stale_entries`，不套用。
  - 理由同 §4：package 檔改了，舊的 modify／delete 是針對已經不存在的開機狀態。
- **`fabric_cookie`** 見 Q1。

### 5.3 寫入的順序與鎖

整段放在一個 `run_in_threadpool` 的 callable 裡。鎖用 `threading.Lock`，**絕不跨 `await` 持有**；client 在鎖內才查，這樣 readopt 換過的新 client 一定看得到。

```
def _write_and_journal(dpid, spec, op):            # route: await run_in_threadpool(_write_and_journal, ...)
    st = _journal_state[dpid]                      # {lock, pending, failures, writes}
    if st.pending: raise ReplayPending             # -> 503
    with st.lock:
        if st.pending: raise ReplayPending
        client = topology.switches.get(dpid)       # 在鎖內查，看得到 readopt 的換 client
        written = client.write_table_entry(spec, op)   # 失敗就 raise -> 4xx/5xx，不記
        ok = journals[dpid].record(op, spec, key)      # fsync；不 raise，回 bool
        st.writes += 1; st.failures += (not ok)
    return written, ok
```

- 順序是「先寫交換機、再記 journal、最後才回應」。
- **insert 在中間當掉**：交換機上有，journal 沒有。重啟後被 push 清掉，規則就丟了。但 operator 沒拿到 200（連線斷了），本來就不知道結果。
- **modify／delete 在中間當掉**：交換機已經改了，journal 沒記。重啟後回到改之前的狀態，**delete 掉的規則會復活。**
  - 這是同一個契約：「沒確認過的寫入，重啟後的狀態未定義；確認過的一定在 journal 裡」。寫進 API 文件。
  - DEADLINE_EXCEEDED 但實際已經落地的情況（`p4_client.py:27-28`），處理見 §10-4。
- **為什麼不先寫 journal**：當掉的話，journal 裡會有一筆從沒裝上、甚至會被交換機拒絕的規則，違反 `rule_journal.py:135-136`。
- **為什麼要鎖**：`RuleJournal` 的鎖只包住 append。而 route 跑在 threadpool，兩個 POST 可能交錯成「A 寫 → B 寫 → B 記 → A 記」，journal 的順序就和交換機上的相反了。
- **代價**：同一台的 POST 會被串起來，每一筆多一次 gRPC 與一次 fsync【推論：毫秒級】。

### 5.4 重放：proxy 重啟（startup）

- 位置：`startup` 的 entries 迴圈裡（`main.py:2009-2020`），每台在 `apply_package_entries` 之後、PRE 之前。
- 條件：`i not in broken and not read_only`，而且 journal 開著。
- startup 期間 uvicorn 還沒開始服務：startup 在 lifespan 裡被 await（`main.py:2441-2443`），uvicorn 是在 lifespan 完成之後才服務（`:2469-2511`）。**所以這裡不需要 503**（修正 r1）。
- 步驟：
  1. **讀檔**：讀這台的 `s<dpid>.jsonl`，得到 header、紀錄與 unreadable 的行數。
  2. **cookie 判斷（Q1）**：在 push 之前，用 COOKIE_ONLY 讀交換機上的 cookie。
     - 和 header 的 `fabric_cookie` 相同：同一個 bmv2，繼續。
     - 新起的 bmv2 會回 FAILED_PRECONDITION「No forwarding pipeline config set」【A0 08】。這種情況，或 `has_cookie=False`，或 cookie 不同，都表示這是新的 fabric：整檔隔離，報 `fresh_fabric`，**不重放**。
     - 然後 push 的時候**一定**帶上 cookie：相符就沿用舊值，否則新鑄一個 u64。
       - 不帶 cookie 的 push 會把它清掉【A0 08】。⇒ `set_forwarding_pipeline_config` 的每一個呼叫點都要帶，包括 readopt。
  3. **sha 防護**：檢查 p4info 與 entries 的 sha（§5.2）。
  4. **折疊**：依 `key` 與檔案順序算淨效果。
     - 第一個 op 決定「API 之前在不在」：insert ⇒ 不在；modify／delete ⇒ 在，例如開機 entry 或 default。
     - 最後一個 op 決定「之後在不在」，以及最終的 spec。
     - 四種組合：
       - 不在 → 在：insert(最終 spec)
       - 在 → 在：modify(最終 spec)
       - 在 → 不在：delete
       - 不在 → 不在：什麼都不做
     - default entry 的 key 是 `"default"`，淨效果一律是 modify。
  5. **套用**：依 key 第一次出現的順序，逐筆呼叫 `write_table_entry`。
     - 這是直接呼叫，不經 `_write_and_journal`，所以**不會追加紀錄**；也不做 MODIFY fallback。
     - 失敗的那筆進 `failed`，附上理由，例如 bmv2 回的 UNKNOWN（`p4_client.py:1802-1804`）或 NOT_FOUND。
  6. **snapshot**：新檔＝header（新的 cookie 與 sha）＋成功重放的淨紀錄。
     - 失敗與 stale 的紀錄只留在隔離檔與報告裡，不進新檔。理由：它們不在交換機上，API 也刪不掉（§10-4 讓 NOT_FOUND 的 delete 也記，但記了也只是從折疊裡消掉）。
     - 每台一檔，所以不必替其他交換機保留紀錄。
  - **步驟 6 中途當掉**：hard link 做了、replace 還沒做時當掉，live 檔就是完整的舊 log。下次重新折疊一次，結果相同。

### 5.5 重放：readopt

`main.readopt_switch` 在呼叫 `topology.readopt_switch` **之前**：
- 設 `pending = True`，並拿這台的鎖；
- `pending` 的意思是「這台正在 readopt」，期間其他 POST 不等，直接回 503 `replay pending`。

拿著鎖依序做這些事：
- push 與換 client（`topology_manager.py:1503-1506`）；
- `apply_package_entries`（`main.py:1757`）；
- **從檔案重新讀一次**，做 §5.4 的步驟 3–6。readopt 的情況下跳過步驟 2 的 cookie 判斷：readopt 就是「同一個 fabric 上這一台剛 power-cycle」，push 時沿用 header 的 cookie。

做完才清掉 `pending`、放開鎖。

- 這把鎖蓋住了「換 client → 重放」之間的空窗（審查 M3）。
- 報告放進 `result["table_entries"]["replay"]`。
- 失敗的 readopt 也一定要清 `pending`：放在 `finally` 裡。
- 適用範圍：外來 pipeline 的分支（`:1754` 之後）。baseline 在 `:1743` 就 return 了。
  - Q2 (a) 底下 baseline 沒有能寫的表，所以不需要。
  - **Q2 若選 (b) 或 (c)，必須在 `:1743` 之前也補一次**（審查 M2.5）。

### 5.6 揭露

- **POST 回應**：`journaled: true|false`。
- **`switch_state.table_entries`**（`main.py:794-807`、`api_routes.py:762-767`）：
  - `journaled`：journal 開著、這台不是 read_only、而且這次開機 `failures == 0`。三個條件都要成立。
  - 新增 `journal: {"writes", "failures", "replay": <ReplayReport.as_dict()> + {"fresh_fabric", "stale_pipeline", "stale_entries", "skipped_reason"}}`。
- **T8** 讀的就是 `journaled`。
- **`TABLE_ENTRY_NOT_JOURNALED` 拆成兩個常數**，multicast 那一個（`api_routes.py:1130`）原文保留（Q5）。
- **`boot_identity` 的契約要改**。今天它說：`boot_id` 或 `table_generation` 一變，就「assume everything you installed on that switch is gone」（`boot_identity.py:27-33`）。
  - 重放之後，這句話對 API entry 不再成立。
  - Cut C 改 docstring：「除了 `table_entries.journal.replay` 列為已還原的那些」。
  - 會在自己重啟後重送規則的 app，要先讀 replay 報告。
  - 不然在 bmv2 上重複 insert 會拿到 **502 UNKNOWN**，不是 ALREADY_EXISTS（`p4_client.py:1802-1804`）。

### 5.7 external 與 owner；舊 replay

- **external**：寫入在 `_refuse_write` 就被擋（409），什麼都不記。startup 不重放、不寫 snapshot，檔案 byte 不動，報告寫 `skipped_reason: "external control plane"`。
- **owner**：
  - Q2 (a) 底下，owner ndtwin 的表除了 default，都會在 V7 被擋，journal 裡不會出現。
  - owner package 的表照常記、照常重放。
- **舊的 kernel-routing replay 這一刀不接**，§1.4 列的理由都還成立。API entry 不一樣的地方：
  1. 理由不是 proxy 算出來的，沒有「過期」這回事。
  2. 除了 journal，沒有任何東西能把它重算出來。
  3. 它有 cookie／sha 的世代管理。

## 6. 決定五：測試與 mutation gate

### 6.1 怎麼看紅

**原則**：每一條決策路徑都要有一顆，在今天的碼上**為了它自己的理由**紅；不能是因為撞到 501。

做不到的就分兩步：
- **A1**：先讓 builder 建出三種新型別，**不加 V 檢查**。這時檢查類測試的紅，是「wire 上出現了請求」，正是它要防的事。
- **A2**：再加檢查，測試轉綠。

此外每條檢查都配一個 mutant。

| # | 測什麼 | 紅的理由，以及在哪一步看紅 |
|---|---|---|
| R1–R3 | ternary／range／optional 建得出正確的 wire | 229ed30c：`TableEntryUnsupported`（`:1204-1208`） |
| R4 | V6：有 priority 欄的表，priority 缺漏或為 0 → 400，`stub.requests == []` | 229ed30c：用**空 match** 打 `t_ternary`／`flow_5tuple`，今天會送上 wire（§1.5） |
| R5 | V6：default 帶 priority → 400 | 229ed30c：今天建得出來、送得出去 |
| R6a | V5：lpm /0 → 400 | 229ed30c：`:1249` 允許 0 |
| R6b–e | V3、V4，V5 的遮罩 0、整段 range | A1：請求上了 wire |
| R6f | V1：arity，包括 optional 給兩個元素 | A1：上了 wire，或建出錯誤的形狀 |
| R6g | V2：三種新型別的值放不下 | A1：先在 A1 確認 `encode_value` 本身就會拒；若沒有拒（例如 mask 漏過編碼），就上了 wire |
| R7 | V8：EXACT 欄位省略 → 400 | 229ed30c：今天建得出來 |
| R7b | V9：LPM 有 host bit → 400 | 229ed30c：今天建得出來、送得出去（bmv2 會拒絕，【A0 09】） |
| R8 | `_built_entry_match` 的形狀等於讀取側 | **直接建一個 TableEntry**，再呼叫 `_built_entry_match`（229ed30c：ternary 欄位會被丟掉） |
| R9 | 讀取側讀得到 optional | 229ed30c：被丟掉 |
| R10 | route 200 ⇒ `journaled: true`，檔案多一行，key 是正規化過的 | 229ed30c：常數 false |
| R11 | stub raise ⇒ 沒有新行 | 只能用 mutant 看紅：M-J1 |
| R12 | Q4(a)：`record` 回 False ⇒ 200、`journaled: false`、`failures + 1`、`switch_state.journaled` 為 false | 229ed30c：恆為 false，所以這顆的紅要看 M-J12 |
| R12b | `switch_state.journaled` 的三個條件，各翻一個 | M-J13a–c |
| R13 | 折疊的四種結果，加上 default 規則，**每種各一顆**；另一顆混合：兩種寫法的 insert／delete；斷言 snapshot 的**內容**與重放送出的 op 序列 | M-J3、M-J14（把折疊改成回空） |
| R14 | **重啟之後還在**：一個會被 push 清空的有狀態假 stub；POST、重啟、斷言那筆在交換機上；**隔離檔 byte 等於重啟前的 journal** | M-J4（重放又追加）：靠隔離檔斷言殺；M-J15（重放什麼都不還原）：靠存在斷言殺 |
| R15 | sha 不符 ⇒ 不套用、計 `stale_pipeline`；entries sha 不符 ⇒ modify／delete 計 `stale_entries`、insert 照常 | M-J5、M-J16 |
| R16 | external ⇒ 不重放，檔案 byte 不變 | M-J6 |
| R17 | readopt：在 package entries 之後重放；readopt 兩次，計數一樣；**從檔案重讀**（startup 之後的 POST 也會被重放） | 229ed30c：readopt 不重放；M-J10、M-J17（改用 startup 時的清單） |
| R18 | pre-flight：PF-T 的 fixture 通過；缺 priority 的 ternary、`value & ~mask`，FAIL 的**新句子** | 229ed30c：句子是「G5 not done」，所以斷言新句子會紅 |
| R19 | V7：baseline 上空 match 打 `flow_5tuple` 與 `ipv4_lpm` 都是 409；owner ndtwin 表的 package default 仍裝得上（C） | 229ed30c：今天都是 200 |
| R20 | readopt 期間 POST 同一台 ⇒ 503，什麼都沒寫、什麼都沒記 | M-J18（拿掉 pending） |
| R21 | readopt A 的時候 POST B ⇒ B 的那一行在 A 做完 snapshot 之後還在 | M-J19（改回單檔加每台一把鎖） |
| R22 | 換完 client 之後、重放之前的 POST 會被擋 | M-J20（把鎖移到換 client 之後） |
| R23 | 剩下的 501：`UNSPECIFIED` 欄位 ⇒ 501，`stub.requests == []` | M-J21 |
| R24 | cookie：相符就重放；FAILED_PRECONDITION、沒有 cookie、或 cookie 不同 ⇒ `fresh_fabric`、隔離、不重放；push 一律帶 cookie | M-J22；M-J25（push 不帶 cookie）。假 stub 的行為照【A0 08】 |
| R25 | E1：交換機拒絕時，502 body 帶 `p4rt_error.code`（例如 NOT_FOUND） | 229ed30c：只有 `grpc_status: UNKNOWN`；M-J24 |

### 6.2 要退役或反轉的既有 gate

- `tests/shell/mutate_table_entry.sh` 要退役或反轉的 mutant【讀】：M-B6（`:244-247`）、RANGE 那個（`:282-283`）、M-B7／M-B14（`:333-339`）、M-B20（`:344-350`）。
- 錨點會搬進 `match_shape.py`、要重新錨定的：M-B1（`:205-209`）、M-B5（`:235-241`）、M-B16（`:275-279`）（§10-9）。
- 測試要改：
  - `test_ndt_app_package.sh:1001`；
  - `test_table_entry_route.py:343` 起的三顆 501 測試；
  - `tools/p4_exercise/tests/test_preflight.py:191-200`，以及 `:347` 起。
- 反轉的做法：同一個錨點改成新的行為，再加一個「改回舊行為」的 mutant，例如把 tuple 改回 `("EXACT","LPM")`，必須被 R1 抓到。

### 6.3 新的 mutation gate

分兩支：
- **Cut A 的** `mutate_table_entry.sh` 增補：
  - V1、V2、V3（M-J7）、V4；
  - V5，每一種寫法一個（遮罩 0、整段 range、lpm /0）；
  - V6 必須帶 priority；V6 的 default 分支（M-J8）；
  - V7；V7 的 default 例外；
  - V8、V9；
  - 讀取側 optional（M-J9）；
  - `table_honours_priority` 回到舊定義（§10-1）；
  - 501 路徑（M-J21）。
- **Cut B／C 的** `mutate_table_journal.sh`：
  - M-J1 先記 journal；
  - M-J2 拿掉鎖；
  - M-J3 用 spec 的寫法當 key；
  - M-J4 重放又追加；
  - M-J5、M-J16 拿掉 sha 檢查；
  - M-J6 external 也重放；
  - M-J10 readopt 的計數用累加；
  - M-J11 snapshot 原地覆寫（用 fault injection，舊檔必須完整）；
  - M-J12 `record` 失敗仍回 true；
  - M-J13a–c；
  - M-J14 折疊回空；
  - M-J15 重放什麼都不做；
  - M-J17 readopt 用舊清單；
  - M-J18 拿掉 503；
  - M-J19 改回單檔；
  - M-J20 鎖放在換 client 之後；
  - M-J22 拿掉 cookie 檢查；
  - M-J23 在鎖外查 client；
  - M-J24 502 不拆 per-update error（E1，放在 Cut A）；
  - M-J25 push 不帶 cookie。

兩支都要：
- 一個只改註解的負對照；
- baseline 保持 byte-identical；
- 0 survivor；
- `check_gate_anchors` 通過。

### 6.4 健檢格的預測（Cut A＋D 一起合併之後；T4–T7 另外要等健檢 Cut 2 的收集器）

| 格 | 預測 | 根據與風險 |
|---|---|---|
| T4 | GREEN | ⚠️ `priority_ok` 的 oracle 必須用 thrift 的 bm priority = 2147483647 − p 換算【A0 07】，否則會是假紅 |
| T5 | GREEN | 同 T4 |
| T6 | GREEN | ⚠️ thrift 把 optional 顯示成 `TERNARY v &&& ff`【A0 10】，oracle 要接受這種顯示 |
| T7 | GREEN（T4 綠才會跑） | 數字大的贏【A0 11，只在 stock 量到】。`order_ok` 必須比的是換算之後的 bm priority：bm 數字**小的**贏 |
| T8 | GREEN（static） | 需要 Cut B。重啟那一半這一刀只做離線證明（R14） |
| PF-T | GREEN（rc 0） | 合併之後，這一格**只會是 GREEN 或 PROBE-BROKEN**：它的 RED 路徑認的那句話被刪掉了（§1.7） |

## 7. 決定六：cut 計畫（行數都是【推論】估計）

| Cut | 內容 | 大小 | 驗收 | 依賴 |
|---|---|---|---|---|
| A0 | **已完成**（`ternary-a0/INDEX.txt`，11 項，stock 與 fast 相同）。還沒量的有兩項：`value & ~mask ≠ 0`，以及六個欄位全省略的 ternary entry。⇒ 兩項併進 Cut A 的第一步，用同一支 `ternary_a0.py` 補量 | — | 已填進本稿 | — |
| A＋D | **A**：`match_shape`；A1／A2 兩步；V1–V9；讀取側；`_built_entry_match`；錯誤碼；pre-flight 的 G5；退役與反轉（§6.2）；§6.3 的 Cut A 部分。**D**：和健檢那條線協調，同一個合併窗口：S0 的兩條 PF-T 檢查（`s0.py:275-277,574-583`）、`expected_today.tsv`、PF-T 格的 RED 路徑、T4–T7 oracle 的反轉。D 的那些檔案屬於健檢線 | A：程式約 350 行、測試約 500 行、gate 約 150 行；D：由健檢線估 | R1–R9、R18、R19、R23、R25 先紅後綠；Cut A 的 mutant 0 survivor；健檢 S0 COMPLETE | A0 |
| B | `TableEntryJournal`（record／fold／snapshot）、`_write_and_journal`、§5.6 的揭露、拆開常數 | 程式約 250 行、測試約 350 行 | R10–R13；M-J1–M-J3、M-J12–M-J14 | A（要用 key） |
| C | startup 與 readopt 的重放、cookie、sha、pending／503、`boot_identity` 的 docstring | 程式約 300 行、測試約 450 行 | R14–R17、R20–R22、R24；其餘的 M-J | B、A0（cookie） |

- 合計：程式約 900 行、測試約 1,300 行、gate 約 350 行。
- **A 不能單獨合併**：A 一合併，S0 就變成 PROBE-BROKEN（§1.7），所以 A 和 D 一起進。

## 8. 要 Adam 決定的

**Q1　怎麼分辨「warm fabric 上 proxy 重啟」和「全新的 fabric」？**

- 今天的 proxy 分不出來，但其實**可以分**，有好幾種訊號：
- **(a)【建議】pipeline cookie。**
  - 做法：push 的時候在 `ForwardingPipelineConfig.cookie` 寫入 fabric 世代號，也記進 journal 的 header；下次 push 之前先用 COOKIE_ONLY 讀回來比對（§5.4 步驟 2）。
  - 後果：
    - 只改 proxy，不用 shell、不用 manifest、不用 root；
    - 每台交換機各自判斷；
    - `ndt up` 與 `stack.sh` 這兩條 bring-up 路徑都涵蓋。
    - power-cycle 但還沒 readopt 的交換機，如果 proxy 正好這時重啟，它會回 FAILED_PRECONDITION，被當成新的 fabric：那台的 API entry 會被隔離、不重放，報 `fresh_fabric`。
    - 代價：每一次 push 都必須帶 cookie，因為不帶就會被清掉。
  - **前提已量到**【A0 08】：cookie 讀得回來；不帶 cookie 的 push 會清掉它；新起的 bmv2 在 push 之前回 FAILED_PRECONDITION，命令列給了 JSON 也一樣。
- **(b) 在 `p4_testbed_topo.py` 的 `bring_up` 裡鑄一個 `fabric_id`，寫進 switch manifest**（`:33,494-532,1309`）。
  - proxy 讀 manifest，比對 journal header。
  - 後果：
    - `stack.sh` 要求 operator 手動 `sudo python3 $script` 起 Mininet（`stack.sh:88-99,1040-1043`）。如果那支 script 就是 `p4_testbed_topo.py`【推論：`P4_TOPO_SCRIPT` 的定義沒讀到】，兩條路徑都涵蓋。
    - power helper 會在原地更新 manifest 的 pid（`tools/p4_power_helper.py:222,342`）。它會不會保留新加的頂層鍵【推論：它是載入後只改 entry】，要測。
    - 不是 Mininet 起的 fabric 沒有 manifest，要另訂規則。
    - **不能讓 root 寫 `.run/`**：那裡會產生 root 擁有的檔，proxy 就寫不進去了。所以只寫 manifest。
- **(c) `ndt up` 在起 bmv2 的那一步隔離 journal。**
  - 後果：
    - 需要改 shell；
    - **`stack.sh` 那條路不會隔離**，昨天的規則會在 sha 相符時被重放，也就是 (e) 的失敗模式。
    - r1 說「quarantine 第一次有呼叫點」不成立：shell 不會呼叫那個 Python 方法。
- **(d) 每筆記下 bmv2 的 pid。**
  - 後果：power-cycle 會換 pid；而 manifest 不存在的時候沒有可用的值。
- **(e) 不分世代，只看 sha。**
  - 後果：昨天的規則會被寫進今天的 fabric。**不建議。**
- 其他：

**Q2　generic writer 能不能寫 NDTwin 擁有的表？**

- **(a)【建議】不能。** 範圍：
  - baseline 綁定的交換機上的每一張表；
  - 加上 `roles.ipv4_route` owner ndtwin 的那張。
  - 都回 409 `owned_by_ndtwin`（V7，放在 `write_table_entry` 裡）。
  - 後果：
    - **修掉 §1.5 那個空 match 的 catch-all 缺陷**；
    - journal 和 kernel routing 永遠不在同一張表上；
    - ruling 8-1 延伸到 runtime。
  - 代價：
    - 今天打 baseline 的 `ipv4_lpm`、以及空 match 打 `flow_5tuple`，都回 200，之後變 409。這是行為變更。
    - `a_client` 是 baseline 的替身（§1.5），所以 `test_table_entry_route.py` 每一顆 POST `AN_LPM_ENTRY` 的成功路徑測試都會變 409。
    - `test_p4_client_writes.py` 的替身也會翻。
  - **子題 (a-i)【建議】保留 8-1 的 default-action 例外**：owner 為 ndtwin 的表上，default action 開機與 API 都可以寫。
    - 理由：NDTwin 的寫入者不寫 default【推論】，而 C 依賴它（§1.7）。
  - **子題 (a-ii) 不留例外。**
    - 後果：C 起來會 `failed = 1`，`main.py:1770` 的前提不再成立。
  - **子題 (a-iii) roles ticket「不准改既有測試 fixture」那條規矩**（`p4_client.py:255-257`），這一刀還適用嗎？
    - 若適用：那批測試只能改斷言、不能改 fixture，可是新的正確答案就是 409。⇒ 等於要改寫測試的意圖，必須你明說。
    - 建議：解除，只限這幾個替身，給它們加上明確的 `bind_routes`。
- **(b) 只擋 `flow_5tuple`。**
  - 後果：
    - **這也是行為變更**（空 match 今天是 200）。
    - `ipv4_lpm` 上的 API entry 會在下一次鏈路變化時被 `install_initial_routes` 改寫（MODIFY fallback，`p4_client.py:1903-1913`）。
    - 而且 baseline 的 readopt 要在 `main.py:1743` 之前補一次重放（§5.5）。
- **(c) 全部放行，只揭露。**
  - 後果：catch-all 缺陷留著；`insert_5tuple_rule` 的 fallback 會默默覆蓋 operator 的同 key entry（`:1800-1808`）；baseline readopt 一樣要補重放。
- 其他：

**Q3　don't-care 的第二種寫法（遮罩 0、整段 range、lpm /0）**

- **(a)【建議】400，訊息寫「omit the field」。**
  - 後果：
    - 一個 entry 只有一種 wire 形狀。**bmv2 自己就拒絕這三種寫法**，回 INVALID_ARGUMENT「omit match field instead…」，什麼都不存【A0 04、05】。
    - ⇒ 這條只是把 bmv2 的拒絕提前到本機：今天是 502 UNKNOWN（§1.8），之後是 400，而且訊息講得清楚。
    - **就現有證據來說，沒有任何既有檔案要改**：健檢 DESIGN 寫 int-v1 的 P4Runtime 形式本來就省略 don't-care 欄位、只留兩個 IP 欄位（`:829-831`），遮罩 `0x0000` 只出現在 thrift script（`:828`）【轉述】。
- **(b) 正規化成「省略」，用 `normalised: [...]` 揭露。**
  - 後果：NDTwin 會接受 **bmv2 自己拒絕的寫法**【A0 04、05】，也比 tutorials 自己的 controller 更寬鬆：那支 controller 會把遮罩 0 原樣送出，然後被 bmv2 拒絕【推論，依 A0 05】。這和 ruling 23② 擔心的方向相反。
- 其他：

**Q4　journal 寫失敗（例如磁碟滿）時，回應怎麼辦？**

- **(a)【建議】200，`journaled: false`，加 note，`failures + 1`；這台在本次開機剩下的時間裡，`switch_state.journaled` 都是 false。**
  - 後果：
    - 規則確實在交換機上，回應是實話。
    - 但缺了一行可能讓之後的折疊判斷錯。例子：insert 沒記到，接著 delete 與重新 insert 都記到了。折疊會把 delete 當成「本來就在」，於是重放成 modify，然後 NOT_FOUND 失敗。
    - 失敗會出現在 replay 報告裡，但那一筆就丟了。
- **(b) rollback，回 507。**
  - 後果：**只有 insert 做得到。**
    - rollback modify 需要先前的 spec，proxy 從沒讀過；
    - rollback delete 需要 action，而 delete 可以不帶 action（`p4_client.py:1356-1359`）。
    - ⇒ 三種 op 裡有兩種做不到，**不可行**。
- 其他：

**Q5　multicast／PRE 的 API 寫入要不要一起 journal？**

- **(a)【建議】這一刀不做**，保留 `api_routes.py:1130` 的原文。
  - 後果：範圍不擴大，健檢格也不需要它。
- **(b) 一起做。**
  - 後果：**沒有比 table entry 簡單。**
    - `write_multicast_group` 會從 INSERT 落回 MODIFY（`p4_client.py:932-946,1026-1046`）；
    - 開機時 package 的 PRE 每台都套（`main.py:2024-2048`）。
    - ⇒ 重放的 group 會默默蓋掉 package 裡同 id 的 group，正是本稿要擋的 replace-vs-add。
    - 要先拿掉那個 fallback，或者把 package 的 group id 從 API 可用的範圍排除。
    - 再加約 150 行。
- 其他：

## 9. 讀了什麼、沒讀什麼

**讀了**（r1 讀過的之外，r2 另外讀的）：
- `p4_client.py:20-32,250-262,693-760,1353-1360,1842-1852,1903-1913`
- `topology_manager.py:1366-1380,1490-1512`
- `api_routes.py:650-695`
- `main.py:1743-1772,2024-2030,2436-2480`
- `rule_install_times.py:70-130`
- `preflight.py:210-216,500-517`
- `s0.py:45-53,120-135,570-600`
- `runtime/s1-runtime.json:18-26`
- `test_table_entry_route.py:155-206`
- `stack.sh:86-100,1038-1045`
- `p4_power_helper.py:120-136,335-345`
- 審查稿 `judge-ternary-design-521a95d1-r1.md`

**觀測了**：`gates-0910/ternary-design/` 底下的四份 log；proxy venv 裡 `google.rpc.status_pb2` 可以 import。

**A0（別人執行的）**：讀了 `ternary-a0/INDEX.txt`、`stock/01-delete-wrong-priority.txt`、`stock/10-byte-forms.txt` 的 optional 段，以及 `ternary_a0.py:150-156`。其餘各項只引用 INDEX 的逐項摘要。

**沒讀**：
- P4Runtime spec；
- PI 原始碼；
- `ndt up_p4`；
- `P4_TOPO_SCRIPT` 的定義。

**已知、這一刀不處理的分歧**：pre-flight 的 `encoded_width` 對 exact／lpm 比 writer 寬鬆（IPv6、任意字串）。

## 10. 留到實作時處理（定案，不再討論）

1. **`table_honours_priority` 改定義**：「有任何欄位是 TERNARY、RANGE 或 OPTIONAL」，不再寫成「不在 `BUILDABLE_MATCH_TYPES`」（`p4_client.py:1144-1145`）。否則 tuple 一長大，它就會回 False。另配一個 mutant。
2. **`entry_key`**：
   - 補明確的 optional 分支；
   - default entry 另造 key（§3.1）；
   - 寫一顆測試斷言「default」與「全省略的 LPM」是兩個 key。
3. **`TableEntryJournal.replay` 自己寫。** `attempted` 是淨 op 的數量，不是原始行數。
4. **沒被確認的 delete／modify**：
   - 回 NOT_FOUND 的 delete 照樣回 502，**但會記成 `outcome: not_found`**。它在折疊裡只會讓那個 key「不在」，所以是安全的。
   - 用來處理 DEADLINE_EXCEEDED 但實際已落地、重試又拿到 NOT_FOUND 的情況（`p4_client.py:27-28`）。
   - modify 沒有對應的安全做法，寫進 API 文件。
5. **Q4(a) 的缺行風險**：寫進回應的 note 與 API 文件（Q4 的後果）。
6. **LPM host bit**：定為拒絕（V9）。bmv2 自己也拒絕【A0 09】。
7. **`PRIORITY_MAX`**：定為 2^31-1。整段 int32 都 OK、沒有 abort；-1 被拒（UNKNOWN）【A0 07】。V6 的下限 1 已經擋住 -1。
8. **pre-flight 與 writer 對齊**：
   - 「空 match、有 priority 欄」的 entry 放行（§4）；
   - V8 進 `match_shape`，pre-flight 也查。
9. **錨點**：
   - §6.2 的那幾個 mutant 要重新錨定；
   - `mutate_rule_journal_is_wired.sh` 的 m6／m7（`rule_journal.py`）與 n2／n3（`main.py` 的 `base_dir` 那一行）：新程式碼**不准複製那幾行**，免得錨點不再唯一。一律用新的 helper 名稱。
10. **耐久性**：`os.replace` 之後、以及第一次建檔之後，fsync 目錄。
11. **保留期**：每台的隔離檔只留最近 N 份（建議 10），多的刪掉。刪除也寫進 log。
12. **先 hard link，再 replace**：三處文字已經統一（§3.2-3、§5.2、§5.4）。
13. **liveness 的註解與 A0 08 不一致**：`topology_manager.py:1373-1375` 說 bmv2 沒有 pipeline 時也會回 COOKIE_ONLY，A0 08 量到的是 FAILED_PRECONDITION。
    - ⇒ power-on 之後、readopt 之前，`probe` 應該是 `ok: False`。
    - 這一刀不改：它影響的是 liveness 判斷，不在這一刀範圍內。這裡記下來，交給 auditor 另開一張單。
14. **`delete_5tuple_rule` 的 docstring**（`p4_client.py:1847-1850`）改成量到的行為：priority 錯 ⇒ NOT_FOUND ⇒ 回 False【A0 01】。Cut A 順手改，只改註解。

## 11. r1 → r2 對照（審查 `judge-ternary-design-521a95d1-r1.md`）

**MAJOR**

| 審查項 | 處理位置 |
|---|---|
| M1 Q1：前提錯、漏了選項、(a) 說過頭 | Q1 改寫：加入 cookie 選項 (a) 與 `p4_testbed_topo` hook (b)；(c) 寫明 stack.sh 的漏洞，並撤回「第一次有呼叫點」；§5.4 步驟 2 |
| M2.1 `flow_5tuple` 的事實 | §1.5（列為現存缺陷）、§1.1、§0 |
| M2.2 8-1 的 default 例外 | Q2 (a-i)／(a-ii)、§2.2 V7 |
| M2.3 V7 放哪裡 | §2.2 V7（定案：`write_table_entry`）、§4、對 C 的影響 |
| M2.4 fixture 的成本與 ticket 規矩 | §1.5、Q2 的代價、Q2 (a-iii) |
| M2.5 (b) 需要 readopt 重放 | §5.5、Q2 (b)／(c) |
| M3 並行：每台一檔 | §5.2 |
| M3 鎖與 threadpool callable，鎖內查 client | §5.3 |
| M3 readopt 的鎖與 503 窗口、重新讀檔 | §5.5 |
| M3 startup 不需要 503 | §5.4 |
| M3 snapshot 保留其他交換機的紀錄 | 每台一檔，所以不需要（§5.4 步驟 6） |
| M4 每條路徑自己的紅 | §6.1 原則、A1／A2 兩步、R4 用空 match 路徑 |
| M4 補 mutant | §6.3 |
| M4 折疊每種結果 | R13 |
| M4 重啟後還在 | R14 |
| M4 M-J4 怎麼殺 | R14 的隔離檔斷言、§3.2-1 |
| M4 Q4／journaled | R12、R12b |
| M4 兩種並行危險 | R20–R22 |
| M4 剩下的 501 | R23 |
| M4 R18 是 vacuous green | 改成斷言新句子 |

**MINOR（要先改才能送表單）**

| 審查項 | 處理位置 |
|---|---|
| Q3 的代價與 (b) 的說法 | Q3 |
| Q4(b) 不可行 | Q4 |
| Q5(b) 的危險 | Q5 |
| S0 有兩條檢查，A 要和 D 一起合 | §1.7、§6.4、§7 |
| `boot_identity` 的契約 | §5.6 |
| sha 防護與 entries 檔 | §5.2、R15 |
| 證據標籤 | 開頭的等級說明；§1.6 每一列對到 log，或對到【A0 NN】；凡沒有證據支撐的都改成【推論】（§1.5、§2.1、§3.1、Q3） |
| A0 結果併入（r2 中途） | 開頭、§1.5、§1.6、新增 §1.8、§2.1、§2.2（PRIORITY_MAX、V9、E1）、§3.1、§5.4 步驟 2、R7b、R24、R25、§6.4、§7、Q1、Q3、§10-6／7／13／14 |

**MINOR（可以等到實作）**：全部收進 §10 的第 1–12 條。

**自相矛盾**

| 審查列出的矛盾 | 處理位置 |
|---|---|
| ① M-J7–M-J9 放錯 cut | 搬到 Cut A（§6.3、§7） |
| ② A 能不能單獨合併 | §7：不能 |
| ③ 改名還是 hard link | §3.2-3、§10-12 |
| ④ readopt 沒有讀檔 | §5.5：重新讀 |
| ⑤ 哪些選項要補 readopt 重放 | §5.5：(b)、(c) 都要 |
| ⑥ 防線到底是什麼 | §0、§3.2-1：折疊＋snapshot |
| ⑦ 兩種寫法 | §2.1：改成「錯誤訊息只有一套」 |
| ⑧ 「priority 0 今天走不到」 | §1.1、§1.5 |

**另外**：r1 對 `insert_ipv4_route` 的行號引用錯了，改成 `:1903-1913`（§1.1）。
