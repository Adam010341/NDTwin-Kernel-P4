# run-03（opus）— orchestrator 獨立複驗（2026-09-02 23:03–23:15 CST）

**原則**同 run-01／run-02：tester 的回報是**宣稱**。每一列都是本線進 guest **唯讀**查
（`orchestrator-scripts/harvest03.sh`、`harvest03b.sh`、`pull03.sh`，15:04–15:05Z）或讀 repo／手冊原始碼查出來的。
「CONFIRMED-by-log」＝只讀它留下的 raw log、沒重跑。
VM＝`nslab:~/ndtwin-vm-usertest-03-opus/`（port 2313、qemu 322483）。guest＝UTC，host＝CST（+8）。

🔴 **這一輪沒有 tester 的最終報告。** agent 在 22:08 CST 因為**我們自己這條 Claude session 撞到用量上限**
（HTTP 429，`session limit · resets 11pm Asia/Taipei`）而中止——**這是 orchestrator 端的中止，不是專案缺陷、
也不是 tester 失敗**。它的遺言是「A genuine catch-22: the manual's prescribed interpreter can't import
Mininet. Let me confirm both directions and work around it.」`JOURNAL.md` 裡 **沒有 `## SUMMARY`**（grep 命中 0），
最後一則寫到 13:59Z。倖存的記錄＝`JOURNAL.md`（251 行）＋`BUGS.md`（662 行、22 條）＋ 50 支 `~/logs/*.log`
＋ 76 個 `logs/api_ovs/` 端點檔 ＋ 55 支它自己的 `/tmp/*.sh` 驅動腳本。**沒有替它補寫任何總結。**

## 時間線（CST）

| 時刻 | 事件 |
|---|---|
| 20:30:35 | VM start（4 vCPU／6144 MB、affinity 16-19）；qemu 322483 |
| 20:34 | opus tester 派出（prompt sha256 前 16 碼 `1b9fd8aed8cbc9fe`；docs `bcf98f5`） |
| 20:35–20:52 | 安裝手冊 §1–§5（conda／ryu／系統相依／ninja build／topology 腳本） |
| 20:53:05 | §6.1 `install-p4dev-v8.sh` 進 `P4` tmux 背景開跑 |
| 20:56–21:16 | 等 §6 的空檔：讀完 User Manual＋41 端點 API 頁、寫 `CHECKLIST.md`、備妥 NSR／NTG 環境、無 fabric 的 kernel CLI 檢查 |
| 21:16–21:21 | User Manual OVS 三終端（T1 Ryu／T2 topology／T3 kernel），一次成功 |
| 21:21–21:59 | 使用與破壞：41 個 REST 端點逐一驗**效果**、`ndt` launcher、第二次完整 bring-up、power state |
| 21:59 | `JOURNAL.md` 最後一則（13:59:50Z） |
| 22:00–22:08 | NTG：發現 interpreter 的 catch-22、做出 `ntg-env2` workaround、重試 |
| **22:08:53** | **最後一筆 raw log（`50_ntg2.log`，14:08:53Z）＝ agent 被我們的用量上限中止的時刻** |
| **23:01:22** | **§6.1 build 自己跑完（`SCRIPT_EXIT=0`）——tester 已死 53 分鐘，沒人看到** |
| 23:03–23:05 | 本線唯讀 harvest（tmux pane×4、GUEST-STATE、tar 拉回，共 216 個檔） |

## 宣稱 vs 證據

「檔案」欄一律相對 `tester-files/`。

### A. 安裝階段（JOURNAL 的數字）

| # | 宣稱（tester 原文） | 佐證檔 | 逐字節錄 | 判定 |
|---|---|---|---|---|
| A1 | Step 2.4「printed exactly the four lines the manual predicts: dnspython 1.16.0 / eventlet 0.30.2 / greenlet 2.0.2 / ryu 4.34」 | `logs/02b_ryu.log:643-650` | `=== Step 2.4 Verify ===` … `dnspython 1.16.0` / `eventlet 0.30.2` / `greenlet 2.0.2` / `ryu 4.34` | **CONFIRMED** |
| A2 | Step 2.5「`ss -lntp` showed LISTEN … 6653 … ryu-manager pid=4212 … so it really was serving」；Ctrl-C → port gone | `logs/02d_stop.log:2,11` | `LISTEN 0 50 0.0.0.0:6653 … users:(("ryu-manager",pid=4212,fd=5))` / `(nothing on 6653/8080 - stopped)` | **CONFIRMED**（有查效果，不是只看印出的字） |
| A3 | §3.3「`ovs_version: "3.3.9"`」「`sudo mn --test pingall` → `*** Results: 0% dropped (2/2 received)`」 | `logs/03_sysdeps.log:2374,2377`、`logs/03b_pingall.log:24` | `active` / `ovs_version: "3.3.9"` / `*** Results: 0% dropped (2/2 received)` | **CONFIRMED** |
| A4 | §4.1 clone → `936f8c6c9d05…` | `GUEST-STATE.txt`（repos 段） | `936f8c6 Snapshot of the P4/BMv2 kernel tree at 20cd80b, published for the manual` | **CONFIRMED** |
| A5 | §4.2「CMAKE_EXIT=0 NINJACLEAN_EXIT=0 NINJA_EXIT=0；grep -ic "error:" → 0；90 targets；binary 11839016 bytes」 | `logs/04b_build.log:44,48,140,144`、`logs/04c_verify.log:2-4,10` | `CMAKE_EXIT=0` / `NINJACLEAN_EXIT=0` / `NINJA_EXIT=0` / `-rwxrwxr-x 1 ndt ndt 11839016 Sep 2 12:48 ndtwin_kernel`；`[40/90] Linking CXX executable bin/ndtwin_kernel` | **CONFIRMED** |
| A6 | 「about 13 minutes on 4 vCPUs at -j2」 | log mtime `04b_build.log` 12:51:41、`04a_clone.log` 12:38:56；journal 記 12:46 起 | 由 mtime 推得 ~12:46→12:51 的 ninja 段 | **CONFIRMED-by-log**（量級相符；本線未獨立計時） |
| A7 | §6.4「AppConfig.hpp 由 cmake 自動生成，已含 `P4_PROXY_IP_AND_PORT = "localhost:8081"`、`ALLOW_MIXED_DATAPLANE = false` ⇒ fresh clone 不必改」 | `logs/04c_verify.log:39` 一帶 | `static const std::string SIM_SERVER_URL = "http://localhost:9000/submit";`（同一個生成檔） | **CONFIRMED** |

### B. User Manual OVS 路徑（JOURNAL 的數字）

| # | 宣稱 | 佐證檔 | 逐字節錄 | 判定 |
|---|---|---|---|---|
| B1 | T2「32 occurrences of "Bandwidth limit 10000 is outside supported range 0..1000 - ignoring"」 | `logs/21_t2_topo.log`（自計數行）＋本線獨立在 `pane_MN.txt` 數 | log：`--- bandwidth-limit warning the manual predicts? --- 32`；本線 `grep -c "Bandwidth limit" pane_MN.txt` → **32** | **CONFIRMED**（兩個獨立來源同數） |
| B2 | T2「`Host internet: OK \| sFlow reachability: OK \| Switch identification: OK`」、45 s 到 `mininet>` | `logs/21_t2_topo.log:17,20`、`T2_START 13:18:43` → `T2_45S 13:19:28` | 該行逐字出現；兩個時戳相差 45 s | **CONFIRMED** |
| B3 | Ryu「`install_all_pair_paths done: hosts=128 pairs=16256 rules=1280 paths=16256 walk=0.347s`」 | `logs/23_flows.log`（末段） | `install_all_pair_paths done: hosts=128 pairs=16256 rules=1280 paths=16256 walk=0.345s…` 與 `walk=0.347s…` 兩筆 | **CONFIRMED** |
| B4 | T3「Data plane: ovs (10 switch(es))」「10 switches, 128 hosts, 288 edges up」「Pulled 16256 paths」「Server Listening on port 8000」 | `logs/24_t3_kernel.log:19,22,23,25` | 四行全部逐字命中（`13:20:48.496 … Server Listening on port 8000`；`13:20:53.822 … Pulled 16256 paths from controller`） | **CONFIRMED** |
| B5 | 流偵測「exactly 2 records, one per direction；`10.0.0.2:54764 -> 10.0.0.1:5201 rate_bps_last_sec=982401024`」 | `logs/25_traffic.log` | 兩筆雙向記錄；`get_average_link_usage` 對照見 B7 | **CONFIRMED-by-log** |
| B6 | purge「records went 2,2,2,2,2,2 then 0，即在 t+10s 與 t+12s 之間消失（手冊說 15 s）」 | `logs/32_purge.log`、`33_purge2.log` | 序列如述 | **CONFIRMED-by-log**（tester 自己已註明「我的『最後一個封包』時刻只準到幾秒」——這個但書是對的，本線同意不能拿它去推翻手冊的 15 s） |
| B7 | 「`get_average_link_usage` 在 h1↔h2（同交換機）回 0.0；h1↔h50（跨三台）回 0.45873436975000004」 | `logs/31_strict.log` | `{"avg_link_usage":0.45873436975000004,"status":"success"}`；`"switch_count":3`；path `[16777226, 1, 5, 2, 838860810]` | **CONFIRMED** |
| B8 | 第二次 bring-up「convergence stable at t+63 s；130 flows on every switch again；HstA 存活」 | `logs/47_run2.log` | `t+52s : 130 ×10` / `t+63s : 130 ×10` / `STABLE at t+63s after topology start` / `"device_name":"HstA"` | **CONFIRMED** |
| B9 | power state：s10 off → bridge 真的消失、graph `is_up=False`；on → 回來 | `logs/48_power.log` | `-- AFTER off: bridges -- s1 s2 s3 s4 s5 s6 s7 s8 s9`（無 s10）；`s10 node: is_up=False`；`-- AFTER on: bridges -- s1 s10 s2 …` | **CONFIRMED**（查的是 bridge 的存在，不是回應字串） |

### C. BUGS.md #1–#22

| # | 宣稱摘要 | 佐證檔 | 逐字節錄（節選） | 判定 |
|---|---|---|---|---|
| #1 | §2.6.2 三個 knob 有兩個不是 knob；預設值寫死 `/home/adam` | `logs/02e_router.log:4,7-13`、`logs/02f_cfg.log:1-8` | `56:is_mininet = True   # … SEE ABOVE, this value is discarded`；`602:is_mininet = True`；`=== edit (1) static_topology_file_path : /home/adam -> /home/ndt ===`；`92:_env_switch_num = os.environ.get("NDTWIN_RYU_SWITCH_NUM")` | **CONFIRMED**（靜態閱讀，tester 自己也標 n/a） |
| #2 | Simulation Platform 頁說 `:8003`，出貨的 header 是 `:9000` | `logs/04c_verify.log:39` | `6:    static const std::string SIM_SERVER_URL = "http://localhost:9000/submit";` | **CONFIRMED**（tester 已自註「我沒照 5.4 做，這是讀出來的不一致，不是觀察到的執行失敗」——這個自我限縮是誠實的） |
| #3 | `ln -sf … ~/.local/bin/ndt` 在新機失敗 | `logs/11_lnbin.log:7-8,11-12,15` | `ln: failed to create symbolic link '/home/ndt/.local/bin/ndt': No such file or directory` / `LN_EXIT=1`；重跑 `LN_EXIT_2=1`；`mkdir -p` 後 `LN_EXIT_3=0` | **CONFIRMED**（含它宣稱的「跑兩次」） |
| #4 | NSR start 腳本裡沒有手冊要你檢查的 interpreter 路徑，是裸 `python3` | `logs/07_tools_prep.log` | 腳本內容 `nohup python3 network_state_recorder.py &` | **CONFIRMED** |
| #5 | NSR stop 腳本正是它自己手冊禁止的 `kill $(pgrep -f …)` | `logs/07_tools_prep.log` | 腳本逐字含 `sudo kill -15 $(pgrep -f network_state_recorder.py)` | **CONFIRMED** |
| #6 | `--ai` 無 key → 未捕捉的 C++ 例外 abort | `logs/09_kernelcli.log:18,23,25` | `[error] [LLMAgent.cpp:37 LLMAgent] OPENAI_API_KEY environment variable is not set.` / `what():  OPENAI_API_KEY environment variable is not set.` | **CONFIRMED** |
| #7 | `--topology` 檔不存在 → 記 error 但照樣起來 | `logs/09_kernelcli.log:31,36` | `[info] … Topology file: ../setting/NOPE.json`；`[error] [TopologyAndFlowMonitor.cpp:207 loadStaticTopologyFromFile] Cannot open topology file:  ../setting/NOPE.json`（子系統的 info 行在它之前） | **CONFIRMED** |
| #8 | registered 的 binary 進了 git ⇒ 手冊承諾的失敗不會發生；且與 `make all` 產物是不同 build | `logs/13_simplat2.log:6-7,12-13,25,28`、`logs/14_spm.log:3-6`、`logs/12_simplat.log:17` | `83d6e39 2026-01-28 16:18:39 +0800 Add demo registered Apps`；`8243d24952c1…  -`（committed）vs `2ed19b2c746c…  registered/…/executable`（make all 後）；刪掉後裸 `make` 兩者仍 `No such file or directory` | **CONFIRMED**（三段都有檔：committed 存在、裸 make 不生、兩個 sha 不同） |
| #9 🔴 | `modify_flow_entry` 連 controller 的 priority=10 路由規則一起改寫，主機失聯 | `logs/29_repro.log` | before `priority=10,ip,nw_dst=10.0.0.98 actions=output:1`；after modify `priority=10,… actions=output:7` 與 `priority=99,… actions=output:7`；ping `0% packet loss` → `100% packet loss`；對照組 10.0.0.98 未動時 `0% packet loss` | **CONFIRMED**（有前後、有對照組、有 ping 效果——這一條的證據品質是全篇最高的） |
| #10 🔴 | 鎖 API：缺 `type` 仍拿 `routing_lock`（手冊說 2026-08-30 起一律 400） | `logs/28_lock_flow.log:1-14`、`logs/26_api_ovs.log:116-121` | acquire `{"ttl":30}` → `{"status":"locked","ttl":30,"type":"routing_lock"}` `[HTTP 200]`；`{}` → `ttl:5` 200；`{"type":123,"ttl":30}` → `ttl:5` 200（ttl 也被丟掉）；`banana_lock` → `[HTTP 423]`；renew `{}` → `HTTP 200 {"status":"renewed","ttl":5,"type":"routing_lock"}` | **CONFIRMED-but-mis-stated** — 見下方註 ① |
| #11 | install/modify/delete flow 的回應 body 與手冊不符 | `logs/28_lock_flow.log`（六次呼叫全同） | `{"accepted":1,"detail":"entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response","status":"queued"}`；錯誤路徑 `[HTTP 404] {"error":"unknown dpid",…"unknown_dpids":[106225808380928]}` 且十台交換機都是 `0` | **CONFIRMED** |
| #12 | 手冊說 131／自己的敘述算出 129／機器是 130 | `logs/23_flows.log` | `total lines with actions=: 130`；`128 priority=10` / `1 priority=65535` / `1 priority=0`；十台 `s1..s10` 全 `130`；Ryu `rules=1280`（÷10＝128） | **CONFIRMED**（十台全查、兩輪取樣） |
| #13 | cpu 與 memory 回傳位元組相同、且兩次取樣不變 | `logs/27_effects.log:29-35`、`logs/api_ovs/D12_*.txt`、`D13_*.txt` | sample 1／sample 2 的 cpu 與 mem 四份字串完全相同（`{"192.168.123.11":14,…,"192.168.123.20":26}`） | **CONFIRMED** |
| #14 🔴 | `/ndt/simulation_completed`（與 §17）回報成功，但自己的 log 說 forward 失敗 | `logs/30_more_api.log:28-36`、`logs/31_strict.log`（kernel log 摘錄） | API：`{"status":"result forwarded"}` `[HTTP 200]`；同一請求的 kernel log：`Command failed (exit code 7): curl -s -X POST "http://127.0.0.1:9000/simulation_completed"…` 接著 `Forwarded simulation result, response:`（空）。§17：`{"status":""}` `[HTTP 202]`，手冊寫的是 `{"status": "Request received (…)"}` | **CONFIRMED**（兩端都有：API 回應 + kernel log 的 exit 7） |
| #15 | 一批「完全照文件」的端點（link failure／group／meter／strict delete／historical／intent／rename…），且**效果**都查過 | `logs/26_api_ovs.log`＋`logs/api_ovs/` 76 個檔、`logs/27_effects.log`、`logs/31_strict.log` | 例：strict delete 後 `priority=10,ip,nw_dst=10.0.0.55 actions=output:25` 存活；rename 三路查證（graph／get_nickname／磁碟 JSON） | **CONFIRMED**（抽查 8 條全部對得上；這一節是「沒 bug ≠ 沒測」的正確做法） |
| #16 | 一個 runtime API 呼叫把 git checkout 弄髒 | `logs/27_effects.log:43`、`GUEST-STATE.txt` | `M setting/StaticNetworkTopologyMininet_10Switches.json`；harvest 時 repo 仍是 `M intelligent_router.py` ＋ `M setting/StaticNetworkTopologyMininet_10Switches.json` | **CONFIRMED** |
| #17 🔴 | NSR `start_…sh` exit 0、改了你的設定、什麼都沒起 | `logs/33_purge2.log:20-28` | `display_on_console: true` → `START_SCRIPT_EXIT=0` → `ModuleNotFoundError: No module named 'nornir'` → `display_on_console: false` | **CONFIRMED** |
| #18 | NSR 的 `logs/` 從未建立 ⇒ 手冊的 `tail -f logs/NSR_$(date +%F).log` 不可能成立 | `logs/34_nsr.log`（`-- E15: logs/ --`）、`logs/35_nsr2.log`（九次取樣） | `ls: cannot access 'logs/': No such file or directory`；九個取樣行的 `logs dir:` 全空 | **CONFIRMED**（tester 自己已寫下無法排除的但書「可能只有 `display_on_console: false` 時才寫檔，而我測不到那個組合」——本線同意這個限縮，不把它記成完整結論） |
| #19 | NSR 本體是好的（週期、命名、輪替壓縮、記錄形狀） | `logs/35_nsr2.log` | `13:31:56 \| DEBUG : Writing item with timestamp 1788355911821 to ./recorded_info/2026_09_02_13-31-16_flowinfo.json...`；13:33:33 取樣出現 `…_flowinfo_json.zip`＋新的 `2026_09_02_13-33-19_*`；`pgrep -af` → `145497 python3 network_state_recorder.py` | **CONFIRMED** |
| #20 | NSR stop 腳本在沒東西可停時印 kill(1) usage 仍 exit 0 | `logs/34_nsr.log`（開頭到 `STOP_EXIT=0`） | 整段 `Usage: kill [options] <pid> [...]` 後 `STOP_EXIT=0`；且 `display_on_console: true` 被改回 | **CONFIRMED** |
| #21 🔴 | `ndt up ovs` 在照手冊裝好的機器上不可能成功：`/usr/local/sbin/ndtwin-lab` 沒有，文件也沒裝它 | `logs/40_probe_lab.log`、`logs/41_workaround.log` | `ls: cannot access '/usr/local/sbin/ndtwin-lab': No such file or directory`；`/home/ndt/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab`（repo 內有）；`55:LAB=/usr/local/sbin/ndtwin-lab`；docs 全文搜尋只命中 clone URL 的 GitHub org 兩行；`ndt down` 也印同一行卻仍結論 `clean`；workaround 後 `-rwxr-xr-x 1 root root 6560 … /usr/local/sbin/ndtwin-lab` | **CONFIRMED**（惟 `ndt up ovs` 的**逐字畫面**無檔，見註 ②） |
| #22 🔴 | `ndtwin-lab ovs-topo-start` 印「OVS topo session started」、exit 0、什麼都沒建，且無任何診斷 | `logs/45_helper.log`、`logs/46_sock.log`、`evidence/ndtwin-lab.sh:82-83` | `OVS topo session started (attach: …)` / `HELPER_EXIT=0`；`no lab sessions` / `bmv2: 0  mininet: 0`；`ndtwin-lab: no topo session`；2 秒後與 15 秒後 `no server running on /tmp/tmux-0/ndtwinlab`；且 `mininet importable as root: /usr/lib/python3/dist-packages/mininet/__init__.py`（排除 mininet 缺席） | **CONFIRMED**，機制本線另行證實——見註 ③ |

### D. 註記

**① #10 的 mis-stated 之處（本線發現，tester 自己沒發現）**
BUGS #10 的觀察表列了一行
`release, no type -> [HTTP 200] {"status":"released","type":"routing_lock"} (when routing_lock was held)`。
**這一行沒有檔案支持。** 拉回來的全部證據裡，唯一「不帶 `type` 的 release」是 `logs/28_lock_flow.log`：

```
### release, no type
    sent: {}
{"detail":"Lock 'routing_lock' is not held or is an invalid type","error":"Release failed"}
    [HTTP 412]
```

即 **412，不是 200**。tester 引用的那個 200 body 來自 `logs/api_ovs/D29_release_lock.txt`，而它的驅動腳本
`tester-scripts/api_test.sh:51` 送的是 `p D29_release_lock /ndt/release_lock '{"type": "routing_lock"}'`
——**有帶 type**，是文件正確用法那一組，不是「沒帶 type」那一組。
**acquire 與 renew 兩半仍然完全成立**（acquire 三種形狀在 `28_lock_flow.log:1-14`；renew `{}` 在
`26_api_ovs.log:119-120` 的 `HTTP 200 {"status":"renewed","ttl":5,"type":"routing_lock"}`），
所以 **#10 的核心結論不變**：缺少／非字串的 `type` 仍會靜默取得 `routing_lock`，而手冊把這件事寫成
2026-08-30 已修的既成事實。要修正的只是 release 那一列 —— 它應該記成 **412（尚未證實 release 有同樣的洞）**。

**② `ndt up ovs` 的逐字畫面無檔（UNVERIFIABLE-from-files，但實質有旁證）**
BUGS #21／#22 引的 `[1/4] control plane (Ryu) / ok Ryu up … [2/4] data plane (OVS fabric) / XX fabric has 0
hosts, expected 128 / NDT_UP_EXIT=1` **在拉回的檔案裡找不到**。原因在 tester 自己的腳本：
`tester-scripts/39_ndtup.sh` 把 `ndt up ovs` 送進 tmux session `UP`，`39b_poll.sh` 用
`tmux capture-pane … | tail -45` 把畫面印到**它自己的 stdout**、沒有重導到檔案 ⇒ 隨 agent 一起消失
（`logs/43_diag2.log` 還看得到 `UP: 1 windows (created Wed Sep 2 13:41:19 2026)` 存在過，harvest 時已不在）。
**但實質不受影響**，因為同一組事實有獨立的檔：
`logs/40_probe_lab.log` 逐字有 `sudo: /usr/local/sbin/ndtwin-lab: command not found`（來自 `ndt down`）；
`logs/42_diag.log` 記下失敗後的殘留狀態 `bmv2 switches 0 / host/switch 0 / topo session absent /
:8000 kernel open :8080 ryu open`、`switches 0 up, 0 enabled`、`links 288 total, 288 down`、
`kernel graph 10 switches (0 up, 0 enabled), 128 hosts, 288 edges` —— 正是 #22 說的
「a kernel serving a model of a fabric that does not exist」。
⇒ **判定：結論 CONFIRMED，逐字引文 UNVERIFIABLE（腳本沒把 pane 存檔）**。這是 run-03 唯一的取證缺口，
應寫進 run-04 的模板：**凡是要引用的畫面，capture-pane 一律 `> 檔案`。**

**③ #22 的機制（本線讀 harvest 回來的 `evidence/ndtwin-lab.sh`，tester 沒讀到這一層）**
```
25:KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel
26:NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python
82:        $TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator \
83:            "$NTG_PY" /home/adam/Network-Traffic-Generator/testbed_topo.py
84:        echo "OVS topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)"
```
guest 的使用者是 `ndt`，`/home/adam/…` 三個路徑（工作目錄、直譯器、腳本）全部不存在 ⇒ `tmux new-session`
失敗、不留 server；而 **第 84 行的 `echo` 沒有任何條件**，`new-session` 成不成功都照印，函式也不檢查回傳值
⇒ 「印成功、exit 0、什麼都沒有」。這**完全吻合 run-01 auditor 讀碼得到的 ④**（見
`run-01-sonnet/RECONCILIATION.md` §6），run-03 是在**真實使用者路徑上獨立重現**，並且比 run-01 多走一層：
把 subcommand 單獨叫出來，證明假成功發生在 helper 自己，與 `ndt` 的 300 s 等待無關。

**④ NTG「catch-22」——遺言的裁定：手冊確實如此，是**兩個**文件缺陷，而且兩個都已在 `bcf98f5` 之後修掉**
tester 的四行探針（`logs/50_ntg2.log:2-5`）把兩個方向都證死了：
```
system python3 + mininet : OK
system python3 + loguru  : ModuleNotFoundError: No module named 'loguru'
ntg-env python + mininet : ModuleNotFoundError: No module named 'mininet'
ntg-env python + loguru  : OK
```
本線獨立複驗（`evidence/ntg-and-lab-probe.txt:37-39`）：`~/ntg-env/bin/python` 3.12.3 → `mininet: None`；
`/usr/bin/python3` 3.12.3 → `mininet: /usr/lib/…/mininet/__init__.py`。
NTG 的 `testbed_topo.py:4-9` 是**頂層** import mininet（缺了就立刻 `ModuleNotFoundError`；
`network_traffic_generator.py:18` 那個包在 `try/except` 裡，不算），同時又要 loguru
（PEP 668 擋住裝進系統）⇒ 手冊叫你建的 `python3 -m venv ~/ntg-env` 兩者不可能同時有。

**但「catch-22」這個詞誇大了，而且底下其實是兩個缺陷：**
- **(a)** Installation Manual（`bcf98f5`，NTG 頁 `:57`）建的是 `python3 -m venv ~/ntg-env`，**少 `--system-site-packages`**。
- **(b)** User Manual（同 snapshot，NTG 頁 `:134-141`、`:263`）叫你跑
  `sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py`——**一個 conda 路徑，guest 上根本不存在**
  （`GUEST-STATE.txt` 只列 `ryu-env`）。**兩本手冊對同一個環境給了同名、不同工具、不同位置的路徑。**
- 而它不是死結，是少一個旗標：tester 90 秒內就破了（`--system-site-packages` 的 `ntg-env2`，
  `logs/50_ntg2.log:8-10` 兩者皆 OK），topology 也真的起來了。

**兩個都不是新缺陷，而且都已修**：run-01（sonnet）記成 BUG-008／BUG-007，網站上對應的修法是
**`062d8eb`（09-02 20:48:30，加 `--system-site-packages` 並說明為什麼不是選配）**與
**`df614ce`（09-02 20:50:18，User Manual 兩處 conda 路徑改成 `~/ntg-env/bin/python`）**，
兩個 commit message 都引 run-01 的 BUG-008／BUG-007。本線核過：`bcf98f5` 是 **09-02 11:26:28**，
比修法早九個多小時 ⇒ **run-03 撞到的是舊 snapshot**。
（時序值得記一筆：兩個修法在 **20:48／20:50** 落地，而 run-03 的 VM **20:30:35** 就已開機、
tester **20:34** 派出——修法是在這一輪跑到一半時才進 repo 的，guest 那份 docs 不會變。）
run-03 的價值是**用四行對稱探針把它證成一個乾淨的雙向事實**，不是又一條新 bug。

**⑤ NTG 的無限迴圈——這一條是真的新，但 tester 沒來得及立案**
用 `ntg-env2` 重試後（14:07:23Z），NTG 自己的 topology **完整起來了**：
`pane_NTG.txt:216-217` 有 `--- Final Configuration Active ---` 與
`Host internet: OK | sFlow reachability: OK | Switch identification: OK`；
`:219-220` 有 `DEBUG : Current NTG Configuration:` 加 nornir inventory dump
（⇒ loguru 有在記、nornir 解析了 NTG.yaml，**早就過了 import 階段**）；
kernel log 14:07:29 收到 `inform_switch_entered dpid=3,6,7,9…`。
然後從 `pane_NTG.txt:228` 起，同一行 WARNING 出現 **約 1675 次**，14:07:55 → 15:04:18，每 2 秒一次，
**採證當下仍在跑**，而 kernel 全程活在 :8000（`GUEST-STATE.txt`：`ndtwin_kernel,pid=188793`）。

機制在 NTG 原始碼裡（本線比對 `/home/adam/Network-Traffic-Generator`，該檔於該工作樹未修改）：
`Utilis/distance_seperate.py:42-43` 的 `except Exception: return [-1]` **吞掉所有例外**，
`:58-59` 把 `[-1]` 翻成那句 `Failed to get hosts from NDTwin server.`，
而 `network_traffic_generator.py:397-401` 是 `while True: … logger.warning(…); time.sleep(2)`
——**無上限重試、且訊息不分辨成因**。`bcf98f5..tip` 之間**沒有任何 commit 碰過這段**。
⇒ **這是 run-03 第一個跑出來的、真正的新缺陷**（NTG repo 側，不是手冊）。

**成因：本線在停機前用一條唯讀 GET 證實了，不再是假說**
（`orchestrator-scripts/harvest03c.sh`，15:22:13Z；輸出存 `evidence/NTG-loop-cause.txt`）：
```
=== is NTG still looping? last 2 lines of the NTG pane ===
2026-09-02 15:22:11 | WARNING : Failed to get hosts from NDTwin server., retrying...

=== GET /ndt/get_graph_data : every node device_name (READ ONLY) ===
node count: 138
device_name values whose [1:] is NOT all digits: ['HstA']
first 12 device_name: ['s1','s2',…,'s10','HstA','h2']

=== does int() throw on the observed values? ===
ValueError on device_name='HstA' -> invalid literal for int() with base 10: 'stA'
```
⇒ **因果鏈六步全部有證據**：
1. tester 在 run 1 用 **`/ndt/modify_device_name`**（文件化的端點，Web GUI 的 Device Information
   面板也走它）把 h1 改名成 `HstA`，寫進被 git 追蹤的 `StaticNetworkTopologyMininet_10Switches.json`
   （`logs/26_api_ovs.log:131`、`logs/27_effects.log:39`），**跨重啟存活**（`logs/47_run2.log:12`）。
2. kernel 完全正常：`get_graph_data` **答得出 138 個節點**，一個都沒少。
3. NTG `Utilis/distance_seperate.py:37` 對**每一個**節點做 `int(node['device_name'][1:])`。
4. `int("stA")` → `ValueError`（上面逐字重現）。
5. `distance_seperate.py:42-43` 的 `except Exception: return [-1]` **把成因整個吞掉**。
6. `:58-59` 把 `[-1]` 翻成 `Failed to get hosts from NDTwin server.`，
   `network_traffic_generator.py:397-401` 的 `while True … sleep(2)` **永遠重試**
   （15:22 仍在跑，已 74 分鐘）。

**⇒ 這條的嚴重度要往上調**：一個**文件化、且 GUI 就點得到**的改名操作，會把 NTG 的啟動路徑
**永久毒化**（因為改名是持久化的，重開機也還在），而使用者看到的訊息**指控錯了對象**——
它說 NDTwin server 拿不到 hosts，但 server 好端端地回了 138 個節點。
沒有任何 log 會告訴你真正的原因是一個 `ValueError`。
**修法有兩個層次**：NTG 端不該 `except Exception` 吞掉成因、也不該無上限重試；
而 `device_name` 被當成 `h<數字>` 來 parse 這件事，代表改名 API 的值域其實是有約束的，兩邊都沒寫。
（一個必須先排除的干擾：`logs/21_t2_topo.log` 顯示 topology 腳本**啟動階段本來就會**印一批 100% 遺失的
ping，所以 `pane_NTG.txt` 開頭那些 100% loss 不能單獨當成證據。）

**⑥ 順帶查出：這台機器上有過兩個 kernel，其中一個 13:57:44 撞埠自殺**
`pane_KERNEL.txt:10-13`：
```
[error] [FlowLinkUsageCollector.cpp:690 openReceiveSocket] bind() to sFlow port 6343 failed: Address already in use.
[critical] [main.cpp:406 main] cannot start telemetry collection: Failed to bind UDP socket. Exiting
```
⇒ tmux `KERNEL` pane 裡那個 kernel 13:57:44 就退出了；:8000 上活著的是 `.test_run` 那一個
（pid 188793，13:57:04 起）。**「kernel 活著」的結論仍然成立**，但這一輪其實有兩次 kernel 啟動、
一次撞埠。tester 沒記錄這件事（它當時正在做 run-2 bring-up）。列為 run-04 要注意的獨立變因。

**⑦ 🔴 最重要的一條：#9／#10／#13 都是「已修」的缺陷，而使用者照手冊 clone 到的公開快照裡沒有那些修法**
這三條在 `doc/KNOWN-ISSUES.md` 都有 id、而且都標成已修：**#9 → A-4e**、**#10 → B-2d**、**#13 → F-1**。
但 guest 的 kernel repo HEAD 是 `936f8c6`＝「Snapshot of the P4/BMv2 kernel tree at **`20cd80b`**」
（`GUEST-STATE.txt` repos 段），而 `20cd80b6` 是 **2026-08-28 10:46:57**。本線逐一用
`git merge-base --is-ancestor` 驗過三個修法在不在那個快照裡：

| KNOWN-ISSUES | 修法 commit | 日期 | 在 `20cd80b` 裡？ |
|---|---|---|---|
| A-4e `modify_flow_entry` 送非 strict | `c46c51eb` | 2026-08-31 11:28 | **❌ 不在** |
| B-2d 三個鎖端點代入 `routing_lock` | `4ee086f8` | 2026-08-30 18:50 | **❌ 不在** |
| F-1 cpu／mem 位元組相同 | `65c5cdb1` | 2026-09-02 14:16 | **❌ 不在** |

⇒ **這三條既不是新缺陷、也不是回歸，而是「安裝手冊叫使用者 clone 的那個公開快照，仍在出貨修法前的碼」。**
最尖銳的是 #10：API 頁把 B-2d 的修法寫成**帶日期的既成事實**
（「All three now return `400` and acquire nothing.」），而讀者拿得到的 build 裡沒有它。
⇒ 處理方式不是開新條目，是去 A-4e／B-2d／F-1 各補一行**出貨口徑**，並排定公開快照的更新。
（本線只認定事實，不代 auditor 決定怎麼修。）

**⑧ CHECKLIST.md 不是這一輪的成績單**
`CHECKLIST.md` mtime 12:55:40Z，**寫在 OVS bring-up（13:16）與整輪 API 掃描（13:22–13:59）之前**，
之後再也沒更新。計數是 **28 WORKS／3 WORKS-BUT／2 BROKEN／5 NOT-TRIED／149 PENDING**（共 187 條）。
⇒ 它是**讀手冊寫出來的計畫**，只有安裝段（A01–A29）填了結果。
**不可以拿它的計數當 run-03 的覆蓋率**；真正的結果在 `BUGS.md` 與 `JOURNAL.md`。

**⑨ 死後才到的證據：§6.1 build 自己跑完了**
`P4` tmux session 在 harvest（15:04:20Z）前 3 分鐘結束，所以 `pane_P4.txt` 是空的
（`pane_capture_errors.txt`：`can't find pane: P4`）。但**日誌完整存活**，而且它是成功的：
```
logs/06a_p4.log（末段，15:01:22Z）
  SCRIPT_EXIT=0
  === the check that decides it, per the manual ===
  1.15.6-1c8c9a4f            SSG_EXIT=0
  p4c-bm2-ss
  Version 1.2.5.17 (SHA: d46d824202 BUILD: Release)   P4C_EXIT=0
  === which mn (manual says should stay packaged 2.3.0) ===
  /usr/bin/mn   2.3.0
  === venv interpreter check the manual mentions ===
  home = /usr/bin      version = 3.12.3
  Total time             : 7640 sec
```
⇒ **§6.1 完成、且手冊自己的四項驗收（兩個 binary 的 `--version`、`mn` 維持 2.3.0、venv 的 `home=/usr/bin`）
全部通過**，總時 **7640 s**。這補上了 `CHECKLIST.md` 的 A30–A34（原本 PENDING）。
**但 tester 從未看到它**——它在 22:08 就被中止，build 在 23:01 才結束。這是**無人看管跑完的機器證據**，
不是 tester 的宣稱，本線據此獨立記錄。

## 統計

| 判定 | 條數 |
|---|---|
| CONFIRMED | 36 |
| CONFIRMED-but-mis-stated | 1（#10 的 release 那一列） |
| UNSUPPORTED | 0 |
| CONTRADICTED | 0 |
| UNVERIFIABLE（腳本沒存檔） | 1（#21／#22 的 `ndt up ovs` 逐字畫面；結論本身另有旁證成立） |

**合計 38 條宣稱。** 沒有任何一條宣稱被 raw log 推翻。
唯一的實質瑕疵是 #10 表格裡一列把「有帶 `type` 的 release」寫成「沒帶 `type` 的 release」，
方向對、結論不受影響，但那一格的證據不是它引的那個檔。

**本線對這份 tester 產出的整體評價（給 campaign 用）**：R12 預期 ⑤「報告的每個數字對得上 log」
基本成立——38 條裡 36 條逐字對得上，1 條引錯檔、1 條腳本沒存檔。
這與 run-02（haiku）形成極強的對比：run-02 的前三條主要宣稱全部 **REFUTED**（把迴圈計畫時長報成手動測試時數、
coverage 100%、18/2/0 對不上自己的 log）。**opus 這一輪不需要「先不信再查」，查完是真的。**

[Co-developed with claude code -- Adam]
