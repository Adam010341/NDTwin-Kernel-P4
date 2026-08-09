# 端到端數值差分 runbook（2026-08-09）

## 0. 這個檢查要證明什麼、證明不了什麼

### 證明什麼

kernel 從 sFlow 取樣到 link usage 數字的**四層推導**都至少「方向正確」：
1. OVS 的 sFlow datagram 有被收到（UDP socket 層）
2. 手寫的固定字組位移解析器能正確取出 flow sample（agent IP、input port、frame length、sampling rate）
3. 速率估計公式 `frameLength × samplingRate × 8` 在 1 秒間隔內累積後轉成 bps 的邏輯無誤
4. 速率被歸屬到正確的 switch-to-switch 邊（`getAgentKeyFromTheOtherSide` 的 dst→src 反查）

檢查方法是：在同一條實體鏈路上，比較 kernel 的**估計速率**（來自 sFlow 取樣）與 OVS 自己的 **per-port tx_bytes 計數器**（來自硬體/核心計數，不經過取樣）。

### 證明不了什麼

- **絕對精確度**：sFlow 取樣率 256 造成 ±X% 的相對誤差（見 §1 容差推導）。這個檢查只能說「在容差內一致」，不能說「精確相等」。
- **per-flow 速率**：只檢查 per-link 的聚合速率，不檢查個別 flow 的速率（`get_detected_flow_data` 是另一個 endpoint，非本 runbook 範圍）。
- **反向路徑**：UDP iperf 沒有回程流量，只檢查單向 edge（s1→s5 或 s1→s6）。
- **非 switch-to-switch edge**：`getAvgLinkUsage` 只計 switch-to-switch 邊。host-to-switch 邊不在此檢查範圍內，因為 sFlow agent 是 switch，host 沒有 sFlow。

---

## 1. 容差推導（算式，不是憑感覺的百分比）

### 1.1 取樣模型

OVS sFlow 設定 `sampling=256`。每個封包獨立以機率 p = 1/256 被取樣。
在 T 秒內，若一條鏈路上通過 N 個封包，被取樣的封包數 K ~ Binomial(N, 1/256)。

kernel 的估計邏輯（`FlowLinkUsageCollector.cpp` line 1364–1369 與 1718–1721）：

```
每收到一個 flow sample:
    m_counterReports[{agentIp, port}].inputByteCountOnALinkMultiplySampingRate
        += frameLength × samplingRate

每秒結算一次:
    estimated_bps = counter.inputByteCountOnALinkMultiplySampingRate × 8
    // 8 是 bytes→bits；除以 1 秒隱含在每秒重置中
    // 所以 estimated_bps = Σ(frameLength_i) × 256 × 8  bps
```

若取樣 K 個封包、每個大小 S bytes，則：
- 估計總 bytes = K × S × 256
- 估計 bps = K × S × 256 × 8 / T

實際總 bytes = N × S
實際 bps = N × S × 8 / T = R

### 1.2 變異數推導

- E[K] = N × p = N/256
- Var[K] = N × p × (1-p) = N/256 × 255/256 ≈ N/256（p 很小時）
- E[估計 bps] = E[K] × S × 256 × 8 / T = (N/256) × S × 256 × 8 / T = N × S × 8 / T = R ✓（不偏估計）
- Var[估計 bps] = (S × 256 × 8 / T)² × Var[K] = (2048 × S / T)² × N/256
  = 2048² × S² × N / (256 × T²)
  = 2048 × 8 × S² × N / T²  ... wait let me re-derive cleanly

Let estimated_bps = (K × S × 256 × 8) / T

Var[estimated_bps] = (S × 256 × 8 / T)² × Var[K]
  = (2048 × S / T)² × (N/256)
  = 2048² × S² × N / (256 × T²)
  = (2048² / 256) × S² × N / T²
  = 16384 × S² × N / T²

代入 N = R × T / (8 × S)：  （R 用 bps，S 用 bytes）
Var[estimated_bps] = 16384 × S² × (R × T / (8 × S)) / T²
  = 16384 × S × R × T / (8 × T²)
  = 2048 × S × R / T

StdDev[estimated_bps] = sqrt(2048 × S × R / T)

相對標準差（coefficient of variation）：
CV = StdDev / R = sqrt(2048 × S × R / T) / R = sqrt(2048 × S / (R × T))

### 1.3 數值代入

假設：
- 封包大小 S = 1500 bytes（iperf UDP 預設 payload 1472 + 8 UDP + 20 IP = 1500，對齊 Ethernet MTU）
- 流量 R = 100 Mbps = 100,000,000 bps
- 持續時間 T = 30 秒

封包速率 = R / (S × 8) = 100,000,000 / 12,000 ≈ 8,333 pps
總封包數 N = 8,333 × 30 ≈ 250,000
期望取樣數 = N / 256 ≈ 976
每 1 秒期望取樣數 ≈ 32.5

**kernel 每秒更新一次** `linkBandwidthUsage`。每個 1 秒窗口的相對標準差：
CV₁ = sqrt(2048 × 1500 / (100,000,000 × 1)) = sqrt(3,072,000 / 100,000,000) = sqrt(0.03072) ≈ 17.5%

如果我們**每 2 秒取一次 kernel 值、共取 15 次（覆蓋 30 秒）然後平均**，
有效的獨立樣本數 ≈ 15（每秒的取樣事件獨立）。
平均值的相對標準差 = CV₁ / sqrt(15) ≈ 17.5% / 3.87 ≈ 4.5%

用 95% 信心區間（±1.96σ）：
相對誤差範圍 ≈ ±1.96 × 4.5% ≈ ±8.9%

再加安全邊際（sFlow 解析誤差、時鐘誤差、背景流量、header 大小變異）→ 設 **±15%**。

### 1.4 若達不到此容差怎麼辦

如果 iperf 打不到 100 Mbps（例如 CPU 不夠、虛擬網路瓶頸），則實際速率 R 更低，CV 更大。
補救：延長時間 T。CV ∝ 1/sqrt(R × T)。若 R 只有 10 Mbps，則需 T = 300 秒才能達到相同精確度。
→ 這種情況下，本 runbook 的數值檢查**不可靠**，應退化成 §3.6 的方向性檢查。

### 1.5 結論

| 參數 | 值 |
|---|---|
| 取樣率 | 1/256 |
| 測試流量 | UDP 100 Mbps，1500-byte 封包 |
| 持續時間 | 30 秒 |
| 取樣間隔 | 每 2 秒取一次 kernel 值（15 次） |
| 容差 | **±15%** |
| 信心 | 約 95%（基於二項分佈常態近似，15 次獨立 1 秒窗口平均） |

**通過條件**：kernel 的平均估計速率落在 OVS 實測速率的 ±15% 內。
**失敗**：超出 ±15% 且 kernel log 無 sFlow drop 警告 → 四層推導中至少一層有 bug（見 §4 診斷）。

---

## 2. 拓撲選擇

### 2.1 選擇的 host pair

| | Host | IP | 掛在哪台 switch | switch dpid | host port on switch |
|---|---|---|---|---|---|
| 發送端 | **h1** | 10.0.0.1 | s1 | 1 | port 3 |
| 接收端 | **h97** | 10.0.0.97 | s4 | 4 | port 3 |

來源：`testbed_topo.py` lines 71–90（h1–h32 掛 s1 ports 3–34；h97–h128 掛 s4 ports 3–34）。

### 2.2 為什麼選這兩台

1. **不同 switch**：h1 在 s1 (dpid 1)，h97 在 s4 (dpid 4)。流量必須穿過 switch fabric。
2. **不同 pod**：s1 在左半（經 s5/s6 上核心），s4 在右半（經 s7/s8 上核心）。路徑至少經過 4 條 switch-to-switch 邊。
3. **路徑確定性**：雖然有 ECMP（s1 有兩個 uplink port 1→s5、2→s6），但對單一個 5-tuple flow，OVS 的 hash 會固定選一條路。我們不需要預測哪條，而是**監控兩個可能的第一跳 edge，總和使用量**。

### 2.3 預期經過的 switch-to-switch 邊

從 h1 到 h97 的 IP 封包路徑（單向）：

```
h1 → s1 (port 3 ingress)
s1 → s5 (port 1 egress) 或 s1 → s6 (port 2 egress)    ← 第一跳，ECMP 二選一
s5/s6 → s9 (port 3 egress) 或 s5/s6 → s10 (port 4 egress)  ← 第二跳
s9/s10 → s7 (port 3 egress) 或 s9/s10 → s8 (port 4 egress)  ← 第三跳
s7/s8 → s4 (port 1 或 2 ingress, 對應 s7/s8 port 2/1 或 2/2)
s4 → h97 (port 3 egress)
```

### 2.4 我們監控哪條 edge

我們**只監控第一跳**（s1→s5 或 s1→s6）。理由：
- 第一跳最靠近發送端，流量最集中（還未分散到多條路徑）
- s1 的 OVS port counters（tx_bytes on port 1 & 2）直接對應這兩條 edge
- 只需要在 s1 上執行 `ovs-ofctl dump-ports`，不需要跨多台 switch 收集

### 2.5 對應的 edge 定義（從 topology JSON 驗證）

**s1→s5**（topology JSON line 1856–1867）：
- src_dpid=1, src_interface=1, src_ip=192.168.123.11
- dst_dpid=5, dst_interface=1, dst_ip=192.168.123.15
- link_bandwidth_bps=1,000,000,000 (1 Gbps)

**s1→s6**（topology JSON line 1882–1892）：
- src_dpid=1, src_interface=2, src_ip=192.168.123.11
- dst_dpid=6, dst_interface=1, dst_ip=192.168.123.16
- link_bandwidth_bps=1,000,000,000 (1 Gbps)

### 2.6 sFlow 取樣點與 edge 歸屬的對應關係

kernel 的 edge 歸屬邏輯（`FlowLinkUsageCollector.cpp` line 1364–1369 + 1711–1719）：
1. sFlow sample 從 s5 發出，agentIp=192.168.123.15，inputPort=1（封包從 s1 進入 s5 的 port 1）
2. Counter key = {192.168.123.15, 1}
3. `getAgentKeyFromTheOtherSide` 在拓撲圖中找 dst_ip=192.168.123.15 且 dst_interface=1 的 edge
   → 找到 edge s1→s5（src_ip=192.168.123.11, src_interface=1）
   → 返回 {192.168.123.11, 1}
4. `updateLinkInfoLeftLinkBandwidth({192.168.123.11, 1}, estimatedIn)` 更新 edge s1→s5 的 `linkBandwidthUsage`

所以 kernel 對 edge s1→s5 的估計 = s5 的 sFlow agent 看到從 port 1 進來的流量 × 256 × 8 bps。

OVS 的 s1 port 1 tx_bytes = s1 從 port 1 送出的 bytes。
這兩者測量**同一條實體鏈路上的同一方向流量**（s1→s5），可以對比。

---

## 3. 步驟

### 3.1 前置確認：iperf 可用性與 host PID

⚠️ **執行前必須先完成 §6 的資訊收集。** 以下步驟假設你已經知道：
- h1 的 PID（記為 `<H1_PID>`）
- h97 的 PID（記為 `<H97_PID>`）
- iperf 或 iperf3 的可用性與路徑
- s1 的 `dump-ports` 輸出格式（確認 port 1、port 2 存在且為 uplink）

以下命令用 `<H1_PID>`、`<H97_PID>`、`<IPERF>` 作為佔位符，
執行時取代為 §6 收集到的實際值。

---

### 3.2 步驟總覽

```
3.3  量測前 baseline：OVS port counters + kernel edge snapshot
3.4  啟動 iperf server（在 h97 上）
3.5  啟動 iperf client + 同時開始 polling kernel（30 秒）
3.6  量測後 snapshot：OVS port counters
3.7  計算與比對
3.8  方向性補充檢查（使用 get_average_link_usage）
```

---

### 3.3 量測前 baseline：OVS port counters + kernel edge snapshot

#### 步驟 3.3.1：記錄 s1 的 port counters（baseline）

```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-ports s1
```

**看什麼**：輸出中 port 1 和 port 2 的 `tx bytes=` 值。
**記錄**：記下這兩個值為 `TX1_BEFORE` 和 `TX2_BEFORE`。
**注意**：OVS 的 `dump-ports` 輸出格式是每 port 一個區塊，格式大致為：
```
port  1: rx bytes=... tx bytes=... rx pkts=... tx pkts=...
```
確切格式見 §6 的範例輸出。

**通過條件**：能成功列出 ports，port 1 和 port 2 都存在且有 tx bytes 欄位。
**失敗代表什麼**：port 不存在 → 拓撲可能已變更（不應該發生）；無法執行 → Mininet namespace 問題。

#### 步驟 3.3.2：記錄 kernel 的 edge 狀態（baseline）

```bash
curl -s http://localhost:8000/ndt/get_graph_data | python3 -c "
import json, sys
g = json.load(sys.stdin)
for e in g['edges']:
    if e['src_dpid'] == 1 and e['src_interface'] in [1,2] and e['dst_dpid'] in [5,6]:
        print(f\"s1->s{e['dst_dpid']} (if{e['src_interface']}): usage={e['link_bandwidth_usage_bps']} bps, util={e['link_bandwidth_utilization_percent']}%, up={e['is_up']}\")
"
```

**看什麼**：四條 edge 的目前 `link_bandwidth_usage_bps`（s1→s5, s1→s6, s5→s1, s6→s1）。
**記錄**：基線值，預期接近 0（無流量時）。
**通過條件**：四條 edge 都存在，`is_up=true`，usage 值合理（0 或很小的背景值）。
**失敗代表什麼**：edge 不存在 → kernel 的拓撲載入有問題。`is_up=false` → sFlow 沒收到或 switch 狀態異常。

---

### 3.4 啟動 iperf server（在 h97 上）

```bash
sudo -n mnexec -a <H97_PID> <IPERF> -s -u -p 5201 &
```

（如果 `<IPERF>` 是 `iperf3`，則用 `iperf3 -s -p 5201`；`iperf3` 不區分 TCP/UDP 的 server flag，client 端指定 `-u`）

**看什麼**：server 啟動訊息（通常 "Server listening on UDP port 5201"）。
**通過條件**：server 成功啟動，沒有 "bind failed" 或 "address in use"。
**失敗代表什麼**：port 被佔用 → 換 port（如 5202）。iperf 不存在 → 見 §6。

---

### 3.5 執行流量測試 + kernel polling（核心步驟）

#### 步驟 3.5.1：準備 polling 腳本

建立一個小 Python 腳本 `/tmp/poll_kernel.py`（放在 /tmp 因為不能寫到 repo 以外的地方？可以寫 /tmp）：

```bash
cat > /tmp/poll_kernel.py << 'PYEOF'
import subprocess, json, time, sys

url = "http://localhost:8000/ndt/get_graph_data"
duration = int(sys.argv[1]) if len(sys.argv) > 1 else 30
interval = 2  # seconds between polls

print(f"Polling every {interval}s for {duration}s...")
start = time.time()
samples = []
while time.time() - start < duration:
    try:
        r = subprocess.run(["curl", "-s", url], capture_output=True, text=True, timeout=5)
        g = json.loads(r.stdout)
        for e in g['edges']:
            if e['src_dpid'] == 1 and e['src_interface'] in [1,2] and e['dst_dpid'] in [5,6]:
                samples.append({
                    'ts': time.time(),
                    'edge': f"s1->s{e['dst_dpid']}",
                    'usage_bps': e['link_bandwidth_usage_bps']
                })
    except Exception as ex:
        print(f"Poll error: {ex}", file=sys.stderr)
    time.sleep(interval)

# Print summary
print("\n--- Samples ---")
for s in samples:
    print(f"{s['ts']:.1f} {s['edge']} {s['usage_bps']}")

# Compute averages per edge
from collections import defaultdict
edge_sums = defaultdict(lambda: {'sum': 0.0, 'n': 0})
for s in samples:
    k = s['edge']
    edge_sums[k]['sum'] += s['usage_bps']
    edge_sums[k]['n'] += 1

print("\n--- Averages ---")
for k, v in sorted(edge_sums.items()):
    avg = v['sum'] / v['n'] if v['n'] else 0
    print(f"{k}: avg={avg:.0f} bps ({v['n']} samples)")

# Total for both uplinks
total_avg = sum(v['sum'] for v in edge_sums.values()) / max(sum(v['n'] for v in edge_sums.values()), 1)
print(f"\nTOTAL s1 uplink avg (kernel estimate): {total_avg:.0f} bps")
print(f"TOTAL_AVG {total_avg:.0f}")  # easy to grep
PYEOF
```

#### 步驟 3.5.2：同時啟動 iperf client 與 kernel polling

使用兩個 terminal 或 background jobs：

**Terminal A**：先啟動 polling（讓它先跑 2 秒抓 baseline）
```bash
python3 /tmp/poll_kernel.py 34 &   # 34 = 30s traffic + 2s before + 2s after
POLL_PID=$!
sleep 2   # 讓 polling 先取一次 baseline
```

**Terminal B**：啟動 iperf client（在 h1 的 namespace 中）
```bash
sudo -n mnexec -a <H1_PID> <IPERF> -c 10.0.0.97 -u -p 5201 -b 100M -t 30
```

**iperf 參數說明**：
- `-c 10.0.0.97`：連到 h97
- `-u`：UDP
- `-b 100M`：目標速率 100 Mbps
- `-t 30`：跑 30 秒
- 如果是 `iperf3`：`iperf3 -c 10.0.0.97 -u -b 100M -t 30 -p 5201`

等 iperf 結束後，等 polling 也結束（最多 4 秒）：
```bash
wait $POLL_PID
```

**看什麼**：
- iperf client 輸出：實際傳輸速率、封包數、lost 數。**記錄實際傳輸速率**（如 `91.5 Mbits/sec`）。
- iperf server 輸出：收到的速率、loss、jitter。
- polling 輸出：每 2 秒一次的 edge usage 值，以及最後的 `TOTAL_AVG` 值。

**通過條件（初步）**：
- iperf 能跑完 30 秒，server 有收到封包
- iperf 報告的 loss < 1%（loss 太高會影響 kernel 的估計，因為 sFlow 取樣到的封包數變少）
- polling 有回傳合法數值（不是全部 0 — 如果全部 0 見 §3.8 方向性檢查）

**失敗代表什麼**：
- iperf "connection refused" → server 沒起來或 port 不對
- iperf "no route to host" → h1 和 h97 之間不通（Ryu 沒下發規則？）
- polling 全部回 0 → sFlow 沒在採樣或 kernel 沒在收（見 §4 診斷）
- polling 回傳錯誤（HTTP 非 200）→ kernel 掛了

---

### 3.6 量測後 snapshot：OVS port counters

iperf 結束後立刻執行：

```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-ports s1
```

**記錄**：port 1 和 port 2 的 `tx bytes=` 值為 `TX1_AFTER` 和 `TX2_AFTER`。

---

### 3.7 計算與比對

用 Python 計算（直接在 terminal 執行）：

```bash
python3 << 'PYEOF'
# Paste the BEFORE and AFTER values here
TX1_BEFORE = 0   # <-- replace
TX1_AFTER = 0    # <-- replace
TX2_BEFORE = 0   # <-- replace
TX2_AFTER = 0    # <-- replace

# iperf duration (should match -t value)
T = 30.0

# Compute actual rates
actual_bytes_1 = TX1_AFTER - TX1_BEFORE
actual_bytes_2 = TX2_AFTER - TX2_BEFORE
actual_total_bytes = actual_bytes_1 + actual_bytes_2
actual_bps = actual_total_bytes * 8 / T

print(f"Port 1: {actual_bytes_1} bytes in {T}s = {actual_bytes_1 * 8 / T:.0f} bps")
print(f"Port 2: {actual_bytes_2} bytes in {T}s = {actual_bytes_2 * 8 / T:.0f} bps")
print(f"Total:  {actual_total_bytes} bytes in {T}s = {actual_bps:.0f} bps")

# Kernel estimate from polling (TOTAL_AVG line from step 3.5)
kernel_est = 0   # <-- paste TOTAL_AVG value here

if actual_bps > 0:
    ratio = kernel_est / actual_bps
    pct_diff = (kernel_est - actual_bps) / actual_bps * 100
    print(f"\nKernel estimate: {kernel_est:.0f} bps")
    print(f"OVS actual:      {actual_bps:.0f} bps")
    print(f"Ratio:           {ratio:.3f}")
    print(f"Difference:      {pct_diff:+.1f}%")
    
    if abs(pct_diff) <= 15.0:
        print("\n✓ PASS: within ±15% tolerance")
    else:
        print(f"\n✗ FAIL: {abs(pct_diff):.1f}% > 15% tolerance")
        print("  → See §4 for diagnosis")
else:
    print("\n✗ FAIL: no traffic detected on s1 uplink ports")
    print("  → Check iperf output; flow may have taken unexpected path")
PYEOF
```

**通過條件**：
- `actual_bps > 0`（有流量）
- `|pct_diff| ≤ 15%`

**失敗代表什麼**：
- 超出 ±15% 且 kernel 低估（`ratio < 0.85`）：sFlow 取樣不足、datagram 被丟棄、或解析錯誤導致漏計 bytes。**先檢查 kernel log 有沒有 `sFlow samples lost` 的 WARN**（見 §4.1）。
- 超出 ±15% 且 kernel 高估（`ratio > 1.15`）：可能有 double-counting（同一個 flow sample 被計入多個 edge）或 samplingRate 被誤用。
- `actual_bps == 0` 但 iperf 有送：流量沒經過 s1 port 1 或 2。可能 s1 的 flow rule 把封包送到其他 port 或 drop 了。用 `ovs-ofctl dump-flows s1` 檢查。

---

### 3.8 方向性補充檢查（使用 get_average_link_usage）

這個檢查比 §3.7 粗糙，但只需要一個 HTTP request，適合快速確認「完全沒流量」vs「有流量」：

#### 步驟 3.8.1：無流量時的 baseline

在沒有任何 iperf 時：
```bash
curl -s http://localhost:8000/ndt/get_average_link_usage
```

**記錄**：`avg_link_usage` 值（預期 0.0 或很小的值）。

#### 步驟 3.8.2：有流量時的值

在 iperf 執行期間（或剛結束後 1 秒內）：
```bash
curl -s http://localhost:8000/ndt/get_average_link_usage
```

**通過條件**：有流量時的 `avg_link_usage` **明顯大於**無流量時的值（例如從 0.0 → 0.5 或更高）。
**失敗代表什麼**：兩個值相同 → kernel 完全沒看到流量。問題在 sFlow 取樣或接收層（§4.1/§4.2）。

**注意**：這個檢查**不做數值比對**，只做方向確認。它不能取代 §3.7。

---

### 3.9 清理

停止 iperf server（如果還在跑）：
```bash
sudo -n mnexec -a <H97_PID> pkill -f '<IPERF>.*-s'
# 或更安全的方式：找到 iperf server 的 PID 後 kill
```

刪除暫存腳本（可選）：
```bash
rm /tmp/poll_kernel.py
```

---

## 4. 如果對不上，怎麼分辨是哪一層錯的

四層推導中任何一層都可能出錯。以下是每層的**獨立驗證方法**與**故障特徵**。

### 4.0 決策樹（快速導航）

```
數值對不上
├─ kernel 報 0，OVS 有流量
│  ├─ sFlow datagram 有到 socket 嗎？            → §4.1
│  ├─ sFlow 解析有報 malformed datagram 嗎？      → §4.2
│  └─ CounterReports 有被寫入嗎？                  → §4.3
├─ kernel 報非 0，但偏差 >15%
│  ├─ kernel log 有 "sFlow samples lost" WARN 嗎？ → §4.1
│  ├─ 是同一個 edge 還是多個 edge 都有值？         → §4.4
│  └─ 每秒的值抖動很大（CV > 20%）嗎？              → §4.1（取樣不足）
└─ kernel 報非 0 但歸屬到錯的 edge                 → §4.4
```

---

### 4.1 第一層：sFlow 取樣與接收（UDP socket）

**故障特徵**：kernel 報的使用量為 0 或明顯偏低，但 OVS port counter 顯示有流量。

**獨立驗證方法**：

#### A. 檢查 sFlow datagram 是否有送到 socket

kernel 的 sFlow collector 在 UDP port 6343 監聽。可以用 `ss` 或 `netstat` 看 socket 的接收隊列：
```bash
ss -uln 'sport = 6343'
```
或檢查 kernel log 中的 sFlow 接收統計。kernel 每秒會 log 一次 ingest 統計（TRACE level；第一條是 INFO）：
```bash
# 查看 kernel 的 log（假設輸出到 stderr 或檔案）
# 找 "sFlow ingest healthy" 或 "sFlow samples lost"
```

如果看不到任何 sFlow 接收 log → kernel 的 socket 沒收到 datagram。

#### B. 用 tcpdump 驗證 sFlow datagram 在線上

```bash
sudo -n tcpdump -i lo -nn 'udp port 6343' -c 5
```
（sFlow collector IP 是 192.168.123.1，掛在 lo 上，見 `testbed_topo.py` line 19-20 與 175）

**通過條件**：5 秒內看到 sFlow datagram（UDP packet to 192.168.123.1:6343）。
**失敗**：完全沒有 → OVS sFlow 配置遺失或 OVS 沒在送。檢查：
```bash
sudo -n mnexec -a 2910932 ovs-vsctl list sflow
```

#### C. 檢查 kernel log 的 drop 計數器

kernel 在 `calAvgFlowSendingRatesPeriodically` 中每秒檢查 socket overflow 和 application drop（`FlowLinkUsageCollector.cpp` lines 1741–1757）。如果成長，會印 WARN。
搜尋 kernel log 中的：
```
sFlow samples lost in the last second
```

**如果看到這個 WARN**：kernel 的估計會**低估**（漏了樣本）。這是環境問題（socket buffer 太小、CPU 太忙），不是邏輯 bug。重跑測試時降低流量速率或增大 socket buffer。

**如果看不到 WARN 但還是低估 >15%**：往下到 §4.2。

---

### 4.2 第二層：sFlow datagram 解析（固定字組位移）

**故障特徵**：sFlow datagram 有收到，但解析出來的 bytes 不對（漏 field、錯位、endian 錯誤）。

**獨立驗證方法**：

#### A. 搜尋 malformed datagram 警告

kernel 的解析器會 log malformed datagram：
```bash
# 搜尋 kernel log 中的關鍵字
grep -i 'malformed\|TruncatedDatagram\|discarding' <kernel_log>
```

**如果出現**：說明某些 datagram 被丟棄。記錄出現頻率。如果每個 datagram 都被丟棄 → 解析器與 OVS 的 sFlow 格式不匹配（例如 OVS 版本更新改變了 flow sample 的內部結構）。

#### B. 手動檢查 sFlow 的 frameLength 與 OVS port counter 的關係

`sFlow` datagram 中的 flow sample 包含 `frameLength`（取樣封包的大小）。kernel 用 `frameLength * samplingRate` 來估計總 bytes。

**驗證**：可以用 `sflowtool`（如果安裝）來解碼 sFlow datagram 並檢查 frameLength：
```bash
sudo -n tcpdump -i lo -nn 'udp port 6343' -w /tmp/sflow.pcap -c 50 &
# 等幾秒然後
kill %1
# 用 sflowtool 或 wireshark 分析
```
（`sflowtool` 需要另外安裝，如果沒有則跳過此步驟）

#### C. 比對不同層級的計數器

如果 kernel 的 `get_detected_flow_data` 有回傳個別 flow 的 estimated rate，可以跟 iperf 自報的 rate 比對（但 flow rate 有 per-hop 平均的問題，不如 link usage 直接）。

**通過/失敗判斷**：
- 如果 kernel log 無 malformed 警告，且 sFlow datagram 有被 tcpdump 看到
- 但 link usage 為 0
→ 問題在第三層（速率計算）或第四層（edge 歸屬），繼續往下。

---

### 4.3 第三層：速率計算（`frameLength × samplingRate × 8`）

**故障特徵**：sFlow 有解析，`m_counterReports` 有累積（可從 log 的 TRACE 訊息看到），但最終 `linkBandwidthUsage` 不對。

**獨立驗證方法**：

#### A. 檢查採樣率是否被正確讀取

kernel 從 sFlow datagram 中讀取 `samplingRate` 欄位（line 1133 或 1213，取決於 sampleType）。OVS 配置 `sampling=256`。如果解析器讀錯 offset，`samplingRate` 值可能是垃圾。

**檢查**：在 kernel log 中搜尋 TRACE 訊息（若 log level 夠低）：
```
Flow Sample Recieve Src Ip ... Dst Ip ...
```
這行不會直接印 samplingRate，但可以在更早的 log 中找到。

**更直接的方法**：如果 kernel 高估了約 2 倍或 256 倍 → samplingRate 可能被讀成 512 或 1。如果低估了約 256 倍 → samplingRate 可能被讀成 1 或 0。

#### B. 手算驗證

從 kernel log 的 TRACE 訊息中，可以找到每個 flow sample 被處理後的累積。但這需要開啟 TRACE log level，實務上不太可行。

替代方案：使用 Python 腳本模擬 kernel 的計算：
```python
# 假設 iperf 30 秒送了 actual_bps = 95 Mbps
# 封包大小約 1500 bytes
# 每秒約 95e6 / (1500*8) ≈ 7917 封包
# 期望取樣數：7917/256 ≈ 31 個/秒
# kernel 的估計公式：sum(frameLength_i) * 256 * 8 bps (每秒)
# 如果每秒正好取到 31 個 1500-byte 封包：
# estimate = 31 * 1500 * 256 * 8 = 95,232,000 bps ≈ 95.2 Mbps ✓
```

**故障判斷**：
- 如果 kernel 的估計是 OVS 實測的 **~1/256** → `samplingRate` 被當成 1 使用（沒乘 sampling rate）
- 如果 kernel 的估計是 OVS 實測的 **~256 倍** → 乘了兩次 sampling rate（`frameLength * 256 * 256` 之類）
- 如果 kernel 的估計是 OVS 實測的 **~8 倍或 ~1/8** → bit/byte 混淆（`×8` 被省略或多乘）

#### C. 檢查 reset 邏輯

`m_counterReports` 的值每秒被 reset 為 0（line 1721）。如果 reset 沒發生（例如因為時鐘或 thread 問題），`linkBandwidthUsage` 會累積而不重置，造成高估且持續成長。這可以從 polling 的數值看出：如果數值每秒都在增加而不是圍繞一個穩定值擺動 → reset 失敗。

---

### 4.4 第四層：邊歸屬（`getAgentKeyFromTheOtherSide`）

**故障特徵**：總量大致正確，但歸屬到**錯的 edge**，或**漏歸屬**（某個 edge 該有值但為 0，另一個不該有值但非 0）。

**獨立驗證方法**：

#### A. 比對 s1 的兩個 uplink port 與 kernel 的兩個 edge

我們同時監控 s1→s5 和 s1→s6 兩條 edge。如果：
- s1 port 1 tx_bytes 增加很多，但 kernel edge s1→s5 的 usage ≈ 0
- s1 port 2 tx_bytes ≈ 0，但 kernel edge s1→s6 的 usage 很高

→ **edge 歸屬交換了**（sFlow 的 inputPort 跟 topology 的 dst_interface 對應錯誤）。

#### B. 檢查 `lookupOfport` 轉換

在 MININET 模式下，kernel 會呼叫 `lookupOfport(ifIndex)` 把 sFlow 報的 ifIndex 轉成 OpenFlow port number（`FlowLinkUsageCollector.cpp` line 1311–1312）。這個轉換仰賴 `ovs-vsctl` 或 identity mapping。如果轉換表是空的或錯誤，port 對應就會亂掉。

**檢查**：kernel log 中搜尋：
```
identity ifIndex->port mapping
```
或
```
populateIfIndexToOfportMap
```

如果使用了 identity mapping（BMV2 時），但實際上是 OVS（需要 `ovs-vsctl`），則 port 對應會全錯。反之亦然。

**驗證**：從 `testbed_topo.py` 的 `addLink` 呼叫中，s1 port 1 連接 s5。OVS 的 port 號碼應該與 Mininet 指定的 `port1=1` 一致。確認：
```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 show s1
```
看 port 1 是否存在且連接到 s5。

#### C. 檢查 `getAgentKeyFromTheOtherSide` 的搜尋邏輯

`getAgentKeyFromTheOtherSide`（`TopologyAndFlowMonitor.cpp` line 1200–1217）在所有 edge 中線性搜尋 `dstIp == agentIp AND dstInterface == inputPort`。如果有多條 edge 符合（例如 NIC teaming 或重複 IP），會回傳**第一條找到的**（不確定性）。

這個拓撲中，每個 switch IP 與 interface 組合應該是唯一的（每個 switch 每個 port 只有一條 ingress edge）。但如果拓撲 JSON 中有重複定義，edge 歸屬就會不穩定。

**驗證**：搜尋 topology JSON 中是否有兩個 edge 具有相同的 `dst_ip` 和 `dst_interface`：
```bash
python3 -c "
import json
with open('setting/StaticNetworkTopologyMininet_10Switches.json') as f:
    g = json.load(f)
from collections import Counter
keys = [(e['dst_ip'][0], e['dst_interface']) for e in g['edges']]
dupes = [k for k,v in Counter(keys).items() if v > 1]
if dupes:
    print('DUPLICATE dst edges found:')
    for k in dupes:
        print(f'  dst_ip={k[0]}, dst_interface={k[1]}')
else:
    print('All dst (ip, interface) pairs are unique - OK')
"
```

---

### 4.5 綜合診斷流程

```
1. 先看 kernel log 有沒有 "sFlow samples lost" WARN
   ├─ YES → 環境問題（socket buffer），降低流量重跑
   └─ NO  → 往下

2. 看 kernel 報的 edge usage 總和 vs OVS port counter 總和
   ├─ kernel ≪ OVS (ratio < 0.5)
   │  ├─ 檢查是否有 malformed datagram 警告 → §4.2
   │  ├─ 檢查 samplingRate 是否正確讀取 → §4.3
   │  └─ 檢查 m_counterReports reset 是否正常 → §4.3
   ├─ kernel ≈ OVS (0.5 < ratio < 1.5) 但超出 ±15%
   │  └─ 可能是取樣變異（檢查每秒值的抖動）或背景流量干擾
   ├─ kernel ≫ OVS (ratio > 1.5)
   │  └─ 檢查 double-counting 或 samplingRate 重複乘 → §4.3
   └─ kernel 有值但歸屬錯 port
      └─ 檢查 lookupOfport / edge 對應 → §4.4
```

---

## 5. 清理

### 5.1 停止 iperf server

```bash
# 找到 h97 namespace 中的 iperf server 並停止
sudo -n mnexec -a <H97_PID> pkill -f 'iperf' 2>/dev/null || echo "no iperf to kill"
```

### 5.2 確認 kernel 仍健康

```bash
curl -s -w '\n%{http_code}\n' http://localhost:8000/ndt/get_graph_data | head -c 100
```

**通過條件**：HTTP 200，response 是合法 JSON。
**失敗代表什麼**：kernel 在測試期間 crash 了。

### 5.3 檢查 kernel log 有無新的 ERROR

```bash
# 如果有 kernel log 檔案，檢查今天新增的 ERROR
grep -c 'ERROR' <kernel_log>
```

（這一步的具體命令取決於 kernel log 的輸出路徑，見 §6 的確認事項。）

---

## 6. 我需要 Claude 先回報的資訊

在執行 §3 之前，請先執行以下命令並回報結果。這些資訊無法從程式碼靜態推導。

### 6.1 Host PID

取得 h1 和 h97 的 PID（用於 `mnexec -a` 進入 host namespace）：

```bash
# 方法 1：從 Mininet 的 CLI 殘留或 ps tree 找
ps aux | grep -E 'mininet:h1|mininet:h97' | grep -v grep

# 方法 2：如果上面找不到，試著從 /var/run/netns 找
ls -la /var/run/netns/ 2>/dev/null || echo "no netns directory"

# 方法 3：用 ip netns
ip netns list 2>/dev/null || echo "ip netns not available"
```

如果以上都不行，請回報實際情況，我們再想辦法。

### 6.2 iperf 可用性

檢查 iperf 或 iperf3 是否在 Mininet host 的 namespace 中可用：

```bash
sudo -n mnexec -a 2910932 which iperf iperf3 2>&1 || echo "not found in root ns"
```

以及（如果能拿到 host PID）：
```bash
# 用 §6.1 拿到的 h1 PID 取代 <H1_PID>
sudo -n mnexec -a <H1_PID> which iperf iperf3 2>&1 || echo "not found in h1 ns"
```

如果 iperf 不存在，我們可以用大量 `ping -f`（flood ping）代替，但 UDP 測試會變成 ICMP，且速率難以控制。請如實回報。

### 6.3 s1 的 port 列表與對照

確認 s1 的 port 1 和 port 2 確實是 uplink（到 s5 和 s6），且格式與 topology JSON 一致：

```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 show s1
```

以及 port counters 的輸出格式範例：

```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-ports s1 | head -30
```

**我需要看**：(a) port 1 和 port 2 是否存在，(b) `tx bytes` 欄位的確切名稱（可能是 `tx bytes=` 或 `tx_bytes=` 或 `tx-byte=`），(c) 有沒有其他我不知道的 port（例如 s1 可能還有一個 port 連到 localhost）。

### 6.4 kernel 目前的 edge 狀態

確認 kernel 的拓撲中有 s1→s5 和 s1→s6 這兩條 edge，且格式符合 §3.3.2 的解析腳本：

```bash
curl -s http://localhost:8000/ndt/get_graph_data | python3 -c "
import json, sys
g = json.load(sys.stdin)
for e in g['edges']:
    if e['src_dpid'] == 1 and e['src_interface'] in [1,2]:
        print(json.dumps(e, indent=2))
        print('---')
"
```

**我需要看**：(a) `link_bandwidth_usage_bps` 欄位名稱是否正確，(b) `is_up` 是否為 true，(c) `dst_dpid` 是否為 5 或 6。

### 6.5 Ryu 與 kernel 健康確認（快速）

雖然上一輪已確認，但在跑流量測試前再確認一次：

```bash
curl -s -w '\n%{http_code}\n%{time_total}\n' http://localhost:8080/stats/flow/1 | head -5
curl -s -w '\n%{http_code}\n' http://localhost:8000/ndt/get_average_link_usage
```

**我需要看**：(a) Ryu `time_total` 是否還在 0.02–0.08 秒（健康），(b) kernel 的 `avg_link_usage` 目前值（baseline 用）。

### 6.6 sFlow 配置確認

確認所有 switch 的 sFlow 仍在正確配置（特別是 `sampling=256`, `polling=0`）：

```bash
sudo -n mnexec -a 2910932 ovs-vsctl list sflow | grep -E 'agent|sampling|polling|target'
```

**我需要看**：10 台 switch 的 sFlow 配置，確認 `sampling=256` 和 `polling=0` 都還在（上一輪有人改過 polling，後來改回來了，必須確認）。

### 6.7 Kernel binary 與 log 路徑

雖然上一輪確認過 binary 名稱，但請再確認目前的 kernel process：

```bash
ps aux | grep -E 'ndt|kernel|twin' | grep -v grep
```

以及 kernel log 的輸出位置（stdout/stderr 還是檔案）：
```bash
ls -la /proc/$(pgrep ndt_twin)/fd/ 2>/dev/null | grep -E '1|2' | head -5
```

我需要知道 kernel log 寫到哪裡，因為 §4 的診斷需要搜尋 log。

---

**請先回報 §6.1–§6.7 的所有輸出**。我會根據實際值確認或微調 §3 的命令（特別是 host PID、iperf 路徑、port 格式），然後你就可以依序執行 §3.3 → §3.4 → §3.5 → §3.6 → §3.7 → §3.8 → §5。

---

## 執行摘要（給 Claude 的快速指引）

這份 runbook 的結構：
- **§0**：這個測試能證明什麼、不能證明什麼
- **§1**：容差推導 — 從二項分佈推得 ±15%（95% 信心，30 秒 100 Mbps UDP）
- **§2**：拓撲選擇 — h1 (10.0.0.1, s1 port 3) → h97 (10.0.0.97, s4 port 3)，監控第一跳 edge s1→s5 / s1→s6
- **§3**：逐步命令 — baseline snapshot → iperf 30 秒 + kernel polling → after snapshot → 計算比對
- **§4**：診斷決策樹 — 四層各自怎麼獨立驗證（這是最有價值的部分）
- **§5**：清理
- **§6**：需要先回報的 7 項資訊

**優先讀 §6**，執行那 7 個查詢命令，把原始輸出貼給我。我會確認沒有格式或參數問題，然後你就可以跑 §3.3–§3.8 的實際測試。
