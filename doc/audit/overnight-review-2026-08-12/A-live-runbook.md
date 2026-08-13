# A — Live runbook 全輪（bmv2，獨佔 live 環境）

Agent A / 2026-08-12 夜間 / HEAD `5d53cf0` @ `fix/flow-rate-divide-by-zero`（開場已確認相符）
基準文件：`doc/p4_manual_test_runbook.md`（1030 行，全文讀過）

## TL;DR

**整輪走完（Phase 0–6），環境完好交還：Mininet 178866 與 4 host 全在、repo 逐字未動、HEAD 仍是 5d53cf0、
netem 零殘留、port 全空。唯一需要人動手的是一個 orphan process（見文末「給 Adam 的早晨清單」）。**

**發現計數：P0 0 ／ P1 3 ／ P2 5 ／ note 若干**

### 最重要的三件事

1. 🔴🔴 **P1 — `POST /p4/readopt/{dpid}` 會清空健康 switch 的整張表、裝 0 條路由、然後回 `"status":"success"`。**
   s1 實測：readopt 前 4 條規則、連通正常 → readopt 後 **0 條**、h1 **四個方向全部 100% loss、60 秒不自癒**，
   而 kernel 仍宣稱 `sw up 10 en 10`。控制組 s6（乾淨、未被污染）**同樣被清空**，所以是通用缺陷；
   差別只在核心交換機會被 fabric 繞過去、缺陷隱形，**邊緣交換機則讓那台 host 永久失聯**。
   **危險加倍**：3a312e3 的 502 訊息正是叫操作員打這個端點來「復原」。復原方法＝重啟 proxy（實測有效）。
2. ✅ **今天三個 commit 的 live 驗證**：32afeb9 **通過**（power off 後 dpid `0a` 從
   `/v1.0/topology/switches` 消失；用 commit 自己的量法 10Hz 取樣 678 次，**零 up-blip**）；
   949fcba **通過**（停機 **135 秒**後 power on **1.50 秒**完成，沒有繼承 gRPC backoff）；
   3a312e3 / eace67c **未觸發**（沒遇到 502）——**標為未驗證，不要寫成驗過**。
3. ✅ **failover 端到端健康**：斷 `s6-eth3↔s9-eth2`（自己從 topo 推對端，非照抄 runbook）→
   偵測 **2 筆零假訊**、38/40、規則 `OUTPUT:3→4`、路徑繞成 `1 6 10 7 4`、
   **ping 停 16.63s 自癒**、**復原 hitless（0 遺失）**。power-cycle 過的 s10 也**實測扛得住真流量**。

### 其餘
- **P1** — runbook §5c 的預期輸出是錯的：`src_ip` 是**整數** `16777226`（小端 `s_addr`）不是 `'10.0.0.1'`；
  程式自 2025-12-15 未變，是文件錯不是回歸；同 kernel 其他端點有 `ipToString`，**只有這個端點沒轉**。
- **P1** — `pgrep -cx simple_switch_g` 今晚被別的 agent 的測試 fixture 汙染過（一度回 11）；
  **判 orphan 要看 ppid/sid，不能看數量**。
- **P2** ×5：s10 這輪不在任何路徑上（照抄 §6 的 netem 範例會斷到零流量鏈路）；§5b 行號再次腐爛（實際 `:1842`）；
  §6f「12→9」在有替代路時不成立（維持 12 才對）；`/stats/flow` 的 `packet_count` **恆為 0**，
  不能拿來判斷有無流量；**控制平面死亡時 kernel API 完全不吭聲**（log 很吵但 `get_graph_data` 照樣 10/10 40/40）。
- **改判** — W1（23:02:40–23:09:02）內 s1 的封包風暴事故，經 orchestrator 通報 + 我的重現實驗
  （同手法殺 proxy，102 秒**重現不出來**），**歸因於 B3 測試的外部寫入，不是系統缺陷**。
- **Port 佈局實測**：kernel API = **:8000**，proxy = **:8081**，**:8080 無 listener**。


---

## Phase 0 — 基線（收尾要比對）

**時間**：2026-08-12 22:39:02

### 【觀察】bmv2 switch 完整 pid 清單（`pgrep -ax simple_switch_g`）

10 台，pid **179110–179119 連號**，對應 device-id 1–10 / gRPC :50051–50060：

| pid | device-id | gRPC port | thrift |
|---|---|---|---|
| 179110 | 1 | 50051 | 9091 |
| 179111 | 2 | 50052 | 9092 |
| 179112 | 3 | 50053 | 9093 |
| 179113 | 4 | 50054 | 9094 |
| 179114 | 5 | 50055 | 9095 |
| 179115 | 6 | 50056 | 9096 |
| 179116 | 7 | 50057 | 9097 |
| 179117 | 8 | 50058 | 9098 |
| 179118 | 9 | 50059 | 9099 |
| 179119 | 10 | 50060 | 9100 |

`pgrep -cx simple_switch_g` = **10**。（`-cx simple_switch_grpc` 回 0 是 comm 15 字元截斷，已知。）

**收尾比對規則**：這 10 個 pid 在 `stack.sh down` 之後**仍然活著是正常的**（Mininet 還開著）。
**多出來的 pid = orphan**（power-on helper 用 setsid 起的，活得過 mn exit）。

### 【觀察】其他 process

```
host:   178914 mininet:h1 / 178916 mininet:h2 / 178918 mininet:h3 / 178920 mininet:h4
topo:   178866 sudo python3 ...p4_testbed_topo.py（+ 178867 sudo child, 178868 真正的 python3）
proxy:  181157 .../p4_proxy/venv/bin/python proxy_agent/main.py
kernel: 181323 ./bin/ndtwin_kernel --mode mininet --topology .../StaticNetworkTopologyP4_10Switches_4Hosts.json --no-ai
```

### 【觀察】Port 佈局（`ss -ltnp`，查 8000/8080/8081）

```
LISTEN 0 4096 0.0.0.0:8000 users:(("ndtwin_kernel",pid=181323,fd=8))
LISTEN 0 2048 0.0.0.0:8081 users:(("python",pid=181157,fd=21))
```

**【推論】(note)** kernel API 在 **:8000**、proxy 在 **:8081**、**:8080 完全沒有 listener**。
runbook §4 / §9 寫的就是 8000+8081，一致。記憶裡「kernel 在 :8080」的說法在這個 P4 stack 上是錯的；
:8080 在 P4 模式的唯一角色是 runbook §3b 描述的那筆「kernel 啟動瞬間誤問 Ryu port」的預期失敗。

---

## Phase 1 — 靜態健康（idle，runbook §4）

**時間**：2026-08-12 22:40:12–22:40:30。**結論：§4 每一條全綠，數值與 runbook 寫的完全一致。**

### 【觀察】逐條對照

| runbook | 預期 | 實測 | |
|---|---|---|---|
| 4a 圖 | switches 10 up 10 enabled 10 / hosts 4 up 4 / edges 40 up 40 | **完全相同** | ✅ |
| 4b node key | 12 個，含 `admin_disabled` | 12 個，字母序與文件逐字相同 | ✅ |
| 4c 電力 | 10 筆，33466–147622 mW | 10 筆，min **33466**（dpid 10）max **147622**（dpid 8） | ✅ |
| 4d avg usage | `{"avg_link_usage":0.0,"status":"success"}` | 逐字相同 | ✅ |
| 4e flow table | 10 台各 4 條 | 10 台各 4 條 | ✅ |
| 4f detected flow | 0 | 0 | ✅ |
| 4g switch_state | 10 台 probe_ok/stream_alive 全 true、age 0–5s | 全 true，age 全部 4.55–4.56s | ✅ |
| 4h paths | 12 | 12 | ✅ |
| 4i proxy log | 10× clone session、0 fail、1× watchdog seeded | `Clone session 250 -> port 255 installed` ×10、`clone session failed\|NO telemetry` **0 筆**、`link watchdog seeded with 32 declared links` ×1 | ✅ |

4c 的電力值連 min/max 都跟 runbook 記的 33466/147622 一模一樣——**是合成值，跨 stack 重啟仍相同**，
可當成穩定指紋（runbook 只說「跨輪詢不變」，實測是跨 stack 也不變）。

### 【觀察】本輪的實際路徑（12 條，與 runbook 2026-08-10 那次**不同**）

```
h1<->h2:  去 [1,5,2]        回 [2,5,1]
h1->h3:   [1,6,9,7,3]       h3->h1: [3,7,9,5,1]
h1->h4:   [1,6,9,7,4]       h4->h1: [4,8,9,5,1]
h2->h3:   [2,6,9,7,3]       h3->h2: [3,7,9,5,2]
h2->h4:   [2,6,9,7,4]       h4->h2: [4,8,9,5,2]
h3<->h4:  去 [3,7,4]        回 [4,7,3]
```

**【推論】(P2 — 對 runbook 使用者的陷阱)** **s10 這一輪完全不在任何路徑上**（12 條路徑一個 s10 都沒有）。
runbook §6「正確的故障注入方式」示範斷的是 `s5-eth4 ↔ s10-eth1`，那是 2026-08-10 那次路徑
（`1 5 10 8 4`）的中段；**照抄那條指令在今天的 stack 上會斷到一條零流量的鏈路**，ping 全程不中斷，
而 runbook §6 自己的判準說「完全不中斷代表你斷的鏈路根本不在流量路徑上」。
runbook §5g 已經警告過「不要照抄固定的 dpid 清單」，但 §6 的 netem 範例本身就是硬寫的一對。
→ **Phase 3 因此改斷 `s6-eth3 ↔ s9-eth2`**，依據見 Phase 3。

去回程不對稱這次也成立（h1→h3 走 s6、h3→h1 走 s5），與 runbook §4h 的警告一致。

### 【觀察】`/v1.0/topology/switches` 基線（32afeb9 的驗證基準）

`GET localhost:8081/v1.0/topology/switches` → **HTTP 200，10 筆**，dpid 為 16 進位零填充字串
（`0000000000000001` … `000000000000000a`），每筆 `ports` 都是**空陣列**。

同一路徑打 kernel `:8000` 回 **HTTP 404**（這個端點只在 proxy 上）。

**【推論】(note)** `ports: []` 是**設計如此**，不是缺陷：`ryu_topology.py:84` 直接寫死
`{"dpid": _dpid_hex(d), "ports": []}`。所以 Phase 4 的判準只能看「dpid 有沒有從清單裡消失」，
不能看 ports。32afeb9 改的是**餵給 render_switches 的集合**（`switches.keys()` →
`connected_switch_dpids()`），不是輸出格式。

### 【觀察】環境前置

- netem 殘留：對 s1–s10 的 eth1–eth4 全掃，**零 netem**（乾淨起點）。
- `sudo -n -l`：NOPASSWD 只有 `ovs-vsctl`、`ifconfig`、`mnexec`、`tc qdisc add/del/show`（限
  `s[0-9]*-eth[0-9]*`）、`ndtwin-p4-power`。`(ALL:ALL) ALL` 那條**沒有** NOPASSWD 標記。
- **【推論】(note)** 因此我**無法 kill 任何 root process**（`sudo -n kill` 會要密碼）。
  用 `mnexec` 起的 ping 是 root 所有 → 一律加 `-w <秒>` 上限，**不留無主的長命 ping**。
  canary 因此是「每個 phase 一條有期限的 ping」而不是一條永久 ping。
- ping 支援 `-D`（unix timestamp）`-O`（缺漏回覆會印出 `no answer yet for icmp_seq=N`）
  → 時間線用這兩個旗標重建，不靠事後推算。
- 前置 ping h1→h2：`4 packets transmitted, 4 received, 0% packet loss`，**TTL 61**
  （64−3，路徑 `1 5 2` 三台 switch，與 §4h 讀到的路徑一致）。
---

## Phase 2 — 流量 + telemetry（runbook §5）

**時間**：2026-08-12 22:42:54 起，h1→h4 `ping -D -i 0.002 -w 100 10.0.0.4`（`mnexec -a 178914`）。

### 【觀察】canary / 資料面（**判準：ping 有沒有停**）

```
14464 packets transmitted, 14463 received, 0.00691372% packet loss, time 99994ms
rtt min/avg/max/mdev = 3.223/13.793/141.842/11.890 ms, pipe 18
```

**loss 0.0069%（14464 送出只掉 1 個，是第一個 seq 的 ARP 暖機）**，全程 `ttl=59`。
✅ 100 秒滿載無中斷。runbook §5e 預期「0% loss、rtt avg ~12.8ms、TTL 59」——TTL 完全吻合
（64−5，路徑 5 台 switch），rtt avg 13.79ms 同量級。

### 【觀察】§5c 已偵測 flow（流量進行中查）

`flows: 2`，雙向 ICMP（`protocol_id: 1`），`path_len` 各 7，rate 100352–301056 bps。
路徑與 §4h 的宣告一致且**去回程不同**：

```
去程 (h1->h4): [10.0.0.1, 1, 6, 9, 7, 4, 10.0.0.4]
回程 (h4->h1): [10.0.0.4, 4, 8, 9, 5, 1, 10.0.0.1]
```

### 🔴【觀察】P1 — §5c 記載的輸出格式是錯的：`src_ip`/`dst_ip`/path 端點是**整數**不是字串

runbook §5c 寫預期輸出是 `10.0.0.1 -> 10.0.0.4`，路徑是 `['10.0.0.1', 1, 6, 9, 8, 4, '10.0.0.4']`
（帶引號的字串）。**實測 raw JSON**（`curl -s localhost:8000/ndt/get_detected_flow_data | python3 -m json.tool`）：

```json
{
    "dst_ip": 16777226,
    "src_ip": 67108874,
    "protocol_id": 1,
    "path": [ {"interface": 3, "node": 67108874}, {"interface": 2, "node": 4},
              {"interface": 3, "node": 8},        {"interface": 1, "node": 9},
              {"interface": 1, "node": 5},        {"interface": 3, "node": 1},
              {"interface": 0, "node": 16777226} ]
}
```

**【推論】(P1，但是 doc 缺陷不是程式回歸)** 三件事分開講：

1. **這不是今天的回歸。** `j["src_ip"] = flowKey.srcIP;`（`src/ndt_core/collection/FlowLinkUsageCollector.cpp:2070`，
   `getFlowInfoJson()`）用 `git log -L` 追到 **d6f7c01（2025-12-15）**，早於全部 P4 工作，從未改過。
   所以是 **runbook §5c 的預期值寫錯了**，不是 API 變了。
2. **數值的解讀**：整數是 `in_addr.s_addr`（網路位元組序存在 uint32 裡），在小端機器上
   **`16777226` = `10.0.0.1`、`67108874` = `10.0.0.4`**。機制證據不是算式吻合而是同一個 helper：
   `include/utils/Utils.hpp:82-92` 的 `ipToString(uint32_t ip)` 做的就是 `addr.s_addr = ip` 再 `inet_ntop`。
   可跑的驗證：`python3 -c "import socket,struct; print(socket.inet_ntoa(struct.pack('<I',16777226)))"`
   → `10.0.0.1`（用 `>I` 打包會得到 `1.0.0.10`，所以**大端解讀是錯的**）。
3. **同一個 kernel 的其他端點會轉字串**：`HttpSession.cpp:1680` 和
   `TopologyAndFlowMonitor.cpp:2675` 都呼叫 `utils::ipToString(...)`。**只有 `getFlowInfoJson()` 不轉。**
   → 端點之間格式不一致，消費端（Web-GUI / Energy-Saving-App）必須自己 byte-swap。
   要不要統一是 Adam 的決定；至少 runbook 的預期值該改成整數，或程式改成呼叫既有的 `ipToString`。

**runbook 作者大概怎麼寫錯的**：proxy 的 `/ryu_server/all_destination_paths` **真的**回字串
（Phase 1 實測 `[['10.0.0.1', 3], [1, 1], ...]`），kernel 的 flow path 回整數——兩個格式被混為一談。

### 【觀察】§5d 平均鏈路使用率（流量中連查三次）

```
8.697173333333333e-05 → 2.00704e-05 → 8.697173333333334e-05
```

✅ 落在 runbook 說的 `1e-05`～`3e-04`，且**上下跳動不是單調爬升**，與 §5d 修正後的描述一致。

### 【觀察】§5f flow table（流量中）

`1:4 2:4 3:4 4:4 5:4 6:4 7:4 8:4 9:4 10:4` —— 10 台仍各 4 條，✅ 與 runbook「P4 flow table 不隨流量變動」一致。

### 【觀察】§5g `get_num_of_flows_passing_a_switch`（POST）

```
dpid 1 {"num_of_flows":2}   dpid 6 {"num_of_flows":1}   dpid 9 {"num_of_flows":2}
dpid 7 {"num_of_flows":1}   dpid 4 {"num_of_flows":1}   dpid 8 {"num_of_flows":1}
dpid 2 {"num_of_flows":0}   dpid 3 {"num_of_flows":0}   dpid 5 {"num_of_flows":0}   dpid 10 {"num_of_flows":0}
```

回傳形狀 `{"num_of_flows":N,"status":"success"}` ✅。路徑外的 s2/s3/s10 長期為 0 ✅。
**s5 這一瞬間是 0，但它在回程路徑 `4 8 9 5 1` 上**——runbook §5g 已明寫這個數字逐秒跳動、
「不適合當通過／失敗的判準」，所以不視為缺陷，只記錄它再次成立。

### 【觀察】§5b sFlow ingest healthy

```
[2026-08-12 22:42:55.484] [info] [FlowLinkUsageCollector.cpp:1842 calAvgFlowSendingRatesPeriodically]
sFlow ingest healthy: rx=6, app_drop=0, addressed=6, sock_ovfl_total=0
```

全檔**只有 1 筆**（之後轉 TRACE），✅ 與 runbook 描述一致。
**note**：runbook §5b 兩處都寫這行在 `FlowLinkUsageCollector.cpp:1798-1801`，**實測在 `:1842`**——
文件開頭的 2026-08-12 重核已經說 `:1798-1801` 漂掉了，但 §5b 內文的兩個引用**沒跟著改**
（第 402 行、第 1025 行）。行號腐爛的第三次，與開頭的警告自相矛盾。(P2，交給 B2/B4 彙整)
---

## Phase 3 — 斷鏈路 / 偵測 / failover / 復原（runbook §6，`tc netem`）

**結論：✅ 全綠，而且是本輪品質最高的一段——偵測、繞路、規則層、資料面、復原、零殘留全部對上。**

### 【觀察】斷哪一條、為什麼（不是照抄 runbook 的 s5↔s10）

runbook §6 示範的 `s5-eth4 ↔ s10-eth1` **今天不在任何路徑上**（Phase 1），斷它會得到「ping 全程不中斷」
這個無效結果。改斷 **`s6-eth3 ↔ s9-eth2`**，依據兩條：

- `p4_proxy/mininet/p4_testbed_topo.py:164` `addLink(switches[6], switches[9], port1=3, port2=2)`
  → **s6-eth3 ↔ s9-eth2** 是同一條鏈路的兩端（對端由此確定，不是猜的）。
- 它是 h1→h4 去程 `[1,6,9,7,4]` 的**中段**；且存在替代路：`:165` s6↔s10（s6-eth4↔s10-eth2）
  加 `:167` s7↔s10（s7-eth4↔s10-eth3）→ 預期繞成 `1 6 10 7 4`。

canary：h1→h4 `ping -D -O -n -i 0.5 -w 200`（2 pps，`-O` 讓每個沒回覆的 seq 自己印一行）。

### 【觀察】完整時間線

| 時刻 | 事件 | 證據 |
|---|---|---|
| 22:46:50.253 | **注入** `tc qdisc add ... netem loss 100%` 兩端，rc=0/0 | — |
| 22:46:50.284 | canary 最後一個回覆 `icmp_seq=17` | canary log |
| 22:47:05 | 監測仍 `edges_up=40/40 down=[]` | monitor |
| 22:47:06.661 | kernel `link failed on 6:3 -> 9:2` | kernel.log `HttpSession.cpp:414 handleLinkFailure` |
| 22:47:06.684 | kernel `link failed on 9:2 -> 6:3` | 同上 |
| **22:47:06.913** | **canary 恢復**，`icmp_seq=50` | canary log |
| 22:47:08 | 圖更新 `edges_up=38/40`、路徑已繞道 | monitor |
| 22:48:58.601 | **移除** netem 兩端，rc=0/0 | — |
| 22:49:07 | `edges_up=40/40 down=[]`、路徑復原 | monitor（≈6–9 秒） |

proxy log 對應兩行，措辭就是逾時機制本身：

```
[TopologyManager] link down (no beacon for 15s): (6, 3, 9, 2)
[TopologyManager] link down (no beacon for 15s): (9, 2, 6, 3)
```

### 【觀察】判準一：ping 有沒有停 —— **停 16.63 秒後自己恢復**

```
400 packets transmitted, 368 received, 8% packet loss, time 199999ms
rtt min/avg/max/mdev = 5.011/8.199/23.922/1.924 ms
GAP 1: seq 17 @22:46:50.284 -> seq 50 @22:47:06.913  missing=32 wall=16.63s
total gaps: 1 | replies: 368
```

✅ **整趟只有一個 gap**，就是注入的那一次。runbook §6 判準是「短暫中斷再自己恢復，15–20 秒正常；
永遠不恢復＝failover 沒生效，完全不中斷＝斷錯鏈路」——**16.63s 正中區間**。
對照 runbook 2026-08-10 那次 `9.67% / ~14.5s`，今天 `8% / 16.63s`，同一個量級。

**恢復（移除 netem）造成的封包遺失是 0** —— 路徑從 `1 6 10 7 4` 換回 `1 6 9 7 4` 全程無感，
gap 總數維持 1。**復原是 hitless 的**，這點 runbook 沒寫過，值得記下來。

### 【觀察】判準二：零假 link-down

`down=[(6, 3, 9, 2), (9, 2, 6, 3)]` —— **只有我故意斷的那兩個方向，一筆假的都沒有**，
`edges_up` 正好 38/40。完全複現 runbook 的 netem vs ifconfig 對照表（netem 2 筆零假訊 / ifconfig 5 筆含 3 假）。
**同一台 s6 的其他埠沒有被拖下水**，`sw_up` 全程 10/10。

### 【觀察】判準三：真的有繞路（規則層證據）

- twin 宣告的路徑：`1 6 9 7 4` → **`1 6 10 7 4`**，`paths` 全程維持 **12**（沒有 host 變不可達）。
- **switch 上的規則跟著變**（`GET localhost:8081/stats/flow/6`）：

| 目的地 | 斷線中 | 復原後 |
|---|---|---|
| 10.0.0.3 | `OUTPUT:4` | `OUTPUT:3` |
| **10.0.0.4** | **`OUTPUT:4`**（s6-eth4 → s10） | **`OUTPUT:3`**（s6-eth3 → s9） |
| 10.0.0.1 | `OUTPUT:1` | `OUTPUT:1`（未動） |
| 10.0.0.2 | `OUTPUT:2` | `OUTPUT:2`（未動） |

**【推論】** 斷線前 s6 對 10.0.0.4 是 `OUTPUT:3`——這一點我沒有在斷線前直接讀 s6 的規則，
是由 (a) 斷線前路徑 `1 6 9 7 4` 加 topo `:164`（port 3 通 s9），與 (b) 復原後實測回到 `OUTPUT:3`
兩邊夾出來的。**標為推論不是觀察**；要變成觀察，下次應該在注入前先存一份 `/stats/flow/6`。

### 【觀察】穩定性與殘留

- 38/40 在 22:47:08–22:48:58 之間**連續 18 個取樣完全不變**，無 flapping（runbook §6d 要求）。
- 收尾 `tc qdisc show`：掃過 s1–s10 的 eth1–eth4，**零 netem 殘留**；
  兩個動過的介面明確回到 `qdisc noqueue 0: root refcnt 2`。

### 【推論】(note) §6f「路徑數 12→9」在今天的拓撲下不適用

runbook §6f 預期斷線後路徑掉到 9，而 §6 後半的修正段落又說「要驗的是有下降」。
本次斷中段鏈路 **paths 全程 12 不變**，而這是**正確**行為——12 條路徑沒有一條經過失效鏈路
（h1→h4、h1→h3、h2→h3、h2→h4 四條都改走 s10）。
「路徑數必須下降」只在**失效導致某 host 不可達**時成立；有替代路時維持 12 才是對的。
§6f 與 §6 修正段落合起來讀會讓人以為「維持 12 是退步的徵兆」，在這個斷點上會誤判。(P2，doc)
---

## Phase 4 — 電源輪（直接驗今天三個 commit）

**目標 switch：s10 = dpid 10 = `192.168.123.20`**。選它的理由：Phase 3 復原後 12 條路徑**沒有一條經過 s10**，
所以電源操作的 blast radius 為零，canary 的任何變化都能乾淨歸因。
（ip↔dpid 對照從 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` 讀出：`192.168.123.11`→s1 … `.20`→s10。）

**API 形狀（實測，runbook 未涵蓋 Phase 7）**：
`POST /ndt/set_switches_power_state?ip=<管理IP>&action=on|off` —— **query param，吃 ip 不吃 dpid**，
body 不用帶（`HttpSession.cpp:648` `handleSetSwitchesPowerState`）。查詢用
`GET /ndt/get_switches_power_state` → `{"192.168.123.11":"ON", ...}`。

### 4a.【觀察】power off → 驗 32afeb9 ✅

| 時刻 | 事件 |
|---|---|
| 22:53:04.810 | `POST ...?ip=192.168.123.20&action=off` → **HTTP 200 `{"192.168.123.20":"Success"}`**，0.28s |
| 22:53:05 | bmv2 pid **179119 消失**，`pgrep -cx simple_switch_g` 9 |
| 22:53:27 | `/v1.0/topology/switches` → **`['01'..'09']`，`0a` 不見了** ✅ |
| 22:53:27 | `/p4/switch_state` s10 → `probe_ok=False stream_alive=False` |

**兩個端點口徑一致**——這正是 32afeb9 commit message 說修掉的「同一個 process 的兩個端點互相矛盾」。

**up-blip 測試（複製 commit 自己的量法：10Hz 取樣 is_up）**：22:53:30–22:54:40 共 **678 個取樣**

```
is_up value counts: Counter({False: 678})
UP-BLIPS (is_up true while powered off): 0
```

✅ **零 up-blip**。kernel topology poll 此時是 30s 一次（process 已過 90s），70 秒窗口涵蓋 2 次以上輪詢，
若缺陷仍在，每次輪詢都該出現一次 blip。**32afeb9 在 live 上驗證通過。**

其餘狀態：`switches up 9/10 enabled 10/10`、`edges up 32/40`（s10 的 4 條鏈路 ×2 向 = 8 條，40−8=32，數字精確對上）。
**canary（h1→h4 2pps）全程 0 遺失**——s10 不在路徑上，符合預期。

### 4b.【觀察】停機 135 秒後 power on → 驗 949fcba ✅ **1.50 秒完成**

停機 22:53:04.810 → 22:55:19.091，**135 秒**（遠超 gRPC backoff 實測值 32.56s 的要求）。

```
=== POWER ON s10 AT 22:55:19.091 ===
{"192.168.123.20":"Success"}
HTTP 200 time_total=1.496305
=== DONE AT 22:55:20.597 | elapsed=1.503334565s ===
```

**1.50 秒**，遠低於「<5s 級」的判準。kernel log 與 proxy log 把兩個階段分得很清楚：

```
{"status": "started", "name": "s10", "pid": 198120}                                  <- helper 起 process
{"status":"success","dpid":10,"clone_session":true,"routes_installed":0}             <- readopt 回應
[10] Received arbitration response: Mastership confirmed.
[10] Setting Forwarding Pipeline Config...
[10] Clone session 250 -> port 255 installed
[TopologyManager] readopt 10: pipeline pushed, clone_session=True, 0 routes installed
INFO: 127.0.0.1:39098 - "POST /p4/readopt/10 HTTP/1.1" 200 OK
```

**【推論】** 135 秒停機後 readopt 一次就成功、總耗時 1.5 秒，代表新 channel **沒有繼承舊 channel 的
重連 backoff**——這就是 `use_local_subchannel_pool`（949fcba / e7d564b）要解決的問題，
**live 驗證通過**。若 backoff 被繼承，這一步應該要等到 30 秒級才會通。

### 4c.【觀察】沒有遇到 502，所以 3a312e3 / eace67c 的路徑**未被觸發**

power on 直接回 200，**沒有出現 502**，因此：
- 3a312e3 的「訊息指向直接打 `/p4/readopt/{dpid}`」**這次沒機會驗**（錯誤路徑沒走到）。
- eace67c 的 `--fail-with-body`（讓 readopt 失敗細節進 kernel log）**同樣沒被觸發**。

程式碼上兩者都在位（`P4PowerStrategy.cpp:82` 用的是 `curl -sS --fail-with-body -X POST --max-time 30`，
註解明寫「`--fail-with-body`, not `-f`」以及 2026-08-12 那次「kernel log 只剩 `curl: (22) ... error: 502`」的動機；
`:115-127` 的 failure(502) 訊息包含 `POST http://<proxy>/p4/readopt/<dpid>`）。
**但今晚是靜態閱讀，不是 live 證據** —— 標記為**未驗證**，不要在文件裡寫成驗過了。

### 4d.【觀察】復原完整

22:56:51：`/v1.0/topology/switches` 回到 10 筆（`0a` 回來）、`sw_up=10/10 sw_en=10 edges_up=40/40 down=[]`、
`paths=12`、s10 `probe_ok=True stream_alive=True`、ages 0.87s。
**canary 整個電源循環 no-answer = 0**（476+ 封包全收）。

### 🔴 4e.【觀察】P1 — `pgrep -cx simple_switch_g` 今晚被**別的 agent 的測試** 汙染

power on 之後 `pgrep -cx simple_switch_g` 回 **11**，不是 10。第 11 個是：

```
198254 /tmp/ndtwin_p4helper_bin.8fb0njwm/pysw/simple_switch_grpc \
       /tmp/ndtwin_p4helper_case.67qcc4tl/silent.py 60323 /tmp/ndtwin_p4helper_case.67qcc4tl/sw.pid
```

啟動於 22:55:29（我的 power on 在 22:55:20.597 就結束了，**不是我造成的**），ppid 198253，
數秒後自行消失（再查已 gone）。

**【推論】(P1 — 影響收尾判讀，不是產品缺陷)** 這是 **p4 power helper 的測試 fixture**：
路徑 `/tmp/ndtwin_p4helper_bin.*/pysw/simple_switch_grpc` 是假的 bmv2，
`silent.py` 對應 helper docstring 裡「SIGTERM only... 一個忽略 TERM 的 process 視為失敗」那個測試案例。
極可能是 **B3（測試/mutation agent）** 在跑 `tools/p4_power_helper.py` 的測試。

**後果，Adam 早上務必注意**：
1. **`pgrep -cx simple_switch_g` 的數量今晚不可信**——它會把測試 fixture 算進去。
   要判斷 orphan **必須看 cmdline**：真 switch 的 cmdline 含 `--device-id N` 和 `--grpc-server-addr 0.0.0.0:5005x`；
   fixture 的路徑含 `ndtwin_p4helper`。
2. runbook「收尾」寫的 **`pkill -x simple_switch_g` 會連別人的測試 fixture 一起殺**
   （名稱匹配，Mininet 與測試共用 root PID namespace）。今晚我沒有執行它。
---

## 附記 — 對 B4 三項掃雷結論的 live 佐證（orchestrator 插播）

B4 靜態掃出 §6 三處問題，我這輪的實測**三項都對得上**，記在這裡當交叉證據：

1. **§6h 寫 `ifconfig down` 是文件腐爛** —— 確認**我全程沒有執行過任何 `ifconfig`**（禁令 #3）。
   Phase 3 唯一的注入手段是 `tc qdisc add dev <if> root netem loss 100%`，兩端都下，
   即 runbook L810-816 那個正確版本。`sudo -n -l` 顯示 `ifconfig` 確實在 NOPASSWD 名單裡，
   **所以照抄 §6h 會成功執行並產生假證據**——這是最危險的一種腐爛（不會報錯，只會騙人）。
2. **`reroutable_down_endpoints()` 已修（`topology_manager.py:451-455`）** ——
   我的 Phase 3 給出**行為面的佐證**：斷 `s6-eth3↔s9-eth2` 後回報的 down 集合是
   `[(6,3,9,2), (9,2,6,3)]`，**恰好兩個方向、零假訊**，且 `edges_up=38/40` 沒有多扣。
   runbook 描述的舊漏洞是「suspect 判定把整台的 down link 一起赦免、包含真斷的那條」，
   若仍存在，進入 s6 方向的那筆應該被錯誤保留、繞路也會不完整。**實測繞路成功且雙向都對。**
3. **§6b 的「約 11 秒」是過時值，實際 15–20s** —— 我的實測**支持 15–20s**：
   注入 22:46:50.253 → kernel 記 `link failed` 22:47:06.661（**+16.41s**）→ canary 恢復 22:47:06.913（**+16.63s**），
   proxy log 的措辭本身就寫著機制：`link down (no beacon for 15s)`。
   **11 秒這個數字在今晚的環境下不會出現**，照它判「超過 11 秒就是異常」會產生假陽性。
### ✅ 4f.【觀察】追加測試：power-cycle 過的 s10 **真的能轉發封包**（runbook 沒有這一步）

**為什麼加這一步**：readopt 的回應是 `{"status":"success","dpid":10,"clone_session":true,"routes_installed":0}`
——**`routes_installed: 0`**。一台剛重啟的 bmv2 是空的（無 pipeline、無 table entry、無 mastership），
「成功但裝了 0 條路由」值得懷疑它是不是回來了卻不會轉發。**光看 API 全綠會漏掉這個**
（這個 repo 的既有教訓：twin 會安靜地說謊）。

**先確認資料來源不是快取**：`GET /stats/flow/{dpid}`（`api_routes.py:220-260`）走的是
`client.read_table_entries()`，**從 switch 上讀回來**，不是 proxy 的快取；讀不到會回 503。
所以它看到的 4 條規則是 s10 上真的有的。

**再做端到端**：22:58:52.397 重新對 `s6-eth3 ↔ s9-eth2` 注入 netem，把 h1→h4 逼上 s10。

| 觀測 | 結果 |
|---|---|
| twin 路徑 | `1 6 9 7 4` → **`1 6 10 7 4`**（22:59:13 起） |
| canary | `GAP 1: seq 16 @22:58:51.924 -> seq 56 @22:59:12.081 missing=39 wall=20.16s`，**之後持續到 seq 225 無第二個 gap** |
| **s10 實體介面計數** | `s10-eth2`（接 s6 那側）RX **631 → 636 / 2 秒，持續遞增** |
| 復原 | 23:00:12 移除 netem → 23:00:18 回到 40/40、路徑復原、**零 netem 殘留** |

✅ **結論：power-cycle + readopt 之後的 s10 是真的活著的 switch，不只是 API 上綠的。**
`routes_installed: 0` 不代表交換機留空——規則後來由鏈路重新發現那條路徑補上了
（proxy log `[TopologyManager] Installing initial routes proactively...`），實測 4 條規則齊全且會轉發。

**【推論】(P2 — 量測陷阱，值得寫進 runbook)** `/stats/flow/<dpid>` 回的
**`packet_count` 恆為 0，即使該 switch 正在實際轉送封包**：上表同一時刻 s10 四條規則全是 `pkts= 0`，
而 `s10-eth2` 的 RX 正在遞增。**不要用 `packet_count` 當「有沒有流量」的證據**——
要看流量請讀 `/sys/class/net/<if>/statistics/rx_packets`，或用 canary ping 本身。

**【推論】(note)** 本次偵測窗 **20.16s**，比 Phase 3 的 16.63s 慢；兩次都落在 15–20s 這個窗的範圍內
（20.16 剛好在上緣）。所以判準寫「15–20 秒」比寫單一數字穩健，**寫「約 11 秒」會誤判成異常**。
---

## Phase 5 — 殺 proxy / 錯誤回報 / 恢復

### 【觀察】proxy 不在的三個時間窗（供 B3 s1 污染事件界定範圍）

orchestrator 通報：B3 的 `test_p4_client.py::LiveSwitchTest` opt-in 守衛失效，**趁 :8081 沒人聽的窗口
直連 switch 1 的 :50051**，推了 pipeline config、2 條 route、clone session 250。
以下是**我這邊 :8081 無 listener 的完整時間窗**，其他時間 :8081 都有 proxy 在聽：

| # | 開始（kill） | 結束（proxy 起來） | 長度 | 備註 |
|---|---|---|---|---|
| **W1** | **23:02:40.284** | **23:09:02.096** | **6分22秒** | 第一次殺，pid 181157。**s1 異常發生在這個窗內** |
| W2 | 23:11:51.811 | 23:14:34 | 2分43秒 | 重現嘗試，pid 207796 |
| W3 | 23:19:5x（約） | 23:20:1x（約） | ~25 秒 | 為了修復 readopt 造成的空表而重啟 |

在此之前（22:36 stack 起來 → 23:02:40）proxy 全程在線。

### 【觀察】proxy 死掉時 kernel 的錯誤回報：**log 很吵，API 完全不吭聲**

W1 期間 kernel log 新增（去重後計數）：

```
     91 Command failed (exit code 7): curl -s --max-time 3 -w '\n%{http_code}' http://localhost:8081/p4/switch_state 2>/dev/null
      9 Command failed (exit code 7): curl -s -X GET http://localhost:8081/stats/flow/1   （每台 switch 各 9 筆，共 10 台）
```

✅ **失敗有進 kernel log，而且指名道姓**（含 exit code 7 = 連線被拒、完整指令）。這一半是好的。

🔴 **但 API 從頭到尾說一切正常**。W1 內連續取樣 60+ 秒：

```
23:03:03 sw_up=10/10 en=10 edges_up=40/40
23:03:13 sw_up=10/10 en=10 edges_up=40/40
...
23:04:03 sw_up=10/10 en=10 edges_up=40/40
```

**【推論】(P2)** 控制平面完全消失、kernel 每秒都在記連線失敗，`/ndt/get_graph_data` 仍宣稱
10/10 up+enabled、40/40 edges，**沒有任何端點透露 twin 已經瞎了**。
這與 32afeb9 的三態規則是**一致**的（「探測從未完成 ≠ 死亡」，避免啟動瞬間整個 fabric 變黑），
所以**不是回歸**；缺的是「控制平面不可達」這個**獨立訊號**——目前只能從 kernel log 看出來，
拿 `/ndt/get_graph_data` 做決策的 app（Energy-Saving、Traffic-Engineering）分辨不出
「資料是新的」還是「資料是 6 分鐘前的快照」。要不要補一個 freshness / control-plane-reachable
欄位是 Adam 的設計決定，我只記錄現況。

### 🔶【觀察→改判】W1 內 s1 的資料面異常 —— **歸因於外部污染，不是系統缺陷**

W1 內我觀察到一段真實的資料面故障，時間線如下（保留原始觀察，因為它同時也是污染的證據）：

| 時刻 | 觀察 |
|---|---|
| 23:02:40 | 殺 proxy |
| 23:02:40–23:03:54 | canary h1→h4 **持續正常 74 秒**（0 遺失） |
| **23:03:54** | canary 最後一個回覆（seq 158），之後**再也沒有回來** |
| 23:04:39 | 診斷 ping h1→h2 100% loss |
| 23:06:31 | `tcpdump -i s1-eth1` 抓到 **只有 3 個封包在無限循環**：`00:00:00:00:00:01 > 00:00:00:00:00:01, 10.0.0.2 > 10.0.0.1: ICMP echo reply, seq 1/2/3`（正是我那次 `ping -c 3` 的回覆），8 個 sample／1649 packets received by filter |
| 23:07 | 介面速率：**s1-eth1 RX 4788/s TX 4789/s、s5-eth1 RX 4791/s TX 4791/s，其餘全 0** → s1↔s5 之間的封包風暴，最高衝到 **5964 pkt/s** |
| 23:08:14 | **故障範圍精確定位**：h3→h4 0% loss、h2→h4 0% loss、**h4→h1 100% loss** → 只有「送往 10.0.0.1」壞掉 |
| 23:09:02 | 重啟 proxy → 風暴歸零、s1 的 `10.0.0.1 -> OUTPUT:3` 恢復、全部連通 |

**排除掉的假設（都有實測，不是推測）**：ARP 過期 → h1/h4 的 ARP 全是 **PERMANENT**（靜態），不是它；
bmv2 process 掛掉 → 10 台**全部活著**；整個 fabric 壞掉 → **只有 s1 的 host 交付壞掉**。

🔴 **然後我做了重現實驗，結果是「重現不出來」**：23:11:51 用同樣手法殺掉**剛重啟過的** proxy，
每 3 秒探一次 h4→h1，**連續 102 秒全部 `0% packet loss`**，s1-eth1 只有 ping 本身的 2 pkt/取樣，零風暴。

**【推論】(改判為 note，不是產品缺陷)** 兩件事合起來解釋得很乾淨：
1. B3 的測試在 **W1 的窗內**直連 s1:50051 推了 pipeline config（**會清空整張表**）+ **只有 2 條 route**。
   s1 正確的 route 有 4 條；被替換成 2 條之後，`10.0.0.1` 的正確出口（host port 3）就沒了。
2. 沒有正確 entry 時封包在 s1↔s5 之間彈跳成風暴；**W2 重現不出來，正是因為 B3 已經封鎖該測試再發**。

**所以 W1 的 s1 故障是外部寫入造成的，我不把它列為系統缺陷。** 保留完整紀錄的理由有兩個：
(a) 它是污染確實發生過的獨立佐證（症狀與「pipeline 重推 + 只裝 2 條 route」完全吻合）；
(b) **「封包在兩台 switch 之間無限循環且 TTL 沒有把它燒掉」這個現象本身值得存檔**——
    抓到的 3 個封包循環了至少數千次仍存活。TTL 遞減在正常路徑上是有效的（Phase 2 實測 TTL=59），
    所以循環路徑上走的不是正常的 `ipv4_forward`。這點沒有進一步追（不在今晚範圍，且起因是外部寫入）。

### 【觀察】恢復方式

`stack.sh` **沒有「只起 proxy」的子命令**（只有 `up {ovs|p4}` / `wait` / `status` / `down` / `logs`），
而 `up p4` 會 (a) 互動式等 Enter、(b) 起**第二個 kernel** 打在已被佔用的 :8000。
所以我用 **stack.sh 自己那一行**把 proxy 帶回來（`stack.sh:583-586` 的同一條指令、同樣的 cwd 與 PYTHONPATH），
並把 pid 寫回 `.test_run/pids/p4_proxy.pid`，讓收尾的 `stack.sh down` 仍然管得到它。
（`.test_run/` 在 `.gitignore:21`，寫這裡不算改 repo。）

✅ **恢復完全成功**，而且 kernel **不需要重啟**：proxy 一回來就對 10 台重推 pipeline、重裝路由，
`sw_up=10/10 en=10 edges_up=40/40 paths=12`，四對 host 全部 0% loss。**kernel 自己撐過了 6 分鐘的控制平面真空。**

### 🔴🔴 P1 —— `POST /p4/readopt/{dpid}` 會**清空健康 switch 的整張表、裝 0 條路由、然後回報 success**

這是今晚最重要的產品缺陷，**與 B3 的污染無關**（控制組在乾淨的 s6 上重現）。

**實驗一（s1，readopt 前狀態健康）**：

```
s1 BEFORE: 4 entries   10.0.0.1->OUTPUT:3  10.0.0.2->OUTPUT:1  10.0.0.3->OUTPUT:1  10.0.0.4->OUTPUT:1
POST /p4/readopt/1  ->  HTTP 200  {"status":"success","dpid":1,"clone_session":true,"routes_installed":0}
s1 AFTER:  0 entries
連通性 AFTER: h1->h2 100% loss / h4->h1 100% loss / h1->h4 100% loss / h3->h1 100% loss
```

**不會自癒**：其後 60 秒每 10 秒取樣一次，`s1_entries=0`、`h4->h1=100% packet loss`，**六次全部如此**。
同時 s2/s5/s6 各自仍是 4 條，kernel 卻回報 **`sw up 10 en 10`**（edges 掉到 36/40）——
**twin 說十台交換機全部 up 且 enabled，而 h1 完全不可達。**

**實驗二（控制組：s6，從未被 B3 碰過、從未 power-cycle 過）**：

```
s6 BEFORE: 4 entries [(10.0.0.2,OUTPUT:2) (10.0.0.1,OUTPUT:1) (10.0.0.3,OUTPUT:3) (10.0.0.4,OUTPUT:3)]
POST /p4/readopt/6  ->  HTTP 200  {"status":"success","dpid":6,"clone_session":true,"routes_installed":0}
s6 AFTER:  0 entries
h2->h3 AFTER: 0% packet loss   <- 仍然通
```

**→ 缺陷是通用的，不是 s1 專屬。** 差別只在**後果**：
- readopt **邊緣交換機**（s1–s4，底下掛 host）＝ **那台 host 永久失聯**，因為 host 只有這一個接入點，沒有替代路徑。
- readopt **匯聚／核心交換機**（s5–s10）＝ fabric 繞過它，**表面上什麼事都沒有**，缺陷完全隱形。

**為什麼危險加倍**：3a312e3 的 502 訊息**明確叫操作員執行這個指令來復原**——
`P4PowerStrategy.cpp:120-121`：「Recover by retrying the readopt directly: POST http://<proxy>/p4/readopt/<dpid>」。
**照著做會把一台健康的邊緣交換機變成黑洞。**（Phase 4 沒遇到 502，所以那條路徑今晚才第一次被人真的走。）

**【推論】機制（程式碼佐證，未做 instrumentation，標為推論）**
`readopt_switch` 的順序是自我拆台的（`topology_manager.py:813`）：先推 pipeline config（**清空表**），
最後才 `routes = self.install_initial_routes(only_dpid=dpid)`。而 `install_initial_routes`（`:665-717`）
**第一件事就是 `self.calculate_all_paths(self.reroutable_down_endpoints())` 重算路徑**，然後只對
`src == only_dpid` 的路徑寫規則。剛被清空的那台此刻在 proxy 眼裡鏈路是 down 的
（readopt 後 kernel 立刻看到 `edges up 36/40`，正好是 s1 的 2 條鏈路 ×2 向），
**於是重算出來的路徑集合裡沒有任何一條的 src 是它**，迴圈一條都沒進去 → `installed = 0` → 回傳
`routes_installed: 0` **並且照樣宣告 `"status":"success"`**。
Phase 4b 的 s10 也是 `routes_installed: 0`，**只是它靠 power-cycle 造成的鏈路重新發現補回了規則**
（那條路徑會呼叫無 `only_dpid` 的 `install_initial_routes()`），所以看起來沒事——
**同一個 bug，被另一條路徑掩蓋掉了。**

**建議（交 Adam 裁決）**：(a) `routes_installed == 0` 不該回 `"status":"success"`；
(b) readopt 應在重算路徑**之前**先把該 switch 的鏈路視為可用，或改呼叫不帶 `only_dpid` 的完整安裝；
(c) 在 (a)(b) 修好之前，3a312e3 那段「直接打 readopt 復原」的指示應該加警告。

**復原方式（實測有效）**：重啟 proxy → 對 10 台重推 pipeline + 重裝路由。實測 s1/s2/s5/s6/s9/s10 全部回到 4 條、
四對 host 全部 0% loss、`edges up 40/40`。
---

## Phase 6 — 收尾與基線比對

**時間**：2026-08-12 23:22:15。`tools/test_workflow/stack.sh down` 輸出：

```
Shutting down (reverse order)
  stopped kernel
  stopped p4_proxy
Mininet was started manually; clean it up with:  sudo mn -c
done
```

✅ 乾淨收尾，**沒有** port 殘留警告（`down` 會檢查 :8000/:8080/:8081 的擁有者，全部安靜）。

### 【觀察】Mininet 完好（最重要的一條）

```
178866 / 178867 sudo python3 .../p4_testbed_topo.py
178868 python3 .../p4_testbed_topo.py
178914 mininet:h1   178916 mininet:h2   178918 mininet:h3   178920 mininet:h4
```

✅ **topo pid 178866 與 4 個 host 全部還在，整輪沒有碰過 Mininet。** 從未執行 `mn -c`、
未 kill 任何 mininet/bmv2 process（唯二被 kill 的是 proxy，且都用確切 pid、**沒有用過 `pkill`**）、
未對 178866 送過 stdin、未執行過任何 `ifconfig`。

### 【觀察】bmv2 基線比對

```
baseline count: 10 | now count: 10
still alive from baseline : [179110 ... 179118]      (s1–s9，九台原班)
GONE since baseline       : [179119]                 (原本的 s10，被 power off 殺掉)
NEW  since baseline       : [198120]                 (power on 重開的 s10)
```

### 🔶【觀察】orphan 確認：**198120 是 orphan，其餘九台不是**

用 process 譜系判定，不是用數量：

| | 原班 switch（例：179118 / s9） | **198120 / s10** |
|---|---|---|
| ppid | 178948（`bash --norc ... mininet:s9`） | **5919 = `systemd --user`（已被 reparent）** |
| pgid / sid | 178948 / 178948 —— **在 Mininet 的 session 內** | **198120 / 198120 —— 自己的 session** |
| stat | `Sl+` | `Ssl`（s = session leader） |
| 起始 | 22:27:43（Mininet 起的） | 22:55:18（power helper 起的） |

**【推論】** 原班九台在 Mininet 的 session 裡，Adam `exit` Mininet 時會跟著結束；
**198120 用 setsid 脫離，會活過 Mininet exit，也活過 `mn -c`** ——與記憶中
「helper 開的 bmv2 活過 `mn -c`」完全吻合，這次拿到了 ppid/sid 級別的證據。

manifest `/tmp/ndtwin_p4_switches.json` 已同步更新（`s10.pid = 198120`），**所以 helper 現在還定址得到它**。

### 【觀察】其他收尾檢查

- `ss -ltn`（8000/8080/8081）：**全部無 listener** ✅
- netem 殘留：s1–s10 的 eth1–eth4 全掃，**零殘留** ✅
- **repo 未被我改動**：`git status --porcelain` 與 session 開場**逐字相同**
  （`M .vscode/settings.json` + 那 6 個未追蹤的 patch/diff 檔，都不是我產生的），
  HEAD 仍是 `5d53cf0`。我只寫過：本報告檔、`/tmp` scratchpad、以及 `.test_run/`（在 `.gitignore:21`）底下的
  log/pid 執行期產物。

---

## 給 Adam 的早晨清單

1. **先處理 orphan：`198120`（s10 的 bmv2）。** 它不在 Mininet 的 session 裡，`exit` 和 `mn -c` 都殺不掉。
   兩個選擇，**建議 (a)**：
   - **(a) 趁 `/tmp/ndtwin_p4_switches.json` 還在**：`sudo -n /usr/local/sbin/ndtwin-p4-power off s10`
     —— helper 會用 manifest 的 pid 並在送 SIGTERM 前核對 `/proc`（comm + cmdline），比 kill 安全。
   - **(b) manifest 已被刪掉的話**：`sudo kill 198120`（先 `ps -o pid,sid,args -p 198120` 確認是它）。
   - ⚠️ **不要用 runbook「收尾」寫的 `pkill -x simple_switch_g`**：它按名稱殺，會連別的 agent 的
     測試 fixture（`/tmp/ndtwin_p4helper_*/pysw/simple_switch_grpc`）一起掃掉，而且掩蓋掉「哪一台是 orphan」。
2. **退出 Mininet 後複查**：`pgrep -ax simple_switch_g` 應為**空**。若還有殘留，比對本檔 Phase 0 的
   基線 pid 表（179110–179119）與 Phase 6 的譜系判定法（看 ppid/sid，不要只看數量）。
3. **讀 Phase 5 的 `readopt` 那一節** —— 今晚唯一的真缺陷，而且 3a312e3 的錯誤訊息正在教操作員執行它。
4. **s1 污染脈絡**：B3 的 `LiveSwitchTest` 在 **23:02:40–23:09:02** 那個窗內直連寫過 s1。
   我在 23:20 重啟 proxy 後 s1 已回到 canonical 4 條規則、連通性正常，**但那段時間的 s1 觀察值不可採信**。
5. **runbook 要改的地方**（P1/P2 各處，細節在對應 phase）：§5c 的 IP 格式、§6 netem 範例寫死 s5↔s10、
   §6b 的「約 11 秒」、§6f 的「12→9」、§5b 兩處行號、文末重複的 §5b 區塊。
