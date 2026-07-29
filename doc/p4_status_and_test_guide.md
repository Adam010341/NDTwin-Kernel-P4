# P4/bmv2 支援：目前進度與測試流程

對應計畫：[p4_bmv2_support_plan.md](p4_bmv2_support_plan.md)　測試分層定義：[testing_workflow.md](testing_workflow.md)

最後更新：2026-07-29（branch `fix/flow-rate-divide-by-zero`，最新 commit `9808684`）

---

## 先講最重要的一件事

**現在還不能做「完整的 end-to-end twin 測試」。** Phase 6 還沒做，而 `GET /ndt/inform_switch_entered`
是**唯一**會把圖上的 vertex/edge 的 `isEnabled` 設成 true 的東西，proxy 目前完全沒有呼叫它。

所以如果你現在開起整套 P4 stack，會看到下面這些。**這些數字是我實際跑起來量的**，不是推論：

| 項目 | 實測值 | 為什麼 |
|---|---|---|
| switch `is_up` | **10/10 是 true** ⚠️ | 這是**假的**。bmv2 的 liveness 還是 stub（`DeviceConfigurationAndPowerManager.cpp:422`），無條件標記為 up。就算完全沒開 bmv2 也一樣顯示 up |
| host `is_up` | **4/4 是 true** ⚠️ | 同上，也是 stub |
| switch／host `is_enabled` | **0/14** | `inform_switch_entered` 沒人呼叫。這才是真正代表「控制平面認得這台」的旗標 |
| edge `is_up` / `is_enabled` | **0/40** | 同上 |
| `avg_link_usage` | **0.0** | edge 沒 enabled，sample 對不到 edge |
| flow 的 `path` | **`[]`** | BFS 找路需要 enabled 的圖 |

⚠️ **請特別注意 `is_up` 這件事**：它會讓 GUI 看起來「10 台都活著」，但那是 stub 騙你的 ——
真正的旗標是 `is_enabled`，而它是 0。所以**不要用 `is_up` 判斷 P4 模式有沒有成功**，要看 `is_enabled`。
我原本以為 `is_up` 會是 false，實際跑過才發現不是，這正是為什麼下面的流程要看具體欄位而不是看畫面。

**這不是壞掉，是還沒做到那一步。** 下面的測試流程是針對「現在真的能驗證的東西」設計的，
不要用「GUI 有沒有正常顯示」當標準 —— 那要等 Phase 6。

---

## 一、目前應該要有的功能

### A. 已完成，而且有測試證明它對

| 功能 | 說明 | 證據 |
|---|---|---|
| **不會再 SIGFPE 崩潰** | `hopsCounter == 0` 的除以零守衛回來了，並且把速率計算抽成 `computeEstimatedRates` 這個可測的接縫 | 單元測試（含 `hopsCounter == 0` 的迴歸測試） |
| **sFlow parser 不會被打爆** | 加了 `BoundedWords` 邊界檢查。這是 kernel 第二個對外輸入面（任何能送 UDP 到 6343 的東西都碰得到） | ASan 實測：拿掉 `BoundedWords` 就重現 `heap-buffer-overflow` |
| **typed SwitchKind 派發** | `enum class SwitchKind { OVS, BMV2, HARDWARE }`，取代原本用檔名做大小寫敏感的字串比對。O(1) 查表，不再每個 flow 操作都深拷貝整張 BGL 圖 | 單元測試：BMV2 dpid 給 P4 strategy、OVS dpid 給 OVS、未知 dpid 回錯誤 + WARN、只有 `brand_name` 的舊 JSON 仍能正確分類 |
| **同質性驗證** | 拓撲裡 switch 種類不一致會直接 fatal 並列出是哪些 dpid，除非 `ALLOW_MIXED_DATAPLANE` | 單元測試（預設失敗、開旗標後通過） |
| **南向失敗看得見** | `OpResult { ok, httpStatus, message }`，curl 帶 `-w '%{http_code}' --max-time 5`。200 裡面包 `{"status":"error"}` 也算失敗 | 單元測試：mock 回 404／500／timeout |
| **P4 誠實宣告自己的極限** | group/meter 回 `501 unsupported`，而不是像以前那樣安靜地轉給 Ryu | 單元測試 |
| **P4 pipeline 能表達 5-tuple 規則** | `flow_5tuple` ternary 表 + 真正的 priority，前置於 `ipv4_lpm`。LPM 表做不到這件事（LPM 沒有 priority，是比 prefix 長度） | `p4c-bm2-ss` 編譯把關 |
| **ARP 不再被安靜丟掉** | 加了 `l2_forward` exact 表。之前非 IPv4 的 frame 因為沒設 `egress_spec` 就消失了 | 編譯把關 |
| **TTL 不會繞回 255** | 遞減前先檢查 | 編譯把關 |
| **synthesised sFlow 真的能被 kernel 解析** | proxy 自己組 sFlow v5 打到 6343，所以 `FlowLinkUsageCollector`、`Classifier` 和所有 `/ndt/` metric 都不用改 | **跨語言 round-trip**：Python emitter 真的產出的位元組 → 餵進 C++ 真的在用的 parser → 斷言還原出的 5-tuple。TCP／UDP／ICMP／截斷／非 IPv4／多 sample 串接都有 |
| **clone session 250 有被設定** | 沒設的話 bmv2 會**安靜地**丟掉每一份 clone。失敗是硬錯誤而且會講出來 | 單元測試：斷言送出去的 request（session id、CPU port replica、oneof 用哪一邊、`class_of_service = 0`、ALREADY_EXISTS 改用 MODIFY、真失敗回 False） |
| **sample 和真 packet-in 分流** | 靠 `packet_in.reason` 區分。取樣是全部流量的 1/256，讓 sample 跑進 LLDP parser 會把 discovery 淹掉 | 單元測試 |
| **全 bmv2 拓撲用 identity port mapping** | `populateIfIndexToOfportMap` 是去 shell 呼叫 `ovs-vsctl`，它完全不認識 bmv2 的介面，所以會回空 map、每個 port 都變 0 | 單元測試（含「空拓撲」和「混合拓撲」都必須維持原本的翻譯行為，不能影響現有 OVS 部署） |
| **agent IP 從 kernel 讀的同一份拓撲 JSON 來** | kernel 是用 `AgentKey{agentIP, port}` 把 sample 對到 edge，位址不對就是「收到了但對應到空氣」 | 單元測試（含 host 必須被排除 —— host 的 dpid 都是 0，會全部塌到同一個假 agent） |
| **headless 啟動** | `--mode` / `--topology` / `--no-ai`，不用再手動打 `std::cin` | — |

### B. 已完成，但只有單元測試，還沒對真的 bmv2 跑過

這些是「邏輯上驗證過、實機還沒驗證」的：

- **1/256 取樣 clone 到 CPU** —— P4 編譯過，clone session 的 request 也驗證過，但沒有真的看到一份 sample 從 bmv2 出來。
- **direct counter（`flow_5tuple` / `ipv4_lpm`）和 per-port counter** —— 表和 counter 都在 p4info 裡，但 `/stats/flow/{dpid}` 還沒接（見下面 Phase 6）。
- **P4RoutingStrategy 的實際下規則路徑** —— curl → proxy → P4Runtime 這條鏈的每一段都有測，但整條沒有對活的 switch 跑過。

### C. 還沒做（會影響你測試時看到什麼）

| Phase | 缺什麼 | 對你測試的影響 |
|---|---|---|
| **6** | proxy 不呼叫 kernel 的北向（`inform_switch_entered`、`link_failure_detected`、`inform_all_destination_paths`）；`GET /stats/flow/{dpid}` 還是回 `[]`；`pingWorker` 的 liveness 還是假的 | **整張圖是死的**。這是現在最大的一塊，也是下一步要做的 |
| **3**（proxy 那半） | 少 `POST /stats/flowentry/delete`（非 strict，這是所有 `priority == -1` 刪除的預設路徑，包含 Intent Translator 的）；prefix 還是硬寫 `/32`；沒有 idle_timeout 模擬；dpid→grpc_addr 還是硬寫 `range(1,11)`；`TopologyManager` 沒加鎖 | 刪規則和聚合路由會不如預期 |
| **4**（漏掉的） | `p4_testbed_topo.py` 的 **TCLink 頻寬沒補回來**（OVS 那邊是 1000/10000 Mbps，`GraphTypes.hpp` 和兩份拓撲 JSON 都假設 1 Gbps）；ECMP 的 ActionSelector 也還沒做 | 頻寬相關的計算會用預設值，不是 1 Gbps |
| **7** | 電源管理還是壞的 | 別測關機 |
| **8** | 清理 | — |

> **技術債（你說先留著，之後跟其他人討論）**：每一條南向指令都是
> `popen("curl … -d '" + json.dump() + "'")`。`nlohmann::json::dump()` 不會 escape 單引號，而 JSON 來自
> 未認證的 REST body 和 LLM 輸出。目前 3 個檔案共 22 處。

---

## 二、測試流程

由快到慢，**建議照順序**。前面的過不了就不用往後跑。

### 第 0 步：不需要開任何東西（約 2 分鐘）

這步涵蓋 153 個測試（90 個 C++ + 63 個 Python），是你日常改完程式碼唯一需要跑的。

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./run_layers.sh quick
```

**通過標準**（腳本會自己判斷，不用你看 log 找 warning）：

```
L0 passed: ... build
L1 passed: 1 test binary/binaries, clean under ctest and direct execution.
  test_clone_session.py          PASS  14 ran and passed
  test_p4_client.py              PASS  1 ran, 1 skipped     ← 沒開 bmv2，這是正常的
  test_sflow_emitter.py          PASS  48 ran and passed
```

**要特別注意**：如果看到 `NO TESTS RAN`，那是失敗，不是通過 —— 表示那個檔案一個測試都沒真的跑到
（通常是缺套件）。這正是我把 Python 測試接進 L1 的當下抓到 `test_p4_client.py` 從來沒跑成功過的方式。

P4 pipeline 的編譯要另外跑：

```bash
./l0_build_check.sh p4
```

### 第 0.5 步：sanitizer（改到 parser 或 collector 的時候跑）

sFlow parser 是對外輸入面，改到它就值得跑一次：

```bash
cd /home/adam/Desktop/NDTwin-Kernel
cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
cmake --build build-asan -j$(nproc)
cd build-asan && ASAN_OPTIONS=detect_leaks=0 ./bin/test_routing_strategy
```

通過標準：`[  PASSED  ] 90 tests.`，而且**沒有**任何 `ERROR: AddressSanitizer` 或 `runtime error:`。

### 第 1 步：telemetry 路徑（不需要 bmv2，也不需要 Mininet）

這一步很有價值：它用真的 kernel process 驗證 sFlow 這條路，而且不用開資料平面。

**開一個 terminal 跑 kernel：**

```bash
cd /home/adam/Desktop/NDTwin-Kernel/build
./bin/ndtwin_kernel --mode mininet \
  --topology ../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json --no-ai
```

啟動時應該看到這行（這是新的 identity mapping 生效的證據）：

```
All-bmv2 topology: using identity ifIndex->port mapping and skipping ovs-vsctl,
which does not know about bmv2 interfaces.
```

**另一個 terminal 把 fixture 打進去**（這些就是 emitter 真的產出的位元組）：

```bash
cd /home/adam/Desktop/NDTwin-Kernel
python3 -c "
import socket, glob
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for f in sorted(glob.glob('tests/fixtures/emitted_*.bin')):
    s.sendto(open(f,'rb').read(), ('127.0.0.1', 6343))
    print('sent', f)
"
curl -s http://localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json, sys
flows = json.load(sys.stdin)
print('flow count:', len(flows))
for f in flows:
    print(' ', f['src_ip'], f['src_port'], '->', f['dst_ip'], f['dst_port'], '| path', f['path'])
"
```

（IP 是以整數回傳的。`16777226` = `0x0100000A` = 10.0.0.1。）

**通過標準 —— 這是我實測到的輸出，你應該看到一樣的 5 筆：**

| 回傳值 | 意思 |
|---|---|
| `16777226:5001 → 67108874:40997` | 10.0.0.1:5001 → 10.0.0.4:40997（TCP）|
| `16777226:5001 → 67108874:40998` | 同上但是截斷的 frame |
| `33554442:5201 → 50331658:33333` | 10.0.0.2:5201 → 10.0.0.3:33333（UDP）|
| `16777226:8 → 33554442:0` | ICMP echo request，type 8 code 0 放在 port 欄位 |
| `50331658:3 → 67108874:1` | ICMP dest-unreachable，type 3 code 1 |

- **剛好 5 筆**。送進去的是 7 個 fixture：ARP 正確地不產生 flow，`emitted_multi.bin` 裡的三筆跟前面重複所以合併。
- **不應該**有 malformed datagram 的訊息。
- `path` 會是 `[]`、link usage 會是 `0.0` —— **這是預期的**（Phase 6 未做）。
- log 裡會有一堆 `parseFlowStatsTextToJson JSON parsing failed`（我實測有 50 筆）。**這是正常的** ——
  沒開 proxy，kernel 去輪詢 flow stats 拿到空回應。跟 telemetry 無關。

這一步能證明的事：P4 那邊產出的 sFlow，真的能被跑起來的 kernel 收下並解析成正確的 flow。

### 第 2 步：OVS 沒有退步（**每個 phase 都必須跑**）

Phase 0／1／2 和 identity mapping 都動到共用程式碼，所以這是每一個 phase 的閘門。

**這台機器上有兩個前置條件，缺任一個 OVS 模式都會停在 `up=0 enabled=0` 而且不會自己好**
（這兩個都是實際跑的時候踩到才發現的，已經修進 `stack.sh`，寫在這裡是為了讓你看懂症狀）：

1. **`ovs-vsctl` 要能免密碼 sudo。** kernel 的 `pingWorker` 每秒 shell 出去跑一次
   `sudo ovs-vsctl list-br`；但 `stack.sh` 是用 `setsid` 背景啟動 kernel 的，沒有 controlling
   terminal，`sudo` 沒辦法問密碼就直接失敗，回一個空的 bridge 清單 → 每台 switch 都被判定
   unreachable → 每秒被 `setVertexDown()` 蓋一次。症狀是 `up=0` 但 `enabled` 可能是 10。

   ```bash
   echo 'adam ALL=(root) NOPASSWD: /usr/bin/ovs-vsctl, /usr/sbin/ifconfig, /usr/bin/mnexec' \
     | sudo tee /etc/sudoers.d/ndtwin-mininet
   sudo chmod 440 /etc/sudoers.d/ndtwin-mininet
   sudo visudo -c          # 檢查語法，做完一定要跑
   ```

2. **Ryu 要多載 `ryu.app.rest_topology`**，而且 **kernel 必須在 Mininet 之後至少 60 秒才開**。
   `--observe-links` 只提供事件、不提供 `/v1.0/topology/*` 這組 REST endpoint，少了它那三個網址
   回 404，而 kernel 的 `updateSwitches()` 會把 404 的 HTML 拿去 `json::parse`、丟例外後**靜靜地**
   放棄。而 `TopologyAndFlowMonitor::run()` 只在啟動時**拉一次**就結束（沒有重試迴圈），所以那一刻
   Ryu 還沒收斂完的東西，kernel 這輩子都看不到。這兩件事 `stack.sh up ovs` 現在都處理好了
   （會顯示 60 秒倒數）。

`api` 和 `baseline` **必須帶資料平面參數**（`ovs` 或 `p4`），因為它們要據此挑對應的拓撲檔；
只有 `compare` 不用帶（它就是拿兩邊的 capture 來 diff）。

```bash
cd tools/test_workflow
./stack.sh up ovs              # Ryu + OVS Mininet → 等 60s → kernel
./stack.sh wait                # 等到 up=10 enabled=10 才算起來了
./run_layers.sh api ovs        # L2 + L3 + log allowlist 檢查
./run_layers.sh baseline ovs   # 記錄基準（存到 .test_run/baseline/ovs）
# 之後任何改動再跑：
./run_layers.sh compare        # 跟基準比（不帶參數）
./stack.sh down
```

想連流量一起驗（要求一定要有 flow／path／非零速率）就加 `--traffic`：

```bash
./run_layers.sh api ovs --traffic
```

**通過標準**：L2 全過，`compare` 沒有非預期的差異。有預期的差異要進
[tools/contract_test/baseline_diff_allowlist.txt](../tools/contract_test/baseline_diff_allowlist.txt)，
而且要寫原因。

在 Mininet CLI 裡跑 `h1 ping h4`、`iperf h1 h4`，然後：

```bash
curl -s http://localhost:8000/ndt/get_detected_flow_data | python3 -m json.tool | head -30
curl -s http://localhost:8000/ndt/get_average_link_usage | python3 -m json.tool | head
```

OVS 模式下這些**應該**是正常的（有 path、有非零速率）。如果不正常，就是我動到共用程式碼弄壞了 —— 這比 P4 那邊還沒做完更嚴重。

### 第 3 步：P4 stack 真的起得來（目前能做到的極限）

```bash
cd tools/test_workflow
./stack.sh up p4           # proxy + bmv2 Mininet + kernel
```

**通過標準**（看 proxy 的 log）：

```bash
tail -40 .test_run/logs/p4_proxy.log
```

應該看到 10 台都有這三件事：

```
[Proxy Agent] Connected to Switch 1
[1] Clone session 250 -> port 255 installed
[Proxy Agent] Switch 1 sampling to sFlow as 192.168.123.11
```

**如果看到這行，telemetry 就是沒有：**

```
[Proxy Agent] Switch N: clone session failed, NO telemetry from it
```

然後在 Mininet CLI 裡產生流量，看 sample 有沒有真的出來：

```bash
sudo tcpdump -i lo -n udp port 6343 -c 20
```

**通過標準**：有看到封包。這會是第一次證明「bmv2 取樣 → packet-in → emitter → kernel」整條鏈在實機上通了。
這件事目前**還沒有人驗證過**，所以它是這一步真正的目的。

**不要用這些當標準**（Phase 6 未做，一定是空的）：
`/ndt/get_graph_data` 的 `is_up`、link usage、flow 的 `path`、Web GUI 的畫面。

```bash
./stack.sh down
```

---

## 三、一句話總結

現在可以放心相信的是：**kernel 不會崩、南向失敗看得見、P4 pipeline 能表達 NDTwin 真正會下的規則、
而且 proxy 合成的 sFlow 真的能被 kernel 解析成正確的 flow**（這件事有跨語言 round-trip 證明，
不是靠讀 offset 讀兩次）。

還不能相信的是：**圖是活的**。那是 Phase 6。

[Co-developed with claude code -- Adam]
