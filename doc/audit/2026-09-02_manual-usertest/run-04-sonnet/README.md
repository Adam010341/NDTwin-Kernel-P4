# run-04（sonnet）— A-7「naive user」campaign 第四輪

**這一輪確立的事：把手冊改對，缺陷就會消失，而且對應是乾淨的。**
run-04 刻意重複 run-01 的模型（皆 sonnet），只換手冊（`bcf98f5` → **`2612b0a`**），
於是兩輪的差異可歸因到文件。結果：run-01 的**十一條缺陷裡有五條半純粹因為改了文件而消失**
（#001／#002／#003／#007／#008，加上 #011 的揭露那半），而**重現的四條，每一條我們事前都在
帳本上寫下了「不修，理由是 X」**（#004 G-7／#005 G-6／#006 NSR stop script／#009 pnpm）——
**零意外**：沒有一條「改了卻沒消失」，也沒有一條「沒改卻消失了」。
tester 跑滿 **6h48m** 並自行收尾，**通過 Adam 的判準（§1–§6，四比四）**，
過程中有**兩次 harness 干預**，均已逐字記錄、內容僅涉及它對自身執行環境的誤解。
它另外撞出 **7 條新缺陷**，其中 **BUG-3** 由本線讀碼後從「有一支孤兒行程」推進到
**「`ndt up` 的失敗路徑會漏出一支活的 `stack.sh`，它接著把 kernel 起到別人的 fabric 上」**。

## 目錄索引

| 檔案 | 是什麼 |
|---|---|
| **`VERIFICATION.md`** | **逐條複驗表**：81 條宣稱 × 佐證檔 × 逐字節錄 × 判定（58 CONFIRMED／2 mis-stated／1 in-part／**20 UNSUPPORTED**／**0 CONTRADICTED**），外加十則註記——註 ① 查明 BUG-3 的來源與機制、註 ② 證明那個 OK banner 與 ping 結果零關聯、註 ⑦ 是本輪最重要的取證發現 |
| **`RECONCILIATION.md`** | **對帳**：九條 R12 預期逐條裁定（中 5／部分中 3／未測 1／不中 0）、**run-01↔run-04 十一條對照表**、四輪比較、兩次干預的分類與洩漏檢查、**Adam 判準的四子句逐條裁定**、帶進 run-05 與 A-8 的事項 |
| `DOCS-FIX-MAP.md` | 派工前寫的：`2612b0a` 改了哪三筆、**故意沒改哪些以及為什麼**。讀 RECONCILIATION §2 之前先讀它 |
| `tester-files/` | tester 留在 guest 的東西（140 檔），原樣拉回、未編輯 |
| `orchestrator-scripts/` | 本線的採證腳本（`recon04.sh`／`harvest04.sh`／`pull04.sh`），全部唯讀＋打包 |
| `orchestrator-evidence/` | **跑到一半時**的唯讀觀測，證明 §6.1 的 detached 指令被逐字照做（R12 ② 的直接證據） |

## 讀的順序

1. 本檔 → 知道這一輪要換的是「歸因」。
2. `RECONCILIATION.md` **§2** → 十一條裡消掉幾條，**這是交付物**。
3. `RECONCILIATION.md` **§5** → 判準的四子句逐條裁定。
4. `VERIFICATION.md` **註 ①** → BUG-3 的真正形狀（與 tester 自己寫的不同）。
5. `VERIFICATION.md` **註 ⑦** → 20 條 UNSUPPORTED 為什麼全部落在同一條分界線上。

## ⚠️ 引用之前必須知道的三件事

1. 🔴 **引用 tester 的任何數字之前，先在 `VERIFICATION.md` 查它的判定。**
   本輪 **20 條宣稱沒有檔可查**——其中包括三個很好用的數字：
   **「每台 130 條流表」「iperf3 ~955 Mbit/s」「P4 stock build ~34–37 Mbit/s」**，
   以及 BUG-2 最漂亮的那一格（「同一對主機幾秒後手動 ping 通」）。
   **`0 CONTRADICTED`**——凡是有旁證的都對得上，問題是**我們拿不到它看到的東西**，不是它看錯了。
   分界線很乾淨：**它 tee 到 `~/logs/` 的全部可查，只在自己回合裡讀過的全部查不到。**
2. 🔴 **BUG-3 的正本是 `VERIFICATION.md` 註 ①，不是 `tester-files/BUGS.md`。**
   tester 被規則禁止讀原始碼，只能列兩個候選並誠實地不選。本線讀了碼，**排除了候選 (b)**，
   並補上機制與時間算術。BUGS.md 的 severity 段還有一句需要更正的口徑
   （它說 `ndt down` 報告乾淨時孤兒已存在——實際上 `ndt down` 早了 2 分 41 秒，那一刻它沒說謊）。
3. **手冊本身沒有被採證。** guest 的 `~/ndtwin-docs/` 只留了 `DOCS-SNAPSHOT.txt`
   （`website commit: 2612b0a`），42 個 md 本體沒進 tar，且該目錄不是 git repo。
   ⇒ 凡是「手冊上寫著 X」的宣稱，本線只能靠 tester 的引用，**無法獨立覆核**。VM 映像已保留，需要時可重取。

## `tester-files/` 裡有什麼

| 路徑 | 內容 |
|---|---|
| `JOURNAL.md` | **517 行，這一輪的正本**，17 節，每節有 `started`／`ended`／`friction`（0–3），**結尾有完整的 `## SUMMARY`**（run-03 沒有） |
| `BUGS.md` | 618 行、**13 則條目**（6 個編號 BUG ＋ 3 則 addendum／update ＋ 4 則 minor slip／note）。格式：feature · 手冊頁 · steps · expected（引用）· observed（逐字）· reproduced? · severity |
| `CHECKLIST.md` | 115 行、八個區段（A–H）。⚠️ 與 run-03 不同，**這一份是成績單**：mtime 18:25:27，是全輪最後被寫入的檔之一，逐項標了 WORKS／WORKS-BUT／BROKEN／NOT-TRIED（附理由） |
| `JOURNAL.md.bak-dedup` | 492 行。tester 自己發現腳本把三節重複貼了兩次，刪掉並留下這份 pre-edit 備份——**主動揭露，不是被抓到** |
| `logs/` | **54 個檔**。kernel／ryu／build／install／deploy 的長期輸出，本輪所有 CONFIRMED 的來源 |
| `log.txt` | 1.5 MB、14605 行，§6.1 完整安裝紀錄。`:14241` ＝ **`Total time : 7748 sec`**、`:14605` ＝ `SCRIPT_EXIT=0` |
| `Desktop/NDTwin-Kernel/test_run-harvested/` | ⚠️ **原名 `.test_run/`，改名是為了繞過 repo 根 `.gitignore:21` 的 `.test_run/` 規則**——那條規則不分路徑，run-02 的採證就是這樣被靜默吃掉的。理由寫在該目錄的 `WHY-RENAMED.txt`。**`logs/kernel.log` 是 BUG-3 破案的關鍵證據** |
| `tester-scripts/` | 它自己寫的 60 支驅動腳本與 24 個 checklist patch，原本在 `~`（不是 `/tmp`），移進子目錄只為了讓上層可讀，內容未編輯——見 `WHERE-THESE-CAME-FROM.txt` |
| `GUEST-STATE.txt` | 採證瞬間（18:37:15Z）的機器狀態：tmux（**全滅**）、listeners、repo HEAD、`.local` 的 birth time、`.profile` 的 PATH 段、六個直譯器能不能 import mininet、`p4setup.bash` 之後的三條 `--version` |
| `pane_capture_errors.txt` | ⚠️ **`NO TMUX SERVER AT HARVEST TIME`**——這一輪**一格 pane 都沒採到**，因為 tester 收尾時把所有 session 都關乾淨了 |
| `.bash_history` | 只有兩行——它幾乎所有指令都是透過腳本跑的，所以 history 不是可靠的行為紀錄 |

**採到但刻意不進版控**：`~/install-details/`（16 MB、8 個純路徑清單檔，`install-p4dev-v8.sh` 的副產物）。
**不是任何結論的依據**；磁碟映像已保留，需要時可重取。

[Co-developed with claude code -- Adam]
