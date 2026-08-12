# Phase 7 電源機制設計定案（2026-08-11）

[Co-developed with claude code -- Adam]

範圍：**機制不是策略**。kernel 提供 `/ndt/set_switches_power_state` → `P4PowerStrategy`；
閒置判斷等策略在 Energy-Saving-App，dataplane 無關，不在此範圍。

前提對照（本日實測，不是承接摘要）：

- `P4PowerStrategy::powerOn/powerOff` 仍回 `OpResult::unsupported`（stub）。
- manifest **寫入端已完成**：`p4_testbed_topo.py` 的 `write_manifest`（pid / device_id /
  grpc_port / thrift_port / log_file / argv，只列 verified-live）。缺的是讀取端。
- Phase 6 存活偵測已 wired：`p4LivenessFor` 有定義且在 pingWorker 有 call site。
- 計劃 §456 說要順手修的 OVSPowerStrategy seam **已經修好**，不用再動。

## 決定 1：root helper 是 manifest 的唯一擁有者，kernel 不碰 PID

`kill` 不在 NOPASSWD，Adam 定案走「專用 helper + 一行 NOPASSWD」。順著這個決定，
把 manifest 的解析也放進 helper：kernel 只喊 `sudo -n ndtwin-p4-power {off|on} <switch>`，
「s3 現在是哪個 PID」這個事實只有一個擁有者。kernel 側因此沒有「讀了過期 manifest 去殺
重用後的 PID」這一類問題——那類驗證集中在唯一有權殺的地方做。

helper 的硬規則（也是測試的斷言）：

- `off <name>`：manifest 查 PID → 驗證 `/proc/<pid>/comm == simple_switch_grpc` **且**
  cmdline 含 manifest 記載的 grpc port（PID 重用防線）→ SIGTERM → 等到 process 真的消失
  才算成功（逾時報錯，不升級成 KILL——bmv2 對 TERM 是乾淨退出，賴著不走代表有別的問題，
  該回報不該滅口）。成功後 manifest 的 pid 置 null。
- `on <name>`：拒絕 pid 還活著的 entry → `shlex.split(argv)`、驗證 `argv[0] ==
  simple_switch_grpc` → **不經 shell** 直接 spawn（殺掉整類注入）、setsid、導向記載的
  log_file → 等 gRPC port LISTEN 才算成功 → 原子更新 manifest 的新 pid。
- 任何情況下**絕不含 `pkill`/`killall`/名稱比對殺**。原始 baseline（`6f32bca`）的
  `mnexec -a s1 pkill -f simple_switch_grpc` 錯兩層：`-a` 吃 PID 給了名字（意外 no-op）、
  `pkill -f` 全域比對（修好第一層就殺十台）。`08746f4` 把指令刪掉而不是修，就是為了
  不留這個陷阱。

**Root 信任邊界**：helper 以 root 執行 manifest 裡的 argv，所以 manifest 本身必須不可被
非 root 竄改。`/tmp` 是 sticky 目錄，任何人可以**預先**建立 `/tmp/ndtwin_p4_switches.json`
——topo script 以 root `open(path, "w")` 只截斷不換 inode，檔案擁有者仍是原建立者，之後
就能改寫 argv 讓 helper 以 root 執行任意指令。兩道修補：

1. `write_manifest` 改成 tempfile + `os.replace`（新 inode 必為 root 所有），順帶原子化。
2. helper 讀 manifest 前驗證：owner 是 root、group/other 不可寫，否則拒絕。

安裝（Adam 手動，一次性）：

```
sudo cp tools/p4_power_helper.py /usr/local/sbin/ndtwin-p4-power
sudo chown root:root /usr/local/sbin/ndtwin-p4-power && sudo chmod 755 /usr/local/sbin/ndtwin-p4-power
# visudo 加一行：
adam ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-p4-power
```

sudoers 釘的是 root-owned 路徑。**不可**釘 repo 內的路徑——adam 可寫的檔案掛 NOPASSWD
等於整台機器的 root。

## 決定 2：powerOn = 重啟 process + proxy readopt，兩者缺一即失敗

計劃 §452 只寫「等 gRPC port 開起來」。實測讀完 proxy 連線流程後確認**不夠**，bmv2
重啟後有四樣東西是空的或死的：

| 東西 | 誰在啟動時建的 | 重啟後狀態 |
|---|---|---|
| pipeline | `startup()` 批次 `set_forwarding_pipeline_config` | 空（不能轉送） |
| clone session（telemetry） | `startup()` 在 pipeline 之後 | 空（無 sFlow 樣本） |
| stream / mastership | `client.start()` 的 arbitration | 死（`_stream_receiver` 於
  grpc.RpcError 退出，不重連；無 mastership 則所有 write 被拒） |
| table entries | `install_initial_routes` | 空（沒有任何路由） |

更糟的是 liveness 會**掩蓋**這個殘缺：`p4LivenessFor` 見 `probe_ok=true` 即判 Up，而
probe 是 unary RPC，gRPC channel 自動重連，bmv2 沒有 pipeline 也答得出 COOKIE_ONLY。
所以「只重啟 process」的 powerOn 會做出 twin 說 Up、dataplane 死的——本 repo 一直在
消滅的那種謊，而且這次是 liveness 自己作的證。

因此新增 proxy 端點 `POST /p4/readopt/{dpid}`：

1. 建**新的** `P4RuntimeClient`（同 device_id/addr/p4info/json）——不復用舊 client：
   `stop()` 已關 channel、queue 裡有 None sentinel、receiver thread 已亡，重啟舊物件的
   每一步都是坑。
2. `start(push_config=False)` → mastership settle → `set_forwarding_pipeline_config`
   → `write_clone_session`（順序同 `startup()`，clone session 必須在 pipeline 之後，
   它活在 pipeline 的 PRE 裡）。
3. 換掉 `topology.switches[dpid]`，舊 client `stop()`。

   > **更正（2026-08-12，四主題審計 D 抓到）**：原文寫「持有 clients 引用的只有 api_routes
   > 和 main（grep 過…），swap 安全」。**被點名的 main 就是反例**——`main.py` 有一個
   > module-global `p4_clients`，在 startup 時從 `startup()` 的 summary 抄一份，
   > `shutdown_event` 迭代的是那份。readopt 換掉 `topo.switches[dpid]` 之後那份不會跟著動，
   > 於是關機時停的是已經停掉的舊 client，新 client 的 channel 和 receiver thread 活過關機。
   > 已修：刪掉那個重複的 mapping，shutdown 直接讀 `topo.switches`。
   >
   > 教訓不是「grep 漏了」——grep 沒漏，它找到了 main，是我看到之後判斷它安全。
   > 「有幾個持有者」問對了問題，「持有者拿到的是同一個物件還是一份拷貝」才是會咬人的那個。
4. 對該 dpid 重灌路由（`install_initial_routes` 的迴圈按 `src == dpid` 過濾）。
5. 回報做到哪一步、哪一步失敗，failure 給 5xx + detail。

kernel 側 powerOn 順序：helper on（process 起來、port 開）→ curl readopt（可用）→
兩者都成功才 `setVertexUp` + `OpResult::success`。

不需要重發 `inform_switch_entered`：power off 只動 `isUp`（照 OVS 前例），`isEnabled`
不動，switch 從未離開圖。

## 決定 3：twin 狀態只在動作被證實後更動

照 OVS 修過的樣子與 `IPowerStrategy` 契約：

- powerOff：helper 確認 process 消失 → `setVertexDown`。helper 失敗 → twin 不動、
  `OpResult::failure`。
- powerOn：helper + readopt 都成功 → `setVertexUp`。中途失敗 → twin 不動、failure 訊息
  講清楚停在哪一步。
- `P4PowerStrategy::executeSystemCommand` 從 `void` 改成回 `bool`（OVS 在
  `08746f4` 之後的同款誠實化）。

## 已知殘餘與界外

- **readopt 失敗後的 Up 假象**：helper on 成功、readopt 失敗時，process 活著，
  pingWorker 的 probe 仍會把它標 Up——但它沒有 pipeline。powerOn 回 failure 是誠實的，
  可是 twin 的 is_up 會跟著 probe 走。根治要動 `p4LivenessFor` 的政策（例如 probe 加
  pipeline cookie 檢查），那是 liveness 政策變更，界外。記錄，不處理。

  > **這個殘餘的第二個後果（2026-08-12 補記，四主題審計 A 抓到）**：它同時讓
  > **重試失效**。probe 在一秒內把 vertex 標 Up 之後，重跑 powerOn 會撞上函式開頭的
  > `getVertexIsUp` early-return，回 200 success 而完全不碰 readopt；若搶在 probe 之前，
  > helper 會以「已經在跑」拒絕，錯誤訊息還會指向錯的步驟。**唯一能再次抵達 readopt 的
  > 路徑是 power off 再 power on。** 502 的訊息原本寫「retrying this power-on retries the
  > readopt」，已改成明講 off-then-on，並由 `test_P4PowerStrategy.cpp` 的
  > `TheReadoptFailureNamesARecoveryThatCanActuallyRun` 釘住。
  >
  > 原文只記了「twin 會顯示 Up」，沒記「所以我建議的復原動作做不到」——殘餘寫了一半，
  > 而沒寫到的那一半才是操作員會照著做的那一半。
- **0186#1（Tier 2）**：關掉的 switch 的 dpid 在某些端點回 success/0 而非錯誤，
  Energy-Saving-App 若拿它當閒置判準會誤讀。機制本身不消費它。Tier 2 依 Adam 指示不動。
- **關機期間的 watchdog 行為**：殺掉 bmv2 → stream 死 + probe 失敗，赦免邏輯
  （「gRPC 活著才赦免」）不適用，watchdog 會如常繞路——這正是計劃 §479 步驟 6 要的
  「其他九台照常轉送」。開回來之後靠既有的 link recovery 機制收斂，不另造。

## 驗收

- 計劃 §456：mock `executeSystemCommand`，斷言指令只針對單一目標、絕不含 `pkill -f`。
- C++ 測試照 `test_OvsPowerStrategy.cpp` 的形狀（seam 覆寫 + 真 TopologyAndFlowMonitor）。
- helper 的拒絕路徑（壞 manifest、活 PID、comm 不符、非 root 所有）以假 manifest 無特權測。
- Python：readopt 的成功／每一步失敗、manifest 原子更新。
- 全部過 mutation gate。
- Live（計劃 §479 步驟 6）：off → 那台關掉且**保持**關掉、其他九台照常轉送；on → 回來
  且路由重灌。前置：Adam 的 OVS 手動輪結束、切 P4 stack、helper 安裝 + sudoers 行。

## Live 驗收結果（2026-08-12 16:29–16:38，實跑）

[Co-developed with claude code -- Adam]

環境：Mininet + 10 台 bmv2 + proxy + kernel，`stack.sh up p4` 收斂為 10 switches / 40 edges /
12 paths。對 **s6**（`192.168.123.16`，dpid 6）做 off → 保持 6 分鐘 → on。

判準不是只看 API：全程從 h1 灌兩條 ping（`mnexec -a`，20 pps），一條的路徑**不經過** s6，
一條**經過** s6。API 全綠但封包停掉，是這個 repo 已經踩過的坑。

### 通過的

| 項目 | 實測 |
|---|---|
| 只關掉目標那一台 | `pgrep -cx simple_switch_g` 10→9，gRPC 只少 `:50056`，其餘 9 個 pid 不變 |
| **其他九台照常轉送** | h1→h2（s1→s5→s2）**9000 送出 / 9000 收到 / 0% 遺失**，全程無 >0.5s 的間隙 |
| 關掉的那台真的不轉送了 | h1→h3（經 s6）在 power-off 那一瞬間斷掉，最後一個回覆落在 helper 回報 stopped 前 0.3 秒 |
| 保持關掉 | 60 秒 20 次取樣，`bmv2=9` 從頭到尾，沒有東西把它拉回來 |
| twin 誠實 | `is_up=false`、power state `OFF`、kernel 停止輪詢 `/stats/flow/6`；`edges` 維持 40（決定 2：switch 不離開圖） |
| 自動繞路 | proxy 偵測到 s6 的鏈路全斷 → `link_failure_detected` ×6 + 重算路徑，h1→h3 **14.9 秒**後自己回來，改走 s1→s5→s9→s7→s3（ttl 前後都是 59，一樣 5 跳）。s6 從 12 條路徑中完全消失 |
| powerOn 之後完全復原 | s6 回到 4 條路徑、每台 4 條規則、h1→h3 200/200 0% 遺失 |

> 繞路這件事值得記一筆：`doc/p4_manual_test_runbook.md` 寫「failover 還沒做」，那是指
> **`tc netem` 砍單一鏈路**的情境（process 還活著）。**整台 switch 死掉**是不同的路徑——
> gRPC stream 斷、probe 失敗、beacon 停，proxy 會回報 link failure 並重算。兩件事不要混。

### 沒通過的：powerOn 在關機夠久之後會失敗，而且文件寫的復原方法也失敗

`POST set_switches_power_state?action=on` 回 **HTTP 500**。分解：

1. helper **成功**：`{"status": "started", "name": "s6", "pid": 65972}`，manifest 更新，
   process 活著，`:50056` 在聽。
2. `POST /p4/readopt/6` 回 **502**，卡在 **`step: "pipeline"`**，錯誤是
   `UNAVAILABLE ... ipv4:127.0.0.1:50056: Connection refused`。
3. kernel 的行為**完全正確**：twin 不動、回 failure、log 寫明卡在哪一步，並照 `2abf1e3`
   的修正叫人 off-then-on 而不是重試 power-on。

關鍵在於 **port 明明在聽**。手動連 `127.0.0.1` / `localhost` / `::1` 三種都 CONNECTED，
而同一時間 readopt 仍然拿到 Connection refused。第二次手動 readopt（process 起來約 90 秒後）
**還是** refused；第三次（約 130 秒後）**成功**，`{"status":"success","clone_session":true,
"routes_installed":0}`。

- **確定的事實**：helper 的「port 接受 TCP」不足以當作 readopt 可以開始的條件。
- **補充實測（同日 16:52，換掉 `-f` 之後重跑）**：**關掉 1 秒就開回來，powerOn 第一次就成功**
  （`routes_installed: 4`）。所以「powerOn 第一次一定失敗」是錯的說法，正確的說法是
  **失敗與否取決於它被關了多久**，不是取決於 process 剛起來。關 4 分鐘再開 → 一樣失敗，
  一樣卡在 `step: "pipeline"`。
- **⚠️ 而且文件寫的復原方法也失敗。** 失敗之後照 `2abf1e3` 那句訊息做 off-then-on
  （這一輪只關了 1 秒）——**回 500**。反而直接打 `POST /p4/readopt/6`，約 65 秒後**一次就成功**。
  所以現在那句「Recover with power off and then power on」在這個狀態下不可靠。
  `2abf1e3` 修掉的是「叫人重試 power-on」這個更糟的建議，方向沒錯，但它換上的替代方案
  **同樣沒有實測撐腰**——這正是那次修正想消滅的毛病，只是換了個位置。修 powerOn 的時候
  一起修這句話。
- **還沒證實的機制**：上面那個對比讓「bmv2 還沒 ready」的讀法站不住（關 1 秒和關 6 分鐘，
  新 process 的啟動過程一模一樣）。剩下比較合理的方向是 gRPC 全域 subchannel pool 的重連
  backoff——proxy 的舊 client 對死掉的 port 連越久，backoff 長越大，新 channel 共用到同一個
  subchannel。**符合不等於就是**，沒有驗證，不要當結論寫進程式碼註解。
- `routes_installed: 0` 不是 bug：那個時間點路徑已經繞開 s6，所以「s6 的路由」本來就是空集合。
  之後 link recovery 重算路徑才把 4 條規則裝回去——實測確認。

### 沒通過的：失敗原因在兩邊的 log 都查不到

`readopt` 的 docstring 寫「502 和 404 **both carry the step detail so the kernel's log says
what actually broke**」。做不到：`P4PowerStrategy::executeSystemCommand` 用
`curl -sS -f`，**`-f` 會把 body 丟掉**，kernel log 只剩 `curl: (22) ... error: 502`。
proxy 那邊也只有 uvicorn 的 access log 一行 502，沒有細節。

`step: "pipeline"` 是我**手動再打一次那個端點、拿掉 `-f`** 才看到的。設計寫下來的意圖被
呼叫端的一個旗標取消掉了。

> **已修（`eace67c`）**：改成 `--fail-with-body`——一樣 exit 22（seam 的控制流不變），但
> body 留著。實測確認 readopt 的回應現在會進 kernel log：
> `{"status":"success","dpid":6,"clone_session":true,"routes_installed":4}`。
> 順帶一提 `routes_installed` 這個數字上一輪要手動打端點才看得到，現在是白送的。
>
> 原本護著這件事的斷言護不住：`"-f"` 是 `"--fail-with-body"` 的**子字串**，所以
> `find("-f")` 對「留 body」和「丟 body」兩種旗標都會通過。新測試改成比對整個 token，
> 並把「非 2xx 要失敗」和「body 要留著」拆成兩個各自獨立的主張。
> Mutation gate：把旗標改回 `-f`，546 條裡**恰好 1 條**紅——就是新的那條，其餘 545 條全綠，
> 這正好證明舊斷言真的抓不到。

### 沒通過的：twin 對關掉的 switch 會週期性謊報 Up（機制已釘死）

1 Hz 取樣 59 次有 **1 次** `is_up=true`，而同一次取樣 `bmv2=9`、`:50056` 沒人聽——
process 確定是死的。proxy 沒有說謊：70 秒取樣裡 `probe_ok` 一次都沒有 true。

**機制（2026-08-12 實測釘死，不是推測）**：寫這個 Up 的是**拓樸輪詢**，不是 liveness probe。

1. `TopologyAndFlowMonitor::updateSwitches`（`:565`）對控制平面列出的**每一個** dpid
   **無條件**做 `isUp = true; isEnabled = true`。沒有任何存活性判斷。
2. P4 proxy 的 `/v1.0/topology/switches`——就是 `updateSwitches` 吃的那個端點——
   **會列出已經死掉的 switch**。它 render 的是 `topology.switches.keys()`，也就是
   P4RuntimeClient 的 dict，而 process 死掉不會把 client 從 dict 裡拿掉。
   實測（s6 process 已死時）：該端點回 `[1..10]`，**包含 6**；同一時刻
   `/p4/switch_state` 說 `probe_ok=False, probe_age_s=0.036, stream_alive=False`。
   **同一個 proxy 的兩個端點互相矛盾**，而 kernel 信的是說謊的那個。
3. 1 Hz 的 liveness worker 依 `p4LivenessFor` 在 1 秒內把它改回 Down。

所以每一次輪詢，twin 都會有最多約 1 秒宣稱一台死掉的 switch 活著。

**怎麼釘死的**：`run()` 的輪詢間隔前 90 秒是 5 秒（`kWhileConverging`），之後 30 秒
（`kOnceConverged`）。**這台機器上沒有別的東西在第 90 秒改變節奏。** 於是：重啟 kernel →
立刻關掉 s6 → 用 10 Hz 取樣 `is_up` 150 秒。結果：

```
t= 14.3s  gap= 14.1s      <- 第一次輪詢後的 blip
t= 19.3s  gap=  5.0s
t= 24.4s  gap=  5.1s
 ...（每 4.9-5.1 秒一次，共 15 次）
t= 89.7s  gap=  5.0s      <- 最後一次 5 秒間隔（kernel 起來後 90.2 秒）
t=119.7s  gap= 30.1s      <- 節奏在這裡換檔
t=149.7s  gap= 29.9s
```

blip 的間隔在 kernel 起來後**第 90 秒**由 5 秒切換成 30 秒，跟 `kConvergingFor` 一模一樣。
1451 個取樣點、168 個 up。**輪詢就是寫入者，沒有其他解釋。**

（先前記的「兩次相隔正好 120 秒」是取樣假影：1 Hz 對一個不到 1 秒的視窗，30 秒週期裡
大約每四次才抓到一次。舊的那個讀法會把人引去找不存在的 120 秒任務。）

**真正的缺陷是語意混淆**：拓樸輪詢把「控制平面知道有這台」當成「這台活著」。
OVS 模式下這個混淆剛好成立——Ryu 的 `/v1.0/topology/switches` 只列出 OpenFlow 連線還在的
switch。P4 模式下不成立，因為 proxy 列的是它建過的 client，不是它探測到的存活狀態。

**兩個修法方向**（未定案，等 Adam）：

- **proxy 側（建議）**：讓 `/v1.0/topology/switches` 只列出 `probe_ok` 不是 False 的 switch，
  也就是讓這個端點的語意跟 Ryu 一致。改動小、修在說謊的那一端、而且恢復 kernel 本來就
  依賴的不變量。要注意 `updateLinks`／edges 是否也吃這份清單。
- **kernel 側**：讓 `updateSwitches` 不要宣告存活性（只建圖、不碰 `isUp`）。比較徹底，
  但同時影響 OVS 模式，而 OVS 模式目前正是靠這一行把 switch 標上來的。

影響：閒置策略（Energy-Saving-App）若在那一秒讀到 `is_up`，會把關掉的 switch 當成還活著。
