# live-p1 — 階段一（P4 app package）的三個 live 驗收，Adam 跑

工單 `TICKET-P1C-ndt-integration.md` §2；母工單 `TICKET-P1-app-package.md` §0 的驗收 ①②③。
腳本由 P1-C session 寫，**寫的人一次都沒跑過**（沒有 sudo、沒有 lab）。

[Co-developed with claude code -- Adam]

---

## 怎麼跑

三支**依序**跑，中間任何一支 `FAIL` 就停下來看 raw，不要接著跑下一支。
每支自己 claim、自己 `ndt down`、自己把 `host_count_override` 寫回、自己 release（EXIT trap，
Ctrl-C 也會走）。**不需要 `sudo bash`**——腳本要的是「root 拿得到而且不會問密碼」
（`sudo -n true`），也就是 `ndt` 平常就需要的那兩條 sudoers 授權。
用 `sudo` 跑也可以，但 `runs/` 與 `.test_run/` 會變成 root 所有，之後你自己的 `ndt` 會踩到。

| 步 | 貼這一行 | 最後一行應該是 |
|---|---|---|
| ① | `NDT_OWNER=adam bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/01_baseline.sh` | `PASS 01_baseline` |
| ② | `NDT_OWNER=adam bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/02_app_basic.sh` | `PASS 02_app_basic` |
| ③ | `NDT_OWNER=adam bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/03_app_p4runtime.sh` | `PASS 03_app_p4runtime` |

在**跑 lab 的那個 checkout**（主 checkout，`/home/adam/Desktop/NDTwin-Kernel`）的根目錄跑。`ndt` 只在
`/etc/ndtwin-lab.conf` 的 KERNEL_DIR 指的那一棵樹裡動 lab（`guard_lab_acts_in_this_tree`；這台機器沒有那個檔，
ndt 就用它內建的 `LAB_DEFAULT_KERNEL_DIR`，也就是主 checkout——第五輪更正），而且那棵樹要有
建好的 `build/bin/ndtwin_kernel`——功能分支的 worktree 兩樣都沒有，所以分支要先併進主 checkout 再跑。
腳本自己從所在位置推 repo 根，所以 `cd` 到哪裡都行，上面寫相對路徑只是因為那樣好貼。

失敗時最後一行是 `FAIL <step> -- <原因>`，rc 1。
**rc 2＝拒絕**：root 拿不到、lab 被別人 claim、claim 裡有 `measuring=`、package 目錄不在、
pre-flight 紅——這些都在**還沒動任何東西之前**就停，什麼都沒起、什麼都沒寫。

raw 一律在 `live-p1/runs/<UTC>_<step>/`，最後一行的上一行會印路徑。**之後整個 `runs/` 進 audit-raw。**

---

## 🔴 驗收 ① 沒有「改動前」可以逐格比——這件事先講

工單要「和改動前逐格同」。**我找不到可比的改動前 raw**，找法與結果：

- `GET /p4/switch_state`：`scratch/overnight-2026-09-05/logs` 與 `hunt-0911/logs` 底下
  **一份存檔都沒有**（用 `probe_ok`／`probe_age_s`／`switch_state` 三個字串各掃一次，
  命中的全是 proxy／kernel 的 log 和 C++ 原始碼，沒有任何一份是那個端點的回應）。
- `GET /ndt/get_graph_data`：存檔很多，但**最新的 BMv2 平面**那幾份是 2026-09-06／09-07 的
  **128 主機** fabric（`logs/x2-sweep/001_GET_ndt_get_graph_data.json`、
  `logs/r3-topo-g-mixed-plane.json`）。驗收 ① 講的是 `ndt up p4 4`＝**4 主機**，
  所以那幾份**不是同一個網路**，逐格比沒有意義。09-11／09-12 那批 graph 存檔全是 **OVS** 平面。

⇒ **`01_baseline.sh` 是第一份 baseline，不是比對的後半。** 它能證明的是「合併後的樹自身自洽」：

1. 兩個**新增**的鍵在 baseline 也出現，而且是空的——`control_plane {mode: ndtwin, package: null,
   skipped: []}` 與每台 `entries_recorded: 0`（P1-A §4-1 的決定：揭露欄位一律發出，
   「只在有東西時才出現」的欄位和「這個 proxy 舊到沒有這個欄位」分不開）。
2. **結構欄位**與 kernel 拿到的模型一致：10 台交換機、4 台主機、brand `BMv2`、每台 `probe_ok`。
3. 時間戳／age 類欄位（`probe_age_s`、`last_lldp_age_s`、任何 `_at`）**不比**——那是「什麼時候抓的」。

存下來的目的就是讓**下一次**改這段碼的人有我沒有的那份逐字「改動前」。

---

## 每一步在驗什麼、以及它**不**證明什麼

### ① `01_baseline.sh` — 無 package 的 baseline
先確認 `p4_proxy/mininet/app_package_override` **不存在**（存在就 rc 2 拒絕：有那個檔的話
proxy 和拓樸腳本建的是別人的 exercise，底下每個數字都在描述另一個 fabric）。
然後 `ndt up p4 4` → 存 `switch_state`、`get_graph_data`、`ndt status`、`verify_p4`、
proxy log 前 40 行 → teardown。

proxy log 那 40 行裡要有 `[Proxy Agent] app package: baseline (mode ndtwin, election_id 0,1)`
——那是 proxy 唯一一處自報它認為自己在服務哪個 fabric。

**不證明**：它不是驗收 ①「逐格同」的後半（見上）。

### ② `02_app_basic.sh` — `exercises/basic` 的 pod-topo，NDTwin 自己的控制面
`convert.py` 產 `.test_run/packages/basic` → `preflight.py` 要 PASS →
`ndt up p4 --app <pkg>` → `switch_state.control_plane.mode == ndtwin`、`package` 是那個路徑、
`skipped == []`、四台交換機、每台 `entries_recorded == 5` → `verify_p4` →
**12 個有序主機對全部 ping 通**（走 `ndt` 自己的 `dataplane_ok`，它會先單獨問權限再問轉發，
所以少一條 sudo 授權不會被報成「fabric 不轉發」）。

**不證明**：0% loss **不**代表 NDTwin 在跑 `basic.p4` 的 pipeline——它沒有，而且到 G4（階段二）
之前都不會。exercise 自己的 runtime 表項也**沒有被套用**：`entries_recorded: 5` 是
「記錄了五筆、一筆都沒裝」的**揭露**，不是結果。

### ③ `03_app_p4runtime.sh` — exercise 自己的控制器與 proxy 共存
`--app <p4runtime pkg>` 起來的 fabric **是空的**（`mode: external` ⇒ proxy 不開 arbitration
stream、不推 pipeline、不寫任何東西、不發 LLDP、不裝路由；`skipped` 要含
`pipeline_push`／`clone_session`／`lldp`／`link_watchdog`／`initial_routes` 五個）。
（09-27 起 `ndt up` 在這個 fabric 上也啟動心跳，**只偵測**：`heartbeat.watchdog` 是 `running` 時
`link_watchdog` **不在** `skipped` 裡——watchdog 在跑，由心跳餵；其餘五個照樣在。03／04 **斷言** `heartbeat.watchdog`
是 `running`（不是讀它來挑清單；opus judge 09-27 對 02 的 N1），再要求那五個，跟 02 共用 `_common.sh` 的
`heartbeat_skips_verdict`。）
`ndt up` 的 [3/3] 會把「路徑數」與「轉發」兩格印成 **NOT CHECKED／NOT TESTED 並說原因**，
而不是判紅或判綠——這一步看到那兩行是**預期**，不是故障。

然後 `setsid` 跑 `run_external_controller.py <pkg> mycontroller.py`（B 的 adapter 在**控制器那側**
把寫死的 `127.0.0.1:5005N`／`device N-1` 改寫到這個 fabric 的埠）→ 等 10 s → `h1` ping `h2` 要通
→ 用**第三方 client**（`p4runtime_mastership_probe.py` 的 `channel`／`count_entries`，**純讀**，
**不跑**那個檔裡會清表的 scenario 2／3）數 s1 表項 N → `POST :8081/p4/readopt/1` 要 4xx/5xx
且 body 要**指名 external／read-only** → 再數一次要等於 N、再 ping 一次要還是通。

**內建的控制組**：`N` 在 readopt **之前**必須 > 0，而且那時 ping 必須已經通。否則
「數字沒變」對一台根本沒有表的交換機也成立，第 7 步就什麼都沒證明。

**readopt 的 body 為什麼要指名 external**：P1-A §4-8。它以前也 fail closed，但講的理由是
mastership race——那句話在描述一場這個 proxy**輸掉**的競賽，實情是它被設定成永遠不參賽。
operator 對這兩件事的處置不同（前者重試／power-cycle，後者是你要的模式）。

**不證明**：它不證明 65535 在真的仲裁裡**贏得** primary——external 模式下 proxy 根本不投標。
它證明的是「proxy 掛著、被要求去接管、拒絕了，而且 exercise 的表和轉發都沒有被動到」。

---

## 收尾與失敗處理

- 三支都會在 teardown 之後檢查 `p4_proxy/mininet/app_package_override` 是不是真的不見了。
  **如果它還在**，會印一行紅字＋檔案內容：下一個 `ndt up p4` 和下一個 proxy 都會讀它，手動 `rm`。
- `ndt release` 在 `host_count_override` 還沒寫回時會拒絕（E-11b），所以 trap 的順序是
  **控制器 → `ndt down` → 寫回 knob → release**，而且**不用 `--force`**。
- Ctrl-C 也會走同一個 trap。中途被 systemd-oomd 砍掉就不會——那時手動
  `NDT_OWNER=adam ndt down && NDT_OWNER=adam ndt release`，並確認上面那個 knob 檔不在。
- 檔案／目錄：`_common.sh` 是三支共用的前置（工單只列四個檔，多出來的這一個與理由寫在
  `P1-C-SUMMARY.md`；三份同樣的 claim／teardown 程式碼正是這個 repo 反覆記錄的那種缺陷）。

---

## 階段三新增的兩支（TICKET-P3 §2.7）

| 步 | 貼這一行 | 最後一行應該是 |
|---|---|---|
| ⑤ | `NDT_OWNER=adam bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/05_link_usage_generic.sh` | `PASS 05_link_usage_generic` |
| ⑥ | `NDT_OWNER=adam bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh` | `PASS 06_thirteen -- 26 arm(s), every arm as the exercise says it should be` |

**跑的順序**：①②②b③ 之後才跑 ⑤，⑤ 綠了才跑 ⑥。⑥ 很長（26 個 arm，每個都自己起一次 fabric）。

### ⑤ `05_link_usage_generic.sh` — 通用格，三組

**在驗什麼。** 前面每一支驗的都是某一支 exercise 的程式；這一支驗的是 **NDTwin**：
iperf 期間，twin 的 `link_bandwidth_usage_bps` 在**真的搬了位元組的那些 `sN-ethP` 上非零、
在沒搬的交換機間邊上為零**——不管交換機在跑誰的程式。這是 TICKET-P3 §2.2「先記鏈路位元組、
再談流身份」可以被斷言的那一半。

三組，第三組是讓前兩組有意義的那一組：

| 組 | package | `--telemetry` | 斷言 |
|---|---|---|---|
| 1 `link` | `convert.py --p4 solution/basic.p4`（**exercise 自己的程式**） | `link` | on-path > 0、off-path == 0 |
| 2 `cooperative` | 同一支 exercise，`--ndtwin-pipeline`（**NDTwin 自己的程式**） | `cooperative` | 同上 |
| 3 `none`（陽性對照） | 同組 2 的 package | `none` | **on-path 必須恰好 0** |

**為什麼第二組要換 package 而不是只換那個字**：`basic.p4` 沒有合作式的 `packet_in` header，
`cooperative` 對它會在啟動時被拒（§2.1）。要看合作式那條路就得讓交換機跑 NDTwin 自己的程式。

**不證明**：它不比較三組的取樣誤差或成本——那是工單 E（`doc/audit/2026-09-19_telemetry-three-groups/`）。
這裡只有「非零／在門檻之下」。

#### 🔴 為什麼 off-path 的界是「門檻」而不是「恰好 0」

第一版寫的是「非路徑的交換機間邊積分 == 0」。**那會在一個完全正常的 fabric 上隨機判紅**：

- 工單 A 併回之後，kernel **先記鏈路位元組、再問流身份**（§2.2）——ARP、LLDP、IPv6 鄰居探索
  全都會計入鏈路使用率，而它們以前在 `etherType != 0x0800` 那一行就被丟掉了；
- NDTwin 自己的 pipeline 上，proxy 會沿**每一條**交換機間鏈路送 LLDP 信標，而 pipeline 取樣 1/256。
  八秒視窗裡抽中一顆信標是很平常的事，**而抽中一顆就會被記成 256 倍的訊框長度**——
  一條什麼都沒載的邊上幾十 kbit。

#### 🔴 一條邊分三類，因為「載了流」和「取樣器看得見」是兩件事

（TICKET-P3 §9 ruling 20①，第一次 live 跑出來的。）qos/solution 的真實 tx 增量是
`s1-eth3` 2,162,160 B、`s2-eth1` 2,162,160 B（真的流），外加 **`s1-eth4` 15,120 B、
`s3-eth1` 15,120 B——十個 datagram 走的側支**。四個都過 10 kB，舊規則把四個都當 on-path
並要求積分 > 0；但 1/256 對十個封包的**期望樣本數是 0.04** ⇒ twin 積分 0 是對的，
**紅的是格子，不是 twin**。

| 類別 | 條件 | 這一格怎麼對待它 |
|---|---|---|
| **主路徑 P** | 增量 ≥ `max(10 kB, 5% × 最大的交換機介面增量)` | **斷言**：積分必須 > 0 |
| **次要 M** | `10 kB < 增量 < 5% × 最大` | **兩邊都不斷言**；但要印出來，並附「期望樣本數＝增量 ÷ (MTU × rate)」 |
| **off-path** | 增量 ≤ 10 kB | 積分要在下面那個**門檻**之下 |

M 不斷言的理由要說清楚：取樣器**可能**抽到、**可能**抽不到，所以「twin 看到了」和
「twin 沒看到」**兩句都不是發現**——斷言任何一邊都會讓一個正確的 twin 隨機判紅。
欠讀者的是**數字本身**與**取樣器本來該看到多少**，那兩個都印。

所以 off-path 的界是
**`max(一個樣本的量 = 256 × MTU × 8 bit, 2% × 最小的【主路徑】積分)`**，兩者取大：

- **絕對項＝一個樣本的量**（§9 ruling 26①、31④）。1/256 取樣下，被抽到的**一顆**幀會被記成
  256 × 幀長；MTU 1500 B 時是 `256 × 1500 × 8 = 3,072,000 bit`。**取樣器有可能報出的最小的
  東西就是這個數**，界訂在它以下等於對雜訊判紅。舊的 `5 kbit` 常數已經**移除**而不是留在
  `max()` 裡：`max(5000, 3072000)` 永遠是後者，留著就是一條沒有輸入到得了的死算術。
- **相對項**只在流夠大的時候接手：要 `2% × 最小主路徑積分 > 3,072,000`，最小的那條主路徑
  積分得超過 `3,072,000 / 0.02 = 153.6 Mbit`。8 秒 2 Mbit/s（≈16 Mbit on-path）還差得遠，
  那一格是**絕對項**在管；長視窗、大流量的時候才換相對項管。
- 取**最小**的【主路徑】積分而不是最大：一個視窗裡的主路徑邊本來就不相等（host 那條載一次、
  路徑長的交換機間邊載第二次），**最小的那個是保守的一端**。
  🔴 **而且只從 P 算**：M 的積分本來就該是 0，算進去會把界壓成 0。

**每一條 off-path 邊的原始積分都會印出來**，判了或沒判都印。界不是零的時候，
「在界之下」和「恰好是零」在 raw 裡長得一樣，而**餘裕本身才是要看的東西**。
（TICKET-P3 §9 ruling 9 的 R4；紅綠雙向的格在 `tests/shell/test_live_p1_common.sh` §5c-bis。）

### ⑥ `06_thirteen.sh` — 13 支 × 兩臂

**它自己不判定**：每一格的判定都在 `drive_exercise.py` 裡，它自己 claim、自己 `ndt up`、
自己 down＋release、自己寫 report。⑥ 加的是那 26 次分開跑看不到的東西：一張表，
說哪些 arm 跑了、各自 exit 多少，以及——**重點**——**每一臂都守住了它自己那組期望**。

🔴 **「紅」是期望的性質，不是 rc 的性質。** driver 的骨架臂斷言的就是紅的那些事
（「h2 收到 0 個」「每個回報的 port 都是 0」「這條流**沒有**被擋」），所以
**骨架照 exercise 說的方式表現時，那些期望全部 PASS，driver exit 0**——09-08／09-18 的實跑就是
`>>> PASS (2/2)`、`PASS (4/4)`、exit 0。第一版把骨架的期望值寫成 rc 1，
**一輪完全正確的 26 臂會印成 `FAIL 06_thirteen -- 11 of 26`**（judge A2）。

**骨架臂 exit 1 ＝ FAIL**：代表它的紅斷言有一條沒守住，也就是骨架沒有照 exercise 說的方式表現——
那一支的解答臂就不再是關於解答的證據了。

**兩個例外**，紅在「拒絕」而不在資料面，driver 印 `RED ARM (n/n): … by design`、exit 1：

- `flowcache` 骨架（兩個 fabric 都是）——`p4c` 拒編（README:29）；
- `basic_tunnel` 骨架（**兩個 fabric 都是**）——它的 runtime entries 指名一張骨架沒有宣告的表
  （README:41-43）。NDTwin 上是 pre-flight 拒絕，tutorials 上是 harness 自己丟例外——
  **同一個拒絕，兩條路**。
  🔴 第二輪只修了 NDTwin 那半（旗標掛在 `run_on_ndtwin` 上、判定又問 `args.fabric`），於是
  同一支 exercise 在 tutorials 印 `PASS (1/1)`／exit 0、在 NDTwin 印 `RED ARM (1/1)`／exit 1
  ——**正是 A6 指的那個缺陷，只做了一半**。第三輪把旗標改成 module-level、判定不再問 fabric。

**⑥ 自己不 claim lab**，因為每一次 driver 的 round 會自己 claim；這支若持有 claim 會擋掉自己的子程序。
所以它**不 source `_common.sh` 的 `start_step`**，也沒有自己的 fabric 要拆——它唯一碰的狀態是
三個 knob，而且是**檢查**而不是寫（每一 round 自己會寫回；⑥ 是在斷言它們真的寫回了）。

`ONLY=basic,calc bash .../06_thirteen.sh` 可以只重跑一部分。

**rc 2 的那一格不是結果**：pre-flight／claim／compile／root 任一個擋掉都是 2，代表那一 round
根本沒跑，既不算紅也不算綠，表上會標出來。

---

## 階段四第一刀新增的一支（TICKET-P4-roles §5-2）

| 步 | 貼這一行 | 最後一行應該是 |
|---|---|---|
| ⑦ | `NDT_OWNER=adam bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh` | `PASS 07_roles_basic` |

**寫的人沒跑過它**（沒有 sudo、沒有 lab）。離線自測：`bash .../07_roles_basic.sh --self-test`——每個判定
各餵一份該綠、一份該紅的合成 capture，再拿真的 `2026-09-19T062604Z_02_app_basic` 驗 L1 的判定讀出 0/8
（那一份不在版控裡，`SELFTEST_OLD_RUN=`／`SELFTEST_OLD_TOPO=` 指到跑過它的那個 checkout）。自測只證明
判定分得出兩種答案，**不證明任何 fabric 的事**。

**兩段、一個 claim。** 先 `convert.py --role-ipv4-route owner=ndtwin,...` 產 `basic_roles`（ipv4_lpm 的比對 entries
被拿掉、只留 default action）跑 L1／L2／L3／L4／L6；`ndt down` 後換成不帶 roles 的 `basic_noroles` 跑 L5 與
unbound 的 L6。L4 **不斷言改路**（第一刀 (c) 不成立，`capabilities.reroute: false`），斷鏈期間的流量照實記在
`54_pingall_during_cut.txt`。外來 fabric 上邊的 `is_up` 來自**宣告**的鏈路，不是斷線偵測。

**段 W（TICKET-P4-heartbeat）之後**：`ndt up p4 --app` 會在這兩個 package 上啟動心跳。

- **L6 的預期已改**（fable judge 2.4）：
  - owned 是 `reroute: true, link_discovery: "heartbeat"`；
  - unbound 是 `reroute: false, link_discovery: "heartbeat"`。
  - 兩者都需要心跳真的有在跑；`ndt up` 沒能啟動心跳的那次 run，會讀到 `declared`／`false`，L6 就會紅。
- **switch_state 上的 L1 也已改**（fable judge 對 ebdf365e 的 R2 附註）：
  - 要求 `links` 正好是那 8 個宣告的方向，每一個都是 `source: heartbeat, down: false`；
  - 會輪詢最多 30 s，因為 proxy 的第一個 watchdog pass 才會把心跳餵進 `links`；
  - owned 和 unbound 兩個 package 都檢查。
  - 原本要求的是 8 筆 `source: declared`，心跳一跑就一定紅。
- **L4 記下的流量數字可能會變**（INFERRED，沒跑過）：
  - L4 的 `inject_link_failure` 會在兩端下 netem，心跳幀也會一起被擋住；
  - 所以在 owned 那個 package 上，proxy 現在會自己偵測到斷線並**改路**；
  - 因此 `54_pingall_during_cut.txt` 的遺失可能比第一刀記錄的少。
  - L4 本身仍然不斷言改路；改路由 ⑧ 的 H1 驗。
  - recovery 之後，proxy 要等到心跳重新聽到那條鏈路（最多約 10 s）才會回報 up。這和 kernel 的 recovery 之間有沒有互相打架，也還沒在真機上看過。

[Co-developed with claude code -- Adam]

---

## 階段四第二刀新增的一支（TICKET-P4-heartbeat §2 live，段 W）

| 步 | 貼這一行 | 最後一行應該是 |
|---|---|---|
| ⑧ H1–H4 | `NDT_OWNER=adam bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh` | `PASS 08_heartbeat` |
| ⑧ H5 | `NDT_OWNER=adam PART=h5 bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh` | `PASS 08_heartbeat` |

（做 external 比對的那一次 H5 不看這一行：它的判準寫在下面「合併前的比對」，08 的最後一行可能因為 verdict 自己翻而是
FAIL。）

**寫的人沒跑過它**（沒有 lab）。離線自測：`bash .../08_heartbeat.sh --self-test`——每個判定各餵一份該綠、
一份該紅的合成 capture，teardown 用假 ndt 走一遍（down 回 5／1 時**不 release、保留 claim**），前導段單獨跑、
讀回預設值。只證明判定分得出兩種答案，**不證明任何 fabric 的事**。

- **INT／TERM 是失敗**（AEG judge 09-28 的 N-1）：各有自己的 trap，記下 `interrupted by SIG…`、以 130／143 結束，
  EXIT trap 照常拆；用 pid 停掉的 run **不可能**以 PASS 收尾。
- **必須明給 `NDT_OWNER`**（沒給就 rc 2、什麼都沒做）；**從不宣告 `measuring=`**，所以自己的 `ndt down` 不會被
  T2d 擋；最後一次 `ndt down` 不是 0／3 就**不 release**（段 S 第 7 輪的教訓）。
- H1 的剪線**控制相位**：
  - 前 `H1_WORST`（預設 3）次在心跳一輪送出後 `PHI_WORST`（0.02 s）剪，也就是最壞相位；其餘隨機，種子記在 log，`H1_SEED=` 可重現。
  - 每次剪線和復原都記在 CLOCK_MONOTONIC 上（`30_cycles.tsv`）：
    - 兩端 tc 呼叫的前後時刻，是 **shell 自己的 `$EPOCHREALTIME`，不是 fork 出去的 `date`**；
    - 兩個方向最後／最先聽到的幀；
    - graph 的 down／up 時刻；
    - 報告這次變化的那個 watchdog pass、它晚了多少、pass 到 graph 花了多久。
  - 落在剪線或復原窗口內的幀**標出來，不丟掉**。
- **H1 的驗收是「最多約 20 s」**（Adam 09-27 裁決：與 NDTwin 自家 fabric 的 LLDP 同級，同一條規則、同一組常數）：
  - 嚴格的 20 s 照量、照記：每個 cycle 在 `30_cycles.tsv` 的 `strict_20s` 欄寫 `yes` 或 `OVER+x`，那個 cycle 自己也印一行嚴格值。
  - 超過 20 s 的 cycle **揭露為 NOTE，不判 FAIL**：run 的最後一行（`PASS 08_heartbeat` 或 FAIL 的原因）正上方，會有一行 `NOTE 08_heartbeat -- H1: N of M cycle(s) over the strict 20 s -- disclosed, not a failure …`，**逐字**列出每個超過的 cycle 自己那行嚴格值。H3 的那一個 cycle 也一樣。run 在 H1 迴圈或 H3 **中途停下**（剪線或復原失敗而 exit、INT／TERM）時，EXIT trap（`w_finish`）先把已量到的 cycle 結算，那行寫成 `H1, cut short: …`，一樣在最後一行正上方。
  - 「約」**不延伸**到這兩處（opus judge 09-27 的 N2）：偵測有**硬上限 35 s**（`DETECT_BOUND_S + 15`：graph_until 等到這裡就放棄；09-28 起 `v_strict` 自己也把超過 35 s 的判 **FAIL**——慢的最後一次輪詢也逃不掉；AEG judge 的 N-4），不是 NOTE；**復原仍以嚴格 20 s 判定**（`RESTORE_BOUND_S`，超過判 FAIL）——裁決只講偵測，復原要不要也改成「約 20 s」待 Adam 決定。
  - （裁決前：那個 cycle 判 FAIL，最後一行以「`H1: N of M cycle(s) OVER the strict 20 s … until Adam rules on the acceptance`」開頭——fable judge 的 F1，09-26。）
  - 「20 s ＋ 實際量到的時間」只是**診斷欄**：它包含 pass 晚到的部分、讀檔／HTTP／kernel／本腳本輪詢，以及剪線本身開的窗口。judge 證明了這個數字在設計照常運作時恆為 OK。
  - 設計的最壞情況是 (15 s − φ) ＋ 最多一個 watchdog 間隔 5 s ＋ 上述那些，**在 φ→0 時嚴格 20 s 沒有任何餘裕**；所以是「約」20 s，這正是自家 LLDP 的同一性質。
  - **一次 run 只取樣到一個 ψ**：watchdog 的相位每個 pass 只漂一個 pass 的耗時，所以最壞的 ψ 不保證被取樣到。
- H4（09-27 起）：external 的 p4runtime 上 `ndt up` 也啟動心跳，**只偵測、不改路由**。驗：`ndt up` 說 detect only、
  helper 在跑、switch_state 心跳 usable、capabilities `reroute: false`／`link_discovery: heartbeat`、`reroute.reason`
  仍是 `external_control_plane`、四個 `/stats/flowentry/*` 仍是 409；剪 s1-s2 一條線，**proxy 自己**（switch_state
  的 `links`）兩個方向都判 down、來源 heartbeat，約 20 s 內（超過揭露、不判 FAIL），剪著時 reroute 仍 false；
  復原後兩向 up、沒有殘留 netem、沒有心跳幀離開 host 埠。**這裡不看 kernel 的 graph**：H4 沒跑 exercise 的控制器，
  pipeline 沒載入，twin 把這些交換機判 down（03 在 09-18 的讀數）。09-28 起（external judge 的 F4、F9）還要：
  剪線後與復原後兩個方向的 `reported_to_kernel` 都是 true（kernel 收下了）、每台交換機的
  `pipeline_commits`／`rules_timed`／`table_generation` 在剪線與復原前後都沒動；復原以**嚴格 20 s** 判（輪詢等到 35 s，
  只是為了晚到的也量得到）。
- H5 不自己 claim（06、01 每步自己 claim），跑 06 一次時旁邊有一個讀心跳報告的 sampler，逐臂對
  `OLD_06`（預設 `2026-09-27T074635Z_06_thirteen`；09-27 前是 `2026-09-24T185505Z`，兩者 rc／verdict 逐臂相同。
  **做 external 比對時設成同一個 session 的對照組 C1——一個完整的 06**，見下面「合併前的比對」；第五輪起
  `OLD_06` 不是 26 臂就在開跑前拒絕，rc 2），並確認心跳只在 20 個多交換機、
  有建出來的外來臂上跑過（09-27 前是 17 個：當時不含 3 個 external 臂）；接著跑 01。sampler 每一列也記報告的
  `written_wall`、`stop_reason` 與 daemon 的四個計數器，`50_t06_end.txt` 記 06 結束的時間；第五輪起再加每個方向的
  `heard` 與當下活著的 exercise 控制器 pid，第六輪起再加每個控制器 log 的大小（`ctrl_logs`，sampler 開始之後
  才建的 round 目錄裡的 `driver-controller-*.log`）。`C_IDENTITY`＋`B_SHA` 給了時，06 開跑前先確認這棵樹是對照組的
  程式加上 B（`code_identity.py verify`），不是就 rc 2。
- 任何 `forwarded_to_hosts > 0`（心跳幀離開 host 埠）＝裁決 4，最後一行以 `STOP` 開頭。

[Co-developed with claude code -- Adam]

---

## external 的臂也跑心跳之後（09-27，只偵測）

`ndt up p4 --app` 從 09-27 起在 **external control plane 跑自己的 pipeline** 的 fabric（06 的 p4runtime 兩臂、
flowcache/solution）上也啟動心跳：proxy 宣告 package 的連線、由心跳判斷哪條斷了、告訴 kernel，**不寫任何交換機**
（client 沒有 arbitration、每個寫入都拒絕；`install_initial_routes` 仍在 `skipped`），`reroute` 永遠是 false、
理由 `external_control_plane`。Adam 09-25 的條件：心跳若改變使用者自己的轉發結果，就停下來回報。

### 🔴 看不到的地方（external judge 09-28 的 F3，揭露）

- **這對「每一個」跑自己 pipeline 的 external package 都生效**，不只這三臂。helper 只拒絕 NDTwin 自己的
  pipeline（argv 裡的 `ndtwin_switch.json`）。
- 心跳幀會進 exercise 自己的 pipeline。**一個會把未知 ethertype 送上控制器（punt）或洪泛的程式**——最明顯的是
  L2 學習型的控制器——會把 0x88B5 的幀交給**它自己的控制器**或它的 host。
- 這兩條路 NDTwin **都看不到**：proxy 在 external 上沒有 stream（packet-in 不經過它），daemon 只數離開交換機埠的
  幀。所以 switch_state 的 `side_effects`／`frames_reached_hosts` 在「punt 給控制器」這一種上**是盲的**。
- 這三個程式為什麼應該會丟掉它，是**從 P4 原始碼讀出來的，不是量到的**（第二輪 judge 的 S1）：
  - **flowcache/solution**：parser 對非 0x0800 的幀不再往下解（`flowcache.p4:137-143`）；ingress 丟掉不是
    packet-out 也不是 IPv4 的所有東西（`:251-257`）⇒ 不 punt、不建 cache entry、counter 不動（counter 只數
    packet-out 與 CPU 埠的 egress，`:236-238`、`:279-283`）。
  - **p4runtime（advanced_tunnel，skeleton 與 solution 同一個程式）**：parser 預設 accept（`advanced_tunnel.p4:70-74`），
    沒有任何表會套到這種幀（`:170-180`），`egress_spec` 停在 0；「沒有埠 0 ⇒ 幀被丟」是從 bmv2 的行為**推論**的。
    tunnel counter 只在 tunnel action 裡動（`:123-141`）；沒有控制器 header，不可能有 packet-in。
  - 段 S 的普查（`40_census.tsv:24-26`）在這三臂上手動跑過心跳，**沒有啟動它們的控制器**
    （`S_heartbeat_spike.sh:63-65`）。第五輪對著那份 raw 重寫這一句（round-4 review 的 S-3；舊句「沒有 pipeline、
    量到的是空的交換機」被它自己的 raw 推翻）。raw 顯示的是（OBSERVED）：每台交換機跑的是 package 編好的程式
    （`census_<臂>/30_report.json` 的 `fabric.switches.*.program` 三臂都是 `advanced_tunnel.json` 或 `flowcache.json`，
    取自 bmv2 的啟動 argv），沒有任何表項；每個方向送 5、聽到 5；三個 host 都沒看到幀，daemon 的轉出／誤送／外來
    都是 0。`10_up.txt` 的「no pipeline loaded on any of them」是 P4Runtime 的說法：沒有人推過 pipeline config，
    liveness probe 回 FAILED_PRECONDITION——不是 data plane 是空的。所以那三列量到的是**程式的預設動作**（正是
    drop check 問的事），**`PART=h5` 是第一次在控制器載入程式、裝上表項之後量**。
- **Adam 09-28 裁定：預設安全，不是預設開**。`ndt up p4 --app` 在 external control plane 上**先**跑離線的
  drop check（`tools/test_workflow/heartbeat_drop_check.py`），證明程式會丟掉心跳幀，才啟動心跳；沒證明——
  不丟、或判斷不了——就不啟動，`ndt up` 與 `ndt status` 都寫原因（`.test_run/heartbeat.withheld`）。
  - 方法：一個丟棄式的 stock `simple_switch`（與 fabric 的 fast build 同一個 bmv2 commit，有逐封包 log）載入
    package 的**同一份編好的 JSON**，沒有控制器、沒有表項、沒有 clone session 與 multicast group；每個資料埠
    各打一個真的心跳幀（與 daemon 的 `encode()` 逐 byte 相同，測試釘住）；每個幀的去向讀 bmv2 自己的 log，
    並用每個接上的埠（資料埠與 CPU 埠）的輸出 pcap 交叉核對。轉到 fabric 的埠、送到 CPU 埠、digest、clone、
    multicast、任何 pcap 有幀 ⇒ 不丟；讀不到的 ⇒ 判斷不了（不是丟）。結果以程式 JSON 的 sha256 快取。
  - 這三個程式都過（2026-09-28 離線量）：flowcache 在 ingress 丟掉；advanced_tunnel 送到埠 0，而這個 fabric
    沒有任何交換機有埠 0。
  - 🔴 **限制**：只驗 package **宣告的那個程式**的預設（table-miss）行為；external 控制器之後裝的表項、clone
    session、multicast group 都不在涵蓋範圍內，**它自己推的另一個 pipeline（SetForwardingPipelineConfig）、
    它在 runtime 改的 default action 也不在**（round-4 review 的 S-2）。
  - 第五輪的加固：任何崩潰都是 rc 2（判斷不了），不是 Python 的 rc 1（ndt 會讀成「不丟」）；以 root 跑就拒絕；
    沒有資料埠可打的程式＝不適用（rc 3），不是空洞的 DROPPED；stock bmv2 的 `--version` 必須等於 fabric 那顆
    （`p4_proxy/mininet/bmv2_binary_override` 指的那顆）的，不同或讀不到就是判斷不了；兩次 `--version` 也以
    `ndt-hbdrop-bmv2` 為名執行（comm 不是 `simple_switch_g`）；每次 bring-up 一份完整答案的 log，檔名寫在那一行。
  - 已知的限制：兩個 check 同時挑到同一個 Thrift 埠時，後啟動的那顆綁不上、自己結束 ⇒ 判斷不了（不是通過）。
  - 不是 lab：以呼叫者身分跑（沒有 root），pcap、log、nanomsg socket 都在它自己的暫存目錄，Thrift 埠在
    29400-29499（lab 的埠之外，啟動前再確認一次沒人用），device id 遠高於任何 fabric，argv[0] 是
    `ndt-hbdrop-bmv2`——ndt 的 bmv2_count、helper 的 sweep、p4_testbed_topo、kernel 的 capacity scan 都不會
    把它當成 fabric 的交換機；以確切 pid 停止，checker 死掉時也一起死（PR_SET_PDEATHSIG）。
- **twin 那一側**（F5；Adam 09-28 裁定後改）：09-27 起 external 上 `/ryu_server/all_destination_paths` 曾是
  **在宣告連線上算的最短路徑**——external 上沒有已安裝的路由可讀，那是 twin 的猜測，不是 exercise 真正的轉發。
  **現在回到不報任何路徑**（unknown，不是猜測）：轉發是 exercise 自己的控制器的事，proxy 不知道。宣告的連線
  照樣進 topology（心跳要判它們）；NDTwin 自己的 pipeline 不變。

### 合併前的比對——可以照著跑的程序（預先登記；第五輪重寫，第六輪改：round-5 re-review 的 M-1..M-3、S-9）

[Co-developed with claude code -- Adam]

**要回答的問題**：B 讓 external 臂也跑心跳之後，三個 external 臂（p4runtime skeleton／solution、flowcache
solution）**exercise 自己**的證據有沒有變。**不是**拿來和 074635Z 比：它跑的是 `5dc7fc9a` ＋ 95 個未提交的檔，
沒有 venv 指紋，只能當參考。

**第五輪改了什麼**（第四輪的程序照做會出錯）：
- 第四輪的 C1／C2 是 `ONLY=p4runtime,flowcache`（4 臂），而 T 的 H5 拿 C1 當 `OLD_06` 比 26 臂——每一次 T 都會
  以 `H5 06 against <C1>: the reference table has 4 arms, not 26` 收尾（M-1）。⇒ **對照組改成完整的 06**；08 的
  `PART=h5` 在 `OLD_06` 不是 26 臂時，**什麼都還沒跑就拒絕**（rc 2）。對照組與處理組因此也跑同一個臂序。
- 本地 merge 沒有保護（M-2）。⇒ 每個 run 記下**程式身分**（`code_identity.py`），`compare` 對不上就拒絕（rc 3）。
- 一個欄位的範圍規則撐不住小的誤判率（S-9，算式在下面）。⇒ 欄位分成**判定的**與**只描述的**。

**第六輪改了什麼**（round-5 re-review；orchestrator 第六輪的裁定）：
- **身分多記四件事，而且每個 run 記兩次**：開跑前（`00_identity.before.txt`）與跑完（`00_identity.after.txt`），
  兩份不同 ⇒ 拒絕（跑的途中程式變了）。身分是：HEAD、它的 parents 與 **tree**；未提交的追蹤檔（路徑、狀態、
  內容的 sha256）；kernel／fabric 的 bmv2／**fabric bmv2 的 `lib/`（底下每個 shared object 的 sha256）**／drop
  check 的 stock bmv2／安裝的 helper 的 sha256；兩個 venv 的指紋；**`~/tutorials`**（HEAD、未提交的追蹤檔與
  sha256、`exercises/p4runtime`、`exercises/flowcache`、`utils` 底下每個檔的 digest——`build/`、`logs/`、`pcaps/`、
  `__pycache__` 不算，每個 round 都會重寫它們）。T 的 tree 必須等於 `git merge-tree --write-tree <C 的 HEAD> <B>`
  算出來的那棵：手動解衝突、amend 過的 merge 都不是「C 加 B」。
- **未提交檔的比較只看程式路徑**（orchestrator 裁定）：`doc/**/*.md` 與 `doc/audit/**/*.tsv` 不比（別的 session
  整天在主 checkout 改 ledger 與報告），**其餘每一個追蹤檔都比**。未追蹤的檔仍然不記：每個 live run 都在
  `runs/` 底下加 raw，必然不同（揭露，不檢查）。
- **編譯器與程式也要一樣**：每臂的 round 報告裡 p4c 的 sha256 與每個編出來的 JSON 的 sha256（§2 的表；控制器推的
  就是那個 `build/*.json`），在 C1、C2、T 之間必須相同，否則拒絕；報告裡沒有這兩列 ⇒ 讀不到（rc 2）。
- **「聽到」改用控制器自己的時間窗**（M-3）：sampler 多記一欄 `ctrl_logs`——每個 round 目錄裡
  `driver-controller-*.log` 當下的大小。窗的起點＝第一個看到 log 長到「最後一行 pipeline push（`Installed P4 Program
  using SetForwardingPipelineConfig`）的結尾」的 sample；沒有 push 行就用第一行 rule／cache entry；兩者都沒有 ⇒
  讀不到。終點＝log 最後一次寫入（mtime）。session 在窗口起點那一刻之前（含）的最後一個 sample 與終點之前（含）的
  最後一個 sample 之間，**每個方向都要至少多聽到一輪**，否則拒絕（rc 3）；起點時 session 還沒在跑也拒絕。
  **窗口短於兩個心跳週期（10 s）⇒ UNDECIDED（rc 2，照樣印出整份比對）**，不是拒絕：那麼短的窗口證明不了有沒有
  聽到。控制器的 pid 不再是依據（第五輪的版本靠 round 報告的 `controller pid N`；那一欄留在 samples 裡當背景）。
  測試用的是真的節奏：每個方向每 5 s 加一、sampler 每秒讀一次。
- **34 個依據 round 凍結了**：`external_survey_34.tsv` 記每個 round 報告與控制器 log 的路徑與 sha256；
  `external_survey.py <主 checkout 的 prep 目錄>` 檔案不見、內容變了、或任何一個帶心跳痕跡（detect-only 行、
  heartbeat block、running 列）就拒絕，其餘印出每臂每欄有幾種值（OBSERVED，2026-10-02：34 個都對得上、都沒有心跳，
  輸出在 logs/gates-0910/extb6/survey.out）。
- 程序本身（下面）：凍結從 C1 前到判定後；merge 之前的祖先檢查；H1–H4 在本地 merge 之下、判定之前跑；回復前檢查
  HEAD 是 T 的 merge commit；每一種中途結果都預先登記。

**在哪裡跑**：全部從主 checkout（`/home/adam/Desktop/NDTwin-Kernel`，下面寫成 `$M`）跑。這台機器**沒有**
`/etc/ndtwin-lab.conf`，ndt 用它內建的 `LAB_DEFAULT_KERNEL_DIR`，就是主 checkout，所以**不需要任何 root 步驟**。
B 沒有改任何 C++，**不需要重建 kernel**（重建了，身分就不同，`compare` 會拒絕）。每一步都要 `NDT_OWNER=<你>`，
照常 claim（06／08 自己 claim）。`B_WT` 是 B 的 worktree（停在 `B_SHA`）、`B_SHA` 是要 merge 的 B commit、
`LP=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1`、`ID="python3 $B_WT/$LP/code_identity.py"`。

0. **凍結與檢查**（orchestrator 宣布）：從這一步到第 7 步結束，trunk **不 commit、不 merge、不 push**。主 checkout
   停在 trunk 的 head，**還沒** merge B：
   ```
   C_HEAD=$(git -C $M rev-parse HEAD); [[ "$C_HEAD" == "$(git -C $M rev-parse trunk)" ]] || echo STOP
   git -C $M merge-base --is-ancestor $C_HEAD $B_SHA \
     || [[ "$(git -C $M merge-tree --write-tree $C_HEAD $B_SHA | head -1)" == "$(git -C $M rev-parse $B_SHA^{tree})" ]] \
     || echo STOP
   ```
   第二行：trunk 的 head 是 B 的祖先，或兩者 merge 出來的 tree 就是 B 的 tree——否則 T 跑的不是 B 測過的那棵，
   **停下**，B 先 merge trunk、重跑閘門，再從這一步開始。

1. **對照組 C1、C2（不含 B，完整的 06，不加 `ONLY=`）**，每一個都在開跑前與跑完各記一次身分：
   ```
   S=$(mktemp -d); $ID record $M $S/before.json        # 開跑前
   NDT_OWNER=<你> bash $M/$LP/06_thirteen.sh            # 最後一行前一行印出 raw 目錄 R
   cp $S/before.json $R/00_identity.before.txt
   $ID record $M $R/00_identity.after.txt               # 跑完
   bash $B_WT/$LP/venv_fingerprint.sh $R/00_venv.txt $M/p4_proxy/venv/bin/python /home/adam/p4dev-python-venv/bin/python
   ```
   （trunk 的 06 不寫這三個檔，那是 B 加的；B 的兩支只讀，不動 repo。）C1 的 `head` 就是回復點 C_HEAD。

2. **merge B 進主 checkout 的 trunk，只在本地、不 push**（orchestrator 做）：
   ```
   git -C $M merge --no-ff --no-edit $B_SHA; T_MERGE=$(git -C $M rev-parse HEAD)
   [[ "$(git -C $M rev-parse $T_MERGE^1)" == "$C_HEAD" && "$(git -C $M rev-parse $T_MERGE^2)" == "$(git -C $M rev-parse $B_SHA)" \
      && "$(git -C $M rev-parse $T_MERGE^{tree})" == "$(git -C $M merge-tree --write-tree $C_HEAD $B_SHA | head -1)" ]] || echo STOP
   ```

3. **處理組 T（含 B）**：一次 `PART=h5`，`OLD_06` 指向 C1，身分對 C1 跑完時的那份檢查：
   ```
   NDT_OWNER=<你> OLD_06=<C1> C_IDENTITY=<C1>/00_identity.after.txt B_SHA=$B_SHA PART=h5 bash $M/$LP/08_heartbeat.sh
   ```
   它跑完整的 06（26 臂）一次、旁邊的 sampler 每秒讀一次 daemon 的報告與控制器 log 的大小，接著跑 01。T＝它印的
   `06 rc …, raw …` 那個 06 run（B 的 06 自己寫 `00_venv.txt` 與兩份身分）；samples＝`<08 的 run 目錄>/50_samples.tsv`。

4. **H1–H4，仍在本地 merge 之下、判定之前**：`NDT_OWNER=<你> bash $M/$LP/08_heartbeat.sh`（`PART` 預設 h1h4）。

5. **比對**：
   ```
   python3 $M/$LP/external_evidence.py compare <C1> <T> --control2 <C2> --samples <08 的 run 目錄>/50_samples.tsv --b-sha $B_SHA
   ```

6. **結束**：判定是通過 ⇒ 照 orchestrator 的順序 push，解除凍結。其他每一種結果 ⇒ **回復本地 merge**，先確認 HEAD
   還是 T 的 merge commit：
   ```
   [[ "$(git -C $M rev-parse HEAD)" == "$T_MERGE" ]] && git -C $M reset --keep $C_HEAD || echo "STOP: HEAD is not T's merge"
   ```
   HEAD 不是 T_MERGE（凍結期間有人 commit 了）⇒ **不 reset**，回報。**永遠是 `--keep`，不是 `--hard`**：主
   checkout 帶著別人未提交的檔，`--keep` 遇到會被蓋掉的本地改動就停下來，`--hard` 會直接丟掉它們。回復後
   `git -C $M rev-parse HEAD` 應等於 C_HEAD、程式路徑的未提交清單應等於 C1 身分裡的那份。

7. 解除凍結（orchestrator 宣布）。

**判定（預先登記；只看下面這些，08 最後一行的 PASS／FAIL 不是 B 的判準）**：
- **H5 本身**：`H5 where the heartbeat ran` 必須是 OK（剛好 20 臂，含 3 個 external 臂——這就是 drop check 在
  live 也通過的證據）；ruling 4 的 STOP ⇒ 停下回報。某個 external 臂的 drop check 沒過 ⇒ 那臂沒有心跳、這一行
  會 BAD ⇒ T 無效，回報那臂的 drop check 輸出（每次 bring-up 一份 `.test_run/logs/heartbeat_drop_check.<UTC>.<pid>.log`，
  檔名就在那一行）。`H5 06 against <C1>` 的 rc／verdict 差異**只回報**：verdict 在更早的 round 裡會自己翻（見下），
  不是判準。
- **H1–H4**（第 4 步）：H4 **只**因為 `reported_to_kernel` 失敗 ⇒ kernel 處理 Down 交換機的發現（S4），不改變判定，
  但要回報；H1–H3 任何一個 FAIL、或 H4 因為別的原因 FAIL ⇒ **不通過**，回復、回報。
- **`compare` rc 0** ⇒ **通過**。
- **rc 1**（判定欄位的差異）：
  - `!! DAEMON`（該臂的 session 算到任何轉出、誤送或外來的幀）或任何 0x88B5 的 packet-in ⇒ **立刻失敗，停下回報**
    （Adam 09-25 的條件），不補跑：這是心跳幀真的跑到哪裡去了，不是統計上的差異。
  - 其他判定欄位的 `DIFF`／`INV BAD` ⇒ **T 重跑一次**（第 3 步，同一棵樹），用同樣的對照組再比一次，**只重跑這一次**：
    - 重跑 rc 0 ⇒ 通過，並回報第一次的 DIFF；
    - 重跑 rc 1、**同一臂的同一個欄位或不變式**再出現 ⇒ **失敗**，回復、回報；
    - 重跑 rc 1、但只在**別的**欄位 ⇒ **不通過、也不算失敗的定論**：回復、記錄兩次的 DIFF、回報 Adam，不跑第三次；
    - 重跑 rc 2（讀不到或 UNDECIDED）⇒ 同上：不通過、回復、回報，不跑第三次；
    - 重跑 rc 3（拒絕：程序出錯）⇒ 那次不算一次讀數；修正原因後**最多再做一次**這個重跑，再被拒絕 ⇒ 停下回報。
- **rc 2**：
  - `UNREADABLE` ⇒ 重跑出問題的那一個 run 一次，同樣原因再出現就回報。
  - `UNDECIDED`，對照組在一個判定欄位上彼此不同（預先登記以為是確定的，結果不是）⇒ 再跑兩次對照組 C3、C4
    （第 1 步；merge 之後要跑對照組就得先照第 6 步回復），`--control2 C2 --control2 C3 --control2 C4` 重比一次；
    通過 ⇒ 照第 2 步再 merge 同一個 B_SHA，它的 tree 必須與 T_MERGE 的相同；還是 UNDECIDED ⇒ 回報 Adam，
    **不算通過也不算失敗**。
  - `UNDECIDED heard`，某臂控制器的窗口不到 10 s ⇒ T 重跑一次；還是 ⇒ 回報 Adam，不算通過也不算失敗。
- **rc 3**（拒絕）：程序沒照做（缺 samples／C2／`--b-sha`／身分、對照組有心跳痕跡、session 沒有從頭到尾在跑、在
  控制器的窗口裡沒有每個方向都聽到）⇒ 修正後重跑；**心跳在某一臂中途停掉或什麼都沒聽到的處理組不算通過**。
  - **身分被拒絕而原因是別人的改動**（拒絕訊息裡不同的檔或 binary 不是這個程序動的：凍結期間別人改了主 checkout
    的程式路徑、重編了 kernel、換了 `~/tutorials`）⇒ 先回復（若已 merge），**從第 0 步、C1 重新開始**；被拒的 run
    留著當 raw，不再使用。
  - **merge 被拒**（第 2 步：本地改動會被蓋掉，或有衝突）⇒ 有衝突就 `git -C $M merge --abort`；確認 HEAD 仍是 C_HEAD；
    **不跑 T**，回報。C1、C2 只在之後的身分仍然相同時才能沿用。
- **這個 raw 答不了的**：「臂結束時 proxy 什麼都沒寫」——由 H4 的 `no_writes` 回答。

**判定的欄位與只描述的欄位，與誤判率的算式（S-9；預先登記，orchestrator 第六輪接受）**

*範圍規則為什麼不行。*沒有效果時，處理組與 n 個對照組可交換；一個連續的噪音欄位落在 n 個對照組範圍之外的機率是
2/(n+1)：n=2 是 67%，n=4 是 40%（每個欄位、每一次）。要壓到 5% 需要 n ≥ 39 個對照組。所以噪音欄位**不能**用
範圍來判。

*依據。*主 checkout 的 `runs/` 裡，B 之前、沒有心跳的同臂 round（2026-09-19 到 09-27，別的程式版本，只用來分類，
不是這次比對的資料）：p4runtime/skeleton 11 個、p4runtime/solution 12 個、flowcache/solution 11 個，共 34 個，
凍結在 `external_survey_34.tsv`。`external_survey.py` 用 `external_evidence.py` 的讀法逐欄數（OBSERVED，2026-10-02，
輸出在 logs/gates-0910/extb6/survey.out；第五輪 10-01 的計數與它相同）：

| 欄位 | p4runtime/skeleton (11) | p4runtime/solution (12) | flowcache/solution (11) |
|---|---|---|---|
| verdict | 2 種（1 個 ERROR：lab 沒還回） | 3 種（FAIL (1/5) ×3） | 4 種（FAIL ×3） |
| p4c、編出的 JSON 的 sha256 | 1 種、1 種 | 1 種、1 種 | 1 種、1 種 |
| rules_installed | 1 種 | 1 種 | 1 種 |
| counters_final | 1 種 | 4 種 | 1 種（空） |
| packet_ins／cache_entries／grpc_errors | 0／0／0 | 0／0／0 | 3 種／4 種／2 種 |
| 0x88B5、非 IPv4 的 packet-in | 0、0 | 0、0 | 0、0 |
| 不變式 | 都成立 | s1 ingress 100＝pings＋datagrams **只 1 個成立**；s2 egress 100＝s1 ingress 100 11 個成立；200 那條 12 個都成立 | 都成立 |

*分類（寫在 `external_evidence.py` 的 `DESCRIPTIVE`／`DESCRIPTIVE_INVARIANTS`）。*有任何一個 round 變過的欄位與
不變式＝**只描述**：印出對照組的值、處理組在不在它們的範圍內，**不計**——rc、verdict 三臂都是；p4runtime/solution 的
counters_final 與它的兩條流量不變式；flowcache 的 packet_ins、cache_entries、grpc_errors。其餘＝**判定**，對照組
必須一致、處理組必須等於它：skeleton 9 個、solution 7 個、flowcache 6 個，共 22 個檢查。

*判定檢查的誤判率。*沒有效果、而一個判定檢查每一次以機率 q 自己變的話，「對照組一致、處理組不同」至多 q；加上
「重跑一次、同一處再出現才算失敗」，至多 q²。
- **點估計**：34 個 round 裡判定檢查**一次都沒有變過**（22 個檢查 × 各自的 round 數，0 次）⇒ q 的點估計是 0。
- **每個檢查的保守上界**：0/N 的 95% 上界（1 − 0.05^(1/N)），平方：三臂共有的（rules_installed、0x88B5 與非 IPv4
  的 packet-in，N=34）0.7%；p4runtime 兩臂共有的（packet_ins、cache_entries、grpc_errors，N=23）1.5%；
  solution 自己的 200 那條（N=12）4.9%；skeleton 與 flowcache 自己的（N=11）5.7%——**略高於 5% 的目標，揭露**。
- **整個 run 的 family-wise 上界**：把 22 個檢查的上界**相加**，skeleton 23.7%、solution 11.5%、flowcache 19.2%，
  **共約 54%**（re-review 用略不同的 N 分配算出約 52%）。🔴 **這是上界的和，不是估計**：它假設每個檢查都以自己的
  上界在變，而觀察到的是 0 次；把它當成「一半的機會誤判」是讀錯了。orchestrator 第六輪接受這個規則，附這段揭露。
- **誤判的代價**：一個 FAIL 不是悄悄否決，而是一份記錄下來的調查，加上**那一次**預先登記的 T 重跑——**絕不**反覆重跑
  直到通過。
- **`!! DAEMON` 與 0x88B5 packet-in 不是統計判斷**：沒有效果時那些幀根本不存在（drop check 離線、段 S 普查的 daemon
  計數器在三臂都是 0），誤判率在設計上是 0。

*一個 PASS 不證明什麼。*
- **只描述的欄位不判**：p4runtime/solution 的 tunnel counter 與兩條流量不變式、flowcache 的 packet-in、cache entry、
  gRPC error 的數量。⇒ **PASS 排除不了「心跳改變了轉發的量」**——那些量本來就會自己變，這個比對分不出來。
- **重跑規則的檢定力是 p²**：一個真的、但只以機率 p 出現的效果，要兩次都出現才算失敗，被抓到的機率只有 p²
  （p=0.5 ⇒ 25%）。每次都出現的效果（p=1）一定抓得到；偶發的大多抓不到。
- 一次 T、兩個對照組：只看得到這三臂、這一次的 06；別的 external package、別的程式不在裡面（見上面「看不到的地方」）。

*為什麼現在改預先登記是正當的。*（1）這次比對還沒有任何 live 資料：C1、C2、T 都沒跑過，所以這個改動不可能是
看了結果才調的；（2）它用的只有規則本身的算術，和 B 之前、跑別的程式版本的舊 round——那些 round 只拿來決定
哪些欄位會自己變，不是比對的對象，而且現在凍結了；（3）它是 orchestrator 第五、六輪的裁定要求的；（4）它在一個
commit 裡，時間戳早於任何 live run，之後不再改——要再改，同樣得在下一次 live run 之前、寫明理由。

`external_evidence.py` 的細節（它的 docstring 是正本）：它從每臂自己的控制器 log、round 報告、`00_table.tsv`、
H5 的 samples 讀證據；拒絕／讀不到／比對／不變式的規則如上；N4 那份 switch_state 的 daemon 計數器是 pipeline
載入之前的快照，**只列、不判**。

**venv 指紋**：從 09-27 起每個 live-p1 raw（`start_step` 的每一步、06）都有 `00_venv.txt`——proxy 的 venv 與
控制器／driver 的直譯器各一段：路徑、Python 版本、protobuf 版本與 `api_implementation`、grpcio、所有已安裝套件
（`name==version`，排序）及其 sha256。取不到就揭露（`NOTE … venv fingerprint was not fully recorded`），不判 FAIL。
074635Z 沒有這個檔（它早於這個改動）。

[Co-developed with claude code -- Adam]
