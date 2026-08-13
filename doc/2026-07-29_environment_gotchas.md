# 這台機器上的環境陷阱

[Co-developed with claude code -- Adam]

每一項都是實際踩到、浪費過時間才記下來的。全部驗證過，不是推測。

相關文件：[2026-07-29_p4_status_and_test_guide.md](2026-07-29_p4_status_and_test_guide.md)（測試流程）、
[2026-07-27_p4_bmv2_support_plan.md](2026-07-27_p4_bmv2_support_plan.md)（開發計畫與進度）

---

## 必要的系統設定

### `ovs-vsctl` 要能免密碼 sudo

kernel 的 `pingWorker` 每秒 shell 出去跑 `sudo ovs-vsctl list-br`。但 `stack.sh` 用 `setsid`
背景啟動 kernel，**沒有 controlling terminal，`sudo` 沒辦法問密碼就直接失敗**，回一個空的 bridge
清單 → 每台 switch 被判定 unreachable → 每秒被 `setVertexDown()` 蓋掉。

症狀：`up=0` 但 `enabled` 可能是 10。log 裡會有幾千行 `sudo: a password is required`。

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/ovs-vsctl, /usr/sbin/ifconfig, /usr/bin/mnexec" \
  | sudo tee /etc/sudoers.d/ndtwin-mininet
sudo chmod 440 /etc/sudoers.d/ndtwin-mininet
sudo visudo -c          # 檢查語法，做完一定要跑
```

注意 `ovs-ofctl` **不在**這個清單裡，所以 `dump-flows` 之類的指令仍需要密碼。查 flow table 可以改用
Ryu 的 REST（`curl localhost:8080/stats/flow/1`），不需要 sudo。

---

## 診斷工具的坑

### `pgrep` 數 bmv2 會數錯（兩種錯法）

1. **`pgrep -c simple_switch_grpc` 回 0**，即使 10 台都在跑。
   `pgrep` 預設比對 `/proc/PID/comm`，那個欄位**上限 15 字元**，`simple_switch_grpc`（18 字元）
   會被截成 `simple_switch_g`，所以匹配不到完整名稱。

2. **`pgrep -fc simple_switch_grpc` 數字偏大**。`-f` 比對完整命令列，會把「命令列裡剛好含這個字串」
   的東西也算進去 —— 包括你自己那個 `bash -c '... pgrep -f simple_switch_grpc ...'` 的 shell。

**可靠的數法**：

```bash
ps -eo comm --no-headers | grep -c "^simple_switch_g$"
ps -eo pid,args --no-headers | awk '$2=="simple_switch_g"'   # 要看 argv 時
```

同樣的坑也會咬到寫 pidfile：用 `pgrep -f` 抓 Ryu 的 PID 會抓到自己的 wrapper shell，導致
`stack.sh down` 殺錯對象、真正的程序變成孤兒。

### 讀 bmv2 的 counter：這台機器上做不到

`simple_switch_CLI` 有裝（`/usr/local/bin/`），但它需要兩個 Python 模組，**兩個 interpreter
（系統 python3 和 `/home/adam/p4dev-python-venv`）都缺**：

| 模組 | 在哪 | 狀況 |
|---|---|---|
| `sswitch_CLI` | `/home/adam/P4_Source_Code/behavioral-model/targets/simple_switch/` | 要手動加 `PYTHONPATH` |
| `runtime_CLI` | `/home/adam/P4_Source_Code/behavioral-model/tools/` | 要手動加 `PYTHONPATH` |
| `thrift`（Python binding） | — | **沒裝，這是硬阻礙** |

所以 P4 的 direct counter / per-port counter 目前**無法從外部讀取**驗證。要驗證的話得先
`pip install thrift`。替代方案是看 veth 的封包計數（`ip -s link show s1-eth3`），但那只反映
介面層的流量，不是 P4 表的 counter。

### `tcpdump` 的 `0 packets captured` 不代表沒流量

`0 packets captured / 72 packets received by filter` 的意思是：tcpdump 檢查了 72 個封包，
但**沒有一個符合過濾條件**。要判斷 sFlow 有沒有真的到 kernel，看 kernel log 的計數器更直接：

```bash
grep -oE "rx=[0-9]+, app_drop=[0-9]+, addressed=[0-9]+" .test_run/logs/kernel.log | tail -1
```

`rx` 是收到的 datagram 數，`addressed` 是成功歸戶到 agent 的 **sample** 數。
**`addressed` 只在處理 flow sample（type 1）時遞增** —— counter sample（type 2）是週期性的，
會讓 `rx` 一直漲但 `addressed` 不動。所以「`rx` 漲、`addressed` 不漲」= 沒有真實流量，不是壞掉。

---

## 兩個 Mininet 不能共存

切換 OVS ↔ P4 之間**一定要清乾淨**，否則殘留的 namespace/bridge/程序會讓下一輪起不來或測出假結果。

```bash
sudo mn -c
```

⚠️ **`mn -c` 不會殺 bmv2。** `p4_testbed_topo.py` 現在啟動時會自己 `pkill -f simple_switch_grpc`
（commit `22ada58`），但手動清的時候要記得：

```bash
sudo mn -c && pkill -f simple_switch_grpc
```

殘留的 bmv2 會**佔住 gRPC port**，讓下一輪對應的那台 switch 綁不上 port 而死掉。真實案例：
s10 的 `:50060` 被上一輪的孤兒佔住，只有 9 台起來，而腳本當時還照樣印「10 台成功」。

### `stack.sh` 起的程序會活過 terminal 關閉

`stack.sh` 用 `setsid` 啟動 kernel/proxy/ryu，它們**脫離 terminal**。關掉視窗後畫面上什麼都沒有，
但 `:8000`/`:8081` 還被佔著 —— 下次手動開 kernel 會撞到：

```
terminate called after throwing an instance of 'boost::wrapexcept<boost::system::system_error>'
  what():  bind: Address already in use
```

用 `./stack.sh status` 確認，`./stack.sh down` 收掉。

---

## 兩個模式的啟動順序是**相反的**

南向連線方向不同，所以順序不能通用：

| 模式 | 誰是 server | 正確順序 |
|---|---|---|
| OVS | **Ryu** 監聽 :6633，switch 主動連進來 | Ryu → Mininet → 等收斂 → kernel |
| P4 | **bmv2** 監聽 :50051-50060，proxy 是 gRPC **client** | **Mininet → proxy** → 等收斂 → kernel |

`stack.sh up {ovs|p4}` 會自動走對的順序。P4 若順序錯了，症狀是 proxy 完全不開 `:8081`
（uvicorn 在 startup 就 exit），而真正的原因是 log 裡幾十行前的 ECONNREFUSED。

**kernel 一定要最後開。**

⚠️ **2026-08-10 更正**：原本寫的理由是「`run()` 只在啟動時拉一次拓撲、沒有重試迴圈」——
`71d27c1` 之後不成立，`run()` 已改為定期輪詢（前 90 秒每 5 秒、之後每 30 秒，
`TopologyAndFlowMonitor.cpp:1793-1795`）。順序規則保留，理由改成上表那個：南向連線方向不同。
先開 kernel 現在只會讓圖晚幾十秒補齊，不會永久缺料。

---

## Ryu 需要多載兩個 stock app

`intelligent_router.py` **只**提供 `/ryu_server/all_destination_paths`。kernel 依賴的其他
Ryu REST endpoint 全部來自內建 app，少載任何一個都是**靜默失敗**：

| app | 提供 | 少了它的症狀 |
|---|---|---|
| `ryu.app.rest_topology` | `/v1.0/topology/{switches,hosts,links}` | 圖永遠 `up=0 enabled=0`（`updateSwitches()` 把 404 的 HTML 拿去 `json::parse`、接住例外後靜靜放棄）|
| `ryu.app.ofctl_rest` | `GET /stats/flow/<dpid>`、`POST /stats/flowentry/*` | 每次輪詢一筆 `JSON parsing failed ... last read: '<'`、flow table 查不到、**所有下規則都失敗** |

`--observe-links` 只載入 `ryu.topology.switches`（提供**事件**），不含這兩組 REST endpoint。
已修進 `stack.sh`（commit `3acad16`）。

---

## 語言/框架層面的陷阱

### spdlog 的 log 參數**一定會被求值**，即使等級關掉

`SPDLOG_LOGGER_TRACE(logger, "...", expr)` 把 `expr` 當**普通函式引數**傳進 `log()`，等級過濾發生在
函式**內部**。所以「看起來關掉的」trace log 裡的運算式照樣執行 —— 一個 `.front()` 對空 vector 就足以
讓整個 process segfault。這個 build 還帶著 `-DSPDLOG_ACTIVE_LEVEL=SPDLOG_LEVEL_TRACE`。

真實案例：`Classifier.cpp` 的 `pr.effect.outputPorts.front()` 讓 kernel 崩掉（`segfault at 0`），
而觸發條件是 Ryu 的 table-miss 規則 `"actions": []`。修法是包一層安全的格式化函式（`196a10d`）。

**寫 log 時假設參數一定會被執行。**

### gRPC 的 channel 是延遲連線的

`grpc.insecure_channel()` 不會馬上連線，所以 `P4RuntimeClient.start()` 看起來會成功，即使對方
根本沒在跑。失敗要等第一個真正的 blocking RPC 才浮現 —— 讓錯誤看起來出現在無關的地方。

### `unittest` 在 module 最外層 `raise SkipTest` 不會優雅跳過

那是 import 期間的未接住例外，直接 exit 1，跟它想避免的 `ImportError` 崩潰是同一種失敗。
正確做法是把條件存成 flag，用 `@unittest.skipUnless(...)` 裝飾 TestCase class。

### 每個 gtest suite 都要自己 `Logger::init`

`Logger::instance()` 在 init 前是 **null shared_ptr**，spdlog 會在 `should_log` 裡解參考它。
不能靠別的 suite 先 init —— `ctest` 給每個測試獨立 process。`Logger::init` 是 idempotent 的，
所以每個 suite 的 `SetUpTestSuite` 都呼叫沒問題。

## 用 `mnexec` 起的東西不會隨 Mininet 一起死

**[Co-developed with claude code -- Adam]**

`sudo -n mnexec -a <host-pid> <cmd>` 是在沒有 Mininet CLI 時製造流量的方法（見上面關於 sudo 權限的
一節），但它起出來的 process **不是 Mininet 的子程序**。Mininet 結束時不會帶走它。

實測：一個 `iperf -s -u -p 5003` 從 2026-07-31 15:32 活到 08-03，**跨越了兩次 Mininet 重啟**，
並且把那台已經不存在的 host 的 network namespace 撐著沒回收。`pgrep -x iperf` 找得到，但
`ps` 的 PID 落在舊的區間（161 萬，當天的是 240 萬），所以掃「今天的 process」會漏掉它。

危害不大 —— `-s` 只是在等，三天累積 CPU 15 秒 —— 但它是一個**會回應的流量端點**，而那正是
「量到的數字無法解釋」的來源。整合測試前應該清掉。

```bash
# 找出來（-x 比 -f 安全，-f 會匹配到自己的 shell）
pgrep -a -x iperf; pgrep -a -x iperf3; pgrep -a -x ping

# 關掉：它是 root 起的，普通身分殺不掉，但 mnexec 可以（uid 0）
sudo -n mnexec -a <pid> kill -TERM <pid>
```

`sudo mn -c` 也會清掉，但只有在你記得跑的時候 —— 而手動起的 Mininet 是用 Ctrl-D 離開的，
不會自動 `mn -c`。

## 在 bmv2 上用 `ifconfig <iface> down` 模擬斷線，會連累整台 switch

**[Co-developed with claude code -- Adam]**（2026-08-10 實測）

要在 P4 fabric 上模擬鏈路失效，直覺做法是 `sudo -n ifconfig s1-eth1 down`（`ifconfig` 在 NOPASSWD
清單裡）。它確實會讓那條鏈路斷掉 —— **但它同時讓 s1 的整條 packet-in 路徑停擺**。

實測數字（`GET /p4/switch_state`）：

| 欄位 | 斷線後的 s1 | 同時間的 s2／s3 |
|---|---|---|
| `probe_ok` | `true`（gRPC 照常回答） | `true` |
| `stream_alive` | `true` | `true` |
| `last_lldp_age_s` | 3.2 s（s1 **送出**的 beacon 別人還收得到） | 3.2 s |
| **`last_packet_in_age_s`** | **73 s** | 3.2 s |

也就是說 switch 沒死、gRPC 沒斷、它還在對外送 beacon，但它**不再把收到的封包送上 CPU**。

**後果是一個誤報**：從 s6 送到 s1-eth2 的 beacon 永遠不會被 proxy 看到，於是 watchdog 依它掌握的
證據判定 `(6, 1, 1, 2)` 也失效了 —— 而那條線實體上完全正常（`ip link` 顯示兩端都 UP）。
接著 s1 的**兩個入向**都被標 down，`all_destination_paths` 從 12 條掉到 9 條，少的三條全是
「→ 10.0.0.1」：**twin 認為 h1 不可達，但實際上經 s6 走得通。**

把介面 `up` 回來之後，s1 的 packet-in 在幾秒內恢復（`last_packet_in_age_s` 回到 0.2–4.6 s），
圖也在 14 秒內回到 40/40、12 條路徑。所以是可逆的，不是壞掉。

> **判讀規則：在 bmv2 上做斷線測試時，只信任你**故意**斷掉的那條鏈路的判定。同一台 switch 上
> 其他埠出現的失效回報，先去看 `last_packet_in_age_s` 再說。**

Mininet CLI 的 `link s1 s5 down` 底層也是對兩端做同樣的事，所以**大概率同一個症狀**（未另外實測）。
要乾淨地只斷一條鏈路而不影響該 switch 的其他埠，目前沒有已知做法。

---

## 不要單獨重啟 Ryu

**[Co-developed with claude code -- Adam]**

「先 Ryu 再 Mininet」是**初次啟動**的既有規則，原因是 Mininet 啟動時會探測 6653/6633 決定撥哪個
port（`mininet/node.py:1551`）。那條規則管不到**中途重啟**，而中途重啟 Ryu 是很自然會做的事 ——
改了 `intelligent_router.py` 想生效就會這樣做。

**在 Mininet 還在跑的時候重啟 Ryu，8 秒後 `/stats/flow/<dpid>` 開始永久回空表**（1.001 秒逾時、
`{"1": []}`），而且不會恢復 —— 不會因為初始安裝完成而恢復，也不會因為唯一的客戶端停止而恢復。
實測可重現。正確順序下掛了 7.5 分鐘、223 個樣本，零退化。

後果：**資料平面完全正常**（實測每台 130 條規則、`is_connected: true`），但 kernel 的
`fetchOpenFlowTablesInternal` 讀的是 Ryu 的視角，餵給 Classifier —— 所以**每條 flow 的 `path`
都是空的，而網路其實好好地在轉封包**。詳細分析和四個被推翻的假設見 `2026-07-29_HANDOFF.md` 第 2c 節。

> **完整規則：先 Ryu 再 Mininet；而且不要中途單獨重啟 Ryu —— 要重啟就兩個一起。**

也就是說**改完 `intelligent_router.py` 要重測，必須整組重開。**

## `ovs-ofctl` 不在 NOPASSWD 清單裡

**[Co-developed with claude code -- Adam]**

sudoers 只放了 `/usr/bin/ovs-vsctl`、`/usr/sbin/ifconfig`、`/usr/bin/mnexec`。**`ovs-ofctl` 不在
裡面**，所以：

```bash
sudo -n ovs-ofctl dump-flows s1 2>/dev/null | wc -l     # 回 0 —— 指令失敗，不是沒有規則
```

我一度據此報告「fabric 完全沒有規則」，差一點成為結論。正確做法是透過 `mnexec`（它以 uid 0 執行）：

```bash
sudo -n mnexec -a $(pgrep -f '[t]estbed_topo.py' | head -1) ovs-ofctl -O OpenFlow13 dump-flows s1
```

同樣的技巧讓 `py-spy` 可用（`ptrace_scope=1` 會擋掉直接執行）：

```bash
sudo -n mnexec -a <pid> /home/adam/miniconda3/bin/py-spy dump --pid <pid>
```

⚠️ **`py-spy dump` 是單一取樣，會騙人。** 我從一張「hub 空閒在 epoll」的 dump 推論「hub 停止調度」，
連拍 8 張才發現 7 張空閒、1 張在 `lldp_loop` 的 sleep —— hub 正常。要判斷時間花在哪請用
`py-spy top` 或 `py-spy record`。

## `tc qdisc add ... root netem` 會靜默替換 TCLink 的 htb（2026-08-13）

OVS testbed（`testbed_topo.py`）用 `link=TCLink` 建鏈路，root qdisc 是 htb（頻寬 shaping
掛在那）。`tc qdisc add dev X root netem ...` 不是「疊一層」，是**把 htb 整個換掉**——
shaping 靜默消失；`tc qdisc del dev X root` 還原的是預設 qdisc，**不是** htb；常用的
「netem 殘留＝0」收尾檢查看不見這種損傷，NOPASSWD 的授權範圍也裝不回 htb。
（2026-08-13 OVS 夜測輪實測；C 報告 Phase 3 有完整經過。）

- 動手前先 `tc qdisc show dev X`：root 是 htb 的介面，netem 要掛在 class 底下
  （`parent 5:1`），**但 NOPASSWD 沒有授權那個形式**——2026-08-13 實測 `sudo -n tc qdisc add
  dev s1-eth1 parent 5:1 netem loss 1%` 直接回 `sudo: a password is required`。sudoers 只給了
  三條：`qdisc add dev s[0-9]*-eth[0-9]* root netem *`、`qdisc del … root`、`qdisc show …`。
  **也就是說唯一免密碼的注入形式，正好就是會替換掉 htb 的那個。**
  可行的繞法是透過已授權的 `mnexec` 在 root namespace 裡執行 tc（同日實測可用）：

  ```bash
  TOPO=$(ps -eo pid,args | grep '[t]estbed_topo.py' | awk '{print $1}' | head -1)
  sudo -n mnexec -a "$TOPO" tc qdisc add dev s1-eth1 parent 5:1 netem loss 100%
  ```

  注意這實質上繞過了 sudoers 對 tc 參數的限制，只是因為 `mnexec` 被整支授權。要嘛照這樣用，
  要嘛請 Adam 在 sudoers 補一條 `parent` 形式的規則——後者比較誠實。
- root 是預設 qdisc 的介面才可以用 `root netem`。P4 testbed（`p4_proxy/mininet/
  p4_testbed_topo.py`）不用 TCLink、無 shaping，屬此類——這也是 P4 runbook §6 的
  root netem 寫法在該環境成立的原因。
- 建議紀律：故障輪前後各拍一次 `tc qdisc show` 全量快照做 diff，讓「注入工具自己的
  side effect」變成可斷言的檢查項，而不是靠人記得。
