# FIX — `ndt` round 2（W16 續、I-3、D-2 續），2026-09-07

[Co-developed with claude code -- Adam]

分支 `fix/ndt-round2-0907`，base＝`fix/w16-apps-stop-lists-rules`@`19a05ddb`。
**沒有 rebase、沒有併、沒有推。** 只動 `tools/test_workflow/ndt`（bash）、`tests/`、`doc/`；
**沒有碰任何 C++／CMake／P4**，所以沒有建置、沒有用 build lock。

裁決正本：`scratch/overnight-2026-09-05/DECISIONS.md`
—— grill §4D 第七輪（W16-1／W16-2）、第九輪（D-2）、第十輪（I-3）、09-07 01:0x（W16-3 實跑）。

---

## 1. W16-1 — `ndt apps orphans` 的 rc 因殘留而紅

**裁決**：「rc 因殘留而紅（⚠️ 與建議相反 ⇒ `arm_up.sh` 等把 orphans 當 gate 的腳本要跟著改判準）」。

前一張單（W16）刻意**沒有**改 rc，理由寫在 `W16-SUMMARY.md` §7 第 1 題：orphans 回答的是行程的
問題，悄悄重新定義會弄壞每一個呼叫者。Adam 裁了反過來，而他的理由比較強：**G-12 這條 finding
本身就是「所有既有檢查都是綠的」**——一個 rc 不會紅的殘留報告，只是多一個綠燈。

### 五個互斥的碼（`cmd_apps` 的 `orphans)` 分支）

| rc | 意思 | 補救 |
|---|---|---|
| 0 | 行程乾淨，網路上也沒東西 | — |
| 1 | 有沒人追蹤的 app **行程**在跑（09-02 起的舊語意，不變） | `ndt apps stop <name>` |
| 2 | 某一條存活通道看不到（舊語意，不變） | 查那條通道 |
| **4** | 行程乾淨，**網路上有殘留**：窗內的流表規則，或還握著的鎖 | 手動 `delete_flow_entry`；鎖等 TTL |
| **5** | 行程乾淨，**殘留查不了** | 不是「乾淨」，是「沒問到」 |

🔴 **4 與 5 刻意不是 1。** 一個還活著的行程還在改網路，補救是 `ndt apps stop`；
一條留下來的規則沒有人在跑它，補救是手寫一個 delete。**分不出這兩者的 rc，兩邊都不能行動。**

**優先序**：行程的答案先贏（`orc != 0` 就回 `orc`，並在旁邊多印一行說網路也不乾淨）。
理由：既有呼叫者讀 rc 1 的方式不變，而 rc 仍然非 0，當 gate 的腳本照樣會擋。

### `apps_orphans()` 這個**函式**沒有變

它仍然只回答行程的問題（0／1／2）。變的是 `cmd_apps orphans` 這個**子指令**。
`tests/shell/test_ndt_app_orphans.sh` 驅動的是函式，所以它一格都沒改。

### 4 與 5 的分界（`residue_verdict`，四個計數器）

```
RESIDUE_RULES      被「定年」而且落在窗內的規則      -> 有東西    -> 4
RESIDUE_LOCKS      現在握著的鎖                       -> 有東西    -> 4
RESIDUE_UNDATABLE  列出來但 age=UNKNOWN 的規則        -> 沒定位到  -> 5
RESIDUE_BLIND      根本問不出來的問題                 -> 沒看到    -> 5
```

🔴 **`UNDATABLE` 算 5 不算 4**。「我找到一條我放不進任何窗的規則」是一次**檢查失敗**，
不是一個**發現**。而在 P4 平面上那是**每一條**規則（見 §3），把它算成殘留＝每一個健康的 P4
fabric 都紅，一週之內就沒有人看這個 rc 了。

### 「沒有窗」不再一律算 blind

`residue_report` 對每個 app 找窗；找不到窗的 app 以前只印一句話。現在分兩種：

- **log 是空的／不存在** ⇒ 「沒有跡象它在這個 checkout 跑過」，**不計入 blind**。
- **log 有內容** ⇒ `app_spawn` 建的 log 證明它跑過，**窗是丟失的、不是不存在** ⇒ 計入 blind。

沒有這個分辨，五個 app 在一台沒人起過 app 的機器上都沒有 pidfile ⇒ 每一次 orphans 都回 5。
判別子是 log，因為 `app_spawn` 就是建 log 的那一步。

---

## 2. W16-2 — `ndt status --check` 多印殘留一列，有殘留就紅

**裁決**：「印且 rc 紅（⚠️ 與建議相反 ⇒ `--check` 判準改了，所有當 gate 的地方要跟）」。

新函式 `status_residue_row`（`ndt`，在 `residue_verdict` 下面），由 `cmd_status` 在
**`--check` 模式下**呼叫；它把 `STATUS_RESIDUE_PROBLEMS` 併進既有的 `problems` 陣列，
所以「有殘留」就是既有的 rc 1（"I compared and found this wrong"），呼叫者不必認識新的碼。

| 那一列說 | rc |
|---|---|
| `residue        none -- 0 rule(s) in any app window, 0 lock(s) held (asked, not assumed)` | 不影響 |
| `residue        N rule(s) inside an app window, M lock(s) HELD` | **算一個 problem ⇒ rc 1** |
| `residue        NOT CHECKED: ...` | **不算 problem**，但那一列自己說它不是「乾淨」 |

### 🔴 為什麼 `NOT CHECKED` 不進 problems（這是新出現的張力，見 SUMMARY §7）

W16-2 裁決的時間**早於** W16-3 的實跑結果。實跑之後我們才知道：**P4 平面上沒有任何一條規則
可以定年，而且那是永久的**（proxy 合成的統計沒有時間軸）。如果 `NOT CHECKED` 也算 problem，
`ndt status --check` 在**每一個健康的 P4 fabric 上永遠是紅的**——而
`doc/2026-08-17_testing-manual.md:279` 寫的是「**P4**：`ndt status --check` 回 rc=0 才算過」。
一個永遠過不了的閘門，一天之內就會被無視，那正是 G-12 裡那些綠燈失去意義的方式。

所以：**4 才紅，5 只印**。誠實性靠那一列自己扛——它每一次都印出 `NOT CHECKED`、印出
「this is not 'the network is clean'」、印出為什麼，而且**鎖是有查到的**（鎖是 kernel 狀態、
不是流表統計），所以 P4 上握著的鎖照樣讓 `--check` 變紅。

### 🔴 只有 `--check` 付這個代價

那個掃描是一次流表 GET 加三次 `acquire_lock` POST。`ndt status` 是各 session 每小時讀幾十次的
頁面。閘門可以付一次讀取的錢，狀態頁不行。
`tests/shell/test_ndt_status_residue_row.sh` 第 5 組用**檔案 marker** 釘死這件事
（不能用 stderr：`status_residue_row` 把 `residue_report` 導到 `/dev/null`，任何訊息都會被吞掉）。

---

## 3. W16-3 — P4 平面沒有時間軸，所以它上面什麼都不能定年

**實跑結果（DECISIONS 09-07 01:0x，orchestrator 跑的，我沒有跑）**：P4 4 hosts、trunk
`862c4bf8`、`logs/w163-*`。裝一條 10.0.0.3 的路由，+12 s 與 +32 s 兩次讀
`get_switch_openflow_table_entries`：**該條與所有既有條目都是 `duration_sec:0, duration_nsec:0`**，
而 `packet_count`／`byte_count` 有值。`p4_proxy/proxy_agent/ryu_flow_stats.py` 合成這些列，
它沒有安裝時間可以填。

**把那個 0 當成「0 秒前」，就是把整張表都判成「剛剛裝的」⇒ 落在每一個窗裡面**——那正是
W16 的 mutation M3（widening）要防的形狀，只是這次從資料那一側進來。

### 改了什麼

`suspect_rules` 多一個 `plane` 參數（`residue_rule_lines <started> <now> <plane>`；
plane 由 `residue_report` 呼叫一次 `live_dataplane_kind()` 取得）。三條新規則：

1. `plane == "p4"` ⇒ 每一條規則 `age=UNKNOWN (P4 plane: ...)`，**全部列出來**。
2. `duration_sec == 0 && duration_nsec == 0`（不論平面）⇒ `age=UNKNOWN (...0 AND ...0)`。
   **真正的交換機不會產生這一對**：OpenFlow 的 duration 是 (sec, nsec)，一條一秒內裝好的
   規則是 sec 0 / nsec **非** 0。兩個都 0 是合成的簽名。
3. 新的純函式 `window_blindspot(entries, plane)` 回一句話說「這個平面分不了窗」，
   由 python 印成 `CANNOTWINDOW <why>`，`residue_report` 每次執行印一次：
   「CANNOT WINDOW ... every rule below is age=UNKNOWN and NONE is attributed to an app;
   this is the whole flow table, not a residue list」。

🔴 **反方向也釘住了**：`test_a_genuinely_sub_second_rule_is_still_dated` 與 5K 的後半——
sec 0 / nsec 有值的規則仍然被定年成 `installed 0s ago`，而且那張表不會被判成 blind。
沒有這一格，「凡是 duration 0 就 UNKNOWN」會通過上面每一格。

---

## 4. I-3 — 警報比值，收工檢查比檔案集合差

**裁決（第十輪）**：「開一張單修兩處（狀態警報比值／收工檢查比檔案集合差）」。

### 這個 finding 為什麼危險（`rounds/03-R7-reconciler.md` I-3）

`p4_proxy/mininet/host_count_override` 09-05 那晚的基準是**工作樹 4 / HEAD 128**
（LAB-RULES 硬規則 5 紅字：還原＝寫回 4，**不能** `git checkout --`）。R4 為了跑 128-host
把它寫成 128 ⇒ **它跟 HEAD 相同了** ⇒ 兩個儀器同時失明：

- `git status --porcelain | wc -l` 從 **22 掉到 21**：機器**離開**基準，數字往「比開工還乾淨」走。
- `ndt status` 那句專門為這顆旋鈕寫的 `1 of them can change behaviour` **整段消失**——
  它是用 git 髒度推導的。

⇒ **兩個守衛用同一個有缺陷的訊號源，所以不是互相備援，是一起瞎。**

### 修法

**`.test_run/round.baseline`**，由 `ndt claim` 寫（開工＝claim 那一刻）：

```
at=<unix seconds>   by=<NDT_OWNER>   head=<claim 當下的 short sha>
host_count=<旋鈕當時的值>
dirty=<path>        每一個未提交路徑一行，排序
```

**`knob_row`**（`git_lines` 呼叫，**完全不看 git 髒度**）：

- 有 baseline：值 == baseline ⇒ 一行「== the value this round started with」；
  值 != baseline ⇒ **紅**「NOT RESTORED」＋**明講 git 怎麼看這個檔**
  （"git calls this file CLEAN (it matches HEAD) -- that is NOT 'restored'"）
  ＋交出 `echo <base> > <path>` 並警告 `NOT 'git checkout --', which gives you HEAD`。
- 沒有 baseline：`!= 4` 無條件印（Adam 給的 fallback）；`== 4` 印一行說是預設值。

**`tree_vs_round_row`**（`git_lines` 呼叫）：`comm` 兩次，**兩個方向都列檔名**。
**離開**未提交集合的那一邊列在前面並標「now matches HEAD -- which is not the same as restored」，
因為那是計數表達不了的方向。

**`git_lines` 的 early return 拿掉了**：舊碼在乾淨樹上就 `return`，而**乾淨樹正是旋鈕最危險的
那個值造成的狀態**——那個 early return 就是 bug。

### 🔴 沒做的：set difference **不**進 `--check` 的 problems

一輪之中 commit 會合理地改變這個集合，一個每次 commit 都響的閘門沒有人會看。
**會變紅的只有旋鈕的值那一條。**

> ⚠️ **本段已被 09-07 的補一顆更正（E-9）。** 這裡原本寫「（而且它也只是印在 `lab` 區塊，
> **不進 problems**——舊的 "can change behaviour" 區塊也從來不進 problems，這一點沒有改）」。
> 那句話**是實作的實情，但它是錯的規格**：04:36 的 live 臂（`rounds/08-round2.md:146`）
> 讓那一列印出紅字 `8 -- this round started at 128: NOT RESTORED`，而 `--check` 回 **rc 0**。
> Adam 09-07 裁（grill §4E 第三輪，E-9）：**NOT RESTORED 進 problems ⇒ rc 1**；
> 「commit 會改集合所以不該紅」的理由**只適用 `tree_vs_round_row`**，那一列維持不進 problems。
> 詳見底下的〈補一顆（09-07：E-9／E-11／E-10）〉。

---

## 5. D-2 — `ndt check` 印取樣率與預期低報；取樣率在 OVS 平面改讀 OVSDB

**裁決（第九輪）**：「要，一起印（連同『status 取樣率在 OVS 讀錯來源』一起開）」。

### (a) X-2：讀錯平面（`rounds/06-X-experiments.md` §3-B）

舊的 `sample_rate()` 只會解 `p4_proxy/p4_src/build/ndtwin_switch.json` 裡 `random(0, N-1)`
的上下界，而且**在每一個平面都印那個數字**。實測逐字（`logs/x1-22-status-blind-to-ovs-rate.log`），
把十筆 OVS sflow record 全設成 64 之後：

```
ovs now: 64
--- ndt status says: ---
  sample rate    1/256
```

兩個數字**只是碰巧都是 256**，所以幾個月沒人發現。

**修法**：`sample_rate [plane]`，plane 是**參數**不是內部查詢（`cmd_status` 與 `cmd_check`
各自已經知道自己在講哪個平面，問兩次會讓取樣率和報告其他部分描述兩個不同的 fabric）。

| plane | 讀哪裡 | 函式 |
|---|---|---|
| `ovs` | `ovs-vsctl --bare --columns=sampling list sflow`（OVSDB） | `ovs_sample_rate` |
| `p4`／`none`／`unknown` | 編出來的 JSON（原本的行為） | `p4_sample_rate` |

新增 `rate_source <plane>`，**每一次都印**（`ndt status` 的 `rate source` 列、
`ndt check` 的 `source` 列）。X-2 活了幾個月就是因為那一列只寫 `1/256`、從不寫「out of what」。

OVS 側**十筆記錄、一個問題**，四種答案都不會被印成分數：

| OVSDB 說 | 回什麼 | `--check` |
|---|---|---|
| 十筆一致 | 那個數字 | — |
| 不一致 | `OVS-DISAGREE:64,256` | **紅**（這個 fabric 沒有單一取樣率） |
| 一筆都沒有 | `OVS-NOSFLOW` | **紅**（什麼都沒在取樣 ⇒ 每個頻寬數字都是 0） |
| `sudo -n ovs-vsctl` 被拒 | `UNREADABLE:...` | **紅**（不是預設值） |

（🐛 寫的時候踩到並留成 mutation P8：`tr -d '[:space:]'` 連換行一起刪，十筆 64 會變成
一個值 `64646464646464646464`，不一致那一支就永遠不會觸發。正確是 `tr -d ' \t\r'`。）

### (b) X-1：`ok` 把 0.65 也吃下去

X1 實測（`rounds/06` §X1，19 次全部低於真值，三組 `loss_fraction`／`sock_ovfl_total`／
`app_drop_total` 全 0 ⇒ 是偏差不是掉包）：

| 取樣率 | n | ratio 均值 | 低報 |
|---|---|---|---|
| 1/64 | 6 | 0.977 | 2.3% |
| 1/256 | 9 | 0.902 | 9.8% |
| 1/1024 | 4 | 0.753 | 24.8% |

`ndt check` 的 ok 帶是 0.5–1.5（Adam 保留了它：那是**倍增**的絆線，不是校準檢查），
所以 0.65 也印 `ok`。現在 `check_rate_lines <rate> <plane>` 在 ratio 旁邊印：
取樣率、來源、**這個取樣率下該有的低報**，以及三個測過的點。

🔴 **表裡沒有的取樣率印「no reference」，絕不內插。** 曲線會飽和（1/64→1/256 低報約 4 倍，
1/256→1/1024 只有約 2 倍），兩點之間造一個數字＝一個沒有人量過的宣稱，而讀的人分不出它跟
那三個量過的有什麼不同。

### 刻意沒改的一個不一致

P4 側讀不到編譯產物時 `sample_rate` 回 `unknown`，而它**不進 `--check` 的 problems**
（OVS 側的 `UNREADABLE:` 會）。`unknown` 是本單之前就有的行為，把它變成 problem 會讓
**任何沒有編過 P4 pipeline 的 checkout**（含只跑 OVS 的人）在 `--check` 上一律紅。
留原樣，記在這裡以免下一個人以為是漏的。

---

## 6. 檔案與函式

| 位置 | 是什麼 |
|---|---|
| `ndt` `p4_sample_rate` / `ovs_sample_rate` / `sample_rate` / `rate_source` | D-2 (a) |
| `ndt` `rate_label`（多三個 token）/ `expected_shortfall` / `check_rate_lines` | D-2 (b) |
| `ndt` `round_baseline_file` / `round_baseline_field` / `round_baseline_dirty` / `record_round_baseline` | I-3 |
| `ndt` `git_lines`（改寫）/ `knob_row` / `tree_vs_round_row` | I-3 |
| `ndt` `_all_rows` / `_no_time_axis` / `window_blindspot` / `suspect_rules(+plane)` | W16-3 |
| `ndt` `RESIDUE_*` / `residue_verdict` / `status_residue_row` / `residue_report`（計數） | W16-1 / W16-2 |
| `ndt` `cmd_apps` 的 `orphans)`／`cmd_status`／`cmd_check`／`cmd_claim`／usage heredoc | 接線 |

測試：`tests/shell/test_apps_residue.sh`（74 檢查）、`tests/python/test_app_residue_rules.py`（36）、
`tests/shell/test_ndt_status_residue_row.sh`（27，新）、`tests/shell/test_ndt_round_baseline.sh`（34，新
⇒ **09-07 補一顆後 65**）、`tests/shell/test_ndt_check_sample_rate.sh`（39，新）。
閘門：`mutate_apps_stop_lists_rules.sh`（26 變異）、`mutate_ndt_round_baseline.sh`（12，新
⇒ **補一顆後 18**）、`mutate_ndt_check_sample_rate.sh`（12，新）。**三支合計 50 變異、0 存活
（補一顆後 56、0 存活）。**

## 7. `doc/KNOWN-ISSUES.md` 沒有動——替換文字放在這裡

跟 W16 一樣的理由，而且範圍更大：本分支的 `doc/KNOWN-ISSUES.md` 裡
**`G-12`／`I-3`／`X-1`／`X-2` 一個都沒有**（`grep -c` 全 0）。G-12 由手冊員登在 trunk 的
`1536ff17`，那顆**不是本分支的祖先**（`git merge-base --is-ancestor 1536ff17 HEAD` → 否），
而 I-3／X-1／X-2 是 09-05／09-06 兩輪的 finding，還沒有人登。在這裡自己寫一條，合併時會變成
兩條。**協調員明講不要 rebase** ⇒ 文字放這裡，兩邊相遇時套。

**G-12 狀態改**（接在既有條目後面）：

> **狀態（2026-09-07，分支 `fix/ndt-round2-0907`）**：`ndt apps stop`／`ndt apps orphans`
> 已經會列出殘留（W16，`19a05ddb`），而且 **rc 會因為殘留而紅**（W16-1）：
> 0 都乾淨／1 行程孤兒／2 通道盲／**4 網路有殘留**／**5 殘留查不了**。
> `ndt status --check` 多一列 `residue`，有殘留算一個 problem（W16-2）。
> **仍然什麼都不刪**（Adam 09-05 grill 第五輪）。**P4 平面分不了窗**——見下面 W16-3。

**新條目 G-13（建議）— P4 的流表統計沒有時間軸**：

> `p4_proxy/proxy_agent/ryu_flow_stats.py` 合成 `get_switch_openflow_table_entries` 的每一列，
> 而它沒有安裝時間可以填：**`duration_sec` 與 `duration_nsec` 恆 0**，`packet_count`／
> `byte_count` 則有值。實測 2026-09-07（P4 4 hosts、trunk `862c4bf8`、`logs/w163-*`）：裝一條
> 路由後 +12 s 與 +32 s 兩次讀，該條與**所有**既有條目都是 0/0。
> ⇒ 任何用 `duration_sec` 給規則定年的東西，在 P4 上會把**整張表**判成「剛剛裝的」。
> `ndt` 側已擋（W16-3：P4 平面一律 `age=UNKNOWN` 並印「CANNOT WINDOW」）；
> **proxy 側沒有修**，端點的回應仍然是 0/0。

**新條目 I-3 — 兩個還原檢查用同一個有缺陷的訊號源**：見本文件 §4 與 §9.1，
狀態「已修（分支）」，並補一句「**`--check` 下 `NOT RESTORED` 算 problem ⇒ rc 1**（E-9，09-07）」。

⚠️ **G-13 已由 Adam 裁成要開的單**（E-10，`DECISIONS.md:242`）：「**從根本修**：proxy 在 install
時記時間戳給 P4 規則裝入時間」。上面那段文字可以直接當這條 issue 的本文；
過渡期（G-13 落地前）arm 腳本把 5 記成「殘留未查」、不擋下一臂——那是 Adam 的預設，沒有點名白名單。
另外，上面「P4 平面分不了窗 ⇒ orphans 5」要照 §9.3 更正：**沒有窗的時候是 0，而 0 不是乾淨**。

**新條目 X-2 — `ndt status` 的取樣率在 OVS 平面讀 P4 的編譯產物**：見本文件 §5(a)，
狀態「已修（分支）」。**X-1（低報是取樣率的函數）不是缺陷、是量測結果**，不需要登記成 issue；
它的數字現在印在 `ndt check` 裡（§5(b)）。

## 8. 順手修的一個壞掉的儀器（不是本單造成的）

`tests/shell/test_lab_handoff.sh` 的 sandbox 只複製 `ndt`，沒有複製它 source 的
`ports.sh`／`sudo_surface.sh`／`components.env` ⇒ `ndt` 在讀到任何子指令之前就 exit 2 ⇒
**18 格裡 12 格紅**。在 base `19a05ddb` 上一樣紅（親自跑過對照），所以**不是本單造成的**。
補了三個 `cp` 之後 18/18 綠。一個沒有人見過它綠的測試等於沒有測試。

---

## 9. 補一顆（09-07：E-9／E-11／E-10）

[Co-developed with claude code -- Adam]

**單號 R3-NDT**，接在 `b09d330d` 後面的同一條分支 `fix/ndt-round2-0907`（沒有 rebase、沒有
merge trunk）。裁決正本：`scratch/overnight-2026-09-05/DECISIONS.md:238`（E-9）、`:240`（E-11）、
`:242`（E-10）。**動機全部來自 04:3x 那四場 live 臂**，不是重讀原始碼想出來的。

### 9.1 E-9 — `knob baseline` 的 `NOT RESTORED` 進 problems（`--check` ⇒ rc 1）

**實跑的動機**（`rounds/08-round2.md:146`，臂 lw16 步驟 D，04:36，OVS 4 hosts、分支 `b09d330d`）：

```
claim（round.baseline 記 host_count=128）→ echo 8 > p4_proxy/mininet/host_count_override
  knob baseline  8 -- this round started at 128 (at 04:36:41): NOT RESTORED     ← 紅字
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
$?  →  0                                                                        ← rc 綠
```

紅字配綠 rc，正是 W16-2 當初被裁「印且 rc 紅」時 Adam 自己的理由要擋的東西
（「rc 不會紅的報告只是多一盞綠燈」）。而收工 `--check` 正是「還原＝寫回 4」該咬人的地方：
`p4_proxy/mininet/host_count_override` 決定下一次 `ndt up p4` 蓋幾台，沒有別的東西讀它。

**改法**（照 `STATUS_RESIDUE_PROBLEMS` 的形狀）：

| 位置 | 改動 |
|---|---|
| `ndt` `STATUS_KNOB_PROBLEMS=()`（`knob_row` 上方） | 新全域；`knob_row` 開頭重設 |
| `ndt` `knob_row` 的 NOT RESTORED 分支 | `STATUS_KNOB_PROBLEMS+=(...)`，句子含**現值、開工值、`echo <base> > <path>`、以及「不是 `git checkout --`，那會給你 HEAD」** |
| `ndt` `cmd_status`（`git_lines` 之後一行） | `(( ${#STATUS_KNOB_PROBLEMS[@]} > 0 )) && problems+=("${STATUS_KNOB_PROBLEMS[@]}")` |

**併在 `cmd_status` 而不是在 `knob_row` 裡直接 `problems+=`**：那一列維持是個印表機，
「`--check` 對什麼東西回非零」只由一個函式決定。**無條件併**（不像 residue 那樣只在 `--check`）：
這裡不花任何一次 POST，而 `problems` 本來就只在 `--check` 底下印。

🔴 **範圍只有這一句。** 另外兩支不進 problems：
- `4 (the default; no round baseline recorded)` — 根本沒有偏離。
- `!= 4, and no round baseline exists` — **它分不出「忘了還原」和「本來就要跑 128 台但沒 `ndt claim`」**。
  把它折進來，等於每一場沒 claim 的 128-host round 都紅。變異 **N14（widening）** 釘住這一格。
- `tree_vs_round_row`（集合差）也不動，理由見 §4：一輪中 commit 會合理地改變那個集合。
  變異 **N14** 之外另有第 10 組的對照格（改別的檔 ⇒ `--check` 仍綠）。

想擴大範圍要 Adam 再裁一次，寫在 SUMMARY §7。

### 9.2 E-11 — `ndt release` 把 `round.baseline` 收成 `.prev`

R2-NDT 的 SUMMARY §7 #3 刻意把它留成「沒有任何東西刪它」。Adam 09-07 裁：**release 時 rename
成 `.prev`**，照 `lab.handoff` → `lab.handoff.prev` 的前例（`cmd_claim` 裡那一段）。

**改法**：`cmd_release` 在**真的移除了 claim 之後**（`rm -f "$CLAIM"` 那條路，`--force` 也走它）：

```
    local rb; rb="$(round_baseline_file)"
    if [[ -f "$rb" ]]; then
        mv -f "$rb" "$rb.prev" 2>/dev/null && info "..."
    fi
```

**rename 不是刪**：一輪開工時的旋鈕值與髒檔集合，事後**無法**從 `git status` 重建，
而「那一輪留下了什麼」是收工之後才被問的問題。**沒有任何程式讀 `.prev`**，它是留給人的。

🔴 **`no claim to release` 那條早退路徑不動。** 一個沒握著 claim 的 release 是 no-op，
它不該把別人還活著的 round 結束掉。變異 **N17（widening）** 把 rename 移到早退之前，
測試第 12 組最後一格會紅。

**檔案格式註解**（`ndt` 的 `.test_run/round.baseline` 那段）補了 `.prev` 的說明。
之後 `ndt status` 會回到「no round baseline recorded」——**那是正確語意（round 結束了）**，
不是資料掉了；手冊與收工清單都寫進去了，並且明講**兩列要在 `release` 之前抄**。

### 9.3 E-10 — 「P4 上 orphans 固定回 5」不成立（文件更正）

R2-NDT 的 SUMMARY §7 #2 這麼寫，並且把它寫進了**已 commit 的手冊**。lw16p 實測推翻
（`rounds/08-round2.md:157-172`，04:39，乾淨 P4、bmv2 4 hosts）：

```
ndt apps orphans  →  rc 0
  0 dated rule(s) in a window, 0 lock(s) held, 0 could not be dated, 0 not answerable
  (no app had a datable window in this run)
  residue: none -- ... (asked, not assumed)
```

**沒有窗就不去定年任何規則** ⇒ UNDATABLE=0 ⇒ 回 0。lw16pw（`:174-193`）在**同一個 checkout**
起過一次 `sim` 之後才走得到 UNDATABLE／BLIND ⇒ 5。

**正確的說法**（已寫進 `doc/2026-08-31_round-closing-checklist.md` §5 與
`doc/2026-08-17_testing-manual.md` §2.3）：

- P4 平面上**只要有 app 在這個 checkout 留下窗**就是 5／`NOT CHECKED`（流表統計沒有時間軸）。
- **沒有任何窗時回 0／`none`，而那個 0 是「沒東西可定年」，不是「乾淨」**——一條規則都沒被問過。
- 窗來自**這個 checkout** 的 app pidfile／log；別的 checkout 跑過的 app 留下的規則在這裡永遠沒有窗。
- `|| exit 1` 在 P4 上**只要有 app 跑過**就會失敗（先前寫「永遠失敗」）。
- `energy`／`sim` 目前因 **3-51** 永遠沒有窗（helper 起的 app 不寫 pidfile），另一張單修。
- Adam 對 E-10 的處置是**從根本修**：**G-13**——proxy 在 install 規則時記時間戳，
  讓 P4 的規則定得了年（另開單；過渡期 arm 腳本把 5 記成「殘留未查」，不擋下一臂）。

〔本節全部是**讀 `rounds/08-round2.md` 的實跑紀錄**改寫的；**我沒有上過實驗室**。〕

### 9.4 閘門

`tests/shell/test_ndt_round_baseline.sh` 從 34 格加到 **65 格**（第 8–12 組）。
第 8–11 組驅動**整個 `cmd_status --check`**（不是單一列）：沙盒是同一個臨時 git repo，
加上 `.test_run/up.target`＋一張 graph／entries／topology fixture，
**`git_lines`／`knob_row`／`tree_vs_round_row`／`check_up_target`／exit code 全部真的跑**。
第 11 組另外釘住「沒有 `up.target` ⇒ rc **3**（COULD NOT CHECK），而旋鈕那句 problem
仍然出現在 `everything else this report could still check:` 底下」。

`tests/shell/mutate_ndt_round_baseline.sh` 從 12 變異加到 **18**，0 存活：

| 變異 | 放回去的東西 | 該紅的格 |
|---|---|---|
| N12 | NOT RESTORED 印紅字但什麼都不 raise（＝04:36 的行為） | `🔴 and it is listed as a problem` |
| N13 | `cmd_status` 不把 `STATUS_KNOB_PROBLEMS` 併進 `problems` | `🔴 --check exits 1 (it exited 0 over this at 04:36)` |
| N14（widening） | 沒有 baseline 的那句也進 problems | `🔴 but it is not a problem` |
| N15 | `release` 不收 `round.baseline` | `🔴 the round baseline is gone` |
| N16 | 收成 `.old` 而不是 `.prev`（釘住檔名，手冊寫它） | `🔴 and kept as .prev, not deleted` |
| N17（widening） | `no claim to release` 也收 | `🔴 and leaves the baseline where it is` |
