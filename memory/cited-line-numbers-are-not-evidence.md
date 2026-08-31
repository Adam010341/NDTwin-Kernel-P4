---
name: cited-line-numbers-are-not-evidence
description: "A line number cited in an NDTwin doc is a claim, not evidence — open it. One misread line propagated into four documents and a source comment."
metadata: 
  node_type: memory
  type: project
  originSessionId: b955baee-a646-4fe6-9986-df69b65478e6
  modified: 2026-08-31T10:06:55.408Z
---

**Opening a cited line is cheaper than believing it.** On 2026-08-10 I found that
`TopologyAndFlowMonitor.cpp:1798` had been cited as "the topology poll interval is 1 s" in four
places (the SPEC-UNKNOWN adjudication ×4 mentions, `2026-07-27_p4_bmv2_support_plan.md` ×2,
`topology_manager.py`'s `down_link_endpoints` docstring, and a memory). `:1798` is a **1-second
sleep slice** so `stop()` need not wait out a whole interval; the real interval is at
`:1793-1795` — 5 s for the process's first 90 s, then 30 s. Every downstream conclusion that
traded against "only 1 second" was arguing against a number 30× too small.

Same session, same shape, three more times: `getAvgLinkUsage` was cited as `:2245` and `:2431` in
three docs (actually `:2410`); `:1902` was labelled "link utilisation" when it is the DFS
all-paths walk, which hid that the *real* utilisation function `:2418` is the one site that does
**not** take the `isUp && isEnabled` intersection; and `GraphTypes.hpp`'s `from_json`/`to_json`
were described as "a contract with 7 downstream apps" when both have **zero live callers** — the
three topology loaders comment them out in favour of hand-written extraction, and the actual
emit surface is two lines in `HttpSession.cpp` (`:514`, `:528`).

**Why:** this repo's docs are hand-written status snapshots while the code moves by commit, so
citations rot silently — and a wrong citation is worse than a missing one, because it looks like
evidence and gets copied forward. Three of the four propagations above were me copying my own
earlier claim rather than re-reading.

**2026-08-12 補上最短命的一次：我寫的引用在同一個 commit 裡就爛了。** `Classifier.cpp` 的
VLAN 警告寫著「sFlow 那側在 `FlowLinkUsageCollector.cpp:2534` 建 key」——而**我在同一次
提交裡加到那個函式上方的註解，把它推到了 2542**。引用在任何人讀到之前就已經是錯的。
所以規則不只是「引用前先開」，而是：**寫進註解的定位一律用符號名 + 一個唯一的 grep 錨點**
（現在寫的是 `FlowLinkUsageCollector::calFlowPathByQueried`，錨點
`ndtClassifier::FlowKey fk{}`，全檔只有一個 hit）。行號連自己這一手都撐不過。

**2026-08-24：新機制——把「執行順序」誤映射成「原始碼行號順序」，而且兩個 session 差點互相
背書。** review session 分解一個「同字串、兩個 handler 發」的 log 行（12＝2＋10），**數字全對**，
但把兩個 notify site 的歸屬**左右顛倒**（說截斷在 `:857`，實為 `:763`）。他們自述的成因值得記：
**log 交錯裡 `connected` 先於 `entered`，就無意識地假設原始碼裡也是那個順序**——而
`754↔763` 的相鄰性證據**就印在他們自己那次 grep 的輸出裡，看著它還是寫反了**。

判準是 **decorator ＋ marker 相鄰性**，不是執行順序：`@set_ev_cls(EventSwitchEnter)` 底下
`Switch entered:`(`:754`) 與 notify(`:763`) 同函式，`@set_ev_cls(EventOFPStateChange)` 底下
`connected (…)`(`:827`) 與 notify(`:857`) 同函式。

**兩個教訓**：① 一個字串有多個發射點時，flat `grep -c` 看起來同質其實不是——**先問這個字串有
幾個呼叫點**。② 他們的**結論是對的**（截斷在 enter handler），錯的只是掛在結論上的行號——
**正確的結論會讓錯的引用活下來**，這是最難抓的一種。③ 這同時是 [[two-writers-one-worktree]]
的**正面案例**：兩個獨立來源同意仍然不等於正確，但**其中一個肯去 fresh grep 就夠**。

**How to apply:** when a doc, a review, or your own earlier note supports a decision with
`file.cpp:NNN`, open `NNN` before using it — especially before estimating a change's size or
arguing a trade-off from it. Ask specifically: does this line still say what the citation claims,
and is the function named the one actually doing the job? Related: [[change-magnitude-send-the-diff]]
(estimate from the real artefact, not a summary), [[existence-is-not-wiring]] (a definition is not
a call site), [[replace-vs-add-bug-shape]] (which carried the 1-second error).

## 🔴 08-27（auditor 本人）：**`git log -1 -- <path>` 不是 provenance 工具**

我宣稱 proxy 的 `/sflow/stats` 端點「本來就存在、committed 在 `ee443f4`、只差 `main.py` 一行沒接」，
並據此把它記成缺陷家族的**第 12 例（committed reader、零 setter）**，還寫進給 Adam 的報告。
**全錯。** mainDev 用三條指令推翻：`git log -S "inject_emitter"` 只回**他們今天那一個 commit**；
`git show 59e7298^:<path>` 與 `git show ee443f4:<path>` 對 `inject_emitter|datagrams_sent|/sflow/stats`
**都是 0 命中**。真相是那 50 行**全是他們當天新寫的**，仍是**第 11 例、writer 零 reader 那一面**
——**我最初的判斷才對，是我後來把自己改錯的。**

**機制（精確）**：我跑的是 `git log --oneline -1 -- <path>`。它回答的是
**「最後一個動過這個檔的 commit」**，不是**「我正在讀的這幾行的來歷」**——那幾行當時還在
**工作區、未提交**。檔案只要有未提交改動，這個指令就會**系統性**地把新碼歸給一個舊 commit。

🔴 **最刺的一點：推翻我的證據就印在同一個指令的輸出裡。** 我同一條命令跑了
`git diff --stat`，它印著 `50 insertions(+)`（＝那正是未提交的新碼），我讀過去了。
⇒ 與 [[verify-against-known-good-output]] 第五式同一母題：**證據為真、指向為假**；
工具全程正常，錯的是我讀了旁邊那一欄／問了旁邊那個問題。

**How to apply:**
1. **要 provenance 只能用 `git log -S <string> -- <path>`、`git show <sha>:<path>`、`git blame`。**
   `git log -1 -- <path>` 永遠不是答案。
2. **任何「這行本來就在／這是第 N 例」的宣稱，附上上述指令的輸出，不附就不計分**（mainDev 提，
   對雙方同等適用）。
3. **先 `git status <path>`**：檔案髒的時候，任何基於 commit 的歸屬都要先排除工作區。
4. ⚠️ **驗收方犯這種錯的傳播距離更遠**——我用的措辭是「我查到的」而非「我猜」，
   下游會拿它當已驗證的前提。同日 mainDev 也犯了同型錯（`sflow_emitter.py` 的作者），
   雙方各自主張自己那次比較嚴重 ⇒ **兩邊都往自己身上收，剩下的討論就只剩機制**（mainDev 語）。

## 🆕 08-29：**「我複驗了」本身可以是錯的，而宣稱仍然是對的**

同一輪裡「複驗」這個動作出錯**兩次**，兩次的**實質都對**：
① agy 複審引 `:74/:84/:100`，跟實際檔案（F-17 在 `:515`／`:597`）對不上，但它指認的缺陷是真的；
② 我說「我複驗了 `KNOWN-ISSUES.md:171`」並貼出那句話——**那句在 `:172`**，`:171` 是它的前半句。

🔑 **兩個方向都要守**（mainDev 的措辭）：
**行號錯不代表宣稱錯**——不要因為引用對不上就丟掉一個真的發現（我差點對 agy 這樣做）；
**但也不能拿行號當「已複驗」的證明**——我說「我複驗了」而複驗本身差一行，
那句話當下的作用是**讓對方停止查證**，這比單純引錯更貴。

📌 成因（我自己的診斷，mainDev 同意）：**裸行號夾在混引兩個檔的段落裡等於沒有出處**。
我在同一段逐行引 `types.cpp` 然後裸寫 `:171`，任何人都會讀成 `types.cpp:171`。
⇒ **跨檔的段落一律寫完整形式 `<檔名>:<行號>`**，一次都不要省。

## 🆕 08-30：**一次正確的量測，會因為底下的碼變了而無聲過期**——跟「量錯了」是兩種失效

`doc/2026-01-02_ndt_api.md` §39 的 success shape 帶著一個 **2026-08-17「已實測」**的標記，
而它記下的 body **沒有 `recording` 欄**。今天讀源碼發現實際有**三個** shape、每個都有那欄。

🔑 **那次量測沒有錯。** `recording` 是**之後**才隨「旗標設了但不會寫入任何一列」的修法加上去的。
⇒ **量測的有效期，是被它量的那段碼的壽命決定的，而碼改變時不會回頭通知任何一份文件。**

**為什麼這比「量錯了」更危險**：錯的量測還有機會被複驗推翻；
**過期的量測帶著「已實測」這個最高可信度標記**，正是讓人**不去複驗**的那個標記。
它腐爛的時候看起來跟正確的一模一樣——本檔行號那條的同構物，
只是腐爛的東西從「位置」換成「內容」。

⇒ 可操作：
1. 標「實測」時**一併記下被量的那顆 commit / 那段碼的識別**，
   讓讀者能問「那之後這裡改過嗎」（`git log -- <path>` 就夠）。
2. **改行為的修法，要順手 grep 有沒有文件記著它的舊回應形狀。**
   §39 這次是修法加了欄位、文件沒跟——修的人沒有錯，只是沒人告訴他有第二個副本。
3. 撤回／更新時**逐句分判**：§39 那句「這些 shape 是實測的」有一半仍然成立
   （200 而非 500），過期的只是 body 的內容。整段砍掉會連對的一起丟。
   （[[disclosure-is-not-downgrading]]）

🔑 而這次「比較好講」的版本是「08-17 那次量錯了」——把過去的自己講成粗心，
比承認「證據有半衰期而我們沒有機制追蹤」容易。[[the-clean-version-is-the-one-to-recheck]]

---

## 🆕 2026-08-31：「算式在檔」有三態，第三態每次檢查都看起來是好的

母版衍生數字全掃（17 個）找到**三種不同的洞**：

1. **raw 未保存**——原始資料沒了，算式還在（pilot 12×：`2026-08-15` 報告 :66 有 25→300）。
   🔑 母版連寫三次 "raw not retained" 很容易被讀成「算式也沒了」，**兩件事要分開講**。
2. **算式不在鏈上**——只有結論句沒有算法（`1,500×`，全 repo 零命中）。
3. 🔴 **算式在檔、但那個檔不在版控**——**最陰險**：追下去每一格都「有出處」，
   我當天就是這樣報出「16/17 在檔」的，而其中**五個的檔從未 commit**
   （`git log --all` 零筆）。

**第三態的機制**（實例）：那個目錄被 **`.git/info/exclude`** 排除，而**排除檔本身也不進
版控** ⇒ 別人連規則存在都不知道；**一次全新 clone 就完全沒有那些算式**，論文照樣印數字。
（機制細節：純 `git clean -fd` 不刪被 exclude 的檔，`git clean -fdx` 才會——結論不變。）

🔑 **判準：查到「出處」之後要再問一句「那個出處在版控裡嗎」。** `git ls-files
--error-unmatch <path>` 一行就知道。
🔑 **鎖的粒度**：「不進版控」的鎖是**對內容**下的（投稿材料、場次名），**不是對算式**下的。
算式是量測 provenance ⇒ 抽進版控檔（`DERIVATIONS.md`，`69c6449`），內容仍留在鎖裡。
混為一談會兩頭落空。

## 🆕 08-31：對**移動中的目標**做的 preflight，有效期只到你真的去用它為止

我為了不浪費 2 小時的 p4 建置，先花 2 分鐘 `patch --dry-run` 驗 p4-guide v8 的 patch 套不套得上
（帶 v10 當控制組）。**08-30 16:12 量到 behavioral-model HEAD＝`fdd3b893`（08-24）⇒ 綠燈。**

隔天建置，實際建到的是 **`583e76e4`，時間戳 08-30 22:06**——**上游在我量完之後、開建之前推了新 commit**。
安裝器**不釘** behavioral-model（`INSTALL_BEHAVIORAL_MODEL_SOURCE_VERSION` 預設空），所以輸入
在腳下換掉了。**結論碰巧仍然成立**（v8 的 patch 對新 commit 也套得上、整段 PASS），
**但那是運氣，不是我的設計**——我量的是 X，建置吃的是 Y。

🔑 **這條的形狀比一般的「量測會過期」更尖**：preflight 存在的理由就是「上游會漂」，
而**它自己就是被上游漂掉的那個讀數**。⇒ 儀器與它要防的失效模式共用同一個弱點時，
它給的綠燈只覆蓋量測那一瞬間。

⇒ 可操作，三選一：
1. **把 preflight 的讀數釘進建置**（量到哪顆就 pin 哪顆）——這樣證據與被建物一致，代價是不再是「讀者今天會拿到的」；
2. **在建置腳本裡重驗一次**（開建前自己 dry-run，失敗就停），成本兩分鐘；
3. **接受它是機率性的，並在報告裡寫出「preflight 的 commit ≠ 建到的 commit」**——最差但至少不騙人。

🔴 **我做的是第 3 種卻沒有寫出來**，還跨 session 斷言「輸入與你 08-28 那次完全相同」——
**那句話在我說的時候就已經是假的**。已更正。同族：[[benchmark-must-name-the-binary-it-measured]]
（報數字要指名 binary）——這裡是它的上游版：**指名之前，先確認你指的那顆就是被用掉的那顆。**

---

## 🆕 2026-08-31：對整份文件**機械重跑**一次解析（175 條），三件事

起因：別條線抓到 `config.log:2` 錯（正確 `:4`）**從 08-21 活到今天**——
活得下來是因為**宣稱是對的、只有指標錯**，同 bullet 裡另一個行號又是對的
⇒ **兩者永不互相矛盾，所以永遠不會有人發現**。**repo 裡沒有任何東西在檢查行號。**

我寫了個解析器把自己文件裡每個 `` `path:line` `` 抽出來、**去讀那一行**。結果：

1. ✅ **175 條可解析、越界 0**——沒有同型的漂移。
2. 🔴 **`config.log:7` 是對的，但它指的檔案即將被刪** ⇒ 行號正確 ≠ 引用可長存。
   **改指的時機是「原檔還在的時候」**，刪掉之後連「我引的對不對」都查不了。
3. 🆕 **裸 basename 的歧義**：`PREREG.md` 在版控裡有 **19 份**，
   而文件通篇寫 `` `PREREG.md:101` `` ⇒ **第三方無法跟隨**。解法＝文件頂端放解析鍵
   （用**內容**把它釘死，不是用「應該是最近那輪」猜）。

🔑 **我自己的稽核工具先給了假警報**：第一版說 123 條歧義，因為它把
`.claude/worktrees/` 的副本算進候選。**排除 worktree 後只剩一個真歧義。**
⇒ [[new-tools-are-the-first-thing-under-test]] 再一次；
**「同名檔案有幾份」這個問題，母體要限定在版控內。**

🆕 **另一個形狀：一行同時裝著兩條款的東西，不適合當引用目標。**
`PREREG.md:101` 的**前半是前一條款的 `🔴 SUPERSEDED` 標記，後半才是還活著的規則**。
引用它在字面上正確，但**跟著指標去讀的人會先看到紅字，然後合理地以為那條規則死了**。
⇒ 撤回／取代的標記要**獨占一行**，否則它會汙染鄰居的可引用性。

相關：[[verify-against-known-good-output]]（抄錄一遍是找 provenance 洞最便宜的方法）、
[[disclosure-is-not-downgrading]]（撤回會製造新的引用點）。

## 🔴 08-31（auditor 本人）：**貼進文件的「證據謄本」會無聲落後它謄的那支腳本**

我為了不要在不完整的證據上蓋章，發明了一個 `EVIDENCE-BASIS:` 欄位當閘門
（preflight 讀到 `INCOMPLETE` 就拒跑）。**然後我在兩輪都蓋了 `COMPLETE`，
而兩輪嵌在註冊裡的 force 矩陣謄本都是舊的：**

| | 嵌入 | 實跑 | 缺的 |
|---|---|---|---|
| F-5 | 13 | **15** | `config -> [exit]`（trap 蓋 abort）、`config,restore_atexit`（複合） |
| E | 14 | **15** | `labmarker`（鄰輪 marker 的讀者） |

🔴 **短少的正好是花最久才做對的那幾列。** 而 E 的證據基礎**這是第二次事後補**
（第一次是身分括號的 force，`8e24be1`）。

🔑 **機制**：`EVIDENCE-BASIS:` 是**宣告欄**——它擋的是「有沒有人宣告」，
不是「宣告是不是真的」。**新增一列 force 不會讓任何東西變紅**，
所以謄本靜靜落後兩列，而每一次檢查都看起來是綠的。
⇒ 本檔 08-30 那條（量測會無聲過期）的**謄本版**：腐爛的東西從「位置」→「內容」→
現在是「**一份被謄寫的清單，與它的來源分岔**」。

🔑 **與 [[mutation-gate-for-tests]] 的到期 fixture 是同一個形狀的兩面**（寫章的代理提的，正確）：
**兩者都是證據在事後失效**——fixture 因真東西到達而過期、謄本因新增列而過期。
差別在 fixture 那次是**被真東西戳破**的，謄本這次是**被人要求確認才發現**的；
**兩次都不是任何自動檢查抓到的。**

🆕 順帶一個計數陷阱（同輪）：`grep -c '[ok]'` 兩輪都回 **16**，矩陣其實是 **15**——
多的那個是講錨定規則的**散文**。⇒ 數證據列要**在 block 內數並和標頭互相對帳**，
`grep -c` 全檔掃會給一個「看起來已驗證」的數字。

⇒ 可操作：**謄本型證據要有一道把它和來源對帳的檢查**，而且要掛在既有的拒跑槓桿上
（preflight 已經在讀那個標頭了），不要新增一個沒人會跑的 checklist 項目。
