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
`/etc/ndtwin-lab.conf` 的 KERNEL_DIR 指的那一棵樹裡動 lab（`guard_lab_acts_in_this_tree`），而且那棵樹要有
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
  **做 external 比對時設成同一個 session 的對照組 C1**，見下面「合併前的比對」），並確認心跳只在 20 個多交換機、
  有建出來的外來臂上跑過（09-27 前是 17 個：當時不含 3 個 external 臂）；接著跑 01。sampler 每一列也記報告的
  `written_wall`、`stop_reason` 與 daemon 的四個計數器，`50_t06_end.txt` 記 06 結束的時間。
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
  - 段 S 的普查（`40_census.tsv:24-26`）在這三臂上手動跑過心跳，但**沒有啟動它們的控制器**
    （`S_heartbeat_spike.sh:63-65`）——external package 沒有控制器就沒有 pipeline，所以那三列量到的是**空的交換機**。
    **`PART=h5` 是第一次在這三個程式載入時量**。
- 其他 external 程式**沒有人看過**。要不要給一個關掉的選項，orchestrator 在問 Adam；在那之前，這一段就是揭露。
- **twin 那一側**（F5；Adam 09-28 裁定後改）：09-27 起 external 上 `/ryu_server/all_destination_paths` 曾是
  **在宣告連線上算的最短路徑**——external 上沒有已安裝的路由可讀，那是 twin 的猜測，不是 exercise 真正的轉發。
  **現在回到不報任何路徑**（unknown，不是猜測）：轉發是 exercise 自己的控制器的事，proxy 不知道。宣告的連線
  照樣進 topology（心跳要判它們）；NDTwin 自己的 pipeline 不變。

### 合併前的比對——可以照著跑的程序（第二輪 judge 的 M1；預先登記，事後不改）

**要回答的問題**：B 讓 external 臂也跑心跳之後，三個 external 臂（p4runtime skeleton／solution、flowcache
solution）**exercise 自己**的證據有沒有變。**不是**拿來和 074635Z 比：它跑的是 `5dc7fc9a` ＋ 95 個未提交的檔，
沒有 venv 指紋，只能當參考。

**在哪裡跑**：全部從主 checkout（`/home/adam/Desktop/NDTwin-Kernel`）跑——它就是 `/etc/ndtwin-lab.conf` 的
KERNEL_DIR 指的樹，所以**不需要任何 root 步驟**。B 沒有改任何 C++，**不需要重建 kernel**；proxy 是 Python，下一次
`ndt up` 就用新的。每一步都要 `NDT_OWNER=<你>`，照常 claim（06／08 自己 claim）。

1. **對照組 C1、C2（不含 B）**：主 checkout 停在 trunk 的 head（**還沒** merge B），同一台機器、同一個
   `p4_proxy/venv`：
   ```
   NDT_OWNER=<你> ONLY=p4runtime,flowcache bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh   # C1
   NDT_OWNER=<你> ONLY=p4runtime,flowcache bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh   # C2
   ```
   trunk 的 06 **不寫** `00_venv.txt`（那是 B 加的），所以每一次跑完**手動補記**，用 B 分支裡的那支腳本（它是獨立的，
   不讀 repo 其他東西）：
   ```
   bash <B 的 worktree>/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/venv_fingerprint.sh \
       <C 的 run 目錄>/00_venv.txt /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/p4dev-python-venv/bin/python
   git -C /home/adam/Desktop/NDTwin-Kernel rev-parse HEAD > <C 的 run 目錄>/00_code.txt
   git -C /home/adam/Desktop/NDTwin-Kernel status --short | wc -l >> <C 的 run 目錄>/00_code.txt
   ```
2. **merge B 進主 checkout 的 trunk，只在本地、不 push**（orchestrator 做）。
3. **處理組 T（含 B）**：一次 `PART=h5`，`OLD_06` 指向 C1——H5 的 rc／verdict 檢查就是和同一個 session 的對照組比：
   ```
   NDT_OWNER=<你> OLD_06=<C1 的 run 目錄> PART=h5 bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh
   ```
   它跑完整的 06（26 臂）一次、旁邊的 sampler 每秒讀一次 daemon 的報告（含 `written_wall`、`stop_reason`、四個
   計數器），接著跑 01。T＝它印的 `06 rc …, raw …` 那個 06 run；samples＝`<08 的 run 目錄>/50_samples.tsv`
   （旁邊的 `50_t06_end.txt` 是 06 結束的時間）。這一輪 B 的 06 會自己寫 `00_venv.txt`。
   **只有這一種處理組**：沒有 samples 的「B 上的 06 一次」**不算**——報告裡的標記全都在控制器啟動、pipeline
   載入之前取得，說不出心跳在程式跑的時候有沒有在跑。
4. **比對**：
   ```
   python3 doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_evidence.py compare \
       <C1> <T> --control2 <C2> --samples <08 的 run 目錄>/50_samples.tsv
   ```

**判定（預先登記）**：
- **rc 0**：沒有任何差異落在對照組的範圍外，每臂的不變式都成立，daemon 在每臂的 session 裡什麼都沒轉 ⇒ **通過**，
  可以 push（照 orchestrator 的順序）。**只有 rc 0 是通過。**
- **rc 1**（差異）：
  - 下列任何一個 ⇒ **失敗，停下來回報**（Adam 09-25 的條件），不補跑、不事後解釋：`!! DAEMON`（daemon 在該臂的
    session 算到轉出的幀；轉給 host 就是 ruling 4）、任何 0x88B5 的 packet-in、`INV BAD`（每個對照組都守住的不變式）、
    **C1 與 C2 相等**的欄位上的 DIFF（沒有噪音可解釋）。
  - 只有在 **C1 與 C2 本來就不同**的欄位上有 DIFF（噪音，例如 flowcache 的 packet-in 數）⇒ 再跑兩次對照組 C3、C4
    （同第 1 步），`--control2 C2 --control2 C3 --control2 C4` 重跑比對，**以四個對照組的結果定案**：rc 0 通過、rc 1
    失敗。只加這一次，不再加。
- **rc 2**（讀不到）：這次比對不算。原因寫在那一行（缺檔、counter 區塊被截斷或**還沒穩定**——最後一次讀數既不重複
  前一次、也還沒算到這一輪送出的全部封包——解析不了的 packet-in）。重跑出問題的那一個 run 一次；同樣的原因再出現一次
  就回報，不算通過。
- **rc 3**（拒絕）：程序沒照做（沒給 samples 或 C2、對照組裡有心跳的痕跡、處理組某一臂的 session 沒有從頭到尾都
  在跑——沒被取樣到、報告變 STALE、中間有空檔、停了又起、在控制器最後一次寫 log 之前就停、同一個窗口裡還有別的
  session）。修正後重跑；**心跳在某一臂中途停掉的處理組不算通過**。
- **H5 本身的判定**：`H5 where the heartbeat ran`（每臂剛好有一個 session）或 ruling 4 STOP 失敗 ⇒ T 無效（STOP 就停下
  回報）。`H5 06 against <C1>` 的 rc／verdict 差異同時會是 compare 的 `DIFF rc/verdict`，以 compare 為準。H5 的 01 與
  external 臂無關，另外回報。
- **H4 的風險（S4，預先登記）**：之後跑一次 H1–H4（`NDT_OWNER=<你> bash .../08_heartbeat.sh`）。H4 現在要求 kernel
  對兩個方向的連線回報都回 200（`reported_to_kernel: true`），而 H4 沒有跑 exercise 的控制器，kernel 把這些交換機
  判 Down——**沒有證據說 kernel 會接受 Down 交換機的連線回報**。如果 H4 **只**因為 `reported_to_kernel` 失敗：那是
  kernel 處理 Down 交換機的發現，**不改變**上面 external 臂比對的結論，但「剪線會告訴 twin」在沒有控制器的
  external fabric 上仍未證明，要回報。
- **這個 raw 答不了的**：「臂結束時 proxy 什麼都沒寫」——06 只在 bring-up 時記一次 switch_state。proxy 在 external
  fabric 上的寫入紀錄由 H4 的 `no_writes`（剪線與復原前後 `pipeline_commits`／`rules_timed`／`table_generation`
  不變）回答。

`external_evidence.py` 的細節（它的 docstring 是正本）：它從每臂自己的控制器 log、round 報告、`00_table.tsv`、
H5 的 samples 讀證據；拒絕／讀不到／比對／不變式的規則如上；N4 那份 switch_state 的 daemon 計數器是 pipeline
載入之前的快照，**只列、不判**。

**venv 指紋**：從 09-27 起每個 live-p1 raw（`start_step` 的每一步、06）都有 `00_venv.txt`——proxy 的 venv 與
控制器／driver 的直譯器各一段：路徑、Python 版本、protobuf 版本與 `api_implementation`、grpcio、所有已安裝套件
（`name==version`，排序）及其 sha256。取不到就揭露（`NOTE … venv fingerprint was not fully recorded`），不判 FAIL。
074635Z 沒有這個檔（它早於這個改動）。

[Co-developed with claude code -- Adam]
