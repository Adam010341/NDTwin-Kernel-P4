# 待辦工作項目

Adam 交辦、但還沒有 session 在做的事。**這個 build 沒有 `TaskCreate`／`TaskUpdate`**（工具集裡不存在），
所以待辦放在這裡，不放在某個 session 的腦裡——那樣 Adam 看不到，session 一結束也就沒了。

一件事開工之後，把它從這裡移到它自己的分支／文件，並在這裡留一行指過去。

[Co-developed with claude code -- Adam]

---

## W-1 — 在 NDTwin 上跑 p4lang/tutorials 的 exercise 1–5

**來源**：教授交辦，Adam 2026-09-03 轉達，並指定「你自己決定什麼時候做」。

**材料已經在機器上**：`~/tutorials`（p4lang/tutorials，13 個 exercise）。不需要重新 clone。

### ✅ Adam 15:xx 已釐清（原本的兩個問題都答了）

- **「1–5」＝五個主題群，共 13 個 exercise**，沒有期限。
- **目的不是跑 tutorial**：教授知道那只是量 p4lang 的東西。要測的是 **NDTwin 能不能在不同的 `.p4` 檔下正常橋接它們的 p4info**。
- 分析（auditor 15:xx）：我們的 `ndtwin_switch.p4` 的 `ipv4_lpm` 就是 p4lang `basic.p4` 那張表加 `send_to_cpu`，proxy 寫死查
  `MyIngress.ipv4_lpm`。⇒ **8 個 exercise**（basic／ecn／qos／mri／firewall／link_monitor／basic_tunnel／p4runtime）路由橋得過去、
  但**沒有 CPU port／`send_to_cpu`／clone session** ⇒ LLDP 與 sFlow 全滅——要測的是 NDTwin 會說「看不到」還是回報一個健康的空網路；
  **5 個**（flowcache／calc／load_balance／multicast／source_routing）連 `ipv4_lpm` 都沒有 ⇒ 第一個量測：proxy 在 p4info 找不到表時做什麼。
  建議順序 `source_routing`（沒有表，最快炸）→ `basic`（基線）→ `flowcache`（與 idle-timeout 已知缺陷重疊）→ `p4runtime`（參照 controller）→ 其餘。

### （原問題留底）「1–5」是哪五個

`~/tutorials/README.md` **不是平面編號**，它分成四個主題群。照 README 由上而下取前五個是：

| # | exercise | 主題群 |
|---|---|---|
| 1 | `basic`（Basic Forwarding） | 1. Introduction and Language Basics |
| 2 | `basic_tunnel`（Basic Tunneling） | 1. 同上 |
| 3 | `p4runtime` | 2. P4Runtime and the Control Plane |
| 4 | `flowcache` | 2. 同上 |
| 5 | `ecn` | 3. Monitoring and Debugging |

⚠️ 教授說的「1–5」也可能是指**第 1 群到第 5 個主題**、或課程投影片自己的編號。
**開工前先跟 Adam 確認一次**，這是唯一會讓整件事白做的分歧。

### 🔴 開工前一定要知道的四件事（不要重新踩一次）

正本：記憶 `p4lang-tutorials-as-local-control.md`（2026-08-13 實際用過）。

1. **exercise 目錄裡的 `.p4` 是編不過的填空骨架。** 完整版在各自的 `solution/`。
   要「跑起來」用的是 `solution/`，要「當練習做」才用骨架。
2. **教學拓撲（2–4 台）與我們的 topology JSON 不相容。** 這是整件事最大的一個決定，見下。
3. **它的 `utils/p4runtime_lib/` 對 bmv2 會卡死**：`MasterArbitrationUpdate()` 等回應，
   而 bmv2 對重複 election id 是直接殺 stream ⇒ 永遠等不到。要繞過它的 stream 封裝手寫低階 gRPC。
4. **它需要 `p4.tmp`，我們的 venv 沒有**——用 `/home/adam/p4dev-python-venv/bin/python`。

### 要 Adam 裁的：「在 NDTwin 上跑」是哪一層

這句話有兩個差很多的讀法，成本與產出都不同：

- **(a) 只跑 bmv2 管線本身**：用 tutorial 自己的 `make run`／Mininet，我們只提供機器與 bmv2 build。
  便宜、幾乎一定跑得起來，但**沒有用到 NDTwin 的任何東西**——證明的是工具鏈能用，不是孿生體能用。
- **(b) 讓 NDTwin kernel 管理它們**：要把每個 exercise 的拓撲翻成我們的 topology JSON、
  接上 p4_proxy、讓 kernel 認得那些 pipeline。**這才是有意義的那個**，但每個 exercise 的
  pipeline 不同（不同 table、不同 action），我們的 proxy 目前只認 `ndtwin_switch.json` 的表結構。
  ⇒ 這是一件**每個 exercise 都要單獨接線**的工作，不是跑五次同一個腳本。

**我的建議**：先做 (a) 把五個都跑通並存下 raw（成本低、而且是 (b) 的對照組——
沒有 (a) 的話 (b) 失敗時分不出是我們的問題還是 exercise 的問題），
然後只挑 **`basic`** 做 (b)，把「接一個外來 pipeline 進 NDTwin 要做哪些事」寫成一份可重複的清單。
五個都做 (b) 之前先讓 Adam 看那份清單的成本。

### 需要實驗室

(a) 與 (b) 都要起 Mininet／bmv2 ⇒ **不能在 Adam 需要實驗室的時段做**。開跑前 claim。

---

## W-2 — finding #6／#48：`ndt apps stop` 停不掉 viz（✅ 修法已進 trunk `94abfb3f`；真 app 未驗）

2026-09-03 13:1x Adam 本人現場撞到：`ndt apps stop` 之後 visualizer 仍在跑。
**`fix/g6-ndt-apps-liveness` 不修這個**（已查證，見 `AUDITOR-VERIFICATION.md`）——
它改善的是「回報有沒有在跑」，而 `app_spawn` 仍是 `( cd "$dir" && exec nohup "$@" ) &`，
**沒有 `setsid`、沒有自己的 process group**，`app_stop` 仍只對單一 pid 送 TERM。

修法形狀：`app_spawn` 加 `setsid`（或 `systemd-run --user`），停止時殺**整個 process group**，
並且停止之後用**獨立管道**確認（`/proc/<pid>/fd` 反查誰開著它的 log，比 pidfile 可靠）。

🔴 **連帶**：`.test_run/logs/app_viz.log` 在 09-03 長到 **364 MB**（每一幀一行 DEBUG），
根目錄一度到 98%。09-02 同一個機制長到 875 MB 塞爆磁碟。**log 要有上限**，這是同一張工單的一部分。

### ✅ 19:1x：已進 trunk `94abfb3f`（`fix/apps-stop-kills-the-group @ 850a6ea8`）——下面五條殘留仍然成立

- **做了**：`app_spawn` 走 `exec setsid nohup`，啟動後讀 `/proc` 驗 pgid==sid==pid 並寫 `.pgid`；`app_stop` 先 `kill -TERM -<pgid>` 整個 group、再補個別 pid、再補「log 的可寫 fd 持有者」找到的殘存；
  「停掉了」要過 `app_verify_stopped`（group／log fd／port 三管道皆空），看不到的管道明說「不是沒有，是沒看到」（rc 2）；
  `apps orphans` 用同一組管道（09-02 那個狀態從 rc 0 變 rc 1）；log 改 `>>`、兩代輪替、`status` 印大小＋256 MB 轉黃、新增 `ndt apps trim`。
- **證據**：測試 71 checks（修法前 45 紅）、閘門 13/0（8 缺陷向＋5 放寬向控制組，含「對自己的 group 送訊號」）；auditor 丟棄式樹重跑：71/0、鄰居 52/44/29 全綠、兩支閘門在跑。
- **🔴 沒做／要接的**（可另開工單）：
  1. `energy`／`sim` 走 `ndtwin-lab` 的 tmux，**沒有自己的 group**（要改 root 端 `ndtwin-lab`），這次只加了停止後的獨立驗證（含 sim 的 `:9000`）。
  2. **沒在真 app 上跑過**（viz 要顯示器）；最便宜的真機驗證是 `ndt apps start sim` → `stop`，順便驗 `:9000` 管道——要一段有實驗室的時間。
  3. log **沒有硬上限**（只有輪替＋警告＋手動 `trim`）；理由寫在 FIX-APPS-STOP §6.1（中介行程會弄壞 fd 管道）。
  4. `ndt down` 仍把 `app_stop` 的輸出丟到 `/dev/null` ⇒ 殘存者名單不進 teardown log。
  5. `apps orphans` 新增 rc 2，呼叫端（`||` 閘門）沒有盤點。

---

## W-3 — finding #3：失敗的 `ndt up` 不回滾（沒有人在修）

`ndt up ovs4` 失敗後 Ryu（:8080/:6633/:6653）、tmux topo session、15 個行程／36 條 veth 全留著，
而沒有 kernel。`:8000` 被佔用的檢查在 `stack.sh` 的 [3/3]，**在 fabric 建好之後**。
證據：`round1-ovs/02_ndt_up_failure_leaves_fabric_running.log`（對照組 `03_`）。
同事線把它列為 BUG-3，未查證。需要實驗室才驗得完。

## W-N11 量測：一條規則裝進 bmv2 要多久（對帳 rule journal 的 6.37 ms fsync）

Adam 裁（09-03 21:1x）：journal 現況不動，先量。要量的是 REST `/stats/flowentry/add` 一筆從進 proxy 到 gRPC table write 回來的 per-rule latency（bmv2、`ndt up p4 4`），與 `RuleJournal.record` 的 6.37 ms（`RED_before`＝stub fsync 0.027 ms）並列；若 gRPC write 本身 ≥ 6 ms，fsync 的 150 rules/s 上界不是瓶頸、N11 ①結案；若遠小於，再回 N11 裁批次 fsync。要 lab（P4），排在 #77／#8 兩支之後；raw 進 audit-raw；報告寫進 `doc/audit/2026-09-03_fix-rule-journal/` 的補記或新 dir。狀態：⭕ 未派（09-03 21:1x）。

## W-Q12 `is_up` 拆成 `admin_state`＋`reachable`

Adam 裁（09-03 21:1x）：(a)。派 `fix/is-up-split-admin-state-reachable`。狀態：🛠 派工中（09-03 21:1x）。
