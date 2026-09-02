# run-03（opus）— A-7「naive user」campaign 第三輪

🔴 **這個目錄裡沒有 tester 的最終報告，因為 agent 是被我們自己這條 Claude session 的用量上限殺掉的**
（2026-09-02 22:08:53 CST，HTTP 429 `session limit · resets 11pm Asia/Taipei`），
死在句子中間——最後一句是「A genuine catch-22: the manual's prescribed interpreter can't import
Mininet. Let me confirm both directions and work around it.」。
**這是 orchestrator 端的中止，不是專案缺陷，也不是 tester 失敗**：它當時正在追一條新線索，
沒有任何收尾或自行停止的跡象。因此 `tester-files/JOURNAL.md`（251 行、最後一則 21:59 CST）
**就是這一輪倖存的第一手記錄**，它裡面**沒有 `## SUMMARY`**，而本線**沒有替它補寫任何總結**。
所有結論性的文字都是 orchestrator 事後從 raw log 驗出來的，並在檔內標明出處。

## 這一輪拿到了什麼

opus 在 94 分鐘裡走完安裝手冊 §1–§5、把 §6.1 丟背景、跑通 User Manual 的 OVS 三終端、
然後用「查效果不看狀態碼」的方式掃過 41 個 REST 端點、`ndt` launcher、NSR 與 Simulation Platform，
提出 **22 條 BUGS**（新缺陷 15 條，含本線補立的 1 條），**零次 orchestrator 干預**。
它沒看到的是：**§6.1 的 build 在它死後 53 分鐘（23:01:22）自己跑完了，而且手冊自己的四項驗收全過**
（`logs/06a_p4.log`，`Total time : 7640 sec`）。

## 目錄索引

| 檔案 | 是什麼 |
|---|---|
| **`VERIFICATION.md`** | **逐條複驗表**：38 條宣稱 × 佐證檔 × 逐字節錄 × 判定（36 CONFIRMED／1 mis-stated／1 unverifiable／0 UNSUPPORTED／0 CONTRADICTED），外加九則註記（#10 引錯檔、#22 的機制、NTG catch-22 的裁定、NTG 無限迴圈、公開快照仍出貨修法前的碼…） |
| **`RECONCILIATION.md`** | **對帳**：五條 R12 預期逐條裁定、已知 vs 新的歸類與計數、三輪（sonnet／haiku／opus）對照、收案理由、帶進 run-04 與 A-8 的事項 |
| `tester-files/` | tester 留在 guest 的**全部**東西（216 檔），原樣拉回，未編輯 |
| `orchestrator-scripts/` | 本線的採證腳本（`harvest03.sh`、`harvest03b.sh`、`pull03.sh`），全部唯讀＋打包 |

## `tester-files/` 裡有什麼

| 路徑 | 內容 |
|---|---|
| `JOURNAL.md` | 251 行，**這一輪的正本**。每段有「what I did／surprised by／verdict」與 friction 分數（0–3） |
| `BUGS.md` | 662 行、22 條。格式：feature · 手冊頁 · steps · expected（引用） · observed（逐字） · reproduced? · severity |
| `CHECKLIST.md` | ⚠️ **不是成績單**。mtime 20:55 CST，寫在 OVS bring-up 與整輪 API 掃描**之前**，之後沒再更新（149/187 條 PENDING） |
| `logs/` | 50 支編號 log（`02_conda` … `50_ntg2`）＋ `api_ovs/` 76 個端點檔 ＋ 兩個 `.orig` 備份 |
| `logs/06a_p4.log` | 1.5 MB，§6.1 完整安裝紀錄，**含死後才產生的成功結尾** |
| `pane_*.txt` | harvest 當下的 tmux 畫面。`pane_P4.txt` **是空的**——該 session 在採證前 3 分鐘隨 build 結束而消失（`pane_capture_errors.txt`）；其內容另存於 `logs/06a_p4.log` |
| `tester-scripts/` | 55 支它自己寫的驅動腳本（原本在 guest 的 `/tmp`，不在 `~`） |
| `evidence/` | 本線另外抓的：`ndtwin-lab.sh`（#22 的機制證據）、`NTG-loop-cause.txt`（停機前的唯讀 GET，證實 NTG 迴圈成因）、`bash_history.txt`、`tester-edits.diff`、`ntg-and-lab-probe.txt`、`p4setup.bash`／`.csh` |
| `evidence/OMITTED-FROM-VCS.txt` | ⚠️ **兩項採到但刻意不進版控**（`~/log.txt`＝`logs/06a_p4.log` 的真子集；`~/install-details/`＝235152 行純路徑清單、15.7 MB）。**兩項都不是任何結論的依據**，該檔記下它們的大小與行數；磁碟映像已保留，需要時可重取 |
| `GUEST-STATE.txt` | 採證瞬間的機器狀態：tmux、listeners、`~/logs`、各 repo 的 HEAD 與 porcelain、直譯器能不能 import mininet |

## 讀的順序

1. `README.md`（本檔）→ 知道沒有最終報告、正本是 journal。
2. `RECONCILIATION.md` §1 → 五條預期中了幾條。
3. `VERIFICATION.md` 註 ⑦ → 這一輪最重要的發現（公開快照仍出貨修法前的碼）。
4. 要看 tester 自己怎麼說：`tester-files/JOURNAL.md`，再看 `tester-files/BUGS.md`。

⚠️ **引用 tester 的任何數字之前，先在 `VERIFICATION.md` 查它的判定。**
本輪 38 條裡有 1 條引錯了檔（BUGS #10 的 release 那一列）、1 條的逐字畫面沒有檔可查。

[Co-developed with claude code -- Adam]
