# FIX — finding #75：INV-01 的延遲檢查修好了，但 runner 沒有接線

分支 `fix/chaos-runner-runs-latency-check`，base `b57736cd`（分支時的 trunk 頭），
code commit `3e992f0d`。**純離線完成**：沒有 lab、沒有 claim、沒有 `ndt up`、沒有 kernel／
bmv2／Mininet／OVS、沒有編 C++、沒有起任何 server。測試把 `probes._curl` 換成假的
（那個 seam 是 `probes.py` 自己的 docstring 指定的），另外把一輪裡剩下兩個會碰系統的讀取
（`probes.bmv2_process_count`、`antioracle.cpu_busy_fraction`）也在 setUp 換掉。

raw 全部在 `audit-raw` 分支的 `doc/audit/2026-09-03_fix-chaos-runner-wiring/raw/`，
commit `acd56f45`，十個檔逐一用 sha256 對過（不是用 exit code）。

[Co-developed with claude code -- Adam]

---

## 1. 一句話

#17 把 `inv01_powercycle_latency()` 修好了——**修好的是一個沒有人呼叫的函式**：`chaos.py`
的一輪只叫 `inv01_power_state_agreement`，延遲那一半在整個 repo 裡零呼叫點，所以
null／dry-run／controls／full 四種模式**沒有任何一種跑到過它**。這是 #71 的同族，
`existence ≠ wiring`。現在每一輪都評估 INV-01 的**兩半**、分兩列報告；而在沒有東西可以量的
時候，報告寫 **NOT-MEASURED**，**永遠不寫 pass**。

---

## 2. 為什麼不是「把它叫起來」就好

#17 的第二半是**前提條件**，那句話是：**INV-01 的延遲檢查從來沒有量到過一次 power-on。**

`P4PowerStrategy::powerOn` 在 vertex 已經是 up 的時候會立刻回成功——**那個 early return 對一台
活著的交換機是正確行為**，而這個檢查把「快的 2xx」讀成 A-1 的謊。所以無條件呼叫它，
會在一個完全健康的 fabric 上製造出一個 FAIL：`instrument-must-not-mimic-its-own-finding`，
這個 harness 已經踩過兩次（`switch_flags` 把 128 台 host 併成 +1；#17 拿 404 計時）。

⇒ 前提是「**一次應該要做事的 power-on**」。兩種狀態算數，**兩種都從 agreement 那半的
同一份 graph 快照讀**（不另外再抓一次 graph，否則 INV-01 的兩半會對著兩個不同的 fabric 推理）：

1. 目標本身就是**圖上寫 down 的交換機** ⇒ 把它打開必須真的啟動一台；
2. **圖宣稱 up 的台數 > 活著的 BMv2 行程數** ⇒ A-1 狀態，至少有一次 power-on 有事要做。

其他一律 NOT-MEASURED，**而且一個位元組都不送**。不送是重點的一半：錯的時候送出去，
本身就在製造呼叫端下一步要秤的那個數字（#17 就是這樣被騙的），而且這條路由會改變 fabric。

---

## 3. 前後對照

| | 前（trunk `b57736cd`） | 後（`3e992f0d`） |
|---|---|---|
| 一輪評估的 INV-01 | 只有 `inv01_power_state_agreement` | **兩個**：`INV-01` 與 `INV-01-latency`，分列 |
| `inv01_powercycle_latency` 的呼叫點 | **0 個**（全 repo） | 1 個：`chaos.py:358`，`run_invariants` 的 ALWAYS_ON 迴圈裡 |
| 沒東西可量的時候 | ——（根本不會跑到） | `NOT-MEASURED`，`elapsed_s: null`，理由寫在 `why_not_measured` |
| 一輪的總判定 | **報告裡沒有這個欄位** | `verdict`／`verdict_detail`；**任一檢查 FAIL 就 FAIL**，沒有結論的逐一列名並註明**不是 pass** |
| 門檻 | `invariants.py` 裡寫死的 `0.1` | `A1_FAST_S`，**報告印的門檻就是比較用的那一個** |

### 3.1 三個檔各動了什麼

```
chaos.py       power_on_chance()        前提條件，兩個方向都給理由
               inv01_latency_check()    跑它，或誠實地說沒量
               round_verdict()          一輪一個判定
               run_invariants()         迴圈改成 for inv_id, fn，INV-01 後面接上延遲那半
               null_round/injection_round   多一個 power_ip；回傳併入 round_verdict
               main()                   --power-ip
invariants.py  INV01 / INV01_LATENCY    兩個名字
               A1_FAST_S / A1_HONEST_S  0.1 / 1.27；判定式改成讀 A1_FAST_S
               node_ip()                graph 的 ip 是 little-endian uint32 的 list
               inv01_power_state_agreement 的 evidence 多 down_by_ip（同一份快照）
antioracle.py  NOT_MEASURED             刻意不是 PASS／FAIL／SKIPPED
```

**為什麼 NOT-MEASURED 要是第四個字，而不是重用 SKIPPED**：SKIPPED 在這個 harness 裡已經有
主人——#17 把它給了「kernel 拒絕了這個請求」。「被拒絕」與「這一輪沒有 power-on 可以量」
是兩件相反的事，而它們都會以一個很小的數字抵達。PASS 則是宣稱「查過了，沒問題」，
那是量測撐不起的宣稱（跟 `INCONCLUSIVE-CPU` 存在的理由一樣）。

**`elapsed_s` 在沒量到的時候是 `null`，不是 `0.0`。** 0.0 正好就是這個檢查要抓的
「快得可疑」簽名——把它當成沒發生的量測的預設值，等於把指控白送給下一個讀報告的人。
（閘門 W6 就是在測這個。）

**`chaos.py` 仍然是零 HTTP 呼叫點**（只用 `probes.run`／`bmv2_process_count`／
`bmv2_provenance`）——#17 §2.4 那張 34 列的對照表沒有多一列，`TheWholeHarnessConforms`
每次跑仍然自己推導一次並且綠。

---

## 4. 紅 → 綠

🔴 **沒看過紅不算交付。** 新測試 `tests/python/test_chaos_runner_wiring.py`，**13 個 case**。

**在 trunk 的碼上跑**（raw 01）：

```
Ran 13 tests in 0.006s
FAILED (failures=12, errors=1)

AssertionError: 0 != 1 : expected exactly one INV-01-latency row in the round report,
found 0: ['INV-01', 'INV-02', 'INV-08', 'INV-03', 'INV-04', 'INV-05', 'INV-06', 'INV-07']
```

十三個紅只有三種話：**十二個都是「報告裡沒有 `INV-01-latency` 這一列」**
（十個講「found 0」、兩個講「the round evaluated […]」，其中一個是 injection round），
剩下那一個 error 是 `KeyError: 'verdict'`——一輪的報告根本沒有總判定這個欄位。
上面那八列就是這個 harness 從第一次 live run 到今天報告過的全部內容。

**接線之後**（raw 02）：`Ran 13 tests in 0.607s / OK`。

三個類別，兩個方向：

- `TheRunnerRunsBothHalves`——它有沒有被叫到、結果有沒有進報告、有沒有帶著量到的秒數與門檻、
  **injection round 也算數**（只接到一種模式等於同一個缺陷往下一層搬）。
- `WhenThereIsNothingToTime`——健康 fabric ⇒ NOT-MEASURED、**而且一個請求都沒送出**；
  沒給 `--power-ip`、graph 讀不到，也都是 NOT-MEASURED；而 NOT-MEASURED **不會**自己把一輪弄紅。
- `ItStillResolves`——🔴 對照組。**恆為 NOT-MEASURED 的接線可以通過上面每一個 case 而且什麼都測不到**
  （#17 的閘門抓過一模一樣的交換：恆為 SKIPPED）。所以：失敗側的秒數要真的讓**一輪**變紅、
  誠實側要讓它保持綠、報告印的門檻要真的是判定用的那一個（把門檻**從報告裡讀出來**再跨過去測）、
  404 既不是 pass 也不是 FAIL、三個判定用三種真的不同的輪次取得。

🔑 **失敗那個 case 是有鑑別力的，不是裝飾**：fixture 選在「s1 圖上是 down、圖說 2 台 up、
剛好 2 個行程」——agreement 那半是 **PASS**，所以**這一輪只可能透過延遲檢查變紅**。
（如果拿 A-1 狀態當 fixture，agreement 本來就會 FAIL，那個 assert 就算把延遲檢查整個刪掉也會綠。）

⚠️ **極性提醒**：這個檢查的**失敗側是「快」**。A-1 的簽名是 ~0.01 s 的假成功，~1.27 s 才是誠實
路徑。工單寫的是 "a slow fixture (latency over threshold) fails the round"——我照**真實的極性**
實作與命名（`test_a_duration_on_the_failing_side_of_the_threshold_fails_the_round`），
另外補了誠實側的對照（`..._on_the_honest_side_leaves_the_round_passing`）。見 §8 Q1。

---

## 5. 閘門對帳

新閘門 `tests/shell/mutate_chaos_runner_wiring.sh`（raw 03）：

```
  caught   W1: the call is removed again (finding #75 itself)
  caught   W2: the threshold is widened so every latency passes
  caught   W3: 'not measured' is scored as a pass
  caught   W4: the round verdict stops counting the latency check
  caught   W5: the report drops the threshold it judged by
  caught   W6: an unmeasured duration is written as 0.0, not null
  caught   W7: a healthy fabric is timed anyway, so a power-on is sent

  survived X1 (widening): an extra evidence key is added              (all green, as required)
  survived X2 (widening): the verdict string itself is reworded       (all green, as required)
  survived X3 (widening): the honest-path reference is re-measured    (all green, as required)
  survived U1 (control): an inert edit -- a survivor must be reportable (all green, as required)

baseline byte-identical: yes (chaos.py, invariants.py, antioracle.py)
widening controls: 4, 0 killed
mutation gate: 7 mutations, 0 survived
```

- **X 那一組是重點**：pin 在措辭、pin 在 evidence 的精確內容、pin 在 verdict 常數的拼字——
  這三種測試都會殺掉 X1–X3，而那種測試下次改字就會紅，然後就沒有人跑閘門了。
  合約只有四件事：兩半都評估、分列並帶秒數與門檻、沒得量就說 NOT MEASURED 而且不送、
  任一半 FAIL 則該輪 FAIL。其餘自由。
- **U1 是計分器自己的對照組**：一個永遠印不出 SURVIVED 的閘門，不能被相信它會印。
  U1 只改一行註解 ⇒ **必須**存活；被算成 caught 的話閘門自己失敗。
- 🔴 **套不上的變異算 SURVIVOR，不算 caught**：anchor 數不是 1 的時候印 `UNAPPLICABLE`、
  計入存活數、閘門非零退出。這正是 `check_gate_anchors.py` 存在要防的那種失效
  （anchor 漂掉了、輸出看起來還是很整齊）。
- **閘門守自己的 baseline**：變異全部套在 `/tmp` 的**副本**上（`NDT_CHAOS_HARNESS` 指過去），
  `doc/audit/2026-08-28_chaos-harness/harness/` 一個 byte 都沒被寫；anchor 的唯一性從**真檔**
  數，跑完再比三個檔的 sha256。`NDT_KERNEL_REPO` 把路由表釘在**真的** `HttpSession.cpp` 上。

### 沒有打破的既有閘門（raw 04／05／06）

| | 前 | 後 |
|---|---|---|
| `tests/shell/mutate_chaos_invariants_method.sh`（#17） | 11 mutations, 0 survived | **11 mutations, 0 survived** |
| `tests/shell/mutate_chaos_c07_control.sh` | 6 mutations, 0 survived | **6 mutations, 0 survived** |
| `tests/python/test_chaos_invariants_method.py` | 27 OK | **27 OK** |
| `tests/python/test_chaos_c07_control.py` | 20 OK | **20 OK** |
| `harness/test_probes.py`（parser self-test，不是 unittest 模組） | all passed | **all passed** |

**#17 的閘門一個 anchor 都沒碰到**：它在 `invariants.py` 的五個 anchor 我一個都沒改
（尤其 `    ev = {"elapsed_s": round(dt, 4), "ip": ip}` 是 N3 的 anchor，原封不動）；
唯一動到 `inv01_powercycle_latency` 內部的是下一行 `if dt < 0.1:` → `if dt < A1_FAST_S:`，
那不是任何一個 anchor。

```
$ python3 tests/shell/check_gate_anchors.py HEAD \
      --gates mutate_chaos_invariants_method.sh mutate_chaos_c07_control.sh mutate_chaos_runner_wiring.sh
mutate_chaos_c07_control.sh        ok(6)
mutate_chaos_invariants_method.sh  ok(11)
mutate_chaos_runner_wiring.sh      ok(11)
3/3 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)
```

### 全套 Python 測試（raw 07）

`tests/python/test_*.py` **30 個模組，各自單獨跑，全部 rc=0**
（`test_sflow_stats_endpoint.py` 用 `p4_proxy/venv/bin/python`，其餘 `python3` 3.13.13）。
順帶對帳一筆：FIX-CHAOS-INVARIANTS.md §6.1 記「`test_l3_dispatch_drift.py` 在 trunk 上就是紅的」，
**今天在本分支上是綠的（12 cases OK）**。本分支與 `b57736cd` 之間只差我動的那五個檔
（`git diff --name-only b57736cd HEAD`），其中沒有 `HttpSession.cpp` 也沒有
`tools/contract_test/components.py` ⇒ 那條測試讀的東西與 trunk 上一模一樣，
所以它在 trunk 上也是綠的。**那是別人在我拿到 trunk 之前修掉的，不是我修的**，
建議把 §6.1 那條標成已解決。

---

## 6. Live：**沒有跑**

🔴 **這一輪完全沒有碰 lab。** 沒有 claim、沒有 `ndt up`、沒有 kernel／bmv2／Mininet／OVS，
`ndt status` 是唯讀查詢、沒有取得任何租約。§4／§5 的每一個數字都是離線的，
來自被替換掉的 `probes._curl`。

決定的當下（raw 09，2026-09-03T23:38+08:00）：

```
lab
  claim          none
  measuring      nothing
  running        bmv2 switches 0 / :8000 kernel closed / :8081 proxy closed
$ ls .test_run/lab.claim        →  No such file or directory
```

**檔案不在、`claim none`，我還是沒有跑。** 兩個理由，都寫清楚免得下一個人以為 lab 是空的：
orchestrator 明說今晚 P4 lab 由另一個 agent（ovstopo）持有、還有兩個在排隊；而
`measuring nothing` 是**點取樣**、claim 檔是**per-checkout**（#79）——**兩個都不是租約**，
「檔案不在」證不了「沒有人在用」。

⇒ **`inv01_powercycle_latency` 到今天為止仍然沒有量到過一次 power-on。**
接線讓它**能**被量到了，但「它在真 fabric 上量出什麼」還是一個沒有答案的問題。見 §8 Q5。

---

## 7. 合併順序與衝突

- base `b57736cd`；目前 trunk 已前進到 `92a79392`（logger CLI 那支併進來）。
- `git merge-tree --write-tree trunk fix/chaos-runner-runs-latency-check` → **exit 0，零衝突**。
  對 code commit `3e992f0d` 量到的樹是 `1916baf7`，raw 10 存的就是那一次；
  把本文件的 commit 也算進去再量一次仍然是 exit 0。
  **樹的 oid 會隨這份文件本身改變（所以這裡不釘它），會不會衝突不會。**
- 交集為空：trunk 自 base 以來動的是 `include/utils/Logger.hpp`、`src/main.cpp`、
  `src/utils/Logger.cpp`、`tests/test_LoggerCliArgs.cpp`、`tests/shell/mutate_logger_cli.sh`
  與兩份 doc；本分支動的是 chaos harness 的三個 `.py` 加兩個新檔。**順序無所謂。**
- 未來要留意的是：任何同時動
  `doc/audit/2026-08-28_chaos-harness/harness/{chaos,invariants,antioracle}.py` 的分支
  要先併誰後併誰。目前 `refs/heads/` 底下沒有別的。
- 併完建議重跑三支 chaos 閘門（各 <15 秒，不需要 lab）：
  ```
  bash tests/shell/mutate_chaos_runner_wiring.sh
  bash tests/shell/mutate_chaos_invariants_method.sh
  bash tests/shell/mutate_chaos_c07_control.sh
  ```

**回退**：單一 code commit，`git revert 3e992f0d`。沒有 migration、沒有落地狀態、沒有生成物。
回退之後回到的狀態是：延遲檢查回到零呼叫點，一輪的報告回到八列、沒有總判定。

---

## 8. 未處理（我沒有做的事）

1. **沒有 live 驗證。** 見 §6。守衛與判定都是離線證明（假 kernel + 假 process count），
   不是「我在真 fabric 上量到 1.27 s」。
2. **G1 那條路徑沒有接。** `probe_one_invariant("INV-01", ...)` 仍然只回 agreement 那一半，
   所以 G1-01 的正對照驗的還是舊的那半。**我刻意沒動**：G1-01 是 `--allow-poweroff` 後面的
   破壞性控制、它的 undo 是 UNPROVEN，而它本來就會自己 off-then-on 計時
   （`_c01_apply`／`_c01_verify` 各有一次 `api_post_timed`）——把延遲檢查再塞進去，
   等於在同一輪對同一台交換機發第三次 power-on。那需要先想清楚，不該順手做。
3. **「只靠延遲」仍然是單一來源判準**，跟 #17 §6.4 記的一樣：真 2xx 的 `dt < 0.1` 旁邊
   沒有狀態檢查。我把**前提**修了（沒得量就不量），**判準本身沒動**。
4. **#17 §2.4 那張表的行號漂了**（我在 `invariants.py` 上面加了約 38 行；
   `api_post_checked_timed` 從 :126 移到 :164）。**表的內容沒有變**——沒有新增／刪除任何
   HTTP 呼叫點，`chaos.py` 仍然零呼叫——所以我沒有去改那份文件的行號欄。
5. **`--power-ip` 沒有預設值**，所以**不帶它的時候每一輪都是 NOT-MEASURED**。見 Q2。
6. **proxy（Ryu）那面一樣沒有守衛**（#17 §6.2 的洞照舊）。

---

## 9. 要問 Adam 的

**Q1（極性）** 工單寫「slow fixture (latency over threshold) fails the round」，但這個檢查的
**失敗側是快的那一側**（~0.01 s 的假成功；~1.27 s 是誠實路徑）。我照真實極性做，
並且兩側都寫了 case。**確認一下這是你要的**——如果你其實想要的是「太慢也算違規」
（例如 power-on 花了 30 s），那是**另一個判準**，現在沒有。

**Q2（預設值）** `--power-ip` 要不要給預設 `192.168.123.11`（`S1_MGMT_IP`）？
- 給：延遲檢查在真跑的時候比較容易真的量到。
- 代價：null round 在「s1 圖上是 down」的時候會**真的送出一次 power-on**——那是狀態變更，
  而 null round 的合約是「什麼都不注入」（雖然它已經在拿真的 `power_lock` 了，而且有寫出來）。
- 我選了**不給**：這條路由會開機器，需要一個被指名的目標，不是一個預設值。

**Q3（第三個來源）** 「可量測」現在只認兩個**觀測到的**狀態。要不要加第三個——
**由 harness 自己先把交換機關掉再量**？那正是 G1-01 在做的事（`--allow-poweroff`、
undo 未經證明、`P4PowerStrategy.cpp:100-114` 記錄 off-then-on 救不回 P4 交換機）。
我沒有動它。

**Q4（判準）** 要不要在 `dt < A1_FAST_S` 旁邊補一個狀態對照（power-on 之後 process count／
graph 有沒有真的變）？現在快慢是單一來源，`_c01_verify` 已經因為這個教訓重寫過一次。

**Q5（lab 窗口）** 要不要排一個 lab 窗口，把 `INV-01-latency` 真的量一次？
那會是這個檢查存在以來**第一次真的量到一次 power-on**——最短路徑是：claim、`ndt up p4 4`、
把 s1 關掉、`--power-ip 192.168.123.11 --null`、看那一列是 FAIL 還是 PASS、raw 進 audit-raw。

[Co-developed with claude code -- Adam]
