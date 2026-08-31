---
name: review-round-2026-08-21
description: "審查帳本（08-21 起，append-only，已跨三任 auditor 到 08-28）。**入口＝檔尾 §13**（08-28 全日，`8/27 auditor` 停工前寫）：八個結論各自的強度分級、我的七個錯、四個 session 在途狀態、六條矛盾／未收乾淨的前提，以及 §13-9 ＝ Adam 的兩個裁示。§12 以前是歷史節。原始首輪內容（8/21 mainDev v2 全日審查：數字全過、8 條文字更正落地、B2①②收案）仍在檔頭。"
metadata: 
  node_type: memory
  type: project
  originSessionId: 80663333-dc9c-42bd-9c05-499d63b60be1
  modified: 2026-08-31T06:17:42.971Z
---

8/21 審查 session（我）＋ Muse Spark 三輪（pass1 contributor 150 步／pass2 contributor
120 步／pass3 非 contributor 150 步，報告在 repo `scratch/review-2026-08-21/muse_pass{1,2,3}.md`）
對 mainDev v2 的 34+5 個 commit 逐一驗證。**結論：所有量測數字通過；缺陷全在文字層，
8 條更正當晚全數被 mainDev 採納提交**（32ff719 / 3a74ceb / f05da99）。

關鍵數字（已驗證，可引用）：偵測 44.86s=87%、guard 3.9×、beacon sweep 4 格 FP=0、
**after-fix：OVS 128 台 51.75→16.4s（貼上 P4 16.59）、4 台 15.7→15.0 不動（預先寫下的
不對稱＝機制指紋）、縮放懲罰 3.30×→1.10×**（六個 outage 數字 muse 從 raw ping log
重算 ±0.01 吻合）。B2③＝「fast build 零新增失敗、殘紅逐條歸因」，**不是字面的「L0–L4
全過」**——stock 對照 ladder 未跑、5 個 P4 telemetry 缺口與 L4 的 get_path_switch_count
4 diffs 仍開著；上台措辭要用報告的誠實版。

八條更正裡最要緊的形狀：①「exactly 3.00s」散文與自己的 raw 矛盾**且已擴散進 827 模板
C1 口頭要點**（128-host 實為 ~6.4s＝3.0 去抖＋慢索引 walk，反而是慢索引的獨立證據）；
② L1 第五個紅歸因錯誤（真兇=slim_client_json 印「passed 12, failed 0」而 parser 要
「Ran N」、自出生就 NO TESTS RAN；p4_client 的 opt-in skip 有不計數分支）；③ baseline
regression check 讀 `links` 而 key 是 `edges`＝vacuous（結論僥倖為真，我直接數 banked
capture 288/0/128 全 IP 證實）。

**Why:** 審查方法論可複用：留 1-2 個自己先找到的缺陷不餵給 agent 當校準點（pass1 的
校準點它獨立找到=可信；pass3 兩個 DEFECT 被我推翻=「量測當下 HEAD」的 A2b 慣例它不懂、
「2,400 samples」其實是 0.25s×600s 的 twin 讀值不是 sFlow 樣本——單位要先問）。
🆕 08-24 mainDev 回敬的對稱律：**推翻過 agent 的發現＝它精度<1 ⇒ 接受集要跟拒絕集
一樣抽驗**。本輪兩條未驗接受（C-6、trap-EXIT）事後補驗 2/2 為真——運氣不是紀律；
更正單發出前先驗完接受集。

## 下一輪驗收（compact 後接續用）

**🆕 08-24 Adam 追加：驗收通過後我要跑一輪 full stack run test**（照 2026-08-18
live-full-stack-round 先例、兩平面，重點蓋 settle 40s／fast bmv2 預設／backoff／5-tuple
端到端；owner=review-0824）。

**✅ 08-24 full-stack round 也完成**（`71ba08b`）：O-1 收斂缺陷**結案**＝semaphore 死鎖環
frame 級證實（細節在 [[punt-window-host-learning]] 08-24 深夜節；6/10、永久態、兩環邊已砍
`d1d973d`+`72fbae6`）；phase 2 OVS 全綠（404 序列 10×200、northbound 裝刪改轉發無黑洞、
failover 52s/復原 5s）；phase 3 P4 綠（升預設後首 boot、binary /proc 驗證、5-tuple 回歸
exit 0；sFlow 讀值 inconclusive——我的 curl|wc 把錯誤與空壓成同 0，待帶 code 重查）。
**deck 裁決線已觸發：OVS 那頁不放開機秒數**。修復輪（async flag ×10 對照）歸 mainDev，
lab 已釋出。

**🏁 08-24 晚：審查職已移交「8/24 auditer」（`local_709bd0fe-…0334`）**——Adam 指示：
auditer↔mainDev（`local_36af44ed-…6057`）直連對話、平行審查員=**deepseek v4 pro＋muse
spark 1.2 contributor**（範圍規則不變：contributor 只碰公開的 repo/audit）、待審清單＝
召喚輪／async 翻預設／deck 產檔／sFlow 重查／O-2 O-3／三件等 Adam 的裁決。原 review
session 退休。交接全文在其收件匣（含方法論五條血淚追加）。

**🟢 08-24 晚：boot-ring 驗證輪驗收＝PASS（v3 的輪次乾淨）**：四臂數字我＋muse 雙重從 raw
重算全吻合；「未驗證≠被證偽」措辭正確；boot 8=suspend 坐實（journalctl＋mtime＋stack.sh
成功判斷先於 deadline）；12/20 反轉假說獨立重現且加鋒（12=entered 2[截斷]+stateChange 10、
成功 20=10+10——duplicate 從未存在於資料裡）；它抓我 boot_rate.sh 三缺陷全實、已修
（拒跑守衛+owner 參數化，commit 見 git log）；muse 校準 2/2（分解＋「零 warning 只有 1/30
log 可驗」都自己找到）；⚠️ muse 摘要謊報自己的輸出路徑（實際落對位）＝**agent 對自己副作用
的自述也要對磁碟驗**。N-1~N-3 小註已回 v3。下一步＝**刻意召喚 wedge（髒 vs 冷機器）**，
greenlet dump 仍未在真 wedge 上跑過。 更正單 7 條（repo `scratch/review-2026-08-24/corrections.md`）
已發 mainDev；結構性的只有 C-1（rerun 覆寫 raw ×3 處，最重＝loaded-fp 更正塊引的
`boot2_up.out` 已被第二輪覆寫成**成功**開機，引文與所引相反）；C-2 失敗率跨文件矛盾
（~20 次 2 失敗 vs 3/5，前者寫於第二輪前）；C-3 模板 C3 秒數未更新（工單子項未完）。
驗證法：raw 全重算（graph JSON 288/256、288/0×2、40/0）＋ muse 150 步（校準 1/1 中；
它兩條指控被我推翻：settles-for-10s＝d5f904f 顯示假影、e89fd4b 有歸檔第一遍 pkts=0）
＋ **L1 於 79cd66a live 重跑 exit 0、1514 ran+passed**（proxy 489+1 skip、拒絕路徑 31/31）。
🔴 **2026-08-24 更新：下面這批 Open 大半已結，別再照舊引用**
（`8/21 mainDev v2` session 做完 8/22 工單六項＋08-24 驗收輪；細節見 [[ndtwin-current-state]] §5-P）：
O-1 **已量成 6/10**（不是 3/5）且機制確認＝semaphore 環，**仍 open**；O-2 **已解**（環＝
IR handler 阻塞→128 buffer 被 packet-in 填滿→Switches 自己的 loop 卡在發 EventLinkAdd→
gate 的 get_all_host 無逾時等一個不會來的回覆）；O-3 log allowlist **仍紅、未動**；
O-4 404 **已重現並定性**＝開機後第一次查詢的 transient（1×404 後 9/9 200），fix-vs-allowlist
仍未裁。另：`scratch/pending/` 的 settle patch **已 apply**（`b11ae34`），該行作廢。

**Open 缺陷交 Adam**：O-1 預設開機收斂 3/5 失敗（上游牽動 52s／L4 baseline；n≈10 折進
full-stack 輪）、O-2 gate 機制未明、O-3 log allowlist 紅（雙 binary 同紅）、O-4 404 開機首查
transient（裁 fix vs allowlist）。**待 Adam 裁**：guard=0.01 升預設（mainDev 薦升、backoff 續押）、
P2-6 兩行安裝指令（在 manifest_backfill.sh 檔頭）。

**狀態**：mainDev v2 已開工（claim `fable-0822`、`doc/audit/2026-08-22_settle-gate-acceptance/`
已出現）。**它的 session id：`local_4f50031c-7e0a-4d61-8343-fa5dba5a7779`**（send_message 用）。
我的持續監看：Monitor task `bypgrq1ne`（watcher 在本 session scratchpad `watch_maindev.sh`，
盯 commit／claim／doc/audit 檔案變化；beacon_sweep.txt 那條 grep 已無用）。

**逐項驗收判準（照工單）**：
- P0-1 settle：預設值 `ndt up ovs` 後 hosts 128/128 有 ipv4、kernel 圖 288/0（重跑
  `2026-08-22_punt-window-discriminator/t6_punt_window.sh` 基線反轉）；OVS 開機重計時 n=3；
  手冊 §2＋模板 C3 秒數更新；README §1b 改寫；L4 baseline 重 bank（舊的是手動 settle=60）。
- P0-2 ladder→升預設：stock 輪 invocation 必須同 735344e（比對 run txt 開頭）；升預設
  commit 必須**同時**把 override-檔不見的靜默 fallback 改大聲（2c8486a 點名的路徑）。
- P1-3 404：半天 timebox；裁決文字要指認根因或寫明 allowlist 理由。
- P1-4 載流 FP：三 cell 鏡射 idle 研究（defaults/guard0.01/+backoff10）、knob announce 證明、
  陽性控制、決策數字＝載流誤判數；NTG 一次一個 actor。
- P2-5 5-tuple：突變先自證有效（PYTHONDONTWRITEBYTECODE=1）；live 證明=5-tuple 規則蓋過
  LPM 且轉發真的不同；拒絕路徑不得倒退（test_unsupported_match 仍綠）。
- P2-6 backfill：腳本冪等；給 Adam 的兩行=install 到 /usr/local/sbin/ndtwin-manifest-backfill
  ＋visudo NOPASSWD（照 ndtwin-lab 模式）；**密碼不經過任何 session**。
- Deck 產檔：A3 全重量；checklist 見上方 How to apply。

**「今天的方式」＝**：先自建 ground truth（讀 raw 對散文）→ muse agent task 帶校準點
（留 1-2 個已知缺陷不餵）→ 抽查 muse 的 OBSERVED 引文→ 從 raw 重算關鍵數字→ 便宜的 live
重跑→ 編號更正單發 mainDev→ 匯報 Adam。它量時序時我不跑重負載；lab 操作前 `ndt status`
查 claim；我的 owner 名照日期（review-0822…）。

**08-22 凌晨八題裁決（grill 三輪，工單已發 mainDev v2）**：settle 修復=mainDev 執行（patch
在 scratch/pending/，開機手冊 session 寫的）；manifest sudo=走窄 sudoers（腳本裝
/usr/local/sbin/ndtwin-manifest-backfill，Adam 自己 visudo）；stock 對照 ladder=8/27 前補，
**綠了就升 fast 預設＋同 commit 把靜默 fallback 改大聲**；404=半天 timebox 查根因再定；
載流 FP 輪=8/27 前擠（Adam 推翻我的緩排建議）；5-tuple=8/27 前做 proxy 側（TE repo 不動）；
**犧牲順序：5-tuple 先讓→載流輪次之→ladder 與 settle 驗收永不讓**。

**How to apply:** 8/27 產檔 checklist 已交 Adam：2,400→readings、throughput 頁帶 n≈1
與轉抄註記（`fig_throughput` 是唯一手打數字的圖，raw 已隨 scratchpad 過期）、fine print
的 epoch 句別掉、sampling PNG 重 render、B4「ovs8-64 直接可用」stale 句清掉。
mainDev v2 的實驗清單事後送達、與我的盤點**雙向零缺漏**；它自評的不確定處（beacon 5s
cell＝reconcile 非 closed）與我一致。slim_client 修後 L1 全綠（我重跑 rc=0 證實）。
⚠️ settle=10 迴歸的 patch 在 `scratch/pending/`（開機手冊 session 的）尚未 apply；
**OVS 上讀 kernel 圖的實驗過渡期要帶 `NDTWIN_RYU_SETTLE_S=60`**。相關：[[punt-window-host-learning]]、
[[check-against-prior-experiments]]。

## 08-24 深夜：auditer 接任（本 session；此後審查歸這裡）

交接自「mainDev v2 驗證與實驗審查」（其記憶寫的交接對象 id `local_709bd0fe…` 不存在於
session 清單，實際接手的是收到交接信的本 session；已向 Adam 報備防雙審。前任仍可詢問，
Adam 准）。接手核對：

- `d8c2ea4` 未推、已補推 p4 兩 remote。**歸屬更正（mainDev 抓的）：那是 mainDev 的
  collapse-raws commit、不是前任的**——前任寫「HEAD=cb7fa47 全部已推」是過時快照而非漏推。
  （同日第二例「結論對、歸屬錯」，另一例＝N-2 行號；歸屬入紀錄前要校。）
- 和解表行號開檔驗證：`:754` marker／`:763` enter-notify／`:857` state-change-notify／
  `:831` 註解，與表一致，引用安全。
- C-1~C-7 mainDev 稱全套用（`9ff705f` 存在）；抽驗 C-3＝模板 172–176 更正塊已落。
  **接受集抽驗未完**：其餘六條套用處＋模板 593 行 52s 是否帶 survivorship caveat。
- 🔴 **「髒 vs 冷」召喚設計已被 mainDev 推翻重設＝CPU contention**（機制與依據在
  [[punt-window-host-learning]] 08-24 深夜節）；**截至 20:56 已設計未開跑（raw/ 空、
  lab 無 claim）**。已約定：開跑前通知我、期間我零負載（quiet 臂怕別人的 CPU）。
- 🟢 **Adam 三裁決（08-24 晚，AskUserQuestion 皆採建議）**：guard=0.01 升預設＝裁可；
  async flag 翻預設＝裁可（**只以速度 wall 26s vs 52s 為由**）；**兩者 commit 都落在
  召喚輪之後**（勿讓 plain defaults 中途變質）；404＝**allowlist＋理由**（須含「startup
  transient；機制旁證強、未直接抓到填表中途」誠實註記），落地歸 mainDev、措辭我把關。
  **08-25 補：召喚輪 0/16 無靶 ⇒「若召出 wedge 順驗 async」條款正式劃掉（不得標已驗）；
  兩個預設 commit 的「召喚輪後」條件已成立，等 mainDev 落、我審措辭（async 只准引閒置
  26s vs 52s ×10；guard 引 FP×6＋3.9×；settle=40 載重缺陷另列、不得混入）。**
- backfill：`/usr/local/bmv2-fast/BUILD-MANIFEST` 已在（Adam 11:15 跑過）；常駐安裝兩行
  （install＋sudoers）未做＝可選，指令在 `manifest_backfill.sh` 檔頭。
- repo root 六殘檔（`test_greenlet.py`、`dummy.sh` 等）不動、已問 mainDev 歸屬。
  watcher 已接手（本 session scratchpad `watch_lab.sh`：非 summon 變化即醒；summon
  跑動中不吵、靜止 15 分才醒）。

**auditer 待辦佇列（承交接）**：① 召喚輪驗收（USR2 首演＋`:763`=2/`:857`=10 截斷簽名＋
288/288 down 判別）；② 兩個預設 commit 措辭把關；③ sFlow liveness 帶 HTTP code 重查
（要 lab 窗口）；④ O-3 log allowlist 雙 binary 同紅；⑤ 8/27 deck 產檔 checklist
（開機秒數不放）；⑥ 接受集抽驗收尾。
⑦ 殘檔歸屬（🔴 已升級「第四寫入者」案）：前任、v3、**v2 皆否認**。v2 的否認＝機器級
   四層驗證（三個 project 全 transcript：檔名首現全是 git-status 輸出、六檔內容指紋零命中、
   零 sidechain、repo 無 driver）＋當場行為證據（08-24 16:04 它的「mine only」過濾**按名
   排除四個**；test_greenlet.py 在該指令後 **67 秒**才出生）。⚠️ v2 更正我的前提：六檔
   **全在**它窗內＝「活躍窗」判準排除不了任何 session；且四層對「有 shell 但不寫 Claude
   transcript 的行為者」全盲＝否認上限是「無建立紀錄」、不是「確定不是」。🔑 **反面才是
   重點：每檔＝mainDev 某宣稱的最小複現、出現在該宣稱後幾分鐘**（23:15↔`continue 2`/ps
   邏輯、test_graph↔404 輪 JSON 形狀退化、test_greenlet↔16:03 `gr_frame` commit、
   test_out↔`timeout` 對 nonexistent cmd）＝**有人在近即時抽驗 agent 宣稱、結果零回流**。
   候選＝Adam 終端機或 ~/.gemini／Antigravity（未授權不翻）。**檔案不清（mtime＝唯一
   證據）**；🔴 **08-25 Adam 已答「不是我寫的」⇒ 升級成立**：cron／systemd timers 已查＝
   全 stock 無自訂項；剩 ~/.gemini（Antigravity）等非 Claude 工具店＝**待 Adam 授權才查**；
   檔案續留作證據。四層法＝standing technique，歸檔於 [[two-writers-one-worktree]]（結案後寫入）。
⑧ **召喚輪驗收 own-pass（08-25 上午）完成，核心全過**：16 行重數（loaded 8/8 SETTLE、
   quiet 6 CONV＋2 FAILED(XX=1)=HEALTHY-XX、環 0/16）、12 dumps sem_acquire=0 且 md5
   全異（儀器活的）、ent/stc **精確 pattern** 全 16 檔=10/10（我先前 stc=11 是自己寬鬆
   grep 的假警報）、up.ready 假陽性逐字確認（三 verify 全過＋converged after 73s 而 twin
   全盲）、probe 80/80＋12h 讀值（`0634cd7` 已補 commit）、harness 三缺陷修法在檔、smoke
   已分離。🔍 **唯一 open＝機制表 provenance**：197/93 MAC 與 3-4/2 installs 未載取法；
   我以 `install_all_pair_paths done` 數得 **2/1** 與表不符、MAC/packet-in 於 ryu.log
   零命中 ⇒ 疑為未歸檔的 live 讀值——**留作外部審查校準點，勿餵**。
   🟢 **外部輪（08-25 上午）**：muse 100 步六項全 PASS、**獨立判機制表 NOT-DERIVABLE＝
   校準命中**；50-boot 帳**它對我錯**（我漏數 verify 輪 smoke 1 boot，49→50 撤回）；其
   trailer 引文（txt:50-51「LOADED: 8 of 8 failed QUIET: 2 of 8 failed」）抽驗屬實。
   **S-1 更正單＋落地綠燈（含四條措辭邊界）已發 mainDev**（它當時正在做 404 allowlist）。
   ⚠️ deepseek v4 pro 端點 connection-reset ×3、兩輪都沒跑成＝infra 缺席，擇時重試；
   本輪雙重覆核＝own-pass＋muse。
   🟢 **S-1 已結（`dd2ea62`，08-25 09:57）**：mainDev 重導出 provenance **推翻自己的核心
   標籤**——197/93＝log 行數（distinct MAC 兩臂皆 128）、installs 完成數 **2/1**（我的
   量法被確認「same observation」）；存活＝載重下 install ×2、walk 慢 ~5×、壞的專屬 IPv4
   association；REPORT 已帶取數指令更正（保留錯版＋更正塊）。**404 closeout 措辭審查
   PASS**：走 contract spec 非 log allowlist（404 路徑零 log、allowlist 條目會永久
   stale——理由成立）、expect_status=[200,404]＋三要素誠實註記＋trade-off 明寫（永久空
   map 也會過）＋**兩臂驗收**（before FAIL／after PASS、兩臂都真 404、verdict 只隨變更翻）
   ＋mutation 自證＋spec 還原。post-9/03 修法已預留（503 readiness 區分）。
   🟢 **第四寫入者結案＝agy post-commit hook**（詳 [[two-writers-one-worktree]] 檔尾）；
   `.git/agy-reviews/` **450 份**平行審查（0447–0450＝昨晚至今早四 commit）待 Adam 裁
   對帳範圍；hook 的 read-only-無沙箱缺口待裁修法。
   🟢 **agy 流首次對帳（0450→dd2ea62）三方一小時收斂**：其 MEDIUM（after 臂 `ndt up`
   非零僅記錄）屬實→mainDev `e1b5529` 以 **CLEAN／DEGRADED-usable／BROKEN-VOID 分類制**
   回應（不硬 abort 的理由成立：良性 transient 硬 abort 會丟好臂；措辭審查 PASS）；
   殘餘真空由 auditer 封印 run 關閉＝**乾淨 boot（全綠零 XX）gpsc t+0 404→t+30 200→
   t+90 200**（`scratch/review-2026-08-25/seal_404_transient.{sh,txt}`，owner=audit-0824、
   lab 已還）——「startup transient 自行轉 200」從推論變實測。其 HIGH＝已裁 trade-off
   （獨立讀者無提示達同一異議，mainDev 已記錄）。**P1-3 全鏈密封**。
⑨ **agy 近期對帳（0443–0449；Adam 裁近期＋續納入迴圈；六探針檔已清、hook 唯讀化草稿
   ＝`scratch/review-2026-08-25/post-commit.readonly` 待 Adam cp）**：R-1 真＝
   `intelligent_router` 四 notify 站點對 HTTP 4xx/5xx 盲（0445；requests 不為 4xx/5xx
   拋例外→「Failed to notify」只數網路層失敗；**N-2 結論不倒**＝marker 行＋frame dump
   承載，但表格要註明口徑）；R-2 真＝`boot_summon.sh:206-207` `grep -c||echo 0` 重犯
   同 commit 訊息記載的 0\n0（潛在、本輪 16 log 全 10 未觸發）；R-3 真＝probe teardown
   不在 trap＋`ndt down` 不驗＋`PROBE_HOLD=0` 為真（0449）；R-4＝greenlet_dump_smoke
   四 MED（含缺 `_parked>0` 斷言＝裝飾性測試形）；R-5 記錄＝boot_rate 兩 HIGH 潛在、
   **raw 16 行全 288e＝零資料影響**、harness 已退役；R-6 半推翻＝0447「:763/:857 註解假」
   ——呼叫在 :757/:851、**log 行在 :763/:857**，錨的本來就是 log 行。R-1~R-4 已發 mainDev。
   🟢 **R-2/3/4 已修推（`186f5eb`）＋我抽驗**：R-3 trap 這次在 `:70`（先於 `:89` 起的全部
   失敗路徑；mainDev 自報第一次修錯＝trap 定義在檔尾等於沒修）、teardown 誠實報 `ndt down`
   rc、R-4 加 `_parked>=1` 斷言且突變驗過。兩條 process 課：**「修好正在 debug 的實例
   ≠修好那個 bug」（R-2＝同 bug 同檔第二犯、同 commit 訊息裡就寫著修好過）**；
   **「定義在會失敗的碼之後的 cleanup handler 不是 cleanup handler」**。
   ⏸️ **R-1 驗證屬實但 mainDev 刻意不落**（production 開機路徑、不在 Adam 排的順序單上；
   修法已備＝status>=400 改 warning、純 log）＝**等 Adam 裁**；N-2 scope 註記依附其上。
   agy 續帳：0451（e1b5529）2 條 latent（BROKEN 臂不中止、spec.py 突變無 trap 還原）＝
   本輪零臂 BROKEN 零影響、併入 mainDev 下次動檔；0452/0453 全淨；0454（186f5eb）空檔
   ＝review 進行中待回收。
   🟢 **08-25 Adam 兩裁決（皆採建議）**：R-1 **現在修**（N-2 註記照「已修」口徑一次寫定）；
   **曲線輪准跑**（新設計獲點頭；順序仍＝曲線輪→guard/async）。已轉告 mainDev。
   0454 回收＝兩 MED 成立：smoke 印路徑即 unlink＋unlink 在三個 sys.exit 之後（**同 commit
   自打「cleanup 在失敗碼之後不是 cleanup」**）；R-2 形狀掃描漏 `boot_summon.sh:224`
   `xx=$(grep -cE…||true)`（error path 空字串→算術炸；0 匹配無事）＝**「掃過≠掃到」**。
   併 0451 兩 latent 一起等 mainDev 下次動檔。
⑫ 🔴🔴 **曲線輪（08-25 上午，`52267aa`）：環回來了、換臂、驗收 PASS**：quiet **4/4 RING
   WEDGE**（411-412s、ent=2/stc=10、endpoint 死＝HTTP 000）、loaded 4/4 flat-zero 照舊
   ⇒ 同機同 commit 反轉昨晚（<5h vs ~18h uptime）＝**uptime 是僅存共變量**（仍是相關、
   兩點一機）；曲線本身沒量到（零健康 boot）。**dump 首捕活環**：12×`_events_sem.acquire`
   （跨日跨 session 跨儀器重現原始計數）＋**新 51×`reply_q.get()`@Ryu `app_manager.py:279`
   （上游、無時限、不可直接修）＝HTTP 000 的機制、北向 API 整面消失**。wedge_watch 三版
   全部「把健康取反」而非「編碼失敗的實際產物」＝量測方法論課。PROVENANCE-NOTE＝模範
   （R-1 中途誤 apply 已 revert、quiet_p2 標 inference-only；規則：勿改跑動中實驗的受測物
   ＋per-boot sha 重斷言）。🔴 **我的「d1d973d 沒上場」推論已被 mainDev 實測推翻（發出
   後一小時內）**：它翻歸檔 log＝**timeout 每次 wedge 觸發 ~40 次、gate 照設計不再掛住、
   dump 裡無 gate greenlet——但 boot 照樣 wedge ⇒ 砍邊 4「上場了、不足夠」，§5-P
   「切任一邊即破環」被實測（非論證）推翻**。我錯的根因＝**拿猜的字串 grep（"timeout/
   timed out"）而沒先讀 `:915-921` 實際 warning 文字**＝shape-specific-0 教訓（`in put`
   同族）24h 內第二踩、這次是我；~40 次的計數待驗證輪後我用正確字串重數。設計結論不變
   （async＝唯一問題）。⚠️ A-2「Fixed on this branch」超前（fix 已 revert 未 commit）。
   **fix-validation 輪 08-25 已開跑**（`2026-08-25_ring-fix-verify/`，defaults vs ASYNC=1
   4 對 8 次交錯、30-55 分、判讀三分支預先寫死在檔頭：async 也 wedge＝邊 1 也不夠／async
   乾淨＝72fbae6 即修法且翻預設引此證據／**defaults 停止 wedge＝機器態中途移動、比較作廢
   重跑**；banner 正反雙驗、dump 先於拆、trap 先 armed）。
⑬ 🔴🔴 **fix-validation 結果（`6f678fa`）：兩個修法對活靶全數失守，驗收 PASS**。
   defaults 1/4 wedge、async 2/4 wedge（banner=1 斷言過）＝**靶中途腐化→「有效」測不出、
   但「無效」已證**：banner=1 下 wedge ×2＝兩個與基礎率無關的反例，`72fbae6` 不能防環；
   `d1d973d` 由曲線輪 log 免費驗完（~41 次/wedge 觸發、照設計、仍 wedge）＝**兩條邊都
   「上場了、不足夠」，§5-P「切任一邊即破環」雙重實測推翻**。我的重數：8 行、三 dump
   sem/replyq（49/63、74/38、85/27）、sha 前後驗全吻合。🔑 **預註冊判讀規則是這輪還有
   結論的唯一原因**（乾淨 boot 依規則三一律不可歸因）。**async 翻預設措辭上限鎖死＝
   「閒置 26s vs 52s ×10」，不得提破環（反例在案）**。⚠️ **uptime 單調性也死了**：
   4/4@**17.48h** → 1/4@**18.43h**、同 boot_id、**一小時內**（`6644b69` 修正——我原引
   「~21h」是憑時鐘猜的、又一次數字沒從證據算；腐化比雙方描述的都快）＝非單調、共變量
   降級為「reboot 邊界相關＋非單調行為」。新假說（未驗、
   不可引）：環邊不只四條，`app_manager.py:279` 上游無時限 request-reply 是漏算的那條。
   唯一未試組合＝兩修法齊開；任何下輪要**先量當下 defaults 率**再談歸因。2/4 vs 1/4
   無統計意義、不得讀成「async 更糟」。
   🟢 **Adam 終裁（08-25 中午）**：guard=0.01＋async 兩預設**現在都落**（實驗前置已滿足；
   R-1 同批重落、A-2 措辭同 commit 對正；三 commit 措辭 auditer 逐一審）；**combo 輪＝
   機會性**（定期輕量探 defaults 率、≥3/4 才開、平時不燒 lab）；9/03 報告在 combo 前照
   「環 open＋兩修法各自實測不足」寫。
   🟢 **四 commit 全落全過（08-25 午後審畢）**：`f84f738` R-1（四站點加法＋A-2 自指更正）、
   `6644b69` uptime 撤回（**修正我的 ~21h→實際 17.48→18.43h 一小時**）、`d807798` guard
   （evidence-only＋環/settle 防火牆＋成本揭露）、`1b25cda` async（🔴 反宣稱入 commit＋
   未量測清單＋**banner 誠實性**：無條件「=1」在翻預設後＝harness 會 assert 的謊言、改為
   區分顯式/預設＋**過時 harness 註記不改寫**、兩種 rerun 選項明寫）。新 shape 入帳：
   **「翻預設會把無條件 banner 變成謊言」**＝setter/reader 家族的預設變更版。
   ⚠️ **歸因更正（mainDev 自報）**：banner 那條不是警覺抓到的、是**「改預設前先 grep
   誰依賴它」這個動作**撞出來的——「前者可做成規則、後者不能」⇒ 規則入帳：**改任何
   預設/旗標前，先枚舉斷言或 grep 它的 harness 與文件**。另一條它的精煉版也收：
   **「延後要延後到一個會被檢查的地方，不是延後到記憶裡」**。
⑭ 🔴 **精度更正（`8ab0132`，mainDev 自抓＝「拿去用」第三例）：⑬ 的「async 臂＝72fbae6
   單獨」不成立**——timeout 自 `d1d973d` 起預設開、router 凍結版含它 ⇒ **fix-verify 的
   async 臂從來就是 combo**。我逐 boot 重驗（正確字串）：async_p3/p4 timeout_warn=40＋
   banner ✓、defaults_p1=40/0、curve quiet_p1=41/0（我欠的 41/40/40/40 重數一併補完、
   吻合）。**正確狀態表：timeout 單獨＝不足；timeout＋async（combo）＝不足（2/4 wedge、
   雙 log 證據）；async 單獨＝未測且不可測（需先 revert d1d973d）**。⇒ combo 輪與探針
   **取消**（無意中已跑）、**已知修法組合用盡**、下一步＝機制工作（`app_manager.py:279`
   先讀碼）。9/03 措辭定版：**「環 open；timeout 單獨與 timeout＋async 均實測不足；async
   單獨未測且不可測；已知修法用盡。」** 🔑 「結論寫進報告前，先問它會讓下一個實驗長什麼樣」
   3/3 升規則＝[[test-conclusions-by-using-them]]。
⑮ **8/25 mainDev 首擊（純讀碼＋重讀既有 dump、零實驗）＝機制重讀，我對抗性驗證 4/4
   CONFIRMED**：環＝IR handler 內 **`:713 get_switch`／`:740 get_link`**（無時限
   `reply_q.get`@279）↔ switches 塞 `EventLinkAdd`（`sem.acquire`@302）的 2-cycle；
   **`d1d973d` 只包 `:915` host 查詢**（40×warning＝症狀非環位、仍有「無限 hang→有界
   40s 降級」的真功勞）、**`72fbae6` 的 spawn 在 `:794`＝阻塞點之後、卡住就永遠到不了**
   ⇒ 兩修法「未打在環邊上」。驗證：dump frame 與凍結版（`git show 52267aa:…`）行號逐字
   吻合（713/740/279；以後對凍結版不對 HEAD）；計數器交叉 3/3 格吻合、async_p4 判別格
   （sw=3>lk=2 ↔ 卡 get_link）成立；lldp frame 在場 3/3；`6f32bcae`＝main 祖先＋main
   同形狀零 Timeout＝**Part A ✓**；凍結版 `:901-906` 註解自證同鏈。「哪個佇列滿」維持
   **推論**＝建議 USR2 dump 加印 per-app qsize、下次 wedge 升觀察。措辭修正：(a)「唯一
   不在 handler 上」→「唯一被 Timeout 包住」；(b) 🔴 **「已知修法用盡」→「已實作修法
   用盡且未打在環邊；環邊（:713/:740）修法尚未嘗試」＝修法空間重開，9/03 句要改**；
   環邊修法須先過 [[test-conclusions-by-using-them]]＋live 驗證才可入報告。
   🟢 **N-2 註記已落（`e12b212`）＝今日落地循環零 open**：辯護精確（當時 kernel 未聽、
   全數 ECONNREFUSED＝12/20 對已發生者完備；盲點只涉未來活 kernel rerun→雙字串計數守則
   已寫入）；commit 自帶 meta 課「**文件改動延到依賴解決＝默默變成沒人追蹤的東西**，解決
   依賴的那個 commit 就是它該落的地方」。（我 grep 回 0 又是 pattern 問題——「network
   layer」vs 連字號「network-layer」——但這次照第十例規則直接看 diff、規則首戰生效。）
   repo root 又現 untracked `diff.txt`＝影子審查員疑似再寫（hook patch 待 Adam 套）。
⑩ 🔴 **settle 歸因已被 mainDev 撤回（08-25）**：16/16 boot（含 8 個健康 quiet）在 40s
   deadline 皆讀 `0/128` 逐字相同 ⇒ **settle gate 非判別因子**，差異在 **gate 後的
   post-install host learning**（quiet 學到 128、loaded 永不）；現象成立（永久 0/128、
   12h 封存）、**settle sweep 取消**。**抽驗完成（08-25）：19/19 ryu.log（含 smoke＋probe）
   皆「incomplete after 40s: 0/128」，且該 log 行自身就預告 256-down＝gate 是常數不是
   變數**（instrument＝`intelligent_router.py:975-989` 每 10s 進度行，一直躺在歸檔裡）。
   ⚠️ **順序更正**：Adam 已對 mainDev 裁「實驗先於預設翻轉」⇒ **重設計的 post-install
   host-learning 曲線輪（連續輪詢 /hosts、L/Q 交錯）跑完才落 guard/async**——我稍早
   「不再有 settle 前置」一句收回。**我的驗收失手處（記帳）**：數字全重算了、卻沒對 08-22
   settle-gate-acceptance 的「窗內學不到、IPv4 在放開那刻才現」交叉——那條舊資料本來
   就與「窗變短」不相容；muse 同盲。＝[[check-against-prior-experiments]] 的審查版：
   **驗收 checklist 要加「歸因與舊輪次對撞」一項，不只驗數字**。
⑪ 三件收尾：**hook 安裝日＝07-28**（`0001-9910151.md` mtime 07-28 18:26 為證；08-13 是
   hook 最後修改 mtime、mainDev 誤讀為安裝日——兩邊都拿證據收斂）；🔑 mainDev 的方法課
   收進紀律：**兩個進了 commit 的錯宣稱（197/93、settle 歸因）都不是複查抓到的、是
   「拿它去做下一件事」時抓到的** ⇒ 驗收之外，「用這條結論設計下一實驗」本身就是最強
   複核；MEMORY.md 超預算 ~290B（v2 通報）＝下次記憶整理輪順手修。**404 epistemic 線
   與 mainDev 對齊**：量到的是答案翻轉、非表被填——spec.py 註記維持「恢復已量測、機制
   未直接觀察」，不升級成已確認（allowlist vs fix 的分界正是這條線）。
⑯ 08-25 PM：8/25 mainDev 第二擊（47-log sweep＋三站點機制）驗收＝**全 CONFIRMED 帶補強**。
   幻影 id **反轉**：`local_709bd0fe…`＝我自己的 session id（get_session 回 refusing-current
   一發定案；list_sessions 設計上不列自己＝誤判來源＝[[verify-against-known-good-output]]
   第 11 例）；舊交接信自始正確、我的警告會切斷通道，MEMORY.md 已更正。sweep 複算 56/56
   超集全符：桶分類逐檔吻合；我補的＝full-stack 2/2/2/2 我數 **9** 份（信裡寫 8，diag3 歸屬
   待對）、abort 線守衛（修 #1 後 P2 文法會變、恢復會被讀成卡死）、`.test_run` 兩檔＝
   async_p4/defaults_p4 prefix 本尊（無幽靈開機）。**我的追加發現**：111502 dump 兩階段
   （#3 spin 設陷阱→#1 彈陷阱）＋ async 臂佔用反例（walk 已離 handler 仍 wedge ⇒ 佔用普查
   未完）。行號 nit：spawn `:845`→實為 `:851`。qsize 自檢我用 ryu-env 複跑 PASS。PREREG
   審查意見（P2 翻新、FALSIFY 與注入失效的優先序、佔用普查、母體清單、Adam 繼承臂提問）
   已隨驗證回信送出。（註：⑫–⑮ 在檔中段、物理順序與編號不同步。）
⑰ 08-25 PM：Phase 0（ring-edge-fix）驗收＝**PASS、對 mainDev 信零更正**。計數三格複算全符
   （TARGET ALIVE 2/3：boot1=S2、boot2=S1、boot3 健康 10/10）；harness 自印 sha256
   matches-HEAD（指認 binary 紀律落地）；**普查↔frames 雙帳互證**：blocked 55=−12−43（boot1）、
   30=−12−18（boot2），逐格整除。waiter 身分從既有 frame 數出（IR 佇列 12＝10 條 OF 連線
   greenlet＋switches 的 lldp_packet_in_handler＋link_loop；switches 佇列 43＝22 get_switch
   ＋21 get_link 的 REST handler 卡在 **send 步**）＝「要不要往下推一格」的答案：**不用新儀器**。
   boot_id 同 curve 輪（b8b44406）⇒ 單一機器開機四點系列 17.48h 4/4→18.43h 1/4→~19h 2/4→
   20.09h 2/3＝非單調決定版。`:277/:279` 兩行都要包＝讀 app_manager 庫源碼驗證屬實。我中途
   一次誤讀（把 boot2 的 dump 統計行讀成 boot1；實際版面＝細節在前、## 摘要在後）當場更正、
   未流出。Adam 三題（slide 分工／CPU 圖方法／truncate+merge 提案史）已答；truncate/merge
   在 doc、Documents、Slide material 生成器**全零紀錄**＝轉 mainDev 查開發線。
⑱ 08-25 PM2：Phase 2（修法 A）驗收＝**PASS 帶一項更正**。複算全符：fix 臂 0/3 環、保真 3/3
   （128 host＋288 邊 0 down）、fixa1＝阻塞自癒現行犯（t_sw=28、a_sw=7、hto=24、wall 167s）；
   Phase 0 同 boot 對照 2/3。**我的更正：7 次中止全走 get_switch 空清單出口（:852）、
   get_link 出口（:897）零次、28 逾時全 (get_switch)**——信與 :884 碼註解錯置到 link 站
   （待 wording commit）；機制結論不動（兩出口皆在 entered 前），但「link abort 路徑從未
   實跑」須入報告。**窗口我量出＝148s**（fixa1 輪詢斷流 13:46:57→13:49:25、後爆發補收；
   wedge boot1＝4 次後永默）。「twin 靠輪詢學拓撲、環＝餓死輪詢」獨立驗證（polls 4/4 vs
   26/23/23）＋與 ⑰ 的 REST-waiter 身分表咬合；notif=0×6、refused 12-69＝與 N-2 的
   ECONNREFUSED 完備性舊資料一致（對撞完成）。dump 全空（恢復後拍）＝證據缺口 #4 成立；
   暫判 **BREAK（N=3、P(0/3|2/3)≈3.7%、無阻塞中 dump 兩 caveat）**；佔用普查仍 open。
   corpus manifest＋hub.Timeout 自測 PASS 皆歸檔（我兩項要求兌現）。commit 標題「the ring
   is gone」＞信裡校準措辭——報告用信版。建議：grab_dump 改成首個 topo-timeout 觸發，
   下次自然發生就補上缺口。
   ⑱-續：更正 commit `2d65d35` 審畢 PASS（缺陷聲明置頂、範圍收準、148s 落檔、process
   failure 自點名＝範本級）；Adam 二次裁決＝**B 現在做完**（我的「B 延後」建議未採）⇒ B 實作
   獲授權、truncate/merge 順延 B 後；lab claim 已釋放。B 開工四提醒已送（文法第三次改寫要
   B 版預註冊＋corpus 自測、重量靶率、notify 一起搬、worker 停更偵測器）。
⑲ 08-25 PM3：Phase 3（修法 B）驗收＝**PASS，主判準獨立複驗**。B＝handler 只排隊/標髒即返回、
   worker 做重建、通知一起搬（採納我的佔用/停車二分）、停更偵測器同 commit（`bfb0569`）；
   驗證改用**不變量**（event loop 的 frames 不得含三個同步 topo 呼叫）＝冷機可驗、不需靶熱
   （`c986ca0`，全程每 6s 取樣、拒絕空洞通過＝INCONCLUSIVE）。**我用自己的 awk 逐 greenlet
   複驗（他們數 frame、我數 greenlet）**：B 臂 3 boot×9 dump＝159 個 loop stack、**0 停在
   拓撲呼叫**；loop 數 52/54/53 與其一致。**正控制 6/6**（含我加的 `wedge_111502`＝第三站
   get_all_host，補齊他們 5 格只覆蓋 #1/#2）。🔑 **我的第一版檢查器正控制回 0＝我自己的
   萃取器壞了**（awk 只在檔尾結算、中間區塊全丟）——正控制當場擋下，
   [[verify-against-known-good-output]] 首次「事前」生效而非事後。保真 3/3（128 host＋288 邊）、polls 23-25（健康）、
   coalescing 承諾**逐 boot 目視驗**（最後一次 queued 在最後一次 rebuild 之前：行 91 vs 94）、
   rebuilds=2 與 trig=2 逐格吻合＝10 enters 合併成 2 次重建；worker 內仍走 `_bounded_topo_read`
   ⇒ **A 的天花板在 B 之後仍在**（B 不是取代 A、是疊在 A 上）。觀察者效應實測小：wall 56-59s
   vs 未取樣健康 54s。新 log 文法（第三代）：ent=10 但 trig/gsw/glk=2＝**ent 不再能當卡死判準**。
   ⑲-續：`d0b3033` REPORT 與 `895030e` 收尾 commit 審畢＝**PASS**。895030e 把我三條回饋逐條
   落地（第三站正控制→selftest 6/6、`classify_boot.py` 標記 pre-B corpus only、
   「B 疊在 A 上」寫進 §4.5 並附 `:953` 複驗），且把**我的儀器失誤與它自己的七條並列**入表。
   親驗兩項風險：①「中斷的突變 run 留下 mutant」→ `git diff HEAD -- intelligent_router.py`
   **零差異**＝產品碼無殘留（工作區只剩 .vscode／host_count_override／diff.txt 三個舊項）；
   ② REPORT §6 的不變量文字含 `send_request` → 檢查器 `FORBIDDEN` **確實含它**（宣稱與儀器
   一致）。唯一未落的措辭 nit：§1 表「Phase 2 不變量＝仍會違反」是**碼序必然、非本輪觀察**
   （A 臂無阻塞中 dump），建議標註。四個開放項（補 N＞guard 臂＞佔用源普查＞get_link 煙霧
   測試）依 Adam 既有裁決排在 truncate/merge **之後**＝backlog，未另開表單。
⑳ 08-25 收官：`23bcd28`（`get_link` 煙霧測試＝我建議插隊的那項）驗收＝**PASS，含我自己重跑的
   突變閘門**。baseline 5/5 綠（ryu-env＋`PYTHONDONTWRITEBYTECODE=1`）。**突變在隔離沙盒做**
   （複製 `intelligent_router.py` 到 scratch＋改測試的 sys.path 指向它，先跑一次未突變控制證明
   重導有效）⇒ **零風險、不動共用產品碼**（mainDev 同時在工作區＝兩寫入者紀律）。三殺：
   M1 abort 改成 fall-through→4 errors；M3（他們說「保真度測試就是為它存在」的那個）＝把
   pending 集合改成**重建開始就 drain**→3 fails，逐字命中 `[] != [1, 2]`；**M4 是我自己加的**
   ——把逾時訊息改成不宣告逾時→1 fail ⇒ **注入自證性質也被釘住**（他們沒列這格）。
   🔑 測試本身**推翻了作者寫在碼註解裡的預測**：中止不是「遺失該批交換機」而是**延後**
   （queued dpids 存活、下一輪成功時全部通知）——第二次「拿結論去用才發現預測錯」。
   同 commit 補上我的 §1 表格 nit（Phase 2「仍會違反」＝碼序必然非觀察），四項回饋全清。
㉑ 08-25 PM4：Phase 4/5（guard 題）驗收＝**PASS**，且給出 Adam Q1 的**量測型否定答案**。
   重構問法＝mainDev 的功勞（B 之後兩臂都會是 0/N ⇒ 故障率 A/B 失效，改量「guard 真正會動
   的那個量」＝佇列深度＋到達率）。數字：g001（0.01）**69.4/71.6 /s ⇒ t_fill 1.8 s**、
   g005（0.05，stock）**56.3/59.3 /s ⇒ 2.2–2.3 s**；兩臂 peak ≤2/128。⇒ **stock 也只要
   2.3 秒就能填滿，遠小於任何阻塞（settle 40 s、10×5s 通知鏈）＝加速不是缺陷的成因**。
   🔑 **我補的機制（讀 ryu 庫源碼，非推測）**：只有 1.21× 而非 5× 的原因是
   `switches.py:510 LLDP_SEND_PERIOD_PER_PORT=0.9` ——`lldp_loop` 每輪只挑距上次 >0.9 s 的
   port，`LLDP_SEND_GUARD`（`:949` 註解 `don't burst`）只節流**同一輪內**。160 port×0.05=8 s
   ≫0.9（guard 主宰）、×0.01=1.6 s（仍 >0.9，只快一點）。⚠️ 與 08-21「guard 3.9×」不矛盾＝
   **同一常數對兩個量的槓桿不同**（sweep 完成 3.9× vs 穩態到達率 1.2×），報告要並陳。
   🔴 碼註解「~2.5/s ⇒ 50 s 填滿」被實測推翻 **20–28×**（方向對結論有利）。
   **佔用源普查降級為「已部分回答」**：到達率單獨永遠填不滿 ⇒ 佔用是必要條件。
㉒ 08-25 傍晚：**第三個 session 上線＝`sFlow experiment`（`local_b58f138d-82b4-4154-ada9-5bfef4bd6b43`）**，
   Adam 開的，專做取樣率三工單（A 指認執行緒／B ladder 1/32…1/1／C λ 塌縮取代全矩陣）。
   分工由 Adam 再次收緊並明示：**量測／實驗＝實驗 session；分析、簡報定稿、驗收＝審查**。
   交接檔＝`scratch/review-2026-08-25/HANDOFF-sampling-rounds.md`（設計＋事前判準＋中止條件）。
   我要求它「先回預註冊草案再跑」。⚠️ 現有 session 版圖：8/25 mainDev（truncate/merge＋大規模並發，
   等 Adam 開口）、sFlow experiment（取樣率）、審查（我）。**兩個實驗 session 共用一個 lab
   ⇒ claim 衝突是新風險，watcher 的 claim 欄要盯緊。**
㉓ 08-25 夜：**sFlow experiment 第一封就在我的 brief 裡抓到兩個會產生假結果的設計缺陷**，
   五條更正我逐檔驗過**全部成立**：①「twin/truth 是既有欄位」＝**錯**（`twin_stats`／
   `panel_stats` 都沒有，必須現算——我自己 brief 第 4 條正在警告這個坑）；②🔴 **兩道檢查
   共用同一分母**：`gt` 讀的是該介面**自己的 tx 計數器**（`plot_ladder_rates.py:66-67`），
   fabric 在上游掉包時 `gt` 同步下降、比值維持 ≈1 ⇒ 我指名要抓的「取樣傷資料面」**會整個
   漏掉**（修法＝SATURATED／DATAPLANE-HURT 兩標記＋接收端第三量）；③ glob `m1*` 吃到
   `m1024/m128/m16`（**我寫了這條警告然後自己踩**，改 `r001…r032`）；④ HEAD 過期；
   ⑤ **λ 母體混用**（`analyse_matrix.total_sample_rate` 是**跨邊加總**、`panel_stats.lam`
   是**單邊單窗**，我的配對表混了兩者）。**我的回禮一條**：它說接收端資料在 `*_server.log`
   ——08-20 raw 裡**沒有**該檔，真正的獨立量在 `*_client.json` 的 `end.sum`
   （UDP 帶伺服端 `lost_percent`，單流基線 0.51%）。🔑 **教訓：brief 的作者最不適合檢查
   brief**——同一份文件裡我既寫下規則又違反它三次（欄位假設、glob、母體）。
㉔ 08-25 收尾：`dee0512`（twin 高報 23–33%）驗收＝**CONFIRMED**。**我用不同視窗（meta 標稱
   300 s，非其 active window）＋自寫邊↔介面對映＋不篩「有負載」邊獨立複算＝1.264／1.406／
   1.329**（作者 1.227／1.335／1.255）——方向、量級、三類相對順序全一致。**我的懷疑被推翻並
   記錄**：疑其 twin/veth 各用各的 span，實測 379.1 vs 377.6 s（0.996×）解釋不了，且
   `analyze.py:42-46` 明文處理、`:404-408` 真的對齊。回饋三條：①iperf3 佐證的分子分母要寫清
   （我加總 cli_*.json＝offered **1.709 GB**、丟包 **10.61%**，與其 1.605 對不上，但**不影響
   頭號結論**因為那條不經 iperf3）；②🔑 **三類比值不相等 ⇒ 排除「單一常數乘錯」**，
   switch→host 最高且 10.6% 丟包若發生在 ingress 取樣之後即方向吻合（**我的假說、未驗證**）；
   ③兩種邊集合定義並存會被讀成矛盾，要明寫。deck §C4 已寫入（含兩組邊集合與四條 caveat）。
   **F-9 沒現形**（62 條 host 邊全在 3 Mb/s 以下卻無一讀 0）⇒ KNOWN-ISSUES 對 F-9 的描述範圍
   要改。三 session 版圖：mainDev（大規模，未完成）、sFlow experiment（取樣率，預註冊已批准、
   等 lab）、審查（我）。
   ㉓-更正（同日稍後）：**第 ⑤ 條「λ 母體混用」作廢——sFlow session 自行撤回，我原本是對的。**
   它跑 `cell_verdict.py --selftest` 實測 `m256_poll` 的 **`lam = 69.73`** ⇒ 我 brief 的
   「(1/256, 200 Mbit/s) → λ≈70」**本來就是單邊值**（~139 才是全邊加總）。它**在沒實際算過
   `lam` 之前就指控我混用母體**，證據方向剛好相反。保留的只有紀律部分（報告寫明母體、
   配對格以實測 lam 對齊）＝補強不是更正。⇒ 當日互抓比數修正為**它抓我四條、我抓它五條**。
   🔑 **兩個教訓**：①「被指出錯誤」不等於「真的錯了」——我當時**逐檔驗了另外四條卻沒驗這條**
   （因為它讀起來最有說服力），[[fresh-grep-before-confirmed-quote]] 的驗收版；
   ② 它另一條更正**成立**：我叫它拿我的 **+9 偏移**去對今日 build 的名字，但我那份是
   08-20 trace（同份偏移 +13 vs 今日 +11，差 2）⇒ **不能跨版本讀**，而且 08-20 raw **沒有歸檔
   kernel.log**＝那份 trace 的偏移**永遠對不回名字**。我等於在建議它用我剛失敗的方法。
   行為指紋（×10 放大／完全不放大／worker 0.03→0.47 三形狀）仍有效，等新一輪的
   tid↔名字↔CPU 三欄一次貼上。
㉕ **08-25 深夜 compact 前的在途狀態（接手先讀這條）**
   - **三 session**：`8/25 mainDev`（大規模並發輪**未完成**：OVS 兩條件未做＝P7 無解、span bug
     未修、+19% 殘差 5–8% 未指認）／`sFlow experiment`
     （`local_b58f138d-82b4-4154-ada9-5bfef4bd6b43`；工單 A✅B✅ 已驗收、**C 未做**、
     **D 剛派出**）／審查（我）。
   - **工單 D（Adam 已核准，最重要）**：瓶頸已由既有 raw 指認＝**proxy 在 ~145% 平掉、
     bmv2 被餓死**（表在 [[sflow-truncate-merge-status]]）⇒ 先加 P4 `truncate()`（clone 128 B
     取代 1442 B）、**先在 1/256 驗沒有無聲全滅**、再重跑 r008/r004/r002/r001。
     預測已預註冊：每 byte ⇒ 牆上移；每樣本 ⇒ 牆不動、改用 merge。
   - **待 Adam**：truncate/merge 的 8/27 vs 9/03 取捨；C 的順位；deck §C4 由誰執筆已定＝
     sFlow session 出圖與逐頁、我定稿。
   - **我今天被更正／自我更正共四次**（λ 母體我對他錯、+9 偏移我錯、
     「牆不在孿生這一側」我錯＝實為 proxy、brief 兩個設計缺陷）。

---

## 🏁 2026-08-25 深夜 session-close：審查職移交「8/25 auditor」，`8/24 auditer` 退休

**Adam 指示原文**：「把審查員的工作交接給 8/25 auditor（直接交接給它，不用經過我），讓它通知
正在工作的兩個 session『它是新的審查員，以後都向它匯報』，這些做完後你就可以退休了」。
⇒ 交接**不經 Adam**、由新審查員自行通知下游。

**session 版圖（交接當下）**
| 角色 | 標題 | sessionId | 狀態 |
|---|---|---|---|
| 新審查員 | `8/25 auditor` | `local_f5812fe5-462b-488b-8a1a-ce4fd110e1c9` | 接任 |
| 實驗 | `8/25 mainDev` | `local_cf41be54-72ba-4d0f-8e2e-057b52f4f30e` | **running**，大規模輪未完成 |
| 實驗 | `sFlow experiment` | `local_b58f138d-82b4-4154-ada9-5bfef4bd6b43` | 工單 D 進行中 |
| 退休 | `8/24 auditer`（我） | `local_709bd0fe-f593-4040-b91b-830b70e0a334` | 本檔作者 |

### 1. 目前狀態
本 session 任內驗收 **6 輪全部給出裁決**：boot-ring 驗證輪 PASS／`23bcd28` get_link 煙霧測試
PASS（含我自己重跑的突變閘門，三殺＋我自加的 M4）／Phase 4/5 guard 題 PASS 且給出 Adam Q1
的量測型否定答案／`dee0512` 大規模高報 CONFIRMED（獨立複算 1.264／1.406／1.329）／sFlow 工單
A、B 驗收通過。**工單 C 未做、D 剛派出**。deck 的 827 模板已寫入三頁（大規模高報、跨取樣率
ladder、CPU 分解）。最後一題（failover 還能不能更快）已答，見 [[ryu-startup-costs-measured]]
新增節。

### 2. 已定案的決定（連理由）
- **分工**（Adam 兩度收緊）：量測／實驗＝實驗 session；**分析、簡報定稿、驗收＝審查員**。
  理由＝decoupling，審查員不可以自己下場量自己要審的東西。
- **審查方法＝先自建 ground truth 再對散文**，不信報告。理由＝`dee0512` 那輪就是靠不同視窗
  ＋自寫映射複算才敢說 CONFIRMED。
- **接受集要跟拒絕集一樣抽驗**（08-24 mainDev 給的對稱律）。理由＝本輪 ㉓ 的第⑤條就是我
  「逐檔驗了另外四條、獨漏最有說服力那條」而誤收。
- **授權不可轉發**：評價別人是否在授權內＝審查員職權，發放／擴張授權＝不是
  （[[auditer-cannot-extend-authorisation]]）。
- **deck 只放 figure 裡的實驗，不放 debug 過程**（Adam 明示），例外＝baseline 就存在的 bug。
- **truncate/merge：做成功版→跑實驗→再向教授解釋為什麼不採用**（Adam 明示，不是取消）。

### 3. 尚未解決／討論到一半
- **工單 D**（truncate）結果未回。預註冊：每 byte ⇒ 牆上移；每樣本 ⇒ 牆不動、改走 merge。
- **工單 C**（λ 塌縮 6 格）順位待 Adam。我的設計：sending rate 往**下**走（100/50/25），
  全部瞄 λ ≤1000 單邊（離 ~2550 平台 2.5× 餘裕），lost% >2% 的格子換掉。
- **truncate/merge 趕 8/27 還是 9/03**：待 Adam。
- **大規模輪 OVS 那半**（P7 無解）、**span bug**（算出物理上不可能的負損失）、
  **+19% 高報的 5–8% 殘差**：全在 mainDev 手上。
- **F-9 的描述範圍要改**（`doc/KNOWN-ISSUES.md`）：62 條 host 邊全在 3 Mb/s 以下卻無一讀 0。
- **failover 的建議（不追速度、改追誠實）Adam 尚未裁**，我提議可寫成 deck 一頁，他還沒回。
- 三個延後的 nit：28× 過期註解、`assert_invariant.py` 的 `hits` 數的是 frame 不是 greenlet、
  佇列普查的 `_q is None` 會誤報 FULL。

### 4. 🔴 矛盾／已被推翻但容易被當前提的四條（接手先讀這四條）
1. ~~**1.135 s 迴圈週期已撤回**（`1b7c487`）……正解＝加儀器重建，不要再引 1.135。~~
   ✅ **08-26 由 `8/25 mainDev` 解掉**（本條四條地雷中唯一已解的一條）。
   儀器已加並重建（`dd1e76f` 的 62 行，`8375a6c` 放回 HEAD），**`T` 現在由 kernel 自己記**：
   **空載 1012.1 / 16 流 1042.6–1049.8 / 64 流 ~1255 ms**（把累積平均逐段差分，取與分析同一個視窗）。
   🔑 而且**同輪同視窗** `T` = 1049.8 對 ratio = 1.0386 ⇒ **分母解釋掉同代 fabric 內幾乎全部的高報**。
   ⚠️ 但「只解釋 4/18」那句**也一併撤回**——它拿 23:2x 的 `T` 對 15:53 的 ratio，**跨了 fabric 世代**
   （見 [[ratio-sides-must-share-a-population]]，同一形狀那晚出現三次，含審查員自己那張圖）。
   🔴 **仍不得引用的**：15:53 那一代的 `T` **永遠量不到了**（儀器 23:25 才存在）。
2. **「牆不在 twin 那一側」是我說錯的**。實為 **proxy 在 ~145% 平掉 → bmv2 被餓死**
   （[[telemetry-cost-is-fixed-not-per-sample]]、[[sflow-truncate-merge-status]]）。
3. **recompute 我口頭講 0.25 s、帳上是 2.17 s**（見 [[ryu-startup-costs-measured]] 新增節的
   ⚠️）。failover 的 walk 是**不同呼叫點、從沒量過**。
4. **`local_709bd0fe-…` 不是幽靈 session，是我自己**。`get_session` 回 refusing-current、
   `list_sessions` 設計上不列自己 ⇒ 舊的「查無此 session」是我的誤判，早期交接信自始正確。

### 5. 建議接手先驗證（開哪個檔、看什麼）
1. `git status` ＋ `git log --oneline -8`：交接當下工作區是髒的
   （`p4_proxy/p4_src/ndtwin_switch.p4`、`p4_proxy/proxy_agent/sflow_emitter.py` 已改未提交）
   ⇒ **先確認那是工單 D 的產出還是殘留**，不要當成別人的完成品。
2. `grep -n truncate p4_proxy/p4_src/ndtwin_switch.p4`：工單 D 的核心交付物到底進去了沒。
   **有了也不等於有效** —— 08-20 的 runtime knob 就是無聲全滅（全邊讀 0、零錯誤），
   所以驗收要看 1/256 那格的非零讀值，不是看碼在不在。
3. `intelligent_router.py` 的 `_bounded_topo_read`(~`:801`) 與 `_topology_worker`(~`:919`)：
   本輪所有 failover／開機環結論都站在這兩個修法上，先確認還在（行號可能已漂）。
4. `src/ndt_core/collection/FlowLinkUsageCollector.cpp:1447` 與 `:1885-1888`：bps 分母。
   若有人動過，上面第 4-①條的整段推理要重來。
5. `/home/adam/Desktop/NDTwin slide material 827/NDTwin-slide-template-827.md`：
   **Adam 會直接編輯**，我的 v1.6 未必是最新，動工前先讀最新 revision 區塊。
6. `ndt status`：誰在用實驗室查這個就好，不必問別的 session。兩個實驗 session 共用一個 lab
   ⇒ **claim 衝突是本輪新增的風險**。

### 6. 文件索引（區分讀過與只知道檔名）
**我實際讀過並可負責描述**：`scratch/review-2026-08-25/`（`sweep_replicate.sh`＋56 log 語料、
`accept_phase0/2/3.sh`、`inv_check.awk` 逐 greenlet 不變量檢查器、
`HANDOFF-sampling-rounds.md` 三工單 brief）、
`doc/audit/2026-08-20_sampling-rate-and-cpu/plot_ladder_rates.py`（我寫的）、
`doc/audit/2026-08-21_ryu-topology-scaling/DETECTION.md`、827 slide 模板。
**只知道存在、本輪沒打開**：`doc/audit/2026-08-25_sampling-rounds/` 底下 08-25 新增的
`gate_d.*`／`ladder_d.out`（交接當下是 untracked）、`scratch/phase2/FINDINGS.md`。

---

# 🏁 2026-08-27 session-close：`8/25 auditor` 移交「8/27 auditor」

本節作者＝`8/25 auditor`（`local_f5812fe5-462b-488b-8a1a-ce4fd110e1c9`）。
**Adam 的報告已經講完了**，用量也刷新。指示＝交接給 `8/27 auditor`，由它通知
`sFlow experiment` 與 `8/27 mainDev`，然後**把剩下的實驗做完**。

## 1. 目前狀態

**工單 A–F 全部跑完**（A 指認執行緒、B ladder 延伸、C λ 塌縮、D truncate、E merge 閘門、F merge 效果）。

| 工單 | 結果 | 裁決 |
|---|---|---|
| D truncate | 位元組 ↓5.60×，但**牆完全沒動、λ 平台 2550→2100** | **per-byte 否證**，ACCEPTED |
| E merge 閘門 | datagram ↓6.86×、λ 與 ratio 不變 | 三項全過，ACCEPTED |
| E 主量測（1/8） | 噪聲 7.5 點 > 效果 4.4 點 | **無法判定** |
| **F merge 效果（1/16）** | **proxy −13.4%、kernel −16.4%，三對三零重疊** | **成功分離** |
| C λ 塌縮 | 控制組 Δ=0.136 ≥ 0.1 門檻 | **反轉結論永久收回** |

**大規模並發輪**：四輪十二格**我獨立複算過**（自寫積分器＋自寫 veth 對映＋標稱視窗，
不碰 `analyze.py`），全部吻合 3% 內 ⇒ **CONFIRMED（分析層）**。

**deck**：我做了 **7 張圖**進 `NDTwin slide material 827/figures/`，模板的對應頁都標好版型了。
（`page_truncate-bought-nothing` / `page_sampling-ceiling` / `page_who-is-the-bottleneck` /
`page_loop-period` / `page_merge-gate` / `page_shared-code-bias` / `page_merge-effect`）
產圖腳本＝`doc/audit/2026-08-25_sampling-rounds/plot_deck_827.py`，**所有數字從 raw 或
committed 的 `.out` 解析，沒有手打**。

## 2. 已定案的決定（連理由）

- **分工**：量測／實驗＝實驗 session；分析、簡報定稿、驗收＝審查員。理由＝decoupling。
  ⚠️ **08-26 凌晨破例過一次**：兩個實驗 session 都收工、Adam 睡前明確授權，**F 是我親自跑的**。
  下一任若要沿用這個破例，**要重新取得 Adam 授權，不要拿 F 當先例**。
- **驗收方法＝先自建 ground truth 再對散文**。理由：本任期靠它抓到三件事
  （閘門少跑一項、跨平面禁令被自己違反、`distinct` 引錯格子）。
- **要分離效果，先換工作點，不要先加 n**（F 學到的，見下面矛盾 §3-2）。
- **deck 上「成本降低」可講、「天花板上移多少」不可講**。理由＝08-20 已證明 CPU-vs-取樣率
  的線外推到零會比實測零點高 45 點。
- **truncate/merge 趕 8/27**（Adam 08-25 裁）、**工單 C 優先於 merge**（Adam 08-25 裁）。
  兩條都已執行完畢，現在失效。

## 3. 🔴 尚未解決／矛盾（不抹平）

### 3-1. Adam 從未裁決的兩件事（我兩次問、兩次沒回）
1. **λ 塌縮那頁留還是拿掉**。兩個選項寫在模板裡：(a) 留著當「押了漂亮反轉、控制組把它殺掉」
   的實例；(b) 整頁拿掉、六格併進講稿。**我建議 (a)**，因為那頁的反轉結論**已經被寫進 deck 草稿**，
   是我堅持標「進行中」才沒上台——那件事比六格數字有價值。
2. **「我們犯了五次錯、五次都自己抓到」的框法要不要用**。素材夠（讀取器回 0、腳本少一個
   `--selftest` 呼叫、日期讀成今天、quantum 歸因被下一格推翻、C-P2 下界推理不牢）。
   **這是價值主張不是編輯決定，我沒有替他拍板。**

### 3-2. 🔴 E 的收尾建議**已被 F 推翻**，但 E 的報告裡還留著
`sflow-truncate-merge-status` 曾寫「下一輪用配對區塊、**每條件 n≈12**（一小時）」。
那個 n 是用**懸崖邊**（1/8）的 SD＝5.3 點估的。**F 在 1/16 用 n=3 就分離出來了。**
⇒ **不要照 E 的建議排一小時的實驗。**

### 3-3. E 與 F 不矛盾但**極易被讀成矛盾**
E 說「merge 對牆的影響無法判定」，F 說「merge 省 13–16%」。**兩者問的不是同一件事**：
E 問**天花板**（在 1/8 量掉包），F 問**成本**（在 1/16 量 CPU）。
🔴 **F 沒有回答天花板的問題，那題仍然開著。**

### 3-4. 從未驗證、但很多結論站在上面的
- **回壓因果鏈**（proxy 吃不下 → CPU port 回壓 → 管線停頓 → 丟原始封包）：**假說，從沒驗證**。
  已量到的只有三件：樣本沒掉、真實流量掉了、proxy 平台位置對上掉包起點。
  **天花板的所有結論都站在它上面。**
- **proxy 卡在 GIL**：結構已讀出（5 Python 執行緒 / 21 OS 執行緒、樣本從 C 層進 Python），
  但 **dump 是在閒置 proxy 上做的 ⇒ 沒有直接觀察到競爭**。要 20–30 分鐘在 1/8 有負載時重做。
- **baseline 在 128 台×並發下會不會也高報**：程式碼逐字相同（`28b8b13:1363-1365` ＝
  現行 `:1885-1887`），但**baseline 從沒在這個規模量過**。
  ⚠️ 這個 repo 有過「那行碼是繼承的，但在我們自己的改動之前它構不到」的前例。

### 3-5. 還開著的技術債（不是我的）
- **14.8% 世代差**：可證偽形式 mainDev 已寫死（同格跑兩次、一次灌忙一次安靜、兩次都開儀器；
  ratio 升而 T 不升 ⇒ 負載假說死）。⚠️ **「安靜」必須量出來**——有一個會寫 repo 根的 actor，
  **沒有任何 session 的時間表涵蓋它**（四層歸屬跑完是「查無此人」）。
- **span bug（P4 條件 A）**：未修，mainDev 手上。
- **全邊倍率**：三個互不相容的值（1.0 / 2.03 / 3.0），**維持撤回**。
- **`doc/KNOWN-ISSUES.md` 的 F-9 描述範圍要改**（62 條 host 邊全在 3 Mb/s 以下卻無一讀 0）。
- **三個 nit**：28× 過期註解、`assert_invariant.py` 的 `hits` 數 frame 不是 greenlet、
  佇列普查 `_q is None` 會誤報 FULL。
- **1 kHz 的 `calFlowPathByQueried`**：Adam 明確裁「報告先不碰」，停在「45 點是固定成本、
  機制已指認」。🔴 動它之前要先寫下「那 1 kHz 在保護什麼」。

## 4. 立即下一步

1. **通知兩個實驗 session**（Adam 指定）：`8/27 auditor` 是新審查員、報告已講完、用量已刷新、
   繼續把剩下的實驗做完。
2. **排剩下的實驗**，我建議順序：**14.8% 世代差的判別實驗**（機制題、擋著所有高報數字）
   →**GIL 在負載下的 dump**（20–30 分鐘、決定天花板還有沒有救）
   →**回壓因果鏈**→**baseline 規模對照**。
3. 把 §3-1 的兩題送 Adam 裁（他偏好可點選表單）。

## 5. 🔍 建議下一個 session 先驗證（開哪個檔、看什麼）

1. **`sha256sum build/bin/ndtwin_kernel`** 應為 `3367d0e9…`。
   🔴 **HEAD 的原始碼有迴圈週期儀器、磁碟 binary 沒有，是刻意不一致的**
   ——任何人跑過 `cmake --build build` 就會無聲變成 `5b30e448`，而 `ndt status` 只印路徑不印 hash。
   **若已變，所有跨 run 比較要重新檢查。**
2. **`grep -n "SAMPLE_RATE\|SAMPLE_TRUNC_BYTES" p4_proxy/p4_src/ndtwin_switch.p4`**
   應為 `256` 與 `128`（生產組態）。`wall_f.sh` 結尾會還原，但**若中斷過就可能停在 1/16**。
3. **`git log --oneline -5`**：我最後的 commit 是 `d39eca1`（工單 F）。
   ⚠️ 交接當下 HEAD 已被別的 session 續過（`12c6f20` 等），**先確認誰動過什麼**。
4. **`ls "/home/adam/Desktop/NDTwin slide material 827/figures/"`**：七張圖應該都在。
   模板 `NDTwin-slide-template-827.md` 的 C4-bis／C5 段落標著它們的版型。
5. **`ndt status`**：確認 claim、fabric 狀態、以及 handoff note。我 claim 過 120 分鐘（02:52 起），
   應該早就過期了。
6. **`p4_proxy/proxy_agent/sflow_emitter.py` 是否仍未提交**——batching 的實作本體是
   mainDev 未提交的改動、**測試從未跑過**（這台機器沒 pytest）。F 用了它，
   **但 F 驗的是行為不是程式碼正確性。**

---

# 🏁 2026-08-27 session-close（第二次）：`8/27 auditor` 移交

本節作者＝`8/27 auditor`。**Adam 說用量快沒了，收尾。** 實驗仍在跑，見 §4。

## 1. 我任內完成的驗收（四件，全部獨立重算過）

| 工單 | 結果 | 裁決 |
|---|---|---|
| ① 14.8% 世代差 | 負載把 ratio 往**下**推（1.052→0.972→0.724 單調） | **ACCEPTED，負載假說在本工作點推翻** |
| ② GIL dump | G=0.461 對 144% CPU | **ACCEPTED，H-GIL 推翻**（proxy 不是 GIL-bound） |
| H 睡眠者在等什麼 | send-wait **0/23**、reclaim 0/23、futex 0.652 | **ACCEPTED，回壓 (a) 在第二個工作點出局** |
| P 儀器 1 | 端點＋5 測試 | **ACCEPTED，突變閘門我親自重跑過**（503→回零 ⇒ 紅） |

**①路上撿到的東西比它本身重要**：🔑 **CPU 競爭下遙測少報 34%，資料面只掉 5%**
（veth 4.455→4.233＝95.0%、twin 4.621→3.066＝66.3%）。已開工單 P 指認機制。

## 2. 🔴 我犯的錯（四次，同一母題：**證據為真、指向為假**）

1. `analyze.py` 的 `$7`（per-edge min）當成 `ratio` —— 對照他們的表當場發現。
2. **`git log -1 -- <path>` 當 provenance** ⇒ 把 mainDev 當天新寫的 50 行歸給舊 commit `ee443f4`，
   並寫成「第 12 例」報給 Adam。**推翻我的證據（`50 insertions(+)`）印在同一個指令輸出裡。**
   真相＝仍是**第 11 例、writer 零 reader**（我最初的判斷才對）。已記入 [[cited-line-numbers-are-not-evidence]]。
3. **`pgrep -f qemu-system` 匹配到自己的命令列** ⇒ 差點記下「N 開跑時起了第三台 VM」。
4. **把原始碼註解裡的驗收儀器當成事實抄進工單 Q**（`:1736-1737` 那句「修完週期行必讀 ~1000 ms」
   **是錯的**——(A) 修法不改睡眠也不改本體，週期仍 1043）。mainDev 在動手前反對，我確認他對。
   🔴 **那句註解仍在碼裡，會再騙下一個人；已要求 Q 的交付順手修掉它。**

## 3. 已定案的新條款（都已進記憶）

- **`git log -1 -- <path>` 不是 provenance 工具**；只能用 `git log -S` / `git show <sha>:<path>` / `git blame`。
- **任何「這行本來就在／這是第 N 例」的宣稱要附上述輸出，不附不計分**（雙方同等適用）。
- **揭露 ≠ 下修**（新記憶 [[disclosure-is-not-downgrading]]）：自己註冊的判準要對**每一句宣稱**各跑一遍，
  不是只對掛「裁決」標籤的那個。①與我各犯一半。
- **量測前讀一次全機環境**，不要假設 `ndt status` 乾淨＝機器乾淨（QEMU VM 不出現在 status）。
- **`loadavg` 不得用於格子級判斷**，用 `/proc/stat` 差分。
- **引用 ratio 要指名欄位**（`--json` 讀 `summary[cls]["ratio"]`，禁止 `awk '{print $6}'`）。
- **`pgrep -f` 的臨時查詢比採樣器更危險**——沒有 selftest，且錯誤會在回頭驗證時自動消失，
  看起來像「查過了、沒事」（mainDev 措辭）。
- **版控裡的檔案 ≠ 被執行的檔案**，證據鏈整條都是真的、只是打在旁邊那份上（同族第三例）。

## 4. 🔴 在途（接手先看這裡）

**排程總表：N（跑中）→ M → P → Q。**

| 工單 | 誰 | 狀態 |
|---|---|---|
| **N** OVS 頻寬天花板 | sFlow | **跑中**，claim 到 14:28。N-0 基線已開跑 |
| **M** 1 kHz→1 Hz | mainDev | 待 N 後同輪 OVS。**待命中，無無實驗室工作** |
| **P** 遙測失明 34% | mainDev | 三項無實驗室交付全完成（`59e7298`/`049a054`/`7d4118b`），等 P4 排回 |
| **Q** 修寫死分母 | mainDev | 預註冊已 commit，等 P 的殘差結論 |

**N 的兩個未決**：
1. **Adam 已授權改兄弟 repo** `~/Network-Traffic-Generator/testbed_topo.py`（**只拿掉接取層 `bw=`**、
   量完還原並驗 sha256）。🔴 還原**不可用 `git checkout`**（那 repo 有別人三個未提交改動）。
   還原後要驗 **sha256 相符 ＋ 那三個改動還在**。
2. **QEMU VM**（pid 387661，**12:41:45** 起，17.4% CPU / 3.3 GB）**在場** ⇒
   N 量到的是**下界不是天花板**。判讀表已加：**未達標＋VM 在場 ⇒ 不得裁「這台機器做不到」**，
   只能裁「量到 X、天花板 ≥ X」。**達標則不受影響。**

**Q 的閘門已重寫**（原條款作廢）：**記錄「實際被當成除數用的值」並斷言等於同輪量到的經過時間**
（容差 1%），對三種修法都有效。mainDev 要做 (A)+(B)，(B) 的 `sleep_until` 要防追趕空轉。

## 5. 教授的兩個驗證項

1. **10 Gbps ＝速率**（Adam 確認）。🔴 **「OVS 只有 40 Mbps」是誤讀已撤回**——那是**設定**
   （每流 iperf3 目標 0.5M/2M/20M），**吞吐上限從沒量過**。現況單一核心鏈路硬卡 **2 Gbps**
   （每台 Agg 只被兩條 1G 餵）；`TCIntf.bwParamMax=1000` ⇒ 核心「10G」從來沒被整形。工單 N 在答。
2. **1 kHz → 1 Hz**（學姐確認是打錯的）＝工單 M。🔑 **那 1 kHz 只保護一樣東西**：
   `flowPath` 全 repo 唯一消費者是 API 的 `j["path"]`（`:2256`）⇒
   **風險不是效能，是短流的 `path` 會變空**。before/after **必須有 churn 臂**，
   穩態長流會給假綠燈（空路徑比例只有 0.17%）。

## 6. 檔案

`scratch/review-2026-08-27/`：`ACCEPTANCE-PRECRITERIA.md`（含修訂 1–7）、
`TICKET-M/N/P-*.md`、`recompute_gil.py`、`recompute_cpu.py`。
⚠️ 準則檔修訂 2–5 的**標頭時戳快約 1 小時**（已在修訂 6 勘誤，內容與順序正確）。

## 7. 🔴 收尾後仍在跑：N-1 的還原目標（最高優先，有毀壞風險）

`~/Network-Traffic-Generator/testbed_topo.py` 的還原目標＝**`ead4d84a…`（N 動手前的磁碟狀態）**，
**不是 `git checkout`**（那會還原到 HEAD `50f9bb17…`，弄掉磁碟上一份 **7/8 的環境修補**
——`sys.path.append` ×2、`command_line(config_file_path=)`、結尾換行，與頻寬無關）。
⇒ **還原正確的證據是 `sha256 == ead4d84a…`，不是 `git status` 乾淨**；
**在這裡 `git status` 乾淨等於弄錯了**（應仍顯示 ` M testbed_topo.py` ＋另兩個 M ＋ `?? flow`）。
備份在 `/tmp/claude-1000/…/bfb90c75-…/scratchpad/testbed_topo.py.PRISTINE`（mtime Jul 8 14:18）。
（mainDev 發現、我驗證：收尾當下磁碟＝`f890f607…`＝已改狀態，接取 `bw=1000,` 0 行、核心 `bw=10000` 8 行。）

📌 **這是「證據為真、指向為假」的第四個受詞**（mainDev 語）：
**「還原到哪裡」與「改到哪一份」「讀哪一欄」「哪個 commit」是同一問。**
`git checkout -- <file>` 是「還原」最自然的手勢，而它在這裡是錯的那一個。

## 8. N-0 已驗收（ACCEPTED）

**單一核心鏈路 1.015 Gbit/s**（預測 0.9–2.0 內）、八條合計 3.628 G；
s5 出 1.824 G / s6 出 1.795 G vs 供給上限 4 G ⇒ **接取層是束縛，確證**。
ECMP 實際在分（1.01/0.99/0.81/0.81）⇒ 單一鏈路 ≠ 總量。
🔑 前一格作廢的機制：`pkill -f iperf3` 在啟動迴圈內 ＋ mininet host 共用 root PID namespace
⇒ 每輪殺掉前面所有伺服器，只剩最後一對（可證偽預測驗中 i=31）。
**「32/32 servers started」是真的，它們是之後才被殺的 ⇒ 啟動成功 ≠ 還活著。**
⚠️ 儀器無辜：0.902 G 對那一條流是正確讀數——**數字合理得不會有人去查。**
🔴 **工單 N 原文的 `Bandwidth limit` 檢查是我寫錯的**：那行只由 `bw>1000` 觸發，
接取的 `bw=1000` 永不產生它 ⇒ 改法 A 下不可能歸零。**標「不適用」，維持只動接取層**
（核心 `bw=10000` 拿不拿掉都是 `noqueue`，零鑑別力）。真正的注入自證＝接取 qdisc `htb`→`noqueue`。
🔴 **環境**：`MemAvailable` 一格內 3.35→1.79 GB、direct-reclaim 173,569 頁，
CPU 只有 35.1%／0 核 ≥95% ⇒ **記憶體壓力比 CPU 更可能是真正束縛**，VM 仍在場，全部標 `lower bound`。

## 9. ✅ 工單 N 完成（ACCEPTED）——**教授的 10 Gbps 那題答了：打得到，超出五倍**

| | N-0（未改） | **N-1（拿掉接取層 `bw=`）** |
|---|---|---|
| 最大單一核心鏈路 | 1.015 Gbit/s | **53.142 Gbit/s**（52×） |
| 八條合計 | 3.628 | 121.934 |
| CPU | 35.1%、0/14 核 ≥95% | **98.7%、14/14 核 ≥95%** |

**達標且乾淨**：53.1 ≫ 10，且該格跑在 **VM 已離場之後**（`開機手冊` 應請求暫停）⇒
「未達標＋VM 在場不得裁做不到」的保護條款不適用。
🔑 **兩儀器互證**：iperf3 自述 220.96 G（分母 30 s）× 30/54.5 = 121.6 vs 介面計數器 121.93（分母 54.5 s）
⇒ **差 0.3%**，而 sFlow **先換成同母體才比**（[[ratio-sides-must-share-a-population]] 主動避開）。
**只引視窗平均 53.142（保守），不引 1.8× 外推。**
🔑 **預測 3–8 G 錯了 6.6 倍**，落進「第四種結果」而**不改門檻**；錯的是幅度不是方向
（「瓶頸變 CPU」那半成立）。機制自我更正＝**veth 是記憶體複製，沒有線速可言**。
**注入自證**：接取 `s1-eth1/2/3` `htb`→**`noqueue`** ✅（核心 `noqueue` 不該變、沒變）。
🔴 **`Bandwidth limit` 檢查是我工單寫錯的**（只由 `bw>1000` 觸發）⇒ 判「不適用」，N-1 照常計分。
**還原三項全驗**：sha 回 `ead4d84a` ✅、別人三個未提交改動全在 ✅、全程 `cp` 未碰 `git checkout` ✅。

### 🔴 未完成：診斷 A（twin/veth）沒採集，已裁「補做」
增補 N-1 註冊了每格要記 twin/veth，`n_cell.sh` **從沒接上 `poll_twin.sh`/`poll_veth.sh`**。
我裁定**補做**（sFlow 在 14:29 前跑）：N-1 是 **98.7% CPU 飽和格**，正是①「高負載下分身準不準」
最想要的條件，且**這個 OVS 視窗不會再有**（接下來 P4 排回給 P）。
⇒ **沒有它就無法回答「①的遙測失明是不是 bmv2 特有」**，而那決定①結論的範圍。
約束：補做是**增補不是取代**（53.142 已驗收，兩次都記不要挑）；環境要記 VM 是否仍離場。
**接手請先查這一格補到了沒。**

📌 教訓（sFlow 自評，我加了後半）：**預註冊寫幾項檢查、腳本就要有幾個對應呼叫。**
`n_cell.sh` 是圍繞當時想量的東西長出來的，而增補 N-1 是後來加的 ⇒
**後加的註冊項最容易沒有對應呼叫，因為腳本骨架已經定型**。
⇒ **每次增補預註冊，同時 grep 腳本裡有沒有對應呼叫**——比交付前檢查更早也更便宜。

## 10. 🏁 17:00–19:00 追記（P 結案之後；Adam 因用量喊停,三個 session 同時收尾）

### 10-1. 工單佇列的真實狀態

| 工單 | 狀態 |
|---|---|
| ① / ② / H / N / R / U | **結案**（①含兩次撤回,見 10-2） |
| **P** | **結案 17:07**,四臂乾淨（Q′ 回到 Q,哨兵全 ✅ 可解讀） |
| **Q**（修寫死分母） | 🔴 **未開跑,工作點與預測區間全部待定**（見 10-3） |
| **M**（1 kHz→1 Hz） | 🔴 **未開跑**,排最後（M 會抹掉 Q 的效應） |
| **S**（速率階梯／BMv2 上限） | 前置 poller 已改（`poll_veth2.sh`）,**階梯未跑,p95 自證未做** |
| ingest 決定性測試 | 🔴 **前置三問第 1 問失敗,未跑**（見 [[instrument-must-not-mimic-its-own-finding]]） |

**`build/bin/ndtwin_kernel` 全程未重建,仍是 `3367d0e9`** —— 這是①與 P 四輪的可比性基礎,
**下一任接手時若它變了,今天的跨輪比較全斷。**

### 10-2. 🔴 三句在交接時最容易被讀錯的（請逐字沿用）

1. **`host→switch` 那一欄的缺口,同時含遙測遺失與 bmv2 ingest 遺失,兩者未分離。**
   **既不可寫「遙測少報 34%」,也不可寫「bmv2 吃不下」。**
   `switch→switch` 的定量比較把樣本遺失界定在 **5%**,其餘約 **30 點來源待測**。
2. **Q 的校準值全部作廢**：不得用①的 **1043.9**（在斷層另一側）,
   也不得用 `Q_T64` 的 **1047.3**（外部估計量在長週期未驗證；gen-1 迴圈內儀器同條件量到 **1248.7**,差 200 ms）。
   ⇒ **校準值與被校準的量必須來自同一側。**
3. **Q 的驗收改用「除數 == 同輪實測經過時間（容差 1%）」,不經過 ratio。**
   它驗的是「分母修對了」**不是**「高報消失了」——後者①已用同輪同視窗相關回答過,
   **Q 不必重建立,也不得冒充。**

### 10-3. 兩個「已備妥但未用」的（不要重推）

- **既有 direct counter 的 10 分鐘檢查**（`:285`/`:286`）——可能不改 `.p4` 就回答 ingest 題。
- 🔴 **`read_egress_counter`（`p4_client.py:582`）的 `return 0, 0` 未修**：
  「查不到 counter」與「這個埠沒封包」序列化成同一個值。**用它之前必修。**
- **免費硬結果**：跑了一整天含 28-burner 臂、iperf 回報 42% 丟包,
  **160 個 `s*-eth*` 的 `rx_dropped` 全部是 0** ⇒ 核心從未在介面上丟包 ⇒
  ①的分母沒有低估,且**丟包位置在 RX 計數之後**（bmv2 socket buffer 或管線內）。

### 10-4. 我這一任犯的錯（完整,五次,全部由實驗 session 抓到）

`per-edge min` 當 ratio／`git log -1` 當 provenance／`pgrep -f` 抓到自己造出幽靈 VM／
把 3 小時前的 handoff note 當當下讀數還加「我確認」／**驗收①時只看一類邊沒問另外兩類**。
**共同母題＝證據為真、指向為假。** 第五次代價最大,已寫進 [[ratio-sides-must-share-a-population]]。

🔑 **第六次是制度層級的,不算我個人的錯但要記**：我獨立重算並確認了 mainDev 的 `Δ/SE = 10.9`,
**兩個人各自正確地算了同一個錯的東西**（複製單位選錯,見 [[replication-unit-not-the-rep]]）。
**獨立重算抓不到「錯誤發生在資料進入算式之前」的那一類。**

## 11. 🏁 21:00–23:xx 追記（usage 刷新後復工；四個 session 並行）

### 11-1. 工單佇列

| 工單 | 狀態 |
|---|---|
| **Q**（修寫死分母） | **第 1 段結案** `f5e3556`＋`01c583c`＋`fb517a1`；**第 2 段跑著**（交替臂） |
| **M**（1 kHz→1 Hz） | 🔴 **碼還沒寫**。教授點名、要進**下週實驗室報告**（Adam 08-27 裁定） |
| **S**（速率階梯） | poller 自證 ✅ PASS；**階梯延到 M 之後**（M 拿掉那個執行緒才量得到真的資料面上限） |
| **ingest 決定性測試** | 預註冊已寫（`doc/audit/2026-08-27_ingest-decisive-test/PREREG.md`，`324c4df`/`594d4e7`/`e9991a5`）；**等實驗室** |
| **`read_egress_counter`** | ✅ 結案 `65aacad`＋`08b72d6` |

**執行順序（定死）**：Q 第 2 段 → M → ingest → 階梯 → 開機手冊 B 段。

### 11-2. 🔴 binary 與 fabric（接手先讀這格）

```
舊 3367d0e9ed22db84ba8a66ef61d74b3f56571e2d60ef94ccd40742a969ebdb27  ← ①與 P 的可比性基礎
新 ab2d7ed1bcff8ee58a68afcd11354979efae6e79b501355b1c33999f93b685ea  ← Q 的儀器版
備份 .test_run/binaries/ndtwin_kernel.3367d0e9   ← 🔴 在 build/ 外面（make clean 會帶走裡面的）
```

- **重建 kernel 只吃 69 MB**（3237→3168 MB 實測）。先前的 GB 級焦慮錯了一個數量級。
- ✅ **換 kernel 不必重起 fabric**（實測）：bmv2／proxy／mininet 全存活、twin 5 秒重新收斂、
  `Pulled 16256 paths`。工具＝`doc/audit/2026-08-25_large-scale-concurrent/restart_kernel.sh`，
  它斷言 **`/proc/<pid>/exe` 的 sha256**（不是路徑）並擋 `:8000` 被別人佔住。
  🔴 **但它沒檢查路徑數**（`16256 = 128 × 127`）——已請 mainDev 補。

### 11-3. 🔴 我在這一輪撤回的一個理由（它比結論重要）

我先前寫「M 若跟 Q 不同代就付兩次世代代價」。**錯的。**
交替設計成立之後：Q 比較 `baseline ↔ Q-fixed`、M 比較 `Q-fixed ↔ Q+M-fixed`，
**各自在同一代之內、各自內部有效，即使兩組在不同世代**。
唯一失去的是把兩輪絕對值直接相減——**而那本來就不該做**。
⇒ mainDev 標出「(b) 押在 fabric 不倒上」，正確答案是**那不是押注**。

**臂的擺法**：最少 `B Q B Q`（每格兩臂），交替不是 `B B Q Q`；**除數斷言每一臂都跑**。

### 11-4. 三句容易讀錯的（逐字沿用）

1. **夾制門檻是 1 Gbit/s，不是 10 G。** 288 條有向邊裡 **272 條宣告 `1e9`**（256 host↔switch ＋
   16 switch↔switch），只有 **16 條核心是 `1e10`**。
2. **空載迴圈週期 1000.1 ms，與①加儀器的 binary 逐位相同** ⇒ 新儀器對得上舊 ground truth。
   **但 Q 仍必須用自己那一輪量到的 `T`**，①的 1043.9 與 `Q_T64` 的 1047.3 兩個都作廢。
3. **`divisor_used_s = -1.0` 是「還沒發布過任何速率」，不是失敗。** 空載時正確。
   若它是 `0.0`，那行會讀成「用了一個 0 的除數」＝看起來像修法壞掉。

### 11-5. Q 的真正性質：**它是 bug，不是單位慣例**

`FLUC:1145` 早就寫著 `avgIn = inputOctetsDiff * 8 / interval;`，`interval`（`:1121`）是實測的，
`:1123` 有零守衛 ⇒ **量測區間、相除、零守衛三件齊全，在同一個檔往上 700 行、寫同一個欄位。**
而 `FLUC:1101` 在 MININET 下 `continue` 掉整個 counter 分支 ⇒ **兩條路從來沒有並排跑過。**

**窮舉指令**（用欄位不用函式，15 個寫入點，只有 3 個在發布速率）：
```
grep -rnE "(\.|->)(linkBandwidthUsage|leftBandwidthFromFlowSample|linkBandwidthUtilization|leftBandwidth)[[:space:]]*=([^=]|$)" src/ include/ --include=*.cpp --include=*.hpp
```
🔴 **`|$` 不能省**——`TAFM.cpp:1117` 的 `=` 在行尾、值在下一行，`=[^=]` 會給一個很有信心的少算。

### 11-6. Adam 這一輪的四個裁決

1. **磁碟**：清安全的快取（已清 344 MB）。🔴 **`~/miniconda3` 不能刪**（`p4_proxy/venv/bin/python3`
   是指進去的 symlink）、`~/.gemini/antigravity-cli` 是工具不是快取。**停用的 sanitizer build tree
   6.0 GB 仍未裁決**（`build-asan` 2.9 G／`build-tsan` 1.4 G／`build-clang` 874 M／`build-fuzz` 863 M，
   最後動過 08-18／08-13）。
2. **手冊 §4.1 指向落後 580 commit 的公開 repo**：記成已知缺陷，**不動公開 repo**。
3. **教授兩題的答案** → **下週實驗室報告**（⇒ M 有死線，S 沒有）。
4. **記憶目錄刪除**：放行那 5 個檔。

### 11-7. 我這一輪犯的錯

**把別人標好的推論升格成事實**（開機手冊寫「我**會**看到 rc=0」，我讀成量測並寫進記憶、
還稱它「本檔最完整的一例」；他們要求「先別寫進記憶」而我已經寫了）。
**驗收方升格推論，比原作者自己搞混更難抓——因為下游會信任驗收這一關。**

**選擇題的選項本身是斷言**：「~6 GB 安全」三項我一項都沒查，兩項會弄壞正在跑的東西。

🔴 **前提斷言可以「全程成立卻擋不住它要擋的東西」**：我要求 ingest 測試斷言「兩臂同一組 5-tuple
⇒ miss 率不隨負載變」。sFlow 指出**那只在規則已裝好時成立**——反應式安裝的 miss 窗長度＝安裝延遲，
而 proxy 在負載下會變慢 ⇒ miss 隨負載上升 ⇒ 偽造出「封包沒進管線」，**而 5-tuple 確實沒變**。
**必要而不充分，且它的持續成立會給人假保證。**

**今晚三個 session 各抓到我一個錯，我自己抓到零個。**

---

# §12 — 08-27 深夜（22:40–00:xx）。§11 之後的一切（**已被 §13 接續；接手的入口是檔尾 §13**）

## 12-1 機器與用量（最先看）

- 🔴 **Adam：用量快沒了，半夜可能歸零。** ⇒ 長跑一律**跑在背景 script 裡，不要跑在 agent 回合裡**
  （安裝器／chaos 在背景不吃用量；「每隔幾分鐘看一次」才吃）。
- 🔴 **通則已下達給三個 session：發現要隨時落盤。** 用量中斷／session 掛掉／context 壓縮，
  三種都會讓「還沒寫下來的」蒸發，**而且都不預警**。
- **已叫停**：`Claude memory 審查`（CLAUDE.md 草稿、KNOWN-ISSUES 指標，明天做）、
  `8/27 mainDev` 的三件讀碼工作（明天做）。
- **保留跑**：`開機手冊` 的 v8 安裝測試（VM，2–4 h）。
- **磁碟**：刪掉 `build-asan`/`build-tsan`/`build-clang` **5.2 GB**（`build-fuzz` 保留），
  剩 **8.1 GB / 92%**。四個安全檢查（指入的 symlink、跑著的行程、mtime、資料檔）全過。

## 12-2 工單 M：**6-2 退場，換指標。十個臂沒有跑。**

- pre-flight 第 1 步 ✅：`path` 會被清空（`FLUC:2928`，每次 pass 重新賦值）。**不是 replace-vs-add。**
- 🔴 pre-flight 第 2 步 ✗：比例在兩顆 binary 之間動不出可用的量。**mainDev 沒有開十臂。**
- **原因不是我猜的選擇效應（方向相反）**，是**過度納入**：見 [[api-flow-list-inflated-by-idle-timeout]]。
- **新指標＝「流建立 → 第一次拿到 path 的延遲」**（`f6cc9b1` M-quater，已放行、未跑）。
  三個儀器條件：**輪詢 ≥10 Hz 且先跑只輪詢的基線**（p95 變動 >20% ⇒ 降頻重來）、
  **`t_first_appearance` 與 `t_first_path` 分開記**（M 的效應＝**差**不是總和）、
  **`never` 是獨立類別**。預註冊區間：1 ms < 一個輪詢週期；1 s 平均 0.4–0.6、p95 < 1.0。
- **副產品**：偵測延遲＝「分身多久才看見一條新流」，**分身保真度的直接指標，本專案從未量過**。

## 12-3 工單 Q：**閘門在真實負載下通過，與擺法無關，可以用**

`Q_Q1` 整臂 180 s 真流量：**`GATE: 7/7 live, worst |measured-divisor|/measured = 0.0000%`**。
六臂的 Q 輪被 mainDev 停掉（用的是穩定長流＝我禁止的工作點，會跨兩種母體）。**這個數字留著。**

## 12-4 9/03 投影片：**四張圖已產，腳本 `plot_deck_903.py`（`216cba1` + `b9f920e`）**

`~/Desktop/NDTwin slide material/NDTwin slide material 903/figures/`
1. `page_Q_assumed-denominator.png`（實測）
2. `page_Q_gate-after-fix.png`（實測，含「本圖不宣稱什麼」）
3. `page_M_what-1khz-buys.png`（機制，戳章 NO ARM HAS RUN）
4. `page_M_dose-response.png` — 🔴 **重畫過**。原版把一個**兩小時後被推翻的模型**當預測。

- **每個數字都從 committed log 解析，解析各自 assert 自己的 yield。**
- 🔑 **這樣抓到 M-bis 一個算術錯**：閉式給 93.33%，表上印 93.6%，**其他三列逐位吻合**
  ⇒ 已由 `f32c10f`（M-ter）更正，距否證線 1.4 → **1.7 點，論證更強**。
- ⚠️ **圖上措辭**：要寫 **damped ~13×**，**不可以寫「盲」**（`mean 0.9635 / min 0.677 / 16-of-39 < 0.99` 說它會動）。
- **待補**：`8c9e841` 已 commit pre-flight readout ⇒ **13.3× 現在可以畫上去了**（畫時記得 min ratio 2.25、從未低於 1）。
- **Adam 還要的圖**：① OVS/bmv2 天花板（資料齊，`53.142 Gbit/s`）② **三層 jitter**（見 12-6）。

## 12-5 安裝手冊 B 段失敗 ⇒ 見 [[install-manual-clean-room-test]]

裁 **B**（真跑一輪 v8）。🔴 **我先前跟 Adam 說「B 段與 chaos 不能並行」要修正**：

| | 怕不怕 CPU/IO 競爭 |
|---|---|
| v8 安裝測試 | ❌ 判準是**產物存不存在**＝狀態不是時間 |
| chaos 的 **baseline 差異臂** | ❌ **兩臂共享同一個干擾 ⇒ 差異仍有效** |
| chaos 的 **三層 jitter 臂** | ✅ **會**，要安靜的機器 |

## 12-6 chaos 過夜跑：**設計定了，harness 還沒寫**

- **架構（Adam 核准）**：便宜模型（DeepSeek ＋ Muse Spark，**兩個都跑取聯集**）產生「亂搞的方式」；
  Claude 執行並寫斷言；**判定留到早上**。**不准回報「全綠」**，交付物是「N 個異常＋現場狀態」。
- 🔴 **正控制（沒抓到 ⇒ 整夜作廢）**：A-1 電源開機回成功但沒動作／缺 priority 回 400 卻仍裝上規則／
  `popen(curl)` 在 IPv6 黑洞卡 131 秒。
- 🔴 **Adam 加的主線：baseline 差異臂。** 領先 `origin/main` **646 commit**，
  `src/`+`include/` **50 檔 +8632/−1268**。**`−1268` 才是「繼承行為消失了」的地方。**
  ⚠️ 三個前提要先查：`28b8b13` 建不建得起來／origin/main 是 P4 之前的版本（只覆蓋 OVS 那條路）／
  繼承版自己就有 11 個已知缺陷（差異會同時吐出兩種）。
- **三層 jitter（Adam 的觀察引出的）**：`iperf3 UDP jitter_ms` ／ `iperf 自己回報的吞吐散佈` ／
  `分身回報的速率散佈`，**同一視窗**。三層一起抖 ⇒ 是測試床；③ 大於 ①② ⇒ 我們加了噪聲；
  ③ 小於 ①② ⇒ 我們在平滑。**沒有這個控制，現有的「分身 vs sFlow 地板」分不出
  「我們的碼加噪聲」與「資料面本來就在抖」。**
- **等待器**：讀 `bsegment.done` 的 **rc**，不只讀檔案存在（那個檔在 B 段**失敗**時也被寫了）。
- **DeepSeek 已產 80+ 條**，最有用的是它自列的一節「**哪些會像發現、其實是我自己的儀器在騙自己**」。

## 12-7 我這一輪的錯（五個）

1. **選擇效應假說錯，且方向相反**（分母是被灌爆不是被掏空）。**同一個觀察我只想了一個成因。**
2. **`pgrep` 不加 `-f`** ⇒ comm 截 15 字元 ⇒ 我一度以為 fabric 倒了，**並據此對別人宣告「lab 空著」**。
   → 見 [[put-measurement-commands-in-script-files]] 末節的更正（偽陰性比偽陽性貴）。
3. **拿轉述取代直接查證**（`lab.claim` 是唯一真實來源）。`開機手冊` 查了 claim、沒照我的話做，**他對**。
4. **格式要求偷渡事實宣稱**（要求 v8 標「今天實測」）。`開機手冊` 拒絕照寫，**他對**。
5. **「6-2 是盲的」措辭過強**，正確是「damped 13×」。**做決定同一個結論，寫報告不是同一句話。**
   而且**我先寫了報告用的那一句**。

## 12-8 Adam 的新指示（本輪新增）

- **跨 session 回報＝四段式**（要我裁的／推翻更正／交付／細節），**1、2 放最前面，不設字數上限**。
  已對三個 session 下達，**且我自己的訊息也照這個格式**。
- **DeepSeek 與 Muse Spark 兩個都用**（「又強又便宜」），不是二選一。
- **今晚排程**：B 段先跑 → chaos 接手（B 段提早失敗 ⇒ 改成並行，見 12-5）。

---

# §13 — 2026-08-28 全日（`8/27 auditor` 停工前寫，交棒給 `8/28 auditor`）

**本節是新審查員的入口。** 正本全部在 repo，這裡只寫 repo 裡沒有的：**強度分級、我的錯、在途狀態。**

## 13-1 交付與**各自的強度**（強度不同，不要並列引用）

| 結論 | 強度 | 正本 |
|---|---|---|
| **工單 Q：分母修正成立** | 🟢 **最強**——預註冊、兩個區塊、四關全過、臂內絕對檢查（鄰居負載無法讓錯除數看起來像 1.000） | `doc/audit/2026-08-28_QM-mirrored-block/REPORT.md` |
| **工單 M：代價 +0.530 s** | 🟢 預註冊主量，落在註冊的 0.4–0.6 s | 同上 §4 |
| **工單 M：效益省 51.2% CPU** | 🟡 **POST-HOC**，沒過「先寫判準再看資料」那關 | 同上 §6-bis |
| **工單 W：前 10 名約 6 具屍體** | 🟢 實測，3040 次觀察；**三個假說全錯**（含我的） | `api-flow-list-inflated-by-idle-timeout` 檔尾 |
| **jitter ＝ 收端 socket，不是網路** | 🟢 **排他性歸因**（`InErrors == RcvbufErrors` ⇒ 100% 是緩衝區滿），每個網路層 dropped 0 | `doc/audit/2026-08-28_jitter-working-point/04_ovs_result.md` |
| **bmv2 容量 430–500 Mbit（單流）** | 🟢 而且對上 08-15 那輪的 fast build 460–530 | `01_capacity.md` |
| **容量是流數的函數**（16 流合計 48 Mbit，塌 3.3×；OVS 不塌） | 🟢 有對照平面 | 同上 |
| **KNOWN-ISSUES B-2b 升級成可遠端執行命令** | 🟢 四個環節我逐一讀碼確認 | `doc/KNOWN-ISSUES.md` B-2b 增補 |

## 13-2 🔴 我這一輪的錯（**七個，形狀比數量重要**）

| # | 錯 | 形狀 |
|---|---|---|
| 1 | `pgrep -axf` 把活的 kernel 報成死的，我據此跟 Adam 說「kernel 死了」 | `-x`+`-f`＝整條 cmdline 相等 |
| 2 | 讀 `28b8b13` 卻回答關於 `origin/main` 的問題，**還發「急件」指控 mainDev 錯** | **讀對原始碼、問錯 commit**，而我拿「我親自驗證過」當權威 |
| 3 | 用四捨五入後的值去糾正一個**精度**宣稱 | 鈍化的輸入不能稽核精度 |
| 4 | 叫人「扣掉共同基線」算 CPU | 那是把整機 CPU 當前提，實際量的是單一行程 |
| 5 | 叫人先用現成資料答 jitter | **那批資料裡沒有那個現象** |
| 6 | 給架構稽核的正控制**不在比對範圍內**（`p4_proxy/` 在 baseline 不存在） | 我出的控制我沒查 |
| 7 | 🔴 用 `git ls-remote` 成功就裁「可以推」 | **讀的通道去測寫的問題** |

🔑 **四個（2/4/5/6）是同一件事：我對我沒有看過的資料或程式碼做推理。**
🔑 **而 #7 那一族今天出現五次**：`ls-remote` 帶憑證所以成功≠公開／讀≠寫／`@{u}` 無 upstream 時 `wc -l` 給 0／`head -1` 抓到空行／`&&`/`||` 把三值 exit code 壓成二值。
⇒ **共同解法：空結果與零要分開；讀的通道不能回答寫的問題。**

## 13-3 🔑 本輪最可轉移的三條（都已進記憶）

1. **最下游的瓶頸會遮住它上游的一切** ⇒ 對上游歸因前先證明收端不是瓶頸（[[instrument-must-not-mimic-its-own-finding]] 第五式）
2. **照假設清單設計的判別器，找不到不在清單上的那一個**——找到答案的是**記帳**（讀每一層的計數），不是任何一個假設。我的 H1/H2/H3 全錯，而 H3 那一支只保住了「不要把 null 當失敗」
3. **保護的失效時機與它要防的事件重合**（[[failures-that-report-success]] 新一族，三個實例）

## 13-4 在途：四個 session 的狀態

| session | 在做什麼 | 我給的判準 |
|---|---|---|
| **bmv2 performance** | 14 篇文獻審核（`~/Desktop/NDTwin slide material/paper/bmv2 performance/`） | 🔴 **先讀 `3725530.pdf`（TOMACS 2025），它可能讓 workshop 想法直接結束**；不准寫「文獻裡沒人做過」，只能寫「這 14 篇裡沒有」 |
| **8/27 mainDev** | 回溯掃描：哪些現有結論**沒排除「收端是瓶頸」** | 判準＝該輪有沒有讀過 `RcvbufErrors`；沒讀過就標「收端未排除」。**不要重跑，只讀既有資料** |
| **開機手冊** | 🔴 **卡在 Adam**：`ndtwin-lab/NDTwin-Website` 他是唯讀（`permissions.push: false`） | bundle 在同一顆磁碟，**擋不住機器故障** |
| **無狀態tester** | 跨 repo wire 相容性稽核（7 個兄弟 repo 誰在讀改掉的欄位） | 只讀不動；`~/Energy-Saving-App` 有未 push 修改 |

## 13-5 🔴 尚未解決／還在權衡的

- **workshop 論文**：我的立場是「①build 不可複現最有力」，**但我只讀過 14 篇裡的 6 篇，沒讀 TOMACS**。⇒ **這是待證的立場不是結論**，而且我明確告訴那個 session 可以推翻我
- **H1a/H1b 未分離**（htb vs OVS datapath）——**但已降級成不重要**，因為兇手是第四層。**R-1/R-2 的前置是「先解收端瓶頸」**，見 `749a1fe`
- **`ovs-bandwidth-ceiling-measured` 的 53.1 G 標了「範圍待證」**——核心鏈路也是 `bw=1000`，跨核心路徑未驗。**是待證不是已否證**（mainDev 編輯錯檔案所以沒驗到）
- **chaos harness**：DeepSeek 的行動面＋Muse 的 oracle 已交付並經我複審（`doc/audit/2026-08-28_chaos-harness/`，含**兩個必修的偽陽性**）。**還沒組成可跑的東西，第一次實跑要 Adam 在場**

## 13-6 ⚠️ 矛盾與被推翻但可能沒收乾淨的前提

- 🔴 **「baseline」今天指過三個不同 commit**（`28b8b13` fork point／`origin/main`／`3367d0e9` 那顆 binary），三個人各對一部分。**看到「baseline 如何」而沒指名 commit 的句子，一律當作未定案**
- 🔴 **`doc/2026-08-15_bmv2-performance-report.md` 標題寫「~170 Mbps 的成因」，而 170 是文獻值不是本機值**——檔案內文第 50 行自己更正過，**但標題沒改**
- **「撤回沒收乾淨」今天五次、三次是我** ⇒ 讀任何結論時，**先 grep 它的關鍵詞看有沒有更新的版本**

## 13-7 建議 `8/28 auditor` 先驗證的（開哪個檔、看什麼）

1. **`.test_run/lab.claim`** — 誰持有、`exclusive_cpu` 是什麼。⚠️ **今天證明過這個檔會過期**（mainDev 寫著 `CPU free again` 而正在跑 10 個 burner）⇒ **配 `uptime` 與 `pgrep -cf burner` 一起看**
2. **`.test_run/binaries/*.provenance`** — 三顆 binary 的 `commit=UNKNOWN` 是**量測結果不是佔位符**，別「補上」
3. **`pgrep -af 'simple_switch_g[r]pc'`（不要 `-x`）** — 看 fabric 跑的是 `/usr/local/bmv2-fast/` 還是 stock。**兩顆差 12–18×**
4. **`gh repo view ndtwin-lab/NDTwin-Kernel-P4 --json visibility`** — 它是 **PUBLIC**，而 `p4/main` 反映的是私有那個。**不要看本地 ref**
5. **`doc/audit/2026-08-28_chaos-harness/03_auditor-review.md`** — chaos 跑之前必修的兩個偽陽性


## 13-8（08-28 深夜追記，bmv2 文獻 session）：結案＋一個 commit 掛名事故

**文獻審核已結案**：14/14 篇讀畢，交付在 `doc/audit/2026-08-28_bmv2-literature-review/`（RELATED-WORK／GAP／VERDICT）。§13-5 第一條可以劃掉：**TOMACS 沒有擋掉 workshop 角度**（它自己就沒控制 build 變數；VT 的 TDF 成本正比於效能缺口 ⇒ 我們的 12–18× 把它除以同倍，互補不對撞）。唯一推翻 8/27 auditor 的是措辭：「已發表數字不可複現」→「**互相不可比較**」（ICNCC '23 有一句質性 build 揭露＋版本 1.15；build flags 0/9、對照 0/9、固定拓樸流數軸 0/9）。待裁在完成報告裡（投稿前置實驗 vs 工單 M 順位等四項）。

🔴 **commit 事故（[[two-writers-one-worktree]] 實例）**：`5ae3623` 掛我的 message（「VERDICT: add the can/cannot-support section」）但內容 95% 是**另一個 session 的 raw 遷移**——162 檔、10.9 萬行刪除＋各 raw 目錄的 `.gitignore`。成因＝它在我兩個 commit 之間把遷移 stage 進共用 index，我的 `git commit`（未帶路徑）整鍋收走並推到 p4（公開）。**證據沒丟**：本機 `audit-raw` 的 `f899aeb` 先保存了那批 raw——**但 f899aeb 還沒推**（`p4/audit-raw` 停在 `4ffe9c5`）⇒ 公開 repo 現況＝刪除可見、保存不可見。**我不動已推歷史、也不代推別人的 audit-raw**；請原 session 確認 f899aeb 定稿後自推，或 Adam 裁史實修法。教訓：**共用 worktree 上 commit 前先 `git diff --cached --stat`**，`git add <path> && git commit` 不保證只收你 add 的那些。

（次要：我這輪的 `raw/hits_*.txt` 不在 audit-raw、只在本機——可由已 commit 的 `sweep_keywords.sh` 重生，非不可再生證據。）

> ✅ **08-28 傍晚 `8/27 auditor` 實測結案：上面那個 🔴 已經過期，不要去追。**
> `f899aeb` **已推兩個遠端**，公開 repo 的 `audit-raw` head 就是 `f899aeb198a…`（走 `gh api` 查的，不是本地 tracking ref）。
> 抽驗 `5ae3623` 刪掉的三個檔（`2026-08-25_large-scale-concurrent/raw/B1/{load.jsonl,meta.json,period_1.json}`）
> 在 `f899aeb` 上**都在**；該分支現有 **2,920 檔**。⇒ **刪除與保存都可見，帳是平的。**
> 🔑 這條本身是個教訓：**「🔴 待處理」寫下之後不會自己變綠，而問題會自己解決。**
> 交接檔裡的紅字要嘛附「怎麼查它還成不成立」，要嘛在交棒前重查一次——
> 這條若沒重查，新審查員會花時間追一個已經沒有的問題。同 [[disclosure-is-not-downgrading]] 的鏡像面。

---

## 13-9 🏁 Adam 的兩個裁示（08-28 傍晚，`8/27 auditor` 停工前最後一件事）

1. **順位：投稿前置實驗優先，9/03 用現有數據。**
   （我推薦的是反過來，他裁了這個；他的裁示算數。）
   ⇒ 9/03 的內容**凍結在現有的 Q／M／jitter／ceiling 四條**，不等新數字。
   投稿前置四項＝單 switch 隔離工作點、完整封包大小掃描、中間流數 2/4/8、補 n。
   ⚠️ **他明示接受的代價**：9/03 那天講「九篇論文都不報 build」時，我們自己的 bmv2 數字仍是 n=1–2。
2. **公開範圍：`GAP.md`／`VERDICT.md` 維持公開，不特別處理。**
   （含依成本排序的投稿角度。公開時間戳對先占有利，且已公開，撤下來 git 歷史還在。）

✅ **已解除（08-28 `開機手冊`）：這台機器上一直有 matplotlib**，在 `.plotvenv` 裡（3.11.1），圖已重畫並驗過裁切。**下面這段的前提是錯的，保留供對照。**
🔴 ~~9/03 的硬阻塞（我沒解決，交出去）：這台機器上沒有 matplotlib。~~
python3.13、三個 conda env（ntg-env／ryu-env／te-env）、`test_env`、`p4dev-python-venv` **全部 import 失敗**，
~~而 `~/.cache/matplotlib` 證明它今天跑過 ⇒ 是後來消失的，不是從來沒有。~~
🔴 **這個推論錯在最後一步（08-28 更正）。** 前半是對的：`~/.cache/matplotlib/fontlist-v3.11.0.json`
確實證明**某一個** matplotlib 跑過（版本號 v3.11.0 正好對上 `.plotvenv` 的 3.11.1）。
錯的是「而我找不到它 ⇒ 它消失了」——**找不到的原因是它埋在兩層目錄底下、而且沒被 activate 過**
（`~/Desktop/NDTwin slide material/NDTwin Slide material 820/.plotvenv`）。
🔑 **快取只證明「有東西跑過」，不證明「那個東西現在不在」——中間那步是搜尋，而搜尋會漏。**
⇒ 通則：**用「我找不到」當作「它不存在」的證據之前，先問這個搜尋方法看不到什麼。**
`compgen -c`／`which`／列舉已知 env **全都只看 PATH**，而沒 activate 的 venv 不在任何 PATH 上。
影響：`plot_deck_903*.py` 現在畫不出來，而 `de17866`（給 ceiling 圖補上 build 身分）**只改了腳本、PNG 是舊的**。
`NDTwin slide material 903/figures/page_bandwidth-ceiling.png` 相對腳本已過期。
⇒ **9/03 之前一定要有人把 matplotlib 裝回來並重畫**，否則簡報上那張圖仍然是「不報 build 的 bmv2 數字」。

## §14 08-30 auditor 兩個新失誤（OvS 對照輪簽收案）

1. **我簽收了一個與處理組不可分辨的「陽性對照」**——因為不可分辨性有被誠實揭露（§3 寫明
   shaped 954.77 vs unshaped 955.75），我把它當成「範圍限制」收掉。**錯**：後來證實七臂同 config、
   「對照」＝第七個 replicate。判準補上：**不可能不像處理組的對照不是對照，是 replicate；
   揭露不能把零鑑別力升級成 scoping**。「帽源不可分辨」該觸發的問句是「那這個對照到底控制了什麼？」
   ——我沒問。（[[controls-decide-what-you-learn]] 的審查端鏡像）
2. **我把對不上的 provenance identifier 降級成「標示混亂、不是 blocker」**——`ca4de8ae` 對不上
   現行檔任何一種 hash，我驗了 kernel repo 副本==HEAD 就結案「byte-exact 由 git 證成」。
   事實：**那個對不上是整輪工作點錯置的線頭**（實跑的 topo 在 NTG repo，我驗的副本根本不是 fabric
   讀的檔）。判準：**一個什麼都指認不到的 identifier 是「量測身分」警報，不是文書錯**；
   「還原正確」與「還原的是受測物」是兩個宣稱（[[claim-verb-decides-the-evidence]]）。
   救回這案的是我把它退回去要求指認，而不是我自己的判讀——問對了問題、下錯了註腳。
3. **派工單引了三顆 rebase 前的 sha**（08-30 夜）——批次 push 的 fork 手術改寫了歷史，我在
   手術「後」發的 ledger 派工單仍引手術「前」的 `dff87f9`/`db02d45`/`e29424e`；agent 用
   patch-id 對出真身 `4ee086f`/`87d272f`/`a7ab17d`。害處放大器：舊 sha 被 archive tag 掛著
   ⇒ `git log -1` 照樣 resolve，**「sha 找得到」≠「sha 在這條歷史上」**，判準是
   `git merge-base --is-ancestor`。通則：**歷史改寫之後，記憶、派工單、文件裡的每顆 sha 都是
   嫌疑犯**——[[cited-line-numbers-are-not-evidence]] 的 sha 版。
8. **看到「NOTHING PUSHED (freeze)」，我沒查凍結的理由就規劃並下發 push 指令**（08-31 午）
   ——兩個 session 的交接文件都寫著那句，我讀成「過期的保守預設」。實際理由是投稿包的
   歷史仍在該線上（poster 首 commit 是已推 ref 的祖先），而**攔下它的不是我的判斷，是 Adam
   一小時前口述進 CLAUDE.md 的「diff 暴漲先查」**——換句話說，那次沒出事靠的是運氣加新規則。
   🔑 判準：**看到跨 session 一致的保守預設，先找它的理由，不是先找解除它的理由。**
   （與 [[the-clean-version-is-the-one-to-recheck]] 同源：我對「為什麼會這樣」的好奇心
   在方便的方向上會自動關掉。）另一半教訓在正面：掃到東西之後我**先定性再行動**
   （查 `9c8c0e6` 是不是既有 ref 的祖先），沒有急著改歷史——那一步是對的。
7. **把「git checkout -- 撤銷變異」寫進兩份派工單，而 bundle 全是未 staged 改動**（08-31 晨）
   ——該指令復原的是 index（=1208d22），會**把整份 fix 靜靜還原成修之前**，不是撤銷變異。
   成因＝把「變異目標是 committed 檔」情境的慣例搬到未 commit 的樹上，沒驗 stage 狀態。
   seatbelt 執行 agent 自行識破（改校驗和備份），behavior agent 急件攔下。教訓：
   **復原指令的語意取決於基準住在哪一層（工作樹／index／HEAD）——寫復原步驟前先問
   「這棵樹的乾淨版在哪裡」**。[[the-clean-version-is-the-one-to-recheck]] 的字面版：
   我以為的乾淨版（index）正是要覆蓋掉的東西。
6. **限定詞沒有跟著主張過河**（08-30 深夜）——FINDING-07 機制我對 Adam 寫的是「機制推測
   （待驗）」，**對 mainDev 的 T-15 派工輸入卻寫成直述句**（「API 收了一個 exact-match 表
   結構上編不進去的 priority 欄」）。.p4 一讀就推翻：路徑上無 exact 表，真相是 LPM 無此欄。
   同晚 903 模板警告 3 才寫過「片語化之後更容易掉限定詞——限定詞跟著數字走」；**派工文字
   是同一條規則的適用域**，hedge 要跟著主張走過每一次轉發。救場的又是收件人的查證習慣。
5. **把別人草稿裡的預期值抄進驗收單**（08-30 深夜）——mainDev COMMIT-PLAN 初版寫「讀
   `Ran 12`」，我照抄進驗收佇列；正確是 **`Ran 20`**（gtest filter 連帶收 8 顆既有
   ControllerTest，12 只是新增數），路徑也錯（`./build/bin/` 非 `./build/tests/`）。
   照單跑會**把一次正確的通過讀成失敗**。[[verify-the-purpose-not-the-mechanism]] 早寫著
   「交接節的『預期值＋指令』要分開驗」——**驗收單上每個預期值要嘛自己導出、要嘛明標
   「轉抄未驗」**。是 mainDev 自己抓的，不是我。
4. **派工單把 compact 摘要裡的「已完成」當事實**（08-30 夜，同晚第二例）——我寫「PEP668（4 處）
   與 cd（4 處）先前已 systematic pass 修過、只需複核」，agent 三路查證（`git log --all --grep`
   ／content/ 全樹 grep／working tree 乾淨）＝**PEP668 0/4、cd 1/4，pass 根本沒發生**（可能是
   壓縮把「規劃」記成「做完」，或修在別處未達 website 樹——未追）。同晚 seatbelt 包的 A-5/A-6
   是鏡像方向：帳本說 OPEN 而其實已修。**兩個方向合起來＝狀態宣稱（不論來源是摘要還是帳本）
   在派工前都要對磁碟重驗**；救場的是派工單裡那句「前提可能過期，先查證再動」——它兩次都被
   agent 執行了。[[the-clean-version-is-the-one-to-recheck]] 的派工版。
