# OVS/Ryu 手動測試 runbook

**這份文件是做什麼的**：從乾淨環境開始，逐步啟動 OVS/Ryu stack，在 idle 狀態下確認靜態健康，灌流量驗證 telemetry 鏈路，模擬一條鏈路斷線後觀察偵測與恢復。全部手動執行，一步一確認。

**什麼時候跑**：任何對 OVS 路徑（Ryu controller、intelligent_router.py、kernel 的 OVS 分支、sFlow ingest、power/liveness 迴圈）的修改之後。

**涵蓋範圍**：Phase 1–6 全部完成的功能。以下這些從舊文件來的宣稱是錯的，不要照抄：

- ~~「OVS 模式的 `stack.sh wait` 永遠 timeout」~~ — 現在會收斂。
- ~~「`is_up` 是 stub」~~ — OVS 模式用 `ovs-vsctl list-br` 做真實 liveness 檢查。
- ~~「P4 runbook 的 port 是 OVS 的」~~ — OVS 模式跑 Ryu :8080，P4 模式跑 proxy :8081。port 不同。
- ~~「`avg_link_usage` 逐步爬升，是累積平均」~~ — 那是瞬時值，分母是「當下有樣本的邊數」。見 P4 runbook §5d 的更正。

本文件參考 `doc/p4_manual_test_runbook.md` 的結構、✅/⚠️/🔴 慣例和「這個檢查可能因為錯的原因通過」的寫法。**結構對齊，事實不對齊**——控制平面不同、port 不同、啟動順序相反、收斂時間差一個數量級。

**名稱刻意不帶 phase 編號。** 每個 phase 應該延伸這一份，而不是各自新增一份互相矛盾的文件。

> **⚠️ 驗證狀態**：本文件撰寫於 2026-08-10，此時機器上跑的是 P4 stack，**OVS 路徑未實測**。每個預期值都標明了來源（原始碼行號、既有文件、或 TO BE MEASURED）。Adam 第一次跑的時候請把 TO BE MEASURED 的值填入 §10 的表格。
>
> **已核對的部分（2026-08-10，逐條開檔確認）**：啟動順序的依據（`stack.sh:530-538` 確實說明兩種模式方向相反）、Ryu 需要 `--observe-links` 加上 `rest_topology` 與 `ofctl_rest`（`stack.sh:562-564`）、`#define SFLOW_PORT 6343`（`FlowLinkUsageCollector.hpp:33`）、`kFlowStatsSuspectSeconds = 0.5`（`DeviceConfigurationAndPowerManager.hpp:291`）、poll 間隔 5s/30s/90s（`TopologyAndFlowMonitor.cpp:1758-1760`）、`controlPlaneHostAndPort`（`FlowLinkUsageCollector.cpp:211-218`）、`bool adminDisabled = false;`（`GraphTypes.hpp:215`）、kernel 以 `--no-ai` 啟動（`stack.sh:606`）、`intelligent_router.py` 存在於 repo 根目錄。
>
> **拓撲規模也核對過**：`testbed_topo.py` 有 **10 個 `addSwitch`**、`HOST_NUM = 128`，topology 檔 `StaticNetworkTopologyMininet_10Switches.json` 是 10 switches / 128 hosts / **288 edges**，與本文推導的 `128×2 + 16×2 = 288` 一致。（審查時我一度以為只有 4 台 switch 而誤判本文有錯，那是我自己的 grep 截斷造成的——文件是對的。）
>
> **抽驗範圍以外的行號沒有逐條開檔**，§10 表格裡的引用請在使用時順手確認。

---

## 0. 這份文件要回答什麼

每個「你應該看到」都有精確的預期值。每個檢查如果可以「通過但原因不對」，會標出來。每個步驟標了誰能跑。本文件**不是** OVS/P4 基準比對——那份在 `doc/full_test_runbook.md`。這裡只測 OVS 路徑本身是否健康。

**和 `doc/full_test_runbook.md` 的關係**：那份文件是 OVS + P4 各一輪的**完整迴歸流程**，做完要抓基準、跑 `run_layers.sh` 契約測試、用 `compare` 比對。本文件是**手動健康檢查**——不做契約測試、不抓基準、不比對。兩者互補，不重複。如果目的是「改完 code 快速確認 stack 沒壞」，看這份；如果目的是「正式迴歸並取得可比較的基準」，看 `full_test_runbook.md`。

---

## 1. 前置：確認起點乾淨

### 誰能做什麼

| 只有 Adam 能做 | 為什麼 |
|---|---|
| `sudo python3 testbed_topo.py` | 需要互動式 root，`sudo -n python3` 會要密碼 |
| `sudo mn -c` | 同上 |
| `mininet> exit` | 在你的互動 CLI 裡 |
| `sudo -n ifconfig <iface> down/up` | NOPASSWD 有放行，但需要 root |
| `mn`、`ip`、`ovs-ofctl`、kill root process | NOPASSWD 不含這些 |

| 我可以代跑 | 方式 |
|---|---|
| `stack.sh up/wait/down`、`l1_unit_tests.sh` | 不需要 root |
| `curl` 檢查、log 分析 | — |
| `sudo -n ovs-vsctl list-br` | NOPASSWD 放行了 `ovs-vsctl` |
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
pgrep -x ndtwin_kernel; pgrep -x simple_switch_g; pgrep -x iperf; pgrep -x iperf3
#                        ^^^ 15 字元上限，寫 simple_switch_grpc 永遠匹配不到
pgrep -af "[t]estbed_topo.py"          # 中括號避免匹配到自己的 shell
pgrep -af "[p]4_testbed_topo.py"       # 也清掉 P4 Mininet（如果有殘留）
pgrep -f "[r]yu-manager"               # Ryu 殘留
sudo ovs-vsctl list-br                 # 預期空輸出（見下方陷阱）
ss -ltn '( sport = 8000 or sport = 8080 or sport = 8081 or sport = 6633 )'
```

✅ 上面八個查詢**全部沒有輸出**（`list-br` 除外——它應該輸出空行，或完全沒有 bridge 名稱）才算乾淨。

⚠️ **`pgrep -x ndtwin_kernel` 一定要是空的。** 殘留在 `:8000` 的 kernel 會讓 `stack.sh up` 印出 `waiting for kernel API on :8000  up` 然後**假成功**——它自己起的 kernel 死於 `bind: Address already in use`，但 port 有人聽所以它以為成功了。`wait_for_port` 現在會檢查 socket 擁有者（`stack.sh:353-378`，`port_owner_verdict`），但起點乾淨仍是第一道防線。來源：`stack.sh:393-448` 的 `wait_for_port` 註解。

⚠️ **`pgrep -f testbed_topo.py`（沒有中括號）會匹配到你自己下的那道指令**，看起來永遠像有 Mininet 在跑。這個陷阱騙過人不只一次。

⚠️ **`sudo ovs-vsctl list-br` 回 `""`（空字串）不代表沒有 bridge**——它代表 OVS 沒有安裝或 `ovsdb-server` 沒跑。在乾淨機器上這是預期的；如果你剛跑過 Mininet 但沒 `mn -c`，它會列出殘留的 bridge（例如 `s1` 到 `s10`）。那些必須清掉。

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

**預期數字（來源：`doc/p4_manual_test_runbook.md` §2，兩種模式共用同一份 C++ 和 Python 測試）**：

| 項目 | 數量 |
|---|---|
| C++ 測試（直接執行） | 426 pass |
| p4_proxy Python 測試 | 312 條，分布在 12 個檔案 |
| kernel-side Python/shell 測試 | 101 條，分布在 2 個檔案（`tests/python/`） + 1 個 shell（`tests/shell/`） |

⚠️ C++ 測試必須**兩種跑法都通過**——`ctest` 每個 test case 開獨立 process，會掩蓋 suite 級別的失敗（例如 static init 順序、singleton 殘留狀態）。`l1_unit_tests.sh` 兩種都跑，並且交叉比對 ctest 註冊數和 gtest 發現數是否一致。

⚠️ `test_p4_client.py` 整份 skip 是**預期行為**——它需要真實 bmv2 在 `:50051` 上跑，檔案裡有 `NDTWIN_L1_OPT_IN` 標記。不是失敗。

### OVS 模式沒有等價的「P4 pipeline 編譯」步驟

P4 模式有 `./l0_build_check.sh p4` 檢查 bmv2 pipeline 編譯。OVS 模式沒有這個步驟——switch 是 kernel OVS datapath，不需要外部編譯。跳過。

---

## 3. 起 stack（OVS 順序）

### ⚠️ 重要：OVS 的啟動順序和 P4 相反

| 模式 | 誰是 server | 正確順序 |
|---|---|---|
| OVS | **Ryu** 監聽 :6633（OpenFlow），switch 主動連進來 | **Ryu → Mininet** → 等收斂 → kernel |
| P4 | **bmv2** 監聽 :50051-50060，proxy 是 gRPC **client** | Mininet → proxy → 等收斂 → kernel |

來源：`stack.sh:530-538`（「Treating both as 'control plane first' is what used to break P4 mode.」）。

`stack.sh up ovs` 會走對的順序。kernel 一定要最後開。

### 3a. 開 Ryu + 等 Mininet prompt（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh up ovs
```

✅ 你應該看到：

```
Bringing up the ovs stack
  topology: /home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json

[1/3] control plane (Ryu)
  started ryu (pid ...) -> .../.test_run/logs/ryu.log
  waiting for Ryu REST on :8080 ................ up
[2/3] data plane (Mininet, needs sudo)
  Mininet is interactive (it drops into a CLI) and needs root.
  Start it in a separate terminal:

      sudo python3 /home/adam/Desktop/NDTwin-Kernel/testbed_topo.py

  Press Enter once Mininet is up (or Ctrl-C to abort)...
```

⚠️ **先不要按 Enter。** Ryu 必須在 Mininet 之前監聽，因為 OVS switch 會主動撥給 controller。順序錯了的話，Mininet 啟動時探測 Ryu port 會失敗（`mininet/node.py:1551`），port 回退成盲猜的 6653 —— 在 `stack.sh` 下剛好對，但照使用說明書的 `--ofp-tcp-listen-port 6633` 就永遠連不上。來源：`doc/full_test_runbook.md` §1a 陷阱。

⚠️ **Ryu 載入了哪些 app 至關重要。** `stack.sh:562-563` 的指令是：

```
ryu-manager --observe-links intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest
```

三個 stock app 各管一條命脈：

| app | 提供 | 少了它的症狀 |
|---|---|---|
| `--observe-links` | ryu.topology.switches（LLDP 事件） | 拓撲永遠空的，switch 不會出現 |
| `ryu.app.rest_topology` | `/v1.0/topology/{switches,hosts,links}` | 圖永遠 `up=0 enabled=0`。kernel 把 404 HTML 拿去 `json::parse`、接住例外後靜靜放棄（`TopologyAndFlowMonitor.cpp` 的 `updateSwitches()`） |
| `ryu.app.ofctl_rest` | `GET /stats/flow/<dpid>`、`POST /stats/flowentry/*` | 每次輪詢一筆 `JSON parsing failed ... last read: '<'`、flow table 查不到、**所有下規則都失敗** |

來源：`stack.sh:545-560` 的註解，以及 `doc/environment_gotchas.md`「Ryu 需要多載兩個 stock app」。

### 3b. 開 OVS Mininet（terminal B —— Adam）

```bash
sudo python3 /home/adam/Desktop/NDTwin-Kernel/testbed_topo.py
```

✅ 看到 `mininet>` 就成功。

⚠️ 啟動時它會自己跑一輪 128 台 host 平行 ping 當自我測試（`testbed_topo.py:229-243`），**那個階段的 `100% packet loss` 可以忽略**——是啟動洪泛造成的。等提示符出現再回 terminal A 按 Enter。

⚠️ `testbed_topo.py` 使用 `RemoteController` 但**沒有指定 port**（`testbed_topo.py:163`）。Mininet 會在自己啟動的那一刻探測 Ryu 在 6653 還是 6633。這是在 `stack.sh` 的設計之內，但如果手動跑 Ryu 時指定了不同的 port（例如 `--ofp-tcp-listen-port 9999`），Mininet 會連不上。

⚠️ **sFlow 組態在拓撲腳本裡自動完成**：`testbed_topo.py:201-204` 對每台 switch 跑 `ovs-vsctl` 設定 sFlow（`sampling=256 polling=0`，target 是 `192.168.123.1:6343`）。kernel 的 sFlow collector 綁在 UDP :6343（`FlowLinkUsageCollector.hpp:33`：`#define SFLOW_PORT 6343`）。polling=0 是故意的——kernel 在 MININET 模式下丟棄所有 counter sample，只從 flow sample 推導鏈路使用率（`FlowLinkUsageCollector.cpp:120-136` 的註解）。

### 3c. 回到 terminal A，按 Enter 之後自動收斂

按 Enter 後 `stack.sh` 會自動等收斂並啟動 kernel：

✅ 要看到：

```
  waiting for 10 switches, 32 links, and all-destination paths
  the Ryu app sleeps a hard-coded 60s before installing paths, so expect >60s
    switches=10 links=32 paths=pending
    switches=10 links=32 paths=installed
  converged after 6Xs
[3/3] kernel
  waiting for kernel API on :8000 . up

stack up. next: ./stack.sh wait
```

⚠️ **`paths=pending` 停留約 60 秒是正常的**——那是 `intelligent_router.py:422` 寫死的 `hub.sleep(60)`，也就是使用說明書要你等的那一分鐘。

那 60 秒是**從 10 台交換機全部連上 Ryu 之後**開始算的，不是從 Ryu 啟動算：`load_static_topology()` 只在 `len(self.switches) >= switch_num` 時才被呼叫（`intelligent_router.py:178`，位於 `_switches_changed_handler` 附近）。所以 `paths=installed` 這個訊號其實同時證明了**10 台都連上了**——它比單看 link 數量更強，而不只是「等了一分鐘」。

⚠️ **如果 `converged after` 只花了 2 秒，那是閘門又壞了**（只等到 link discovery，沒等到路徑安裝），不要往下做。來源：`stack.sh:195`（P4 收斂才是 2 秒）和 `doc/full_test_runbook.md` §1c。

⚠️ 看到 `all-destination paths were never installed` 代表 `install_all_pair_paths` 拋例外了，去 `.test_run/logs/ryu.log` 找 `Failed to load static topology file`。來源：`stack.sh:244-245`。

⚠️ **kernel log 裡一筆 `curl` 失敗（對 `:8081` 的連線拒絕）是預期的嗎？** 在 OVS 模式**不是**。OVS 模式下 `controlPlaneHostAndPort()` 永遠回 `localhost:8080`（`FlowLinkUsageCollector.cpp:211-218`），因為 switch kind 是 OVS 不是 BMV2。如果 OVS 模式下 log 出現對 `:8081` 的嘗試，代表 topology 檔案裡的 `brand_name` 欄位不是 `"OVS"`，kernel 誤判了 data plane 類型。來源：`TopologyAndFlowMonitor.cpp:87-100`（`configureTopologyApiUrls` 只對 all-bmv2 重指向）。

### 3d. 等 kernel 收斂

```bash
./stack.sh wait
```

✅ 應該在若干秒內輸出：

```
waiting for topology convergence (expect 10 switches up+enabled, timeout 90s)
  switches=10 up=10 enabled=10 edges=288
converged after Xs
```

⚠️ **edges=288** 是 OVS 模式的數字（128 hosts × 2 向 = 256 + 16 inter-switch links × 2 向 = 32 = 288）。來源：topology 檔案 `StaticNetworkTopologyMininet_10Switches.json` 的邊數（`grep -c src_dpid` 回 288）。如果看到 40 或更少的邊數，kernel 可能在讀 P4 的 topology——檢查 `stack.sh up` 的參數是不是 `p4` 而非 `ovs`。

⚠️ **OVS 模式的 `is_up` 由 `pingWorker` 每秒更新**：kernel 跑 `sudo ovs-vsctl list-br`，比對每個 switch 的 bridge name 是否出現在清單中（`DeviceConfigurationAndPowerManager.cpp:349-358`，`ovsLivenessFor`）。出現 = Up，不在 = Down，查詢失敗 = Unknown（保持原狀）。**這和 P4 模式完全不同**——P4 模式查 proxy 的 `/p4/switch_state`，OVS 模式 shell 出去跑 `ovs-vsctl`。

⚠️ **NOPASSWD 必須正確設定**，否則 `sudo ovs-vsctl list-br` 會在 detached process（`setsid`）下卡住問密碼 → 回傳空 → 整張圖的 switch `is_up` 全變 false。症狀：`up=0` 但 `enabled=10`。log 裡有幾千行 `sudo: a password is required`。來源：`doc/environment_gotchas.md`§1。

---

## 4. 靜態健康檢查（idle，無流量）

以下全部在 terminal A 跑 `curl`。kernel 聽在 `localhost:8000`，Ryu 聽在 `localhost:8080`。

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
hosts 128 up TO BE MEASURED
edges 288 up TO BE MEASURED
```

⚠️ **hosts `up` 的數字不是 128。** OVS 模式下 host 的 `is_up` 由 kernel 的 topology poll 週期性從 Ryu 學習。Ryu 的 host 學習依賴封包 in（host 發封包 → controller 看到 → 學到 MAC/IP），但 `testbed_topo.py` 設的是 static ARP（`testbed_topo.py:219-226`），Ryu 不一定學得到所有 host IP。這是已知限制，來源：`doc/full_test_runbook.md` §1e 的「static ARP → Ryu 學不到 host IP」。**TO BE MEASURED**——記錄實際數字。

⚠️ **edges `up` 的數字不是 288。** host 邊的 `is_up` 也取決於 host 是否被學到。**TO BE MEASURED**。核心交換機間的 32 條邊應該全部 `is_up=true`，前提是 `ovs-vsctl list-br` 正常。

⚠️ 這個檢查可以因為「kernel graph 沒更新」而通過——`wait` 只看 switches up+enabled，不看 hosts 和 edges 的 liveness。如果 hosts 全部顯示 down（`up=0`），但 switches 都是 `10/10/10`，那代表拓撲 poll 正常但 host 學習沒發生——這是預期內的不完美，不是回歸。

### 4b. 節點 key 檢查

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
keys = sorted(d['nodes'][0].keys())
print('node keys:', keys)
print('count:', len(keys))"
```

✅ 預期 12 個 key（照字母排），**和 P4 模式完全相同**：

```
admin_disabled, brand_name, device_layer, device_name, dpid, ecmp_groups, ip, is_enabled, is_up, mac, nickname, vertex_type
```

來源：`include/common_types/GraphTypes.hpp:215` 定義 `VertexProperties` 欄位，以及 `doc/p4_manual_test_runbook.md` §4b 的實測結果。兩種模式共用同一份 graph schema。

### 4c. 電力報告

```bash
curl -s localhost:8000/ndt/get_power_report | python3 -m json.tool
```

✅ 預期：一個 JSON array，10 個元素，每個有 `dpid` 和 `power_consumed`（mW）。值落在 33466–147622 mW 之間（來源：`doc/full_test_runbook.md` 2026-07-30 實測值），各台不同，隔 10 秒再查數字不變（這是合成電力，不是真實量測，所以跨輪詢穩定）。

⚠️ `get_power_report` 回傳的是 bare JSON array（`[{...}, ...]`），不是 `{"status": ..., "data": ...}` 包裝。

⚠️ 如果 `up=0`，power report 可能是空的——`is_up` 是 power/CPU/溫度 的前置條件（`doc/full_test_runbook.md` §「這一輪之後要做什麼」）。

### 4d. 平均鏈路使用率

```bash
curl -s localhost:8000/ndt/get_average_link_usage
```

✅ 預期：`{"avg_link_usage":0.0,"status":"success"}`（idle 狀態為 0.0）。

⚠️ 這個端點是 GET，不加 query param，不加 body。

⚠️ OVS 模式下的 `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2429`）**刻意排除所有接到 host 的邊**（判斷式在 `:2455-2456`）。所以即使 host 間有背景流量（例如 Mininet 啟動時的 ping 測試殘留），只要流量只在 host-switch 邊上，`avg_link_usage` 仍然是 0.0。不是 bug。來源：`doc/full_test_runbook.md` §1d。

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

✅ 預期：10 台 switch，每台 **約 130 條** flow entry（來源：`doc/full_test_runbook.md` §1e 的實測值）。**這和 P4 模式的 4 條完全不同**——OVS 的 `intelligent_router.py` 會安裝 all-destination paths 對應的 OpenFlow 規則，所以 flow table 是滿的。P4 模式只有 4 條預設規則。

⚠️ 這個端點是 GET，**不加 `?dpid=`**。加了會 404（因為 dispatch 用 `target == "/ndt/get_switch_openflow_table_entries"` 精確匹配，不是 `starts_with`）。來源：`HttpSession.cpp:165`。

⚠️ `get_switch_openflow_table_entries` 回的是 kernel 的快取（`DeviceConfigurationAndPowerManager.cpp:1842-1845`），由 `openflowTablesUpdateWorker` 每 10 秒更新一次（`:1801-1802`）。所以開機後最多 10 秒才會出現。如果剛開機第一秒查，可能回空。

### 4f. 已偵測 flow

```bash
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('flows:', len(d))"
```

✅ 預期：`flows: 0`（idle 狀態）。

⚠️ 回傳的是 bare JSON array（`[{...}, ...]`），不是 `{"flows": [...]}`。所以 `len()` 直接對解析結果取即可。

### 4g. ⚠️ 沒有 `/p4/switch_state` 等價端點

P4 模式可以用 `curl localhost:8081/p4/switch_state` 查每台 switch 的 probe/stream/lldp/packet-in 年齡。OVS 模式**沒有這個端點**——Ryu 的 REST API 在 `:8080`，但沒有等價的逐 switch liveness 端點。替代方案：

```bash
# Ryu 的 switch 連線狀態
curl -s localhost:8080/v1.0/topology/switches | python3 -m json.tool
```

✅ 預期：10 個 dpid 的 array。

```bash
# Ryu 的 link 狀態
curl -s localhost:8080/v1.0/topology/links | python3 -m json.tool | head -20
```

✅ 預期：32 條 inter-switch link（每條含 src/dst dpid 和 port）。

### 4h. Ryu 端路徑數

```bash
curl -s localhost:8080/ryu_server/all_destination_paths | python3 -c "
import json,sys; d=json.load(sys.stdin)
paths=d.get('all_destination_paths',[])
print('paths:', len(paths))
for p in paths[:5]:
    print('  ', len(p), 'hops:', p[0][0], '->', p[-1][0])"
```

✅ 預期：**128 × 127 = 16256 條路徑**（128 台 host，每對雙向各一條）。來源：`intelligent_router.py` 的 `install_all_pair_paths` 為所有 host pair 計算最短路徑。**這和 P4 模式的 12 條完全不同**——P4 topology 只有 4 台 host。

⚠️ 這個端點在 OVS 模式下由 Ryu 直接提供（`intelligent_router.py` 跑在 Ryu process 裡），**不是** proxy。port 是 `:8080`，不是 P4 的 `:8081`。

### 4i. Ryu log 關鍵訊息

```bash
grep -E "Static topology initialized|all-destination paths installed" .test_run/logs/ryu.log
```

✅ 預期：至少一筆 `Static topology initialized, all-destination paths installed.`（來源：`intelligent_router.py:435`）。

```bash
grep -E "Failed to load static topology|Traceback" .test_run/logs/ryu.log
```

✅ 預期：**0 行**。

### 4j. Kernel log 關鍵訊息

```bash
grep "topology from the control plane" .test_run/logs/kernel.log | tail -3
```

✅ 預期看到類似（TO BE MEASURED——確切數字取決於 Ryu 學到多少 host）：

```
topology from the control plane: 10 switches, N hosts, M edges up
```

來源：`TopologyAndFlowMonitor.cpp:1784-1788`。這行只在數字變化時印出（`:1781`）。

⚠️ kernel 的 topology poll 間隔是**前 90 秒每 5 秒，之後每 30 秒**（`TopologyAndFlowMonitor.cpp:1758-1760`，`kWhileConverging=5s`、`kOnceConverged=30s`、`kConvergingFor=90s`）。所以開機後第一條確認 log 可能在 5–30 秒後才出現，不是 1 秒。

---

## 5. Telemetry（灌流量，邊跑邊查）

### 5a. 灌流量（terminal B —— Adam）

⚠️ **h1 和 h97 在不同交換機上**（h1 在 s1，h97 在 s4，見 `testbed_topo.py:69-90` 的 host 分配），這很重要。同一台交換機底下的 host 互打，`get_average_link_usage` 永遠是 0.0——因為 `getAvgLinkUsage` 刻意排除所有接到 host 的邊。來源：`doc/full_test_runbook.md` §1d。

| 交換機 | host IP |
|---|---|
| s1 | 10.0.0.1 – 10.0.0.32 |
| s2 | 10.0.0.33 – 10.0.0.64 |
| s3 | 10.0.0.65 – 10.0.0.96 |
| s4 | 10.0.0.97 – 10.0.0.128 |

你自己在 CLI 裡打：

```
mininet> h97 iperf -s -u -p 5001 &
mininet> h1 iperf -c 10.0.0.97 -u -p 5001 -b 10M -t 600 &
```

或者用 `mnexec` 代跑（`mnexec` 在 NOPASSWD 清單）：

```bash
H1=$(pgrep -f "[m]ininet:h1")
H97=$(pgrep -f "[m]ininet:h97")
sudo -n mnexec -a "$H97" iperf -s -u -p 5001 &
sudo -n mnexec -a "$H1"  iperf -c 10.0.0.97 -u -p 5001 -b 10M -t 600 &
```

收掉：`for p in $(pgrep -x iperf); do sudo -n mnexec -a "$H1" kill "$p"; done`（`sudo kill` 不在 NOPASSWD 清單裡，所以要繞過 `mnexec` 以 root 身分殺。）

⚠️ **頻寬用 `-b 10M`，不要 100M。** 實測 100M 會把 LLDP 餓死，Ryu 會誤判 link 掛掉（曾經一次跑出 19 次 link deleted），連 `ping` 都測不了。來源：`doc/full_test_runbook.md` §1d。

⚠️ **流量必須在以下檢查執行的「同時」還在跑**，不能先跑完再測：flow 會老化，停幾秒 `get_detected_flow_data` 就變 0 筆。來源：`doc/full_test_runbook.md` §1d。

⚠️ **OVS 的 sFlow 是 1/256 取樣**（`testbed_topo.py:136`：`sampling=256`）。所以需要一定流量才能穩定產生 sample。iperf 10M 足夠；ping 不夠（1 pps × 256 = 256 秒才一個 sample）。

⚠️ **sFlow 在 OVS 模式下來自 OVS 本身**，不是 proxy 合成的。每台 switch 透過 `ovs-vsctl` 設定將 sFlow datagram 送到 `192.168.123.1:6343`（kernel collector）。這和 P4 模式不同——P4 模式由 `p4_proxy/proxy_agent/sflow_emitter.py` 從 bmv2 packet-in 合成 sFlow。來源：`testbed_topo.py:105-137`（`enable_sflow`）和 `p4_proxy/proxy_agent/sflow_emitter.py`。

### 5b. 確認流量有被觀測到（terminal A）

```bash
# kernel log 的 sFlow ingest 健康線（只會有一行 INFO，其餘是 TRACE）
grep "sFlow ingest healthy" .test_run/logs/kernel.log
```

✅ 預期：至少一行，`rx=` 和 `addressed=` 都有值。`rx` 是收到的 datagram 總數（含 counter sample），`addressed` 是成功歸戶的 flow sample 數。有 traffic 時 `addressed` 應該 > 0。

⚠️ 這行在 `FlowLinkUsageCollector.cpp:1837-1850`：第一輪收到東西後是 INFO，之後全部是 TRACE。所以 `grep` 只會找到一筆。不要用它判斷「流量夠不夠」——用下面的 `get_detected_flow_data` 判斷。

⚠️ OVS 模式下 `polling=0`（無 counter sample），所以 `rx` 全部來自 flow sample。這是正常的。

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
    path_nodes = [hop['node'] for hop in f.get('path',[])]
    print('    path:', path_nodes)"
```

✅ 預期（iperf h1 → h97，10M UDP）：

```
flows: 2
   10.0.0.1 -> 10.0.0.97 proto 17 rate_bps TO BE MEASURED path_len TO BE MEASURED
   10.0.0.97 -> 10.0.0.1 proto 17 rate_bps TO BE MEASURED path_len TO BE MEASURED
```

- 雙向 UDP（proto 17）。
- 路徑經過 5 台交換機（h1→s1→...→s4→h97），含起點和終點 host IP 共 7 個節點。**確切路徑 TO BE MEASURED**——不同 run 可能走不同路（s1 有兩條出去：s1→s5 和 s1→s6）。
- rate 約 10 Mbps（發送端），但受 1/256 取樣影響會有波動。

⚠️ flow 會在流量停止後幾秒內老化歸零。所以查詢必須在 iperf 還在跑的時候做。

### 5d. 平均鏈路使用率（趁流量還在跑，連查三次）

```bash
for i in 1 2 3; do
  curl -s localhost:8000/ndt/get_average_link_usage
  sleep 2
done
```

✅ 預期：**非零，大約在 0.001–0.01 量級（TO BE MEASURED）。** 來源：`doc/full_test_runbook.md` §1e 的 2026-07-30 實測值 `0.0074514`（h1→h97，10M UDP）。

⚠️ **這個值是瞬時的、上下跳動的，不是單調爬升。** 原因見 P4 runbook §5d 的詳細分析。簡單說：`getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2429`）只把 `linkBandwidthUsage != 0` 的邊算進去，除以那一刻非零邊的數量。1/256 取樣下分子分母同時在變。

⚠️ 如果一直是 `0.0`，確認流量兩端在不同交換機上（h1 在 s1，h97 在 s4）。

### 5e. iperf 自身統計

在 Mininet CLI 看 iperf 的輸出，或在 terminal A 用 `pgrep -x iperf` 確認還在跑。

✅ 預期：server 端報告 stable throughput ~10 Mbps，loss ~0%。

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

✅ 預期：仍為每台約 130 條。**OVS 模式 flow table 不會因 traffic 顯著變動**（除非 `intelligent_router.py` 收到 link event 觸發重安裝）。這和 P4 模式不同——P4 模式永遠每台 4 條。

### 5g. Flow 通過的交換機（路徑上的交換機才有 flow）

```bash
# 先看這次走哪裡
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys
for f in json.load(sys.stdin):
    print([h['node'] if isinstance(h,dict) else h for h in f.get('path',[])])"

# 再查路徑上的 dpid（把下面的清單換成上面印出來的）
for d in 1 6 10 8 4; do
  printf "dpid %-2s " $d
  curl -s -X POST localhost:8000/ndt/get_num_of_flows_passing_a_switch \
    -H 'Content-Type: application/json' -d "{\"dpid\":$d}"
  echo
done
```

✅ 預期：回傳的是物件不是裸數字，`{"num_of_flows":N,"status":"success"}`。

⚠️ **這個端點數的是「進來」的 flow，不是「經過」的 flow。** 實作是 `if (e.dstDpid == dpid) numOfFlows += e.flowSet.size()`（`HttpSession.cpp:1734-1739`），也就是**以該 switch 為終點的邊**上的 flow 數。所以某個方向的起點 switch，那個方向不會被算到。雙向流量都經過的中繼 switch 會是 2。來源：P4 runbook §5g。

⚠️ **這個端點是 POST**，body 是 `{"dpid": N}`。不是 GET，不加 query param。

⚠️ 路徑上的交換機清單不是固定的——同一組 host、同一個拓撲，不同次跑可能走不同的路（s1 有兩條等價路徑：經 s5 或經 s6）。

### 5h. 為什麼「有 flow 卻 usage=0」不是 bug

和 P4 模式相同的現象，相同的原因：一條邊上有兩個獨立的東西，來源相同但壽命不同。

| 欄位 | 誰寫的 | 何時消失 |
|---|---|---|
| `flow_set` | sFlow 樣本落到這條邊時 `touchEdgeFlow` 加入（`FlowLinkUsageCollector.cpp` 約 `:1544`） | 由 flush loop 依 TTL 老化 |
| `link_bandwidth_usage_bps` | 每次樣本更新時重算 | 沒有新樣本就掉回 0 |

所以「這條邊列得出 flow，但 usage 是 0」是正常狀態——flow 的成員資格活得比速率久。

---

## 6. Link failure → 維持 down → 恢復

### ⚠️ 重大陷阱：`ifconfig <iface> down` 在 OVS 和 bmv2 上的行為不同

在 bmv2 上用 `ifconfig <iface> down` 模擬斷線，會癱瘓整台 switch 的 packet-in 路徑（見 P4 runbook §6）。**在 OVS kernel datapath 上，這個 side effect 不存在**——OVS 的 packet-in 走的是 kernel datapath，不是 P4Runtime gRPC stream。把一條 veth 介面 down 掉只會斷那一條鏈路。

但是 OVS 模式有自己的陷阱：**Mininet CLI 的 `link s1 s5 down` 底層也是對兩端做 `ifconfig down`**，所以效果相同。而且 OVS 的 LLDP 是 controller 發的（Ryu 透過 OpenFlow 下發 `packet_out`），不是 switch 自己發的，所以斷線的偵測路徑和 P4 完全不同。

來源：`doc/environment_gotchas.md` 的 bmv2 陷阱一節，以及 P4 runbook §6 的詳細分析。OVS 模式的斷線測試尚未實測過（TO BE MEASURED）。

### 6a. 斷線（terminal A —— Adam 可代跑，`ifconfig` 在 NOPASSWD 清單裡）

我們斷 **s1-eth1**（即 s1:1 ↔ s5:1 這條鏈路）：

```bash
sudo -n ifconfig s1-eth1 down
```

### 6b. 觀察偵測（terminal A）

```bash
# 看 Ryu log 的 link down 事件
grep -E "link deleted|EventLinkDelete" .test_run/logs/ryu.log | tail -10
```

✅ 預期：出現 link deleted 事件（TO BE MEASURED：延遲秒數和確切 log 格式）。

```bash
# 看 kernel log 的 link_failure_detected POST
grep "link failed" .test_run/logs/kernel.log | tail -5
```

✅ 預期：**TO BE MEASURED**。OVS 模式下的 link failure 偵測路徑是：
1. `ifconfig down` → veth pair 一端消失
2. Ryu 的 LLDP 在這條鏈路上收不到 → `EventLinkDelete` 觸發
3. Ryu 更新 `/v1.0/topology/links` → kernel 的 topology poll 看到變化
4. Ryu 的 `intelligent_router.py` 可選地推送 `link_failure_detected` POST 給 kernel

⚠️ OVS 模式和 P4 模式的 link failure 偵測是**完全不同的機制**。P4 模式依賴 proxy 的 watchdog（LLDP beacon timeout）；OVS 模式依賴 Ryu 的 `--observe-links` 事件。**kernel 的 `/ndt/link_failure_detected` 端點是否在 OVS 模式下被推送，需要確認**。來源：`intelligent_router.py` 的 `_link_changed_handler` 附近（需要 code 確認推送邏輯）。

### 6c. 確認圖已更新（斷線後約 15–30 秒，TO BE MEASURED）

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

✅ 預期：**edges up 從 TO BE MEASURED 降到 TO BE MEASURED**（少兩條：s1:1→s5:1 和 s5:1→s1:1）。switches 仍為 10/10/10。

⚠️ OVS 模式下斷線的 edge 更新取決於 kernel 的 topology poll。poll 間隔是前 90 秒每 5 秒、之後每 30 秒。所以圖更新延遲可能比 P4 模式長。**TO BE MEASURED**：實際延遲秒數。

### 6d. 穩定性：維持 down 約 2 分鐘，確認沒有 flapping

```bash
for i in $(seq 1 40); do
  up=$(curl -s localhost:8000/ndt/get_graph_data | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for e in d['edges'] if e['is_up']))")
  echo "$(date +%H:%M:%S) edges up: $up"
  sleep 3
done
```

✅ 預期：119 秒內 40 次查詢，全部回相同的 edge up 數字，沒有 flapping。

### 6e. Kernel 自身的 poll 也確認

```bash
grep "topology from the control plane" .test_run/logs/kernel.log | tail -3
```

✅ 預期看到 edge up 數字下降（TO BE MEASURED）。

### 6f. 路徑數的變化

```bash
curl -s localhost:8080/ryu_server/all_destination_paths | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('paths:', len(d.get('all_destination_paths',[])))"
```

✅ 預期：**TO BE MEASURED**。路徑數是否從 16256 下降取決於斷掉的鏈路是否在某條最短路徑的 critical path 上。OVS 模式下 `intelligent_router.py` 收到 link event 後會重算路徑（`_link_changed_handler`），所以路徑應該會更新。

### 6g. 恢復

```bash
sudo -n ifconfig s1-eth1 up
```

等待若干秒後（TO BE MEASURED）：

```bash
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
ed=d.get('edges',[])
print('edges up:', sum(1 for e in ed if e['is_up']), '/', len(ed))"
```

✅ 預期：edges up 回到原始值。

```bash
curl -s localhost:8080/ryu_server/all_destination_paths | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('paths:', len(d.get('all_destination_paths',[])))"
```

✅ 預期：路徑數回到 16256。

### 6h. ⚠️ 這一節驗證的是偵測，不是繞路

P4 模式目前**不會繞路**（見 P4 runbook §6h 的 🔴 實測結果）。OVS 模式下的繞路行為**尚未驗證過**——`intelligent_router.py` 的 `_link_changed_handler` 是否真的觸發 `install_all_pair_paths` 重裝規則，**TO BE MEASURED**。

---

## 7. admin_disabled

### 背景

`admin_disabled` 是 `VertexProperties` 和 `EdgeProperties` 上的第三個 flag（和 `isUp`、`isEnabled` 並列），定義在 `include/common_types/GraphTypes.hpp:215`。

kernel 以 `--no-ai` 啟動（`stack.sh:606`），因此 `IntentTranslator` 是 `nullptr`（`main.cpp:346-362`），而 `disableSwitchAndEdges`（唯一設定 `adminDisabled = true` 的路徑）**只被 Intent Translator 呼叫**。所以 `adminDisabled` 永遠是初始值 `false`。來源：P4 runbook §7。

**本節和 P4 模式的 §7 完全相同**，因為 admin_disabled 是 kernel 層的功能，與 data plane 無關。

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

⚠️ 這個檢查**今天只是回歸陷阱**。Phase 7 引入 power management 後才真正有意義。

---

## 8. 判定總表

### 綠燈代表什麼

| 項目 | 綠燈條件 | 綠燈代表 |
|---|---|---|
| 起點乾淨 | 八個查詢全部無輸出（`list-br` 除外） | 沒有殘留 process 汙染下一個 `up` |
| Unit tests | C++ 426 pass, Python 312+101 pass, 無 skip 異常 | 離線邏輯正確 |
| `stack.sh up ovs` | Ryu `:8080 up`，然後 `paths=installed converged after 6Xs` + kernel `:8000 up` | Ryu 成功載入、10 台 switch 連上、路徑安裝完成、kernel 啟動 |
| `stack.sh wait` | `switches=10 up=10 enabled=10 edges=288` | kernel 的圖和 topology 檔案一致，liveness 檢查正常 |
| Idle graph | 10/10 switch up+enabled, edges 288（部分可能 down） | 所有 switch 被拓撲發現並啟用 |
| Node keys | 12 個 key，含 `admin_disabled` | schema 正確，和 P4 模式一致 |
| Power report | 10 筆，33466–147622 mW，跨輪詢不變 | 合成電力值正常產生 |
| `avg_link_usage` idle | `0.0` | 沒有 phantom 流量 |
| Flow tables | 10 台各約 130 條 | OVS flow rules 已安裝（intelligent_router.py 的 all-destination paths） |
| Detected flows idle | `0` | 沒有 stale flow |
| Ryu topology | 10 switches, 32 links | Ryu LLDP 發現完成 |
| Ryu paths | 16256 | 所有 host pair 都有路徑 |
| Ryu log | `Static topology initialized` 出現，0 筆 `Failed` 或 `Traceback` | intelligent_router.py 正常載入 |
| Traffic: detected flows | 2 筆（雙向 UDP），rate ~10M bps | OVS sFlow → kernel 的 ingest 鏈路完整 |
| Traffic: `avg_link_usage` | 非零，約 0.001–0.01 | 鏈路使用率有在追蹤流量 |
| Traffic: iperf | ~10 Mbps, ~0% loss | 資料平面正常轉送 |
| Link failure detect | Ryu log 出現 link deleted，kernel graph edge up 下降 | link failure 偵測鏈路完整 |
| Link failure graph | edges up 下降 2，穩定不 flapping | 失效值正確、沒有振盪 |
| Recovery | edges up 恢復，路徑數恢復 | 偵測是可逆的 |
| `admin_disabled` | 全部 false，不變量空洞成立 | schema 正確，回歸陷阱就位 |

### 哪些綠燈不代表什麼

| 綠燈 | 不代表 |
|---|---|
| `switches up=10` | `sudo ovs-vsctl list-br` 只確認 bridge 存在，**不確認 OpenFlow 連線是否正常**。bridge 在但 controller 連不上時仍然 `up=10` |
| `edges up` 高 | host edge 的 `is_up` 取決於 Ryu 是否學到 host IP，static ARP 下可能學不到——不要當成 host 真的可達 |
| Flow table 130 條 | 那是 kernel 的快取（每 10 秒更新一次），可能不是最新的 |
| `avg_link_usage` 非零 | 它是瞬時值，且分母是「當下有樣本的邊數」。單次讀數不代表整體負載，連續讀數上下跳是正常的 |
| Ryu topology 32 links | Ryu 回報的是 inter-switch link，不含 host 邊——不能用來判斷 host 連通性 |

---

## 9. 出問題時先看哪裡

| 症狀 | 先看 | 別誤判成 |
|---|---|---|
| `stack.sh up ovs` 停在 `waiting for Ryu REST` | `.test_run/logs/ryu.log` 找 `ImportError` 或 `ModuleNotFoundError` | 不是 port 被佔——是 Ryu 沒裝好或 `intelligent_router.py` import 失敗 |
| `stack.sh up ovs` 收斂時 `paths` 永遠 `pending` | `.test_run/logs/ryu.log` 找 `Failed to load static topology file` | 不是 LLDP 沒跑完——是 topology 檔案讀不到 |
| `converged after 2s`（OVS 模式） | `stack.sh` 的 `paths_installed()` 是不是又只等 link discovery | 不要當成「收斂很快」——是閘門壞了 |
| `up=0` 但 `enabled=10` | `sudo -n ovs-vsctl list-br` 能不能跑。log 找 `sudo: a password is required` | 不是 kernel bug——是 NOPASSWD 沒設 |
| `avg_link_usage` = 0 但有流量 | 流量兩端是不是在同一台交換機 | 不是 bug（設計上排除 host 邊） |
| `num_of_flows` = 0 | 流量還在跑嗎；那台交換機在路徑上嗎 | 它不是 OpenFlow 規則數 |
| `{"error":"Not Found"}` | 端點是 GET 還是 POST；是不是多加了 `?dpid=` | 不是功能沒實作 |
| `get_detected_flow_data` 回 0 筆 | iperf 還在跑嗎（flow 幾秒內老化） | 不是 ingest 壞掉——是流量停了 |
| 全部節點紅色 | `.test_run/logs/kernel.log` 找 `ovs-vsctl list-br failed` 或 `sudo: a password is required` | 不要以為整個 stack 壞了——是 liveness query 失敗 |
| Ryu 突然沒 log | `pgrep -f "[r]yu-manager"` | **2026-07-30 曾經無聲死亡一次，死因至今未確定**（沒 traceback、沒 OOM 紀錄）。再發生請把 `ryu.log` 完整留下。來源：`doc/full_test_runbook.md` |

### Log 位置

| 程式 | Log |
|---|---|
| kernel | `.test_run/logs/kernel.log` |
| Ryu | `.test_run/logs/ryu.log` |
| OVS switch（每台） | Mininet 的 console output 或 `ovs-vsctl` 查詢 |

### 有用的快速指令

```bash
# 誰在聽哪些 port
ss -ltnp '( sport = 8000 or sport = 8080 or sport = 8081 or sport = 6633 )'

# Ryu 活著嗎
pgrep -f "[r]yu-manager" && echo alive || echo dead

# kernel 活著嗎
pgrep -x ndtwin_kernel && echo alive || echo dead

# OVS bridges 存在嗎
sudo -n ovs-vsctl list-br

# 快速看圖的 switch 狀態
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
sw=[n for n in d['nodes'] if n.get('vertex_type')==0]
for s in sw: print(f\"dpid {s['dpid']}: up={s['is_up']} enabled={s['is_enabled']} name={s.get('device_name','?')}\")"
```

---

## 10. TO BE MEASURED 彙總

以下所有標記 TO BE MEASURED 的項目，請 Adam 在第一次實跑 OVS stack 時填入實際數字。

| 節 | 項目 | 預期（來自 source/doc） | 實測值 |
|---|---|---|---|
| §4a | hosts `up`（idle） | ≤128（Ryu host 學習不完全） | |
| §4a | edges `up`（idle） | ≤288（取決於 host 學習） | |
| §4j | kernel log「topology from the control plane」的 hosts/edges 數 | — | |
| §5c | 已偵測 flow 的 `rate_bps`（h1→h97，10M UDP） | ~10M bps | |
| §5c | 已偵測 flow 的 `path_len` | ~7（含起終點 host） | |
| §5c | 已偵測 flow 的實際路徑（dpid 序列） | h1 → s1 → ... → s4 → h97 | |
| §5d | `avg_link_usage`（有 traffic 時，連查三次） | 非零，約 0.001–0.01 | |
| §6b | 斷線後 Ryu log 出現 link deleted 的延遲 | — | |
| §6b | 斷線後 kernel log 出現 `link failed` 的延遲和筆數 | — | |
| §6c | 斷線後 edges up 的變化（從多少降到多少） | 少 2（雙向 s1↔s5） | |
| §6c | 斷線後圖更新的實際延遲秒數 | 5–30 秒（kernel poll 間隔） | |
| §6f | 斷線後路徑數的變化（從 16256 降到多少） | — | |
| §6g | 恢復後 edges up 回到原始值的延遲 | — | |
| §6h | OVS 模式是否真的會繞路（流量是否繼續通） | 🔴 未知，**優先驗證** | |

---

## 收尾

```bash
# terminal A
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh down
sudo mn -c

# terminal B
mininet> exit

# 確認真的乾淨
pgrep -x ndtwin_kernel; pgrep -x iperf; pgrep -f "[r]yu-manager"
sudo ovs-vsctl list-br
ss -ltn '( sport = 8000 or sport = 8080 or sport = 8081 or sport = 6633 )'
```

✅ 全部無輸出（`list-br` 除外——它應該沒有任何 bridge 名稱）。

---

## ⚠️ 特別警告：不要單獨重啟 Ryu

**[Co-developed with claude code -- Adam]**

「先 Ryu 再 Mininet」是**初次啟動**的規則。**在 Mininet 還在跑的時候重啟 Ryu，8 秒後 `/stats/flow/<dpid>` 開始永久回空表。** 來源：`doc/environment_gotchas.md`「不要單獨重啟 Ryu」。

後果：資料平面完全正常（每台 130 條規則、`is_connected: true`），但 kernel 讀到的 flow table 全是空的 → Classifier → **每條 flow 的 `path` 都是空的**，而網路其實好好地在轉封包。

kernel 現在有防禦：`classifyFlowStatsReply`（`DeviceConfigurationAndPowerManager.cpp:998-1021`）如果回覆空且耗時 ≥ `kFlowStatsSuspectSeconds`（0.5 秒），會認定為 Ryu timeout 並**保留上一份 flow table**。這個防禦讓 wedged 狀態不會立刻汙染 kernel，但**不能恢復正常**——因為永遠拿不到真實的 flow table。

> **完整規則：先 Ryu 再 Mininet；而且不要中途單獨重啟 Ryu——要重啟就兩個一起。**

也就是說**改完 `intelligent_router.py` 要重測，必須整組重開。**

### 防禦程式碼位置

1. `DeviceConfigurationAndPowerManager.cpp:998-1021`：`classifyFlowStatsReply` — 空表 + 耗時 ≥ 0.5s → `SuspectTimedOut` → 保留上一份表
2. `DeviceConfigurationAndPowerManager.cpp:1130-1143`：呼叫 `classifyFlowStatsReply`，若為 `SuspectTimedOut` 則 WARN 並跳過（不更新快取）

---

*本文件從原始碼產生。需要確認但未涵蓋的事項標記為 TO BE MEASURED。撰寫於 2026-08-11，針對 OVS/Ryu stack（Mininet mode）。*


---

## 附錄 A：OVS 和 P4 模式快速對照

這不是 runbook 的一部分，只是幫助你（和未來的讀者）在兩份文件之間快速定位。

| 面向 | OVS（本文件） | P4（`doc/p4_manual_test_runbook.md`） |
|---|---|---|
| 控制平面 | Ryu (`:8080` REST, `:6633` OpenFlow) | P4 proxy (`:8081`) |
| 資料平面 | OVS kernel datapath (Mininet) | bmv2 `simple_switch_grpc` (Mininet) |
| 啟動順序 | Ryu → Mininet → wait → kernel | Mininet → proxy → wait → kernel |
| 收斂時間 | ~60s+（`hub.sleep(60)`） | ~2s |
| 交換機台數 | 10 | 10 |
| host 數 | 128 | 4 |
| 圖邊數 | 288 | 40 |
| flow table（idle） | 每台約 130 條 | 每台 4 條 |
| all-destination paths | 16256 | 12 |
| sFlow 來源 | OVS 內建 sFlow（`ovs-vsctl` 設定） | proxy 的 `sflow_emitter.py` 合成 |
| sFlow 取樣率 | 1/256（`sampling=256`） | 1/256（bmv2 clone session） |
| `is_up` 判定 | `sudo ovs-vsctl list-br` 比對 bridge name | proxy `/p4/switch_state` 的 probe_ok/stream_alive/lldp |
| liveness 檢查頻率 | 每秒（`pingWorker`） | 每秒（`pingWorker`） |
| topology poll 頻率 | 前 90s 每 5s，之後每 30s | 同 |
| flow table poll 頻率 | 每 10s（`openflowTablesUpdateWorker`） | 每 10s |
| 關鍵 port | :8000 (kernel), :8080 (Ryu REST), :6633 (Ryu OpenFlow), :6343 (sFlow UDP) | :8000 (kernel), :8081 (proxy), :50051-50060 (bmv2 gRPC), :6343 (sFlow UDP) |


---

## 附錄 B：撰寫時的驗證筆記

以下記錄撰寫本文件時**實際讀過的原始碼行號**，供後續維護者追溯。未列在這裡的主張來自既有文件（`doc/full_test_runbook.md`、`doc/p4_manual_test_runbook.md`、`doc/environment_gotchas.md`），並在文中已標明。

| 主張 | 來源檔案:行號 |
|---|---|
| OVS 啟動順序（Ryu → Mininet） | `stack.sh:530-538` |
| `up ovs` 的第一步印 `[1/3] control plane (Ryu)` | `stack.sh:541` |
| Ryu 載入的 app 清單和缺 app 症狀 | `stack.sh:545-560`（註解） |
| Ryu REST port 檢查（`:8080`） | `stack.sh:564` |
| Mininet prompt 等待 | `stack.sh:567-568` |
| `paths_installed()` 只對 OVS 模式生效 | `stack.sh:168-175` |
| `hub.sleep(60)` 硬編碼等待 | `intelligent_router.py:422` |
| `install_all_pair_paths` 和 log 訊息 | `intelligent_router.py:433-435` |
| `expected_counts` 對 OVS 只算 inter-switch links | `stack.sh:107-112` |
| kernel 啟動指令（`--no-ai`） | `stack.sh:606` |
| `wait_for_port` 的 socket owner 檢查 | `stack.sh:393-448` |
| `port_owner_verdict` 函式 | `stack.sh:353-378` |
| OVS 模式的 `is_up` 判定（`ovsLivenessFor`） | `DeviceConfigurationAndPowerManager.cpp:349-358` |
| `pingWorker` 呼叫 `ovs-vsctl list-br` | `DeviceConfigurationAndPowerManager.cpp:630-664` |
| `pingWorker` 的呼叫和 sleep 間隔 | `DeviceConfigurationAndPowerManager.cpp:616, 620` |
| topology poll 間隔（5s/30s/90s） | `TopologyAndFlowMonitor.cpp:1758-1760` |
| topology poll log（變化時才印） | `TopologyAndFlowMonitor.cpp:1781-1788` |
| sFlow port 定義 | `FlowLinkUsageCollector.hpp:33` (`#define SFLOW_PORT 6343`) |
| sFlow ingest healthy log（INFO→TRACE） | `FlowLinkUsageCollector.cpp:1837-1850` |
| OVS polling=0 的設計理由 | `FlowLinkUsageCollector.cpp:120-136`（註解） |
| `controlPlaneHostAndPort` — OVS 模式永遠回 Ryu | `FlowLinkUsageCollector.cpp:211-218` |
| `configureTopologyApiUrls` — 只對 all-bmv2 重指向 | `TopologyAndFlowMonitor.cpp:87-100` |
| flow table cache 更新頻率（每 10s） | `DeviceConfigurationAndPowerManager.cpp:1801-1802` |
| `fetchOpenFlowTablesInternal` — curl 到 Ryu `/stats/flow/<dpid>` | `DeviceConfigurationAndPowerManager.cpp:1025-1047` |
| `classifyFlowStatsReply` — 空表+耗時≥0.5s 的防禦 | `DeviceConfigurationAndPowerManager.cpp:998-1021` |
| `kFlowStatsSuspectSeconds = 0.5` | `DeviceConfigurationAndPowerManager.hpp:291` |
| sFlow 設定（OVS `ovs-vsctl`） | `testbed_topo.py:105-137` (`enable_sflow`) |
| Mininet 用 `RemoteController` 未指定 port | `testbed_topo.py:160-163` |
| Host 分配（h1-h32→s1, ..., h97-h128→s4） | `testbed_topo.py:69-90` |
| static ARP 設定 | `testbed_topo.py:219-226` |
| admin_disabled 定義和序列化 | `include/common_types/GraphTypes.hpp:215`、`HttpSession.cpp:530` |
| `--no-ai` 使 IntentTranslator 為 nullptr | `main.cpp:346-362` |
| OVS topology 邊數統計 | `run_command: grep -c src_dpid` → 288 |
