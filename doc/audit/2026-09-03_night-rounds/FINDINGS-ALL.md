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
| 42 | **`testbed_topo.py` 內建的 128 對 ping self-test 全部回報 `100% packet loss`，而結尾 banner 照樣印 `Host internet: OK | sFlow reachability: OK | Switch identification: OK`**；同一對主機幾秒後手動 ping 是 **0% packet loss**。兩次獨立重啟＋NTG 自己那份副本都重現。 | 自我檢測失敗，而橫幅仍然宣告三項全 OK——使用者拿到的是一個假的健康聲明 | run-04 BUG-2；🆕 09-03 補記（#77 agent；auditor 親驗 NTG HEAD 那份在 `NTG_PY` 下 import 即死）：本 repo 這份在 #42 修法併入時於 `NTG_PY` 下同樣 import 不了（缺 bootstrap），⇒ **#42 的修法從未被執行過、只有單元測試**；#77 的 AFTER 臂（09-03 23:2x）是它第一次實跑，橫幅 `0/128`＋兩項 NOT MEASURED |
| 43 | 🔴 **`pkill -f` 禁令的第一次現場重現**：NSR 的 stop script 執行 `sudo kill -15 $(pgrep -f network_state_recorder.py)`，**連坐殺掉 tester 自己的 shell**（SSH exit 255）——而手冊自己在兩節之前才警告過這個反樣式。 | 以前這條禁令只有推論，現在有現場證據；今晚正好有一支分支在移除同族的 `pkill -f` | run-04 BUG-4 |
| 44 | **Web GUI 的 pnpm 未釘版本**（run-01 就有、刻意沒修）**如預測重現**，`web_gui_deploy.sh` 在任何 container 起來之前就失敗。 | 預測命中本身是預註冊有效的證據 | run-04 BUG-5 |

### Round 3（反覆重啟／併發）

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 45 | 🔴 **啟動競態的勝負由 topology 檔的 JSON parse 時間決定，而在任何出貨用的檔上是 100% 輸**：60 次冷啟動——310 B 贏 5/8、587 B 贏 5/8、**7.8 KB 以上 0/44**（出貨 4-host 檔 0/20、128-host 0/8）。60 次全部**稍後**都印 `All-bmv2 topology`，證明輸的是**時序不是拓樸**。 | 把 round 2 的根因從「有時發生」釘成「出貨組態下必然發生」；也證明**修法只能是排序／同步，不能靠把載入變快**（587 B 仍會輸） | round3 `01_`、`02_`、`05_` |
| 46 | 🔴 **輪詢會覆蓋關機指令，而且復活是永久的**：`TopologyAndFlowMonitor.cpp:768-772` **只寫 `isUp=true`，沒有任何 else 分支寫 false**。相位相關性量到了——指令落在 poll 前 1.5 s 失敗 **8/14**，落在 poll 後 2 s 失敗 **0/4**；所有失敗的 `is_up` 0→1 都在 **t_off+2.31 s**（＝ t_off+1.86 s 抵達 proxy 的那次 poll 被套用的時刻）。 | 從「9 次失手 2 次」變成一個有機制、有相位、可預測的缺陷 | round3 `11_` |
| 47 | 🔴 **kernel 的 listening socket 被它自己 `popen` 出來的 `sh`／`curl` 繼承**：`:8000`(TCP) 與 `:6343`(UDP) 在 kernel pid 確定消失後**仍被佔住 2.01–2.22 秒**（48/48）。窗口內重啟 **6/6 失敗**，而錯誤訊息說「另一個 NDTwin kernel 幾乎確定還在跑」——**根本沒有，佔住的是它自己的孤兒 curl**。對照組：間隔 3.0 s 重啟 3/3 成功。 | 一個誤導性的錯誤訊息把使用者推向錯誤的診斷；也是 round 1 的 D1 的天然觸發源 | round3 `03_` 🆕 **09-03 修法分支量出 finding 沒寫的前提**：窗口寬度＝kernel **最長命子行程**的壽命——`:8081` 沒人聽時每個 poll `curl` 0 ms 就失敗、kernel 被殺當下沒有活著的子行程，**未修版也 1–2 ms 釋放**；只有 proxy 卡住（accept 不回答）時才重現：before 1.757 s／0/6 重啟 → after 0.001 s／6/6（n=8，同 commit 兩顆 binary 只差修法，raw 在 `audit-raw @ 94333bb2`）。修在 socket（`SOCK_CLOEXEC`／`FD_CLOEXEC`）而不是 32 個 spawn 站點；`POSIX_SPAWN_CLOEXEC_DEFAULT` 在 Linux 不存在（Apple 擴充），對應物是 `close_range()` |
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

### Round 6（歷史 bug 形狀的未檢驗實例）——十個候選全數判定

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 64 | 🔴 **拓樸輪次的「完整性」檢查只測 body 非空，從不看 HTTP status**（`TopologyAndFlowMonitor.cpp:588-590` 只有 `!body.empty()`）。switches／hosts／links 任一回 **500**、回**非陣列 JSON**、或回**純文字**，全都算「答了」⇒ 該輪被記為 Complete，**log 一行都沒有、API 一欄都沒有**。空 body 那組會紅。**這正是 round 1 的 X-1 造不出來的「半答案」情境。** 修法規格現成：**同一顆 binary 的 flow-table 抓取路徑有分辨**（`reported_failure`／`unparseable`）。 | 一個宣稱「這輪拓樸是完整的」的判斷，實際上只知道對方有回話 | round6 `N1`，含變異閘 2→3 |
| 65 | **三種「讀不到交換機」有三種行為，只有兩種被標記**：HTTP 500 → `reported_failure`、非 JSON → `unparseable`（兩者都保留上次快照並說明）；但**格式正確、型別錯誤**的 body（`{"dpid":3,"flows":{"3":{"unexpected":"object"}}}`）**被原樣轉發且完全沒有標記**。 | 第三種失敗偽裝成成功 | round6 `N2`，2/2 重現 |
| 66 | **交換機死掉後，flow table 照舊供應 10–12 秒且無任何 stale 標記**，要到第一次失敗輪詢之後才出現。 | 一個十秒的窗口，過期資料看起來是新鮮的 | round6 `N3` |
| 67 | **power cycle 會弄丟操作者裝的規則且不還原**，而 `get_flow_dispatch_status` 仍把它們記為 succeeded。 | 規則消失，而計數器說它們還在 | round6 `N4` |
| 68 | **兩個 elephant flag 是唯寫的**：1 個宣告、6 個賦值、**全樹 0 個讀取**，也不在端點的 15 個 key 裡。 | 見下方對我自己的更正 | round6 `N5` |

### 09-03 下午新增（修 #63 的過程中發現，auditor 自己查證）

| # | 缺陷 | 為什麼嚴重 | 證據 |
|---|---|---|---|
| 69 | 🔴 **`--loglevel <打錯的值>` 把 log 整個關掉，rc 0、一句話都沒有，而寫來攔它的錯誤路徑不可能執行。** `Logger::parse_level`（`src/utils/Logger.cpp:10-22`）把 `spdlog::level::from_str` 包在 `try/catch (const spdlog::spdlog_ex&)` 裡，印 `Unknown log level:` 並 `exit(1)`。但 `from_str` **兩處都宣告 `SPDLOG_NOEXCEPT`**（`libs/spdlog/common.h:294` 與 `libs/spdlog/common-inl.h:38`）⇒ **catch 永遠到不了**；而它認不得任何名字時的結尾是 `return level::off;`（`common-inl.h`）⇒ `--loglevel inf` 不是「用預設等級」，是 **`off`＝完全不記錄**。⚠️ **公開 build 上一模一樣**（`origin/main` 的 `Logger.cpp:10-20` 與 `common.h:294` 逐字相同）⇒ 讀者也中。 | 比 #63 更糟：#63 是 log 跑到別的檔（還在），這條是 log **不存在**，而兩者都不出聲。操作者接著會用「log 裡沒有錯誤」當證據。 | auditor 讀碼查證（`common.h:294`、`common-inl.h:38-56`、`Logger.cpp:10-22`），trunk 與 `origin/main` 兩邊都確認 |
| 70 | **`Logger` 的 `--help` 分支在 kernel 裡不可達**，而 `main.cpp` 的 usage 正好指向那段印不出來的字：`cli::parse` 先跑並 `return 0`，所以 `Logger::parse_cli_args` 的 `--help` 永遠沒機會執行。連帶：**兩個 parser 對不認得的旗標都靜默忽略**（`--logfle /tmp/x.log` 被收下、什麼都沒做、沒有訊息）。 | 「說明文字描述的行為從未執行過」，與 B-5 的關機路徑同型 | 同上；修法分支 `fix/logfile-takes-a-path` 的 §旗標完整表 |
| 71 | 🔴 **rule journal 在 production 從來沒有被寫過，而一支叫「journal wiring」的 14 個測試全綠。** `TopologyManager.__init__` 的簽章是 `(kernel_notifier=None, clock=..., journal=None)`，而 production 唯一的建構點 `p4_proxy/proxy_agent/main.py:26` 是 `TopologyManager(kernel_notifier=kernel)`——**沒有傳 journal**。`_note_in_journal`（`topology_manager.py:966`）第一行就是 `if not accepted or self._journal is None: return accepted` ⇒ **每一次都立刻返回**。`rule_journal.py` 沒有被任何 production 模組 import（唯一的 import 在 `tests/test_rule_journal.py:47`）。 | 🔑 **抓這個形狀的儀器自己就有這個形狀。** `tests/test_journal_wiring.py` 的 docstring 逐字寫著它存在的理由：「this repository's most-repeated defect is a component that exists, is documented, is committed, and **has no caller**」——而它用 `TopologyManager(journal=RecordingJournal())` **注入**依賴，所以它證明的是「給它一個 journal 它會寫」，不是「有人給它 journal」。**14 tests OK**，而 journal 一次都沒被寫過。⇒ A-4c 的 replay 在重啟後會拿到空的 journal，並被讀成「本來就沒有東西要還原」——正是那份 docstring 自己預言的結局。 | auditor 查證：`main.py:26`、`topology_manager.py:519/966`、`grep -rn 'rule_journal' --include='*.py' p4_proxy/`（production 零 import）、`venv/bin/python -m unittest tests.test_journal_wiring` → `Ran 14 tests … OK` |
| 72 | **P4/BMv2 demo image 的 `/etc/netplan/50-cloud-init.yaml` 綁死 QEMU 的 MAC `52:54:00:12:34:56`**（cloud-init 在我們自己的 qemu VM 裡建 image 時寫的，而 `tools/remote-lab/ndtwin-vm.sh` 正好釘死同一個 MAC）⇒ 換到任何別的 hypervisor，`match` 不中、網卡永遠不上線、guest 完全沒網路（VirtualBox 實測 `enp0s17` DOWN 無位址）。VMware 的 OUI 是 `00:0c:29`／`00:50:56` ⇒ 手冊叫使用者走的那條路很可能一樣中招——**推論，未測**（那台沒裝 VMware）。 | 🔑 **驗收工具與缺陷是同一個東西生的。** 08-31 那輪點名了對的風險（README：「VMware 兩種 virtio 都沒有，這是整個轉換裡最大的風險」），然後只變動裝置型號、把 MAC 釘著不動——而決定成敗的正是被釘住的那一個；`ens3` 拿到 DHCP 只因為 netplan 仍 match 得到。**整輪跑在會釘死 MAC 的工具裡，所以結構上抓不到。** 與「儀器不能長得像自己的發現」同族 | `開機手冊` session，`doc/audit/2026-09-03_virtualbox-demo-vm/REPORT.md`（commit `1dc62cdf`，在 `lab`）。**已修**：netplan 改 `match name: "en*"`＋擋 cloud-init 重寫，用 A-3 的 ovftool 配方重打包，紅綠都量（出貨原狀無 SSH banner；修後 25 s 有 banner、`10.0.2.15/24`、pingall 0% dropped 6/6），舊 qemu 環境未壞；Adam 已上傳，sha256 `5ed8dcb9…3fefab`。⚠️ **`ndtwin-vm.sh` 本身仍釘著那個 MAC**（該 commit 沒動它）——工具側待修。**順帶降級一格**：08-31 那輪把「Untested on real VMware」標成**已關閉**，依據是 ovftool 轉檔成功而不是開機——**而 ovftool 轉檔在結構上不可能碰到 netplan**。所以那個「已關閉」到現在沒有任何一次真的在 VMware 上開機的證據支撐（同事 09-03 補充） |
| 73 | **`tools/contract_test/components.py` 的手抄表 `KERNEL_ENDPOINTS` 漏了 `GET /ndt/get_sflow_stats`**（telemetry-health 併入 `ea139d1c` 時加進 `HttpSession.cpp`，表沒跟）⇒ `tests/python/test_l3_dispatch_drift.py` 在 trunk 上紅、contract tester 對這個 endpoint 零覆蓋 | 手抄表 vs 源碼掃描：drift 測試抓到了，**但合併驗證沒跑它**（只跑 C++ 924）。「測試存在」與「測試在閘門裡」是兩件事 | auditor：`65d4a32f` 上跑紅；沿 first-parent 逐 commit 跑，`ea139d1c` 起紅。派 `fix/inventories-follow-the-merges` |
| 74 | **`tests/python/test_shell_command_construction.py` 的 `SHELL_SITES` 對不上 `TopologyAndFlowMonitor.cpp:724`**：topology-round（`d00fa57c`）把 `return utils::execCommand(buildTopologyFetchCommand(url));` 包成 `classifyEndpointReply(utils::execCommand(...))`，清單沒跟 ⇒ 站點被判成「未分類＝可能被 request 控制」，兩個 case 紅 | 同 #73 的形狀。我讀過 `buildTopologyFetchCommand` 與 `url` 的來源（`'http://' + AppConfig::{RYU,P4_PROXY}_IP_AND_PORT + 字面路徑`，分支只包了回傳值）⇒ **是清單漂移不是注入路徑**——但這個判斷要 agent 再讀一次才算數 | auditor：同上，`d00fa57c` 起紅。派 `fix/inventories-follow-the-merges`；若 agent 讀出 request 可達，升級為真缺陷 |
| 75 | **`inv01_powercycle_latency()` 修好了（#17）但 runner 沒接**：`harness/chaos.py:123` 只呼叫 `inv01_power_state_agreement`，全 repo 零呼叫點 ⇒ 現行的輪次跑不到 INV-01 的延遲檢查 | existence ≠ wiring，與 #71 同族：修好一個沒人叫的函式 | #17 的 agent 查證（`doc/audit/2026-09-03_fix-chaos-invariants/FIX-CHAOS-INVARIANTS.md` §未做到）；auditor 未另行驗 |
| 76 | **proxy 卡住時，bind 失敗的 kernel 印完 `Exiting` 後不會馬上退**：shutdown 卡在 poll thread 的 `curl`（`--max-time` 3 s／8 s），8 秒後行程仍在 | 「說了要退、還沒退」——與 B-5 關機路徑同族；重啟腳本若以「印了 Exiting」當退出訊號會踩到 | #47 的 agent 順帶觀察（`doc/audit/2026-09-03_fix-cloexec/FIX-CLOEXEC.md` §7 末），**未追**、auditor 未驗 |
| 77 | 🔴 **`ndt up ovs` 跑的不是本 repo 的 `testbed_topo.py`**：`tools/test_workflow/ndtwin-lab:571-580` 的 `ovs-topo-start` 在 tmux 裡起的是 `/home/adam/Network-Traffic-Generator/testbed_topo.py`（NTG repo `6e3f388`，sha256 `ead4d84a…`），而那份**有一模一樣的常數橫幅與不回傳的 `ping_test`**（其 233-234 行）⇒ #42 在本 repo 修好之後，操作員走 `ndt up ovs` 看到的仍是舊橫幅。另：#42 原文寫的路徑 `tools/test_workflow/testbed_topo.py` 是錯的，檔案在 repo 根目錄（`components.env:80` 的 `OVS_TOPO_SCRIPT` 指它） | 兩份副本、兩個 repo、一條實際執行的路徑——「修在哪個 ref」的問題又一次（同 [public-repo-lags-trunk] 那族）；agent 沒加「兩份要一致」的測試，因為今天它就是紅的而且本 repo 修不綠 | #42 的 agent 讀 caller 時發現（`FIX-TESTBED-BANNER.md` §4）；auditor 未另行驗。**要 Adam 裁**（QUESTIONS N13）：改 NTG 那份、還是讓 `ndtwin-lab` 改跑本 repo 的 |
| 78 | **`tests/shell/check_gate_anchors.py` 對 repo 根目錄的檔案會給出自信的錯答案**：`path_at`／`default_file_of` 用 `"/" in v` 判斷「這是不是檔案」，`_repo_relative` 把 `$REPO/testbed_topo.py` 化簡成 `testbed_topo.py`（沒有斜線）⇒ 23 個錨點全被算到閘門裡唯一帶斜線的字串上，回報 `MISSING:23`——不是它設計上該給的 `NO-ANCHORS`，是一個**看起來有在檢查的錯結論** | 儀器對自己讀不懂的輸入沒有說「讀不懂」，說了「壞了」；同 #28 那族（閘門可讀性工具本身的盲點） | #42 的 agent 撞到、以 `TOPO="$REPO/./testbed_topo.py"` 繞過（閘門內有註解）；工具本身未修。全 repo 掃描 trunk vs 分支只多一列（37/50 → 38/51） |
| 79 | 🔴 **`ndt` 的 lab claim 與 pid 帳本是 per-checkout 的**：`tools/test_workflow/ndt` 的 `CLAIM="$REPO/.test_run/lab.claim"`（第 256 行）與 `.test_run/pids/`（第 243 行）都掛在 `$REPO`（由腳本位置推得）下，而 fabric、port、bmv2 行程是**全機唯一**的 ⇒ 從 worktree 下 `ndt claim` 的人，對用主 checkout 的人是隱形的（反之亦然），`measuring` 欄看不到對方。poll agent 用手動複製 claim 檔到主 checkout 繞過、release 時刪掉。同根：worktree 跑 P4 得借主 checkout 的 `p4_proxy/p4_src/build/ndtwin_switch.json`（它對過 `.p4` 的 sha256） | 共用資源、每份副本各自記帳——與 lab-claim 協定／two-writers-one-worktree 同族；claim 協定的前提「一個 claim 檔」在多 worktree 下不成立 | #46 的 agent 撞到（`doc/audit/2026-09-03_fix-poll-resurrect/FIX-POLL-RESURRECT.md` §3.3.5、⑥.6）；auditor 驗了 `ndt` 的定義行 |
| 80 | **kill 之後 1 Hz liveness worker 會用 proxy 的快取 `probe_ok` 把 `is_up` 寫回 true**：確認殺掉 bmv2 後 0.3–1.5 s 內 `is_up` 0→1，撐到 LLDP 過期（8–13 s）才回 0；**兩臂 18/18 trial 全重現**，與 #46 修法無關（那是觀測寫入，修法刻意不擋）。後果：`kPostPowerOffDistrustWindow`（15 s，**時間**界定）目前遮住這段的 API 誤判；被命令關掉的交換機在 API 上仍有 8–13 s 回 `is_up=true`。**同時更新 #46**：「復活是永久的」是 D15／#32 未修時量的（liveness 路徑當時從不執行）；D15 併入後 poll 的覆蓋在 `is_up` 上被這扇門遮住——碼裡的缺陷沒變小（fixed 臂 6/9 trial 在 poll 瞬間印出拒絕復活，逐筆對上 harness 記的 poll 落點 t_off+2.6 s） | 觀測快取的過期比事件慢——#76 的另一面（那邊是「說了要退、還沒退」，這邊是「已經死了、還說活著」）；建議 distrust window 改成證據界定（下一次真的 probe 成功才關窗），與 Q12 一起裁 | #46 的 agent 量到（`FIX-POLL-RESURRECT.md` §3.3.2、⑥.2，raw 在 `audit-raw`）；auditor 未另行量 |
| 81 | **`HttpSession::handleInformSwitchEntered`（`src/ndt_core/http/HttpSession.cpp:1449`）仍無條件 `setVertexUp`**：控制平面主動通報「交換機接上來了」時直接寫 up，會覆蓋一個被命令關掉的交換機（#46 修法只擋 poll 那扇門）。它比清單成員資格更像證據，所以 agent 沒動 | 「should replace, can only add」家族的鄰居：又一個只會往 up 寫的 writer | #46 的 agent 讀碼發現（`FIX-POLL-RESURRECT.md` ⑥.4）；auditor 未驗 |
| 82 | **OVS `powerOff` 的 `!isUp` 早退還在**（#35 的 OVS 同型）：`OVSPowerStrategy::powerOff` 在圖說 down 時直接回 Success、不刪 bridge，也走不到 #46 新的 commanded writer ⇒ OVS 平面上 #46 的修法只在關機當下 `isUp==true` 時生效。拿掉早退要先補 `ovs-vsctl br-exists` 之類的量測，因為 `executeListPorts` 對不存在的 bridge 會失敗回 500 | #35 同族（問圖不問機器）；OVS 是 `ndt up` 的預設平面，卻只有 gtest＋M9、沒有 live | #46 的 agent 指出並刻意不修（`FIX-POLL-RESURRECT.md` ⑥.3、⑥.8）；auditor 未驗 |
| 83 | **安裝副本 `/usr/local/sbin/ndtwin-lab` 是 08-30 20:20 的 `0b6db9e3`（sha `288b71cb`），trunk 的 `tools/test_workflow/ndtwin-lab` 已前進五個 commit（G-9 `pkill -f` 換 `/proc` sweep、G-7 設定檔、ports 表、#77）**——`ndt:55` 寫死 `LAB=/usr/local/sbin/ndtwin-lab`，所以 `ndt up`／`ndt down` 在這台機器上跑的是舊版，而沒有任何東西（`ndt status`、preflight、閘門）會比對兩份的 sha 並出聲 | 08-30 之後併入的四批 lab 修法在機器上**全部沒有生效**：sweep 仍是 `pkill -f`、#77 之前仍跑 NTG 的檔案；09-04 整機測試若不先 `sudo install` 就是在測舊版；而所有「走 `ndt up` 的 live 臂」自 08-30 起量的都是舊 helper（各分支的 FIX 文件沒有一份指認 helper 的 sha） | auditor 09-03 23:5x：`sha256sum /usr/local/sbin/ndtwin-lab`＝`git show 0b6db9e3:tools/test_workflow/ndtwin-lab`；`sudo -n -l` 只有 `/usr/local/sbin/ndtwin-lab` 免密碼；#77 agent `FIX-NDT-OVS-TOPO.md` §6 附帶 |
| 84 | **`ndt up ovs` 自 7 月起依賴 NTG 工作樹裡一個未提交的編輯**：NTG HEAD `6e3f3881`（04-30）的 `testbed_topo.py` 沒有 `sys.path.append('/usr/lib/python3/dist-packages')` 那兩行，它們只存在於這台機器的 NTG 工作樹（`git status` 髒、mtime 07-08 14:18）；NTG HEAD 那份在 `NTG_PY` 下實跑 `ModuleNotFoundError: No module named 'mininet'` | 在 NTG 裡 `git checkout .`／`stash`／重新 clone，#77 之前的 `ndt up ovs` 就死在第一個 import；四輪 manual usertest 的 tester 在乾淨 clone 撞到的正是這一行（`run-01-sonnet/tester-files/BUGS.md:387-395`），當時記成「手冊 bug」——根源是能跑的那份不在版控裡。#77 併入後 `ndt` 這條路不再依賴它，但**手冊教的手動路徑（clone NTG 後 `sudo ~/ntg-env/bin/python testbed_topo.py`）仍會壞**，修它要動 NTG 或改手冊（N13 說不動 NTG） | #77 agent 唯讀查 NTG（`before_08_ntg_bootstrap_is_uncommitted.log`，audit-raw `0a28f885`）；auditor 09-03 23:5x 唯讀重查（`git -C NTG status`／`diff`、HEAD 那份 import 實跑）一致 |
| 85 | **`fetchCpuReportInternal` 對每個 SWITCH vertex 做 `utils::ipToString(vp.ip.front())` 而不檢查 `ip` 是否為空**（`DeviceConfigurationAndPowerManager.cpp:1689` 附近）：一個沒有 IP 的 switch vertex ⇒ status worker 10 秒內 SIGSEGV、整個 kernel 死掉（stop agent 在 gdb 下確認：thread 4 `fetchCpuReportInternal` ← `statusUpdateWorker`） | `updateSwitches` 會為靜態拓樸檔沒有的 dpid 新增 switch vertex，來源是控制平面 `/v1.0/topology/switches` 的回覆，**那份回覆沒有 IP** ⇒ 可能是「控制平面列出一個拓樸檔沒有的 dpid ⇒ kernel 當場死」的線上崩潰；是否真的可達要先查 `updateSwitches` 新增 vertex 時 `ip` 的內容 | stop agent 09-04 凌晨（`FIX-KERNEL-STOP-BOUNDED.md` §9.5；gdb stack 在 audit-raw `2885219a` 的 `logs/gdb_segfault_no_ip.log`）；測試夾具因此給每台 switch 一個 IP；auditor 未親驗 |
| 86 | **`ndt` 的預檢與它接著啟動的不是同一支 binary**：`ndt:830` 檢查 `$REPO/build/bin/ndtwin_kernel`（主 checkout），`stack.sh:908` 啟動 `$KERNEL_DIR/build/bin/ndtwin_kernel`，而 `components.env:16` 用 `:=` 所以環境變數 `KERNEL_DIR` 可覆寫 | 預設相同、被覆寫時不同 ⇒ 預檢會對一個不會被執行的檔案回綠；任何用 `KERNEL_DIR` 跑自己 worktree 的 binary 的 live 臂（09-04 phantomovs 正是這樣做）都在這個縫裡 | phantomovs agent 09-04（`FIX-PHANTOM-FILTER-OVS.md` §八.2）；覆寫後 `LOG_DIR`／`PID_DIR` 跟著搬是實測，預檢對錯檔回綠是讀碼；auditor 未親驗 |
| 87 | **`install_group_entry`／`modify_group_entry`（meter 同型）仍把 Ryu 的 200 當作交換機接受了**：#1 的根因（Ryu 對 group/meter mod 不下 barrier、不等回覆、拒絕非同步回來對不上請求）對 install／modify 一樣成立，修 #1 時刻意只動 delete | 一筆被交換機拒絕的 install 會回 200 `installed`；後續 delete 會因 #1 的讀回而報 404（pre-check）——錯的那一筆從此看不出來 | delgroup agent 09-04 讀 `guardedMod`＋ovs4 直接打 Ryu 的對照實驗（帶 buckets 的 delete 200 但被拒）；install 被拒的實例**沒有量到**；auditor 未親驗 |
| 88 | **`findSwitchByIp`／`findSwitchByIpNoLock`（`TopologyAndFlowMonitor.cpp:3377`／`:3391`）在搜尋時對每一個 switch vertex 做 `ip.front()`**；同檔 `queryMininet:383`（`GET /ndt/get_switches_power_state` 的路徑）、`getSingleSwitchPowerReport:2154`、`getSingleSwitchCpuReport:2183`（IntentTranslator 的路徑）同型 | 一台沒有位址的 switch 不只弄壞自己那一列，是讓整張圖的 IP 查詢與 power-state 端點 UB；今天靠載入端的空 ip 拒絕（`2da6954f`）擋著，與 #85 同一條不變式 | noip agent 09-04 讀碼盤點（`FIX-CPU-REPORT-NO-IP.md` §6）；#85 只修了 status worker 路徑上的四個站點；auditor 未親驗 |
| 89 | **拓樸檔 edge 數 40→39 這件事，contract test 的 `inv_graph_matches_topology`（`tools/contract_test/spec.py:348`）看得見、kernel 自己看不見**（#61／#62 修前的狀態）——「檢查器早就知道、kernel 不知道」，與 #22–24 同形 | 知識在不會被執行的那段碼裡，是這個 codebase 反覆出現的形狀；#61／#62 修的是檔案載入那一扇門，其他三扇（W-TOPO-THREE-DOORS）仍只有檢查器知道 | topoval agent（N18 Q4）；Adam 09-04 裁「記成 finding」 |
| 90 | **四個外部 app（Energy-Saving-App、Web-GUI、TE-App、Visualizer）從沒對著跑起來的 kernel 用過**：09-02 手動測試只到安裝／建置／headless smoke（run-04 `JOURNAL.md:506`）；Q12 的 `get_switches_power_state` 形狀變更只靠 09-04 14:0x 對本地六個 repo 的 grep 證明沒有 consumer | 整機測試若開 app 就是第一次；三個 GUI repo 的 HEAD 停在 04-20，磁碟版≠部署版時 grep 證不了 | auditor grep（六個 repo：`get_switches_power_state` 零、`is_up` 五個在讀）；→ W-APPS-LIVE |


## 驗證結果（不是缺陷，但今晚第一次問得出來）

- **Round 6 關掉六道門**（推翻與確認同等有價值）：`:2020-2027` 的 Immediately 路徑**兩道保護都在**、
  實測 1.5 秒內歸零（rank 1）；per-switch epoch 正確、15 秒內復原（rank 2）；10 秒 worker 會自我修正，
  而 readopt 對活著的交換機根本回 502 mastership（rank 3）；group/meter 的 P4 臂六個端點全回 501
  `unsupported_on_p4`，**與 round 1 的 D5 是不同的東西**（rank 5、6）；`get_power_report` 的值是
  `splitmix64(dpid)`，屬於已知的 #39／#33，**不是 cache bug**（rank 7）。
- **rank 4 在 P4 上結構性到不了**：本輪自證 1929 行 proxy log 裡 `GET /p4/switch_state` **0 次**
  （對照：topology 輪詢 108 次）、liveness warning 0 條 ⇒ **獨立佐證了 #32 那個啟動競態**。
- **未 settled（刻意放掉）**：rank 6 與 rank 4 的 **OVS 臂**，兩者都需要 ovs4，約 20 分鐘，
  會來不及在期限前完成乾淨驗證。實驗設計已寫在 round6 `14_SUMMARY.log` D 節，可直接接手。
- **留下一支可控南向替身** `fake_southbound.py`（照 `ryu_topology.py` 的形狀），可單獨劣化任一端點或任一 dpid
  ——**活的 fabric 做不到這件事**；#64／#65 之後要重現直接用它，不必起 fabric。

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
