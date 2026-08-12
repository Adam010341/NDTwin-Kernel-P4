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
