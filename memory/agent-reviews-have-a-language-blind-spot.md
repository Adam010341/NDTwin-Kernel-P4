---
name: agent-reviews-have-a-language-blind-spot
description: "模型複審回報「EVIDENCE NOT FOUND」時要自己再搜一次——這個 repo 的證據常是中文寫的,而它搜英文片語;另外 agent 工具有自己的允許根目錄,--repo 參數不一定生效"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 38b035fc-b098-4e53-9db6-78561882a7f2
  modified: 2026-08-29T06:03:14.711Z
---

2026-08-19,兩個模型(DeepSeek v4 Pro、Muse Spark 1.2)複審簡報 template 時各撞到一個
**系統性**的失敗模式,兩個都會讓它們的報告在特定方向上不可信。

## 一、`EVIDENCE NOT FOUND` 有語言盲點

DeepSeek 把 Page 15 的頭條數字判為 **"EVIDENCE NOT FOUND anywhere in the repo"**,
理由是它 grep 了 `ten hops` / `107 samples` / `2,700 packets` 全都零命中。

**證據其實在 repo 裡,而且很精確** —— `doc/2026-07-29_p4_status_and_test_guide.md:95`:
> 2700 封包 × 10 跳 ÷ 256 ≈ **105** 個期望 sample,實測 **107**(第一次查詢時)

**它搜英文片語,而這個 repo 的實測紀錄大量是中文寫的。**

🔑 **所以收到 agent 的「找不到證據」時,一律自己用另一種語言/另一個詞形再搜一次。**
在雙語 repo 上,grep 式的否定結論**結構上就不可靠**。
(這是 [[existence-is-not-wiring]] / [[no-in-repo-callers-is-not-dead-code]] 的同族:
**空結果不是事實,是一次查詢的結果**——只是這次多了一個語言維度。)

⚠️ **但它的次要論點是對的**:template 把出處標成「CHANGELOG 條目 9」,而那條目裡沒有這些數字
——**引用標錯了**。所以正確處理是:推翻它的主張,採納它連帶抓到的問題。

## 二、`--repo` 參數不一定讓它讀得到

第一輪我用 `--repo /home/adam/Desktop` 想讓它們同時看到 repo 和
`~/Desktop/NDTwin Slide material/`(**路徑有空格**)。**兩個 agent 都讀不到那三個檔**——
工具有自己的 9 個允許根目錄清單,`--repo` 不能擴充它。

它們**誠實地報告了這件事並改用反推**(DeepSeek 從 repo 內引用過頁碼的文件重建了一份頁面地圖),
但那代表**第一輪的提案可能與 template 既有內容重疊,而它們無法自我檢查**。

**解法(已驗證)**:把要審的檔案複製進 repo 底下(`scratch/slide-material-copy/`,已被 gitignore),
brief 裡改指新路徑。第二輪它們立刻讀到,提案品質完全不同——
**v2 抓到我自己漏改的 Page 24**(裁定寫了但沒執行到那一頁)。

🔑 **開 agent 複審前先確認它讀得到「要審的那份東西」,不要假設 `--repo` 有效。**

## 三、值得留的正面觀察

**讀得到 template 之後,它抓到的是我自己的疏漏**:A2 裁定表寫了「改放 Page 19」,
我改了 A2 和 Page 24 卻**從來沒真的加到 Page 19**。這種「決議與執行脫節」是人最容易漏的,
而它是逐頁對照才找出來的。**這類複審的價值在交叉檢查一致性,不在提出新缺陷**
(新缺陷方向見 [[model-hypotheses-saturated]],42% 是已結案的)。

CLI 版可以背景跑(`~/.local/bin/deepseek-agent --provider {deepseek,muse}` ＋
`nohup ... &`),MCP 版會擋住主 session。brief 第一段一定要叫它**先建報告檔**
(見 [[subagent-operating-constraints]])——今天一個被中斷的任務就是靠這條保住了 29 KB 的成果。

## 🔴 2026-08-28 第二個盲點（比語言那個更難發現）：**環境特定的陷阱**

DeepSeek 與 Muse Spark 各交了一份 chaos harness 設計（行動面／oracle）。
**結構好、覆蓋面好、每條不變量都指名了獨立路徑**——而兩個必修缺陷是同一種東西：

| 缺陷 | 需要的知識住在哪 |
|---|---|
| INV-01 的獨立路徑寫 `pgrep -a simple_switch_grpc`，**恆不匹配**（comm 截斷 15 字元、名字 18 字元）⇒ **最重要那條不變量 100% 偽陽性** | **我的記憶檔第一項**，兩週前付過的學費 |
| INV-08「平均值隨忙碌鏈路增加必須不下降」⇒ **對正確系統發火**（該端點只平均忙碌鏈路，加入低於均值的樣本會拉低均值） | `KNOWN-ISSUES` F-17 |

🔑 **兩個都是偽陽性，不是漏抓**——而偽陽性會**浪費一整輪**並且長得像「系統壞了」。
🔑 而 INV-08 特別諷刺：**它是為了偵測「分母算錯」而寫的，自己用了錯的分母模型。**

## ⇒ 分工的判準

> **它們讀得到 repo，讀不到我們踩過的坑。**
> **讓它們產生結構與覆蓋面，環境特定的判準由我們補。**

⚠️ **最危險的欄位是「獨立路徑」**——那一欄最需要環境知識，而它失效時是**靜默**的
（一個永遠回報「行程不見了」的檢查，看起來就像一個很認真的檢查）。
**複審時第一個要看的就是那一欄，而且要真的跑一次。**

✅ 值得肯定的兩件：**Muse 自己標了覆蓋邊界**（「中文搜尋執行了但不完整、213 個 review 未分類」）；
**飽和標記貫穿全文**（把夾制過的量標成「超過上界即裝飾性」）——而那正是同一天
`mainDev` 在自己的偵測器上學到的東西，**它是獨立寫出來的**。
⇒ **不要因為兩個缺陷就低估它們的產出**：那兩個缺陷是我們的知識該補的位置，不是它們的能力上限。

## 🔴 2026-08-28 深夜第三個盲點：**回憶掃描的引用會帶著章節號捏造**

把兩家當「先行研究回憶引擎」用（文獻 kill-shot 掃描）時，Muse 給出一條**中偏高信心、
帶章節號與數字**的引用：「Gallenmüller TUM 博論 2021 §3.4.2 Behavioral Model Build Options，
-O0 vs -O3 對比約 5–10×」。**博論存在、章節不存在**——全文 pdftotext 7,818 行，
`bmv2|behavioral model` **0 命中**、P4 僅 2 次（結語前瞻）。
🔑 **具體到章節號的引用讀起來最可信，而那正是捏造最愛的形狀**（與 [[fresh-grep-before-confirmed-quote]] 同族，
但這次是「別的模型捏造、我們差點採信」）。⇒ **回憶掃描的正確用法**：它們負責「概念性想起」
（補關鍵詞檢索的散文盲區——這是它們真的強的地方，DeepSeek 47 條裡自標低信心的誠實度也可用），
**每一條具體引用由我們上網/全文獨立驗證後才可進報告**。同夜正面例：兩家用 agent_task
自讀 repo 複審投稿提案時，**獨立抓到我們自己 PREREG 裡的 n=1 軟肋**（我 grep 複驗屬實）——
交叉一致性檢查的價值再次成立。⚙️ 工具註：`*_agent_task` **沒有 effort 參數**，等效旋鈕是
`max_steps`（query 變體才有 effort）。

## 🔴 2026-08-29 第四個盲點：**在我這邊——反駁 agent 的宣稱時，引的證據講的是另一個機制**

Poster 外審輪，DeepSeek 報「②③ 用 pgrep argv 指認 binary」。我引 ② `FINDINGS.md:94-96`
「PIDs are enumerated by exact `comm`, never by a pattern over argv」判它錯——
**但那句講的是 CPU 歸因的 PID 列舉，不是 binary 身分**。實際 `run_size_arm.sh:71`／
`run_flowcount_arm.sh:73` 的 `switch_binary=` 就是 `pgrep -af` 撈 argv，兩支腳本零個
EventLogger/nm 檢查——**DeepSeek 對，我把一個真宣稱擋掉還廣播了「不要採信」**（後已公開更正）。
🔑 **反駁的證據必須與宣稱指名同一個機制**——「同一支腳本裡有一句反著講的話」不夠，
要問那句話的主詞是不是宣稱的主詞。與 [[the-clean-version-is-the-one-to-recheck]] 同族：
這次「比較好講」的方向是「外部 agent 又錯了」。
正面帳同輪一併記：三方（我／DeepSeek／Muse）獨立審同一份稿，收斂條全可直接定案；
DeepSeek 的 NO BACKING FOUND（per-paper limit 編碼不存在）這次**是真的**——
第一盲點的鏡像，否定結論也可能對，判準仍是自己回原檔驗。
Muse 的 paste-ready 段落要逐句驗事實再採（它把 ndtwin_kernel 的 `a40e04ce` 寫成 Linux 版本，
且改寫表原樣沿用了被判死的捏造引文）——**改寫器會忠實搬運輸入裡的錯**。
