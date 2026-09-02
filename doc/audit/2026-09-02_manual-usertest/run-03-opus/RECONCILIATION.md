# run-03（opus）— 對帳

## 1. 帳本 R12 預期 vs 實際

五條預期逐字抄自 `doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md` 的
A-7 / run-03 子列（09-02 20:17 登記，**派之前寫**）。

| # | 帳本上跑之前寫的（逐字） | 實際 | 裁定 |
|---|---|---|---|
| ① | 「opus 不會提早停（九條規則下一段做到底）、總時 ≥4 h、無需干預」 | **未測到底**。tester 在 **22:08:53** 被**我們自己這條 session 的用量上限**（HTTP 429）中止，總時 **94 分鐘**，不是 ≥4 h。但「不會提早停」這半有**正向的部分證據**：它死在句子中間（遺言＝「Let me confirm both directions and work around it.」），手上正在追一條新線索，`JOURNAL.md` 沒有 `## SUMMARY`、沒有任何收尾動作——**沒有任何自行停止的跡象**。「無需干預」這半 **成立**：全程 **零次 orchestrator 干預**（run-02 是五次）。 | **未測（因外部中止）**；子句「無需干預」**中** |
| ② | 「它像 sonnet 一樣在 ~15 min 內自己補 `ndtwin-lab` symlink，再被 `ndt up ovs` 的 ④ 擋住、轉手動三終端」 | **實質中、時序全錯**。它確實自己補了（`logs/41_workaround.log`：`sudo install -m 0755 … /usr/local/sbin/ndtwin-lab`），確實被 ④ 擋住（`logs/45_helper.log`／`46_sock.log`），確實回頭用三終端。但：**(a) 不是 ~15 min，是開機後 48 分鐘**（21:41）；**(b) 順序是反的**——它 **21:16 就先用手動三終端把整套跑通了**，`ndt up ovs` 是 **21:38** 才第一次碰。它把「手冊說仍是 reference 的那條路」當主線，把 shortcut 當受測物，而不是反過來。 | **部分中**（結論中、路徑與時間不中） |
| ③ | 「§6 從早就背景跑，4/6 GB 約 2 h 完（7544 s 的鄰近值）」 | **中，而且很準**。20:53:05 進 `P4` tmux 背景開跑，全程沒擋住別的工作。`logs/06a_p4.log` 末段：`Total time : 7640 sec`——與預測的 7544 s 差 **+1.3%**。`SCRIPT_EXIT=0`、`simple_switch_grpc` 1.15.6-1c8c9a4f、`p4c-bm2-ss` 1.2.5.17、`mn` 維持 2.3.0、venv `home=/usr/bin`——**手冊自己的四項驗收全過**。 | **中**（唯一但書：**23:01:22 才跑完，tester 已死 53 分鐘，沒人看到**） |
| ④ | 「BUGS ≥ 11：run-01 的 9 個已知會重現（同一份 docs），另有 3–6 個新的落在 sonnet 的 NOT-TRIED 的 29 條裡（Web GUI／NSR／Visualizer／apps）」 | **中，而且超出**。BUGS **22 條**（≥11 ✓）。run-01 的發現重現約 **8 條**（#1 #4 #5 #12 #13 #21 #22＋#2/#3 各半）≈ 預測的 9 ✓。新的**不是 3–6 個，是 14 個** ✗（往上偏）。落點也只對一半：**NSR ✓（#4 #5 #17 #18 #19 #20 共 6 條）、apps／Simulation Platform ✓（#2 #8）**，但 **Web GUI 與 Visualizer 完全沒碰到**（被中止時還沒走到）。 | **中**（數量下界成立、重現數對；新缺陷數低估，落點半對） |
| ⑤ | 「報告的每個數字對得上 log——若對不上，那是模板九條無效的證據，不是 opus 的」 | **中**。38 條宣稱裡 **36 條逐字對得上檔案**，1 條 `CONFIRMED-but-mis-stated`（#10 的 release 那一列引錯檔），1 條 `UNVERIFIABLE`（`ndt up ovs` 的畫面，它自己的腳本沒把 pane 存檔）。**0 條 UNSUPPORTED、0 條 CONTRADICTED。** | **中** |

## 2. 已知 vs 新（22 條的歸類）

依 `doc/KNOWN-ISSUES.md` 逐條核對（id 與逐字條文見 `VERIFICATION.md` 註 ⑦）。

| 類別 | 條數 | 是哪幾條 |
|---|---|---|
| **ALREADY-KNOWN（有 id、且已修）** | **3** | #9→**A-4e**、#10→**B-2d**、#13→**F-1** |
| **PARTIALLY-NEW** | **3** | #1（G-7 只涵蓋 `/home/adam` 預設）、#21（主體 G-8＋G-7）、#22（主體 G-7；假成功那層是 G-6 的形狀但不在 G-6 定義域） |
| **NEW** | **14** | #2 #3 #4 #5 #6 #7 #8 #11 #12 #14 #16 #17 #18 #20 |
| 非缺陷（正面紀錄） | 2 | #15（14 組照文件且效果經確認）、#19（NSR 本體可用） |

**外加一條 tester 沒來得及立案、由本線補上並在停機前證實成因的新缺陷**：
**一個文件化的改名 API 呼叫會永久毒化 NTG 的啟動路徑，而錯誤訊息指控錯對象。**

`/ndt/modify_device_name` 把 h1 改成 `HstA`（持久化、跨重啟）
→ NTG `Utilis/distance_seperate.py:37` 對每個節點做 `int(node['device_name'][1:])`
→ `int("stA")` 丟 `ValueError`
→ `:42-43` 的 `except Exception: return [-1]` **吞掉成因**
→ `:58-59` 翻成 `Failed to get hosts from NDTwin server.`
→ `network_traffic_generator.py:397-401` 的 `while True … sleep(2)` **無上限重試**（74 分鐘，停機時仍在跑）。

本線停機前用一條唯讀 `GET /ndt/get_graph_data` 證實（`tester-files/evidence/NTG-loop-cause.txt`）：
kernel **答得出 138 個節點、一個都沒少**，其中**恰好一個** device_name 的 `[1:]` 不是純數字——`HstA`。
⇒ **kernel 沒問題，訊息在說謊**：它說 server 拿不到 hosts，server 明明回得好好的。
`bcf98f5..tip` 沒有任何 commit 碰過這段。
⇒ **新缺陷實際 15 條**，而這一條是其中**唯一一個「照文件操作就會自己踩到、且錯誤訊息會把你導向錯的子系統」**的。

### 🔴 這一輪最重要的發現不是任何單一 bug

#9／#10／#13 三條**在 trunk 都已經修好了**，卻在這台機器上完整重現。原因不是回歸：

| KNOWN-ISSUES | 修法 commit | 日期 | 在使用者 clone 到的快照 `20cd80b`（2026-08-28）裡？ |
|---|---|---|---|
| A-4e | `c46c51eb` | 08-31 11:28 | ❌ |
| B-2d | `4ee086f8` | 08-30 18:50 | ❌ |
| F-1 | `65c5cdb1` | 09-02 14:16 | ❌ |

**安裝手冊叫使用者 clone 的公開快照（`936f8c6`＝「Snapshot … at `20cd80b`」）仍在出貨修法前的碼。**
最尖銳的是 #10：API 頁把 B-2d 的修法寫成**帶日期的既成事實**——
「Until 2026-08-30 … **All three now return `400` and acquire nothing.**」——而讀者拿得到的 build 裡沒有它。
⇒ **這是「公開快照的更新節奏」的問題，不是程式問題**，而它會讓每一輪 naive-user 測試都重複撞上同一批已修缺陷。

### NTG 的「catch-22」：真的，但已修，只是 snapshot 太舊

tester 的遺言追的那條線**成立**，而且底下是兩個缺陷：
Installation Manual 建的 `python3 -m venv ~/ntg-env` 少 `--system-site-packages`；
User Manual 又叫你跑 `~/miniconda3/envs/ntg-env/bin/python`——**一個 guest 上不存在的 conda 路徑**。
兩本手冊對同一個環境給了同名、不同工具、不同位置的路徑。
**但兩個都是 run-01 的 BUG-008／BUG-007，而且都已修**：`062d8eb`（20:48:30）與 `df614ce`（20:50:18）。
`bcf98f5` 是 09-02 11:26:28——比修法早九小時。
**時序值得單獨記**：兩個修法 20:48／20:50 落地，而 run-03 的 VM **20:30:35** 就已開機、tester **20:34** 派出
⇒ **修法是在這一輪跑到一半時才進 repo 的**，guest 那份 docs 不會、也不該變。

## 3. 三輪對照：opus 走到了哪裡，而這是在說手冊還是在說模型

| | run-01 sonnet | run-02 haiku | **run-03 opus** |
|---|---|---|---|
| 干預次數 | 0 | **5** | **0** |
| 走到哪 | §1–§6 走完；User Manual＋工具 | §1–5；§6 只 clone；工具頁全沒做 | §1–§5＋§6.1 完成；User Manual OVS 全程＋41 端點＋NSR＋Sim Platform |
| BUGS | 11 | 實質 0 | **22**（新 15） |
| 宣稱可信度 | 大致可信（BUG-010 混了兩個 log） | **前三條主要宣稱全 REFUTED** | **38 條中 36 條逐字對得上；0 UNSUPPORTED、0 CONTRADICTED** |
| 驗收方式 | 多數看效果 | 看狀態碼、迴圈當使用階段 | **每條都查效果**（ovs-ofctl dump、bridge 存不存在、ping 通不通、檔案內容、磁碟 JSON） |

**opus 比另外兩輪多摸到的**：41 個 REST 端點逐一驗**效果**（run-01／02 都沒打過
`modify_flow_entry`／鎖 API）、NSR 的四種失敗形狀、Simulation Platform 的 binary 譜系（兩個 sha256）、
「做兩次」（第二次 bring-up 驗持久化）、以及**把 #22 的假成功隔離到 helper 自己那一層**。

**這在說手冊，不是在說模型**，兩點：
1. **手冊本身經得起走。** 三輪都走得完 §1–§5，opus 更把 §6.1 也跑完（7640 s，四項驗收全過）。
   opus 記下的 friction 分數是 0–3，`0 smooth` 佔多數。**手冊的主幹是好的。**
2. **手冊的破口集中在「捷徑」與「工具頁」，不在主幹。** 22 條裡真正 🔴 的六條
   （#9 #10 #14 #17 #21 #22）沒有一條在安裝主線上：兩條是 API 語意、一條是 relay 誠實度、
   一條是 NSR 的推薦啟動路徑、兩條是 `ndt` 這個「the short way」。
   **手冊自己說三終端「still the reference」——而三輪裡三終端次次成功、捷徑次次失敗。**
   ⇒ 要修的是「把捷徑寫成推薦」這個編排，以及捷徑背後那支寫死 `/home/adam` 的 helper。
3. 反過來，run-02 證明的是**模型**的事（haiku 的雜訊來自它自己的執行模型）。
   run-03 沒有這類雜訊 ⇒ **模板九條（run-02 之後加的）在 opus 上有效**，⑤ 成立就是它的讀數。

## 4. Orchestrator 干預

**零次。** 這一輪本線沒有停過它、沒有糾正過它、沒有給過提示。
唯一的 orchestrator 端事件是**非自願的**：

| 時刻（CST） | 事件 |
|---|---|
| 22:08:53 | 我們這條 Claude session 撞到用量上限（HTTP 429，`session limit · resets 11pm Asia/Taipei`），tester agent 隨之中止 |
| 23:01:22 | （無人看管）§6.1 build 自己跑完，`SCRIPT_EXIT=0` |
| 23:03–23:05 | 本線唯讀 harvest（216 檔） |
| 23:1x | `stop`、帳本 release |

**這不是專案缺陷，也不是 tester 失敗。** 記錄在案是因為它是 ① 那條預期無法裁定的唯一原因。

## 5. 收案決定

**提前收案。** 理由：tester 在 22:08 被我們自己 session 的用量上限中止，
已完成 **~95 分鐘的 use-and-break**（20:34 派出 → 22:08 中止，扣掉 §1–5 安裝約 20 分鐘）。
沒有 tester 的最終報告，**不替它補寫**；`JOURNAL.md` 是倖存的記錄。
**VM `stop`、磁碟映像保留**（見帳本 release note），理由：
§6.1 已完成的那個狀態（兩個 binary、`p4setup.bash`、七棵樹）是 A-8 之後可能要接的分岔點，
而且 NTG 的無限迴圈假說需要一條 `curl :8000/ndt/get_graph_data` 才能證實——那要這台機器還在。

## 6. 帶進 run-04（fable）與 A-8

**給 run-04 的模板修正（三條，都是這一輪的取證教訓）：**
1. 🔴 **凡是要引用的 tmux 畫面，`capture-pane` 一律 `> 檔案`。**
   run-03 唯一的取證缺口就是 `39b_poll.sh` 把 `ndt up ovs` 的畫面 `tail -45` 印到自己的 stdout
   ⇒ agent 一死就沒了（結論靠旁證才站住）。
2. **`capture-pane` 不要 `tail -n`。** `49_ntg.log` 的 pane 是 25 行全空，因為 session 開 `-y 50`
   而腳本取 `tail -25`——**失敗訊息在上半部被系統性切掉**。要嘛全取，要嘛 `-S -3000`。
3. **docs snapshot 要在派工當下重新確認。** run-03 用的 `bcf98f5`（11:26）在開機時已經 9 小時舊，
   而修它的兩個 commit 在**開機後 18 分鐘**才落地。run-04 若還要與前三輪可比就沿用；
   若目的是驗修法，就明寫改用哪個 commit——**不能默認「拿到的是最新的」**。
4. 🔴 **`.gitignore` 會靜默吃掉採證，這件事已經發生過一次而沒有人發現。**
   repo 根的 `.gitignore:21` 有 `.test_run/`（針對活的工作目錄），但它不分路徑，
   連 `doc/audit/` 底下的**封存副本**一起吃。**run-02 的 `pull6.sh` 確實把
   `Desktop/NDTwin-Kernel/.test_run/logs` 打包拉回來了，而
   `git ls-files …run-02-haiku/ | grep test_run` 一個都沒有**
   ⇒ 那一輪的 `kernel.log`／`ryu.log` 從來沒進過版控。
   run-03 改名為 `test_run-harvested/` 解掉（見該目錄的 `WHY-RENAMED.txt`）。
   **run-04 拉完檔案後要跑一次「磁碟上有幾個檔 vs `git status -uall` 看得到幾個」的對帳**，
   差額不為零就要查 `git check-ignore -v`。

**run-04 該優先打的（run-03 沒走到）：** Web GUI、Traffic Visualizer、`ndt apps`、
以及 §6.2 之後的 P4 路徑（§6.1 這台已經備好了）。

**要一格就結掉的兩個懸案：**
- **#17／#18 一起結**：`display_on_console: false` 時 NSR 的 `logs/` 到底會不會出現。
  run-03 只跑得成前景（`true`）並自己標了但書；**run-01 的 G12 標 WORKS，兩輪結論相反**，
  必須有一格判決。
- ~~NTG 迴圈的成因~~ — **已在停機前結掉**（`tester-files/evidence/NTG-loop-cause.txt`）：
  138 個節點裡恰好 `HstA` 一個過不了 `int(...[1:])`，`ValueError` 逐字重現。
  剩下的不是查證而是**裁決**：`device_name` 的合法值域要在改名 API 那端約束，還是在 NTG 那端容錯，
  以及 NTG 的 `except Exception` ＋ 無上限重試要怎麼修。

**給 A-8（prep5，只做 §1–5 不碰 §6）的兩點：**
- A-8 的 R12 預期 ② 寫「`~/miniconda3/envs/ntg-env` 在 prep5 不存在，手冊 Terminal 2 原句會失敗」——
  **run-03 已經在一台 §1–§6.1 都做完的機器上證實了同一件事**（該 conda env 從頭到尾不存在，
  guest 只有 `ryu-env`）。⇒ A-8 這一項不必再當未知數，改成**確認 prep5 上的表現是否一致**即可。
- 但 A-8 要注意：`df614ce`（20:50）已經把 User Manual 那兩處 conda 路徑改掉了。
  A-8 若用**新**的 docs，②的原句就不存在了；若要與 run-03 可比，就得明寫沿用 `bcf98f5`。

**給 KNOWN-ISSUES 的三件事（本線只陳述後果，裁決留給 auditor）：**
1. A-4e／B-2d／F-1 各補一行**出貨口徑**：修法在 trunk，公開快照停在 `20cd80b`（08-28）。
2. **G-6 的定義域是一個裁決**：它逐字只涵蓋 `energy-start`／`sim-start`，而
   `ovs-topo-start`／`topo-start`／`ovs-topo-4host` 是**位元組上同一個構造**
   （`tmux new-session -d` ＋ 無條件 `echo`）且正在 `ndt up` 的關鍵路徑上。
   擴或不擴都要明寫，否則下一輪會再撞一次。
3. **G-8 只點名 `ndt up`，但 `ndt down` 是第二個 fail-open 入口**（`ndt:1073-1084` 兩步都不讀 rc）。

[Co-developed with claude code -- Adam]
