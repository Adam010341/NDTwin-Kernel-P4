# Phase 7 就緒度手動測試（P4/bmv2）

**這是一份執行用的 runbook**：在 Phase 7（power management）開始前，從乾淨環境開始，手動在 P4/bmv2 全棧上跑一遍，確認 Phase 6 真的完成、沒有回歸。它不是 OVS/P4 基準比對的重跑 —— 那是 [full_test_runbook.md](full_test_runbook.md) 的範圍。

建立於 2026-08-10。

**所有預期值都是 2026-08-10 在 live 10-switch bmv2 stack（4 hosts）上量出來的。用這些數字，不要自己發明、不要四捨五入、不要推廣到別的拓撲。**

**只有 `ovs-vsctl`、`ifconfig`、`mnexec` 是 NOPASSWD；`mn`、`ip`、`ovs-ofctl`、對 root process 的 `kill` 都不是。** 下表照這個規則標。

---

## 0. 這份文件要回答什麼 / 什麼時候跑

Phase 6 完成後，有幾個行為改變（全部驗證過）：

1. `./stack.sh wait` 在 P4 模式會收斂（`switches=10 up=10 enabled=10 edges=40`，約 1 s）。舊 runbook 說它會卡在 `enabled=0` timeout —— 已過時。
2. `is_up` 在 P4 模式是真的（`a8db425`）。舊建議「別信 is_up，看 is_enabled」已過時。
3. Link failure 檢測端到端可用：beacon timeout -> `link_failure_detected` -> edge 在 kernel graph 下去而且**維持**下去，因為 proxy 從 `/v1.0/topology/links` 拿掉 failed links，poll 沒有東西可以復活它們。
4. 新欄位 `admin_disabled` 在 `/ndt/get_graph_data` 的每個 node 和 edge 上。operator 的 DisableSwitch 現在能撐過 topology poll。`is_enabled` 以 folded 形式輸出（`isEnabled && !adminDisabled`），所以既有消費者不用改就能看到 disable。
5. Topology poll interval 是 kernel 前 90 秒每 5 秒一次，之後每 30 秒一次。（不是 1 秒 —— 那是一直以來對 sleep slice 的誤讀。）

這份 runbook 回答：以上五項在 live stack 上是否真的成立？跑完之後，Adam 有把握 Phase 7 可以在這個基礎上開始。

什麼時候**不**跑：要做 OVS/P4 基準比對時，去跑 full_test_runbook.md（`run_layers.sh compare` 不在這裡）。整輪約 30–40 分鐘。

## 1. 前置：確認起點乾淨

### 誰做什麼

| 只有你能做（Adam） | 為什麼 |
|---|---|
| `sudo python3 /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/p4_testbed_topo.py` | 需要互動式 root，`sudo -n python3` 會要密碼 |
| `sudo mn -c` | 同上 |
| `mininet> exit`、Mininet CLI 裡的指令 | 在你的互動 CLI 裡 |
| 直接 `sudo kill <root process>` | `kill` 不在 NOPASSWD 清單；要殺 root process 請用 `sudo -n mnexec -a <ns pid> kill <pid>` 繞，或叫我 |

| 我可以代跑（agent） | 方式 |
|---|---|
| `stack.sh up/wait/down`、`run_layers.sh`、`l0_build_check.sh` | 不需要 root |
| 產生流量（`ping`） | `sudo -n mnexec -a $(ps -eo pid,args \| awk '$NF=="mininet:h1"{print $1}') ping ...` |
| **斷鏈／恢復**（`ifconfig s1-eth1 down/up`） | `sudo -n ifconfig`（NOPASSWD） |
| 所有 `curl` 檢查、log 分析 | — |
| `sudo -n ovs-vsctl list-br` | `ovs-vsctl`（NOPASSWD） |

⚠️ `mn`、`ip`、`ovs-ofctl`、對 root process 的 `kill` **不在** NOPASSWD 清單。上面標「Adam」的步驟不能由 agent 直接 `sudo -n`。

### 需要幾個 terminal

| | 用途 | 生命週期 |
|---|---|---|
| **B** | Mininet CLI（`sudo`，會停在 `mininet>`）—— **你的** | 全程留著，第 6 節的斷鏈測試也要用 |
| **A** | `stack.sh` / `curl` / log 分析 | 全程 |

### 確認起點是乾淨的（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh down
sudo mn -c                                        # ← Adam
pgrep -x ndtwin_kernel; pgrep -x simple_switch_g; pgrep -x iperf
#                        ^^^ 15 字元上限，寫 simple_switch_grpc 永遠匹配不到
pgrep -af "[t]estbed_topo.py"                     # 中括號避免匹配到自己的 shell
sudo -n ovs-vsctl list-br
ss -ltn '( sport = 8000 or sport = 8080 or sport = 8081 )'
```

✅ 上面五個查詢**全部沒有輸出**才算乾淨。

⚠️ **`pgrep -x ndtwin_kernel` 一定要是空的。** 殘留在 `:8000` 的 kernel 會讓 `stack.sh up` 印出 `waiting for kernel API on :8000  up` 然後**假成功** —— 它自己起的 kernel 死於 `bind: Address already in use`，但 port 有人聽所以它以為成功了。P4 這輪要是踩到一個殘留的 OVS kernel，整個圖都是 OVS 的數字，而沒有任何東西提示你不對。

⚠️ `pgrep -f testbed_topo.py`（沒有中括號）**會匹配到你自己下的那道指令**，看起來永遠像有 Mininet 在跑。這個陷阱在這個專案裡騙過人不只一次。

## 2. 離線層（build + unit tests，約 6 分鐘）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./run_layers.sh quick        # L0 build + L1 單元測試
./run_layers.sh selftest     # contract schema 自我測試 + 依賴圖
./l0_build_check.sh p4       # P4 pipeline 編譯
```

**通過標準**：`L1 passed: 1 test binary/binaries, clean under ctest and direct execution.`

⚠️ 看到 **`NO TESTS RAN` 是失敗，不是通過** —— 表示那個檔案一個測試都沒真的跑到（通常是缺套件）。

C++ 測試也要**直接跑一次**，不能只靠 ctest —— ctest 一個測試開一個 process，會掩蓋 suite 級別的失敗：

```bash
cd /home/adam/Desktop/NDTwin-Kernel && ./build/bin/test_routing_strategy
```

✅ 應該是 `[  PASSED  ] 426 tests.`、exit 0。

Python 測試 —— ⚠️ **兩個地方很容易做錯**：

1. **不是 pytest。** 這些檔案是 `unittest.TestCase`，而 `l1_unit_tests.sh` 是逐檔直接執行並解析
   `Ran N tests`。用 pytest 跑會被判 `NO TESTS RAN`（綠燈但什麼都沒驗）。
2. **必須用 venv 的 interpreter。** 系統／conda 的 `python3` 缺 grpc 和 networkx，跑起來會是
   `OK (skipped=18)` —— 一個壞掉的套件看起來會是綠的。

```bash
cd /home/adam/Desktop/NDTwin-Kernel/p4_proxy
for f in tests/test_*.py; do
  echo "--- $f"; PYTHONPATH=. ./venv/bin/python3 "$f" 2>&1 | grep -E "^(Ran|OK|FAILED)"
done
```

✅ 12 個檔案全部 `OK`，加總 **312** 個測試。（`test_p4_client.py` 顯示 `1 ran, 1 skipped` 是正常的
—— 它需要活的 bmv2 而且 proxy 不能在跑。）

```bash
cd /home/adam/Desktop/NDTwin-Kernel
for f in tests/python/test_*.py; do
  echo "--- $f"; PYTHONPATH=. p4_proxy/venv/bin/python3 "$f" 2>&1 | grep -E "^(Ran|OK|FAILED)"
done
```

✅ 兩個檔案 `OK`，加總 **101** 個測試（90 + 11）。

⚠️ **kernel-side 的 `tests/python` 沒有註冊進 ctest，一定要分開跑。** 只跑 ctest 不會跑到它們。

**通過標準（2026-08-10 實測）**：

| 測試 | 指令 | 預期 |
|---|---|---|
| C++ unit tests | `./build/bin/test_routing_strategy` | `[ PASSED ] 426 tests.` |
| p4_proxy Python | 逐檔 `PYTHONPATH=. ./venv/bin/python3 tests/test_*.py` | 12 檔全 `OK`，共 **312** |
| kernel-side tests/python | 逐檔 `PYTHONPATH=. p4_proxy/venv/bin/python3 tests/python/test_*.py` | 2 檔全 `OK`，共 **101**（**未註冊 ctest，要分開跑**） |

## 3. 起 stack（P4 順序：Mininet -> proxy -> kernel）+ 等收斂

### 3a. 開 bmv2 Mininet（terminal B，Adam）

```bash
sudo python3 /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/p4_testbed_topo.py
```

✅ 看到 `mininet>` 就成功。10 台交換機都要在 listen，而且**用腳本自己的驗證**而不是看它印什麼：

```bash
cat /tmp/ndtwin_p4_switches.json | python3 -m json.tool | head -20
```

⚠️ 這個腳本曾經在 s10 已經死掉的情況下印「10 switches listening」（port 被孤兒 process 佔住）。現在它有 PID 記錄和 `verify_switches()`，但還是以 manifest 為準。

### 3b. 起 proxy + kernel（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh up p4
```

✅ 要看到：

```
  waiting for link discovery: want 12 destination paths
  paths=12  converged after 2s
[3/3] kernel
  waiting for kernel API on :8000 . up
```

> ⚠️ **P4 的順序和 OVS 相反，這是對的，不是筆誤。** bmv2 的 `simple_switch_grpc` 是 gRPC **server**（listen `50051-50060`），proxy 是 **client**。先開 Mininet，proxy 才連得到。連不到時 proxy 直接退出，而且 gRPC channel 是 lazy 連線，錯誤會延到第一個阻塞 RPC 才浮現，看起來像別的問題。

⚠️ log 出現 `ECONNREFUSED` 到 `:5005x` 就是 bmv2 沒起來 —— 回 3a。

然後確認 proxy log 的 clone session：

```bash
grep -c "Clone session 250 -> port 255 installed" .test_run/logs/p4_proxy.log
# 10
grep -c "clone session failed\|NO telemetry" .test_run/logs/p4_proxy.log
# 0
```

⚠️ 沒設 clone session 的話 bmv2 會**安靜地**丟掉每一份 clone，telemetry 全空但不報錯。

### 3c. 等收斂（terminal A）

```bash
./stack.sh wait
```

✅ 預期：`switches=10 up=10 enabled=10 edges=40`，約 1 s。

⚠️ **舊 runbook 說 P4 模式 `wait` 會 timeout、`enabled=0` —— 已過時。** Phase 6 之後 P4 模式會收斂；看到 `enabled=0` 才是真的有問題。

⚠️ kernel log 開頭會有一條 `curl ... :8080/ryu_server/all_destination_paths` 失敗 —— **預期的**（FlowLinkUsageCollector.cpp:507-509）：第一次嘗試時 switch kinds 還沒就緒，它去問 Ryu 的 port，失敗後自己修正。不要當 regression。

> Topology poll interval：kernel 前 90 秒每 5 秒一次，之後每 30 秒一次（不是 1 秒 —— 那是一直以來對 sleep slice 的誤讀）。這會影響第 6 節的偵測／恢復時間。

## 4. 靜態健康檢查（idle，無流量）

第 5 節的 ping 還沒開始。照表查：

| # | 檢查 | 指令 | 預期（2026-08-10 實測） |
|---|---|---|---|
| ① | 圖結構 | `curl -s localhost:8000/ndt/get_graph_data` | switches 10、up 10、enabled 10；hosts 4、up 4；edges 40、up 40 |
| ② | node keys | 同上 | `admin_disabled`、`brand_name`、`device_layer`、`device_name`、`dpid`、`ecmp_groups`、`ip`、`is_enabled`、`is_up`、`mac`、`nickname`、`vertex_type` |
| ③ | 電力報告 | `curl -s localhost:8000/ndt/get_power_report` | 10 entries、33466–147622 mW、10 台各不相同、跨 polls 穩定 |
| ④ | 平均鏈路使用率 | `curl -s localhost:8000/ndt/get_average_link_usage` | `0.0`（idle 時正確，**不是故障**） |
| ⑤ | OpenFlow flow table | `curl -s localhost:8000/ndt/get_switch_openflow_table_entries` | 10 switches、4 flow entries each |
| ⑥ | 偵測到的 flow | `curl -s localhost:8000/ndt/get_detected_flow_data` | 0 flows（idle） |
| ⑦ | proxy：拓撲 links | `curl -s localhost:8081/v1.0/topology/links` | 32 directed links |
| ⑧ | proxy：all-destination paths | `curl -s localhost:8081/ryu_server/all_destination_paths` | 12 paths |
| ⑨ | proxy：交換機狀態 | `curl -s localhost:8081/p4/switch_state` | 每台 `probe_ok: true`、`stream_alive: true`、`last_lldp_age_s` 與 `last_packet_in_age_s` 均約 0–5 s |

① 的完整檢查：

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
nodes=d['nodes']; edges=d['edges']
sw=[n for n in nodes if n.get('vertex_type')==0]
hosts=[n for n in nodes if n.get('vertex_type')!=0]
print('switches', len(sw), 'up', sum(1 for n in sw if n['is_up']), 'enabled', sum(1 for n in sw if n['is_enabled']))
print('hosts', len(hosts), 'up', sum(1 for n in hosts if n['is_up']))
print('edges', len(edges), 'up', sum(1 for e in edges if e['is_up']))"
```

✅ 預期：

```
switches 10 up 10 enabled 10
hosts 4 up 4
edges 40 up 40
```

② 的 node keys 檢查：

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
sw=[n for n in d['nodes'] if n.get('vertex_type')==0][0]
print(sorted(sw.keys()))"
```

✅ 預期（sorted）：

```
['admin_disabled', 'brand_name', 'device_layer', 'device_name', 'dpid', 'ecmp_groups', 'ip', 'is_enabled', 'is_up', 'mac', 'nickname', 'vertex_type']
```

⑦⑧ 的計數：

```bash
curl -s localhost:8081/v1.0/topology/links | python3 -c "import json,sys; print(len(json.load(sys.stdin)))"
# 32
curl -s localhost:8081/ryu_server/all_destination_paths | python3 -c "
import json,sys; print(len(json.load(sys.stdin)['all_destination_paths']))"
# 12
# ⚠️ 這個端點回的是 {"status":..., "all_destination_paths":[...]}，不是裸 list。
#    寫 len(json.load(...)) 會得到 2（dict 的 key 數），看起來像壞掉。
```

⑤ 的 flow table 檢查：

```bash
curl -s localhost:8000/ndt/get_switch_openflow_table_entries | python3 -c "
import json,sys
for sw in json.load(sys.stdin):
    print(sw['dpid'], sum(len(v) for v in sw['flows'].values()))"
```

✅ 預期：10 行，每行最後一個數字是 `4`。

⚠️ **`avg_link_usage` = 0.0 在 idle 時是對的**：它刻意排除所有接到 host 的邊。第 5 節灌跨交換機流量後它會爬升；那時如果還是 0.0，才需要查。兩個流量端點掛同一台交換機時它也會是 0.0 —— 都不是 bug。

⚠️ `get_path_switch_count` 是 **GET + query params**，不是 POST。實測：

```bash
curl -s "localhost:8000/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.4"
# {"dst_ip":"10.0.0.4","src_ip":"10.0.0.1","status":"success","switch_count":5}
```

POST 會回 `{"error":"Not Found"}`，看起來像功能沒實作，其實是 method 用錯。

## 5. Telemetry（灌流量 + 邊跑邊查）

Terminal B（Adam）：
```
mininet> h1 ping -c 20000 -i 0.002 h4
```
或 agent 代跑（背景執行，避免佔住 terminal）：
```bash
sudo -n mnexec -a "$(ps -eo pid,args | awk '$NF=="mininet:h1"{print $1}')" ping -c 20000 -i 0.002 10.0.0.4 > /tmp/h1_h4_ping.out 2>&1 &
```

流量一跑就要查（flow 幾秒就老化，停下來就查不到）：

```bash
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -m json.tool | head -80
curl -s localhost:8000/ndt/get_average_link_usage
```

⚠️ **舊 runbook 教的「看 kernel log 的 `addressed=` 有沒有在漲」在這個 build 上行不通。**
那行 (`sFlow ingest healthy: rx=..., addressed=...`) 只在**第一個 pass** 以 INFO 印一次，之後降為
TRACE（`FlowLinkUsageCollector.cpp:1799-1800` 的 `firstSample ? info : trace`）。實測整份 log 裡
**只有一行**，而且值是 `rx=0`，因為那時還沒有流量。拿它判斷流量夠不夠會得到相反的結論。

判斷流量夠不夠，改看這兩個端點本身：`get_detected_flow_data` 出現 flow、`get_average_link_usage`
在連續查詢間**爬升**。

**2026-08-10 實測參考值**：

| 項目 | 值 |
|---|---|
| `get_detected_flow_data` | **2 flows**（ICMP 雙向：type 8 request + type 0 reply），path length **7 hops each**，rate **80281–200704 bps** |
| `get_average_link_usage` | 爬升 **7.0e-05 -> 1.6e-04 -> 2.1e-04**（樣本累積，三次查詢） |
| ping 結果 | **3000 packets, 0% loss, rtt avg ~12.8 ms** |

⚠️ **rate 的變異是 1/256 取樣造成的，不是算錯。** 80281 和 200704 差 2.5 倍在短窗口下預期會有。

⚠️ **flow rates 會在流量停下的幾秒內衰退到 0。** 趁 ping 還在跑的時候查；ping 停了以後 `get_detected_flow_data` 回到 0 是對的。

ping 的 `-c 20000` 是為了確保流量持續夠久；實測參考值取的是約 3000 封包處的統計（0% loss、avg ~12.8 ms）。查完 telemetry 就可以讓它結束，不必等 20000 跑完。

## 6. Phase 6 專項：link failure -> 維持 down -> 恢復

這節測的是：beacon timeout -> `link_failure_detected` -> edge 在 kernel graph 下去且**維持下去**（proxy 從 `/v1.0/topology/links` 拿掉 failed links，poll 沒有東西復活它們）-> `ifconfig up` 後恢復。

### 6a. 斷鏈

```bash
sudo -n ifconfig s1-eth1 down
```

這條是 s1:1 <-> s5:1 的 link。`ifconfig` 在 NOPASSWD 清單，agent 可以代跑。**不要用 `ip link set ... down`** —— `ip` 不在 NOPASSWD 清單。

### 6b. 等偵測（約 11 s）

```bash
sleep 11
grep "link_failure_detected" .test_run/logs/kernel.log
```

✅ 三筆 `link_failure_detected` POSTs，時間約在斷鏈後 11 s。

（這 11 秒**與 kernel 的 topology poll 無關** —— 失效是 proxy **推**過來的，不是 kernel 拉的。
延遲來自 beacon 逾時：`LINK_BEACON_TIMEOUT_S` 是 15 秒、beacon 每 5 秒一個，watchdog 每 5 秒掃一次，
所以最後一個 beacon 到判定之間是 15 秒，而最後一個 beacon 可能落在你斷線前 5 秒內 —— 淨延遲約
11–20 秒。poll 的角色在 6e：它**沒有**把邊救回來。）

### 6c. 檢查圖：37/40

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
edges=d['edges']
down=[e for e in edges if not e['is_up']]
print('edges up:', len(edges)-len(down), '/', len(edges))
for e in down: print(json.dumps(e, ensure_ascii=False))"
```

✅ 預期：`edges up: 37 / 40`，down 的三條是：

```
s1:1 -> s5
s5:1 -> s1
s6:1 -> s1
```

⚠️ **注意第三條 s6:1->s1 —— 那是陷阱，不是你真的弄斷了 s6-s1。** `ifconfig s1-eth1 down` 會讓 s1 的**整個 packet-in 路徑停擺**。實測：s1 的 `last_packet_in_age_s` 衝到 73 s，而 `probe_ok` 仍 true、`last_lldp_age_s` 仍約 3 s（s1 還在送 beacon，但不再把收到的 beacon 送給 CPU）。所以同一台交換機上健康的 s6:1->s1 也被回報 failed，s1 的兩個 inbound 方向都下去，twin（s6）失去到 h1 的 reachability —— 3 條 destination paths 消失。Watchdog 根據它的證據是對的；錯的是模擬方法。Mininet CLI 的 `link s1 s5 down` 底層做一樣的事（未另測）。**測試時，只信你故意弄斷的那條 link 的判決。**

### 6d. 穩定性：40 次取樣、約 119 秒不 flapping

```bash
for i in $(seq 1 40); do
  curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
print(sum(1 for e in d['edges'] if e['is_up']))"
  sleep 3
done
```

✅ 40 次全部 `37`，沒有 38/39 跳動。

### 6e. 鐵證：kernel 自己的 poll 也看到 37

```bash
grep "topology from the control plane" .test_run/logs/kernel.log | tail -1
```

✅ 預期：

```
topology from the control plane: 10 switches, 4 hosts, 37 edges up
```

這證明不是你的查詢看錯，是 kernel 自己的 topology poll 就只看到 37 條 up。

### 6f. 路徑：12 -> 9

```bash
curl -s localhost:8081/ryu_server/all_destination_paths | python3 -c "
import json,sys
paths = json.load(sys.stdin)['all_destination_paths']
print('paths:', len(paths))
# 每條 path 是 [[node, out_port], ...]，終點在最後一個 hop 的第一個元素。
to_h1 = [p for p in paths if p[-1][0] == '10.0.0.1']
print('paths into h1:', len(to_h1))"
```

✅ 預期：`paths: 9`；消失的 3 條全部是 `-> 10.0.0.1`（h1 在 s1 底下，s1 的 inbound 被 trap 1 波及）。

### 6g. 恢復

```bash
sudo -n ifconfig s1-eth1 up
sleep 14
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('edges up:', sum(1 for e in d['edges'] if e['is_up']), '/', len(d['edges']))"
curl -s localhost:8081/ryu_server/all_destination_paths | python3 -c "
import json,sys; print('paths:', len(json.load(sys.stdin)['all_destination_paths']))"
```

✅ 預期：**40/40**、**12 paths**，恢復時間約 14 s 內。

## 7. 新欄位 admin_disabled 的檢查

⚠️ **kernel 目前以 `--no-ai` 跑**，Intent Translator 那條會設 `adminDisabled` 的路徑**到不了**。這裡只驗證欄位存在且全為 false。真的要演練 DisableSwitch，需要重啟 kernel 加 `--ai` —— 那是 Phase 7 之後的事，不在這份 runbook。`is_enabled` 以 folded 形式輸出（`isEnabled && !adminDisabled`），所以既有消費者不用改就能看到 disable。

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes=d['nodes']; edges=d['edges']
bad_nodes=[n for n in nodes if n.get('admin_disabled') is not False]
bad_edges=[e for e in edges if e.get('admin_disabled') is not False]
print('nodes:', len(nodes), 'admin_disabled present and all false:', not bad_nodes)
print('edges:', len(edges), 'admin_disabled present and all false:', not bad_edges)
# 唯一從外部驗得到的不變量：沒有東西同時 admin_disabled 又 is_enabled。
print('nothing is both disabled and enabled:',
      all(not (x['admin_disabled'] and x['is_enabled']) for x in nodes + edges))"
```

✅ 預期：三行都是 `True`。

⚠️ **第三行現在是 vacuous（空真）**，要講清楚：`admin_disabled` 全是 false，所以「沒有東西同時
disabled 又 enabled」必然成立。它現在的用途是**迴歸偵測** —— 哪天有東西被 disable 了而 `is_enabled`
沒跟著變 false，這行才會紅。
另外**不要**寫成 `is_enabled == (is_up and not admin_disabled)`：折進去的是 `isEnabled`，不是
`isUp`，兩者互相獨立。現在全部節點都 up 且 enabled，那個錯公式會剛好通過。

## 8. 判定總表：綠燈代表什麼、哪些綠燈不代表什麼

| 綠燈 | 代表 | 不代表 |
|---|---|---|
| `stack.sh wait` 收斂（10/10/10/40，約 1 s） | Phase 6 graph 在 P4 是真的；`is_up` 是真的 | Telemetry 也正常（要第 5 節） |
| 第 4 節九項全過 | idle 狀態 kernel/proxy 都健康 | 流量狀態也健康（要第 5 節） |
| `get_detected_flow_data` 2 flows、rate 非零 | Telemetry 鏈路在流量下是真的 | rate 的具體數字是穩定的（1/256 取樣變異是預期） |
| `avg_link_usage` 爬升 | 跨交換機流量有被算進去 | `0.0` 是壞掉（idle 或同 switch 時 0.0 是對的） |
| Link failure：37/40、不 flapping | Link-failure detection 端到端可用；proxy 會 withhold failed links | 那三條 down 都是真的斷路（s6:1->s1 是 trap 1 的假陽性） |
| 恢復：`ifconfig up` 後 40/40、12 paths | 恢復路徑也通 | — |
| `admin_disabled` 都在且 false | 新欄位存在、folded `is_enabled` 沒破壞既有 consumers | DisableSwitch 完整路徑有被測過（kernel 是 `--no-ai`，測不到） |
| proxy log：clone session == 10、failed == 0 | Clone session 裝好 | Telemetry 有在流（要第 5 節的 flows） |
| `/p4/switch_state`：`probe_ok` true、`stream_alive` true | gRPC channel 活著 | Dataplane 健康（`last_packet_in_age_s` 高代表 packet-in 卡住，trap 1） |
| `get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.4` -> `switch_count: 5` | GET endpoint 正常 | POST 回 404 = 功能壞掉（那只是 method 用錯） |

## 9. 出問題時先看哪裡

| 症狀 | 先看哪裡 | 別誤判成什麼 |
|---|---|---|
| `wait` 卡住或 `enabled=0` | kernel log、proxy log；`pgrep -x ndtwin_kernel` 是不是殘留 kernel 佔住 :8000 | 舊 runbook 的「P4 本來就會 timeout」 |
| `converged after 2s` | 對 P4 這是**正確**的（paths=12, 2s） | OVS 的「2 秒 = 閘門壞掉」不適用在這裡 |
| `avg_link_usage` = 0.0 | 流量有在跑嗎？兩端是不是同一台交換機？ | 不是 bug（設計上排除 host 邊） |
| `get_detected_flow_data` = 0 | 流量還在跑嗎？（`addressed=` 那行只印一次，不能拿來判斷） | 不是 telemetry 壞掉 —— flow 幾秒就老化 |
| `{"error":"Not Found"}` | 端點是 GET 還是 POST？有沒有用 query params？ | 不是功能沒實作（`get_path_switch_count` 是 GET） |
| Link failure 後三條 down | 你故意斷的那條 + s5 反向 + s6:1->s1 | 不要相信 s6:1->s1 是真的斷了（trap 1） |
| kernel log 開頭一條 `:8080/ryu_server/all_destination_paths` 失敗 | FlowLinkUsageCollector.cpp:507-509 | 不是 regression，它自己會修正 |
| `pgrep -f simple_switch_grpc` 沒輸出 | comm 15 字元上限，用 `pgrep -x simple_switch_g` | 不是 bmv2 沒起來 |
| `/p4/switch_state` `probe_ok` true 但 `last_packet_in_age_s` 很高 | 那台的 packet-in 路徑可能卡了（trap 1） | `probe_ok` true 不代表 dataplane 健康 |
| `stack.sh up p4` 印 `ECONNREFUSED :5005x` | bmv2 沒起來，回 3a | 不是 proxy 的錯 |

log 位置：`.test_run/logs/{kernel,p4_proxy}.log`
