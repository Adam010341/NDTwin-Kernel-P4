# G-7 — `ndtwin-lab` 寫死 Adam 的路徑

> 🔴 **未重裝前，這支分支不改變任何實際行為。**
> `ndtwin-lab` 的 repo 副本與已安裝的 `/usr/local/sbin/ndtwin-lab` 原本 byte-identical，
> 改完之後不再相同，而**機器上跑的是已安裝的那份**。閘門全綠 ≠ 缺陷在這台機器上修好了。
> 重裝指令在 `doc/2026-09-02_ndtwin-lab-config.md`；
> **合併時要把「重裝並重新確認兩份 byte-identical」寫成一個步驟**——
> 那個「兩份逐位元相同」原本是個安全性質：它讓「我讀的是不是 root 會執行的那份」
> 有一個一秒鐘的答案。現在它破了，補回去之前它一直是破的。

分支 `fix/g7-ndtwin-lab-config`，base `6283ff5e19e6c6cee71ba6d04019bda936c90729`（trunk，2026-09-02 23:20）。

[Co-developed with claude code -- Adam]

---

## 1. 問題（這不是 bug，是可攜性缺陷）

`KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel` 寫死，而且檔頭明講「**刻意**不可覆寫」。
代價已量測（2026-08-30，FINDING-01）：一輪把 kernel 釘在獨立 worktree 並 export `KERNEL_DIR`，
`ndt`／`stack.sh`／`components.env` 都讀到了，**這支腳本讀不到**——
於是 `topo-start` 起的是**主樹**的 `ntg_bmv2_topo.py` 與它的 128 台 host override，
而 `ndt up p4 4` 把 4 寫進 worktree 的副本、交給 kernel 一個 4-host 模型。
**Fabric 128、model 4、每一項結構檢查都綠，而且沒有任何一行輸出說了這件事。**

## 2. 修法與那 20 行檔頭的關係（🔴 這段要先讀，否則會以為我違反了它）

檔頭反對的是 **env override**，論證是：這支腳本 root-owned＋NOPASSWD sudoers，
`BRIDGE` 以 root 執行，所以讓環境選 `KERNEL_DIR` ＝ 讓任何以 adam 身分執行的東西
指定 root 要跑哪支 `.py`。**那個論證是對的，而且對設定檔一樣成立——只要那個設定檔誰都能寫。**

差別不在檔案格式，在**誰選、什麼時候選**：

| | 誰選 | 什麼時候 | 誰能做到 |
|---|---|---|---|
| env var | 呼叫者 | 每次呼叫 | 任何以 adam 身分跑的東西 |
| root-only 設定檔 | 機器管理者 | 安裝時一次 | 已經是 root 的人 |

所以本修法**不是**檔頭反對的那件事，而是它自己列的兩個出路
（「(a) 位置參數＋root-owned／allowlist 檢查」「(b) 每棵樹裝一份」）的第三種形狀。
檔頭已改寫，把這個區分寫進去。

🔑 **不要把它讀成比實際更安全。** 預設的 `/home/adam/Desktop/NDTwin-Kernel` **本來就是 adam 可寫**，
所以「root 執行 adam 可寫的 `.py`」今天已經成立。這次把**選哪棵樹**關進 root-only 的檔，
**沒有新增提權類別**；讓被執行的樹本身變 root-owned 是另一個決定，這次沒做。
（auditor 2026-09-02 同意此論證。）

## 3. 實作

三個述詞，不是一個——**因為變異閘門逼出來的**：

```
lab_conf_dir_trusted    目錄可不可信（先問）
lab_conf_file_trusted   檔案可不可信
lab_config_parse        內容說了什麼、可不可用
```

合成一個的話，**非 root 測試永遠碰不到檔案層的檢查**：目錄先判，而
「非 root 使用者可寫、同時又是 root 所有」的目錄**不存在**，所以
「受信任目錄裡的 adam-owned 檔」這個 fixture 造不出來。拆開才測得到，
閘門才能證明每一條各自會紅。（`no-owner-check` 與 `symlink-allowed` 兩個變異
一開始都**存活**，原因正是被目錄檢查擋在前面。）

**目錄先於檔案，這個順序本身就是檢查**（auditor 補的一條，正確）：
對目錄有寫權限＝可以把檔案整個換掉，那樣檔案層的檢查全部白做。
測試用「不存在的檔＋不可信目錄」把順序斷言起來，並有一個 `directory-checked-second` 變異守著它。

其餘：symlink 拒絕、**解析不 source**、只認四個鍵（未知鍵是錯誤）、絕對路徑、禁 `..`、
`KERNEL_DIR` 必須存在且含 bridge 腳本（**載入時**失敗，不是 root 建 fabric 建到一半才失敗）。

## 4. 行為變更前後對照（🔴 早上要看的）

| 情境 | 修法前 | 修法後 |
|---|---|---|
| 沒有 `/etc/ndtwin-lab.conf` | 用寫死的路徑 | **完全相同**（四個預設值逐字未動，測試逐一釘住） |
| 有一份 root-owned 0644 的設定檔 | 無此概念 | 生效 |
| 設定檔是 adam 所有／可寫 | — | **拒絕採用**，用內建預設，理由印在最顯眼處 |
| 設定檔所在目錄可被他人寫 | — | **拒絕採用**（先於檔案檢查） |
| 設定檔被拒時跑 `status`／`config` | — | **照跑**（唯讀），先印 🔴 拒絕理由＋`sudo rm` 的救援指令 |
| 設定檔被拒時跑任何會動東西的子命令 | — | **失敗關閉**，同樣印出理由與救援指令 |
| 設定檔是 symlink | — | 拒絕（rc 本來就會拒，見 §5；新增的是「說出理由」） |
| 設定檔有未知鍵／相對路徑／`..` | — | 拒絕，並指出行號 |
| `KERNEL_DIR` 底下沒有 bridge 腳本 | — | **載入時**拒絕 |
| `export KERNEL_DIR=...` | 無效（sudo env_reset） | **仍然無效**，且有測試釘住 |
| `ndtwin-lab status` | 只列 tmux sessions | 第一行多印來源與 `KERNEL_DIR` |
| `ndtwin-lab topo-start` | `topo session started` | 多印它是從哪棵樹起的 |
| `ndtwin-lab config` | 不存在 | 新子命令，印出五個實際生效的值 |
| 被 `source` | 執行到 root guard 就 `die` | 定義完函式就 return（測試用的縫） |

🔴 **repo 內副本與已安裝的 `/usr/local/sbin/ndtwin-lab` 從此不同。**
兩者原本 byte-identical。**我沒有碰已安裝的那份**（auditor 明令，且那是提權路徑）。
要生效必須有人刻意重裝（指令在 `doc/2026-09-02_ndtwin-lab-config.md`）。
**sudoers 不用改**：檔名、路徑不變，只多一個 `config` 子命令。

🔴 **與 G-9 衝突**：兩支都改 `tools/test_workflow/ndtwin-lab`，且本支從 trunk 長出去。
建議合併順序 **G-9 → G-7**（auditor 已同意），G-7 rebase。

## 5. 變異閘門紅→綠

`tests/shell/mutate_g7_ndtwin_lab_config.sh`：

```
=== baseline (the fix, unmutated) ===
  rc=0  red=

=== mutations ===
  no-directory-check         caught by:   but world-writable, so it is refused
  directory-checked-second   caught by: a bad directory refuses before the file
  no-owner-check             caught by: a file owned by this user is refused
  symlink-allowed            caught by:   and says it will not read the target
  source-instead-of-parse    caught by:   and was NOT executed
  unknown-key-ignored        caught by: unknown-key is refused
  no-bridge-validation       caught by: a KERNEL_DIR with no bridge script
  environment-gets-a-vote    caught by: an exported KERNEL_DIR is ignored
  default-tree-changed       caught by: KERNEL_DIR is the pre-G-7 default
  gate-locks-out-status      caught by: status still runs
  gate-lets-everything-run   caught by: topo-start does NOT
  no-restore-on-refusal      caught by:   a half-applied file leaves no residue
  refusal-is-silent          caught by: the refusal is announced
  no-removal-instructions    caught by:   and says how to remove the file
  control-comment-only       SURVIVED (control, as required)

restore: tools/test_workflow/ndtwin-lab is byte-identical to the pre-gate snapshot

VERDICT: every mutation was caught by the check named for it; the control survived
```

測試 `tests/shell/test_ndtwin_lab_config.sh`，59 checks 全綠。

**閘門在這一支抓到的四件事**（都是讀碼看不出來的）：

1. `no-owner-check`、`symlink-allowed` 兩個變異**存活**——被目錄檢查擋在前面，
   檔案層的斷言其實一條都沒被執行到。→ 拆成三個述詞。
2. `symlink-allowed` 改成拆分後仍然「紅在別的檢查」：**刪掉 symlink 拒絕，symlink 還是會被拒**，
   因為 `stat` 不解參考、報的是 link 本身，而 link 是 mode 777、被 group/other-writable 那條擋下。
   所以明確的 symlink 檢查**不改變 rc**，它買到的是「說出理由」＋擋住未來有人改成 `stat -L`。
   **斷言因此寫在訊息上，而且測試裡寫明了為什麼**——不是因為 rc 剛好不方便。
3. **09-03 改完之後**：`no-restore-on-refusal`（把還原那四行刪掉）**存活**。
   原因是我這個測試造得出來的檔**一定先被信任檢查擋下**，`lab_config_parse` 根本沒跑到，
   所以沒有東西需要還原 ⇒ 那條斷言不必還原存在也會過。
   改成先直接呼叫 `parse` 製造半套用、再讓 `load` 去收拾，才碰得到那段碼。
   （而那不是造作的形狀：它就是「load 執行時值已經不是預設」，
   也正是還原要讀 `LAB_DEFAULT_*` 而不是進入時快照的理由。）
4. 測試套件本身：`source ndtwin-lab` 會把 `set -e` 帶進測試，而一個題材就是「故意觸發失敗」的套件
   在 errexit 下**會中途離開卻仍然把已跑過的每一條印成 `ok`**——看起來像通過，只是提早結束。
   （實測：停在「and it says what is missing」，連結尾的 `Ran N checks` 都沒有。）已 `set +e`。

## 6. 風險與回退

**風險**

1. `status` 與 `topo-start` 的輸出多了一行／一段。有 script 在 parse 這兩個輸出的話會受影響。
   repo 內盤點過兩個消費者，**都親自跑過**：
   - `ndt` 的 `lab_session`（`tools/test_workflow/ndt:411`）比對 `*$'\n'"$1":*`。
     `tools/test_workflow/test_ndt_lab_session.sh` 宣稱涵蓋「`ndtwin-lab status` 能產生的每一種
     形狀」，我加了新形狀進去（4 條，18 passed）——**不加的話那句宣稱就變成假的**。
     其中一條是這條修法新造出來的 near-miss：`KERNEL_DIR` 裡剛好含 `topo:` 的路徑。
   - `lib_e.sh:749` 輪詢 `'bmv2: 10'`（子字串比對，不受首行影響）。
2. `config` 是新子命令，舊的 usage 字串改了。
3. ~~設定檔一旦不可信就整支失敗（連 `status` 都不能用）。~~
   **2026-09-03 依 auditor 裁決改掉一半。** 方向保留——**會動東西的子命令一律失敗關閉**，
   因為不可信的檔不該決定 root 跑哪棵樹。但 `status` 與 `config` 是**唯讀**的，而且正是
   打錯一個字之後你會用來搞清楚發生什麼事的那兩個命令；把它們一起鎖掉，
   等於讓救援路徑只剩「已經知道要 `sudo rm /etc/ndtwin-lab.conf`」，
   不知道的人會以為 lab 壞了。

   現在：拒絕的是**採用那個設定檔**，不是執行。內建預設留在原位，
   `LAB_CONF_ERROR` 記下理由，`lab_conf_gate` 在任何子命令之前把理由（含檔案路徑與
   `sudo rm` 指令）印到 stderr，然後唯讀的放行、其餘的 `die`。
   這不弱化安全性：`status` 不碰任何東西，而「拒絕採用」比「不能執行」提供更多資訊。

   🔑 **還原不是整潔問題**：`lab_config_parse` 是邊讀邊賦值的，所以第三行壞掉的檔
   已經套用了前兩行——**半套用的設定比檔案或預設都糟，因為它對不上任何人寫下來的東西**。
   還原讀的是 `LAB_DEFAULT_*` 而不是「進入 load 時的值」，因為後者只在 load 只被呼叫一次時
   才等價，而那正是這個 repo 一直在付錢的那種假設。
4. 新的 sourced-guard 讓這個檔可以被 `source`。sudo 一律 exec 不 source，所以已安裝路徑不受影響。

**待 live 驗證**（需要 root／真 lab，claim 在 auditor 手上）

- L1 `sudo ndtwin-lab config` 在**沒有**設定檔時印出四個預設值。
- L2 裝一份指向 worktree 的設定檔，`config` 與 `topo-start` 都要顯示那棵樹。
- L3 故意裝一份 adam-owned 的，確認被拒絕且訊息說得出理由。
- L4 重現 FINDING-01 的情境：worktree 128／主樹 4，確認現在**看得見**是哪棵樹。

**回退**：單一 commit，`git revert`。已安裝的 `/usr/local/sbin/ndtwin-lab` 沒被動過，
所以回退不需要重裝、也不需要碰 sudoers。
