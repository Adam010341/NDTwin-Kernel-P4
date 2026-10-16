# P4 register 讀取走 bmv2 thrift：設計

[Co-developed with claude code -- Adam]

- **分支**：`feat/p4-register-thrift`，從 `feat/p4-register-read` 的 `3bd635ce` 開。
- **為什麼走 thrift**：Adam 2026-10-16 裁的（DESIGN.md §5 的選項 (a)）。
  - bmv2 的 P4Runtime 對每一種 RegisterEntry 讀取都回 `UNIMPLEMENTED`（DESIGN.md §1）。
  - 裝在這台的 PI 各層都沒有 register（DESIGN.md §5.2）。
- **LOG**＝`scratch/overnight-2026-09-05/logs/gates-0910/p4-register-read/`。
- 本文先寫設計與動手前的量測（§0），再寫程式。

## 0. 動手前量的：thrift 的 register 讀取會不會讓 P4Runtime 的讀取失同步（OBSERVED）

- 起因：C1 的 worker 看到，bmv2 的 CLI 做過任何一個**寫入**之後，對那台交換機的 P4Runtime Read 會失敗：`INTERNAL: Table state out-of-sync with target`，兩個 build 都一樣。這裡問的是**讀**。
- 腳本：LOG`/syncprobe.py`。結果：LOG`/syncprobe.json`（header：commit `3bd635ce`，dirty 0）。執行紀錄：LOG`/r3B_syncprobe.out` `rc=0`，拿著 lock 跑。
- 做法：拋棄式交換機，stock 與 fast 各一顆（`throwaway.py` 的規則）。
  - hc_main 用 P4Runtime 推上去，寫一筆 t_dcount；pcap 送 1 個 R2 marker（`r_mark[0] := 4737`）、5 個 K2 marker。
  - 每一步之後跑同一組 P4Runtime 讀取：TableEntry（帶 counter_data）讀 t_dcount、DirectCounterEntry 萬用字元讀 dc_k2、CounterEntry 讀 c_in[0]。
- 結果，兩顆一樣：

| 步驟 | P4Runtime 那組讀取 |
|---|---|
| 1 什麼都不做（基準） | 全部成功（t_dcount 335 B／5 pkt） |
| 2 開一條 thrift 連線再關掉 | 全部成功 |
| 3 thrift `bm_register_read(r_mark, 0)` 與 `bm_register_read_all(r_mark)`（生成碼的 client，就是路由會做的讀取） | 全部成功；讀到 4737 與 `[4737, 0, …]` |
| 4 CLI `register_read`（一格、整個陣列） | 全部成功 |
| 5 CLI `register_write r_mark 1 48879`（register 的**寫**） | 全部成功 |
| 6 CLI `counter_read dc_k2 0`（讀一張表的資源） | 全部成功 |
| 7 **陽性對照**：CLI `table_add t_dcount … 40013` | TableEntry 讀取 `INTERNAL: Table state out-of-sync with target`；DirectCounterEntry 與 CounterEntry 讀取仍成功 |

- ⇒ **thrift 的 register 讀取不會讓 P4Runtime 的讀取失同步**，兩個 build 都一樣。所以照原計畫做。
  - 失同步只在表的寫入之後出現（陽性對照重現了 C1 看到的）；register 的寫入也沒有引起。
- 順帶看到：步驟 7 之後，DirectCounterEntry 的萬用字元讀取**沒有報錯**，而且兩筆都列出來了：P4Runtime 寫的那筆（335 B／5 pkt），與 CLI 剛加的 dport 40013 那筆（`data { }`）。
  - ⇒ 有人用 CLI 寫過表之後，`GET /p4/direct_counter` 照常回答（含 CLI 的 entry），而 `read_table_entries`（`/stats/flow`）會失敗。
  - 這是 bmv2／PI 的行為，記下來；這次不改。

## 1. 路由

```
GET /p4/register/{name}?dpid=<n>                    整個陣列
GET /p4/register/{name}?dpid=<n>&index=<i>          一格
GET /p4/register/{name}?dpid=<n>&start=<s>&count=<c> 一段
```

- 與 `/p4/counter/{name}`、`/p4/direct_counter/{name}` 並排：名字是 path 參數，全名或 alias 都收，`dpid` 是 query。
- 回應一律同一個形狀；一格也是長度 1 的 `values`：

```json
{"dpid": 2, "register": "HcIngress.r_mark", "bitwidth": 32, "size": 16, "start": 0,
 "values": [4737], "source": "bmv2-thrift"}
```

- 值是 bit<W> 的值，W 最多 63（第二輪改，§12.2）。
  - 第一輪寫的是「bit<64> 的全 1 會變成 −1，用遮罩還原」。那是推論，量了以後是錯的：bmv2 的 thrift 對 2^63 以上的 bit<64> 格一律回 2^63 − 1（飽和），兩個 build 都一樣。
  - 所以 bit<64> 以上回 501；W < 64 時，值不在 [0, 2^W) 就是程式與 p4info 不一致 → 502，不截斷。
- `register` 永遠是全名。thrift 用的名字就是 p4info 的 `preamble.name`。
  - 在 hc_main 上兩者一樣（`HcIngress.r_mark`，§0 的量測就是用這個名字讀的）。
  - 對不上時，bmv2 回 `INVALID_REGISTER_NAME` → 502。

## 2. 怎麼找到一台交換機的 thrift 埠

- 照 proxy 找 gRPC 埠的同一個規則：`main.build_p4_client` 用 `GRPC_PORT_BASE + dpid` 撥 gRPC；thrift 用 `grpc_ports.thrift_port(dpid)`（9090＋dpid）。
  - `p4_testbed_topo.py` 起交換機時就是這樣給的（`thrift_port=grpc_ports.thrift_port(dpid)`），而兩個數字的出處是同一個檔。
- 存在 client 上：`build_p4_client` 設 `client.thrift_port`。
  - readopt 用同一個 factory，所以重新收編的交換機也有。
  - trial 用拋棄式交換機的隨機埠，直接設這個屬性。
  - 沒有這個屬性的 client（例如測試裡手做的）→ 503 `no thrift port`。
- **不讀** `/tmp/ndtwin_p4_switches.json`（switch manifest）：
  - 它是 topo 以 root 寫的；它的 owner 檢查是給 `ndtwin-p4-power` 用的。
  - proxy 的 gRPC 埠本來就不從它來。兩條規則並存，就會有兩個不一樣的答案。
- host 是 `127.0.0.1`：fabric 的交換機與 proxy 在同一台，gRPC 也是 `localhost`。

## 3. 用哪一個 thrift client

- 結論：**proxy 自己寫一個只有兩個呼叫的 client**（`p4_proxy/proxy_agent/bm_thrift.py`），只依賴 venv 已經釘的 `thrift==0.24.0`。
- bmv2 生成的 `bm_runtime` 在這台**有**，但不用它：
  - 它在 `/home/adam/p4dev-python-venv/lib/python3.13/site-packages/bm_runtime/`，是另一個 venv 的。
  - `p4_proxy/requirements.txt` 記了那個 venv 的直譯器版本與 site-packages 對不上的陷阱。
  - proxy 要 import 它，就得把另一個 venv 的路徑塞進 `sys.path`；lab 機器上的配置未必一樣。
  - 把它整包複製進來是 18 000 行生成碼（`Standard.py` 15 715 行＋`ttypes.py` 2 829 行），只為了兩個呼叫。
- `tools/p4_health/runtime_cli.py` 不是讀取器（它把 runtime JSON 翻成寫入指令）。健檢的讀取器 `collect/thrift.py` 起的是 `simple_switch_CLI` 子行程：一個請求一個行程，不適合放在 proxy 的路由上。
- 兩個呼叫的線上格式照生成碼逐欄寫出（TBinaryProtocol、以 `standard` 這個 service 名 multiplex，與 `bmpy_utils.thrift_connect` 一樣）：
  - `i64 bm_register_read(1: i32 cxt_id, 2: string register_array_name, 3: i32 idx)`
  - `list<i64> bm_register_read_all(1: i32 cxt_id, 2: string register_array_name)`
  - 兩個都 `throws (1: InvalidRegisterOperation ouch)`，`{1: i32 code}`：1 名字、2 index、3 其他。
- 送出去的 bytes 與生成碼的 client **逐 byte 相同**：LOG`/r3B-evidence/wire_bytes_vs_generated.log`。這兩串 bytes 也寫進了單元測試。
- 只有讀，沒有寫。

## 4. deadline 與 thread

- 每次讀取開一條自己的連線、做一個呼叫、關掉。不同 thread 之間不共用連線。
- deadline＝`RPC_TIMEOUT_S`（5 s），**整次呼叫共用一個預算**（第二輪改，§12.5）：連線、送出與每一次 receive 都只拿剩下的時間。
  - 第一輪是每一步各 5 s，一台每 4.9 s 吐一個 byte 的對端可以把一條 worker 拖住很久。
- 路由是 `async def`，thrift 呼叫用 `run_in_threadpool` 放到 worker thread，與 direct counter 路由同一條規則；有 thread identity 的測試與拿掉它的 mutation。

## 5. external 模式

- 可以讀。thrift 讀取不需要 mastership，與 P4Runtime 的 Read 一樣。
- 它也不碰 P4Runtime 記的表狀態（§0），所以不會打擾 exercise 自己的 controller。

## 6. 錯誤

| 碼 | error | 什麼時候 | 有沒有問交換機 |
|---|---|---|---|
| 200 | | 讀到了；0 就是 0 | 有 |
| 400 | `index out of range` | index、`start` 或一段超過 p4info 的 `size`（帶 `size`） | 沒有 |
| 400 | `invalid range` | 負的、空的、`index` 與 `start`／`count` 一起給 | 沒有 |
| 404 | `unknown switch` | dpid 不認得 | 沒有 |
| 404 | `not in this pipeline` | 不是這台 p4info 的 register | 沒有 |
| 413 | `too many cells` | 超過 `REGISTER_CELLS_MAX`（4096）；或陣列大於 `REGISTER_READ_ALL_MAX`（65536）卻要一段 | 沒有 |
| 501 | `register too wide`／`register type not readable` | bit<64> 以上；不是 bit<W>（含 int<W>） | 沒有 |
| 502 | `thrift device mismatch` | thrift 埠上的是另一台（bm_mgmt_get_info 的 device id 或 port 不對）；不讀 register | 只問了身分 |
| 502 | `register refused` | bmv2 回 `InvalidRegisterOperation`（帶 `code`） | 有 |
| 502 | `register answer invalid` | 回的不是這些呼叫的答案（application exception、沒有結果、型別不對、格數不對、整個陣列的長度與 p4info 的 `size` 不同、值超出 bit<W>） | 有 |
| 502 | `register answer not understood` | 回的 bytes 根本不是 thrift（版本不對、名字不是 UTF-8、長度是負的或超限、值放不進去） | 有 |
| 503 | `register not read` | 連不上、斷了、超時。**明說不是 0** | 有（或試過） |
| 503 | `thrift not installed` | proxy 的直譯器沒有 `thrift`；proxy 其他部分照常 | 沒有 |
| 503 | `replay pending` | 正在 readopt（推 pipeline 會把 register 歸零）；只在讀之前查一次，同 DESIGN.md §2.2 的窗 | 沒有 |
| 503 | `no thrift port` | client 沒有 thrift 埠 | 沒有 |
| 503 | `no topology` | proxy 還沒有 topology | 沒有 |

- index 範圍在問交換機之前就用 p4info 的 `size` 擋掉。bmv2 的 `INVALID_INDEX` 因此只會在 p4info 與程式不一致時出現，所以是 502。

## 7. 大陣列

- 一個請求最多 `REGISTER_CELLS_MAX`＝4096 格。
- 一格用 `bm_register_read`；多格用一次 `bm_register_read_all` 再切片。
  - 陣列大於 `REGISTER_READ_ALL_MAX`＝65536 格（512 KiB）時，不整包拿，只准一格一格讀（`index`）。
- 不帶參數＝整個陣列，所以陣列大於 4096 格時要帶 `start`／`count`，否則 413。
- 數字是設計上的取捨，沒有量過：HashPipe 的陣列多大、`read_all` 在 65536 格時要多久，都留給以後。

## 8. 怎麼標明「只有 bmv2」

- 每個 200 都帶 `source: "bmv2-thrift"`；502／503 的 thrift 錯誤也帶。
- 路由的 docstring（也就是 openapi 的說明）第一段就寫「BMV2 ONLY, THROUGH ITS THRIFT SERVICE」。
- 硬體 target 沒有 thrift：連不上 → 503 `register not read`。

## 9. 🔴 R2 的 oracle 換掉

- 今天 R2 的 oracle 就是 thrift：`observe_a.observe_r2` 讀 `register_read HcIngress.r_mark 0`。
- 路由也走 thrift 之後，R2 就是 thrift 比 thrift：
  - 路由讀錯 index、讀錯名字會被抓到；
  - 但「thrift 讀出來的不是資料面寫進去的」這種錯，兩邊一起錯，抓不到。
- **新的 oracle：marker 自己帶的值** `R2_CHOSEN`（`round_a.py:39`，0x1234＋0x4D＝4737）。
  - 程式做 `r_mark.write(0, (bit<32>)hdr.udp.srcPort)`，marker 的 sport 就是這個值。
  - 這個數字是 probe 自己選、自己送的，不經過 thrift，也不經過 NDTwin。
- thrift 的 `register_read` 不丟，留在 **SC-reg**（本來就在）：它檢查 marker 真的把 `chosen` 寫進去了，是 probe 對自己儀器的檢查。
  - SC-reg 失敗時 R2 不會是 GREEN。
  - 🔴 第一輪這裡寫「不會變成 NDTwin 的紅」，那不對（第二輪更正）：cannot 那一步（沒有路由、404、501）在 gate 與 self-check **之前**就判（verdict.py 的順序），所以 SC-reg 失敗時 R2 仍可以是紅。
  - 因此紅的歸因要看 thrift 有沒有真的讀到：第二輪起 observation 的 `oracle.thrift` 是 register_read 印出的值（讀不到是 None），R2 的紅只有在它不是 None 時才宣稱 thrift 證據（`cells/table.r2_thrift_ev`）。這是 K1 的規則：K1 的 `thrift_ev` 要 thrift 的 counter_read 有回答。
- observer 的改法：
  - openapi 有 `GET /p4/register/...` 時，`answer` 改成真的去讀 `GET /p4/register/HcIngress.r_mark?dpid=2&index=0`（`collect/proxy.py` 加 `register()`）；
  - `oracle` 改成 `{"value": chosen, "thrift": register_read 的值}`（`thrift` 是第二輪加的，只用來歸因）；
  - `cells/table.py` 的 R2：紅的理由改成「NDTwin read X, the marker wrote Y」；cannot 另外把 404／501 判成結構性的紅（同 K1 的 `k1_cannot`）。
  - 🔴 **設計規則改了（第二輪）**：路由回答了但沒有值（502、503）→ **紅**，「answered 503, which is not a reading」，與 K1 的 503 一樣。
    - 第一輪是 NOT RUN（`need` 要 `a:value`），那樣一條每次都 503 的路由會讓 R2 永遠判不了。
    - 現在 R2 的 `need` 是 `a:http`（同 K1）：完全沒有回答（`http` 是 None）才是 NOT RUN。
- 🔴 **R3 要一起改**（DESIGN.md §3 寫過）：
  - `route_answer` 只看路徑前綴。一加上 `GET /p4/register/{name}`，R3（寫）就會以為有寫的路由。
  - 改法：`observe.ROUTE_METHODS` 讓 R2 只認 GET、R3 只認 POST／PUT／PATCH。openapi 本來就給 method（`collect/proxy.openapi_paths` 回 `{path: methods}`）。
- **預期檔（第二輪改）**：第一輪沒有改，理由是「要 live 的 health.json」。那與工具自己的規則矛盾（`expected.py:5-8`：翻格子的修正在同一個 PR 改預期檔），也與先例不符（`expected_today.tsv:6-7`：T4–T7、PF-T、T8 都是用離線的拋棄式 bmv2 翻的）。
  - 第二輪照那個先例把 R2 翻成 GREEN，basis 寫「C2 thrift cut: observed offline …」，並在檔頭加一行說明。
  - 假 fabric 加了 `proxy_reads_registers` 這個開關（預設是今天的行為，與 Cut A + D、Cut C 的開關一樣），開著時假 openapi 有 `/p4/register/{name}`，`GET /p4/register/...` 由假 s2 的 r_mark 回答；`test_bring_up_a_reads_as_predicted` 因此檢查的是新的預測。
- 改到的 tools/p4_health 檔：`collect/proxy.py`、`observe.py`、`observe_a.py`、`cells/table.py`。
  - 它們的測試：第一輪只在 `tests/python/test_p4_health_collect.py`（`TestTheRegisterReadAgainstTheMarker`）；`test_p4_health_cells.py` 是第二輪才改的（R2 的 fixture 與 `test_r2s_red_claims_thrift_only_when_thrift_read_the_cell`）。第一輪本段說兩個檔都有，是錯的。
  - `check_gate_anchors.py` 掃 `mutate_p4_health.sh` 的錨點。4-shard 的健檢 gate 不在本工單。

## 10. 測試與 gate

- `p4_proxy/tests/test_bm_thrift.py`：線上 bytes（與生成碼一致）、各種回答的解碼、真的 socket 上的 deadline。
- `p4_proxy/tests/test_register_route.py`：§6 每一列、thread、external、路由只註冊 GET。
- mutation gate：`tests/shell/mutate_p4_register_thrift.sh`（新）。
- 離線 bmv2 trial（stock 與 fast）：
  - 資料面寫值：R2 marker 寫 4737；
  - 經真的路由讀回，與 marker 的值比；
  - 在讀之前與之後跑 P4Runtime 的讀取，看會不會失同步。
- p4lane：在拋棄式 clone 上、拿著 lock 跑。

## 11. 跑了什麼（OBSERVED；第一輪）

- 🔴 第一輪的標題寫「都在最後一個程式碼 commit `503eb109`」，不完全對（第二輪更正）：
  - 下表的 gate、健檢測試、trial 與 p4lane 在 `503eb109`；
  - sync probe 在 `3bd635ce`；`test_bm_thrift.py` 的那次在 `8407076d`（那個檔之後沒有改）；線上 bytes 的比對是在草稿上做的（草稿的線上部分與 commit 的相同）；
  - 寫草稿時有幾次輕量的測試沒有拿 lock；sync probe 第一次（`r3B_syncprobe.try1.out`）因為 PYTHONPATH 蓋掉 `google.protobuf` 而 rc=1，修好路徑後重跑才是 `r3B_syncprobe.out`。
- 拿 lock 跑的步驟，guard.sh 都在 lock 裡面跑。log 在 LOG 底下，每份第 2 行記了 commit 與 dirty 計數。
- 先看紅：
  - proxy 的三個測試檔放在沒有這個功能的程式碼上（`r3B_unit_red_*.log`）：`test_register_route`／`test_bm_thrift` 因為 `bm_thrift` 不存在而在 import 時就失敗；`test_app_package_proxy` 的新測試 `AttributeError: … no attribute 'thrift_port'`。
    - 這些紅的理由是「功能不存在」，不是各測試自己的理由；各測試自己的紅由 gate 的 47 個 mutation 證明。
  - 健檢的 8 個新測試放在沒有改的 tools/p4_health 上（`r3B_health_red.log`）：5 failures、2 errors。綠的那個是 `test_without_the_read_route_r2_is_no_route_and_nothing_is_asked`，它守的是不變的行為。
- 🔴 gate 抓到一個測試的漏洞：第一次跑 `mutate_p4_register_thrift.sh`（在 `8407076d`，`r3B_gate_reg.at-8407076d.out`）時，「拿掉 cell 上限」的 mutation 存活了。
  - 原因：上限的測試用的是一個大於「整包拿」上限的陣列，被另一條規則擋下，看不出 cell 上限不見了。
  - `503eb109` 把測試換成一個 8192 格（可以整包拿）的陣列。
- 結果：

| 檢查 | log | 結果 |
|---|---|---|
| `mutate_p4_register_thrift.sh` | `r3B_gate_reg.out` | `47 mutations, 0 survived` |
| `mutate_p4_direct_counter.sh` | `r3B_gate_dc.out` | `33 mutations, 0 survived` |
| `mutate_telemetry_by_name.sh` | `r3B_gate_tbn.out` | `23 mutations, 0 survived` |
| `mutate_p4_priority_refusal.sh` | `r3B_gate_ppr.out` | `9 mutations, 0 survived` |
| `mutate_table_entry.sh` | `r3B_gate_te.out` | `79 mutations, 0 survived` |
| `mutate_table_entry_owner.sh` | `r3B_gate_teo.out` | `27 mutations, 0 survived` |
| `mutate_table_journal.sh` | `r3B_gate_tj.out` | `193 mutations, 0 survived` |
| `check_gate_anchors.py HEAD` | `r3B_anchors.out` | `139/139 cells ok`（多了本 gate 一格） |
| 健檢的測試 | `r3B_health_tests.out` | cells `Ran 203 … OK`；collect `Ran 200 … OK` |
| `test_bm_thrift.py`（綁本機的臨時埠） | `r3B_unit_bmthrift.out`（在 `8407076d`；這個檔之後沒有改） | `Ran 14 … OK` |
| p4lane（拋棄式 clone，`mkclone.sh`，跑完刪掉） | `r3B_p4lane.out` | `FAILURES=0`；跑之前 :8081 是空的（`r3B_p4lane.ss-before.txt`） |

- bmv2 trial：LOG`/trial-reg.json`（腳本 `trial_reg.py`），兩顆一樣：
  - 讀之前：`r_mark[0]` 0、整個陣列 16 個 0；index 16 → 400 `index out of range`。
  - marker 寫完之後：`r_mark[0]` → `[4737]`，整個陣列 `[4737, 0, …]`，`start 0 count 2` → `[4737, 0]`，alias `r_mark` 一樣；每次讀 1–4 ms。
  - P4Runtime 的讀取（`read_table_entries`、`GET /p4/direct_counter`）在 thrift 讀之前、之後、健檢 observer 之後、SIGCONT 之後都成功。
  - 健檢的 `observe_r2` 原封不動地跑：R2 **GREEN**，「NDTwin's register read equals the value the marker wrote」；oracle `{"value": 4737}`；SC-reg `{"chosen": 4737, "register": 4737}` 通過；openapi 裡 `/p4/register` 只有 GET。
    - R2 的 gate（PL1、T1、TP1）在拋棄式交換機上是手動設成 GREEN 的，不是量出來的。
  - 交換機 SIGSTOP 時（只對自己起的 pid）：5.0 s 回 503 `register not read`。
- 沒有驗的：live lab；硬體 target；一台慢慢吐 byte 的交換機（socket timeout 是每一步 5 s，不是整次）；大陣列的延遲；bit<64> 的值在真的 bmv2 上（只有單元測試）。

## 12. 第二輪

### 12.1 量測（OBSERVED，在 `f7ef3fa0`，動手改之前）

- 腳本：LOG`/r4probe.py`；結果：LOG`/r4probe0.json`（header：commit `f7ef3fa0`，dirty 0）；執行紀錄：LOG`/r4_probe0.out` rc=0，拿著 lock。
- 程式：LOG`/r4-p4/reg64.p4`（拋棄式，不進 repo），用 p4c-bm2-ss 1.2.5.15 編（`r4-p4/compile.log` rc=0）。
  - `register<bit<64>>(4) RIngress.r64`：每個封包經資料面寫 `r64[1] = 2^64−1`、`r64[2] = 2^63+1`、`r64[3] = 2^63−1`；`r64[0]` 留給 CLI。
  - `register<int<32>>(2) RIngress.rint`：p4info 的型別是 `bitstring.int`。
- 交換機：拋棄式 `simple_switch_grpc`，stock 與 fast 各一顆。

**bit<64>**，兩顆一樣：

| 格 | 寫進去的 | CLI `register_read` | bm_thrift（一格／整個陣列） | bmv2 生成的 client | 路由 |
|---|---|---|---|---|---|
| r64[0] | CLI `register_write … -1`，之後 `… 18446744073709551615` | 9223372036854775807 | 同左 | 同左 | 200 `[9223372036854775807]` |
| r64[1] | 資料面 2^64−1 | 9223372036854775807 | 同左 | 同左 | 200，同左 |
| r64[2] | 資料面 2^63+1 | 9223372036854775807 | 同左 | 同左 | 200，同左 |
| r64[3] | 資料面 2^63−1 | 9223372036854775807 | 同左 | 同左 | 200，同左 |
| rint[1] | 資料面 −5 | — | — | — | 501 `register type not readable` |

- ⇒ 2^63 以上一律**飽和成 2^63 − 1**，不是負的 i64。2^63 − 1 本身因此與 2^64 − 1 分不開。
- 這是 bmv2 那一端的轉換：CLI 與生成的 client 讀到的一樣，不是 bm_thrift 的解碼。
- 依工單：bit<64> 以上回 501，訊息寫明原因。bit<63> 的最大值 2^63 − 1 放得進 i64，照讀。
- 測試的前提也改了：第一輪的測試以為 −1 會來、遮罩可以還原，現在改成 501 的測試，加上 bit<63> 讀到頂的測試。

**裝置身分**，兩顆一樣：

- 兩顆交換機 A（device 920011，thrift 29500）、B（device 920012，thrift 29501）；CLI 寫 `r64[0]`：A 111，B 222。
- `bm_mgmt_get_info` 在 A 的埠回 `{device_id: 920011, thrift_port: 29500}`，在 B 的埠回 920012／29501。
- 路由（改之前）：
  - A 的 client、A 的埠 → 200 `[111]`；
  - A 的 client、**B 的埠**（交換過）→ 200 `[222]`，也就是**另一台的資料**；
  - B 的 client、A 的埠 → 200 `[111]`。

### 12.2 改了什麼

- 身分檢查（M3）：經某個 client 第一次讀之前，路由先問 `bm_mgmt_get_info`，比對 device id 與 thrift port。
  - 不同 → 502 `thrift device mismatch`，不讀 register。
  - 結果存在 client 物件上（`thrift_identity`）；readopt 建的新 client 會重新問。
  - 問不到 → 503，不存，下次再問。
- bit<64>（M1）：§1 與上面。
- 預期檔與假 fabric（M2）：§9。
- R2 的歸因與 503（m1、m6）：§9。
- 健檢 gate 的 mutation（m2）：`mutate_p4_health.sh` 加 `C2T-1` 到 `C2T-12`，各有點名的 killer test；r2_cannot 的 501 分支加了測試。
  - 沒有加的一個：「R2 拿 NDTwin 的值與 thrift 比，而不是與 marker 比」。在 SC-reg 通過（thrift == chosen）時兩者等價，SC-reg 不通過時 R2 本來就不會 GREEN，所以它是等價 mutant。
- int<W>（m3）：測試與 mutation（把檢查放寬成只看 `HasField("bitstring")`）。
- 解碼錯誤（m4）：`TProtocolException`、`UnicodeDecodeError`、`struct.error`、`ValueError`、`OverflowError`，以及負的或超限的長度 → 502 `register answer not understood`（以前負長度是 503，其他是 500）。
- 整個陣列的長度（m5）：與 p4info 的 `size` 不同 → 502，在切片之前。
- 整次呼叫的 deadline（m7）：§4。
- thrift 延遲 import（m8）：沒有 `thrift` 時 proxy 照常啟動，只有這條路由回 503 `thrift not installed`；`requirements.txt` 那段註解改了。
- n4：`build_p4_client` 用的不是預設的 gRPC 埠基準時，thrift 埠設成 None（路由回 503 `no thrift port`），不去猜另一套編號的 thrift 埠。
  - 這是我選的做法：工單說「honour port_base」，沒有說要不要讓 thrift 埠跟著平移；照平移去猜，會猜到別人的交換機。
- n7：`start` 超過結尾（沒有 `count`）回 400 `index out of range`，不再是 `invalid range`。
- n10：「32 bit 的值被截斷」那個測試改成 502。

### 12.3 跑了什麼（OBSERVED）

- 每一步都拿著共用的 lock，guard.sh 在 lock 裡；每份 log 第 2 行記 commit 與 dirty 計數。
- proxy 那半在 `a46c8614`，健檢那半在 `2aeae1a1`（之後只多改了 `tests/python/test_p4_health_collect.py` 的兩個斷言）。

| 檢查 | log | 結果 |
|---|---|---|
| 量測，改之後 | `r4_probe1.out`、`r4probe1.json` | bit<64> → 501 `register too wide`（兩顆）；int<32> → 501；身分：右的埠 200 `[111]`，交換過的埠兩個方向都 502 `thrift device mismatch` |
| `mutate_p4_register_thrift.sh` | `r4_gate_reg.out` | `59 mutations, 0 survived` |
| `mutate_p4_direct_counter.sh` | `r4_gate_dc.out` | `33 mutations, 0 survived` |
| `mutate_telemetry_by_name.sh` | `r4_gate_tbn.out` | `23 mutations, 0 survived` |
| `check_gate_anchors.py HEAD` | `r4_anchors.out`（`2aeae1a1`） | `139/139 cells ok` |
| `ANCHOR_CHECK=1 mutate_p4_health.sh` | `r4_health_anchorcheck.out`（`2aeae1a1`） | rc 2（設計如此），530 行每一行都是 1 |
| 健檢 gate 的局部（`ONLY_LABEL_PREFIX=C2T-`，不是 gate） | `r4_health_partial.out`（`2aeae1a1`） | `12 mutations, 0 survived` |
| 健檢測試，p4_proxy/venv（3.13） | `r4_health_venv.out` | cells 204 OK；collect 203 OK |
| 健檢測試，ryu-env（3.8） | `r4_health_ryu.out` | cells 204 OK；collect 203 OK |
| `test_bm_thrift.py` | `r4_unit_bmthrift.out` | 22 OK（含每 2 s 吐一個 byte 的對端在 3 s 預算內被切斷） |
| `test_register_route.py` | `r4_unit_register.out` | 47 OK |
| trial（hc_main） | `trial-reg-r4.json` | 兩顆：`[4737]`；P4Runtime 讀取全程成功；R2 GREEN；SIGSTOP 時 5.0 s 回 503 |
| p4lane（拋棄式 clone `a46c8614`） | `r4_p4lane.out` | `FAILURES=0` |

- 中途 gate 抓到的：
  - `39b53f4c` 的 register gate 有兩個存活：一個是已經不可能觸發的長度檢查（`a46c8614` 刪掉，連同它的 mutation），一個是點錯了 killer test（改點到 `test_a_range_past_the_end_is_400`）。
  - `a46c8614` 的健檢局部 gate 有兩個存活（C2T-8、C2T-9）：404／501 走不到 cannot 那一步時，compare 那一步也會給紅，而測試只看字樣。`2aeae1a1` 讓測試檢查 step 與錯誤字。
- 沒有驗的：live lab；硬體 target；bmv2 在 external 模式下由別的 controller 起的情形；4-shard 的健檢 gate（排在合併 head 跑）。
