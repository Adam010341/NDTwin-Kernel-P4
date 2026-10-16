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

- 值是 bit<W> 的無號值。bmv2 的 thrift 回的是 i64（有號），bit<64> 的全 1 會變成 −1，所以這裡用 W 位元的遮罩還原成無號。
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
- socket timeout＝`RPC_TIMEOUT_S`（5 s），連線與每一次 receive 都受它限制。
  - 注意：這是每一步 5 s，不是整次讀取 5 s；一台每 4.9 s 吐一個 byte 的交換機可以拖更久【推論：沒有量】。
- 路由是 `async def`，thrift 呼叫用 `run_in_threadpool` 放到 worker thread，與 direct counter 路由同一條規則；有 thread identity 的測試與拿掉它的 mutation。

## 5. external 模式

- 可以讀。thrift 讀取不需要 mastership，與 P4Runtime 的 Read 一樣。
- 它也不碰 P4Runtime 記的表狀態（§0），所以不會打擾 exercise 自己的 controller。

## 6. 錯誤

| 碼 | error | 什麼時候 | 有沒有問交換機 |
|---|---|---|---|
| 200 | | 讀到了；0 就是 0 | 有 |
| 400 | `index out of range` | index 或一段超過 p4info 的 `size`（帶 `size`） | 沒有 |
| 400 | `invalid range` | 負的、空的、`index` 與 `start`／`count` 一起給 | 沒有 |
| 404 | `unknown switch` | dpid 不認得 | 沒有 |
| 404 | `not in this pipeline` | 不是這台 p4info 的 register | 沒有 |
| 413 | `too many cells` | 超過 `REGISTER_CELLS_MAX`（4096）；或陣列大於 `REGISTER_READ_ALL_MAX`（65536）卻要一段 | 沒有 |
| 501 | `register too wide`／`register type not readable` | 寬於 64 bit；不是 bit<W> | 沒有 |
| 502 | `register refused` | bmv2 回 `InvalidRegisterOperation`（帶 `code`） | 有 |
| 502 | `register answer invalid` | 回的不是這兩個呼叫的答案（application exception、沒有結果、型別不對、格數不對） | 有 |
| 503 | `register not read` | 連不上、斷了、超時。**明說不是 0** | 有（或試過） |
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
  - SC-reg 失敗 → R2 判不了（PROBE-BROKEN／NOT RUN），不會變成 NDTwin 的紅。
- observer 的改法：
  - openapi 有 `GET /p4/register/...` 時，`answer` 改成真的去讀 `GET /p4/register/HcIngress.r_mark?dpid=2&index=0`（`collect/proxy.py` 加 `register()`）；
  - `oracle` 改成 `{"value": chosen}`；
  - `cells/table.py` 的 R2：紅的理由改成「NDTwin read X, the marker wrote Y」；cannot 另外把 404／501 判成結構性的紅（同 K1 的 `k1_cannot`）。503 仍是「沒有讀到」→ NOT RUN。
- 🔴 **R3 要一起改**（DESIGN.md §3 寫過）：
  - `route_answer` 只看路徑前綴。一加上 `GET /p4/register/{name}`，R3（寫）就會以為有寫的路由。
  - 改法：`observe.ROUTE_METHODS` 讓 R2 只認 GET、R3 只認 POST／PUT／PATCH。openapi 本來就給 method（`collect/proxy.openapi_paths` 回 `{path: methods}`）。
- **預期檔不改**：`expected_today.tsv` 的 R2 預測「no route」→ 紅。依健檢自己的規則（它的 DESIGN §5.1），翻格子要附 live 的 `health.json` 並在同一個 PR 改預期檔。本工單只有離線，所以留給下一次 live；到時 R2 預期會翻（在 Δ 欄看得到）。
- 改到的 tools/p4_health 檔：`collect/proxy.py`、`observe.py`、`observe_a.py`、`cells/table.py`。
  - 它們的測試在 `tests/python/test_p4_health_collect.py` 與 `test_p4_health_cells.py`（先看紅）。
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
