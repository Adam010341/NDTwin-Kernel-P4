# 跨元件串接測試矩陣（2026-08-14 晚，live 實測）

> 本輪目標：把 7 個兄弟元件與 kernel 實際串起來跑一次，回答「哪些建得起來、哪些起得來、
> 哪些連得上」，並標明哪些必須等 Adam。單一機器、P4 fabric（Adam 手動起
> `p4_proxy/mininet/p4_testbed_topo.py`，10×bmv2）＋`stack.sh up p4`（proxy+kernel）。
> head `b9a5bea`；機器 2026-08-14 10:35 重開機後的乾淨環境。
> 測試紀律：兄弟 repo 一律只測不改（唯一動的環境是 session scratchpad 的臨時 venv）。
> 產出：claude code session（串接輪），Adam 委託。

## 總表

| 元件 | 建得起來 | 起得來 | 連得上 | 需 Adam 才能繼續 |
|---|---|---|---|---|
| NDTwin-Kernel | ✅ | ✅ :8000 | —（被連的中心） | — |
| P4 proxy | ✅ | ✅ :8081（4s 收斂 12 路徑） | ✅ 10×bmv2 gRPC | Mininet 本身 |
| Web-GUI | ✅（compose 驗證） | ✅ 三 container（重開機自動回復） | ✅ 輪詢 :8000 全 200、CORS 通過 | — |
| NSR | ✅ | ✅ 官方腳本（conda ntg-env） | ✅ 5s 輪詢、2min zip 落檔實證 | — |
| Visualizer | ✅（mvn, JDK 21 齊） | ✅ JavaFX 於 DISPLAY=:0 存活 100s | ✅ 畫出 14 節點＋即時 flow（rate 與 kernel 一致） | 長開要真人桌面 |
| TE-App | ✅ | ⚠️ 起得來但**互動式**（見發現 3） | ✅ 1s 輪詢＋acquire/release routing_lock 完整生命週期 | 遷移觸發要 OVS 輪（發現 4） |
| NTG | ✅ | ⛔ P4 fabric 無入口（發現 1） | —（設計上綁 OVS+Ryu 同進程） | OVS 輪：起 **NTG 的** testbed_topo.py |
| Energy-App | ✅ | ⛔ mount NFS 硬門（發現 5） | ✅ 註冊腿通（App ID 2、kernel 建 /srv/nfs/sim/2） | `sudo ./energy_saving_app` |
| Sim-Platform-Manager | ✅ | request_manager ✅ :8002；sim_server ⛔ 同 mount 門 | ✅（request_manager 起且聽） | `sudo ./simulation_platform_manager` |

流量面（NTG 的 P4 代打）：mnexec + iperf/ping 實測通——kernel 同時看見 3 條 flow
（UDP 22.3 Mbps、ICMP 往返 0.6/0.32 Mbps，各 7 跳完整路徑），GUI/NSR/Visualizer/TE 四個
消費端同步吃到同一份資料。

## 結構性發現

1. **NTG 不支援 bmv2 拓撲（原樣）——已依 Adam 指示列為待完成功能**（記憶
   `ntg-bmv2-support-pending-feature`）。三層查證：local repo 零 bmv2/P4 參照、user manual
   的 Mininet 模式明定 Ryu+OVS 三終端流程、developer manual 的整合契約
   `command_line(net, config)` 需與 Mininet 同進程。**非架構性不相容**：
   `MininetCommunicator` 只用 `host.cmd`/`host.popen`（與 switch 型別無關），缺的是
   「bmv2 拓撲 + `command_line(net)`」的合體入口（~20 行 glue，含直譯器組合
   `sudo` + ntg-env python + `sys.path.append(dist-packages)` 借系統 mininet）。
2. **kernel 是 app／模擬管線的中介**：`/ndt/app_register`、`/ndt/received_a_simulation_case`、
   `/ndt/simulation_completed` 都在 `HttpSession.cpp`。Sim-Mgr 標頭裡的 10.10.10.250/251
   是他們實驗室的多主機部署；Energy repo 自身設定已是全 localhost，單機管線設計上成立。
3. **TE-App 是互動式程式**：`ask_mode()` 用 `input()` 選模式，背景/無 stdin 直接
   EOFError 崩潰。繞法：`printf '2\n10\n' |` 餵進去（週期模式，EOF 由它的 except 接住）。
   依賴注意：機器上沒有任何現成直譯器同時有 requests+loguru+networkx（conda ntg-env 缺
   networkx），本輪用 session 臨時 venv 代跑。
4. **TE 的遷移邏輯在 bmv2 上結構性觸發不了**：門檻 `congested_threshold=70`（%），
   而鏈路宣告 1 Gbps、bmv2 (`simple_switch_grpc`) 實測天花板 ~170 Mbps → 利用率上限
   ~17%。lock/輪詢/決策迴圈已全數 live 驗證（`0 entries are added` 屬正確判斷）。
   要看真遷移：OVS 輪或（需裁決）調低門檻。
5. **Energy-App 與 sim_server 的 NFS mount 是硬門、且必須 root 執行 binary 本身**：
   兩者 main() 開頭 `safe_system("mount -t nfs …")`，失敗即 `EXIT_FAILURE`（實錄：
   `mount.nfs: failed to apply fstab options`；`sudo -n` 確認 mount 不在免密白名單）。
   **不能預掛代替**：target busy 會讓它們自己的 mount 非零退出，一樣死。正確配方見下節。
   註：NFS 基建本身早佈好（nfs-server active、`/etc/exports` 有 `/srv/nfs/sim`、
   mount point 7/9 建好）——只差 root。
6. **`setupNFSForApp` 以非 root 跑 kernel 時 chown 失敗（警告、非致命）**：註冊照樣
   成功（`Registered app 'power' with App ID: N` + 自動建 `/srv/nfs/sim/N`），但
   「Failed to re-own directory」。all_squash + 777 下實害待 root mount 後那輪驗。
7. **Energy-App 的 app_id 全程用註冊回傳的數字**（`preInstall()` 先註冊再 mount
   `/srv/nfs/sim/<N>`）——一度懷疑的「app 掛 power、kernel 建數字」不對齊**不存在**。
   代價是每次啟動都註冊一次、id 遞增（本輪已到 2：curl 測試=1、app 實跑=2）。
8. **Web-GUI 的 kernel URL 是 build-time 烤死的**，compose 預設
   `NDT_API_BASE_URL=http://192.168.64.8:8000`（別台機器）；本機 `.env` 已蓋成
   localhost 所以現況正確。**換機器部署必重 build image**，是已知坑。
   另：kernel 對 OPTIONS preflight 回 204＋`Access-Control-Allow-Origin: *`，CORS 無虞。

## 給 Adam：下一步要你的三件事

```bash
# (1) Energy 完整管線（兩個 binary 都要 root——它們自己 mount/unmount NFS）
cd ~/Simulation-Platform-Manager && sudo ./simulation_platform_manager   # :9000
cd ~/Energy-Saving-App && sudo ./energy_saving_app                        # :8001，會註冊+mount+開始決策
# request_manager (:8002) 我已用一般權限起著，不用動。
# ⚠️ energy_saving_app 是真актuator：會對 twin 下 /ndt/disable_switch 與 flow 操作。

# (2) NTG 輪（OVS）：Ryu 先起，然後起「NTG 自己的」topo（不是 kernel 的）
#     stack.sh up ovs 到 [2/3] 提示 Mininet 時，改跑：
cd ~/Network-Traffic-Generator && sudo ./testbed_topo.py

# (3) Visualizer 長開（JavaFX 視窗在桌面）：
cd ~/Network-Traffic-Visualizer && ./network_traffic_visualizer.sh
```

## 本輪結束時留著跑的（供接手對照）

Mininet（Adam 的終端）、kernel :8000、proxy :8081、Web-GUI ×3 container、
NSR（背景，累積 recorded_info/）、TE-App（10s 週期）、request_manager :8002、
iperf h2→h3 20M（600s 自然結束）、ping h1→h4 500pps。
收環境順序：先 `stack.sh down`，Mininet 用 `sudo mn -c`（Adam），NSR 用它的 stop 腳本，
TE/request_manager `kill` 即可。

## 證據路徑

session scratchpad（會隨 session 消失）：`visualizer-run.log`、`te-app.log`、
`energy-app.log`、`request_manager.log`、`sim_server.log`、`integration-session-state.md`。
持久的：NSR `recorded_info/`＋`logs/`、kernel/proxy log 在 `.test_run/logs/`。
