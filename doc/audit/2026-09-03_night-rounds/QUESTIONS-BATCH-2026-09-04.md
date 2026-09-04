# 累積給 Adam 的裁決（一次問）— 09-04 下午，auditor

## 要裁的
1. **N22 Q1（#85）`get_cpu_utilization` 等 body 出現非 IP key `dpid:<n>`（值 -1）可以嗎？** (a) 照現在（建議）；(b) 省略那台只留 WARN。今天的載入端會拒絕沒 IP 的檔，正常測試看不到。
2. **N22 Q2（#85）`get_power_report` 的 `power_consumed: -1` 要不要寫進 API 文件？** (a) 補一行沿用 §12/§13 的「-1 = unavailable」（建議）；(b) 不補。
3. **N22 Q4（#1）`502 still_present`／`unverified` 進 API 文件 §33？** (a) auditor 現在改（純文件）；(b) 交 mainDev；(c) 不改。該節現在叫使用者去看一直是空的 kernel log。
4. **#79 `ndt` 的 claim／pids 是 per-checkout，多 worktree 互相隱形。今晚怎麼防？** (a) 程序：你說開跑後我停派工、agent 一律不碰 lab、開跑前我確認所有 wt-* 沒 claim（建議；修法排測後）；(b) 現在派人把 claim 移到與 checkout 無關的位置（動到今晚要用的工具，還要一輪閘門＋重裝 helper 無關但 ndt 會變）。
5. **#88 `findSwitchByIp` 等五處 `ip.front()`（與 #85 同型、同一個「現在的 trunk 不可達」判定）。** (a) 測完再修（建議）；(b) 現在修＝測前再重建一次 binary（+50 分鐘）。
6. **今晚測試的範圍與時間**（自由填）：哪些平面（OVS／P4／兩者）、P4 幾台 host（`ndt up p4 N` 會把 `host_count_override` 改成 N，現在是 4、committed 是 128）、開哪些 app（四個 app 從沒對著活的 kernel 用過）、P4 tutorial exercise 算不算今晚、幾點開跑。
7. **P4 tutorial exercise（那個 session 14:10 已把材料 commit 進 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/`，26 支程式 25 支編過，三個擋點都是環境）**：(a) thrift 9090 被你的 claude-usage dashboard（pid 1685271，`cli.py dashboard`，09-03 起）佔住——tutorials 的第一台交換機固定用 9090 且無旗標可改；`ndt up p4` 用 9091–9100 不受影響。今晚要跑 tutorials 的話那個 dashboard 要先停或搬 port（你的行程，我不動）。(b) `make run` 在這台必定失敗（sudoers `secure_path` 拒絕 `sudo PATH=…`），要改用它寫的 `run_exercise.sh --go`，而那需要互動式 sudo ⇒ 只有你能跑。(c) 今晚先跑哪一支？W-1 的建議順序：`source_routing`（沒有 `ipv4_lpm` 表，最快看到 proxy 在 p4info 找不到表時做什麼）→ `basic`（基線）→ `flowcache` → `p4runtime` → 其餘。
8. **`~/tutorials`（對照樹）現在不乾淨**：`exercises/basic/basic.p4` 有 3 行純註解改動（HEAD `c80d83e`）＋兩個 `.vsix` 未追蹤檔；`2026-08-27_p4guide-v10-tty/PREREG.md:99` 曾斷言它 `DIRTY_COUNT=0`。是你改的嗎？(a) 我不動、文件記「誰改的不明」；(b) 你 `git -C ~/tutorials checkout -- exercises/basic/basic.p4` 還原後再當對照組。

## 只需知道、不用裁
- 今晚會看到的三件事（N22）：OVS 剛裝的 flow 等下一次輪詢（3–13 s）才進表；`delete_group/meter` 交換機沒刪掉回 502 `still_present`、讀不回來回 200 `unverified`；kernel.log 對已不存在的 bridge 關機會先印一行 `Command failed (exit code 2)` 再印正確的 INFO（N19 Q3，不是新缺陷）。
- 如果今晚跑 Network-State-Recorder：它的 stop script 用 `pgrep -f`（#43），會連坐殺掉同一個 shell 的東西——不要從跑測試的那個 shell 收它。
- `.test_run/run_ab.lock`（0 B，09-02 的 paired-AB harness 留下）與 `bsegment.done`（08-27）是舊 harness 的殘留，不影響 `ndt`；我沒動。
- 主 checkout 21 個未提交檔裡只有 `host_count_override` 會改行為（128→4，是 `ndt up p4 4` 寫的）。
