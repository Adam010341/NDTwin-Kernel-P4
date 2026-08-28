# NDTwin-Kernel 測試說明書（權威入口，2026-08-17）

**這一份是入口。** 想知道「我現在該跑什麼」，讀這份就夠；其餘七份測試文件是背景、歷史
或深入細節，各自的地位列在最後一節。

**要開機／收機，直接跳 §2**，那是完整的開機手冊。其餘各節刻意保持短——長文件會腐爛得比
它被讀的速度快。§2 之所以是例外，是因為開機的失敗模式沒有一個長得像失敗，短寫等於不寫。
**§2 裡「為什麼」一律收在摺疊區**，跳過摺疊區就能一路照著打完。

**適用範圍**：本 repo（kernel + P4 proxy）。跨元件串接看
`doc/2026-08-14_cross-component-integration-matrix.md`。

[Co-developed with claude code -- Adam]

---

## 1. 依意圖分派

| 我剛做了什麼 | 就跑這個 | 要多久／要什麼 |
|---|---|---|
| **要開機／收機／換拓樸／開 app** | **見 §2（開機手冊）** | `ndt up` 25–40 秒 |
| 改了任何程式碼，還沒 commit | `bash tools/test_workflow/run_layers.sh selftest` | 秒級，完全離線 |
| 改完想確認沒弄壞既有行為 | `bash tools/test_workflow/run_layers.sh quick` | 約 2 分鐘，不需要 Mininet |
| 準備 commit／想跑「CI」 | `bash tools/test_workflow/local_ci.sh` | 實測 234–272 秒，6 個 job（GCC 建置+直跑+ctest、Python L1、ASan+UBSan、TSan、clang、p4 覆蓋閘門）。**不 fail-fast**——一次看完所有壞掉的東西 |
| 只想跑單元測試 | `bash tools/test_workflow/l1_unit_tests.sh` | **ctest 與直跑兩種都跑**——ctest 每個 TEST_F 各自一個 process，跨測試污染只有直跑抓得到 |
| 改了 `.p4` | `tools/test_workflow/p4_coverage_gate.sh` | hash 沒變時 14ms；`--force` 強制實測 |
| 動了資料面／要驗一輪 live | 見 §2、§3 | 要起 fabric |
| 想確認 twin 沒說謊 | 見 §4 | 要起 fabric＋有流量 |

**Python 一律用 `p4_proxy/venv/bin/python`。** conda 的 `python3` 缺 grpc/networkx，壞掉的
套件在它底下看起來是綠的。且本 repo 走 `unittest` 不是 pytest——**看 `Ran N` 不要只看 `OK`**，
`__main__` guard 底下的測試根本不會被收集。

**目前基準線（2026-08-18 重跑，`b62bafe`）**：C++ **588 tests / 80 suites**、`p4_proxy/tests` **453 ran**（另 1 skipped＝`test_p4_client.py` 自己宣告要 live
switch，所以收集到的是 454）、`tests/python` **238**、`tests/shell/test_faults.sh`
**Ran 60 checks**、p4 覆蓋未覆蓋集 `[414..421]` 不變。數字對不上就是有人動了碼或收集壞了。

⚠️ **加測試的 commit 要回來更新這一行。** 本行第一版寫的是 579/78 與 Ran 454，當天稍後就被
`1b1f941`／`13e53df` 追過——於是「數字對不上＝有人動了碼」這句話把讀者指向不存在的問題，
說明書自己變成假警報的來源。

⚠️ **2026-08-18 更新**：`b62bafe`（`setupNFSForApp` 分辨「目錄已存在」與「建不出來」）
加了 3 條測試、1 個 suite，所以是 585/79 → **588/80**。前一版數字量於 `13e53df`。

📌 **通則：實測數字寫進文件時，一律把當時的 commit 標在旁邊**（像上一段的 `13e53df`）。
量測只對產生它的那版程式成立，而程式會動；沒有 commit，讀的人分不出「現況」和「歷史」，
於是過期的數字會被一直當成系統的性質引用。2026-08-17 同一天抓到兩個實例：上面那行活了
幾小時，而「OVS 斷鏈黑洞 291 秒零自癒」在修好它的 `034da18` 落地之後**又被引用了四天、
散進 11 個檔案**（重量結果與完整脈絡見 `doc/audit/2026-08-17_p4-vs-ovs-matched-topology/`）。
兩者寫下的當時都是正確的——標 commit 防不了數字過期，它防的是**下一個人看不出它過期了**。

---

## 2. 開機手冊

> ✅ **2026-08-21 從乾淨環境實跑驗證過**（`52cba51`）：P4 128 台與 OVS 128 台各一輪，
> 含清空、三個承諾的拒絕、跨象限連通性、收尾與 `clean` 斷言。**實跑推翻了本節初稿的三條**，
> 都已改正並標在原地（§2.1 的 veth、§2.2 的秒數、§2.3 的 `--check`）。
> 逐字輸出：`doc/audit/2026-08-21_bringup-manual-verification/TRANSCRIPT.md`。

**一切都走 `ndt`。** 它是 `tools/test_workflow/ndt`，`~/.local/bin/ndt` 有 symlink，
所以任何目錄下都能打。底層的 `ndtwin-lab` + `stack.sh` 仍然可用（見 §2.9 的摺疊區），
但**不要混用**——`ndt` 記帳、裸指令不記帳，混用就是 §2.10 的第一條。

### 2.0 三十秒版

```bash
ndt status          # 有人在用嗎？現在是什麼狀態？
ndt down            # 清空
ndt up              # 開 P4（預設）／ ndt up ovs 開 OVS
ndt down            # 收
```

**多人共用的機器，第一步永遠是 `ndt status`。** 它第一行就告訴你實驗室現在屬於誰。
不必去問別的 session。

---

### 2.1 先清空環境

```bash
ndt down            # 正常收：apps -> kernel/proxy/Ryu -> topo session -> 掃除
ndt clean           # 只驗不動手；exit 1 = 還有東西活著
```

`ndt down` 分四步印出來（`[0/3] apps` 只在真的有 app 在跑時出現）：

| 步驟 | 它做什麼 |
|---|---|
| `[0/3] apps` | 停掉 energy / sim / nsr / viz / te |
| `[1/3] kernel + proxy/Ryu` | 停 `.test_run/pids/` 裡登記的行程 |
| `[2/3] topology session` | `ndtwin-lab topo-stop`，關 Mininet |
| `[3/3] sweep` | `mn -c`，收殘留的 veth／namespace |

`ndt clean` 檢查五件事：bmv2 行程數、host/switch 行程數、topo tmux session、
switch manifest、以及 **:8000 / :8080 / :8081 三個 port**。全部過才印綠色 `clean`。

<details><summary>什麼時候需要 <code>ndt down --deep</code></summary>

`ndt down` **預設不碰不是它起的東西**。所以如果有人手動跑了一顆 kernel、或上一個
session 的殘骸還佔著 :8000，`down` 會**報告它、然後放著不動**：

```
XX  :8000 still listening -- this stack did not start it
```

這是刻意的：`--deep` 會殺掉佔住那三個 port 的任何行程，而那可能是別人正在用的東西。
確定機器是你的，才加 `--deep`。

`--deep` 自己也有兩道保險：不對 pid < 2 動手、不殺 `ndt` 自己；而如果 port 的持有者
查不出 pid（例如在別的 netns 裡），它會明說 `--deep cannot address it` 而不是假裝成功。
</details>

⚠️ **`ndt clean` 不看 veth / OVS bridge / netns / `tc netem` / `.test_run/`。**
正常路徑上 `[3/3] sweep` 的 `mn -c` 會清掉它們，但 `clean` **不斷言**它們。
做完故障注入（`faults.sh`）之後，要自己確認 `tc qdisc show` 是乾淨的——
`ndt status` 的 `tc netem` 那行會告訴你。

⚠️ **這台機器上永遠有 4 條 veth，它們不是殘留。**（2026-08-21 實測更正：本節初稿寫
「實測 0/0/0/0」，那是錯的。）三條掛在 `br-634fc31085ec`、一條掛在 `docker0`，
屬於 Docker 容器（Web-GUI 那組 `ndt-frontend` :3000 / `ndt-node-positions-api` :3001 /
`ndt-postgres` :5433，加一個 hugo 容器）。**數 veth 判斷乾不乾淨要扣掉這 4 條**，
或者只數名字像 `s1-eth1` 的那些。netem 和 OVS bridge 收乾淨後確實是 0/0。

---

### 2.2 開 bmv2 / OVS

**兩種 fabric 不能同時開**（`s1..s10` 介面名會撞）。`ndt up` 會自己擋下來，
但先 `ndt down` 比較快。

#### P4／bmv2　（實測 33.6 秒 @128 hosts，`52cba51`）

```bash
ndt up              # 用現在的 host 數（見 ndt status 的 hosts 欄）
ndt up 4            # 4 hosts
ndt up p4 128       # 128 hosts
```

三步：`[1/3] bmv2 fabric` → `[2/3] proxy + kernel` → `[3/3] verify`。

#### OVS／Ryu　（實測 24.1 秒 @128 hosts，`52cba51`）

```bash
ndt up ovs          # 128 hosts（NTG 自帶的 testbed_topo.py）
ndt up ovs4         # 4 hosts（P4 測試床的佈局搬到 OVS 上）
```

四步：`[1/4] control plane (Ryu)` → `[2/4] data plane (OVS fabric)` →
`[3/4] proxy-less convergence + kernel` → `[4/4] verify`。

⚠️ **OVS 只有 4 和 128 兩個尺寸，而且不是參數。** `ndt up ovs 16` 會被直接拒絕
（rc=2）。原因是尺寸由「跑哪個動詞」決定：`ovs-topo-start` 是別的 repo 寫死的 128、
`ovs-topo-4host` 是我們的 4，兩支都不吃 host 數。2026-08-21 之前 `ndt up ovs 16`
會**蓋一個 128 台的 fabric、載一份 16 台的模型，然後回報「model matches fabric」**。
要 16 台就用 `ndt up p4 16`。

<details><summary>為什麼兩種 fabric 的啟動順序是相反的</summary>

**南向連線的方向相反：**

- **OVS**：Ryu 是 server，switch 撥出去找它 ⇒ **Ryu 必須先聽好**，Mininet 才能起。
- **P4**：bmv2 是 server（`simple_switch_grpc` 聽 `0.0.0.0:50051-50060`），proxy 是
  gRPC **client** ⇒ **Mininet 必須先起**，否則 proxy 第一個 RPC 就 ECONNREFUSED，
  uvicorn 在開 :8081 之前就退出。

把兩者都當成「控制平面先起」就是以前 P4 模式壞掉的原因。`ndt up` 已經把順序寫死了，
這段是給要看底層或除錯的人。
</details>

<details><summary>關於 6653 / 6633：一條流傳很久的假警告（2026-08-21 更正）</summary>

**舊說法**：「Ryu 一定要聽 6653；照官方文件加 `--ofp-tcp-listen-port 6633`，
switch 仍去敲 6653，永遠連不上。」

**這是錯的。** `mininet/node.py` 的 `RemoteController.checkListening`：

```python
for port in 6653, 6633:
    if self.isListening( self.ip, port ):
        self.port = port; break
```

**兩個都探，誰應答就連誰**；只有兩個都沒人應才 fallback 成 6653。所以帶了
`--ofp-tcp-listen-port 6633` 的 Ryu，switch 探 6653 沒人、探 6633 有人 ⇒ **連 6633，通**。
三臂 live 實測（08-21，128-host）：帶旗標 10/10 connected、不帶旗標 10/10 connected、
照官方文件逐字 10 switches / 32 links。

**真正的失敗模式是順序，不是埠號**：Ryu 兩個埠都還沒聽的時候起 Mininet，
探測全滅 → fallback 6653 → switch 對著死埠撥，**而且任何 log 都不會提到 port**，
你只會看到拓撲永不收斂。

🔴 同一條假警告還躺在另外兩個地方，都還沒改：`tools/test_workflow/stack.sh:660-669`
的註解、以及 `doc/2026-08-16_delivery-package/docs-errata.md` 的第 1 條。
**那份勘誤在轉交給 patty 之前必須把第 1 條刪掉**，否則會去「修」一份本來就對的官方文件。
</details>

⚠️ **官方手冊（ndtwin.org/docs）仍有一處與本機不符**：`sudo ./testbed_topo.py` 會走到
`/usr/bin/python3`（缺 `nornir`/`loguru`，立刻 ImportError）。要用 ntg-env 的直譯器，
或直接讓 `ndt up ovs` 去起。

**Port 佈局**：kernel API **:8000**、P4 proxy **:8081**、Ryu **:8080**。
任何寫「kernel :8080」的舊筆記都是錯的。

---

### 2.3 確認真的開起來了

```bash
ndt status --check      # exit 非零 = 有東西會讓量測不可信
```

`ndt up` 的最後一步（`verify`）**已經送過真的封包**了——`mnexec -a <host-pid> ping`。
這一步存在的理由：**拓樸畫面十台全綠、網路完全不通，發生過兩次**，只有送封包抓得到。

🔴 **在 OVS 上 `--check` 永遠回 rc=1，而且那是假警報。**（2026-08-21 實測更正，
本節初稿把 `--check` 當成 OVS 的驗收關卡，那是錯的。）它會說：

```
network health
  links          288 total, 256 down, 0 admin-disabled
check: 1 problem(s)
  - 256 link(s) are down
```

**網路是好的**——同一輪的 h1→h64、h64→h128、h128→h1 全部 0% 掉包。
把 kernel 的圖逐條分類之後（不是靠 288−32=256 這種算術湊出來的）：

| 邊 | 數量 | `is_up` | `is_enabled` |
|---|---:|---|---|
| switch ↔ **host**（`dst_dpid=0`，例如 `dpid 1:3 → 10.0.0.1`） | **256** | `False` | `False` |
| switch ↔ switch（例如 `dpid 1:1 → dpid 5`） | 32 | `True` | `True` |

128 hosts × 2 = 256。**OVS 平面從來不把 host 邊標成 up**，而 P4 平面會
（同一天的 P4 輪：`288 total, 0 down`）。實測到 4 分鐘都沒動（`32 up / 256 down / 0 hosts up`
每 15 秒取樣一次），所以不是「還沒收斂」。

<details><summary>為什麼——不是設計決定，是資料對不上</summary>

邊的狀態不在模型檔裡。模型檔只有接線（`src_dpid`／`src_interface`／…），
`loadStaticTopologyFromFile` 把**每一條邊都設成 `isUp=false, isEnabled=false`**
（`TopologyAndFlowMonitor.cpp:318`），之後只有控制平面回報得到的才會被標 up。

host 邊是靠 `/v1.0/topology/hosts` 標的——一台 host 一條邊，**用 IP 去找**
（`findEdgeByHostIp`）。而在那之前有一道門：

```cpp
// TopologyAndFlowMonitor.cpp:618
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "Skipping host with no IPv4 address");
    continue;                      // ← 跳過，下面標 up 的兩行不會執行
}
```

**Ryu 回報了 128 台，但每一台的 `ipv4` 都是空陣列**（實測，剛開機時與 60 秒後都一樣）：

```json
{ "mac": "00:00:00:00:00:72", "ipv4": [], "ipv6": ["::", "fe80::200:ff:fe00:72"],
  "port": { "dpid": "0000000000000004", "name": "s4-eth20" } }
```

有 IPv6 沒有 IPv4。**而且灌真流量也不會變**——h1 對 10.0.0.2 與 10.0.0.64 各 ping 三次
全通之後再問，仍然是 128 台、0 台有 ipv4。所以不是「還沒學到」。

P4 那邊沒有這個問題，因為 **proxy 不用學、它直接從自己的模型 render**
（`ryu_topology.render_hosts`），128 台全部帶著 IP 出場 ⇒ 256 條邊全部標 up。

⇒ **兩個平面的差別不是「有人決定不標 host 邊」，是 Ryu 用學的、proxy 用宣告的。**

🔴 **Ryu 為什麼學不到 IPv4，還沒有結論。** 合理的懷疑是測試床設了 static ARP、
於是 host 從不送 ARP，而 Ryu 的 host tracker 正是從 ARP 取 IPv4 的（IPv6 走 NDP，
所以那一欄有值）。**但這個說法在 2026-08-11 被查過並否決**，而且當時的紀錄是
「128/128 都有 IP」——**跟今天的 0/128 直接矛盾**。兩個量測不可能都對，
中間有東西變了或條件不同，沒查清楚之前不要引用任何一邊當機制。
</details>

所以：

- **P4**：`ndt status --check` 回 rc=0 才算過。
- **OVS**：`--check` 一定 rc=1。**看它列出來的問題是不是只有「256 link(s) are down」**——
  只有這一條就是正常的；多出任何別的才要查。

⚠️ 這代表 **OVS 沒有一鍵驗收**。OVS 的驗收就看 `ndt up` 最後那行 `data plane: ... forwards`，
外加下面那張表。

要自己再驗一次，看 `ndt status` 的這三塊：

| 看哪裡 | 什麼叫對 |
|---|---|
| `running` | bmv2 10（P4）或 `:8080 ryu open`（OVS）、三個 port 該開的開 |
| `network health` | `switches 10 up, 10 enabled`、`links` 的 down 數是你預期的 |
| `kernel graph` | switch／host／edge 數要跟 `configuration` 的 topology 檔一致 |

⚠️ **`/ndt/get_cpu_utilization` 在 MININET 模式下是假的**——它回 `10 + hash(ip) % 50`，
恆定不動，而 Web-GUI 直接顯示它。要量 CPU 只能用
`tools/test_workflow/cpu_probe.py` 讀 `/proc`。

---

### 2.4 切換拓樸檔

**這裡有三層拓樸，來源各自不同**，這是最容易搞錯的一節：

| 哪一層 | 由什麼決定 | 誰在讀 |
|---|---|---|
| **fabric 真的接了幾台** | P4：`p4_proxy/mininet/host_count_override`<br>OVS：跑哪個動詞（`ovs-topo-start`=128 / `ovs-topo-4host`=4） | Mininet |
| **kernel 的模型** | `ndt up` 自動依 host 數挑；`NDT_TOPO=<檔>` 可強制 | kernel |
| **Ryu 的模型**（只有 OVS） | `NDTWIN_RYU_TOPO_FILE`，`ndt up ovs` 自動設成和 kernel 同一個檔 | `intelligent_router.py` |

日常用法就是**不要自己碰**——講 host 數就好，其餘 `ndt` 自己對齊：

```bash
ndt up 4            # 改 host_count_override -> 4，並挑 4 台的模型
ndt up p4 128       # 改回 128
```

`host_count` 必須是 4 的倍數且 ≥ 4（hosts 分散在 s1–s4）。改動會印黃字警告，因為
`host_count_override` 是**持久狀態**——下一輪繼承別人設的數字，就是量測描述錯網路的起點。

現有的模型檔：

| host 數 | P4 | OVS／Mininet |
|---:|---|---|
| 4 | `StaticNetworkTopologyP4_10Switches_4Hosts.json` | `StaticNetworkTopologyOVS_10Switches_4Hosts.json` |
| 8 / 16 / 32 / 64 | — | `StaticNetworkTopologyOVS_10Switches_{8,16,32,64}Hosts.json` |
| 128 | `StaticNetworkTopologyP4_10Switches_128Hosts.json` | `StaticNetworkTopologyMininet_10Switches.json` |

要用不照命名規則的模型：`NDT_TOPO=/path/to/model.json ndt up`。

<details><summary>為什麼不要自己 export <code>NDTWIN_RYU_TOPO_FILE</code></summary>

它**預設是 128 台的 Mininet 模型，不管 fabric 實際幾台**。2026-08-21 之前 `ndt` 只設
kernel 的模型、沒設這個，於是 `ndt up ovs4` 蓋了 4 台的 fabric、給 kernel 4 台的模型，
而 **Ryu 為 128 台裝路由**：每一對之間 100% 掉包，**而 kernel 的圖、Ryu 的
`/v1.0/topology/hosts`、`ndt` 自己的「model matches fabric」三個視圖全都顯示正確**。

這個變數有一個 reader、零個自動 setter——repo 裡唯一的 `export` 是某份報告裡手打的一行。
所以那一輪的數字是好的，之後每一次無人值守的跑都不是。現在由 `ndt up ovs` 設定，
自己 export 只會蓋掉它。
</details>

---

### 2.5 改實驗參數：bmv2 快慢版／host 數／取樣率

三個旋鈕，**代價差很多**：

| 改什麼 | 怎麼改 | 什麼時候生效 |
|---|---|---|
| host 數 | `ndt up 4` / `ndt up p4 128` | 下次開機 |
| bmv2 stock ↔ fast | 註解／取消註解 `p4_proxy/mininet/bmv2_binary_override` 那一行 | 下次開機 |
| **取樣率** | 改 `.p4` 裡的 const **＋重編 pipeline** | **要重編＋重起 fabric** |

`ndt status` 的 `configuration` 區塊會把三個當下的值一起印出來，開始量之前看那三行就好。

<details><summary>bmv2 的 stock 與 fast 差在哪、為什麼預設指向 fast</summary>

程式碼的**預設**是裸名 `simple_switch_grpc`（走 PATH → `/usr/local/bin/`，
**-O0、debug log 全開**）。實際在跑的是 `/usr/local/bmv2-fast/bin/simple_switch_grpc`，
因為 `p4_proxy/mininet/bmv2_binary_override` 這個**有進 git 的檔案**指過去。

**為什麼指過去（2026-08-17）**：stock 版大約 **22 Mbps** 封頂，而鏈路宣稱 1 Gbps
⇒ 利用率永遠在 ~2%，於是 energy app 的合併決策**對流量完全不敏感**（實測：有流量、
沒流量，同樣三台、同樣順序），TE 也永遠碰不到它的 70% 門檻。

它是**檔案不是環境變數**，因為 lab wrapper 用固定的 root 環境起拓樸，env var 到不了那裡。
`../lib` 會自動被當成 `LD_LIBRARY_PATH` 帶上——fast 版的函式庫必須跟著它的執行檔，
否則就是把 stock 的函式庫混進一份自稱 fast 的量測裡。

檔案在但內容壞掉（路徑不存在／不是絕對路徑）時**直接拒絕開機**，不會 fallback。
理由：fallback 等於用一個宣稱相反的檔名去 benchmark stock 版，而壞掉的比較比拒絕還糟。
</details>

<details><summary>取樣率為什麼沒有開機旋鈕</summary>

它是編譯期常數：

```
p4_proxy/p4_src/ndtwin_switch.p4:52:  const bit<16> SAMPLE_RATE = 256;
```

要改就得改 source → `p4c-bm2-ss` 重編 → **重起 fabric**（bmv2 在 exec 時載入 JSON，
之後永不重載）。零個環境變數、零個旗標。唯一自動化的是
`doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.sh`，那是實驗 driver 不是支援介面
（但它 `sed` 完會 `grep -q` 自證改成功，值得抄）。

`ndt status` 的 `sample rate` 是**讀回來對帳的**，不是設定值：它去解編出來的 JSON 裡
`random(0, N-1)` 的上界。存在的理由就是 2026-08-20 抓到 source 註解寫 256、
實際跑的 fabric 是 1024。

⚠️ **在 fabric 活著的時候重編，`status` 會說謊**——JSON 換了、switch 沒換。
`ndt status` 有 `stale_pipeline` 偵測（比對 build JSON 與 manifest 的 mtime）會提醒你，
但正解是：**重編完一定重起 fabric**。
</details>

---

### 2.6 跟 fabric 互動：Mininet CLI 還是 NTG prompt

**這兩個是二選一，開機時就決定，開起來之後不能切。**

```bash
ndt ntg             # 現在是哪個
ndt ntg cli         # 下次開機掉進 Mininet 的 CLI
ndt ntg prompt      # 下次開機交給 NTG 自己的 prompt
```

⚠️ `ndt ntg` 改的是**別的 repo** 的設定檔（`~/Network-Traffic-Generator/setting/Mininet.yaml`
的 `mode:`），所以它會印黃字警告。改完要下一次 `ndt up` 才生效，正在跑的拓樸維持原樣。

**Mininet CLI 常用**（在 `topo` 這個 tmux session 裡）：

```
nodes                 列出所有節點
net                   列出所有鏈路
h1 ping -c 3 h2       在 h1 裡 ping h2
h1 ifconfig           看 h1 的介面
pingall               全對 ping（128 台會很久，別隨手打）
iperf h1 h2           兩台之間量頻寬
sh <任何 shell 指令>   在 root namespace 裡跑
exit                  結束拓樸（＝關掉整個 fabric）
```

**NTG prompt**：`flow --config <檔>` 灌流量。
⚠️ **NTG 不支援中斷實驗**——中斷等於整個 NTG 關掉；要等所有非無限的 flow 自然結束。
kernel 還沒起來時 NTG 會卡在 `Failed to get hosts, retrying`，那是**預期的中間態**。

從外面不進 tmux 也能對 host 下指令：

```bash
sudo -n mnexec -a <host-pid> ping -c 2 10.0.0.2
```

---

### 2.7 開外部工具

```bash
ndt apps                    # 在終端機上不帶參數 = 互動選單
ndt apps nsr te             # 指名開
ndt apps stop all           # 全部停
```

| 名字 | 是什麼 | 會不會改變網路 |
|---|---|---|
| `energy` | Energy-Saving-App | 🔴 **會**——它會把 switch 關掉 |
| `te` | Traffic-Engineering-App | 🔴 **會**——它會裝流量規則 |
| `nsr` | Network-State-Recorder | 否，只讀 kernel API |
| `sim` | Simulation-Platform-Manager | 否 |
| `viz` | Network-Traffic-Visualizer | 否（JavaFX GUI，**要有顯示器**） |

**apps 刻意不算在 `ndt up` 裡面**：其中兩個會改變網路，所以「開了哪幾個」是每個實驗
setup 的一部分，不能是預設值。

<details><summary>不歸 <code>ndt</code> 管的兩個</summary>

- **Web-GUI**：`localhost:3000` 的 Docker 容器，生命週期比這裡的任何東西都長，
  用 docker 指令自己起停。這台機器**沒有 Node**，只能走 Docker，而且我們對它只有讀權限。
- **NTG**：它根本不是獨立行程，是拓樸腳本把控制權交出去的那個 prompt（見 §2.6）。

其餘七個兄弟 repo 的路徑都在 `tools/test_workflow/components.env`，那是路徑的唯一真實來源。
**別人的 repo 只測不改。**
</details>

---

### 2.8 收尾

```bash
ndt down            # 收
ndt clean           # 證明真的乾淨了；exit 1 = 沒有
```

`ndt down` 約 13 秒。細節見 §2.1（清空和收尾是同一件事）。

<details><summary>收到一半被 Ctrl-C 會怎樣（2026-08-21 實測）</summary>

SIGINT 打在 `[2/3]` 的結果**比預期好**：`ndt` 被 signal 2 殺掉、kernel 與 proxy 已經停了、
**fabric 完整留著**（不是半毀）、`ndt clean` **正確回報 not clean 且 rc=1**、
再跑一次 `ndt down` 完全復原。

也就是說：中斷之後**再跑一次 `ndt down` 就好**，不需要手動收拾。
但一定要跑 `ndt clean` 確認，不要假設。
</details>

---

### 2.9 開不起來怎麼辦

**已知的失敗全都不長得像失敗**——這張表就是為此存在的。

| 症狀 | 真正的原因 | 解法 |
|---|---|---|
| `kernel did not open :8000`，但環境看起來好好的 | kernel 用 `popen(curl)` 打 HTTP，而 `localhost` 在這台機器上走 IPv6 黑洞，SYN 被丟掉不是被拒絕 ⇒ 卡 **131 秒** | 已於 `b539be7` 修掉（加 `--connect-timeout 2 --max-time 10`、刪掉 `start()` 裡的同步呼叫）。**先確認你跑的 binary 真的重建過**，見下方 |
| `no lab sessions`，但 fabric 明明活著 | tmux 有控制終端時需要環境裡有 `TERM`（**沒 export 等於沒有**）；它的 stderr 被丟進 `/dev/null`，`\|\| echo` 把失敗寫成跟「真的沒有」一模一樣的字 | `ndt` 檔頭已 `export TERM="${TERM:-dumb}"`。裸跑 `ndtwin-lab status` 時自己帶 `TERM=dumb` |
| 拓樸永不收斂，log 完全沒提到 port | 起 Mininet 的時候 Ryu 還沒聽 ⇒ 探測 6653/6633 全滅 ⇒ fallback 到死埠 | **先確認 Ryu 在聽**再起拓樸。`ndt up ovs` 已經處理了（它等 `[2/3]` banner）。**不是埠號問題**，見 §2.2 的摺疊區 |
| 關機後送 `action=on` 回 **200 Success，但什麼都沒發生** | 電源開機在關機後約 10 秒內是 no-op，卻回報成功 | **關機後等 15 秒**再開機。示範前務必知道這條 |
| `ndt up` 說看到 orphan、把健康的 fabric 掃掉 | 上一條 `TERM` 的下游效應（session 被判成不存在） | 同上；已修 |
| 一切都對，但 host 之間 100% 不通 | Ryu 的模型和 fabric 尺寸不一致（見 §2.4） | 用 `ndt up ovs4` 而不是自己拼；不要自己 export `NDTWIN_RYU_TOPO_FILE` |
| `all_destination_paths` 抓到的路徑數比預期少 | 路徑集合**不是單調的**——會先漲到 16256 再掉回 13184，而 **kernel 只抓一次不重試** | 等它沉澱，不要單次取樣就下結論 |
| `pgrep -c simple_switch_grpc` 回 0，但 switch 在跑 | `/proc/<pid>/comm` 上限 15 字元，而這個名字有 18 個 | `ps -eo comm= \| grep -c '^simple_switch'`，或 `pgrep -cx simple_switch_g` |

**沒有頭緒的時候**：`ndt status --check` 會把所有「會讓量測不可信」的狀態一次列出來，
並且 exit 非零。日誌在 `.test_run/logs/`。

🔴 **`ndt status` 的 `code` 欄不能拿來判斷 binary 有沒有重建。** 它是 git HEAD ＋
未提交檔案數，講的是 **source**；binary 是不是那份 source 編出來的，它一個字都沒說。
改完 C++ 忘記重建，然後對著舊 binary 量一整輪——這個 repo 已經連續兩次栽在這上面，
而且兩次的數字看起來都很合理。真的要問 binary，比對時間：

```bash
ls -la build/bin/ndtwin_kernel
find src include -name '*.cpp' -o -name '*.hpp' | xargs ls -t | head -1
```

binary 比最新的 source **新**才算重建過（注意是 `build/bin/`，不是 `bin/`）。

<details><summary>底層路徑（<code>ndt</code> 本身壞掉時）</summary>

```bash
# P4
sudo -n /usr/local/sbin/ndtwin-lab topo-start
bash tools/test_workflow/stack.sh up p4
bash tools/test_workflow/stack.sh wait
bash tools/test_workflow/stack.sh down
sudo -n /usr/local/sbin/ndtwin-lab topo-stop

# OVS（要兩個終端機：stack.sh 會停在 Mininet 提示等你）
bash tools/test_workflow/stack.sh up ovs
sudo -n /usr/local/sbin/ndtwin-lab ovs-topo-start    # 另一個終端
# 回去按 Enter
```

**這條路徑不記帳**（`.test_run/pids/` 不會有登記），所以之後 `ndt down` 收不乾淨。
只在 `ndt` 自己壞掉的時候用，用完自己收。
</details>

---

### 2.10 絕對不要做，以及每一步該花多久

**黑名單：**

| 不要做 | 會發生什麼 |
|---|---|
| `pkill -f <任何字串>` | 🔴 **會殺掉你自己的 shell**——`-f` 比對整條 argv，而你的命令列裡就有那個字串 |
| 把量測指令直接打在命令列 | 同上的偵測版：`pgrep -f` 會匹配到自己。**寫進 script 檔**，script 的 argv 天然免疫 |
| `ifconfig <iface> down` 在 bmv2 上 | 🔴 **整台 switch 停止轉送**，不是斷一條鏈路。斷單鏈路一律 `tc netem loss 100%`，**兩端都要下** |
| 在 h2 裡面 `pkill` | Mininet 只隔離網路 namespace，**PID 空間跟 host 共用** ⇒ 殺全場 |
| 裸的 `sudo -n kill` 做訊號注入 | 本機 sudoers 沒授權 ⇒ **無聲失敗**，下游一切「正常」。用 `sudo -n mnexec -a 1 kill` |
| 開著 fabric 重編 P4 pipeline | `status` 的取樣率會說謊（JSON 換了、switch 沒換） |
| 混用 `ndt` 和裸 `ndtwin-lab` / `stack.sh` | `ndt` 記帳、裸指令不記帳 ⇒ `ndt down` 收不乾淨 |
| 沒設 `NDT_OWNER` 就跑 `ndt claim` 之外的指令 | 🔴 **任何 claim 都會被當成別人的**（安全預設），包括你自己剛剛下的 |

**時間預期表——超過就是卡住了，不是慢**（除註明外皆為 2026-08-21 `52cba51` 實測）：

| 動作 | 正常 | 其中 |
|---|---:|---|
| `ndt status` | 0.3–0.7 秒 | |
| `ndt up p4 128` | **33.6 秒** | bmv2 10 台 18 秒、路徑收斂 4 秒 |
| `ndt up ovs`（128） | **24.1 秒** | Ryu settle 10 秒、收斂 20 秒 |
| `ndt up ovs4` | 10–15 秒 | 未在本輪重測 |
| `ndt down` | **13.3–13.8 秒** | 空的實驗室只要 1.6 秒 |
| `ndt clean` | 0.1 秒 | |
| kernel 開 :8000 | 第一次 poll 就開 | 修好之前是 167 秒＋回報失敗 |

<details><summary>OVS 開機為什麼從 73 秒降到 25 秒（2026-08-21）</summary>

兩個原因，都在 `intelligent_router.py`：

1. **一行沒有任何記錄理由的 `hub.sleep(60)`**，支配了整個 OVS 開機。降到 10 秒後
   128-host 三次全通（h1→h64、h64→h128、h128→h1，跨核心跨象限）。
   `NDTWIN_RYU_SETTLE_S=60` 可以完全還原舊行為。
   **預設留 10 秒不是 3 秒**，因為原本的 60 秒沒有理由記錄，不知道它當初為何而設。
2. **`find_host_by_ip` 線性掃 `net.nodes`，被最內層迴圈呼叫**（128 台時 13.7×），
   已改成索引。順帶推翻一個數字：all-pairs walk 在 128 台是 **2.166 秒不是 ~60 秒**，
   而且 95% 不是裝規則。

⚠️ 這些都是**開機路徑**的量測。failover 的 walk 是不同的呼叫點，那個數字**還沒量過**。
</details>

---

### 2.11 補充：`ndt status` 逐欄解讀

```
lab
  claim          maindev-0821 -- 80m left (until 18:39:09)
  note           experiment: LLDP detection time at 4 vs 128 hosts
  measuring      nothing
  code           07ae07c  +4 file(s) with uncommitted changes
```

| 欄位 | 怎麼讀 |
|---|---|
| `claim` | 四種狀態措辭**刻意不同**：自己的／別人的名字／`EXPIRED`／`none`。過期的不會讀起來像活的。相對時間在前、絕對時間在括號 |
| `note` | 別人留的一句話，說他在做什麼 |
| `measuring` | 有沒有 `iperf3 -c` 在跑。**不是 nothing 就不要拆** |
| `code` | 現在這份 checkout 的 commit＋有沒有未提交的改動。**量測數字要跟這個 commit 一起記** |

```
configuration
  hosts / topology / bmv2 / sample rate
```
**這四行決定你量到的每一個數字。** 開始之前看一眼；寫報告的時候一起抄下來。

```
running / network health / kernel graph
```
見 §2.3。

**要保留實驗室**：

```bash
NDT_OWNER=<你的名字> ndt claim 60 "在量 X"
NDT_OWNER=<你的名字> ndt release
```

🔴 **`NDT_OWNER` 每一個指令都要帶，不只 `claim`。** 沒設的時候，**任何 claim 都算別人的**
（安全預設）——mainDev 08-21 就這樣被自己的 claim 擋在門外。被擋下來時訊息會先給你
`NDT_OWNER=<誰> ndt down`，`--force` 放在最後：照著 `--force` 打會拆掉真的有人在用的實驗室。

🔴 **claim 只擋 `ndt` 的動詞，擋不住裸指令。** 直接跑 `./bin/ndtwin_kernel` 或
`ndtwin-lab topo-start` 一樣會撞進去。**它是約定不是鎖。**

### 🔴 要獨佔 CPU 的量測：`NDT_EXCLUSIVE_CPU=1`（2026-08-28 新增）

```bash
NDT_OWNER=<你的名字> NDT_EXCLUSIVE_CPU=1 ndt claim 60 "六臂量測，不要開 VM"
```

**為什麼有這個欄位**：claim 保護 fabric 與 build，**從來不保護 CPU**。
08-28 一個 session 在另一個 session 的六臂量測窗內跑 4 vCPU 編譯，
**沒有碰 build、沒有碰 binary、沒有碰 fabric**——claim 涵蓋的東西一項都沒動——
而污染在六個臂之間**不對稱**，正好是那個實驗設計唯一無法吸收的形狀。

⚠️ **這件事當時記憶裡已經寫著了**（VM 不撞網路但搶 CPU/RAM/I-O，而沒有機制會通知別人）。
**知道不等於有機制**，所以這個欄位**同時**做了兩件事：

| | |
|---|---|
| **宣告** | `ndt claim` 寫 `exclusive_cpu=yes` |
| **讀取** | `ndt status` **無條件**印出來（不是加旗標才印），並且**把宣告與實際並排** |

`ndt status` 在有 claim 時一律顯示這一行，例如：

```
  exclusive cpu  yes (load1 3.2 on 14 cores -- holding)
                 🔴 do not start a VM, a compile, or any heavy local job
```

實際負載超過 `1.5 × 核心數` 時改印 **`yes -- but load1 is N ... so it is NOT holding`**，
並讓 **`ndt status --check` 失敗**。

🔑 **只加欄位不加讀取端等於沒做**——那只是把同一個失效換一個位置重演。
**門檻用 `load1` 不用 CPU%**：CPU 佔用率會在 1.0 飽和，機器滿了之後它就無法再表達有多滿；
`load1` 沒有上界。08-28 那次正是因為主判準選了有上界的量而漏掉的
（六臂 `busy_max` 全部 = 1.000，`Δbusy` 只有 0.005）。

📌 **門檻是拿當初那次事故校準的**：block 1 的 `load1` 是 27–31，門檻 `1.5 × 14 = 21`
⇒ **當時會被擋下來。**

---

## 3. 對跑著的 stack 驗契約（L2–L4）

```bash
bash tools/test_workflow/run_layers.sh api p4 --traffic     # 或 api ovs
bash tools/test_workflow/run_layers.sh baseline ovs --traffic   # 建 L4 基準（健康的 OVS 輪）
bash tools/test_workflow/run_layers.sh compare                  # P4 對 OVS 基準
```

`api` = L2 契約 + L3 元件依賴 + log 檢查。`--traffic` 額外要求真的有 flow/path/rate，
`--mutations` 才會去打寫入端點。工具本身在 `tools/contract_test/`，那裡的 README 解釋
為什麼「7 個元件與 kernel 之間唯一的介面就是 `/ndt/*`」使得在一處驗契約等於驗了全部地基。

**規格對照**：`doc/2026-01-02_ndt_api.md` 記載全部 **41** 個端點（§1–§41，與 dispatcher
逐條相符）；其中 **32** 個有機器檢查（2026-08-17 補上 `historical_logging` 三條與
`intent_translator/text` 的錯誤路徑一條）。剩下九條沒有：group／meter 各三（Tier 2，
裁決不動）、`link_failure_detected`／`link_recovery_detected`／`inform_all_destination_paths`
（proxy 每輪 live 都在打，只是沒契約測試）。

⚠️ **MUTATE 類檢查要 `--allow-mutations` 才會跑**，所以它們很久沒被執行過——2026-08-17
第一次跑就抓到兩條**自己壞掉的檢查**（`modify_nickname` 送 `nickname`、`modify_device_name`
送 `device_name`，文件規定的是 `new_nickname` 與 `new_name`，kernel 一直正確地回 400）。
**定期跑一次帶 `--mutations` 的輪次**，否則這一半的套件會靜靜爛掉。

⚠️ **跑完 `--mutations` 之後 `git status` 會髒**：`modify_device_name` 會讓 kernel 重寫
`setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`。即使寫回的是同一個名字，
kernel 的序列化器會把 `edges` 排到 `nodes` 前面、鍵序也不同，於是產生 ~1300 行的 diff
——**內容經解析比對完全等價**（2026-08-17 驗過），直接 `git checkout --` 還原即可。

---

## 4. 專用工具

| 工具 | 一句話 | 指令 |
|---|---|---|
| twin 測謊器 | 對帳 twin 宣稱的活流量與實際封包，說謊就 exit 1 | `p4_proxy/venv/bin/python tools/twin_audit/twin_audit.py audit` |
| 故障注入（L5） | 照 `faults.txt` 注入一個具名故障、證明它生效、還原 | `tools/test_workflow/faults.sh list` / `run L-2 --pair 10.0.0.1,10.0.0.2 --iface s1-eth1` / `run-all` |
| qdisc 前後快照 | 每輪注入的前後置，diff 不為空就作廢該輪 | `tools/test_workflow/qdisc_snapshot.sh`（`faults.sh` 自動呼叫） |
| sFlow fuzzer | libFuzzer harness（`-DFUZZING=ON`，clang-only） | `./build-fuzz/bin/fuzz_sflow <corpus> -max_total_time=5400 -timeout=5` |

**跑 `faults.sh` 前要知道的兩件事**（兩件都是它首役當場學到的）：

- **P4 stack 要 `export PATHS_URL=http://localhost:8081`**，否則 `criteria.py` 預設打 Ryu 的
  :8080，paths 通道整輪回 unknown，三通道法定人數**靜默**降成兩通道。
- **訊號注入不要用裸 `sudo -n kill`**：本機 sudoers 沒有 bare `kill` 的 NOPASSWD，注入會
  無聲失敗成 not-injected，而下游 capture 與 verdict 一切「正常」。用
  `FAULTS_KILL="sudo -n mnexec -a 1 kill"`。注入後一律斷言它宣稱的狀態改變
  （訊號驗 `/proc/<pid>/status` 的 `State`，qdisc 驗 `tc qdisc show`）。

**tc 的部分已經好了**：2026-08-15 Adam 補上兩條 `parent` 規則，`sudo -n -l`（08-17 複查）
四條全在，所以 `faults.sh` 預設的安全形式現在直接可用，不必再繞 mnexec。

---

## 5. 環境陷阱（只列最常咬人的，完整清單見 `doc/2026-07-29_environment_gotchas.md`）

**動到 fabric 的那些陷阱在 §2.10**（`ifconfig down`、`pkill -f`、Mininet 共用 PID 空間、
裸 `sudo -n kill`……）——那份表是唯一版本，這裡不重複，兩邊各寫一份就是它們開始分歧的起點。

以下是**建置與測試**這一側的，跟開機無關：

- TSan 一定要 `setarch "$(uname -m)" -R`，否則在 main 之前就 FATAL（`local_ci.sh` 已寫死）。
- 對未 commit 的檔案做 mutation 之前先 commit——`git checkout --` 洗掉過未提交的修復。
- **Python 一律用 `p4_proxy/venv/bin/python`**（見 §1）。conda 的 `python3` 缺 grpc/networkx。
- 監看用的 shell 迴圈要用 `pgrep -f "poll_al[l].sh"` 這種 bracket 寫法，否則會匹配到自己、
  永遠不結束（真的掛過 8 小時）。⚠️ bracket **只保護 pattern**——同一行指令裡任何地方
  （`echo` 標籤、變數預設值）出現同一個裸字串，一樣會匹配到自己。最穩的是把量測指令
  **寫進 script 檔**，script 的 argv 天然免疫。

---

## 6. 其餘七份測試文件現在的地位

| 文件 | 地位 | 什麼時候才需要它 |
|---|---|---|
| `2026-08-07_testing_tools_overview.md` | **參照**：每個工具的完整說明 | 要深入某個工具的設計與取捨時 |
| `2026-07-27_testing_workflow.md` | **參照**：L0–L5 五層架構的定義與理由 | 要新增一層或搬動層界時 |
| `2026-07-28_test_coverage_gaps.md` | **參照**：涵蓋範圍與已知缺口 | 要判斷某個東西有沒有被測到時 |
| `2026-08-10_p4_manual_test_runbook.md` | **手動 runbook**：P4 逐步一步一確認。⚠️ **其中的起停步驟已由 §2 取代** | 要人工走一輪 P4 的**驗證**部分時 |
| `2026-08-10_ovs_manual_test_runbook.md` | 同上，OVS | 同上 |
| `2026-07-30_full_test_runbook.md` | **歷史**：OVS+P4 各一輪的早期執行腳本 | 追溯當初怎麼建立基準時 |
| `2026-07-29_p4_status_and_test_guide.md` | **歷史**：2026-07-30 當時的 P4 進度與測法 | 追溯 P4 支援的演進時 |

**唯一的權威是這一份加上它指到的工具本身。** 上表任何一份與這裡衝突，以這裡為準；
與**程式碼**衝突，以程式碼為準，並回來修這一份。
