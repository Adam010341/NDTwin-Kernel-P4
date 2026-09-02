# 09-02 夜間確認缺陷總表（累積中）

只收 **CONFIRMED**——有證據檔、有對照組、說得出重現方式的。假設與待查不進這張表。
每一條的證據路徑相對於 repo 根目錄。

## 嚴重（會讓人根據錯的東西做決定）

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 1 | **`/ndt/delete_group_entry` 在 OVS 上是無聲的 no-op**：回 `200 {"outcome":"deleted"}`，而 group 還在交換機上（`duration_sec` 繼續累加、buckets 沒動）。同一個 id 再裝回 409「已存在」⇒ **id 永久洩漏、拿不回來**。kernel log 對此**一行都沒有**（5 次 `handleDeleteGroupEntry`、0 條刪除失敗），而 API 自己的說明叫人「去 kernel log 看每筆結果」——指向一個空的地方。 | 「說刪掉了」與「真的刪掉了」在所有可觀測管道上都一樣 | `doc/audit/2026-09-03_night-rounds/round1-ovs/21_delete_group_meter_says_deleted_but_persists.log` |
| 2 | **B-1 的幽靈規則過濾器沒有覆蓋 OVS 寫入路徑**：OVS 上 kernel 在 t=0.257 s 就送出快取列（形狀是呼叫端的 `ipv4_dst` 詞彙、沒有計數器），並持續約 1.0 s；真正輪詢來的列 t=13.4 s 才到。同一份配方在 P4 上是 `first_sighting=never`。 | 08-31 判定「已修」的東西只在一個平面成立 | `.../round1-ovs/22_x5_b1_phantom_window_ovs.log`（含陽性對照：合法的 port-2 規則有同樣的幽靈形狀，所以那一列是快取不是合法性判定；探測解析度 0.25 s vs ~1.0 s 窗，排除「探測太慢」） |
| 3 | **失敗的 `ndt up ovs4` 不會回滾**：Ryu（:8080/:6633/:6653）、tmux topo session、15 個行程／36 條 veth 的資料平面全留著，而沒有 kernel。`:8000` 被佔用的檢查在 `stack.sh` 的 [3/3]，**在 fabric 建好之後**。 | 一次失敗的啟動留下一個沒有大腦的網路，而使用者以為什麼都沒發生 | `.../round1-ovs/02_ndt_up_failure_leaves_fabric_running.log`（對照：`03_...` 顯示 `ndt down` 之後才清乾淨） |
| 4 | **`ovs4` 拓樸完全沒有配置 sFlow**（十座 bridge 的 `sflow` 欄全 `[]`），而 kernel 照常在 :6343 聽 ⇒ 在 `ovs4` 上分身看到的流速率與鏈路使用率結構性為零，`/ndt/get_average_link_usage` 回 `{"avg_link_usage":0.0,"status":"success"}`。歸屬：`ovs_4host_topo.py` 有 **0** 個 sFlow 參照，而參考拓樸 `testbed_topo.py` 在 `:105` 定義、`:202` 呼叫 `enable_sflow()`。**範圍：只有 `ovs4`；`ndt up ovs`（128）走 NTG 的 `testbed_topo.py`，有 sFlow。** | 「我們沒問到」與「網路很閒」在輸出上無法分辨 | `.../round1-ovs/11_sflow_state_on_ovs.log`、`12_...`（對照：同一份 log 裡 3000 封包／0% loss 的真流，數字前後都是 0.0） |
| 5 | **kernel 關機時 abort**（B-5）：`DeviceConfigurationAndPowerManager::start()` 開三條 thread、`stop()` 只 join 兩條 ⇒ 解構 joinable `std::thread` ⇒ `std::terminate`。SIGINT 7/7 exit 134，修後 7/7 exit 0（gdb backtrace 對到 offset）。**而 `ndt down` 送的是 SIGTERM，kernel 只註冊 SIGINT ⇒ 那個「乾淨關機」從來沒被執行過**，行程一直是被硬殺的。 | 文件描述的關機程序在正式路徑上從未跑過，而且沒有人看得出來 | `doc/audit/2026-09-02_live-round/raw/D2_b5_kernel_exit.log` ＋ B-5 報告 |
| 6 | **`ndt apps stop` 只殺 bash wrapper**：viz 的 JVM 活了 1h54m、111% CPU、875 MB log，而 `ndt status`／`apps orphans`／teardown log **三個通道全說它沒在跑**。連帶汙染了 09-02 live round 從 C27（21:44）之後的所有量測。 | 停止工具與所有存活檢查一起說謊，而且會汙染別人的數字 | `doc/audit/2026-09-02_live-round/ADDENDUM-01-viz-orphan-contamination.md` |
| 7 | **`ndt` 有兩個 `sudo -n` 呼叫不在手冊教的 sudoers 規則裡**（`:1177` `ovs-vsctl list-br`、`:1206` `mnexec`）。權限被拒 ⇒ `ovs_bridge_count` 靜靜回 0 ⇒ **`ndt up p4` 的「底下有活的 OVS fabric 就拒絕」守衛永不觸發，會靜靜拆掉別人的 fabric**；另一處把「沒權限問」翻成 `h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding` 這句具體斷言。四輪 usertest 都看不見它，因為 tester VM 有全域免密碼 sudo。 | 儀器把缺陷遮住了；而且誤判方向是「把測不到說成具體的失敗」 | 手冊線 desk check（未實跑於需要密碼的機器） |

## 中等

| # | 缺陷 | 證據 |
|---|---|---|
| 8 | **`ndt status --check` 在健康的 `ovs4` 上報假紅**（"kernel graph does not match the topology file"），且 `configuration` 顯示 `hosts 128` 與 P4 的 128 主機檔——兩者都源自 `host_count_override`（P4 專用旋鈕，`ndt up ovs4` 從不寫）。**而且同一個檢查在 OVS 上零鑑別力**：只比 (hosts, edges)，P4 與 OVS 的 4 主機模型都是 (4,40) ⇒ 旋鈕設對之後它會綠著拿 OVS fabric 比對 P4 模型檔。 | `.../round1-ovs/05_`、`07_` |
| 9 | **OVS 接受了 action 為 `OUTPUT:999` 的流**（s1 上不存在的 port，Ryu 顯示以 prio 915 裝上）。約 13 秒後它不是幽靈，是一條**指向虛無的真規則**。 | `.../round1-ovs/22_...`（用 Ryu `/stats/flow/1` 直接讀回，不是用寫入的那個 API） |
| 10 | **每條流的速率沒有分母**（已量化、已修、在分支上）。誤差＝迴圈週期 T，單向（T 恆大於 1）且隨負載成長：安靜時 1.0439 s（**+4.4%**）、64 流舊 fabric 1.2487 s（**+24.9%**）。**既存讀數無法事後換算**——要用它當下的 T，而 T 只在 `kernel.log` 每 30 次迴圈印一次。（`FlowLinkUsageCollector.cpp:1934`）。排序不受影響（同迴圈、倍數相同、單調變換）；**大象流門檻一定錯且單向**——`:2020` 拿膨脹值比寫死的 10 Mbps，真實約 8.0–9.7 Mbps 的流被誤標。成因：PREREG 的修法範圍是用 `grep "MultiplySampingRate"` 界定的，流那條路用別的變數名。 | `doc/audit/2026-08-27_hardcoded-denominator/SUPPLEMENT-2026-09-02_deferred-and-scope-gap.md` |
| 11 | **`check_logs.py` 的崩潰樣式表缺了 12 類致命訊息**，包括 ① `without an active exception`（正是 B-5 實際印的那一句）與 ② **SIGKILL／oomd**——也就是**今天真正咬到我們的那一種**（下午 systemd-oomd 殺掉 Adam 的 app 與三次建置）。⇒ kernel 若被 oomd 殺掉，那道閘門一樣回綠。已補齊並加測試。 | B-5 報告；修法在 `fix/b5-kernel-shutdown` |
| 12 | **`stop_one` 的 `local name="$1" pidfile="$PID_DIR/$name.pid"`**：bash 在 `local` 生效前就展開兩邊，`$name` 讀的是**呼叫端**的變數。今天能對純屬巧合（兩個呼叫端剛好同名同值），換個呼叫端會 `set -u` 當場死，或**安靜地停掉另一個 component**。 | B-5 報告 |
| 13 | **`l1_unit_tests.sh` 把五個全綠的 shell 套件記成失敗**（只認 unittest 的 `Ran N`，而 `tests/shell` 有三種摘要格式），連帶 `local_ci.sh` 紅。已修，L1 問題群組 6 → 1。 | `doc/audit/2026-09-02_live-round/raw/B15`、`B16`、`B22`–`B24` |
| 14 | **chaos `_c07` 的控制組零鑑別力**（三條路由 404 ＋ 探測丟棄狀態碼 ＋「rows == 0 就算重現」），一條已發表的宣稱建立在它上面。已修並撤回該宣稱。 | 三合一修法 commit `1411f163` |
| 15 | **`l3_component_check.py --check-drift` 誤報**：`scan_kernel_dispatch()` 的 regex 認得 `target ==` 與 `.starts_with(`，**不認得 `utils::pathIs(target, …)`** ⇒ `HttpSession.cpp:164,169` 的兩條路由被讀成「已刪除」。已修，rc 1 → rc 0、42 個端點同步。**兩個平面都會發生**（P4 09-02 C6、OVS 今晚），與平面無關。 | 修法 commit `70665602`；閘門 5 個變異全滅，其中三個各刪掉一種**回報方式**、證明它仍抓得到真的漂移 |
| 16 | **`run_layers.sh` 不管哪座 fabric 起著都用 4 主機模型**（`topo_for_mode()` 直接回 `$TOPO_P4`）⇒ 今晚在 128 主機 fabric 上製造出一條 `BROKEN`，而 `40_r5_p4.sh:336` 把那條讀成**關於 A-8 的證據** ⇒ 今天合併的最高價值修法拿不到 live 判定。OVS 側同病（`TOPO_OVS` 是 128 主機模型）。 | 修法 commit `09e72e7b`；閘門 5 個變異全滅，其中 M2 證明修法沒有變成「總是回一個路徑」——找不到相符模型時**拒絕（rc 3）**而不是回退 |
| 17 | **同型第三、第四例**：chaos 的 `_h23_verify` 讀 `/ndt/get_all_destination_paths`（未註冊）⇒ **每一輪都指控「path map 被清空了」**（已修成拒絕）；`invariants.py:84` 對一條只收 POST 的路由發 GET ⇒ INV-01 的延遲檢查**永遠回報「A-1 early return」**（尚未修，已另開工單）。 | 同上 commit |
| 18 | **兩個速率欄位量的不是同一個東西，而且分歧隨負載成長**。`Periodically` 那條路少了分母 ⇒ **高估**，倍數＝迴圈週期。`Immediately` 那條走 `AutoRefreshQueue`（`SFlowType.hpp:193-266`），`refresh()` 用 `steady_clock` 把超過 1000 ms 的樣本從佇列前端丟掉 ⇒ 分母是**實測的一秒**、沒有倍數；但迴圈每 1.03–1.25 s 才讀一次而每次只涵蓋最近 1.0 s ⇒ **兩次讀數之間有一段時間不在任何回報視窗裡，空隙隨負載變寬** ⇒ **漏看**。一個高估、一個漏看，同一個成因（迴圈週期 > 1 s）、相反的症狀。 | `doc/audit/2026-08-27_hardcoded-denominator/SUPPLEMENT-2026-09-02_deferred-and-scope-gap.md`（`aa93fe30`）。附帶細節：`> m_interval` 會保留年齡剛好 1000 ms 的樣本，窗寬是 (0, 1000] 不是 [0, 1000) |
| 19 | **`check_gate_anchors.py` 有四個閘門根本沒在檢查**（回報 `UNPARSED`／`NO-ANCHORS`），其中包括 `mutate_lock_lease_all.sh`——**A-9 判定「已解決」的全部證據**就是那個 23 變異閘。另有一個假紅（把 dispatch 迴圈的 `${MUT_LABEL[$i]}` 當成字面錨點）。⇒ **一個閘門可以安靜地停止變異任何東西，而沒有人會知道。** 已修（認得四種寫法），從 20 ok／4 未檢查／1 假紅變成 **30/30**；A-9 那支只有在三個委派都在同一輪被檢查且都 ok 時才回 `ok-via(3)`，否則 `VIA-UNCHECKED` 並 exit 2。 | 修法 commit `16419664`；閘門 13 個變異全滅，15 個測試先看過紅（對修法前的工具 13/15 紅）。寫 M3 的過程中還發現另一個真缺陷：`function_bodies()` 用 dot-all 掃一行式 `add() { ... }` 會吞掉下一個函式、把**它的**參數角色讀成 builder 的 |
| 20 | **`lib_e.sh:435` 的 iperf3 守衛會自我毀滅後回報「乾淨」**：它的 `awk` 自己的 argv 帶著 `iperf3`，所以是 `pkill -f iperf3` 的合法目標；沒有 `set -e`／`pipefail`，`pids` 回空 ⇒ **在它被殺掉的那一刻回報成功**。已修（用 `while read` 加精確 `comm` 比對），並新增：**空的行程清單一律拒絕，不再讀成乾淨**。 | 修法 commit `f830dd03`；6 個變異全滅，M1 逐字還原原本的 `awk`；測試也對 HEAD 未修版跑過（12 個案例紅了 5 個）。同型待修：`lib_e.sh:565` 有同樣的 argv 形狀，對象是 `ndtwin_kernel` |
| 21 | **`up_p4` 會在一個沒清乾淨的 orphan 上面建 fabric，而且錯誤會偽裝成 P4 的問題**。`ndt:638` 在「有 orphan bmv2、沒有 topo session」時先呼叫 cleanup，**丟棄它的 rc**；orphan 佔住 `:3005x` ⇒ 下一個 fabric 綁不上 ⇒ 使用者看到的是一個像 P4 壞掉的錯誤。（`ndt:1083` 同族：走管線、`pipefail` 會傳出 rc，但 `cmd_down` 沒讀。）舊版 cleanup 每個 kill 都 `|| true`、結構上不可能回非 0，所以這個丟棄過去看不出後果；G-9 讓 cleanup 會失敗之後，它就變成一個看得見的洞。**今晚刻意不修**（測試輪整晚在跑 `ndt up`）。 | `fix/g9-cleanup-no-pkill-f` 的 RATIONALE 附錄二（呼叫端盤點，未動任何呼叫端） |
| 22 | 🔴 **殘留報告漏掉的正好是唯一會擋住下一次啟動的那個 port。** `cmd_clean` 對 `:8000`／`:8080`／`:8081` 指名到 port 並附「the next up would measure it」，對 bmv2 卻**只印數量不印身分**（`bmv2 switches: $n still running`）。而 `:3005x`（bmv2 的 gRPC port）在整個 `ndt` 裡**只出現一次**——`:635` 的一行註解，說 orphan 佔住它會讓下一個 fabric 綁不上；`cmd_clean` 不查它，`deep_sweep` 也不查。⇒ **`ndt:638` 那條因果鏈所轉的那個 port，正好是唯一沒有任何地方回報的。** 形狀：**涵蓋的是容易指名的 port，不是會擋住下一次啟動的 port**；而「哪個 port 會擋住啟動」這個知識**只活在一行註解裡，註解不會被執行**。 | `fix/g9-cleanup-no-pkill-f` 的 `NEXT.md`（`27eb2c57`），依據是分支 base 上的 `ndt:635`／`cmd_clean`／`deep_sweep` 逐段閱讀 |
| 23 | **同型第二例，而且更凶：`:6653`／`:6633`（Ryu 的 OpenFlow port）在整個 `ndt` 裡一次都沒出現**——`cmd_clean` 不查、`deep_sweep` 不查。而三處記著 OVS 路徑依賴它，其中 `ovs_4host_topo.py:31-33` 明講 port 是寫死的而非讓 Mininet 探測，因為沒指定 port 的 `RemoteController` 會依序試 6653 → 6633 → fallback 6653，**"silently masks a controller that is not there"**。⇒ **一個殘存的 Ryu 佔著 :6653，下一輪 OVS 會安靜地接上它**——`RemoteController` 的 fallback 把「controller 不在」變成「controller 在，只是不是你的」。與 `:8000` 上殘存 kernel 被報成 up 是同一類（`stack.sh:507-531` 就是為那件事寫的防護），差別是 `:8000` **有**被查、`:6653` **沒有**。🔴 **今晚有一個候選實例**：測試輪 finding 1 的那次失敗 `ndt up ovs4` 留下 Ryu（含 :6653），接著 `ndt down` 回 `CLEAN_RC=0` 才重試——而 `cmd_clean` 不查 :6653，所以那個 0 對「Ryu 死了沒」零鑑別力。已要求測試輪用現有證據判定。 | `fix/g9-cleanup-no-pkill-f` 的 `NEXT.md`（`1e78ecd8`）；四處註解＝`ndt:635`、`ndtwin-lab:337/348`、`ovs_4host_topo.py:31`、`stack.sh:676` |
| 24 | **同型第三例：`:9000`（sim app）在 `ndt` 與 `stack.sh` 各出現 0 次**，而今晚 live round 的檢查表**拿它當 app 是否起來的判準**（`CHECKPOINT.md:54`，`LISTENER-OWNER-HIDDEN` 儀器還在它上面實跑觸發過）。⇒ **測試輪的 harness 知道 `:9000`，產品自己的 teardown 檢查不知道。** 這比「沒人想到」嚴重：知識已經存在，只是不在會被執行的那段碼裡。 | `fix/g9-cleanup-no-pkill-f` 的 `NEXT.md`（`99349aa5`）；`grep -c 9000` 在兩個檔案皆為 0，親自跑過 |
| 25 | 🔑 **「這個檢查有鑑別力」的證據，可能只在被檢查的那一組上成立。** ⚠️ 已被用來回頭檢查今晚自己的修法，並找到一個實例：`sweep_matches` 的**每一個測試輸入都是人為發明的命令列**（fixture argv0、手寫的假 `ps` 行），沒有一個抽自真的 bmv2 ⇒ 29 個 check 全綠只證明「它對**想像中的**命令列有鑑別力」；真實 argv 若形狀不同（包在 wrapper 下、執行檔名帶版本後綴），掃除會**安靜地找不到它**並回報乾淨——正是那支修法存在的理由所反對的輸出。已升格為合併前必要條件。 `CHECKPOINT.md:52` 記著 `ndt clean` 的鑑別力驗證——握住 `:8081` 三次、`CLEAN_RC` 紅一次綠兩次、結論「**It discriminates**」。方法完全正確，但 `:8081` 正是它已涵蓋的三個 port 之一；**對 3005x／6653／9000 的鑑別力是零，而這個驗證在結構上不可能發現**。通則：鑑別力測試只證明它對你測過的輸入有鑑別力；輸入若抽自已涵蓋的集合，測試照不出未涵蓋的部分。 | 同上；`CHECKPOINT.md:52` 原文 |
| 26 | **`grep -c 'simple_switch_grpc'` 在 0 座 bmv2 的機器上回 3**——三筆全是自我比中（grep 自己的 argv、`bash -c` 包裝、管線）。`ndt` 檔頭的 trap note 記的是「10 座報 11」；**這次是「0 座報 3」，比例上糟得多，因為分母是零時自我比中就是全部的答案**。撞到它的人正是當晚在寫「移除 `pkill -f`」那支修法的 agent——在寫修法的同時踩進它要修的坑。 | `fix/g9-cleanup-no-pkill-f` 的 RATIONALE（`e245ccf6`），03:25 唯讀查證；同時 `ps -eo pid=,comm=` 數 `simple_switch_g`＝0、`ndt` 的 `bmv2_count`＝0、新的 `sweep_count`＝0，三者一致 |
| 27 | 🔴 **關機的 openflow worker 只在「輪與輪之間」檢查 `m_running`**，所以停止請求要等一整輪輪詢跑完。實測：修好 B-5（補上 join）之後，SIGINT 的關機耗時 2.40／2.40／2.53／2.40／3.00／6.40 秒——**而忙碌那一次是 81.09 秒**，其中約 72 秒卡在這個 join 裡（log：`stop()` 進入 → 7.01 s → `no flow-table response from …` → 72.09 s → `serving 10 switch(es) from their previous tables`）。當時 worker 正在對 10 座交換機輪詢一個沒有回應的控制平面。⇒ **`stop_one` 給的 10 秒上限根本不夠**：若現在就註冊 SIGTERM handler，等於把「一定立刻死」換成「等 10 秒然後照樣被 SIGKILL」。修法順序因此固定：**先把輪詢變成有界的**（每座交換機之間檢查 `m_running`、每個請求設 deadline），**再**註冊 handler。 | `doc/audit/2026-09-02_live-round/B5-REPORT.md`，數據取自已落盤的 7 次修後 SIGINT，沒有為了這個數字重跑 |
| 28 | **今晚新寫的兩個變異閘門，anchor 檢查器一個都讀不到**（G-5 那支抽出零個錨點；preflight 那支的 `report()` 被當成 applier 解析）。⇒ 剛出廠的儀器**預設是未被檢查的**，而它們正是我們用來檢查別人的東西。已改成檢查器認得的寫法，`check_gate_anchors.py HEAD` 現在對兩支各回 `ok(5)`／`ok(6)`。 | trunk `053387b1`、`fbe4dd8f` |
| 29 | **`lib_e.sh` 的還原檢查在輪次真正移動的那個軸上零鑑別力**：它只斷言編譯後的 JSON 裡**存在**一個 `"op":"truncate"`——而那在**每一種取樣率、以及取樣完全關掉時都成立**。另外 `cp -f` 把 kernel binary 複製回去是在 `teardown` **之前**做的，rc 也沒人讀。已改成斷言 `modify_field_rng_uniform` 的**上下界**（上界＝取樣率、下界＝「到底有沒有在取樣」），並把 teardown 移到複製之前、讀 rc。 | trunk `e72ebdfa`；7 個變異全滅 |
| 30 | **`00_preflight.sh` 的 claim 判定分不出「別人的 claim」與「我不知道這是誰的 claim」**：`NDT_OWNER` 沒設時它直接回 FOREIGN。另外 `port_holder` 取 `ss` users 清單的 `head -1`，而**正確答案是最舊的那個 fd 持有者**（fd 只能從已經持有它的行程繼承而來）。已改成五值的 `claim_verdict()`（第五值 `OWNER-UNSET` 明說儀器無法判斷）並取最舊的持有者。 | trunk `c916bd4c`；7 個變異全滅，雙向（M1＝舊的錯答案、M2＝一律放行） |
| 31 | **`TESTBED` 那條路有除以時間，但把間隔截斷成整數秒**（flagged，未修）。與流那條路是同一族的第四個速率產生器；語意搜尋確認**沒有第三個完全沒分母的**。 | 分支 `fix/flow-rate-denominator` 的 `FLOW-RATE-DENOMINATOR.md` |

### Round 2（開關機／路徑重算）——九條，其中一條是其他幾條的根

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 32 | 🔴 **根因：啟動競態讓 bmv2 的 liveness 路徑從不執行。** 整輪的 proxy log 裡，kernel 發出的 `GET /p4/switch_state` **0 次**；`refreshDataPlaneKind()` 比 topology 載入早約 1 ms，而且**只算一次**。 | 下面好幾條從「短暫錯誤」變成「永久錯誤」都是因為它 | round2 `SUMMARY.md`、proxy log |
| 33 | **`/ndt/get_switches_power_state` 回報的是「下過的指令」不是量測**：兩台同樣死透的交換機，**被命令關的報 OFF、自己死掉的報 ON**。 | 電源狀態是決策依據，而它答的是我們自己的意圖 | round2 `09_` |
| 34 | **A-8 的三態檢查在 MININET 下不可能失敗**（`unexplained_down` 結構上恆空，兩邊讀同一個 `isUp`）；而且訊息**硬把原因歸給 Energy-Saving-App**，即使那次是手動 POST。 | 一個永遠不會紅的檢查，外加一句捏造的歸因 | round2 `09_` |
| 35 | **電源 API 兩個方向都用 `isUp` 提前 return Success**：開機 0.8 ms 什麼都沒做（真做事是 1.48 ms），關機也能回 Success 卻沒殺掉。 | 成功回報與實際動作脫鉤，兩個方向都是 | round2 `D16/D18` |
| 36 | **命令的關機會遺失，9 次中 2 次**：`is_up` 觀測到 1→0→**1**，最後那次在指令後 **3.08 s** 被覆寫。與 #35 疊加＝**一次 off 就能讓交換機死掉且 API 再也救不回**，只能用 helper 帶外救。 | 兩個各自可控的缺陷疊成一個不可逆狀態 | round2 `D17` |
| 37 | **一個被拒的模擬 case 讓 Energy app 永久卡死，並持續霸佔 `routing_lock`**（`send_case` 是 void，502 被丟掉）。 | 一個被丟棄的錯誤碼變成一把永遠不放的鎖 | round2 `A3` |
| 38 | **連線被拒被報成「30 秒逾時」**——實測 6–9 ms、5 次。 | 又一個把「立刻被拒」說成「等了很久」的訊息 | round2 `D12` |
| 39 | **`get_power_report` 是 dpid 的純函數**（10/10 與獨立重算相符），且**沒有 `source` 欄**說明它是合成的。 | 任何「省了 N% 電」量的是有幾個 vertex 被標 down | round2 `D14` |
| 40 | **兩條路全關時 twin 說 no path，而交換機自己的表仍指向已關機的 s6。** | 分身與資料平面對同一件事給出不同答案 | round2 `P3` |

### 安裝手冊 run-04（sonnet，6h48m，94 項 checklist，兩條資料平面都跑到真流量）

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 41 | 🔴 **同型第四例，而且是唯一當場擋住合法操作的：`ndt down` 的乾淨驗證看不到 sFlow 的 `:6343`。** 一個 tester 沒啟動過的 `ndtwin_kernel`（pid 59174）佔著 `:6343`，擋掉合法的 Terminal 3（`bind() to sFlow port 6343 failed`），而 **`ndt down` 的五條斷言全部回綠**、`ndt status` 把它當成正常收斂的 run。讀碼確認：`cmd_clean` 的迴圈是 `for p in 8000 8080 8081`，`deep_sweep`（`--deep`）迭代**同一組三個** ⇒ 兩條路徑都看不到它。 | 讓「會擋住下一次啟動的 port」那張表變成五列；而且證明這個形狀會真的咬人不只是理論 | run-04 BUG-3 |
| 42 | **`testbed_topo.py` 內建的 128 對 ping self-test 全部回報 `100% packet loss`，而結尾 banner 照樣印 `Host internet: OK | sFlow reachability: OK | Switch identification: OK`**；同一對主機幾秒後手動 ping 是 **0% packet loss**。兩次獨立重啟＋NTG 自己那份副本都重現。 | 自我檢測失敗，而橫幅仍然宣告三項全 OK——使用者拿到的是一個假的健康聲明 | run-04 BUG-2 |
| 43 | 🔴 **`pkill -f` 禁令的第一次現場重現**：NSR 的 stop script 執行 `sudo kill -15 $(pgrep -f network_state_recorder.py)`，**連坐殺掉 tester 自己的 shell**（SSH exit 255）——而手冊自己在兩節之前才警告過這個反樣式。 | 以前這條禁令只有推論，現在有現場證據；今晚正好有一支分支在移除同族的 `pkill -f` | run-04 BUG-4 |
| 44 | **Web GUI 的 pnpm 未釘版本**（run-01 就有、刻意沒修）**如預測重現**，`web_gui_deploy.sh` 在任何 container 起來之前就失敗。 | 預測命中本身是預註冊有效的證據 | run-04 BUG-5 |

### Round 3（反覆重啟／併發）

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 45 | 🔴 **啟動競態的勝負由 topology 檔的 JSON parse 時間決定，而在任何出貨用的檔上是 100% 輸**：60 次冷啟動——310 B 贏 5/8、587 B 贏 5/8、**7.8 KB 以上 0/44**（出貨 4-host 檔 0/20、128-host 0/8）。60 次全部**稍後**都印 `All-bmv2 topology`，證明輸的是**時序不是拓樸**。 | 把 round 2 的根因從「有時發生」釘成「出貨組態下必然發生」；也證明**修法只能是排序／同步，不能靠把載入變快**（587 B 仍會輸） | round3 `01_`、`02_`、`05_` |
| 46 | 🔴 **輪詢會覆蓋關機指令，而且復活是永久的**：`TopologyAndFlowMonitor.cpp:768-772` **只寫 `isUp=true`，沒有任何 else 分支寫 false**。相位相關性量到了——指令落在 poll 前 1.5 s 失敗 **8/14**，落在 poll 後 2 s 失敗 **0/4**；所有失敗的 `is_up` 0→1 都在 **t_off+2.31 s**（＝ t_off+1.86 s 抵達 proxy 的那次 poll 被套用的時刻）。 | 從「9 次失手 2 次」變成一個有機制、有相位、可預測的缺陷 | round3 `11_` |
| 47 | 🔴 **kernel 的 listening socket 被它自己 `popen` 出來的 `sh`／`curl` 繼承**：`:8000`(TCP) 與 `:6343`(UDP) 在 kernel pid 確定消失後**仍被佔住 2.01–2.22 秒**（48/48）。窗口內重啟 **6/6 失敗**，而錯誤訊息說「另一個 NDTwin kernel 幾乎確定還在跑」——**根本沒有，佔住的是它自己的孤兒 curl**。對照組：間隔 3.0 s 重啟 3/3 成功。 | 一個誤導性的錯誤訊息把使用者推向錯誤的診斷；也是 round 1 的 D1 的天然觸發源 | round3 `03_` |
| 48 | **`ndt apps stop viz` 回報 `ok viz stopped`，兩個 JVM（531 MB）仍活著**，接著 `ndt apps orphans` 回答「沒有未追蹤的 app process」——**對 viz 而言兩個 witness 的鑑別力都是零**。 | 09-02 那次 875 MB 孤兒的機制，這次被完整量到 | round3 `14_` |
| 49 | **`ndt down` 自己的 verify 誤報**：印「XX bmv2 switches: 5 still running / not clean」，20 秒後 `ps` 數到 0——**verify 與它要驗的 sweep 沒有同步**。 | 又一個「檢查與被檢查的東西不同步」 | round3 `SUMMARY.md` |
| 50 | **`ndt:1687` 的 `2>/dev/null` 放在 `<` 之後，所以它擋不住它唯一要擋的那個訊息。** `mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null`——redirection 由左而右套用，開檔失敗的訊息在 stderr 被轉走**之前**就印出去了；**而這個函式存在的全部理由就是那個 pid 可能已經不在**。同族：`ndt:1999`、`:2034`。今晚實際洩到一份 audit log 裡（`tools/test_workflow/ndt: line 1687: /proc/1320231/cmdline: No such file or directory`）。修法＝把 `2>/dev/null` 移到 `<` 前面；驗收＝用不存在的 pid 呼叫，斷言 stderr 為空。 | round3 `14_viz_process_chain.log` 的 stderr 噪音 |

### Round 4（高流量與量測失真）——本輪主題成立，而且是今晚最重的一條

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 51 | 🔴 **高負載下分身低報 2.76 倍，而所有健康訊號都說一切正常。** 同一條 20 Mbit/s、線上**逐位元組零丟失**（`0/98213`）的 flow，twin 報 **19.69 → 7.14 → 20.67 Mbit/s**（中間那格併行灌 541,547 datagram/s）。同時：每個 endpoint 都回 200／`success` 而且**比對照組還快**（<5 ms）、三個窗口全程 `active` 30/30、`avg_link_usage` **反向上升**。唯一痕跡是 33 行 WARN。**不是 CPU 飢餓**——已知的無分母偏差會讓數字**變大**不是變小。 | 這是「量測在壓力下說謊，而且所有儀表板都說健康」的完整實例 | round4 `11_` |
| 52 | 🔴 **一條完全送達的 flow 會從 API 預設窗口消失，而界線的單位是 pps 不是 bit/s。** ≥5 Mbit/s 三窗口全 30/30；**2 Mbit/s（179 pps）開始分歧**；**250 kbit/s（22 pps）預設窗口跨過 50%**——一半的秒級查詢看不到它，而 `?liveness=all` 仍 30/30；60 kbit/s 起 15 s 表也開始漏；≤30 kbit/s 三窗口一起說「不在」。**鎖死頻寬只縮封包（1400→100 B）可見度 0.70→1.00** ⇒ 換 frame size 會讓界線整體位移最多 **14×**。 | 文件與宣稱都用 Mbit/s 表述，而真正的界線是封包率——可移植的講法是 **~22 pps** | round4 `06_`、`07b_` |
| 53 | 🔴 **sFlow 樣本會掉，而且四個丟棄計數器沒有任何 API 讀得到。** 2k／20k／60k 每秒 0 掉；**150,000/s 掉 0.34%**；**654,709/s 掉 72.5%**（第二通道 `/proc/net/udp` 的 drops 與 kernel 的 `sock_ovfl_total` 逐格吻合）。15 個 GET＋3 個 POST＋11 個 metrics 路徑共 **105 個 JSON key，沒有一個**帶這四個計數器；`/metrics`、`/ndt/get_sflow_stats` 全 404。**唯一讀者是一行 log。** | 資料在掉，而讀 API 的人在結構上看不到 | round4 `09_` |
| 54 | **同一個 match 裝 20 次，API 報 `succeeded +20`，交換機只多 1 列**（比值 20.00，無上界）；不同 match 的對照組比值 1.00。**刪一條不存在的規則 15 次，全部 `succeeded +15 / failed 0`，交換機列數不變。** ⇒ `succeeded` 既不是規則數，也不是「有東西被改了」的證據。 | 規則 churn 之下，外部無從得知交換機上到底有幾條規則 | round4 `12_`（switch 側走 proxy 的 P4Runtime 讀，不是寫入的那個 API） |
| 55 | **collector 綁 `INADDR_ANY:6343`，而來源位址從頭到尾沒被讀過**（`srcAddrs` 只寫不讀），歸屬只信 datagram 內部自稱的 agent IP。**現場示範：一個普通本機行程把某條真實邊的 utilisation 灌成兩倍。** | 任何能送 UDP 到本機的東西都能改寫遙測，而沒有 endpoint 會顯示 | round4 `10_` |
| 56 | **`rx` 在穩態下沒有任何通道**（INFO 一輩子只印一次，其餘是 TRACE）⇒ **「沒有 WARN」與「什麼都沒收到」從外面分不出來。** | 又一個「安靜」與「死掉」不可分辨 | round4 |
| 57 | **API 送出的 IP 是位元組反序的**（10.0.0.1 → 16777226），文件沒講。 | 消費者會靜靜地解錯 | round4 |

### Round 5（拓樸檔與重現性）——重現性那條是今晚的王牌

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 58 | 🔴 **同一個指令、同一個拓樸檔、每次都從驗證乾淨的機器起——8 次 bring-up 產生 4 種不同的全網路由表。** 帶相同 h3→h1 流量時 s3 走 s7／s8 **4:4 對分**，s3–s7 公布的使用率取 5 個不同值 `{0.0, 1.476, 1.771, 2.951, 2.952}`。**而 `/ndt/get_path_switch_count` 這 8 次逐位元組相同**——研究者用來問「路徑變了沒」的那個端點，**結構上看不到這個變化**（它只回跳數）。**成因已釘死**：`topology_manager.py:784` 的 `nx.shortest_path` 是 BFS，h3→h1 有 **8 條等長最短路**，平手由 `nx.DiGraph` 的**插入順序**決定，而插入發生在十條並行 gRPC 收包執行緒上；**離線用同一組邊、兩種插入順序重現了現場那兩個結果**。⇒ **修法是加確定性 tie-break（排序），不是同步問題。** | 一個研究工具最壞的缺陷形態：**數字不可重現，而檢查它的端點看不見**；且成因有離線重現 | round5 `SUMMARY.md` B 節、`topo/` |
| 59 | 🔴 **這個 repo 自己的產生器能產出自家 kernel 載不動的檔，而失敗發生在 port 看起來健康之後。** `make_topology.py` 超過 **252 台**就吐出不合法 IPv4（`--hosts 300` 出 45 個 `10.0.0.256+`，1024 台出 769 個），**rc=0、無警告**——它自己的 `validate()` 只檢查字串唯一、不檢查是不是位址。這種檔會讓 kernel **開完 `:8000`／`:6343` 並印出 "Server Listening" 之後才 abort**（0.50 s 開埠、1.50 s rc=134 core dump），唯一診斷是 stderr 兩行、**不含檔名也不含節點**。成因：`run()` 這條 thread 沒有 try/catch。 | 兩個缺陷疊成一個：產生器不擋、載入器在開埠之後才死 | round5 `01_`–`05_` |
| 60 | **P4 平面上 `priority` 被收下、寫進自己的 log、然後丟掉**：同 match 用 priority 500 install 會**覆蓋** priority 100 那條；用**從未存在的 priority 777 做 modify 會改寫既有規則**；priority 999 的 delete 也刪得掉。四次都 200＋`succeeded`+1。`P4RoutingStrategy.cpp` 與 `FlowDispatcher.cpp` 對 priority 的 grep 數是 **0**。 | 使用者以為自己在用 priority 分層，實際上在互相覆蓋 | round5 `1x_` |
| 61 | **dpid 對不到交換機的 host edge 被靜默丟棄**（40 條進 39 條），所有端點回 200，只有一行 WARN。 | 一個少接了一條線的 fabric，對外看起來完全健康 | round5 |
| 62 | **`src_interface` 0 與 999999 完全不做範圍檢查**，被 `get_graph_data` 原樣公布，並經 `FlowLinkUsageCollector.cpp:3017` 流進 flow path。 | 無效值一路流到量測 | round5 |
| 63 | **`--logfile` 文件寫得像吃路徑，實際是 boolean**（`Logger.cpp:31`）：路徑被吞掉、指定的檔 0 bytes、stderr 無話。 | 使用者以為自己在收 log，其實沒有 | round5 |

## 驗證結果（不是缺陷，但今晚第一次問得出來）

- **跨趟的速率散佈已解釋，不是狀態外洩**：線材真值三趟**完全一致**（249,998,000 B／178,570 封包／0% 遺失），
  而 twin 的單流速率 14.77–27.56 Mbit/s（−26%…+38%）。回報的封包率就是 **(k×256)/window**，
  k=5.00…9.33 ＝ 落在一秒窗內的 1/256 樣本數（λ=6.98）；**同一 fabric 內的對照趟散佈與跨 fabric 一樣大**
  ⇒ 是取樣不是狀態外洩。真正的狀態外洩只有一項（dispatch 計數器 per-process 累加）。
- **負對照如預期**：重複的 host edge 沒有被判成缺陷。

- **Lead 5(c) 推翻，而且是機制層級的推翻**：round-robin 的**應用層**丟包**沒有發生**——954 萬個 datagram 裡
  `app_drop_total` 恆為 0。結構原因：socket buffer 4 MB ≈ 5,000 個 datagram，而 worker queue 有
  20×4096 ＝ **81,920**，**差 16 倍，socket 一定先滿**。掉的是 socket 不是應用層。
- **推翻**：灌爆**不會**讓真的 flow 從 API 消失——傷的是**數值**不是存在；`avg_link_usage` 不降反升。
- **高流量數字在這個 fabric 上可信**：20 Mbit/s 只產生約 18 sample/s，離 150k/s 的掉包門檻差四個數量級。
  真正的暴露面是**任何人都能打到 `:6343`** 而且沒有 endpoint 會顯示（見 #53、#55）。

- **關掉載流量的交換機**確實會重繞，**黑洞 14.14 s／18.51 s**（N=2，從封包計數算，路由用 bmv2 自己的 CLI 對帳）。
- `p4_power_helper.py` 首次真正執行：**PASS**。
- **推翻**：「被拒的請求仍然做了事」在這一輪**不成立**——kernel 誠實，`get_flow_dispatch_status` 記下了兩筆失敗。
- **Lead E 推翻（降級一條既有 finding）**：`routing_lock` 後面**什麼都沒擋**。照 wedged Energy app 的方式扣住鎖之後，
  10 個 kernel endpoint 加 `ndt status --check`／`ndt check` 的狀態碼與延遲**與對照組完全一致**（power off 0.237 s、
  on 1.474 s 都真的做了事）；鎖確實握著（競爭 acquire 連續 7 次回 423）。**全 deployment 只有 Energy-Saving-App
  一個 client** ⇒ #37 應降級為單一 app 的 liveness bug，不是系統級併發風險。
- **推翻**：「同 match 併發兩寫者會丟更新」——**序列對照組行為完全相同**（last-writer-wins），不是 race。
  殘留的只是「replace 與 add 在回應與計數器上無法區分」。
- **#36 收窄**：不是無條件變磚，界線是 `kPostPowerOffDistrustWindow{15}` **15 秒**——15 秒內 `action=on` 14/14 成功
  （~1.47 s），超過後 4/4 在 ~1 ms 回 Success 卻什麼都沒做。**有 workaround：15 秒內重試。**
- **viz 行程鏈已擷取**（兩輪拿不到的那個事實）：**3 個 process 不是 4 個**；兩個 JVM 的 argv **都不含 launcher 名字**、
  `comm` 都是 `java`；**可用的比對字串是目錄名 `Network-Traffic-Visualizer`**（maven JVM 2 次、app JVM 1 次、launcher 0 次）。
- **Lead A 推翻**：Energy app 在 ovs4 不動作**不是**因為沒有輸入。`energy_saving_app.cpp:926` 是
  `<= LOW_WATER_MARK 0.40`，**0.0 落在動作側**；它確實發了關機 case，全部 502——因為
  Simulation-Platform-Manager 沒開。先開 sim 再開 energy，它真的關了 s7／s9／s5。

- **30/30 個變異閘的錨點在 HEAD 上全部對得上**（`check_gate_anchors.py HEAD`，rc 0，
  「0 not ok，其中 0 個根本沒被檢查」）。修好檢查器之前這個問題問不出來：四個閘門不在檢查範圍內。

## 已澄清的非缺陷（記下來，免得下一輪重報）

- `50_r5_ovs.sh` 說 `ovs-ofctl is not usable without a password` 是**對的**：sudoers 只給
  ovs-vsctl／ifconfig／mnexec／ndtwin-lab／ndtwin-p4-power。F-5 確實只有兩個來源不是三個。
  （測試輪自己的假設被推翻並就地註記，沒有刪掉。）
- **X-10 是 PASS**：OVS 上六個 group/meter 端點回 200 而非 P4 的 501（正確的反轉），
  「已存在」那半回 409 且訊息精確。F-13 的 12 格矩陣就此關閉。
- `p4_coverage_gate.sh` 的紅**不是覆蓋率下降**，是分母長大（46/54 → 46/55，多的那行原理上不可達）。
