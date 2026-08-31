---
name: nslab-remote-dev-machine
description: 遠端開發機 nslab（172.25.197.100）——🟢 可以用；連法/規格/qemu VM 操作/協調工具/踩過的坑。動手前先讀規定正本 doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md（R1＝開跑前登記）
metadata: 
  node_type: memory
  type: project
  originSessionId: 103a1748-0691-49d5-b92f-8ab519a66ee0
  modified: 2026-08-31T12:53:06.538Z
---

# 遠端開發機 `nslab`（2026-08-31 實驗室配發給 Adam）

> # 🟢 **可以用**（08-31 晚間解封）
>
> 當天下午 Adam 喊過一次「等等，先不要用遠端機器」——**理由是使用規定還沒成型**，
> 不是機器有問題、不是授權被收回。解封條件是**兩個都要**：① 規定落地 ② Adam 開口，
> 08-31 晚間兩個都成立。
>
> 🔑 **措辭那次差點寫錯**：我第一版標成 🔴「停用」，auditor 當天更正成 🟡「規則制定中」。
> **讀到「停用」的人會去找替代機器，讀到「規則制定中」的人知道要等那份文件。**
> 現在兩者都不必，但這個區別下次還會用到。
>
> 🔑 **解封走的是我們自己設計的路徑**：編輯 `tools/remote-lab/rlab` 的 `suspended()` 表。
> **沒有環境變數旁路 ⇒ 解封跟暫緩一樣留得下 diff 與時戳。** 查一台機器能不能用：
> `rlab suspended <machine>`（**不撥號**）。
>
> 🔴 **testbed 那批（server1~8／cc2／gw／gw2）仍然停用**，學姐說的、解封條件不同。
>
> ## 🏁 **規定正本已落地**：`doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`（`935bc80`）
>
> **正本歸「遠端機器測試」這條線**（Adam 裁）。reviewer 原本另立的 `NSLAB-FABRIC-QUEUE.md`
> 已自行撤除（`edffd25`）改成交需求進來——**一台機器只能有一個真實來源**。
> 內容＝優先序表＋**歷史列 H-1…H-25＋V-1（違規列）＋OBS-1（觀測列）**＋規則＋解封程序＋未決清單。
> **別在記憶裡複製它**，回檔讀。08-31 一天長到 **R1–R16** 外加十來條字母子規則——
> **每一條都是踩到才寫的**，沒有一條是預先設計的。要知道有哪些就開檔看目錄，不要從這裡推。
> ⚠️ **這個範圍每隔幾小時就會過期**（08-31 一天內我更新過三次）⇒ **不要引用範圍，要引用檔案。**
>
> 🔑 **三種列號的差別是刻意的，別混用**：`H-` ＝登記過的佔用；**`V-` ＝從沒登記過的佔用**
> （R13 禁止補登成 `H-`，因為一列與合規列長得一樣的紀錄會**製造一段假的合規**）；
> `OBS-` ＝我這一側的觀測，登記的是觀測動作本身。
>
> 🔑 最硬的一條（R1）：**那台沒有 claim 工具 ⇒ 表就是唯一紀錄，沒有第二個東西可以重讀**
> ⇒ **開跑前寫、release 後改，不准事後補登**（事後補登會製造一段假的空窗，而那段資料是髒的）。
> **本機那張表的「本表是意圖不是授權」不適用於它，也不准抄過去**——那邊沒有「別處」。
>
> **開跑的順序**（08-31 解封時排的）：首航（工具部署＋閘門，已完成）→ 開機手冊
> **P4/BMv2 demo VM 的 `.ova`**（⚠️ 我原本記成「SimPlatform」，**是錯的**，那是另一件事）
> → reviewer B 輪 → mainDev E 輪 build → C4 container。**排隊的是量測窗，準備可以重疊**（R3）。
>
> ⚠️ **本檔與規定都不涵蓋 nslab 的實體網路角色**（三張網卡、兩張沒接線，未問學姐）。

⚠️ **這台的授權來源是 Adam 轉述**「實驗室給了我一台新的電腦，**讓我遠端跑**」，
**我從沒向學姐個別確認過**。08-31 下午 Adam 喊停一次又解封，等於 Adam 這一層是確定的；
**學姐那一層仍未確認過**。若她的「遠端機器先不要用」原本就涵蓋這台，以她為準。

## 連法（🔑 要 VPN，但**不要**跳板）

```bash
ssh nslab                      # 別名已寫進 ~/.ssh/config
```

- `172.25.197.100`、帳號 `nslab`、公鑰已放（`ssh-copy-id` 由 Adam 跑過一次）⇒ **永久免密碼**。
- **要先連 VPN**（`ip -brief addr show tun0` 確認）；VPN 通了之後 `172.25.197.x` 直連，**不經 gw／gw2**——`gw`(.103)、`gw2`(.50) 本來也是這樣連的。
- ⚠️ **IP 是 DHCP 給的**（`netplan ipv4.method=auto`）⇒ **會變**。`enp4s0` MAC＝`60:cf:84:bf:1f:59`（要請實驗室綁固定 IP 時用）。連不上先確認是不是換位址了，不要先懷疑機器。

## 規格與環境（08-31 實測）

| | |
|---|---|
| CPU / RAM | **28 核 / 31 GiB** ← 比 server8 的 15 GiB 多一倍，記憶體不再是瓶頸 |
| 磁碟 | NVMe 915 G，空 854 G |
| OS / kernel | Ubuntu 24.04.2 LTS / 7.0.0-28（**與 server8 同 kernel** ⇒ 可比） |
| 虛擬化 | `vmx` ✅、`kvm_intel` 已載入 |
| 自動重開機 | `Automatic-Reboot` 是註解掉的 ⇒ **不會自己重開**，長建置安全 |
| 出廠狀態 | 幾乎空的桌面裝：**沒有** git/gcc/g++/cmake/mn/ovs/tmux/docker |

🔴 **這台有三張網卡，兩張沒接線**（`enp8s0`/`enp9s0`，MAC `00:e0:4c:68:07:55`/`:56`）。三張網卡是 testbed 節點的形狀 ⇒ **它在實體拓撲裡可能也有角色**（[[physical-testbed-operations]] 的「server 有雙身分」同型）。**未問、未確認。**

🔴 **它跟兩個智慧排插同一個 L2 網段**（`172.25.197.120`/`.121`，另有 `gw`.103／`gw2`.50／Proxy .102）⇒ [[physical-testbed-operations]] 的「排插一律不碰」在這台上是**同網段的鄰居**，不是遠方的東西。

## 已經動過的 root（只有這一次，Adam 輸密碼）

`~/ndtwin-virt-root.sh` 裝了 `qemu-system-x86` / `qemu-utils` / `cloud-image-utils`，並把 `nslab` 加進 **`kvm` 群組**。
✅ **root 面沒有被加寬**：`/etc/sudoers.d/` 裡只有 OS 自帶的 `README`，**沒有任何 NOPASSWD**。

🔴 **⇒ 這條線在 host 上不能免密碼 `sudo`**（08-31 實測 `sudo -n true` → `sudo: a password is required`）。
**任何要 root 的 host 動作都要 Adam 本人。** 規劃前先問「這條路上哪幾步要 root」——
p4-guide 整段都在 `sudo apt`，所以兩小時的建置**不可能靠現有權限自己跑完**，那要在開工前發現。
🔑 **解法不是去要權限，是換地方**：guest VM 裡的 `ndt` 有 NOPASSWD root，爆炸半徑＝那顆 VM。
**要 root 的工作放進 guest。**

🔑 **為什麼群組那步不能省**（實測，差點被騙）：`/dev/kvm` 是 `crw-rw----+ root:kvm`，而 `getfacl` 顯示有一條 `user:nslab:rw-` 的 **ACL**——那是 logind 因為「人坐在機器前面登入桌面」（`seat0 tty2 active`）給的。**Adam 一登出桌面它就收回**，SSH 進來的 session 會突然開不了 VM。ACL 是借來的，群組才是自己的。

## 開 lab VM：`~/ndtwin-vm.sh`（全部不需要 host root）

```bash
ssh nslab 'VM_CPUS=16 VM_MEM=16384 bash ~/ndtwin-vm.sh <verb>'
```

`create`（抓 Ubuntu 24.04 cloud image、建 seed、開 120G 磁碟）／`start`／`stop`／`status`／`ssh [cmd]`／`snap <name>`／`restore <name>`／`snaps`／`vms`／`destroy`，＋08-31 晚加的兩個：

- 🔒 **`keep "<理由>"`**（`--clear` 解除）＝標記這顆磁碟不可刪。**價值全在讀者**：`vms`／`status`／`destroy` 三處都讀，`destroy` 會列出快照 tag 並改要 `DESTROY <目錄名>`。
- 🔧 **`adopt`** ＝對**已經在跑**、但不是用 `create`／`start` 開的 VM 補建 `OWNER`＋`CONFIG`，**工作點從 `/proc/<pid>/cmdline` 推導、不接受輸入**。
  🔑 **它存在的理由**：協調整組掛在 `create`／`start` 上，所以**任何繞過它們的正當用法會把協調一起弄丟**——`create` 只會下載乾淨 cloud image，「從匯出的快照建 VM」**根本沒有那條路**（規定 R16）。
**這台的工作點＝`VM_CPUS=16 VM_MEM=16384`**（31 GiB 主機留 15 GiB 給自己）。VM 目錄 `~/ndtwin-vm/`。

**進 guest 的兩條路**（guest 帳號 `ndt`，有 NOPASSWD root）：

```bash
ssh nslab '~/ndtwin-vm.sh ssh'                 # 從 host
ssh -J nslab -p 2222 ndt@127.0.0.1             # 從 Adam 的筆電直達
```

### 🔴 兩把公鑰都要注，這是一個「不可能變綠的閘門」的教訓

第一版只注了 **Adam 筆電的公鑰**，而 `start` 的就緒檢查是**在 host 上**跑 `ssh ndt@127.0.0.1`——**host 沒有那把私鑰** ⇒ 那個檢查**永遠不可能通過**，會對著一台健康的 VM 空等 900 秒然後報失敗。
修法＝host 自己 `ssh-keygen` 一把，**兩把都注進 cloud-init**。
🔑 這是 [[failures-that-report-success]] 的鏡像面（**閘門不可能變綠**）——規矩：**每個閘門都要能 force-red 也要能 force-green**，只想過「它會不會誤放」不夠。

### 🔴 08-31 意外發現：**VM 是共用的，而 snapshot 是那顆磁碟上的全域可變狀態**

我去存工具鏈快照時，列表裡出現**我沒有建過的快照**（`p4-bootstrapped-nodocker` 14:01、以及第二個
`fresh` 14:00——我的 `fresh` 是 11:47）⇒ **另一個 session 正在同一顆 `disk.qcow2` 裡動手**。

三個後果，都不是理論：

1. 🔴 **任何人 `restore`，所有人的狀態一起被換掉**，而且沒有任何提示。`snap`/`restore` 沒有擁有者概念。
2. 🔴 **`qemu-img` 允許重複的 tag** ⇒ 現在有兩個叫 `fresh` 的快照，`restore fresh` 指哪一個不明確。
   **快照命名要帶用途＋日期**（例如 `p4-toolchain-v8`），不要用 `fresh` 這種通用字。
3. ⚠️ **VM 執行中時 `qemu-img snapshot -l` 會失敗**（`Failed to get shared "write" lock`）——
   這不是壞掉，是正常。`ndtwin-vm.sh snap` 會先 stop 所以看得到；要單獨查列表得先停。

🔑 **主機層共用是安全的**（28 核／31 GiB 塞得下好幾顆 VM，而 Mininet netns／OVS 全域衝突只發生在
**同一個 kernel 內**）——**但共用同一顆 VM 就等於共用同一個 kernel，那正是我們開 VM 要避免的事**。
⇒ **一個 session 一顆 VM**：用不同的 `VM_DIR` 與不同的 `SSH_PORT`（兩者都是環境變數），
不要共用 `~/ndtwin-vm/`。共用主機沒問題，共用 VM 沒有意義。

### 已有的快照

- **`fresh`**（08-31 11:47）＝剛開機、什麼都沒裝的乾淨 Ubuntu 24.04.4（kernel 6.8.0-138）。
  🔑 **每一波風險建置前先 `snap`**，炸了 `restore`。p4-guide 的「半安裝之後再跑會回報成功」陷阱在裸機上是永久的，在這裡是一次回滾——**這是選 VM 而不是裸機的決定性理由，不是安全**。

### ⚠️ 兩個誠實界線（不要講成完整隔離／完整乾淨室）

1. **網路走 user-mode (SLIRP)**：guest 在實驗室網段上**沒有 L2 存在**（不會 ARP、不會被交換機看見、不會意外變成別人實驗的流量端點），**但 SLIRP 是走 host 的 socket 層轉出去的** ⇒ guest 刻意連 `172.25.197.x` **仍然連得到，而且看起來像是這台發的**。硬擋要 tap＋nftables，**沒做**。
2. **cloud-init 先建了 `~/Desktop`** ⇒ 這台的 VM **不重測手冊的 M-1**（「用 `~/Desktop` 13 次卻從不建它」），是**繞過**不是通過。見 [[install-manual-clean-room-test]]。

## 🔑 這台量得出來的效能數字，哪些算數（08-31 Adam 戳破我的過寬禁令後訂的）

我一開始跟 `bmv2論文審查` 說「這台的效能數字不能進論文」，**那句話太寬**。三個理由拆開來，
沒有一個支持那麼強的結論：「另一台機器」禁止的是**併**不是**量**；「是 VM」要求的是**控制與申報**
不是作廢；「binary 不同」在任何重編上都成立，**跟哪台機器無關**。

⇒ 真正的規矩只有一條：**一個效能宣稱必須自足——所有臂在同一台機器、同一顆 binary、
同一個工作點上量完，並指名它量了什麼。** 這台沒有違反這條。

| | |
|---|---|
| ✅ | **完全在同一顆 VM 內跑完的 A/B 比值**——共同的 VM 噪聲在比值裡大部分抵銷 |
| ✅ | **當第二個平台重現既有的定性結論**（bmv2 隨流數自塌 vs OvS aggregate 撐住）——**這是加分項**：硬體與宿主都不同還重現得出來，外部效度就強很多（[[replication-unit-not-the-rep]]：第二個平台是新的一格，不是多一個 rep） |
| ⚠️ | **絕對容量／吞吐**——量得出來，但那是**另一個工作點**，當新的一組報，不併進舊表（[[bmv2-ceiling-is-pps-not-bps]]：天花板是「臂」的性質） |
| 🔴 | **不能**跟 Adam 筆電那批數字比或替換（12×／8.0×、pps 天花板、OvS 53.1 G 全釘在那台） |
| 🔴 | **收端行為那一類不會轉移**——[[jitter-is-the-receiver-not-the-network]] 講的是單一接收行程的速率，而 VM 的 virtio 收包路徑本身就是另一回事 |
| 🔴 | **不能假設它安靜**——實驗室的機器、非獨佔（三張網卡、可能有實體角色、別人會用；本檔下方已有多 session 共用的實例）⇒ 要量就得像對本機一樣做負載控制與申報（[[vm-on-this-machine-is-invisible-to-ndt-status]]） |

## 🏁 08-31：完整 P4 工具鏈已在 VM 內建好（milestone-2 PASS，38 分 41 秒）

`vm-install-stack.sh`（手冊 §3.1＋§3.2 apt → `install-p4dev-v8.sh`）在那顆 VM 裡跑完：

```
03:53:10 → 04:31:51 UTC   ＝ 38 m 41 s      （guest 時鐘是 UTC，＋8 才是台北時間）
simple_switch_grpc /usr/local/bin/  1.15.5-583e76e4
p4c-bm2-ss / p4c   /usr/local/bin/
最小 v1model 程式 → 4122 bytes BMv2 JSON     （驗到「會編譯」，不只「binary 在」）
behavioral-model 583e76e401da…（2026-08-30 22:06 -0400）
p4c              c55ca45b1f（08-24）  ／ p4-guide a2f9f8c5（08-25）
```

- 🔑 **建置時間嚴重取決於核數**：手冊寫 1–2 h、4 vCPU 乾淨室實測 **2 h 01 m**、這裡 16 vCPU **38 m 41 s**。
- 🔑 **v8 自己是記憶體感知的**：呼叫 `max_parallel_jobs 2048`，取 min(核數, 記憶體÷2 GB)。我本來要強制 `-j8` 怕 OOM，**查了發現上游已經做對，沒有覆寫**。
- 🔑 **v8 的兩個 patch 現在跨過兩顆不同的 behavioral-model commit 都成立**（`fdd3b893` 與 `583e76e4`），比只有一顆的證據硬。⚠️ 但**上游在我 preflight 之後、開建之前推了新 commit**，所以「輸入與 08-28 乾淨室相同」**不成立**——教訓見 [[cited-line-numbers-are-not-evidence]] 檔尾。
- ⚠️ 這一輪對手冊而言是**第二個資料點，不是同條件重跑**（上游版本不同＋`~/Desktop` 是繞過的）。

## 🔴 腳本住在哪（**不在 repo 裡**，scratchpad 會隨 session 消失）

```
~/.local/share/ndtwin-remote/          ← Adam 筆電上的耐久副本（含 README 說明每支跑在哪）
nslab:~/ndtwin-scripts/                ← 現役機器上的同一份
nslab:~/ndtwin-vm.sh                   ← start/stop 實際呼叫的那支
guest VM:~/vm-install-stack.sh         ← ⚠️ 只活在 qcow2 裡，而 `fresh` 快照比它早 ⇒ restore 就沒了
```

⚠️ **要版控得自己 commit**——目前沒有任何一份在 git 裡。`~/.local/bin/rlab` 是另一支（claim 協調），不在那個目錄。

## 踩過的坑

- 🔴 **`systemctl is-active ssh` 回 `inactive` 不代表 SSH 沒開**——Ubuntu 24.04 預設 socket activation，`ssh.socket` 才是 active。用 `ss -tlnH sport = :22` 有沒有印出行來判斷。詳見 [[process-liveness-checks-lie-in-two-ways]] 第十六式。
- 用 `setsid` 跑 `create`／長建置並落盤（[[evidence-must-outlive-the-handoff]]）。

相關：[[remote-parallel-experiment-workflow]]（那份是 testbed 用的，**目前停用**；本檔的操作獨立成立）、[[lab-claim-handoff-protocol]]（這台是 Adam 專屬，**不需要 `rlab` claim**）。

---

## 🔴 08-31 實測：**VirtualBox 在這台裝不起來，而且原因是結構性的**

`sudo apt-get install -y virtualbox` 裝的是 **7.0.16-dfsg-2ubuntu1.3**，`virtualbox-dkms` 建不出
`vboxdrv`。DKMS build log 的根因：

```
modpost: module vboxdrv uses symbol kvm_enable_virtualization
         from namespace module:kvm-amd,kvm-intel, but does not import it
（同樣還有 kvm_disable_virtualization / cr4_update_irqsoff / cr4_read_shadow）
```

⇒ **VirtualBox 7.0.16 比 kernel 7.0.0-28 早**，它用到的 KVM 符號在新核心被關進受限的 module
namespace 而它沒宣告 import。`linux-headers` 有裝、build tree 在，**不是缺件，是版本不相容**。
要 VirtualBox 只能改用 Oracle 自己的 repo 裝 7.1/7.2（**未試**）。

🔴 **而且那次 apt 沒有跑完，dpkg 現在是壞的、會擋住之後的安裝**：

```
iU virtualbox        iF virtualbox-dkms        iU virtualbox-qt
```

🏁 **08-31 15:47 查證：三個套件都已經不在了**（`no packages found`；全機唯一非 `ii` 的是
`rc dkms`＝設定檔殘留、不擋 apt）。**裝與清都是開機手冊線給指令、Adam 執行**（該線當晚主動回填；
那台沒有免密碼 sudo ⇒ 按不到的人不可能是執行者）。
⚠️ **我原本把它記成「永久的問號」，那是錯的**——補得回「誰」、補不回「何時」。
🔑 **「拼湊不出來」與「我還沒問」是兩件事**，我當時判斷「再開一輪往返不值得」，
而那個判斷是**替別人做的、代價記在帳上**。見規定 R11a。
🔑 **這個「沒有」帶陽性對照**：同一條管線對 `qemu-system-x86` 回 `ii …1:8.2.2+ds-0ubuntu1.18`
⇒ 抓得到東西，不是管線壞掉印出空的。
⚠️ 成因仍成立：**結構性不相容，重試不會成功**。

**能做與不能做（實測分界，不要外推）**：

| 動作 | 需要 `vboxdrv`？ | 結果 |
|---|---|---|
| `VBoxManage import --dry-run`（解析 OVF） | ❌ | ✅ **可以**，`Interpreting … OK.` rc=0 |
| `VBoxManage createmedium`（單獨建磁碟） | ❌ | ✅ rc=0 |
| `VBoxManage import`（真的匯入） | ？ | ❌ `Storage for the medium … is not created` / `VBOX_E_INVALID_OBJECT_STATE` |
| 開機 | ✅ | ❌ 沒有 `/dev/vboxdrv` |

⚠️ **匯入那格的歸因未定**：我否證了兩個假說（空磁碟探針 → 換成有 48 MB 真資料的一樣壞；
轉檔碼路 → `--options importtovdi` 一樣壞），而 `createmedium` 單獨是好的。
**剩下最可能的解釋是那個半設定完成的安裝本身，但我沒有能力證明**——身邊站著壞掉的儀器時，
不能把失敗歸給受測物。

🔑 **VirtualBox 與 KVM 的衝突在這台是「編譯期」不是執行期。** 我原本只警告執行期搶 VT-x
（`VERR_VMX_IN_VMX_ROOT_MODE`），結果它連模組都建不起來，撞的還是同一組 KVM 符號。

## 📌 08-31 其他實測數字

- 🔴 **VPN 鏈路 ≈ 0.91 MB/s**（08-31 對**傳輸中**的 2.5 GB `.ova` 取兩個十分鐘間隔的讀數：
  1,039,400,960 B @16:32:41 → 1,596,981,248 B @16:42:51）。
  🔴 **我先前拿 0.38 MB/s 去排時程是錯的**（8 MB / 21 s，`rc=0`）——**但錯的不是量測，是外推**。
  🔑 **更準的診斷是開機手冊給的**：0.38 **是另一個量的正確量測**。短傳輸裡 SSH 握手與慢啟動是
  **固定開銷**：若穩態 0.9 MB/s，8 MB 只需 **9 秒**而我量到 **21 秒** ⇒ **12 秒是開銷**。
  長傳輸把同一筆開銷攤到 2.5 GB 上就看不見了。**兩個讀數不衝突。**
  ⇒ **通則：問「這個量裡有沒有固定開銷，以及我要外推到的尺度會不會把它攤掉」**——
  這比「樣本要夠大」有用，因為它回答了**大到多少才算夠**：大到固定開銷可忽略。
  🔑 **最好的樣本往往就是那個真正在跑的工作本身**，我手上一直有它卻先用了合成樣本。
  （⚠️ 更早那個「64 MB / 280 s」讀數 **exit code 是 1**——失敗的傳輸不能當速率，也已作廢。
  三個讀數裡兩個是我的、兩個都錯，見 [[the-clean-version-is-the-one-to-recheck]]。）
  ⇒ 結論不變：大 artifact 一律遠端 build，不要推（[[remote-testbed-parallel-dev]] 的 0.9 MB/s 同一個數量級，**現在對上了**）。
- 🔑 **可平行的是「準備」，不是「量測」**（規定 R3 的可操作形式，Adam 08-31 點名要記）：
  - ✅ **可重疊**：build 編譯、容器建置、下載、檔案傳輸、寫作、prereg 起草
  - 🔴 **必須排隊**：**任何兩輪的量測窗**
  - 🔴 **給第二輪另開一顆 VM 也救不了——競爭發生在宿主層。** 可驗證的形式：兩輪跑在同一顆
    實體 host，而 PREREG-B 有一道宿主外來負載閘 ⇒ **一個正確運作的閘門會把兩輪一起判成 suspect**。
  - 🔑 **兩件事必須分開講**：**開 VM 的意義是隔離 kernel 全域狀態**（Mininet netns／OVS
    datapath）**，不是取得獨立的效能量測環境。**
  - 實例（08-31，不是假想）：`bmv2論文審查` 的四核滿載編譯，與開機手冊線傳 2.6 GB `.ova`
    時間重疊——**而後者是被外部事件觸發的**，所以這條規則不能只靠自律。
- 🆕 **十六式當場又演了一次、而且是我自己造成的**：Adam 貼給我看的是
  `systemctl is-active ssh` → `inactive`，我讀到的是 `active`——**因為我那次 scp/ssh 連線
  本身把 `ssh.service` 叫起來了**。兩個讀數都對，只是量測動作改變了被量的東西。
  ⇒ 判準仍然是 `ss -tlnH sport = :22`。見 [[process-liveness-checks-lie-in-two-ways]] 十六式。

---

## 🔴 停用令下來時，這台上留下了什麼（08-31 ~15:00 凍結，事實清單）

**沒有做損害評估**——[[rescinded-orders-invalidate-damage-assessment]]：命令回收之後才評估的損害是無效的。以下只給事實。

| 面向 | 狀態 |
|---|---|
| host 的 root 變更 | `qemu-system-x86` / `qemu-utils` / `cloud-image-utils` 三個套件；`nslab` 加進 `kvm` 群組。**`/etc/sudoers.d/` 沒動**（只有 OS 自帶 README）、沒新增 service、沒改網路、沒重開機 |
| 另一個 session 的 apt | `virtualbox` 系列半裝，**dpkg 現在是 `iU`/`iF` 壞狀態**（見上一節）——收乾淨要 purge，但**現在不准動** |
| 檔案 | `~/ndtwin-vm/`（qcow2 實佔 **13 GB**、seed.iso、user-data/meta-data、qemu.log、monitor.sock、qemu.pid）、`~/ndtwin-vm.sh`、`~/ndtwin-scripts/`、`~/.ssh/authorized_keys`（Adam 筆電的 key）、`~/.ssh/id_ed25519`（host 自己那把，注進 guest 用的） |
| 🔴 **跑著的行程** | ~~**有。**~~ 🏁 **08-31 19:40 已 `stop`**（pid 25269 跑了 4.9 h、13.4 GB RSS；停後 available 14.0→26.6 GiB）。<br>🔴 **停的是 VM，磁碟與四顆快照都在，而且不准 destroy**——ID4 `p4-toolchain-v8` 是規定 §7 裁定保留、**38m41s 建置成本**的產物，已用 `keep` 標記。<br>🔴 **這格原本寫「不是我起的那一顆」——錯的，就是我**（`snap` 動詞會自動重啟）。逐字留著是因為**這個錯誤被別條線引用過** |
| claim | **從來沒有過**——`rlab` 不認得這台（見下） |

## 🔴 08-31 實測：**session 之間協調不到這台**（缺口，未修）

| 機制 | 對 nslab | 證據 |
|---|---|---|
| `rlab claim/note/release` | ❌ **不支援** | `~/.local/bin/rlab` 的 `tgt()` 只列 server1-8／cc2 ⇒ `rlab claim nslab` 回 `unknown machine` exit 2 |
| 本機 `ndt` lab claim | ❌ 管不到遠端 | — |
| cross-session 傳訊 | ⚠️ **推播不是登記** | 沒人主動查就不構成協調 |

而且**就算把 nslab 加進 `rlab` 也不夠——爭用單位不是機器是 VM**：
`ndtwin-vm.sh` 的 `VM_DIR` 預設 `$HOME/ndtwin-vm`、`SSH_PORT` 預設 `2222`，
**兩個 session 不設環境變數就會踩同一顆**（08-31 實際發生，見上面的 snapshot 一節）。
**所有 session 共用同一個 unix 帳號 `nslab` ⇒ 檔案系統是唯一可行的登記媒介。**

### 🏁 08-31 已補起來（Adam 裁「補」）＋**當晚已部署並在那台上驗過**

停用令期間這件事照樣做得完，因為**它整個在筆電上**（`~/.local/bin/rlab`、
`~/.local/share/ndtwin-remote/`），一個 byte 都沒推上去。

| 層 | 動作 |
|---|---|
| 機器層 `rlab` | `nslab` 進機器表（不走跳板）；新增 `suspended()` 停用表 ⇒ **對停用機器連都不連就 refuse (rc=4)**，並印「誰說的／何時／解封條件／沒有替代機器」。`rlab list` 不撥號也能當清單 |
| VM 層 `ndtwin-vm.sh` | `NDT_OWNER` 對所有改動性動詞**強制必填**（fail closed）；`$VM_DIR/OWNER` 記 owner/since/port/note，**別人的 VM refuse (rc=3)**；`SSH_PORT` 被占 refuse (rc=4)；`snap fresh` 這種通用名**直接拒絕**、`restore` 遇重複 tag 拒絕；新動詞 `vms`＝跨 session 視圖 |

三個設計選擇，每個都有代價換來的理由：

1. **claim 放在 VM 目錄裡，不放中央索引**——中央索引會跟磁碟上的實況不一致；放在磁碟旁邊不會。
   `vms` 用 glob 列目錄 ⇒ **沒登記過的 VM 也會現形（標 unowned），而不是隱形**。
2. **擁有與占用是兩個讀數**（同 [[lab-claim-handoff-protocol]] 的 claim≠measuring）。
3. 🔑 **搶奪的旁路會把自己寫進被搶的 OWNER 檔**——看不見的旁路不是守衛。
   而**停用表刻意沒有環境變數旁路**：解封要改 script，留得下 diff。

🔑 **`vms` 唯讀且不要求 `NDT_OWNER`**：查「誰占了什麼」不該以「你已經占了東西」為前提，
否則第一個想禮讓的人反而被擋在門外。

**變異閘**（`test_vm_coordination.sh`）：每個閘門 force-red **與** force-green 各一次，
斷言比對訊息文字不只比對 rc——因為好幾種不同的失敗都是 rc=1。停用表自己也有 green 方向。
📌 **08-31 一天走過 32 → 49 → 56 → 66 → 73**，⚠️ **每一次的「全綠」當下都看起來是完備的**
⇒ **別引用分數，跑一次**（`bash tools/remote-lab/test_vm_coordination.sh`）。
🔴 **73/73 只在筆電上跑過；nslab 上最後驗到的是 66/66**——我答應 reviewer 不在它量測期間跑那台。
**「本機綠」與「那台綠」是兩個宣稱。**

🏁 **08-31 已進版控＝`tools/remote-lab/`（`0d3559d`，含自己的 README）**。
掃描後才推、**定性再行動**：`10.10.10.x`／`172.25.x` 這個類別早就在 repo **也早就在公開上游**
（`origin/main` 各 9／6 檔）⇒ 不新；**唯一真正新的是那台的位址 ⇒ 已移除**，`rlab` 改成只認
ssh 別名（與 `cc2`/`gw`/`gw2` 一致），位址留在 `~/.ssh/config`。`password` 命中全是註解與
`getent passwd`、`lock_passwd: true`（**關閉**密碼登入）⇒ 無憑證。
`ndtwin-bootstrap.sh`／`ndtwin-lab.server8` 不進 repo（server8 專用、那台已凍結）。

🔑 **測試路徑一律相對於腳本自己**——寫絕對路徑的 harness 測的是那個路徑上的副本，
而 repo 與 `~/.local/` 各有一份時，測到的不是讀者剛 checkout 的那份
（[[harness-cd-hides-working-directory-defects]]）。

🏁 **08-31 晚間已部署到 `nslab:~/ndtwin-scripts/`，並在那台上重跑閘門＝32/32**（首航，H-12）。

⚠️ **首航零缺陷，但不要拿它論證「首航不必便宜」**——全綠的原因是三個缺陷已經在筆電上付過帳。
**先在便宜的地方踩過，貴的地方才會綠。**

### 🔴 首航真正找到的東西：**平行 VM 的預算是會漂的量，不是常數**

同一台機器、**同一顆 VM、宣告值沒變**，同一天兩次讀數：

| 時間 | `mem available` |
|---|---|
| ~15:0x | **27 GiB**（那顆 16 GiB 的 VM 剛開不久） |
| 15:44 | **15 GiB**（跑了幾小時之後） |

成因就是 **qemu 記憶體 lazy 配置**。⇒ **不要抄任何寫下來的數字，開新 VM 前跑
`ndtwin-vm.sh vms`**（最後三行就是現場預算）。依 15:44：再開一顆 8 GiB，或兩顆 5 GiB。
🔑 我下午回報的「3 顆 8 GiB」拿到晚上用會**超賣宿主 12 GiB**——見 [[the-clean-version-is-the-one-to-recheck]]
檔尾（同一個機制我只講了樂觀的那一面）。

### 🔑 `snap` 動詞**會自動重啟 VM**（stop → 快照 → 若原本在跑就 start）

這不是 bug，但它是 08-31 那次歸屬誤判的成因：我看到新的 pidfile 時戳就以為有第三個寫者。
`ssh` 子指令**不會** auto-start（它只 `exec ssh`）。⇒ **要判斷「誰動了那台」，
腳本行為與自己的指令紀錄兩者都要看**（[[process-liveness-checks-lie-in-two-ways]] 的**「pidfile 說得出何時、說不出是誰」**那式）。

### 🆕 後來又抓到三個缺陷，全是我自己的（都已修，各自有雙向測試）

1. 🔴 **工作點放在「啟動者的 shell 環境變數」裡，沒有跟著 VM 存**。任何人 `stop→snap→start`
   而沒重帶 `VM_CPUS`/`VM_MEM`，16 vCPU/16 GiB 的 lab 就以 **12/8192**（腳本的內建預設值）
   開回來——**什麼都沒失敗、什麼都沒警告、guest 開得好好的**。
   ⇒ **它把「這台機器的身分」變成一個會無聲改變的量**，而複製研究的重點正是機器身分。
   修法＝`$VM_DIR/CONFIG` 持久化，**env（顯式意圖）＞ CONFIG（上次跑的）＞ built-in**，
   落到 built-in 而磁碟已存在就大聲警告，`status`/`vms` 印出**工作點與它的來源**
   （🔑 **印一個值而不印它從哪來，等於請下一個人猜**）。
   🔴 **這個缺陷有一顆 VM 救不回來**：那顆共用 VM 在一段長度未知的窗裡跑在 12/8192，
   組態史重建不出來 ⇒ auditor 裁「**先盤點、再退役**」，不指派歸屬（規定 §5b）。
2. **`snaps` 把「讀不到」印成「沒有」** ⇒ 別人照著建了同名快照。**這是同名 `fresh` 的病因，
   拒絕通用名只是症狀。**（[[failures-that-report-success]] 第十三式）
3. **`snap` 成功卻 exit 1**（末尾 `&&` 是分支最後一句）。

### 🔴 我把一次自己的動作誤判成「第三個寫者」

14:41 那次 qemu 重啟**是我**——`snap` 動詞會自動重啟。我看到 pidfile 14:41:41 就用消去法判
「不是我」，**對自己寫的工具做推論而不是去讀它**。代價：另一條線因此把有效的校準結果降級、
加紅頭、規劃重跑。詳見 [[process-liveness-checks-lie-in-two-ways]] 的**「pidfile 說得出何時、說不出是誰」**那式。
✅ 反過來也證實了一件事：那次重啟帶了顯式 `16/16384` 且 **guest 自報 `cpus: 16 mem: 15Gi`**
⇒ 那台上 ~15:0x 的校準工作點成立。

## 📌 停用前量到的主機容量（解封後可直接用，不必重量）

28 核／**31.1 GiB**（`MemTotal 32588248 kB`）／swap 只有 8 GiB／`/` 915 G 空 **840 G**／
**KSM `run=1` 已開**（相同 guest 的相同頁會被合併）。建完工具鏈的 qcow2 實佔 13 GB。

⇒ **平行 VM 的瓶頸是 RAM，不是 CPU 也不是磁碟**。host 留 4 GiB 之後約 27 GiB：
8 GiB/顆＝**3 顆**（不超額，建議值）、6 GiB/顆＝4 顆、5 GiB/顆＝5 顆（要超額）。
- 🔑 **qemu 記憶體是 lazy 配置的**：宣告 `-m 16384` 的那顆跑著時，全機 `used` 只有 3,574 MB ⇒ 超額配置真的可行。
- 🔴 **但 swap 只有 8 GiB**：幾顆同時進建置尖峰會一起咬 swap 然後集體變慢——**這正是效能數字失真的機制**，所以「不量效能」是這個結論的前提，不是附註。
- ⚠️ **p4 建置的平行度是 RAM 的函數**（`install-p4dev-v8.sh` 的 `max_parallel_jobs`＝min(核數, RAM÷2GB)）⇒ 給 6 GiB 只拿得到 `-j3`。**工具鏈建在一顆給滿 RAM 的 VM 裡，然後複製映像**。
- 🔴 `ndtwin-vm.sh:115` 的 `create()` 是**完整複製不是 backing file**（為了讓 snapshot 自足）⇒ 現在開第二顆＝從 base 重建工具鏈（38 分）。**改成從建好的 13 GB 映像複製，開一顆掉到幾十秒。**

# 🟢 08-31 傍晚：解封，而且規定有正本了

**狀態＝可以用。** 08-31 ~15:00 Adam 說「等等，先不要用遠端機器」，理由是**使用規定還沒成型**
（不是機器有問題、不是授權被收回）。解封條件是兩個都要：①規定落地 ②Adam 開口，當晚兩個都成立。

🔴 **規定正本＝`doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`**（commit `935bc80`），
歸「遠端機器測試」線。**開工前讀 §3（08-31 收工時是 R1–R16，會再長），我不在這裡複述。**
記憶裡只留會咬到人的四條：

- 🏁 **R15 release 的判準是「資源已釋放」，不是「我認為工作做完了」**——帳本記得住工作收工，
  記不住資源釋放（19:33 實例：帳上全空窗，機器上有顆佔 43% RAM 的 qemu 跑了 4.9 小時）。
  🔑 **而「資源」有兩種、釋放動作不同**：**RAM 用 `stop`、磁碟用 `destroy`**。
  綁成一個 `release` 動詞會逼人在「還別人 RAM」與「保住產物」之間做**一個假的二選一**。

- **R1 開跑前登記，不准事後補登。** 那台**沒有任何 claim 工具**（`rlab` 原本不認得它、`~/RLAB-CLAIM`
  從來沒存在過）⇒ **那張表就是唯一的佔用紀錄，沒有第二個東西可以重讀。**
  事後補登在本機只是遲到，在這裡是**製造一段假的空窗**。
- **R1a 登記時不要自己編號碼**——我和「遠端機器測試」在同一分鐘各自取「下一個空號」都拿到 `H-15`，
  兩邊的表各自自洽、**併起來才看得見**。號碼由正本落表時配（我那筆最後是 **H-18**）。
- **R4 共用帳號暴露條款**：`chmod 600`（傳輸中就套，不是傳完才套）、講明**哪一天刪**、
  **驗狀態不驗 rc**。⚠️ **R4 管的是「停留期間誰看得到」，發佈問的是「之後誰永久拿得到」——
  通過前者不代表通過後者。**

## 🔑 頻寬：兩個讀數差 96 倍，而且兩個都對

| 路徑 | 實測 |
|---|---|
| 我的 VPN → nslab（`rsync`，2.5 GB） | **~1 MB/s**（44 分 11 秒） |
| **nslab 自己的上下行 → Google Drive（`curl`，17.9 GB）** | **~96 MB/s** |

⇒ **大檔一律在那台上抓，不要走 VPN。** 同一顆 17.9 GB 在這裡要五小時、在那裡三分鐘。
（先前記的 0.38 MB/s 是 8 MB 小樣本，量到的是連線建立成本；**錯的不是量測，是外推**——
判準是「這個量裡有沒有固定開銷，我要外推到的尺度會不會把它攤掉」。）

## 🔴 我在那台沒有 root，而且那是刻意的

`sudo -n` → `a password is required`，`/etc/sudoers.d/` 只有 OS 自帶 README。
⇒ **任何要 root 的動作都要 Adam 本人**（他用 `ssh -t`）。規定的 R11：排步驟前先問
「這條路上哪幾步要 root」，要 root 的工作放進 guest（那裡的 `ndt` 有 NOPASSWD、爆炸半徑只有一顆 VM）。

🔑 **「我按不到那個按鈕」不等於「不是我這條線的動作」。** VirtualBox 的裝與清都是**我給指令、
Adam 執行**，我主動認領了——佔用帳記的是**誰造成的**，不是**誰的手指**。

## 🏁 那台上現在有 ovftool

**`/home/nslab/ovftool-dist/ovftool/ovftool`＝ovftool 5.1.0 (build-25410048)**，Adam 08-31 自己下載的。

- **免費**，但要 Broadcom 帳號（我不註冊帳號、不輸入憑證，所以這步一定要人做）。
- **拿 `.zip` 版不要 `.bundle`**：解開就跑、**不需要 root、不需要核心模組** ⇒ 在這台沒有 sudo 的機器上唯一可行。
- 🔴 **`--verifyOnly` 不檢查磁碟雜湊**（截斷成 200 MB、翻一個 byte，兩個對照都 exit 0）。
  要真的驗就**做轉換**：`ovftool x.ova out.vmx`。細節見 [[install-manual-clean-room-test]]。

## VirtualBox：結案，不要再試

7.0.16 對 kernel 7.0.0-28 是**結構性不相容**（`modpost` 說 `vboxdrv` 用了
`kvm_enable_virtualization` 等符號但沒 import），**不是缺件**。Adam 已 purge 乾淨
（`dpkg -l` 無任何 virtualbox、`/usr/lib/virtualbox` 與 `/var/lib/dkms/vboxhost` 皆不存在、只剩無害的 `rc dkms`）。
**重試不會成功**；要 VirtualBox 只能走 Oracle 自己的 repo 裝 7.1/7.2，未試。


---

# 🔵 08-31 夜：B 輪在這台開跑（reviewer 線）——現況與兩個機制缺口

## 現況（親自跑出來的，非轉述）

| | |
|---|---|
| VM 目錄 | `~/ndtwin-vm-reviewer-B`（**自有、帶 `OWNER`＋`CONFIG`**） |
| 起點 | 由 `~/ndtwin-vm/` 的快照 **ID 3 `p4-bootstrapped-nodocker`** 以 `qemu-img convert -l … -U` 攤平（13.5 GB，原檔不動） |
| 工作點 | 16 vCPU / 16384 MiB / ssh `127.0.0.1:2223`（PREREG-B §4 凍結值，顯式明傳） |
| guest | Ubuntu 24.04.4、kernel 6.8.0-138、i7-14700、iperf3 3.16、Mininet 2.3.0、**p4c 1.2.5.16**（🔴 機器 1 是 **1.2.5.15**——manifest 要照實記這一欄差異） |
| 四臂 build | ✅ 完成。A 69.2 MB / B 88.7 MB / C 3.76 MB / D 3.77 MB；`nm -DC EventLogger`＝24/21/0/0 |
| fabric 骨架 | `bnslab_topo.py`（單跳、unshaped）＋`bmv2_binary_override`（絕對路徑、無 fallback、拒絕時不猜）＋`p4_mininet.py`（四樹逐位元組相同，已驗）；`ndtwin_switch.p4` 編出 75,306 B JSON |
| F1 force-red | ✅ **六條拒絕路徑各紅一次**（檔不存在／空／只有註解／裸名字走 PATH／路徑不存在／**libtool wrapper**）＋陽性對照放行 |

**尚未做**：八臂梯子量測。

## 🔴 缺口一：`~/ndtwin-vm/` 那顆的 **destroy 會燒掉 38 分鐘的建置成本**

它的 qcow2 裡有四顆內部快照，**ID 4 `p4-toolchain-v8` 是規定 §7 裁定保留的**。
`destroy` 的第一行字＝"This deletes $IMG and **every snapshot in it**"。
⇒ **不要 destroy 那個目錄**（遠端線已加 `KEEP` 標記，`vms`/`status`/`destroy` 三處讀得到）。

🔑 **我自己在這裡犯過一次**：我需要的是 RAM，去信卻寫「由你 destroy」。
**「釋放資源」這個詞把兩種釋放綁在一起，而它們的動作不同**——
RAM 用 `stop`（會擋住別人開跑，該還），磁碟用 `destroy`（不擋人、只有一份，不該還）。
綁在一起就會逼人在「還別人 RAM」與「保住產物」之間做一個**其實不存在的二選一**。

## 🔴 缺口二：**帳上「零佔用」而機器上有一顆跑了 4.9 小時的 VM**

19:33 我依 R1 登記前讀現場，讀到 `qemu-system-x86` pid 25269 `etimes=17564`、**RSS 13.4 GB**，
而該線二十分鐘前告訴我「全收工、量測窗沒有人開」——**每一句都是真的**。
**工作收工了，VM 沒有被 stop。**

⇒ **release 的判準要是「資源已釋放」（`ps` 上沒有你的 qemu），不是「我認為我做完了」。**
已成為正本的 **R15**（遠端線寫入）。

## ⚠️ 缺口三：工具沒有「從匯出的快照做一顆 VM」這條路

`create` 只會去下載乾淨的 Ubuntu cloud image。所以我是**手動組**的
（convert → 擺 `disk.qcow2`＋`seed.iso` → `start`），而**協調機制整組掛在 `create`/`start` 上**，
繞過去就一起掉了 ⇒ 我的 `CONFIG`/`OWNER` 一開始不存在，
**R7 的無聲降級（下次 start 變 12 vCPU/8192）對我是開著的**。
我事後補寫，**值全部由 `/proc/<pid>/cmdline` 與 `qemu-img info -U` 推導，不是打字**。
（遠端線正在加 `adopt` 動詞做同一件事。）

🔑 **順帶一個我自己種的假閘門**：補 `CONFIG` 時我寫了一行「對帳」把 `0G` 跟 `0G` 比，
它印了 `disk ✅`。**一個拿讀數跟自己比的檢查永遠會過。** 對帳要跟**獨立來源**比。
