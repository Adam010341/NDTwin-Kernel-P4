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
