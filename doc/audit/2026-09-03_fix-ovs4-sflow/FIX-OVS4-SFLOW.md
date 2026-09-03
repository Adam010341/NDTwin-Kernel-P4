# Finding #4 — `ovs4` configured no sFlow, so the twin's rates were structurally zero

分支 `fix/ovs4-has-sflow`，基底 `integrate/2026-09-03-auditor-merge @ 5c64d432`。
🔴 **raw 不在這條分支上**：`.gitignore:74` 的 `doc/audit/**/raw*/*` 把它擋掉，而
`tools/githooks/pre-commit` 會拒絕 raw 出現在 `audit-raw` 以外的分支。十四個 log 全部在
**`audit-raw` 的 `dc0a84d2`**（十四個 live log ＋ 閘門 log），路徑同名 `doc/audit/2026-09-03_fix-ovs4-sflow/raw/`。下面所有
「raw 在 `raw/`」的指涉都是指那裡。
[Co-developed with claude code -- Adam]

## 1. 一句話

`tools/test_workflow/ovs_4host_topo.py` 對十座 bridge 一座都沒設 sFlow，kernel 照常在 `:6343`
聽 ⇒ `ovs4` 上每個流速率與鏈路使用率結構性為零而 API 回 `success`；修法是讓拓樸用
`testbed_topo.py` 那套參數對每座 bridge 設定 sFlow，並讓 `ndt up ovs4` 的驗證會因為「沒在取樣」
而變紅。

## 2. 前後對照（全部 live，raw 在 `audit-raw` `dc0a84d2` 的 `raw/`）

同一台機器、**同一顆 kernel binary**（`a8ba99c2…`）、同一份流量配方。唯一變數是拓樸腳本。

| | BEFORE（`0b3f9796…`） | AFTER（`5f9b4e02…`） | 對照組 `ndt up ovs`（128） |
|---|---|---|---|
| bridge 的 `sflow` 欄 | 十座全 `[]` | 十座各一筆 uuid | 十座各一筆 uuid |
| OVS DB 內 sflow 記錄數 | **0** | **10** | **10** |
| agent／target | 無 | `sN-eth1` ／ `127.0.0.1:6343` | `sN-eth1` ／ `192.168.123.1:6343` |
| header／sampling／polling | 無 | 128／256／0 | 128／256／0 |
| agent 位址 vs 模型檔 | 無 | 十座全中 `192.168.123.11–20` | 同左 |
| `avg_link_usage` 閒置 | 0.0 | 0.0 | 0.0 |
| `avg_link_usage` 負載中 | **0.0**（3000 封包 0% loss 之後仍 0.0） | **0.504371 / 0.505016 / 0.504125 / 0.504305 / 0.504730** | **0.195860 / 0.274391 / 0.255572** |
| 流量停後 | 0.0（本來就是） | 8 s 內回 0.0 | 未量（對照組只跑負載段） |
| `get_detected_flow_data` | `[]` | 有流，`…rate_bps_in_the_last_sec: 208896`、`packet_rate: 256` | 未取 |
| kernel `rate loop` | `flows=0, counters=0` | `flows=1–2, counters=6` | 未取 |
| kernel「no sFlow datagram in 60s」 | **1 次** | **0 次** | 0 次 |
| 新的 `verify_sflow` | **rc=1**，十座逐一點名 | **rc=0**，`10/10 bridges sampling` | **rc=0** |

負載：BEFORE／AFTER 都是 `ping -c 3000 -i 0.01`（3000 封包、0% loss、~33.5 s），AFTER 另加
`iperf3 -t 25`（7.64 Gbits/sec）；對照組 `iperf3 -t 15`（955 Mbits/sec）。

**對照組對帳**：`testbed_topo.py` 檔內註記記著同一對主機（10.0.0.1 → 10.0.0.100，dpid 1 → 4）
讀到 `0.166, 0.256, 0.278`；這次量到 `0.196, 0.274, 0.256`，同一形狀，**更新而非推翻**該筆記錄。

🔴 **兩個誠實但重要的但書**：

1. **`ping` 那段在 AFTER 也會間歇讀到 0.0**（`0.000418 / 0.0 / 0.000313 / 0.0`）。那不是接線問題，
   是取樣率：`sampling=256` 配 100 pps，每座交換機約 2.5 s 才出一個樣本，而回報視窗是 1 s ⇒
   有些視窗合法地沒有樣本。這是刻意沿用 `testbed_topo.py` 的取樣率所致。持續非零的宣稱建立在
   iperf3 那段（五次讀數全在 0.504–0.505），不建立在 ping 那段。
2. **`04_before_traffic_numbers.log` 前半有一個我自己的儀器錯誤，已在同一個檔內更正**：我先打了
   `/ndt/get_all_detected_flows`，那條路由不存在，空白是 404 不是空流表。正確的是
   `/ndt/get_detected_flow_data`，更正後重測仍為 `[]`。**結論不受影響**——它建立在
   `sflow []` ×10、`flows=0, counters=0`、以及 kernel 自己那句警告上。

## 3. 閘門證據

**沒看過紅**：`tests/shell/mutate_ovs4_has_sflow.sh` → `24 mutations, 0 survived`，
baseline byte-identical（`ovs_4host_topo.py` 與 `ndt` 都沒被閘門寫過）。
`check_gate_anchors.py HEAD --gates mutate_ovs4_has_sflow.sh` → **`ok(24)`**（24 個錨點全部讀得到；
finding #28 說的「剛出廠的儀器預設是未被檢查的」在這支上不成立）。

驅動兩套：`tests/python/test_ovs4_sflow.py`（21 檢查，不起 Mininet，mininet 套件被 stub）與
`tests/shell/test_ovs4_sflow_verify.sh`（48 檢查，假的 `sudo`／`ovs-vsctl`／`ip`，不碰實驗室）。

三個方向，缺一不可：

- **缺陷本身**（M1 拿掉 `configure_sflow` 呼叫、M7 agent 介面不給位址、M12 空的 `sflow` 欄讀成正常、
  M18 不檢查 target port）
- **放寬型**——「有設 sFlow 就好」這種檢查會簽掉的形狀：M2 只設九座、M4 每座設兩次、
  M5 設在拓樸不存在的 bridge 上、M16 不再數沒人指向的記錄、M17 一座 bridge 可以掛任意多筆
- **控制組**——反方向：N1 任何 fabric 都設不起來、N2 任何 fabric 都不過、N3 只接受 ovs4 的
  collector 位址（會讓 128 那面誤紅）、N4 沒有 sudo 權限就擋下 bring-up。
  沒有這四個，這支閘門會簽掉一個「誰都跑不起來」的工具。

**開發過程中活下來兩隻，兩隻都指出真缺陷**，寫在碼旁邊：

1. `sflow_query` 為什麼用全域＋暫存檔，而不是 `rows="$(…)"`：命令替換開 subshell，
   `ndt_sudo_capture` 的 `NDT_SUDO_STDERR` 隨 subshell 一起死 ⇒ 每一次拒絕都變成
   `ovs-vsctl did not answer: no message`，**sudo 與 ovsdb 兩個成因被折成同一句**——正是
   `sudo_surface.sh` 存在要防的那件事。
2. 兩次 `ovs-vsctl` 讀取**各自有守衛**：兩個一起失敗時，任一個守衛不見都是隱形的（另一個會走到
   同一個結論）。要看見它，假的 `ovs-vsctl` 必須能**一次只失敗一個查詢**（`FAKE_FAIL_QUERY`），
   而斷言要下在**理由**上不是 exit status 上——`rc=2` 有三條路可以到達，狀態碼的鑑別力比看起來低。

另外 M12／M13／M17 一開始都「活下來」，因為我一開始指定的案例不是**有鑑別力**的那個：
變異確實讓套件變紅，但紅在別的案例上。三個都改指到真正會紅的案例（多半是訊息，不是 rc）。

live 兩個顏色都看過：BEFORE fabric 上 `verify_sflow` rc=1 並逐一點名十座（`03_`），
AFTER fabric 上 rc=0（`07_`），128 fabric 上 rc=0（`11_`，這是 N3 控制組的 live 版）。

## 4. 合併順序與衝突

`git merge-tree --write-tree HEAD <branch>`，全部 **CLEAN**：

| 對象 | 當時 sha | 結果 |
|---|---|---|
| `fix/apps-stop-kills-the-group` | `5c64d432` | CLEAN — ⚠️ **但它還沒有任何 commit**（`git log 5c64d432..` 為空），所以這個 CLEAN 是**平凡的**，不構成「兩支對 `ndt` 的修改不衝突」的證據。它動 `apps` 區塊、我只動 `verify_dataplane` 之後與 `up_ovs` 的 `[4/4]`，文字上不重疊；**它落 commit 之後要重測**。 |
| `integrate/2026-09-03-auditor-merge` | `b466407b` | CLEAN（該分支自 `5c64d432` 以來的 16 個 commit **完全沒有動 `tools/test_workflow/` 或 `tests/`**） |
| `fix/a-4f-sflow-lost-on-power-cycle` | `e9993f9f` | CLEAN（同樣是 sFlow 題但在 kernel C++ 側；本支不含任何 C++ 改動） |
| `fix/cloexec-listening-sockets` / `fix/poll-does-not-resurrect` | `5c64d432` | CLEAN（同樣尚無 commit，同樣平凡） |
| `fix/redirection-order` | `7fdd8971` | CLEAN |

順序：本支可以先合。它對 `ndt` **只增不刪**（production 檔的 diff 是 0 deletions），
新增的是 `verify_dataplane` 之後的一整段函式與 `up_ovs` `[4/4]` 的一行呼叫。

## 5. 回退

三個層次，由輕到重：

1. **只關掉驗證、留下取樣**：把 `up_ovs` 裡 `verify_sflow "$ovs_topo" || rc=1` 那行刪掉。
   fabric 照樣取樣，只是不會因為沒取樣而紅。
2. **只回退拓樸**：`git checkout 5c64d432 -- tools/test_workflow/ovs_4host_topo.py`。
   ⚠️ 這樣做之後 `verify_sflow` 會讓每次 `ndt up ovs4` 變紅（那正是它的工作），所以 1 要一起做。
3. **整支回退**：`git revert` 本支的兩個 commit。無資料庫、無持久狀態要清——sFlow 記錄活在
   OVS DB 裡，隨 `ndt down` 的 `mn -c` 一起消失（實測：`05_`／`09_`／`12_` 三次 teardown 後
   `ports closed … 6343` 全綠）。

**沒有引入任何持久的機器狀態**：`ifconfig` 設在 Mininet 建立的 `sN-eth1` 上，交換機拆掉就沒了。
這是選 `target=127.0.0.1` 而不是照抄 `192.168.123.1` 的理由——後者需要 `ip addr add … dev lo`，
而 `testbed_topo.py` 加了就不收（`11_` 實測那條 alias 在 128 fabric 拆掉後仍在 `lo` 上）。

## 6. 未處理

- 🔴 **`ndtwin-lab` 的 `KERNEL_DIR` 寫死，工作樹無法被它測試**（腳本自己第 26–50 行寫著這件事）。
  所以 AFTER 那一輪是**把修好的 `ovs_4host_topo.py` 暫時放進共用主樹**跑的，跑完按 sha256 還原
  （`01_swap_protocol.log` 記了協定，`13_release.log` 前的檢查確認還原後 `git status` 乾淨）。
  這是本輪唯一一次寫共用工作樹。真正的修法（把樹當參數傳、或每棵樹裝一份）不在本支範圍。
- **`ndt` 的驗證只掛在 `up_ovs`**，沒掛進 `ndt status --check`。一個開起來時在取樣、後來
  sFlow 記錄被清掉的 fabric，`status --check` 不會發現。
- **`SFLOW_PORT` 有三份宣告**（`ndt`、`ovs_4host_topo.py`、`ports.sh` 的 6343 列）。用測試釘住三者
  一致，不是合成一份——`ndt` 不 source `components.env`，要合併得先動那個。
- **對照組沒量「流量停後回落」與 `get_detected_flow_data`**，只量了負載段的形狀；claim 窗內
  另有兩支 agent 在等，優先讓出實驗室。
- **`fix/apps-stop-kills-the-group` 的衝突實測是平凡的**（見第 4 節），它落 commit 後要重測。
- **`avg_link_usage` 的數值語意沒有對帳**：0.504 是什麼的比例（AFTER 的 7.64 Gbps 對上模型宣告的
  1 Gbps 鏈路）本支沒有追。本支的宣稱只到「會動、跟著負載走、停了會回落」，不到「數值正確」。
  finding #10／#18 講的分母問題與 F-8 的宣告容量都還在，跟本支正交。
