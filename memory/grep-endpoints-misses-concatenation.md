---
name: grep-endpoints-misses-concatenation
description: "Three ways a grep gave an incomplete answer I then treated as complete: a base-URL concatenation, a bound-method reference without parens, and my own `| head -10` truncating the evidence before I counted"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-31T10:23:00.503Z
---

To find every external caller of the kernel's HTTP API I grepped the seven client repos for `/ndt/`. That produced a clean-looking list — and it was incomplete. `Traffic-engineering-App.py:572` posts to the batch endpoint as:

```python
requests.post(ndt_url + "install_flow_entries_modify_flow_entries_and_delete_flow_entries", ...)
```

`ndt_url` is `"http://localhost:8000/ndt/"`, so **the line containing the call does not contain the pattern.** A reviewer reading the whole file found it; my grep could not. It mattered: that client discards the response, so it was one of only two affected by a behavioural change.

**Why:** an endpoint path is a *value assembled at runtime*, not a lexical token. Grepping for the assembled form finds only the callers that happen to spell it out.

**How to apply:** enumerate API callers in two passes — first the endpoint path, then the **base-URL variable(s)** (`ndt_url`, `NDT_API_BASE_URL`, `baseUrl`, `ndt_target`, per-repo constants files like `settings.hpp`). Grep for the variable name and read every use. For a definitive list, prefer reading the one file that wraps all HTTP calls (most of these repos have one) over any pattern. Related: [[existence-is-not-wiring]] — same family: reasoning from a proxy for the artefact instead of the artefact.

**Third instance (2026-08-17, and the cheapest one to avoid): I truncated my own evidence.**
Asked how many agy-reviews were unaudited, I ran `git grep -n "0107\|agy-review" -- doc tools | head -10`,
saw two triage records, and reported a backlog of 201. There were **three** records — the
third, `doc/audit/2026-07-29_codebase-review/ADJUDICATION_agy-reviews_0157-0201.md`, was
inside the grep's scope but appeared **fifth in the file list**, and line-level hits from
HANDOFF plus two runbooks consumed all ten lines. Another session caught it; the real
figures are 116 audited / 212 not, backlog since the last round 0202–0328 = 127.
**How to apply:** `| head -N` is for *reading* output, never for *concluding* from it. When
a count is the deliverable, run the unbounded form (or `-l`, or `| wc -l`) and look at the
total before narrowing. A conclusion drawn from a capped list has no error bar — it cannot
even tell you it was capped.
🆕 **08-30 再犯（現行犯）**：`git log --all --not --remotes --oneline | head -5` 的五筆被我
讀成「未推＝5」，真數 **29**——截掉的 24 筆裡藏著一整條公開分支分叉。要總量就 `| wc -l`，
要讀樣本就另跑一次；一個管線不要同時當兩用。
（同日第二次：`ls setting/ | grep -i "topo\|static" | head` 把字母序靠後的 P4 拓樸檔截掉，
差點寫下「審查員引的檔不存在」——換濾詞重列全清單才抓回。存在性結論不准出自截過的清單。）

🆕 **08-31 第八種漏法：我搜的那個關鍵字定義了我的盲區，而盲區的形狀我看不見。**
要把 kernel 搬到別台 build，先決定「build 到底需要哪幾個路徑」。我 grep 了
`add_subdirectory(` ⇒ 得到 `src/` 十個子目錄＋`tests/`，於是宣布「四項就夠」。
**兩次 build 各否證一次**：①`CMakeLists.txt:60` 的 `include(cmake/sanitizer-flags.cmake)`
②`include_directories(… /libs)`（vendored `spdlog`／`nlohmann`）。四項 → **七項**。

🔑 **`add_subdirectory` / `include` / `include_directories` 是三個不同的函式名，而我只想到一個。**
從搜尋結果裡看不出漏了哪個函式名——**輸出很乾淨，因為它就是我問的那題的完整答案**。
⇒ 通則：**當「涵蓋全部輸入」是宣稱本身時，唯一有鑑別力的檢查是讓它真的被用一次**
（build／執行／跑測試），不是再讀一遍。這兩次撞牆之所以便宜，是因為撞在 build
而不是撞在量測窗裡——**「讓它撞一次」還要挑撞在哪裡撞**。
相關：[[verify-the-purpose-not-the-mechanism]]（陽性對照）、[[live-runs-find-what-tests-cannot]]。

**Second instance (2026-08-13, method calls):** grepping `\.link_failure\(` across `p4_proxy/` returned zero production callers, and I nearly recorded a live, tested feature as "does not exist". The real call site is `topology_manager.py`'s watchdog: `report = self._kernel.link_failure if down else self._kernel.link_recovery` — a **bound-method reference with no parenthesis**, invoked later as `report(...)`. Same lesson, new syntax: a call is a *runtime event*, and `name(` only finds the spellings where the call is lexically at the name. Before concluding "zero callers", re-grep the bare name (no paren) and read hits where the method is passed as a value.

**第五式(2026-08-28):零命中證明的是「沒有人用我的詞」,不是「沒有人講這件事」。**
我掃 14 篇 bmv2 論文有沒有人揭露 build 設定,關鍵詞用
`disable-logging` / `disable-elogger` / `-O2` / `-O3` / `configure` / `compilation flag` / `build option`,
**零命中**,我據此寫下「四篇沒有一篇提到 build」。ICNCC '23 §4.2 其實寫著:
*the switch was compiled in a mode that does not generate logs*(txt 187–190,同篇 txt 117 還載明版本 1.15)。
**那句話一個關鍵詞都沒中**——因為我的詞表是**已經知道這件事叫什麼**的人寫的
(flags、optimization level、configure),而作者是**沒把它當成 build 議題**的人,寫的是散文。
🔑 **檢索詞表繼承了寫詞表那個人的框架;被你的框架排除在外的,正是最值得找的那種揭露**
——它不用你的術語,因為作者根本不覺得那是個變數。
判準:掃「有沒有人做過/講過 X」時,詞表要**同時包含 X 的術語與 X 的白話**
(`compil` 而不是 `compilation flag`;`log` 而不是 `disable-logging`),
噪音由人讀掉;**而在把零命中寫成結論之前,至少全文讀過命中數為零的那幾篇**。
(bmv2 performance session 用寬詞表＋逐篇全文重掃才抓到,我已據此更正
`doc/2026-08-28_bmv2-throughput-literature-vs-ours.md` §1。)
相關:[[claim-verb-decides-the-evidence]]——「沒有人做過」是比「我沒搜到」強的宣稱。

**第六式(2026-08-28 夜):我把「我搜過的範圍」當成「存在的範圍」——一個晚上兩次。**

| 我下的結論 | 我搜了哪裡 | 它其實在哪 |
|---|---|---|
| 「9/03 的圖從來沒有存在過」 | repo **所有分支**(`git log --all --diff-filter=A -- '*.png'` 全空)＋確認 PNG 沒被 gitignore | **repo 外的投影片素材目錄**(`NDTwin slide material 903/figures/`,四張現行＋兩張 `_superseded/`) |
| 「全機五個直譯器都沒有 matplotlib」 | 系統 python、miniconda base、三個 conda env | **`NDTwin Slide material 820/.plotvenv`**——沒 activate 就不在 PATH、不是 conda env、埋在兩層有空格的目錄下 |

兩次我都**把搜尋做得很紮實**(第一次還加了「PNG 沒被 gitignore」當旁證,第二次還查了 conda-meta),
**然後對搜尋範圍本身零聲明**就寫下存在性結論。紮實反而讓結論更有說服力。

🔑 **而兩次的正解都一樣便宜:問「這個東西的使用者說它在哪」。**
`plot_deck_903_round2.py` **檔頭第 18 行逐字寫著那條 venv 路徑**——我讀了前 12 行就停了,答案在往下六行。
⇒ **我列舉的是機制**(PATH、conda env、git 分支、gitignore 規則),
**而機制的列舉永遠漏掉「有人手動放的地方」**。

判準:寫下「X 不存在」之前先寫出**「我搜了哪些地方」**,然後問
**「有沒有一個地方是 X 的使用者會指的、而我沒搜的?」**
最便宜的那個地方通常是**使用 X 的那支腳本自己的檔頭**。
相關:[[claim-verb-decides-the-evidence]]、[[the-clean-version-is-the-one-to-recheck]]
(兩次的錯誤方向都偏向「比較好講」——「圖從來不存在」「matplotlib 消失了」都比「我沒搜到」好講)。

**第四式(2026-08-28):diff hunk 不是「可達集合」,而只讀改動的那幾行會給出相反的結論。**
查 kernel 的 `get_path_switch_count` 從 500 改成 400 會不會打到 Network-Traffic-Generator。
改動本身很清楚(`tryIpStringToUint32` 失敗 ⇒ 400),NTG 也確實會檢查
`if response.status_code == 200:` 否則 `raise ConnectionError`。**兩邊都對上了,結論看起來是「會壞」。**
實際上不會:`distance_seperate.py:64` 是 `requests.get(GET_PATHS)`——**完全不帶 query 參數**,
而那段新碼在 `HttpSession.cpp:1663` 的 `if (!srcIpStr.empty() && !dstIpStr.empty())` 底下,
**NTG 進不去那個分支**。只有把整個 handler 讀完才看得出來。
⇒ **「改動的行」與「這個呼叫端會執行到的行」是兩個集合**,而 diff 只給你前者。
判準:找到消費者之後,回去讀**它那條呼叫路徑的完整 handler**,不是讀 diff。
(同一輪的正面對照:`ndtwin_kernel + "/ndt/get_path_switch_count"` 也是本檔第一式的拼接形狀,
這次抓得到純粹是因為端點名仍然完整出現在字串裡——**拆得再細一點就漏了**。)

## 🆕 2026-08-30 正面案例：給 grep 配陽性對照，零命中才算數（R-1 判定）

`開機手冊` 判定「沒有 app 呼叫 `/ndt/set_historical_logging_state`」之前，先讓同一套搜法
在六個 repo 各自找出 14/1/5/4/3/2 個 `/ndt/` 端點——**證明搜法抓得到呼叫端，零命中才有意義**；
並把 TE-App 的裸 `ndt_url = ".../ndt/"`（`:32`）解析到呼叫點，堵掉拼接洞後才收聯集。
🔑 判定檔還明寫「這說的是 untestable，不是 safe」＋「我搜過的範圍不是存在的範圍」。
⚠️ auditor 對帳仍抓到一個洞：`components.env` 列七個 repo、它列了六個數字——
**「掃過的範圍」要逐一列名寫進判定檔**，讀者才驗得動。

## 🆕 08-30 追加兩式（同一輪 R-1 判定，`開機手冊` 供稿）

- **第七式：陽性對照驗儀器、驗不了查詢詞。** exact-string 搜的是 handler 名
  `set_historical_logging_state`，真 route 是 `/ndt/historical_logging`（`HttpSession.cpp:284`）
  ——搜錯名字的零命中**照樣通過**「搜法抓得到別的端點」的對照。結論靠備援的字詞掃描碰巧存活
  （它自己的話：**「那次是運氣」**——若 route 叫 `/ndt/hlog`，兩個搜尋都回零，零證據報同一結論）。
  ✅ **處方＝兩段式**：先對**服務端**（route 表／emitter）驗「這名字存在且唯一」，
  再對呼叫端驗零。順序不能反。
- **第八式：template literal 的 `}` 前綴打敗所有帶引號的 grep。**
  `'/ndt/`、`"/ndt/`、`` `/ndt/ `` 在 `Web-GUI/src` 全零命中，因為端點長在 `${base}/ndt/...` 裡。
  ✅ 有效樣式＝**不對前綴做任何假設**：`grep -rhoE "/ndt/[a-z_/]*"`（Web-GUI 十二個端點靠它撈出）。

---

## 🔴 08-30 第七式與處方：**「沒人呼叫它」的判定是兩段式的**

R-1 要判「有沒有 app 呼叫某個端點」。我做對了陽性對照（七個 sibling repo 各自吐得出
14/4/2/5/3/1/12 個 `/ndt/` 端點 ⇒ 搜法確實抓得到呼叫端），**結論也對**，但兩次都靠錯的東西撐著：

1. 第一次掃了**六個** repo 卻沒列名 —— `components.env` 是**七個**，漏掉的 **Web-GUI**
   偏偏就是拼接型呼叫端。
2. 第二次搜的是 **`set_historical_logging_state`**，那是 **C++ handler 名**；真正的 route 是
   **`POST /ndt/historical_logging`**（`HttpSession.cpp:284`），handler 名當 route 出現 **0 次**。

救我的是順手加的 `histor` **字詞掃描**（兩個名字都蓋得到）。**那是運氣**：route 若叫
`/ndt/hlog`，兩個搜尋都回零，我會用零證據報出同一個（碰巧正確的）結論。

### 處方（auditor 升級的判準，運氣是診斷、這是處方）

> **1. 先對著服務端確立名字存在且唯一** —— 從 route 表／dispatcher／emitter **讀出來**，
>    不要從工單、PREREG 或 header 抄。
> **2. 然後才**對著呼叫端確立零。

順序反了就得到「呼叫端零」其實是「名字零」，**兩者輸出一模一樣**。

🔑 **陽性對照蓋不到這一層。** 「七個 repo 都找得到端點」證明的是**儀器抓得到呼叫端**，
它對「你搜的字串是不是對的字串」**零資訊**。那是兩種不同的失敗，只有第一段擋得住第二種。

第一段的樣子（一行就夠）：
```bash
grep -noE '"/ndt/[a-z_]*histor[a-z_]*"' src/ndt_core/http/HttpSession.cpp
# 284:"/ndt/historical_logging"   ← 一個命中 ⇒ 存在且唯一，沒有第二種拼法
```

## 🆕 第八式：**template literal 的 `}` 前綴打敗所有帶引號的 grep**

同一輪內第二次踩到拼接。`Web-GUI/src/components/llm/LLM.ts`：
```ts
const NDT_API_BASE_URL = import.meta.env.VITE_NDT_API_BASE_URL;   // :8
await fetch(`${NDT_API_BASE_URL}/ndt/intent_translator/text`, …)   // :21
```
我 grep `'/ndt/`、`"/ndt/`、`` `/ndt/ `` 三種引號變體在 `Web-GUI/src` **全部零命中**——
因為 `/ndt/` 前面是 **`}`**。

**正解是不對前綴做任何假設**：
```bash
grep -rhoE "/ndt/[a-z_/]*" <repo> --exclude-dir=.git --exclude-dir=node_modules
```
Web-GUI 的十二個端點是這樣才撈出來的。⚠️ 這一式跟舊的 `ndt_url + "endpoint"` 是**不同載體**
（Python 字串相加 vs JS 模板字串），但同一個病：**引號不是端點的邊界，端點的邊界是路徑本身。**

正本：`doc/audit/2026-08-30_live-full-stack-round/PRE-ROUND-R1-determination.md`（含七列具名表格）。
相關：[[verify-against-known-good-output]]、[[claim-verb-decides-the-evidence]]

## 🆕 第九式（08-30 晚，poster R3 自驗）：**pdftotext 的換行把多詞片語切斷，grep -F 整句回零**

對 PDF 萃取文字驗「紅線子句還在不在」，37 個必存字串裡 3 個回 MISSING
（`a cap the unshaped bmv2 fabric does not have`／`zero ECMP spread`／`quantisation interval`）
——**全是換行假影**：片語跨行，逐字 grep 對不上。`tr '\n' ' ' | tr -s ' '` 正規化後全數 OK。
🔴 差點把「排版換行」讀成「紅線子句被改掉」——錯誤方向又是比較好講的那邊。
✅ 規則：**對萃取文字（pdftotext、OCR、log 折行）驗多詞片語，先正規化空白再 grep**；
單詞 grep 不受影響，兩詞以上一律先 `tr`。

## 🏁 08-30 晚：五連實例 ⇒ 這條判準比 grep 大，而且**它讓發現變好、不是變少**

一個晚上五次，同一個動作改掉了結論——**而且只有兩次跟 grep 有關**：

| # | 我原本要報的 | 先查了什麼 | 改成 |
|---|---|---|---|
| 1 | 「全站沒有 NSR 的安裝步驟」 | 全站搜一次 | 步驟**在**安裝手冊裡 ⇒ 真缺陷是**使用頁不連到它** |
| 2 | 「NTG 的 `--port 8000` 跟 kernel 撞埠」 | 讀那個塊的**上下文散文** | 在 Hardware 章、worker 在別台 ⇒ 不是衝突；真缺陷是**塊旁邊沒說必須在別台** |
| 3 | 「viz 的 PASS 是配到 Maven 樣板」 | 看**實際命中的那幾行** | 命中的是 viz 自己的 `TopologyCanvas.draw()`，而且畫對了 27,262 次 ⇒ **校準債沒有造成偽陽性** |
| 4 | 「NTG 一 import 就崩」 | 查 guest 的 **CPU 旗標** | QEMU `qemu64` 缺 x86-64-v2 ⇒ 是**我的乾淨室**的界，不是軟體 |
| 5 | 「SimPlatform 兩頁有一頁 NFS 路徑寫錯」 | 讀**服務端的 settings header** | 兩個路徑**都對**、屬於兩個角色 ⇒ 真缺陷是**安裝頁沒建那個目錄＋兩頁都沒說有兩個角色** |

🔑 **判準的推廣形式**（不限 grep，第 114 行的兩段式是它的特例）：

> **在報告「不存在」或「寫錯了」之前，先去問另一邊。**
> 另一邊是誰視情況而定：服務端的路由表、原始碼的 header、那段話的上下文、實際命中的那幾行、機器本身。

🔑 **而真正該記的是回報形狀，因為它反駁了「這樣做只是變膽小」**：
**五次沒有一次把發現刪掉。** 每一次都把它換成**更窄、更可執行**的版本——而且新版本通常**更難修也更值錢**（「不連過去」比「不存在」難發現；「沒說有兩個角色」比「有一頁寫錯」更接近根因）。
⚠️ 反面成本也記著：第 5 例若照原判去修，會**害人改掉一個本來正確的值**。

📌 同日另一個相關動作：**沒有鑑別力的儀器給出的 FAIL 不是發現**（§6.7 的 NOTE-4——我測「有沒有連結 nanomsg」，而手冊宣稱的是「移除事件串流」；追測後 fast 與 debug 在那個儀器下**完全相同** ⇒ 撤回改記 UNTESTED）。與 [[claim-verb-decides-the-evidence]] 同一件事的儀器面。

## 🆕 08-30 深夜：**規矩用在了結論上，沒用在搜尋上**——同一條規矩的半套用

派工說「`ndtwin-lab` **拒絕** `KERNEL_DIR` env override」。我查了
`components.env`（`:=`＝**接受** override）、`tools/test_workflow/*.sh`（零拒絕）、
`ndt`（**完全沒有這個字**）、`ls -d ~/ndtwin-lab`（不存在）⇒ 結論「前提不成立」。

**前提是真的。** `ndtwin-lab` 是 `tools/test_workflow/` 底下的**一個檔案，不是目錄**，
還裝在 `/usr/local/sbin/`（root-owned、NOPASSWD）；拒絕就寫在它的 `:26-51`，
理由正是我獨立推出的那個（root wrapper 以 root 執行 `$KERNEL_DIR/…/*.py`）。
會找到它的搜尋是 `git ls-files | grep <name>` 或 `ls /usr/local/sbin`。

🔑 **本檔的規矩我遵守了一半**：「報絕跡之前先問另一邊」我用在**結論**上——
我填的是一張 blocked 票去問，不是下一個有自信的否定。**但沒用在搜尋上**：
「我搜過的地方沒有」被當成「它不在」，而我只搜了目錄與一個檔名。
⇒ **「搜過的範圍」≠「存在的範圍」**（本檔既有條目）**要對搜尋本身再套一次**：
問「這個東西可能長成什麼形狀？」——目錄 vs 檔案、repo 內 vs 已安裝到 `/usr/local`、
tracked vs untracked。名字對了、形狀猜錯，一樣是零命中。

✅ **而救場的是結構不是聰明**：**填 blocked 票去問，勝過下一個有自信的否定。**
前提後來證實為真——一張「這不存在」的票，會是一個以 **root 權限邊界**為主題的、
有自信的錯答案。⇒ 判準：**當「不存在」的代價不對稱時（安全、權限、資料遺失），
預設輸出是「我查了 A B C 沒找到，還可能在哪？」而不是「它不存在」。**
相關：[[investigation-briefs-separate-observation-from-inference]]、[[claim-verb-decides-the-evidence]]。

## 🔴 08-31 第十式：**派工者舉的「例子」會被讀成「範圍」——而這一次錯的是派工者**

我要一條線查「重編號有沒有打斷別的引用」，並**點名**了一個檔案的一句話當例子。
**結果那處根本沒受影響**（我猜錯了），真正壞掉的**兩處在另一個檔**。

> 🔑 **「照著別人的線索查」與「照著別人的線索的範圍查」是兩件事。**

⚠️ **危險在於「只查那一處、回報沒壞」完全符合我的指令，而且是錯的**——
一個服從的回報與一個正確的回報在這裡分岔，**而分岔的責任在下指令的人**。

✅ **派這種查證要寫成三段，順序不能顛倒**：
1. **風險的形狀**（「重編會打斷所有用序數的引用」）
2. **母體**（「全記憶目錄＋repo 全樹，含 frontmatter 的 `description`」）
3. **例子，並明標「這只是一個例子，不是範圍」**

📌 那一輪順帶挖出的第三層，**沒有人會想到去查**：該檔 frontmatter 的 `description`
**還寫著「十二式」，過期九式**——而 `description` **正是別的 session 決定要不要打開這個檔的
唯一依據**。⇒ **過期的 `description` 不是小事，它是「這個檔跟我有沒有關」的判斷材料。**

📌 **修撞號本身有代價**：重編前先查誰引用了它；**改不動的就留著撞號並記錄**
（「留著比修好更安全」比「全部整齊」正確）。根治是**改成用名字指**，
檔頭的新舊對照表只是止血——**因為引用它的人手上永遠是舊的那份。**
