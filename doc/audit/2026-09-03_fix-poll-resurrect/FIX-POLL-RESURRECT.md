# FIX-POLL-RESURRECT — finding #46（含 #35、#36 同根）

分支 `fix/poll-does-not-resurrect`，基底 `integrate/2026-09-03-auditor-merge` @ `5c64d432`。
[Co-developed with claude code -- Adam]

## ① 一句話

**「被命令關機」現在有自己的內部記錄，輪詢不得覆蓋它**——`updateSwitches` 只在交換機沒有
未撤銷的關機命令時才寫 `isUp = true`；而電源 API 的兩個 early return 不再問圖，改問會去看
`/proc` 的 helper。

## ② 行為變更前後對照

| # | 情境 | 修法前 | 修法後 |
|---|---|---|---|
| 1 | 關機指令落在下一次 poll 前 ~1.5 s | 下一次 poll 把 `is_up` 寫回 true（t_off+2.31 s），**且每 30 s 重複一次，永遠** | poll 拒絕改寫；`is_up` 維持 false |
| 2 | 🔴 **對外**：`/ndt/get_graph_data` 的 `is_up` | 被命令關掉的交換機**回報 up**（相位不對時） | 回報 **false**。欄位形狀不變，值變準 |
| 3 | 🔴 **對外**：被命令關機的交換機周邊的 link／單歸屬 host | 因為 #1 把交換機寫回 up，`reconcileDerivedLiveness` 的 `isUsable` 恆真 ⇒ **不會**被隔離 | 連續 `kMissesBeforeIsolating` 次之後，其 link／單歸屬 host 轉 down 並帶 `down_reason=switch-unreachable`。這條路徑本來就存在（phase B「沒被覆蓋」時就會走），修法只是讓它**一致地**發生 |
| 4 | 🔴 **對外**：`POST /ndt/set_switches_power_state?action=off` 打在圖上已經 down、但行程還活著的交換機 | 200 Success，**一個指令都沒下** | 一律執行 helper。helper 對「本來就停了」回 `already-stopped` 且 exit 0 ⇒ 仍然是 200 Success，但那個 Success 來自 `/proc` 不是來自快取 |
| 5 | 🔴 **對外**：`action=on` 打在「有未撤銷關機命令、但圖說 up」的交換機（超過 15 s 信任窗） | 200 Success in ~1 ms，什麼都沒做（#36：救不回來） | 真的執行 helper `on` ＋ readopt |
| 6 | `action=on` 打在沒有關機命令、圖說 up 的交換機 | 200 Success，不下指令 | **不變**（Energy-Saving-App 重送 desired state 不會變成 helper 失敗） |
| 7 | 帶外（不經 API）重啟一台被命令關掉的交換機後，再打 `action=on` | 200 Success，不下指令 | 會執行 helper → helper 拒絕啟第二個實例 → **500**。大聲的錯答案取代安靜的錯答案；列在 ⑥ |
| 8 | log | 覆蓋是**完全無聲的** | 每次「拒絕復活」episode 印一行 WARN（edge-triggered，一台一次，不是每輪一次） |
| 9 | 對外 JSON 欄位形狀 | — | **完全不變**。`adminPoweredOff` 不進 `to_json`／`from_json`；Q12 未裁 |

實作面（沒有對外行為的部分）：

- `VertexProperties::adminPoweredOff`（新欄位，內部）——與 `adminDisabled` 同形狀、同理由：
  一個「discovery 不准碰」的意圖旗標。
- `TopologyAndFlowMonitor` 新增三個入口：`setVertexPoweredOffByCommand`（命令）、
  `clearVertexAdminPowerOff`（命令被撤銷）、`getVertexAdminPoweredOff`。
  `setVertexUp`／`setVertexDown` **維持觀測語意**，兩個方向都不碰新旗標——1 Hz liveness worker
  在每次 kill 後一秒內就會用 proxy 的快取 `probe_ok` 呼叫 `setVertexUp`，若它能清掉命令，
  復活就只是換一扇門。
- 三條電源路徑都接上：`P4PowerStrategy`、`OVSPowerStrategy`、`DeviceConfigurationAndPowerManager`
  的 TESTBED 排插路徑。**`updateSwitches` 是 plane-agnostic 的**，只接 P4 等於只修有量到的那一面。
- 命令在 helper 確認有行程在服務的那一刻撤銷（P4 是 `clearPowerOffRecord` 同一行、readopt **之前**；
  OVS 是 bring-up 指令全部成功之後、`finishTelemetryRestore` 之前）。放在後面會讓 502 那條路徑
  把一台真的活著的交換機永久卡在「discovery 不准把它寫成 up」。

## ③ 閘門證據

**以下全部是我自己在這台機器上跑的**，不是轉述。

🔴 **原始輸出全部在 `audit-raw` 分支的 `19e3ab88`**（CLAUDE.md：raw 進 audit-raw），路徑
`doc/audit/2026-09-03_fix-poll-resurrect/raw/`。這個 doc 目錄只留這份 write-up 與可重跑的
harness `phase_a_trials.py`。讀某一份：

```
git show audit-raw:doc/audit/2026-09-03_fix-poll-resurrect/raw/<檔名>
```

十三個檔：`01_gate_mutate_poll_does_not_resurrect.log`（＝`gate_mutate_poll_does_not_resurrect.log`，
同一次跑的兩個檔名，blob 相同）、`02_phase_a_base.log{,.json}`、`03_phase_a_fixed.log{,.json}`、
`04_fixed_arm_kernel_declines.log`、兩臂各約 2 MB 的 `kernel_base_arm.log`／`kernel_fixed_arm.log`、
以及兩次作廢的 base 跑 `02_phase_a_base_firstrun_no_latency_probe.log{,.json}`
與 `02_phase_a_base_polltimes_invalid.log{,.json}`。

### 3.1 變異閘 `tests/shell/mutate_poll_does_not_resurrect.sh`

`/home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh ./tests/shell/mutate_poll_does_not_resurrect.sh`
全文：`git show audit-raw:doc/audit/2026-09-03_fix-poll-resurrect/raw/01_gate_mutate_poll_does_not_resurrect.log`

```
  ok       baseline green (11 cases in PollDoesNotResurrectTest.*)
  ok       test_routing_strategy sha256 4eb1f909a2aab704
=== M1.  the defect verbatim: the poll writes isUp = true unconditionally ===   ✅ caught
=== M2.  P4 power-off records an observation instead of a command ===          ✅ caught
=== M3.  a liveness observation withdraws the power-off command ===            ✅ caught
=== M4.  power-off marks down but records no command ===                       ✅ caught
=== M5.  the poll never marks any switch up ===                                ✅ caught
=== M6.  power-on never withdraws the command ===                              ✅ caught
=== M7.  power-off returns success on the graph's cached isUp ===              ✅ caught
=== M8.  power-on returns success on a cached isUp with a command standing ===  ✅ caught
=== M9.  OVS power-off records an observation instead of a command ===         ✅ caught
=== M10. the veto consults adminDisabled instead of the power command ===      ✅ caught
=== W1. a comment, nothing else ===                                    ✅ survived
=== W2. the declined-resurrection warning is reworded ===              ✅ survived
=== W3. the veto is written as the negated branch instead ===          ✅ survived
=== restore ===
  all 3 files byte-identical to the pre-run snapshot
  rebuilt from the restored tree / suite green again after restore
  test binary sha unchanged: 4eb1f909a2aab704
=== verdict ===
  10 mutations, 0 survived
  3 widenings, 0 wrongly caught
```

**兩面都在**：M1–M4、M9、M10 是「把缺陷放回去」的六條路；**M5、M6 是放寬型**——一個
「永不寫 up」的 poll，或一個永不撤銷命令的 power-on，會讓 M1–M4 全部更綠，而那是比原缺陷更大的
停機。沒有 M5／M6 的閘門會對 `// vprop.isUp = true;` 開綠燈。

紅是真的看過的：寫測試的過程中 `AnOvsPowerOffAlsoSurvivesThePoll` 先紅過一次
（`ovs.ran("del-br s1") = false`）——`loadStaticTopologyFromFile` 把每個 vertex 起始成
`isUp = false`，所以沒有 `converge()` 的 fixture 讓 OVS 自己的 already-down 早退吞掉整個操作，
測試是對一個從沒收斂過的 fabric 做「關機」。已修成 fixture 明確收斂。

### 3.2 全套 gtest

`build/bin/test_routing_strategy`（無 filter）：**935 tests from 122 test suites，935 PASSED**，
含新增的 11 個 `PollDoesNotResurrectTest.*`。

### 3.3 live：兩支 binary、同一支 harness、同一個配方

- fabric：`ndt up p4 4` → 10 座 bmv2、4 主機、proxy 12/12 destination paths、`h1 -> 10.0.0.2 forwards`。
- **binary（sha256，兩支只差這六個檔）**：
  - base（缺陷仍在）`395753ec31ca955dd58f36fc3274f8fd88f29ccf57af780f92ca701629e4971c`
  - fixed          `f823d8ca4b39dddeea1733fdaaef4d7a77101961b3f55f722f67df0831553071`
  - 交叉驗證：`strings | grep -c "the control plane still lists switch"` → base **0**、fixed **1**。
- 儀器先驗過再用（兩臂皆同）：poll 週期 **30.64／30.67 s**、
  `/switches → /links` 偏移 **0.501 s**（round3 06_ 量到 0.423 s，同一個形狀）。
- 配方：關機指令打在下一次 `/v1.0/topology/switches` 前 **1.5 s**，之後 **10 Hz 取樣 `is_up` 40 s**，
  每臂 **9 次**，交換機輪流 s6..s10。
- 🔴 **相位參考用 `/links` 不用 `/switches`**：harness 自己每秒 10 次 GET `/switches` 來記錄
  「control plane 還列不列這台」，用 `/switches` 當參考等於讓儀器量到自己。

#### 3.3.1 結果一：poll 的那扇門——**6/9 被擋下，每一次都在 poll 的瞬間**

fixed 臂的 kernel log（`git show audit-raw:doc/audit/2026-09-03_fix-poll-resurrect/raw/04_fixed_arm_kernel_declines.log`，
未裁切的原本在同目錄 `kernel_fixed_arm.log`）對照 trial 的 `t_off`：

| trial | t_off | 拒絕復活的 WARN | 差 |
|---|---|---|---|
| s6 | 19:19:33.027 | 19:19:35.586 | **+2.559 s** |
| s7 | 19:21:04.917 | 19:21:07.497 | **+2.580 s** |
| s9 | 19:24:08.729 | 19:24:11.320 | **+2.591 s** |
| s6 | 19:27:12.524 | 19:27:15.123 | **+2.599 s** |
| s7 | 19:28:44.437 | 19:28:47.030 | **+2.593 s** |
| s9 | 19:31:48.288 | 19:31:50.891 | **+2.603 s** |

harness 獨立記到的 poll 落點是 **t_off+2.6 s**（9/9 trial 皆同），與上表逐筆吻合。
另外 3 次（s8×2、s10×1）沒有 WARN——那是 proxy 在 poll 之前就把交換機從清單移除了，
沒有東西要拒絕。base 臂同一段 log 裡這行 **0 次**（那支 binary 沒有這行；它做的是寫入）。

⇒ **9 次裡有 6 次，那個 poll 手上握著一份仍然列著這台交換機的回覆。修法前那 6 次會寫
`isUp = true`；修法後它拒絕，並說出來。**

#### 3.3.2 結果二：`is_up` 的時序在兩臂**一樣**——而這推翻了 #46 的「永久」

| | base（9 次） | fixed（9 次） |
|---|---|---|
| LOST / KEPT / VOID | **0 / 9 / 0** | **0 / 9 / 0** |
| poll 落點 | t_off+2.6 s（9/9） | t_off+2.6 s（9/9） |
| `is_up` 0→1 | **0.32–1.4 s** | **0.4–1.51 s** |
| `is_up` 1→0 | 8.1–12.1 s | 8.8–13.2 s |
| 40 s 後 final | False（9/9） | False（9/9） |

🔴 **不要把這寫成「8/14 → 0/9」。** 我自己的**對照組也是 0/9**——沒有鑑別力，把它當成修法的功勞
就是拿一個零鑑別力的檢查當證據。真正的原因量得出來：**`is_up` 的 0→1 一律發生在 0.3–1.5 s，
早於 t_off+2.6 s 的 poll**，所以寫回 up 的**不是** poll，是 1 Hz liveness worker
（讀 proxy 還沒過期的 `probe_ok`，正是 `P4PowerStrategy.cpp` 註解描述的那一秒）；
而它在 8–13 s 後 LLDP 過期時又自己把它寫回 down。

**這是對 finding #46 的更新，不是推翻**：#46 的「復活是**永久**的」是在 **D15／#32 尚未修好**時量的
——那時啟動競態讓 bmv2 liveness 路徑從不執行（`GET /p4/switch_state` 0 次），所以除了電源 API
沒有任何 writer 會寫 false，poll 寫進去的 true 就沒人推翻。**D15 併入之後**（我的基底已含），
liveness worker 回來了，poll 的覆蓋在 `is_up` 這個欄位上被它自己的下一輪蓋掉 ⇒
在目前的整合頭上，**#46 的觀測後果從「永久」降為「被另一扇門遮住」**。
碼裡的缺陷沒有變小（3.3.1 逐筆證明那個寫入本來會發生），變的是它在 `is_up` 上還看不看得見。

#### 3.3.3 結果三：#35 的關機方向——**有鑑別力的 live 前後對照**

對一台已經確認死掉、圖上也已經是 down 的交換機再下一次 `action=off`（每 trial 各一次，共 9 次）：

| | base | fixed |
|---|---|---|
| 全部樣本（ms） | 1.9, 2.0, 2.0, 2.0, 2.1, 2.2, 2.2, 2.2, 2.6 | 34.2, 34.9, 35.7, 35.8, 36.3, 36.4, 40.4, 49.5, 88.0 |
| min / median / max | 1.9 / **2.1** / 2.6 | 34.2 / **36.3** / 88.0 |
| HTTP | 200 Success ×9 | 200 Success ×9 |

**兩組完全不重疊，約 17 倍。** base 的 2 ms 是 `if (!getVertexIsUp(node)) return success;`——
回 Success，一個指令都沒下；fixed 的 36 ms 是真的走了 `sudo -n ndtwin-p4-power off sX`，
helper 去讀 manifest pid、比對 `/proc`、回 `already-stopped` 並 exit 0。
**同樣是 200 Success，但這個 Success 現在來自 `/proc` 而不是來自我們自己的快取。**

#### 3.3.4 修法沒有把 fabric 弄壞

兩臂各 9 次關機＋9 次開機：**18/18 API 開機回 200 並真的把 gRPC port 打開**
（base 1.536–1.571 s、fixed 1.464–1.552 s），**out-of-band helper 搶救次數 0/18**，
`bmv2 procs` 每次回到 10。18 次關機也全部 200，開火點 poll+28.52–28.58 s（目標 28.5）。
`ndt down` 五條斷言全綠，`ndt release` 已做。

#### 3.3.5 這次量測的但書

- `p4_proxy/p4_src/build/ndtwin_switch.json`（2026-09-02 20:59）是從主 checkout 借用的編譯產物；
  `ndt status` 會說 `.p4 is NEWER than build/...json`，那是 `git worktree add` 造成的 mtime 假象——
  **兩邊的 `ndtwin_switch.p4` 內容 sha256 相同**（`5786a63e…`），所以那份 json 對應的就是這份原始碼。
  取樣率 1/256，與本實驗無關。
- claim 期間 `exclusive_cpu=no`，其他 session 可能同時在編譯；每個 trial 都記了自己的相位
  （9/9 都是 poll+28.5 s 開火、poll 落在 t_off+2.6 s），沒有看到被污染的樣本。
- `polls applied ...` 這個欄位在**第一次** base 跑
  （`git show audit-raw:doc/audit/2026-09-03_fix-poll-resurrect/raw/02_phase_a_base_polltimes_invalid.log`）
  是壞的：drain 放在 40 s 視窗**之後**，所以每一筆都被蓋上 drain 的時間（都是 t_off+39.9）。
  已改成在取樣迴圈內 drain，正式的兩臂都是修好的儀器。壞的那兩份連同更早一次沒有延遲探針的跑
  都留在 audit-raw 上，並在檔名裡說明作廢的理由——丟掉它們是一個關於儀器的宣稱，那個宣稱要可查。
  另外每個視窗第一次 drain 會把上一次 drain 之後累積的行一起蓋上時戳，所以 `t_off+~0.3 s` 那幾筆
  是 backlog 不是抵達時間；真正的 in-window poll 是 2.6 s 與 33.3 s 那兩筆（間隔 30.7 s，與 cadence 一致）。
- 🔴 **`ndt` 的 claim 是 per-checkout 的**（`CLAIM="$REPO/.test_run/lab.claim"`，`$REPO` 來自腳本位置）。
  我從自己的 worktree claim，主 checkout 的 session 看不到 ⇒ 我把 claim 檔**照它自己文件化的格式**
  複製了一份到 `/home/adam/Desktop/NDTwin-Kernel/.test_run/lab.claim`，release 時一併刪除。
  **這是一個真的洞**：`.test_run/pids/` 也是 per-checkout 的，而 fabric 是全機唯一的。列在 ⑥。

## ④ 合併順序與衝突（`git merge-tree` 實測）

基底 `5c64d432`；整合頭在我開工後已前進到 **`1ec39977`**（merge-base 仍是 `5c64d432`）。

```
$ git merge-tree --write-tree --messages integrate/2026-09-03-auditor-merge fix/poll-does-not-resurrect
cec997e953808ef10f0f09707f25ac3769f50196
100644 e2868ce... 1   tests/CMakeLists.txt
100644 d6e56f6... 2   tests/CMakeLists.txt
100644 cd20c21... 3   tests/CMakeLists.txt
Auto-merging tests/CMakeLists.txt
CONFLICT (content): Merge conflict in tests/CMakeLists.txt
```

**只有一個衝突，而且是同一行尾端的兩筆新增**：整合頭在第 88 行後加了 FINDINGS #47 的
`test_CloseOnExecSockets.cpp`，我加了 `test_PollDoesNotResurrect.cpp`。
**解法：兩塊都留，順序不影響**（那是一份 source 清單）。六個 C++ 原始檔**零衝突**——
整合頭自 `5c64d432` 以來動到的原始碼是 `FdHygiene`／`FlowLinkUsageCollector`／
`ControllerAndOtherEventHandler`／`Utils`／proxy 的 Python，與本分支沒有交集。

合併順序沒有相依：本分支可在任何時間點併入，只要解掉上面那一行清單。

## ⑤ 回退方式

- 全退：`git revert 7e8d91e0`（以及本文件那一筆）。單一 commit，沒有跨 commit 相依。
- 只退某一半（都不會編不過）：
  - 只要 #46 不要 #35：把 `P4PowerStrategy::powerOff` 開頭那段註解換回
    `if (!topoMonitor->getVertexIsUp(node)) { return OpResult::success(); }`，
    並把 `powerOn` 的三問改回兩問（拿掉 `!getVertexAdminPoweredOff(node)`）。
    對應的兩個測試（`PowerOffActuatesEvenWhenTheGraphAlreadySaysDown`、
    `PowerOnActuatesWhenACommandedOffIsStillStanding`）會紅，那是預期的。
  - 只要 #35 不要 #46：把 `updateSwitches` 的 `if (vprop.adminPoweredOff) {...} else {...}`
    換回單行 `vprop.isUp = true;`。等同閘門的 M1。
- 資料面沒有 migration：新旗標只存在於記憶體中的圖，不進 JSON、不進檔案、不進線上格式，
  退回去不需要清理任何持久化狀態。
- 變異閘可獨立留著：它會在缺陷被放回去的當下變紅，正是它存在的目的。

## ⑥ 未處理

1. 🔴 **Q12 沒有被回答**——`isUp` 對外仍然一個欄位承載兩種語義。這份修法只在**內部**分開
   （`adminPoweredOff`），`to_json`／`from_json` 一個 key 都沒動，
   `TheEmittedVertexShapeGainsNoNewKey` 會在有人不小心回答 Q12 時變紅。
   要拆欄（Adam 建議的 (a)：`admin_state` ＋ `reachable`）需要動四個 consumer，是另一個工單。
2. 🔴 **另一扇復活的門還開著，而且現在是主要的那扇**：1 Hz liveness worker 在 kill 後
   **0.3–1.5 s** 用 proxy 的快取 `probe_ok` 把 `is_up` 寫回 true，撐到 LLDP 過期
   （**8–13 s**）才寫回 down。本次 18 個 trial 全部重現。修法**刻意不擋它**——那是一個觀測，
   擋掉觀測等於「twin 說一台真的活著的交換機是死的」，而且那正是 Q12 要裁的語義。
   `kPostPowerOffDistrustWindow{15}` 目前用**時間**遮住這 8–13 s 的後果；
   把它改成**證據**界定（下一次真的 probe 成功才關窗）是更小心的做法，未做。
3. **OVS `powerOff` 的 `!isUp` 早退沒有拿掉。** #35 指名的是 `P4PowerStrategy.cpp:176`；
   OVS 那條路 `executeListPorts` 對不存在的 bridge 會失敗回 500，所以拿掉早退需要先補一個
   `ovs-vsctl br-exists` 之類的量測。同型缺陷，未修。
4. **`HttpSession::handleInformSwitchEntered`（`:1449`）仍然無條件 `setVertexUp`。**
   它是控制平面主動通報「交換機接上來了」，比 poll 的清單成員資格更像證據，所以這次沒動；
   但它同樣能覆蓋一個被命令關掉的交換機。
5. **TESTBED 排插路徑是照著改的，沒有量過**——實體 testbed 停用中。
6. 🔴 **`ndt` 的 lab claim 是 per-checkout 的**（見 3.3.5）。`.test_run/lab.claim` 與
   `.test_run/pids/` 都掛在 `$REPO` 下，而 fabric 與 port 是全機唯一的 ⇒
   **從 worktree claim 的人，對用主 checkout 的人是隱形的**。這次用手動複製 claim 檔繞過，
   不是修法。建議把 claim／pid 目錄移到一個與 checkout 無關的位置。
7. **`ndtwin_switch.json` 這次是借主 checkout 的編譯產物**（內容已對帳 sha256）。
   worktree 要能獨立跑 P4 需要自己 `p4c` 一份，或把 build 產物的位置抽成環境變數。
8. **沒有量 OVS 平面的 live**。OVS 的修法有 gtest（`AnOvsPowerOffAlsoSurvivesThePoll`）與變異閘
   M9 覆蓋，但沒有 live 佐證；`ndt up` 預設就是 OVS，值得補一輪。
