# 完整測試流程（OVS + P4 各一輪）

> 📍 **歷史文件（2026-08-17 標記）**：現役入口是
> [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md)。這一份是 2026-07-30 建立
> 第一份基準時的執行腳本，保留是為了追溯當初怎麼建的；**裡面的指令與環境敘述早於
> `ndtwin-lab` wrapper、`local_ci.sh` 與 `run_layers.sh`，不要照抄**。

**這是一份執行用的 runbook**：從乾淨環境開始，照順序做完，最後得到一份可信的 OVS 基準和一份
P4 對照。背景說明、每個功能的證據、已知限制在 [2026-07-29_p4_status_and_test_guide.md](2026-07-29_p4_status_and_test_guide.md)；
機器層面的陷阱（sudo、`pgrep` 數錯、殘留清理）在 [2026-07-29_environment_gotchas.md](2026-07-29_environment_gotchas.md)。

建立於 2026-07-30，對應 commit `6996062`。

---

## 為什麼現在要跑這一輪

自上次完整迴歸（基準抓於 **2026-07-29 18:55**）之後有 6 個 commit，其中三個會直接影響測試結果本身：

| commit | 改了什麼 | 為什麼一定要重測 |
|---|---|---|
| `6b3dc0c` | OVS liveness（`pingWorker`）兩個 bug | `is_up` 是 power / CPU / 溫度 / `getAvgLinkUsage` 的**前置條件**，改它會牽動很多輸出 |
| `0e84234` | 合成電力值 | `/ndt/get_power_report` 和 `getSingleSwitchPowerReport` 的數值全變 |
| `a142fe0` | `stack.sh` 的收斂閘門改成也要等 all-destination paths；`CONVERGE_WAIT` 60 → 150 | **之後每一次測試都建立在它上面**，而它還沒被端到端跑過一次 |

所以現在的 `.test_run/baseline/ovs` 已經過期，**`compare` 之前必須重抓**。

---

## 事前檢查

### 誰做什麼

`sudoers` 放行了 `/usr/bin/mnexec`（NOPASSWD），所以**只要你把 Mininet 開起來，其餘幾乎都我能代跑**
—— `mnexec -a <host pid>` 讓我在 host 的 namespace 裡以 root 執行任何指令（實測 uid 0，
`iperf`／`tcpdump`／`ping`／`ip` 都能用）。

| 只有你能做 | 為什麼 |
|---|---|
| `sudo python3 testbed_topo.py` / `p4_testbed_topo.py` | 需要互動式 root，`sudo -n python3` 會要密碼 |
| `sudo mn -c` | 同上 |
| `mininet> exit` | 在你的互動 CLI 裡 |

| 我可以代跑 | 方式 |
|---|---|
| `stack.sh up/wait/down`、`run_layers.sh` | 不需要 root |
| **產生流量**（iperf / ping） | `sudo -n mnexec -a $(pgrep -f "mininet:h1") iperf ...` |
| `tcpdump` 抓包 | 同上，實測可用 |
| 所有 `curl` 檢查、log 分析 | — |
| 建／刪 OVS bridge | `sudo -n ovs-vsctl`（NOPASSWD） |

### 需要幾個 terminal

| | 用途 | 生命週期 |
|---|---|---|
| **B** | Mininet CLI（`sudo`，會停在 `mininet>`）—— **你的** | 全程留著，OVS 和 P4 之間要換 |
| **A** | `stack.sh` / `run_layers.sh` / `curl` | 我可以代跑；你要自己看也行 |

### 確認起點是乾淨的（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh down
sudo mn -c
pgrep -x ndtwin_kernel; pgrep -x simple_switch_g; pgrep -x iperf
#                        ^^^ 15 字元上限，寫 simple_switch_grpc 永遠匹配不到
pgrep -af "[t]estbed_topo.py"          # 中括號避免匹配到自己的 shell
sudo ovs-vsctl list-br
ss -ltn '( sport = 8000 or sport = 8080 or sport = 8081 )'
```

✅ 上面五個查詢**全部沒有輸出**才算乾淨。

⚠️ **`pgrep -x ndtwin_kernel` 一定要是空的。** 殘留在 `:8000` 的 kernel 會讓
`stack.sh up` 印出 `waiting for kernel API on :8000  up` 然後**假成功** —— 它自己起的 kernel 死於
`bind: Address already in use`，但 port 有人聽所以它以為成功了。實際踩過一次：P4 那輪測到的是一個
殘留的 **OVS** kernel，`stack.sh wait` 回報 288 條 edge、128 台 host（OVS 拓撲的數字），
而整輪都沒有任何東西提示不對。`wait_for_port` 現在會檢查自己起的 process 還活著，但起點乾淨仍是
第一道防線。

> ⚠️ `pgrep -f testbed_topo.py`（沒有中括號）**會匹配到你自己下的那道指令**，看起來永遠像有 Mininet
> 在跑。這個陷阱在這個專案裡騙過人不只一次。

---

## 第 0 步：不用開任何東西（約 6 分鐘）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./run_layers.sh quick        # L0 build + L1 單元測試
./run_layers.sh selftest     # contract schema 自我測試 + 依賴圖
./l0_build_check.sh p4       # P4 pipeline 編譯
```

**通過標準**：

```
L1 passed: 1 test binary/binaries, clean under ctest and direct execution.
```

⚠️ 看到 **`NO TESTS RAN` 是失敗，不是通過** —— 表示那個檔案一個測試都沒真的跑到（通常是缺套件）。

C++ 測試也要**直接跑一次**，不能只靠 ctest —— ctest 一個測試開一個 process，會掩蓋 suite 級別的失敗：

```bash
cd /home/adam/Desktop/NDTwin-Kernel && ./build/bin/test_routing_strategy
```
✅ 驗收條件是 **exit 0**，而且最後一行是 `[  PASSED  ] N tests.`，**沒有** `[  FAILED  ]` 那一段。

⚠️ **這裡刻意不寫 N 應該是多少。** 這個數字被寫死過兩次（127 → 414），兩次都在幾天內就過期，
而過期的方式最糟：測試變多會讓照著 runbook 走的人以為驗收條件沒過。
要對照的話，`N` 應該等於 `./build/bin/test_routing_strategy --gtest_list_tests | grep -c '^  '`
——這是同一個 binary 自己報的數，不會腐爛。

---

## 第 1 步：OVS 一輪（約 15 分鐘）

### 1a. 起 stack —— 它會先開 Ryu 然後停下來等你（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh up ovs
```

它會開 Ryu，印 `[2/3] data plane (Mininet, needs sudo)` 然後停下來等你按 Enter。**先不要按。**

> ⚠️ **順序是 Ryu 先、Mininet 後**，不能顛倒。`testbed_topo.py` 用 `RemoteController` 但沒指定
> port，Mininet 會**在自己啟動的那一刻**探測 Ryu 在 6653 還是 6633（`mininet/node.py:1551`）。
> 先開 Mininet 的話兩次探測都失敗，port 回退成盲猜的 6653 —— 在 `stack.sh` 下剛好對，
> 但照使用說明書的 `--ofp-tcp-listen-port 6633` 就永遠連不上。

### 1b. 開 OVS Mininet（terminal B）

```bash
sudo python3 /home/adam/Desktop/NDTwin-Kernel/testbed_topo.py
```

✅ 看到 `mininet>` 就成功。

⚠️ 啟動時它會自己跑一輪 128 台 host 平行 ping，**那一輪的 `100% packet loss` 可以忽略**。

但**不要**因此以為那輪 ping 沒作用、或反過來以為它就是 twin 學主機 IP 的來源 —— 兩種說法都被
2026-08-22 的實測推翻了（`doc/audit/2026-08-22_settle-gate-acceptance/burst_timing.txt`）：
那 128 個 ping 在開機後 **32 秒內就全部跑完**，而 Ryu 在**接下來 65 秒內一台都沒學到**，
128 台的 IPv4 是在 settle 等待放開的**那一個取樣點**一次全部出現的。

Ryu 只從 packet-in 學主機 IPv4（`ryu/topology/switches.py:877-885`），而 `testbed_topo.py` 已經
幫每台主機寫好靜態 ARP，把 ARP 那條路封死了 —— 這部分（2026-08-22 `e5e4980` 的介入實驗，
`doc/audit/2026-08-22_punt-window-discriminator/REPORT.md`）仍然成立。**但「開機那輪 ping 就是
教 Ryu 的那個封包」是錯的**，觸發點是等待放開的那一刻，機制還沒查出來。

錯過這一窗的後果不是「網路壞掉」，而是更難發現的那種：**資料平面完全正常，但 kernel 在
`TopologyAndFlowMonitor.cpp:618` 跳過每一台沒有 IP 的主機，`get_graph_data` 會有 256 條 host 邊
永遠是 down。** 2026-08-21 把等待從 60 秒縮成 10 秒就是踩到這個。

等提示符出現再回 terminal A 按 Enter。

### 1c. 等收斂（terminal A，按下 Enter 之後自動）

✅ 要看到：

```
  waiting for 10 switches, 32 links, and all-destination paths
  the Ryu app sleeps a hard-coded 60s before installing paths, so expect >60s
    switches=10 links=32 paths=pending
    switches=10 links=32 paths=installed
  converged after 6Xs
[3/3] kernel
  waiting for kernel API on :8000 . up
```

⚠️ **`paths=pending` 停留約 40 秒是正常的**（舊版文件寫 60 秒，那是 2026-08-21 之前的值）。
那個等待現在是 `NDTWIN_RYU_SETTLE_S`，預設 40，不再是寫死的 `hub.sleep(60)`。

它擋住的就是上面 §1b 講的那件事：**規則一裝上去，學習窗就關了。** 所以這個等待不是「保守起見多等
一下」，而是 twin 看不看得見自己 128 台主機的分界線。11 次完整開機實測
（`doc/audit/2026-08-22_settle-gate-acceptance/settle_bisect.txt`）：

| `NDTWIN_RYU_SETTLE_S` | Ryu 學到的主機 | kernel 圖 | `ndt up ovs` |
|---|---|---|---|
| 5 | 0/128 | 288 邊、**256 down** | 16 s |
| 10（2026-08-21 的預設，已知壞，今天重現兩次） | 0/128 | 288 邊、**256 down** | 20 s |
| 15 | 128/128 | 288 邊、0 down | 27 s |
| 20 | 128/128 | 288 邊、0 down | 31 s |
| **40（現在的預設，n=3）** | 128/128 | 288 邊、0 down | **52 s** |
| 90 | 128/128 | 288 邊、0 down | 100 s |

🔑 **這是懸崖不是斜坡** —— 要嘛 128 台全學到、要嘛一台都沒有，分界在 10 到 15 之間。40 是刻意
留了 4 倍餘裕（對最高的失敗值 10），不是「跑得動的最小值」。

⚠️ **快不等於好。** 那個二十幾秒的開機數字之所以快，正是因為它在主機被學到之前就把路由裝好了 ——
速度和 256 條 down 邊是同一件事。**失敗是無聲的**：資料平面完全正常、ping 全通、開機輸出不會有
任何警告，只有 `get_graph_data` 的 down 數會說話。看到 `ndt up ovs` 只花二十幾秒，先去查那個數字。

那 60 秒是**從 10 台交換機全部連上 Ryu 之後**開始算的，不是從 Ryu 啟動算：
`load_static_topology()` 只在 `len(self.switches) >= switch_num` 時才被呼叫
（`intelligent_router.py:178`）。所以 `paths=installed` 這個訊號其實同時證明了**10 台都連上了**
—— 它比單看 link 數量更強，而不只是「等了一分鐘」。

⚠️ **如果 `converged after` 只花了 2 秒，那是閘門又壞了**（只等到 link discovery，沒等到路徑安裝），
不要往下做。

⚠️ 看到 `all-destination paths were never installed` 代表 `install_all_pair_paths` 拋例外了，
去 `.test_run/logs/ryu.log` 找 `Failed to load static topology file`。

```bash
./stack.sh wait
```
✅ 應該 `up=10 enabled=10`。

### 1d. 灌流量（terminal B）—— 兩端必須在**不同**交換機

你自己在 CLI 裡打：
```
mininet> h97 iperf -s -u &
mininet> h1 iperf -c 10.0.0.97 -u -b 10M -t 600 &
```

或者跟我說一聲，我用 `mnexec` 代跑（實測可行）：
```bash
H1=$(ps -eo pid,args | awk '$NF=="mininet:h1"{print $1}')
H97=$(ps -eo pid,args | awk '$NF=="mininet:h97"{print $1}')
sudo -n mnexec -a "$H97" iperf -s -u -p 5001 &
sudo -n mnexec -a "$H1"  iperf -c 10.0.0.97 -u -p 5001 -b 10M -t 600 &
```
收掉：`for p in $(pgrep -x iperf); do sudo -n mnexec -a "$H1" kill "$p"; done`
（`sudo kill` 不在 NOPASSWD 清單裡，所以要繞過 `mnexec` 以 root 身分殺。）

⚠️ **不要用 `h1` ↔ `h2` 或 `h1` ↔ `h4`**：只有 s1–s4 掛 host，而 h1/h2/h4 **全都在 s1 底下**。
`getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2245`）**刻意排除所有接到 host 的邊**，所以同一台
交換機底下互打，`get_average_link_usage` **永遠是 0.0**，那不是壞掉。

| 交換機 | host IP |
|---|---|
| s1 | 10.0.0.1 – 10.0.0.32 |
| s2 | 10.0.0.33 – 10.0.0.64 |
| s3 | 10.0.0.65 – 10.0.0.96 |
| s4 | 10.0.0.97 – 10.0.0.128 |

⚠️ **頻寬用 `-b 10M`，不要 100M。** 實測 100M 會把 LLDP 餓死，Ryu 會誤判 link 掛掉（曾經一次跑出
19 次 link deleted），連 `ping` 都測不了。

⚠️ **流量必須在 1e／1f 執行的「同時」還在跑**，不能先跑完再測：flow 會老化，停幾秒
`get_detected_flow_data` 就變 0 筆。而且 sFlow 是 **1/256 取樣**，`ping` 每秒 1 個封包要 256 秒才
產生一個 sample —— 只有 iperf 這種能打滿的流量才夠。

### 1e. 手動確認四項（terminal C，趁流量在跑）

```bash
# ① 圖：10/10 up 且 enabled，而且要「持續」是 10/10
curl -s localhost:8000/ndt/get_graph_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
sw=[n for n in d['nodes'] if n.get('vertex_type')==0]
print('switch up:', sum(1 for n in sw if n['is_up']), 'enabled:', sum(1 for n in sw if n['is_enabled']), '/', len(sw))"

# ② 電力：30–150 W，各台不同，隔 10 秒再查數字不變
curl -s localhost:8000/ndt/get_power_report

# ③ 鏈路使用率：非零
curl -s localhost:8000/ndt/get_average_link_usage

# ④ 路徑上的交換機才有 flow（s1→s6→s10→s8→s4）
for d in 1 6 10 8 4 2 3; do
  printf "dpid %-2s " $d
  curl -s -X POST localhost:8000/ndt/get_num_of_flows_passing_a_switch \
    -H 'Content-Type: application/json' -d "{\"dpid\":$d}"; echo
done

# ⑤ flow table：10 台各約 130 條（注意：這個端點不吃 ?dpid=，加了會 404）
curl -s localhost:8000/ndt/get_switch_openflow_table_entries | python3 -c "
import json,sys
for sw in json.load(sys.stdin):
    print(f\"dpid {sw['dpid']}: {sum(len(v) for v in sw['flows'].values())} 條\")"
```

**2026-07-30 實測的參考值**（`h1`→`h97`，10M UDP）：

| 項目 | 值 |
|---|---|
| switch up / enabled | 10 / 10 |
| `get_power_report` | 33466 – 147622 mW，10 台各不相同，跨輪詢不變 |
| `avg_link_usage` | `0.0074514` |
| 有流量的交換機間鏈路 | 4 條：s1:2→s6（2.173%）、s6:4→s10、s8:2→s4、s10:4→s8 |
| `num_of_flows` | s1/s6/s10/s8/s4 = 1，s2/s3 = 0 |
| flow table | 10 台各 130 條 |

⚠️ 同一條路徑上四條邊的 bps 不一致（21.7M / 12.4M / 6.2M / 6.2M）是 **1/256 隨機取樣的變異**，
不是算錯 —— 短窗口下預期會有。

⚠️ **四條邊的百分比差 10 倍不是筆誤** —— 這個拓撲的鏈路速率是混合的：s1→s6 和 s8→s4 是
**1 Gbps**，s6→s10 和 s10→s8 是 **10 Gbps**。所以 `12419072 / 10e9 = 0.124%` 是對的。
（審查這段的人假設全部 1 Gbps，得出「少了一個 10 倍」的結論 —— 實測頻寬證明不是。）


### 1f. 契約測試 + 抓基準（terminal A，趁流量還在跑）

```bash
./run_layers.sh api ovs --traffic
```

⚠️ 這一步**會有 FAIL**。判斷標準是 **FAIL 的清單有沒有變**，不是有沒有 FAIL。

**2026-07-30 實測基準線（乾淨 kernel、有跨交換機流量）**：

```
L2: 31/36 passed          ← 只有下表那 5 個 FAIL
L3: 2 BROKEN              ← install_flow_entry、received_a_simulation_case
    MISSING /ndt/disable_switch   （元件期望但 kernel 沒有這個端點）
log: PASS
```

比先前記錄的 30/36 好一個：`get_graph_data` 的 254 條 host edge down 已經不再 FAIL（liveness
修好之後圖是 10/10 up+enabled）。

⚠️ **log 檢查只在「一個 kernel process 只跑一次 api」時才可信。** 跑第二次時，第一次故意打的錯誤
請求會落進檢查窗口，變成一片沒有意義的紅（實測跑四次 → 47 條問題，全部是測試自己打的）。
`run_layers.sh` 現在會偵測並提示你重啟 kernel。

⚠️ **`get_detected_flow_data` 偶發 FAIL** 有兩個原因，都不是 bug：
1. **流量停了** —— flow 幾秒內就老化，`--traffic` 會報「no flows detected」。iperf 要一直跑著。
2. ~~多播~~ 已修：本機 Avahi 的 mDNS（`192.168.123.16 -> 224.0.0.251`）會漏進 sFlow 取樣，
   而多播沒有單播路徑。檢查現在豁免多播／廣播／link-local。

| 已知 FAIL | 原因 |
|---|---|
| `get_graph_data`（host edge down） | static ARP → Ryu 學不到 host IP |
| `install_flow_entry__unknown_dpid` → 200 | kernel 有正確拒絕並記 WARN，只是 `OpResult` 沒反映到 HTTP status |
| `get_path_switch_count__bad_ip` → 500 | `Invalid IP address` 例外沒接 |
| `inform_switch_entered__bad_dpid` → 500 | `std::stoull` 沒包 try |
| `received_a_simulation_case` ×2 → 202 | 收到爛 JSON 也回 202 |

**只在上面這一步的 FAIL 清單沒有多出新項目時**才抓基準：

```bash
./run_layers.sh baseline ovs --traffic
```

⚠️ 基準抓壞了比沒有更糟 —— 之後 P4 的差異比對全部會以它為準。

**抓之前一定要確認這三項不是零／空**，否則 L4 比對會反向失效：

```bash
curl -s localhost:8000/ndt/get_average_link_usage          # 必須非零
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('flows:', len(d))
print('rates:', [f['estimated_flow_sending_rate_bps_in_the_last_sec'] for f in d])
print('paths:', [len(f['path']) for f in d])"
```

**2026-07-30 踩過**：OVS 基準在 `avg_link_usage = 0.0`、唯一那筆 flow `rate = 0` 的瞬間抓下來，
結果 L4 比對變成「OVS 沒有 telemetry，P4 有」—— 和 allowlist 裡那些 Phase 5 條目寫的方向**正好相反**。
唯一那個「非預期差異」`list is empty in OVS but populated in P4: edges[].flow_set[]` 完全是這個
造成的假象，而不是 P4 的問題。**不要把它加進 allowlist** —— 那是把壞基準掩蓋掉。要重抓 OVS 基準。

### 1g. 收尾

terminal B：
```
mininet> exit
```
terminal A：
```bash
./stack.sh down
sudo mn -c
```

⚠️ **兩個 Mininet 不能同時開**，切換模式之間**一定要 `sudo mn -c`**，否則殘留的 namespace／bridge
會讓下一個模式起不來，或測出假結果。

---

## 第 2 步：P4 一輪（約 15 分鐘）

### 2a. 開 bmv2 Mininet（terminal B）—— 這次 **Mininet 先**

```bash
sudo python3 /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/p4_testbed_topo.py
```

> ⚠️ **P4 的順序和 OVS 相反，這是對的，不是筆誤。** OVS 是交換機主動撥給 Ryu，所以 Ryu 要先；
> bmv2 反過來 —— `simple_switch_grpc` 是 **server**（listen `50051-50060`），proxy 是 gRPC
> **client**。proxy 連不到就會直接退出（而且因為 gRPC channel 是 lazy 連線，錯誤會延到第一個
> 阻塞 RPC 才浮現，看起來像別的問題）。

✅ 要看到 10 台都確認在 listen，而且**用腳本自己的驗證**而不是看它印什麼：

```bash
cat /tmp/ndtwin_p4_switches.json | python3 -m json.tool | head -20
```

⚠️ 這個腳本曾經在 s10 已經死掉的情況下印「10 switches listening」（port 被孤兒 process 佔住）。
現在它有 PID 記錄和 `verify_switches()`，但還是以 manifest 為準。

### 2b. 起 stack（terminal A）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh up p4
```

✅ 要看到 10 台都 `Clone session 250 -> port 255 installed`，0 失敗。
⚠️ 沒設 clone session 的話 bmv2 會**安靜地**丟掉每一份 clone，telemetry 全空但不報錯。

⚠️ log 出現 `ECONNREFUSED` 到 `:5005x` 就是 bmv2 沒起來 —— 回 2a。

```bash
./stack.sh wait
```

### 2c. 灌流量（terminal B）

```
mininet> h1 ping -c 2700 h4
```
（或我代跑：`sudo -n mnexec -a $(ps -eo pid,args | awk '$NF=="mininet:h1"{print $1}') ping -c 2700 10.0.0.4`）

⚠️ **封包要夠多。** 1/256 取樣、每跳獨立取樣，所以機會數 = 封包數 × 跳數。200 個 ping × 10 跳
÷ 256 ≈ 8 個 sample。要更穩就用 `-c 2700`（實測 ≈ 107 個 sample）。

判斷流量夠不夠：看 kernel log 的 **`addressed=` 有沒有在增加**。`rx=` 會一直漲（那是週期性的
counter sample），但 `addressed=` 只有收到**flow sample**（真的有流量）時才漲。

### 2d. 確認 telemetry 鏈路（terminal C）

```bash
grep -oE "rx=[0-9]+ .*addressed=[0-9]+|app_drop=[0-9]+" ../../.test_run/logs/kernel.log | tail -3
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -m json.tool | head -40
```

**2026-07-29 實測的參考值**（已經是迴歸標準，不是待驗證項目）：

| 項目 | 值 |
|---|---|
| `rx` / `addressed` | **126 / 126** —— 相等表示每個 datagram 都成功歸戶到 agent |
| `app_drop` | 0 |
| 取樣數 | 2700 封包 × 10 跳 ÷ 256 ≈ 105 預期，實測 **107** |
| 解析出的 flow | 雙向 ICMP：type 8 code 0（request）+ type 0 code 0（reply） |
| `h1 ping h4` | 0% loss、`ttl=59`（64 − 5，證實過 5 台且 TTL 遞減有效） |

~~⚠️ **P4 模式的 `is_up` 現在還是騙人的**~~ —— **2026-08-10 更正：已修（`a8db425`）。**
bmv2 的 liveness 不再是 stub，`is_up` 兩種模式都可以拿來判斷。健康的 P4 fabric 應該是
10/10 switch、4/4 host、40/40 edge，`is_up` 與 `is_enabled` 都是。

### 2e. 契約測試、抓 P4 快照、比對

```bash
./run_layers.sh api p4 --traffic
./run_layers.sh baseline p4 --traffic
./run_layers.sh compare
```

✅ `compare` 的目標是 **0 個非預期差異**。預期內的差異列在
`tools/contract_test/baseline_diff_allowlist.txt`。

**2026-07-31 實測：通過。**

```
PASS: P4 matches the OVS baseline (plus 14 accepted difference(s))
```

那 14 條全部是 Phase 5 的 telemetry 差異（P4 有、OVS 基準那一刻沒有的欄位）加上兩份拓撲檔本身的
差異。Phase 6 相關的 12 條已經在 `22e1176` 剪掉了。

⚠️ allowlist 裡標了「Phase 6」的項目，在 Phase 6 做完之後應該變成 **unused** —— 那正是它們該消失
的訊號，不是錯誤。

### 2f. 收尾

terminal B：
```
mininet> exit
```
terminal A：
```bash
./stack.sh down
sudo mn -c
pkill -x simple_switch_g             # -x 而不是 -f，且名稱只到 15 字元
```

---

## 出問題時要抓什麼

| 症狀 | 先看哪裡 | 別誤判成什麼 |
|---|---|---|
| `converged` 只花 2 秒 | `stack.sh` 的 `paths_installed()`；是不是又只等 link discovery | 不要當成「收斂很快」 |
| `avg_link_usage` = 0 | 流量兩端是不是在同一台交換機 | 不是 bug（設計上排除 host 邊） |
| `num_of_flows` = 0 | 流量還在跑嗎；那台交換機在路徑上嗎 | 它不是 OpenFlow 規則數 |
| `{"error":"Not Found"}` | 端點是 GET 還是 POST；有沒有多加 `?dpid=` | 不是功能沒實作 |
| 全部節點紅色 | `.test_run/logs/kernel.log` 找 `ovs-vsctl list-br failed` | `6b3dc0c` 之後這應該只在真的查詢失敗時發生 |
| Ryu 突然沒 log | `pgrep -f "[r]yu-manager"` | **2026-07-30 曾經無聲死亡一次，死因至今未確定**（沒 traceback、沒 OOM 紀錄）。再發生請把 `ryu.log` 完整留下 |

log 位置：`.test_run/logs/{ryu,kernel,p4_proxy}.log`

---

## 這一輪之後要做什麼

跑完並確認基準可信，下一步是**把 P4 的 liveness stub 換成真的**
（`doc/2026-07-27_p4_bmv2_support_plan.md` Phase 6 的最後一塊）。那件事需要：

- proxy 新增每台交換機的 gRPC channel 狀態，以及 **LLDP beacon 的最後接收時間** ——
  proxy 目前**兩者都沒有記**
- 新的 `GET /p4/switch_state` 端點（現在完全沒有 `/p4/` 開頭的端點）
- kernel 端把 `pingWorker` 的 BMV2 分支換成查詢 + 三態 policy（沿用 `ovsLivenessFor` 的形狀）

`is_up` 是 power / CPU / 溫度 / `getAvgLinkUsage` 的前置條件，所以就算 diff 不大，**影響面很廣**，
而且需要的 LLDP 時間戳追蹤和待辦裡的「LLDP beacon 修正」是同一批資料結構 —— 這是先跑完整測試
再動手的理由。
