# 第六輪裁決（`fix/hb-spike-r6-0926`，`dfbab30e` → `3d297c34`，3 檔 +341 −98）

（fable-judge 同一位判官的限定複審最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿，此處保留裁定、前提與 findings 原文。
orchestrator 附註：判官的前提「兩份未收尾的 rerun 若 rc≠0 則裁決作廢」——兩份其後都收尾為 rc 0：`rerun-HBR6-oldcode.3d297c34.log` 12 列全 ok，
`rerun-HBR6-selfcheck.3d297c34.log` 10 個 case 全部 AS IT MUST。）

一句話：**r5 的 finding 1–5 全部做到位，方法正確、證據齊全**——兩個「現碼本來就對」的 note 靠 oldcode 列拿到有效的紅（R5-1 是真的舊形；R5-2 是有意義的 MUTANT），`--self-check` 十個 case 各自用自己的 PROBLEM 行證明 verdict 路徑會亮，再被 8 個 mutant 反證，`.gitignore` 經 SIGKILL 實測擋得住目錄 pathspec，note 5 只改列文字。live 路徑的改動**只有一行 TSV 文字**。**合併裁決：MERGE**；findings 全是 note，沒有 blocking。段 S 沒有因本輪新增的絆腳石。

要點：(1) R5-1 是 r4 裁決建議、r5 worker 拒絕的真實舊形（`|| true`），紅釘在「cycle 1: could not remove…」的缺席；R5-2（每端在 tc 接受前就登記）製造出 finding 2 擔心的兩種誤導；「完整失敗清單」讀法對 firstref／firstunsafe 成立（真 `hb_watch.py summary()` 對 0 rows 回 BAD，逐字同 `$nocycle`），但 halfdel 在 live 會多一條 `the qdisc tree differs from before the cycles`。(2) 三個新情境為真理由而過（假 tc 先記 call 再拒絕；每次 `del` 前都經 `netem_delete_point`）。(3) `run()` 的每條 verdict 路徑都有 case 與 mutant 對應；`control-rc-check-gone` 只因 case 要求自己的 PROBLEM 行才被抓到；重構穩。(4) 根 `.gitignore:5` 裸 `.gitignore`、`:83/:85` 只對 raw* 例外 ⇒ 局部 `!/.gitignore` 是對的工具；SIGKILL 實測成立。(5) live 碼只有 TSV 那一行。

## Findings（全部 note）
1. halfdel 的「恰好三條失敗」是假 qdisc_tool 下的清單；live 的 `QDISC_TOOL diff` 會多一條 `the qdisc tree differs from before the cycles`。SUMMARY 應加註「under the fake qdisc_tool」，或讓假 qdisc_tool 的 `diff` 讀狀態目錄。
2. firstunsafe 的殘留形狀（`loss 100%`）在 live 到不了 `cut_link`（先讓 `wait-heard` 失敗）；改印不擋聽的殘留（如 `delay 1ms`）就是 live 可達情境。
3. R5-2 是一個被選定的 mutant（已揭露；其他錯形靠 `calls` 斷言接住）。
4. self-check 未覆蓋：`got 2`（重複紅）、`copies_ignored` 的否定式分支、unknown-name rc 2。低價值。
5. 閘門的閘門在 repo 外（`oldcode_selfcheck_mutants.hbr6.py`、`gitignore_sigkill.hbr6.sh` 只在 `logs/gates-0910/`）；可接受，日後可併進 `--self-check`。
6. 兩份 rerun 裁決時未收尾（其後皆 rc 0，見上方附註）。
7. r5 的 finding 6／7 仍開著（r3 三條空 reason；detect 對 "already running" 不對稱）。不擋段 S。
