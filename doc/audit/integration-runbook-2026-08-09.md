# OVS 整合測試 runbook（2026-08-09）

## 0. 執行順序總覽

本 runbook 分為兩大部分：

**A. 重啟 kernel 前（使用舊 binary，uptime 41h）**
- §1：收割長時間 uptime 的記憶體/thread/FD 證據
- §1：記錄目前的 power state、flow table、link usage 當 baseline

**B. 重啟 kernel 後（使用今天 14:33 重建的 binary）**
- §2：重啟 kernel 並確認上線
- §3：第 1 優先 — 批次端點三種情況（混合/全未知/全已知）
- §4：第 2 優先 — OVS 無退化（圖、flow、link usage、並發電源）
- §5：第 3 優先 — 數值差分（或說明為何做不到）
- §6：清理

每一節的步驟標示為 **[PRE]**（重啟前執行）或 **[POST]**（重啟後執行）。

---

## 1. 重啟前：收割長時間 uptime 的證據

### 1.1 記憶體、thread、FD 快照

**[PRE]** 記錄目前 kernel process 的資源用量（作為 41h 無洩漏的證據）：

```bash
pgrep -a ndt_twin  # 或 pgrep -a kernel; 記下 PID
cat /proc/$(pgrep ndt_twin)/status | grep -E '^(VmRSS|VmHWM|Threads)'
ls /proc/$(pgrep ndt_twin)/fd | wc -l
```

**看什麼**：三行輸出：VmRSS、VmHWM、Threads、FD count。
**通過條件**：VmRSS ≪ VmHWM（表示記憶體有還回去）、Threads 穩定在 ~48、FD count 合理（不超過幾百）。
**失敗代表什麼**：如果 VmRSS ≈ VmHWM 且都很高（>500 MB），代表可能有記憶體洩漏。如果 FD count 持續成長（需要兩次快照對比，但只有一次也值得記錄），可能是 fd 洩漏。

### 1.2 現有流表 snapshot（baseline，不做任何修改）

**[PRE]**

```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-flows s1
```

**看什麼**：s1 上目前有哪些 flow entry。記下 `n_bytes`、`n_packets`、`priority`、match 欄位。
**通過條件**：能成功列出（不為空或 error）。Ryu 還活著時應該有規則（至少 controller 會下發 LLDP 等）。
**失敗代表什麼**：如果完全沒有規則，檢查 Ryu 是否卡死（見下面 1.3 的判別方法）。

### 1.3 Ryu 健康檢查（唯讀，不重啟）

**[PRE]**

```bash
curl -s -w '\n%{http_code}\n%{time_total}\n' http://localhost:8080/stats/flow/1
```

**看什麼**：HTTP 狀態碼、`time_total`（往返時間）、response body 是否有 flow entries。
**通過條件**：200 OK，`time_total` 在 0.027–0.083 秒之間（健康範圍）。
**失敗代表什麼**：
- `time_total` ≈ 1.011s ± 0.002 且 body 為空陣列 `{}`：Ryu 已卡死。不要重啟 Ryu（會讓情況更糟），必須整組 Mininet+Ryu+kernel 重啟。
- 其他非 200 狀態碼：Ryu 可能 crash 了，檢查 `pgrep -a ryu`。

### 1.4 取得 switch IP 對照表（供後續步驟使用）

**[PRE]** — 這是資訊收集，不需要判斷通過/失敗。

```bash
curl -s http://localhost:8000/ndt/get_graph_data | python3 -c "
import json, sys
g = json.load(sys.stdin)
for n in g['nodes']:
    if n.get('vertex_type') == 0:
        ips = [str((ip>>24)&0xFF)+'.'+str((ip>>16)&0xFF)+'.'+str((ip>>8)&0xFF)+'.'+str(ip&0xFF) if isinstance(ip,int) else ip for ip in n.get('ip',[])]
        print(f\"dpid={n['dpid']}  name={n['device_name']}  ip={ips}  is_up={n.get('is_up')}  is_enabled={n.get('is_enabled')}\")
"
```

**看什麼**：10 台 switch 的 dpid、name、IP、is_up、is_enabled。
**通過條件**：全部 10 台都出現，全部 `is_up=True` 且 `is_enabled=True`。
**失敗代表什麼**：如果有 switch 的 `is_up=False`，kernel 認為它離線；如果 `is_enabled=False`，可能沒有收到 `inform_switch_entered`。

### 1.5 記錄目前的 power state（baseline）

**[PRE]**

```bash
curl -s http://localhost:8000/ndt/get_switches_power_state
```

**看什麼**：JSON object，key 是 switch IP，value 是 "ON" 或 "OFF"。
**通過條件**：10 個 switch IP 都在，全部 "ON"。
**失敗代表什麼**：如果有 "OFF"，表示某台 switch 已被關閉（可能之前測試殘留）。

### 1.6 記錄目前的 link usage（baseline）

**[PRE]**

```bash
curl -s http://localhost:8000/ndt/get_average_link_usage
```

**看什麼**：`avg_link_usage` 值（0–100 的浮點數）。
**通過條件**：JSON 格式正確，`avg_link_usage` 在 0–100 之間。
**失敗代表什麼**：回傳不是合法 JSON 或數值超出範圍 → kernel 可能有問題。

---

## 2. 重啟 kernel 的步驟與確認

### 2.1 停止舊 kernel

**[PRE→POST 過渡]**

```bash
kill $(pgrep ndt_twin)
```

等 2 秒後確認程序已退出：

```bash
pgrep ndt_twin || echo "stopped"
```

**通過條件**：`pgrep` 無輸出（或印出 "stopped"）。
**失敗代表什麼**：如果程序還在，用 `kill -9`。

### 2.2 啟動新 kernel

**[POST]**

需要知道 kernel binary 的名稱與啟動參數。目前的舊 kernel 是以 `--mode mininet --topology setting/StaticNetworkTopologyMininet_10Switches.json --no-ai` 啟動的。binary 名稱需要先確認。

⚠️ **這一步需要 Claude 先回報**：請執行以下命令告訴我 binary 的實際名稱與路徑：

```bash
ls -la build/bin/ | grep -E 'ndt|kernel|twin'
```

以及確認目前舊 kernel 的完整命令列：

```bash
ps aux | grep -E 'ndt|kernel|twin' | grep -v grep
```

**我會在看到輸出後給出精確的啟動命令。**

暫定啟動命令格式（等確認 binary 名稱後調整）：

```bash
./build/bin/<binary_name> --mode mininet --topology setting/StaticNetworkTopologyMininet_10Switches.json --no-ai &
```

### 2.3 確認 kernel 上線

**[POST]**

```bash
sleep 3 && curl -s -w '\n%{http_code}\n%{time_total}\n' http://localhost:8000/ndt/get_graph_data | head -c 200
```

**看什麼**：HTTP 200，time_total < 1s，body 前 200 字元是合法 JSON 且包含 "nodes"。
**通過條件**：200 OK，response 是合法 JSON。
**失敗代表什麼**：connection refused → kernel 還沒起來或 port 不對；非 200 → kernel 啟動失敗。

### 2.4 確認 10 台 switch 都被識別

**[POST]**

重複 1.4 的命令：

```bash
curl -s http://localhost:8000/ndt/get_graph_data | python3 -c "
import json, sys
g = json.load(sys.stdin)
switches = [n for n in g['nodes'] if n.get('vertex_type') == 0]
print(f'switches: {len(switches)}')
for n in switches:
    print(f\"  dpid={n['dpid']}  is_up={n.get('is_up')}  is_enabled={n.get('is_enabled')}\")
"
```

**通過條件**：10 台 switch，全部 `is_up=True` 且 `is_enabled=True`。
**失敗代表什麼**：少於 10 台 → 拓撲檔沒載入或 kernel 解析失敗。`is_up=False` 的 switch 需要 `inform_switch_entered`。

### 2.5 重啟後的對照量測（記憶體）

**[POST]** — 剛重啟後立刻記錄，作為「無退化」的 baseline：

```bash
cat /proc/$(pgrep ndt_twin)/status | grep -E '^(VmRSS|VmHWM|Threads)'
ls /proc/$(pgrep ndt_twin)/fd | wc -l
```

**通過條件**：
- VmRSS 不顯著高於舊 kernel 的 VmRSS（容許 ±20%，因為 startup 階段波動大）
- Threads 數量相近（~48）
- FD count 相近或更低

**說明**：這組數字要跟 §1.1 的數字對比。但剛啟動的 kernel 還沒跑 41 小時，RSS 低是正常的。真正的「無退化」需要讓 kernel 跑一段時間（至少 30 分鐘並注入流量）後再量一次。如果 RSS 單調成長（每 5 分鐘量一次，連量 6 次），那就是退化。

---

## 3. 第 1 優先：批次端點三種情況

### 測試用 match 的選擇

為避免撞到既有流表規則，我們使用一個沒有 host 使用的 `ipv4_dst`。檢查所有 host IP 範圍為 10.0.0.1–10.0.0.128，所以 `ipv4_dst=10.255.255.100`（以及 .101、.102）是安全的。這些都在 spec.py 的 probe_ip 附近但故意不同，以免跟 contract test 的 probe rule 碰撞。

### 3.1 Case 1：全部已知 dpid → 200，無 rejected 欄位

**[POST]**

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"install_flow_entries":[{"dpid":1,"priority":65535,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.100"},"actions":[{"type":"OUTPUT","port":1}]}],"modify_flow_entries":[],"delete_flow_entries":[]}' \
  http://localhost:8000/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries
```

**看什麼**：HTTP status（用 `-w '\n%{http_code}\n'` 也行，但先不加以便讀 body）。
**通過條件**：
- HTTP status 200（如加 `-w` 可檢查）
- Body 是 JSON，包含 `"status":"queued"`、`"accepted":1`
- Body **不包含** `"rejected"` 欄位，也**不包含** `"rejected_dpids"` 欄位
  （因為全部被接受，這兩個欄位不應出現）
**失敗代表什麼**：
- 404 → kernel 不認識 dpid 1（拓撲載入失敗或 kernel 跟 Ryu 脫節）
- 出現 `"rejected"` → 分區邏輯錯誤地把已知 dpid 當成未知
- `"accepted":0` → 分區邏輯錯誤

### 3.2 確認 rule 真的進了交換機（回應誠實 vs 實際生效）

**[POST]** — 在 3.1 之後執行。等 2 秒讓 dispatcher 送出：

```bash
sleep 2 && sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-flows s1 | grep '10\.255\.255\.100'
```

**看什麼**：OVS s1 的 flow table 中是否有 `ipv4_dst=10.255.255.100` 的 entry。
**通過條件**：至少有一條匹配的 flow entry，priority=65535，action 為 OUTPUT:1。
**失敗代表什麼**：
- 完全沒有 → dispatcher 沒送出、Ryu 沒下發、或 Ryu 拒絕了規則。檢查 kernel log 中的 `SuspectTimedOut` WARN。
- 有但 action 不對 → 南向序列化有 bug。

### 3.3 Case 2：混合已知+未知 dpid → 200，含 accepted 與 rejected

**[POST]**

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"install_flow_entries":[{"dpid":1,"priority":65534,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.101"},"actions":[{"type":"OUTPUT","port":2}]},{"dpid":999999999999,"priority":1,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.253"},"actions":[{"type":"OUTPUT","port":1}]}],"modify_flow_entries":[],"delete_flow_entries":[]}' \
  http://localhost:8000/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries
```

**看什麼**：HTTP status 和 body。
**通過條件**：
- HTTP status **200**（不是 404，那是舊行為）
- Body 包含 `"accepted"` ≥ 1
- Body 包含 `"rejected"` ≥ 1
- Body 包含 `"rejected_dpids"` 陣列，裡面有 `999999999999`
**失敗代表什麼**：
- 404 → kernel 還在用舊的 all-or-nothing 邏輯（新 binary 沒生效？）
- 200 但沒有 `rejected` 欄位 → 未知 dpid 被靜默接受
- 200 但 `accepted:0` → 已知 dpid 沒被接受
- `rejected_dpids` 不含 `999999999999` → 分區邏輯有 bug

### 3.4 確認已知 dpid 的 rule 有進交換機，未知的沒有

**[POST]** — 在 3.3 之後執行：

```bash
sleep 2 && sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-flows s1 | grep '10\.255\.255\.101'
```

**通過條件**：有 priority=65534, ipv4_dst=10.255.255.101 的 rule。
**失敗代表什麼**：accepted 的 entry 沒實際生效 → dispatcher 或 Ryu 問題。

### 3.5 Case 3：全部未知 dpid → 404

**[POST]**

```bash
curl -s -w '\n%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{"install_flow_entries":[{"dpid":999999999999,"priority":1,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.252"},"actions":[{"type":"OUTPUT","port":1}]}],"modify_flow_entries":[],"delete_flow_entries":[]}' \
  http://localhost:8000/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries
```

**看什麼**：HTTP status code（用 `-w` 擷取）。
**通過條件**：HTTP status **404**。
**失敗代表什麼**：
- 200 → kernel 回傳 200 但 accepted=0，這正是規避的舊行為：只看 status code 的呼叫者會誤以為成功
- 400 → 參數格式被拒絕（可能是 match 格式不對）

### 3.6 Case 3 補充：確認沒有 garbage rule 進交換機

**[POST]**

```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-flows s1 | grep '10\.255\.255\.252' || echo "not found (good)"
```

**通過條件**：`not found (good)` 或無輸出。
**失敗代表什麼**：有 rule 出現 → 404 回應但 kernel 還是把 rule 送出去了（嚴重 bug）。

---

## 4. 第 2 優先：OVS 無退化（含並發電源）

### 4.1 Graph data 結構與不變量

**[POST]** — 使用 contract test 的 read-only 模式（不改變任何狀態）：

```bash
python3 tools/contract_test/run_contract_test.py \
  --topology setting/StaticNetworkTopologyMininet_10Switches.json \
  --timeout 15
```

**看什麼**：每個 endpoint 的 PASS/FAIL 結果。
**通過條件**：所有 READ 類別的檢查 PASS（約 20 個）。
**失敗代表什麼**：每個 FAIL 會印出具體失敗原因。
- 如果 `get_graph_data` 失敗 → kernel 回應結構變了
- 如果 `inv_all_switches_up` 失敗 → 有 switch 的 `is_up=False`
- 如果 `inv_edges_enabled` 失敗 → 有 edge 的 `is_up=False`

### 4.2 流量端點（有 traffic 才測）

**[POST]** — 先產生跨 switch 的流量，再跑 traffic 檢查。

#### 4.2.1 選擇跨 switch 的 host pair

根據 testbed_topo.py（lines 71–90）：
- h1（10.0.0.1）掛在 s1（dpid 1）的 port 3
- h97（10.0.0.97）掛在 s4（dpid 4）的 port 3

這兩台在不同 switch 上，流量會經過核心網路，滿足 `getAvgLinkUsage` 的 switch-to-switch 邊條件。

#### 4.2.2 產生跨 fabric 流量

**[POST]**

```bash
sudo -n mnexec -a 2910932 ping -c 20 -i 0.2 10.0.0.97 &
```

等 ping 開始後（約 1 秒），立刻執行：

```bash
sleep 2 && python3 tools/contract_test/run_contract_test.py \
  --topology setting/StaticNetworkTopologyMininet_10Switches.json \
  --with-traffic --timeout 15
```

**看什麼**：帶 `--with-traffic` 的檢查結果。
**通過條件**：
- `get_detected_flow_data`：有 flow 被偵測到，且 path 非空，rate 非零
- `get_average_link_usage`：`avg_link_usage` > 0（有跨 switch 流量時應該有非零值）
- `get_switch_openflow_table_entries`：所有 switch 的 flow table 非空
**失敗代表什麼**：
- flow data 為空 → sFlow 沒在採樣或採樣率 256 導致 20 個 ping 沒被採到（機率上有可能，見容差討論）
- path 為空 → classifier 沒資料（可能是 Ryu flow table 為空）
- avg_link_usage 仍為 0 → 可能是採樣沒命中，或 link usage 計算有 bug
**注意**：`--with-traffic` 的檢查可能因為採樣率而 false negative。如果失敗但 read-only 全過，先確認流量還在跑，多等 5 秒再試一次。

### 4.3 Link usage 端點

**[POST]**

```bash
curl -s http://localhost:8000/ndt/get_average_link_usage
```

**通過條件**：`avg_link_usage` 是 0–100 的數字，且當有跨 switch 流量時 > 0。
**失敗代表什麼**：NaN、負數、或格式錯誤。

### 4.4 電源端點：讀取

**[POST]**

```bash
curl -s http://localhost:8000/ndt/get_switches_power_state
```

**通過條件**：10 個 switch IP 全部對應 "ON"。
**失敗代表什麼**：有 "OFF"、缺 switch、或格式錯誤。

```bash
curl -s http://localhost:8000/ndt/get_power_report
```

**通過條件**：10 個物件的陣列，每個有 `dpid` 和 `power_consumed`。
**失敗代表什麼**：缺 switch、格式錯誤。

### 4.5 並發電源請求檢查（測試 m_lastCommandFailed 修復）

#### 4.5.1 選哪台 switch 最安全

分析拓撲：
- s1–s4：有 host 掛著。關掉會讓 32 個 host 斷線。**不安全。**
- s5–s8：aggregation 層。s5 和 s6 各連接 s1/s2 到核心；s7 和 s8 各連接 s3/s4 到核心。關掉 s5 會讓 s1 和 s2 各失去一條 uplink，但仍有一條經 s6。關掉 s7 同理影響 s3/s4。**有影響但不會完全斷網。**
- s9–s10：core 層。兩台都連接全部四台 aggregation switch。關掉任何一台，另一台仍連接所有路徑。**最安全。**

選擇 **s9**（dpid 9，IP 192.168.123.19）。理由：
- 無 host 直連
- s10 提供完全冗餘（s9 和 s10 連接完全相同的 aggregation switch）
- 關掉 s9 後，所有路徑可經 s10 繞送

#### 4.5.2 還原步驟總覽（先寫，再測）

關掉 s9 的還原需要：
1. 透過 kernel API 將 s9 power on
2. 重新設定 s9 的 sFlow（因為 `ovs-vsctl del-br s9` 會銷毀 bridge 及其 sFlow 配置）
3. 確認 s9 恢復正常

⚠️ **警告**：power off s9 會執行 `sudo ovs-vsctl del-br s9`。這是真實的 OVS 操作，會銷毀 Mininet 建立的 bridge。還原步驟會重建 bridge 並重新加入 port。但 sFlow 配置需要手動重新加入。**請 Claude 判斷是否可以執行，或跳過 4.5.3 的 destructive 部分，只用 4.5.4 的 safe concurrent 測試替代。**

#### 4.5.3 並發測試（destructive：關 s9，同時開 s10）

⚠️ **這一步需要 Claude 確認後才執行。**

步驟：

(a) 先記錄 s9 的 port 列表（供還原用）：

```bash
sudo -n mnexec -a 2910932 ovs-vsctl list-ports s9
```

(b) 同時發出兩個請求（使用 background &）：

```bash
curl -s -X POST 'http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.19&action=off' > /tmp/power_s9_off.txt 2>&1 &
curl -s -X POST 'http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.10&action=on' > /tmp/power_s10_on.txt 2>&1 &
wait
```

(c) 檢查兩個回應：

```bash
echo "=== s9 off ===" && cat /tmp/power_s9_off.txt
echo "=== s10 on ===" && cat /tmp/power_s10_on.txt
```

**看什麼**：
- s9 off 回應：應為 `{"192.168.123.19":"Success"}` 或 error
- s10 on 回應：應為 `{"192.168.123.10":"Success"}`（s10 本來就 up，powerOn 是 no-op）

**通過條件**：
- 兩個回應獨立：s9 的結果不影響 s10 的結果
- 如果 s9 off 失敗，s10 on 仍應成功（不能因為共用狀態而被汙染）
- 如果 s9 off 成功，s10 on 也應成功

**如何判斷有沒有互相汙染**：
- 舊程式碼的 bug 是 `m_lastCommandFailed` 被兩個請求共享。如果 s9 off 的最後一個 OVS 命令失敗（設定 `m_lastCommandFailed=true`），然後 s10 on 的 powerOn 檢查到 flag 為 true，會錯誤地回報失敗。
- 新程式碼每個 `powerOn`/`powerOff` 有獨立的 `allOk`，所以不會互相汙染。
- 判斷方式：如果 s10 on 回應 `"Success"` 但 s9 off 也回應 `"Success"`（且 s9 真的被關掉了），則兩個請求的結果一致。如果 s9 off 回應失敗但 s10 on 也回應失敗，那就是汙染（舊 bug）。
- 更具體：s10 on 是 no-op（switch 已 up），它**不執行任何命令**。所以在新舊程式碼下 s10 on 都應該成功。如果 s10 on 失敗了，就是 bug。

(d) 確認 power state：

```bash
curl -s http://localhost:8000/ndt/get_switches_power_state
```

**通過條件**：s9（192.168.123.19）顯示 "OFF"，s10（192.168.123.10）顯示 "ON"，其他全部 "ON"。

#### 4.5.4 並發測試（safe：兩個都是 power on，不破壞任何東西）

如果不執行 4.5.3 的 destructive 測試，這個 safe 版本至少驗證 HTTP 層的並發正確性：

```bash
curl -s -X POST 'http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.19&action=on' > /tmp/power_s9_on.txt 2>&1 &
curl -s -X POST 'http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.20&action=on' > /tmp/power_s10_on.txt 2>&1 &
wait
echo "=== s9 on ===" && cat /tmp/power_s9_on.txt
echo "=== s10 on ===" && cat /tmp/power_s10_on.txt
```

**通過條件**：兩個回應都是 `{"<ip>":"Success"}`，沒有互相覆蓋或錯誤。
**限制**：兩個請求都是 no-op（switch 已 up），不會執行 OVS 命令，所以無法測試 `allOk` 的命令失敗路徑。但可以驗證 HTTP handler 的並發正確性（response 沒有交錯）。

#### 4.5.5 還原 s9（如果執行了 4.5.3）

```bash
curl -s -X POST 'http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.19&action=on'
```

等 3 秒後確認：

```bash
sleep 3 && curl -s http://localhost:8000/ndt/get_switches_power_state | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('192.168.123.19','MISSING'))"
```

**通過條件**：印出 "ON"。

然後重新設定 sFlow（從 testbed_topo.py 的邏輯推導）：

```bash
S9_IFACE=$(sudo -n mnexec -a 2910932 ovs-vsctl list-br | grep s9)
# 找到 s9 的管理介面（通常是 s9 本身）
sudo -n mnexec -a 2910932 ovs-vsctl -- --id=@sflow create sflow agent=s9 target=\"192.168.123.1:6343\" header=128 sampling=256 polling=0 -- set bridge s9 sflow=@sflow
```

⚠️ `agent=s9` 是推測值（Mininet 中 switch 的管理介面名稱通常等於 switch 名稱）。如果失敗，改用實際的介面名稱（從 `ovs-vsctl list sflow` 看其他 switch 的 agent 設定）。

---

## 5. 第 3 優先：數值差分（含容差推導，或說明為何做不到）

### 5.1 設計思路

kernel 的 link usage 來自四層推導：
1. OVS sFlow sampling（sampling=256）→ UDP datagrams
2. kernel 解析 sFlow datagrams → flow samples
3. 從 flow samples 計算速率
4. 將速率歸屬到 switch-to-switch edges

要驗證數值正確性，需要一個獨立來源對照。兩個候選：
- **OVS 的 `n_bytes` counter**（`ovs-ofctl dump-flows`）：這是 switch 自己的計數器，是原始紀錄、不經過 sampling。
- **iperf 報告的傳輸量**：應用層的測量。

### 5.2 為什麼做不到可靠的點對點比對

#### 問題 1：sampling rate 256 的變異

OVS sFlow 每 256 個封包才取樣一個。kernel 用這個樣本估算整體速率。對於小流量（如 20 個 ping），可能只抓到 0–2 個樣本，估算的速率有極大變異。

假設 ping 發出 20 個 ICMP Echo Request + 20 個 Echo Reply = 40 個封包（每個 98 bytes = 784 bits，單向）。sampling=256 時，40 個封包被採到的期望值是 40/256 ≈ 0.156 個樣本。**大部分情況下根本不會被採到**。

即使被採到，kernel 的速率估算公式為：`(sample_bytes * sampling_rate) / interval_seconds`。如果只抓到 1 個樣本（98 bytes），速率估算 = `(98 * 256) / 1.0` ≈ 200 kbps。但實際瞬時速率遠低於此。**這就是 sampling 的固有誤差，不是 kernel bug。**

#### 問題 2：`n_bytes` counter 是累積值，不是瞬時速率

`ovs-ofctl dump-flows` 的 `n_bytes` 是從 rule 安裝以來累積的。要轉成速率，需要在兩個時間點取差值除以時間間隔。但 kernel 報的是「過去 1 秒的估算速率」，兩者的時間窗口對不齊。

而且 `n_bytes` 包含所有匹配該 rule 的流量（包括背景雜訊如 LLDP、ARP），kernel 的 sFlow 也包含這些。無法隔離出「只有我們產生的測試流量」。

#### 問題 3：kernel 報的是 switch-to-switch edges 的 usage

`getAvgLinkUsage` 只計算 switch-to-switch 邊（已由使用者確認並從 `FlowLinkUsageCollector.cpp` 驗證）。OVS 的 `n_bytes` 是 per-rule、per-switch 的，無法直接對應到特定的 inter-switch link。

#### 問題 4：測試流量太小

要產生足夠的流量讓 sampling=256 穩定採樣，需要至少數千個封包。20 個 ping 不夠。即使用 iperf 打 1 Mbps 的 UDP flow，每秒約 850 個 1500-byte 封包，期望樣本數 = 850/256 ≈ 3.3 個。這仍然有很大的 Poisson 變異（stddev ≈ √3.3 ≈ 1.8 個樣本，對應速率估算在 1 Mbps ± 55%）。

#### 問題 5：kernel 還有 counter sample 的 MININET 模式 early-continue

`FlowLinkUsageCollector.cpp` 在 MININET 模式下跳過 counter samples（來自 testbed_topo.py line 121 的註解確認 `polling=0`），只用 flow samples 計算 link usage。所以 `getAvgLinkUsage` 的數值完全依賴 flow sample 的估算，無法跟 `n_bytes` 這種 counter 直接對比。

### 5.3 務實的替代方案

雖然無法做點對點的數值比對，但可以做**方向性檢查**（而不是數值相等）：

#### 5.3.1 方向性檢查：有流量 vs 無流量

**[POST]**

在**沒有**注入任何測試流量時：

```bash
curl -s http://localhost:8000/ndt/get_average_link_usage
```

記錄 `avg_link_usage` 值（預期很低或 0.0，但可能有背景雜訊）。

在**注入大量流量**後（iperf 打 10 秒）：

```bash
# 需要先確認兩台跨 switch host 之間能通
sudo -n mnexec -a 2910932 ping -c 2 10.0.0.97
```

如果 ping 通，用 iperf（如果 Mininet host 有安裝）或大量 ping：

```bash
sudo -n mnexec -a 2910932 ping -c 200 -i 0.05 10.0.0.97 &
sleep 5 && curl -s http://localhost:8000/ndt/get_average_link_usage
```

**通過條件**：有流量時的 `avg_link_usage` **高於**無流量時的值。差距不需要精確，只要有方向性增加就表示 link usage 收集有在運作。

**容差**：不設數值容差，只做方向比較。如果從 0.0 變成 >0.0，就是通過。

#### 5.3.2 用 contract test 的 flow rate invariant 輔助

```bash
python3 tools/contract_test/run_contract_test.py \
  --topology setting/StaticNetworkTopologyMininet_10Switches.json \
  --with-traffic --timeout 15
```

`inv_flow_rates_nonzero` 會檢查是否有 flow 的 estimated rate > 0。這不驗證 rate 的絕對值正確，但驗證「rate 計算管線有在運作且產出非零值」。

### 5.4 結論

在現有工具（sampling=256、polling=0、MININET 模式跳過 counter samples）下，**無法做可靠的端到端數值比對**。點對點比對需要：
- 更低的 sampling rate（如 1:1，但會大幅增加 overhead）
- 或啟用 polling（但 MININET 模式刻意跳過 counter samples，且註解警告 TESTBED path 的 offset 是針對 Brocade/HPE 校準的，不能用於 OVS）
- 或一個能注入已知速率 traffic 並隔離背景雜訊的測試 harness（目前不存在）

方向性檢查（有 vs 無）加上 contract test 的 invariants 已提供合理的回歸保護。

---

## 6. 清理步驟

### 6.1 刪除測試用的 flow entries

我們在 §3 中安裝了兩條測試 rule（dpid 1 上 priority=65535 和 65534）。用 delete_flow_entry 清理：

```bash
# 刪除 priority 65535 那條（ipv4_dst=10.255.255.100）
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.100"}}' \
  http://localhost:8000/ndt/delete_flow_entry

# 刪除 priority 65534 那條（ipv4_dst=10.255.255.101）
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.101"}}' \
  http://localhost:8000/ndt/delete_flow_entry
```

等 2 秒後確認已清除：

```bash
sleep 2 && sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-flows s1 | grep -E '10\.255\.255\.(100|101)' || echo "cleaned up"
```

**通過條件**：`cleaned up` 或無匹配輸出。

也可以用批次端點一次清除：

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"install_flow_entries":[],"modify_flow_entries":[],"delete_flow_entries":[{"dpid":1,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.100"}},{"dpid":1,"match":{"eth_type":2048,"ipv4_dst":"10.255.255.101"}}]}' \
  http://localhost:8000/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries
```

### 6.2 還原電源狀態（如果執行了 4.5.3）

確保 s9 是 ON：

```bash
curl -s -X POST 'http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.19&action=on'
```

確認：

```bash
curl -s http://localhost:8000/ndt/get_switches_power_state | python3 -c "import json,sys; d=json.load(sys.stdin); print('s9:', d.get('192.168.123.19','MISSING'))"
```

**通過條件**：s9: ON。

### 6.3 確認整體狀態恢復

```bash
python3 tools/contract_test/run_contract_test.py \
  --topology setting/StaticNetworkTopologyMininet_10Switches.json \
  --timeout 15
```

**通過條件**：所有 READ 檢查 PASS（與 §4.1 的結果一致）。

---

## 7. 我需要 Claude 先回報的資訊

在執行 runbook 之前，請先執行以下命令並告訴我結果：

### 7.1 Kernel binary 名稱

```bash
ls -la build/bin/
```

我需要知道 binary 的實際名稱才能寫出 §2 的精確啟動命令。

### 7.2 舊 kernel 的完整啟動命令

```bash
ps aux | grep -E 'ndt|kernel|twin' | grep -v grep
```

這可以確認 binary path、啟動參數、以及是否有其他我沒注意到的 flag。

### 7.3 目前 s1 的 flow table（確認 Ryu 健康）

```bash
sudo -n mnexec -a 2910932 ovs-ofctl -O OpenFlow13 dump-flows s1 | head -30
```

以及：

```bash
curl -s -w '\n%{http_code}\n%{time_total}\n' http://localhost:8080/stats/flow/1 | head -30
```

我需要知道：(a) 有沒有 flow entries（如果不为空，Ryu 活著），(b) `time_total` 是多少（判斷是否卡死在 1.011s）。

### 7.4 目前 kernel 的 graph data 中的 switch is_up 狀態

```bash
curl -s http://localhost:8000/ndt/get_graph_data | python3 -c "
import json, sys
g = json.load(sys.stdin)
for n in g['nodes']:
    if n.get('vertex_type') == 0:
        ips = n.get('ip',[])
        ip_strs = []
        for ip in ips:
            if isinstance(ip,int):
                ip_strs.append(str((ip>>24)&0xFF)+'.'+str((ip>>16)&0xFF)+'.'+str((ip>>8)&0xFF)+'.'+str(ip&0xFF))
            else:
                ip_strs.append(str(ip))
        print(f\"dpid={n['dpid']}  name={n['device_name']}  ip={ip_strs}  is_up={n.get('is_up')}  is_enabled={n.get('is_enabled')}\")
"
```

### 7.5 iperf 是否在 Mininet host 裡可用

```bash
sudo -n mnexec -a 2910932 which iperf iperf3 2>&1 || echo "iperf not found"
```

這決定 §5 的流量產生方式。

### 7.6 確認 s9 的 OVS bridge 與 port

```bash
sudo -n mnexec -a 2910932 ovs-vsctl list-ports s9
```

以及：

```bash
sudo -n mnexec -a 2910932 ovs-vsctl list sflow | head -40
```

這決定 §4.5 的還原步驟需要哪些資訊。

---

請先執行 §7 的命令並回報結果，我會根據實際輸出調整 §2 的啟動命令與 §4.5 的還原步驟，然後你就可以按順序執行 §1 → §2 → §3 → §4 → §5 → §6。

---

# 執行紀錄（Claude 執行，2026-08-09）

runbook 由 DeepSeek 撰寫、由我執行。它的 §7「需要先回報的資訊」用得對，四項都問到了關鍵值。

## 環境（執行前實測）

| 項目 | 值 |
|---|---|
| Ryu | REST :8080、OpenFlow :6653/:6633，健康 |
| Mininet | `testbed_topo.py`，PID 2910932 |
| 舊 kernel | 2026-08-07 21:25 啟動，**41 小時 uptime**，今天所有改動之前的 build |
| 拓撲 | 138 node（10 switch dpid 1–10 ＋ 128 host）、288 edge |

**Ryu 沒有卡死**：`/stats/flow/1` 回 200、**0.024 s**、130 條規則。（卡死的判別值是 1.011 s。）

**41 小時 uptime 的記憶體與執行緒**（重啟前收割，之後就沒了）：
```
VmRSS   39952 kB (~39 MB)      VmHWM  68052 kB (峰值 ~66 MB)
Threads 48                     FD     8
```
RSS 遠低於峰值 → 記憶體有還回去、無單調成長。這回答了 change-magnitude review
三個「優先重驗」的第三項 —— **但只對今天之前的 build 有效**。

## 一個順帶查證：我修的 OpenFlow 常數在活路徑上

`ovs-ofctl` 的文字輸出是 `actions=CONTROLLER:65535`（沒有 `OUTPUT:` 前綴），而 Classifier 的
修法在 `kind == "OUTPUT"` 分支裡 —— 所以有必要確認真實輸入走哪一種。查了 Ryu 的 JSON REST：

```
  128  OUTPUT:<n>
    1  OUTPUT:CONTROLLER
```

**Ryu 的 JSON 用 `OUTPUT:` 前綴**，所以那四個常數不是死路徑；目前的真實流表裡就有一個
`OUTPUT:CONTROLLER`（LLDP 規則）。

## 第 1 優先：批次端點三種情況 —— 全數通過

kernel 重啟成新 build 後（10 switch 全 up+enabled、138/288，與重啟前一致）：

| 情況 | HTTP | body | 交換機實際狀態 |
|---|---|---|---|
| 全部已知 dpid | 200 | `accepted:1`，**無** `rejected`/`rejected_dpids` | `priority=65535,ip,nw_dst=10.255.255.100 actions=output:1` 已在 s1 |
| **混合已知＋未知** | **200** | `accepted:1, rejected:1, rejected_dpids:[999999999999]` | 好的進了（10.255.255.101 = 1 條）、**壞的沒進**（10.255.255.253 = 0 條）|
| 全部未知 | **404** | `unknown_dpids:[999999999999]` | — |
| 空批次（對照） | 200 | `accepted:0`，無 rejected 欄位 | — |

中間那一列就是方案 B 的全部意義：**以前這一批會整批 404、一條都不進，而兩個會寫入的應用
都丟掉回應所以完全看不到。**

最後一列驗證了 404 的條件寫對了（`acceptedJobs.empty() && rejectedEntries > 0`）——
空批次不會被誤判成「未知 dpid」。

**回應誠實 vs 實際生效**：三秒後去 s1 查，回應說 accepted 的都真的在交換機上、
說 rejected 的都不在。這個專案最常見的缺陷形狀正是兩者不一致，這次一致。

兩條拒絕路徑各自記了自己的 WARN，措辭不同（刻意的，一條講「丟掉 n 條中的 m 條」、
一條講「沒有任何一條可用」）：
```
dropping 1 of 2 flow batch entries: 1 dpid(s) are not switches in the loaded topology; the rem…
refusing flow batch: none of its 1 entries names a switch in the loaded topolog…
```

**清理完成**：兩條測試規則已刪（`accepted:2`），s1 上殘留 0 條。

## 第 2 優先：OVS 無退化 —— 通過

重啟前後對三個端點做快照比對（shape 遞歸比對 ＋ 數量）：

| 端點 | shape | 數量 |
|---|---|---|
| `get_graph_data` | 相同 | nodes 138→138、edges 288→288 |
| `get_average_link_usage` | 相同 | 2→2 |
| `get_switch_openflow_table_entries` | 相同 | 10→10 |

**kernel log：0 個 ERROR。** 唯一的 WARN 是我們刻意觸發的未知 dpid。

## 沒有執行的部分，以及為什麼

**並發電源測試（runbook §4 的一部分）—— 刻意不跑。**

runbook 要求同時對兩台 switch 一開一關，用來驗今天 `OVSPowerStrategy` 移除共用可變狀態的修法。
我判斷這件事在**正在使用中的 testbed 上無法同時做到安全與有資訊量**：

- `powerOff` 會 `ovs-vsctl del-br` 真的刪掉 bridge，而它存進圖裡的 port 清單是重建時唯一的依據。
- 對已經 up 的 switch 下 power on 會在 `getVertexIsUp` 就早退，一個命令都不跑 ——
  安全但完全不碰到那個旗標，等於沒測。
- 而那個缺陷**已經有決定性的單元測試**（`AFailedRequestDoesNotMakeAConcurrentOneReportFailure`，
  用 rendezvous 讓交錯由測試決定），並且**對忠實還原的舊版驗證過會失敗**。

所以活體版本的邊際資訊只有「配上真的 ovs-vsctl 也成立」，而代價是可能弄壞一個有 128 台 host
的活環境。列為未執行，理由在此，不是忘記。

**§5 數值差分（sFlow 推導值對上 `ovs-ofctl` 的 `n_bytes`）—— 尚未執行。** 這一項安全且有價值，
但需要先產生流量並推導取樣容差，留待下一輪。
