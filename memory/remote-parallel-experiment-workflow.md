---
name: remote-parallel-experiment-workflow
description: 遠端機器平行做 NDTwin 實驗的操作步驟——選機/占用檢查、放 key、隔離層、setsid 落盤、snapshot、對帳、記錄產出機；每步標 proven vs planned
metadata: 
  node_type: memory
  type: project
  originSessionId: 103a1748-0691-49d5-b92f-8ab519a66ee0
  modified: 2026-08-31T08:11:44.756Z
---

> # 🔴🔴 2026-08-31 記：**這份流程目前不准執行**
>
> **學姐透過 Adam 明講：「遠端機器先不要用。」** 本檔每一步（含標 ✅proven 的）**一律暫停**。
> 這份文件現在的用途只有一個：**等停用解除時不必從頭想**。不要拿它當「可以開工」的依據。
> 🟢 **要遠端機器？→ `nslab`**（[[nslab-remote-dev-machine]]，08-31 晚間解封；有自己一套
> qemu VM 流程與使用規定，**不走這份**）。🔴 **但 server1~8／cc2 那批仍然停用**——解封條件是
> **學姐本人再說一次**，與 nslab 那次無關。查機器能不能用：`rlab suspended <m>`（**不撥號**）。
> 🔴 **step 0 底下那句「登記＝授權」已被資源的實際主人否決**——見該步的更正框與
> [[remote-testbed-parallel-dev]] 檔頭。解除的唯一條件是**學姐本人再說一次可以**。

# 遠端機器平行做實驗的操作流程（2026-08-30 訂；proven／planned 分標；🔴 現已停用）

**前置認知**：平行化的單位＝一個隔離的 kernel（Mininet/OVS 是全域狀態）⇒ 解法是**隔離層不是換機器**。機器盤點、規格、連線坑見 [[remote-testbed-parallel-dev]]。Adam **無 API key 只有 Max** ⇒ 兩種操作模式：A＝本機 session SSH 遙控（零依賴、已實用）；B＝Claude Code 裝遠端、OAuth 用 Max 登入（headless 給 URL＋貼 code），**所有 session 共用 Max 配額**⇒平行度上限是配額不是機器數，日常走 A、衝實驗波才開 B。

## 每次要用一台遠端機器（steps）

0. **預約（實驗室層，學姐 08-30 指定的慣例）**〔✅ proven〕：Google Calendar 日曆 **`NDTwin Testbed(HPE/New testbed) Reservations`**，id＝`3dce23274aaafea9fdb0d4f9357c2c4e1dfdd716e85dfb03142870fef83402e3@group.calendar.google.com`（Adam 帳號權限＝writer）。**格式無硬性慣例，學姐要求含「名字／使用時間／使用機器」**；我方首例＝標題 `Adam / server8 / NDTwin 實驗`、全天、說明欄寫用途＋**「不會碰排插／交換機設定／別人的機器」**（把自律公開承諾，共用日曆看得到）。⚠️ 兩個工具坑（實撞）：①連接器裝了但 scope 不足會回 `requires additional permissions`——要**中斷重連並確認日曆權限有勾**，不是重開 session；②**建全天事件傳台北午夜會整段前移一天**（它換算 UTC 後截日期）⇒ 傳 **UTC 午夜**（`2026-08-30T00:00:00+00:00`），結束日是**排他**的。網頁 UI 沒這個坑。
   🔑 **兩層預約缺一不可**：日曆＝實驗室層（人看的），`rlab` claim＝session 層（我們自己人看的）。
   🔴🔴 **這一段當天稍晚就被推翻了，逐字留著當教訓**：~~08-30 Adam 裁：「server8 只要 Calendar 有預約到就好」⇒ 登記本身就是授權，不必再等學姐個別點頭。~~
   **同日傍晚學姐透過 Adam 說「遠端機器先不要用」** ⇒ **登記從來就不是授權**，它只是把使用登記給別人看；**准不准用的人是資源的主人**。
   🔑 我照那個裁決把「長跑要先問到人」的前置拿掉並開始動工（部署、preflight、VM 腳本），幾小時後被本人否決。
   ⇒ **可轉移**：**我們對別人政策的內部裁決，是猜測不是政策。** 判準——「這個決定要花掉誰的東西？那就只有那個人能批。」
1. **選機＋占用檢查**〔✅ proven〕：先 **`rlab list`／`rlab status <m>`**（`~/.local/bin/rlab`；claim 檔＝機器上 `~/RLAB-CLAIM`）。🔑 **claim≠measuring、沒人登入≠沒閒**——server1~4 實證：`w` 乾淨但 iperf3 跑了 15 天。深查五件套：`w`＋`loginctl`／`ss -tn|grep :22`／`ps --sort=-pcpu`＋load／`last`／`tmux·screen ls`。共用帳號＋跳板⇒身分不可見；「接下來歸誰」靠 claim（[[lab-claim-handoff-protocol]]），跨組機器**先問學姐**。
1b. **claim**〔✅ proven〕：`rlab claim <m> "<owner=會下指令的 session>" "<note 含用途與人類聯絡人>"`；被拒就換機，不搶。收工 `rlab release`（自動寫 handoff log）。
2. **放 key**〔✅ proven〕：**Adam 自己在終端機**跑 `ssh-copy-id -o ProxyJump=<gw2|gw> serverN@10.10.10.x`（老側跳 gw、新側跳 gw2），密碼他自己輸。🔒 **Claude 不碰密碼、不把密碼值寫進記憶**。放完之後永久免密碼（公鑰進 authorized_keys）。
2b. **bootstrap（每台一次、唯一要 Adam 密碼的動作）**〔✅ server8 流程已備〕：staged 的 `ndtwin-bootstrap.sh`（apt 基礎包＋路徑 sed 過的 `ndtwin-lab` wrapper＋scoped-NOPASSWD sudoers、**不含 p4-power**）→ Adam `ssh -t … 'sudo bash ~/ndtwin-bootstrap.sh'`。之後白名單內全自主；**白名單外／wrapper 更新要再找 Adam（安全設計故意的）**。
3. **隔離層**〔🏁 08-30 Adam 選定路線、腳本已就位、待首跑〕：**qemu＋KVM，不用 libvirt**（少一個 root daemon 在共用機上）。一 VM＝一 lab。工具：`ndtwin-virt-root.sh`（唯一的 root 步：裝 `qemu-system-x86`／`qemu-utils`／`cloud-image-utils`＋把帳號加進 `kvm` 群組；**不碰 sudoers、不加任何 NOPASSWD**）＋ `ndtwin-vm.sh`（create/start/stop/status/ssh/snap/restore/destroy，全部不需要 host root）。
   🔑 **`/dev/kvm` 是 `root:kvm` ⇒ 群組成員資格就是「要不要 root 才能開 VM」的那個開關**；而**群組只對新登入生效**，現有 ssh session 要重連。
   ⚠️ **誠實界線（不要把它講成完整隔離）**：走 **user-mode/SLIRP** 網路 ⇒ guest **在 10.10.10.0/24 上沒有 L2 存在**（不會 ARP、不會被交換機看見、不會意外變成別人實驗的流量端點），**但 SLIRP 是走 host 的 socket 層轉出去的，guest 若刻意連 10.10.10.x 仍然連得到，而且看起來像是從 server8 發的**。硬擋要 tap＋nftables，那是之後的事。
   🔑 **選 VM 而不是裸機的決定性理由不是安全，是「建一次」**：p4 工具鏈 2 小時，建在 VM 裡就能 snapshot 成黃金映像 clone 給每個 lab；建在裸機上將來要一機多 lab 時得再建一次。附帶好處＝p4-guide 的「半安裝之後再跑會回報成功」陷阱在裸機上是永久的，在 VM 裡是一次 rollback。
   資源：host 15Gi ⇒ 給 guest 8Gi／12 vCPU（32 核裡留餘裕），disk 120G（host 空 1.6T）。
3b. **開跑前先把「會浪費幾小時」的那個未知用幾分鐘測掉**〔✅ proven 08-30〕：p4 工具鏈要建 2 小時，而它最可能死的地方（p4-guide 的 patch 對 behavioral-model **移動中的 HEAD** 過期）可以用 `git clone` ＋ `patch -p1 --dry-run` **兩分鐘**答完（腳本 `p4_patch_preflight.sh`，staged 在 server8）。🔑 **一定要帶控制組**——同時測已知會失敗的 v10；v10 若突然通過，錯的是儀器不是世界。（第一版腳本就壞在假設 patch 在 `bin/`、實際在 `bin/patches/`，而它**報 INCONCLUSIVE 沒報綠燈**＝[[injections-must-assert-their-own-success]] 的正面例。）
   🔑 通則：**長建置的失敗點通常在前 10%，而且可以離線先問。**
3c. **root 面是硬邊界，要先盤點再開工**〔🔴 08-30 實撞〕：白名單只有 `ndtwin-lab`＋`ovs-vsctl`/`ifconfig`/`mnexec`/`tc` ⇒ **`apt` 不在裡面**，任何「裝套件」的一步都會卡住。而 p4-guide 自己整段都在 `sudo apt` ⇒ 2 小時的建置**不可能靠現有白名單跑完**。⇒ 開工前先問「這條路上哪幾步要 root」，不要走到一半才發現。`rlab` 新增 `note` 動詞（就地修正 claim 的條件，不用假裝交接）。
4. **部署**〔⚠️ 連外已驗、整流程未走〕：VM 內 `git clone` NDTwin-Kernel（遠端連外✅）、建 venv/.plotvenv、跑既有 `ndt` 生命週期（`ndt up` 不重編 .p4、每指令帶 `NDT_OWNER`、包 `setsid`，見 [[ndt-one-command-lab-lifecycle]]）。
5. **跑實驗**〔✅ 紀律 proven〕：長跑一律 `setsid`＋落盤（斷線／`/compact` 不死，[[evidence-must-outlive-the-handoff]]）；script **self-contained**、決策規則預先寫進去（＝預註冊紀律同構，[[prereg-amendment-before-data]]）。
6. **觀測**〔✅ proven〕：**拉式**（讀遠端 log 檔）不靠推；重連第一件事**對帳**（job 在不在、log 走到哪），不假設還活著。
7. **snapshot／防重開**〔⚠️ planned〕：每波風險實驗前做 VM snapshot，炸了 rollback（破壞性指令在 VM 上第一次變便宜，對照 [[destructive-shell-traps]]）。🔴 **真殺手是機器被智慧 PDU／unattended-upgrades 重開**（cc2 08-29 23:42 已示範），比網路斷更該防 ⇒ **可重入 script ＞ snapshot ＞ 網路韌性**。
8. **記錄產出機器**〔✅ 紀律 proven〕：每個結果標「哪台機器／哪台 VM」；要進報告的**效能數字仍釘單一指定機器**（VM 與共機都自帶噪聲，[[benchmark-must-name-the-binary-it-measured]]、[[vm-on-this-machine-is-invisible-to-ndt-status]]）。平行化的是開發與功能性實驗，不是效能量測。
9. **收工**〔✅ proven〕：release＋寫 handoff（[[lab-claim-handoff-protocol]]）。

## 給 Claude 自主權的安全邊界〔⚠️ planned〕

Claude 跑在 VM 內拿 root（爆炸半徑＝該 VM，host 碰不到）；**不持有任何實驗室憑證**（不拿 gateway key／Adam 的 `id_ed25519`／表格密碼），只有 Max OAuth；VM NAT-only＋擋 10.10.10.0/24 內網；CPU/RAM/disk 上限；每波 snapshot。Adam 觀看＝ssh 進 VM attach。
