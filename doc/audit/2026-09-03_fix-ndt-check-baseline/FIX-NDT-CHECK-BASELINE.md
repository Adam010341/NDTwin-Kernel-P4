# FIX-NDT-CHECK-BASELINE — `ndt status --check` 的基準改成「上一次 `ndt up` 的目標」

分支 `fix/ndt-status-check-baseline`（從 `trunk` `0be954ad` 開出）。對應缺陷 **#8**，
裁決 **N12 (a)**（Adam，09-03 20:2x）。

> 本文引用的 `raw/<檔名>` 全部在 **`audit-raw` 分支**的
> `doc/audit/2026-09-03_fix-ndt-check-baseline/raw/` 底下（這個目錄本身只放這一份 .md）。
> 讀法：`git show audit-raw:doc/audit/2026-09-03_fix-ndt-check-baseline/raw/<檔名>`

---

## 1. 缺陷：一個沒有基準的檢查

`ndt status --check` 沒有自己的基準。它從 `p4_proxy/mininet/host_count_override` 推導一個出來——
而那是 **P4 專用的旋鈕，`ndt up ovs4` 從來不寫它**。09-02 23:41 在一座健康的 4 主機 OVS fabric 上
量到的結果（`round1-ovs/05_`、`07_`）：

```
configuration
  hosts          128                                                    <- fabric 只有 4
  topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json   <- fabric 是 OVS
network health
  model          MISMATCH: graph has 4 hosts / 40 edges, file says 128 288
check: 1 problem(s)
  - the kernel graph does not match the topology file
CHECK_RC=1
```

**這是假紅，而且假紅還不是最嚴重的部分。** 把旋鈕「設對」並不能修好它：那個比較只有
(hosts, edges) 兩個數，而兩份 4 主機模型在這兩個數上完全一樣——

| 模型檔 | hosts | edges |
|---|---|---|
| `StaticNetworkTopologyP4_10Switches_4Hosts.json` | 4 | 40 |
| `StaticNetworkTopologyOVS_10Switches_4Hosts.json` | 4 | 40 |
| `StaticNetworkTopologyP4_10Switches_128Hosts.json` | 128 | 288 |

⇒ 旋鈕設成 4 之後，它會**綠著**拿一座 OVS fabric 去比對一份 P4 模型檔。
**一個分不出兩個資料平面的檢查，對兩個資料平面都沒有鑑別力。**
（這正是 #25 那條通則：鑑別力測試只證明它對你測過的輸入有鑑別力。）

---

## 2. 修法：`up` 記下它被要求的東西，`--check` 拿活的狀態跟那份記錄比

裁決 (a)：**基準＝上一次 `ndt up` 的目標。** 所以：

`ndt up <target>` 在**動到機器之前的最後一刻**（每一個不必碰 lab 就能判斷的拒絕都通過之後、
第一個編號步驟之前）寫下 `.test_run/up.target`：

```
plane=<p4|ovs>          up 被要求建哪一種資料平面
hosts=<n>               被要求幾台主機
topology=<path>         kernel 的模型檔，相對於 repo 根目錄
topology_sha256=<hex>   那一刻的檔案身分（之後被改動就看得出來）
model_hosts=<n>         那個檔案宣告的主機數（vertex_type == 1）
model_edges=<n>         那個檔案宣告的邊數
at=<unix seconds>       什麼時候被要求的
by=<NDT_OWNER|unset>    誰要求的
builder=<up_p4|up_ovs>  當時要跑的函式
```

**為什麼記在「開始建之前」而不是「建完之後」**：一次失敗到一半的 `up` 仍然是一次「要求」，
而那正是最值得事後檢查的狀態——#3（失敗的 `ndt up ovs4` 留下 Ryu、topo session 與資料平面，
沒有 kernel）就是這個情況，`--check` 事後應該有能力把它判成紅。

`ndt status --check` 逐欄比對，**每一欄都印出來**（舊的只印一句「不符合拓樸檔」，那句話連檔名都沒說）：

| 欄位 | 活的那一邊 | 記錄的那一邊 |
|---|---|---|
| `dataplane` | `live_dataplane_kind`（bmv2 行程 → p4；OVS bridge → ovs；問不到 → **unknown**） | `plane` |
| `fabric hosts` | `fabric_host_count`（從 `ps` 數 host namespace） | `hosts` |
| `graph hosts` | 北向 API `/ndt/get_graph_data` | `hosts` |
| `graph edges` | 同上 | `model_edges` |
| `topology file` | 現在的 sha256 | `topology_sha256` |

**`dataplane` 那一欄就是 #8 缺的那個欄位。** (hosts, edges) 兩個數是兩個不同網路共用的，
再怎麼小心挑「該讀哪一份檔案」都補不回鑑別力——缺的欄位只能加上去。

### 三種結果，不是兩種

```
0   全部比對過，而且都相符
1   有一欄不符（訊息指名是哪一欄），或有一欄讀不到（讀不到是紅，不是綠）
3   什麼都沒有比對——這個 checkout 沒有跑過 ndt up
```

🔴 **rc 3 永遠不是「檢查過而且相符」，也永遠不會印出那句 mismatch。** 它有自己的措辭
（`check: COULD NOT CHECK -- no 'ndt up' target recorded in this checkout`）與自己的離開碼。
rc 3 **蓋過** rc 1：沒有基準時這份報告不是一個裁決，用 1 回報等於宣稱「我比對過了」。

`ndt down` 會清掉這份記錄——`down` 就是「我不再要求那座 fabric 了」。留著它的話，
每一次在刻意閒置的機器上跑 `--check` 都會對一座沒人要的 fabric 報紅，而一個會亂叫的檢查
最後就沒有人看。清掉之後，閒置機器上的誠實答案是「could not check」。

### 🔴 範圍：與 #79 同一個限制（我沒有修 #79）

`.test_run/` 是**每個 checkout 各一份**。這份記錄描述的是「**從這個 checkout** 跑的上一次 `ndt up`」。
一個 worktree 跑 `ndt up ovs4`、主 checkout 跑 `ndt status --check`，那是兩個不同的檔案，
第二個會說「could not check」而不是自己編一個答案出來。這是 per-checkout 檔案誠實的失敗方式，
不是 #79 的修法；**#79 本次沒有動**。

---

## 3. 前後對照（逐字）

同一組 fixture（健康的 4 主機 OVS fabric：10 bridges、0 bmv2、4 個 host namespace、
kernel graph 4 hosts/40 edges、旋鈕停在 128——因為 OVS 那條路從來不寫它）。

**BEFORE（trunk `0be954ad`）** — `raw/fixture_before_trunk.log`：

```
configuration
  hosts          128
  topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
...
network health
  model          MISMATCH: graph has 4 hosts / 40 edges, file says 128 288
...
check: 1 problem(s)
  - the kernel graph does not match the topology file
CHECK_RC=1
```

**AFTER（本分支）** — `raw/fixture_after_branch.log`：

```
configuration
  hosts          4   (what the last 'ndt up' asked for: ovs)
  topology       setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json
  p4 host knob   128   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
...
up target
  asked for      ovs, 4 hosts   (recorded 2026-09-03 21:17:39 by ndtcheck)
  topology       setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json   (declares 4 hosts / 40 edges)
  dataplane      ovs                    == ovs   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph edges    40                     == 40   ok
  topology file  sha256 6cd0d606f4da    == recorded   ok

check: ok
  compared against the last 'ndt up': dataplane, fabric hosts, kernel graph, topology file
CHECK_RC=0
```

旋鈕沒有被刪掉，它還是決定下一次 `ndt up p4`——但它現在**以它自己的名字**出現
（`p4 host knob`），不再冒充「正在跑的東西的組態」。

---

## 4. 紅 → 綠

測試：`tests/shell/test_ndt_status_check_baseline.sh`，**61 個 check，離線、fixture 驅動**
（REPO 導到 temp dir，`setting/`、旋鈕、記錄、kernel graph 全是這支測試自己寫的檔；
所有行程與權限探測都被 stub）。不碰 lab、不碰 sudo、不碰 port、不碰網路。

* 對本分支：**61 個 check、0 紅**（`raw/green_on_branch.log`）
* 對 trunk 的 `ndt`：**61 個 check 裡 55 個紅**（`raw/red_on_trunk.log`，
  `NDT_UNDER_TEST` 指向 `git show trunk:tools/test_workflow/ndt`，sha256 `42c2844191b7…`）

三個必要的紅，都是**行為上的**紅（不是「函式不存在」）：

| # | 案例 | trunk 的行為 | 本分支 |
|---|---|---|---|
| (a) | 健康 ovs4 | `rc=1`，`the kernel graph does not match the topology file`（假紅） | `rc=0`，並印出比對了哪五欄 |
| (b) | 記錄說 ovs4，實際是 P4 4 主機 fabric（旋鈕設成 4） | `rc=0`，`check: ok`（零鑑別力） | `rc=1`，`dataplane: the lab has 'p4', the last 'ndt up' asked for 'ovs'` |
| (c) | 沒有記錄 | `rc=1` ＋ mismatch 那句；旋鈕碰巧對上時 `rc=0` `check: ok` | `rc=3`，`COULD NOT CHECK`，兩句都不會印 |

三個必要的紅在 trunk 上的逐字輸出：

```
  FAILED   a healthy ovs4 exits 0
             expected: [0]  actual: [1]
  FAILED   🔴 a P4 fabric under an ovs4 record is not ok
             expected: [1]  actual: [0]
  FAILED   🔴 no baseline exits 3, not 0 and not 1
             expected: [3]  actual: [1]
  FAILED   🔴 a coincidence must not be reported as a pass
             expected: [3]  actual: [0]
```

(c) 的第二半是這次最重要的一個紅：**trunk 在完全沒有基準的情況下印了 `check: ok` 並 exit 0。**

另外七組：欄位指名（graph hosts / graph edges / fabric hosts）、讀不到就是紅
（0 個 namespace、被拒的 `ovs-vsctl`、kernel 不回答）、模型檔在 kernel 跑著的時候被改、
🔴 反方向（P4 那條路仍然綠——一個「總是紅」的實作會在這裡失敗）、記錄本身的讀寫、
以及**接線**（group 8：真的驅動 `up_ovs 4`／`up_p4`／`cmd_down`，因為
「函式存在」不等於「有人呼叫它」）。

---

## 5. 變異閘門

`tests/shell/mutate_ndt_status_check.sh` — **12 個變異，0 個存活**
（`raw/gate_ndt_status_check.log`），基準前後 **byte-identical**（sha256 已印在 log 末行）。
每個變異都指名「必須變紅的那一個 check」，紅在別的地方一律算 SURVIVOR。

| 變異 | 內容 | 指名要紅的 check |
|---|---|---|
| M1 | 主機基準又回去讀 P4 旋鈕（假紅本體） | `a healthy ovs4 exits 0` |
| M2 | dataplane 只印不比（零鑑別力本體） | `🔴 a P4 fabric under an ovs4 record is not ok` |
| M3 | 沒有記錄回報成 mismatch（rc 1） | `🔴 no baseline exits 3, not 0 and not 1` |
| M4 | 讀失敗的 fabric 數變成「主機數＝0」 | `  named as not compared, not as agreement` |
| M5 | 模型檔被改過不回報 | `the model file edited under a running kernel is red` |
| M6 | `up_ovs` 不再寫記錄（**接線**） | `'ndt up ovs4' records its target` |
| M7 | `up_p4` 不再寫記錄（**接線**） | `'ndt up p4' records its target too` |
| M8 | `cmd_down` 不再清記錄（**接線**） | `'ndt down' drops the record` |
| M9 | 被拒的 `ovs-vsctl` 讀成「這裡沒有 OVS」（#7 同型） | `🔴 a refused ovs-vsctl is 'unknown', not 'none'` |
| **N1**（控制組） | `--check` 什麼都不比，一律綠 | `🔴 a P4 fabric under an ovs4 record is not ok` |
| **N2**（放寬） | 沒有基準＝通過 | `🔴 no baseline exits 3, not 0 and not 1` |
| **N3**（放寬） | 差異照印，但從不回報 | `a 128-host graph under a 4-host record is red` |

**N1/N2/N3 是「留在綠」的那三個**：它們都能通過「在壞掉的 fixture 上有沒有變紅」這種
單向提問——一個永遠不會失敗的檢查，當然不會在錯的 fixture 上失敗。只有 M 側的閘門
會對這三個放行，而它們放回去的正好就是 #8 的性質：一個看起來像檢查的、沒有鑑別力的東西。

`check_gate_anchors.py HEAD --gates mutate_ndt_status_check.sh` → **`ok(11)`，exit 0**
（12 個變異、11 個相異錨點：M3 與 N2 共用同一個錨點，工具會去重）。

🔴 **這支閘門第一版是照 `mutate_ndt_up_target.sh` 的形狀寫的（錨點放在 heredoc 檔案裡），
而 anchor 檢查器讀不到那個形狀——`mutate_ndt_up_target.sh` 自己在 HEAD 上也是 `NO-ANCHORS`。**
改成 `mutate_apps_stop_kills_the_group.sh` 的形狀（具名參數 `local label="$1" file="$2" old="$3" new="$4"`）
之後才讀得到。**順帶被工具抓到一個真的錯**：M4 原本的單行錨點與 `verify_p4` 自己的
fabric 端斷言**逐字相同**，`count: 2 (want 1)` ⇒ 錨點已加上一行註解使其唯一。
（這正是 #19／#28 那類問題：一支閘門可以安靜地停止變異任何東西。）

---

## 6. 鄰居閘門（都讀同一個檔案）

六支既有閘門對**本分支的 `ndt`**（sha256 `51a7c09ac1d9…`，就是被提交的那份位元組）重跑，
依序、不併行（其中幾支會掃全機 `ps`，兩支同時跑就是「閘門為了與被測改動無關的理由變紅」）。
**全綠，88 個變異、0 個存活**（`raw/neighbour_gates_summary.log` 與各自的
`raw/neighbour_mutate_*.log`）：

| 閘門 | 變異數 | 存活 | rc |
|---|---|---|---|
| `mutate_ndt_up_target.sh` | 8 | 0 | 0 |
| `mutate_ports_that_block_restart.sh` | 9 | 0 | 0 |
| `mutate_apps_stop_kills_the_group.sh` | 13 | 0 | 0 |
| `mutate_ndt_sudo_surface.sh` | 14 | 0 | 0 |
| `mutate_redirection_order.sh` | 20 | 0 | 0 |
| `mutate_ovs4_has_sflow.sh` | 24 | 0 | 0 |
| **合計** | **88** | **0** | |

`mutate_apps_stop_kills_the_group.sh` 的 baseline 是 **71 checks, 0 failed**——
也就是說本次對 `cmd_status`／`cmd_down` 的改動沒有動到它的基準。
`mutate_ndt_sudo_surface.sh` 特別相關：它有一個變異直接驅動 `cmd_status --check`
（M10，斷言它會讀 sudo 表），本次改了 `--check` 的離開碼與輸出之後**仍然被抓到**。

⚠️ **交代兩件可能影響判讀的事**：
1. 這六支的**前三支與 live arm 在時間上重疊**（23:23–23:44 vs 23:29–23:33）。判斷它們可以並行的
   依據是：`test_ovs4_sflow_verify.sh` 檔頭明講 "No lab contact, no real sudo, no ovs-vsctl"
   （PATH 上放假的），`test_apps_stop_kills_the_group.sh` 的 fixture 簽章帶自己的 pid、
   且 REPO 導到自己的 temp dir，都與 mininet／bmv2／Ryu 的行程形狀沒有交集。
   **若當時有任何一支變紅，我會單獨重跑它再下判斷**——實際上六支全綠，沒有觸發這條。
2. 同一段時間機器上有**別的 session 在編 C++**（`cc1plus` 約 1 GB，可用記憶體一度掉到 ~3.9 GB）。
   我這邊沒有任何建置；記在這裡是因為閘門的耗時受它影響（apps-stop 那支跑了 20 分鐘）。

---

## 7. Live 證據

三個 arm，實機、實 fabric。**總共佔用 lab 約 3 分鐘**（23:29:44 → 23:32:46），每個 arm 跑完立刻
`ndt down` ＋ `release`，claim 依 #79 同時寫在 worktree 與主 checkout 兩份、release 時兩份都移除。

執行方式：**兩個 arm 都從我的 worktree 跑**，`build/`（以及 P4 arm 的 `p4_proxy/venv`、
`p4_proxy/p4_src/build`）以 symlink 借用主 checkout 的產物**唯讀**，所以 `.test_run/`（log、pidfile、
claim、記錄）全部留在我的 worktree，**沒有寫到主 checkout 任何檔案**（claim 那一份副本除外）。
BEFORE arm 用的是 `git show trunk:tools/test_workflow/ndt` 落到 worktree 的副本
（sha256 `42c2844191b7…`，與主 checkout 現行的 `ndt` **逐字相同**）。

### 7.1 開工前（唯讀，`raw/live_00_pre_state.log`）

沒有 claim、沒有 fabric、所有 port 關閉。`host_count_override` 停在 **128**——正是 #8 的條件。

### 7.2 BEFORE arm（trunk 的 ndt）— `raw/live_before_0{0..4}_*.log`

`ndt up ovs4` 建起來並自我驗證通過：

```
  ok  kernel: 10 switches up+enabled
  ok  kernel graph matches the model file: 4 hosts, 40 edges
  ok  data plane: h1 -> 10.0.0.2 forwards
  ok  sFlow: 10/10 bridges sampling to :6343, 10 records
up. ready                                     UP_RC=0
```

**同一座 fabric，同一支 ndt，`status --check` 立刻說它壞了**：

```
configuration
  hosts          128
  topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
network health
  model          MISMATCH: graph has 4 hosts / 40 edges, file says 128 288
kernel graph
  10 switches (10 up, 10 enabled), 4 hosts, 40 edges

check: 1 problem(s)
  - the kernel graph does not match the topology file
CHECK_RC=1
```

**與 09-02 23:42 那份 `round1-ovs/07_` 逐字同型。** 這是假紅：`up` 自己的四個驗證全綠、
真流量會轉發、sFlow 有 10 筆記錄。

### 7.3 AFTER arm（本分支）— `raw/live_after_0{0..5}_*.log`

同樣的 `ndt up ovs4`，多印一行 `recorded this target in .test_run/up.target`，寫下：

```
plane=ovs   hosts=4   topology=setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json
topology_sha256=2266c69cbcd3d0ac5272b62925709c70b8fffca8669faee1e4113e50ed58b285
model_hosts=4   model_edges=40   at=1788449424   by=ndtcheck   builder=up_ovs
```

**`--check` 綠，而且說出它比了什麼**（`CHECK_RC=0`）：

```
configuration
  hosts          4   (what the last 'ndt up' asked for: ovs)
  topology       setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json
  p4 host knob   128   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
up target
  asked for      ovs, 4 hosts   (recorded 2026-09-03 23:30:24 by ndtcheck)
  topology       setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json   (declares 4 hosts / 40 edges)
  dataplane      ovs                    == ovs   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph edges    40                     == 40   ok
  topology file  sha256 2266c69cbcd3    == recorded   ok
check: ok
```

**弄壞一件真的東西**：用 kernel 自己 pidfile 裡的 pid 送 `SIGTERM`
（精確到 pid，**沒有用 `pkill -f`**）。`:8000` 關閉之後：

```
running
  :8000 kernel   closed  :8081 proxy    closed  :8080 ryu open
up target
  dataplane      ovs                    == ovs   ok
  fabric hosts   4                      == 4   ok
  kernel graph   the kernel gave no graph on :8000 -- NOT COMPARED
  topology file  sha256 2266c69cbcd3    == recorded   ok
check: 1 problem(s)
  - kernel graph: could not be compared against the 'ndt up' target (the kernel gave no graph on :8000)
CHECK_RC=1
```

紅得**精確**：指名 `kernel graph` 這一欄，其餘三欄照樣比對並相符——不是整片變紅。

**`ndt down`**：清機斷言全過（`bmv2 0`／`host/switch 0`／`no topo session`／
`ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000`），記錄被清掉。
接著在這台已經拆乾淨的機器上：

```
up target
  record         none -- no 'ndt up' has run in this checkout  (.test_run/up.target)
check: COULD NOT CHECK -- no 'ndt up' target recorded in this checkout
CHECK_RC=3
```

### 7.4 P4 arm — 零鑑別力那一半的 live 證據 — `raw/live_p4_0{0..4}_*.log`

`ndt up p4 4` 起來（12/12 destination paths、`model matches fabric: 4 hosts`），記錄 `plane=p4`。
`--check` 的 **up target 五欄全綠**：

```
  dataplane      p4                     == p4   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph edges    40                     == 40   ok
  topology file  sha256 50a3246390a6    == recorded   ok
```

⚠️ **但整體 `CHECK_RC=1`**，來自一條**與本次修法無關的既有檢查**：
`ndtwin_switch.p4 is newer than its compiled json (restored source, never recompiled)`。
成因是**我這次借用的方式**——worktree 的 `.p4` 原始碼是 21:0x 建 worktree 時落地的，
比主 checkout 那份較早編出來的 json 新，`source_ahead_of_build()` 因此觸發。
**這不是本次修法造成的，也不是一個新缺陷**；我把它照實列出來，不把 P4 arm 說成「全綠」。

然後——**同一座還在跑的 P4 fabric，換一份 ovs4 的記錄擺在它前面**
（手寫，格式就是文件寫的那個，`by=hand-written-fixture` 在 log 裡自己說明它是手寫的）：

```
--- both 4-host models agree on (hosts, edges), which is all the old check compared ---
setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json 4 hosts / 40 edges
setting/StaticNetworkTopologyP4_10Switches_4Hosts.json  4 hosts / 40 edges

up target
  asked for      ovs, 4 hosts   (recorded 2026-09-03 23:32:30 by hand-written-fixture)
  dataplane      p4                     != ovs   MISMATCH
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph edges    40                     == 40   ok
  topology file  sha256 2266c69cbcd3    == recorded   ok
check: 2 problem(s)
  - ndtwin_switch.p4 is newer than its compiled json (restored source, never recompiled)
  - dataplane: the lab has 'p4', the last 'ndt up' asked for 'ovs'
CHECK_RC=1
```

**除了資料平面以外每一欄都相符**——4 台主機、4 個 host namespace、4/40 的 kernel graph，
連模型檔的 sha256 都對（那份 OVS 檔在磁碟上沒被動過）。
舊的檢查只比 (hosts, edges) ⇒ **它在這個情境會回綠**。這就是 #8 的第二半，實機上的樣子。

### 7.5 收工

`ndt down` 清機斷言全過、`ndt release`、主 checkout 的 claim 副本已移除、
`p4_proxy/mininet/host_count_override` 被 `ndt up p4 4` 改成 4 之後**已還原成 128**
（那是共用的持久狀態，`git checkout --` 還原，log 裡有前後兩個值）。
收工時 `git status` 只剩我自己的未追蹤輔助檔（symlink 與 `ndt.trunk`），沒有任何被追蹤檔案是髒的。

---

## 8. 合併

```
# trunk = 92a79392  (分支開出後 trunk 已經前進；base = 0be954ad)
$ git merge-tree --write-tree trunk fix/ndt-status-check-baseline
deb2effc30835d5b0cc7eab895c8df84542a91b9
MERGE_TREE_RC=0
```

與 `trunk` **無衝突**——而且值得一提的是，**trunk 在我開分支之後自己也動過
`tools/test_workflow/ndt`**（`1803a7cd`，`fix/poll-does-not-resurrect` 的合併），
兩邊仍然乾淨合併。（`raw/merge_tree.log`）

本分支對 base 的 diff 只有三個檔案：

```
 tests/shell/mutate_ndt_status_check.sh        | 233 ++++++
 tests/shell/test_ndt_status_check_baseline.sh | 379 ++++++
 tools/test_workflow/ndt                       | 292 +++++-
```

---

## 9. 我沒有做的事

1. **沒有修 #79**（`.test_run/` 是 per-checkout）。這份記錄繼承同一個限制，而且是**寫在文件裡的**
   ——`--check` 在別的 checkout 會說「could not check」而不是編一個答案。
2. **沒有動 `host_count_override`**。它是共用的持久狀態，而且它真的決定下一次 `ndt up p4`；
   只是不再被當成「正在跑的東西」來印。
3. **沒有改 `up_p4`／`up_ovs` 的 verify 段**（`verify_p4`／`up_ovs` 的 `[4/4] verify`）。
   它們有自己的比較，形狀正確（`verify_p4` 08-30 已修成讀 `fabric_host_count`），
   本次只加了「把要求記下來」這一件事。
4. **沒有把 `--check` 的 rc 3 接到任何呼叫端**。`run_layers.sh` 等腳本目前沒有讀 `status --check` 的 rc；
   若之後要接，rc 3 的語意是「這份報告不是裁決」，不能當成 rc 1 的同義詞。
5. **沒有處理「記錄比 fabric 舊」的時間軸問題**：記錄裡有 `at`，但 `--check` 目前不比較
   fabric 的年齡與記錄的年齡（見下面的問題 2）。
6. **沒有重構那三份重複的「讀拓樸檔算 hosts/edges」python 片段**（`verify_p4`、`up_ovs`、
   舊的 `cmd_status`）。新程式碼用了新的 `topo_model_counts`，舊的兩處沒動——動它們會擴大 diff，
   而且 `up_ovs` 那一份是別支修法正在動的區域。

---

## 10. 給 Adam 的問題

1. **rc 3 蓋過 rc 1，對嗎？** 現在「沒有基準」時就算報告裡還有別的問題（例如別人握著 claim），
   也回 3（並且把其他問題照樣列出來）。理由：rc 1 宣稱「我比對過而且發現這些」，
   而在最重要的那一項沒比對到的時候，那是一個做不到的宣稱。
   反面意見是：呼叫端可能把 3 當成「工具壞了，忽略」。要不要改成「有其他問題就回 1」？
2. **記錄要不要有有效期？** 現在只要沒 `ndt down` 就一直有效。
   一個三天前的 `up` 記錄配上一座今天別人重建的 fabric，會安靜地「相符」。
   要不要加「記錄比 fabric 老」的偵測（例如比 manifest／topo session 的 mtime）？
3. **`ndt up` 失敗時記錄留著，這樣對嗎？** 我選擇留（理由在第 2 節），
   代價是：一次被 preflight 之後才失敗的 `up`，會讓後續 `--check` 一直紅到有人 `ndt down`。
4. **要不要把 rc 3 接進 `run_layers.sh` 或 `local_ci.sh`？** 目前沒有任何呼叫端讀這個 rc，
   等於這個三態只有人眼看得到。
