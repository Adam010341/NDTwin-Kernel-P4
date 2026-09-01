# §B — 量到的是什麼，以及它與 ③ 差在哪

**2026-09-01 11:1x–11:3x CST 立，於資料產生的同時；本檔不含任何結果。**
結果在 `FINDINGS.md`。本檔的用途是：**在讀到任何數字之前，先固定「這些數字是關於誰的」。**

[Co-developed with claude code -- Adam]

---

## 一、受測物的身分（全部從 `/proc` 指認，不從 argv、不從 HEAD）

| 項 | 值 | 怎麼取的 |
|---|---|---|
| 交換機 binary | `/usr/local/bmv2-fast/bin/simple_switch_grpc` | `sudo -n mnexec readlink -f /proc/<pid>/exe` |
| 交換機 sha256 | `3ff54b5c1901c9d3ffd80ac05dc3dc7d0e696e3df73174c1616fb87ac9aedb4a` | 同上，且**與磁碟上該路徑逐位元相符** |
| 交換機顆數 | **10，全部同一顆 binary** | 掃 `/proc/*/exe`，`sort \| uniq -c` ⇒ 單一項目 ×10 |
| kernel binary | `build/bin/ndtwin_kernel`，mtime `09-01 07:25` | `readlink /proc/1034020/exe` |
| kernel sha256 | `e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94` | `sha256sum` |
| P4 程式 | `p4_proxy/p4_src/ndtwin_switch.p4`（已提交、無未提交改動），編譯產物 `build/ndtwin_switch.json` **比原始碼新** | `git status` ＋ `find -newer` |
| 取樣率 | **1/256**（編譯進 `ndtwin_switch.json`） | `ndt up` 自報 |
| 拓樸 | `StaticNetworkTopologyP4_10Switches_128Hosts.json`，128 host | `ndt status --check`（rc=0） |
| fabric 驗證 | 10 sw／10 up／288 links／0 down／**16256 of 16256 destination paths**／`h1 -> 10.0.0.2 forwards` | `ndt up` §[3/3] ＋ `ndt status --check` |

🔴 **「跑 `ndt up` 時的 HEAD」不等於「現在的 HEAD」。** `ndt up` 在 11:15 執行，當時
`963a588` ＋6 個未提交檔；寫本檔時 HEAD 已是 `087a821`（其他 session 在同一個
worktree 上提交）。**受測的是 11:15 那個樹，不是任何一顆 commit 的名字。**
（[[cited-line-numbers-are-not-evidence]]：一次正確的量測會無聲過期。）

## 二、🔴 我自己儀器的一個缺口，記在這裡因為 `cell.meta` 裡是錯的

`run_tcp_cell.sh:69-72` 用 **無 sudo 的 `readlink` / `sha256sum`** 去讀 root 擁有的
`/proc/<swpid>/exe`。這台機器上那兩個指令**不在免密碼清單裡**，所以每一格的
`cell.meta` 會寫成：

```
switch_pid=994702 exe=UNREADABLE
switch_sha256=
```

⚠️ **注意失效方向：它寫的是 `UNREADABLE` 與一個空字串，不是一個錯的雜湊。**
這次是大聲失敗，所以我發現得了。但**空雜湊在別處已經當過哨兵**
（[[failures-that-report-success]]），一個把空字串當「相符」比對的檢查會亮綠燈。

⇒ 正確值＝上表第一節（走 `sudo -n mnexec`）。**`cell.meta` 的那兩行以本檔為準。**
儀器本身待修，但**不在本輪修**——改動一支正在產生資料的量測腳本，
會讓前後幾格不是同一個儀器量的。

## 三、與 ③ 的差異（逐項，不挑對自己有利的講）

③ ＝ `doc/audit/2026-08-28_flow-count-capacity/`，2026-08-29 00:35–00:56。

| 項 | ③ | 本輪 | 判 |
|---|---|---|---|
| 交換機 binary 路徑 | `/usr/local/bmv2-fast/` | 同 | ✅ 相同 |
| 拓樸／host 數 | 128-host P4，10 switch | 同 | ✅ 相同 |
| 主機對 | h1→h65（s1→s3，五跳） | 同 | ✅ 相同 |
| 傳輸協定 | **UDP** | **TCP** | 這正是本輪要對照的那一維 |
| kernel commit | 記為 **`a40e04ce`** | 11:15 的工作樹（`963a588`＋6） | 🔴 見下 |
| 取樣率 | **未在 ③ 的 FINDINGS／PREREG 中記載** | 1/256 | ⚠️ 不可比對，因為一邊沒有值 |
| 同機佔用者 | 未記載 | **Adam 的 `claude-cowork-vm`（pid 405062）全程在跑**，見證逐筆記錄 | ⚠️ 記錄，不排除 |

### 3.1 🔴 `a40e04ce` 在這個 clone 裡解析不出來

```
git cat-file -t a40e04ce      -> fatal: Not a valid object name
git ls-remote {lab,origin,p4} -> 零命中
git reflog --all              -> 零命中
```

⇒ ③ 的 FINDINGS 指名的 kernel commit **在本 repo 與三個 remote 上都不存在**。
可能的原因（未查證，不要當結論）：分支被 rebase 掉、或該雜湊本身有誤。

**這不影響本輪**——本輪指認的是自己跑的那顆 binary 的 sha。
但它影響 ③：**③ 的 kernel 身分目前不可複現**，而 ③ 是論文三個主實驗之一。
🔑 **這一條要獨立報，不要埋在 §B 的附註裡**——它是關於 ③ 的，不是關於 §B 的。

### 3.2 取樣率無法對帳，而它不是小事

遙測取樣率影響交換機 CPU。③ 沒有記下自己的值 ⇒ **「同一個平面」這句話在這一維上
是未經檢查的**。本輪照實記 1/256；若之後要把兩輪的絕對值並排，**必須先補查 ③ 的值**。
（本輪的判定是**同輪內的比值** `T(16)/T(1)`，兩邊共用同一個取樣率 ⇒ 這個差異不進入該比值。）

## 四、對照本身的界限（在讀它的判定之前先寫下來）

loopback 對照跑在 **h1 的 namespace 內、127.0.0.1**，所以：

- ✅ 它**測得到**「十六條並發 TCP 在單一主機上的排程／socket 壓力」——那正是它要排除的那個混淆。
- 🔴 它**測不到** veth 與 qdisc 層的 per-flow 效應：loopback 路徑上沒有 veth、沒有 qdisc、
  沒有第二個 namespace。⇒ 對照通過**不代表**「fabric 上的塌陷一定發生在 bmv2 內部」，
  只代表「不是宿主自己的並發塌陷」。**兩者不是同一句話。**
- ⚠️ 工作點也不同：loopback 的絕對速率遠高於 fabric 格。方向上這對結論有利
  （宿主在高得多的負載下都不塌），但**它不是同工作點的對照**，照實寫。

## 五、見證

`raw/host_witness.log`——`tools/remote-lab/host_witness.sh`（`beb45fc`，由「遠端機器測試」線提供），
**每行帶 `host=`、以 `/proc/<pid>/exe` 判別 VM 而非 argv**，5 秒一筆，
由 driver 作為**直接子行程**啟動、以記下的 pid 停止（不用 pattern）。

🔑 這是昨晚那條教訓第一次被實際使用：我自己那支見證器沒有 hostname 欄，
害得別條線撤回了兩欄正確資料（[[benchmark-must-name-the-binary-it-measured]]）。

⚠️ 同一支工具在本輪也被抓到一個缺陷（未辨識的旗標會變成 interval ⇒ 忙迴圈取樣），
已回報。**本輪用的是數字 `5`，不受該缺陷影響**，且 header 自陳 `interval=5s`。

[Co-developed with claude code -- Adam]
