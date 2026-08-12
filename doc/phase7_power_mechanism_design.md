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

### 沒通過的：powerOn 第一次必失敗

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

- **確定的事實**：helper 的「port 接受 TCP」不足以當作 readopt 可以開始的條件；powerOn
  在這個環境下第一次一定失敗。
- **還沒證實的機制**：時間點符合 gRPC 全域 subchannel pool 的重連 backoff（舊 client 對死掉的
  port 狂連，新 channel 共用到那個帶 backoff 的 subchannel）。**符合不等於就是**，沒有驗證，
  不要當結論寫進程式碼註解。
- `routes_installed: 0` 不是 bug：那個時間點路徑已經繞開 s6，所以「s6 的路由」本來就是空集合。
  之後 link recovery 重算路徑才把 4 條規則裝回去——實測確認。

### 沒通過的：失敗原因在兩邊的 log 都查不到

`readopt` 的 docstring 寫「502 和 404 **both carry the step detail so the kernel's log says
what actually broke**」。做不到：`P4PowerStrategy::executeSystemCommand` 用
`curl -sS -f`，**`-f` 會把 body 丟掉**，kernel log 只剩 `curl: (22) ... error: 502`。
proxy 那邊也只有 uvicorn 的 access log 一行 502，沒有細節。

`step: "pipeline"` 是我**手動再打一次那個端點、拿掉 `-f`** 才看到的。設計寫下來的意圖被
呼叫端的一個旗標取消掉了。

### 沒通過的：twin 對關掉的 switch 會短暫謊報 Up

1 Hz 取樣 59 次，有 **1 次** `is_up=true`，而同一次取樣 `bmv2=9`、`:50056` 沒人聽——
process 確定是死的。另一次出現在兩分鐘前（16:32:26 與 16:34:26，**相隔正好 120 秒**）。

proxy 沒有說謊：整整 70 秒的取樣裡 `probe_ok` **一次都沒有 true**，`probe_age_s` 都在 1.6 秒內，
`stream_alive: false`。照 `p4LivenessFor` 的政策這應該穩定判 Down。所以 Up 是**別的東西**寫的，
不是 probe 路徑。120 秒的間隔像週期性任務，但**只有兩個資料點，機制未確認**。

影響：閒置策略若在那一秒讀到 `is_up`，會以為關掉的 switch 還活著。
