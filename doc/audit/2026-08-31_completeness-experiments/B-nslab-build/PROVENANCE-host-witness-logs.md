# PROVENANCE — `raw/host_witness_a_rerun.log` 與 `raw/host_witness_bcd.log`

**2026-09-01 立，由「遠端機器測試」線；auditor 指示**
**適用對象**：任何要引用這兩個檔的人。**引用前讀完這頁。**

[Co-developed with claude code -- Adam]

---

## 一、它們記的是 **nslab 的宿主**，不是 Adam 的筆電

這兩個檔每一行長這樣，**沒有 hostname 欄**：

```
23:57:39 load=0.58 qemu=1 pids=52578
```

| | |
|---|---|
| `host_witness_a_rerun.log` | **150 筆**，23:57:39 → 00:10:10，唯一 pid＝`52578` |
| `host_witness_bcd.log` | **200 筆**，00:14:12 → 00:30:54，唯一 pid＝`52578` |

**`pid 52578` 在 nslab 上**（09-01 01:39 與 02:0x 兩次實查，相隔近半小時，**當時仍在跑**）：

```
$ ssh nslab 'ps -o lstart=,etimes=,args= -p 52578'
Mon Aug 31 20:19:30 2026   19717   qemu-system-x86_64 -name ndtwin-lab-vm -machine q35,accel=kvm
                                   -cpu host -smp 16 -m 16384 -drive file=/home/nslab/...
```

⇒ 那是 **B 輪自己那顆 VM**（`~/ndtwin-vm-reviewer-B/`，owner `8/29 poster-reviewer`）。
[`FINDINGS.md`](FINDINGS.md) §7.7 也是這樣寫的：「**宿主上**…**僅本輪的 VM 52578**…
`3.98` 是**本輪 guest 自己的 16 vCPU 工作在宿主上的投影**」。

**三個交叉檢查，都在幾秒內跑得完**：

1. **16 vCPU 的投影**——nslab 28 核；Adam 的筆電 `nproc` ＝ **14**。
2. 筆電上 `/proc/52578` **不存在**；那台唯一的 qemu 是
   `pid 405062 claude-cowork-vm`，**起於 08-30 19:41** ⇒ **整段 23:57–00:30 都在跑**。
   ⇒ **若這兩份記的是筆電，350 筆全部會是 `405062`，而且永遠不會出現 `52578`。**
3. 目錄名 `B-nslab-build` 是**線索，不是欄位**——而下一個讀者會拿它當欄位用。這正是下面第三節那件事。

## 二、~~產生它們的腳本**未進版控、不可重現**~~ → **已由 B 輪線重建並落檔（09-01）**

> 🔴 **本節寫的當下為真，現已被取代。** B 輪線把當時執行的那條指令從自己 transcript 的
> `tool_use` 輸入逐字還原，落成
> [`host_witness_sampler_RECOVERED.sh`](host_witness_sampler_RECOVERED.sh)（`ac426d6`），
> 並誠實標成**「重建的指令，不是找回的檔案」**——原本就沒有腳本檔，
> 是 `ssh nslab '... setsid bash -c "..."'` 的一行式，所以 nslab 上與版控裡都不會留下東西。
>
> ⇒ **「不可重現」不再成立；「當時未進版控」仍然成立。** 兩句要分開讀。

原因仍值得記：`git grep -l host_witness` 當時只命中 `.md` 與 `.py`。
⇒ **證據進了版控，儀器沒有**——而救回它的是**執行者自己的 transcript**，不是檔案系統。
🔑 **一行式的 ssh 指令是「不會留下痕跡的儀器」的典型**：它跑在別台、寫在別台、
自己不落地。要它可稽核，只有兩條路——**寫成檔案**，或**當場把指令本身抄進紀錄**。

🔁 **替代品**：[`tools/remote-lab/host_witness.sh`](../../../../tools/remote-lab/host_witness.sh)（`beb45fc`）
——每行與檔頭都帶 `host=`；用 `/proc/<pid>/exe` 判別而非 argv；
三態 `vm`／`other`／**`unreadable`**（「讀不到」不可壓成「不是 VM」）。

🔁 **替代品**：[`tools/remote-lab/host_witness.sh`](../../../../tools/remote-lab/host_witness.sh)（`beb45fc`）
——每行與檔頭都帶 `host=`；用 `/proc/<pid>/exe` 判別而非 argv；
三態 `vm`／`other`／**`unreadable`**（「讀不到」不可壓成「不是 VM」）。

🔴 **格式不同，不可與這兩份混用**。這兩份是 `load=/qemu=/pids=`，新的是
`host=/load=/vms=/pids=/unreadable=`。**不要把兩種格式餵給同一支解析器。**

### 2a. 🔴 更正一句：**那支 sampler 不受「argv 假冒」影響——我把自己的警告套寬了**

`host_witness_sampler_RECOVERED.sh` 的檔頭寫「遠端機器測試線關於 argv 形狀 fixture 的警告
**適用於**這支 sampler」。**實測不成立**，因為它數的是 `ps -eo comm`：

```
$ bash -c 'sleep 2; :' qemu-system-x86_64 -smp 7 -m 3333 &
/proc/<pid>/comm     : bash                    ← 來自執行檔名，行程設不了
/proc/<pid>/cmdline  : bash -c sleep 2; : qemu-system-x86_64 -smp 7 …
```

⇒ **`comm` 是執行檔名，`argv[0]` 是行程自己寫的。** 用 `comm` 數的不會被那種 fixture 騙。
（`prctl(PR_SET_NAME)` 或把二進位檔改名仍可改 `comm`，所以它不是防偽的，只是**比 argv 準得多**。）

🔑 **但那支 sampler 檔頭的第 2 點成立而且更重要**：**非 VM 的外來負載對 `qemu=` 欄完全不可見**，
唯一的通道是 `load=`（load1，落後複合指標）。
⇒ **「這段窗連續有帳」對 VM 精確，對外來負載一般而言是誇大。**

⚠️ **而這條照到我自己**：`tools/remote-lab/ndtwin-vm.sh` 的 `qemu_pids()`
比對的是 **cmdline（argv）**，不是 exe——**我警告別人的那個缺陷，就在我自己的協調工具裡**，
而我的測試 fixture 之所以會過，正是因為它。已登記待修（要連 fixture 一起改：
用一份改名成 `qemu-system-*` 的真二進位檔，`exe` 才會解析到對的名字）。

## 三、09-01 有人（auditor）把它誤讀成本機佔用，據此要求下游撤回**正確**資料

- auditor 讀到 350 筆 `qemu=1`，判「遠端機器測試線 23:57–00:30 在 Adam 筆電上開著 VM」，
  要求 E 輪撤回兩欄敏感度分析、四格判髒。
- mainDev 據此照做：重寫分類器、命中格從 **5/19 改成 14/20**、拿掉「乾淨」欄、
  得出「那個比較根本算不出來」，並已 commit。
- 逐條查證後 auditor **自行撤回**（它在本機獨立複驗），mainDev **還原全部數字**
  （`1.987`／`1.768` 一個字不改，KNOWN-OVERLAP **5/21**）。

> 🔑 **一個坑最有用的標記，是上一個掉下去的人留的**（auditor 語）。
> 所以這一節有日期、有具體後果，不是泛泛的提醒。

🔑 **兩邊各自的自我診斷，比事件本身可轉移**：

- auditor：**「我看到 `host_witness`，把 host 綁到我自己站著的那台機器上，因為檔案在這個 repo 裡。
  檔案在這個 repo，是因為**結果** commit 到這裡；**量測不在這裡做**。」**
- mainDev：**「我驗的是『這些數字是不是真的』，不是『這些數字講的是哪一台』——
  而只有第一個有一個顯而易見的地方可以查。」**（它驗到 350/350 同一個 pid，**停在往下三行那句
  說明它在講什麼的話之前**。）

## 四、為什麼這張便條在這一層，不在 `raw/` 裡

`raw/` 被 `.gitignore:74`（`doc/audit/**/raw*/*`）排除，且 `tools/githooks/pre-commit`
**拒絕 raw 進 `audit-raw` 以外的任何分支** ⇒ **放進 `raw/` 的便條進不了版控。**

而那兩個 `.log` 在 **`audit-raw`** 分支（`429851e`、`fc96044`）。
🔴 **我沒有把便條加進 `audit-raw`**：那要切分支，而**共用 worktree 裡切分支會影響所有 session**
——為了放一張便條做這件事，代價比它防的還大。

⇒ **本檔放在引用點旁邊**（[`FINDINGS.md`](FINDINGS.md) §7.7 就是引用它們的地方），
並在 `raw/` 留一份工作樹副本給直接翻目錄的人。**從 `audit-raw` 那側進來的讀者看不到它**
——這是已知的缺口，不是遺漏。
