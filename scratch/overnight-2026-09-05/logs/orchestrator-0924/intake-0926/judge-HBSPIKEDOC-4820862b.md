# 判決：`P4-HB-SPIKE.md`（分支 `docs/p4-hb-spike-0926`，`4820862b`，base trunk `580767a8`）

（opus-judge 最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿，此處保留裁決、blocking 全文與 notes 要點。）

## 裁決：**MERGE AFTER FIXES**（2 條 blocking，其餘是 note）

數字本身幾乎沒有錯（60 個逐 cycle 值、所有 min/max、20 份剪線快照時戳、26 列普查表逐欄、78 份 sniff、24 份 `90_down.txt`、三份 log、判官報告、兩份 SUMMARY、每個程式行號引用都對過）。問題在**解讀**。

### Blocking 1：相位鎖的後果沒推到底（§1.2、§2.3 表末三列、§5.1、§5.2）
相位鎖成立（cycles 2–10 的 down_s 在 14.197–14.382 s，剪線落在最後一次聽到之後 φ≈0.62–0.80 s；cycle 1 來自 `S_heartbeat_spike.sh:536` 的 `sleep 1`；迴圈碼 :548-561），標 INFERRED 也對。後果：最壞相位 φ→0 時報告層級約 15 s，W 層級上確界 15＋5＝20 s，再加讀檔／`_notify_link` HTTP／kernel，**可能超過 20 s**。§5.2「只剩 kernel 反應時間的餘裕」與 §1.2、常數算術矛盾；§2.3 替 H1 留了「沿用相位鎖迴圈就會過」的路（那 0.7 s 是量測迴圈的相位，不是系統性質）；watchdog 是 `wait(5)` 後才跑 pass（`topology_manager.py:2050-2053`），同一 run 的 n 個 cycle 不會均勻取樣 (0,5]。工單要的是「分布」，這次只交單一相位（up 的相位更被 15 s＝3 period 規則加立即復原鎖在送出後約 0.15 s）。要改：(a) §5.2 改成「最壞相位下常數本身已用完 20 s，讀檔／HTTP／kernel 會使其超過 20 s；≤20 s 不是保證」；(b) §2.3 與 §5.2 補「相位鎖迴圈的 H1 通過不代表最壞相位通過」，H1 必須刻意取樣 φ→0（`started_mono`＋5k 推算下一次送出）或均勻隨機化剪線前延遲並記錄 watchdog 相對相位，否則只能寫「φ≈0.7 s 時」；(c) 19.382 s 與「down 13.275–14.382」加註相位鎖、非最壞、非分布；(d) 明寫「分布」只以單一相位交付，是否補一輪去相位鎖由 orchestrator 決定。

### Blocking 2：`up_s` 不是報告層級，W 的復原上界少算 0.5 s（§1.1、§2.1、§2.3、§5.1）
`hb_watch.py:185-196` 回傳 `max(last_heard_mono) − t1`＝daemon 接收時戳；報告在聽到後約 0.5 s 才寫（`ndtwin-lab:764-765` `REPORT_MIN_INTERVAL_S = 0.5`、`:1335-1344`；`R1/12_report_first.json` last_heard 與 written 相差 0.5006 s）。正確：報告層級復原約 5.31–5.41 s（OBSERVED＋0.5）、常數推得 (0.5, 5.5]、W 層級上界 ≤10.5 s（另加 pass 耗時與 kernel）、依 OBSERVED 最大值約 10.41 s。down 不受影響。

## Notes（要點）
3. 「沒觸發裁決 4」的範圍：文件用的是段 S 的操作化（心跳幀到達主機），字面卻寫成裁決 4 原文；372 幀非心跳幀未定性、沒有心跳關閉對照窗。
4. p4runtime×2、flowcache/solution「表空只有 default action」放在 OBSERVED、與同檔「no pipeline loaded」未調和；推論鏈要寫明並標 READ/INFERRED。
5. §3.3 第 5 點「沒有 controller」對 17 臂（mode ndtwin，proxy 開 StreamChannel）不成立。
6. binary 指認缺 bmv2-fast、p4c、tutorials（至少明寫「未記錄」）。
7. sniffer 視窗 mtime 數字不在 audit-raw、不可重現。
8. 「raw 已公開」沒有公開性證據（改「已提交到 audit-raw」或附未認證 URL 查證）。
9. 標記定義與實際用法不一致（彙總值、READ 段含「跑過」）。
10. 「每次都在 15 以內」是量測設計保證、非發現。
11. 相位鎖的兩條「raw 對得上」無鑑別力；真正支持的是 cycles 2–10 的集中度＋迴圈碼。
12. §4「仍然開著」不完整（r7b finding 2/3/4、r5 finding 6/7）；另 census 期間 claim 沒有 `measuring=`（detect 收尾 retract 後 census 不再宣告）。
13. 小數字：「至少 34 s」→「約 34 s／大於 33 s」；兩次 run 各送 336 幀（60 幀在 netem 丟、276 進 pipeline）；「只有 eth0」只證明幀都在 eth0；56–82 分鐘出處是判官、現行檔頭算得 67–93；sniff JSON 未記 session。

## 建議補跑（判官）
去相位鎖的偵測（剪線前 U[0,5) 隨機延遲或 φ 掃描含 φ≈0.05 s、復原前也隨機）；真正的報告層級 up；兩個偵測器的 live 陽性對照；每臂心跳關閉對照窗；記錄 bmv2／p4c／tutorials 版本；detect 鑑別力對照（不剪線 ≥20 s、只剪單端）；多交換機包裝的 multicast。

---

# 複審（`4820862b` → `1a11e0d0`）：**MERGE**

（同一位 opus-judge；要點。）兩條 blocking 皆已修好並逐項核對（cycle 2–10 的 18 個值寬 0.185 s、中位數 14.2965；R2 `12_report_first` 差 0.50056–0.50064 s）；notes 3–13 大致已處理。新 note（不擋）：
1. φ→0 的做法要精確：實際送出比 `started_mono + 5k` 晚 1.7–7.0 ms ⇒「在實際送出之後至少留 20–50 ms 再剪」，並逐 cycle 用 `t0 − last_heard_mono` 驗證 φ；去相位鎖那一輪與 H1 都應把 `t0a`／`t0`／`t1` 的 CLOCK_MONOTONIC 絕對值寫進 raw；以現行剪法兩端都生效的 φ 最小約等於 cut_tc_s（0.06–0.1 s），「趨近 15 s」是極限值。
2. 「watchdog 同一 run 內大致固定」標 READ 其實是推論（漂移＝各次 pass 耗時總和，含轉態 pass 的 `install_initial_routes`／`_notify_link` HTTP，未量）⇒ 改標 INFERRED、寫成條件句。
3. §2.4「orchestrator 已決定」需附出處。
小瑕疵：§1.2「不是心跳比較快或比較慢」只對剪線方向成立；§2.3 最壞相位列漏「pass 耗時」；§1.1「≤15 s」嚴格是「≤15 s＋輪詢」；§2.2 中位數精度混用（14.2935、4.8675、0.0715）；§3.2「取自 bmv2 的 argv」出處是 READ（manifest 啟動指令）。
公開性：舊的 push log 沒記錄讀回指令，證明不了「未認證」⇒ orchestrator 其後補了 `public-verify-20260926T063944Z.log`（指令逐行印出：`GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c core.askPass= ls-remote https://…` 兩 repo 皆讀回 `1fafa3a0`；無憑證 `curl` 兩 repo `/tree/audit-raw` 皆 HTTP 200）。

---

# 第三版（`c708f558`，去相位結果補節）：**MERGE AFTER FIXES**

（同一位 opus-judge；要點。新增數字全部從 raw 重算吻合：R3/R4 各 31 欄、逐列 CLOCK_MONOTONIC 重算 0.001 s 內、§2.4.2 13 列×2、§2.4.3 分箱、覆蓋、對照、報告檔。）
- **Blocking 1：run 4 cycle 8 的復原是量測假象。** t1a＝48770.853069、t1＝48770.934670；被剪兩向在 48770.92199 已被聽到（t1a 後 69 ms、t1 前 12.7 ms——netem 已拿掉，幀通過）；t1 是 tc 返回後另起 `now` 行程量的，晚於實際復原；`up_detail` 要求「在 t1 之後聽到」（`hb_watch.py:626`）⇒ 丟掉這一輪、改等下一輪 ⇒ up_s 4.988、up_rpt_s 5.488 是假的；第一份顯示兩向 heard 的報告其實距 t1 0.488 s。只有 c8 受影響。排除後：合併 up_s 0.070–4.864、up_rpt_s 0.571–5.364（最大值 run 3 c10）；W 層級實測最壞 10.364 s（常數 ≤10.5 s 不變）；run 4（n=19）up_s 0.070／1.790／4.613、up_rpt_s 0.571／2.290／5.114。§4.4 補 spike 缺陷：復原視窗 (t1a, t1] 內聽到的幀被丟；t0、t1 用另一行程量，比 tc 實際生效晚。§5.1 說 H1 可沿用這套工具 ⇒ 缺陷會被帶進 H1，必須寫明。
- **Blocking 2：** 「run 3–4 raw 只在主 checkout」已過時 ⇒ 引 `push-audit-raw-e812cf9c.log:12-15`（未認證讀回 e812cf9c）；對 e812cf9c 重做 CHECKED sha256，log3/log4 是否在內照實寫。
- Notes：3「現行兩步剪法達不到 φ→0」寫太滿——這次是 sweep 設計刻意避開（`SWEEP_FIRST_S=0.05`、`SWEEP_LAST_GAP_S=0.15`），真實故障 φ→0 可達；4 t0／t1 比 tc 實際生效晚約 20–40 ms，從「兩端都斷」算起實測最壞 φ 約 0.10 s、W 層級約 19.90 s；「A 端／B 端」不是 cut_tc_s 的分解；5 H1 判準：φ→0 時預算是 0 s，應以「20 s＋實測 pass／讀檔／HTTP／kernel 耗時」判，並在 tc 實際生效處打時戳、標出剪線與復原視窗內被聽到的幀；6 sweep 精度檢查只驗 t0a 準到 1 ms；7 決定出處應引 log3:2、log4:2；8 小處（run 4 c15 不是 run 1–2 的同一相位、§4.1 行號要標 commit、§5.1 對照不是兩端都剪）。
