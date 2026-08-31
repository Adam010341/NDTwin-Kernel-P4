---
name: remote-testbed-parallel-dev
description: 用實驗室遠端機器平行開 NDTwin 實驗室——盤點已完成（cc2/gw2 規格、server5~8 活著等 key、舊 testbed 下線）、Claude Max 無 API key 的兩種操作模式、安全權限架構
metadata: 
  node_type: memory
  type: project
  originSessionId: 5122420e-3c16-40da-88b7-1913057e848f
  modified: 2026-08-31T08:11:39.953Z
---

> # 🔴🔴 2026-08-31 記：**遠端機器全線停用，不要開工**
>
> （時點：學姐的話由 Adam 轉達，**在 08-30 16:10 那個「登記＝授權」裁決之後**——`rlab` claim 的時戳可證；
> 確切時刻我沒記錄，所以只寫得出這個區間。⚠️ 我第一次寫這段時把它標成「08-30 傍晚」，**那是沿用上一段對話的日期沒重新確認**。）
>
> **學姐透過 Adam 明講：「遠端機器先不要用。」** 這句話**蓋過本檔與 [[remote-parallel-experiment-workflow]]
> 裡所有「已解封 / 可以開跑」的記載**（那些是同一天稍早寫的，寫的時候這句話還不存在）。
>
> ## 🟢 那要用哪一台？→ **`nslab`**（[[nslab-remote-dev-machine]]，08-31 晚間解封）
>
> 有自己一套 qemu VM 流程與**使用規定正本**
> （`doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`），**不走這份**。
>
> 🔑 **這一格 08-31 一天之內改了三次，沿革本身就是教訓**：
> ① 最初只寫「不行」沒寫「那要用哪台」⇒ 兩個 session 讀完仍以為遠端＝開 server1~8
>   （**禁令沒附替代路徑，讀的人會自己重推回被禁的那條**）；
> ② 下午 nslab 也暫緩 ⇒ 改成「**沒有替代機器，問 Adam**」（明寫「沒有」比留過期指路安全）；
> ③ 晚間 nslab 解封 ⇒ 就是現在這格。
> ⇒ **一份「不行」的文件，它的指路格會過期得比它本體快**——本體（server1~8 停用）三次都沒變。
>
> 🔴 **server1~8／cc2／gw／gw2 仍然停用**，解封條件是**學姐本人再說一次**，
> 與 nslab 那次（Adam＋規定落地）**完全無關，不要互相推論**。
> 🔧 08-31 起這件事**已經機械化**：`rlab` 內建 suspension 表，對停用機器**連都不連**就 refuse，
> 並印出「誰說的／什麼時候／解封條件」。解封要改那支 script（留得下 diff），沒有環境變數旁路。
>
> ### 🔴 停用時 server8 上留下了什麼（Adam 要問學姐「要不要拆」時用得到）
>
> 程式碼樹約 1.9 G（`.git` 已移除，有 `DEPLOYED_FROM` 戳記 commit `3964f4c`）／bootstrap 裝的
> mininet・OVS・tmux／**`/etc/sudoers.d/ndtwin-lab` 那七行 scoped NOPASSWD**／家目錄幾支腳本／
> `~/p4-preflight/` 的 p4-guide＋behavioral-model clone。**qemu 那一步從沒跑過**（沒有 VM、沒動 kvm 群組）。
> ✅ `~/RLAB-CLAIM` 已於 **08-31 14:39** 用 `rlab note` 就地改註 SUSPENDED，明寫「Calendar 登記不是授權」。
> 🔴 **但 Google Calendar 上那則 `Adam / server8 / NDTwin 實驗`（8/30–9/5）還掛著**——
> 佔著一個我們不能用的預約對別人是誤導，**要刪要縮是 Adam 的決定（共用日曆＝對外動作）**，未處理。
>
> - **不要**在 server1~8／cc2 上跑任何實驗、建置、長跑。
> - **不要**因為「Calendar 上有登記」就認為可以用——**那個推論已經被本人否決**（見下面「教訓」）。
> - 既有部署（server8 的程式碼樹、bootstrap 裝的套件、scoped sudoers）**沒有被要求移除**，
>   但也**沒有被許可繼續使用**。要不要拆掉是 Adam 要問學姐的，不要自行決定。
> - 「先」＝暫時。**解除停用的唯一條件是學姐本人再說一次可以**，不是時間到、不是我們判斷沒影響。
>
> 🔑 **教訓（可轉移）**：**「登記＝授權」是我們對別人政策的猜測，不是政策本身。**
> Adam 08-30 下午裁「Calendar 有預約到就好」，我照著把長跑前置條件拿掉、開始動工；
> 幾小時後資源的實際主人給了相反的答案。**內部裁決可以決定我們怎麼做，不能決定別人的資源歸誰用**——
> 對別人的東西，許可只能來自那個人。同型見 [[rescinded-orders-invalidate-damage-assessment]]。

# 遠端 testbed 平行開發（2026-08-30 盤點完成，🔴 現已停用）

**動機**：一台機器同時只能開一個 NDTwin 實驗室（Mininet netns／OVS datapath 是 kernel 全域的）⇒ 平行化最小單位＝一個 kernel。🔑 **解法是隔離層（VM/netns/container），不是換機器**——多人共一台裸機照樣撞。
**憑證約束**：Adam **沒有 Anthropic API key，只有 Claude Max** ⇒ 模式 A＝本機 session SSH 遙控（零依賴、已實用）；模式 B＝Claude Code 裝遠端、OAuth 用 Max 帳號登入（headless＝URL＋貼 code；憑證在 `~/.claude/`，VM 黃金映像登一次 clone 全繼承）。⚠️ 所有 session 共用 Max 配額 ⇒ 平行度上限是配額不是機器數；日常走 A、衝實驗波才開 B。

## 機器盤點（08-30 13:42 實測；SSH session `local_82b64873` 已移交關閉）

| 機器 | key | 規格 | 關鍵事實 |
|---|---|---|---|
| gw2 172.25.197.50 | ✅ | Ubuntu 24.04.2、32 核、15Gi、1T（空 921G）、bare metal、vmx✅ | sudo 要密碼；up 86 天；連外✅；內網介面＝**10.10.10.249** |
| cc2 10.10.10.250（跳 gw2） | ✅ | Ubuntu 24.04.3、kernel 7.0.0-30、32 核、**15Gi**、1.5T（空 1.4T）、bare metal、vmx✅、**Docker✅** | sudo＝`(ALL:ALL) ALL` **要密碼**（NOPASSWD 只有實驗室的 `/opt/get_cpu/cpu_recorder.py`）；連外✅（api.anthropic.com 通）；**08-29 23:42 被 unattended reboot（實證：長實驗會被重開）**；沒裝 tmux/screen |
| server5~8 ＝ 10.10.10.251–254（跳 **gw2**）＝ ASUS WS760T ×4 | ✅ key 已放（08-30） | 各 32 核、15Gi、1.8T（空 1.6T）、bare metal、vmx✅、連外✅ | sudo 要密碼；**無 docker/tmux/screen**（長跑用 setsid/nohup）；kernel：5/6＝6.17.0-23、7/8＝7.0.0-28 ⇒ **比較性實驗選同 kernel 對**。**占用（last）：5/6 上週有人**（8/23–8/29、小時級 session、經 gateway 身分不可見）、7 最後 8/7、8 自 8/12 幾乎閒 ⇒ **佔用順序 8→7→6→5**；長期佔用前過學姐 |
| gw 172.25.197.103（舊 gateway） | ✅ key 已放（08-30） | 28 核、**31Gi（最大 RAM）**、NVMe 915G（空 804G）、vmx✅ | 舊側基礎設施：enp8s0＝**10.10.10.1/24**、default route 走 Proxy .102；up 108 天 |
| server1~4（10.10.10.5–8，跳 **gw**）＝ E500-G9-WS760T ×4 | ✅ key 已放（08-30） | 28 核；RAM 1/3＝**30Gi**、2/4＝15Gi（**2/4 被吃滿剩 <120Mi**）；NVMe 1/3＝468G、2/4＝937G；vmx✅ 連外✅；**舊側有 tmux**（新側沒有） | 🔴 **佔用中＝非候選（08-30 14:38 實測）**：server1/2/3 各一支 **iperf3 跑 15 天 20h、99.9% CPU（≈8/14 同時起跑的 campaign）**＋四台都另有 2–3 天 iperf3；server1 有 uvicorn 服務；**server2/3 有活 tmux workspace（8/28 起）**；8/28 晚有人四台平行開 session（經 gw）。sudo 要密碼 |
| 舊 cc（10.10.10.2，跳 gw） | — | — | L2 活著但 **port 22 closed/filtered**（08-30 14:38）＝實質不可用 |
| 10.10.10.30 NDTwin collector（帳號 alen，新側） | ❌（Adam 裁先跳過） | 未知 | 活著：ping OK、SSH 開（08-30 14:23）。名字與我們專案直接相關；**可能是別人的 box，先不動** |

🔑 **10.10.10.249＝gw2 的內網介面**：所有經 ProxyJump 進 cc2 的人來源都顯示它 ⇒ last-login 看不出身分。8/12 那筆＝「非 Adam 的某人經 gateway」，**cc2 共用帳號有他人在用的結論成立**，但推不出人在哪。

🆕 **新側 L2 全貌（gw2 ARP，08-30 14:23）**：`.16–.25` 十台 REACHABLE 設備、MAC 同廠牌前綴＝**極可能是新 testbed 的 HPE 交換機群**；`.28` 不明；**`.248` 與 `.250` 同 MAC＝cc2 的第二個 IP**；gw2 內側介面＝enp5s0 10.10.10.249/24。⇒ **實體交換機就在這條 LAN 上，VM 擋內網（NAT-only）的理由再+1**。

🆕 **舊側 L2 全貌（gw ARP，08-30 14:28）**：`.3–.15/.100` 一批 60:9c:9f＝**Brocade 交換機群還通電**；server1~4＝10:7c:61（ASUSTek）；`.31` 與 gw 同廠牌。🔴 **兩套 testbed 共用同一段 10.10.10.0/24 但實體分開** ⇒ **同一個 IP 兩側可以是不同機器；連老側跳 gw、連新側跳 gw2**，跳錯 gateway 連錯機。

🆕 **08-30 學姐憑證表補充**：多一台 `10.10.10.30` **NDTwin collector**（帳號 alen）——已探，活著（見上表）。**免密碼原理**：ssh-copy-id＝公鑰進 authorized_keys，之後全免密碼（已五台實證）；sudo 另計；私鑰＝本機 `id_ed25519`，實驗 VM 按設計不持有。表頭欄位是「智慧排插／Host name」＝**每台 host 也是它的智慧 PDU（遠端電源開關）識別碼**，就是 cc2 被遠端重開的機制、也是「長實驗會被關掉」的來源（[[power-on-reports-success-without-acting]]、[[ovs-testbed-bandwidth-reality]]）。共用密碼一批同、Proxy 例外；**憑證值在學姐 HackMD 表、Adam 手上有，密碼一律不進記憶**。server1~4 表上有、從 gw2 不可達（三假說見上表，未裁）。

## 已定判斷

- 🔴 **08-30「沒人在用」假設被推翻**：老側 server1~4 有進行中的 15 天 iperf3 campaign＋活 tmux ⇒ **實際候選池＝server8→7（6/5 次之，1~4 出局）**；🔑 五件套實戰價值實證——`w` 乾淨完全不代表空機，工作都掛在背景。實驗室 8/23–8/29 兩側都有人動 ⇒ **問學姐從禮貌升級成必要**。

- 🔴 **cc2 不是實驗目標**（共用帳號＋有他人＋會被自動重開）——但它是**隔離層驗證的首選場地**（vmx＋Docker 都在）；RAM 15Gi ⇒ 切 VM 約 2 台到頂。
- **目標池＝server5~8 獨佔幾台**（規格待 key 放了才盤得到）。
- **權限架構**：Claude Code 跑在遠端 VM 裡拿 root；不持有實驗室憑證（不拿 gateway key／Adam 的 id_ed25519）；VM NAT-only、**擋 VM→10.10.10.0/24**（內網有實體交換機）；資源上限；每波實驗前 snapshot。
- **占用檢查五件套**（已在 cc2 實跑）：`w`＋`loginctl`／`ss -tn | grep :22`／`ps --sort=-pcpu`＋load（**沒人登入≠沒人在用**）／`last`／tmux·screen ls。兩盲區：共用帳號＋跳板⇒身分不可見；看得到此刻看不到等下⇒「接下來歸誰」只能靠 claim 約定（[[lab-claim-handoff-protocol]] 延伸）＋問學姐。
- **多使用者**：同時登入本來就行；**同時各開一個 lab 不行**（kernel 全域）——VM 層的理由。共機互為量測共變量 ⇒ 開發可共機、進報告的數字不行（效能量測釘單機，[[benchmark-must-name-the-binary-it-measured]] 延伸）。
- **網路斷 vs 實驗死（解耦四原則）**：①長跑一律 setsid＋落盤（3.2 小時教訓，[[evidence-must-outlive-the-handoff]]）；②script self-contained、決策預先寫進去（＝預註冊紀律同構）；③觀測拉式不推式；④重連先對帳。NDTwin 實驗機器內 self-contained（veth/OVS/bmv2 不出機器）⇒ 任何一段網斷都殺不死包好的實驗；**模式 A 下本機斷網＝總控腦也癱**（本機 Claude 也要 API）；**真殺手是機器重開**（cc2 已示範）⇒ 可重入 script ＞ snapshot ＞ 網路韌性。

## 連線的坑（沿用＋新增）

- VPN 沒開＝timeout 不是 refused，先 `ip -brief addr show tun0`；**08-30 13:57 VPN 又斷（Adam 換網路 10.0.0.x），重連可能要重新認證**。
- 🔴 VPN full tunnel 推 172.17/172.18 ⇒ **VPN 開著時本機 Docker 全斷**；解法候選＝VPN 關進 netns／改 Docker address pool。
- 10.10.10.0/24 必須 ProxyJump（config 的 `cc2` 已包好）；老 Brocade 交換機才要 legacy KexAlgorithms，Linux 主機不要加；文件裡 172.25.166.137 是舊殘留。

## 🏁 08-30 四項裁決（表單，全採建議）＋落地狀態

1. **協調模式＝各 session 自己跑＋claim 檔**（不設代理人）——工具 **`~/.local/bin/rlab`**（list/status/claim/release；claim 檔＝機器上 `~/RLAB-CLAIM`、釋出寫 `~/RLAB-HANDOFF.log`；**claim≠measuring，動手前必看 status 的 load/procs**）。✅ 已建、已 smoke。
2. **首發機器＝server8** ✅ 已 claim（owner=session:test，note 註明長跑等學姐）。
3. **sudo＝特定指令 NOPASSWD**（本機白名單翻版、**故意不含 ndtwin-p4-power**——PDU 控制不上遠端）：`ndtwin-bootstrap.sh`＋路徑已 sed 成 server8 的 `ndtwin-lab.staged` **已 scp 到 server8 家目錄**，等 Adam 跑 `ssh -t -o ProxyJump=gw2 server8@10.10.10.254 'sudo bash ~/ndtwin-bootstrap.sh'`（**唯一要密碼的一步**；裝 mininet/OVS/tmux＋wrapper＋sudoers）。
4. **學姐＝平行進行**：可逆的部署驗證先走，**長跑／常駐前以問到為前置**。

**Adam 插手面收斂成三類**：每台一次 bootstrap／白名單外新 root 需求（**wrapper 更新也要 sudo——這是安全設計故意的**：agent 不能自改自己的 root 面）／社交層（學姐、PDU）。日常實驗（topo/tc/量測/長跑）＝零插手。

## 🏁 milestone-1 收案（08-30 15:02，全驗過）

server8 現況：**claim✅（rlab）＋ code✅（worktree @ `3964f4c`，16,201 檔 1.88G，`DEPLOYED_FROM` 戳記）＋ bootstrap✅（Adam 跑完，實測 `sudo -n ndtwin-lab status` 免密碼、ovs-vsctl 免密碼、mn/mnexec/tmux 齊、NOPASSWD 7 行）**。Claude 在 server8 的白名單內自主權已生效。

- 🔒 **遠端 `.git` 已刻意移除**：本地歷史含投稿包 blob，共用帳號機器只放 worktree（`DEPLOYED_FROM` 記 commit 供 benchmark 指認；要歷史隨時可從本機重傳/淺 clone）。**之後每次部署到共用機都比照**。
- 🐢 VPN 實測吞吐 ≈0.9 MB/s ⇒ **大 artifact 一律在遠端 build，不要推**（bmv2 build 上傳比重編慢）。
- ⚠️ **完整 lab 的相依現實**：`ndtwin-lab` 掛四個 repo＋conda ntg-env＋兩顆 app binary（[[cross-repo-component-ecosystem]]）⇒ **milestone-2＝照安裝手冊在 server8 立全套**（NTG repo、miniconda/ntg-env、bmv2/p4c build、Ryu、venv；也順便是手冊的遠端乾淨室實測，與手冊線協調再說）。

**🏁 08-30 預約層也齊了**：學姐答覆＝**在 Google Calendar 登記**（日曆名與 id、格式、兩個工具坑見 [[remote-parallel-experiment-workflow]] step 0）。我方首則已建：`Adam / server8 / NDTwin 實驗`、**8/30–9/5 全天**。⇒ server8 兩層都有（日曆＋`rlab` claim）。**LINE 六題已擬稿交 Adam 發**（排插界線／server8·7 長借與實體角色／server1~4 的 iperf3 是誰的／`10.10.10.30`／**硬體 P4 switch 能不能借**／Calendar 格式），回覆前**只做可逆的部署驗證，不開長跑**。

## 🏁 08-30 傍晚 Adam 親自裁掉四題 ⇒ **server8 長跑解封**

**六題不必全問學姐，Adam 自己答了四題**：

1. 🏁 **「server8 只要 Calendar 有預約到就好」＝授權門檻就是那則登記**，不需要學姐個別許可 ⇒ **「長跑以問到為前置」這條前置條件已消滅**，server8 現在可以開長實驗。（⚠️ 他明講的是 server8；server7 我按同一規則辦＝**要用先登記**，但那是我的推廣不是他的原話。）
2. 🏁 **server1~4 的 iperf3「不必問是誰的」**——判準是**我們用不用得到**，而我判定用不到（老側跳 gw 的另一條實體 LAN、四台全在 campaign 中、`server8+7` 已足夠打破「一次一個 lab」）⇒ **撤問，不是延後問**。
3. 🏁 `10.10.10.30` collector：Adam **上班口頭問**，不進 LINE、不進待辦。
4. 🏁 **Calendar 格式＝名字／使用時間／使用機器**（現有那則已符合：標題帶名字＋機器，時間＝全天跨度）。

⇒ **LINE 只剩兩題**（都不擋 milestone-2）：**排插**（真正該問的不是「能不能用」而是**「server8 當掉時誰能重開機、我們可不可以」**——我們永遠不會主動斷別人的電，但**Mininet/OVS 玩壞 kernel 是真實失效模式，而復原手段全在我們構不到的地方**）；**硬體 P4 switch**（全實驗室**只有一台** `10.10.10.28` ⇒ 獨佔資源，借＝擋住所有人，值得問但不急）。

**殘餘待辦**：①**milestone-2 立全套（現在無前置、可開跑）**；②VM 隔離層（第二階段，vmx 都在）；③LINE 剩兩題（不擋工作）；④server1~4 佔用中暫不動、key 已放好備用。
