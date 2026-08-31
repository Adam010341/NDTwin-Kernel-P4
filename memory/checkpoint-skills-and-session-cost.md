---
name: checkpoint-skills-and-session-cost
description: 🔑 四個記憶維護 skill（pre-compact／before-sleep／session-close／memory-audit ＋ memory-lint.sh）選哪個的判準，以及支撐它的成本模型——成本＝往返次數 × context 大小，冷寫入是「離開多久」造成的不是「跑了什麼」
metadata: 
  node_type: memory
  type: reference
  originSessionId: eb665942-c34e-4ce9-bc42-2307c10c8a8a
  modified: 2026-08-30T07:51:11.178Z
---

2026-08-27 建立。四個 skill 在 `~/.claude/skills/`，跨專案。

## 選哪個：分界線是「斷點有多長」，不是「session 要不要結束」

| 接下來的斷點 | 還會回這個 session 嗎 | 用 |
|---|---|---|
| 無／幾分鐘（純粹 context 滿了要清） | 會 | `/pre-compact` |
| 幾小時～一夜 | 大概會 | `/before-sleep` |
| 一夜以上，或明確要開新的 | 不會 | `/session-close` |
| （不定期，事件驅動） | — | `/memory-audit` ＋ `shared/memory-lint.sh` |

**`before-sleep` 是 `pre-compact` 的超集**（多了背景工作檢查、共用資源交代、在途狀態四段、明天先驗證、可貼 prompt）。
`memory-checkpoint.md` 的 Phase 0–5 四個都共用，改那裡四個同時生效。

### 🔑 更準的判準（Adam 的情境：agent 自主工作、他只驗收）

「使用者會不會忘記」這條對他很弱——**他不讀狀態檔**。真正的分界是：

| 明天要驗收的是 | 用 |
|---|---|
| **成品**（重構完不完整、測試綠不綠） | `pre-compact` 就夠——成品自己會說話 |
| **結論**（實驗、量測、A/B、任何「對不對取決於當初怎麼設計」的） | `before-sleep`——**判準不該由被驗收的那一方保管** |

⇒ 只寫在壓縮摘要裡的判準，等於**讓執行者保管自己被評分的標準**，而摘要每次 compact 都由它自己重寫。
這是 [[test-independence-is-the-spec-not-the-model]] 的 player-and-referee，只是換到交接層。

## 成本模型：**往返次數 × context 大小**

實測拆帳（`8/27 auditor` 的 `/pre-compact`，11 個 request、context 583k→598k）：

| | 加權（cache_write 1.25×／cache_read 0.1×／output 5×） | 佔比 |
|---|---|---|
| 第 1 個 request 的冷寫入 | 692,971 | 51% |
| req 2–11 的 cache_read ＋ output | 674,089 | 49% |
| 其中 **output** | 64,050 | **4~5%** |

🔑 **output 只佔 4~5% ⇒ 砍回報是砍錯地方。** 省錢要砍的是**往返次數**。

## 🔴 冷寫入是「離開多久」造成的，不是「跑了什麼」

我原本把冷寫入算進 `/pre-compact` 的帳（宣稱它吃掉 9%）。**被 `交接摘要 Skill` 推翻，我拿 JSONL 判定它對。**

掃 08-20 之後所有 transcript，「閒置 >30 分鐘後的第一個 request」：

- context >100k 的閒置回歸 **102 例**，其中 **68 例（67%）冷比例 >80%**
- 絕大多數前導指令是**「(一般輸入)」**，不是任何 skill
- 🔑 **決定性的一筆：前導指令是 `/model`——只改設定什麼都不做——冷比例 100%**

⇒ **`/pre-compact` 的真實成本是那 9% 裡的約 4.4%**，另外 4.6% 是離開 3.27 小時的固定成本。

**⇒ 你控制不了「快取會冷」，你控制得了「冷的時候 context 有多大」。**
離開前跑 `before-sleep` + `/compact`，那筆躲不掉的冷寫入就付在壓縮後的小 context 上：
**554,377×1.25 = 692,971 vs 124,063×1.25 = 155,079 ⇒ 約 4.5 倍**（⚠️ 不是「一個數量級」，
那是我沒驗就寫的數字，見 [[the-clean-version-is-the-one-to-recheck]]）。

## 🔴 `isRunning` 不能拿來判斷「還有什麼開著」

`list_sessions` 的 `isRunning` 是**「此刻正在處理一輪」的毫秒級旗標**，與「還開著什麼」**正交**（不是下界）：

- **會漏**：正在密集對話的 session 在兩輪之間顯示 `false`（實測抓到兩個活例）
- **也會多**：顯示 `true` 的常常只是卡在一輪裡，幾秒後結束，**一樣不會活過今晚**
- 實測 `8/27 mainDev` **90 秒內 true→false**

✅ **用 `lastActivityAt`**，取最近 30~60 分鐘。
🔑 **分界不會乾淨，要預期中間有東西**——兩次實測**兩次都有**一筆卡在中間（78、104 分鐘，
兩次都是同一個 `Context` session），形狀固定：一批擠在半小時內、一批隔十小時以上、中間卡一兩個。
照實列出來讓人判斷，**不要為了清單漂亮砍掉邊界上的那筆——那一個往往正是他忘了的那個**。

⇒ 這裡原本寫的是「不保證乾淨」，**n=2 全中之後改成「不會乾淨」**：前者讓人預期乾淨、
把雜訊當例外處理；後者讓人預期雜訊。`交接摘要 Skill` 已照這個語氣改進 `before-sleep`。
（原句偏軟的方向又是 [[the-clean-version-is-the-one-to-recheck]] 那個偏誤。）

## `memory-lint.sh`（結構層七項，十秒）

```bash
bash ~/.claude/skills/shared/memory-lint.sh <記憶目錄>
```

重複 frontmatter 鍵／缺 `name`／`name` 與檔名不符／索引↔磁碟**集合**相減／斷鏈／自我指向／被換行切斷的連結。
已掛進 `memory-checkpoint` Phase 4 結尾。**動完記憶目錄就跑一次。**

🔑 **不要把「檔數」寫成基準。** 這個目錄有多個 session 同時在寫——08-27 夜實測：
同一次收工我自己就寫出兩個數字（狀態檔中途 118、最終回報 120），**四分鐘後別人又寫成 122**。
基準只能是「**七項有沒有過**」。
⚠️ 而第 4 項（孤兒檔）**正常會抓到別人寫到一半的檔**：新檔先落地、索引後補，中間那段就是孤兒。
⇒ **看到孤兒先查 `mtime`，不要急著替別人補索引**——對方可能正在寫 `MEMORY.md`，搶著改會互相覆蓋。
（[[two-writers-one-worktree]] 在記憶目錄的版本。）

⚠️ 兩類已知偽陽性都已在腳本內處理，但知道形狀有用：**行內反引號的 `` `[[wikilink]]` `` 範例**，
以及**圍籬程式碼區塊裡的 bash 語法**（`[[ $n == 0 ]]`、`[[:space:]]`）。
🔑 後者是**結構性的**——這個記憶庫的用途之一就是記錄 shell 陷阱，而 bash 的 `[[` 與 wikilink 的 `[[` 是同一個 token。

## 🔑 `MEMORY.md` 的兩個**硬**上限（08-30 從 CLI 執行檔挖出，四個常數全第一手）

出處：`~/.local/share/claude/versions/2.1.223`（290MB ELF，`grep -ao 'Qae *= *[0-9]*'` 之類直接搜得到）。

```
lineCap  Qae  = 200      行數上限
byteCap  eRe  = 25000    大小上限
warn     b0_  = 0.8      超過就出現 PostToolUse:Edit hook 提示
target   a$d  = 0.7      提示裡建議壓到的目標
```

- **兩道獨立的天花板，`reduce` 取比例最大的那一道** ⇒ **誰先滿誰生效**。
  「200 × 150 字元 = 30,000 > 25,000 所以規則自相矛盾」是**類別錯誤**（我犯的）——
  `under A and under B` 不主張兩個最大值可同時達到。
- 🔴 **單位是 UTF-16 code unit（JS `.length`），不是 bytes**——欄位名叫 `sizeBytes` 是誤導。
  ⇒ **中文一字算 1，emoji 算 2**；`wc -c` 量會高估約 1.6 倍（CJK），`wc -m` 才接近。
  實測本檔：code point 17,424 vs UTF-16 17,501（77 個非 BMP，差 0.3%）。
- **截斷不是全然無聲**：被截的內容會被接上 `> WARNING: … Only part of it was loaded.`
  （但 hook 自己的文案寫 "silently dropped"，兩處措辭不一致。）
- **兩側的修法相反**：行數超標 ⇒ **退休條目**（寫短救不了）；字元超標 ⇒ **瘦身 hook**。
  `memory-lint.sh` 第 8 項已分開報這兩個。
- 🏁 **08-30 Adam 裁決：`MEMORY.md:2`（poster／bmv2 那條，973 字元且還在長）不砍**，
  **也不准為了補這個缺口去壓別條**——它佔掉的餘裕是他的取捨，不是遺漏。⇒ 下次檢查點不要重提。

⚠️ 官方 `consolidate-memory` 那句 `under 200 lines and ~25KB … under ~150 chars`
**是照抄這些常數**，不是憑感覺寫的——`25KB` 的寫法讓人讀成 bytes 是它唯一的缺陷。

### 🪞 這一輪真正的教訓：**看不出一條規則的理由 ≠ 它沒有理由**

08-30 一晚我在同一件事上錯四次（用 bytes 量／「25KB 沒意義砍掉」／「200 行降成提醒」／
「三個數字互相矛盾」），**四次同一個毛病**。往下挖三層，每一層都推翻上一層：

```
我們的慣例檔 → 官方 skill 的一句話 → CLI 執行檔的常數與判定邏輯
「可以改」   →  「別人隨手寫的」    →  「一開始就沒有矛盾」
```

⇒ **停在哪一層，決定你錯得多離譜。**
可操作：**推翻一條規則之前，先找它的作者或第一次出現的地方。理由通常不寫在規則旁邊。**
🔑 兩次陰性結果都是儀器壞的：我 grep `lines after` 零命中（em-dash 被字元類切掉）、
對方搜常數零命中（搜錯目錄）——**差點各自拿去當「不存在」的證據**。

相關：[[the-clean-version-is-the-one-to-recheck]]、[[cross-session-report-format]]、[[two-writers-one-worktree]]、
[[mutation-gate-for-tests]]（對方的測試產生器寫出無效 UTF-8、閘門仍顯示綠燈）。

## 🔴 索引鉤子決定一條記憶會不會被查到——所以鉤子漏掉的事實等於不存在

08-31 實例，代價約一小時：`cross-repo-component-ecosystem.md` 從 08-15 起就寫著
**「Sim-Mgr/Energy 已可全鏈跑（root 跑 binary 即可，NFS 基建本就在）」**，
而我在 08-31 花了三個實驗階段重新推導出「這兩支要 root、要 NFS」。

**我沒有讀那個檔，因為 `MEMORY.md` 給它的鉤子是**：

> `components.env` 是路徑真實來源

**鉤子是真的，但它只講了那個檔的一個事實。** 判斷「要不要開這個檔」的人看到的只有鉤子，
所以**沒被寫進鉤子的事實，在檢索上等於不存在**——它比沒記還糟，因為記憶目錄的行數被佔了，
而下一個 session 仍然要自己重跑一次。

🔑 **鉤子不是摘要，是檢索鍵。** 寫的時候問的不是「這個檔在講什麼」，
而是「**下一個 session 會為了什麼問題來找它？**」——然後把那些問題的關鍵詞放進去。
一個檔涵蓋五個主題就要五個關鍵詞，寫不下就是那個檔該拆了。

⚠️ 這跟「鉤子不要超過 150 字元」有張力，而張力是真的：`memory-lint` 第 8 項報過長，
但**過長的修法是瘦身措辭，不是刪掉關鍵詞**。刪關鍵詞會讓那條記憶靜默地檢索不到，
而 lint 永遠不會報這種失效。
