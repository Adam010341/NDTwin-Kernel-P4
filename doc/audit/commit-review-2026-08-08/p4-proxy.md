# p4_proxy/ commit review

## 摘要（先講結論：找到幾條、最嚴重的是什麼）

本範圍為 `p4_proxy/` 整個目錄（28 個檔案，+7365 行）。由於 baseline（`28b8b13`）不存在此目錄，所有程式碼均為新加入；因此「不合理」集中在設計問題、半成品、未接上的功能，而非回歸。

共找出 **4 條高嚴重度、8 條中嚴重度、4 條低嚴重度** 發現。

最嚴重的兩條：
1. **H1**：從串流接收執行緒內發起無 timeout 的 blocking gRPC 呼叫，一個 dead switch 可癱瘓其他 live switch 的封包處理路徑。
2. **H2**：NetworkX 圖操作完全沒有執行緒同步，多個 switch 的串流接收執行緒會並發修改 `self.net`。

## 高嚴重度發現

### H1. `install_initial_routes()` 從串流接收執行緒內做 blocking gRPC Write（無 timeout），dead switch 會卡住 live switch 的 packet-in 處理
- 位置：`topology_manager.py:513` → `topology_manager.py:408-433` → `p4_client.py:474`
- 現象：
  `handle_packet_in()`（執行在 `_stream_receiver` 執行緒中）發現新 link 後呼叫 `install_initial_routes()`，後者對**所有** switch 逐一呼叫 `client.insert_ipv4_route()`。
  `insert_ipv4_route()` 在 `p4_client.py:474` 呼叫 `self.stub.Write(req)` —— **沒有 timeout 參數**。gRPC Python 的預設行為是無限期等待。
  若任一個 remote switch 無回應，該 `Write()` 會永久阻塞，導致**發起呼叫的那個 live switch 的串流接收執行緒也被卡住**，後續的 LLDP beacon、telemetry sample 全部無法處理。
- 為什麼不合理：
  這是「治症狀不治病」的典型：`insert_ipv4_route` 已經有 `try/except grpc.RpcError`，但沒設 deadline，所以 exception 永遠不會被觸發。一根 dead switch 可以透過 `install_initial_routes` 的跨 switch 迴圈，把 live switch 的 packet-in 路徑也拖垮。
- 證據：
  ```python
  # p4_client.py:473-474
  try:
      self.stub.Write(req)   # ← 無 timeout
  ```
  ```python
  # topology_manager.py:513
  self.install_initial_routes()   # ← 在 handle_packet_in 內呼叫
  ```
  ```python
  # topology_manager.py:484
  def handle_packet_in(self, device_id, ingress_port, payload):
      # ← 這是 P4RuntimeClient.sample_callback / packet_in_callback，
      #   由 _stream_receiver 執行緒呼叫 (p4_client.py:64, 98-99)
  ```
- 建議：
  1. 所有 `stub.Write()` 呼叫都應傳入 `timeout=` 參數（至少 `delete_ipv4_route`、`modify_ipv4_route` 也有一樣問題）。
  2. `install_initial_routes()` 不該在 packet-in 執行緒內執行；應排入工作佇列由獨立執行緒處理，或至少用 `threading.Thread` 另開執行緒以免阻塞串流接收。

### H2. NetworkX 圖 (`self.net`) 無執行緒同步，多個串流接收執行緒並發修改
- 位置：`topology_manager.py:512`（`add_link`）、`topology_manager.py:513`（`install_initial_routes` → `calculate_all_paths`）、`topology_manager.py:484-513`（`handle_packet_in` 整體）
- 現象：
  `handle_packet_in` 由各 switch 的 `_stream_receiver` 執行緒呼叫，多個執行緒可能同時執行。其內呼叫 `self.net.has_edge()`、`self.add_link()`、`self.install_initial_routes()`（內含 `self.calculate_all_paths()` 讀取 `self.net`），全部沒有鎖保護。
  NetworkX 的 `DiGraph` **不保證執行緒安全**（其底層是 Python dict 操作，dict 的單個操作在 CPython 受 GIL 保護，但複合操作如 `has_edge` + `add_edge` 之間有 check-then-act 競爭）。
- 為什麼不合理：
  同樣的 LLDP beacon 可能從兩個方向幾乎同時抵達（兩個 switch 互相收到對方的 beacon），兩個執行緒可能同時通過 `has_edge` 檢查，然後各自呼叫 `add_link`。目前 `add_link` 對兩個方向各呼叫一次 `add_edge`，若並發可能導致 edge 屬性不一致或遺失。
  此外，HTTP handler 執行緒（`/v1.0/topology/links` 等）同時讀取 `self.net`，與寫端無同步。
- 證據：
  ```python
  # topology_manager.py:509-513
  edge_exists = self.net.has_edge(src_dpid, device_id)
  if not edge_exists:
      print(...)
      self.add_link(src_dpid, device_id, src_port, ingress_port)
      self.install_initial_routes()
  ```
  `has_edge` 和 `add_link` 之間沒有鎖。`add_link` 本身也非 atomic（兩次 `add_edge`）。
- 建議：對所有 `self.net` 的讀寫操作使用 `threading.Lock()` 保護；或將 LLDP 處理全部序列化到一個專門的執行緒。

### H3. LLDP discovery 執行緒無法停止：無 stop flag、無 thread 參考
- 位置：`topology_manager.py:599-610`
- 現象：
  ```python
  def start_lldp_discovery(self):
      def _loop():
          while True:                        # ← 無退出條件
              for dpid, client in list(self.switches.items()):
                  for port in self.lldp_ports_for(dpid):
                      pkt = self.create_lldp_packet(dpid, port)
                      client.send_packet_out(port, pkt)
              time.sleep(LLDP_BEACON_INTERVAL_S)
      t = threading.Thread(target=_loop, daemon=True)
      t.start()
  ```
  - `while True` 沒有檢查任何 stop flag。
  - 執行緒參考 `t` 是區域變數，沒有存入 `self`，外界完全無法 join 或停止它。
  - `main.py` shutdown handler（line 170-176）呼叫 `topo.stop_liveness_polling()` 但**沒有對應的 `stop_lldp_discovery()`**。
- 為什麼不合理：這是半成品。liveness polling 有 `start`/`stop` 對稱設計，LLDP discovery 卻只有 `start`。測試或重啟場景下無法優雅停止。
- 建議：加入 `self._lldp_running` flag 與 `stop_lldp_discovery()` 方法，並在 `main.py` shutdown 中呼叫。

### H4. `KernelNotifier.link_failure` / `link_recovery` 已實作但從未被呼叫——link 失效無法被偵測或回報
- 位置：`kernel_notifier.py:93-105`（定義）、全 repo 搜尋結果（無呼叫點）
- 現象：
  `KernelNotifier` 提供了 `link_failure(src_dpid, src_port, dst_dpid, dst_port)` 和對稱的 `link_recovery`，格式與 `intelligent_router.py` 一致。但 grep 整個 repo 的結果：
  - `kernel_notifier.py` 的 `link_failure` 與 `link_recovery` **只在定義處出現**，無任何呼叫點。
  - `topology_manager.py` 的 `handle_packet_in` 只偵測**新 link 出現**（`if not edge_exists: add_link`），不偵測 link 消失。
  - 測試檔 `test_kernel_notifier.py` 也**沒有**測試這兩個方法（grep 結果為空）。

  所以當一條 link 斷掉時，核心永遠不會收到通知，圖上的 edge 永遠不會被標記為 disabled。
- 為什麼不合理：這是半成品——功能已寫好（含正確的 request body 格式），但沒有接上。LLDP 原本就該用來偵測 link 失效（beacon 停止抵達），但目前只用了新增方向。
- 證據：`grep -r "link_failure\|link_recovery"` 在整個 repo 只在 `kernel_notifier.py` 找到定義。
- 建議：在 `topology_manager.py` 加入 beacon timeout 偵測（例如超過 N 秒沒收到某 neighbor 的 LLDP 則呼叫 `kernel.link_failure`，恢復時呼叫 `link_recovery`）。

## 中嚴重度發現

### M1. P4 `flow_5tuple` 表存在但 proxy 從不寫入——5-tuple 規則實作只完成一半
- 位置：`topology_manager.py:27-28`（註解承認）、`p4_src/ndtwin_switch.p4:307-325`（表定義）、`topology_manager.py:304-354`（`route_flow` 只用 `ipv4_lpm`）
- 現象：
  P4 pipeline 中有 ternary `flow_5tuple` 表（含 priority、L4 port key），但 `route_flow`、`unroute_flow`、`modify_flow` 全部只操作 `ipv4_lpm` 表。
  註解（line 27-28）寫道：「The pipeline does have a ternary flow_5tuple table with real priority (Phase 4); wiring route_flow to it is the proper fix and remains Phase 3 work.」
  這是誠實的承認，但表示 5-tuple 規則（含 priority）目前完全無法透過 proxy 安裝。核心送來的 5-tuple OpenFlow 規則會被 `unsupported_match_fields` 拒絕（400），而非安裝到正確的 `flow_5tuple` 表。
- 為什麼不合理：半成品。`flow_5tuple` 表及其 counter、`ryu_flow_stats.py` 的對應轉譯邏輯都已到位，只差 `route_flow` 的接線。而且這不是隱藏的半成品——核心若嘗試安裝 5-tuple 規則會直接被 400 拒絕，功能缺口是外顯的。
- 建議：完成 `route_flow` 對 `flow_5tuple` 的寫入路徑。

### M2. `stop_liveness_polling` 僅設 flag，不 join 執行緒
- 位置：`topology_manager.py:557-558`
- 現象：
  ```python
  def stop_liveness_polling(self):
      self._liveness_running = False
  ```
  只設旗標，不呼叫 `self._liveness_thread.join()`。執行緒是 daemon，所以 process 結束時會被強制終止，但若在測試中或嵌入式使用時呼叫 stop 後馬上讀取 `_last_probe`，可能讀到執行緒還在跑的過渡狀態。
- 對比：`P4RuntimeClient.stop()`（`p4_client.py:156-161`）有正確實作 join with timeout。
- 建議：加入 `if self._liveness_thread: self._liveness_thread.join(timeout=...)`。

### M3. `test_10_routes.py` 使用錯誤埠號 8080，與 proxy 預設 8081 不符
- 位置：`test_10_routes.py:4`
- 現象：
  ```python
  PROXY_URL = "http://127.0.0.1:8080/stats/flowentry/add"
  ```
  `main.py:179` 執行 `uvicorn.run(app, host="0.0.0.0", port=8081)`。除非手動覆蓋，這個 script 永遠連不上 proxy。
- 建議：修正為 8081，或從環境變數讀取。

### M4. `requirements.txt` 缺少 `requests` 依賴
- 位置：`requirements.txt`、`kernel_notifier.py:28`（`import requests`）
- 現象：`KernelNotifier` 使用 `requests` 庫，但 `requirements.txt` 未聲明。在乾淨 venv 中安裝依賴後執行 proxy 會在 import 時失敗。
- 建議：加入 `requests>=2.28.0`。

### M5. `send_packet_out` 的 metadata ID 使用 hardcoded 魔術數字
- 位置：`p4_client.py:101-114`
- 現象：
  ```python
  meta.metadata_id = 1      # egress_port
  ...
  meta_pad.metadata_id = 2  # _pad
  ```
  對比 `sflow_emitter.py:344-348` 對 packet-in metadata 定義了命名常數（`PKTIN_META_REASON = 1` 等）。packet-out 的 metadata ID 同樣是 positional，卻用 literal，不一致且脆弱。
- 建議：在 `sflow_emitter.py`（或 `p4_client.py`）加入 `PKTOUT_META_EGRESS_PORT = 1`、`PKTOUT_META_PAD = 2` 常數。

### M6. Liveness probe 是序列迴圈，switch 數量多時實際探測間隔遠大於宣稱的 2 秒
- 位置：`topology_manager.py:534-552`
- 現象：
  註解（line 200-201）說 `LIVENESS_PROBE_INTERVAL_S = 2.0` 是探測間隔。但迴圈是：
  ```python
  for dpid, client in list(self.switches.items()):
      result = client.probe(timeout_s=1.5)   # 每個 switch 序列等待
  time.sleep(2.0)
  ```
  每個 dead switch 耗盡 1.5s timeout。10 個 switch 中若有 3 個 dead，一輪探測就需 ~4.5s + 2s sleep = 6.5s。每個 switch 的實際探測間隔是 6.5s 而非 2s。
- 為什麼不合理：註解讓人誤以為每個 switch 每 2 秒被探測一次。雖然核心有自己的 timeout 政策，但這個設計讓 dead switch 拖慢 live switch 的探測更新率。
- 建議：使用 `concurrent.futures.ThreadPoolExecutor` 並發探測所有 switch，或至少註解說明序列行為。

### M7. `MalformedMatchError.__init__` 直接呼叫 `ValueError.__init__` 跳過父類別初始化
- 位置：`topology_manager.py:62-66`
- 現象：
  ```python
  class MalformedMatchError(UnsupportedMatchError):
      def __init__(self, value):
          ValueError.__init__(self, f"match must be a JSON object, got {type(value).__name__}")
          self.fields = []
  ```
  MRO：`MalformedMatchError` → `UnsupportedMatchError` → `ValueError`。直接呼叫 `ValueError.__init__` 跳過 `UnsupportedMatchError.__init__`。
  這是**故意的**（因為 `UnsupportedMatchError.__init__` 的簽名是 `(fields)` 而非 `(message)`），但脆弱：若未來 `UnsupportedMatchError.__init__` 新增共用邏輯（如 logging），`MalformedMatchError` 不會執行到。
- 證據：註解（line 54-59）說明了子類別化的理由（讓現有 `except UnsupportedMatchError` 仍能捕捉），但沒有說明為何跳過 super。
- 建議：重構 `UnsupportedMatchError` 使用 `__new__` 或 classmethod factory，或至少在 `MalformedMatchError.__init__` 內加上顯式註解說明為何不呼叫 super。

### M8. `install_initial_routes()` 使用 `self.net.edges[src, next_node]` 可能拋出 KeyError
- 位置：`topology_manager.py:429`
- 現象：
  ```python
  path = path_info['path']
  next_node = path[path.index(src) + 1]
  out_port = self.net.edges[src, next_node]['port']  # ← 可能 KeyError
  ```
  若 `calculate_all_paths()` 和這行之間圖被修改（edge 被移除），`self.net.edges[src, next_node]` 會拋出 `KeyError`。此 exception 會穿透 `handle_packet_in` → `_stream_receiver` → 終止該 switch 的串流接收執行緒。
- 建議：使用 `.get_edge_data(src, next_node, default={}).get('port', 0)` 防禦性取值（如同 `ryu_topology.py:162` 的寫法）。

## 低嚴重度發現

### L1. 未使用的 import：`BackgroundTasks` 與 `json`
- 位置：`api_routes.py:1-2`
- 現象：`BackgroundTasks` 在 import 後從未被使用；`json` 也同樣未被使用。
- 建議：移除未使用的 import。

### L2. `KernelNotifier` 無 `close()` 方法，`requests.Session` 永不關閉
- 位置：`kernel_notifier.py:39-52`
- 現象：`__init__` 建立 `requests.Session()`，但類別無 `close()` 方法，`main.py` shutdown 中也沒關閉它。
- 建議：加入 `close()` 方法並在 shutdown handler 中呼叫。

### L3. 歸屬註解放錯位置
- 位置：`topology_manager.py:407`
- 現象：
  ```python
  # Developed in collaboration with Gemini 3.1 Pro.
      def install_initial_routes(self):
  ```
  這行註解出現在 `modify_flow` 方法之後、`install_initial_routes` 之前，縮排與類別方法不對齊（0 縮排而非 4）。它看起來像是寫在 class 層級但意外放在方法之間。
- 對比：其他檔案的同樣註解都放在檔尾（`api_routes.py:129`、`p4_client.py:575`、`main.py:181`、`mininet/p4_testbed_topo.py:299`）。
- 建議：移到檔尾或移除。

### L4. P4 `l2_forward` 表從未被 proxy 寫入，所有未知 L2 封包送往 CPU 後被沉默丟棄
- 位置：`p4_src/ndtwin_switch.p4:344-359`（表定義）、`topology_manager.py:484-501`（`handle_packet_in` 只處理 LLDP）
- 現象：`l2_forward` 表的 default action 是 `send_to_cpu()`。非 LLDP 的 packet-in（如未知 MAC 的 ARP）到達 proxy 後，`parse_lldp_packet` 回傳 None，然後…什麼都不做。封包被用於 liveness 證據，但其內容被丟棄。Proxy 沒有 MAC learning 或 flooding 邏輯。
- 為什麼是低：Mininet 拓撲使用靜態 ARP 條目，所以這在目前部署中不會觸發。但若未來有人拿掉靜態 ARP 或新增 host，這個行為會很難診斷。
- 建議：至少在 log 中記錄非 LLDP packet-in 的計數，或明確宣告這不是 bug。

## 註解宣稱查證表

| 註解位置 | 它宣稱什麼 | 查證結果 |
|----------|-----------|---------|
| `sflow_emitter.py:17-18` | 「measured from a real capture (tests/fixtures/, 2863 samples, 100% consistent)」 | 部分可驗證。fixtures 目錄存在於 repo root `tests/fixtures/`（31 個 `.bin`），但無法驗證「2863 samples」的數量（檔案總數 31 個，每個可能含多個 sample）。`test_sflow_emitter.py` 確實有載入 fixtures 做欄位比對。**無法確認 2863 這個數字。** |
| `sflow_emitter.py:53-54` | 「the parser reads record[0]'s length and skips that many words... Emitting a single-record sample would make it skip six words」 | **未驗證**。這描述的是核心 C++ parser 的行為，不在 p4_proxy/ 範圍內。需要讀取 `src/` 中的 parser 原始碼才能確認。 |
| `topology_manager.py:27` | 「The pipeline does have a ternary flow_5tuple table with real priority (Phase 4); wiring route_flow to it is the proper fix and remains Phase 3 work.」 | **正確**。P4 中 `flow_5tuple` 表確實存在（`p4_src/ndtwin_switch.p4:307-325`），proxy 確實未接上（`route_flow` 只寫 `ipv4_lpm`）。「Phase 3 work」與「Phase 4」的矛盾（說 Phase 4 的 table 等待 Phase 3 接線）暗示計畫順序與實作順序不一致。 |
| `topology_manager.py:145-153` | 「The beacon used to be sourced from `00:00:00:00:00:{dpid:02x}`, which **is** the host MAC range: main.py registers hosts as 00:00:00:00:00:01 through :04」 | **正確**。`main.py:16-19` 確實註冊 h1-h4 為 `00:00:00:00:00:01` 到 `:04`。s1-s4 的 dpid 為 1-4，所以舊的 beacon source MAC 格式會與 host MAC 完全重疊。 |
| `topology_manager.py:153` | 「`bytes.fromhex(f"...{dpid:02x}")` raises for any dpid >= 256」 | **正確**。`f"{256:02x}"` = `"100"`（3 個 hex digits），`bytes.fromhex("...100")` 在 Python 中會拋出 `ValueError: non-hexadecimal number found in fromhex()` 因為奇數長度？實際上 `"00000000000100"` 是偶數長度（14 個 hex chars = 7 bytes），但原始格式是 `00:00:00:00:00:{dpid:02x}` 去冒號後變 `000000000000XX`（12 hex chars），dpid=256 時 `{dpid:02x}` = `"100"`，整個字串變成 `"000000000000100"`（15 chars，奇數），確實會報錯。 |
| `api_routes.py:17-19` | 「measured on a live kernel it took switches from 0/10 to 10/10 enabled but left edges at 0/40」 | **無法驗證**。這描述的是測試時的觀察，無從查證。但邏輯一致：`updateLinks()` 需要 `/v1.0/topology/links` 端點才能啟用 edge。 |
| `api_routes.py:115-118` | 「The two branches after the raise were unreachable. More importantly the raise itself fired on every *successful* modify」 | **可從 git 紀錄推論**。`commit df73e44` 和 `c18b4c9` 修改了 `api_routes.py`。當前邏輯是 `if not success: raise`（正確），舊邏輯應為無條件 raise。`p4_client.py:563-564` 的註解確認 `modify_ipv4_route` 一度缺少 `return True`。 |
| `p4_client.py:235-237` | 「Measured against a real bmv2: inserting an existing session returns **UNKNOWN with an empty details string**, not ALREADY_EXISTS」 | **無法驗證**（需要 bmv2 實機）。但 commit `0843a6c` 的 message 「Fix the clone-session fallback: bmv2 says UNKNOWN, not ALREADY_EXISTS」與程式碼改動一致。這屬於實測結論，合理。 |
| `kernel_notifier.py:12-13` | 「inform_switch_entered matters most: it is the **only** path that sets `isEnabled` on a vertex」 | **無法驗證**。這描述的是核心 C++ 端的行為，不在 p4_proxy/ 範圍內。需要讀取 `src/` 中 `HttpSession` 的實作。 |
| `ryu_flow_stats.py:19-22` | 「Classifier::parseActionsArrayIntoEffect parses *only* the string form; `{"type": "OUTPUT", "port": N}` is silently ignored」 | **無法驗證**。同樣是核心 C++ 行為。但 proxy 確實輸出字串格式（`f"OUTPUT:{port}"`），符合其自身建議。 |
| `ryu_topology.py:17` | 「`/ndt/inform_switch_entered` was expected to be sufficient, but…edges are enabled by `updateLinks()`, which only runs off this poll」 | **無法完全驗證**，但邏輯自洽：proxy 提供了 `/v1.0/topology/links` 端點，而 `kernel_notifier.py` 的 `switch_entered` 只通知 vertex。若核心需要分別啟用 vertex 和 edge，則兩個缺一不可。 |

## 逐類檢查記錄

### 1. 改動與 commit message 宣稱的意圖不符
檢查了範圍內 20 個 commit 的 message 與實際 diff。由於這是全新子系統，多數 commit 是累積建構。以下幾個值得注意：
- `0843a6c`（「Fix the clone-session fallback: bmv2 says UNKNOWN, not ALREADY_EXISTS」）：diff 確實將 INSERT 失敗的處理從只檢查 `ALREADY_EXISTS` 改為任何失敗都嘗試 MODIFY。**一致。**
- `c964946`（「Refuse match fields ipv4_lpm cannot express」）：diff 加入了 `unsupported_match_fields()` 和 `UnsupportedMatchError`。**一致。**
- `a8db425`（「Report bmv2 switch liveness from evidence instead of asserting it」）：diff 加入了 `_liveness_lock`、`_last_packet_in`、`_last_lldp_from`、`_last_probe` 以及 `switch_liveness()` 方法。**一致。**
- 未發現夾帶無關改動的 commit（因為這是全新子系統，每個 commit 都屬於 P4 支援工作）。

### 2. 註解宣稱的事實與程式碼不符
詳見上方「註解宣稱查證表」。發現一條**明確不準確**的宣稱：
- `topology_manager.py:27` 說 `flow_5tuple` 的接線是「Phase 3 work」，但 `flow_5tuple` 表本身在 `p4_src/SPEC.md:34` 被標為 Phase 4。同一句子內 Phase 4/Phase 3 的矛盾暗示計畫順序與實作順序不一致，但這是文件問題而非程式碼錯誤。

其餘宣稱多數描述的是核心 C++ 端行為，無法在 p4_proxy/ 範圍內驗證，但邏輯與程式碼自洽。

### 3. 治症狀不治病
- **H1** 是典型：`insert_ipv4_route` 用 `try/except grpc.RpcError` 包住 `Write()`，但不設 timeout，所以 exception 永遠不會被觸發。這只是「包住了症狀」，根因（無 timeout 的 blocking call）沒解決。
- `install_initial_routes` 被呼叫在 packet-in 路徑上，每次新 link 都重算所有路徑並寫入所有 switch。這是「拓撲改變就全量重裝」的暴力法，而非漸進更新。
- 同樣的無-timeout `Write()` 模式存在於 `delete_ipv4_route`（line 518）、`modify_ipv4_route`（line 568），grep 確認三處都有相同問題。

### 4. 不一致
- **M5**：`send_packet_out` 用 hardcoded metadata ID（1, 2），而 packet-in metadata 在 `sflow_emitter.py` 有命名常數（`PKTIN_META_REASON = 1` 等）。
- `P4RuntimeClient.stop()` 有 join with timeout（`p4_client.py:160`），但 `stop_liveness_polling()` 沒有（**M2**），`start_lldp_discovery` 更完全沒有 stop 機制（**H3**）。
- `handle_packet_in` 的 liveness 更新有 `_liveness_lock` 保護，但同一函式內的圖操作（`has_edge`/`add_link`）完全無鎖（**H2**）。
- `install_initial_routes` 使用 `self.net.edges[src, next_node]['port']`（直接索引，可能拋 KeyError），而 `ryu_topology.py:162` 使用 `.get_edge_data(..., default={}).get('port', 0)`（防禦性）。同一 repo 內有兩種風格。

### 5. 過度工程
- `ryu_topology.py` 的 `_dpid_hex`、`_port_hex` 指定了固定寬度（`DPID_HEX_WIDTH = 16`、`PORT_HEX_WIDTH = 8`），註解說「matching them keeps the payloads diffable against a real Ryu capture」。這有實際測試價值（diffable），不算是過度。
- `sflow_emitter.py` 的 `SwitchAgent` 類別有完整的 sequence number wrapping、sample pool 估算邏輯。這些是 sFlow 協定所需的，不算過度。
- 整體來說，這個子系統的抽象層次合理，未發現明顯的過度工程。

### 6. 新引入的缺陷
- **H1**（無 timeout 的 gRPC call 阻塞串流執行緒）
- **H2**（並發圖操作無鎖）
- **H3**（LLDP 執行緒無法停止）
- **M8**（`KeyError` 風險）
- `main.py:87` 的 `except Exception` 攔截範圍過寬（含 `MemoryError` 等），雖有 `# noqa: BLE001` 標記，但可能隱藏程式錯誤。
- `topology_manager.py:325` 中 `match_dict.get("nw_dst") or match_dict.get("ipv4_dst")` 若 `nw_dst` 為空字串 `""`，`or` 會落入 `ipv4_dst`。空字串是無效 IP，但目前下游的 `insert_ipv4_route` 會讓 `socket.inet_aton("")` 拋出 `OSError`，該 exception 沒有被捕獲（`insert_ipv4_route` 只捕獲 `grpc.RpcError`），會導致 500。這是邊界條件缺陷。

### 7. 效能退步
- **M6**：序列化 liveness probe 使 per-switch 探測率受 dead switch 數量影響。
- `install_initial_routes()` 在每次新 link 發現時重算所有路徑（O(V³) 的 BFS all-pairs）並對所有 switch 發起 gRPC Write。若 40 條 link 逐一被發現，這會被呼叫 40 次（實際上因為 `if not edge_exists` guard，每個方向只觸發一次，所以是 40 次）。每次都是全量計算＋全量寫入，而非漸進更新。
- `send_packet_out` 對每個 LLDP beacon 建立新的 protobuf 物件，但這是每個 switch 每 5 秒每 port 一次，數量不大。

### 8. 半成品與死碼
- **H4**：`KernelNotifier.link_failure` / `link_recovery` 已定義但從未被呼叫。
- **M1**：`flow_5tuple` P4 表未被 proxy 使用。
- `l2_forward` P4 表未被 proxy 寫入（**L4**）。
- `BackgroundTasks` import 未使用（**L1**）。
- `test_10_routes.py` 埠號錯誤，無法運作（**M3**）。
- 無 `TODO` 或 `FIXME` 標記。

### 9. 可回退性
- 由於這是全新子系統，所有 commit 都是同一功能線的一部分。若需回退整個 P4 支援，可以 revert 到 `28b8b13`。
- 在子系統內部，`0843a6c`（clone session fallback）與 `f62d468`（only program clone session when start() pushed pipeline）是相關的，但它們處理的是同一功能的兩個面向，分開回退會導致 clone session 行為不一致。這是合理的耦合。
- `c964946`（refuse unsupported match fields）與 `c18b4c9`（hex ethertype, non-object match）是同一嚴格化工作的兩個部分；但它們修改的是不同函式（`unsupported_match_fields` vs `parse_eth_type` + `MalformedMatchError`），可以獨立回退。
- 整體可回退性尚可，未發現將無關改動捆綁的 commit。

## 無法判定

1. **核心 C++ parser 的 sFlow 解析行為**：`sflow_emitter.py` 的註解大量描述核心 parser 的固定 offset 行為（如「flowDataLength = data[index + 11]」）。這些描述無法在 p4_proxy/ 範圍內驗證，需檢視 `src/` 中的 parser 原始碼。

2. **「2863 samples, 100% consistent」**：fixtures 目錄有 31 個 `.bin` 檔案，但無法確認是否總計 2863 個 sample 以及是否真的 100% consistent。

3. **核心 `isEnabled` 語意**：`kernel_notifier.py` 宣稱 `inform_switch_entered` 是唯一設定 `isEnabled` 的路徑。需要檢視核心 `HttpSession` 實作才能確認。

4. **`Classifier::parseActionsArrayIntoEffect` 只接受字串格式**：`ryu_flow_stats.py` 的宣稱，需檢視核心 C++ 程式碼。

5. **`/ndt/inform_switch_entered` 啟用 switch vertex 但不啟用 edge**：`ryu_topology.py` 與 `api_routes.py` 的宣稱，需要從核心 `TopologyAndFlowMonitor` 原始碼驗證。

### 補充發現：`install_initial_routes()` 忽略 `insert_ipv4_route` 的回傳值
- 位置：`topology_manager.py:433`
- 現象：
  ```python
  client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port)
  ```
  與 `route_flow`（line 354）不同，此處不檢查回傳值。若寫入失敗（switch 無回應、rule 衝突），呼叫者完全不知情，且沒有 log。
- 建議：至少 log 失敗；或收集失敗清單在函式結尾彙總印出。

### 補充發現：`handle_packet_in` 中的空字串 `nw_dst` 會導致 500
- 位置：`topology_manager.py:325`、`p4_client.py:456`
- 現象：
  ```python
  ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")
  ```
  若 `nw_dst` 為空字串 `""`（falsy），會落入 `ipv4_dst`。若後者也是空字串，則 `socket.inet_aton("")` 在 `insert_ipv4_route` 中拋出 `OSError`，該 exception 不被 `try/except grpc.RpcError` 捕獲，最終變成 HTTP 500。
- 建議：在 `route_flow`/`unroute_flow`/`modify_flow` 中加入 `if not ipv4_dst: return False`（`route_flow` line 327 已有此 guard，但之後才檢查；然而若 `nw_dst` 是空字串，`False or match_dict.get("ipv4_dst")` 的行為取決於 `ipv4_dst` 的值——若也是空字串，guard 會觸發。所以此問題僅在 `ipv4_dst` 也是空字串或 None 時才成立。目前的 guard 已處理此情況。**經重新檢查，此項為誤報——既有 guard 已涵蓋。**）

（更新：經重新審視，`route_flow` line 327 `if not ipv4_dst: return False` 已處理空字串情況。撤銷此發現。）


---
### 更正
經重新檢查，上一則「補充發現：空字串 `nw_dst` 會導致 500」為**誤報**。`route_flow`（line 327）、`unroute_flow`（line 371）、`modify_flow`（line 389）均有 `if not ipv4_dst: return False` guard，已正確處理空字串情況。已從發現清單中撤銷。


---

## 最終統計

| 嚴重度 | 數量 | 編號 |
|--------|------|------|
| 高 | 4 | H1-H4 |
| 中 | 8 | M1-M8 |
| 低 | 4 | L1-L4 |

**核心建議優先修復**：
1. **H1**：所有 `stub.Write()` 加上 timeout；`install_initial_routes()` 移出串流接收執行緒。
2. **H2**：為 `self.net` 操作加上鎖，或將 LLDP 處理序列化到單一執行緒。
3. **H3**：為 LLDP discovery 加入 stop 機制。
4. **H4**：在 LLDP 處理中加入 beacon timeout 偵測，接上 `link_failure`/`link_recovery`。

**附帶**：`requirements.txt` 補上 `requests`（M4）、`test_10_routes.py` 修正埠號（M3）。
