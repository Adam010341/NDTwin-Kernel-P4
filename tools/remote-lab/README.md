# `tools/remote-lab/` — 遠端 lab 機器的佔用協調與 VM 生命週期

> 🟢 **`nslab` 可以用**（2026-08-31 晚間解封）。🔴 **testbed 那批（server1~8／cc2／gw／gw2）仍然停用。**
> 先問，不要用試的：`rlab suspended <machine>`（**不撥號**）。
>
> **使用規定與佔用帳的正本＝[`doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`](../../doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md)。**
> 這份 README 只講工具；**要不要用、什麼時候登記、登記什麼，看那份規定。**
> 🔴 **R1：開跑前登記，不准事後補登**——那台沒有 claim 工具，佔用表是唯一紀錄。

## 為什麼有兩層

爭用單位有兩個，而**只做機器層是不夠的**：

| 層 | 工具 | 單位 |
|---|---|---|
| 機器 | `rlab` | 一台實體機（`~/RLAB-CLAIM` 是那台上的真實來源） |
| **VM** | `ndtwin-vm.sh` | **一顆 VM** |

2026-08-31 的實例：兩個 session **共用同一台機器沒事**（Mininet netns／OVS datapath 的衝突
是 per-kernel 的），但它們**落在同一顆 `disk.qcow2` 裡**——因為 `VM_DIR` 與 `SSH_PORT`
**兩個預設值互相獨立**，只改其一的第二個 session 就直接疊上去，而且**沒有任何一層會報錯**。
發現的方式是快照列表裡出現沒人建過的快照。

## 檔案

| 檔 | 跑在哪 | 用途 |
|---|---|---|
| `rlab` | 操作者的機器 | 機器層 claim：`list` / `status` / `claim` / `note` / `release`，＋ `suspended()` 停用表 |
| `ndtwin-vm.sh` | 遠端 host（**不需要 root**） | VM 生命週期＋協調守衛＋`vms` 跨 session 視圖 |
| `ndtwin-virt-root.sh` | 遠端 host（**唯一要 root 的一步**） | 裝 `qemu-system-x86`／`qemu-utils`／`cloud-image-utils`＋帳號加進 `kvm` 群組。**不碰 sudoers、不加任何 NOPASSWD** |
| `vm-install-stack.sh` | **guest VM 內** | 安裝手冊 §3.1＋§3.2 apt ＋ `install-p4dev-v8.sh`。**驗收釘產物不釘 rc** |
| `p4_patch_preflight.sh` | 任何有網路的機器 | 2 分鐘 dry-run：p4-guide 的 patch 還套不套得上（**v10 當控制組**） |
| `test_vm_coordination.sh` | **本機，不碰任何 lab 機器** | 下述全部守衛的變異閘 |

🔑 **`/dev/kvm` 是 `root:kvm`**，所以「要不要 root 才能開 VM」的開關就是**群組成員資格**。
桌面登入時 logind 會給一條 `user:<帳號>:rw-` 的 **ACL**，但**人一登出就收回**，SSH 進來的
session 會突然開不了 VM。**ACL 是借來的，群組才是自己的**；而群組只對**新登入**生效。

## `ndtwin-vm.sh` 的守衛（每一條都是踩過才有的）

| 守衛 | 行為 | 起因 |
|---|---|---|
| `NDT_OWNER` 必填 | 缺就拒絕（fail closed） | 把 `unset` 寫進登記等於一個永遠不會紅的閘門 |
| `$VM_DIR/OWNER` | 別人的 VM → **`rc=3`**，印出對方的 claim 與「開自己那顆」的完整指令 | 兩個 session 同一顆 qcow2 |
| `SSH_PORT` 佔用 | → **`rc=4`**，列出誰佔的 | 碰撞的真正機制 |
| `CONFIG` 工作點 | env ＞ CONFIG ＞ built-in；落到 built-in 而磁碟已存在就**大聲警告** | 一次 `stop→snap→start` 沒重帶參數，16 vCPU/16 GiB 的 lab **無聲地以 12/8192 開回來**。什麼都沒失敗、guest 開得好好的 |
| 快照通用名 | `fresh`/`base`/`clean`/… **直接拒絕**；`snap` 先讀再寫、tag 已存在也拒絕 | `qemu-img` **允許重複 tag 而且完全不報錯** |
| 快照列表 | `-U` 讀得到；**「讀不到」與「沒有」印成兩種不同的字** | 舊碼是 `qemu-img snapshot -l … \|\| say "(no snapshots)"`——鎖住讀失敗被翻譯成「磁碟是空的」，**不是報錯，是一個有自信的錯誤答案**。這是同名快照的**病因**，通用名只是症狀 |
| `NDTVM_FORCE=1` | 可以搶，但**會把搶奪這件事寫進被搶的 `OWNER` 檔** | 看不見的旁路不是守衛 |
| `vms` | **唯讀、不需要 `NDT_OWNER`** | 查「誰佔了什麼」不該以「你已經佔了東西」為前提，否則第一個想禮讓的人反而被擋在門外 |

`rlab` 的 `suspended()` 同理：**對停用機器連都不連就拒絕**，並印出誰說的／何時／解封條件／
有沒有替代機器。**刻意沒有環境變數旁路**——解封要改這支 script，留得下 diff。

## 驗收

```bash
bash tools/remote-lab/test_vm_coordination.sh
```

**32/32**（2026-08-31，筆電與 `nslab` 上各驗過一次）。每個閘門 **force-red 與 force-green 各一次**，包含停用表自己的
green 方向（不在表上的機器要正常落到 `unknown machine`，證明它不是無差別拒絕）。
斷言比對**訊息文字**不只比對 rc——好幾種不同的失敗都是 `rc=1`。

🔑 **測試自己也是受測物**：第一版拿「內容不是 qcow2 的文字檔」當「讀不到」的 fixture，
**但 `qemu-img` 會把它猜成 raw，而 raw 就是零個快照 ⇒ 讀成功、空的** ⇒ **那個測試對舊的壞碼
也會過**。改用 `chmod 000` 的真 qcow2 才真的紅。

🔑 **路徑一律相對於腳本自己**。寫絕對路徑的 harness 測的是那個路徑上的副本——一旦
repo 與 `~/.local/` 各有一份，**測到的就不是讀者剛 checkout 的那一份**。

## 不在這裡的東西

- `ndtwin-bootstrap.sh` / `ndtwin-lab.server8`：**server8 專用**，而那台的部署已凍結。
  留在 `~/.local/share/ndtwin-remote/`，等處置裁決下來再決定去留。
- **機器位址**：`rlab` 只認 ssh 別名（`nslab`、`cc2`、`gw`、`gw2`），位址在 `~/.ssh/config`。
  這個 repo 有**公開的上游**，而那些位址是 DHCP 給的、只在 VPN 內解析得到。
- **任何憑證**。這批腳本從不持有密碼或金鑰；唯一要密碼的是 `ndtwin-virt-root.sh`，
  由**人**自己 `sudo` 跑。

[Co-developed with claude code -- Adam]
