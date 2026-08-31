---
name: ndt-one-command-lab-lifecycle
description: "`ndt up` / `ndt down` 一行開機收機;含 claim 查用法、NDT_OWNER 每個指令都要帶、claim 擋不住裸指令;🆕 08-25 新增 handoff 機制(status 顯示、claim 使其失效)、🔴 `ndt up` **不會**重新編譯 .p4"
metadata:
  node_type: memory
  type: project
  originSessionId: ead7700c-55b2-4730-a1f9-4bdd2b99ee33
  modified: 2026-08-31T06:16:11.447Z
---

2026-08-20 建,08-21 大幅改。`tools/test_workflow/ndt`,symlink 在 `~/.local/bin/ndt`。
**已 commit**(`c8d73a5` 起,到 `957a646`)。

```
ndt up [p4 [n] | ovs | ovs4]   ndt down [--force] [--deep]   ndt status [--check]
ndt clean   ndt check   ndt apps   ndt ntg   ndt claim [分鐘] [note]   ndt release
```

## 🔑 誰在用實驗室:查就好,不必問別的 session

```bash
ndt status        # 第一行就是 claim:自己的 / 別人的名字 / EXPIRED / none
```

四種狀態措辭刻意不同(過期的不會讀起來像活的),相對時間在前絕對時間在括號。

**但守衛有兩個縫,都實際發生過:**

1. 🔴 **`NDT_OWNER` 每個指令都要帶,不只 `claim`。** 沒設時**任何 claim 都算別人的**
   (安全預設)。mainDev 08-21 踩到:自己 claim 完直接 `ndt down`,被自己擋下來。
   拒絕訊息已改成**先講 `NDT_OWNER` 再講 `--force`** —— 舊訊息只給 `--force`,照做會
   拆掉真的有人在用的實驗室。
2. 🔴 **claim 只擋 `ndt` 的動詞,擋不住裸指令。** 我自己繞過去過一次(直接跑
   `./bin/ndtwin_kernel` 在別人視窗裡種了一個 kernel)。**是約定不是鎖。**

撞車的真正機制是 **`.test_run/pids/` 是共用註冊表而且沒有 owner 欄位**,claim 就是補那一欄。

## 實測時間(2026-08-21)

| | 時間 |
|---|---|
| `ndt up`(P4 128 host) | **35-40 s** |
| `ndt up ovs`(128) | **25 s**(原本 73 s,見 [[ryu-startup-costs-measured]]) |
| `ndt up ovs4` | 10-15 s |
| `ndt down` | 13 s |
| `ndt status` | 0.73 s |

## 它擋掉的錯(每個都對應實際事故)

- **`TOPO_P4` 從 host 數推導**,忘不掉。
- **拓樸模型 = fabric 的來源**:Mininet 接線改讀 JSON(`topo_from_json.py`),
  取代三份字面 `addLink`。切換前用等價閘門證明衍生接線與字面**逐項相同**。
- **重用要 host 數也對**:只數交換機等於沒判斷(每個 P4 拓樸都 10 台)。
- **`ndt up ovs <N>` 只有 4 和 128**,其他直接拒絕 —— OVS 兩個尺寸都不是參數。
- **verify 會真的送封包**(`mnexec -a <host-pid> ping`)。拓樸視圖全對而網路完全不通
  發生過兩次,只有封包抓得到。
- **pipeline 過期偵測**、**量測進行中拒絕拆**(`in_flight`)。

## `ndt down` 現在會自證身分(08-21 修)

- `stop_one` 殺之前比對**行程啟動時間 vs pidfile 寫入時間** —— 被回收的 pid 一定晚於
  pidfile 才啟動。名字和 argv 都比不了(每個服務都是 wrapper `exec` 過去的)。
- `app_stop` 拒絕 symlink pidfile。
- `in_flight` 只認 `iperf3 -c`(閒置 server 不再擋 teardown)。
- **手動起的東西預設不碰**,`--deep` 才殺(Adam 裁決)。

⚠️ **`ndt clean` 仍不看 veth / OVS bridge / netns / `tc netem` / `.test_run/`。**
正常路徑上 `mn -c` 會清掉前四項(實測 0/0/0/0),但 clean 不斷言它們。

**中斷 teardown 的實測結果**:SIGINT 打在 `[2/3]` → `ndt` 被 signal 2 殺掉、
kernel/proxy 已停、**fabric 完整留著**(不是半毀)、`ndt clean` **正確報 not clean rc=1**、
再跑一次 `ndt down` 完全復原。**比我預測的好** —— 我原本以為會半毀然後被報成 clean。

## 環境變數(全部可選)

`NDT_OWNER` / `NDT_TOPO` / `CONVERGE_WAIT` / `NDTWIN_P4_TOPO_FILE`(要與 host 數一致,
否則拒絕) / `NDTWIN_RYU_TOPO_FILE` / `NDTWIN_RYU_SWITCH_NUM` / `NDTWIN_RYU_SETTLE_S`。

## 測試檔(都在 `tools/test_workflow/`)

`test_topo_from_json.py`(接線等價)、`test_ndt_lab_session.sh`(14 條)、
`test_topo_model_guards.py`(模型壞掉的守衛)、`test_teardown_guards.sh`(14 條,
把 `PID_DIR` 導到暫存目錄,**跑它不會干擾使用中的實驗室**)。

每一份都先看它失敗過才收下。

盤點與全部證據:`doc/audit/2026-08-20_lab-bringup-inventory/INVENTORY.md` §8。
相關:[[destination-paths-not-monotonic]]、[[p4-128-hosts-four-hardcoded-lists]]、
[[shell-outs-need-timeouts]]、[[ryu-startup-costs-measured]]。


## 🆕 2026-08-25:`.test_run/lab.handoff` 交接機制(`ffdca1b` + `0d45a89`)

**解決的問題**:有人 release 了 claim 但**刻意留著 fabric**(P4 重建一次 35-40 s,留著對下一個人是淨賺),
於是 `status` 說 `claim none` 而十台 bmv2 都在跑 ⇒ **Adam 變成那個要判斷的人**。
兩個 session 談定約定,Adam 裁定由我改共用工具。全文見 [[lab-claim-handoff-protocol]]。

- **`ndt status`** 在 claim 為 none 或已過期時,顯示 `.test_run/lab.handoff`(by/at/fabric/topology/note)
  ＋ 一行「沒有 claim ⇒ lab 可用,包含這個 fabric,要拆就拆」。
  **有效的 claim 會壓掉它**(兩個聲音回答同一個問題,而錯的方向是對著別人在跑的 fabric 說「可以拆」)。
- **`ndt claim` 成功時把 handoff 改名成 `.handoff.prev`**。刪除綁在「承擔責任」而不是「讀取」。
- **`release` 不自動寫** — 自動註記只能寫工具推得出來的,而有用的那半(「可以拆」vs「跑到一半別動」)推不出來。
- 寫法:
```bash
printf 'by=%s\nat=%s\nfabric=up\ntopology=%s\nnote=%s\n' \
  "<owner>" "$(date -Is)" "p4 128" "可直接拆" > .test_run/lab.handoff
```
- 測試 `tests/shell/test_lab_handoff.sh`(18 條、突變全殺、在沙箱跑真腳本不碰共用 `.test_run`)。

## 🔴 08-29 實測：**`ndt down` 和 `ndt up` 會殺掉呼叫它們的 shell**

工單 ① 要在兩顆 bmv2 build 之間來回切，所以一晚跑了六次 `ndt down` + `ndt up`。
**前兩次我直接呼叫，兩次都拿到 `exit 144`**，而且是我的 shell 死掉、不是 `ndt` 失敗：

- **teardown 本身完全成功**（bmv2=0、kernel=0、namespace 清掉、`.test_run/` 完好、claim 完好、raw 完好）
- **`ndt up` 也一樣**：包 `setsid` 之後跑完並印出 `up. ready`，fabric 正常

⇒ 這**不是** `pkill -f` 自殺（[[destructive-shell-traps]] 那一族），我這次一個 `pkill` 都沒下。
**是 `ndt` 的 teardown 掃到了呼叫端所在的行程群組。** 兩者症狀相同（exit 144）但成因不同，
⇒ **`exit 144` 之後一定要複驗 fabric** 這條照樣適用，但**不要據此推論「我又用了 pkill」**。

**繞法（已驗證，`drive_p1.sh` 裡每個 ndt 呼叫都這樣包）：**

```bash
setsid env NDT_OWNER="$NDT_OWNER" ndt down > down.log 2>&1
setsid env NDT_OWNER="$NDT_OWNER" ndt up   > up.log   2>&1
grep -q '^up\. ready' up.log || { echo "🔴 not ready"; exit 1; }
```

🔑 **驗收要看 log 裡的 `up. ready`，不要看 rc** —— 呼叫端可能已經死了，rc 讀不到。
**沒有 `setsid`，任何「切 build → 重建 → 跑臂」的 driver 會死在第一次切換**
（跟 ③ 的 pass B 死在 `/compact` 是同一個死法，見 [[evidence-must-outlive-the-handoff]]）。

📌 **切 build 的機制**：`p4_proxy/mininet/bmv2_binary_override`，第一個非註解行勝出、必須絕對路徑、
**沒有 fallback**（刪掉或全註解 ⇒ 拓樸拒絕啟動）。fast = `/usr/local/bmv2-fast/bin/simple_switch_grpc`、
stock = `/usr/local/bin/simple_switch_grpc`。
⚠️ 用腳本改它的時候**保留註解、只換最後那行**，而且改完要比對 `git diff` ——
我的 python 改寫每切換一次就多留一行空白，四次累積四行，差點把漂移 commit 進去。

## 🔴 `ndt up` **不會**重新編譯 `.p4`

改了 `p4_proxy/p4_src/ndtwin_switch.p4` 之後 `ndt up` 重建 fabric,**跑的還是舊 pipeline**。要:
```bash
p4c-bm2-ss --arch v1model -o p4_proxy/p4_src/build/ndtwin_switch.json \
  --p4runtime-files p4_proxy/p4_src/build/ndtwin_switch.p4info.txt p4_proxy/p4_src/ndtwin_switch.p4
```
**然後還要 `ndt down` + `ndt up`,bmv2 才會載新的。** 三層驗法見 [[injections-must-assert-their-own-success]] 第五式。

## 🆕 08-30 兩個 T-4 實測發現（正本＝live-full-stack-round 的 FINDING-01／BASELINE-PROVENANCE）

- 🔴 **`model matches fabric` 永遠不可能失敗**：`ndt:709-723` 的兩邊都來自模型（kernel 的圖 vs 餵進去的
  JSON），fabric 從頭到尾沒被讀過；`:759-760` 早記著 08-21 OVS 側同型假通過而四行外的註解沒改。
  **T-8 已開**：改比 fabric 實讀、雙向逼紅驗收。在修好前，`ok model matches fabric` 一個 bit 資訊都沒有。
- 🔴 **`/usr/local/sbin/ndtwin-lab:25` 寫死 `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel`**（root 所有、
  與 repo 版同 hash 但 export 搆不到）⇒ 從 worktree 測基線時 fabric 永遠是主樹的 128 台；
  解法＝兩棵樹都放 `p4_proxy/mininet/host_count_override`（tracked 檔！用完要還原並驗 git status 乾淨）。
- 🔴 **`ndt up ovs` 跑的 topo 是 NTG repo 的 `testbed_topo.py`**（`ndtwin-lab:83`），
  **kernel repo 的同名副本不是它讀的檔**——08-30 OvS 對照輪整輪 patch 打在副本上＝no-op 的肇因。
  要改 fabric 形狀，先 `grep` `ndtwin-lab` 確認它到底讀哪個檔。
- 🏁 **08-30 深夜 T-8 已合併生效**（`1208d22`；`ndt` 走 main-tree symlink 即生效）：
  `model matches fabric` 改讀 fabric 實數、讀不到＝紅；`app_running` 改 /proc+cmdline；
  handoff 欄位格式修正後 `ndt status` 讀得出交接。**`ndtwin-lab` 已由 Adam sudo 重裝**
  （hash `288b71cb` 兩側一致）：非 root 直呼＝拒絕 rc=1（tmux per-uid 之故——手打要加 sudo）、
  sim 有磁碟 log。KERNEL_DIR 寫死＝保安設計（env override 是提權向量、agent 拒做對）→ T-14 設計票。

## 🔴 08-30 深夜：**worktree 不能透過 `ndtwin-lab` 測——而且失敗是無聲的**

⚠️ **名字會撞**：`ndtwin-lab` 有兩個意思——GitHub org（`ndtwin-lab/NDTwin-Kernel`）、
以及**一個 root-owned 的腳本檔** `tools/test_workflow/ndtwin-lab`
（裝在 `/usr/local/sbin/ndtwin-lab`、NOPASSWD sudo 叫用）。**這條講的是後者。**
它是**檔案不是目錄**——我找它的時候搜 `ls -d ~/ndtwin-lab` 就漏掉了，
會找到的是 `git ls-files | grep ndtwin-lab` 或 `ls /usr/local/sbin`。

**`KERNEL_DIR` 依權限層分岔，兩邊都是對的**（親讀，08-30）：

| 層 | 行為 | 理由 |
|---|---|---|
| **user**（`components.env:16` 的 `: "${KERNEL_DIR:=…}"`、`ndt`、`stack.sh`） | **接受** override | by design，換一個 checkout 不用改任何檔 |
| **root**（`ndtwin-lab:51` 寫死） | **拒絕、且刻意不可覆寫** | wrapper 以 **root** 執行 `$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py` |

檔頭 `:26-49` 自己把「用 env 覆寫」這條路封死了，原話值得記：
**「override 在安全的地方無效（sudo `env_reset` 會丟掉變數）、在有效的地方是提權
（任何 adam 行程都能把 root 指向任意 adam 可寫的 `.py`）——both halves are bad」**。

🔴 **代價已經量過（FINDING-01）**：有一輪把 kernel 釘在獨立 worktree、export 了 `KERNEL_DIR`，
於是 `ndt`／`stack.sh`／`components.env` 全都聽話——**而 `ndtwin-lab` 在那個變數搆不到的地方，
跑了主樹的 `ntg_bmv2_topo.py` 與它的 `host_count_override` 128**，同時 `ndt up p4 4`
把 4 寫進 worktree 的副本、餵給 kernel 一個 4-host 模型。
⇒ **fabric 128、model 4、每一項結構檢查全綠、沒有任何訊息說兩半不一致。**

🔑 **被尊重的那個 override 正是造成撕裂的東西。** 一個完全忽略 `KERNEL_DIR` 的工具會**一致地**錯、
而且顯眼；**在五個地方尊重它、第六個地方不尊重**，做出一個一半 A 樹一半 B 樹、
**而且通過自己所有檢查**的 stack。⇒ 部分生效的設定比完全不生效危險。

⇒ 現行唯一緩解是檔頭那句註解：**A WORKTREE CANNOT BE TESTED THROUGH THIS SCRIPT.**
設計票＝`doc/audit/2026-08-30_a7-dispatch-visibility/T-14_multi-tree-support.md`
（(c) 大聲拒絕＝比對自己寫死的樹 vs 呼叫端 `git rev-parse --show-toplevel`，最便宜、
會把 FINDING-01 從無聲撕裂變成第一個指令就報錯；(a) 位置參數＋allowlist＝真解，
⚠️ 但「root-owned」當判準不夠——root 擁有的**目錄**下放一個 adam 可寫的 `.py` 照樣是任意碼，
檢查要落在**被執行的那個檔**）。
相關：[[worktree-agents-branch-from-origin-main]]、[[cross-repo-component-ecosystem]]。

## 🔴 08-31：**活過自己 pidfile 的 app，在每一個 `ndt` 介面上同時是隱形且殺不掉的**

live 實證：前一 session 的 `Traffic-Engineering-App` 活了 **20 h 32 m**（PID 286700、起於
08-30 15:07、`UnboundLocalError` 崩潰迴圈、往 `app_te.log` 灌了 **100 MB**），而同時：
`ndt status`＝`apps none running`、`ndt apps`＝`te -`、**`ndt apps stop te` 回 rc 0
「te not running」**。成因＝`app_stop` 只看 `.test_run/pids/app_te.pid`，pidfile 不在就全盲。
⇒ **它會裝流表規則，kernel 一起來就污染量測**（那輪的 A-4e/B-2c 差點被它汙染）。
- **查法**：不要靠 `ndt`／不要 `pgrep -f`——列 `/proc/*/cmdline` 比對後按 **PID** 停。
- **交接的盲點會被繼承**：前一份 handoff 寫「nothing of mine is running」是照 `ndt` 寫的，
  而 `ndt` 看不到它 ⇒ **handoff 的可信度上限＝它所用工具的可見度**。
- 修票待開（`stop` 要有三態：running／not-running／**pidfile-lost-but-alive**）。
崩因本身是 **Traffic-Engineering-App repo 的缺陷**（`get_graph_data_api_call` 在 except 之後
`return graph_data` 而該變數未賦值），excerpt 存在
`doc/audit/2026-08-31_live-recipes/te-crashloop-excerpt.txt`。
