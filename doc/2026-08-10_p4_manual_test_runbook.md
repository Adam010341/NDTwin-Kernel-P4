# P4/bmv2 手動測試 runbook

> 📍 **入口不是這裡（2026-08-17）**：「我現在該跑什麼」看
> [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md)。這一份仍是**現役的手動
> runbook**——要人工逐步走一輪 P4 的**驗證**部分時用它。
>
> ⚠️ **起停步驟已由入口那份的 §2（開機手冊）取代（2026-08-21）**：現在一律
> `ndt up` / `ndt down`。本文件裡的 `ndtwin-lab topo-start` + `stack.sh up p4`
> 仍然可用，但**不記帳**（`.test_run/pids/` 不會有登記），之後 `ndt down` 收不乾淨。

**這份文件是做什麼的**：從乾淨環境開始，逐步啟動 P4/bmv2 stack，在 idle 狀態下確認靜態健康，灌流量驗證 telemetry 鏈路，模擬一條鏈路斷線後觀察偵測與恢復，最後檢查 `admin_disabled` 欄位。全部手動執行，一步一確認。

**什麼時候跑**：任何對 P4 路徑（proxy、bmv2 pipeline、sFlow emitter、kernel 的 P4 分支）的修改之後。（2026-08-13 更正：Phase 7（power management）已完成——`2026-07-27_p4_bmv2_support_plan.md` Phase 7 節——但其電源/readopt 流程仍不在本文件涵蓋內，見 §9 的 readopt 條目。）

**涵蓋範圍**：Phase 1–6 全部完成的功能。以下這些從舊文件來的宣稱是錯的，不要照抄：

- ~~「P4 模式的 `stack.sh wait` 永遠 timeout，`enabled=0`」~~ — 現在會收斂。
- ~~「P4 的 `is_up` 是 stub，要改用 `is_enabled` 判斷」~~ — `is_up` 是真的。
- ~~「P4 模式圖是死的、`path` 是 `[]`、link usage 是 0」~~ — 全部是活的。
- ~~「看 kernel.log 的 `addressed=` 有沒有增加來判斷流量夠不夠」~~ — 那行只在第一輪是 INFO，之後是 TRACE，所以只會出現一次，且 `rx=0`。見 `FlowLinkUsageCollector.cpp:1798-1801`。
- ~~OVS runbook 的 port 是 P4 的~~ — P4 模式不跑 Ryu，port 不同。

本文件建立於 Phase 6 完成之後，對應 `doc/2026-07-29_environment_gotchas.md` 的陷阱、`doc/2026-07-30_full_test_runbook.md` 的 ✅/⚠️ 慣例。

**名稱刻意不帶 phase 編號。** 它涵蓋到 Phase 6，Phase 7 開工前跑一次；之後每個 phase 應該延伸這一份，
而不是各自新增一份互相矛盾的文件。

> **驗證紀錄（2026-08-10）**：§4 的每一條 idle 檢查都在活的 stack 上實跑過，數值與本文所寫一致
> （10/10/4/40、12 個 node key、power 10 筆 33466–147622 mW、avg usage 0.0、每台 4 條 flow、
> 0 個 detected flow、10 台 `probe_ok`、12 條路徑、clone session ×10／failed ×0／seeded ×1）。
> 引用的行號（`FlowLinkUsageCollector.cpp:507`、`:1798-1801`、`TopologyAndFlowMonitor.cpp:1793-1795`）
> 都開檔確認過，`?dpid=` 真的回 404、`get_num_of_flows_passing_a_switch` 真的只吃 POST 也確認過。
>
> 🔴 **2026-08-12 重核：上面三個行號有兩個已經漂掉。** 逐一開檔對過 2026-08-10 當時的版本與今天：
> `:1798-1801` 當時是 `sockOvfl` 的 WARN 那段，今天是被註解掉的 `getsockopt` 呼叫——**漂了**；
> `TopologyAndFlowMonitor.cpp:1793-1795` 當時是 poll 間隔的三元式，今天在 `run()` 裡
> `kWhileConverging`／`kOnceConverged` 的三元式那段——**漂了，而且改用符號名而不是新號碼**：
> 2026-08-12 這行原本寫「今天在 `:1951-1953`」，實測 `:1951` 是「Safely write the modified
> JSON data back to the file」，三元式在 `:2039`——**更正過的號碼本身又錯了 88 行**，而且是在
> 「修正我自己驗證時發現的腐爛」那個 commit 裡漏掉的。行號在這個檔案裡已經腐爛兩次，第三次
> 不會例外，所以這裡只留符號名。
> `FlowLinkUsageCollector.cpp:507` 和當時**一模一樣**（都是一段 docblock 的 `@details` 行），沒漂。
> 記三個而不是含糊寫「都漂了」，是因為「大概都過期了」和「這兩個過期、那個沒有」是兩種不同的可信度。
> §5–§6 的數值來自 2026-08-10 的實測，未在這次重跑（跑了會打斷你正在用的 stack）。

---

## 0. 這份文件要回答什麼

每個「你應該看到」都有精確的預期值。每個檢查如果可以「通過但原因不對」，會標出來。每個步驟標了誰能跑。本文件**不是** OVS/P4 基準比對——那份在 `doc/2026-07-30_full_test_runbook.md`。這裡只測 P4 路徑本身是否健康。

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

⚠️ **每一筆是「單一方向」，而且去程與回程經常走不同的 switch。** 實測（2026-08-10）6 對 host 裡
**3 對不對稱**：

```
10.0.0.1 <-> 10.0.0.2:  去程 [1, 6, 2]      回程 [1, 5, 2]
10.0.0.1 <-> 10.0.0.3:  去程 [1, 5, 10, 8, 3]  回程 [1, 5, 9, 8, 3]
10.0.0.1 <-> 10.0.0.4:  去程 [1, 5, 10, 8, 4]  回程 [1, 5, 9, 8, 4]
```

不對稱本身**不是 bug**——等價路徑由 networkx 依探索順序挑一條，真實 IP 網路也是如此。但它有一個
會咬人的後果：**單看一個方向不能判斷「這兩台 host 能不能互通」**。ping 需要雙向都活著，所以
一台 switch 掛掉可能只斷其中一個方向，而你查的那個方向看起來完全正常。

今天就是這樣被騙的：我以為 `h1→h2` 走 `1 6 2` 不碰 s5，於是把它當成「不受影響的對照組」，
但回程 `2 5 1` 直接穿過 s5。**要判斷連通性，兩筆都要查。**

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

⚠️ **h1 和 h4 在不同交換機上**（h1 在 s1，h4 在 s4），這很重要。同一台交換機底下的 host 互打，`get_average_link_usage` 永遠是 0.0——因為 `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp`）刻意排除所有接到 host 的邊
（判斷式在 `:2468-2469`），那不是 bug。

⚠️ **【2026-08-11 更正】原本引用的 `:2429` 和 `:2455-2456` 都是錯的，而且寫下當時就錯了。** `:2429` 是另一個函式裡的 JSON `push_back`，`:2455` 是 `if (!isUsable(g[e]))`（可用性檢查，與 vertex type 無關）。結論本身正確，只有指標錯誤。（來源：agy-review 0182。）

🔴 **【2026-08-12 再更正】那次改成的 `:2441` 現在也漂掉了**——`getAvgLinkUsage` 今天在 `:2600`，host 排除的判斷式在 `:2626-2627`。**同一個指標在四天內腐爛兩次**，所以這次不換數字，直接把行號拿掉：函式名不會因為上面插了幾行就失效。這份文件裡其他幾處也照辦。

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

✅ 預期：**有流量時**至少一行，`rx=` 和 `addressed=` 都有值。（2026-08-13 更正：這行 INFO 只在 `rx > 0` 時印，而 **P4 的 emitter 只送 flow sample、沒有 counter sample**——idle 時完全沒有 datagram，`grep` 會是**零行**，且約 60 秒後會出現一筆「沒收到 sFlow」的 WARN，兩者都不是故障。舊版寫「rx 含 counter sample、idle 也有值」是 OVS 的行為，對 P4 不成立。）

⚠️ 這行第一輪是 INFO，之後是 TRACE（`FlowLinkUsageCollector.cpp`，搜 `addressed=` 的那個 INFO/TRACE 對）。所以 `grep` 最多找到一筆。不要用它判斷「流量夠不夠」——用下面的 `get_detected_flow_data` 判斷。

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
`getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp`）：它只把 `linkBandwidthUsage != 0` 的邊
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
`if (e.dstDpid == dpid) numOfFlows += e.flowSet.size()`（`HttpSession.cpp`，用 `grep -n "numOfFlows +="` 找——唯一一中，2026-08-13 時在 :1813。⚠️ 認內容不要認行號：上方不遠處**另一個端點**有長得一樣的 `if (e.dstDpid == dpid)` 判斷式，抄行號會讀錯段），
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

✅ 預期：約 **15–20 秒**後出現三筆 `link failure detected`（2026-08-13 更正：`LINK_BEACON_TIMEOUT_S = 15`，加上 poll 間隔；舊版的「11 秒」低於 timeout 本身，不可能發生）：

```
link failed on 1:1 -> 5:1
link failed on 5:1 -> 1:1
link failed on 6:1 -> 1:2   ← 這是誤報（見上方陷阱），但 watchdog 的證據使它合理
```

⚠️ 偵測延遲約 15–20 秒是 watchdog 的 beacon timeout（15s）加上 poll 間隔，不是 bug。

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

⚠️ kernel 的 topology poll 間隔是**前 90 秒每 5 秒，之後每 30 秒**（`TopologyAndFlowMonitor.cpp` 的 `run()`，常數 `kWhileConverging`／`kOnceConverged`／`kConvergingFor`）。所以斷線後第一條確認 log 可能在 5–30 秒後才出現，不是 1 秒。

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

> **📌 2026-08-13 狀態 banner（先讀這個再讀本節）**：本節下方的 ❌ 結論與「根因」段是
> **2026-08-10 的歷史快照**，failover 之後已完成（`ca72d22`）並經兩輪 live 驗證：
> bmv2 側 2026-08-12 夜實測——斷鏈偵測 2 筆零假訊、canary ping 中斷 **16.63 秒後自癒**、
> 復原 hitless 零遺失（OVS 對照輪同法 52.42 秒自癒）。步驟照走（用上面 tc netem 版），
> 預期結果以 §6h 末的「✅ 通過判準」為準；歷史敘述保留供脈絡，不要照抄其結論。

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

# 2. 斷掉「中段」的一跳，不要斷第一跳。以上面的路徑為例是 s6 <-> s10。
#    （2026-08-13 更正：這一步舊版寫 `ifconfig s6-eth4 down`——那會讓整台 s6 停止轉送、
#    產生假 link-down、ping 永不恢復，再配上本節「永不恢復＝failover 沒生效」的判準，
#    照跑保證得出假結論。斷單一鏈路一律用下方 §「正確的故障注入方式」的 tc netem，兩端都下。
#    s6↔s10 的介面對照 p4_testbed_topo.py 是 s6-eth4 ↔ s10-eth2：）
sudo -n tc qdisc add dev s6-eth4  root netem loss 100%
sudo -n tc qdisc add dev s10-eth2 root netem loss 100%
# （恢復：同兩個介面 `tc qdisc del dev <if> root`）

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

（2026-08-10 當時的）根因很單純：`install_initial_routes()` 全專案只有**一個**呼叫點，
條件是 `if not edge_exists`，也就是**發現新鏈路**的時候。鏈路**消失**時沒有任何東西呼叫它。
**2026-08-13 更正：這已不是現況**——它現在有**三個** production 呼叫點（LLDP 發現、
`readopt_switch`、link transition——最後一個就是 failover 的修復本體），且回傳值已改為
`(accepted, attempted)` 兩元組。找它們用 `grep -n "install_initial_routes(" ` 認 symbol，
不要認行號。

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

#### 🔴 `ifconfig <iface> down` **沒辦法用來驗 failover**（2026-08-10 18:38 實測）

failover 已經實作（見計劃書 Phase 6），而且**規則層面確定有繞路**：斷 `s5-eth4` 之後，
s5 對 `10.0.0.4` 的規則從 Port 4 改成 Port 3，用 `read_table_entries()` 從 switch 讀回來確認，
雙向都追得出完整路徑。**但封包還是不通。**

原因不是 failover，是這個**故障注入方式本身太粗暴**。同時從 h1 ping 三台的對照實驗：

| 目標 | 斷線前的路徑 | 經過 s5？ | 結果 |
|---|---|---|---|
| h2 | `1 6 2` | **否** | 🔴 一起死 |
| h3 | `1 5 10 8 3` | 是 | 🔴 死 |
| h4 | `1 5 10 8 4` | 是 | 🔴 死 |

**連看起來不碰 s5 的 h1→h2 也一起死了**，三條同時停在同一個 `icmp_seq`。三條的規則當時都正確
（`s1→p2→s6→p2→s2→p3→h2`，逐台讀回來確認）。事後重新 ping 三台都是 **0% loss**。

🔴 **更正（2026-08-10，派 Opus 5 + DeepSeek 兩路獨立調查後）**：「h1→h2 不碰 s5」這個前提是錯的
——**只查了去程**。`all_destination_paths` 裡 h1→h2 的**去程**是 `1 6 2`，真的不碰 s5；但
**回程** h2→h1 是 `2 5 1`，直接穿過 s5（`p4_testbed_topo.py:154`：`addLink(switches[2],
switches[5], port1=1, port2=2)`，s2 的 port 1 就是接 s5 的那個口，`s2` 對 `10.0.0.1` 的實際規則
是 `OUTPUT:1`，跟 topology 對得上）。ping 需要雙向都通，s5 斷線時回程封包在 s2 就被送進一台已經
停擺的 switch。**三條 ping 其實都跟 s5 有關，只是有的在去程、有的在回程**——不是「完全不相關的
流量也死了」，是我當時只驗了單向。

這代表 twin 目前**對每個方向獨立計算路徑，沒有雙向一致性檢查**——`calculate_all_paths` 對每個
`(src, dst)` 各自跑最短路徑，兩個方向走不同 switch 是正常的穩態行為（這條 h1↔h2 現在活著的時候
就是這樣），不是斷線才出現的異常。這代表 twin 可能正在宣告「這對 host 通」，卻只驗證了其中一個
方向。這是新發現，跟 failover 本身是不同問題，還沒有修。

**而且這不是 failover 造成的** —— 同樣的特徵在 failover 存在之前就出現過兩次：早上斷 `s1-eth1`
時 h1 整個從可達集合消失（12→9，三條到 10.0.0.1 的路徑全沒），斷 `s10-eth3` 時 ping 直接停死。
兩次都在 failover 之前。

**結論：`ifconfig down` 讓整台 switch 停止搬運流量，不只是停止 packet-in。** 既然任何繞路都救
不了一台不轉發的 switch，這個方法就驗不了 failover ——它只能驗**偵測**與**誠實回報**（§6a–§6h
前半仍然有效）。

要真正驗 failover，需要一種**只弄壞一條鏈路、不弄壞整台 switch** 的注入方式。**已解決 —— 用
`tc netem`**，見下一節。

#### ✅ 正確的故障注入方式：`tc netem`（2026-08-10 端到端驗證通過）

介面全程維持 UP，只在**送出佇列**丟包，所以那台 switch 的其他 port 完全不受影響。

```bash
# 斷線（雙向都要，才是完整的鏈路失效）
sudo -n tc qdisc add dev s5-eth4  root netem loss 100%
sudo -n tc qdisc add dev s10-eth1 root netem loss 100%

# 恢復
sudo -n tc qdisc del dev s5-eth4  root
sudo -n tc qdisc del dev s10-eth1 root
```

⚠️ 需要 sudoers 授權（`/etc/sudoers.d/ndtwin-mininet`），且**刻意限制成只能動 Mininet 的
switch 介面**，避免手滑把實體網卡的 qdisc 改掉：

```
adam ALL=(root) NOPASSWD: /usr/sbin/tc qdisc add dev s[0-9]*-eth[0-9]* root netem *
adam ALL=(root) NOPASSWD: /usr/sbin/tc qdisc del dev s[0-9]*-eth[0-9]* root
adam ALL=(root) NOPASSWD: /usr/sbin/tc qdisc show dev s[0-9]*-eth[0-9]*
```

**兩種注入方式的實測對照**（同一條 `s5↔s10` 鏈路、同一個 stack）：

| | `ifconfig down` | `tc netem loss 100%` |
|---|---|---|
| link down 回報 | **5 筆**（3 筆是假的） | ✅ **2 筆**（就是真的那兩個方向，零假報） |
| `edges up` | 35/40（多扣了 3 條健康邊） | ✅ **38/40**（正好扣掉斷掉的雙向） |
| 該 switch 還能轉發嗎 | ❌ 整台停擺 | ✅ 正常轉發 |
| ping | 🔴 全程不通，插回來才恢復 | ✅ **停約 15 秒後自己恢復** |
| 驗得出 failover 嗎 | ❌ 不行 | ✅ **可以** |

**實測時序**（19:58:22 注入）：

```
seq 停在 46 ────────► 約 15 秒（beacon 逾時偵測）
t+18s  seq 跳到 82 並持續遞增   ← 流量已繞道
```

- 新路徑：`1 5 9 8 4`（原本 `1 5 10 8 4`），繞開斷掉的 `5→10`
- s5 對 `10.0.0.4` 的規則從 `OUTPUT:4` 改成 **`OUTPUT:3`**，用 `read_table_entries()` 從
  switch 讀回來確認
- 路徑數維持 **12**（沒有 host 變成不可達）
- 移除 netem 後 25 秒內：40/40、路徑回到 `1 5 10 8 4`、ping 持續
- 整趟 ping 統計：**`300 packets transmitted, 271 received, 9.67% packet loss`**。29 個封包
  ＠2 pps ≈ **14.5 秒的中斷**，與 beacon 逾時窗吻合。對照 `ifconfig` 那次是 **38% 且全程未恢復**。

**failover 至此為「規則層 ＋ 端到端」皆已驗證。**

✅ **這一節的通過判準**：ping **會短暫中斷再自己恢復**（約 15 秒），不是全程不通。
中斷時間 ≈ `LINK_BEACON_TIMEOUT_S`（15s）加上一個 watchdog 掃描週期，所以 15–20 秒是正常的；
**永遠不恢復**代表 failover 沒生效，**完全不中斷**代表你斷的鏈路根本不在流量路徑上。

#### 🔴 `reroutable_down_endpoints()` 的一個真漏洞（DeepSeek 靜態分析找到，程式碼＋log 覆核確認）

`s5-eth4` 斷線那次，log 記到五筆 down：`(1,1,5,1)` `(9,1,5,3)` `(2,1,5,2)` 三筆是 packet-in 卡住
造成的假報，`(5,4,10,1)` `(10,1,5,4)` 才是真的斷線（雙向各一筆）。因為 s5 入向全靜默且
`probe_ok` 仍是 true，判定為 suspect，`reroutable_down_endpoints()` 把**所有 dst=5 的 down link
都排除**——包括真的斷線的 `(10,1,5,4)`。`ryu_topology.down_edges()` 只看 `(src_dpid, src_port)`，
`(10,1)` 沒被排除，`calculate_all_paths` 因此還是會把 `s10→s5` 這條物理上已斷的邊當可用邊。

**只有單一方向受影響**：離開 s5 的方向（dst=10，不是 suspect）排除正確；進入 s5 的方向
（dst=5，是 suspect）被錯誤保留。這次 h3→h1、h4→h1 的回程理論上會踩到，但因為 s5 整台停擺，
這個漏洞被蓋住看不出來——換成 `tc netem` 只弄壞單一鏈路之後，這個漏洞就會現形。

**已修（2026-08-13 更正——本段之前寫「還沒修」已過時）**：採用的是「從證據分辨」路線——
`reroutable_down_endpoints()`（`topology_manager.py`，搜 symbol）現在帶反向檢查：一條 down link
即使落在 suspect switch 的赦免範圍，只要**反向那筆也 down**，就視為真斷線、不赦免。
`p4_proxy/tests/test_link_watchdog.py` 以本節這個 `{(5,4),(10,1)}` 場景鎖定此行為。

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
| Link failure detect | 3 筆 `link_failure_detected` POST，約 15–20s 後（timeout 15s＋poll 間隔） | watchdog 正確偵測到 beacon timeout |
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
| `addressed=0` 但 `rx` 在漲 | （2026-08-13 更正）P4 **沒有** counter sample，rx 在漲＝有 flow sample 進來；addressed 不動代表**歸戶失敗**——查 proxy 的 flow 快取與 kernel flow 表（舊解釋「rx 是 counter sample」是 OVS 的行為） | 這在 P4 模式**是**異常，要查 |
| power off 後 `switches` 少於 10 | 這是 `32afeb9` 之後的**正常**行為：死掉的 switch 從 `/v1.0/topology/switches` **消失**（不再是留在清單裡 `enabled` < 10） | 不要當成 topology 掉資料 |
| `/p4/readopt/{dpid}` 回 502 `step:"mastership"` | 舊 client 還是 primary（switch 是健康的）。readopt 是給 power-cycle 後用的；2026-08-13 起這種情況被 gate 擋下、**switch 不會被動到**。對健康 switch 不要硬跑 readopt | 不是 readopt 壞掉 |
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

---

*本文件從原始碼產生。需要確認但未涵蓋的事項標記為 NEED-FILE。最後更新：Phase 6 完成後。*
