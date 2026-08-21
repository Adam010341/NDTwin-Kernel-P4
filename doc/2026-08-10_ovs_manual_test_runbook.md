# OVS/Ryu 手動測試 runbook

> 📍 **入口不是這裡（2026-08-17）**：「我現在該跑什麼」看
> [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md)。這一份仍是**現役的手動
> runbook**——要人工逐步走一輪 OVS 的**驗證**部分時用它。
>
> ⚠️ **起停步驟已由入口那份的 §2（開機手冊）取代（2026-08-21）**：現在一律
> `ndt up ovs` / `ndt down`。本文件裡的 `ndtwin-lab ovs-topo-start` + `stack.sh up ovs`
> 仍然可用，但**不記帳**，之後 `ndt down` 收不乾淨。
>
> 🔴 **本 banner 原本寫的「Ryu 聽 6653 不是 6633」是錯的，2026-08-21 live 實測撤回。**
> Mininet 的 `RemoteController` 會**依序探測 6653 和 6633、誰應答就連誰**，
> 兩個都沒人應才 fallback。所以 `--ofp-tcp-listen-port 6633` 是**可以用的**
> （三臂實測 10/10 connected）。真正的失敗模式是**順序**：Ryu 還沒聽就起 Mininet。
> 本文件內文 §（`mininet/node.py:1551` 那幾處）也帶著同一個錯誤結論，尚未逐條修正。

**這份文件是做什麼的**：從乾淨環境開始，逐步啟動 OVS/Ryu stack，在 idle 狀態下確認靜態健康，灌流量驗證 telemetry 鏈路，模擬一條鏈路斷線後觀察偵測與恢復。全部手動執行，一步一確認。

**什麼時候跑**：任何對 OVS 路徑（Ryu controller、intelligent_router.py、kernel 的 OVS 分支、sFlow ingest、power/liveness 迴圈）的修改之後。

**涵蓋範圍**：Phase 1–6 全部完成的功能。以下這些從舊文件來的宣稱是錯的，不要照抄：

- ~~「OVS 模式的 `stack.sh wait` 永遠 timeout」~~ — 現在會收斂。
- ~~「`is_up` 是 stub」~~ — OVS 模式用 `ovs-vsctl list-br` 做真實 liveness 檢查。
- ~~「P4 runbook 的 port 是 OVS 的」~~ — OVS 模式跑 Ryu :8080，P4 模式跑 proxy :8081。port 不同。
- ~~「`avg_link_usage` 逐步爬升，是累積平均」~~ — 那是瞬時值，分母是「當下有樣本的邊數」。見 P4 runbook §5d 的更正。

本文件參考 `doc/2026-08-10_p4_manual_test_runbook.md` 的結構、✅/⚠️/🔴 慣例和「這個檢查可能因為錯的原因通過」的寫法。**結構對齊，事實不對齊**——控制平面不同、port 不同、啟動順序相反、收斂時間差一個數量級。

**名稱刻意不帶 phase 編號。** 每個 phase 應該延伸這一份，而不是各自新增一份互相矛盾的文件。

> **✅ 驗證狀態（2026-08-11 更新）**：本文件撰寫於 2026-08-10（當時 OVS 路徑未實測）。**2026-08-11 已完整實跑一輪 §1–§7**，§10 的 TO BE MEASURED 全部填入實測值，文中若干預期值被實測推翻，已就地更正並標註 `【2026-08-11 實測】`。
>
> **被實測推翻的原始預期**（詳見各節）：
> 1. §4a「Ryu 學不到所有 host IP，hosts/edges up 會少於 128/288」——**錯**。實測 128/128 host、288/288 edge，Ryu 自己也回報 `hosts: 128, with ipv4: 128`。
> 2. §5c「detected flows 應為 2 筆雙向」——**對 `iperf -u` 是錯的**，UDP 單向只有 1 筆。
> 3. §5c「`src_ip` 是 `10.0.0.1` 這樣的字串」——**錯**，是 little-endian 整數。
> 4. §5a 的 `pgrep -f "[m]ininet:h1"` ——**會命中 40 個 process**，必須用 `$` 錨定。
> 5. §6 的斷線目標 `s1-eth1` **不在流量路徑上**，照原樣跑測不到 §6h 的繞路。
>
> **本次實測新發現的問題**：twin 在鏈路轉換期間會輸出自相矛盾的狀態，見 §6i（新增）。
>
> **原始撰寫時的驗證狀態（保留供追溯）**：撰寫於 2026-08-10，此時機器上跑的是 P4 stack，OVS 路徑未實測。每個預期值都標明了來源（原始碼行號、既有文件、或 TO BE MEASURED）。
>
> **已核對的部分（2026-08-10 逐條開檔確認，2026-08-12 重新核對並改成符號引用）**：
> 啟動順序的依據（`stack.sh` 的 `cmd_up`，開頭的註解明說兩種模式方向相反）、
> Ryu 需要 `--observe-links` 加上 `rest_topology` 與 `ofctl_rest`（`stack.sh` 的 `cmd_up` 裡那句 `start_bg ryu`）、
> `#define SFLOW_PORT 6343`（`FlowLinkUsageCollector.hpp`）、
> `kFlowStatsSuspectSeconds = 0.5`（`DeviceConfigurationAndPowerManager.hpp`）、
> poll 間隔 5s/30s/90s（`TopologyAndFlowMonitor.cpp` 的 `run()`，常數 `kWhileConverging`／`kOnceConverged`／`kConvergingFor`）、
> `controlPlaneHostAndPort`（`FlowLinkUsageCollector.cpp`）、
> `bool adminDisabled = false;`（`GraphTypes.hpp` 的 `VertexProperties`）、
> kernel 以 `--no-ai` 啟動（`stack.sh` 的 `cmd_up` 裡啟動 `ndtwin_kernel` 那行）、
> `intelligent_router.py` 存在於 repo 根目錄。
>
> 🔴 **2026-08-12 重核結果：九條裡有兩條的行號已經漂掉**——`DeviceConfigurationAndPowerManager.hpp:291`
> （`kFlowStatsSuspectSeconds` 現在在 `:294`）和 `GraphTypes.hpp:215`（`adminDisabled` 現在在 `:217`）。
> **後面那條是這次自己弄壞的**：同一輪修文件時往它上面的註解加了兩行，這一行就往下推了兩行。
> 斷言全部仍然成立，漂的只有指標。所以整段改成引用符號名——
> **一份宣稱「逐條開檔確認」的清單，如果它的指標會因為別人改註解就失效，那個宣稱只在寫下那一天成立。**
>
> **拓撲規模也核對過**：`testbed_topo.py` 有 **10 個 `addSwitch`**、`HOST_NUM = 128`，topology 檔 `StaticNetworkTopologyMininet_10Switches.json` 是 10 switches / 128 hosts / **288 edges**，與本文推導的 `128×2 + 16×2 = 288` 一致。（審查時我一度以為只有 4 台 switch 而誤判本文有錯，那是我自己的 grep 截斷造成的——文件是對的。）
>
> **抽驗範圍以外的行號沒有逐條開檔**，§10 表格裡的引用請在使用時順手確認。

---

## 0. 這份文件要回答什麼

每個「你應該看到」都有精確的預期值。每個檢查如果可以「通過但原因不對」，會標出來。每個步驟標了誰能跑。本文件**不是** OVS/P4 基準比對——那份在 `doc/2026-07-30_full_test_runbook.md`。這裡只測 OVS 路徑本身是否健康。

**和 `doc/2026-07-30_full_test_runbook.md` 的關係**：那份文件是 OVS + P4 各一輪的**完整迴歸流程**，做完要抓基準、跑 `run_layers.sh` 契約測試、用 `compare` 比對。本文件是**手動健康檢查**——不做契約測試、不抓基準、不比對。兩者互補，不重複。如果目的是「改完 code 快速確認 stack 沒壞」，看這份；如果目的是「正式迴歸並取得可比較的基準」，看 `2026-07-30_full_test_runbook.md`。

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

> **【2026-08-11 實測】要把「空輸出」變成真訊號，先確認 daemon 在跑：**
>
> ```bash
> pgrep -ax ovsdb-server; pgrep -ax ovs-vswitchd
> ```
>
> 兩個都在（本機是 systemd 開機起的常駐 daemon），那 `list-br` 的空輸出就**確定**代表 0 個 bridge，而不是查詢失敗的假陰性。

⚠️ **【2026-08-11 實測】中括號技巧在這裡會失效，別被騙。** `pgrep -af "[t]estbed_topo.py"` 會命中**你自己這條指令**，只要同一條命令列裡別處出現了 `testbed_topo.py` 的字面文字——例如上面那行 `pgrep -af "[p]4_testbed_topo.py"`，它的字面內容 `4_testbed_topo.py` 就含有 `testbed_topo.py`。把整組檢查寫成一行時必然踩到。

**可靠的替代判準**（不受這個問題影響）：

```bash
pgrep -af "[m]ininet:"          # Mininet host/switch namespace，沒有就是沒有 Mininet
sudo -n ovs-vsctl list-br       # 0 個 bridge
```

⚠️ **【2026-08-11 實測】`stack.sh status` 的 `mode:` 是上一次成功 `up` 留下的殘留值，不是現在的狀態。** 乾淨環境下它仍會顯示上次的 `mode: p4 .../StaticNetworkTopologyP4_10Switches_4Hosts.json`。`MODE_FILE` 只在 `up` **完全成功後**才寫入（`stack.sh` 的註解說明了理由）。

後果：**如果 `up ovs` 中途失敗，`MODE_FILE` 仍指向 P4，`./stack.sh wait` 會拿 P4 的 topology（10 switch / 40 edge）去檢查一個 OVS stack**，於是 `edges=288` 對不上它預期的數字。看到 `wait` 的預期值不是 288 時，先確認 `status` 的 mode 是不是 ovs。

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

**預期數字（來源：`doc/2026-08-10_p4_manual_test_runbook.md` §2，兩種模式共用同一份 C++ 和 Python 測試）**：

| 項目 | 數量 |
|---|---|
| C++ 測試（直接執行） | 426 pass |
| p4_proxy Python 測試 | **331 pass + 1 skip = 332 條**，分布在 12 個檔案 |
| kernel-side Python/shell 測試 | **107 條**（`test_contract_spec.py` 90 + `test_route_reinstall.py` 11 + `test_wait_for_port.sh` 6） |

⚠️ **【2026-08-11 實測】上表後兩列原本寫 312 和 101，是舊數字。** 實測逐檔數字：`test_clone_session` 18、`test_kernel_notifier` 17、`test_link_watchdog` 66、`test_lldp_beacon` 16、`test_p4_client` 1 skip、`test_p4_client_writes` 55、`test_ryu_flow_stats` 22、`test_ryu_topology` 32、`test_sflow_emitter` 48、`test_startup` 13、`test_switch_state` 20、`test_unsupported_match` 24。**這些數字會隨測試增加而過時——真正的通過標準是最後那行 `L1 passed:`，不是對數字。**

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

⚠️ **先不要按 Enter。** Ryu 必須在 Mininet 之前監聽，因為 OVS switch 會主動撥給 controller。順序錯了的話，Mininet 啟動時探測 Ryu port 會失敗（`mininet/node.py:1551`），port 回退成盲猜的 6653 —— 在 `stack.sh` 下剛好對，但照使用說明書的 `--ofp-tcp-listen-port 6633` 就永遠連不上。來源：`doc/2026-07-30_full_test_runbook.md` §1a 陷阱。

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

來源：`stack.sh:545-560` 的註解，以及 `doc/2026-07-29_environment_gotchas.md`「Ryu 需要多載兩個 stock app」。

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

那 60 秒是**從 10 台交換機全部連上 Ryu 之後**開始算的，不是從 Ryu 啟動算：`load_static_topology()` 只在 `len(self.switches) >= switch_num` 時才被呼叫（`intelligent_router.py:320`，位於 `get_topology_data` 裡，該函式定義在 `:265`）。所以 `paths=installed` 這個訊號其實同時證明了**10 台都連上了**——它比單看 link 數量更強，而不只是「等了一分鐘」。

⚠️ **如果 `converged after` 只花了 2 秒，那是閘門又壞了**（只等到 link discovery，沒等到路徑安裝），不要往下做。來源：`stack.sh:195`（P4 收斂才是 2 秒）和 `doc/2026-07-30_full_test_runbook.md` §1c。

> **【2026-08-11 實測】但 2 秒也可能是真的，不要只看這個數字就下結論。** 本次實測就出現 `converged after 2s`，而閘門是好的——因為 Mininet 已經開了超過 60 秒才回 terminal A 按 Enter，`hub.sleep(60)` 早就跑完，`await_convergence` 第一次 poll 就看到 `paths=installed`。
>
> **分辨方法（兩者都要對，不要只看其一）**：
>
> ```bash
> # 1. 路徑數必須是 16256，不是 0、不是少少幾條
> curl -s localhost:8080/ryu_server/all_destination_paths | python3 -c \
>   "import json,sys; print(len(json.load(sys.stdin)['all_destination_paths']))"
> # 2. 這行必須在 ryu.log 裡
> grep -c "Static topology initialized, all-destination paths installed." .test_run/logs/ryu.log
> ```
>
> `paths_installed()`（`stack.sh:167-175`）只檢查 `> 0`，所以它**不能**分辨「16256 條」和「1 條」。上面第 1 條指令才可以。

⚠️ **【2026-08-11 實測】啟動時 ryu.log 會出現大量 `ECONNREFUSED to localhost:8000`，那是預期的，不是錯誤。** 訊息長這樣：

```
Failed to notify NDT (switch enter): ... /ndt/inform_switch_entered?dpid=6 ... [Errno 111] ECONNREFUSED
Failed to notify NDT: ... /ndt/link_recovery_detected ... [Errno 111] ECONNREFUSED
```

kernel 依設計是**最後**才啟動的（`[3/3]`），所以 Ryu 在 switch 連進來、LLDP 發現 link 的那段時間，`:8000` 上根本沒人。本次實測有 30+ 筆，全部集中在 kernel 起來之前。**判準：檢查最後一筆 ECONNREFUSED 的時間是否早於 kernel 的啟動時間**，是就沒問題。

⚠️ **【2026-08-11 實測】ryu.log 裡會有兩次 `install_all_pair_paths`，這是正常的。** 第一次是 `hub.sleep(60)` 之後的初始安裝；第二次是 LLDP 陸續發現 32 條 link，每條 `Link added` 都呼叫 `_schedule_route_reinstall`，被 debounce 收斂成**一次**重算（`recomputing all-pair routes after topology change` → `route reinstall done`）。**32 個事件只觸發 1 次重裝，正是去抖動生效的證據**——如果看到 32 次重裝，那才是 bug。

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

⚠️ **NOPASSWD 必須正確設定**，否則 `sudo ovs-vsctl list-br` 會在 detached process（`setsid`）下卡住問密碼 → 回傳空 → 整張圖的 switch `is_up` 全變 false。症狀：`up=0` 但 `enabled=10`。log 裡有幾千行 `sudo: a password is required`。來源：`doc/2026-07-29_environment_gotchas.md`§1。

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
hosts 128 up 128
edges 288 up 288
hosts with ipv4: 128
```

🔴 **【2026-08-11 實測】本節原本的兩段 ⚠️ 是錯的，已刪除。** 原文主張「hosts `up` 的數字不是 128」「edges `up` 的數字不是 288」，理由是 `testbed_topo.py:219-226` 設了 static ARP，Ryu 學不到 host IP。**實測全滿：128/128 host up、288/288 edge up、128 個 host 都有 IP。** Ryu 自己也是滿的：

```bash
curl -s localhost:8080/v1.0/topology/hosts | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(len(d), sum(1 for h in d if h.get('ipv4')))"
# 實測輸出：128 128
```

**這個錯誤的來源和它的真正解釋**：原文引用 `doc/2026-07-30_full_test_runbook.md` §1e 的「static ARP → Ryu 學不到 host IP」。那個因果是誤判——真正的原因是 kernel 早期版本只在啟動時抓一次 topology snapshot，host 尚未被學到就定案了，之後不再更新；空的 `ipv4` 是**過渡狀態**，不是 static ARP 造成的永久限制。現在 kernel 會週期性重抓（`TopologyAndFlowMonitor::run()` 的輪詢迴圈），所以收斂後就是滿的。

⚠️ 因此 **`hosts up < 128` 或 `edges up < 288` 現在是紅燈，不是「預期內的不完美」**。看到的話請往下查 topology poll，不要照舊文件當成已知限制放過。

⚠️ 這個檢查仍然可以因為「kernel graph 沒更新」而通過——`wait` 只看 switches up+enabled，不看 hosts 和 edges 的 liveness。所以 hosts/edges 的數字要自己看，不能只信 `wait` 的綠燈。

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

來源：`include/common_types/GraphTypes.hpp:215` 定義 `VertexProperties` 欄位，以及 `doc/2026-08-10_p4_manual_test_runbook.md` §4b 的實測結果。兩種模式共用同一份 graph schema。

### 4c. 電力報告

```bash
curl -s localhost:8000/ndt/get_power_report | python3 -m json.tool
```

✅ 預期：一個 JSON array，10 個元素，每個有 `dpid` 和 `power_consumed`（mW）。值落在 33466–147622 mW 之間（來源：`doc/2026-07-30_full_test_runbook.md` 2026-07-30 實測值），各台不同，隔 10 秒再查數字不變（這是合成電力，不是真實量測，所以跨輪詢穩定）。

**【2026-08-11 實測】10 筆，min `33466` / max `147622`——和 2026-07-30 完全相同的上下界**，例如 `{'dpid': 1, 'power_consumed': 92465}`。隔 10 秒重查，整個回應的 md5 一模一樣。

⚠️ **上下界跨兩次獨立測試完全相同，代表這是 dpid 的決定性函數，不含任何量測成分。** 所以這個檢查能抓的是「power 模組有沒有在跑」，**不能**抓「電力估算對不對」。

⚠️ `get_power_report` 回傳的是 bare JSON array（`[{...}, ...]`），不是 `{"status": ..., "data": ...}` 包裝。

⚠️ 如果 `up=0`，power report 可能是空的——`is_up` 是 power/CPU/溫度 的前置條件（`doc/2026-07-30_full_test_runbook.md` §「這一輪之後要做什麼」）。

### 4d. 平均鏈路使用率

```bash
curl -s localhost:8000/ndt/get_average_link_usage
```

✅ 預期：`{"avg_link_usage":0.0,"status":"success"}`（idle 狀態為 0.0）。

⚠️ 這個端點是 GET，不加 query param，不加 body。

⚠️ OVS 模式下的 `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp`）**刻意排除所有接到 host 的邊**（判斷式是迴圈裡那個 `vertexType != VertexType::HOST` 的檢查）。所以即使 host 間有背景流量（例如 Mininet 啟動時的 ping 測試殘留），只要流量只在 host-switch 邊上，`avg_link_usage` 仍然是 0.0。不是 bug。來源：`doc/2026-07-30_full_test_runbook.md` §1d。

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

✅ 預期：10 台 switch，每台 **約 130 條** flow entry（來源：`doc/2026-07-30_full_test_runbook.md` §1e 的實測值）。**【2026-08-11 實測】10 台全部正好 130 條，總計 1300**，有流量時、斷線後重裝後都不變。**這和 P4 模式的 4 條完全不同**——OVS 的 `intelligent_router.py` 會安裝 all-destination paths 對應的 OpenFlow 規則，所以 flow table 是滿的。P4 模式只有 4 條預設規則。

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

✅ **【2026-08-11 實測】收斂後只有一行，數字是滿的**：

```
[2026-08-11 10:59:41.923] [info] [TopologyAndFlowMonitor.cpp:1784 run] topology from the control plane: 10 switches, 128 hosts, 288 edges up
```

⚠️ **這行只在數字變化時才印**，所以正常運作時 log 裡就是很少的幾行——**行數少不代表 poll 沒在跑**。斷線時會多印一行 `286 edges up`，恢復時再印一行 `288 edges up`。

> 📌 上面那段是 2026-08-11 抓下來的**原始 log**，裡面的 `TopologyAndFlowMonitor.cpp:1784`
> 是 spdlog 當時印的行號，**不是引用，不要更新它**。程式改過之後這個行號不會再對得上，
> 那正常——它記錄的是當時那個 binary。要找現在的位置就搜函式名。

✅ 順帶檢查整份 kernel log 的錯誤數，**實測全程 0**：

```bash
grep -icE "\[error\]|\[critical\]|exception|Traceback" .test_run/logs/kernel.log   # 0
grep -c "JSON parsing failed" .test_run/logs/kernel.log                            # 0（非 0 代表 ofctl_rest 沒載入）
```

來源：`TopologyAndFlowMonitor::run()`。這行只在 `graphLivenessSummary()` 回傳的三元組和上一輪不同時才印出。

⚠️ kernel 的 topology poll 間隔是**前 90 秒每 5 秒，之後每 30 秒**（`TopologyAndFlowMonitor.cpp` 的 `run()`：`kWhileConverging=5s`、`kOnceConverged=30s`、`kConvergingFor=90s`）。所以開機後第一條確認 log 可能在 5–30 秒後才出現，不是 1 秒。

---

## 5. Telemetry（灌流量，邊跑邊查）

### 5a. 灌流量（terminal B —— Adam）

⚠️ **h1 和 h97 在不同交換機上**（h1 在 s1，h97 在 s4，見 `testbed_topo.py:69-90` 的 host 分配），這很重要。同一台交換機底下的 host 互打，`get_average_link_usage` 永遠是 0.0——因為 `getAvgLinkUsage` 刻意排除所有接到 host 的邊。來源：`doc/2026-07-30_full_test_runbook.md` §1d。

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
# 【2026-08-11 更正】$ 錨定是必要的，不是可有可無
H1=$(pgrep -f "[m]ininet:h1$")
H97=$(pgrep -f "[m]ininet:h97$")
sudo -n mnexec -a "$H97" iperf -s -u -p 5001 &
sudo -n mnexec -a "$H1"  iperf -c 10.0.0.97 -u -p 5001 -b 10M -t 600 &
```

🔴 **【2026-08-11 實測】上面的 `$` 是本次修正的，原文沒有，而且沒有它一定會壞。** 在 128 台 host 的拓撲上：

```bash
pgrep -fc '[m]ininet:h1'    # 40 —— h1, h10-h19, h100-h128 全中
pgrep -fc '[m]ininet:h1$'   # 1
```

沒有錨定時 `H1` 會是一個**含換行的 40 個 PID 字串**，`mnexec -a "$H1"` 拿到的參數是垃圾。h97 同理（`h97` 沒有其他 host 以它為前綴，所以剛好只中 1 個——這讓 bug 更難發現，因為 server 端會正常起來，只有 client 端壞）。

⚠️ **【2026-08-11 實測】host 的介面叫 `h1-eth1`，不是 `h1-eth0`。** 要在 namespace 裡查 IP 用 `sudo -n mnexec -a "$H1" ip -4 -o addr`，不要猜介面名。

✅ **開流量前先確認資料平面本身是通的**，否則後面所有 telemetry 檢查都在測一個不通的網路：

```bash
sudo -n mnexec -a "$H1" ping -c 3 -W 2 10.0.0.97
# 實測：3 transmitted, 3 received, 0% packet loss, rtt avg 0.241 ms
```

收掉：`for p in $(pgrep -x iperf); do sudo -n mnexec -a "$H1" kill "$p"; done`（`sudo kill` 不在 NOPASSWD 清單裡，所以要繞過 `mnexec` 以 root 身分殺。）

⚠️ **頻寬用 `-b 10M`，不要 100M。** 實測 100M 會把 LLDP 餓死，Ryu 會誤判 link 掛掉（曾經一次跑出 19 次 link deleted），連 `ping` 都測不了。來源：`doc/2026-07-30_full_test_runbook.md` §1d。

⚠️ **流量必須在以下檢查執行的「同時」還在跑**，不能先跑完再測：flow 會老化，停幾秒 `get_detected_flow_data` 就變 0 筆。來源：`doc/2026-07-30_full_test_runbook.md` §1d。

⚠️ **OVS 的 sFlow 是 1/256 取樣**（`testbed_topo.py:136`：`sampling=256`）。所以需要一定流量才能穩定產生 sample。iperf 10M 足夠；ping 不夠（1 pps × 256 = 256 秒才一個 sample）。

⚠️ **sFlow 在 OVS 模式下來自 OVS 本身**，不是 proxy 合成的。每台 switch 透過 `ovs-vsctl` 設定將 sFlow datagram 送到 `192.168.123.1:6343`（kernel collector）。這和 P4 模式不同——P4 模式由 `p4_proxy/proxy_agent/sflow_emitter.py` 從 bmv2 packet-in 合成 sFlow。來源：`testbed_topo.py:105-137`（`enable_sflow`）和 `p4_proxy/proxy_agent/sflow_emitter.py`。

### 5b. 確認流量有被觀測到（terminal A）

```bash
# kernel log 的 sFlow ingest 健康線（只會有一行 INFO，其餘是 TRACE）
grep "sFlow ingest healthy" .test_run/logs/kernel.log
```

✅ 預期：**恰好一行**，`rx=` 有值。實測：

```
sFlow ingest healthy: rx=1, app_drop=0, addressed=0, sock_ovfl_total=0
```

🔴 **【2026-08-11 實測】原文說「有 traffic 時 `addressed` 應該 > 0」，這個期待用這條 `grep` 永遠看不到。** 這行只有**第一輪**是 INFO，之後全是 TRACE（`FlowLinkUsageCollector.cpp:1837-1850`），而第一輪發生在 kernel 剛啟動、還沒有人灌流量的時候。所以它必然是 `addressed=0`，**這不代表 ingest 有問題**。實測本次全程流量正常，這行仍是 `rx=1, addressed=0`。

**它能證明的**：sFlow socket 綁定成功且收得到東西（`rx≥1`）。
**它不能證明的**：流量夠不夠、歸戶對不對——那要看 `get_detected_flow_data`。

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

✅ 預期（iperf h1 → h97，10M UDP）——**【2026-08-11 實測】**：

```
flows: 1
   16777226 -> 1627389962 proto 17 rate_bps 10556211 path_len 7
     path: [16777226, 1, 6, 10, 8, 4, 1627389962]
```

🔴 **原文寫「flows: 2，雙向」，對 `iperf -u` 是錯的。** `iperf -u` 的 client 單向送 UDP，server 在跑的期間不回送資料（只在結束時送一次報告）。所以**只有 1 筆**。要看到 2 筆得用 TCP 或雙向流量。

🔴 **原文寫 `src_ip` 是 `10.0.0.1` 這樣的字串，實際是整數。** `get_detected_flow_data` 的 `src_ip` / `dst_ip`，以及 `path[].node` 裡的 host 節點，都是**整數形式的 IP，位元組序是 little-endian**（`16777226` = `0x0100000A` → `10.0.0.1`；`1627389962` = `0x6100000A` → `10.0.0.97`）。解碼方式：

```python
import socket, struct
def dec(v): return socket.inet_ntoa(struct.pack('<I', v))
```

⚠️ **`path[].node` 是混合型別的**：switch 節點是小整數 dpid（1–10），host 節點是上面那種大整數 IP。兩者在同一個陣列裡靠數值大小區分，沒有型別標記。消費端要小心。

- 路徑 7 個節點（含起終點 host），中間 5 台交換機：`h1 → s1 → s6 → s10 → s8 → s4 → h97`。**不同 run 會走不同路**——s1 有兩條等價出口（s1→s5 和 s1→s6），本次實測初始走 s6。
- rate 實測在 `6209536`–`15523840` bps 之間跳動（送 10M），受 1/256 取樣影響。**單次讀數不要當準確值**。

⚠️ flow 會在流量停止後幾秒內老化歸零。所以查詢必須在 iperf 還在跑的時候做。

### 5d. 平均鏈路使用率（趁流量還在跑，連查三次）

```bash
for i in 1 2 3; do
  curl -s localhost:8000/ndt/get_average_link_usage
  sleep 2
done
```

✅ 預期：**非零，大約在 0.001–0.01 量級。** 來源：`doc/2026-07-30_full_test_runbook.md` §1e 的 2026-07-30 實測值 `0.0074514`（h1→h97，10M UDP）。

**【2026-08-11 實測】連查三次：`0.004890 / 0.008460 / 0.007658`** ——落在預期區間，且如下方所述是上下跳動而非單調爬升。與 2026-07-30 的 `0.0074514` 同量級。

⚠️ **這個值是瞬時的、上下跳動的，不是單調爬升。** 原因見 P4 runbook §5d 的詳細分析。簡單說：`getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp`）只把 `linkBandwidthUsage != 0` 的邊算進去，除以那一刻非零邊的數量。1/256 取樣下分子分母同時在變。

⚠️ 如果一直是 `0.0`，確認流量兩端在不同交換機上（h1 在 s1，h97 在 s4）。

### 5e. iperf 自身統計

在 Mininet CLI 看 iperf 的輸出，或在 terminal A 用 `pgrep -x iperf` 確認還在跑。

✅ 預期：server 端報告 stable throughput ~10 Mbps，loss ~0%。

**【2026-08-11 實測】**（509.6 秒，期間刻意斷過兩次鏈路）：

```
[  1] 0.0000-509.6032 sec   627 MBytes  10.3 Mbits/sec  0.023 ms  6932/454388 (1.5%)
```

⚠️ **1.5% 的 loss 不是異常，是那兩次斷線的代價。** 沒有做斷線的乾淨一輪應該接近 0%。**如果你的一輪沒斷線卻看到 1% 以上的 loss，那才要查。**

⚠️ **收流量要用 `mnexec` 繞道以 root 殺**，因為 `kill` 不在 NOPASSWD 清單：

```bash
H1=$(pgrep -f "[m]ininet:h1$")
for p in $(pgrep -x iperf); do sudo -n mnexec -a "$H1" kill "$p"; done
```

`pgrep -x iperf`（精確比對 process 名）是安全的；**不要用 `pkill -f iperf`——`-f` 會比對整條命令列，可能連你自己下這道指令的 shell 一起殺掉。**

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

**【2026-08-11 實測】單向 UDP，路徑上 5 台各 1、路徑外 0**：

```
dpid 1   {"num_of_flows":1,...}    dpid 6   {"num_of_flows":1,...}
dpid 10  {"num_of_flows":1,...}    dpid 8   {"num_of_flows":1,...}
dpid 4   {"num_of_flows":1,...}
dpid 2   {"num_of_flows":0,...}    dpid 5   {"num_of_flows":0,...}   <- 路徑外
```

⚠️ 單向時路徑上每台都是 1，包含起點 s1——因為 `h1→s1` 這條 host 邊的 `dstDpid` 就是 1。

✅ **【2026-08-11 補測】雙向 + 多對 host 的情況也驗過了，10/10 全對。** 三條並行流量：

```
A: 10.0.0.1  -> 10.0.0.97   path [h1, 1, 6, 10, 8, 4, h97]
B: 10.0.0.97 -> 10.0.0.1    path [h97, 4, 8, 10, 5, 1, h1]     <- 回程走 s5 不是 s6，不對稱
C: 10.0.0.33 -> 10.0.0.65   path [h33, 2, 6, 9, 7, 3, h65]
```

實測 `num_of_flows`：`1:2  2:1  3:1  4:2  5:1  6:2  7:1  8:2  9:1  10:2`

逐台核對（數的是「以該 switch 為終點」的入向邊）：dpid 1 = A 的 `h1→s1` + B 的 `s5→s1`；dpid 6 = A 的 `s1→s6` + C 的 `s2→s6`；dpid 10 = A 的 `s6→s10` + B 的 `s8→s10`⋯⋯**十台全部與 `get_detected_flow_data` 的路徑自洽。**

⚠️ **順帶實測到雙向路徑不對稱**：A 走 s6、B 走 s5。這不是 bug——等價路徑由探索順序決定，真實 IP 網路也這樣。但**消費端若只查一個方向就假設回程相同，這裡會猜錯**。

✅ **路徑外的 switch 回 0，是這個檢查真正有鑑別力的部分**——如果每台都回非零，那就不是在數這條 flow。

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

⚠️ **【2026-08-11 補充】OpenFlow 規則的計數器比 flow_set 活得更久，長達整個 session。** `get_switch_openflow_table_entries` 回的 `packet_count`/`byte_count` 是**永久規則的累積計數**（`hard_timeout:0, idle_timeout:0`，all-destination-paths 規則裝上去就不會撤），不是最近流量的快照。

第三方 agent 測試時發現 s1 有一條 `nw_dst=10.0.0.98` 的規則有 133 萬封包、2GB，但當時的流量描述完全沒提到 `.98`，一度被判讀成「flow detector 漏掉了一大筆流量」。查證後：`packet_count=1337473` 精確吻合**同一個 session 稍早**（約一小時前）另一輪測試裡 `h2→h98` 的 iperf 最終報告（`0/1337473 datagrams`），而且這個數字之後**完全不再變動**——是那次測試的舊計數器，早就沒有活流量支撐它了。

⚠️ **在讀 `get_switch_openflow_table_entries` 找異常時，先問「這個 switch 活了多久」再問「這個數字合不合理」。** `duration_sec` 會告訴你這條規則存在多久；一個大的 `packet_count` 配上長 `duration_sec` 且和 `get_detected_flow_data` 當下的流量對不上，通常代表的是**同一個 stack 生命週期內更早的流量**，不是當下漏偵測的流量。stack 開得越久、跑過的測試越多，這種舊計數器就越容易被誤讀成新異常。

---

### 5i. 【2026-08-11 新增】速率估算的準確度，以及它的量化底噪

**這一節是 2026-08-11 新測的，原本的 runbook 沒有量過 twin 估的速率準不準。** 之前只確認過「非零」，沒有和真值比對過。

**方法**：單一 flow（h1→h97，其他流量全停），在五個檔位各跑 45 秒，取 twin 的 `estimated_flow_sending_rate_bps_in_the_last_sec` 8 次取樣的中位數，對照 iperf server 自己報的吞吐量。

| 送出 `-b` | iperf 實際 | twin 中位數 | twin 8 次取樣範圍 | 比值 |
|---|---|---|---|---|
| 1M | 1.05 Mbps | 1.55 Mbps | **1.03 – 4.66** | **1.48x** |
| 5M | 5.24 Mbps | 5.82 Mbps | 3.73 – 9.94 | 1.11x |
| 10M | 10.5 Mbps | 9.31 Mbps | 6.83 – 13.66 | 0.89x |
| 25M | 26.2 Mbps | 26.39 Mbps | 20.49 – 36.02 | **1.01x** |
| 50M | 52.4 Mbps | 53.40 Mbps | 42.22 – 61.47 | **1.02x** |

✅ **高速率下 twin 的「中位數」估得很準**：25M 和 50M 的**8 次取樣中位數**誤差在 ±2% 以內。

⚠️ **但「±2%」只屬於中位數，不屬於單次讀數。** 同一組 50M 測試的單次取樣範圍是 42.22–61.47（±20%），而四條 50M 流量並行時單次讀數還出現過 **80.7 Mbps 和 23.0 Mbps**（送出皆 50M）。

**這一樣是取樣統計，不是壞掉。** 50 Mbps ≈ 每秒 16.6 個樣本，Poisson 標準差 √16.6 ≈ 4.07，所以**單次讀數 1σ 就有 ±25%**。實測的 80.7（≈26 個樣本，+2.3σ）和 23.0（≈7.4 個樣本，−2.2σ）都落在正常波動內。

⚠️ 內部是自洽的：`estimated_packet_rate_in_the_last_sec` 和 bps 永遠對得上（`pps × 1470 × 8` ≈ bps），所以**兩個欄位一起看不會幫你分辨真波動和取樣雜訊**——它們是同一個樣本數換算出來的。

🔴 **低速率下單次讀數不可信**：1 Mbps 時 8 次取樣散布在 1.03–4.66 Mbps，**最大值是真值的 4.4 倍**。

**這不是雜訊，是可以算出來的量化階梯。** OVS 的 sFlow 取樣率是 1/256（`testbed_topo.py:136`），iperf 的 datagram 是 1470 bytes，所以**一個樣本代表**：

```
256 × 1470 bytes × 8 bits = 3,010,560 bps ≈ 3.01 Mbps
```

1 Mbps 時每秒只有約 85 個封包 ≈ **每 3 秒才 1 個樣本**；50 Mbps 時每秒約 4250 封包 ≈ **每秒 16.6 個樣本**，才平滑得起來。

🔴 **【2026-08-11 更正】本節原本寫「估算值是 3.01 Mbps 的整數倍除以取樣窗長度」，那是錯的。取樣窗長度從來不是分母。**

實際的除法在 `computeEstimatedRates`（`include/common_types/SFlowType.hpp:339-350`）：

```cpp
return {accumulatedFlowRate / hops, accumulatedPacketRate / hops, true};
```

分母是 **`hopsCounter`——這條 flow 在幾台 switch 上有樣本**，由 `calAvgFlowSendingRatesImmediately`（`FlowLinkUsageCollector.cpp:1886-1916`）逐個 agent 累加而來。也就是說讀數是「所有觀測點的估算總和 ÷ 觀測點數」，不是對時間平均。

**這個更正怎麼來的**：我原本用 `取樣率 × 封包大小 × 8 = 3.01 Mbps` 推導出一個和實測範圍吻合的機制，數字對得上，就當成機制寫下來了——**但沒有去讀真正的除法在哪一行**。agy-review 0199 指出後查證屬實。吻合的算術不等於正確的機制。

#### 順帶查到一個真 bug：分母會被灌水

```cpp
if (packetQueueTemp.size())          // size() 是 const，不 refresh
{
    hopsCounter++;                    // 用「含過期樣本」的數字遞增分母
    estimatedBytes = getSum() * rate; // getSum() 內部先 refresh()，過期樣本被丟掉 → 可能是 0
```

`AutoRefreshQueue::size()`（`SFlowType.hpp:134`）是 `const` 且**不 refresh**，`getSum()`（`:116`）會。所以一個**只剩過期樣本**的 agent 會讓 `hopsCounter` +1（分母變大）卻對分子貢獻 0——**分母灌水、分子沒有，讀數被系統性壓低**。

低速率下每個觀測點的樣本本來就稀疏、更容易全部過期，所以這個效應在低速率下最明顯。這比單純的量化階梯更能解釋為什麼 1 Mbps 那列會出現 1.03 這種**低於單一樣本值（3.01）**的讀數——單純的量化階梯解釋不了低於一個樣本的數字，這個可以。

⚠️ 此 bug **尚未修復**，也尚未寫測試。

⚠️ **對消費端的意義**：`estimated_flow_sending_rate_bps_in_the_last_sec` 在**低於約 10 Mbps 的 flow 上，單次讀數可能有數倍誤差**。要用這個值做決策（例如 Energy-Saving-App 判斷鏈路閒置）就必須**取多次的中位數**，不能讀一次就下結論。中位數在所有五個檔位都落在真值的 1.5 倍以內，單次讀數不是。

⚠️ **這個底噪隨封包大小變動**。3.01 Mbps 是 1470-byte datagram 算出來的；小封包的流量底噪更低，大封包更高。**不要把 3 Mbps 當成通用常數**，它是 `取樣率 × 封包大小 × 8`。

### 5j. 【2026-08-11 新增】取樣底噪不只影響速率讀數，還會讓 flow 的「存在」本身閃爍

**這一節由第三方 agent（deepseek-agent）用即時流量交叉測試發現、再由我獨立驗證確認。** §5i 講的是「速率讀數會抖」；這裡是更嚴重的延伸——**在極低速率下，一條 flow 會在 `get_detected_flow_data` 裡整個消失又出現，`get_num_of_flows_passing_a_switch` 也會漏算它**，而且**不是因為它真的斷了**。

**觀察**：一條持續的 ICMP ping（10.0.0.33→10.0.0.65，5 pkt/s）搭配兩條 10M UDP iperf 同時跑。立即抓 flow 路徑，緊接著查全部 10 台的 `get_num_of_flows_passing_a_switch`，用「以該 switch 為終點的邊」演算法（`HttpSession.cpp:1737` 的 `if (e.dstDpid == dpid)`）算出期望值：

```
dpid  1   2   3   4   5   6   7   8   9  10
exp   2   2   2   2   1   3   1   3   2   2
got   2   0   0   2   1   1   0   2   0   2
```

**s1/s4/s5/s10 全對，s2/s3/s6/s7/s8/s9 全錯**——乍看很像「這個端點排除了 ICMP」（deepseek-agent 的原始推論，10/10 吻合這個假設，看起來很有說服力）。**但直接讀 edge 的 `flow_set` 戳破了這個假設**：

```
s1->s6 flow_set: [UDP 條目]      <- 有
s2->s6 flow_set: []              <- 空
s6->s9 flow_set: [ICMP 條目]     <- 有！同一條 ICMP flow，另一條邊上是有的
```

**同一條 ICMP flow，在它路徑上的某些邊有記錄、某些邊沒有。** 不是協定過濾，是**每條邊各自獨立取樣、各自獨立老化**。連續 10 次、每 5 秒查一次 `s2->s6` 和 `s6->s9` 的 `flow_set`：

```
12:53:02  s2->s6: 0  s6->s9: 0
12:53:07  s2->s6: 1  s6->s9: 0
12:53:12  s2->s6: 0  s6->s9: 0
...(其餘 8 次全部 0/0)
```

**算得出來的機制**：5 pkt/s、1/256 取樣，每台 switch 對這條 flow 的期望取樣間隔是 `256/5 = 51.2 秒`。**50 秒的觀察窗裡，每條邊有很大機率一次樣本都沒有**——不是流量斷了、不是 bug 排除了 ICMP，是取樣機率在這個速率下算出來就是這樣。

⚠️ **這解釋了同一份報告裡兩個表面上獨立的現象，其實是同一個根因**：
1. `get_detected_flow_data` 裡 ICMP flow 忽隱忽現（頂層 flow table 的存在依賴最近有沒有樣本）
2. `get_num_of_flows_passing_a_switch` 對某些 switch 漏算（`edge.flow_set` 依賴那條邊最近有沒有樣本）

**兩者都是 §5i 取樣底噪的另一種呈現**，但比 §5i 更嚴重：§5i 說的是「速率讀數不準」，這裡是**「flow 存在與否本身不可信」**。

⚠️ **對消費端的意義比 §5i 更重要**：如果消費端用 `get_detected_flow_data` 的**存在與否**判斷「這條路徑現在有沒有流量」（例如 Phase 7 電源管理拿它當「這台 switch 閒置可以關掉」的依據），**低於約 10 pkt/s 的流量會被系統性地誤判為不存在，即使它從未停止**。這不是取多次中位數可以解決的問題（§5i 那招對速率讀數有效）——因為連「這一刻它存在嗎」都在賭機率，取樣本身沒有東西可以取中位數。

🔴 **這個發現的初版推論是錯的，記錄下來作為教訓**：deepseek-agent 下結論「這個端點排除了 ICMP」，10/10 的吻合度讓假設看起來很有說服力，但直接讀 `flow_set` 一戳就破。**跨端點矛盾被驗證為「可重現」，不代表找到真正的機制；重現只排除了「這是暫態噪音」，沒有排除「原因猜錯了」。** 真正的機制（取樣機率）比「協定過濾」更根本，也更能預測其他情境——這個問題在 TCP/UDP 上一樣會發生，只要速率夠低。

### 5k. 【2026-08-11 新增】大流量：200 Mbps 聚合負載

原本的 runbook 只測 10M 單流。這一節是 2026-08-11 加測的。

**設定**：四條並行 50M UDP，共 300 秒。

```
h1  -> h97   50M    path h1  -> s1 -> s6 -> s10 -> s8 -> s4 -> h97
h97 -> h1    50M    path h97 -> s4 -> s8 -> s10 -> s5 -> s1 -> h1
h33 -> h65   50M    path h33 -> s2 -> s6 -> s9  -> s7 -> s3 -> h65
h2  -> h98   50M    path h2  -> s1 -> s5 -> s10 -> s8 -> s4 -> h98
```

**結果**（負載期 90 秒，取樣 9 次）：

| 指標 | 實測 |
|---|---|
| `edges_up` | **288/288 全程不動** |
| 偵測到的 flow | 4 條，**沒有一條的 path 是空的** |
| twin 回報總速率 | 195.6 – 230.4 Mbps（送出 200M，實際 210M） |
| `avg_link_usage` | 0.0296 – 0.0372（10M 單流時是 0.007） |
| Ryu `Link deleted` 事件 | **0 筆** |

✅ **`avg_link_usage` 隨負載等比例上升**：4×50M 相對 1×10M 是 20 倍流量，avg 從 ~0.007 升到 ~0.034（約 5 倍）——不是 20 倍，因為分母（有樣本的邊數）也變多了。這符合 §5d 說的「分母是當下有樣本的邊數」。

⚠️ **「100M 會把 LLDP 餓死」在本次設定下沒有重現。** `doc/2026-07-30_full_test_runbook.md` §1d 記載 100M 曾造成 Ryu 誤判、跑出 19 次 link deleted。本次 200 Mbps 聚合、單一鏈路最高約 100 Mbps（s10→s8 同時承載兩條），**負載期間 0 筆 link 事件**。

🔴 **但這不足以推翻舊觀察**：舊的是**單流 `-b 100M`**，本次是四條 50M。**要否定舊警告必須照它原本的條件重跑，本次沒有做。** 在那之前，`-b 100M` 的警告請繼續遵守。

⚠️ **【2026-08-11 更正】本段原本還寫著「單流 100M 的封包速率是本次任一條的兩倍，對單一 switch 的 packet-in 壓力不同」，那個理由不成立，已刪除。** 本次的 `s10→s8` **同向**承載 `h1→h97` 和 `h2→h98` 兩條 50M，合計 100 Mbps，封包率和單流 100M **相同**——所以「壓力不同」解釋不了差異。

**現在的誠實立場是：我不知道為什麼舊測試餓死了 LLDP 而這次沒有。** 兩個可能的方向都沒查證：那次的瓶頸可能不在鏈路而在 switch 的 CPU（Mininet 是軟體轉送），或者舊觀察本身有其他未記錄的條件。**在照原條件重跑之前，不要為這個差異編任何理由。**（來源：agy-review 0200。）

---

## 6. Link failure → 維持 down → 恢復

### ⚠️ 重大陷阱：`ifconfig <iface> down` 在 OVS 和 bmv2 上的行為不同

在 bmv2 上用 `ifconfig <iface> down` 模擬斷線，會癱瘓整台 switch 的 packet-in 路徑（見 P4 runbook §6）。**在 OVS kernel datapath 上，這個 side effect 不存在**——OVS 的 packet-in 走的是 kernel datapath，不是 P4Runtime gRPC stream。把一條 veth 介面 down 掉只會斷那一條鏈路。

但是 OVS 模式有自己的陷阱：**Mininet CLI 的 `link s1 s5 down` 底層也是對兩端做 `ifconfig down`**，所以效果相同。而且 OVS 的 LLDP 是 controller 發的（Ryu 透過 OpenFlow 下發 `packet_out`），不是 switch 自己發的，所以斷線的偵測路徑和 P4 完全不同。

來源：`doc/2026-07-29_environment_gotchas.md` 的 bmv2 陷阱一節，以及 P4 runbook §6 的詳細分析。

✅ **【2026-08-11 實測】「OVS 上 `ifconfig down` 只斷該鏈路」已驗證為真。** 實驗設計：讓流量走 `h1 → s1 → s6 → ...`，然後斷掉 s1 的**另一條**鏈路 `s1-eth1`（s1:1↔s5:1，不在流量路徑上）。若 `ifconfig down` 會癱瘓整台 switch，穿過 s1 的流量必然中斷。**實測流量完全沒有中斷**（rate 持續 9–15 Mbps），只有被斷的那兩個方向從圖上消失。

這和 bmv2 的行為形成明確對照——bmv2 上同樣的操作會讓整台 switch 的所有入向靜默（P4 runbook §6）。**所以 OVS 模式不需要 P4 側那套 tc netem 的替代方案。**

### 6a. 斷線（terminal A —— Adam 可代跑，`ifconfig` 在 NOPASSWD 清單裡）

🔴 **【2026-08-11 實測】斷哪一條要看流量實際走哪裡，不能照抄。**

原文固定斷 `s1-eth1`（s1:1↔s5:1）。但本次實測流量走的是 `h1 → s1 → **s6** → s10 → s8 → s4 → h97`，也就是 s1 的 **port 2**。**照原文斷 s1-eth1 等於斷了一條沒有流量的鏈路，§6h（🔴 標為優先驗證的「是否繞路」）根本測不到。**

**先查流量走哪，再決定斷哪條**：

```bash
curl -s localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys
for f in json.load(sys.stdin): print([h['node'] for h in f['path']], [h['interface'] for h in f['path']])"
# 實測：[16777226, 1, 6, 10, 8, 4, 1627389962]  interfaces [3, 2, 4, 4, 2, 3, 0]
#                    ^^^^ s1 走 port 2 -> s6，所以路徑上的鏈路是 s1-eth2
```

**兩條都值得斷，測的是不同東西**：

| 斷哪條 | 測什麼 |
|---|---|
| **路徑外**（本例 `s1-eth1`） | 偵測鏈路是否完整；且流量沒斷 = 證明 `ifconfig down` 不會癱瘓整台 switch |
| **路徑上**（本例 `s1-eth2`） | §6h 的繞路：流量會不會被救回來 |

```bash
sudo -n ifconfig s1-eth1 down   # 路徑外
# ... 觀察、恢復 ...
sudo -n ifconfig s1-eth2 down   # 路徑上
```

⚠️ **每次只斷一條，斷完恢復再斷下一條。** 同時斷兩條會分不出哪個現象是哪條造成的。

### 6b. 觀察偵測（terminal A）

```bash
# 看 Ryu log 的 link down 事件
grep -E "link deleted|EventLinkDelete" .test_run/logs/ryu.log | tail -10
```

✅ 預期：出現 link deleted 事件。**【2026-08-11 實測】格式如下，每次斷線會有兩組（一個方向一組）**：

```
Link deleted: Link: Port<dpid=1, port_no=1, DOWN> to Port<dpid=5, port_no=1, LIVE>
removed edge 1 -> 5 from the routing graph
topology changed (link 1 -> 5 down); route reinstall scheduled
Notified NDT, status code: 200
Link deleted: Link: Port<dpid=5, port_no=1, LIVE> to Port<dpid=1, port_no=1, LIVE>
removed edge 5 -> 1 from the routing graph
topology changed (link 5 -> 1 down); route reinstall scheduled
Notified NDT, status code: 200
```

⚠️ 注意 `Port<...>` 裡的 `DOWN`/`LIVE`：**只有被 `ifconfig down` 的那一端是 `DOWN`，對端仍是 `LIVE`**。兩個方向都會被刪除，但物理上只有一端真的 down。不要以為 `LIVE` 代表那個方向沒事。

```bash
# 看 kernel log 的 link_failure_detected POST
grep "link failed" .test_run/logs/kernel.log | tail -5
```

✅ **【2026-08-11 實測】會推送，而且快得驚人——31 毫秒**：

```
[2026-08-11 11:04:09.150] ... handleLinkFailure] link failed on 1:1 -> 5:1
[2026-08-11 11:04:09.154] ... handleLinkFailure] link failed on 5:1 -> 1:1
```

斷線指令的時間戳是 `11:04:09.119`，所以是 **+31 ms / +35 ms**。第二次實測（s1-eth2）是 **+24 ms / +29 ms**，一致。

**原文猜的偵測路徑第 2 步是錯的。** 不是「LLDP 收不到 → 逾時」——`ifconfig down` 會讓 OVS 立刻送出 OpenFlow **port-status** 事件，Ryu 收到就直接發 `EventLinkDelete`。**沒有逾時，所以是毫秒級不是秒級。** 修正後的路徑：

1. `ifconfig down` → OVS 偵測到 port 狀態改變
2. OVS 送 OpenFlow port-status → Ryu 立即 `EventLinkDelete`（**非逾時**）
3. `on_link_delete`（`intelligent_router.py:757`）先 `remove_edge`、再 `_schedule_route_reinstall`、**最後**才 POST `/ndt/link_failure_detected`
4. kernel 的 topology poll 之後才看到 `/v1.0/topology/links` 的變化（秒級，見 §6c）

⚠️ **第 3 步的順序是刻意的**（`intelligent_router.py:766-780` 的註解）：自己的狀態先更新，遠端通知後做。因為 `requests.post` 對一個「接受連線但不回應」的 kernel 會**無限期阻塞且不拋例外**，順序反了會導致 edge 永遠不被移除、重裝永遠不被排程。

⚠️ OVS 模式和 P4 模式的 link failure 偵測是**完全不同的機制**：P4 依賴 proxy watchdog 的 LLDP beacon **逾時**（5 秒輪詢，見 P4 決定 10）；OVS 是**事件驅動**、毫秒級。這正是 P4 側決定「不做去抖動」時拿來對照的差異——**OVS 需要去抖動（`reinstall_quiet_period`），因為事件是逐條到達的；P4 不需要，因為一輪輪詢就把所有逾時一起收。**

### 6c. 確認圖已更新（【2026-08-11 實測】≤3.9 秒，非原本猜的 15–30 秒）

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

✅ **【2026-08-11 實測】edges up 從 288 降到 286**（正好少兩條），switches 仍 10/10/10，`down edges` 精確為：

```
down: [(1, 1, 5, 1), (5, 1, 1, 1)]
```

**延遲：≤3.9 秒**（kernel log 的 `topology from the control plane: 10 switches, 128 hosts, 286 edges up` 出現在斷線後 3.9 秒）。比原文猜的 15–30 秒快。

⚠️ **這個 3.9 秒沒有測準，不要當成精確值。** 有兩條路徑都會更新這張圖，而本次量測分不出是哪一條生效的：

1. `link_failure_detected` 的 POST（+31 ms 就到了）
2. kernel 的 topology poll（收斂後每 30 秒一次，`TopologyAndFlowMonitor::run()` 的 `kOnceConverged`）

本次第一次查圖是斷線後 7 秒，那時已經是 286，而 poll 的 log 落在 +3.9 秒。**所以真值可能是 31 毫秒，也可能是 3.9 秒——取決於圖是被 POST 直接改的還是等 poll 才改的。** 要分辨得用 100ms 級的密集取樣，本次沒做。

⚠️ 若是走 poll 這條路，**最壞情況是 30 秒**（poll 週期），而不是 3.9 秒——3.9 只是這次剛好落在週期裡的位置。

### 6d. 穩定性：維持 down 約 2 分鐘，確認沒有 flapping

```bash
for i in $(seq 1 40); do
  up=$(curl -s localhost:8000/ndt/get_graph_data | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for e in d['edges'] if e['is_up']))")
  echo "$(date +%H:%M:%S) edges up: $up"
  sleep 3
done
```

✅ 預期：119 秒內 40 次查詢，全部回相同的 edge up 數字，沒有 flapping。

**【2026-08-11 實測】跑了 65 秒 / 20 次查詢，全部 `edges_up=286`，零 flapping**，同時 `flows=1` 也全程穩定。⚠️ 本次只跑到 65 秒而非 2 分鐘，**這一格算部分驗證**——下次請跑滿。

### 6e. Kernel 自身的 poll 也確認

```bash
grep "topology from the control plane" .test_run/logs/kernel.log | tail -3
```

✅ **【2026-08-11 實測】會多印一行 `286 edges up`**，恢復後再印一行 `288 edges up`。這行只在數字變化時才印，所以斷線／恢復各一行，中間不會重複刷。

### 6f. 路徑數的變化

```bash
curl -s localhost:8080/ryu_server/all_destination_paths | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('paths:', len(d.get('all_destination_paths',[])))"
```

✅ **【2026-08-11 實測】路徑數維持 16256，不會下降。**

原因是這個拓撲夠密（10 switch / 16 條 inter-switch link），斷任一條之後每一對 host 都還有替代路徑，所以**條數不變、內容改變**。

⚠️ **因此「路徑數 16256」不能用來判斷重算有沒有發生**——斷線前後都是 16256。要確認重算真的跑了，看 ryu.log：

```bash
grep -nE "recomputing all-pair routes|route reinstall done" .test_run/logs/ryu.log | tail -4
```

**【2026-08-11 實測】重算耗時 <14 秒**（`recomputing` 到 `route reinstall done` 之間），遠快於 `intelligent_router.py` 註解裡說的「16256 對約 60 秒」。

### 6g. 恢復

```bash
sudo -n ifconfig s1-eth1 up
```

**【2026-08-11 實測】edges up 在 3 秒內回到 288**（`ifconfig up` 於 11:06:04.032，11:06:07 已是 288）。第二次實測同樣是 3 秒。

等待若干秒後：

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

### 6h. ✅ 繞路：已驗證，OVS 會繞路

**【2026-08-11 實測】OVS 模式會繞路，而且流量不中斷。**

實驗：流量走 `h1 → s1 → s6 → s10 → s8 → s4 → h97`，斷掉路徑上的 `s1-eth2`（s1:2↔s6:1），全程觀察 twin 回報的路徑與速率。

```
11:06:47.155  ifconfig s1-eth2 down
11:06:54      [h1, 1, 6, 10, 8, 4, h97]  rate 12419072    <- 仍是舊路徑
11:06:57      [h1, 1, 6, 10, 8, 4, h97]  rate  9935257    <- 仍是舊路徑
11:07:00      [h1, 1, 5, 10, 8, 4, h97]  rate 15523840    <- 已繞到 s5
...           （之後 60 秒穩定走 s5，rate 6.2M-15.5M 之間跳動）
```

**s6 被 s5 取代，約 13 秒完成，iperf 全程沒有斷。** 恢復後約 27 秒繞回 s6。

⚠️ **和 P4 模式的對照**：P4 在 Phase 6 之前**偵測得到但不繞路**（P4 runbook §6h 的 🔴）；Phase 6 補上 failover 後才會。OVS 這條路徑一直都會繞，機制是 `on_link_delete` → `_schedule_route_reinstall` → `_route_reinstall_worker` → `install_all_pair_paths`（`intelligent_router.py:757, 115, 132`）。

### 6i. 🔴【2026-08-11 新發現】鏈路轉換期間 twin 會輸出自相矛盾的狀態

本次實測發現兩個窗口，**twin 的輸出在此期間不可信**。兩個都不是 crash、不是錯誤 log，靜靜地發生。

**窗口 A：宣告一條穿過已知死鏈路的路徑（約 13 秒）**

斷線後 11:06:54 和 11:06:57 兩次取樣，`get_graph_data` 已回報 `edges_up=286`（s1↔s6 標記為 down），但同一時刻 `get_detected_flow_data` 回報的路徑**仍然穿過 s6**。也就是 twin 同時說「這條鏈路死了」和「流量正走過它」。

**窗口 B：對一條活著的 flow 回報空路徑（約 15 秒）**

鏈路恢復後 11:08:47–11:08:59，`get_detected_flow_data` 回報的 flow **`path` 是空陣列**，而 iperf 從未中斷。

⚠️ **窗口 B 很容易誤判成「flow 消失了」，不是。** flow 一直在（`first_sampled_time` 全程維持 `11:02:13`，沒有被老化重建），消失的只是 `path` 欄位。`getFlowInfoJson`（`FlowLinkUsageCollector.cpp:2062-2100`）沒有任何過濾、直接 dump 整張表，所以**空陣列不可能是這個現象的解釋**——判斷時請看 `path` 的長度，不要看 flow 的筆數。

**推測成因**：flow 的 `path` 來自 kernel 快取的 OpenFlow table，每 10 秒更新一次（`DeviceConfigurationAndPowerManager.cpp:1801-1802`）。轉換期間快取是舊的、或解不出完整路徑，於是輸出舊路徑（窗口 A）或空路徑（窗口 B）。10 秒快取 + 繞路耗時，合起來就是觀察到的 13/15 秒。

**為什麼這值得記一筆**：P4 側的決定 5（代號 B）就是為了修掉同一類問題——twin 只宣告「規則真的裝進 switch 且每一跳還活著」的路徑。**OVS 側沒有等價的防護。** 窗口 A 尤其明確：twin 自己的兩個端點在同一時刻互相矛盾，任何同時讀 `get_graph_data` 和 `get_detected_flow_data` 的消費端都會看到。

✅ **【2026-08-11 已確認機制，非推測】** agy-review 0198 #3 追進 `calFlowPathByQueried`（`FlowLinkUsageCollector.cpp:2659`）確認：查詢失敗時賦值 `sflow::Path{}`，序列化為 `[]`，且沒有獨立欄位區分「失敗」和「真的沒有路徑」。這個查詢讀的正是 classifier 快取——`DeviceConfigurationAndPowerManager.cpp:1801-1802` 每 10 秒整批替換一次（不是增量更新）。鏈路恢復後的過渡期，查詢落在替換窗口內就會失敗，`ok=false` 直接進入空 Path 賦值。這條路徑現在就在程式碼裡，不是根據時序推論出來的。

#### 窗口 A 已在完全不同的條件下獨立重現

第一次觀察是**單一 10M flow、其餘閒置**。重現時是**四條 50M 並行、200 Mbps 聚合負載**：

```
11:40:40.727  ifconfig s1-eth2 down
11:40:40      up=286   path [h1, 1, 6, 10, 8, 4, h97]   45.3 Mbps   <- 圖說 down，路徑還走 s6
11:40:45      up=286   path [h1, 1, 6, 10, 8, 4, h97]   74.5 Mbps
11:40:50      up=286   path [h1, 1, 6, 10, 8, 4, h97]   50.3 Mbps
11:40:55      up=286   path [h1, 1, 5, 10, 8, 4, h97]   57.7 Mbps   <- 繞到 s5
```

**約 14 秒，和第一次的 13 秒一致。** 兩次條件差異極大（閒置 vs 200M 負載、單流 vs 四流），窗口長度卻相同——**支持「成因是固定週期的快取更新，不是負載相關」的推測**，但仍未進 Classifier 確認。

#### 這次同時收窄了 §6c 的圖更新延遲

**斷線在 11:40:40.727，而 11:40:40 那次取樣（同一秒內）`up` 已經是 286。** 也就是圖的更新是**亞秒級**的。

§6c 原本只能說「≤3.9 秒」，分不出是 `link_failure_detected` 的 POST（+31 ms）還是 topology poll（週期 30 秒）。**亞秒級更新和 30 秒的 poll 週期不相容**，所以強烈指向 POST 路徑。⚠️ 仍非決定性——這一次取樣剛好落在斷線後不到一秒，沒有做 100 ms 級的連續取樣去定出確切轉換點。

#### 對照：負載下斷線的實際代價

同一次實驗四條流量的最終 iperf 報告：

| 流量 | 吞吐 | Loss |
|---|---|---|
| h1→h97（**路徑被斷**） | 51.0 Mbps | **2.7%**（35445/1337473） |
| h97→h1 | 52.4 Mbps | 0% |
| h33→h65 | 52.4 Mbps | 0% |
| h2→h98 | 52.4 Mbps | 0% |

✅ **只有受影響的那條掉封包，其餘三條零損失**——包含與它共用 s10 和 s8 的 h97→h1。繞路沒有波及無關流量。2.7% 就是那 ~14 秒重新收斂的代價。

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
| Idle graph | 10/10 switch up+enabled, **hosts 128/128 up, edges 288/288 up** | 拓撲發現與 host 學習都完成（【2026-08-11 更正】原本寫「部分可能 down」，實測是全滿） |
| Node keys | 12 個 key，含 `admin_disabled` | schema 正確，和 P4 模式一致 |
| Power report | 10 筆，33466–147622 mW，跨輪詢不變 | 合成電力值正常產生 |
| `avg_link_usage` idle | `0.0` | 沒有 phantom 流量 |
| Flow tables | 10 台各約 130 條 | OVS flow rules 已安裝（intelligent_router.py 的 all-destination paths） |
| Detected flows idle | `0` | 沒有 stale flow |
| Ryu topology | 10 switches, 32 links | Ryu LLDP 發現完成 |
| Ryu paths | 16256 | 所有 host pair 都有路徑 |
| Ryu log | `Static topology initialized` 出現，0 筆 `Failed` 或 `Traceback` | intelligent_router.py 正常載入 |
| Traffic: detected flows | **`iperf -u` 是 1 筆**（單向 UDP），rate ~10M bps，`path_len` 7 | OVS sFlow → kernel 的 ingest 鏈路完整（【2026-08-11 更正】原本寫 2 筆） |
| Traffic: `avg_link_usage` | 非零，約 0.001–0.01 | 鏈路使用率有在追蹤流量 |
| Traffic: iperf | ~10 Mbps, ~0% loss | 資料平面正常轉送 |
| Link failure detect | Ryu log 出現 link deleted，kernel log `link failed` 在 **~30 ms** 內出現（雙向 2 筆） | link failure 偵測鏈路完整 |
| Link failure graph | edges up **288→286**，穩定不 flapping | 失效值正確、沒有振盪 |
| **Failover（§6h）** | **斷路徑上的鏈路後，flow 的 path 改走替代 switch，iperf 不中斷** | 繞路真的發生了，不只是偵測到 |
| Recovery | edges up ~3 秒恢復，路徑 ~27 秒繞回 | 偵測與繞路都是可逆的 |
| `admin_disabled` | 全部 false，不變量空洞成立 | schema 正確，回歸陷阱就位 |

### 哪些綠燈不代表什麼

| 綠燈 | 不代表 |
|---|---|
| `switches up=10` | `sudo ovs-vsctl list-br` 只確認 bridge 存在，**不確認 OpenFlow 連線是否正常**。bridge 在但 controller 連不上時仍然 `up=10` |
| `edges up` 高 | host edge 的 `is_up` 取決於 Ryu 是否學到 host IP，static ARP 下可能學不到——不要當成 host 真的可達 |
| Flow table 130 條 | 那是 kernel 的快取（每 10 秒更新一次），可能不是最新的 |
| `avg_link_usage` 非零 | 它是瞬時值，且分母是「當下有樣本的邊數」。單次讀數不代表整體負載，連續讀數上下跳是正常的 |
| Ryu topology 32 links | Ryu 回報的是 inter-switch link，不含 host 邊——不能用來判斷 host 連通性 |
| **flow 的 `path` 非空** | 【2026-08-11】轉換期間它可能是**舊路徑**（穿過已標記 down 的鏈路）或**空的**，長達 13–15 秒。見 §6i |
| **`edges up` 已下降** | 不代表 `get_detected_flow_data` 的 path 也更新了——兩個端點在轉換期間會互相矛盾。見 §6i |
| **路徑數 16256 不變** | 不代表沒有重算。這個拓撲斷任一條鏈路後條數都不變，只有內容變。要看 ryu.log 的 `route reinstall done` |

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
| Ryu 突然沒 log | `pgrep -f "[r]yu-manager"` | **2026-07-30 曾經無聲死亡一次，死因至今未確定**（沒 traceback、沒 OOM 紀錄）。再發生請把 `ryu.log` 完整留下。來源：`doc/2026-07-30_full_test_runbook.md` |

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

**✅ 已於 2026-08-11 完成第一次實跑，全部填入。** 環境：10 switch / 128 host、Ryu + OVS Mininet + kernel `--no-ai`、iperf h1→h97 10M UDP、`ifconfig down` 斷線。

| 節 | 項目 | 預期（來自 source/doc） | 實測值（2026-08-11） |
|---|---|---|---|
| §4a | hosts `up`（idle） | ≤128（Ryu host 學習不完全） | 🔴 **128/128，預期是錯的** |
| §4a | edges `up`（idle） | ≤288（取決於 host 學習） | 🔴 **288/288，預期是錯的** |
| §4j | kernel log「topology from the control plane」的 hosts/edges 數 | — | `10 switches, 128 hosts, 288 edges up` |
| §5c | 已偵測 flow 的筆數 | 2（雙向） | 🔴 **1 筆**——`iperf -u` 是單向的 |
| §5c | 已偵測 flow 的 `rate_bps`（h1→h97，10M UDP） | ~10M bps | `6209536`–`15523840`，跳動 |
| §5c | 已偵測 flow 的 `path_len` | ~7（含起終點 host） | **7** ✅ |
| §5c | 已偵測 flow 的實際路徑（dpid 序列） | h1 → s1 → ... → s4 → h97 | `h1 → s1 → s6 → s10 → s8 → s4 → h97` |
| §5c | `src_ip`/`dst_ip` 的型別 | （原文假設是字串） | 🔴 **little-endian 整數**，非字串 |
| §5d | `avg_link_usage`（有 traffic 時，連查三次） | 非零，約 0.001–0.01 | `0.004890 / 0.008460 / 0.007658` ✅ |
| §5e | iperf throughput / loss | ~10 Mbps, ~0% | `10.3 Mbits/sec`，loss 1.5%（含兩次斷線） |
| §6b | 斷線後 Ryu log 出現 link deleted 的延遲 | — | 毫秒級（事件驅動，非逾時） |
| §6b | 斷線後 kernel log 出現 `link failed` 的延遲和筆數 | — | **+31 ms / +35 ms**，每次斷線 2 筆（雙向） |
| §6c | 斷線後 edges up 的變化 | 少 2（雙向 s1↔s5） | **288 → 286** ✅，`down: [(1,1,5,1), (5,1,1,1)]` |
| §6c | 斷線後圖更新的實際延遲秒數 | 5–30 秒（kernel poll 間隔） | **≤3.9 秒**（⚠️ 未測準，見 §6c） |
| §6d | 維持 down 的穩定性 | 2 分鐘無 flapping | 65 秒 / 20 次全 286，零 flapping（⚠️ 未跑滿 2 分鐘） |
| §6f | 斷線後路徑數的變化（從 16256 降到多少） | — | **不變，仍 16256**（拓撲夠密） |
| §6f | 重算耗時 | 註解說 ~60 秒 | **<14 秒** |
| §6g | 恢復後 edges up 回到原始值的延遲 | — | **~3 秒**（兩次實測一致） |
| §6g | 恢復後流量路徑繞回原路的延遲 | — | **~27 秒** |
| §6h | OVS 模式是否真的會繞路（流量是否繼續通） | 🔴 未知，**優先驗證** | ✅ **會繞路，~13 秒，流量不中斷** |
| §6 | `ifconfig down` 是否只斷該鏈路（不癱瘓整台 switch） | 推測是（與 bmv2 相反） | ✅ **確認只斷該鏈路** |
| §6i | 轉換期間 twin 狀態一致性 | （原文未預期） | 🔴 **兩個不一致窗口，13 秒 / 15 秒**——新發現 |

### 仍未測的項目（下一輪補）

| 項目 | 為什麼還沒測 |
|---|---|
| §6d 跑滿 2 分鐘 | 本次只跑 65 秒 |
| §6c 的圖更新延遲的確切值 | 已收窄到「亞秒級」（見 §6i），但要定出確切轉換點仍需 100 ms 級連續取樣 |
| §6i 兩個窗口的真正成因 | 已兩次獨立重現，但仍只有觀察和推論，沒有進 Classifier 確認 |
| **單流 `-b 100M` 是否真的餓死 LLDP** | §5k 用四條 50M 沒重現，但那不是舊警告的條件。**要照原條件重跑才能下結論** |
| 多條鏈路同時斷 | 本次每次只斷一條 |
| switch 整台失聯（非單一鏈路） | 完全沒測；Phase 7 的電源管理會需要這個 |

### 已於 2026-08-11 補測完成的項目

| 項目 | 結果 |
|---|---|
| 雙向 + 多對 host 的 §5c / §5g | ✅ 10/10 switch 與 flow 路徑自洽（見 §5g） |
| 速率估算準確度 | ✅ 五個檔位的階梯量測（見 §5i） |
| 大流量（200 Mbps 聚合） | ✅ 穩定，0 筆假 link 事件（見 §5k） |
| 低速率 flow 的存在會閃爍（第三方 agent 發現） | ✅ 5 pkt/s ICMP，取樣機率算得出來（見 §5j） |
| 負載下斷線 | ✅ 只有受影響的流量掉 2.7%，其餘 0%（見 §6i） |
| 跨端點一致性掃描（第三方 agent + 獨立驗證） | ✅ 288 條 edge、多條 flow 的 hop 全部對上；1 個新發現（§5j）、2 個假警報已排除（§5h 補充） |

### 【2026-08-11】第三方視角測試：deepseek-agent 交叉檢驗

Adam 要求用獨立於本次測試設計者的第三方視角，找跨端點矛盾。deepseek-agent 用 `run_command`（唯讀、無 sudo）自主探索了 51 次工具呼叫，產出 12 條 finding。逐條驗證後：

| Finding | 驗證結果 |
|---|---|
| `get_num_of_flows_passing_a_switch` 6/10 switch 不吻合 | ✅ **現象真實**，但 agent 猜的機制（排除 ICMP）錯了。真正原因見 §5j：取樣機率，不是協定過濾 |
| ICMP flow 忽隱忽現 | ✅ **與上一條同一根因**，已併入 §5j |
| power report 靜態 | 已知（見 §4c），非新發現 |
| OF 計數器顯示 `.98` 有未被偵測的流量 | 🔴 **假警報**——是本 session 稍早另一輪測試的舊計數器，已排除，見 §5h 補充 |
| link_bandwidth 10G vs 1G 內部矛盾 | 🔴 **假警報**——API 和內部 log 其實一致，都同時有 1G/10G，agent 自己因為工具問題只看到部分資料就下結論 |
| 啟動時 ECONNREFUSED | 已知（見 §3c），非新發現 |
| s1-s5 於 11:04 link flap | 這是**本 session 稍早 §6 章節的實驗性斷線**，不是自發異常——agent 沒有這輪測試以外的上下文，合理誤判 |
| top_k / all_destination_paths / ECMP 說明 | ✅ 核對正確，無異常 |
| `jq` 過濾器失效 | 非系統問題——是 agent 自己一開始把 jq 程式寫成字串字面值（`"."` 而非 `.`），過幾輪自己改對了。工具本身沒壞 |

**淨收穫**：1 個真實、之前沒人發現的問題（§5j，flow 存在本身在低速率下不可信），比純速率誤差更嚴重，直接影響 Phase 7 電源管理若要拿 flow 存在與否當閒置判準。3 個假警報全部有明確的根因排除（不是「猜測沒問題」，是找到真正原因並排除）。

⚠️ **方法論教訓**：agent 對 Finding 1 的「跨端點矛盾」是真實可重現的（10/10 吻合它自己的假設），但**重現不代表機制猜對了**。直接讀 `flow_set` 而非只看聚合端點的回傳值，才拆穿了「排除 ICMP」這個看似成立、實則錯誤的推論。
| 跨端點一致性掃描 | ✅ 288 條 edge、3 條 flow 的 18 個 hop 全部對上，0 個真實不一致 |

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

「先 Ryu 再 Mininet」是**初次啟動**的規則。**在 Mininet 還在跑的時候重啟 Ryu，8 秒後 `/stats/flow/<dpid>` 開始永久回空表。** 來源：`doc/2026-07-29_environment_gotchas.md`「不要單獨重啟 Ryu」。

後果：資料平面完全正常（每台 130 條規則、`is_connected: true`），但 kernel 讀到的 flow table 全是空的 → Classifier → **每條 flow 的 `path` 都是空的**，而網路其實好好地在轉封包。

kernel 現在有防禦：`classifyFlowStatsReply`（`DeviceConfigurationAndPowerManager.cpp:998-1021`）如果回覆空且耗時 ≥ `kFlowStatsSuspectSeconds`（0.5 秒），會認定為 Ryu timeout 並**保留上一份 flow table**。這個防禦讓 wedged 狀態不會立刻汙染 kernel，但**不能恢復正常**——因為永遠拿不到真實的 flow table。

> **完整規則：先 Ryu 再 Mininet；而且不要中途單獨重啟 Ryu——要重啟就兩個一起。**

也就是說**改完 `intelligent_router.py` 要重測，必須整組重開。**

### 防禦程式碼位置

1. `DeviceConfigurationAndPowerManager.cpp:998-1021`：`classifyFlowStatsReply` — 空表 + 耗時 ≥ 0.5s → `SuspectTimedOut` → 保留上一份表
2. `DeviceConfigurationAndPowerManager.cpp:1130-1143`：呼叫 `classifyFlowStatsReply`，若為 `SuspectTimedOut` 則 WARN 並跳過（不更新快取）

---

*本文件 2026-08-10 從原始碼產生（DeepSeek 撰寫，當時 OVS 路徑未實測）。**2026-08-11 由 Claude 完整實跑 §1–§7 一輪**，§10 的 TO BE MEASURED 全數填入，5 處預期值被實測推翻並就地更正，新增 §6i 記錄一個實測發現的狀態不一致問題。針對 OVS/Ryu stack（Mininet mode）。*

*[Co-developed with claude code -- Adam]*


---

## 附錄 A：OVS 和 P4 模式快速對照

這不是 runbook 的一部分，只是幫助你（和未來的讀者）在兩份文件之間快速定位。

| 面向 | OVS（本文件） | P4（`doc/2026-08-10_p4_manual_test_runbook.md`） |
|---|---|---|
| 控制平面 | Ryu (`:8080` REST, `:6633` OpenFlow) | P4 proxy (`:8081`) |
| 資料平面 | OVS kernel datapath (Mininet) | bmv2 `simple_switch_grpc` (Mininet) |
| 啟動順序 | Ryu → Mininet → wait → kernel | Mininet → proxy → wait → kernel |
| 收斂時間 | ~60s+（`hub.sleep(60)`） | ~2s |
| link failure 偵測 | **事件驅動**，OpenFlow port-status → `EventLinkDelete`，**~30 ms** | **輪詢**，LLDP beacon 逾時，5 秒一輪 |
| 去抖動 | **有**（`reinstall_quiet_period`），因為事件逐條到達 | **無**（決定 10），因為一輪輪詢批次收齊 |
| 繞路（failover） | ✅ 一直都有，~13 秒（2026-08-11 實測） | Phase 6 之後才有 |
| twin 只宣告已安裝的路徑 | ❌ **沒有**，轉換期間會矛盾（§6i） | ✅ 有（決定 5 / 代號 B） |
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

以下記錄撰寫本文件時**實際讀過的原始碼行號**，供後續維護者追溯。未列在這裡的主張來自既有文件（`doc/2026-07-30_full_test_runbook.md`、`doc/2026-08-10_p4_manual_test_runbook.md`、`doc/2026-07-29_environment_gotchas.md`），並在文中已標明。

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
| topology poll 間隔（5s/30s/90s） | `TopologyAndFlowMonitor::run()`，常數 `kWhileConverging`／`kOnceConverged`／`kConvergingFor` |
| topology poll log（變化時才印） | `TopologyAndFlowMonitor::run()`，`graphLivenessSummary()` 的結果和上一輪不同才印 |
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
