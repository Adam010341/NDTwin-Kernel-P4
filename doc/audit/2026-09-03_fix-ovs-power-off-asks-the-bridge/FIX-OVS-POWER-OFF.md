# FIX-OVS-POWER-OFF — finding #82（#35 的 OVS 同型）

分支 `fix/ovs-power-off-asks-the-bridge`，基底 `trunk` @ `92a79392`，修法 commit `6945e6f9`。
[Co-developed with claude code -- Adam]

🔴 **原始輸出全部在 `audit-raw` 分支的 `559692e0`**（CLAUDE.md：raw 進 audit-raw），路徑
`doc/audit/2026-09-03_fix-ovs-power-off-asks-the-bridge/raw/`。**這個 doc 目錄只留這份 write-up。**
十個檔，每一個都用 sha256 對過 blob 與磁碟上的檔案（不是只看 exit code）。讀某一份：

```
git show audit-raw:doc/audit/2026-09-03_fix-ovs-power-off-asks-the-bridge/raw/<檔名>
```

| 檔 | 內容 |
|---|---|
| `01_red_gtest_seam_present_logic_unchanged.log` | 紅：對 trunk 的判斷邏輯，6 個案例 FAILED |
| `02_green_gtest_ctest.log` | 綠：同 filter 45/45、全套 974/974、ctest 974/974 |
| `03_gates_82_and_46.log` | 兩支變異閘的完整輸出 |
| `04_br_exists_exit_codes_and_sudoers.log` | `br-exists` 的實測 exit code ＋ `sudo -n -l` |
| `05_python_suites.log` | `tests/python` 29 ＋ `p4_proxy/tests` 25，逐模組 |
| `06_gate_anchors_and_merge_tree.log` | anchor 檢查、merge-tree、分支重疊掃描 |
| `07_live_before_arm.log` / `08_live_after_arm.log` | ovs4 兩臂 |
| `09_build_two_arms.log` | 兩支 binary 的建置與 sha256 對帳 |
| `10_live_round_orchestration.log` | claim → up → 兩臂 → down → release 的全程 |

## ① 一句話

**OVS 的關機現在問機器，不問圖**——新的量測 seam `executeBridgeExists`（`ovs-vsctl br-exists`）
決定要不要拆 bridge；而**兩條路都會寫下「被命令關機」**，因為重複下的關機仍然是一道命令。

## ② 缺陷

`OVSPowerStrategy::powerOff` 開頭是

```cpp
if (!topoMonitor->getVertexIsUp(node)) { return OpResult::success(); }
```

——#35 在 P4 那邊指名的同一個早退。P4 那支在 `fix/poll-does-not-resurrect` 已刪掉，
OVS 這支**刻意留著**（`FIX-POLL-RESURRECT.md` ⑥.3）：P4 有 helper，`off` 讀 `/proc`、
對「本來就停了」回 `already-stopped` 且 exit 0，**冪等性來自量測**；OVS 沒有 helper，而
`executeListPorts` 對不存在的 bridge 會失敗 ⇒ 直接拿掉守衛會讓關機回 500。**缺的是那個量測。**

它問的是圖，而**圖對一座還在轉送的 bridge 至少有四種情況會回 false**：

1. 拓樸剛載入——`loadStaticTopologyFromFile` 把每個 vertex 起始成 `isUp = false`；
2. `ovs-vsctl list-br` 失敗或被 sudo 拒絕（`ovsLivenessFor` 的 Unknown／Down 分支，
   那段註解本身就是為了「一次抖動讓整張圖變紅」而寫的）；
3. 一次普通的 liveness 抖動；
4. 🔴 **finding #46 之後：任何已經被命令關機的交換機。**

第 4 條是它從「不整齊」變成真缺陷的原因：**早退在 `setVertexPoweredOffByCommand` 上面**，
而第一次關機之後圖**必然**說 down ⇒ **第二次 `action=off` 回 200、一個字都沒記。**
⇒ **在 OVS 上，#46 的否決只保護「關機當下 `isUp` 剛好是 true」的那一次。**

一個諷刺的對照：**liveness worker 早就在問機器了**（`ovsLivenessFor` 讀 `ovs-vsctl list-br`），
只有電源 API 還在問自己的快取。

## ③ 修法前後對照

| # | 情境 | 修法前 | 修法後 |
|---|---|---|---|
| 1 | 圖說 down、bridge 還在 | 200 Success，**bridge 沒刪**、命令沒記 | `br-exists` 說在 ⇒ 照舊拆掉，並記命令 |
| 2 | 圖說 down、bridge 真的不在（例：連下兩次 off） | 200 Success，**命令沒記** | 200 Success，**不拆任何東西，但命令有記** |
| 3 | `br-exists` 問不到（sudo 拒絕／沒有 ovs-vsctl） | — | **照舊嘗試拆**（含它原本的 500）。「問不到」不得讀成「不存在」 |
| 4 | bridge 在、`list-ports` 讀不到 | 500、vertex 留 up、不記命令 | **不變** |
| 5 | `action=on` 打在「圖說 down、bridge 還在」 | `add-br` exit 1 ⇒ **整個開機 500** | 不下 `add-br`；撤銷未撤的關機命令、結清欠的 sFlow restore、回 200 |
| 6 | `action=on` 打在 bridge 真的不在 | 完整 bring-up | **不變** |
| 7 | 對外 JSON 欄位形狀 | — | **完全不變**（Q12 仍未裁） |

實作面：

- **`executeBridgeExists`（新 seam，virtual）**：`sudo ovs-vsctl br-exists <br>`，**走 argv 不走 shell**
  （B-2b）⇒ `tests/python/test_shell_command_construction.py` 的 shell site 母體**沒有變動**（已跑，7/7 綠）。
  三種結果分開：exit 0＝在、**exit 2＝不在**、其餘＝不知道。
  exit 2 不是我推測的，**手冊與實測都對過**（`raw/04_...`）：本機 `man ovs-vsctl` 的 EXIT STATUS 寫
  「2 The bridge argument to br-exists specified the name of a bridge that does not exist.」，
  而 `sudo -n ovs-vsctl br-exists nosuchbridge_test82` 在 ovs-vsctl 3.3.9 上實跑 **exit 2**。
- **`interpretBrExistsStatus(ran, waitStatus)`（static）**：把「判斷」從「執行」裡拆出來。
  理由不是美學——**所有 double 都會蓋掉 seam，seam 自己的 body 會一個測試都沒有**，
  那正是 `TheRealShellSeamRunsTheCommandAndReportsItsExitStatus` 當初為 `executeSystemCommand`
  補的洞；這次是在它被挖出來之前先補上。它吃的是 wait status 不是 exit code
  （exit 2 的 int 值是 512——這個檔案曾經把 exit 1 印成 "status 256"）。
- **`tearDownBridge()`**：把原本 powerOff 的 body **原封不動**搬出來，讓「不存在」那條路可以跳過它，
  而**記命令的那一行只有一個呼叫點**、在兩條路的下面 ⇒「兩條路都記」是結構保證，
  不是兩個呼叫點剛好一致。

## ④ 紅 → 綠

🔴 **紅是在 trunk 的判斷邏輯上取的**：先只加 seam（`executeBridgeExists` 存在但**沒有任何呼叫端**，
所以行為與 trunk 完全相同），讓測試編得起來、然後對著 trunk 的 `powerOff`／`powerOn` 跑。

`raw/01_red_gtest_seam_present_logic_unchanged.log`：**45 tests，39 passed，6 FAILED**

| 紅掉的案例 | 第一個斷言失敗的原因 |
|---|---|
| `PowerOffTearsDownABridgeThatExistsThoughTheGraphSaysDown` | `ovs.bridgeExistsCalls` **0**（沒問機器）；`ran("del-br s1")` false |
| `PowerOffOnAnAbsentBridgeSucceedsWithoutDeletingAnythingAndStillRecordsTheCommand` | `bridgeExistsCalls` 0；`getVertexAdminPoweredOff` false |
| `ASecondPowerOffOnAStillRunningSwitchIsNotSwallowedByTheFirst` | 第二次 `ran("del-br s1")` false |
| `PowerOnDoesNotBlindAddBrWhenTheBridgeIsAlreadyThere` | 對已存在的 bridge 跑了 `add-br` |
| `PowerOnOnAnExistingBridgeWithdrawsAStandingPowerOffCommand` | 同上 |
| `PollDoesNotResurrectTest.ARedundantOvsPowerOffIsStillRecordedAsACommand` | `getVertexAdminPoweredOff` **false**——「重複的關機回 200 而什麼都沒記」 |

修法後同一個 filter **45/45 綠**（`raw/02_green_gtest_ctest.log`）。

**被刪掉的測試一個**：`PowerOffOnAnAlreadyDownSwitchDoesNothing`——它**斷言的就是缺陷本身**
（「圖說 down 就什麼都不做」）。它裡面唯一仍然成立的顧慮（不得重跑 `list-ports`，否則會把
真正成功那次存下的 port 清單蓋掉）已原封搬進新的 absent-path 案例。
另有 **13 個既有 power-on 案例**加了一行 `bridgeExistsResult = false`，明說它們模擬的是
「交換機是關的，所以 bridge 不在」——不是為了讓測試通過，而是那句話本來就該寫出來。

## ⑤ 閘門

**以下全部是我自己在這台機器上跑的。** 原始輸出：`raw/03_gates_82_and_46.log`。

### 5.1 `tests/shell/mutate_ovs_power_off_asks_the_bridge.sh`（新）

```
  ok       baseline green (35 cases in the #82 filter)
  ok       test_routing_strategy sha256 388ec050979f6492
=== M1.  early return restored: powerOff believes the graph's cached isUp ===   ✅ caught
=== M2.  br-exists result ignored: the teardown runs whatever the machine answered === ✅ caught
=== M3.  command not recorded on the absent path ===                            ✅ caught
=== M4.  unknown conflated with absent at the decision site ===                 ✅ caught
=== M5.  the seam reads every failure as 'no such bridge' ===                   ✅ caught
=== M6.  power-on blind-adds the bridge again ===                               ✅ caught
=== M7.  the teardown's failure is dropped by its new caller ===                ✅ caught
=== M8.  power-off never tears anything down ===                                ✅ caught
=== M9.  power-on never builds the bridge ===                                   ✅ caught
=== M10. the existing-bridge power-on never withdraws the command ===           ✅ caught
=== W1. a comment, nothing else ===                                      ✅ survived
=== W2. the already-stopped log line is reworded ===                     ✅ survived
=== W3. the absent/present branch is inverted ===                        ✅ survived
=== restore ===
  all 2 files byte-identical to the pre-run snapshot
  rebuilt from the restored tree / suite green again after restore
  test binary sha unchanged: 388ec050979f6492
=== verdict ===  10 mutations, 0 survived   /   3 widenings, 0 wrongly caught
```

**兩個方向都在。** M1–M7 是把缺陷放回去的七條路；**M8–M10 是放寬型**——
一個「永遠走 absent 路」的 powerOff 會讓 M1–M7 全部**更綠**（命令照記、vertex 照 down），
而它是一台**再也不會停任何交換機**的 twin。沒有 M8 的閘門會對「一律相信 br-exists 說不在」開綠燈。

**M5 是這支閘門存在的第二個理由**：它改的是 seam 自己的規則（任何非零都當成「沒有這個 bridge」），
而**每一個 double 都蓋掉了 seam** ⇒ 若沒有把判斷拆成 `interpretBrExistsStatus`，
這個變異會**存活**，而它正是「把 sudo 拒絕讀成 bridge 不存在」——比原缺陷更大聲的版本。

閘門另外**先拒絕再開跑**：`executeListPorts` 的 override 數必須等於 `executeBridgeExists` 的
override 數（3 個 double／2＝2、1／1＝1，皆 ok）。這不是風格檢查——
`tests/test_OvsPowerStrategy.cpp` 的檔頭記著 `sudo ovs-vsctl add-br` 曾經**真的**在這個 suite 裡
對開發者的機器跑過，**第五個 seam 就是第五次機會**。

### 5.2 `tests/shell/mutate_poll_does_not_resurrect.sh` 重跑（#46）

```
  ok     ovs-off-writes   src/ndt_core/power_management/OVSPowerStrategy.cpp   x1
  ok       baseline green (12 cases in PollDoesNotResurrectTest.*)
  test binary sha unchanged: 388ec050979f6492
=== verdict ===  10 mutations, 0 survived   /   3 widenings, 0 wrongly caught
```

**維持 10/0＋3/0。** 值得指名的一點：它的 `ovs-off-writes` 錨點是
`    topoMonitor->setVertexPoweredOffByCommand(node);`，**要求剛好出現一次**——
所以「absent 路也要記命令」如果用第二個呼叫點去實作，**會讓 #46 的閘門直接 REFUSE（exit 2）**。
單一呼叫點是被這個約束逼出來的，結果它也是比較好的設計。基底案例數 11 → 12（我加的那一個）。

### 5.3 閘門本身有沒有被檢查（finding #28）

```
$ python3 tests/shell/check_gate_anchors.py HEAD --gates mutate_ovs_power_off_asks_the_bridge.sh mutate_poll_does_not_resurrect.sh
mutate_ovs_power_off_asks_the_bridge.sh  ok(11)
mutate_poll_does_not_resurrect.sh        ok(13)
2/2 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)
```

finding #28 說「剛出廠的儀器預設是未被檢查的」。這支從出廠就讀得到。（`raw/06_...`）

## ⑥ 套件

| 套件 | 結果 |
|---|---|
| gtest 全套（無 filter） | **974 tests from 124 test suites，974 PASSED** |
| `ctest`（逐案例，974 個） | **100% tests passed, 0 failed out of 974**（125.28 s） |
| `tests/python`（逐模組） | **29 ok / 0 red（共 29）** |
| `p4_proxy/tests`（逐模組） | **25 ok / 0 red（共 25）** |

`raw/02_green_gtest_ctest.log`、`raw/05_python_suites.log`。
直譯器：`tests/python` 用 `test_env/bin/python`，`test_sflow_stats_endpoint.py` 與
`p4_proxy/tests` 全部用 `p4_proxy/venv/bin/python`。
🔴 **兩個 venv 都在主 checkout 底下**（worktree 沒有自己的），這是借用，已對帳於此。

## ⑦ live（ovs4，兩臂）

**兩臂同一支 harness、同一份配方、同一座 fabric 形狀**，`ndt up ovs4`（10 座 bridge，
sFlow 10/10 sampling）。原始輸出 `raw/07_live_before_arm.log`、`raw/08_live_after_arm.log`。

**binary（sha256，兩支只差 `OVSPowerStrategy.{hpp,cpp}` 這兩個檔）**

| 臂 | sha256 | `strings` 含 "has no bridge on this machine" | 含 "br-exists" |
|---|---|---|---|
| before（trunk 的 OVS 電源碼） | `53fdd8dbf3dad7478a046fa7d52f26fd05c484b44c25f7fcb236df7895fb445f` | **0** | **0** |
| after（本分支） | `18373873fdb56faad74c6bbd3d9579c8fdf3eadd920d4d4bb2b1efb62be216dd` | **1** | **1** |

after 那支的 sha 與 `build/bin/ndtwin_kernel` 重建後**逐位元相同**（`raw/09_build_two_arms.log`），
所以這兩個數字對應的就是 commit `6945e6f9` 的原始碼。

### 7.1 結果一：連下兩次 `action=off`（③表第 2 列）——**有鑑別力**

| | before | after |
|---|---|---|
| 第 1 次 off | 200 Success，**131.1 ms** | 200 Success，**142.0 ms** |
| 第 2 次 off（bridge 已經不在） | 200 Success，**0.9 ms** | 200 Success，**12.1 ms** |
| 第 2 次的 `del-br` 次數 | **0** | **0** |
| 第 2 次的 log | 只有 `MININET: switch s1 -> off`，**沒有任何量測** | `br-exists s1 exited 2` ＋ `s1 has no bridge on this machine ... still recorded as commanded` |
| `br-exists s1`（我在外面查） | exit 2 | exit 2 |

**0.9 ms vs 12.1 ms，約 13 倍，兩組不重疊。** 0.9 ms 就是
`if (!getVertexIsUp(node)) return success;`——回 200、一個指令都沒下、什麼都沒記；
12.1 ms 是真的 fork 了一次 `sudo ovs-vsctl br-exists`。
**兩邊都是 200，但 after 的那個 200 來自 ovs-vsctl，before 的來自我們自己的快取。**
（形狀與 #35 在 P4 上量到的 2.1 ms → 36.3 ms 完全同型。）

### 7.2 結果二：帶外 `del-br` 之後再打 `action=off`——**有鑑別力，而且比預期大**

配方：`sudo ovs-vsctl del-br sX` 之後**立刻**打 API（搶在 1 Hz liveness worker 之前，
所以圖仍然說 up 而 bridge 已經不在）。s4／s5／s6 各一次。

| | before | after |
|---|---|---|
| HTTP | **500 ×3**　`{"error":"Failed to change switch power state"}` | **200 ×3**　`{"192.168.123.1x":"Success"}` |
| 耗時 | 14.7 / 13.4 / 12.6 ms | 13.9 / 13.9 / 16.2 ms |
| 請求後 `is_up` | **True ×3**（分身說一座已被刪掉的交換機還活著） | **False ×3** |
| kernel log | `list-ports s4 failed ... treating the port list as unknown`<br>`could not read the ports of s4, so it was left running` | `br-exists s4 exited 2 ... documented answer, not a failed query`<br>`s4 has no bridge ... still recorded as commanded` |
| 命令有沒有記 | 沒有（整個操作被拒） | 有 |

🔴 **這正是 FIX-POLL-RESURRECT ⑥.3 當初擔心的那件事，實測到了**：拿掉早退而**沒有**先補量測，
`executeListPorts` 就會對不存在的 bridge 失敗並回 500。before 臂三次全中。
**after 臂用 `br-exists` 把那條路整個繞開**，回 200 並記下命令。

附帶觀察（不是我的修法範圍，但值得記）：before 臂的錯誤訊息把 `list-ports` 的 exit 1 解讀成
**「ovs-vsctl refused; a sudo password prompt does this…」**，而真正的原因是同一行上面的
`ovs-vsctl: no bridge named s4`。`describeCommandStatus` 對 exit 1 給了一個合理但錯的歸因。

### 7.3 結果三：輪詢之後有沒有復活——🔴 **零鑑別力，不能當成修法的功勞**

兩臂各在關機後以 5 s 間隔取樣 40 s（跨過 ~30 s 的 topology poll）：

| | before | after |
|---|---|---|
| s1／s4／s5／s6 的 `is_up`，t+5…t+40 s | **全 False，8/8 取樣點** | **全 False，8/8 取樣點** |
| kernel log 的「拒絕復活」WARN | **0** | **0** |

**對照組也是 0。** 把這寫成「修法讓它不再復活」就是拿一個零鑑別力的檢查當證據
（#46 那一輪已經踩過同一個坑並寫下來了）。**原因是知道的、也是結構性的**：
OVS 的 liveness worker 每秒讀 `ovs-vsctl list-br`，bridge 是真的沒了 ⇒ 它每秒寫一次 false；
而 Ryu 也很快就把被刪掉的 bridge 從 `/v1.0/topology/switches` 移除 ⇒
**那個 poll 手上根本沒有可以拿來復活它的清單成員**，#46 的否決在這個配方裡從來沒被觸發。
⇒ **「輪詢不復活」在 OVS 平面上仍然只有 gtest 與變異閘覆蓋，沒有 live 佐證。**
要 live 佐證需要一個「bridge 被刪掉、但 Ryu 還在列它」的窗口，本輪沒有做出來。

順帶一提，7.2 的 before 臂那個 `is_up=True` 是**短暫的**：下一次 liveness tick（<1 s）就把它改回
False，所以 t+5 s 已經是 False。**持久的傷害不是那個 True，是那個 500** ——
操作員下的關機被整個拒絕，而且沒有留下任何「這台被命令關機」的記錄。

### 7.4 修法沒有把 fabric 弄壞

- 兩臂各 `ndt down` **五條斷言全綠**（bmv2 0／host+switch 行程 0／無 topo session／無 manifest／
  `8000 8080 8081 6653 6633 6343 30051-30060 9091-9100 9000` 全關），`down rc=0`。
- 沒被碰到的另外六座 bridge（s2 s3 s7 s8 s9 s10）兩臂都完整留著。
- `ndt release` 已做，**兩份 claim 檔都已刪除**（本 worktree 的與主 checkout 的複本，finding #79）。

### 7.5 但書

- **⑨.1 的 stderr 雜訊在 live log 裡看得到**，形狀與預期一模一樣：
  `Command failed (exit code 2): sudo ovs-vsctl br-exists s1` 緊接著才是我那行正確的 INFO。
  它不影響判斷，但它會出現在明天整機測試的 kernel log 裡，**先講清楚免得被當成新缺陷**。
- 本輪 `exclusive_cpu=no`，其他 session 可能同時在編譯；7.1／7.2 的毫秒數在這個條件下量的。
  兩組差距（0.9 vs 12.1 ms；500 vs 200）遠大於任何合理的排程雜訊。
- 兩臂的 fabric 是**分開 `ndt up` 兩次**建的，不是同一座。橋名與拓樸相同。
- s4／s5／s6 在 before 臂被帶外刪掉之後**沒有被復原**就 `ndt down` 了——這是刻意的，
  `ndt down` 本來就會把整座 fabric 拆掉，而 after 臂是重新 `ndt up` 的乾淨 fabric。

## ⑧ 合併

```
$ git merge-tree --write-tree --messages trunk fix/ovs-power-off-asks-the-bridge
db21865d63bddfc0c9dc3ff0e2f2154812298a81
rc=0
```

**對 `trunk` 零衝突**，一則訊息都沒有。與 `fix/poll-does-not-resurrect` 不同的是這支**沒有動
`tests/CMakeLists.txt`**——新增的是 shell 閘門（不進 CMake），既有的兩個測試檔早就在清單裡。

🔴 **但是對另一支分支有衝突，合併順序要注意。** 我掃過所有 `fix/*`／`integrate/*`／`verify/*`
分支，找動到這四個檔的：

| 分支 | 動到幾個 | 合併結果 |
|---|---|---|
| `fix/is-up-split-admin-state-reachable` | 1（`tests/test_PollDoesNotResurrect.cpp`） | **CONFLICT (content)** |
| 其他所有分支 | 0 | — |

```
$ git merge-tree --write-tree --messages fix/is-up-split-admin-state-reachable fix/ovs-power-off-asks-the-bridge
CONFLICT (content): Merge conflict in tests/test_PollDoesNotResurrect.cpp
```

兩邊都是**在同一個檔案裡加新案例**（它動 `isUp` 的語義拆分，我加
`ARedundantOvsPowerOffIsStillRecordedAsACommand`）。**兩塊都要留**；但因為那支動的是 `isUp`
本身的語義，**先併它、再併我，然後把我的那個案例重跑一次**比較安全——我的案例斷言的正是
`isUp` 與 `adminPoweredOff` 的關係。`OVSPowerStrategy.{hpp,cpp}` 兩個檔**沒有任何別的分支在動**。

## ⑨ 沒有做的事

1. 🔴 **`utils::execArgv` 會對任何非零 status 往 stderr 印一行 `Command failed (exited 2): sudo
   ovs-vsctl br-exists sX`。** 對 `br-exists` 而言 exit 2 是**答案不是失敗**，所以每一次
   「bridge 已經不在」的正常關機都會先印一行誤導的話，才印我那行正確的。
   **刻意沒動 `Utils.hpp`**——今晚有三個分支共用它，為了一行訊息去改共用檔會製造衝突。
   碼裡與這裡都記了。要修的話見 ⑩ Q3。
2. **帶外被刪掉的 bridge，它的 sFlow 記錄跟著沒了，而 absent 路不會把 `restorePending` 立起來**
   ⇒ 之後的 power-on 會建一座**沒有 sFlow 而且不說話**的 bridge（A-4f 的一種形狀）。
   🔴 **這不是我造成的新洞**：修法前那條路是早退，結果一模一樣。
   刻意沒補，因為把它一律設成 pending 會讓「本來就沒有 sFlow 的 bridge」在開機時吐 502 假警報，
   那是拿一個安靜的錯換一個大聲的錯。
3. **powerOn 的「bridge 已存在」那條路只結清命令與 sFlow，不驗證 port 與 controller。**
   理由是系統其他地方對同一份量測已經下了同樣的結論：`ovsLivenessFor` 讀 `list-br`，
   會在一秒內把這種交換機標成 up，之後 `alreadyUp` 早退做的事完全一樣。
   要真的處理「bridge 在但 port 不全」得把 `add-br`／`add-port` 換成 `--may-exist` 讓 bring-up
   冪等——那會動到既有的成功路徑，是另一張單（⑩ Q2）。
4. **`HttpSession::handleInformSwitchEntered`（`:1449`）仍然無條件 `setVertexUp`**——
   #46 ⑥.4 列的那一條，沒動。它同樣能覆蓋一個被命令關掉的交換機。
5. **P4 那一側一行沒動**，`DeviceConfigurationAndPowerManager` 的 TESTBED 排插路徑也沒動。
6. **Q12 沒有被回答**：`isUp` 對外仍然一個欄位承載兩種語義；`to_json` 一個 key 都沒變，
   `TheEmittedVertexShapeGainsNoNewKey` 仍然綠。
7. **沒有 push。** 只在本地 commit。
8. 🔴 **「輪詢不復活」在 OVS 平面上仍然沒有 live 佐證**（見 7.3）。本輪的配方對它零鑑別力，
   而且是結構性的：bridge 真的沒了 ⇒ liveness 每秒寫 false、Ryu 也不再列它 ⇒ 沒有東西可以復活。
   要驗它需要「bridge 已刪、Ryu 還在列」的窗口，本輪沒做出來。**#82 的 live 只證了電源 API
   這一半**（7.1／7.2），#46 在 OVS 上仍然只有 gtest ＋ M9 ＋ 我新加的那個案例。
9. ~~`interpretBrExistsStatus` 沒有對真的 `ovs-vsctl` 驗過~~ ——**已補**：
   `sudo -n ovs-vsctl br-exists nosuchbridge_test82` 在本機（ovs-vsctl 3.3.9）實測 **exit 2**，
   `list-br` exit 0，見 `raw/04_...`。gtest 那邊是用 wait status 驅動的（不跑任何行程），
   兩者對得起來。

## ⑩ 要問 Adam 的

**Q1。`sudo ovs-vsctl br-exists` 是新的 argv 形狀，手冊的 sudoers 規則要不要補？**
🔴 **我先去量了，答案是「這台機器不用補」**（`raw/04_...`）：

```
$ sudo -n -l
(root) NOPASSWD: /usr/bin/ovs-vsctl, /usr/sbin/ifconfig, /usr/bin/mnexec
```

`ovs-vsctl` 是**整個執行檔**被放行的，不是逐 argv ⇒ `br-exists` 自動涵蓋。
實測 `sudo -n ovs-vsctl br-exists nosuchbridge_test82` → **exit 2**，
`sudo -n ovs-vsctl list-br` → exit 0，兩者都沒有要密碼。
（順帶：這也是 `interpretBrExistsStatus` 的規則**對真的 ovs-vsctl 3.3.9 量過**，不只是照手冊寫的。）

**仍然要問你的是：手冊教使用者寫的那條規則是哪一種形狀？** 如果手冊教的是**逐 argv**
（`NOPASSWD: /usr/bin/ovs-vsctl list-ports *` 這種），那使用者的機器就會拒 `br-exists`，
行為退回③表第 3 列（照舊嘗試拆、不會壞），**但 #82 在他們的機器上等於沒修**。
我刻意讓它退化而不是拒絕，就是為了不用一個電源管理故障去換一個量測缺陷——但這條要對手冊查一次。
finding #7 已經記著 `ndt` 有兩個 `sudo -n` 不在手冊的規則裡，同一族。

**Q2。powerOn 要不要一路做到底，把 `add-br`／`add-port` 換成 `--may-exist`？**
好處：bring-up 真正冪等，順手蓋掉「bridge 在但 port 不全」。
代價：動到既有的成功路徑，而那條路徑是明天整機測試會走的。我這次沒做。

**Q3。`utils::execArgv` 要不要能表達「這個非零 status 是預期的答案」？**（見⑨.1）
最小改法是多一個「預期狀態集合」參數，只影響那行 stderr。它是共用檔，要你點頭我才動。

**Q4。`ovs4` 的十座 bridge 名稱在 `ndt down` 之後會被重用。**
`powerOff` 現在會對「不存在的 bridge」回成功並記下命令——如果同名 bridge 稍後由別人重建，
那道命令仍然掛在同一個 vertex 上（要 power-on 才會撤）。這是 #46 的既有語義，我沒有改，
但在 OVS 上因為名字可重用而比 P4 更容易遇到。要不要讓 `ndt up` 開場清掉所有 `adminPoweredOff`？
