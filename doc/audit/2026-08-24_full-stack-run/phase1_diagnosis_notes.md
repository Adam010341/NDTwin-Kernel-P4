# Phase-1 診斷筆記（隨 ×10 進行中累積；raw 見 raw/rate_boot*_ryu.log）

[Co-developed with claude code -- Adam]

## 到 boot 2 為止的失敗機制圖（OBSERVED，全部來自已歸檔 log）

1. `EventOFPStateChange` connect 數 = **10/10**（boot1、boot2 皆是）——「switch 沒連上」
   不成立；mid-wait 的「5 of 10 … Not yet connected」是暫態快照（健康 boot 也出現過
   3/10，bisect_40 log 同款）。缺席集合兩次不同（{3,5,6,9,10} vs {1,2,3,5,9}）。
2. t+300 waiter 收到 **10 of 10 online** 並印 install 行、`Loaded static topology` 也印了
   ——但 `/ryu_server/all_destination_paths` 回應**全程 158 bytes（空）**；健康 boot 裝完
   是 1,110,641 bytes。⇒ **walk 沒有產出任何 path**。
3. `/v1.0/topology/links` 全程 109 bytes（空）⇒ **LLDP link discovery 一條邊都沒發現**
   ——與 loaded-fp cell C 的「10 switches connected / 0 link events」同源。walk 對無邊圖
   自然無 path 可裝 → 不轉發 → 無 punt → host 學不到。
4. `Switch entered:`（IntelligentRyu 的 EventSwitchEnter handler）**只跑了 2 個**（健康=10）。
   gate(40s)+waiter(300s) 睡在第一個 handler 裡、同 app 事件序列化 ⇒ enter queue 被堵
   ≥340s，是**次生症狀**（settle-gate REPORT 候選(1) 的實證），不是禍首——因為 links
   是 Switches app（不同 app、沒被堵）該發現的。
5. **backoff 除罪（code-read）**：`intelligent_router.py:262-330` 的 sweep 修補在
   `if _lldp_backoff:` 的 else 分支內安裝，defaults boot 跑的是 stock `lldp_loop`。
   與 mainDev 的 C-2 更正一致。

## 開放問題（×10 結束後 live 診斷）

為什麼 stock link discovery 會整場零產出？候選：
- Switches app 的 PortState 沒被填（無 port ⇒ 無 LLDP 可發）——查 `/v1.0/topology/switches`
  的 ports 欄是否為空
- LLDP 有發但不回（OVS datapath/veth 狀態）——`timeout 5 tcpdump` 抓 inter-switch veth
  （AppArmor 擋 kill，要用 timeout 自然退出）；或 `ovs-ofctl dump-flows` 看 punt 規則
- packet-in 半死的控制連線——`ovs-vsctl show` 的 is_connected、`ss -tn :6653`
- 對照同一台機器上為何 08-22 上午 11/11 全綠、08-22 14:5x 之後開始間歇失敗：
  嫌疑=系統資源/狀態漂移（OVS db、veth 洩漏、uptime），e44e956 時間線已被 11/11 排除

## 預先押注（寫於 attempt 3 結果出來之前）

以 ×10 的 0.6 失敗率計，連續 k 次健康的機率 0.4^k：3 次=6.4%、5 次=1%。
**押注：連續 5 次探針 attempt 健康（p≈1%）才把「儀器化開機行為不同」（觀察者效應
／×10 窗與現在之間的系統漂移）當活假說**，屆時先跑 3 次無儀器開機重量基率再繼續。
註：探針在開機中每 5s 打一次 links REST——與 ndt 收斂 spinner 本來就在做的同種負載
（失敗 log 裡整場都是 2s 節奏的 switches/links/paths GET），不是新增擾動類型。

## 我自己踩的（記下防重犯）
- wedge_spy 第一輪：pid 從 up.out 抓（probe 當下還沒 flush 到 pid 行）→ 撲空、dump 沒拍。
  修=從活的 ryu.log 的 `(PID) wsgi starting up` 行抓＋pgrep 後備。
- 監看第二輪：`tail -F` 預設回放末 10 行 → 舊的 `WEDGE CAUGHT`/`done` 被我當成新事件、
  monitor 即刻自殺，且我一度誤判「boot 沒發生」。**freshness 陷阱的 monitor 版**：
  盯 append 檔一律 `tail -F -n 0`。

## ⚠️ phase 3 收尾必做
five_tuple_live.sh 重跑會寫回**它自己的目錄**（覆寫 e5931fa 已 commit 的證據 working copy）。
phase 3 done 後：`cp` 重跑的 five_tuple_live.txt＋raw/*.json 進本目錄 raw/（p3_ft_ 前綴）→
`git checkout -- doc/audit/2026-08-24_five-tuple-live/` 還原原證據。這正是 C-1 族、
run-me 腳本互跑時的新變種：**別人的 run-me 腳本的輸出目錄是它自己的證據目錄**。

## 行政

- 每次 monitor 喚醒都要續 claim（30m TTL，review-0824）
- monitor bnfu61csc 於 ~13:22 到壽，屆時重掛
- 對 ndt 的觀察：give-up 前的 convergence spinner 約 400s，加 verify ≈ 414s/失敗 boot
