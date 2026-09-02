# 09-02 fix-design 派工對帳簿（auditor 自己的，逐 agent 更新）

## 規則
- 每個 agent 回來：①基底 ②commit 在哪個分支 ③我**自己重跑**變異閘（紅→綠）④讀 §7 裁決題 ⑤順手撞到的缺陷要不要獨立開單
- 「agent 說」≠「我量到」；本簿只記我量到的，agent 的話標「agent 報」

## A-4d ✅ 已對帳 12:5x
- 基底 4cbec52d ✓（parent 即 base）；分支 `fix/a-4d-delete-restores-p4-route` @ `a1a4a295`；3 檔 +300
- **我重跑變異閘**：HEAD green rc=0；`git checkout HEAD~1 -- proxy_agent/topology_manager.py` 後 red rc=1（6 顆 3 紅、3 控制組綠）；還原 clean。
  - 附註：`proxy_agent` 是 namespace package（`__file__`=None），改用「倒回 worktree 的檔案 ⇒ 結果翻轉」證明跑的是 worktree 那份，比 `__file__` 更強
- 真因（agent 報，機制我讀了 §2 認同）：install 與 delete 寫同一個 `dst/32` LPM key ⇒ INSERT 被拒落到 MODIFY 覆寫控制面路由 ⇒ delete 刪掉唯一一筆；default action 是 `send_to_cpu` 不是 drop ⇒ 黑洞＝punt 後 `handle_packet_in` 只認 LLDP
- 修法：`unroute_flow` LPM 分支「有控制面路由就還原（同一支 insert ⇒ 原地 MODIFY、零空窗），沒有才真刪」
- **§7 四題待 Adam**：Q1 TE 規則改走 5-tuple？(建議不改，是設計變更) Q2 留不留「真黑洞」出口？(建議不留) Q3 delete 時重算 dest_paths？(建議不) Q4 順手缺陷開單？
- 🔴 **順手撞到：`BLOCK_HOST` 在 P4 模式完全不生效且回 success**。我讀了兩端：`IntentTranslator.cpp:728` `actions = json::array()` 空、match 只有 `ipv4_src` 無 `ipv4_dst`；`topology_manager.py:880-882` `if not ipv4_dst: return False`。kernel 端 try 只接 exception，False 不會變錯 ⇒ 印「Blocked host」回 `{"status":"success"}`。**兩端讀碼確認、未執行。示範若有 block-host 動作就是台上穿幫。建議開單。**
- 未做：NOT COMPILED（C++ 無改動所以無所謂）；live 驗證腳本在 §6.2 含三組負控制

## F-1 ✅ 已對帳 13:0x
- 基底 4cbec52d ✓（parent 即 base）；分支 `fix/f-1-mininet-health-metrics` @ `316703e7`；7 檔 +504/−29（含 API 文件 §12/§13/§21、`selftest_fixtures.py`、C++ 測試 230 行）
- **我重跑 Python 紅／綠**：HEAD green rc=0（6 顆）；倒回 `tools/contract_test/selftest_fixtures.py` ⇒ red rc=1、6 顆全紅；還原 clean。用的是 miniconda python3（agent 也是）——這支測試純 schema 比對，不需要 grpc
- **C++ 測試 `tests/test_SimulatedDeviceMetrics.cpp` 8 個 TEST_F：NOT COMPILED、never seen red。worktree 無 build/ 目錄，我驗過。⇒ 真正的 `-1` 行為仍未驗，要等我批次編譯**
- 機制補充（agent 報）：捏造點是四處不是三處——多一個 `:1810` `getSingleSwitchCpuReport`（IntentTranslator 單台路徑），**KNOWN-ISSUES 條目漏了它**。`% 50` 五十個桶、十台交換機撞號 ≈ 60%（生日問題，我心算核過 ≈0.62）
- 修法：四處改回既有哨兵 `-1`（`kHealthMetricUnavailable`）；`spec.py:502` 本來就 `Num(min=-1,max=100)` ⇒ 零 schema 變更；Energy-App 不消費這三值（`components.py:144-165`）
- **§8 四題待 Adam**：Q1 `ndt status` 的「fabricated」提示何時翻面（建議等編譯＋部署同一 commit 翻）；Q2 KNOWN-ISSUES 現在不標（建議不標，沒編譯）；Q3 🔴 **Network-Traffic-Visualizer 完全沒有 `-1` 處理的證據、且 repo 不在這台機器** ⇒ 示範建議先不開它；Q4 Web-GUI 把 `-1` 顯示成什麼、台上口徑
- 順手撞到 UB：`:1594` 溫度迴圈在過濾頂點型別前就 `vp.ip.front()`，空 vector 即 UB（見下一則我的親讀）

## F-1 順手 UB —— 我親讀確認 13:0x
- `DCAPM.cpp:1594` 溫度迴圈 `vp.ip.front()` 在 `vertexType != SWITCH` 過濾**之前**；`:918`（memory）與 `:1519`（cpu）都是先過濾再取。空 `ip` vector ⇒ UB。**讀碼確認、未執行。** 一行搬位即修，但要編譯；歸入批次編譯那一輪。

## RESTORE-SWEEP ✅ 已對帳 13:1x（唯讀 agent，repo 未動）
- **我親讀確認兩條**：
  1. `tools/test_workflow/ndt:445 sample_rate()` 只取 `hi[1]`（rng 上界）`+1` ⇒ 下界被改成 1（取樣關）時照印 256。**`ndt status` 的 `sample rate` 欄對「取樣關掉」是盲的。** 而 `stale_pipeline()` 只抓「live fabric 下重編」這個方向。
  2. `lib_e.sh:931` `RUN cp -f` ⇒ unlink 繞過 ETXTBSY，磁碟 sha 變了、執行中的行程沒變；`:932` 印的 sha **量的是檔案不是行程**；靠下一行 `teardown` 救。
- agent 報（我未逐一重讀）：`zero_cell.sh:50-61 restore_p4()` 只寫 `.p4` 且是 EXIT/INT/TERM trap ⇒ 三條 `exit 1` 路徑都留下取樣關閉的 JSON；happy path `p4c` 不讀 rc；**沒有任何東西抓 R1**；12 份獨立 `compile_at` 副本、無共用 helper；`run_f5.sh:190` 宣稱一個腳本裡不存在的 binary swap；F-5 從未 live 跑過
- 曝險窗：`run_e8.sh` 02:18:34 設 1/8 後 abort、宣告「restore left to operator」，`wall_f.sh` 02:59 先重編 ⇒ 約 40 分鐘無任何 round 資料落在裡面。**靠運氣不是靠還原。**
- 正確範本已存在：`run_ab.sh:54-101`（down-first、讀 rc、驗 sha、重編）；`restart_kernel.sh:11,72`（`/proc/<pid>/exe` 驗執行中）
- 未關閉：`audit-raw` 分支內容沒讀 ⇒ 08-26 窗未完全排除；`zero_cell.sh` 09-02 00:23 的 JSON 狀態永久不可考

## RESTORE-SWEEP Q-D（run_e8 曝險窗）—— 我自己查了，13:2x
- 窗＝2026-08-26 02:18:34（`run_e8.log:48` ABORT）→ 02:59:00（`wall_f.log:1` 開跑並先重編）。
- 掃 `lab/audit-raw` 的 `doc/audit/2026-08-25_sampling-rounds/` **1458 個檔**，三種樣式：`^\[02:(18-59):`、ISO `2026-08-26[T ]02:(18-59)`／`08-26 02:`、epoch `1787681914..1787684340` ⇒ **三種都 0 命中**。
- 判定：**已查、無 raw 落在窗內**（不是「沒去找」）。盲點：不帶任何時間戳的 raw 檔不在這三種樣式的覆蓋內；我沒有逐檔開。
- 我親讀 `ndt`：`$rate` 四個消費端（`:579 :596 :1293 :1296`）全是 `1/$rate` 的印出，沒有算術、沒有比較；repo 內沒有任何腳本 parse `ndt status` 的 sample rate 行（只有 HANDOFF／TRANSCRIPT 引用輸出）⇒ 改回傳為 DISABLED 字串**外部無破壞**，內部四處要一起改印法。ndt 在 `:2105` 有 source guard ⇒ 可被測試 source。

## B-3 ✅ 已對帳 13:3x（純 C++，無法跑紅綠；改驗兩個系統性宣稱）
- 基底 ✓；分支 `fix/b3-historical-logging-honest-reply`，3 commits（`626084bb` seam+tests、`8a1dcbdd` 行為、`3f04b99e` allowlist——**三顆要一起落**，否則 `check_logs.py` 對每個 MININET run 變紅）；6 檔 +397/−12；**NOT COMPILED、never seen red**（agent 自陳，§6.1 有兩次 checkout 的紅→綠配方）
- **我 grep 確認**：
  1. `HttpSession.cpp:117-120 buildResponse()` 以 `http::status::ok` 建構 ⇒ **任何沒呼叫 `res.result()` 的 handler 一律回 200**。這是 F-13／B-3／B-4「沒做事卻回 200」整族的共同根。
  2. chaos harness `_c07`（`actions.py:275/281/293`）打 `/ndt/set_historical_logging` 與 `/ndt/get_historical_data`——**兩條路由在 HttpSession 裡都是 0 命中**；真正的路由是 `/ndt/historical_logging`（`:289`）。`probes.py` 丟棄 status code ⇒ 404 也算「rows==0 ⇒ B-3 reproduced」。**`05_first-live-run.md:203` 的「verified true」是儀器假象。** 要記進 KNOWN-ISSUES 的儀器缺陷段。
- agent 報（未重驗）：MININET 早退在 `HistoricalDataManager.cpp:51`；`m_running.exchange(true)` 是 `or` 的左運算元 ⇒ MININET 留下「running 但無執行緒」；`canRecord()` 是模式判定不是存活判定；**六個捏造值站點打到四個端點零揭露**，含 `intent_translator/text` 把合成數字餵給 LLM 當事實——F-1 只點名其中兩個
- 修法：維持 200、`status` 改成可分辨（`not_applicable`）＋穩定 `reason` token（`spec.py:789` 鎖 `[200,500]`，08-31 驗過 51/51，所以不走 501/409）

## ndt sample_rate 修補 ✅ 我自己做的，13:4x
- 紅（`ndt.old`）rc=1：lo=1 印 256；綠 rc=0 6/6；變異閘 3/3 抓到、baseline byte-identical。以 atomic rename 換檔（另一 session 執行中的 ndt 不受影響）。
- commit 在 trunk、已推 lab。改動：`sample_rate()` 讀兩界、`rate_label()`、`source_ahead_of_build()`、`cmd_status` 兩個新 problem；四個印出點改用 label。
- 設計裁量（我判的，步驟級）：選 B1（取樣關掉時值改成文字，故意讓任何做 `1/N` 算術的 parser 大聲壞）而非 B2；repo 內無 parser，風險＝0。Adam 若不同意可回 B2。

## F-13 ✅ 已對帳 13:4x（純 C++，UNVERIFIED）
- 🔴 **agent 在 detached HEAD 上 commit、沒建分支**——我已 pin 成 `fix/f13-group-meter-existence` → `3ce21cc5`。其他還在跑的 4 個 agent 也是 detached（A-8、A-9、B-2b/B-4、F-6），完成時要逐一 pin。
- **我從本機 Ryu 原始碼確認**：`ofctl_v1_3.py:1151` 只 `send_msg`（無 barrier、不等回覆）；`ofctl_rest.py:276-277` `method(...)` 後立刻 `Response(status=200)` 空 body。⇒ kernel 沒東西可判；delete 打不存在 group 在 OF1.3 是靜默 no-op ⇒ **先查是唯一辦法**（TOCTOU 只縮窗不關窗，agent 自己標了）。
- 12 檔 +1236/−32、30 gtest、無 build/ 目錄。6×2 矩陣 12 格回應完全相同、6 格錯；**F-13 列漏了 install-on-existing 兩格**（方向更糟）；六端點無 get。KNOWN-ISSUES 四個引用三個行號漂了。

## B-1-VERIFY ⚠️ 已對帳 13:4x —— **它的變異宣稱我沒重現**
- 分支 `agent/b-1-verify` @ `7fc77907`，只加一個 `tests/python/test_t11_filter_is_wired.py`（209 行，讀原始碼文字的「接線」測試）。HEAD 綠 rc=0（5 顆）。
- **我的 M1（把 `DCAPM.cpp:1975 stripUnprogrammedEntries(...)` 整行加 `//` 註解掉）⇒ 測試仍綠 rc=0。** agent 報「M1/M2/M3 全 RED」。差異待查：它的 M1 可能是「刪行」而不是「註解」——若它的測試做子字串比對，被註解掉的呼叫仍匹配 ⇒ **接線測試看不出「被註解掉」**，正是它自己指控 gtest 的那種洞。控制組 C1 綠。
- 它的重大讀碼發現（未實測、我也未驗）：**OVS 上 T-11 過濾器根本不生效**（Ryu 200 空 body ⇒ `OpResult::success` ⇒ token 蓋章 ⇒ 幽靈照服務）；08-31 的修是視圖過濾在唯一共同讀出口，狀態仍污染（`modifyOne/deleteOne` 走原始陣列）。建議拆 B-1a（P4 RESOLVED）／B-1b（OVS OPEN）。

## 批次對帳 14:0x（全部 16 個我的 worktree 基底 4cbec52d ✓；4 個 detached 已 pin：A-9→pin/a2f68…、B-2b/B-4→pin/a6f97…、A-8→pin/a7849…、F-6→pin/a8c31…）
- **A-4c ✅ 我重跑**：75 tests 綠 rc=0；倒回 4 個 proxy_agent 產品檔 ⇒ rc=1、errors=21。分支 `fix/a4c-proxy-restart-honesty` @ `05976e27`，8 檔 +1282。機制：`main.py:189-201` 重啟無條件 `set_forwarding_pipeline_config`＝`VERIFY_AND_COMMIT` 清空所有表；kernel **完全沒有 intent store**；`Classifier` 對缺席 switch 無限期保留舊規則。修法 (a) `boot_id`＋per-switch `table_generation` 掛在 `/p4/switch_state`（**目前沒有 kernel 讀者＝有寫者沒讀者**）；(b) append-only journal 記錄端接線、replay 刻意不接。
- **NDT-HARNESS ✅ 我重跑**：34/34 綠；變異 12/12 殺；倒回 `lib.sh` ⇒ 12/34 紅。分支 `ndt-harness-t9-t10-instruments` @ `b4059384`。**KNOWN-ISSUES 行 02/05 已過期**（T-9/T-10 修在 `cd440488`，是 base 祖先；同內容雙胞胎 `e2098033` 不是）。真正未修的：`WATCH_S`/`WATCH_ACTUAL` 只 `info()` 印、**註冊窗與實跑窗從未被比較** ⇒ 加 `assert_window_span`。`port_holder` 是 `ss -lptnH` 無權限時看不到 `users:` ⇒ 空回傳被讀成「沒有」⇒ 三態 `LISTENER-OWNER-HIDDEN`。⚠️ **它改了 `doc/KNOWN-ISSUES.md` 4 行**（在它分支上）——合併前要看。
- **F-15 ✅ 我重跑**：27 綠 rc=0；把 base 翻回 50050 ⇒ rc=1、4 紅。分支 `fix/f15-grpc-port-block` @ `858ebda2`。本機 `ip_local_port_range`=32768–60999，50051–60 **10/10 在範圍內**；今天 `ss` 看到 10 個無關長期 listener 在範圍內、一個在 50841。**第二缺陷：兩支 bring-up 偵測到失敗仍 exit 0 繼續**；KNOWN-ISSUES 引用的 `ASSERT FAIL: bmv2 did not all start` 守衛**repo 裡不存在**（那是審查員自己的 harness）。修：base→30050（30051–60）、單一來源 `grpc_ports.py`、pre-flight 對 `/proc` 檢查、partial fabric 改 fatal。🔴 **~20 處文件＋5 支手跑 probe 仍寫 50051**；示範機要先 `cat /proc/sys/net/ipv4/ip_local_port_range`。
- **F-8**（未重跑 Python 契約；C++ UNVERIFIED）：分支 `fix/F-8-declared-link-capacity` @ `53f7957a`，10 檔 +530。**推翻條目一半**：對從未有流量的邊是**永久**錯誤不是暫態（MININET counter-sample 分支 `FlowLinkUsageCollector.cpp:1102-1107` 直接 `continue`）。宣告容量其實讀了（`TopologyAndFlowMonitor.cpp:320`）只是寫錯欄位。16/288 條核心邊 10G 報 1G＝少報 33%；**272 條「巧合正確」無欄位可分辨** ⇒ 加 `left_link_bandwidth_source`。唯一活消費端 `get_graph_data`。
- **B-x**（C++ UNVERIFIED、有一 case 修前會 segfault 中斷 gtest）：分支 `fix/bx-flow-liveness` @ `58aa5569`，12 檔 +1030。92% 是**實測**（PREREG `59d58fb`／raw `8c9e841`）但單一工作點；`:821` 加乘不再主張（速率已歸零、3040 次觀察 dead-AND-nonzero=0，成立的是母體填滿）。三態 `active/idle/ended`；**92% 全是 idle**——若寫成布林「排除 ended」會通過 review 卻幾乎什麼都不移除。路由 `:158` 精確比對帶 query 會 404 ⇒ 加 `utils::pathIs`。
- **F-6**（C++ UNVERIFIED；演算法以 Python 轉寫 40 斷言＋6 mutant 全殺）：pin/a8c31… @ `4a004db7`，5 檔 +685。`continue` 不是「保留」是「這輪不產生」，worker 整份取代 ⇒ 沖掉；**`Classifier::updateFromQueriedTables` 早就是逐 dpid upsert** ⇒ 同一輪 poll 兩子系統答案不同。選「保留＋標記」（`stale_since/stale_polls/last_error`），`isUp==false` 那條刻意不 carry。已知副作用：`inv_tables_non_empty` 對 `never_read` 會變紅。
- **F-14+F-16+F-4**（C++ UNVERIFIED，7 測試含 2 負控制）：分支 `fix/optimistic-topology-reporting-f14-f16-f4` @ `21712f3b`。共同根 A：`isUp` 賦 `true` 六處、`false` 零處，且 liveness／`link_failed` 定義域都不含 host。根 B（F-4 獨立）：`updateHosts` 邊查找只比 IP 不比 dpid、MAC 不符時 `:723` 無 `continue`。**關鍵：對帳式修法在 host 上永遠不觸發**（Ryu `HostState` 無 timeout、P4 圖 append-only）⇒ 改從 switch 三態 liveness 推導（連續 2 poll ⇒ 邊與 host 標 down 帶 `down_reason`，恢復不主動標 up）。路由不受影響（`getAllPathsBetweenTwoHosts` 零呼叫端）。**建議翻案 F-4 的 08-18「不修」**，留 Adam。
- **A-4f**（Python 13 紅→綠、4/4 mutant；C++ 11 測試 UNVERIFIED）：分支 `fix/a-4f-sflow-lost-on-power-cycle` @ `f0fb29e8`。OVS-only：`OVSPowerStrategy.cpp:171 del-br` 回收 sFlow 記錄＋bridge 內部 port 的 mgmt IP；`powerOn :97-112` 兩者都不重建。P4 的 `readopt` 早就做了對應的事（`P4PowerStrategy.cpp:104-121`）。無人察覺：`m_counterReports` 永不清 ⇒ 每秒發 0，與 idle 位元相同；`EdgeProperties` 無 timestamp；`getAvgLinkUsage:2866` 跳過零邊。修：powerOff 存記錄、powerOn 回放並**回讀**；`get_graph_data` 加 `telemetry_status`。⚠️ 依賴 sudoers 允許 `ovs-vsctl get bridge`／`list sflow`，否則降級為只回報。**它正確拒絕了我誤送的 A-9 addendum。**

## B-2b+B-4 ✅ 我重跑 14:1x（Python 4 綠 rc=0；倒回 `HttpRoutingStrategyBase.cpp` ⇒ rc=1 2 紅；C++ UNVERIFIED）
- pin/a6f97… @ `8084c6fc`（2 commits）。**我親讀**：`ControllerAndOtherEventHandler.cpp:90` `tcp::endpoint{tcp::v4(), NDT_PORT}`＝綁 0.0.0.0；`HttpRoutingStrategyBase.cpp:82-84` `curl … -d '<body.dump()>'` 走 `popen`。⇒ **未認證遠端命令執行**（無 Authorization 檢查）。
- agent 報：一個根三個站點（Routing `:82-84`、SimulationRequestManager `:124-125`／`:150-151`）；**`app_register` 的 `simulation_completed_url` 內插在雙引號 ⇒ `$(...)` 展開一個引號都不需要**（KNOWN-ISSUES 沒記）；另 `HttpSession.cpp:1363` 手串 JSON、`IntentTranslator.cpp` 22 處同形、`ApplicationManager` 跳錯層（BRE 非 shell）；`execCommand` 呼叫點 19 個（KNOWN-ISSUES 的 11／14 兩個數對不回來）。修：`utils::execArgv`（fork+execvp 無 shell）、`OpResult::notSent`(500) 與 `unreachable`(502) 分家、B-4 的 202 等模擬伺服器回答後才送、補兩個 curl 從未有的 timeout。
## A-8 ✅ 我重跑 14:1x（22＋113 綠、selftest 綠；倒回 spec/check_logs/l3 ⇒ rc=1、15 紅 4 錯）
- pin/a7849… @ `fb68ef1d`，10 檔 +1182/−53。三個工具＝L2 `spec.py:161/:186`（`inv_all_switches_up`／`inv_edges_enabled`）、L3 `l3_component_check.py`（繼承 L2 判決扇出 6 元件）、`check_logs.py:240`＋缺的 allowlist 條目。**08-18 建議的修法是死的**：`admin_disabled` 標的是 Intent Translator 的 DisableSwitch 不是 power app，實測 false ⇒ 要 key 在 `/ndt/get_switches_power_state`。三態：down+ON＝failure、down+OFF＝`ACCOUNTED-FOR`、讀不到＝`TOOL-PRECONDITION-FAILED` exit 3。R5 harness `40_r5_p4.sh:324`／`50_r5_ovs.sh:219` grep 字面 `switch(es) not up`／`BROKEN` 判 A-8 在不在——新路徑不可出現這些字，已用測試釘住。

## A-9 ✅ 到齊 14:2x（C++ UNVERIFIED，never seen red/green；只跑過 23/23 mutation-target 唯一性＋`bash -n`）
- 分支 `fix/a-9-lock-lease` 3 commits。**機制更正**：鎖**有**到期（`LockManager.hpp:210`（原記 :203，14:1x 驗正）），缺陷是到期是「條件」不是「事件」——`isLocked` 從不清 ⇒ 死租約 `unlock()` 回 true、`/ndt/release_lock` 回 `200 released` 與真釋放位元相同；晚到的 release 清掉**新**持有者的 flag。300s 租約會到期但 app 1Hz retry 一秒內重拿 ⇒ polling livelock。
- 🔴 **kernel 從不檢查 `routing_lock`**（`m_lockManager` 只被三個 lock handler 用）⇒ 因果鏈全走 app 自己的 gate，`set_switches_power_state` 不受影響。KNOWN-ISSUES「任何要 routing_lock 的操作都吃 423」要改成「任何 *acquire*」。
- B-2②：A-9 的 `leaseId` 就是②要的 token；加 `setRequireLeaseId()`（預設關、**沒接線**）⇒ ②仍 OPEN。順手發現 A-9 重構讓 `mutate_lock_renew_expiry.sh`（B-2①）**六個 mutation target 全失效**（gtest 仍綠、閘門跑不了）——已重寫。
- App 側（唯讀）：八條 acquire 後的出口不 release，`easy_enable_switch()` 完全沒 release；修法形狀＝RAII＋in-flight simulation deadline；未在該 repo commit。

## Adam 裁決 14:2x（互動表單）
1. **RCE：全部站點掃完才合**（非我建議的 3 站點先合）⇒ 已派回 B-2b/B-4 agent 掃 19+22+2 站點、加零殘留 grep 守衛。
2. **F-15：接受換號，文件與 probe 同一次合併改完** ⇒ 已派回 F-15 agent；歷史 audit 記錄不改、列為 historical。
3. **BLOCK_HOST：示範沒有此動作 ⇒ 開單排後**（標「讀碼推論、未實測」）。
4. **KNOWN-ISSUES：編譯＋變異閘過了再一次批改**。
## 下一步（不需裁決）：mainDev 14:55 release 後，單一 build worktree 逐分支 checkout → ninja 增量 → gtest → 各自變異閘；只合過閘的。

## 續做回報 13:2x–13:3x
- **B-1 ✅ 關閉**：agent 改成剝註解／字面量／`#if 0` 再比對，`b19045b0`；**我的 M4（註解掉 :1975）重跑 ⇒ rc=1、16 顆 3 紅**。它自陳唯一存活 M9（predicate 永遠 true）是語意層、由 gtest T4 守——合理。仍待人實測：OVS 上過濾器不生效（讀碼）。
- **B-3 mutate 腳本** `tests/shell/mutate_b3_historical_logging.sh`（9 個 C++ 變異＋1 控制＋1 已實跑的 allowlist 變異 rc 0/1）。target `test_routing_strategy` filter `HistoricalLogging*`。三顆 commit 要一起落。
- **F-1 mutate 腳本** `tests/shell/mutate_f1_mininet_health_metrics.sh`（M1–M7＋C1；**M5「更好的假值」是關鍵**：若存活＝套件釘的是舊公式不是性質）。target `test_routing_strategy` filter `SimulatedDeviceMetricsTest.*`。⚠️ repo 把所有 gtest 連成一顆 binary ⇒ batch_compile 的 ctest -R 要對 filter 名，不是檔名——**batch_compile.sh 的 newtests 推導要改**。
- **F-8 mutate 腳本** `tests/shell/mutate_f8_declared_link_capacity.sh`（`28a9b550`）：4 變異＋comment 對照＋契約紅綠（不需 build、已實跑）；**腳本本身 force-red/force-green 過（stub 掉 cmake 與 test binary）**。兩個比參考腳本嚴的決定：編不過／anchor 移位**計為 survivor**；**每次還原後 `touch`**——`cp -p` 會還原舊 mtime ⇒ ninja 不重建 ⇒ 下一個變異測到上一個 mutant。⚠️ 這個 mtime 坑要查其他八支。
- **F-15 文件＋probe 換號完成**（分支同，未 push）：51 檔命中、23 檔更新、5 支 probe 改 import `grpc_ports`、18 檔封存不動、新守衛 `NoLiveDocumentStillNamesTheOldPortBlock` 紅（22 offenders）→綠、31 tests 0 skip。🔴 **stale `.pyc` 坑**（同長度改動＋秒級 mtime）——已寫進狀態檔。⚠️ **它改了 KNOWN-ISSUES F-15 列成 ✅**——合併時對齊 Adam 裁決。`gate_d.sh:42` 封存活邏輯要改指。

## 變異閘腳本到齊 13:3x（四支，全部 NOT COMPILED / never executed；我量到的只有：基底 ✓、分支有名、tree clean、`bash -n` 0）
- **F-13** `fix/f13-group-meter-existence` @ `40bcb7de`（3 commits，13 檔 +1808/−32）`mutate_f13_group_meter_existence.sh`：5 變異＋1 註解對照（A/A′/A″/B/B′/C）。agent 報：30 顆測試裡有 1 顆沒有任何變異能殺（`AControllerRefusalOfTheModIsStillReported`）⇒ 補 A″；**A′ 要改兩處不是一處**（`entryExists` 三個 early return＋`guardedMod` 的 ternary），設計稿寫錯已改。anchor 移位原本只設 harness fault ⇒ 現在計 survivor 且 exit 2。它自己點名三個可能編不過的位置：`HttpRoutingStrategyBase.cpp:386`（結構化綁定初始式是成員函式 `get`——我判：類別作用域先找到成員、ADL 被抑制，應該過）、`:465`（`const char*`+string 鏈尾接不同長度字面量的 ternary——衰變成 `const char*`，應該過）、`tests/test_GroupMeterExistence.cpp:60`（同型別 alias 重宣告，合法）。編譯見真章。
- **F-6** `fix/f-6-stale-table-carry-forward` @ `65cc9b3a`（3 commits，6 檔 +1270/−12；**已從 pin 改名，branches.txt 已改指**）`mutate_f6_stale_table_carry_forward.sh`：7 變異＋1 宣告未覆蓋（#8 merge 在寫鎖外讀 cache——單執行緒 gtest 看不到，要 TSan，另開單）＋NEG。**寫閘門抓到自己第一版兩個假綠**（`c1b1b43e`）：`isUp` 守衛改成 `isPollableForFlowTable()`（原本變異 3「down switch 被 poll」是綠的＝把 F-6 變 F-4/F-16 沒人看到）；merge 抽成 `applyFetchedTables()` 讓三個 wiring 測試斷言端點**真的服務**carried table。編不過原本會**扣掉**變異數 ⇒ 現在計 survivor。`anchor_count` 用 python `.count()`——`grep -c -F` 對兩行 anchor 報 2。副作用重申：`spec.py:295 inv_tables_non_empty` 對 never_read 會紅（訊息錯：「empty」其實是「never read」）。
  - 🔴 **它指出 `tests/shell/mutate_rate_denominator.sh:47` 有同一個洞——我親讀確認**：`mutant does not compile` 印 ⚠️ 後 `restore; return`，不計 survivor。這支是 trunk 上既有的參考腳本（不在本批），且其他 agent 有人從它抄——**批次結束後補一行**（compile-fail ⇒ survivor）。
  - 它說共用 scratchpad 的 `fix-designs/F-6_check_anchors.py` 被別的 agent 覆寫過——18 個 agent 共寫同一目錄，檔名沒加前綴的會互撞；批次時只信分支裡的東西。
- **B-x** `fix/bx-flow-liveness` @ `7d678ed0`（2 commits，13 檔 +1535/−13）`mutate_bx_flow_liveness.sh`：7 變異＋CONTROL。**兩個必要變異在紙上就存活**（`kFlowActiveWindowMs=1e9`：collector 測試全走 seam 沒人讀常數；`API default→All`：repo 裡沒有任何測試用真 collector 服務請求）⇒ 補 `TheActiveWindowSitsBetweenARateLoopPeriodAndTheIdleTimeout`（斷言關係：window < FLOW_IDLE_TIMEOUT 否則 idle 不可達）與 `TheEndpointDefaultIsActiveOnlyRatherThanTheWholeTable`（⚠️ 釘值不釘行為，缺 `HttpSessionTestPeer` 帶真 collector）。它自抓三個錯：`grep -cF` 對 5 行 anchor 數出 121（改 python）；signal death（>128）與 hang（124）分開分類；最後一次 rebuild 原本 `build || true` ⇒ 會把 mutant binary 交給批次裡的**下一支閘門**——已改成失敗即 restore 判壞。
- **F-14/16/4** `fix/optimistic-topology-reporting-f14-f16-f4` @ `6db478ca`（2 commits，7 檔 +1469/−6）`mutate_optimistic_topology_reporting.sh`：16 變異＋對照，9 cases `OptimisticTopologyReportingTest.*`。**寫閘門抓到三個讀碼沒抓到的洞**：從 `updateGraph` 刪掉 `reconcileDerivedLiveness()` 呼叫七顆全綠（測試直接打 seam）⇒ 加 wiring 測試；`=1000` 全綠（迴圈上界就是那個常數）⇒ poll 次數改字面 `kPollsToIsolate`；MAC-not-found 分支加 `continue` 讓 F-4 測試綠**同時解除武裝**。三個 F-4 守衛不可獨立觀測（能到方向檢查的輸入都已被前置拒絕）⇒ 6a/6b/6c 斷言「保持綠」、7a/7b/7c 斷言殺——它明說，沒裝。build-fail／anchor 移位原本記 BROKEN 且 anchor 移位 exit 2 ⇒ 現在計 survivor 且繼續跑。提醒：未修樹上唯一編得過的紅→綠候選是 `ASwitchLearnedAsAHostDoesNotResurrectASwitchLink`，其餘八顆要先註解才能看紅（§6.1）。
- 批次現況：10 支分支裡 9 支有 mutate 腳本；A-9 有 4 支（`head -1` 取到 `mutate_lock_lease_all.sh`，應是總閘，A-9 回來時確認）；B-2b/B-4 尚無（agent 還在掃全站點）。lab 仍是 mainDev 到 14:55。
- **A-9** `fix/a-9-lock-lease` @ `3dfa51cc`（5 commits，12 檔 +2472/−94，tree clean）4 支腳本：總閘 `mutate_lock_lease_all.sh` 串三閘（lease_expiry 9／renew_expiry 6＝B-2① 修復／ownership 8＝B-2②），23 變異。**我在它的 worktree 實跑 `--dry-run` rc=0**（只證 23 anchor 唯一命中，不是變異結果，腳本自己也這樣講）。agent 報：原本 compile-fail 進獨立 `BUILD-FAIL` 欄、anchor 缺 `exit 2` 棄掉其餘結果 ⇒ 改成兩者都 SURVIVED、`build_failures`/`anchors_missed` 只當子集印。它實測過「故意壞一個 anchor」⇒ 不中止、報 survived=1、runner exit 1。**TTL 值無測試依賴**（C++ 引用全是符號 `DEFAULT_TTL_SECONDS`，新測試用字面 0/60/300/3600/7200 自配對）；真硬編 5 的在 `tools/contract_test/spec.py:43 LOCK_TTL=5` 與 Energy-App `http.cpp:425 ttl:300`。⚠️ 預設 ≤0 讓每張租約生來就死而兩個既有斷言都綠——若 Adam 選那種值要補測試。batch 用 `head -1` 取到的正是總閘 ✓。
- **A-4f** `fix/a-4f-sflow-lost-on-power-cycle` @ `e9993f9f`（2 commits，14 檔 +1743/−11，tree clean）`mutate_a4f_sflow_power_cycle.sh`：5 變異＋對照，filter `OvsPowerStrategyTest.*:OvsPowerStrategyConcurrencyTest.*:TelemetrySilenceTest.*`。**我實跑 `ANCHOR_CHECK=1` rc=0**：5/5 anchor 唯一、還原 byte-identical（無 build）。變異 5「telemetry_status 永遠 live」原本無測試可及 ⇒ 抽 `classifyTelemetry` 純函式＋8 顆 `TelemetrySilenceTest`。它自抓三個錯（`apply` rc 沒被讀 ⇒ 未變異的 binary 被跑來計分；負控制加 `// ` 改了縮排等於沒複製；多行 anchor 只複製第一行）——第九形式，寫防護腳本時自己犯。**sudoers 我查了：`(root) NOPASSWD: /usr/bin/ovs-vsctl`（無 argv 範圍限制）⇒ 本機 `get bridge … sflow` 走得通，降級路徑不會觸發；示範機另查。**
- 到此 **9/10 分支有可跑的閘門且全部 `bash -n` 過**；剩 B-2b/B-4（全站點掃描中）。所有 C++ 仍 NOT COMPILED。

## B-2b/B-4 全站點掃描 ✅ 我重跑 13:5x
- 分支 `fix/b-2b-b-4-no-shell-strings` @ `051faf12`（4 commits，21 檔 +1621/−148，tree clean；branches.txt 已從 pin 改指）。**我重跑 Python 守衛**：HEAD 7/7 綠 rc=0；把 6 個產品檔倒回掃描前 `8084c6fc` ⇒ rc=1、**4 紅**（intent 手串 JSON、sudo nfs 非 argv、有請求可控字串到達 shell 站點、站點清單≠分類表）；還原 dirty=0 再綠。與 agent 報的 4/7 一致。
- agent 報（我未逐點重讀）：🔴 **它自己第一版母體錯**——grep `execCommand|std::system|executeSystemCommand` 漏掉兩個裸 `popen(`（`OVSPowerStrategy.cpp:34`、`SSHHelper.hpp:52`）⇒ 真母體 28 執行點／20 相異行。遷 4＋3、留 21（逐點 CONSTANT／CONFIG／NUMERIC 附證據）、無法遷 2、`REQUEST` 判定 0 ⇒ **今天樹上仍走 shell 的有 23 個點但沒有一個吃請求字串**。守衛 `SHELL_SITES` 未分類一律 `REQUEST`（推定有罪）。IntentTranslator 22 處手串 JSON 改 `json{}.dump()`。
- 🔑 兩個「本來就不可利用」的站點安全是偶然的：`action` 靠兩層 call frame 外的白名單、`deviceIdentifier` 靠 `== ipToString()` 的副作用——放寬那個 `==` 就無聲變成 injection。`ApplicationManager` 是「非請求可控仍遷」的唯一例外：BRE 跳脫放進 `'…'` 交 shell，`'` 兩張表都沒有 ⇒ 瞄錯層的跳脫比沒跳脫更糟。
- 它差點犯的：把 `purgeSurvivors` 的編譯錯留給編譯器 ⇒ 整顆 test target 編不起來，已在 `051faf12` 修。**C++ 仍 NOT COMPILED**；無 mutate 腳本（3 個新 C++ 測試各附「復原哪一行會紅」的手動配方）。
- **待 Adam**：Q2 `--max-time 30` 對模擬伺服器夠不夠；Q3 202 body 形狀變更要不要相容。
- ⚠️ 相關：spawn 時的 Monitor（lab 釋放）已不在本 session 任務清單 ⇒ 重掛。

## 批次前置 14:0x（我做的）
- Monitor 重掛（`bnu1x34iz`，persistent）：每 60 s 讀 `ndt status`，claim 不再是 `9/1 mainDev` 就通知並退出；連 5 次讀不到也會叫。
- `buildwt` 已 configure（Ninja、Debug、`CMAKE_CXX_COMPILER_LAUNCHER=ccache`；本機 ccache 67% 命中、0.2 GiB）；**主 worktree 根本沒有 `build/`**（`ndt` 期待 `build/bin/ndtwin_kernel`，mainDev 的 kernel 從哪編的我沒查）。磁碟 8 GB 可用（92%）——批次要留意。
- `batch_compile.sh` gate 0 改成接受 auditor 自己的 claim；新 wrapper `run_batch_claimed.sh`：claim 150 分（註明重 CPU、不碰交換機）→ 批次 → trap 釋放。
- 已通知 9/1 mainDev（session `local_05a8f773…`）：14:55 後我接手 CPU、`SAMPLING DISABLED` 那行是 f2836fc3 的預期輸出、別在批次期間開 ninja。
- 派出 `fix/mutate-rate-denominator-survivor-accounting` agent（`ae8a61e4…`）：參考腳本三處 ⚠️ 改計 survivor、加 summary 行與 0/1/2 exit、`BUILD_DIR` 可覆寫；以 stub cmake／test binary 做六種情境的紅→綠，不編譯。落地後加進 branches.txt（RateDenominator.* 已在 base，批次能給它真結果）。
- 派回 F-1 agent：`DCAPM.cpp:~1594` 溫度迴圈 `front()` 搬到型別過濾之後＋測試＋變異；要它查 `_GLIBCXX_ASSERTIONS` 有沒有開，沒開就明講「看不到紅」。
- **F-9／F-17 不派**：F-17 是 Adam 08-29 重裁「不修」；F-9 是 sFlow 1/256 的解析度限制（§C 標「解析度限制」），「修」只能是暴露量子大小或改取樣率，後者是 Adam 已反覆量過的取捨 ⇒ 列入回報請 Adam 決定要不要開「暴露 `usage_resolution_bps`」這種標示型工單。
- 未派、不在 Adam 清單內但在 §A 🔴：A-2（topology poll 永久阻塞無人發現）、A-4e（`modify_flow_entry` 忽略 priority）、A-7（排隊寫入失敗對 API 不可見）⇒ 回報時列為候選，不擅自擴。
- **F-1b（UB 補修）** `fix/f-1-mininet-health-metrics` @ `922e3935`（+1 commit，tree clean，`bash -n` ok）。**我 grep 確認**：`_GLIBCXX_ASSERTIONS`／`_GLIBCXX_DEBUG` 在 CMake 全樹零命中，sanitizer 是 opt-in（`cmake/sanitizer-flags.cmake`）⇒ 新測試 `AVertexWithNoIpIsSkippedRatherThanDereferenced` 是**形狀守衛、非 red-seen**（agent 明講、寫進註解與 commit）。M8 走 `mutate_may_survive`：回報不計分、能辨認 catch-by-crash。它的 stub 整跑「9 mutations, 7 survived」是 stub 結果不是量測。要真看紅要 `-DSANITIZER=asan` 的 `build-asan`——批次若有餘裕加一輪 ASan 只跑 F-1 M8 與 F-14（可選）。

## KNOWN-ISSUES 機制 diff 到齊 14:1x（唯讀 agent；repo 未動；**依 Adam 裁決，批次過閘前不套用**）
- 位置 `known-issues-delta/`：`KNOWN-ISSUES.mechanism.diff`（+557/−9，13 處既有條目改寫涵蓋 21 個缺陷＋6 條新條目）、`STATUS-CHANGES-DEFERRED.md`（22 個狀態變更＋2 個邊界案待 Adam）、`NOTES.md`。**我在 HEAD（trunk `c05e4988`）對 `doc/KNOWN-ISSUES.md` `patch --dry-run -p0` rc=0**（注意 diff 標頭是 base.md/edited.md，要指名檔案；base→HEAD 該檔有 7+/1− 的無關變動，仍套得上）。
- **它抓到本簿四個行號錯，我逐一驗過、本簿以下為準**：`LockManager.hpp` 到期檢查在 **`:210`**（`state.isLocked && now < state.expiryTime`）不是 `:203`（那行是 lock_guard；A-9 agent 給錯我照抄）；`measure.sh` 的 `pkill -f iperf3` 在 **`:99`** 不是 `:96`；`HttpSession.cpp` 的 `int k = 50` 在 **`:594`**（`:589` 是 log 行，文件原本就錯兩次）；F-14 的「`isUp = true` 六處」在 discovery path 是 **五處**（`:639/:721/:761/:801/:936`，`:920` 是註解），另有 `:1834/:1842/:2341` 三處在恢復 helper；「`false` 零處」只對 host／discovery 成立，全檔另有 `:243/:318/:1817/:1825/:2334` 五處 `false`。**核心宣稱不變**：liveness／`link_failed` 的定義域不含 host。
- 它最沒把握的三點（留給合併時）：§C 表 F-8 格仍寫「暫態」只加了指標行；`NEW-HTTP-200-DEFAULT` 放 §B 當「review 問題」還是 §C/§G；§G-2 行 02/05 要不要比照 `ndt sample_rate` 給「已修」豁免（修在 `cd440488`，base 祖先，我重跑 34/34＋12/12）。**F-4 翻案是唯一要裁決不是要編譯的延後項。** `ndt-harness-t9-t10-instruments` 分支動了 KNOWN-ISSUES 4 處，會撞。
- 已同步到 `doc/audit/2026-09-02_fix-design-campaign/known-issues-delta/`。

## Adam 裁決 14:2x：A-2、A-4e、A-7 也派
- 三個 opus worktree agent 已派（id→題目在 `agents.tsv`）。A-2 範圍＝條目明列的未覆蓋項 2（Ryu `get_link()` 無界）與 3（半套用），項 1（`--max-time` live）唯讀比對配方；A-4e＝重驗 RESOLVED 宣稱＋**全 campaign 分支 vs 既有閘門的 anchor 漂移矩陣**（A-9 那種「重構讓別人的閘門失效」要在批次前全抓出來）＋可重用檢查器 `check_gate_anchors.py`；A-7＝接線 `droppedAfterStop()`、開機編程計數設計、追 FINDING-07「priority 落地恆 0」是不是躲在 RESOLVED 後面的活缺陷。
- 三個都禁編譯；閘門規則同前（cp -p+touch、編不過／anchor 移位／錯測試紅＝survivor、`N mutations, M survived`、exit 0/1/2）。

## RATE-DENOM 參考閘門記帳修補 ✅ 我重跑 14:0x
- 分支 `fix/mutate-rate-denominator-survivor-accounting` @ `a9470d26`（1 commit，1 檔 +186/−40，tree clean，`bash -n` ok）。**已加進 branches.txt**——`RateDenominator.*` 在 base 就有，批次會對真 build 跑它 5 個變異，是本批唯一「舊修法＋新記帳」的真實閘門結果。
- **我用它的 stub driver（`run_all.sh`，stub cmake＋假 test binary、沙箱副本、真 worktree 不碰）對 committed 版與原版各跑 11 情境，矩陣與 agent 的逐格相同**（只差欄寬）：原版 b/c/d/d2/g/j 六種「沒量到」全部 rc=0（假綠）、i 對 `BUILD_DIR` 無效 rc=2；新版 a/i rc=0 印 `5 mutations, 0 survived`，b/c/d/d2/g/j rc=1 印 `5 mutations, 1 survived`＋理由，e/f/h rc=2 無 summary。f 情境「沙箱來源被改」是**刻意**弄壞 restore 的預期結果。
- 🔴 **我的 brief 錯了一行**：要求 `sed -n '47p'` 含 `mutant does not compile`，實際在 46 行（47 是 `restore; return`）；agent 查了該檔全部歷史（兩個版本都是 46）判定是筆誤而續做——判斷正確。教訓：給 anchor 前自己 `sed -n` 一次，不要憑對帳簿的行號。
- 它順手抓到兩個 brief 沒提的洞：負控制把 binary **非零退出**當成「測試變紅」（build/ 不存在照印 ✅ red）；`sed -i` 沒配到回 0 ⇒ header 變異 anchor 移位完全隱形。它的六個裁量（restore 後 rebuild 失敗＝2、EXIT trap 也還原 FLUC/HDR、kernel sha 缺時印 `absent`、`-F` 訊息檔等）我全接受。
- 已派回同一 agent：掃 base 上全部既有 `mutate_*.sh` 的六類記帳洞（不碰今天新加的與 `mutate_lock_*`），能 stub 驗的才修、一腳本一 commit。

## 批次開跑 14:13（lab 由 mainDev 於 14:11:52 提前釋放；12 格 A/B 跑完、fabric DOWN 且 clean、handoff 有寫）
- 我 14:13:43 以 auditor claim 150 分（到 16:43）；`buildwt` 從零全建 F-1 分支（ccache 暖）。Monitor `bpcriby0a` 逐分支回報 SUMMARY.tsv。
- 🔴 **我自己的儀器 bug**：gate 0 我改成放行含 `auditor` 的 claim，但 `ndt status` 對**自己的** claim 印的是 `yours -- 150m left (until …)`，不含 owner 名 ⇒ 第一次啟動被自己的 claim 擋掉、wrapper 順手 release（14:13:19–20，lab 空窗 23 秒，無人受影響）。已改成也放行 `yours*`。教訓進 memory：**任何 grep claim owner 的腳本都看不到自己**。
- 兩個 lab-release Monitor 其實都活著（`byvin1l7l` 是舊 session 的任務 id，不在本 session tasks/ 目錄但仍會通知）⇒ 「不在 tasks/ 就是死了」是錯的判準；重掛只多一則通知，無害。

## 批次第一支結果 14:2x：F-1 編不過（`-Werror=range-loop-construct`）→ 我修
- `tests/test_SimulatedDeviceMetrics.cpp:206/:273` `for (const nlohmann::json report : {…})` 逐元素複製，`-Wall -Wextra -Werror` 拒絕。我在 F-1 worktree 改成 `const nlohmann::json&`，commit `65c5cdb1`（明列路徑）。**這是本批第一個「NOT COMPILED 宣稱」被編譯器打臉的實例**——agent 寫的 C++ 沒編過就是沒編過。
- 我掃了 11 支分支同型樣式：只剩 base 就有的 `test_RelayResponse.cpp` `const std::string code : {"200",…}`（`const char*`→string 是轉換不是複製，不觸發），無需處理。
- F-1 要重跑：`batch_compile_retry.sh`（複本，跑中的原腳本不動；`BRANCHES=` 指清單、**跑該分支新增／修改的每一支 mutate 腳本**而非 `head -1`、輸出 `SUMMARY.retry.tsv`）。原批次對 RATE-DENOM 分支會用 `head -1` 抓到 `mutate_ep4_…`（純 shell 閘門），真正的 `mutate_rate_denominator.sh` 要靠 retry pass 才會跑。

## 既有閘門記帳掃描 ✅ 到齊 14:2x（同分支 `fix/mutate-rate-denominator-survivor-accounting`，5 commits，tree clean，`bash -n` ×5 我跑過）
- 表（agent 報，行號為 base）：`rate_denominator` ①②③④ 四洞；`gate_exit_code`／`ep4_gate_and_abort_evidence`／`log_suffix_idempotent` 三支 shell 閘門各 ①③④⑥；`topk_recursive_lock` 只 ④⑥（③是全 repo 唯一做對的）。⑤（restore 舊 mtime）全線無洞。
- 它的 stub 驅動：54 次（4 閘 × 情境 × 新舊），變異集合與期望案例名一字未改，**現有 anchor 全部仍有效**。最重要一條：`topk` 原版 restore 失敗後**繼續跑**，mutation 5 疊在 4 的 mutant 上、判給 5 一個 SURVIVED、exit 1 與「測試弱」同碼 ⇒ 現在第一次 restore 失敗就 exit 2，且每次 restore 驗 byte-identical。
- 它的四個裁量我接受：topk anchor 缺失維持 exit 2（比慣例嚴且不會假通過）；每次 restore 驗 byte；三支 shell 閘門加最終 green 重跑（多一次套件，值得）；`mutate_lock_renew_expiry.sh` 沒碰（A-9 分支重寫了）——**A-9 合併後回頭掃**。
- 我未重跑它這 54 次（前一輪 22 次我已重跑到逐格相同，同一套 driver 與方法）；批次 retry pass 會對 rate_denominator 跑真 build。

## 批次結果逐支（我讀 batch-out 的 log，不是 agent 說的）
- **B-3 ✅** `341b66be`：build ok；ctest 18/18（`HistoricalLogging*` 家族）；`mutate_b3_historical_logging.sh` **10 mutations, 0 survived, 0 did not compile**，comment-only control 綠，4 檔 byte-identical 還原。**這是本批第一支真正過閘的 C++ 分支**——三顆 commit 要一起落（allowlist 那顆不落 `check_logs.py` 會紅）。
- **F-13 ❌→修** `40bcb7de` 編不過：`OpResult.hpp` 四個工廠函式的聚合初始化仍列三個成員（F-13 加了第四個 `outcome`）⇒ `-Werror=missing-field-initializers`。我補 `""`（`respondToOpResult` 對空字串本來就是「不加欄位」），commit `1ba8a1d1`，列入 retry。agent 自己點名的三個風險點（結構化綁定 `get`、字串鏈 ternary、alias 重宣告）**都不是**問題——真正的洞在它沒點名的地方。
  - 續：base 的 `tests/test_Controller.cpp` 有 8 處 `OpResult{false, 400, "…"}` 三成員字面量，同一個 -Werror 會在 F-13 樹上炸 ⇒ 補第四欄，commit `10ca8852`。**加聚合成員＝全 repo 的聚合初始化都要跟著動**，agent 的 grep 沒掃 tests/。F-13 現在 `10ca8852`（5 commits）。

## 🔴 14:23 app 閃退，批次陪葬（第 3 支 F-6 跑到變異閘中途）；14:3x 重啟
- 證據：`buildwt` 髒了一個檔（`StaleTableCarryForward.hpp`＝F-6 某個 mutant 套上、restore 沒跑到）⇒ **F-6 的 build 與 gtest 其實已過，死在閘門裡**；三份 F-6 log 改名 `.interrupted.log` 留證，樹已 `checkout -- .`＋`touch` 還原乾淨。SUMMARY 只有 F-1 ❌／B-3 ✅／F-13 ❌ 三行。
- 成因：Bash 工具跑在 app 的 cgroup scope（`app-com.anthropic.Claude-*.scope`），app 一死整個 scope 被殺，`setsid nohup` 擋不住。改用 `systemd-run --user --unit=ndt-batch-143620` 起獨立 transient unit（已驗可用），batch 從此不隨 app 死；日誌 `batch.retry.log`／`SUMMARY.retry.tsv`。
- 重跑清單 `branches.retry.txt`（10 支）：F-6 起 7 支＋RATE-DENOM＋修過的 F-1(`65c5cdb1`)、F-13(`10ca8852`)。retry driver 對每支分支跑**全部**它新增／修改的 mutate 腳本。lab claim 仍是我的（到 16:43），批次超時前要續 claim。
- A-2（1 commit `05edac65`）與 A-7（5 commits，到 `56ae7642`）agent 被中斷，worktree 乾淨、commit 在；已發訊息叫它們接續。A-4e 結果完整到齊（見下一則）。

## A-4e 重驗＋閘門 anchor 漂移矩陣 ✅ 到齊、我重跑檢查器 14:4x
- 分支 `verify/a-4e-and-gate-drift` @ `71ea3cef`（1 commit：`tests/shell/check_gate_anchors.py` 680 行，tree clean）。**我自己跑**：base `4cbec52d` 6/6 ok rc=0；`fix/bx-flow-liveness` ⇒ `mutate_topk_recursive_lock.sh MISSING:3` rc=1（其餘 ok，含 bx 自己的閘 7 anchor）；`fix/a-9-lock-lease` ⇒ 重指後的 `lock_renew_expiry` ok(6)、`lock_lease_expiry` ok(9)、`lock_ownership` ok(8)，但 `mutate_lock_lease_all.sh` 是 driver 無 anchor ⇒ 工具設計上 exit 2（不是假通過；roster 要列三個 delegate 而非 driver）。
- 🔴 **真碰撞 1 個**：bx 在 `FlowLinkUsageCollector.cpp:2320/2433` 把 `getFlowInfoJson()` 改成 `getFlowInfoJson(filter)` ⇒ topk 閘門 3/5 anchor 死、gtest 仍綠（它守的是一個**刪除**）。任何合併順序都 MISSING:3。**而 RATE-DENOM 分支也改了同一支 topk 腳本（記帳）** ⇒ 決定：兩支都合完後，由我在 trunk 上重指 topk anchor 一顆 commit，用檢查器驗 6/6 再收工；不叫 bx agent 在它分支上動那支腳本（會跟 RATE-DENOM 撞文字）。
- 🟠 文字衝突（合併時要手解）：F-1 × F-6 在 `DeviceConfigurationAndPowerManager.hpp`；F-8 × A-4f 在 `tools/contract_test/spec.py`。`HttpSession.cpp` 8 支分支合得乾淨。
- A-4e 本身：①`c46c51e` 在 base ✓；②**沒有 `tests/shell/mutate_*` 覆蓋 A-4e**——它的閘是 `doc/audit/2026-08-30_known-issues-wave/11b_mutation-harness/mutations.py` M6–M9，5 anchor 仍各 1，**但 `mutations.py:13`／`run_one.sh:19` 寫死另一個 agent 的 worktree 路徑、`driver.sh:6` source 一個已不存在的 scratchpad** ⇒ 不可重跑（會變異一棵它不 build 的樹）；③strict body 帶 priority＋全 match、`strictModifyPath()` `:236-239`、P4 override `P4RoutingStrategy.hpp:60`、本機 Ryu 有 `modify_strict`（`ofctl_rest.py:686-689`），proxy 無 `modify_strict` 路由；`ofctl_v1_3.py:1049-1071` cookie_mask/table_id 預設 0 ⇒ 只 table 0（與 install 一致，未明說的假設非缺陷）；④無新缺陷（讀了 delete/add/group×3/meter×3/Controller/FlowRoutingManager/HttpSession 三個 job factory/IntentTranslator 四處；唯一不對稱 `IntentTranslator.cpp:417` 非 strict delete 但 `DeleteFlowEntryTask` 本無 priority）；⑤標題 🔴 vs 狀態 🟢 不一致，且 `:195-201` 引用已漂到無關行——措辭在 `A-4e.md`。
- 待裁：A-4e 舊 harness 的寫死路徑要修還是記錄（建議：記錄＋下次 wave 用 `check_gate_anchors.py` 取代）。

## A-7 ✅ 我重跑 14:4x（Python 綠／紅／綠；C++ NOT COMPILED，進 retry2）
- 分支 `fix/a-7-dispatch-status-wiring` @ `56ae7642`（5 commits，10 檔 +919/−10，tree clean，不碰 KNOWN-ISSUES）。**我重跑**：proxy 測試（`p4_proxy/venv/bin/python3 -m unittest`，miniconda 沒 fastapi、venv 沒 pytest）HEAD 22/22 綠 rc=0；`api_routes.py` 倒回 base ⇒ 3 ERROR（priority_honoured 三顆）rc=1；還原 dirty=0 再綠。閘門 `--dry-run` 9/9 anchor rc=0、`--python-only` `5 mutations, 0 survived` rc=0（明印 cpp lane 未跑）。
- **推翻條目**（我 grep base 確認）：`droppedAfterStop()` 在 `HttpSession.cpp:669` **早有讀者**（`636f9ab`，正是條目自己引的修法 commit）——⚠️ delta agent 14:5x 更正時序：接線 `636f9ab` 是 08-30 22:18，註記 commit `1c8828b6` 是 08-31 11:25，但註記**自報基底 `1208d22`（08-30 20:11）**，對那個基底它是對的 ⇒ 教訓不是「子註記活過修法」而是「讀碼有標基底才誠實；13 小時後不重讀就 commit，落地時已是假的」。真正的洞：`dropped_after_stop` 只在 `stop()` 後才可能非零 ⇒ 一個 0 蓋兩種相反狀態 ⇒ 加 `FlowDispatcher::running()`（`.hpp:137`）、`HttpSession.cpp:678` 發布。
- 項 2 只設計：`dispatched` 數的是單一 `enqueue` 站（`HttpSession.cpp:1145`），餵它的是**四**條路由不是兩條；`boot_installed` 做不到——開機編程在**另一個行程**（Ryu `install_all_pair_paths`／proxy `topology_manager.py:1008`），計數器會永遠 0（`fencePerBurst` 那種假 affordance）⇒ 改發布 `counters_cover`。IntentTranslator 四處直呼（`:364/394/417/733`）要把 log 傳進建構子才收得到；`:733` 丟棄 `OpResult` 無條件回成功——**這是新發現的小缺陷，未修**。
- FINDING-07「priority 落地恆 0」：**不是遺失是不可表達**——priority 逐跳都在（`HttpSession.cpp:915`→`Controller.cpp:33`→`HttpRoutingStrategyBase.cpp:176`→`api_routes.py:230`→`p4_client.py:708`），只在 `topology_manager.py:880-897` 目的地-only 規則進 `ipv4_lpm`（P4 LPM 表無 priority 欄）時消失。可修的是「端點無聲回 success」⇒ 現在回 `table`／`priority_honoured`／`priority_note`（附加欄位、不回 400，T-15 Option 0 與 §1.2 裁決禁止拒絕）。
- 它三個待裁：用 venv python（同 `l1_unit_tests.sh:153`，我接受）；把既有 `test_flow_stats_route.py:197` 的整 dict 斷言收窄到 `status`（合併時看 diff）；FINDING-07 揭露與 T-15 Option 0 重疊——若 T-15 有人在做要併。

## A-2 ✅ 我重跑 14:4x（Ryu Python 紅／綠；C++ NOT COMPILED，進 retry2）
- 分支 `fix/a-2-ryu-get-link-and-partial-apply` @ `05edac65`（1 commit，5 檔 +929 純新增，tree clean）。**我重跑**：`A-2_test_ryu_rest_topology_bounded.py` 對 patched 檔 `Ran 7, OK` rc=0；`A2_REST_TOPOLOGY=<stock rest_topology.py>` ⇒ `errors=8` rc=1。閘門 `ANCHOR_CHECK=1`：10 變異＋控制各 1 站，exit 2（明講不是閘門結果）。
- 🔴 **推翻條目項 2**：base 的 `intelligent_router.py:304`／`:284-288` 是 SIGUSR2 greenlet-dump 註解（差約 700 行）；`get_link` 在 `:1007-1009` 且**早被 `_bounded_topo_read`（`:878-907`，`cce9c5db` 08-25）綁住**——比 `687de6c` 寫條目早六天。而且那支函式**從不服務 kernel 的 poll**：`/v1.0/topology/*` 來自 stock `ryu.app.rest_topology`（`stack.sh:719-720`），這正是條目自己觀察到「三個 topology 端點 000、同行程 `all_destination_paths` 0.2 ms 回答」的原因——兩個不同 app。真正無界的讀在 `ryu/app/rest_topology.py:97-119` → `app_manager.py:279 reply_q.get()`。
- Ryu 補丁 `A-2_ryu_rest_topology_bounded.patch`（`patch -p1 --dry-run` 0）：三個 handler 包 `hub.Timeout(3s)` ⇒ **503 空 body**——因為 `execCommand` 是裸 popen 丟棄 exit status，status code 到不了 kernel，body 是唯一通道；帶 body 的 5xx 會被當成有答案餵 `json::parse`，比 wedge 更糟。3s 必須小於 kernel 的 `--max-time 5`。
- 項 3 決定**不做 all-or-nothing**：三個 writer 全是單調向上（每個 `isEnabled`/`isUp` 寫入都是 `= true`，無 remove），半輪製造不出假 down；丟掉有答案的那半反而把 A-2 的悲觀靜默推更遠。改為可觀測：`classifyPollRound` → Complete/Partial/Silent（初始 NotYetPolled）、`lastPollRoundKind()`、邊沿觸發 WARN token `topology-round-partial`。`""` vs `"[]"` 仍以 `empty()` 判——OVS 開機到 LLDP 完成前都回 `[]`。
- 項 1 配方比對無漂移；新 WARN 在 iptables 配方下不觸發（三端點全停＝Silent 非 Partial）⇒ §5.3 不必重跑。
- 待裁：Ryu 補丁如何落地（stock site-packages 檔，重裝會無聲還原；建議 vendor 進 repo、改 `stack.sh:720` 的 app 名）；`lastPollRoundKind()` 要不要上 `/ndt/get_graph_data`；`KNOWN-ISSUES.md:132-133` 同一條舊引用要跟著改。

## 🔴 14:4x 真因：systemd-oomd。**14:23 的 app 閃退是我的批次造成的**
- `journalctl --user`：14:23:41 `app-com.anthropic.Claude-3404.scope: systemd-oomd killed 100 process(es)`，候選榜首就是 Claude app 的 scope（Current Memory Usage 11.0G、Pressure Avg10 68.64%）——`ninja -j6` 跑在 app 的 cgroup 裡，oomd 連 app 一起殺。14:37:19 systemd unit 版同樣 `oom-kill`（65 processes）。兩次都死在 F-6 閘門的 rebuild。
- 機器：15.4 GB，chrome×多＋claude-desktop＋claude＋30 小時的 `claude-cowork-vm`；`user@1000.service` `ManagedOOMMemoryPressure=kill`、limit 50%。任何 -j6 的 C++ build 都會把某個 cgroup 推過線。
- 對策：`JOBS=2`（driver 的 ninja＋讀 `${JOBS}` 的 B-x／F-13 閘門）、`--nice=10`、仍用 systemd unit（`ndt-batch-144729`）；F-8 與 rate_denominator 腳本寫死 `-j4`（只重建 test target，增量，接受）。F-6 的 build 與 gtest（100% passed）在 oom 版 log 裡都有，閘門結果仍未知。
- 🔴 教訓進 memory：**這台筆電上編 C++ 會把 Adam 的 app 殺掉**——不是 CPU 汙染問題，是 oomd。
- 14:48:28 第三次 oom-kill（unit `ndt-batch-144729`，JOBS=2 也死，available 11.5 GB、swap 已用 4.9 GB）。**三次都死在 F-6 閘門第 2 個變異（改 header）的 rebuild**：F-6 閘門呼叫 `cmake --build` **不帶 -j** ⇒ ninja 預設 nproc+2＝16 個 g++ 同時編所有 include 那個 header 的 TU ⇒ 記憶體爆。`JOBS` 環境變數對它無效。修法：unit 環境加 `CMAKE_BUILD_PARALLEL_LEVEL=2`（cmake --build 無 -j 時讀它）＋ `MAKEFLAGS=-j2`；第四次 unit `ndt-batch-144930`。這次 app 沒死＝unit 隔離有效。
- 14:50–14:52 **實測上限有效**：每 5 s 取樣 120 s，`cc1plus` 同時最多 2、`/proc/pressure/memory some avg10` ≤0.31、available 7.6–10.3 GB；F-6 閘門已越過致命的第 2 變異跑到第 5。unit `ndt-batch-144930`。

## F-6 批次結果 14:5x：build ok、gtest 20/20、**閘門 7 變異 2 存活（兩個 mutant 編不過）**
- 存活的是 #2「stale_since 永不設定」與 #4「stale_polls 永不累加」——都是改 header 的變異，mutant 本身編不過 ⇒ 依規則計 SURVIVED（正是我要求的計法在起作用）。其餘 5 個各被具名測試抓到、控制組綠、還原 byte-identical、還原後套件綠。#8 宣告未覆蓋（鎖序）。
- 處置：把 log 交回 F-6 agent 改寫這兩個變異使其能編（禁編譯，讀錯誤訊息推理）；F-6 進 retry2 重跑閘門。log 存 `fix-designs/F-6_gate_run1.log`。

## KNOWN-ISSUES 機制 diff 第二波 ✅ 15:0x（A-2 ×3、A-4e ×1、A-7 ×2、BLOCK_HOST ×2 ⇒ 21 hunks，+694/−17）
- **我對 HEAD（trunk `06bc60ac`）dry-run rc=0**。延後清單 25 項＋3 邊界案（新增：A-2 項 3 落地、Ryu 補丁 vendor 與否、A-4e 標題 🔴→🟢 一字裁決）。
- 它與 brief 不同的三點我接受：A-7 時序更正（上）；`IntentTranslator.cpp:733` 併入 `NEW-BLOCK_HOST`（`:728/:733/:739` 是同一個 try 的三行，兩個 ID 指同一處會違反本文件自己的警告）；A-4e 標題不動、加「以狀態行為準」一句。
- 它沒 sed 過的引用只有一組（A-4e 的 `ofctl_rest.py:686-689`／`ofctl_v1_3.py:1049-1071`），已標〔轉述〕。兩個小錯它修了：`driver.sh` 的 `S=` 在 `:5` 且是 `bash` 不是 `source`；A-2 的 `= false` 清單漏 `:2407/:2411/:2421`（不影響結論）。
- 仍依 Adam 裁決：**批次過閘後一次套用**。
- F-6 agent改寫 #2／#4（`d50f63f2`）：兩個 `const` 區域變數唯一的讀取就是被刪的那行 ⇒ `-Wunused-variable`。#2 改「set 後 erase」（消費端看不到 `stale_since`），#4 改「指派 priorPolls 不 +1」（永遠 0）。anchor 與期望測試名不變。retry2 重跑閘門即可（build／gtest 已確立）。它提的 `mutate_rate_denominator.sh:56` 洞已在 RATE-DENOM 分支修掉，它不知道。
- 15:02:34 **第四次 oom-kill**（unit `ndt-batch-144930`，F-14 閘門第 1 變異後）：F-14 閘門寫死 `-j"$(nproc)"`＝14 ⇒ 10.2 GB。環境變數對寫死的 -j 無效 ⇒ 改用 **PATH shim**（`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/4e0e8cb4-1c72-4731-b5fe-2989d7af1d65/scratchpad/shim/{cmake,ninja}`：剝掉呼叫端任何 -j／--parallel，一律 -j2）。F-14 的 build 與 gtest 9/9 已在 oom 版 log。第五次 unit `ndt-batch-150344`，清單 12 支（F-14 起＋RATE-DENOM＋F-1／F-13／F-6 修後＋A-2／A-7）。
- 15:04–15:09 shim 實測：F-14 閘門 rebuild 期間每 5 s 取樣 300 s，`cc1plus` 最多 2、無一次超過。unit `ndt-batch-150344`。
- **F-14/16/4 ✅** `6db478ca`：build ok；ctest 9/9；`mutate_optimistic_topology_reporting.sh` **16 mutations, 0 survived**——16 個具名抓到（含 1000 次不隔離、`continue` 解除武裝、rejected fix 各一）、6a/6b/6c 依宣告保持綠（單獨移除任一 F-4 守衛不可觀測，由 7a/7b/7c 殺）、兩來源 byte-identical 還原。**第一支「閘門真跑完且全殺」的分支**。
- **B-x ✅** `7d678ed0`：build ok；ctest 47/47（`FlowLiveness*`／`HttpSessionRouting*`／`LinkTransitionEndpoints*`）；`mutate_bx_flow_liveness.sh` **7 mutations, 0 survived**——#1–#6 具名 assert 抓到（#3/#4 由新加的「window 介於 rate loop 與 idle timeout 之間」關係測試殺、#5 由釘值測試殺），#7（loose `starts_with`）如預期以 **signal 11 crash** 分類抓到（死在 `AMistypedFlowDataEndpointIsNotFoundRatherThanServed`），CONTROL 存活，還原後 test binary sha 與基線相同（`510fc659…`）。

## 批次跑完 16:57（unit `ndt-batch-150344`，3h13m CPU，無 oom-kill；buildwt 乾淨）—— 12 支結果（我讀 SUMMARY.retry.tsv 與各 log）
| 分支 | build | ctest | 閘門 |
|---|---|---|---|
| F-14/16/4 `6db478ca` | ok | 9/9 | 16/16 殺 |
| B-x `7d678ed0` | ok | 47/47 | 7/7 殺（#7 crash 分類） |
| F-8 `28a9b550` | ok | 全綠 | 4/4 殺 |
| A-9 `3dfa51cc` | ok | 全綠 | 總閘 23/23 殺（三支 delegate rc=0） |
| A-4f `e9993f9f` | ok | 全綠 | **rc=2：閘門說 baseline 紅**（ctest 同套件卻全綠——待查是閘門判紅邏輯還是 filter 裡別的 case） |
| B-2b/B-4 `051faf12` | ok | 全綠 | 無腳本（Python 守衛我已紅綠） |
| RATE-DENOM `22b3f7c2` | ok | — | rate_denominator 5/5、topk 5/5、log_suffix 6/6 殺；**ep4 與 gate_exit_code rc=2：baseline 紅**（既有 shell 測試在 buildwt 環境紅，待判環境或 trunk 既有壞） |
| F-1 `65c5cdb1` | ok | 全綠 | 9/9 殺（含 M8 expected-survivor 另計） |
| F-13 `10ca8852` | ok | 全綠 | 5/5 殺 |
| F-6 `d50f63f2` | ok | 20/20 | 7/7 殺（#2/#4 改寫後） |
| A-2 `05edac65` | ok | 全綠 | 9/9 殺 |
| A-7 `56ae7642` | ok | 全綠 | 8/8 殺 |
- lab claim 16:43 到期、批次跑到 16:57（14 分鐘無 claim；`measuring nothing`、fabric 一直 down、handoff 仍是 mainDev 的）。
- 三個 rc=2 的判定（我跑的）：`test_gate_exit_code_not_tee.sh` 在 **trunk 綠 7/7**、在 base `4cbec52d` 紅 5/2 ⇒ base 之後修好，整合到 trunk 上應綠。`test_ep4_gate_and_abort_evidence.sh` **在 trunk 也紅**（`lib_e.sh:67` 要求先設 `LOG_BASE` 才能 source；base 與 trunk 都如此）⇒ **trunk 上既有的紅測試**，不是本 campaign 造成，要回報 mainDev／Adam（誰的測試誰修）。A-4f 閘門「baseline 紅」log 沒印出哪顆——交整合 agent 直接跑 filter 查（含 shuffle 看時序相依）。
- 18:1x 派整合 agent（在 buildwt 開 `integrate/2026-09-02-fix-campaign` from trunk `06bc60ac`，20 支分支指定順序合併、四處預期衝突給了解法、bx 後重指 topk anchor、丟掉 F-15／ndt-harness 的 KNOWN-ISSUES hunk；shim PATH、JOBS=2、先 claim lab；全 ctest＋Python 三套＋19 支閘門＋anchor 檢查器；不 push、不動 trunk）。

## 整合中 18:5x（agent 在 buildwt；我讀 log）
- 20 支全合（trunk+77）：衝突四處如預期解掉；bx 後 topk anchor 重指 `dbc3692b`；F-8 anchor 因 spec.py 解衝突重排而重指 `a41e5df0`；A-4c×A-4d 互動：A-4d 的 TopologyManager double 缺 A-4c `__init__` 設的 journal 屬性 ⇒ `9b4047b0`。
- 整合樹：build 0 error；**ctest 870/870**；proxy 572 OK（skip 3）；contract selftest 66；kernel-side Python 22 檔中 20 檔 OK、`test_sflow_stats_endpoint.py` 是 miniconda 無 fastapi（既知）、**`test_shell_command_construction.py` 紅**——B-2b 守衛抓到 A-4f 新加的兩個 shell 站點（`OVSPowerStrategy.cpp` 的 `sudo ifconfig …`／`sudo ovs-vsctl … create sflow …`＋read-back popen），**跨分支互動、守衛照設計推定有罪** ⇒ 已叫整合 agent 閘門跑完後改成 `execArgv`。anchor 檢查器對 a7／lock_lease_all／ndt_sample_rate 三支「no anchors extracted」（driver 型或非 python-heredoc 型腳本，非缺陷）。
- 閘門 19 支跑到第 4（F-1 9/9、B-3 10/10、F-13 5/5、F-6 跑中）。lab claim auditor 到 22:05。

## Adam 裁決 19:0x（互動表單，四題）
1. **F-4 翻案**：§D 的 08-18「不修」改為「09-02 翻案，併入 F-14/F-16 的推導式修法」。
2. **§G-2 row 02/05 給例外標「已修」**（比照 NEW-NDT-SAMPLE-RATE；殘餘「註冊窗與實跑窗從未比較」另列）。
3. **A-9 標題改成 polling livelock，舊標題括號保留**。
4. **Ryu 補丁 vendor 進 repo、`stack.sh` 改載入自家副本**（路徑定為 `tools/ryu_apps/rest_topology_bounded.py`；live 載入驗證進 live-verify 佇列）。
- 派工：A-2 agent 在自己分支做 vendoring（整合 agent 最後再合一次）；delta agent 準備第三波（四項裁決＋過閘分支的狀態翻面 `KNOWN-ISSUES.status.diff`，A-4f 那列等 execArgv 後閘門結果）。

## Adam 授權 19:1x：**合進 trunk 之後直接派 agent 跑整機一輪，不用等他**
- Adam 19:2x 追加：**整機一輪要把所有 tool 都測過**（不只 kernel 修法；contract test、l3、check_logs、R5 harness、chaos harness、ndt harness 儀器、cpu_probe、twin_audit、make_topology、p4_power_helper、anchor 檢查器……逐一有跑過的證據）。

## 19:1x 開機手冊 session 交來 usertest run-01（sonnet）結果，要我判四題（正本 `doc/audit/2026-09-02_manual-usertest/run-01-sonnet/`，trunk `e6cc0998`）
- 9 個新 bug 我的歸屬：**進 KNOWN-ISSUES §G（本 repo 儀器）**：⑤ `ndt apps sim/energy` 印 ok rc 0 什麼都沒起（`ndt:1928-1929` 只看 ndtwin-lab rc、無 `kill -0`；他們親手重現）＝「失敗回報成功」又一例，**要修**；④ 乾淨 VM 上 `ndt up` 3/3 起不來（0 hosts／manifest missing）而手冊三終端路徑每次過＝OPEN 機制，先在 run-01 VM 重現留證；③ `ndtwin-lab` 缺時 `ndt` 沒有清楚的 fail 訊息（手冊只 symlink `ndt`）＝儀器 fail-open＋文件。**回各 repo owner**：⑥ NSR `stop_network_state_recorder.sh:2-3` 的 `kill $(pgrep -f …)`（違反專案硬規則）；⑨ Web-GUI 兩個 Dockerfile 未釘 pnpm（`pnpm@9` 才過）。**純文件（website）**：①② §2.6 `is_mininet` 死開關／`switch_num` 行不存在；⑦ NTG python 路徑；⑧ NTG venv 要 `--system-site-packages`；130 vs 131/129 流數公式。
- BUG-010 降級：同意（關機序列那幾行來自另一場的 log；站得住的是 kernel 行程在 SIGINT 經 `setsid nohup sudo` wrapper 後沒死＋手冊 P4 關機檢查缺 :8000／kernel 存活項）。SIGINT 送達＝OPEN，要在 run-01 VM 刻意重現。
- run-02（haiku）沿用 `bcf98f5` 不改：同意（P3 要的是同一份手冊下的差異；③ 的牆本身也是 P3 資訊）。
- run-01 VM 被動前要驗：④ 重現（完整 `ndt up` log、root tmux 各 pane、`ndt status --check`、manifest 狀態、`sudo -n -l`）；SIGINT 送達（對 wrapper pid 與 kernel pid 各打一次、`/proc/<pid>/status` 的 SigCgt/SigBlk、kernel log 有無 shutdown 行）；⑤ 的 `ndt apps` 三支各一次含 `tmux ls`。
- 推送：他們 trunk 領先 p4/lab 13 commits、push 被擋——我整合合進 trunk 後一次推（先逐 hunk看 diff 規模）。⑤ 的修法排在整合之後（`ndt` 今天被 mainDev 與 ndt-harness 分支同時改，先合再修）；⑤/④/③ 進 KNOWN-ISSUES 第四小波。整機一輪的 tool 清單加 `ndt apps` 存活斷言。

## A-2 vendoring ✅ 我重跑 19:3x（分支 `fix/a-2-ryu-get-link-and-partial-apply` @ `68744c49`，+4 commits，12 檔 +1990/−1，tree clean）
- `tools/ryu_apps/{rest_topology_bounded.py,.patch,README.md}`；`components.env:85` `RYU_TOPOLOGY_APP` 預設指向它、`stack.sh:705-707` 檔案不存在就明確失敗；載入行改成 `'$RYU_APP' '$RYU_TOPOLOGY_APP' ryu.app.ofctl_rest`（stock 只剩註解說不可加回）。
- **我跑**：`tests/python/test_ryu_rest_topology_bounded.py` 預設（vendored）OK rc=0、`A2_REST_TOPOLOGY=<stock>` errors=8 rc=1；`mutate_ryu_rest_topology_bounded.sh` **6 mutations, 0 survived** rc=0、tree 乾淨；`.patch` 套在 upstream 副本上與 vendored 檔 **byte-identical**（cmp）。
- 🔴 它的閘門第一次跑抓到 **stale .pyc 第二例**：mutation 2/3 檔案大小相同（11531）且同一秒內套用 ⇒ mutation 3 跑到 mutation 2 的 bytecode、報「wrong test went red」；`PYTHONDONTWRITEBYTECODE=1` 不夠（直譯器仍會**讀**別人寫的 .pyc），還要每次清 `__pycache__`。與 F-15 那次同形 ⇒ 記憶要補「每次跑前清 __pycache__」。
- 未驗：ryu-manager 用檔案路徑載入、三個路由活著回答、eventlet 3 s timer 在真 wedge 下觸發——**整機一輪的 ovs4 那輪必驗**。整合 agent 要再合一次這支分支。

## 19:4x 開機手冊 session 補來 ④⑤ 的機制（我親讀 trunk 確認）
- ④：`tools/test_workflow/ndtwin-lab:51-56` 寫死（`:26-35` 是那段檔頭註解；delta agent 20:0x 更正、我驗） `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel`、`NTG_PY=/home/adam/miniconda3/…`、`ENERGY_DIR`／`SIM_DIR`；`ovs-topo-start:143-144` 直接跑 `/home/adam/Network-Traffic-Generator/testbed_topo.py`。**但檔頭註解明寫「KERNEL_DIR IS HARDCODED, AND DELIBERATELY NOT OVERRIDABLE」**（08-30 FINDING-01：env 覆寫讓 `ndt`／`stack.sh` 與此腳本各讀不同樹）⇒ 修法不是「改 source components.env」，是**安裝時期的設定檔**（例如 `/etc/ndtwin-lab.conf` 由安裝步驟寫入，腳本無設定檔就明確 die），維持「不吃呼叫端 env」的設計意圖。另：安裝副本 `/usr/local/sbin/ndtwin-lab`（root、sudoers NOPASSWD、與 repo 副本 byte-identical）——**repo 改了要 Adam 重裝才生效**。
- ⑤：`ndt:1928-1929` 只看 `sudo -n "$LAB" energy-start` 的 rc；`ndtwin-lab` 的 `*-start` 是 `tmux new-session -d … ; echo` ⇒ 秒死也 rc 0。修法＝比照 `nsr` 的 `app_spawn`（`kill -0`／port）。
- 順帶：`ndtwin-lab cleanup:131/132/133/135` **四個 `pkill -f`**（`:134` 是 `mn -c`）（含 `pkill -f simple_switch_grpc`）——專案硬規則在 lab 工具自己裡面；KNOWN-ISSUES 1488 那條講的是 `mn -c` 內部的 `pkill -9 -f`，這四個是另外的。進 §G，修法候選＝tmux session／pid 檔定向殺。
- 補驗排在 run-02 stop 之後（宿主不壓到 4 GB）——同意，今天 oomd 已殺過四次。
- 對今晚整機一輪無影響（就是 Adam 這台）。
- 19:5x：開機手冊 session 已把四題裁定落檔（RECONCILIATION §6/§7，trunk `5da71c74`）；delta agent 第四波改引 §6。trunk 從整合基底 `06bc60ac` 又前進（皆 audit 文件）⇒ 已叫整合 agent 收尾時 `git merge --no-ff trunk`，並判斷有無 src/include/tests/tools/p4_proxy 變動（有就重編＋ctest）；之後我在主 worktree `git merge --ff-only`。

## KNOWN-ISSUES 四個 diff 到齊 20:0x（我對 trunk `5da71c74` 的 doc 副本依序套 mechanism→rulings→status→usertest：四個都 rc=0，1853→2729 行）
- hunks：mechanism 21／rulings 15／status 23（§C 表相鄰列用零 context 逐列 hunk，可單獨丟）／usertest 2。新條目編號：A-4g、C-2、C-3、G-3…G-9（C-1 刻意不用，§B-1 已引「08-13 catalogue C-1」）。B-2b/B-4 翻面那列加了一句「守衛在整合樹上目前紅（A-4f 兩站點）」——等 execArgv 改完再拿掉那句。
- 它三個引用更正我親驗：`ndtwin-lab` 寫死路徑在 `:51/:53/:55/:56`；cleanup 的 `pkill -f` 在 `:131/:132/:133/:135`；`app_spawn` 給 nsr/viz/te，只有 energy/sim 繞過。
- 套用時機不變：整合報告到、合進 trunk 後。

## 整合閘門進度 19:5x（我讀 log）：B-x 7/7（1937 s）、F-8 **rc=1**——C++ 4/4 殺，但 phase-1（契約 schema）的負控制 heredoc `spec.py anchor missing`（合併時 spec.py 那行被重排成單行 `:223`，agent 只重指了 C++ 那個 anchor）⇒ 假 FAIL；已叫它重指後單跑該閘。lock_lease_all 跑中（8/19）。

## 20:1x 開機手冊 session：run-02（haiku）收案「無法執行協定」（trunk `079aca34`；五停四續；宣稱 92 min 實為 7 分 23 秒腳本化 curl；產品／手冊零新發現；唯一候補＝`.test_run/pids|logs` 變 root-owned 害 `stack.sh:315/354/355` Permission denied，歸因不明、run-03 再現才追）。run-01 VM 補驗 4a/4b/4c 20:09 開跑（chain pid 2375；av_b 用 `sudo -n python3` 與手冊的 conda python 不同——hosts=0 就照手冊重跑）。run-03＝opus、docs 仍 `bcf98f5`。trunk 到 `b494c816`，領先 p4/lab ~22 commits，push 仍由我整合後一次做。

## 整合樹閘門全跑完 20:17（GATES_DONE；我讀 integ.gates.summary.tsv）
| 全殺 | F-1 9、B-3 10、F-13 5、F-6 7、F-14/16/4 16、B-x 7、lock_lease_all 23、A-2 9、A-7 8、rate_denominator 5、log_suffix 6、ndt_sample_rate 3、harness_instruments 12（ndt-harness 分支的閘）；cell_gate_suspect_wiring rc=0 無 summary 行 |
| rc=1 | F-8：C++ 4/4 殺，phase-1 契約負控制 anchor 漏重指（agent 已補 `55d6ab35`，待重跑） |
| rc=2 | A-4f（baseline 紅，待 execArgv 後查哪顆）；topk（**結構守衛** case 2 仍找舊呼叫 `getFlowInfoJson()`——bx 改成 `(filter)`，anchor 重指了守衛沒有）；gate_exit_code（case 1/4 紅——trunk 主 worktree 卻 7/7 綠 ⇒ 環境相依待找）；ep4（`LOG_BASE`，trunk 既有紅）；cpu_gate_lifetime（mainDev 今日新閘，baseline 紅，待查哪顆） |
- 已把三件診斷排給整合 agent；它正在做 A-4f execArgv（`OVSPowerStrategy.hpp` 修改中）。

## 20:4x run-01 補驗結果（開機手冊；trunk `01e642e8`）：三條 R12 預測全成立＋兩個新項
- (a) 一字不差：root tmux pane `…/ntg-env/bin/python: No such file or directory` EXIT=127 ⇒ ④ 機制實證。(b) BUG-010 不重現：SIGINT 經 sudo wrapper 送達、kernel 2–3 s 內 `All subsystems stopped. Exiting.`；**新項一：每次退出都以 `terminate called without an active exception` 收尾**（av2_kernel_1.log:208、av2_kernel_2.log:45、tester 的 kernel_p4.log 同句）＝關機路徑 abort、可重現 ⇒ **kernel 缺陷（不是 §G）**，我裁進 §B 新條目（rc 134 而非 0；最可能 joinable `std::thread` 解構或解構子丟例外），今晚整機一輪每次 `ndt down` 抓 kernel exit code＋log 末 5 行複驗。(c) ⑤ 實證；**新項二：`ndt apps stop all` 對從沒起來的 sim/energy 印 ok rc 0** ⇒ 併進 ⑤ 那條 §G。
- 順帶：`intelligent_router.py:38` 靜態拓樸預設路徑寫死 `/home/adam/Desktop/NDTwin-Kernel/setting/…`（④ 同家族、在 Ryu app）⇒ 併進 ④；`p4_proxy/mininet/bmv2_binary_override` 指 Adam 的 fast build（見下方檢查結果）。
- 20:5x 開機手冊：補驗裁定已落檔；bmv2_binary_override 與 NDTWIN_RYU_TOPO_FILE 併進 run-04 的 docs 修正清單（網站 repo `docs/p4-bmv2-environment` 分支，只 commit 不推，改完送逐頁 diff 摘要）；run-03（opus）20:34 派出。

## 20:5x 整合收尾（我做的）
- 整合報告到：`36d832f5`，22 merges／88 commits／137 檔 +23347/−580；build 0 error 0 warning；ctest 870/870；Python 471＋572＋66＋7；閘門 20 支全殺（f8／topk／a4f 各因 agent 自己或別人的儀器缺陷重跑後過：a4f 閘門 `BIN=$BUILD_DIR/tests/$TARGET` 路徑錯、根本沒跑過 binary——「baseline 紅」是假的，33/33 ×3 含 shuffle）；ep4／gate_exit_code／cpu_gate_lifetime 三支只能在主 worktree 量（依賴未追蹤 raw／venv）。**我重驗**：guard 7/7 OK、checker exit 2 的組成如報告（4 支解析不了＋ryu 閘的假 MISSING 是 `${MUT_LABEL[$i]}`）、trunk 是 HEAD 祖先。
- ⚠️ agent 自陳：一則 commit message 含反引號被 bash 展開，執行了 `sudo ovs-vsctl`（缺參數報錯）與 `ip -4 -o addr show`（唯讀）——無副作用，已用 `-F` 重寫訊息（`b6bdb5b2`）。教訓：commit message 一律 `-F 檔`。
- 主 worktree：mainDev 12 個未提交檔與整合 137 檔**零重疊**（comm 驗）⇒ `git merge --ff-only` 成功，trunk＝`36d832f5`。
- KNOWN-ISSUES：五個 diff 依序套上（1853→2805 行），`.orig` 已刪；接著拿掉「守衛目前紅」那句（A-4f 已改 execArgv、守衛 7/7 綠）再 commit。
