# P4 register 讀取與 direct counter 讀取：量測與設計

[Co-developed with claude code -- Adam]

- **分支**：`feat/p4-register-read`，從 `39bdb614` 開。
- **LOG**＝`scratch/overnight-2026-09-05/logs/gates-0910/p4-register-read/`。
- 本文先寫量測（§1），再寫設計（§2–§6），§7 是第二輪補的量測與記下來的小事。第一次量測在任何程式碼之前做完。
- 第二輪的 run 都在 json 的 `header` 裡記了 `git rev-parse HEAD`、三種 dirty 計數（`--untracked-files=no`、預設、`--ignored`）、`df -m /` 與 p4c 版本。第一輪的 `measure.json`、`trial-*.json` 沒有這個 header；它們的身分只在同一時間其他步驟 log 的第一行。

## 1. 量測（OBSERVED，離線）

### 1.1 怎麼量的

- 腳本：LOG`/measure.py`（一次性，不是 gate 的對象）。
  - 第一輪：LOG`/measure.json`（`measure.out` `rc=0`）。
  - 第二輪在最後一個程式碼 commit（`ff028f10`）重跑一次：LOG`/measure-r2.json`，header 有 commit 與 p4c 版本。
- 程式：`tools/p4_health/exercise/src/hc_main.p4`，用 `p4c-bm2-ss --p4v 16`（Version 1.2.5.15，SHA 5b948b037a）編，不帶 define，與 S0 的 `build/hc_main` 同樣的編法。
  - 它有 `register<bit<32>>(16) HcIngress.r_mark`、`direct_counter HcIngress.dc_k2`（掛在 `HcIngress.t_dcount`）、`counter(1024) HcIngress.c_in`（對照用）。
- 交換機：`tools/p4_health/throwaway.py` 的規則。pcap 模式、不用 root、argv0 `ndt-hc-regread-bmv2`、thrift 29500、gRPC 29650（量之前檢查過是空的，且在 lab 的埠外面）、用自己的 pid 停。兩顆 binary：

| binary | sha256 |
|---|---|
| stock `/usr/local/bin/simple_switch_grpc` | `327fa7d17221739747a15c6ced580b452b5c8981f29ba6a6998c1361d73cdef4` |
| fast `/usr/local/bmv2-fast/bin/simple_switch_grpc`（`p4_proxy/mininet/bmv2_binary_override` 指的那顆） | `3ff54b5c1901c9d3ffd80ac05dc3dc7d0e696e3df73174c1616fb87ac9aedb4a` |

- 🔴 兩顆 binary 連的是**同一個** P4Runtime 前端：`ldd` 兩顆都指到 `/usr/local/lib/libpifeproto.so.0`（sha256 `987b2431…`）。所以下面「兩顆都一樣」在 P4Runtime 那一層是同一份程式量了兩次，不是兩個獨立的實作。
- 步驟：
  1. 一個裸的 P4Runtime stub 拿到 primary（election 1），推 hc_main。
  2. 插一筆 `t_dcount`：dport 40012 → `dc_hit`。
  3. 在 bmv2 讀 pcap 之前（還剩 11.5 s）送下面每一種 Read，每種各自一個 ReadRequest。
  4. pcap 送進：1 個 R2 marker（dport 40031，sport 4737；程式做 `r_mark.write(0, sport)`）、5 個 K2 marker（dport 40012）、2 個 K1 marker（dport 40011 → `c_in[0]`）。
  5. 處理完以後再送一次同樣的 Read，並用 thrift 的 `register_read`／`counter_read` 當 oracle。

### 1.2 結果：兩顆 binary 完全一樣

| Read | 處理前 | 處理後 |
|---|---|---|
| `register_entry { register_id: r_mark, index { } }`（index 0） | `UNIMPLEMENTED: Register reads are not supported yet` | 同左 |
| 同上，index 1 | 同上 | 同上 |
| 同上，不帶 index（整個陣列） | 同上 | 同上 |
| 同上，index 16（超出 size 16） | 同上 | 同上 |
| 一個 ReadRequest 裡 4 個 entity（index 0..3） | 同上 | 同上 |
| `register_entry { }`（每一個 register） | 同上 | 同上 |
| 不存在的 register id 0x0FFFFFFF | 同上 | 同上 |
| `direct_counter_entry { table_entry { 那筆 dport 40012 的完整 entry } }` | `data { }`（0） | `data { byte_count: 335 packet_count: 5 }` |
| `direct_counter_entry { table_entry { table_id: t_dcount } }`（萬用字元） | 那一筆，帶 match，`data { }` | 那一筆，帶 match（不帶 action），`335 / 5` |
| `direct_counter_entry`，一筆不存在的 entry（dport 40099） | `INVALID_ARGUMENT: Cannot map table entry to handle` | 同左 |
| `table_entry { table_id: t_dcount, counter_data { } }`（`read_table_entries` 的形狀） | 帶 `counter_data { }` | `counter_data { byte_count: 335 packet_count: 5 }` |
| 對照：`counter_entry { c_in, index { } }` | `data { }` | `134 bytes / 2 packets` |

- thrift oracle（處理後，兩顆都一樣）：`HcIngress.r_mark[0]= 4737`、`r_mark[1]= 0`、`HcIngress.c_in[0]= (134 bytes, 2 packets)`。
  - ⇒ 資料面確實寫進了 register（陽性對照成立），而 P4Runtime 讀不到它。
  - 連不存在的 id 都回同一句 ⇒ 前端在查 id 之前就整個拒絕了 register 讀取。
- 每個 Read 都在 5 ms 以內回來；兩顆交換機量完都還活著，停的 rc 都是 -15（我送的 SIGTERM）。
- 順帶看到：`counter_entry.index.index = 0` 這種寫法（proxy 的寫法，`read_egress_counter`）在 Python protobuf 裡會把 `index` 標成存在，送出去就是 `index { }`，與 `SetInParent()` 一樣。所以 proxy 讀 index 0 不會變成萬用字元讀取。

### 1.3 結論

- **bmv2（stock 與 fast）的 P4Runtime 不支援 RegisterEntry 的讀取**，錯誤碼 `UNIMPLEMENTED`，訊息 `Register reads are not supported yet`。與 R3 量到的寫入被拒（`Register writes are not supported yet`）是同一處（兩句都在 `libpifeproto.so.0` 裡，§5.2）。
- **DirectCounterEntry 的讀取可以用**，指定一筆或萬用字元都可以，數字與送進去的封包數一致（5 個 67 byte 的 marker＝335 byte）。
- 依工單：register 這半**停在量測與這份設計**，不做 thrift 路徑（§5 列選項給 Adam 裁）；direct counter 這半照做（§2）。

## 2. direct counter 的路由

### 2.1 形狀

```
GET /p4/direct_counter/{name}?dpid=<n>
```

- `name`：p4info 的 `direct_counters` 裡的全名（`HcIngress.dc_k2`）或 alias（`dc_k2`）。與 `GET /p4/counter` 一樣兩種都收。
- 一次回這個 direct counter 所在的表的**每一筆 entry**：

```json
{"dpid": 2, "counter": "HcIngress.dc_k2", "table": "HcIngress.t_dcount", "unit": "both",
 "entries": [{"match": {"hdr.udp.dstPort": {"type": "exact", "value": 40012}},
              "priority": 0, "bytes": 335, "packets": 5}]}
```

- `counter` 永遠是全名，即使用 alias 問。
- match 的每個欄位都是 `{"type", ...}`，值是整數：
  - exact／optional：`value`；
  - lpm：`value`、`prefix_len`；
  - ternary：`value`、`mask`；
  - range：`low`、`high`。
  - 用整數而不用 bytes，是因為 JSON 放不了 bytes，而 app 寫 entry 時（`POST /p4/table_entry`）給的也是整數。
- `priority`：交換機自己回的數字。bmv2 在萬用字元的回答裡確實會填它（§7.1：flow_5tuple 兩筆同 match 的 entry 回 100 與 200）。沒有 priority 欄的表（lpm、exact）是 0，那是 P4Runtime 對「沒有 priority」的定義，不是補出來的。
- **不捏造 0**：
  - `unit` 是 p4info 宣告的單位：`both`、`bytes`、`packets`；p4info 沒說時是 `unspecified`。
  - 沒有計的那個單位回 `null`，不是 protobuf 預設的 0。
  - 一筆 DirectCounterEntry 沒有 `data` 欄時，那一筆保留，`bytes`、`packets` 都是 `null`。
    - 這是照 `read_table_entries` 的做法：`counter_data` 不在時那筆 entry 的 `counters` 是 None，只有 OpenFlow 的 renderer 因為 kernel 的形狀要整數才把它變成 0。
    - 選 `null` 不選 503：讀取本身成功了，同一張表其他 entry 的數字是真的；整個回 503 會把真的數字一起丟掉。
    - bmv2 沒被看到這樣回（§1.2 連 0 都帶 `data { }`）；這是給別的 target 的。
  - `unspecified` 時兩個數字照交換機回的傳出去，因為分不出哪一個沒計；`unit` 讓呼叫的人知道。
- **為什麼沒有用 match 挑一筆**：
  - GET 帶不了一個 ternary＋priority 的 match。
  - 一筆不存在的 entry，bmv2 回的是 `INVALID_ARGUMENT`（§1.2），與「讀失敗」分不開。
  - 萬用字元一次 RPC 就拿到整張表；app 自己用 match 找它那一筆。
- 空表回 200、`entries: []`。這是一個事實，不是失敗。

### 2.2 錯誤碼（照 `GET /p4/counter` 的三種結果，加兩種）

| 碼 | 什麼時候 | 有沒有碰交換機 |
|---|---|---|
| 200 | 讀到了，包括 0／0 的 entry 與空表 | 有 |
| 404 `unknown switch` | dpid 不認得 | 沒有 |
| 404 `indexed counter` | 名字不是這台的 direct counter，而是 indexed counter；訊息指到 `GET /p4/counter/<name>?dpid=&index=` | 沒有 |
| 404 `not in this pipeline` | 名字兩種都不是 | 沒有 |
| 502 `direct counter not rendered` | 交換機回了，但把回答渲染成 body 時丟了例外。**只有渲染丟例外才是 502**（見表下） | 有 |
| 503 `direct counter not read` | RPC 失敗（含 deadline 到了）。**明說不是 0、不是空表** | 有 |
| 503 `replay pending` | 這台正在 readopt（`table_journals.pending(dpid)`），表還在放回去。只在讀之前查一次（見表下） | 沒有 |
| 503 `no topology` | proxy 還沒有 topology | 沒有 |

- **502 不是「對不上 p4info」的總稱**：
  - 一個 match 欄位 id 這台的 p4info 不認得時，不會丟例外：`_match_field_name` 回 None，`_match_as_dict` 把它放在 None 這個鍵底下。所以那一筆照樣 200 回來，欄位名是 null。這與 `read_table_entries` 的做法相同，是刻意的。
  - 同一筆 entry 有兩個不認得的 id 時，兩個都放在同一個 None 鍵下，後一個蓋掉前一個，少一個欄位。
  - 改成遇到不認得的 id 就丟例外（→ 502），是以後的程式碼改動，這次沒有做。
  - 測試裡的 502 是用一個會丟例外的 `_match_as_dict` 替身造出來的（`test_an_answer_this_p4info_cannot_render_is_502_and_not_a_read_failure`）。
- **`replay pending` 只在讀之前查一次**：
  - `POST /p4/table_entry` 是在 journal 的 lock 底下再查一次（`rule_journal.write_and_journal`）。這條讀取路由沒有那個 lock，查完就讀。
  - 留下的窗：查完之後讀取被拖延超過約 1 s 時，`POST /p4/readopt` 可能剛好設了 pending、等 1 s、推 pipeline（表清空）。這時這次讀取還拿著舊的 client，會讀到清空的表，回 200 `entries: []` 或 0/0，直到舊 client 被停掉為止。
  - 發生的頻率沒有量。
  - 以後的修法：讀完再查一次 pending；或給 readopt 一個 generation，讀之前與讀之後比對。
- 一個名字同時是 direct counter 又是某個 indexed counter 的 alias 時，這條路由**先看 direct**，照讀；只有不是 direct counter 的名字才會被指去 `/p4/counter`。
- `GET /p4/counter/<direct counter 的名字>` 仍是 404，但 `error` 改成 `direct counter`，訊息指到 `GET /p4/direct_counter/<name>`。
  - 今天它回 `not in this pipeline`，那是錯的：這個 counter 在 pipeline 裡，只是沒有 index。
  - 碼不改：沒有 index 可讀，這是結構性的、永久的。
  - 這個檢查在讀之前做：名字只在 `direct_counters` 裡時才指過去；同時是 indexed counter 的名字照舊讀 index。
  - 健檢的 K1-neg 用的是一個不存在的名字（`HcIngress.no_such_counter`），它的 `not in this pipeline` 不受影響。
- 新路由的錯誤處理故意寫成與 `/p4/counter` 不同的排版：`tests/shell/` 的 gate 用原文找錨點，同一段字出現兩次，錨點就會對兩處，或者更糟，只對到另一條路由（§7.3）。

### 2.3 deadline 與 thread

- 新的讀取帶 `timeout=RPC_TIMEOUT_S`（5 s），與 `read_table_entries` 一樣。
- 🔴 **工單說「照 `/p4/counter` 怎麼限制它的讀取」——它沒有限制**：`read_egress_counter` 的 `self.stub.Read(req)`（在 `39bdb614`）沒有帶 timeout。
  - gRPC 預設沒有 deadline。`read_table_entries` 的 docstring 記了 2026-08-13 量到的事：bmv2 被 SIGSTOP 時，沒有 deadline 的 Read 永遠不回來。
  - `/p4/counter` 是用 `run_in_threadpool` 跑的，所以卡住的是 threadpool 的一條 thread，不是 event loop。但一個停住的交換機上，每一個請求都會卡住一條，直到 threadpool 用完，之後所有走 threadpool 的路由都會排隊。【threadpool 用完那一段是推論，沒有量】
  - 量到的（LOG`/trial-old.json`，第一輪；`trial-old-r2.json`，第二輪）：在 `39bdb614` 的程式碼上，拋棄式交換機 SIGSTOP 時，`GET /p4/counter/HcIngress.c_in?index=0` 12 s 都沒有回來（stock 與 fast），SIGCONT 之後才回 200。分支上同一個讀取在 5.0 s 回 503（`trial-new-r2.json`）。
  - 本分支一併補上：`read_egress_counter` 也帶 `timeout=RPC_TIMEOUT_S`。deadline 到了是 `grpc.RpcError`，原本的 `except Exception` 就會把它變成 `None` → 503，契約不變。
- 兩條路由都是 `async def`，gRPC 讀取用 `run_in_threadpool` 手動放到 worker thread。
  - 測試比的是 thread identity（`TheReadStaysOffTheEventLoopTest`，照 `test_flow_stats_route.py` 的 `BlockingWorkStaysOffTheEventLoopTest`），兩條路由各一個，各有一個拿掉 `run_in_threadpool` 的 mutation。

### 2.4 誰的 counter 可以讀

- **每一個都可以讀，包括 NDTwin 自己的**（`MyIngress.ipv4_lpm_counter`、`MyIngress.flow_5tuple_counter`）。
- 理由：
  - V7（owner 檢查）管的是**寫**：寫進 NDTwin 的表會改它的轉送。讀不改轉送狀態。
  - 現有的讀取路由本來就讀 NDTwin 自己的東西：`GET /p4/counter` 讀 `MyEgress.egress_port_counter`；`GET /stats/flow/<dpid>` 經 `read_table_entries` 讀的就是這兩個 direct counter。
  - 「讀不會清零」只有一個弱的佐證：§1.2 處理前讀一次、處理後讀一次，第二次是送進去的總數。這說明前一次讀沒有把它清掉，但沒有測連續讀很多次；P4Runtime 規格裡 Read 也沒有清零的語意【規格那半是讀規格得知，沒有在這台上查證】。

### 2.5 external 控制面

- 可以用。P4Runtime 的 ReadRequest 根本沒有 `election_id` 欄位，不需要 mastership；與 `GET /p4/counter` 同一個理由。
- 測試照 `test_counter_route.py` 的 `AnExternalControlPlaneCanStillReadTest`；bmv2 trial 也用一個 `arbitration=False` 的 client 讀過（§7.2）。

### 2.6 大小

- 一個請求＝一次 RPC。回應的大小受那張表宣告的 `size` 限制：NDTwin 自己的兩張表各 1024 筆（`ndtwin_switch.p4`）。所以不另設上限。
- 沒有量的：1024 筆滿表時的延遲；gRPC 預設 4 MB 的接收上限在多大的表會碰到（§7.4）。

## 3. register 的路由：不做

- 理由見 §1.3。§5 是選項。
- 🔴 給以後做 register 路由的人：健檢的 `ROUTE_PREFIXES` 把 R2（讀）與 R3（寫）都對到 `/p4/register`，而 `route_answer` 只看路徑前綴、不看 method（`tools/p4_health/observe.py:22-40`）。
  - ⇒ 一加上 `GET /p4/register/...`，R3 的「沒有寫的路由」就判不出來了，R3 會變成「寫入回了 None」的紅。
  - 要在同一個 PR 裡讓 `route_answer` 看 method，或把 R3 對到別的路徑。

## 4. 健檢（tools/p4_health）：不改

- **本分支沒有改 tools/p4_health 的任何檔**，所以不需要跑 4-shard 的健檢 gate。判定也沒有變：K2 今天仍是 404 → 紅，只是理由的字樣過時了。
- **K2**：
  - 今天的 observer 呼叫的是 `GET /p4/counter/HcIngress.dc_k2?dpid=2&index=0`（`observe_a.py:403-419`），新的路由它不會去叫。
  - 要讓 K2 轉綠，observer 要改叫 `GET /p4/direct_counter/HcIngress.dc_k2?dpid=2`，從 `entries` 找 `hdr.udp.dstPort == 40012` 那一筆；`ROUTE_PREFIXES["K2"]` 要加 `/p4/direct_counter`。
  - 健檢自己的規則（DESIGN §5.1 的「預註冊」）：翻轉格子的修正要附 `health.json` 並在**同一個 PR** 改預期檔。`health.json` 要 live 跑才有，本工單只做離線 ⇒ 不改 observer、不改 `expected_today.tsv`。
- **R2**：
  - 沒有 register 路由，R2 仍是「no route」的紅，預期檔不用改。
  - 把 bmv2 那半歸因（P4Runtime 讀不到）寫進 R2 的理由欄，是健檢那邊的事，要 live 的佐證時再改。
- **後續要改的地方**（都還描述 `/p4/counter` 的舊回答；判定不變，所以這次不動）：
  1. `tools/p4_health/cells/table.py:461`：K2 的紅理由寫死「GET /p4/counter answered 404 (not in this pipeline)」；現在 dc_k2 的 404 是 `direct counter`。
  2. `tools/p4_health/collect/proxy.py:35-37`：`counter()` 的 docstring 引 `api_routes.py:963-1029` 與只有 `not in this pipeline`／`unknown switch` 兩種 404。
  3. `tests/python/test_p4_health_collect.py:1571-1573`：假 proxy 對 `HcIngress.dc_k2` 回 `not in this pipeline`。
  4. `tests/python/test_p4_health_collect.py:2296-2305`：「讀得到 direct counter 的 proxy 讓 K2 轉綠」的測試，假設的仍是 `/p4/counter/...?index=0` 回 `packets`，不是新路由的 `entries`。
- 其他後續：
  - `GET /p4/counter` 對 PACKETS／BYTES 的 indexed counter，沒計的單位仍回 0（從 `39bdb614` 就這樣）。新路由用 `unit` 與 `null` 處理了，舊路由沒有改。
  - `GET /p4/counter` 在 readopt 的窗裡也沒有 `replay pending`（`/stats/flow` 也沒有）；新路由有，舊的沒改。

## 5. register 讀取的選項（給 Adam 裁）

### 5.1 選項

| 選項 | 做法 | 好處 | 代價 |
|---|---|---|---|
| **(a) proxy 走 thrift 讀**（建議） | proxy 對 bmv2 的 thrift 埠（`grpc_ports.thrift_port(device_id)`，9090＋N）送 `register_read`；或直接用 thrift binding 呼叫 `bm_register_read`／`bm_register_read_all`。只讀不寫 | 今天就讀得到（§1.2 的 oracle 就是這條）；不需 mastership，external 模式也能用；`bm_register_read_all` 一次拿整個陣列 | 只有 bmv2 有，硬體 P4 沒有 thrift；proxy 要多一條連線（每台交換機一個 thrift 埠）與它的 deadline；名字用的是 bmv2 JSON 的名字，要對到 p4info；venv 已釘 `thrift==0.24.0`（`p4_proxy/requirements.txt`），但 proxy 從來沒有 import 過它，CLI 模組在 p4dev venv 的 site-packages 裡、版本對不上的陷阱寫在同一段註解；**健檢的 R2 會變成 thrift 比 thrift**（下面） |
| (b) 讓 PI 支援 register 讀 | 在 PI 的 C API 加 register、在 bmv2 的 PI target 實作、在 P4Runtime 前端接上（§5.2） | 留在 P4Runtime 上，硬體 target 也走同一條 | 要改並編 C++ 的 PI 與 bmv2（本工單禁止）；不是升個版本就好（§5.2） |
| (c) 不做 | R2 維持紅，歸因寫 bmv2 | 零成本 | sketch 類 app（HashPipe 等）在 NDTwin 上讀不到自己的狀態 |

- 🔴 **選 (a) 時健檢的 R2 要一起改**：R2 的 oracle 本來就是 thrift（`observe_a.observe_r2` 讀 `register_read HcIngress.r_mark 0`）。如果 NDTwin 的路由也是 thrift 讀出來的，R2 就是拿 thrift 去比 thrift：路由抄錯 index 或名字會被抓到，但「bmv2 的 thrift 讀錯」這種錯兩邊一樣，抓不到。
  - 要保留鑑別力，oracle 得換成不經 thrift 的東西：例如資料面自己的證據（marker 的 sport 本來就是寫進去的值，`round_a.R2_CHOSEN`），讓 R2 比「NDTwin 讀到的」與「送進去的」。
- 工單提到的「`tools/p4_health/runtime_cli.py` 的 reader」：那個檔是把 runtime JSON 翻成 CLI 指令（寫入用，只給拋棄式交換機）。健檢真正的讀取器是 `tools/p4_health/collect/thrift.py` 的 `ThriftReader`：它起 `simple_switch_CLI` 子行程、一次一個指令、30 s timeout、白名單只准讀。
  - 選 (a) 時有兩種接法：照 `ThriftReader` 起子行程（簡單，但每個請求一個行程，約數百 ms【推論：沒有量】），或在 proxy 裡直接用 thrift binding（快，但要處理上面那個版本陷阱）。
- 大陣列：(a) 的 `bm_register_read_all` 一次回整個陣列。上限要在路由上設（例如超過 N 格就要求帶 `index` 或 `start`／`count`），N 要等 HashPipe 的實際大小再定。

### 5.2 (b) 查到什麼（只看這台機器上裝的東西，沒有上網）

- **這台機器上沒有 PI 或 behavioral-model 的原始碼，也沒有它們的 release notes**：
  - `find / -xdev -name device_mgr.cpp` 找不到。
  - behavioral-model 的原始碼樹 2026-08-31 刪掉了（`p4_proxy/requirements.txt` 的註解）。
  - ⇒ 上游新版有沒有支援，我**沒有查**，也查不了。
- 裝在這台的 PI（兩顆 binary 共用）：
  - 兩句拒絕的字都在 `/usr/local/lib/libpifeproto.so.0`（P4Runtime 前端）：`Register reads are not supported yet`、`Register writes are not supported yet`。
  - PI 的 C API 標頭 `/usr/local/include/PI/` 有 `pi_counter.h`、`pi_meter.h`、`pi_tables.h`、`pi_act_prof.h`、`pi_clone.h`、`pi_mc.h`、`pi_learn.h`、`pi_value.h`，**沒有 register 的標頭**；`target/` 底下的實作介面也沒有。
  - `libpi.so.0` 匯出 `pi_counter_read`、`pi_counter_read_direct` 等，**沒有任何 P4 register 的函式**（名字含 register 的只有 callback 的註冊）。
  - bmv2 的 PI target（`libbmpi.so`，stock 與 fast 各一份）也沒有 register 的符號。
- ⇒ 在裝在這台的版本上，缺的不只是前端那一句：PI 的 C 層與 bmv2 的 PI target 都沒有 register 的介面。所以 (b) 是「在三層各加一段 C++ 再重編」，不是換個版本。

## 6. 測試與 gate

- 單元測試：`p4_proxy/tests/test_direct_counter_route.py`（新）。
  - 第一輪的 21 個裡有 20 個在沒有這個功能的程式碼上看過紅（`unit_red_before_feature.log`）。綠的那個是 `test_a_name_that_is_neither_keeps_the_old_404`：它守的是舊行為，由 mutation 29 證明它會紅。紅的 20 個裡，但其中三個（unknown dpid、不是 direct counter、沒有 topology）紅的理由是「路由不存在」，不是它自己的理由。它們自己的紅由第二輪的三個 mutation 證明（unknown switch → 200 空表、不認得的 direct counter → 空表、沒有 topology → 404）。
  - 第二輪加的測試在第一輪的 head（`bce1b6d3`）上看紅（`unit_red_r2_at_bce1b6d3.log`：30 個裡 4 failures、3 errors）。
    - packets-only 與 bytes-only 兩個測試紅的理由是 `KeyError: 'unit'`（舊碼沒有 `unit` 欄），不是 null 的規則本身；null 的規則由 mutation 10–12 證明。其餘的紅是各自的理由。
  - 在舊碼上本來就綠的有三個，它們的紅由 mutation 證明：
    - 兩個 thread 測試：舊碼本來就用 `run_in_threadpool`；由拿掉它的兩個 mutation 證明。
    - `test_another_switch_being_readopted_does_not_stop_this_read`：它守的是「不要擋太寬」，舊碼根本不擋；由把檢查放寬到每台交換機的 mutation 證明。
- mutation gate：`tests/shell/mutate_p4_direct_counter.sh`（新），32 個 mutation，錨點給 `check_gate_anchors.py` 讀。有些 mutation 共用同一段錨點，所以 anchor 檢查數到的不重複錨點比 32 少（gate 開頭有說明）。
- `tests/shell/mutate_telemetry_by_name.sh` 的 M-C6、M-C15 錨點改成從 `/p4/counter` 才有的那一行開始（§7.3）。
- 離線 bmv2 trial：起真的 proxy 程式碼（`P4RuntimeClient` 與路由 handler），對 stock 與 fast 各一顆拋棄式交換機，讀到 0 再讀到送進去的數；hc_main 與 ndtwin_switch 各一組（§7.1、§7.2）。
- p4lane：`p4lane.sh <worktree>`。

## 7. 第二輪補的量測與記下的小事

### 7.1 ndtwin_switch 上的 priority（OBSERVED）

- LOG`/trial-ndt-r0.json`（在 `bce1b6d3`，腳本 `trial_ndt.py`）與 `trial-ndt-r2.json`（最後一個程式碼 commit `ff028f10`）。
- 真的 `P4RuntimeClient`，綁 BASELINE，推已經編好的 `ndtwin_switch.json`（sha256 `f1c6e096…`）：
  - `insert_5tuple_rule` 兩筆，match 一樣（dst 10.0.0.2、proto 17、l4 dport 40012），priority 100 與 200；
  - `insert_ipv4_route` 一筆 10.0.0.3/32；
  - pcap 送 3 個打到 5-tuple 的 frame、2 個到 10.0.0.3。
- 兩顆 binary 一樣：
  - 萬用字元 DirectCounterEntry 的回答**有填 `table_entry.priority`**：100 那筆 `data { }`，200 那筆 `201 bytes / 3 packets`。
  - ipv4_lpm 那筆沒有 priority 欄（0），`134 bytes / 2 packets`。
  - thrift：`table_dump` 的 priority 是 PI 換算過的（2147483547 對 100、2147483447 對 200，即 2^31−1−p），`counter_read` 依 handle 是 `0/0`、`201/3`、`134/2`，與 P4Runtime 一致。
  - `TableEntry`＋`counter_data`（`read_table_entries` 的形狀）回同樣的 priority 與數字。
- ⇒ 路由回的 priority 是交換機的，不是補的，不必另外說明。
- 在最後一個程式碼 commit（`ff028f10`）重跑，路由的回答（兩顆一樣）：flow_5tuple `unit: both`，`(priority 100, 0 B, 0 pkt)`、`(200, 201, 3)`；ipv4_lpm `(0, 134, 2)`。與 thrift 依 handle 讀到的一致。

### 7.2 hc_main 上的路由（OBSERVED）

- `trial-new-r2.json`：與第一輪同樣的結果（primary 與 external 兩個 client 都是 0/0 → 335/5，與 thrift 一致；SIGSTOP 時兩條路由 5.0 s 回 503），多了 `unit: "both"`。

### 7.3 錨點撞車

- 第一版（`705e07e4`）新路由抄了 `/p4/counter` 的錯誤處理寫法：`mutate_telemetry_by_name.sh` 的 M-C15 錨點變成兩處，M-C6 的錨點**次數仍是 1，但只對到新路由**（anchor 檢查會說 ok，mutation 卻改錯地方）。
- 第一輪用「恢復原文、新路由換排版」修；第二輪再把兩個錨點改成從 `/p4/counter` 才有的那一行開始，下次再有人照抄也搶不走。

### 7.4 記下、沒有做的

- 一個在 proxy 重啟後還沒有連上的交換機，讀取回 404 `unknown switch`，不是 503；這是 `topology.switches` 的事，與 `/p4/counter` 一樣，沒有改。
- mutation 32（`{name:path}`）是弱的：路徑變了，`TheRouteIsRegisteredTest` 找不到 `/p4/direct_counter/{name}`，在 `[0]` 上丟 `IndexError`。這與 mutation 31（拿掉 decorator）是同一個訊號，並沒有測到 greedy 參數會答錯的請求。
- 第一輪 SUMMARY 說「19 個 mutation」而 anchor 檢查是 `ok(17)`：差的是共用錨點，不是漏了。
- 本文與 code 裡引的檔案行號會隨後續修改漂移；第二輪改成盡量引函式名。
- 沒有量：1024 筆的表讀一次要多久、gRPC 4 MB 接收上限在多大的表會碰到。
