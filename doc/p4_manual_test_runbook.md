# P4/bmv2 手動測試 runbook

**這份文件是做什麼的**：從乾淨環境開始，逐步啟動 P4/bmv2 stack，在 idle 狀態下確認靜態健康，灌流量驗證 telemetry 鏈路，模擬一條鏈路斷線後觀察偵測與恢復，最後檢查 `admin_disabled` 欄位。全部手動執行，一步一確認。

**什麼時候跑**：任何對 P4 路徑（proxy、bmv2 pipeline、sFlow emitter、kernel 的 P4 分支）的修改之後，以及開始 Phase 7（power management）之前。Phase 7 還不存在，本文件不涵蓋它。

**涵蓋範圍**：Phase 1–6 全部完成的功能。以下這些從舊文件來的宣稱是錯的，不要照抄：

- ~~「P4 模式的 `stack.sh wait` 永遠 timeout，`enabled=0`」~~ — 現在會收斂。
- ~~「P4 的 `is_up` 是 stub，要改用 `is_enabled` 判斷」~~ — `is_up` 是真的。
- ~~「P4 模式圖是死的、`path` 是 `[]`、link usage 是 0」~~ — 全部是活的。
- ~~「看 kernel.log 的 `addressed=` 有沒有增加來判斷流量夠不夠」~~ — 那行只在第一輪是 INFO，之後是 TRACE，所以只會出現一次，且 `rx=0`。見 `FlowLinkUsageCollector.cpp:1798-1801`。
- ~~OVS runbook 的 port 是 P4 的~~ — P4 模式不跑 Ryu，port 不同。

本文件建立於 Phase 6 完成之後，對應 `doc/environment_gotchas.md` 的陷阱、`doc/full_test_runbook.md` 的 ✅/⚠️ 慣例。

**名稱刻意不帶 phase 編號。** 它涵蓋到 Phase 6，Phase 7 開工前跑一次；之後每個 phase 應該延伸這一份，
而不是各自新增一份互相矛盾的文件。

> **驗證紀錄（2026-08-10）**：§4 的每一條 idle 檢查都在活的 stack 上實跑過，數值與本文所寫一致
> （10/10/4/40、12 個 node key、power 10 筆 33466–147622 mW、avg usage 0.0、每台 4 條 flow、
> 0 個 detected flow、10 台 `probe_ok`、12 條路徑、clone session ×10／failed ×0／seeded ×1）。
> 引用的行號（`FlowLinkUsageCollector.cpp:507`、`:1798-1801`、`TopologyAndFlowMonitor.cpp:1793-1795`）
> 都開檔確認過，`?dpid=` 真的回 404、`get_num_of_flows_passing_a_switch` 真的只吃 POST 也確認過。
> §5–§6 的數值來自 2026-08-10 的實測，未在這次重跑（跑了會打斷你正在用的 stack）。

---

## 0. 這份文件要回答什麼

每個「你應該看到」都有精確的預期值。每個檢查如果可以「通過但原因不對」，會標出來。每個步驟標了誰能跑。本文件**不是** OVS/P4 基準比對——那份在 `doc/full_test_runbook.md`。這裡只測 P4 路徑本身是否健康。

---

## 1. 前置：確認起點乾淨

### 誰能做什麼

| 只有 Adam 能做 | 為什麼 |
|---|---|
| `sudo python3 p4_testbed_topo.py` | 需要互動式 root，`sudo -n python3` 會要密碼 |
| `sudo mn -c` | 同上 |
| `mininet> exit` | 在你的互動 CLI 裡 |
| `sudo -n ifconfig <iface> down/up` | NOPASSWD 有放行，但需要 root |
| `mn`、`ip`、`ovs-ofctl`、kill root process | NOPASSWD 不含這些 |

| 我可以代跑 | 方式 |
|---|---|
| `stack.sh up/wait/down`、`l1_unit_tests.sh` | 不需要 root |
| `curl` 檢查、log 分析 | — |
| `sudo -n mnexec -a <pid> <cmd>` | NOPASSWD 放行了 `mnexec`，可在 host namespace 內以 root 執行 |

### Terminal 安排

| | 用途 | 生命週期 |
|---|---|---|
| **B** | Mininet CLI（`sudo`，會停在 `mininet>`）—— **Adam 的** | 全程留著 |
| **A** | `stack.sh` / `curl` / 看 log | 我可以代跑 |

### 確認乾淨（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh down
sudo mn -c
pgrep -x ndtwin_kernel; pgrep -x simple_switch_g; pgrep -x iperf
#                        ^^^ 15 字元上限，寫 simple_switch_grpc 永遠匹配不到
pgrep -af "[t]estbed_topo.py"          # 中括號避免匹配到自己的 shell
pgrep -af "[p]4_testbed_topo.py"
ss -ltn '( sport = 8000 or sport = 8080 or sport = 8081 )'
```

✅ 上面六個查詢**全部沒有輸出**才算乾淨。

⚠️ **`pgrep -x ndtwin_kernel` 一定要是空的。** 殘留在 `:8000` 的 kernel 會讓 `stack.sh up` 印出 `waiting for kernel API on :8000  up` 然後**假成功**——它自己起的 kernel 死於 `bind: Address already in use`，但 port 有人聽所以它以為成功了。`wait_for_port` 現在會檢查 socket 擁有者，但起點乾淨仍是第一道防線。

⚠️ **`pgrep -f p4_testbed_topo.py`（沒有中括號）會匹配到你自己下的那道指令**，看起來永遠像有 Mininet 在跑。這個陷阱騙過人不只一次。

---

## 2. 離線層：build + unit tests（約 6 分鐘，不需要 Mininet）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow

# C++ build + unit tests（ctest + 直接執行）
./l1_unit_tests.sh
```

**通過標準**：

```
L1 passed: 1 test binary/binaries, clean under ctest and direct execution.
```

⚠️ 看到 **`NO TESTS RAN` 是失敗，不是通過**——表示那個檔案一個測試都沒真的跑到（通常是缺套件）。

**預期數字（2026-08 實測）**：

| 項目 | 數量 |
|---|---|
| C++ 測試（直接執行） | 426 pass |
| p4_proxy Python 測試 | 312 條，分布在 12 個檔案 |
| kernel-side Python/shell 測試 | 101 條，分布在 2 個檔案（`tests/python/`） + 1 個 shell（`tests/shell/`） |

⚠️ C++ 測試必須**兩種跑法都通過**——`ctest` 每個 test case 開獨立 process，會掩蓋 suite 級別的失敗（例如 static init 順序、singleton 殘留狀態）。`l1_unit_tests.sh` 兩種都跑，並且交叉比對 ctest 註冊數和 gtest 發現數是否一致。

⚠️ `test_p4_client.py` 整份 skip 是**預期行為**——它需要真實 bmv2 在 `:50051` 上跑，檔案裡有 `NDTWIN_L1_OPT_IN` 標記。不是失敗。

### P4 pipeline 編譯（可選，除非改了 P4 程式本身）

```bash
./l0_build_check.sh p4
```

✅ 看到（實測輸出）：

```
  P4 pipeline                  PASS  (.test_run/logs/build_p4.log)
...
All selected components build.
```

---

## 3. 起 stack（P4 順序）

### ⚠️ 重要：P4 的啟動順序和 OVS 相反

| 模式 | 誰是 server | 正確順序 |
|---|---|---|
| OVS | **Ryu** 監聽 :6633，switch 主動連進來 | Ryu → Mininet → 等收斂 → kernel |
| P4 | **bmv2** 監聽 :50051-50060，proxy 是 gRPC **client** | **Mininet → proxy** → 等收斂 → kernel |

`stack.sh up p4` 會走對的順序。kernel 一定要最後開。

### 3a. 開 bmv2 Mininet（terminal B —— Adam）

```bash
sudo python3 /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/p4_testbed_topo.py
```

✅ 要看到：

```
All 10 BMv2 switches verified listening on gRPC 50051 ~ 50060
Switch manifest: /tmp/ndtwin_p4_switches.json
```

然後停在 `mininet>`。

⚠️ **不要只看它印什麼，用腳本自己的驗證確認**：

```bash
cat /tmp/ndtwin_p4_switches.json | python3 -m json.tool | head -20
```

這個 manifest 只列出真的通過 `verify_switches()` 的 switch（process 活著 + gRPC port 有在聽）。如果曾經有殘留 process 佔住 port，對應的 switch 不會出現在 manifest 裡，腳本也會印 `WARNING`。

⚠️ 腳本啟動時會自己跑 `sudo pkill -f simple_switch_grpc` 清殘留，但如果你手動清過 Mininet 後沒跑這步，可能會有孤兒 process。

### 3b. 起 proxy + kernel（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh up p4
```

✅ 你應該看到：

```
[1/3] data plane (bmv2 Mininet, needs sudo)
  Mininet is interactive ...
  Press Enter once Mininet is up ...
```

按 Enter 之後：

```
[2/3] control plane (P4 proxy agent)
  started p4_proxy (pid ...) -> .../p4_proxy.log
  waiting for P4 proxy agent on :8081 ... up

  waiting for link discovery: want 12 destination paths
    paths=12
  converged after 2s
[3/3] kernel
  waiting for kernel API on :8000 ... up

stack up. next: ./stack.sh wait
```

⚠️ **收斂時間約 2 秒**（P4 模式沒有 Ryu 的 hard-coded 60s sleep）。如果你看到 `paths=12` 且 `converged after 2s`，這是正常的。OVS 模式才需要 >60s。

⚠️ 如果 proxy log 出現 `ECONNREFUSED` 到 `:5005x`，代表 bmv2 沒起來——回 3a。

⚠️ kernel log 裡**一筆** `curl` 失敗（對 `:8080` 的連線拒絕）是**預期且自癒的**。原因在 `FlowLinkUsageCollector.cpp:507` 的註解：`start()` 跑在 `loadStaticTopologyFromFile` 之前，所以 `controlPlaneHostAndPort()` 那時候還不知道這是 bmv2 fabric，第一次會去問 Ryu 的 port（`:8080`），拿到空回應；等 topology 載入後切換到 proxy 的 port（`:8081`），之後就正常了。這不是 bug。

### 3c. 等 kernel 收斂

```bash
./stack.sh wait
```

✅ 應該在約 1 秒內輸出：

```
waiting for topology convergence (expect 10 switches up+enabled, timeout 90s)
  switches=10 up=10 enabled=10 edges=40
converged after 1s
```

---

## 4. 靜態健康檢查（idle，無流量）

以下全部在 terminal A 跑 `curl`。kernel 聽在 `localhost:8000`，proxy 聽在 `localhost:8081`。

### 4a. 圖（graph）

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
sw=[n for n in d['nodes'] if n.get('vertex_type')==0]
ho=[n for n in d['nodes'] if n.get('vertex_type')==1]
ed=d.get('edges',[])
print('switches', len(sw), 'up', sum(1 for n in sw if n['is_up']), 'enabled', sum(1 for n in sw if n['is_enabled']))
print('hosts', len(ho), 'up', sum(1 for n in ho if n['is_up']))
print('edges', len(ed), 'up', sum(1 for e in ed if e['is_up']))"
```

✅ 預期：

```
switches 10 up 10 enabled 10
hosts 4 up 4
edges 40 up 40
```

### 4b. 節點 key 檢查

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
keys = sorted(d['nodes'][0].keys())
print('node keys:', keys)
print('count:', len(keys))"
```

✅ 預期 12 個 key（照字母排）：

```
admin_disabled, brand_name, device_layer, device_name, dpid, ecmp_groups, ip, is_enabled, is_up, mac, nickname, vertex_type
```

### 4c. 電力報告

```bash
curl -s localhost:8000/ndt/get_power_report | python3 -m json.tool
```

✅ 預期：一個 JSON array，10 個元素，每個有 `dpid` 和 `power_consumed`（mW）。值落在 33466–147622 mW 之間，各台不同，隔 10 秒再查數字不變（這是合成電力，不是真實量測，所以跨輪詢穩定）。

⚠️ `get_power_report` 回傳的是 bare JSON array（`[{...}, ...]`），不是 `{"status": ..., "data": ...}` 包裝。

### 4d. 平均鏈路使用率

```bash
curl -s localhost:8000/ndt/get_average_link_usage
```

✅ 預期：`{"avg_link_usage":0.0,"status":"success"}`（idle 狀態為 0.0）。

⚠️ 這個端點是 GET，不加 query param，不加 body。

### 4e. Flow table

```bash
curl -s localhost:8000/ndt/get_switch_openflow_table_entries | python3 -c "
import json,sys
tables=json.load(sys.stdin)
for sw in tables:
    dpid=sw.get('dpid','?')
    n=sum(len(v) for v in sw.get('flows',{}).values()) if isinstance(sw.get('flows'),dict) else 0
    print(f'dpid {dpid}: {n} entries')"
```

✅ 預期：10 台 switch，每台 4 條 flow entry（這是 idle 狀態下的 P4 預設規則）。

⚠️ 這個端點是 GET，**不加 `?dpid=`**。加了會 404（因為 dispatch 用 `target == "/ndt/get_switch_openflow_table_entries"` 精確匹配，不是 `starts_with`）。

### 4f. 已偵測 flow

```bash
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('flows:', len(d))"
```

✅ 預期：`flows: 0`（idle 狀態）。

⚠️ 回傳的是 bare JSON array（`[{...}, ...]`），不是 `{"flows": [...]}`。所以 `len()` 直接對解析結果取即可。

### 4g. Proxy 端 switch state

```bash
curl -s localhost:8081/p4/switch_state | python3 -c "
import json,sys; d=json.load(sys.stdin)
sw=d.get('switches',{})
for k,v in sorted(sw.items(), key=lambda x: int(x[0])):
    print(f'{k}: probe_ok={v.get(\"probe_ok\")} stream_alive={v.get(\"stream_alive\")} last_lldp_age_s={v.get(\"last_lldp_age_s\")} last_packet_in_age_s={v.get(\"last_packet_in_age_s\")}')"
```

✅ 預期：10 台 switch，`probe_ok` 全部 `true`，`stream_alive` 全部 `true`，`last_lldp_age_s` 和 `last_packet_in_age_s` 都在約 0–5 秒之間。

### 4h. Proxy 端路徑數

```bash
curl -s localhost:8081/ryu_server/all_destination_paths | python3 -c "
import json,sys; d=json.load(sys.stdin)
paths=d.get('all_destination_paths',[])
print('paths:', len(paths))
for p in paths:
    print('  ', len(p), 'hops:', p[0][0], '->', p[-1][0])"
```

✅ 預期：`paths: 12`（4 台 host，每對雙向各一條，共 4×3=12）。每條路徑長度不一，但第一和最後一個節點是 host IP 字串。

### 4i. Proxy log 關鍵訊息

```bash
grep -E "Clone session|clone session failed|link watchdog seeded" .test_run/logs/p4_proxy.log
```

✅ 預期：

- `[1] Clone session 250 -> port 255 installed` … 一直到 `[10]`，共 10 行。
- **0 行** `clone session failed` 或 `NO telemetry`。
- 1 行 `[TopologyManager] link watchdog seeded with 32 declared links`。

---

## 5. Telemetry（灌流量，邊跑邊查）

### 5a. 灌流量（terminal B —— Adam）

⚠️ **h1 和 h4 在不同交換機上**（h1 在 s1，h4 在 s4），這很重要。同一台交換機底下的 host 互打，`get_average_link_usage` 永遠是 0.0——因為 `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2429`）刻意排除所有接到 host 的邊
（判斷式在 `:2455-2456`），那不是 bug。

```
mininet> h1 ping -c 20000 -i 0.002 10.0.0.4
```

（或用 `mnexec` 代跑：`sudo -n mnexec -a $(ps -eo pid,args | awk '$NF=="mininet:h1"{print $1}') ping -c 20000 -i 0.002 10.0.0.4`）

這個指令以 ~500 pps 持續發送。讓它跑著，以下檢查在它**還在跑**的時候做。

⚠️ **flow 會在流量停止後幾秒內老化歸零**。所以查詢必須在 ping 還在跑的時候做。

⚠️ **P4 的 sFlow 是 1/256 取樣**。ping 每秒 1 個封包要 256 秒才產生一個 sample。用 `-i 0.002`（~500 pps）才能穩定產生 sample。

### 5b. 確認流量有被觀測到（terminal A）

```bash
# kernel log 的 sFlow ingest 健康線（只會有一行 INFO，其餘是 TRACE）
grep "sFlow ingest healthy" .test_run/logs/kernel.log
```

✅ 預期：至少一行，`rx=` 和 `addressed=` 都有值。**`rx` 是收到的 datagram 總數（含 counter sample），`addressed` 是成功歸戶的 flow sample 數。** idle 時 `addressed=0` 是正常的；有 traffic 時應該 > 0。

⚠️ 這行在 `FlowLinkUsageCollector.cpp:1798-1801`：第一輪是 INFO，之後是 TRACE。所以 `grep` 只會找到一筆。不要用它判斷「流量夠不夠」——用下面的 `get_detected_flow_data` 判斷。

### 5c. 已偵測 flow

```bash
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('flows:', len(d))
for f in d:
    print('  ', f.get('src_ip'), '->', f.get('dst_ip'),
          'proto', f.get('protocol_id'),
          'rate_bps', f.get('estimated_flow_sending_rate_bps_in_the_last_sec'),
          'path_len', len(f.get('path',[])))
    # print path nodes
    path_nodes = [hop['node'] for hop in f.get('path',[])]
    print('    path:', path_nodes)"
```

✅ 預期（ping h1 → 10.0.0.4）：

```
flows: 2
   10.0.0.1 -> 10.0.0.4 proto 1 rate_bps 80281-200704 path_len 7
   10.0.0.4 -> 10.0.0.1 proto 1 rate_bps ... path_len 7
```

- 雙向 ICMP（proto 1），type 8 code 0（request）和 type 0 code 0（reply）。
- 路徑長 7 跳（含起點和終點 host IP），例如 `['10.0.0.1', 1, 6, 9, 8, 4, '10.0.0.4']`。
- rate 落在 80281–200704 bps 之間（1/256 取樣的變異，正常）。

### 5d. 平均鏈路使用率（趁流量還在跑，連查三次）

```bash
for i in 1 2 3; do
  curl -s localhost:8000/ndt/get_average_link_usage
  sleep 2
done
```

✅ 預期：**`1e-05` 到 `3e-04` 之間，上下跳動，不是單調爬升。** 觀測到的實際序列長這樣：

```
1.47e-04 → 1.77e-04 → 3.01e-05 → 1.00e-04 → 1.00e-04 → 2.11e-04 → 8.36e-05 → 1.40e-04
```

⚠️ **這裡本來寫「逐步爬升，是累積平均」，那是錯的（2026-08-10 更正）。** 看
`getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2429`）：它只把 `linkBandwidthUsage != 0` 的邊
算進去，然後除以**那一刻非零邊的數量**。1/256 取樣之下，每一秒有樣本落在哪幾條邊會變，所以分子
分母同時在變——它是瞬時值，而且分母會跳。**只要在 `1e-05`～`3e-04` 這個量級就是對的；
要求它單調上升是要求一個它從來沒有過的性質。**

⚠️ 如果一直是 `0.0`，確認流量兩端在不同交換機上。

### 5e. Ping 自身統計

在 Mininet CLI 看 ping 的輸出：

✅ 預期：3000 封包左右時，`0% packet loss`，rtt avg ~12.8 ms。TTL 應該是 59（64 − 5 台交換機），證實經過 5 台且 TTL 遞減有效。

### 5f. Flow table（有流量時）

```bash
curl -s localhost:8000/ndt/get_switch_openflow_table_entries | python3 -c "
import json,sys
tables=json.load(sys.stdin)
for sw in tables:
    dpid=sw.get('dpid','?')
    n=sum(len(v) for v in sw.get('flows',{}).values()) if isinstance(sw.get('flows'),dict) else 0
    print(f'dpid {dpid}: {n} entries')"
```

✅ 預期：仍為每台 4 條（P4 模式 flow table 不會因 traffic 變動，和 OVS 模式不同）。

### 5g. Flow 通過的交換機（路徑上的交換機才有 flow）

⚠️ **不要照抄固定的 dpid 清單。** 路徑不是固定的——同一組 host、同一個拓撲，不同次跑會走不同的
路。先從 §5c 讀出這一次的實際路徑，再查那些 dpid：

```bash
# 先看這次走哪裡
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys
for f in json.load(sys.stdin):
    print([h['node'] if isinstance(h,dict) else h for h in f.get('path',[])])"

# 再查路徑上的 dpid（把下面的清單換成上面印出來的）
for d in 1 6 10 7 4; do
  printf "dpid %-2s " $d
  curl -s -X POST localhost:8000/ndt/get_num_of_flows_passing_a_switch \
    -H 'Content-Type: application/json' -d "{\"dpid\":$d}"
  echo
done
```

✅ 預期：回傳的是物件不是裸數字，`{"num_of_flows":N,"status":"success"}`。

⚠️ **這個端點數的是「進來」的 flow，不是「經過」的 flow。** 實作是
`if (e.dstDpid == dpid) numOfFlows += e.flowSet.size()`（`HttpSession.cpp:1734-1739`），
也就是**以該 switch 為終點的邊**上的 flow 數。所以：

- 某個方向的**起點** switch，那個方向不會被算到（它沒有對應的入邊）
- 雙向流量都經過的中繼 switch 會是 **2**
- host 邊也算（`src_dpid=0 → dst_dpid=4` 這種邊會貢獻 1）

⚠️ **這個數字在固定流量下也會逐秒跳動**，實測連續三秒同一台可以是 `0 → 1 → 2`。原因見 §5h。
所以它**不適合當通過／失敗的判準**，只適合看「路徑外的 switch 是不是長期為 0」。

⚠️ 這個端點是 **POST**，body 是 `{"dpid": N}`。不是 GET，不加 query param。

### 5h. ⚠️ 為什麼「有 flow 卻 usage=0」不是 bug

一條邊上有兩個獨立的東西，來源相同但**壽命不同**：

| 欄位 | 誰寫的 | 何時消失 |
|---|---|---|
| `flow_set` | sFlow 樣本落到這條邊時 `touchEdgeFlow` 加入（`FlowLinkUsageCollector.cpp:1544/1553`） | 由 flush loop 依 TTL 老化（`TopologyAndFlowMonitor.cpp:2680-2692`） |
| `link_bandwidth_usage_bps` | 每次樣本更新時重算（`TopologyAndFlowMonitor.cpp:895-907`） | 沒有新樣本就掉回 0 |

所以「**這條邊列得出 flow，但 usage 是 0**」是正常狀態：flow 的成員資格活得比速率久。實測快照：

```
src_dpid=1  dst_dpid=6   usage=200704  flows=1
src_dpid=6  dst_dpid=10  usage=0       flows=1   <-- 同一條 flow 的下一跳
src_dpid=7  dst_dpid=4   usage=200704  flows=1
src_dpid=10 dst_dpid=7   usage=0       flows=1
```

同一條 flow 在相鄰兩跳上，一跳有速率、一跳是 0。1/256 取樣下這完全預期。

**這也是 Web-GUI 上「flow information 有 200kb、但單一條 link 顯示 0」的原因**——GUI 的
`LinkInformation.tsx:198-199` 讀的就是 `link_bandwidth_usage_bps`。GUI 沒有錯，kernel 也沒有錯，
是這個數字本來就是斷續的。要看一條 link 的持續速率，得自己在時間上平滑，API 不提供平滑後的值。

---

## 6. Link failure → 維持 down → 恢復

### ⚠️ 重大陷阱：`ifconfig <iface> down` 會癱瘓整台 switch 的 packet-in 路徑

在 bmv2 上用 `ifconfig <iface> down` 模擬斷線，**不只是那條鏈路斷掉**——它讓該 switch 的**整條 packet-in 路徑停擺**。

實測（`GET /p4/switch_state`）：

| 欄位 | 斷線後的 s1 | 同時間的 s2/s3 |
|---|---|---|
| `probe_ok` | `true`（gRPC 照常回答） | `true` |
| `stream_alive` | `true` | `true` |
| `last_lldp_age_s` | ~3 s（s1 **送出**的 beacon 別人還收得到） | ~3 s |
| **`last_packet_in_age_s`** | **73 s** | ~3 s |

switch 沒死、gRPC 沒斷、它還在對外送 beacon，但它**不再把收到的封包送上 CPU**。所以 s6→s1 的 beacon 永遠不會被 proxy 看到，watchdog 依它掌握的證據判定那條線也失效了——而那條線實體上完全正常。

**判讀規則：只信任你故意斷掉的那條鏈路的判定。同一台 switch 上其他埠出現的失效回報，先去看 `last_packet_in_age_s` 再說。**

Mininet CLI 的 `link s1 s5 down` 底層也是對兩端做 `ifconfig down`，所以**大概率同一個症狀**（未另外實測）。

### 6a. 斷線（terminal A —— Adam 可代跑，`ifconfig` 在 NOPASSWD 清單裡）

我們斷 **s1-eth1**（即 s1:1 ↔ s5:1 這條鏈路）：

```bash
sudo -n ifconfig s1-eth1 down
```

### 6b. 觀察偵測（terminal A）

```bash
# 看 kernel log 的 link_failure_detected POST
grep "link failed" .test_run/logs/kernel.log | tail -5
```

✅ 預期：大約 11 秒後出現三筆 `link failure detected`：

```
link failed on 1:1 -> 5:1
link failed on 5:1 -> 1:1
link failed on 6:1 -> 1:2   ← 這是誤報（見上方陷阱），但 watchdog 的證據使它合理
```

⚠️ 偵測延遲約 11 秒是 watchdog 的 beacon timeout 加上 poll 間隔，不是 bug。

### 6c. 確認圖已更新（斷線後約 15 秒）

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
sw=[n for n in d['nodes'] if n.get('vertex_type')==0]
ed=d.get('edges',[])
print('switches up/enabled:', sum(1 for n in sw if n['is_up']), '/', sum(1 for n in sw if n['is_enabled']), '/', len(sw))
print('edges up:', sum(1 for e in ed if e['is_up']), '/', len(ed))
down=[(e['src_dpid'],e['src_interface'],e['dst_dpid'],e['dst_interface']) for e in ed if not e['is_up']]
print('down edges:', down)"
```

✅ 預期：

```
switches up/enabled: 10 / 10 / 10
edges up: 37 / 40
down edges: [(1,1,5,1), (5,1,1,1), (6,1,1,2)]
```

三條 down：你故意斷的兩向（s1:1→s5 和 s5:1→s1），加一條誤報（s6:1→s1，見上方陷阱）。

### 6d. 穩定性：維持 down 約 2 分鐘，確認沒有 flapping

```bash
for i in $(seq 1 40); do
  up=$(curl -s localhost:8000/ndt/get_graph_data | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for e in d['edges'] if e['is_up']))")
  echo "$(date +%H:%M:%S) edges up: $up"
  sleep 3
done
```

✅ 預期：119 秒內 40 次查詢，全部回 `edges up: 37`，沒有 flapping（不會 37→40→37）。

### 6e. Kernel 自身的 poll 也確認

```bash
grep "topology from the control plane" .test_run/logs/kernel.log | tail -3
```

✅ 預期看到類似：

```
topology from the control plane: 10 switches, 4 hosts, 37 edges up
```

⚠️ kernel 的 topology poll 間隔是**前 90 秒每 5 秒，之後每 30 秒**（`TopologyAndFlowMonitor.cpp:1793-1795`）。所以斷線後第一條確認 log 可能在 5–30 秒後才出現，不是 1 秒。

### 6f. 路徑數的變化

```bash
curl -s localhost:8081/ryu_server/all_destination_paths | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('paths:', len(d.get('all_destination_paths',[])))"
```

✅ 預期：從 12 降到 9（少的三條全部是目的地為 10.0.0.1 的路徑，因為 h1 的 switch s1 對外兩條鏈路都被標 down，twin 認為 h1 不可達——雖然實際上經 s6 走得通）。

### 6g. 恢復

```bash
sudo -n ifconfig s1-eth1 up
```

等待約 14 秒後：

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
ed=d.get('edges',[])
print('edges up:', sum(1 for e in ed if e['is_up']), '/', len(ed))"
```

✅ 預期：`edges up: 40 / 40`。

```bash
curl -s localhost:8081/ryu_server/all_destination_paths | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('paths:', len(d.get('all_destination_paths',[])))"
```

✅ 預期：`paths: 12`。

### 6h. ⚠️ 這一節**沒有**驗證到「斷線後重算出新路徑」

上面 6a–6g 驗的是**偵測**與**移除**，不是**繞路**。證據就在 6f：路徑數 12 → 9，少掉的三條全部是
到 10.0.0.1 的——那是路徑**消失**，不是路徑**改道**。斷 `s1-eth1` 會連帶癱瘓 s1 的 packet-in
（見本節開頭的重大陷阱），s1 兩條入向都被判 down，h1 就從可達集合裡整個掉出去。所以這個斷點
在設計上就看不到改道。

要驗改道，必須斷在**路徑中段、且存在替代路徑**的鏈路上，**灌著流量**，然後看兩件事：
封包有沒有繼續通，以及 twin 說的路徑跟真實規則有沒有一致。

⚠️ **判準一定要包含「ping 有沒有停」。** 只看 API 會被騙——實測時 twin 的每一個數字都正常，
封包卻已經在被丟掉了。

> 🔴 **2026-08-10 實跑了，而且它抓到一個真的 bug。** 詳見本節末的「實測結果」。這一節不是
> 假想測試，是目前唯一會讓這個缺陷現形的步驟——其他每一項檢查在缺陷存在時都照樣是綠的。

```bash
# 1. 灌流量，記下這一次的路徑（§5a + §5c）
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys
for f in json.load(sys.stdin):
    print([h['node'] if isinstance(h,dict) else h for h in f.get('path',[])])"
#    例如 h1->h4 走 [10.0.0.1, 1, 6, 10, 7, 4, 10.0.0.4]

# 2. 斷掉「中段」的一跳，不要斷第一跳。以上面的路徑為例是 s6 <-> s10：
sudo -n ifconfig s6-eth4 down

# 3. 流量繼續跑著，等約 15 秒後再讀一次路徑
```

**目前的實際結果是 ❌**（2026-08-10 實測，見下）。以下寫的是 failover 做出來之後**應該**看到什麼：

- **ping 不中斷**（最重要的一項，其他都是輔證）
- flow 的 `path` 仍然從 10.0.0.1 走到 10.0.0.4，但中間換成別的 switch 序列
- **switch 的規則跟著變**：`curl -s localhost:8081/stats/flow/6` 裡 `10.0.0.4` 的 `OUTPUT:` 換了 port
- `all_destination_paths` 維持 12，`edges up` 掉到 38

❌ 如果 **ping 停了但 API 全部正常**：twin 在宣告一條資料平面上不存在的路。這就是現況。
這正是這個測試存在的理由——這種錯誤不會讓任何一個 ✅ 變成 ❌，只會讓 twin 安靜地說謊。

⚠️ 因為那個 packet-in 陷阱，斷中段鏈路也會讓同一台 switch 的其他入向鏈路被誤報 down。所以
`edges up` 會低於 38（實測是 35）。**判準看的是 `path` 有沒有改道、以及 12 條路徑有沒有保住**，
不是邊數。

### 🔴 實測結果（2026-08-10）：P4 模式**根本不會繞路**，而 twin 會宣稱它會

斷 `s10-eth3`（`s10:eth3 ↔ s7:eth4`，正向路徑的中段，s10 有四個鄰居所以理論上有替代路）。

| 觀測 | 結果 |
|---|---|
| 封包還通嗎 | 🔴 **不通**。ping 完全停住，`icmp_seq` 6 秒內沒有前進 |
| 鏈路真的斷了嗎 | 是。`s7-eth4` 的 RX counter 6 秒內完全沒動（197539 → 197539） |
| bmv2 的規則有改嗎 | 🔴 **沒有**。s6 對 `10.0.0.4` 仍然是 `OUTPUT:4`（就是往 s10 那條），proxy 自己的 `/stats/flow/6` 和 kernel 的快取**兩邊完全一致** |
| kernel 的 flow table 檢視有變嗎 | 沒有，前後**逐位元組相同**，每台仍是 4 條 |
| kernel 回報的 flow path | `1 6 10 7 4` —— **這是對的**，它忠實反映了規則實際上會把封包送去哪 |
| proxy 的 `all_destination_paths` | 🔴 **變成 `1 6 9 8 4`**，一條只存在於它 networkx 圖裡、**沒有被安裝到任何一台 switch** 的路 |
| 路徑數 | 維持 12 —— 宣稱全連通，實際 h1↔h4 已經斷了 |
| 恢復 | `ifconfig up` 後 ping 立刻回來，40/40、12 條路徑 |

**結論：偵測是對的，繞路不存在。** proxy 偵測到斷線、把邊標 down、從拓撲回覆裡拿掉它、
**重算出一條新路、把新路推給 kernel** —— 唯獨沒有把新規則裝進 bmv2。

根因很單純：`install_initial_routes()` 全專案只有**一個**呼叫點，在
`topology_manager.py:655`，條件是 `if not edge_exists`，也就是**發現新鏈路**的時候。
鏈路**消失**時沒有任何東西呼叫它。

⚠️ **最危險的不是流量斷掉，是 twin 說它沒斷。** `all_destination_paths` 維持 12，代表 twin
對外宣告 h1 到 h4 有一條路；那條路只存在於 proxy 的圖裡。任何拿這個 API 做決策的東西
（Energy-Saving-App、Traffic-Engineering-App）都會據此規劃，而封包正在被丟掉。

**這是能力缺口，不是回歸。** Phase 6 的範圍是「鏈路失效**偵測**」，那部分完整可用且已驗證；
failover／重新安裝路由從來沒有被實作過，也沒有被宣稱過。要修的話，路徑是讓 watchdog 的
down 轉換除了推路徑給 kernel 之外，也呼叫一次 `install_initial_routes()`（或它的增量版本）。

> **給後續的人**：這個缺陷在 §6a–§6g 全部是綠的。邊數對、路徑數對、偵測有觸發、推送有送達。
> 只有「**灌著流量斷中段鏈路，然後看 ping 有沒有停**」會讓它現形。所以這一節不要跳過。

#### ✅ 修掉一半之後的實測（2026-08-10 18:18，重開 stack 後）

「twin 宣稱不存在的連通性」這一半已經修掉：proxy 現在只宣告**規則真的裝進 switch、而且每一跳
都還活著**的路徑。同一個實驗重跑：

| | 修之前 | 修之後 |
|---|---|---|
| `all_destination_paths` | 🔴 維持 **12**（其中含一條沒安裝的繞路） | ✅ **12 → 7** |
| h1→h4 | 🔴 宣告 `1 6 9 8 4`（不存在） | ✅ **撤掉（WITHDRAWN）** |
| 經過失效鏈路的宣告路徑 | 🔴 有 | ✅ **0 條** |
| `edges up` | 35/40 | 35/40（不變，偵測本來就對） |
| ping | 停 | **仍然停** —— failover 還沒做，這是預期 |
| 恢復 | — | `ifconfig up` 後 25 秒內回到 **12 條路徑、40/40、ping 恢復** |

所以現在的行為是：**斷線後 twin 會誠實地少報路徑，但流量不會自己繞路。** 判準因此變成
「路徑數有沒有下降」而不是「有沒有維持 12」——維持 12 反而是退步的徵兆。

⚠️ 這也代表 **§6f 的「12 → 9」是修之前的數字**。實際掉多少取決於這次的路徑經過哪些鏈路，
不是固定值；要驗的是「有下降、且沒有任何一條宣告路徑經過失效鏈路」。

---

## 7. admin_disabled

### 背景

`admin_disabled` 是 `VertexProperties` 和 `EdgeProperties` 上的第三個 flag（和 `isUp`、`isEnabled` 並列），定義在 `include/common_types/GraphTypes.hpp:215`。它的用途是讓 Intent Translator 的 `DisableSwitch` 指令**不被下一次 topology poll 覆寫**——poll 只寫 `isUp`/`isEnabled`，永遠不碰 `admin_disabled`。

序列化為 `admin_disabled`，並**折入** `is_enabled`：`/ndt/get_graph_data` 回傳的 `is_enabled` 實際上是 `isEnabled && !adminDisabled`（`HttpSession.cpp:530` 和 `GraphTypes.hpp:323`）。所以四個讀取 `is_enabled` 的 app（Energy-Saving、Visualizer、Web-GUI、Traffic-Engineering）不需要改程式碼就能看到 operator 的 disable。

### 為什麼現在總是 false

kernel 以 `--no-ai` 啟動（`stack.sh:606`），因此 `IntentTranslator` 是 `nullptr`（`main.cpp:346-362`），而 `disableSwitchAndEdges`（唯一設定 `adminDisabled = true` 的路徑）**只被 Intent Translator 呼叫**。所以 `adminDisabled` 永遠是初始值 `false`。

### 可以做的檢查

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
nodes=d.get('nodes',[])
edges=d.get('edges',[])
ad_nodes=[n for n in nodes if n.get('admin_disabled')]
ad_edges=[e for e in edges if e.get('admin_disabled')]
print('nodes with admin_disabled=true:', len(ad_nodes))
print('edges with admin_disabled=true:', len(ad_edges))
# Invariant: nothing is both admin_disabled and is_enabled
bad_nodes=[n for n in nodes if n.get('admin_disabled') and n.get('is_enabled')]
bad_edges=[e for e in edges if e.get('admin_disabled') and e.get('is_enabled')]
print('violations (admin_disabled AND is_enabled):', len(bad_nodes)+len(bad_edges))"
```

✅ 預期：

```
nodes with admin_disabled=true: 0
edges with admin_disabled=true: 0
violations (admin_disabled AND is_enabled): 0
```

⚠️ 這個檢查**今天只是回歸陷阱**——「admin_disabled 和 is_enabled 不應同時為真」這個不變量**空洞地成立**（因為沒有任何東西被 disable）。Phase 7 引入 power management 後，如果有 switch 被 power off，這兩個條件應該同時變化，但 `is_enabled`（折入後的）應該變 false。那時候這條檢查才真正有意義。

---

## 8. 判定總表

### 綠燈代表什麼

| 項目 | 綠燈條件 | 綠燈代表 |
|---|---|---|
| 起點乾淨 | 六個查詢全部無輸出 | 沒有殘留 process 汙染下一個 `up` |
| Unit tests | C++ 426 pass, Python 312+101 pass, 無 skip 異常 | 離線邏輯正確 |
| `stack.sh up p4` | `paths=12 converged after 2s` + kernel 起來 | P4 proxy 成功連上 10 台 bmv2、LLDP 發現完成、kernel 啟動 |
| `stack.sh wait` | `switches=10 up=10 enabled=10 edges=40` | kernel 的圖和 proxy 的 topology 一致 |
| Idle graph | 10/10 switch up+enabled, 4/4 host up, 40/40 edge up | 所有節點和邊都被拓撲發現並啟用 |
| Node keys | 12 個 key，含 `admin_disabled` | schema 正確，Phase 6 的 `admin_disabled` 欄位有出現在輸出中 |
| Power report | 10 筆，33466–147622 mW，跨輪詢不變 | 合成電力值正常產生 |
| `avg_link_usage` idle | `0.0` | 沒有 phantom 流量 |
| Flow tables | 10 台各 4 條 | 預設規則已安裝 |
| Detected flows idle | `0` | 沒有 stale flow |
| Switch state | 10 台 `probe_ok=true`, `stream_alive=true`, ages 0–5s | gRPC liveness probe 和 stream 都健康 |
| Paths idle | 12 | 所有 host pair 都有路徑 |
| Proxy log | 10× clone session ok, 0 fail, 1× watchdog seeded | telemetry 鏈路和 link failure 偵測已初始化 |
| Traffic: detected flows | 2 筆（雙向 ICMP），rate > 0，path 長 7 | sFlow → proxy → kernel 的 ingest 鏈路完整，flow path 正確 |
| Traffic: `avg_link_usage` | 落在 1e-05～3e-04，上下跳動 | 鏈路使用率有在追蹤流量（**不會單調爬升**，見 §5d） |
| Traffic: ping | 0% loss, rtt ~12.8ms, TTL=59 | 資料平面正常轉送，hop 數正確 |
| Link failure detect | 3 筆 `link_failure_detected` POST，約 11s 後 | watchdog 正確偵測到 beacon timeout |
| Link failure graph | 37/40 up，穩定不 flapping | 失效值正確、沒有振盪 |
| Link failure paths | 12 → 9 | 失效鏈路被排除在最短路徑搜尋外 |
| Recovery | ~14s 內回到 40/40 和 12 paths | 偵測是可逆的 |
| `admin_disabled` | 全部 false，不變量空洞成立 | schema 正確，回歸陷阱就位 |

### 哪些綠燈不代表什麼

| 綠燈 | 不代表 |
|---|---|
| `probe_ok=true` | gRPC probe 只測 switch 是否回應 P4Runtime，**不測 packet-in 是否正常**。`ifconfig down` 過的 switch 仍然 probe_ok=true |
| `stream_alive=true` | 只代表 gRPC stream 沒斷，不代表封包有送到 |
| `edges up: 37/40`（斷線後） | 只信任你故意斷的那條。其他的「失效」可能是 `ifconfig` 的 side effect |
| Flow table 4 條 | P4 模式 flow table 不反映 traffic。它不是 OpenFlow 規則數 |
| `avg_link_usage` 非零 | 它是瞬時值，且分母是「當下有樣本的邊數」。單次讀數不代表整體負載，連續讀數上下跳是正常的 |

---

## 9. 出問題時先看哪裡

| 症狀 | 先看 | 別誤判成 |
|---|---|---|
| `stack.sh up p4` 停在 `waiting for P4 proxy agent` | `.test_run/logs/p4_proxy.log` 找 `ECONNREFUSED` | 不是 proxy bug——bmv2 沒起來 |
| `stack.sh wait` timeout，`enabled` 不是 10 | `.test_run/logs/p4_proxy.log` 找 `inform_switch_entered` 或 `pipeline push failed` | 不是 kernel 的問題 |
| `avg_link_usage` = 0 但有流量 | 流量兩端是不是在同一台交換機 | 不是 bug（設計上排除 host 邊） |
| `num_of_flows` = 0 | 流量還在跑嗎；那台交換機在路徑上嗎 | 它不是 OpenFlow 規則數 |
| `{"error":"Not Found"}` | 端點是 GET 還是 POST；是不是多加了 `?dpid=` | 不是功能沒實作 |
| `get_detected_flow_data` 回 0 筆 | ping 還在跑嗎（flow 幾秒內老化） | 不是 ingest 壞掉——是流量停了 |
| `addressed=0` 但 `rx` 在漲 | 沒有真實流量——rx 是 counter sample（週期性），addressed 只對 flow sample 遞增 | 不是 sFlow 壞掉 |
| Proxy 有起來但 graph 全是 down | kernel log 找 `curl` 失敗（對 `:8080` 的 ECONNREFUSED）——第一筆是預期的（見 §3b 陷阱），但**持續**出現就不對 | 不是 proxy 的問題 |
| 斷線後 edges up 變 36 或更少 | 那是 `ifconfig down` 的 side effect（見 §6 陷阱）——同一台 switch 的其他埠也被拖下水 | 不要當成多條鏈路真的同時壞了 |

### Log 位置

| 程式 | Log |
|---|---|
| kernel | `.test_run/logs/kernel.log` |
| P4 proxy | `.test_run/logs/p4_proxy.log` |
| bmv2 switch（每台） | `/tmp/s1_bmv2.log` … `/tmp/s10_bmv2.log` |

### 有用的快速指令

```bash
# 誰在聽哪些 port
ss -ltnp '( sport = 8000 or sport = 8080 or sport = 8081 )'

# bmv2 還在嗎（注意 15 字元截斷）
ps -eo comm --no-headers | grep "^simple_switch_g$" | wc -l

# kernel 活著嗎
pgrep -x ndtwin_kernel && echo alive || echo dead

# proxy 活著嗎
pgrep -f "[p]roxy_agent.main" && echo alive || echo dead
```

---

## 收尾

```bash
# terminal A
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh down
sudo mn -c
pkill -x simple_switch_g    # -x 而非 -f，名稱只到 15 字元
```

```bash
# 確認真的乾淨
pgrep -x ndtwin_kernel; pgrep -x simple_switch_g; pgrep -x iperf
ss -ltn '( sport = 8000 or sport = 8080 or sport = 8081 )'
```

✅ 全部無輸出。
### 5b. 確認流量有被觀測到（terminal A）

```bash
# kernel log 的 sFlow ingest 健康線（只會有一行 INFO，其餘是 TRACE）
grep "sFlow ingest healthy" .test_run/logs/kernel.log
```

✅ 預期：至少一行，格式為 `sFlow ingest healthy: rx=..., app_drop=..., addressed=..., sock_ovfl_total=...`。
`rx` 是收到的 datagram 總數（含 counter sample），`addressed` 是成功歸戶的 flow sample 數。

⚠️ **這行只在第一輪輸出 INFO**（`FlowLinkUsageCollector.cpp:1798-1801`），之後全部是 TRACE——所以 `grep` 只會找到一筆，而且它的 `rx=` 和 `addressed=` 反映的是**啟動瞬間**的值（通常都是 0）。不要用它判斷「流量夠不夠」——用下面的 `get_detected_flow_data` 判斷。這正是舊文件 `doc/full_test_runbook.md` 的陷阱之一：它教你 watch `addressed=` 的值，但那行根本不會再出現。


---

*本文件從原始碼產生。需要確認但未涵蓋的事項標記為 NEED-FILE。最後更新：Phase 6 完成後。*
