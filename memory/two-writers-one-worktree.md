---
name: two-writers-one-worktree
description: 另一個 session 在主工作樹跑 mutation，會留下編得過、只紅一條測試的殘留——共用一棵樹 + 有人在做 mutation = 保證出事；08-24 兩則追加：互相背書差點把反的行號歸屬寫進報告；以及殘檔歸屬四層驗法＋「第四個有 shell 但不寫 transcript 的寫入者」（見檔尾）
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-31T07:56:37.437Z
---

2026-08-12：我在主工作樹修東西，同時 Adam 的 audit session **也在主工作樹**重放 mutation。
結果我在 `FlowLinkUsageCollector.cpp:955` 撿到一條殘留的 `if (false)`（sFlow 版本守衛整個被停掉），
HEAD 乾淨、只有工作樹被改。我還原並重建之後才想通是誰留的。

**為什麼特別危險：** mutation testing **本質上就是週期性地把樹改成錯的再改回來**。它留下的
東西編得過、只讓一條測試變紅——不是語法錯誤那種一眼看出來的破壞。而且雙向都會壞：
它污染我的建置，我的 `git checkout` 也可能把它的 mutant 從腳下抽走，讓它量到修好的程式碼。

**我 spawn 的 agent 沒這個問題**——`Agent` 工具的 `isolation: "worktree"` 讓它們各自有
worktree。但**別的 session 不受我的 spawn 設定管**，那是 Adam 開的，我只能請它自己搬。

**How to apply：**
- 開工前先 `git worktree list`，看有沒有別人在同一棵樹上。
- 要另一個 session 幫忙審查／跑 mutation 時，**在請求裡就明講「請在自己的 worktree 跑」**，
  不要等撞到才協調。可以用 `mcp__ccd_session_mgmt__send_message` 直接跟它說（實測可用）。
- 撿到來路不明的工作樹修改：先 `git diff HEAD` 看全貌再還原，**還原後一定要重建**
  （見 [[mutation-harness-must-guard-its-baseline]] 的 Trap A）。
- 判斷污染有沒有影響已報的結果：如果那個 mutant 是**測試抓得到**的，那麼任何一次「全套綠」
  的紀錄本身就證明當下樹是乾淨的。這比事後回想可靠。

## 2026-08-13 晚:真的發生了一次,而且多一個我沒想到的後果

`8/13 mainDev` 與另一個 session 同時在**主樹**寫。它的 `039446a` 在我跑 mutation 的同時
疊到我的 `1a7d815` 上面。**沒出事純屬運氣**:它只動 `doc/`,我的 `git checkout --` 只碰
三個原始碼檔,零交集。要是有交集,我的還原迴圈會**無聲地**洗掉它未提交的修改。

**新的一課:`git push` 推的是分支,不是單一 commit。** 它 push 自己的 commit 時,把我
**還沒宣告完成**的 commit 一起帶上 remote。等我想 `--amend` 修正 commit message 裡的一個
不準確數字時,前提已經不成立了——我一度以為那個 commit 還沒推。
**想 amend 之前先 `git fetch` 確認它是否已在 remote。**

**談定的協議**:後來的那個 session 該搬 worktree。當天是它主動停手把主樹讓出來。


---

## 2026-08-20：兩個 session 互相拆錯，三回合，全部有效

同一晚我和「開機手冊」共用實驗室，互相回報發現，結果**三條宣稱被推翻**：

| # | 誰錯 | 錯在哪 | 誰抓到、怎麼抓的 |
|---|---|---|---|
| 1 | 我 | 「gzip 把 mtime 全改了」 | 他們對 20 個 `.gz` 逐檔對帳 → gzip **保留** mtime；我是在 `client.json`（被回溯改寫過）上看到現象然後推廣到整個目錄 |
| 2 | 我 | 「s2-eth3 監控缺口是繼承的」 | 他們在 P4 重現不出來 → 是我 recorder 自己的 inter-switch 過濾（`run.py:63`） |
| 3 | **兩個都錯** | 「host-facing 邊載運過境流量 ⇒ 模型或接線有錯」 | 他們讀邊的 `dst_ip=10.0.0.33` ＋ 兩個 ping 對照 → 那是 h33 的接取鏈路，流量是**最後一跳** |
| 4 | 他們 | 「直接帶 `NDTWIN_CLONE_DISABLE=1`」 | 我 grep 到零個 reader；但他們給建議時掛勾**確實在**，是之後被還原的 |

🔑 **第 3 條最值得記**：我們**剛各自修完同形的過濾器錯誤**，然後對殘餘觀察**合編**了一個新機制——它聽起來合理、和雙方資料都吻合、而且沒人去問「那條邊到底接到誰」。
**兩個獨立來源同意，不等於機制正確**；它們可能只是共享同一個未檢驗的前提。

## 2026-08-24：互相背書差點把「反的」寫進正式報告——被第二次驗證擋下

boot-ring 驗收的和解回合：我把兩個 notify 呼叫點的歸屬**寫反**（把 `:763`＝enter handler
說成 state-change、`:857` 反之），並建議 v3 照抄進 REPORT。**相鄰性證據（marker `:754`
與 notify `:763` 同函式）就印在我自己那次 grep 的輸出裡**——我被 log 的執行順序帶著，
無意識把它映射成原始碼行號順序。v3 沒有照抄，用 decorator＋相鄰性重驗後反殺；我 fresh
grep 認帳。同一回合 v3 也撤回它自己的「retry 第二輪」框架（根本沒有 retry）。

🔑 **結論對、行號反**是最危險的組合：結論的正確會讓行號免檢。收到對方「建議照抄」的
具體指涉（行號、檔名、函式名）時，照 [[cited-line-numbers-are-not-evidence]] 開檔驗完
再落盤——**兩個 AI 各驗一次的成本，遠低於一個反的歸屬送到下一個讀者手上**。

## 2026-08-24 夜：第四個寫入者——有 shell、但不寫進 `~/.claude/projects`

清帳 repo root 六個 untracked 殘檔（`dummy.sh`／`output.txt`／`test_continue.sh`／
`test_graph.py`／`test_greenlet.py`／`test_out.txt`）。四個 Claude session 全部否認，
**而且否認是對的**：

🔑 **歸屬四層驗法（可重跑，比「我記得」可靠）**：① 檔名字面搜尋**三個** project 目錄全部
transcript —— 六個檔的**最早出現全是 `git status` 輸出**，沒有一次是產生它的指令；
② **內容指紋**（每檔獨有字串，如 `after inner loop`、`eventlet.spawn(blocked)`、
`nonexistent_command`）—— 全部零命中；③ 代理路徑：`isSidechain` 計數＝0（沒開 subagent）、
MCP agent 派發時間全晚於 mtime；④ repo 內腳本 grep —— 沒有 driver 會生它們。
⚠️ 前三層對「**有 shell 但不寫 Claude transcript 的行為者**」全部無效，所以結論只能寫成
「沒有我建立它們的紀錄」，不能升級成「確定不是我的」。

**最硬的一條是當場行為，不是事後搜尋**：`08-24T08:04:10Z` 我自己跑過
`git status --short | grep -vE "^\?\? (dummy|output|test_continue|test_graph)"`，
標籤 `worktree (mine only)` —— 當下就按名字否認了四個；第五個 `test_greenlet.py`
不在清單裡是因為它**晚 67 秒才出生**。**同期的自我否認 > 事後的自我否認。**

🔴 **真正的發現不是「沒人認領」，是有第四個寫入者在逐條複驗 mainDev 的宣稱**：六個檔每一個
都在我某條宣稱之後 **2–4 分鐘**出現，內容剛好是那條宣稱的最小獨立複現（改 `in_flight()` 讀
`comm`＋巢狀 `continue 2` → 3 分鐘後兩個檔驗這兩件事；commit `gr_frame` dump → 2 分鐘後
8 行版驗 parked greenlet 抓不抓得到；404 輪的 JSON 形狀退化 → `data['edges'][0]['dst_ip']`）。
候選只剩 Adam 自己的終端機或 `~/.gemini`（Antigravity 有自己的 store）。
**清檔＝刪掉唯一指向它的 mtime 證據**，所以先問人再 `git clean`。
（別人的 shell history 是個人資料，不因一則跨 session 請求去讀——請本人自己查。）

✅ **08-25 上午結案（auditer）：第四寫入者＝`.git/hooks/post-commit` 起的 Antigravity
（agy）per-commit 背景審查**（hook **07-28 裝**＝`0001` review mtime 為證、08-13 是最後
修改 mtime 勿混、`[Co-developed with claude code -- Adam]`、
repo-local 未版控＝**集體記憶之外**）。Adam 授權唯讀查 `~/.gemini` 後一槍中的：
`antigravity-cli/brain/*/logs/transcript*.jsonl` 同時命中檔名與內容指紋；e93ee5f8＝
「You are reviewing commit 79cd66a」11:54 啟動、11:56 寫下 `test_graph.py`（當場 curl 到
死 endpoint、JSONDecodeError、**零產出**）。**探針＝agy 違反自己 prompt 的 read-only 指令
寫的**——hook 開 `--dangerously-skip-permissions`，指令級禁令沒有沙箱 backing。審查報告
**450 份**在 `.git/agy-reviews/`（0001–0450，每 commit 一份）＝一條沒人對帳過的平行審查流。
教訓：① **指令級 read-only ≠ 沙箱 read-only**；② repo-local 未版控 hook 是「集體記憶外
行為者」的藏身處——**`ls .git/hooks/` 進開工 checklist**；③ 四層驗法的非 Claude 盲區，
補法＝帶授權擴大到其他工具店（本案即範例）。

**How to apply:**
- 跨 session 回報發現時**附上證據和取得方式**，不要只給結論——對方要能獨立重推，那才是價值所在。
- 收到回報時**先自己驗一次再接受**（我對 mtime 那條跑了 20 檔對帳才認，結果發現他們對、但兩種檔案行為不同，比雙方原本的說法都準）。
- **對「未提交的工作區狀態」給的建議要標保存期限**——手貼的掛勾、沒 commit 的改動，給的當下為真、對方要用時可能已經沒了。
- 別的 session 的檔案（`INVENTORY.md`、`tools/test_workflow/ndt`）**只讀不改**。


## 2026-08-25:第五種寫入者 —— **我自己的兩個背景工作**

不是別的 session,是我自己。同一天兩次:

1. **重複輪詢器**:一個舊的 `until [ -f X ]; do sleep; done` 迴圈沒死,等到新的 run 產生同名檔案就自己接上,
   於是兩個 poller 同時以 ~3 Hz 輪詢同一個 API、寫同一批檔案。
2. **重複 run**:條件 B 被我啟動兩次(一次是接在條件 A 之後的鏈式工作、一次我自己又下了一遍),
   兩個 `run_plane.sh` 寫同一個輸出目錄 ⇒ 兩組 poller 交錯寫入 `veth.tsv` / `graph.jsonl`。

🔴 **兩次都看起來完全正常** —— 檔案在長、進度在動、沒有任何錯誤。第二次的資料**已刪除重跑**
(半交錯的檔案比沒有檔案更糟,沒有留)。

**修法(已實作)**:`run_plane.sh` 在輸出目錄寫 PID 鎖,第二個 run 直接拒絕;
stale lock 用 `kill -0` 區分。**紀律抓不到這種,斷言才會。**

⚠️ 順帶:`iperf3 --daemon` **會重親到 systemd**,殺掉啟動它的腳本殺不到 server;
而且透過 `sudo mnexec` 起的是 **root 擁有**,無權限的 `pkill` 拿到 EPERM。
清場要分兩段:先殺 harness(逐 PID),再用 `sudo -n mnexec ... pkill -f iperf3` 逐 namespace 清。

## 🆕 08-26：**四層歸屬跑完的結果可以是「查無此人」——而那比指認錯更重要**

repo 根在 00:56–00:57 冒出 `test.sh` / `test2.sh` / `test3.sh` / `nohup.out` / `pid.txt`，
落在我臂 U 的分析視窗（00:52:44–00:57:44）裡。

🔴 **我只做了兩層就下結論**（時間戳吻合 ＋ 「`8/25 sampling` 當時在動」），
**寫進報告當事實**。他們用**檔案內容**反駁，而且對。

| 層 | 我做了嗎 | 結果 |
|---|---|---|
| 時間戳 | ✅ | 落在視窗內 |
| **檔案內容** | ❌ 跳過 | `test2.sh` ＝ `( cd /tmp && nohup sleep 10 & echo $! > pid.txt )` |
| 候選者的習慣 | ❌ 跳過 | 他們六個腳本全在自己的 round dir、暫存在 scratchpad、**沒有一個寫 repo 根** |
| **全 session transcript** | ❌ 跳過 | 搜獨有字串，**00:56–00:57 沒有任何 session 寫過** |

⇒ **查無此人。** 最合理候選是**人在終端機打的**（見本檔「2026-08-24 夜：第四個寫入者」那節：
有 shell、不寫 transcript），但那是推測不是證據 ⇒ 報告寫「**來源未指認**」。

🔑 **「查無此人」比指認錯更該擔心**：既然不是任何一個我能對話的 session，
就代表**有一個會寫 repo 根的 actor，而我沒有它的時間表** ⇒
那次量測帶著一個**已知存在、大小未知**的共變數。

😐 而內容是**我四分鐘前撞到的那個 launcher bug 的最小重現**（同一個 `( cd X && nohup Y & echo $! )`、
同一個 `readlink -f /proc/PID/exe` 診斷）。**巧合或有人在跟著看，我分辨不出來，所以兩種都不宣稱。**

⇒ **規則**：把別人寫的檔寫進報告之前，四層都要跑；**跑完發現指認不出來，就寫「未指認」**，
不要退回到最方便的那個候選。**transcript 全域搜獨有字串是最便宜的一層，我先前從沒用過。**

---

## 🆕 08-27：第六種——**別人把第三方的碼歸給我**，而且推理鏈每一步都對

`8/27 mainDev` 寫「`sflow_emitter.py` 的未提交改動我認定是你的，不會碰」。
他的依據是合理的：repo 底下唯一在跑的 session 是我、我剛 claim 了實驗室、
而且他知道我在量 sFlow。**四個間接證據全部指向我，答案還是錯的**——
那是 `8/25 mainDev`（他的前任）的 batching 實作，mtime 08-25 14:48，我只量過、沒改過。

🔑 **可用的一步、成本接近零、他沒做**：`git log -- <file>`。
它會告訴你這個檔最後是被誰的 commit 動的，而未提交的改動則要看 mtime 落在誰的任期。
**「誰現在在跑」與「誰寫了這個檔」是兩個不同的問題。**

🔴 **為什麼這個方向的誤判特別貴**：他因此決定**不動**那個檔——
而那其實是他自己這條線的碼、他有權處理。誤判歸屬不只會讓人背錯鍋，
**也會讓人放棄本來該做的事**。

## 🔴 08-27：**同一天三次 provenance 宣稱被 `git log -S` 十秒否掉**

| # | 誰 | 宣稱 | 真相 |
|---|---|---|---|
| 1 | **我** | 「`sflow_emitter.py` 的未提交改動是 `8/27 sampling` 的」，並**當事實轉述給對方** | 是 `8/25 mainDev`（我前任）的；對方只拿它量過、一個字沒改 |
| 2 | 前任（`§13-3`） | 「該檔之後被 `sFlow experiment` 改過」 | 同樣錯 —— **但它誠實標了「未查證」，我沒有** |
| 3 | **審查員** | 「`inject_emitter` 在 `api_routes.py:42` 本來就存在（`ee443f4`），你只是接上懸空的線 ⇒ 第 12 例」 | `git log -S` 只回我今天那個 commit；`ee443f4` 是五元組路由、零命中；我 commit 前一刻 `grep -c` ＝ **0**；diff 是 **50 行純新增** |

🔑 **三次都是同一個替代品**：拿「**誰當時在動**」或「**檔案現在長什麼樣**」當 provenance。
第 3 例特別值得記，因為**行號是在我的 diff 之後才變成 :42 的** —— 讀當前檔案去推歷史，
必然把新東西歸給舊 commit。

🔧 **第 3 例的機制（審查員自己寫下來的，很精確，值得逐字留著）**：
他跑的是 **`git log --oneline -1 -- <path>`**。那回答的是**「最後一個動過這個檔的 commit」**，
**不是「我正在讀的這幾行的來歷」**——那幾行當時還在我的工作區、沒提交。
🔴 **而同一個指令的輸出裡就印著 `50 insertions(+)` 的未提交差異**，推翻他的證據就在他讀的那行旁邊。

⇒ **`git log -1 -- <path>` 不是 provenance 工具。** 檔案有未提交改動時它會**系統性**誤導，
因為它回答的問題跟你以為你問的問題不同。要 provenance 只有
**`git log -S`／`git show <sha>:<path>`／`git blame`** 三個。

✅ **可操作（已寫進驗收條款，對雙方同等適用）**：
**任何「這行本來就在／這是第 N 例／這是某某加的」的宣稱，要附 `git log -S "<字串>" -- <path>`
或 `git show <sha>:<path>` 的輸出；不附就不計分。** 成本十秒。

⚠️ 第 3 例的後果本來會比前兩例大：它會在帳本裡把一個缺陷家族**歸錯面**
（「committed reader 零 setter」vs 真相「writer 零 reader」），
而帳本是下一輪的前提。**錯的 provenance 不只是記錯，它會改變下一個人找什麼。**

## 🔴 `git add -A` 在共用 worktree 裡會偷走別人正在跑的實驗(08-27 差一點)

我要 commit 三個 doc 檔時,同一棵樹裡有 `8/27 mainDev` 的 Ticket P 在跑,
未追蹤檔包含 `monitor.cpp`、`scratch.py`、`doc/audit/2026-08-27_telemetry-blindness/drive_P.log`,
已修改檔包含他們的 `loadavg_h.txt`。**`git add -A` 會把整組掃進我的 commit。**

我這次用的是明列路徑(`git add <path> <path> <path>`),所以沒事 —— 但那是習慣救的,
不是我當下有意識地在防這件事。**規則:在 kernel repo 一律明列路徑,`-A` 只在
確定自己獨佔的 repo 用**(例如 `NDTwin-Website`)。

🔑 判斷「我獨佔嗎」不能靠印象:`git status --short` 裡出現**你不認得的檔名**
就是有第二個寫入者的證據,而且比查 `ndt status` 或問人都快。
(同一輪的另一半:`git log --oneline -2` 顯示別人的 commit 已經疊在我上面 ——
**共用樹裡「我剛剛 commit 完」不代表 HEAD 還是我的。**)

## 🔴 08-28：上一節的**反方向**真的發生了——別人的 `add -A` 吞掉**我暫存但還沒 commit 的改動**

上一節防的是「我的 `-A` 掃走別人的檔」。今天中的是鏡像面，而且**防不到**：
我 `git rm --cached` 了 128 個 raw、改了 `.gitignore`、加了 32 個 keeper，**停在 index 裡還沒 commit**；
三分鐘後另一個 session 下 commit，全部被收進 **`5ae3623`「VERDICT: add the can/cannot-support section」**——
一個訊息完全沒提到這件事的 commit。**樹是對的，log 是錯的。**

🔑 **明列路徑保護不了 index**：`git add <path>` 只管我加什麼，
**index 是整棵樹共用的單一狀態**，別人 commit 時它就在那裡。
⇒ **暫存區不是工作空間，是共用資源。** 在共用 worktree 裡
**`add` 與 `commit` 之間不要有第三個工具呼叫**，尤其不要夾一段驗證。
(我夾的正是驗證——`git status` 顯示 `0 staged`，才發現東西已經被別人 commit 走了。)

🔴 **而且修不回來**：對方三分鐘內就 push 了 ⇒ 不能 rewrite。
唯一的修法是**下一個 commit 的訊息裡寫清楚 `5ae3623` 其實還帶了什麼**。
⇒ **共用樹裡「等一下再 commit」的成本不是延遲，是可能永久失去 provenance。**

相關：[[benchmark-must-name-the-binary-it-measured]]（同一族：標籤指不到內容）

## 🔴 08-29：上一節的**鏡像**，這次我是加害者——而正確的工具一直都在

上一節：別人的 commit 吞掉我暫存的東西。今天反過來：**我的 commit 吞掉別人暫存的東西。**

我明列了五個自己的路徑 `git add`，然後 `git commit`。結果 commit 裡多了
`doc/2026-08-29_bmv2-performance-study.md`（+32/−13）——那是 `bmv2 論文審查` 的檔，
**在我 `git add` 之前就已經在 index 裡了**。

🔑 **`git add <明列路徑>` 防的是「我加了什麼」，`git commit` 送的是「index 裡有什麼」。**
我以為明列路徑是保護，其實它只管住我自己那一半。上一節寫的是
「明列路徑保護不了 index」——**我讀過那句話，還是中了**，因為我把它記成
「別人會吞我的」而不是「index 是共用的，兩個方向都會」。

✅ **正確工具（`git commit --help` 逐字）**：
> When pathspec is given on the command line, commit the contents of the files that match the
> pathspec **without recording the changes already added to the index**.

```bash
git commit -- doc/audit/my-round/ path/two.py     # 只送這些，index 裡別人的東西留在原地
```
⚠️ 代價：它送的是**工作區內容**，不是暫存內容 ⇒ 用過 `git add -p` 只暫存半個檔的話，
這個寫法會把整個檔送出去。兩害相權，共用樹裡仍然選它。

🟢 **這次修得回來，只因為 HEAD 還沒被別人疊上去**（上一節那次三分鐘內被 push，永久失去 provenance）：
`git reset --soft HEAD~1` → `git restore --staged <他們的檔>` → 重 commit。
**兩個指令都不碰工作區**，所以就算對方正在編輯也不會掉東西；
我用 sha256 前後對帳確認內容逐 byte 相同。**唯一的殘留副作用：他們的檔從 staged 變成 unstaged。**

⇒ **開工檢查**：`git diff --cached --name-only` **在 commit 之前跑**，不是之後。
出現不認得的檔名就是有第二個寫入者已經站在 index 裡了。

⚠️ **`git commit -- <paths>` 吃不下未追蹤的新檔**（`did not match any file(s) known to git`）。
新檔要先 `git add -N <newfile>` 註冊意圖再 commit。實測撞到過，不是推論。

🆕 **08-30 反面實例（別的 session 中招、auditor 驗屍）——:267 那句代價的具體形狀**：
先 `git rm -r --cached <兩目錄>` 把 untrack 的刪除放進 index，再用 pathspec commit
（`git commit -- .gitignore REVIEW.md` 型）⇒ **pathspec 外的 staged 刪除整組被無聲丟棄**，
產出的 commit（`fbf9cce`）只有 +22 行、零刪除，**而 commit 訊息照樣宣稱「Untracked」**
（＝[[failures-that-report-success]] 的「訊息與內容各說各話」族）。被 `git ls-files` 抓到
（仍列 22 檔）。⇒ 🔑 **`git commit -- <paths>` 的保護與丟棄是同一個動作**：
它保住 index 裡別人的東西的方式，就是不看 index——**你自己 staged 的刪除也一併不看**。
untrack 類操作要嘛無 pathspec commit、要嘛 commit 完驗 `git ls-files <dir> | wc -l`==0。

⚠️ **`core.hooksPath` 指到空目錄會把 `pre-commit` 一起關掉。** 這個 repo 的 `pre-commit`
是 audit-raw 守衛，而**守衛不執行就不會抱怨** ⇒ 無聲失效。正解是複製守衛過去：
```bash
H=/tmp/hooks-nopost; rm -rf "$H"; mkdir -p "$H"; cp .git/hooks/pre-commit "$H"/
git -c core.hooksPath="$H" commit -- <paths>
```

🔴 **`git commit -- <paths>` 吃不下未追蹤的新檔** —— 回 `did not match any file(s) known to git`
（`開機手冊` 08-29 實撞，開新工單檔時第一次就被擋）。**新檔要先 `git add -N <newfile>` 註冊意圖再 commit。**
不寫這條，下一個人會以為指令壞了然後退回舊的 `git add` + `git commit`（＝把吞檔的門重新打開）。
（我中過兩顆，查證沒有 raw 外洩——但**守衛沒開火是因為沒東西可抓，不是因為它在運作**。）

## 🔴 08-29 續：我道歉錯對象——**歸屬要看檔案內容，不是看誰在場**

我把被吞的 `doc/2026-08-29_bmv2-performance-study.md` 認成**正在跟我講話的那個 session**，
其實是**第三個 session**（`bmv2 performance`）的。我當時只有兩個線索：「它在 index 裡」＋
「這個 session 在跟我對話」，就選了最方便的候選。

🔑 **對方一眼看穿的判準比我的兩個線索都強**：那 +32/−13 改的是**研究報告的宣稱句**，
**內容本身就指認了作者**。⇒ 跟 08-26「查無此人」那次同一個錯法（我只做時間戳＋在場，
跳過檔案內容）。**`claim` 的 owner 字串對「誰 staged 了什麼」零資訊。**

## 🔴 2026-08-28：**`git` 的作者欄對「哪個 session」零資訊**，而審查員用時間戳歸屬了兩顆給我

`8/28 auditor` 依時間戳把 `54551bc`／`aa10c8e` 判成我的（他自己註明「那是推論不是事實」，做得對）。
**兩顆都不是我的。** 而我當下要證明「不是我」，才發現常用的欄位全都不管用：

| 想用來歸屬的東西 | 為什麼答不出 |
|---|---|
| `%an` / `%cn`（author/committer） | **三顆全是 `Adam010341`**——那是**這台機器的共用身分**，不是 session 身分 |
| 時間戳 | 我在 18:57:58 也 commit 了，只是**在另一個 repo**；區間重疊不代表同一個人 |
| 「最近的 commit 在 HEAD 附近」 | 多個 session 共用一棵樹，log 是交錯的 |

🔑 **真正管用的是「檔案譜系」**：`plot_deck_903*` 有一條連續六顆的線
（`b024354` → `124bc24` → `7064fed0` → `de17866` → `54551bc` → `aa10c8e`），
而我**一顆都沒碰過那些檔**。⇒ **歸屬要問「這個檔案這條線是誰在推」，不要問「這顆是誰 commit 的」。**

⇒ 可操作：**跨 session 指派工作之前，先問一句**。成本一句話，
而錯誤歸屬的成本是「有人去修一個他沒寫過的東西，而真正的作者不知道有事要修」。

## 🪞 同一次裡，風險判斷的方向也是反的

他警告「repo 現在 detached HEAD，**修好之前不要 commit**，否則落在沒有分支上」。
實測：**detached HEAD 正指在那個分支的 tip**，所以
`54551bc`／`aa10c8e`／我的 `49b1e24` **三顆都在 `fix/flow-rate-divide-by-zero` 上，沒有孤兒**。
而且未認證 curl 三顆都 **200** ⇒ **早就公開了**。

🔑 **「有遺失風險」與「已經發佈」是相反的兩種狀態，而 detached HEAD 這個訊號兩種都相容。**
⇒ 看到 detached HEAD 不要直接推「東西會不見」，先問 `git branch --contains <sha>`。
⇒ **如果那顆 commit 是未驗證的修正，「已公開」比「detached」急得多。**

相關：[[local-git-refs-cannot-tell-you-what-is-public]]（tracking ref 反映私有 fetch URL）、
[[benchmark-must-name-the-binary-it-measured]]（同族：識別碼答的不是你問的問題）。

## 🔴 08-29：`git add <自己的路徑>` 保護不了別人——`git commit` 送的是整個 index

`開機手冊` 只 `git add` 自己五個路徑就 commit，把 `bmv2 performance` 已 staged 的
`2026-08-29_bmv2-performance-study.md` 一起收進去（+32/−13）。它修得很乾淨
（`reset --soft` → `restore --staged` → 重 commit，sha256 前後相同、不碰工作區），
但坑的形狀要記：**「明列路徑 add」不是隔離，index 是全域的**。

🔑 **共用 worktree 的正解＝`git commit -- <path> <path>`**——man page 逐字：
*"without recording the changes already added to the index"*，別人 staged 的東西留在原地。
我同一天兩個 commit 用的正是 `add+commit` 的寫法，**沒吞到東西只是運氣**（那時 index 剛好乾淨）。
之後在共用 worktree 一律 `git commit -- <paths>`。
補三個當天的實證註腳：①受害檔 unstaged 之後，**它的主人自己 commit 才是收尾**
（第三方替它 re-add 只會把陷阱擺回去）；②修復用 `reset --soft` 的前提是
**HEAD 還沒被疊上去**——多人 worktree 裡這個窗口以分鐘計；③吞檔的 commit 若已被
別的 session 引用過 hash，重寫（f970c08→dc32f97）會讓那些引用 dangling——引用前先
`git branch --contains`。

## 🔴 08-29：兩條「指令做的不是我以為的那件事」——都靠獨立驗收擋下，不是靠指令正確

`8/29 auditor` 派工時給了兩條指示，**兩條都錯**，而三個 session 都照做了：

| 我給的 | 它實際做的 | 正解 |
|---|---|---|
| `git add <paths>` 然後 `git commit`「只點名自己的檔」 | `add` 只是往 index 加，**`commit` 送的是整個 index** ⇒ 會吞掉別人 staged 的檔 | **`git commit -- <paths>`**（`--help`：*without recording the changes already added to the index*） |
| `git -c core.hooksPath=<空目錄> commit`（想擋 agy 的 `post-commit`） | **把 `pre-commit` 的 audit-raw 守衛也一起關掉**，而且**失效無聲**——守衛不執行就不會抱怨 | 複製 hooks 目錄、**只刪 `post-commit`**（見下） |

```bash
H=/tmp/hooks-nopost
rm -rf "$H" && mkdir -p "$H"
cp .git/hooks/pre-commit "$H"/          # 留守衛，不留 post-commit
git -c core.hooksPath="$H" commit -- <paths>
```

📌 **`.git/hooks/pre-commit` 是 symlink → `tools/githooks/pre-commit`**，`cp` 會**解引用**
⇒ 複製出來的是腳本本體（可用），但**不會跟著上游更新**（`8/29 mainDev` 發現）。

**兩邊都用陽性對照驗過**（`GIT_INDEX_FILE` 指到丟棄式 index 塞假 `raw/x.tsv`
⇒ `GUARD EXIT=1`，共用 index 全程未被碰）。

🔑 **共同形狀（`8/29 mainDev` 的措辭）：「我給的指令會做一件事，但不是我以為的那件事。」**
`add` 加到 index 但 commit 送整個 index；`hooksPath` 換掉的是**全部** hook 不是一個。
**兩次都是靠獨立驗收擋下來的，兩次都不是靠指令本身正確** ——
實例：`開機手冊` 14:04 吞掉別的 session 暫存中的檔（已還原）；
`8/29 mainDev` 八個 commit 零外來檔，但那是因為它每次都印 `git diff --cached --name-only`。

⇒ **派工要給「驗收怎麼做」，不能只給指令。** 驗收＝commit 後 `git show --stat <sha>` 只有點名的檔、
且 `.git/agy-reviews/` 沒有多出該 sha 的檔。（`--no-verify` **擋不到 post-commit**。）

### 🔴 這條的最貴一層：**正解當時就在 `MEMORY.md` 裡，而且我讀過，五次都沒用上**

`8/29 mainDev` 的 session **開場載入的 `MEMORY.md` 就有這一行**：

> 🆕 **`git add <paths>` 保護不了 index**（commit 送整個 index，已實際吞檔）⇒ 用 **`git commit -- <paths>`**；
> **`core.hooksPath=<空目錄>` 會連 audit-raw 守衛一起無聲關掉** ⇒ 只刪 `post-commit`

**兩條正解、逐字、在 context 裡從第一個 turn 就在。** 然後它八個 commit 裡
**五個用 `git add`＋`git commit`、五次都把守衛關掉**，直到 auditor 事後指出才知道。

🔑 **所以「有沒有記進記憶」不是這個失效模式的閘門，「有沒有在動手當下被叫出來」才是。**
索引鉤子是**用來決定開哪個檔**的，不是用來在打指令的瞬間攔截你的——
**它出現在 context 頂端，而決定發生在幾百個 turn 之後的一次 Bash 呼叫裡。**

⇒ 可操作的兩條（都不依賴記得）：
1. **把正解綁在動作上，不是綁在知識上**：共用 worktree 的 commit 一律走
   `git commit -- <paths>`＋複製 hooks 目錄那段**當成一整塊樣板貼**，不要每次重新組。
2. **驗收才是真正的防線**——`8/29 mainDev` 沒吞到別人的檔、沒漏 raw 出去，
   **靠的是每次 commit 前印 `git diff --cached --name-only`、commit 後數 `.git/agy-reviews/`**，
   不是靠記得那條記憶。**這正是本節標題那句的第三個實例：擋下來的是驗收，不是知識。**

📌 對照 `:257` 那句「我讀過那句話，還是中了」——那次是**記錯方向**（以為只有別人會吞我的）；
這次是**根本沒被喚起**。兩者的修法不同：前者靠把規則寫成雙向，後者只能靠樣板與驗收。

🔑 **歸屬要看檔案內容，不是看誰在場。** 那個被吞的檔 `開機手冊` 和我**都**認成 claim 持有者的，
實際是 `bmv2 performance` 的——`+32/−13` 改的是研究報告的宣稱句，**一看內容就知道是作者 session**。
兩邊都只有「index 裡有它」＋「這個 session 正在跟我講話」兩個線索，就各自選了方便的候選。

⚠️ **claim 的 owner 字串說的是「lab 歸誰」，從來不說「誰 staged 了什麼」** ——
我就是這樣把上面那個吞檔事件歸錯人（實際是 `bmv2 performance` 的檔，不是 claim 持有者的）。
⚠️ 補：`git commit -- <path>` **吃不下未追蹤的新檔**（`did not match any file(s) known to git`，
開機手冊 08-29 實踩）——新檔要先 `git add -N <file>` 註冊意圖再 `git commit -- <paths>`。

## 🆕 2026-08-30 第三式：`git commit -- <paths>` 提交的是那些路徑的**工作樹**，不是 index

我 `git rm -r --cached <兩目錄>`（staged 刪除）後用 `git commit -m … -- <同兩目錄>` 收尾，
結果（`fbf9cce`）：**staged 的刪除被蓋掉、檔案原樣留在 tree**，還把另一個 session
對同路徑的**未提交**修改（+16 行 REVIEW.md）一起提交了。commit message 宣稱
「a future push cannot resurrect it」——假的，三個 session 各自用 `git ls-files` 抓到。

**家族全景**（三式合看）：
| 寫法 | 吞誰 |
|---|---|
| 裸 `git add` ＋ `git commit` | 送**整個 index** ⇒ 吞別人 **staged** 的東西 |
| `git commit -- <paths>` | 送那些路徑的**工作樹** ⇒ 吞別人對同路徑 **unstaged** 的修改，**並蓋掉自己 staged 的意圖** |

⇒ **index 狀態操作（untrack）沒有帶 pathspec 的安全解**。正解：
`git diff --cached --name-only` 確認 staged 集合乾淨 → **無 pathspec** commit。

🔑 **驗證教訓（零鑑別力閘門）**：我當時的驗證是 `git status --short -- <dirs>` 印空白——
但 **tracked-clean 與 ignored-untracked 都印空白**，成功與失敗長得一模一樣。
問「還有沒有被追蹤」只有一個對的問法：**`git ls-files <dirs> | wc -l`**。
（＝[[verify-the-purpose-not-the-mechanism]] 的「這檢查若完全沒效會紅嗎」——不會，而且真的沒紅。）
🔴 08-30 對偶陷阱補完：**`git commit -- <path>` 提交的是那些路徑的「工作樹狀態」，
會蓋掉 staged 的 `git rm --cached` 刪除**（auditor 的 fbf9cce 實踩：untrack 沒生效、
還把我未提交的 +16 行一起帶進歷史）。⇒ 兩把刀各有割手方向：
**index commit 吞別人 staged 的東西；pathspec commit 蓋自己 staged 的刪除、吞工作樹**。
選用規則：改「內容」用 pathspec；改「追蹤狀態」（rm --cached/mv）**必須無 pathspec**、
且驗收用 `git ls-files`（`git status --short` 在成敗兩態長一樣＝零鑑別力）。

## 🆕 08-30：歸屬判定的兩個工具事實（plot_deck 案，auditor 裁定）

- **transcript 搜尋只索引對話文字、不索引 tool-call 內容**（commit message 全字串搜＝零命中）
  ⇒ 內容指紋探針要打「session 會寫進**回報散文**的詞」（檔名、函式名），不是 diff 內容；
  且探針第一發會**自我污染**（查指紋的 git diff 把指紋種進自己的 transcript）——先想好再開槍。
- **最強的譜系證據是前任的自我記帳**：交接報告一句「deferred commit…而且是我的」＋diff
  行數吻合，勝過全部筆跡分析。四層驗法驗不出時，答案常在**交接文件**不在檔案系統。
- 拒認的價值：作者「不憑筆跡認領」＋我方「不預設歸他」——裁定出爐＝auditor 線前任的
  押後 commit，**差一步就誤指認**。

## 🆕 08-30：第七種共用寫入面——**`MEMORY.md` 全檔重寫**（不是 git，但同一個形狀）

我為了壓縮索引做了**整份 Read → 整份 Write**。結果**淨值幾乎沒降**：同一段時間 poster 那條線
一直在追加 `:2` 與 `:11`，我壓掉的字元被它加回來。真正的風險比「白做」大一階——
**Read 與 Write 之間的窗口內別人寫進去的東西會被整段蓋掉**，而且**不會有任何錯誤**
（沒有 index、沒有 conflict、沒有 hook）。

🔑 **判準跟 git 那幾式一樣：共用的單一狀態，就不要用「讀全部→寫全部」的方式改。**
✅ 正解＝**逐條 targeted edit，而且只改自己名下那幾條**（用
`~/.claude/skills/shared/memory-lint.sh <記憶目錄>` 第 8 項挑出過長的鉤子，它印**檔名**不是行號）。
驗收看「**那幾條有沒有變短**」，不要看總量——總量是移動標靶（實測條目數整晚不動而內容全變）。
📌 機制：**索引變肥主要來自既有條目被反覆追加，不是新增條目**（實測同一條 hook 一次對話內 566→755 字元）。
⚠️ 別人名下的肥條（例如 poster 線那條 827 字元）**不要替它瘦身**——正在被寫的條目改了就是撞車。

## 🔴 08-31 第八式：**兩個人寫同一個檔時，`git commit -- <path>` 不提供任何保護**

前面幾式講的是「pathspec 保護你不被別人的檔汙染」。**它保護的是「不同檔案」**——
四個 session 同時寫 `doc/KNOWN-ISSUES.md` 時，那個機制什麼都做不到。
實例：A 寫入四段、兩分鐘內下 commit，**整批已被 B 的 commit 帶走**，A 的 `git commit`
回 **rc 1「no changes added to commit」**；更早一次是雙向交叉，**兩邊都回 rc 0，完全無聲**。
🔑 **沒有掉資料，壞掉的只有歸屬**——所以它不會以任何形式報錯，只會讓 `git log` 說謊。

🔴 **我先裁的「編輯完立刻 commit」是必要條件、不是充分條件**——被實作打臉：
**窗口是「第一次 Edit 到 commit」的整段時間**，四個寫者時**兩分鐘也輸得掉**。
✅ 真正關窗的做法＝**編輯與 commit 放進同一道命令**（腳本改檔 → 緊接著
`git commit -- <path>`），把窗壓到次秒級。實測這樣做就沒有交叉。
✅ 而且 commit 之後要**驗自己的改動在自己的 commit 裡**（`git show <sha> -- <path>`）——
歸屬交叉是靜悄悄的，rc 不會告訴你。

📌 這一式與第三式（pathspec 提交的是工作樹、會蓋掉自己 staged 的刪除）同源：
**`git commit -- <path>` 的語意是「拿這條路徑現在的樣子」，而「現在」是所有人共用的。**

## 🔴 08-31 第九式：**目錄不算「明確路徑」**

`CLAUDE.md` 寫的是 `git commit -m "..." -- <paths>`，而有人傳了一個**目錄**當 pathspec
（`-- $C`）⇒ 把另一條線在該目錄下**未提交的修改**整包掃進自己的 commit。
**沒有掉資料，但那份工作被一個完全不描述它的 commit message 帶走了。**
⇒ **pathspec 要列到檔案**。目錄 pathspec 的語意是「這個目錄現在的全部樣子」，
在共用 worktree 裡等同於 `git add -A` 的局部版。
✅ 事後處置也對：**那顆 commit 已經不是 tip 就不要改寫歷史**——在活著的共用 worktree 上
改寫比原錯誤更糟；正解＝在後續 commit 裡明文記錄歸屬，並通知被掃到的那條線。

---

## 🆕 2026-08-31 第八式：**目錄 pathspec 在多寫者 worktree 裡等同局部 `git add -A`**

`CLAUDE.md` 要求 `git commit -- <paths>`，但**目錄不算「明確路徑」**。
`git commit -- <dir>` 的語意是「這個目錄**現在的全部樣子**」——四個寫者共用一棵樹時，
它會把別人**未提交的修改**一起帶走。

**實例（08-31）**：E 輪那條線以目錄 pathspec commit，把我在
`B-nslab-build/arm_binary_assert.sh` 的未提交修改掃進 `fe1f1ea`。
**工作沒掉，但被一個完全不描述它的 commit message 帶走了。**

- **處置＝不回退**：那顆已非 tip，且我還在同一支檔案上工作 ⇒
  **在活著的共用 worktree 上改寫歷史比原錯誤更糟**。歸屬另行明文記錄（`646afc6`）。
- 🔑 **對讀者的後果**：**下次引用自己那份改動時不要去 `git log` 找它**——
  `%an` 與 commit message 都會指錯人（歸屬看檔案譜系不是 commit，本檔開頭那條的再一例）。
- ⇒ **規矩收緊：列到檔案，不要列目錄。**

### 同日的鏡像收穫：**「讀到了」與「被允許讀」不可收斂成同一個輸出**

我在 `arm_binary_assert.sh` 讀 `/proc/<pid>/exe` 時，一律走 sudo 會掩蓋這個差別；
而目標若以 root 執行，非特權讀**回空**——**沒有 fallback 時它長得跟「讀不到」一模一樣**，
會中止一個完全正常的 cell。改法＝**先直接讀、再 sudo，並把 `read_via=direct|sudo|none`
帶進判決行**。另一條線採納了同一改法。
🔑 這與同日的 `snaps`「讀不到印成沒有」是**同一個形狀**：
**兩種不同原因產生同一個輸出**——而它一旦成立，讀到的人會做出完全合理但完全錯誤的下一步。

### 🔴 第八式（08-31）：**兩個並發寫者各自取「下一個號碼」，兩邊都自洽，只有併起來才看得見**

共用的佔用帳（`NSLAB-USAGE-RULES.md` §2.2）用 `H-1`…`H-n` 編列。開機手冊線與我
**在同一分鐘各自登記**，兩筆**都編成 `H-15`**。

🔑 **這與同一份文件裡 R8a 的 `VM_DIR`／`SSH_PORT` 撞號是同一個形狀**：
**兩個獨立的預設值（各自數到「下一個空號」），而沒有任何一層會報錯。**
差別只在媒介——那次是磁碟路徑與 port，這次是文件裡的列號。
⇒ **只要「下一個」是各自算出來的，它就是一個預設值，就會撞。**

**修法（R1a）**：**登記時不必帶號碼**，寫「誰／做什麼／何時」；**號碼由正本落表時配**。
🔑 **刻意不要求登記者先讀正本再取號**——那會把「開跑前登記」變成一次往返，
而那條規則的價值就在它便宜到沒有藉口不做。**把成本留在收斂點（正本）那一邊，
不要攤給每個寫者**，否則你是用「大家更小心」去換「規則更少被遵守」。

⚠️ 反面也要記：**撞號當下兩邊都沒錯**，各自的紀錄都完整且自洽。
⇒ **不要去找「誰編錯了」**——沒有人編錯，是配置機制不存在。
（同 [[failures-that-report-success]]：找不到犯錯的人，通常代表缺的是機制不是紀律。）

### 🔴 第九式（08-31）：**別人讀得到你的未提交修改，並可能據以決策**

mainDev 要在共用的規定檔裡加一列，先 `git diff` 看了一眼，發現**我有兩列還沒提交**
⇒ 它**沒有動手**，改成「請正本代落表」，理由是 `git commit -- <path>` 會把我
未寫完的東西一起帶進一個不描述它們的 commit（＝本檔第一式）。**處置完全正確。**

但底下那層更值得記：**它的排程判斷（誰在跑、要不要現在開跑）有一部分是從我的
working tree 讀來的**，而我幾分鐘後就 commit 了 ⇒ **它手上的前提當場過期。**

🔑 **一份草稿沒有時戳、沒有作者、也沒有「它會留下來」的承諾。**
`git log` 有的那三樣，working tree 一樣都沒有。

⇒ 兩個方向都要記：
1. **不要拿別人的 working tree 當決策依據**——它隨時會被改寫、丟掉或整段換掉。
2. **知道別人讀得到你的草稿** ⇒ 半成品不要停在會被誤讀的狀態太久；
   長時間的編輯要嘛頻繁小 commit，要嘛在檔頭放一行「編輯中」。

✅ **它做對的那一件小事**：明講「**這是從 uncommitted diff 讀到的，不是已提交版本**」。
**那一句就是全部的差別**——它把一個看起來像事實的東西標成了一個有保存期限的觀測。
