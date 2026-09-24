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

在**這個分支的 worktree 根目錄**跑（`scratch/overnight-2026-09-05/wt-app-ndt-0917`）；
併回 trunk 之後同樣的相對路徑在主 checkout 也成立。腳本自己從所在位置推 repo 根，所以
`cd` 到哪裡都行，上面寫相對路徑只是因為那樣好貼。

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

[Co-developed with claude code -- Adam]
