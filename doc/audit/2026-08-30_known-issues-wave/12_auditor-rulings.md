# Auditor 窗內裁決與窗後驗收佇列（2026-08-30 21:07 起；08-31 晨續）

## 24. 🔴 push 急停與定性：poster 祖先在本地主線上（08-31 12:2x）

- **事件**：依 CLAUDE.md 新規（diff 暴漲先查）對 push 範圍掃描 ⇒ `20cd80b..HEAD` 含**完整投稿包**
  （abstract/figs/REVIEW 全套、38 物件）。急停成功——Adam 尚未執行我稍早給的 `lab:main` push。
- **定性（git 證據、非記憶）**：`9c8c0e6`（poster 首 commit）**是 09c9b03 的祖先** ⇒ 昨晚推上
  **私有** lab repo 的線本來就帶這段歷史——「轉私有到過審、re-publicize 需重裁（history
  rewrite vs accept）」的既裁狀態，**不是新洩漏**。lab `main`（`20cd80b`，08-28）＝乾淨系。
  本地 rescue 線經 `bd3463e`（我的 ledger merge，root 1208d22）連回同一祖先——untrack 清 tip
  不清歷史，一如帳上那課。
- **auditor miss #8**：兩個 session 的「NOTHING PUSHED (freeze)」我讀成過期凍結、未查凍結
  理由就規劃並下發 push 指令；攔下它的是 Adam 一小時前口述的新規則。判準：**看到跨 session
  一致的保守預設，先找它的理由，不是先找解除它的理由。**
- **audit-raw 掃描＝0** poster 物件（`1aefade..d62ff34`）⇒ audit-raw push 安全，可逕行。
- kernel 主線 push ⇒ 單題表單交 Adam：A 推新 ref（私有備份、main 保持乾淨系錨點）／
  B 直接推 main（repo 已私有、但 main 從此帶 poster 祖先、未來重寫面擴大）／C 先重放乾淨線。

## 23. live 配方收官＋最終狀態翻牌（08-31 12:0x）

- **live recipes：9 PASS／1 INCONCLUSIVE／1 SKIPPED**。INCONCLUSIVE＝A-1 arm3（量測時交換機
  是關的，I1/I5 是關於開著的交換機的命題——誠實的零鑑別力宣告），排入 F-5 新輪重跑；
  SKIPPED＝A-2 §5.3，真因＝**iptables 不在 NOPASSWD sudoers**（sudoers 清單只有
  ndtwin-lab/ovs-vsctl/ifconfig/mnexec/ndtwin-p4-power＋限定 dev 的 tc），非我派工單猜的
  P4-mode 理由；解法二選一交 Adam（加一行限定 sudoers vs 操作者手跑）。
- **三個配方缺陷更正入 11_ §5**（:8081→:8000、`switch_ip`→`ip`、`pgrep -c simple_switch_grpc`
  的 15 字元截斷儀器＝恆 0 恆過）；agent 首輪 arm2 誤判自抓自正（3 秒取樣太早，隔離重跑
  3.046s PASS）；「兩個讀數打架」正確歸因（inline 掃描數到自己的 cmdline，腳本檔版不受影響）。
- **狀態翻牌**：A-4e／A-5／B-2c → 🟢 RESOLVED（修法＋變異閘＋live 全鏈）；A-1 留非 RESOLVED
  （arm3 綠前不改，依包自訂條款）；§G 新條目＝**pidfile-lost-but-alive**（TE 殭屍 20h32m 🔴、
  三個 ndt 介面全盲、`stop` 回 rc0 假成功——修票待開）＋TE-App `UnboundLocalError` 跨 repo 票。
  > 🔴 **就地更正（08-31 加註，上面那行是裁決當下的原文，不改）**：**`20h32m` 已撤回**。
  > 08-31 刪除 `app_te.log` 前做了有界證據包，實測**檔案本身跨 20h38m39s、崩潰迴圈跨
  > 20h07m02s**，兩者都不是 20h32m，且 repo 裡找不到任何 raw 支撐這個數字。
  > 引用請改用 `doc/audit/2026-08-31_live-recipes/app_te_log_evidence.txt`。
  > 同一輪另外兩項更正：迴圈**不是從頭就有**（前面 31m37s 全乾淨）；那隻孤兒**沒裝成任何流表
  > 規則**（123,420 條 ERROR 全是 `:8000 connection refused`）。「殭屍」「100 MB」則已確認。
- raw 18 檔＋TE excerpt＋drive_ovs.log 落 **audit-raw `d62ff34`**。量測 binary md5 `5f2e701e…`
  （跨 15b213c 不變、strings 驗 bundle-2 字串——每步都指認了 binary）。
- 待 Adam：①A-2 §5.3 sudoers vs 手跑；②`app_te.log` 100MB 刪否（excerpt 已存證）；
  ③F-5 新輪 PREREG（Adam 已裁開輪）我落稿後送閱。

## 22. live 批次收官＝六裁（08-31 11:2x）

**全綠交付**：T-11 力紅力綠雙向鑑別（pre-T-11 binary 幻影 t=0.005s 現／t=1.274s 消；T-11 binary 25s 全程不現）；A-7 **P5 6/6**（紅色條款未觸發＝南向對壞 port 誠實回報失敗）；M15 殺（淘汰算術閉合 261−256=5）；contract **51/51** 含新 `recording` 斷言雙向驗；`route_flow(None)`＝接受、priority 常數 0（帶 700 亦 0）；lab 收乾淨（handoff 在、claim 釋出）。證據 8 檔在 `doc/audit/2026-08-31_live-acceptance-batch/`。量測 binary md5 `8322b6c7…`（含 PendingEntryFilter）、力紅臂 pre-T-11 `a40e04ce`，換裝雙向複驗。

六裁：
1. `spec.py` +10/−4 **收**，入 kernel commit 佇列。
2. **T-11 主張收窄＝不開新票**：7.4s「已確認但仍 request-shape」窗＝昨晚已劃給 FINDING-07 的殘留（§14 裁三），現在有量測值；merge 時把數字與收窄措辭寫進 T-11 票誠實節＋ledger 條目（「力紅單看會支持過強主張」句入票）。
3. **A-7 FINDINGS P6 更正**：`dispatched` 只數經兩個 dispatch API 的請求、開機編程隱形（暖 fabric 40 條已編程而 dispatched=0、之後精確跟 POST 數）——預註冊逃生條款（「恰等於 POST 數⇒先找其他寫入者」）照設計發動、找到「無」。以更正 commit 落（51b3e84 模式）。
4. **P5 的 `controller_status` 非零斷言零鑑別力**（proxy 失敗也回 HTTP 200＋error body、常數滿足）：斷言改寫併入同一更正 commit；「proxy error＝HTTP 200」註記進 T-15 素材。
5. **契約套件 `--allow-mutations` 汙染 tracked topology**（鍵字母序重寫＝666 行 no-op diff）：開票修（序列化保序或寫 temp 副本），週四後。
6. **`ndt release --help` 直接 release**：併入既有 task_78209672（release 拒絕未知參數＝已裁可逕行的安全修正），優先級上調；agent 自陳的順序違規（release 先於 handoff）無損害、已補寫，收。
另收兩個觀察：live proxy 對 5-tuple 一律 `Failed to add route`（單元層綠而 live 拒＝T-15 表達力題再添一筆，未過度歸因）；ENOSPC 下 `cp` 產 0-byte 備份**回報成功**＋截斷偽裝成契約 FAIL[400]（靠內容驗證不靠 rc 才沒立假缺陷）。

**合併階段開工條件**：只剩 behavior 變異 agent。屆時序：kernel 側 commit（mainDev 四遺產＋spec.py＋批次證據＋rulings 檔＋雜項歸檔）→ ledger 先落 → KNOWN-ISSUES 手動疊（B-3/F-13/B-2c/mn-c 收窄/T-11 收窄/B-2c-b/鏡像票/§5 計數 8→7）→ seatbelt/behavior 分支併 → A-5/A-6 live 配方（lab 已 free）→ 主樹全套綠 → push。

## 21. seatbelt 變異閘收案＋兩起 ENOSPC＋復原指令地雷（08-31 11:0x）

- **seatbelt M-1〜M-7＝7/7 全殺、零存活零 CRASH-RED**，預測全中或更嚴（M-1 恰 2 紅＝gate 真接進 `route_flow` 非只測 helper；M-6 四條 depth-1 舊檢查全綠＝向後相容實證；M-5 綠＝accept-path 對照在位）。基線 9 輪全綠、worktree 收尾逐字同跑前。正本 `10b_seatbelt-mutation-run.md`。文件更正待併：§5 shell 基準 8→7（delta +6 非 +5）；M-7 hedge 收斂綠。
- 🔴 **兩份變異派工單裡 auditor 寫的復原步驟是地雷**（miss #7）：bundle 檔案未 staged ⇒ `git checkout -- <file>`＝整包還原成 1208d22 而非撤銷變異。seatbelt agent 自行識破改用校驗和備份；behavior agent 已急件更正（其每輪 46/46 綠基線本身＝fix 未被吃的證據，另令 `diff --stat` 對帳）。§6 step 5 已改（含更正註記）。教訓＝**復原指令的語意取決於基準住在哪一層（工作樹／index／HEAD），寫復原步驟前先問**。
- 🔴 **ENOSPC 二連**：root 100%（低點 6.6MB）。傷：`cp` 截斷 topology_manager.py（agent pristine sha 全復原）＋batch 的 tracked topology JSON 截 0（已復原、auditor 驗 `git diff` 空＝byte 級一致；全 repo 零位元組 tracked 檔僅兩個本就為空的 placeholder）。處置：刪兩座殭屍 build 樹（2.7G）＋`scratch/lab/logs/viz*.log`（08-18、實測不再增長）**gzip 壓縮**（可逆、非刪除、agent 依規不動由 auditor 裁）＝現 5.6G；`~/.config` 19G 待 Adam。harness 硬化配方（512MB preflight＋temp+fsync+replace＋復原後逐檔 sha）入 10b、已轉兩 agent。
- batch agent：ENOSPC 中斷→自行復原 topology→決定拆場→stream stall；已帶新條件（5.6G、claim 至 11:43）喚醒續跑。

## 20. 早晨執行佇列——兩包單元面收案（08-31 10:2x）

- **behavior 包單元面 ✅**：worktree build 綠；指定 filter **46/46**；新增測試數對帳 **+14**（17−12／12−7／18−14＝5+5+4，與報告一致；auditor 第一把 diff-grep 數到 4 是自己的 regex bug——`TEST_F?` 匹配不到裸 `TEST(`，逐檔重數為準）。M1–M13 變異執行 agent 已派（六步紀律：磁碟斷言→重建→rc-first 判定→SKIP 獨立→restore 後重建→基線綠）。
- **seatbelt 包單元面 ✅**：py_compile ✓、unsupported_match **49/49**、flowentry_endpoints **8/8**、A-5 shell **13/13**、C++ **635/635 兩儀（ctest＋direct）一致**。l1 首跑 13 problem groups＝**新鮮 worktree 缺 gitignored `p4_proxy/venv`**（清一色 ModuleNotFoundError）；symlink 主樹 venv 重跑 **13→1**；殘 1＝`test_sflow_stats_endpoint`（import fastapi、PY_KERNEL guard 只驗 networkx+ryu、ryu-env 無 fastapi）——**主樹同指令同炸、`59e7298`（08-27 Ticket P）即有＝既有 infra 缺口、非本分支**，修復 chip 已開（task_402e7fc1）。M-1..M-7 變異 agent 已派；A-5/A-6 live 配方排 batch agent 釋出 lab 後。
- 誠實記錄：auditor 本晨又踩兩個已入冊的坑（pipeline-rc：`python -c … | tail` 後讀 rc；零鑑別力 grep：「usage error」通過訊息被掃成失敗候選）——均在下結論前被正確讀數取代，無後果。
- 在飛：live 批次 agent（斷線一次已喚醒，claim batch-acceptance）、兩個變異 agent。

---

[Co-developed with claude code -- Adam]

寫的人：8/29 auditor。量測窗（開機手冊的有流量輪，claim 至 01:24）生效中：本檔只落盤、不 commit。
兩個修復包已完成回報：行為包（agent a2c2a660，branch `fix-demo-behavior`）、安全帶包（agent aaf83a75，branch `fix-demo-seatbelt`），皆基於 `1208d22`、零 commit 零 build。

## 1. 行為包三題的裁決

1. **modify_strict 存在檢查＝阻斷閘。** 窗後驗收第一步就跑它的 curl（其報告內附）；404 ⇒ COMMIT-PLAN 的 commit 2 不合。
2. **缺 priority 改 400？——裁：不改。** 唯一已知呼叫端 Energy-Saving-App 丟棄回應，改了會讓它的 modify 靜默停擺；維持現狀，語意風險由文件記載。
3. **412 decide-first？——裁：不做。** 理由收下（非同步 dispatcher 讓 412 到不了呼叫端；先讀表要嘛踩 A-2 已證的卡死路徑、要嘛讀 8 秒舊快取）。窗後驗收時複讀其證據檔 §2.3 確認論證成立。

## 2. 安全帶包四題的裁決

1. **A-5 depth-2 留不留？——裁：留。** 2 行、磁碟有界、向下相容，理由成立。
2. **B-2c-b（5-tuple 數值欄位仍 500）——裁：登記後辦。** 窗後併入 ledger 成新條目；本輪不動編碼寬度表。
3. **其餘 OPEN 條目對 HEAD 複驗——裁：待 ledger agent（a0170b16）回報覆蓋範圍後決定要不要補派**；原則上週四展示前收完。今晚抽 3 中 2 過期是實質訊號。
4. **跨 repo caller——✅ auditor 已親查收案**，證據見 §3。

## 3. 跨 repo caller 檢查（auditor 親查，21:00–21:04）

- 兩 app **只打 kernel 北向 :8000 `/ndt/`**，不直接碰 proxy(:8081) 或 Ryu(:8080)：ESA 的 12 個端點全在 `src/app/http.cpp`；TE 只有一個 `ndt_url`（`Traffic-engineering-App.py:32`）。
- **兩 repo 零個 4xx/5xx 字面比較**（.py 與 .cpp 各掃一輪；依「零命中＝沒人用我的詞」規矩再實讀呼叫點封詞彙缺口）：
  - ESA `install/modify/delete_flow_entry` 把 code log 完**原樣 return**（`src/app/http.cpp` install 一帶），無任何 500 分支。
  - TE 全部 `requests…​.json()` 包 `try/except`，從頭到尾不讀 `status_code`。
- ⇒ proxy 端 500→400 的改動對兩個 app **不可見**；且 flow 路徑非同步、北向呼叫端拿的是 200 queued（FINDING-03 機制），雙重隔離。
- 誠實邊界（未查）：兩 app 的 log 之外有沒有營運腳本去 parse 那個 code；repo 之外的部署副本。

## 4. 合併衝突預告（給窗後執行者）

三條線都改 `doc/KNOWN-ISSUES.md`：ledger（a0170b16）、seatbelt、behavior。合併順序：**ledger 先落**，兩個 fix 分支的 KNOWN-ISSUES hunk **以 ledger 版為基準手動疊**，不要讓 git 自動 merge 那個檔。

## 5. 窗後驗收佇列（依序）

0. 讀 `ndt status` 確認 `measuring` 清空、claim 釋放（不要用 pgrep 判斷窗）。
1. 安全帶包：`py_compile`（今晚完全沒跑過、最便宜）→ 兩包測試 → 其證據檔 §5 M-1（先證 gate 真的接進三個動詞）→ M-2〜M-7 變異。
2. 行為包：modify_strict curl 閘 → `cmake` build `test_routing_strategy` → 指定 filter 測試 → 其證據檔 §4 M1–M13 變異＋1 個必須保綠的對照 → §5 三個 live 配方。
3. 依各自 COMMIT-PLAN 用 `git commit -- <paths>` 逐 commit；不動 hooksPath（post-commit 已是 .disabled，無 agy，但仍窗後才 commit）。
4. 合併照 §4 順序；KNOWN-ISSUES 手動疊。
5. **代 reviewer 線補 commit**（21:26 通報、22:0x 範圍更新、誰先到誰做）：`doc/2026-08-29_bmv2-performance-study-figs/make_survey_figs.py`＋**fig5–fig8 八個渲出檔（PNG＋PDF）**（量測窗內落盤未 commit）——commit 前先讀 903 模板 D 節的 A2b 註記照做。已兩度對帳其對我 E-delta-1 表的頁碼同步（v0.3 五格、v0.4 三格＋警告 4 的 fig8 補句）＝乾淨，紅線未動。

## 6. 21:07 新派兩單（Adam 離開前口令「把剩下的工作發派下去」）

- **doc-fix wave**（website repo，寫檔不 commit）：N-3/N-5/N-6/N-8/S-1/lock 頁 §27-29 mirror/T-13 十二路由＋PEP668·cd 兩家族複核。驗收＝每 ID 三態結案（FIXED/ALREADY-FIXED/BLOCKED）、§4.1 一個 byte 不變、全站無 venue 字樣、T-13 只寫 T-6 驗過的行為、無 commit。
- **雜項檔案＋分支歸屬**（kernel repo 唯讀取證）：repo root 五個 untracked 檔＋`rescue/literature-search-round1` 分支。驗收＝逐項歸屬證據＋處置建議，零刪除零改動。

## 7. ledger 包三題的裁決（21:15 補）

1. **F-5「不修」要不要重裁？——裁：掛起待 TR-3。** 它指出的證據缺口（177 樣本是 10 秒格，FINDING-03 的窗只有 2–3 秒 ⇒「0 次自然發作」幾乎無證據力）正是已預註冊的 TR-3 要補的重量（有流量、t=0、結構指紋）。今晚有流量輪回報後拿 TR-3 數據重裁；**不用「再多取樣」路線**（同格點加 n 不解決刻度問題）。
2. **兩套 F-n 撞號重編號——裁：週四後。** 動全部引用點屬深水區工程，與 bundle ③ 同波排程；本週靠消歧塊護住。
3. **檔內 AI 標記——裁：照 agent 做法。** KNOWN-ISSUES.md 既有慣例是檔內 0 處，維持不加，標記寫在 commit message。
4. 合併補充：**seatbelt 與 ledger 都動了 B-2c 條目**（ledger 補行號＋重驗、seatbelt 擴寫觸發面與 in-repo 生產者）⇒ 合併時該條目以 ledger 版為底、疊 seatbelt 的觸發面段。
5. **sha 對照表（auditor merge-base＋patch-id 雙驗，21:12）**：`dff87f9`→`4ee086f`、`db02d45`→`87d272f`、`e29424e`→`a7ab17d`。舊 sha 仍被 archive tag 掛著、`git log -1` 照樣 resolve ⇒ 驗「在不在這條線上」一律用 `git merge-base --is-ancestor`。窗後 commit 訊息與文件一律引右邊那顆。

## 8. 雜項取證收卷（21:36 補）——五檔一分支的處置分工

取證 agent 唯讀收案（HEAD 不動、零改動），逐項證據在其報告；處置分兩類：

| 項 | 身分（信心） | 建議處置 | 執行歸屬 |
|---|---|---|---|
| `diff.txt` | Adam 手動 `git show 739c072 > diff.txt` 審閱導出（很可能；「非任何 Claude session 產出」有逐字稿級硬證據） | 可刪——byte-identical 於已推上兩 remote 的 commit，零資訊損失 | **等 Adam 一句話**（刪除類不代辦） |
| `out.json`／`out2.json` | flow-count 臂中途的 loopback iperf3 手動 smoke（很可能；時序夾在 n1_a 與 n2_a 之間） | 移入 `doc/audit/2026-08-28_flow-count-capacity/raw/`（該目錄本有 smoke_* 慣例） | 窗後我做（歸檔類） |
| `patch.py` | plot_deck guard 的 **force-green 工具**（lane 歸屬很可能；作者只到猜測——/compact 上限）；**現為啞彈**：目標字串 `assert tracked, (` 在現行樹只剩它自己，新 guard 已改成 ls-files＋內容雜湊 | 可刪；要保 force-green 能力就對**新** guard 重寫＋附對帳、放 audit 目錄 | **等 Adam**；🔴 教訓入檔：force-green 工具用完要留書面對帳、放 audit 目錄不留 root |
| `test_wait.sh` | `run_flowcount_arm.sh:111` 裸 `wait` 安全性的**唯一物證**（**確定**：20:06 inline 版真卡死的 ps 快照＋20:07 落檔＋20:18 臂開跑，先驗證再開跑） | **保留**：移入 `doc/audit/2026-08-28_flow-count-capacity/`；並在 `run_flowcount_arm.sh:111` 加一行註解（安全理由＝`run_rep` 跑在命令替換子 shell、其 job table 看不到 SAMPLER） | 窗後我做；那是 performance 線的儀器，commit 訊息載明代辦與出處 |
| 分支 `rescue/literature-search-round1` | `e3bfac1` 的髒前身（**確定**：唯一獨有 commit `b8f7540` 三個內容檔 blob 逐一同於主線，只多兩個 0-byte 探針檔；不在任何 remote） | 刪（可先 `git tag archive/literature-search-round1-dirty b8f7540` 保險） | **等 Adam**（分支刪除） |

- 附帶目擊：`doc/audit/2026-08-30_live-traffic-round/FINDING-06_dispatch-is-a-10.7s-cycle-not-a-queue.md` 在取證中途出現＝開機手冊輪的在途產出；收四部報告時一併驗，現在不讀不評。
- 取證自報的四條鑑別力保留（照引）：檔名 grep 無鑑別力（旁觀 session 全命中）；自我污染已手動排除；mtime 窗選不可靠（session resume 會更新 mtime）；**/compact 吃回合 ⇒「內容不在逐字稿」是「找不到作者」的證據、不是「Claude 沒做過」的證據**。

## 12. mainDev A-7 交付＋FINDING-06 機制更正（22:2x）

- **A-7 交付收到**：`DispatchOutcomeLog` seam（header-only）＋`GET /ndt/get_flow_dispatch_status`＋9+3 測試＋M1–M15＋C1 保綠對照，零 build 零 commit 窗內完成；正本 `doc/audit/2026-08-30_a7-dispatch-visibility/`。四題全裁：detail 字串改指新端點＝可；三設計決定（ring 只存失敗／`recent_failures_evicted` 公開／成功走 record() 不存、不建無讀者索引）＝全可。
- 🔴 **FINDING-06 機制更正成立**（auditor fresh 複驗四點：FlowDispatcher 無時鐘、`openflowTablesUpdateWorker` 10s 迴圈、`HttpSession.cpp:1119-1120` 同步快取寫、**tr3_simultaneity.py:56/:88 讀的就是快取端點**）⇒ 10.70 s＝儀器上游的快取刷新週期；嚴重度翻轉「延遲編程→延遲可見」。已急件轉開機手冊（南向一條規則的便宜檢查建議；其 lane 其裁）。FINDING-06 的觀察數據全保、標題與三個衍生宣稱不成立。
- mainDev 下一件＝**T-11-A**（設計輸入：programmed 訊號走南向確認不走快取刷新；幻影注入點 :1119-1120 解凍）；⑥順手；③④其後；⑤窗後。
- 窗後驗收佇列追加 A-7 包：P1 build → **`Ran 20`（勘誤：初版誤植 12＝只數新增；filter 連帶 8 顆既有 ControllerTest；binary 在 `./build/bin/`）** → M1–M14（M13＝M12 重複；M11 關鍵；M5/M6 race、M10/M14 未跑照其標註）→ C1/C2 → live §5；**P5 紅色條款**（failed 仍 0 ⇒ 南向謊報成功＝另開票）。

## 19. T-14 定稿＋mainDev 最終 wrap（23:5x）

- **T-14 重寫完成**（未 commit）：第一段＝依權限層分岔（user 層 `:=` override＝feature；root 層寫死＝安全邊界，兩者相容）。設計空間 (a)/(b) 之上補 **(c) 大聲拒絕**（比對 invoking cwd 的 `git rev-parse --show-toplevel` vs 寫死樹，不同即拒——把 FINDING-01 從無聲撕裂變成第一個指令就報錯；與 (a) 正交）。**裁：採其推薦＝(c) 先做、(a) 隨後**，(a) gate 在三個未證上：呼叫端盤點／**worktree 測試是否仍為需求**（若否，(c) 即結案）／sudoers 規則精確度（若比「指向這支腳本」寬，權限分析重做）。(c) 的實作＋重裝需 Adam sudo，排週四後與 bundle ③ 同波。
- 兩句入帳的觀察：①「**被尊重的 override 正是造成撕裂的東西**——完全忽略會一致地錯且顯眼；五處尊重、第六處不尊重＝一半 A 樹一半 B 樹且通過自己所有檢查」（(a) 的 allowlist 陷阱同理：判準要落在**被執行的檔**不是樹根——root 目錄下的 adam 可寫 .py 照樣以 root 跑）；②方法論：「**這張票差點被寫反，救場的是結構不是聰明——填 blocked 票去問，而不是下一個有自信的否定**」。
- **mainDev session 收工**。總帳：4 commit（A-7×3＋T-11-A，未 push）＋4 份未 commit 文件（§39／T-15／T-14／違規存證）；自抓三個儀器缺陷（全靠 §0 預註冊）；一次違規（已存證更正）；推翻 auditor 一輸入、救掉一錯票、撤一選項。未結三球歸窗後：`route_flow(None)`（批次讀取優先項）、modify/delete 鏡像票（已裁開）、T-14 呼叫端盤點＋sudoers 讀。

## 18. T-14 前提釘案＋mainDev 收工安排（23:4x）

- **T-14 前提成立、位置釘死**（auditor fresh grep）：拒絕在 root wrapper **檔案** `tools/test_workflow/ndtwin-lab`（裝於 `/usr/local/sbin`、root-owned、兩側 12843 bytes）——`:51` KERNEL_DIR 寫死、`:26-44` 大寫註解載明理由（root 執行 `$KERNEL_DIR/...py`、env override＝「安全處無效、有效處提權」）與 FINDING-01 實測代價（fabric 128/model 4 全綠）、**`:46` 起修法方向已草**（tree 當位置參數等）。`components.env:16` 的 `:=` 接受 override＝user 層功能、與 root 層拒絕相容——**T-14 第一段＝「依權限層分岔：user 層 feature、root 層 danger」**。mainDev 三讀法皆非；其拒寫假前提票＝正確行為。
- **mainDev context 將滿＝收工安排**：T-14 草稿補完＋最終 wrap 後停機。**00:24 後批次改由 auditor 派新執行者**（claim → T-11 力紅力綠 live → A-7 P5/P6 → contract_test 帶新 `recording` 斷言重跑；入口＝`doc/audit/2026-08-30_a7-dispatch-visibility/` FINDINGS §5／COMMIT-PLAN／T-11 票）。mainDev 未 commit 遺產（⑥ §39、T-15、T-14、WINDOW-VIOLATION_evidence）待窗開落盤——併入 auditor 窗後 commit 佇列。
- 觸發器：開機手冊 TR-5 釋出訊息（≈00:24）→ auditor 醒 → 派批次 agent＋自跑兩修復包 build/變異。

## 17. FINDING-07 機制收斂＋我的 T-15 輸入 (a) 被推翻（23:2x）

- **輸入 (a)（「exact-match 表編不進 priority」）被 mainDev 的 .p4 實讀推翻**：轉發路徑上無 exact 表——`flow_5tuple`＝**ternary**（priority 有意義且必填、刻意排在 LPM 前）、`ipv4_lpm`＝**LPM**（priority 這一欄不存在、次序＝prefix length）、`l2_forward`＝exact 但 key 是 MAC。我的 miss 另入審查帳本（對 Adam 有標「推測待驗」、對 mainDev 的派工把限定詞掉了——hedge 要跟著主張過河）。
- **嚴重度分岔 auditor 親讀收斂**（`api_routes.py:209-214` docstring＋`p4_client.py:696-717`）：dst-only match → `ipv4_lpm`、docstring 明寫 priority「still **ignored** for the destination-only path」；多欄 match → `flow_5tuple`、priority 必填。FINDING-07 的 17 條全 dst-only ⇒ **無封包被轉錯**、LPM 次序確定。**FINDING-07 降級＝API 契約／文件缺陷**（收下 priority、路由到用不到它的表、回 success 不告知）——`recording`/`status` 同族**第三例**。
- 下放三件：①開機手冊比照 FINDING-06 修 FINDING-07 機制節與嚴重度（觀察數據全保；證據鏈已附）；②T-15 用收斂後的最強形式（「會 honour priority 的 ternary 表就在旁邊，只差更豐富的 match」）；③新登記：5-tuple match **不帶** priority 時 `route_flow(..., None)` 的行為（P4Runtime ternary priority 必填）——B-2c-b 同族待查。
- **Option 3 撤案核可**（dst-only 本來就在 LPM；原選項照 API 字彙寫、不是照 pipeline——「先讀 .p4」一次閱讀的直接戰果）。

## 16. 違規案機制更正＋儀器票撤案＋T-15 草稿收（23:1x）

- **儀器缺陷票不開（假說被否證）**：`WINDOW-VIOLATION_evidence.md` 存證顯示「claim none」讀數取於 22:10 之前（輸出 `code` 行＝`1e0665b`），當時 live-traffic 輪已於 21:53 釋出、handoff 明寫 the lab is free——**`ndt status` 報的是實話**。機制更正＝**點取樣當租約**（動手當下未重讀；⓪ 寫的是「動手前」＝每次，不是每 session 一次）。§14 敘述已標更正。條件式流程的價值在此案成立：先存證、後開票——證據把票救掉了。
- T-11 票誠實節劃界核可：**污染的是別人的資料、不是本票的功能性結論**（變異判決不依賴機器安靜）——明寫此界防止日後有人為污染重跑本來有效的結果。
- **T-15 草稿收**＋兩裁：①「**先讀 `.p4`**」核准且提前到**現在**做（純讀、窗內合法）——最便宜、卡著四選項中兩個、並解 FINDING-07 懸案（priority 是被某層丟掉還是 pipeline 根本沒有——修法完全不同）；②Option 0 與 §1.2 裁決的相撞立為 T-15 設計原則：**500→400 免費**（呼叫端本就不讀 status code、行為無差）、**200→400 是破壞性變更**（須先有 capabilities 端點＋呼叫端遷移路徑才可做）。
- mainDev 次件＝④T-14 草稿（純寫）；窗前停手承諾已明列（不起 fabric、不 build、不 commit，00:24 親讀 claim 後才動）。

## 15. ⑥ api doc §39 收卷＋兩裁（23:0x）

- **⑥ 交付**（未 commit、窗規遵守）：`doc/2026-01-02_ndt_api.md` §39 兩 shape→三 shape、每個補 `recording` 欄；**被原文漏掉的那個 shape 正是本 lab 唯一會拿到的**（MININET 下 `HistoricalDataManager::start()` 直接 return、兩套 stack 都是 MININET）；明寫「`recording` 才是可判斷欄、`status` 不是」；`at line 1661` 改錨點字串引用。
- 裁一：**KNOWN-ISSUES:444（B-3）過期**——ledger 分支今晚已重寫 B-3（揭露已修/本體未修/兩分支同 200）；mainDev 的增量（指認 `recording` 為判別欄）於**三方合併時**對 ledger 版查核、缺則疊上。合併時另按 §9.1 疊 F-13 措辭、§8 疊 B-2c。
- 裁二：**contract_test 對 `recording` 零斷言（spec.py:787/794 連 optional 都沒有）＝「路由有登記、形狀零斷言」第二實例**——裁做：`required={"recording": Bool()}`，**排窗後**、對活 kernel 驗過才算數，併入 mainDev 窗開後的 claimed session 批次（fabric 一次起：T-11 力紅力綠 → A-7 P5/P6 → contract_test 含新斷言；跑前對開機手冊四部報告確認 TR-4 是否已蓋）。claim note 需寫「functional acceptance only; concurrent builds tolerated」以便 auditor 同窗跑兩修復包 build＋變異。
- mainDev 下一件＝③T-15 設計票（純寫），兩個今晚輸入：FINDING-07（收了編不進去的 priority）＝capabilities 活例；`recording`/`status` 對＝能力揭露含部署模式行為差。之後 ④T-14。

## 14. T-11-A 交付＋窗內違規事件（22:45）

- **T-11-A 交付**：`91e7743`（token provenance＋`getOpenFlowTables()` 過濾＋`stripUnprogrammedEntries` 自由函式可獨立測）；T1–T5 全紅、C1 綠（28 顆）、全套 655/655、kernel 建得起來。單元層把力紅力綠都斷言了（含「濾網 keyed on provenance 不是 keyed on 長相」的互偽測試）。**live 雙向未跑＝本票最大缺口**（其自報），排 00:24 釋出後與 A-7 P5/P6 併一個 claimed session 補。
- 🔴 **窗內違規**：mainDev 以一次取於 22:10 前的真讀數（存證輸出 `code=1e0665b` 為時戳；當時 lab 真自由）充當後續 20 分鐘的許可證，動手當下未重讀 claim，於 TR-5 窗內做 build＋變異重跑＋655 套件＋commit。〔🔄 23:1x 更正：本段初版記「誤讀 bmv2=0 為 claim none」不確；機制正本＝`doc/audit/2026-08-30_a7-dispatch-visibility/WINDOW-VIOLATION_evidence.md`，見 §16〕時間界：`91e7743`＝**22:33:17**（A-7 三顆 22:18:13–26＝21:53–22:24 合法空檔、不涉）；load1 ~22:29→0.63、22:34:57→0.94；**重 CPU 壓在 TR-5 的 P4 臂（22:24:55–22:31）上**。已通報開機手冊（P4 臂重跑 vs 申報共變量、它裁——claim 尚餘 110 分鐘夠重跑 4-host 臂）；mainDev 凍結至釋出；其「claim none」讀數的**原始指令＋輸出令存證**——若存在一條在 claim 生效時回報無 claim 的路徑＝「錯誤被吞掉變成有自信的錯答案」族儀器缺陷、開票。
- 裁決三條：①live 驗收排釋出後（自己 claim、note 寫明、一個 session 併 T-11 力紅力綠＋A-7 P5/P6、release 寫 handoff）；②modify/delete 鏡像**開新票不併入**（自癒上界＝下次 poll ≤10.7 s、嚴重度低於幽靈、週四後）；③殘留不誠實（已確認列在 poll 前仍帶請求 priority 與呼叫端字彙）＝FINDING-07 地盤，邊界確認。
- T5 SKIP 課（錨點縮排 12 vs 8 ⇒ 變異沒跑 ⇒ SKIP）：「把 SKIP 併進通過數＝變異表開始高估自己」入記憶；其 harness 把 SKIP 印成獨立狀態才活捉它。

## 13. 窗二＝TR-5 能量輪＋驗收單勘誤＋讀取式審查排程（22:4x）

- **新量測窗**：claim `tr5-energy` 至 **00:24:54**（開機手冊；**Adam 22:24 授權 power-off 動詞**；p4 4-host → ovs4，重做 15:30/15:53 被 agy 污染的兩輪；exclusive CPU、load1 0.63 holding）。**窗內全 repo 禁 commit、禁 compile、禁重活**——§5 佇列的 build／變異／commit 段順延 00:24 後；**讀取式審查不受限，排本窗內做**。
- **時間軸更正**：輪一 21:53 提前收（claim 原至 01:24）；21:53–22:24 是合法空檔，mainDev 在空檔內完成 A-7 build＋全套驗收＋commit（`2016d4c`/`636f9ab`/`30eb6d7`，未推）：P1/P2/P4 過、M1–M12 紅、C1 綠、全套 647/647。auditor 複審改讀取式（diff＋證據對帳），M11 執行式重放排 00:24 後。
- **有流量輪已 commit**：`68c3209`（輪本體）＋`1e0665b`（共變量事後申報）＋`51b3e84`（FINDING-06 更正——開機手冊已接受，commit 訊息自署「it was my instrument's clock」）。四部報告待收；RESULTS.md／FINDING-07（priority 歸零）讀取式審查本窗內做。
- **行為包阻斷閘靜態解除**：裝機 ryu-env `ofctl_rest.py:147`（`POST /stats/flowentry/modify_strict` 路由表）＋`:428`（`OFPFC_MODIFY_STRICT` 映射）都存在——2026-07-29 文件的路由清單不全，不是 Ryu 缺路由。live curl 確認排 00:24 後自有 fabric 時；behavior commit 2 解封。seatbelt `py_compile` ✅ 三檔全過。
- **mainDev harness 兩缺陷（自抓自修、已入記憶）**：①M1 段錯誤被判 GREEN——判定只讀 gtest summary 文字、不讀 rc（-11），「最嚴重的結果翻成最無害的結論」；已改 rc 優先＋`Ran N` 斷言。②還原 source 未重建——測的是 M11 的舊 binary 而 `git diff` 乾淨；`mutation-harness-must-guard-its-baseline` 第三次復發（三作者三套 harness 各踩一次）⇒ 共用機器可判 harness 優先級上調。
- **T-11-A 設計綠燈**：token provenance（不比內容——FINDING-07 priority 歸零＋兩側字彙不同）、過濾在 `getOpenFlowTables()`（端點／LLMAgent:275／IntentTranslator:1069 三消費者共享）、保守預設（predicate 斷線⇒隱藏帶 token 列、8192 有界、老化讀作未確認——失效方向永遠是少報不是幽靈）、install-only＋modify/delete 鏡像登記不默默併入。

## 11. T-11 裁決（21:58，Adam 本人）＋非週四工作移交

**T-11 裁：A＝表列只報已編程**（B state 欄、C 只記文件皆不採）。已轉發 8/29 mainDev 實作，規格要點：①過濾依據＝provenance（A-7 的 confirmed 訊號），**不准按指紋形狀過濾**（4 欄／無 counters 是偵測輔助不是判準）；②驗收雙向＝force-red（變異重曝隊列、t=0 配方再抓到幽靈）＋force-green（合法規則確認後必須出現——順帶回答 FINDING-03「合法規則回音」未定案題）；③時序在 A-7 之後、共用 outcome 管線。

同時依 Adam 21:55 指令「非週四工作全交 8/29 mainDev」，移交單已發（該 session 未開機、訊息排隊）：①A-7（第一優先，Adam 令「先把前置做完」）→②T-11-A→③T-15 API 多樣性設計票→④T-14→⑤protobuf bump→⑥api doc §39→⑦A-4c/A-4d 開票。週四相關（兩包驗收、ledger 合併、doc-fix render＋commit、有流量輪收案、903 deck）留 auditor 線。

## 10. doc-fix wave 收卷（21:45 補）——三題裁決＋窗後審查要點

9 個 ID 全數三態結案（7 FIXED、cd 家族 1 ALREADY-FIXED＋3 FIXED、PEP668 4 FIXED）；website tree 7 檔 +1075/−292 未 commit，`COMMIT-PLAN-docfix-0830.md` 在該 repo root（8 顆 commit、順序限制 4→5、1→7）。§4.1 diff 零 byte、全站 venue 掃描零命中——兩條紅線機械驗過。

1. **「PEP668／cd 已修」前提＝假，agent 擴大範圍補齊 7 處——裁：收。** 它的三路查證（git log --all --grep／content/ 全 grep／working tree 乾淨）勝過我派工單引的 compact 摘要。修復本來就該做、且隔離在 commit 6/7 可整顆丟。**摘要說「已完成」≠磁碟上完成**——我的失誤，另記帳。
2. **N-8 改檔名（Recoder→Recorder）＋aliases——裁：收全套。** 檔名即 URL slug，光改 title 是半修；aliases 從既有 public/ build 逐字抄而非推導，方法對。窗後 render 時實測 aliases 生效。
3. **鎖頁鏡像兩處刻意偏離——裁：①收（repo 內部路徑對網站讀者無意義）；②有條件收**：兩條 desk-check 補充（ttl 預設 5s／鎖全域）內容已回源碼複驗，但**頁面上必須帶 DESK CHECK 級標記**——窗後審 diff 時查，沒帶就補。

窗後審查要點（接 §5 佇列）：
- render（hugo，看 exit code 不看 --quiet 輸出）＋它自報的四個肉眼風險點：Simulation Platform §3.2 blockquote 內表格、blockquote 內 code fence、兩頁 aliases front matter、API 頁 `§` 字元 anchor。
- 12 條路由是回 `HttpSession.cpp` dispatcher 重新導出的（非抄 T-6 清單）——審時抽 3 條對 dispatcher 複核。
- 依 COMMIT-PLAN 順序 commit（新檔要 `git add -- <path>` 再 `git commit -- <paths>`，pathspec 限定不整鍋 add）。
- 🆕 kernel 側新工單：`doc/2026-01-02_ndt_api.md` §39 過期（success body 缺 `recording` 欄、實為三種 shape 非兩種，正本 `HttpSession.cpp:1803-1818`）——小修，窗後一併。

## 9. C/E/G sweep 收卷（21:20 補）

sweep（唯讀驗證 agent）結論與 ledger 版一致或更精確；交叉驗證通過（B-x 行漂移 `:2290-2329`、§G bullet 3「`sudo` since `0b6db9e`」兩個獨立 agent 同結論）。合併時把兩處措辭疊進 ledger 版：

1. **F-13 契約那半**（ledger 原標 ⚠️ 未重驗，sweep 已驗）：「6 個端點零契約覆蓋」改成「**路由有登記**（`tools/contract_test/components.py:36-41`，六端點都在、mapped POST）、**回應形狀零斷言**（components.py 以外 grep `group_entry` 零命中）」。sweep 明標範圍：generic reachability sweep 可能仍涵蓋 liveness，未追。
2. **§G bullet 1 收窄**：`mn -c` 的機制已實讀（`/usr/lib/python3/dist-packages/mininet/clean.py:29/:37/:66`，`pkill -9 -f`）——但「一定殺掉呼叫 shell」比碼支持的強；改寫成「**argv 對上 pattern 才殺**（`sudo mn -c` 的 shell 不匹配 `"sudo mnexec"`；帶 topo 腳本名的 driver 會匹配 killprocs）」。
3. sweep 引用的行號基於 ledger worktree 未 commit 的 1212 行版＝將要 commit 的版本，合併後即為準。
4. 順帶（上游、不動）：mininet clean.py:55-56 字串少空格 ⇒ `nox_core`/`ovs-openflowd` 兩個名字其實從沒被殺過。僅記錄。
